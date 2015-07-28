#!/usr/bin/bash
# Functions and definitions to work with the different applications for
# the distribtuion.

source common.sh
source logging.sh
source genfuncs.sh

APP_OT=ot
APP_QPT=qpt
APP_SPDB=spdb
APP_PIT=pit
APP_P1PDF=p1pdfmaker

DIST_LINUX32=Linux32
DIST_LINUX64=Linux64
DIST_MACOS=MacOS
DIST_WINDOWS=Windows

eval "DISTNAME_OCS_${DIST_LINUX32}=linux32"
eval "DISTNAME_OCS_${DIST_LINUX64}=linux64"
eval "DISTNAME_OCS_${DIST_MACOS}=mac"
eval "DISTNAME_OCS_${DIST_WINDOWS}=windows"
eval "DISTNAME_PIT_${DIST_LINUX32}=linux"
eval "DISTNAME_PIT_${DIST_LINUX64}=linux"
eval "DISTNAME_PIT_${DIST_MACOS}=mac"
eval "DISTNAME_PIT_${DIST_WINDOWS}=windows"

# TODO: This could be cleaned up a bit!!!
# Use eval to sub in APPSET_OCS, etc.

APPSET_OCS=OCS
APPSET_PIT=PIT
APPSETS_ALL=(OCS PIT)

APPS_OCS=("$APP_OT" "$APP_QPT")
APPS_PIT=("$APP_PIT" "$APP_P1PDF")
APPS=(${APPS_OCS[@]} ${APPS_PIT[@]} ${APPS_P1PDF[@]} $APP_SPDB)

eval "DISTS_${APP_OT}=($DIST_LINUX32 $DIST_LINUX64 $DIST_MACOS $DIST_WINDOWS)"
eval "DISTS_${APP_QPT}=($DIST_LINUX64 $DIST_MACOS)"
eval "DISTS_${APP_SPDB}=($DIST_LINUX64)"
eval "DISTS_${APP_PIT}=($DIST_LINUX32 $DIST_LINUX64 $DIST_MACOS $DIST_WINDOWS)"
eval "DISTS_${APP_P1PDF}=($DIST_LINUX32 $DIST_LINUX64)"

SPDB_SERVERS=(gsodbtest gnodbtest)


# Build the app distributions for the specified app. Parameters are as follows:
# 1. The name of the app (one of APP_####)
# 2. The OCS_BASE_PATH.
# 3+ The list of distributions to build. Arrays or single distributions can be
#    specified. If no distributions are specified, use all defaults in DISTS_app.
function buildApp() {
    local APP="$1"
    if [[ -z "$APP" ]]; then
	logError "buildApp: no app specified."
	return 1
    fi
    contains "$APP" "${APPS[@]}"
    if [[ $? -ne 0 ]]; then
	logError "buildApp: not a valid app: $APP"
	return 1
    fi
    verbose "Building distributions for $APP."

    local OCS_BASE_PATH="$2"
    if [[ -z "$OCS_BASE_PATH" ]]; then
	logError "buildApp: no OCS base path specified."
	return 1
    fi
    local OLD_PATH="`pwd`"
    cd "$OCS_BASE_PATH"
    if [[ $? -ne 0 ]]; then
	logError "buildApp: could not cd to OCS base path: $OCS_BASE_PATH"
	exit 1
    fi

    local DISTS_ALL_VAR=DISTS_$APP[@]
    local DISTS=()

    if [[ $# -eq 2 ]]; then
	DISTS+=${!DISTS_ALL_VAR}
    else
	for arg in `seq 2 $#`; do
	    DISTS+=(${arg[@]})
	done
    fi
    verbose "Distributions specified: ${DISTS[@]}."

    for dist in ${DISTS[@]}; do
	contains "$dist" "${!DISTS_ALL_VAR}"
	if [[ $? -ne 0 ]]; then
	    logError "buildApp: not a valid distribution: $dist"
	    return 1
	fi
    done

    # Build the actual distributions with sbt.
    for dist in ${DISTS[@]}; do
	logInfo "Building $APP -> $dist"
	sbt --error "project app_$APP" "ocsDist $dist"
	if [[ $? -ne 0 ]]; then
	    logError "buildApp: could not build."
	    return 1
	fi
    done

    cd "$OLD_PATH"
    return 0
}


# Files available to distribute.
# Populated by the findDistFiles function below.
eval "declare -a DIST_FILES_${APP_OT}"
eval "declare -a DIST_FILES_${APP_QPT}"
eval "declare -a DIST_FILES_${APP_SPDB}"
eval "declare -a DIST_FILES_${APP_PIT}"
eval "declare -a DIST_FILES_${APP_P1PDF}"


# Populate the DIST_FILES_app array for a given app with available files for distribution.
# This function takes THREE parameters:
# 1. The app name (one of $APP_apps).
# 1. The OCS base path.
# 2. The version code (OCS or PIT as relevant).
function findDistFiles() {
    local APP="$1"
    if [[ -z "$APP" ]]; then
	logError "findDistFiles requires as first parameter the app name."
	return 1
    fi
    contains "$APP" "${APPS[@]}"
    if [[ $? -ne 0 ]]; then
	logError "findDistFiles received illegal app name: $APP_NAME"
	return 1
    fi

    local OCS_BASE_PATH="$2"
    if [[ -z "$OCS_BASE_PATH" ]]; then
	logError "No OCS base path specified."
	return 1
    fi

    local VERSION="$3"
    if [[ -z "$VERSION" ]]; then
	logError "findDistFiles requires as third parameter the version code."
	return 1;
    fi

    # Clear the array.
    eval "DIST_FILES_${APP_NAME}=()"

    # Separate processing for OCS/PIT apps and SPDB.
    if [[ "$APP" == "$APP_SPDB" ]]; then
	# We populate an array with one entry for each server in SPDB_SERVERS.
	# Ignore the dists since the only dists are Linux64.
	for server in ${SPDB_SERVERS[@]}; do
	    local CURR_DISTLOC="${OCS_BASE_PATH}/app/${APP_SPDB}/target/${APP_SPDB}/${VERSION}/${DIST_LINUX64}/${server}"
	    local CURR_DIST_FILES=(`find "${CURR_DISTLOC}"/*`)
	    if [[ ${#CURR_DIST_FILES[@]} -ne 1 ]]; then
		logError "findDistFiles could not find distribution file in: $CURR_DISTLOC"
		return 1
	    fi
	    eval "DIST_FILES_${APP_SPDB}+=($CURR_DIST_FILES)"
	done
    else
	# This is an OCS / PIT app. First, we must indulge in a bit of ugly hackery to
	# determine if there is a "-test" in the path to the distribution. For the OT
	# and QPT, there is if VERSION contains "-test", and for the PIT apps, no.
	# We also get the appset (OCS / PIT) for the app, as this determines the names
	# used for the various dists during the build.
	local TEST_STRING=
	contains "$APP" "${APPS_OCS[@]}"
	if [[ $? -eq 0 ]]; then
	    local CURR_APPSET=OCS
	    if [[ "$VERSION" == *"-test"* ]]; then
		TEST_STRING="-test"
	    fi
	else
	    local CURR_APPSET=PIT
	fi

	# Iterate over the distros for the given app and try to find them.
	local DISTS_VAR=DISTS_$APP[@]
	for dist in ${!DISTS_VAR}; do
	    local CURR_DISTNAME=DISTNAME_${CURR_APPSET}_$dist
	    local CURR_DISTLOC="${OCS_BASE_PATH}/app/${APP}/target/${APP}/${VERSION}/${dist}/${!CURR_DISTNAME}${TEST_STRING}"
	    local CURR_DIST_FILES=(`find "${CURR_DISTLOC}"/*`)
	    if [[ ${#CURR_DIST_FILES[@]} -ne 1 ]]; then
		logWarn "findDistFiles could not find distribution file in: $CURR_DISTLOC"
	    else
		eval "DIST_FILES_${APP}+=($CURR_DIST_FILES)"
	    fi
	done
    fi

    return 0
}
