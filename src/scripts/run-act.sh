#!/bin/bash
set -uo pipefail

# Bash-safe truthiness for orb boolean parameters -- see install.sh for why
# both "1" and "true" are accepted rather than assuming one encoding.
is_true() {
    case "${1:-}" in
        1 | true | TRUE | True) return 0 ;;
        *) return 1 ;;
    esac
}

if [ ! -f "${ORB_VAL_WORKFLOW_FILE}" ]; then
    echo "Error: Workflow file not found at path '${ORB_VAL_WORKFLOW_FILE}'."
    exit 1
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
