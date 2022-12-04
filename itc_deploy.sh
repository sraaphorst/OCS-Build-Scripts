#!/bin/bash

BASE_DIR=`dirname $0`
source $BASE_DIR/appfuncs.sh
source $BASE_DIR/common.sh
source $BASE_DIR/genfuncs.sh
source $BASE_DIR/logging.sh
source $BASE_DIR/verfuncs.sh
source $BASE_DIR/continuefuncs.sh

# Variables and arrays used by this script, as declared in common.sh.
VARIABLES=(SERVER VERBOSE DIRTY DIRTY_DISTROS VERSION_OCS_STRING)
ARRAYS+=(DIST_FILES_itc)


# *************************************************
# ***** Check for and handle continue / abort *****
# *************************************************
# Note that if the script was aborted and the user opts to continue, this
# loads up the configuration that was used in the original call to this script
# so we can begin precisely where we left off.
configSetup


# ******************************************
# ***** Handle command line parameters *****
# ******************************************
# Check to see if the script is fresh (i.e. did not terminate prematurely)
# and if so, configure via the specified command line parameters.

function showHelp() {
    echo "usage: odb_deploy.sh [-h] [-v] [-d] [-b] [-o str] [server]"
    echo "   -h:     display help"
    echo "   -v:     verbose output"
    echo "   -d:     dirty (no sbt clean)"
    echo "   -b:     dirty distros (use existing distros)"
    echo "             WARNING: may cause issues; predominantly to speed up testing"
    echo "   -o str: OCS version string (e.g. 2015B-test.1.1.1)"
    echo "   server: the server on which to install the ITC (default: sbfitcdev-lv1)"
}

if configExists; then
    # Handle the continue / abort process.
    configInterruptedHandler "$@"
else
    # Fresh start: configure from the command line.
    # Handle command line arguments.
    while :
    do
	case $1 in
	    -h) showHelp
		exit 1
		;;
            -v) VERBOSE=TRUE
		shift 
		;;
	    -d) DIRTY=TRUE
		shift
		;;
	    -b) DIRTY_DISTROS=TRUE
		shift
		;;
	    -o) shift
		VERSION_OCS_STRING=$1
		shift
		;;
            --) shift
		break
		;;
            -*) showHelp
		exit 1
		;;
	    *) break
               ;;
	esac
    done

    # The rest is the server.
    SERVER=sbfitcdev-lv1
    if [[ $# -ne 0 ]]; then
	SERVER=$1
	shift
    fi

    # There should be no more command line arguments at this point.
    if [ $# -ne 0 ]; then
	showHelp
	exit 1
    fi

    # The process has started, so write the config file.
    writeConfig
fi


# *******************
# ***** SSH IDS *****
# *******************
sshIds


# ************************
# ***** JAVA VERSION *****
# ************************
javaVersion


# ******************************
# ***** 1: OCS SOURCE CODE *****
# ******************************
performStep 1 ocsSourceCodeSetup


# ************************
# ***** 2: JRE SETUP *****
# ************************
performStep 2 jreSbtSetup


# *************************
# ***** VERSION SETUP *****
# *************************
# Always do this as it is simply a function of the configuration.
function versionSetup() {
    logHeader "Processing versioning."
    local BUILD_FILE_SRC="$OCS_BASE_PATH"/build.sbt
    local BUILD_FILE_DST="$OCS_BASE_PATH"/build_tmp.sbt

    # Process the app versions.
    appVersionSetup "${APPSET_OCS}" "$OCS_BASE_PATH" "${VERSION_OCS_STRING}"

    logInfo "Processing versioning complete."
    return 0
}
versionSetup


# ******************************
# ***** 3: OCS-CREDENTIALS *****
# ******************************
performStep 3 ocsCredentialsSourceCodeSetup


# ***********************************************
# ***** 4-5: SBT PREPARATIONS AND EXECUTION *****
# ***********************************************
performStep 4 sbtCompile "$DIRTY"

function buildItc() {
    logInfo "Creating ITC distribution."

    # If dirty distros is not defined, then build.
    if [[ -z "$DIRTY_DISTROS" ]]; then
	# Build the app.
	buildApp "$APP_ITC" "$OCS_BASE_PATH"
	if [[ $? -ne 0 ]]; then
	    logError "Could not run buildApp."
	    return 1
	fi
    fi

    # Populate the DIST_FILES array for the spdb.
    verbose "Looking for $APP_ITC in $OCS_BASE_PATH with $VERSION_OCS"
    findDistFiles "$APP_ITC" "$OCS_BASE_PATH" "$VERSION_OCS"
    if [[ $? -ne 0 ]]; then
	logError "Could not run findDistFiles."
	return 1
    fi

    logInfo "Creating distributions complete."
    return 0
}
performStep 5 buildItc


# *******************************
# ***** ITC DEPLOYMENT CODE *****
# *******************************

# Perform all the necessary processing for the server.
# Parameters required:
function processServer() {
    contains "$DISTS" "${DISTS[@]}"
    if [[ $? -ne 0 ]]; then
	logError "processServer: $DIST is not a valid distribution."
	return 1
    fi

    performStep 6 copyDist "$SERVER" "$DIST"
    performStep 7 stopServer "$SERVER"
    performStep 8 startServer "$SERVER"
    return 0
}


# Find the appropriate distribution file and copy it to the server.
# Parameters required:
# 1. The server.
function copyDist() {
    local SERVER=$1

    local DIST_PATH=
    local DIST_VAR=DIST_FILES_${APP_ITC}
    local DIST=${!DIST_VAR}[@]
    for dist in ${!DIST_VAR}; do
	echo "Checking $dist"
	if [[ "$dist" == *"$DIST"* ]]; then
	    DIST_PATH="$dist"
	    break
	fi
    done

    if [[ -z "$DIST_PATH" ]]; then
	logError "copyDist: could not find distribution matching $DIST"
	return 1
    fi

    local DIST_FILE=`echo $DIST_PATH | sed "s/.*\///"`
    if [[ $? -ne 0 ]]; then
	logError "copyDist: could not extract filename from $DIST_PATH"
	return 1
    fi
    local DIST_DIR=`echo $DIST_FILE | sed "s/\.tar\.gz//"`
    if [[ $? -ne 0 ]]; then
	logError "copyDist: could not extract dirname from $DIST_FILE"
	return 1
    fi    

    # Copy the distribution to the server.
    local SSH_CONNECT="${SSH_USER}@${SERVER}"
    scp "$DIST_PATH" "$SSH_CONNECT":
    if [[ $? -ne 0 ]]; then
	logError "copyDist: could not copy $DIST_PATH to $SERVER"
	return 1
    fi

    # Untar it on the server and remove the tarfile.
    REMOTE_ITC_PATH=`ssh "$SSH_CONNECT" "tar xfz ${DIST_FILE} && rm -f ${DIST_FILE} && cd $DIST_DIR && pwd"`
    if [[ $? -ne 0 ]]; then
	logError "copyDist: could not untar $DIST_FILE on $SERVER"
	return 1
    fi
    if [[ "$REMOTE_ITC_PATH" != "/"* ]]; then
	logError "copyDist: could not determine path of untarred $DIST_FILE on $SERVER"
	return 1
    fi

    logInfo "Copying the appropriate distribution complete."
    return 0
}


# Stop the server by telnetting in, checking psjava and telnetting
# to the server to attempt to exit. Parameters are as follows:
# 1. The name of the server.
function stopServer() {
    local SERVER="$1"
    if [[ -z "$SERVER" ]]; then
	logError "stopServer: requires a server name."
	return 1
    fi

    local SSH_CONNECT="${SSH_USER}@${SERVER}"

    logInfo "Attemping to stop server $SERVER"
    while :
    do
	local PSJAVA=`ssh $SSH_CONNECT psjava`
	if [[ -z "$PSJAVA" ]]; then
	    break
	fi

	verbose "Telnetting to stop server..."
	echo "stop 0" | ncat "$SERVER" 8224
	sleep 10
    done

    logInfo "Attempting to stop server $SERVER complete."
    return 0
}


# Start the new server.
function startServer() {
    logInfo "Attempting to start server $SERVER at $REMOTE_ITC_PATH"
    local SSH_CONNECT="${SSH_USER}@${SERVER}"

    # Get the name of the executable.
    local REMOTE_ITC_CMD=`ssh "$SSH_CONNECT" "cd $REMOTE_ITC_PATH && ls itc_* | tail -n 1" | sed "s/\*$//"`
    if [[ -z "$REMOTE_ITC_CMD" ]]; then
	logError "startServer: could not determine remote ITC executable."
	return 1
    fi

    # Start it, but do so in the background. This is because for some odd reason, the ssh command
    # does not always return here.
    ssh -f "$SSH_CONNECT" "cd $REMOTE_ITC_PATH && ./$REMOTE_ITC_CMD > sysout.txt 2>&1 &"
    if [[ $? -ne 0 ]]; then
	logWarning "startServer: could not confirm that server started."
    fi

    # We need to wait long enough for the database to come up.
    logInfo "Waiting 60 seconds for $SERVER to complete startup."
    sleep 60
    logInfo "Attempting to start server $SERVER complete."
    return 0
}
processServer



# *******************
# ***** Cleanup *****
# *******************
configCleanup
