#!/bin/bash

ACT_VERSION_FILE="/tmp/.act-version"

if [[ "${ORB_VAL_VERSION}" == "latest" ]]; then
    echo "Fetching the latest Act version from GitHub..."
    ACT_LATEST_VERSION=$(curl --silent --fail --retry 6 --retry-all-errors \
        https://api.github.com/repos/nektos/act/releases/latest | jq -r '.tag_name') || {
        echo "Failed to fetch the latest version. Continuing anyways."
        return
    }
    echo "$ACT_LATEST_VERSION" > "$ACT_VERSION_FILE"
else
    echo "${ORB_VAL_VERSION}" > "$ACT_VERSION_FILE"
fi

echo "Stored Act version: $(cat "$ACT_VERSION_FILE")"
