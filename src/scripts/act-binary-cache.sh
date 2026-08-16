#!/bin/bash
set -uo pipefail

ACT_VERSION_FILE="/tmp/.act-version"

if [[ "${ORB_VAL_VERSION}" == "latest" ]]; then
    echo "Fetching the latest Act version from GitHub..."
    if ACT_LATEST_VERSION=$(curl --silent --fail --retry 6 --retry-all-errors \
        https://api.github.com/repos/nektos/act/releases/latest | jq -r '.tag_name'); then
        echo "$ACT_LATEST_VERSION" > "$ACT_VERSION_FILE"
    else
        # Don't hard-fail the job over a transient GitHub API hiccup: the
        # actual installed version is still resolved by Act's own installer
        # (which independently talks to the same "latest" endpoint) -- this
        # file only feeds a cache-key checksum, so fall back to a fixed
        # literal rather than leaving the file missing (a missing file would
        # make the downstream `checksum` cache-key function error out and
        # fail the whole job).
        echo "Warning: failed to fetch the latest Act version from GitHub. Using a fixed cache-key literal; this will just mean fewer cache hits until GitHub's API is reachable again." >&2
        echo "latest-unresolved" > "$ACT_VERSION_FILE"
    fi
else
    echo "${ORB_VAL_VERSION}" > "$ACT_VERSION_FILE"
fi

echo "Stored Act version: $(cat "$ACT_VERSION_FILE")"
