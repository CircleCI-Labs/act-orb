#!/usr/bin/env bash
# Regenerates the heredoc-embedded copy of the cache-shim server in
# cache-shim-start.sh from the single canonical source file,
# cache_shim_server.py. Mirrors act/oidc-shim's own
# sync-embedded-server.sh -- see that file's comments for the full
# rationale (one script file per orb command, no "second file" reachable at
# job runtime, so the canonical .py file has to be physically embedded).
#
# Usage: bash src/scripts/sync-embedded-cache-server.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL="${HERE}/cache_shim_server.py"
START_SCRIPT="${HERE}/cache-shim-start.sh"

if [ ! -f "${CANONICAL}" ]; then
    echo "sync-embedded-cache-server: ERROR: canonical file not found: ${CANONICAL}" >&2
    exit 1
fi
if [ ! -f "${START_SCRIPT}" ]; then
    echo "sync-embedded-cache-server: ERROR: start script not found: ${START_SCRIPT}" >&2
    exit 1
fi

MARKER_BEGIN='^cat > "\$\{SERVER_PY\}" <<[ ]*.CACHE_SHIM_SERVER_PY_EOF.$'
MARKER_END='^CACHE_SHIM_SERVER_PY_EOF$'

if ! grep -qE "${MARKER_BEGIN}" "${START_SCRIPT}" || ! grep -qE "${MARKER_END}" "${START_SCRIPT}"; then
    echo "sync-embedded-cache-server: ERROR: could not find the heredoc markers in ${START_SCRIPT} -- has the launch mechanism changed?" >&2
    exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT

awk -v canonical="${CANONICAL}" '
    BEGIN {
        while ((getline line < canonical) > 0) {
            body = body line "\n"
        }
        close(canonical)
    }
    /^cat > "\$\{SERVER_PY\}" <<[ ]*.CACHE_SHIM_SERVER_PY_EOF.$/ {
        print
        printf "%s", body
        in_block = 1
        next
    }
    /^CACHE_SHIM_SERVER_PY_EOF$/ {
        print
        in_block = 0
        next
    }
    in_block { next }
    { print }
' "${START_SCRIPT}" > "${TMP}"

mv "${TMP}" "${START_SCRIPT}"
chmod +x "${START_SCRIPT}"
echo "sync-embedded-cache-server: embedded copy in ${START_SCRIPT} regenerated from ${CANONICAL}"
