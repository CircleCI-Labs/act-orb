#!/bin/bash

# Build the base `act` command
act_cmd="act"

if [ ! -f "${ORB_VAL_WORKFLOW_FILE}" ]; then
    echo "Error: Workflow file not found at path '${ORB_VAL_WORKFLOW_FILE}'."
    exit 1
else
    act_cmd="$act_cmd --workflows ${ORB_VAL_WORKFLOW_FILE}"
fi

if [ ! -f "${ORB_VAL_ENV_FILE}" ]; then
    echo "Warning: Env file not found at ${ORB_VAL_ENV_FILE}. Skipping..."
else
    act_cmd="$act_cmd --env-file ${ORB_VAL_ENV_FILE}"
fi

if [ ! -f "${ORB_VAL_SECRET_FILE}" ]; then
    echo "Warning: Secret file not found at ${ORB_VAL_SECRET_FILE}. Skipping..."
else
    act_cmd="$act_cmd --secret-file ${ORB_VAL_SECRET_FILE}"
fi

if [ ! -f "${ORB_VAL_INPUT_FILE}" ]; then
    echo "Warning: Input file not found at ${ORB_VAL_INPUT_FILE}. Skipping..."
else
    act_cmd="$act_cmd --input-file ${ORB_VAL_INPUT_FILE}"
fi

if [ ! -f "${ORB_VAL_VAR_FILE}" ]; then
    echo "Warning: Var file not found at ${ORB_VAL_VAR_FILE}. Skipping..."
else
    act_cmd="$act_cmd --var-file ${ORB_VAL_VAR_FILE}"
fi

if [ ! -f "${ORB_VAL_EVENT_FILE}" ]; then
    echo "Warning: Event file not found at ${ORB_VAL_EVENT_FILE}. Skipping..."
else
    act_cmd="$act_cmd --eventpath ${ORB_VAL_EVENT_FILE}"
fi

# Add parameters with valid defaults
act_cmd="$act_cmd --platform ${ORB_VAL_PLATFORM}"
act_cmd="$act_cmd --directory ${ORB_VAL_DIRECTORY}"
act_cmd="$act_cmd --defaultbranch ${ORB_VAL_DEFAULT_BRANCH}"
act_cmd="$act_cmd --remote-name ${ORB_VAL_REMOTE_NAME}"
act_cmd="$act_cmd --actor ${ORB_VAL_ACTOR}"

# Check for job 
if [ -n "${ORB_VAL_JOB}" ]; then
    act_cmd="$act_cmd --job ${ORB_VAL_JOB}"
fi

# Check boolean flags
if [ "${ORB_VAL_PULL}" = "0" ]; then
    act_cmd="$act_cmd --pull=false"
fi
if [ "${ORB_VAL_REBUILD}" = "0" ]; then
    act_cmd="$act_cmd --rebuild=false"
fi
if [ "${ORB_VAL_REUSE}" = "1" ]; then
    act_cmd="$act_cmd --reuse"
fi
if [ "${ORB_VAL_DETECT_EVENT}" = "1" ]; then
    act_cmd="$act_cmd --detect-event"
fi
if [ "${ORB_VAL_BIND}" = "1" ]; then
    act_cmd="$act_cmd --bind"
fi
if [ "${ORB_VAL_VERBOSE}" = "1" ]; then
    act_cmd="$act_cmd --verbose"
fi
if [ "${ORB_VAL_ACTION_OFFLINE_MODE}" = "1" ]; then
    act_cmd="$act_cmd --action-offline-mode"
fi

# Include additional flags if provided
if [ -n "${ORB_VAL_ADDITIONAL_ACT_FLAGS}" ]; then
    act_cmd="$act_cmd ${ORB_VAL_ADDITIONAL_ACT_FLAGS}"
fi

# Echo the final command for debugging
echo "Running command: $act_cmd"

# Run the `act` command
eval "$act_cmd"
