#!/bin/bash

# Set the bin-dir and debug flags based on the parameters
BIN_DIR_FLAG=""
DEBUG_FLAG=""
FORCE_INSTALL_FLAG=""

# Add bin-dir flag if a custom directory is provided
if [[ -n "${ORB_VAL_BIN_DIR}" && "${ORB_VAL_BIN_DIR}" != "./bin" ]]; then
    BIN_DIR_FLAG="-b ${ORB_VAL_BIN_DIR}"
fi

# Enable debug logging if the debug parameter is true
if [[ "${ORB_VAL_DEBUG}" == "true" ]]; then
    DEBUG_FLAG="-d"
fi

# Enable force install if the debug parameter is true
if [[ "${ORB_VAL_FORCE_INSTALL}" == "true" ]]; then
    FORCE_INSTALL_FLAG="-f"
fi

# Install Act with the correct options
INSTALL_CMD="curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/james-crowley/act/refs/heads/master/install.sh | sudo bash -s --"

# Construct the full command with all flags
FULL_CMD="$INSTALL_CMD ${BIN_DIR_FLAG} ${DEBUG_FLAG} ${FORCE_INSTALL_FLAG} ${ORB_VAL_VERSION}"

# Echo command for debugging
echo "Running: $FULL_CMD"

# Execute the command
eval "$FULL_CMD"
