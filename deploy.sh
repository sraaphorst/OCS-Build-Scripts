#!/bin/bash

source appfuncs.sh
source common.sh
source genfuncs.sh
source logging.sh
source verfuncs.sh


function showHelp() {
    echo "usage: deploy.sh [-h] [-v] [-d] [-b] [-NO] [-NQ] [-NP] [-NC] [-NG] [-o str] [-p str]"
    echo "   -h:       display help"
    echo "   -v:       verbose output"
    echo "   -d:       dirty (no sbt clean)"
    echo "   -b:       dirty distros (use existing distros)"
    echo "               WARNING: may cause issues; predominantly to speed up testing"
    echo "   -NO:      suppress OT installation"
    echo "   -NQ:      suppress QPT installation"
    echo "   -NP:      suppress PIT / p1pdfmaker installation"
    echo "   -NC:      do not install on obs consoles"
    echo "   -NG:      do not copy to gnconfig / gsconfig"
    echo "   -o str:   OCS version string (e.g. 2015B-test.1.1.1)"
    echo "   -p str:   PIT version string (e.g. 2016A.1.1.0)"
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
	-NO) shift
	    SUPPRESS_OT=TRUE
	    ;;
	-NQ) shift
	    SUPPRESS_QPT=TRUE
	    ;;
	-NP) shift
	    SUPPRESS_PIT=TRUE
	    SUPPRESS_P1PDF=TRUE
	    ;;
	-NC) shift
	    SUPPRESS_OBSCONSOLES=TRUE
	    ;;
	-NG) shift
	    SUPPRESS_GCONFIGS=TRUE
	    ;;
	-o) shift
	    VERSION_OCS_STRING=$1
	    shift
	    ;;
	-p) shift
	    VERSION_PIT_STRING=$1
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

if [ $# -ne 0 ]; then
    showHelp
    exit 1
fi


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

    # Process the app versions.
    for appset in ${APPSETS_ALL[@]}; do
	local VERSION_APPSET_VAR="VERSION_${appset}_STRING"
	appVersionSetup "$appset" "$OCS_BASE_PATH" "${!VERSION_APPSET_VAR}"
    done

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


function buildApps() {
    logInfo "Creating application distributions."
    for app in ${APPS[@]}; do
        # Make sure that we are not suppressing this app.
	local SUPPRESS_FLAG=SUPPRESS_$app
	if [[ "${!SUPPRESS_FLAG}" == "TRUE" ]]; then
	    continue
	fi

	# Determine the version we are using. If not PIT, then OCS.
	contains "$app" "${APPS_PIT[@]}"
	if [[ $? -eq 0 ]]; then
	    local VERSION=$VERSION_PIT
	else
	    local VERSION=$VERSION_OCS
	fi

	# If dirty distros is not defined, then build.
	if [[ -z "$DIRTY_DISTROS" ]]; then
	    # Build the app.
	    buildApp "$app" "$OCS_BASE_PATH"
	    if [[ $? -ne 0 ]]; then
		logError "Could not run buildApp."
		exit 1
	    fi
	fi

	# Populate the DIST_FILES array for the app.
	findDistFiles "$app" "$OCS_BASE_PATH" "$VERSION"
	if [[ $? -ne 0 ]]; then
	    logError "Could not run findDistFiles."
	    exit 1
	fi
    done

    logInfo "Creating distributions complete."
}
buildApps



# ******************************
# ***** OBS CONSOLES SETUP *****
# ******************************

function installObsConsoles() {
    logHeader "Installing on obs consoles."

    local CONSOLE_USER=telops
    local CONSOLE_SERVERS=(sbfcon02 hbfcon03)
    local CONSOLE_VERSION=`echo $VERSION_OCS | sed "s/\..*//"`
    local SSH_PATH="perm/$CONSOLE_VERSION"

    # We only want the Linux64 OT / QPT dists for this. Just dig them up out of the arrays.
    for app in ${APPS_OCS[@]}; do
	local DIST_VAR=DIST_FILES_$app[@]
	for tmp_file in ${!DIST_VAR}; do
	    if [[ "$tmp_file" == *"$DIST_LINUX64"* ]]; then
		eval "local DIST_FILE_CONSOLE_$app=$tmp_file"
		break
	    fi
	done

	local DIST_FILE_VAR=DIST_FILE_CONSOLE_$app
	if [[ -z "${!DIST_FILE_VAR}" ]]; then
	    logError "Could not find $app $DIST_LINUX64 build."
	    exit 1
	fi

	# Retrieve filename from path.
	eval "local CONSOLE_FILENAME_$app=`echo ${!DIST_FILE_VAR} | sed "s/.*\///"`"
    done

    # Script for finalizing install on obs consoles.
    local FILENAME_OT=CONSOLE_FILENAME_${APP_OT}
    local FILENAME_QPT=CONSOLE_FILENAME_${APP_QPT}
local CONSOLE_SCRIPT="#!/bin/bash
cd $SSH_PATH
tar xfz ${!FILENAME_OT}
tar xfz ${!FILENAME_QPT}
rm -f ${!FILENAME_OT} ${!FILENAME_QPT}

echo '#\!/bin/sh' > bin/ot.sh
echo 'VERSION=$VERSION_OCS' >> bin/ot.sh
echo 'echo \"Starting the OT (\${VERSION})\"' >> bin/ot.sh
echo 'DIR=~/perm/$CONSOLE_VERSION/ot_\${VERSION}_linux64' >> bin/ot.sh
echo '\${DIR}/ot_\${VERSION}' >> bin/ot.sh
chmod a+x bin/ot.sh

echo '#\!/bin/sh' > bin/qpt.sh
echo 'VERSION=$VERSION_OCS' >> bin/qpt.sh
echo 'echo \"Starting the QPT (\${VERSION})\"' >> bin/qpt.sh
echo 'DIR=~/perm/$CONSOLE_VERSION/qpt_\${VERSION}_linux64' >> bin/qpt.sh
echo '\${DIR}/qpt_\${VERSION}' >> bin/qpt.sh
chmod a+x bin/qpt.sh
"

# TODO: REMOVE ECHO
echo ${CONSOLE_SCRIPT}
    for console_server in ${CONSOLE_SERVERS[@]}; do    
	logInfo "Setting up $CONSOLE_VERSION on $console_server"

	local SSH_CONNECT="$CONSOLE_USER"@"$console_server"
	ssh "$SSH_CONNECT" "mkdir -p ${SSH_PATH}/bin" 2>&1 > /dev/null
	if [[ $? -ne 0 ]]; then
	    logError "Could not create path ${SSH_PATH}/bin"
	    exit 1
	fi

	# Copy the files
	for app in ${APPS_OCS[@]}; do
	    local DIST_FILE_CONSOLE_VAR=DIST_FILE_CONSOLE_$app
	    verbose "Copying ${!DIST_FILE_CONSOLE_VAR} to ${SSH_CONNECT}:${SSH_PATH}"
	    scp "${!DIST_FILE_CONSOLE_VAR}" "$SSH_CONNECT":"$SSH_PATH" 2>&1 > /dev/null

	    if [[ $? -ne 0 ]]; then
		logError "Could not copy file ${DIST_FILE_CONSOLE_OT} to ${SSH_CONNECT}:${SSH_PATH}"
		exit 1
	    fi
	done
	
        # Now finish setting up by running a script on the remote server.
	ssh "$SSH_CONNECT" "$CONSOLE_SCRIPT"
	if [[ $? -ne 0 ]]; then
	    logError "Could not set up $console_server"
	    exit 1
	fi

	logInfo "Setting up $CONSOLE_VERSION on $console_server complete."
    done
    logInfo "Installing on obs consoles complete."
}
if [[ "$SUPPRESS_OBSCONSOLES" != "TRUE" ]]; then
    installObsConsoles
fi



# *********************************************
# ***** GSCONFIG / GNCONFIG DISTRIBUTIONS *****
# *********************************************

function installDistros() {
    logHeader "Installing distributions."

    local DIST_USER=telops
    local DIST_SERVERS=(gsconfig gnconfig)

    local SSH_PACKAGES=(OCS PIT P1PDF)
    local SSH_PATH_OCS=/gemsoft/var/downloads/"$VERSION_OCS"
    local SSH_PATH_PIT=/gemsoft/var/downloads/PIT_"$VERSION_PIT"
    local SSH_PATH_P1PDF=/gemsoft/var/downloads/p1pdfmaker_"$VERSION_PIT"

    for dist_server in "${DIST_SERVERS[@]}"; do
	logInfo "Creating distributions on: $dist_server"

	local SSH_CONNECT="$DIST_USER"@"$dist_server"
	for app_pkg in ${SSH_PACKAGES[@]}; do
	    local SSH_PATH_VAR=SSH_PATH_${app_pkg}

	    ssh "$SSH_CONNECT" "mkdir -p ${!SSH_PATH_VAR}" 2>&1 > /dev/null
	    if [[ $? -ne 0 ]]; then
		logError "Could not create ${!SSH_PATH_VAR}."
		exit 1
	    fi

	    # Now for app_pkg, iterate over the APPS_${app_pkg} apps
	    logInfo "Copying distribution $app_pkg to ${SSH_CONNECT}:${!SSH_PATH_VAR}"
	    local APPS_VAR=APPS_${app_pkg}[@]
	    for app in ${!APPS_VAR}; do
		verbose "Copying $app"
		local DIST_FILES_VAR=DIST_FILES_$app[@]

		for distfile in ${!DIST_FILES_VAR}; do
		    verbose "Copying $distfile"
		    scp "$distfile" "$SSH_CONNECT":"${!SSH_PATH_VAR}" 2>&1 > /dev/null
		    if [[ $? -ne 0 ]]; then
			logError "Could not copy file ${distfile} to ${SSH_CONNECT}:${!SSH_PATH_VAR}"
			exit 1
		    fi
		done
	    done
	    logInfo "Copying distribution $app_pkg to ${SSH_CONNECT}:${!SSH_PATH} complete."
	done
    done
    logInfo "Installing distributions complete."
}
if [[ "$SUPPRESS_GCONFIGS" != "TRUE" ]]; then
    installDistros
fi
