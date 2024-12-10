#!/bin/bash

# Set the bin-dir and debug flags based on the parameters
BIN_DIR_FLAG=""
DEBUG_FLAG=""

# Check if a custom bin directory is set
if [[ "${ORB_VAL_BIN_DIR}" != "./bin" ]]; then
    BIN_DIR_FLAG="-b ${ORB_VAL_BIN_DIR}"
fi

# Enable debug logging if the debug parameter is true
if [[ "${ORB_VAL_DEBUG}g >>" == "true" ]]; then
    DEBUG_FLAG="-d"
fi

# Install Act with the specified version, bin-dir, and debug options
curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash -s -- $BIN_DIR_FLAG $DEBUG_FLAG ${ORB_VAL_VERSION}
