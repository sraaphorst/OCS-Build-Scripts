#!/bin/bash
# Logging functionality.

# Color definitions.
COLOR_NONE='\033[0m'
COLOR_BLACK='\033[0;310m'
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_ORANGE='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_PURPLE='\033[0;35m'
COLOR_CYAN='\033[0;36m'
COLOR_LIGHTGRAY='\033[0;37m'
COLOR_DARKGRAY='\033[1;30m'
COLOR_LIGHTRED='\033[1;31m'
COLOR_LIGHTGREEN='\033[1;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_LIGHTBLUE='\033[1;34m'
COLOR_LIGHTPURPLE='\033[1;35m'
COLOR_LIGHTCYAN='\033[1;36m'
COLOR_WHITE='\033[1;37m'

# Colors for output.
COLOR_HEADER=$COLOR_CYAN
COLOR_WARN=$COLOR_YELLOW
COLOR_ERROR=$COLOR_RED
COLOR_INFO=$COLOR_NONE
COLOR_VINFO=$COLOR_NONE

# Turn on coloring by default. Can be shut off by unsetting USE_COLOR or setting it to
# something other than TRUE.
if [[ -z "$USE_COLOR" ]]; then
    USE_COLOR=TRUE
fi

# Using a color specified by second param, write the first param as a message in that
# color if USE_COLOR is TRUE, and otherwise, simply write it without color.
function colorPrint() {
    if [[ "$USE_COLOR" == "TRUE" ]]; then
	printf "$2"
    fi
    printf "$1"
    if [[ "$USE_COLOR" == "TRUE" ]]; then
	printf "$COLOR_NONE"
    fi
    return 0
}

# Header logging: if a second param is given, no leading newline.
function logHeader() {
    if [[ -z "$2" ]]; then
	printf "\n"
    fi
    colorPrint "[ $1 ]\n" "$COLOR_HEADER"
    return 0
}

# Internal function for printing out log categories.
function logCat() {
    printf "["
    colorPrint "$1" "$2"
    printf "]"
    return 0
}

function logInfo() {
    logCat "info" "$COLOR_INFO"
    echo "  $@"
    return 0
}

function logWarn() {
    logCat "warn" "$COLOR_WARN"
    echo "  $@"
    return 0
}

function logError() {
    logCat "error" "$COLOR_ERROR"
    echo " $@"
    return 0
}

# If the variable VERBOSE is set to TRUE, then output a message; otherwise do nothing.
function verbose() {
    if [[ "$VERBOSE" == "TRUE" ]]; then
	logCat "vinfo" "$COLOR_VINFO"
	echo " $@"
    fi
    return 0
}

# Run one of two commands depending on whether verbosity is selected.
# IF VERBOSE is set to TRUE, execute the first command; otherwise, execute the second.
function execVerbose() {
    if [[ "$VERBOSE" == "TRUE" ]]; then
	eval "$1"
    else
	eval "$2"
    fi
    return $?
}
