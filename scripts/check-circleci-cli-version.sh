#!/usr/bin/env bash
set -euo pipefail

# Fails loudly if the `circleci` CLI on PATH is older than the version floor below.
#
# WHY: CLI builds older than 1.0.48254 silently pack this orb's `<<include(...)>>`
# directives as literal text instead of expanding them, producing a broken-but-still-
# `circleci orb validate`-clean orb -- a false green with no other symptom. This script
# exists so that trap surfaces as a loud, early failure instead of a silent one.
MIN_BUILD=48254

if ! command -v circleci > /dev/null 2>&1; then
    echo "check-circleci-cli-version: no 'circleci' binary found on PATH." >&2
    echo "Install the CircleCI CLI (>= 1.0.${MIN_BUILD}) before packing/validating this orb." >&2
    exit 1
fi

version_output="$(circleci version 2>&1)" || {
    echo "check-circleci-cli-version: 'circleci version' failed to run: ${version_output}" >&2
    exit 1
}

# `circleci version` prints e.g. "circleci 1.0.48254 (76ed0cc1b4da)" (older/dev builds
# may add a "-pre"/"-dirty" suffix to the build number, e.g. "1.0.44595-pre").
build="$(printf '%s\n' "${version_output}" | sed -nE 's/.*[^0-9]1\.0\.([0-9]+).*/\1/p')"

if [[ -z "${build}" ]]; then
    echo "check-circleci-cli-version: could not parse a build number out of '${version_output}'." >&2
    echo "Expected output shaped like '1.0.<build> (<sha>)'. Refusing to guess -- required floor is 1.0.${MIN_BUILD}." >&2
    exit 1
fi

if ((build < MIN_BUILD)); then
    echo "check-circleci-cli-version: CircleCI CLI build ${build} is older than the required floor of ${MIN_BUILD} (found: '${version_output}')." >&2
    echo "Builds older than 1.0.${MIN_BUILD} silently pack '<<include(...)>>' as literal text instead of expanding it, producing a broken orb that still passes 'circleci orb validate' -- a false green. Upgrade the CLI and retry." >&2
    exit 1
fi

echo "check-circleci-cli-version: circleci CLI build ${build} >= required floor ${MIN_BUILD}. OK."
