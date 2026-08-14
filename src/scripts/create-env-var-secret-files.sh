#!/bin/bash
set -uo pipefail

# Security note: enumerate the environment with `env -0` (NUL-delimited
# records) rather than `env` + newline-splitting. A CircleCI env var whose
# *value* itself spans multiple lines (SSH private keys, JSON service
# account credentials, etc.) has no `=` on its continuation lines; splitting
# on newlines turned each continuation line into its own spurious
# no-`=`-sign "entry", which fell through to the default *non-secret*
# bucket below -- meaning fragments of a multi-line secret could land in
# the plaintext .env file even when the secret's own name was correctly on
# the `secrets` allow-list. NUL cannot appear inside an environment
# variable's value, so `env -0` gives exactly one record per variable
# regardless of embedded newlines, closing that leak.
echo "Fetching environment variables..."
readarray -d '' -t ALL_ENV_VARS < <(env -0)

# Convert the comma-separated secrets and variables parameters into arrays
IFS=',' read -ra SECRETS <<< "${ORB_VAL_SECRETS}"
IFS=',' read -ra VARIABLES <<< "${ORB_VAL_VARIABLES}"

# Create associative arrays for action, secret, and variable environment variables
declare -A ACTION_ENV_VARS
declare -A SECRET_ENV_VARS
declare -A VARIABLE_ENV_VARS

# Process environment variables directly
for VAR in "${ALL_ENV_VARS[@]}"; do
    [ -z "${VAR}" ] && continue
    KEY=${VAR%%=*}
    VALUE=${VAR#*=}

    # Check if the key is a secret
    IS_SECRET=false
    for SECRET in "${SECRETS[@]}"; do
        if [[ $KEY == "$SECRET" ]]; then
            IS_SECRET=true
            break
        fi
    done

    # Check if the key is a variable
    IS_VARIABLE=false
    for VARIABLE in "${VARIABLES[@]}"; do
        if [[ $KEY == "$VARIABLE" ]]; then
            IS_VARIABLE=true
            break
        fi
    done

    if [[ $IS_SECRET == true ]]; then
        SECRET_ENV_VARS[$KEY]=$VALUE
    elif [[ $IS_VARIABLE == true ]]; then
        VARIABLE_ENV_VARS[$KEY]=$VALUE
    else
        ACTION_ENV_VARS[$KEY]=$VALUE
    fi
done

# Write ACTION_ENV_VARS to the .env file
#
# NOTE on the model here (documented in the README too): every variable NOT
# named in `secrets`/`variables` lands in this plaintext file by default --
# an opt-in, not opt-out, secrecy posture. `env -0` above stops a
# multi-line secret's continuation lines from leaking here even when the
# secret's own name IS on the allow-list; it does not change the fact that
# anything you don't explicitly name is treated as safe to write in
# plaintext. A value containing an embedded newline is still written to
# these files unquoted -- Act's own dotenv-style parser may not round-trip
# such a value correctly; avoid multi-line secrets/vars/env values, or
# pre-encode them (e.g. base64) if you must use one.
echo "Writing non-sensitive environment variables to ${ORB_VAL_ENV_FILE}"
for KEY in "${!ACTION_ENV_VARS[@]}"; do
    echo "$KEY=${ACTION_ENV_VARS[$KEY]}" >> "${ORB_VAL_ENV_FILE}"
done

# Write SECRET_ENV_VARS to the .secrets file
echo "Writing sensitive environment variables to ${ORB_VAL_SECRET_FILE}"
for KEY in "${!SECRET_ENV_VARS[@]}"; do
    echo "$KEY=${SECRET_ENV_VARS[$KEY]}" >> "${ORB_VAL_SECRET_FILE}"
done

# Write VARIABLE_ENV_VARS to the .vars file
echo "Writing non-sensitive variables to ${ORB_VAL_VAR_FILE}"
for KEY in "${!VARIABLE_ENV_VARS[@]}"; do
    echo "$KEY=${VARIABLE_ENV_VARS[$KEY]}" >> "${ORB_VAL_VAR_FILE}"
done
