#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Supply-chain note
#
# nektos/act's own install.sh already verifies the *release binary* it
# downloads against a checksums.txt asset published alongside every GitHub
# release (see hash_sha256_verify() in that script) -- that part of the
# supply chain is already vendor-hardened and we do not duplicate it here.
#
# What nektos/act's own docs do NOT protect is the installer *script*
# itself: the previous version of this file fetched
# `https://raw.githubusercontent.com/nektos/act/master/install.sh` -- a
# mutable branch ref -- and piped the response straight into `sudo bash`.
# A compromised/mutated master push, a poisoned CDN cache, or a MITM able to
# present a valid TLS cert for a different origin would be executed as root
# with zero verification.
#
# We close that gap the same way GitHub's own security guidance recommends
# pinning third-party Actions (see the "Secure use reference" in
# docs.github.com): fetch from an immutable commit SHA instead of a
# mutable branch, then verify the fetched bytes against a checksum pinned
# in this file before ever executing them.
#
# Maintenance: if nektos/act changes install.sh upstream and the new
# behavior is wanted, a human must review the diff at
# https://github.com/nektos/act/commits/master/install.sh, then bump both
# ACT_INSTALL_SCRIPT_COMMIT and ACT_INSTALL_SCRIPT_SHA256 below together.
# Verified against the live file at fetch time (2026-08-14): the commit
# below is the last commit to touch install.sh on master, and its raw
# content's sha256 matches the pinned value.
# ---------------------------------------------------------------------------
ACT_INSTALL_SCRIPT_COMMIT="fe017a109f2b78fa5d8cdd3ad2c5691443665c89"
ACT_INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/nektos/act/${ACT_INSTALL_SCRIPT_COMMIT}/install.sh"
ACT_INSTALL_SCRIPT_SHA256="11abcff86ac5ce8b147d4c4ddb4fcee710874adaaf546dc82b7881ee7e0a5778"

sha256_of() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum > /dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        echo "Error: neither sha256sum nor shasum is available to verify the installer." >&2
        exit 1
    fi
}

# is_true() is defined by the shared src/scripts/lib/is_true.sh include,
# which install.yml's `command:` prepends ahead of this file's own content --
# see that file for the single source of truth and the rationale (CircleCI's
# own docs do not commit to a single stringified form of a boolean parameter
# reaching a step's `environment:` map, so both "1"/"0" and "true"/"false"
# must be accepted).

INSTALL_SCRIPT_TMP="$(mktemp)"
trap 'rm -f "${INSTALL_SCRIPT_TMP}"' EXIT

echo "Fetching nektos/act's installer (pinned commit ${ACT_INSTALL_SCRIPT_COMMIT})..."
curl --proto '=https' --tlsv1.2 -sSf --retry 6 --retry-all-errors \
    -o "${INSTALL_SCRIPT_TMP}" "${ACT_INSTALL_SCRIPT_URL}"

ACTUAL_SHA256="$(sha256_of "${INSTALL_SCRIPT_TMP}")"
if [[ "${ACTUAL_SHA256}" != "${ACT_INSTALL_SCRIPT_SHA256}" ]]; then
    echo "Error: nektos/act's install.sh (pinned commit ${ACT_INSTALL_SCRIPT_COMMIT}) failed checksum verification." >&2
    echo "  expected: ${ACT_INSTALL_SCRIPT_SHA256}" >&2
    echo "  got:      ${ACTUAL_SHA256}" >&2
    echo "Refusing to execute an unverified installer. If nektos/act intentionally changed" >&2
    echo "install.sh, this orb needs its pinned commit/checksum bumped (src/scripts/install.sh)" >&2
    echo "after a human reviews the diff." >&2
    exit 1
fi
echo "Installer checksum verified (sha256:${ACTUAL_SHA256})."

# Build the installer's own argv as an array rather than an eval'd string, so
# that no parameter value (bin-dir, version) is re-interpreted by the shell
# a second time.
INSTALL_ARGS=()
if [[ -n "${ORB_VAL_BIN_DIR}" && "${ORB_VAL_BIN_DIR}" != "./bin" ]]; then
    INSTALL_ARGS+=(-b "${ORB_VAL_BIN_DIR}")
fi
if is_true "${ORB_VAL_DEBUG:-}"; then
    INSTALL_ARGS+=(-d)
fi
if is_true "${ORB_VAL_FORCE_INSTALL:-}"; then
    INSTALL_ARGS+=(-f)
fi
if [[ -n "${ORB_VAL_VERSION:-}" ]]; then
    # Passed through verbatim -- nektos/act's own installer resolves
    # "latest" or a specific tag itself; this orb does no version
    # resolution of its own.
    INSTALL_ARGS+=("${ORB_VAL_VERSION}")
fi

echo "Running: sudo env PATH=\"\$PATH\" bash ${INSTALL_SCRIPT_TMP} ${INSTALL_ARGS[*]}"
sudo env PATH="$PATH" bash "${INSTALL_SCRIPT_TMP}" "${INSTALL_ARGS[@]}"
