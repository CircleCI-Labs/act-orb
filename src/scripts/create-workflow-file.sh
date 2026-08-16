#!/bin/bash
set -uo pipefail

# `action`/`uses` and `id` are aliases of each other (the family-consistent
# name added alongside the GitHub-native one); the explicit GitHub-native
# name wins if both happen to be set.
ACTION_REF="${ORB_VAL_ACTION}"
if [ -z "${ACTION_REF}" ]; then
    ACTION_REF="${ORB_VAL_ACTION_ID}"
fi

if [ -z "${ACTION_REF}" ]; then
    echo "Error: one of the 'action'/'uses' or 'id' parameters is required but neither was set."
    echo "If you are trying to pass in a workflow, please set skip-create-workflow-file to true to avoid this error."
    exit 1
fi

# Same alias pattern for `with`/`inputs`.
WITH_RAW="${ORB_VAL_WITH}"
if [ -z "${WITH_RAW}" ]; then
    WITH_RAW="${ORB_VAL_INPUTS}"
fi

# Capture 'with' and 'env' inputs directly
WITH_STRING=$(
    cat << EOF
${WITH_RAW}
EOF
)

ENV_STRING=$(
    cat << EOF
${ORB_VAL_ENV}
EOF
)

# Format 'with' parameter
if [ -n "$WITH_STRING" ]; then
    # shellcheck disable=SC2001
    formatted_with="$(echo "$WITH_STRING" | sed 's/^/          /')"
else
    formatted_with=""
fi

# Format 'env' parameter
if [ -n "$ENV_STRING" ]; then
    # shellcheck disable=SC2001
    formatted_env="$(echo "$ENV_STRING" | sed 's/^/          /')"
else
    formatted_env=""
fi

# Format 'services' parameter -- passed straight through under a job-level
# `services:` key with no translation, preserving whatever internal nesting
# the caller already wrote (service name -> image/env/ports).
SERVICES_STRING=$(
    cat << EOF
${ORB_VAL_SERVICES:-}
EOF
)
if [ -n "$SERVICES_STRING" ]; then
    # shellcheck disable=SC2001
    formatted_services="$(echo "$SERVICES_STRING" | sed 's/^/      /')"
else
    formatted_services=""
fi

# When outputs are requested, give the action step a stable id and append a
# second, same-job step that resolves each requested
# `${{ steps.<id>.outputs.<key> }}` expression and writes it to a handoff
# file `collect-outputs` reads back on the CircleCI host afterwards (see
# that command for why this, and not reading $GITHUB_OUTPUT directly, is
# the mechanism: $GITHUB_OUTPUT lives inside Act's own per-step temp area,
# which is not shared with the host even when --bind is on).
ACTION_STEP_ID="act-orb-main"
id_line=""
outputs_step=""
if [ -n "${ORB_VAL_OUTPUTS:-}" ]; then
    IFS=',' read -ra OUTPUT_KEYS <<< "${ORB_VAL_OUTPUTS}"

    env_lines=""
    body_lines=""
    idx=0
    for RAW_KEY in "${OUTPUT_KEYS[@]}"; do
        # trim surrounding whitespace so "a, b" behaves like "a,b"
        KEY="$(echo "${RAW_KEY}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "${KEY}" ] && continue
        idx=$((idx + 1))
        VAR_NAME="ACT_ORB_OUT_${idx}"
        env_lines+="          ${VAR_NAME}: \${{ steps.${ACTION_STEP_ID}.outputs.${KEY} }}"$'\n'
        body_lines+="            DELIM=\"act_orb_delim_${idx}_\$(date +%s%N)_\$\$\""$'\n'
        body_lines+="            {"$'\n'
        body_lines+="              printf '%s<<%s\\n' \"${KEY}\" \"\${DELIM}\""$'\n'
        body_lines+="              printf '%s\\n' \"\${${VAR_NAME}}\""$'\n'
        body_lines+="              printf '%s\\n' \"\${DELIM}\""$'\n'
        body_lines+="            } >> \"\${GITHUB_WORKSPACE}/${ORB_VAL_OUTPUTS_FILE}\""$'\n'
    done

    if [ "${idx}" -gt 0 ]; then
        id_line="        id: ${ACTION_STEP_ID}"
        outputs_step=$(
            cat << STEPEOF
      - name: Collect outputs for CircleCI (act-orb)
        if: always()
        shell: bash
        env:
${env_lines%$'\n'}
        run: |
          : > "\${GITHUB_WORKSPACE}/${ORB_VAL_OUTPUTS_FILE}"
${body_lines%$'\n'}
STEPEOF
        )
    fi
fi

# Generate the workflow YAML file. Built line-by-line (rather than a single
# heredoc with embedded $(if ...) substitutions) so that an unused optional
# section (services/id/outputs) contributes zero lines instead of a blank
# placeholder line -- keeping the common case (no services, no outputs)
# byte-identical to what this orb has always generated.
{
    echo "name: ${ORB_VAL_WORKFLOW_NAME}"
    echo "on: ${ORB_VAL_WORKFLOW_EVENT}"
    echo "jobs:"
    echo "  ${ORB_VAL_JOB_NAME}:"
    echo "    runs-on: ${ORB_VAL_RUNS_ON_IMAGE}"
    if [ -n "$formatted_services" ]; then
        echo "    services:"
        echo "$formatted_services"
    fi
    echo "    steps:"
    echo "      - uses: ${ACTION_REF}"
    if [ -n "$id_line" ]; then
        echo "$id_line"
    fi
    if [ -n "$formatted_with" ]; then
        echo "        with:"
        echo "$formatted_with"
    fi
    if [ -n "$formatted_env" ]; then
        echo "        env:"
        echo "$formatted_env"
    fi
    if [ -n "$outputs_step" ]; then
        echo "$outputs_step"
    fi
} > "${ORB_VAL_WORKFLOW_FILE}"

# Echo the workflow file for debugging. Deliberately NOT `echo -e` here: -e
# would re-interpret any literal backslash-escape sequences that are part of
# the generated file's own content (e.g. the `\n` inside the output-capture
# step's printf format strings, see above) as real escapes in this debug
# printout, making the logged copy look different from what was actually
# written to disk even though the file itself is correct.
echo "Generated workflow:"
cat "${ORB_VAL_WORKFLOW_FILE}"

echo
echo "Generated workflow YAML file at ${ORB_VAL_WORKFLOW_FILE}"
