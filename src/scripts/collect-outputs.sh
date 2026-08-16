#!/bin/bash
set -uo pipefail

OUTPUTS_PATH="${ORB_VAL_DIRECTORY%/}/${ORB_VAL_OUTPUTS_FILE}"

if [ ! -f "${OUTPUTS_PATH}" ]; then
    echo "No output handoff file found at ${OUTPUTS_PATH} -- nothing to collect. (Requested: ${ORB_VAL_OUTPUTS:-none})"
    exit 0
fi

echo "Collecting outputs from ${OUTPUTS_PATH} (requested: ${ORB_VAL_OUTPUTS:-none})"

# The handoff file uses the same key<<delimiter / value-lines / delimiter
# framing @actions/core's setOutput() uses for $GITHUB_OUTPUT itself (see
# packages/core/src/file-command.ts) -- reused here deliberately, since it
# is the vendor's own answer to safely carrying a value that may contain
# `=`, quotes, or embedded newlines through a plain text file.
COLLECTED=0
KEY=""
DELIM=""
VALUE=""
IN_VALUE=0

flush() {
    if [ -z "${KEY}" ]; then
        return
    fi

    # $BASH_ENV is sourced by later steps' shells, so the exported name
    # must be a legal bash identifier. GitHub output ids may contain
    # characters (e.g. "-") that bash identifiers cannot, so we sanitize
    # only when the verbatim key isn't already a valid identifier, and say
    # so loudly rather than silently renaming it.
    if [[ "${KEY}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        EXPORT_NAME="${KEY}"
    else
        EXPORT_NAME="$(printf '%s' "${KEY}" | tr -c 'A-Za-z0-9_' '_')"
        if [[ ! "${EXPORT_NAME}" =~ ^[A-Za-z_] ]]; then
            EXPORT_NAME="_${EXPORT_NAME}"
        fi
        echo "Warning: output key '${KEY}' is not a valid shell variable name; exporting as '${EXPORT_NAME}' instead. The action's own output name is unchanged -- only the CircleCI-side variable name differs." >&2
    fi

    # printf %q renders VALUE as a shell-safe quoted literal (handles
    # embedded newlines, quotes, `$`, backticks, etc.) so sourcing
    # $BASH_ENV later reconstructs the value exactly, not a re-interpreted
    # version of it.
    {
        printf 'export %s=%q\n' "${EXPORT_NAME}" "${VALUE}"
    } >> "${BASH_ENV}"

    echo "  exported ${EXPORT_NAME} (from action output '${KEY}')"
    COLLECTED=$((COLLECTED + 1))
    KEY=""
    DELIM=""
    VALUE=""
}

while IFS= read -r LINE || [ -n "${LINE}" ]; do
    if [ "${IN_VALUE}" -eq 1 ]; then
        if [ "${LINE}" = "${DELIM}" ]; then
            # Strip exactly the one trailing newline that was added when
            # accumulating VALUE below (join semantics, not a truncation).
            VALUE="${VALUE%$'\n'}"
            flush
            IN_VALUE=0
        else
            VALUE+="${LINE}"$'\n'
        fi
        continue
    fi

    if [[ "${LINE}" == *"<<"* ]]; then
        KEY="${LINE%%<<*}"
        DELIM="${LINE#*<<}"
        VALUE=""
        IN_VALUE=1
    fi
done < "${OUTPUTS_PATH}"

if [ "${COLLECTED}" -eq 0 ]; then
    echo "Output handoff file was present but contained no recognizable key/value blocks."
else
    echo "Collected ${COLLECTED} output(s) into \$BASH_ENV."
fi
