#!/bin/bash

source appfuncs.sh
source common.sh
source genfuncs.sh
source logging.sh
source verfuncs.sh

declare -a SERVERS
declare -a DISTS
declare -a SOURCE_SERVERS
declare -a MOUNT_POINTS

SSH_USER=software

function showHelp() {
    echo "usage: odbDeploy [-h] [-v] [-d] [-b] [-o str] [server1 dist1 sourceServer1 mountPoint1 [server2 dist2 sourceServer2 mountPoint2 [...]]"
    echo "   -h:            display help"
    echo "   -v:            verbose output"
    echo "   -d:            dirty (no sbt clean)"
    echo "   -b:            dirty distros (use existing distros)"
    echo "                     WARNING: may cause issues; predominantly to speed up testing"
    echo "   -o str:        OCS version string (e.g. 2015B-test.1.1.1)"
    echo "   server#:       a server on which to install the ODB (default: gsodbtest2 and gnodbtest2)"
    echo "   dist#:         use the specified distribution for the server (default: gsodbtest and gnodbtest)"
    echo "   sourceServer#: the server from which to fetch the DB backup (default: gsodb and gnodb)"
    echo "   mountPoint#:   the mount point on the corresponding sourceServer to get the DB backup (default: petrohue and wikiwiki)"
}

# Command line arguments.
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

# Add the rest to the servers
while [[ $# -gt 0 ]]; do
    SERVERS+=("$1")
    shift

    if [[ -z "$1" ]]; then
	showHelp
	exit 1
    fi
    SOURCE_SERVERS+=("$1")
    shift

    if [[ -z "$1" ]]; then
	showHelp
	exit 1
    fi
    MOUNT_POINTS+=("$1")
    shift
done

if [[ -z ${SERVERS[@]} ]]; then
    SERVERS=(gsodbtest2 gnodbtest2)
    DISTS=(gsodbtest gnodbtest)
    SOURCE_SERVERS=(gsodb gnodb)
    MOUNT_POINTS=(petrohue wikiwiki)
fi
verbose "Using servers: ${SERVERS[@]}"
verbose "Using distributions: ${DISTS[@]}"
verbose "Using source servers: ${SOURCE_SERVERS[@]}"
verbose "Using mount points: ${MOUNT_POINTS[@]}"



# ***************************
# ***** OCS SOURCE CODE *****
# ***************************
ocsSourceCodeSetup



# *********************
# ***** JRE SETUP *****
# *********************
jreSbtSetup



# *************************
# ***** VERSION SETUP *****
# *************************
function versionSetup() {
    logHeader "Processing versioning."
    local BUILD_FILE_SRC="$OCS_BASE_PATH"/build.sbt
    local BUILD_FILE_DST="$OCS_BASE_PATH"/build_tmp.sbt

    # Process the app versions.
    appVersionSetup "${APPSET_OCS}" "$OCS_BASE_PATH" "${VERSION_OCS_STRING}"

    logInfo "Processing versioning complete."
}
versionSetup


# ***************************
# ***** OCS-CREDENTIALS *****
# ***************************
ocsCredentialsSourceCodeSetup



# ******************************************
# ***** SBT PREPARATIONS AND EXECUTION *****
# ******************************************
sbtCompile "$DIRTY"

function buildSpdb() {
    logInfo "Creating SPDB distributions."

    # If dirty distros is not defined, then build.
    if [[ -z "$DIRTY_DISTROS" ]]; then
	# Build the app.
	buildApp "$APP_SPDB" "$OCS_BASE_PATH"
	if [[ $? -ne 0 ]]; then
	    logError "Could not run buildApp."
	    exit 1
	fi
    fi

    # Populate the DIST_FILES array for the spdb.
    findDistFiles "$APP_SPDB" "$OCS_BASE_PATH" "$VERSION_OCS"
    if [[ $? -ne 0 ]]; then
	logError "Could not run findDistFiles."
	exit 1
    fi
    logInfo "Creating distributions complete."
}
buildSpdb



# *******************************
# ***** ODB DEPLOYMENT CODE *****
# *******************************

# Perform all the necessary processing for a server.
# Parameters required:
# 1. The server.
# 2. The distribution.
# 3. The source server.
# 4. The mount point on the source server.
function processServer() {
    local SERVER=$1
    local DIST=$2
    local SOURCE_SERVER=$3
    local MOUNT_POINT=$4

    if [[ -z "$SERVER" ]]; then
	logError "processServer: must provide a server to process."
	return 1
    fi
    contains "$SERVER" "${SERVERS[@]}"
    if [[ $? -ne 0 ]]; then
	logError "processServer: $SERVER is not a valid server."
	return 1
    fi

    if [[ -z "$DIST" ]]; then
	logError "processServer: must provide a distribution to process."
	return 1
    fi
    contains "$DISTS" "${DISTS[@]}"
    if [[ $? -ne 0 ]]; then
	logError "processServer: $DIST is not a valid distribution."
	return 1
    fi

    if [[ -z "$SOURCE_SERVER" ]]; then
	logError "processServer: must provide a source server to process."
	return 1
    fi
    contains "$SOURCE_SERVER" "${SOURCE_SERVERS[@]}"
    if [[ $? -ne 0 ]]; then
	logError "processServer: $SOURCE_SERVER is not a valid source server."
	return 1
    fi

    if [[ -z "$MOUNT_POINT" ]]; then
	logError "processServer: must provide a mount point to process."
	return 1
    fi
    contains "$MOUNT_POINT" "${MOUNT_POINTS[@]}"
    if [[ $? -ne 0 ]]; then
	logError "processServer: $MOUNT_POINT is not a valid mount point."
	return 1
    fi

    copyDist "$SERVER" "$DIST"
    if [[ $? -ne 0 ]]; then
	return 1
    fi

    fetchLatestBackup "$SERVER" "$SOURCE_SERVER" "$MOUNT_POINT"
    if [[ $? -ne 0 ]]; then
	return 1
    fi

    stopServer "$SERVER"
    if [[ $? -ne 0 ]]; then
	return 1
    fi

    setupKeys "$SERVER"
    if [[ $? -ne 0 ]]; then
	return 1
    fi

    startServer "$SERVER"
    if [[ $? -ne 0 ]]; then
	return 1
    fi
    
    importXml "$SERVER"
    if [[ $? -ne 0 ]]; then
	return 1
    fi

    return 0
}


# Find the appropriate distribution file and copy it to the server.
# Parameters required:
# 1. The server.
# 2. The distribution.
function copyDist() {
    local SERVER=$1
    local DIST=$2

    logInfo "Copying the appropriate distribution."
    local DIST_PATH=
    local DIST_VAR=DIST_FILES_${APP_SPDB}[@]
    echo "DISTS=${!DIST_VAR}"
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
    echo "DIST_FILE=$DIST_FILE"
    echo "DIST_DIR=$DIST_DIR"
    REMOTE_SPDB_PATH=`ssh "$SSH_CONNECT" "tar xfz ${DIST_FILE} && rm -f ${DIST_FILE} && cd $DIST_DIR && pwd"`
    echo "REMOTE_SPDB_PATH=$REMOTE_SPDB_PATH"
    if [[ $? -ne 0 ]]; then
	logError "copyDist: could not untar $DIST_FILE on $SERVER"
	return 1
    fi
    if [[ "$REMOTE_SPDB_PATH" != "/"* ]]; then
	logError "copyDist: could not determine path of untarred $DIST_FILE on $SERVER"
	return 1
    fi

    logInfo "Copying the appropriate distribution complete."
    return 0
}


# Fetch the latest DB file backup.
# Parameters required:
# 1. The server.
# 2. The source server.
# 3. The mount point on the source server.
function fetchLatestBackup() {
    local SERVER=$1
    local SOURCE_SERVER=$2
    local MOUNT_POINT=$3

    logInfo "Fetching latest backup filename for $SERVER on $SOURCE_SERVER at mount point $MOUNT_POINT"

    local SSH_SOURCE_CONNECT="${SSH_USER}@${SOURCE_SERVER}"
    local SSH_SOURCE_PATH="/mount/${MOUNT_POINT}/odbhome/ugemini/spdb/spdb.archive/archive"
    local LATEST_FILE=`ssh ${SSH_SOURCE_CONNECT} "ls ${SSH_SOURCE_PATH} | tail -n 1"`
    if [[ $? -ne 0 ]]; then
	logError "fetchLatestBackup: could not complete ssh command to determine latest backup filename."
	return 1
    fi
    if [[ -z "$LATEST_FILE" ]]; then
	logError "fetchLatestBackup: could not retrieve latest backup filename."
	return 1
    fi
    logInfo "Latest backup filename: $LATEST_FILE"

    # Copy the latest backup to the right place on the server.
    logInfo "Copying $LATEST_FILE from $SOURCE_SERVER to $SERVER"
    local SSH_CONNECT="${SSH_USER}@${SERVER}"
    local SSH_DEST_PATH="ugemini/spdb/spdb.archive"
    scp "${SSH_SOURCE_CONNECT}":"${SSH_SOURCE_PATH}/${LATEST_FILE}" "${LATEST_FILE}"
    if [[ $? -ne 0 ]]; then
	logError "fetchLatestBackup: could not copy backup file from source server."
	return 1
    fi
    scp "${LATEST_FILE}" "${SSH_CONNECT}":"${SSH_DEST_PATH}"
    if [[ $? -ne 0 ]]; then
	logError "fetchLatestBackup: could not copy backup file to server."
	rm -f "${LATEST_FILE}"
	return 1
    fi
    rm -f "${LATEST_FILE}"

    # Unzip the backup and remove the zip.
    logInfo "Unzipping and removing the backup file."
    local BACKUP_DIRNAME=`echo $LATEST_FILE | sed "s/\.zip//"`
    BACKUP_PATH=`ssh "${SSH_CONNECT}" "cd ${SSH_DEST_PATH} && unzip -o ${LATEST_FILE} 2>&1 > /dev/null && rm -f ${LATEST_FILE} && cd $BACKUP_DIRNAME && pwd"`
    echo "BACKUP_DIRNAME=$BACKUP_DIRNAME"
    echo "BACKUP_PATH=$BACKUP_PATH"
    if [[ $? -ne 0 ]]; then
	logError "fetchLatestBackup: could not unzip the backup file on the server."
	return 1
    fi
    if [[ "$BACKUP_PATH" != "/"* ]]; then
	logError "fetchLatestBackup: could not determine the backup path."
	return 1
    fi

    logInfo "Fetching latest backup complete."
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
	sleep 5
    done

    logInfo "Attempting to stop server $SERVER complete."
    return 0
}


# Set up the keys from an old server.
# Parameters required:
# 1. The name of the server
function setupKeys() {
    local SERVER="$1"
    if [[ -z "$SERVER" ]]; then
	logError "setupKeys: requires a server name."
	return 1
    fi

    local SSH_CONNECT="${SSH_USER}@${SERVER}"
    local SSH_KEY_PATH="ugemini/spdb/spdb.active"

    logInfo "Copying over keys on $SERVER"
    local KEY_DIR_NEW=`echo "$VERSION_OCS" | sed "s/[.][0-9]\{1,\}$//"`
    if [[ -z "$KEY_DIR_NEW" ]]; then
	echo "setupKeys: could not determine new key directory from $VERSION_OCS"
	return 1
    fi
    verbose "New key directory: $KEY_DIR_NEW"

    verbose "Extracting the existing key directory from $SERVER"
    local KEY_DIR_OLD=`ssh "$SSH_CONNECT" "ls $SSH_KEY_PATH | grep 2 | tail -n 1" | sed "s/\/$//"`
    if [[ -z "$KEY_DIR_OLD" ]]; then
	logError "setupKeys: could not extract an existing key directory."
	return 1
    fi
    verbose "Existing key directory: $KEY_DIR_OLD"

    # Check to make sure the directories are not the same.
    if [[ "$KEY_DIR_NEW" == "$KEY_DIR_OLD" ]]; then
	logInfo "Nothing to be done as new key directory and old key directory are the same: $KEY_DIR_NEW"
    else
local CONSOLE_SCRIPT="#!/bin/bash
cd $SSH_KEY_PATH
mkdir -p $KEY_DIR_NEW
cp -r $KEY_DIR_OLD/keyserver $KEY_DIR_OLD/vcs* $KEY_DIR_NEW/"

# TODO: REMOVE ECHO
echo ${CONSOLE_SCRIPT}

        # Execute the key copy script.
	ssh "$SSH_CONNECT" "$CONSOLE_SCRIPT"
	if [[ $? -ne 0 ]]; then
	    logError "setupKeys: could not copy keys."
	    return 1
	fi
    fi

    logInfo "Copying over keys done."
    return 0
}


# Start the new server.
# Parameters required:
# 1. The name of the server.
function startServer() {
    local SERVER="$1"
    if [[ -z "$SERVER" ]]; then
	logError "startServer: requires a server name."
	return 1
    fi

    logInfo "Attempting to start server $SERVER at $REMOTE_SPDB_PATH"
    local SSH_CONNECT="${SSH_USER}@${SERVER}"

    # Get the name of the executable.
    local REMOTE_SPDB_CMD=`ssh "$SSH_CONNECT" "cd $REMOTE_SPDB_PATH && ls spdb_* | tail -n 1" | sed "s/\*$//"`
    if [[ -z "$REMOTE_SPDB_CMD" ]]; then
	logError "startServer: could not determine remote SPDB executable."
	return 1
    fi

    # Start it.
    ssh "$SSH_CONNECT" "cd $REMOTE_SPDB_PATH && nohup ./$REMOTE_SPDB_CMD > sysout.txt 2>&1"
    if [[ $? -ne 0 ]]; then
	logError "startServer: could not start server."
	return 1
    fi

    logInfo "Waiting 20 seconds for $SERVER to complete startup."
    sleep 20
    logInfo "Attempting to start server $SERVER complete."
    return 0
}


# Telnet to server and import the XML backup dump.
# Parameters required:
# 1. The name of the server.
function importXml() {
    local SERVER="$1"
    if [[ -z "$SERVER" ]]; then
	logError "importXml: requires a server name."
	return 1
    fi

    logInfo "Importing XML backup to $SERVER"
    echo "importXml $BACKUP_PATH" | ncat "$SERVER" 8224
    if [[ $? -ne 0 ]]; then
	logError "importXml: could not run importXml on $SERVER for path $BACKUP_PATH"
	return 1
    fi

    logInfo "Importing XML backup complete."
    return 0
}


function processServers() {
    local NUM_SERVERS=${#SERVERS[@]}
    for (( i=0; i<${NUM_SERVERS}; i++ )); do
	local SERVER="${SERVERS[$i]}"
	local DIST="${DISTS[$i]}"
	local SOURCE_SERVER="${SOURCE_SERVERS[$i]}"
	local MOUNT_POINT="${MOUNT_POINTS[$i]}"

	logHeader "Processing server $SERVER for distribution $DIST using source server $SOURCE_SERVER at mount point $MOUNT_POINT"
	processServer "${SERVERS[$i]}" "${DISTS[$i]}" "${SOURCE_SERVERS[$i]}" "${MOUNT_POINTS[$i]}"
	if [[ $? -ne 0 ]]; then
	    logError "processServers: could not process."
	    exit 1
	fi
	logInfo "Processing server $SERVER complete."
    done
}
processServers
