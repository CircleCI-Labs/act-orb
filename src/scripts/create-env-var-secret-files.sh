#!/bin/bash

# Get environment variables directly from the env command
echo "Fetching environment variables..."
IFS=$'\n'
ALL_ENV_VARS=($(env))

# Convert the comma-separated secrets and variables parameters into arrays
IFS=',' read -ra SECRETS <<< "${ORB_VAL_SECRETS}"
IFS=',' read -ra VARIABLES <<< "${ORB_VAL_VARIABLES}"

# Create associative arrays for action, secret, and variable environment variables
declare -A ACTION_ENV_VARS
declare -A SECRET_ENV_VARS
declare -A VARIABLE_ENV_VARS

# Process environment variables directly
for VAR in "${ALL_ENV_VARS[@]}"; do
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
echo "Writing non-sensitive environment variables to ${ORB_VAL_ENV_FILE}"
for KEY in "${!ACTION_ENV_VARS[@]}"; do
    echo "$KEY=${ACTION_ENV_VARS[$KEY]}" >> "${ORB_VAL_ENV_FILE}"
done

# Write SECRET_ENV_VARS to the .secrets file
echo "Writing sensitive environment variables to ${ORB_VAL_SECRET_ENV_FILE}"
for KEY in "${!SECRET_ENV_VARS[@]}"; do
    echo "$KEY=${SECRET_ENV_VARS[$KEY]}" >> "${ORB_VAL_SECRET_ENV_FILE}"
done

# Write VARIABLE_ENV_VARS to the .vars file
echo "Writing non-sensitive variables to ${ORB_VAL_VAR_FILE}"
for KEY in "${!VARIABLE_ENV_VARS[@]}"; do
    echo "$KEY=${VARIABLE_ENV_VARS[$KEY]}" >> "${ORB_VAL_VAR_FILE}"
done
