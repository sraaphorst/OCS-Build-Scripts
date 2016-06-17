##!/usr/bin/bash
# Functions that facilitate continuing the build process if it aborts early due to error.
# We use exit for errors here instead of return, as this is tightly linked to the main
# scripts and we don't want the main scripts to have to check error codes for each
# function call.

BASE_DIR=`dirname $0`
source $BASE_DIR/common.sh
source $BASE_DIR/logging.sh

# ***********************************
# ***** Config checks and setup *****
# ***********************************
function configSetup() {
    # Make sure the VARIABLES or ARRAYS exist.
    # If they don't, there isn't really anything we can do.
    if [[ -z "$VARIABLES" && -z "$ARRAYS" ]]; then
	echo "Error in `basename $0`: VARIABLES and / or ARRAYS must be set."
	exit 1
    fi

    # Figure out the configuration file that records what step in the build was the last one executedo visit a
    # and the build settings.
    CONFIG_FILE=`eval "echo $0.cfg"`

    # Initialize the step. If it exists, it will be set appropriately by configInterruptedHandler.
    STEP=0

    return 0
}

# *********************************************
# ***** Config cleanup if script succeeds *****
# *********************************************
function configCleanup() {
    deleteConfig
    return 0
}

# *******************************************
# ***** Check if the config file exists *****
# *******************************************
# Evaluates to a boolean expression that can be used as:
# if configExists; then ...; else ...; fi
function configExists() {
    if [[ -f "$CONFIG_FILE" ]]; then
	return 0
    else
	return 1
    fi
}

# ***************************************************
# ***** Determine if a step should be performed *****
# ***************************************************
# Evaluates to a boolean expression whether or not a step should be
# performed. STEP should indicate the last step successfully performed
# (with 0 indicating no steps have been performed) and the parameter
# indicates the current step number.
function shouldPerformStep() {
    if [[ -z "$1" ]]; then
	logError "shouldPerformStep requires the number of the current step."
	exit 1
    fi

    # We perform the current step if it hasn't already been done.
    if [[ "$STEP" -lt "$1" ]]; then
	return 0
    else
	return 1
    fi
}

# **************************
# ***** Perform a step *****
# **************************
# Given a step number, checks to see if that step needs to be performed, and
# if so, performs the function given as the second parameter with all pending arguments.
# Then set STEP to indicate that the step was performed and rewrite the config file.
function performStep() {
    if [[ -z "$1" ]]; then
	logError "performStep requires a step number for the first parameter."
	exit 1
    fi
    if [[ -z "$2" ]]; then
	logError "performStep requires a function for the second parameter."
	exit 1
    fi

    if (shouldPerformStep $1); then
	local ARGS=("$@")
	eval "$2" "${ARGS[@]:2}"
	if [[ $? -ne 0 ]]; then
	    logError "Error in step $STEP."
	    exit 1
	fi

	STEP=$1
	writeConfig
    fi
    return 0
}

# ***************************************
# ***** Interrupted script handling *****
# ***************************************
# This assumes that $CONFIG_FILE exists and demands the user continue or abort,
# setting up the configuration variables necessary to pick up where we left off.
# Parameter is $1, the first parameter to the script.
function configInterruptedHandler() {
    if [[ "$1" == "--continue" ]]; then
	readConfig
    elif [[ "$1" == "--abort" ]]; then
	deleteConfig
	echo "`basename $0` terminated. Manual cleanup may be necessary."
	exit 0
    else
	echo "`basename $0` terminated before completing."
	echo "Please either specify --abort or --continue to proceed."
	exit 1
    fi
    return 0
}

# ********************************
# ***** Read the config file *****
# ********************************
# Assumes that the config file exists.
function readConfig() {
    source "$CONFIG_FILE"
    if [[ $? -ne 0 ]]; then
	logError "Could not ready $CONFIG_FILE."
	exit 1
    fi
    return 0
}

# *********************************
# ***** Write the config file *****
# *********************************
function writeConfig() {
    echo STEP="$STEP" > "$CONFIG_FILE"

    local VARIABLE_NAME
    for VARIABLE_NAME in ${VARIABLES[@]}; do
	writeConfigVariable "$VARIABLE_NAME"
    done

    local ARRAY_NAME
    for ARRAY_NAME in ${ARRAYS[@]}; do
	writeConfigArray "$ARRAY_NAME"
    done
    return 0
}

# Write a line:
# VARIABLE_NAME=VALUE
# to the config file, where VARIABLE_NAME is the parameter.
function writeConfigVariable() {
    if [[ -n "${!1}" ]]; then
	echo "$1"="${!1}" >> "$CONFIG_FILE"
    fi
    return 0
}

# Write a line:
# ARRAY_NAME=(value1 value2 ...)
# to the config file, where ARRAY_NAME is the parameter.
function writeConfigArray() {
    if [[ -n "${!1}" ]]; then
	local ARRAYNAME=$1
	eval local ARRAY=\( \${${ARRAYNAME}[@]} \)
	echo "$ARRAYNAME"="(${ARRAY[@]})" >> "$CONFIG_FILE"
    fi
    return 0
}

# **********************************
# ***** Delete the config file *****
# **********************************
function deleteConfig() {
    rm -f "$CONFIG_FILE"
    return 0
}
