#!/usr/bin/env bash
# Regenerates the embedded copies of is_true() in install.sh and run-act.sh
# from the single canonical source file, src/scripts/lib/is_true.sh. Two
# more embedded copies (cache-shim-start.sh, oidc-shim-start.sh) existed
# here until the cache/OIDC shims were split onto feature/translation-layer
# and the cache shim was removed outright -- see lib/is_true.sh's own
# comment for why this is a generate-and-embed step rather than a plain
# <<include(...)>> (a real orb-tools/pack constraint, reproduced on real
# CI).
#
# Usage: bash src/scripts/sync-embedded-is-true.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL="${HERE}/lib/is_true.sh"

if [ ! -f "${CANONICAL}" ]; then
    echo "sync-embedded-is-true: ERROR: canonical file not found: ${CANONICAL}" >&2
    exit 1
fi

MARKER_BEGIN='^# BEGIN GENERATED: is_true '
MARKER_END='^# END GENERATED: is_true$'

TARGETS=(
    "${HERE}/install.sh"
    "${HERE}/run-act.sh"
)

for target in "${TARGETS[@]}"; do
    if [ ! -f "${target}" ]; then
        echo "sync-embedded-is-true: ERROR: target script not found: ${target}" >&2
        exit 1
    fi
    if ! grep -qE "${MARKER_BEGIN}" "${target}" || ! grep -qE "${MARKER_END}" "${target}"; then
        echo "sync-embedded-is-true: ERROR: could not find the is_true markers in ${target}" >&2
        exit 1
    fi

    tmp="$(mktemp)"

    awk -v canonical="${CANONICAL}" -v begin_marker="${MARKER_BEGIN}" -v end_marker="${MARKER_END}" '
        BEGIN {
            while ((getline line < canonical) > 0) {
                body = body line "\n"
            }
            close(canonical)
        }
        $0 ~ begin_marker {
            print
            printf "%s", body
            in_block = 1
            next
        }
        $0 ~ end_marker {
            print
            in_block = 0
            next
        }
        in_block { next }
        { print }
    ' "${target}" > "${tmp}"

    mv "${tmp}" "${target}"
    chmod +x "${target}"
    echo "sync-embedded-is-true: regenerated is_true() in ${target}"
done
