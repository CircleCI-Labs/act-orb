#!/bin/bash

# Get environment variables directly from the env command
echo "Fetching environment variables..."
IFS=$'\n'
ALL_ENV_VARS=($(env))

# Convert the comma-separated secrets parameter into an array
IFS=',' read -ra SECRETS \<<< "${ORB_VAL_SECRETS}"

# Create associative arrays for action and secret variables
declare -A ACTION_ENV_VARS
declare -A SECRET_ENV_VARS

# Process environment variables directly
for VAR in "${ALL_ENV_VARS[@]}"; do
    KEY=${VAR%%=*}
    VALUE=${VAR#*=}
    IS_SECRET=false
    
    for SECRET in "${SECRETS[@]}"; do
    if [[ $KEY == "$SECRET" ]]; then
        IS_SECRET=true
        break
    fi
    done

    if [[ $IS_SECRET == true ]]; then
    SECRET_ENV_VARS[$KEY]=$VALUE
    else
    ACTION_ENV_VARS[$KEY]=$VALUE
    fi
done

# Write ACTION_ENV_VARS to the .env file
echo "Writing non-sensitive environment variables to ${ORB_VAL_ENV_FILE}"
for KEY in "${!ACTION_ENV_VARS[@]}"; do
    echo "$KEY=${ACTION_ENV_VARS[$KEY]}" >> ${ORB_VAL_ENV_FILE}
done

# Write SECRET_ENV_VARS to the .secrets file
echo "Writing sensitive environment variables to ${ORB_VAL_SECRET_FILE}"
for KEY in "${!SECRET_ENV_VARS[@]}"; do
    echo "$KEY=${SECRET_ENV_VARS[$KEY]}" >> ${ORB_VAL_SECRET_FILE}
done
