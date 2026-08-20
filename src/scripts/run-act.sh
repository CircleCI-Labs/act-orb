#!/bin/bash
set -uo pipefail

# BEGIN GENERATED: is_true (from src/scripts/lib/is_true.sh -- do not hand-edit; regenerate with `bash src/scripts/sync-embedded-is-true.sh`)
# shellcheck shell=bash
# Bash-safe truthiness for orb boolean parameters -- both "1"/"0" (published
# orb) and "true"/"false" (inline job, per this project's own recorded
# boolean-parameter quirk) must be accepted. This file is a sourced/embedded
# fragment, not a standalone executable -- no shebang, hence the shellcheck
# directive above instead.
#
# SINGLE SOURCE OF TRUTH for this function. install.sh and run-act.sh each
# embed a mechanically generated, byte-identical copy of this file's body
# between "BEGIN GENERATED: is_true" / "END GENERATED: is_true" markers --
# regenerate both with `bash src/scripts/sync-embedded-is-true.sh` any time
# this file changes. (Two more embedded copies, in cache-shim-start.sh and
# oidc-shim-start.sh, existed here until the cache/OIDC shims were split
# onto feature/translation-layer and the cache shim was removed outright;
# that branch still carries its own copy of this same generator for those
# two files.)
#
# Why embedded copies rather than a plain `<<include(scripts/lib/is_true.sh)>>`
# in each command's `command:` field: that was tried first and reverted --
# the circleci-cli baked into orb-tools/pack's own Docker image rejects more
# than one <<include(...)>> directive in a single YAML scalar, and each of
# these commands' `command:` field already has one include for its own main
# script (see git history for the reproduced real-CI pack failure: "An
# unexpected error occurred: multiple include statements"). test_is_true_no_drift
# in .circleci/test-deploy.yml is the real, working drift check for this one
# (regenerates both from this file and asserts `git diff` is clean).
is_true() {
    case "${1:-}" in
        1 | true | TRUE | True) return 0 ;;
        *) return 1 ;;
    esac
}
# END GENERATED: is_true

if [ ! -f "${ORB_VAL_WORKFLOW_FILE}" ]; then
    echo "Error: Workflow file not found at path '${ORB_VAL_WORKFLOW_FILE}'."
    exit 1
fi

# Guard against a stale output-handoff file being silently re-read by
# `collect-outputs` after this call. The handoff file is normally
# truncated by `create-workflow-file`'s own generated step, but that step
# is skipped whenever `skip-create-workflow-file: true` -- e.g. a
# hand-written workflow file, or a second `act/act`/`run-act` call reusing
# the same `directory` in the same job. Removing it here, unconditionally
# whenever `outputs` is requested and regardless of who generated the
# workflow file, means a leftover file from an earlier call can never be
# mistaken for this call's own (possibly absent) output.
if [ -n "${ORB_VAL_OUTPUTS:-}" ]; then
    OUTPUTS_PATH="${ORB_VAL_DIRECTORY%/}/${ORB_VAL_OUTPUTS_FILE:-.act-orb-outputs.env}"
    rm -f "${OUTPUTS_PATH}"
    if ! is_true "${ORB_VAL_BIND}"; then
        echo "Warning: 'outputs' is set but 'bind' is false -- the container's output handoff file can never reach the CircleCI host this way, so no outputs will be collected this run. Set bind: true (the default) to use 'outputs'." >&2
    fi
fi

# Build `act`'s argv as an array and exec it directly, rather than
# concatenating a string and `eval`-ing it. Any parameter sourced from a
# CircleCI pipeline parameter (rather than a literal in config.yml) --
# most plausibly `additional-act-flags`, `platform`, or `directory` -- can
# contain shell metacharacters; an array avoids a second round of shell
# interpretation of that value.
act_cmd=(act --workflows "${ORB_VAL_WORKFLOW_FILE}")

if [ ! -f "${ORB_VAL_ENV_FILE}" ]; then
    echo "Warning: Env file not found at ${ORB_VAL_ENV_FILE}. Skipping..."
else
    act_cmd+=(--env-file "${ORB_VAL_ENV_FILE}")
fi

if [ ! -f "${ORB_VAL_SECRET_FILE}" ]; then
    echo "Warning: Secret file not found at ${ORB_VAL_SECRET_FILE}. Skipping..."
else
    act_cmd+=(--secret-file "${ORB_VAL_SECRET_FILE}")
fi

if [ ! -f "${ORB_VAL_INPUT_FILE}" ]; then
    echo "Warning: Input file not found at ${ORB_VAL_INPUT_FILE}. Skipping..."
else
    act_cmd+=(--input-file "${ORB_VAL_INPUT_FILE}")
fi

if [ ! -f "${ORB_VAL_VAR_FILE}" ]; then
    echo "Warning: Var file not found at ${ORB_VAL_VAR_FILE}. Skipping..."
else
    act_cmd+=(--var-file "${ORB_VAL_VAR_FILE}")
fi

if [ ! -f "${ORB_VAL_EVENT_FILE}" ]; then
    echo "Warning: Event file not found at ${ORB_VAL_EVENT_FILE}. Skipping..."
else
    act_cmd+=(--eventpath "${ORB_VAL_EVENT_FILE}")
fi

# Add parameters with valid defaults
act_cmd+=(--platform "${ORB_VAL_PLATFORM}")
act_cmd+=(--directory "${ORB_VAL_DIRECTORY}")
act_cmd+=(--defaultbranch "${ORB_VAL_DEFAULT_BRANCH}")
act_cmd+=(--remote-name "${ORB_VAL_REMOTE_NAME}")
act_cmd+=(--actor "${ORB_VAL_ACTOR}")

# Check for job
if [ -n "${ORB_VAL_JOB}" ]; then
    act_cmd+=(--job "${ORB_VAL_JOB}")
fi

# Check boolean flags
if ! is_true "${ORB_VAL_PULL}"; then
    act_cmd+=(--pull=false)
fi
if ! is_true "${ORB_VAL_REBUILD}"; then
    act_cmd+=(--rebuild=false)
fi
if is_true "${ORB_VAL_REUSE}"; then
    act_cmd+=(--reuse)
fi
if is_true "${ORB_VAL_DETECT_EVENT}"; then
    act_cmd+=(--detect-event)
fi
if is_true "${ORB_VAL_BIND}"; then
    act_cmd+=(--bind)
fi
if is_true "${ORB_VAL_VERBOSE}"; then
    act_cmd+=(--verbose)
fi
if is_true "${ORB_VAL_ACTION_OFFLINE_MODE}"; then
    act_cmd+=(--action-offline-mode)
fi

# Act already implements the real GitHub Actions artifact-v4 protocol with
# its own built-in local server (pkg/artifacts) -- it just never starts it
# unless --artifact-server-path is passed. Empty (the default) means none of
# these three flags are added at all, so this is a no-op for every existing
# caller. See run-act.yml's own parameter descriptions and the README's
# "Artifacts" section for what this does and does not fix.
if [ -n "${ORB_VAL_ARTIFACT_SERVER_PATH:-}" ]; then
    act_cmd+=(--artifact-server-path "${ORB_VAL_ARTIFACT_SERVER_PATH}")
    if [ -n "${ORB_VAL_ARTIFACT_SERVER_ADDR:-}" ]; then
        act_cmd+=(--artifact-server-addr "${ORB_VAL_ARTIFACT_SERVER_ADDR}")
    fi
    if [ -n "${ORB_VAL_ARTIFACT_SERVER_PORT:-}" ]; then
        act_cmd+=(--artifact-server-port "${ORB_VAL_ARTIFACT_SERVER_PORT}")
    fi
fi

# Act already ships its own built-in GitHub Actions cache server
# (pkg/artifactcache) and starts it automatically unless told not to. When
# enabled (the default), pass --cache-server-path explicitly so this orb's
# own restore-actcache/cache-actcache steps (run around this script by
# run-act.yml) and Act itself agree on exactly where its storage lives, so
# it can be persisted across jobs via native restore_cache/save_cache --
# see the README's "Caching" section for the one documented tradeoff (one
# native cache key per job covers the whole directory) and for what
# happens with no cache server reachable at all (actions/cache warns and
# continues; not a failure). When disabled, pass --no-cache-server so Act
# never starts one at all.
#
# A leading "~/" in the path is expanded to "$HOME/" here, by hand: unlike
# CircleCI's own restore_cache/save_cache `paths:` (which do expand "~"),
# Act's own flag parsing does not -- pkg/artifactcache.StartHandler calls
# os.MkdirAll() on this string verbatim, so an unexpanded "~/..." silently
# creates a literal "~" directory under Act's current working directory
# instead of the real home directory (reproduced live: a real
# actions/cache/save@v4 call succeeded against the server, but nothing
# showed up under the real $HOME afterward, because it was never written
# there in the first place).
if is_true "${ORB_VAL_CACHE_SERVER_ENABLED:-true}"; then
    cache_server_path="${ORB_VAL_CACHE_SERVER_PATH:-$HOME/.cache/actcache}"
    cache_server_path="${cache_server_path/#\~/$HOME}"
    act_cmd+=(--cache-server-path "${cache_server_path}")
    if [ -n "${ORB_VAL_CACHE_SERVER_ADDR:-}" ]; then
        act_cmd+=(--cache-server-addr "${ORB_VAL_CACHE_SERVER_ADDR}")
    fi
    if [ -n "${ORB_VAL_CACHE_SERVER_PORT:-}" ]; then
        act_cmd+=(--cache-server-port "${ORB_VAL_CACHE_SERVER_PORT}")
    fi
else
    act_cmd+=(--no-cache-server)
fi

# Include additional flags if provided. `additional-act-flags` is the one
# place a user can hand us something that needs real shell word-splitting
# (e.g. "--env FOO=bar --env BAZ=qux"), so it is deliberately word-split
# here via an unquoted expansion into the array -- everything else above
# is passed as a single argv element per flag.
if [ -n "${ORB_VAL_ADDITIONAL_ACT_FLAGS}" ]; then
    # shellcheck disable=SC2206
    extra_flags=(${ORB_VAL_ADDITIONAL_ACT_FLAGS})
    act_cmd+=("${extra_flags[@]}")
fi

# Echo the final command for debugging
echo "Running command: ${act_cmd[*]}"

# Run the `act` command
"${act_cmd[@]}"
