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

if [[ -z "${ORB_VAL_JOB}" ]]; then
    echo "Error: the 'job' parameter is required for gha-render-job." >&2
    exit 1
fi

mkdir -p "$(dirname "${ORB_VAL_OUT}")"

echo "Rendering job '${ORB_VAL_JOB}' from ${ORB_VAL_WORKFLOW_FILE} -> ${ORB_VAL_OUT}"
# Re-derives this one job's single-job, needs:-stripped,
# needs.*.outputs.*-rewritten workflow file. Deliberately re-run per compiled
# job rather than generated once in the setup job and shared: a setup:true
# workflow does not share a workspace with the pipeline it continues into
# (see the main README's "setup-workflow wiring" section), so every job
# re-derives its own file at runtime from the same checked-out
# .github/workflows source instead.
"${GHAC_BIN}" render-job \
    --in "${ORB_VAL_WORKFLOW_FILE}" \
    --source-path "${ORB_VAL_WORKFLOW_FILE}" \
    --job "${ORB_VAL_JOB}" \
    --out "${ORB_VAL_OUT}"

echo "Rendered single-job workflow file at ${ORB_VAL_OUT}:"
cat "${ORB_VAL_OUT}"
