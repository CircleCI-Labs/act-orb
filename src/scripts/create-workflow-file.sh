#!/bin/bash

# Check if the 'action' parameter is set
if [ -z "${ORB_VAL_ACTION}" ]; then
    echo "Error: The 'action' or 'uses' parameter is required but not set."
    echo "If you are trying to pass in a workflow, please set skip-create-workflow-file to true to avoid this error."
    exit 1
fi

# Capture 'with' and 'env' inputs directly
WITH_STRING=$(cat \<<EOF
${ORB_VAL_WITH}
EOF
)

ENV_STRING=$(cat \<<EOF
${ORB_VAL_ENV}
EOF
)

# Format 'with' parameter
if [ -n "$WITH_STRING" ]; then
    formatted_with="$(echo "$WITH_STRING" | sed 's/^/          /')"
else
    formatted_with=""
fi

# Format 'env' parameter
if [ -n "$ENV_STRING" ]; then
    formatted_env="$(echo "$ENV_STRING" | sed 's/^/          /')"
else
    formatted_env=""
fi

# Generate the workflow YAML file
cat \<<EOF > ${ORB_VAL_WORKFLOW_FILE}
name: ${ORB_VAL_WORKFLOW_NAME}
on: ${ORB_VAL_WORKFLOW_EVENT}
jobs:
    ${ORB_VAL_JOB_NAME}:
    runs-on: ${ORB_VAL_RUNS_ON_IMAGE}
    steps:
        - uses: ${ORB_VAL_ACTION}
$(if [ -n "$formatted_with" ]; then echo "        with:"; echo "$formatted_with"; fi)
$(if [ -n "$formatted_env" ]; then echo "        env:"; echo "$formatted_env"; fi)
EOF

# Echo the workflow file for debugging
echo "Generated workflow: $(cat ${ORB_VAL_WORKFLOW_FILE})"

echo "Generated workflow YAML file at ${ORB_VAL_WORKFLOW_FILE}"
