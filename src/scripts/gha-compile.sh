#!/bin/bash
set -euo pipefail

GHAC_BIN="${ORB_VAL_BIN_DIR%/}/ghac"

if [[ ! -x "${GHAC_BIN}" ]]; then
    echo "Error: ghac not found at ${GHAC_BIN}. This command must run after install-ghac (gha-compile/gha-render-job both do this automatically)." >&2
    exit 1
fi

if [[ ! -f "${ORB_VAL_WORKFLOW_FILE}" ]]; then
    echo "Error: GitHub workflow file not found at path '${ORB_VAL_WORKFLOW_FILE}'." >&2
    exit 1
fi

mkdir -p "$(dirname "${ORB_VAL_OUT}")"

echo "Compiling ${ORB_VAL_WORKFLOW_FILE} -> ${ORB_VAL_OUT}"
# ghac's own stderr already distinguishes a supported-but-broken input from
# an unsupported-construct rejection (the latter prefixed "UNSUPPORTED:" and
# naming the exact construct -- see tools/ghac/README.md and the main
# README's limits table). Nothing here needs to interpret that further;
# just let it surface and fail the step.
"${GHAC_BIN}" compile \
    --in "${ORB_VAL_WORKFLOW_FILE}" \
    --source-path "${ORB_VAL_WORKFLOW_FILE}" \
    --out "${ORB_VAL_OUT}" \
    --self-hosted-namespace "${ORB_VAL_SELF_HOSTED_NAMESPACE}"

echo "Generated CircleCI config at ${ORB_VAL_OUT}:"
cat "${ORB_VAL_OUT}"
