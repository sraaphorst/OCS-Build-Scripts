#!/usr/bin/bash
# Functions that are common to deploy and odb_deploy.

source genfuncs.sh
source logging.sh
source verfuncs.sh


# Set up the requisite paths.
DEV_BASE_PATH=`absPath ${DEV_BASE_PATH:-"$HOME/dev"}`
OCS_CRED_PATH=`absPath ${OCS_CRED_PATH:-"$DEV_BASE_PATH/ocs-credentials"}`
OCS_BASE_PATH=`absPath ${OCS_BASE_PATH:-"$DEV_BASE_PATH/ocs"}`
JRE_PATH=`absPath ${JRE_PATH:-"$DEV_BASE_PATH/jres8"}`


# Update the OCS source code.
function ocsSourceCodeSetup() {
    logHeader "OCS source code setup" no

    if [[ -d "$OCS_BASE_PATH" ]]; then
	logInfo "Updating OCS source code."
	cd "$OCS_BASE_PATH"
	if [[ $? -ne 0 ]]; then
	    logError "Could not cd to OCS base path: $OCS_BASE_PATH"
	    exit 1
	fi
	execVerbose \
	    "git pull --progress" \
	    "git pull -q 2>&1 > /dev/null"
	if [[ $? -ne 0 ]]; then
	    logError "Could not update OCS from git repository."
	    exit 1
	fi
	logInfo "Updating OCS source code complete."
    else
	logInfo "Checking out OCS source code."
	execVerbose \
	    "git clone -v --progress https://github.com/gemini-hlsw/ocs \"$OCS_BASE_PATH\"" \
	    "git clone -q https://github.com/gemini-hlsw/ocs "$OCS_BASE_PATH" 2>&1 > /dev/null"
	if [[ $? -ne 0 ]]; then
	    logError "Could not clone the OCS git repostitory to OCS base path: $OCS_BASE_PATH"
	    exit 1
	fi
	logInfo "Checking out OCS source code complete."
    fi
    return 0
}



# Make sure that the jres.sbt file exists, and if not, create it, making sure all the JREs exist.
function jreSbtSetup() {
    if [[ ! -d "$JRE_PATH" ]]; then
	logError "Cannot find the JRE directory for the build: $JRE_PATH"
	exit 1
    fi
    if [[ ! -f "$JRE_PATH"/osx/JRE1.8/bin/java ]]; then
	logError "Cannot find the MacOS JRE."
	logInfo  "Note that for MacOS, the symlink `absPath "$JRE_PATH"/osx/JRE1.8` should point to `absPath "$JRE_PATH"/osx/jre1.8.x_xx.jre/Contents/Home`."
	exit 1
    fi
    if [[ ! -f "$JRE_PATH"/linux/JRE32_1.8/bin/java ]]; then
	logError "Cannot find the Linux32 JRE."
	exit 1
    fi
    if [[ ! -f "$JRE_PATH"/linux/JRE64_1.8/bin/java ]]; then
	logError "Cannot find the Linux64 JRE."
	exit 1
    fi
    if [[ ! -f "$JRE_PATH"/windows/JRE1.8/bin/java.exe ]]; then
	logError "Cannot find the Windows JRE."
	exit 1
    fi
    if [[ ! -f "$OCS_BASE_PATH"/jres.sbt ]]; then
	echo "ocsJreDir in ThisBuild := file(\"$JRE_PATH\")" > "$OCS_BASE_PATH"/jres.sbt
	if [[ $? -ne 0 ]]; then
	    logError "Could not create jres.sbt file."
	    exit 1
	fi
    fi
    return 0
}



# Handle the versioning for a specific app group, either OCS or PIT.
# Parameters are as follows:
# 1. Appset name: either OCS or PIT.
# 2. The OCS base path.
# 3. The version string (can be empty / undefined).
function appVersionSetup() {
    local APPSET=$1
    local OCS_BASE_PATH=$2
    local VERSION_APPSET_STRING=$3

    if [[ -z "$APPSET" ]]; then
	return 0
    fi

    if [[ -z "$OCS_BASE_PATH" ]]; then
	logError "appVersionSetup requires OCS base path to be specified."
	return 1
    fi
    local BUILD_FILE_SRC="$OCS_BASE_PATH"/build.sbt
    local BUILD_FILE_DST="$OCS_BASE_PATH"/build_tmp.sbt

    # Convert APP into a build ID string, i.e. either ocsVersion or pitVersion.
    local APPSET_BUILD_ID=`echo "$APPSET" | tr [:upper:] [:lower:]`Version

    if [[ -z "$VERSION_APPSET_STRING" ]]; then
	logWarn "No versioning info provided for $APPSET"
    else
	logInfo "Setting $APPSET version in build.sbt to $VERSION_APPSET_STRING"
	local VERSION_APPSET_TUPLE=`toOcsVersion "$VERSION_APPSET_STRING"`
	if [[ -z "$VERSION_APPSET_TUPLE" ]]; then
	    logError "Illegal $APPSET version string: $VERSION_APPSET_STRING"
	    exit 1
	fi
	verbose "$APPSET version tuple: $VERSION_APPSET_TUPLE"
	
        # Substitute it into build.sbt to a temp file, and then move the temp file back to build.sbt.
	sed "s/^${APPSET_BUILD_ID}.*/${APPSET_BUILD_ID} in ThisBuild := ${VERSION_APPSET_TUPLE}/" < "$BUILD_FILE_SRC" > "$BUILD_FILE_DST"
	mv -f "$BUILD_FILE_DST" "$BUILD_FILE_SRC"
	
	logInfo "Setting $APPSET version in build.sbt complete."
    fi

    # Retrieve the version from build.sbt.
    logInfo "Extracting $APPSET version from build.sbt"
    local VERSION_VAR="VERSION_${APPSET}"
    local VERSION_EXTRACT="`grep "^${APPSET_BUILD_ID}" "$BUILD_FILE_SRC"`"
    eval "$VERSION_VAR=`fromOcsVersion "$VERSION_EXTRACT"`"
    logInfo "Extracted $APPSET version as: ${!VERSION_VAR}"
    
    return 0
}


# Update and setup the OCS credentials.
function ocsCredentialsSourceCodeSetup() {
    logHeader "OCS credentials source code setup"

    if [[ -d "$OCS_CRED_PATH" ]]; then
	logInfo "Updating OCS credentials source code."
	
	cd "$OCS_CRED_PATH"
	if [[ $? -ne 0 ]]; then
	    logError "Could not cd to OCS credentials path: $OCS_CRED_PATH"
	    exit 1
	fi
	
	execVerbose \
	    "svn up" \
	    "svn up 2>&1 > /dev/null"
	if [[ $? -ne 0 ]]; then
	    logError "Could not update OCS credentials from svn repository."
	    exit 1
	fi
	logInfo "Updating OCS credential source code complete."
    else
	logInfo "Checking out OCS credentials source code repository."
	
	execVerbose \
	    "svn co http://source.gemini.edu/software/ocs-credentials \"$OCS_CRED_PATH\"" \
	    "svn co http://source.gemini.edu/software/ocs-credentials \"$OCS_CRED_PATH\" 2>&1 > /dev/null"
	if [[ $? -ne 0 ]]; then
	    echo "ERROR: could not check out the svn ocs-credentials repostitory"
	    exit 1
	fi
	logInfo "Checking out OCS credentials source code repository complete."
    fi

    # Now we need to link the OCS credentials to the OCS.
    logInfo "Linking the OCS credentials to the OCS."
    execVerbose \
	"\"$OCS_CRED_PATH\"/trunk/link.sh -v \"$OCS_BASE_PATH\"" \
	"\"$OCS_CRED_PATH\"/trunk/link.sh \"$OCS_BASE_PATH\" 2>&1 > /dev/null"
    if [[ $? -ne 0 ]]; then
	echo "ERROR: could not run the OCS credentials link.sh script"
	exit 1
    fi
    logInfo "Linking the OCS credentials to the OCS complete."
}



# Run sbt compile if appropriate to do so.
# If a first parameter is specified as TRUE, then do not clean first.
function sbtCompile() {
    logHeader "Running SBT for OCS"

    local OLD_PATH=`pwd`
    cd "$OCS_BASE_PATH"
    if [[ $? -ne 0 ]]; then
	logError "Could not cd to OCS base path: $OCS_BASE_PATH"
	exit 1
    fi

    if [[ "$1" != "TRUE" ]]; then
	logInfo "Cleaning project."
	sbt --error clean
	if [[ $? -ne 0 ]]; then
	    logError "Could not run: sbt clean"
	    exit 1
	fi
	logInfo "Cleaning project complete."
    fi

    logInfo "Compiling project."
    sbt --error compile
    if [[ $? -ne 0 ]]; then
	logError "Could not run: sbt compile"
	exit 1
    fi

    cd "$OLD_PATH"
    logInfo "Compiling project complete."
}