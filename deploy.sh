#!/bin/bash

BASE_DIR=`dirname $0`
source $BASE_DIR/appfuncs.sh
source $BASE_DIR/common.sh
source $BASE_DIR/genfuncs.sh
source $BASE_DIR/logging.sh
source $BASE_DIR/verfuncs.sh
source $BASE_DIR/continuefuncs.sh

# Variables and arrays used by this script, as declared in common.sh.
VARIABLES+=(SUPPRESS_spdb VERBOSE DIRTY DIRTY_DISTROS SUPPRESS_ot SUPPRESS_qpt SUPPRESS_pit SUPPRESS_p1pdfmaker
	    SUPPRESS_OBSCONSOLES SUPPRESS_GCONFIGS VERSION_OCS_STRING VERSION_PIT_STRING)
ARRAYS+=(DIST_FILES_ot DIST_FILES_qpt)

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
	    -NO) shift
		 SUPPRESS_ot=TRUE
		 ;;
	    -NQ) shift
		 SUPPRESS_qpt=TRUE
		 ;;
	    -NP) shift
		 SUPPRESS_pit=TRUE
		 SUPPRESS_p1pdfmaker=TRUE
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
    SUPPRESS_spdb=TRUE
    
    # There should be no more command line arguments at this point.
    if [ $# -ne 0 ]; then
	showHelp
	exit 1
    fi

    # The process has started, so write the config file.
    writeConfig
fi


# *********************************
# ***** Figure out valid apps *****
# *********************************
# Always do this step as it is simply a function of the configuration.
declare -a APPSETS_VALID

function validApps() {
    if [[ -z "$SUPPRESS_ot" || -z "$SUPPRESS_qpt" ]]; then
	APPSETS_VALID+=(OCS)
    fi
    if [[ -z "$SUPPRESS_pit" ]]; then
	APPSETS_VALID+=(PIT)
    fi

    if [[ "${#APPSETS_VALID[@]}" == 0 ]]; then
	echo "All apps suppressed. Nothing to install."
	exit 0
    fi
}
validApps

# *******************
# ***** SSH IDS *****
# *******************
# Always do this step as ssh ids may expire.
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

    # Process the app versions.
    for appset in ${APPSETS_VALID[@]}; do
	local VERSION_APPSET_VAR="VERSION_${appset}_STRING"
	appVersionSetup "$appset" "$OCS_BASE_PATH" "${!VERSION_APPSET_VAR}"
    done

    logInfo "Processing versioning complete."
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

# It is kind of annoying, but if buildApps fails, we will rerun the whole thing
# instead of keeping what may have already been built. It would be overly complicated
# to do otherwise.
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
		return 1
	    fi
	fi

	# Populate the DIST_FILES array for the app.
	findDistFiles "$app" "$OCS_BASE_PATH" "$VERSION"
	if [[ $? -ne 0 ]]; then
	    logError "Could not run findDistFiles."
	    return 1
	fi
    done

    logInfo "Creating distributions complete."
    return 0
}
performStep 5 buildApps



# *********************************
# ***** 6: OBS CONSOLES SETUP *****
# *********************************
function installObsConsoles() {
    logHeader "Installing on obs consoles."

    local CONSOLE_USER=telops
    local CONSOLE_SERVERS=(sbfcontest hbfcon03)
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
	    return 1
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

    for console_server in ${CONSOLE_SERVERS[@]}; do    
	logInfo "Setting up $CONSOLE_VERSION on $console_server"

	local SSH_CONNECT="$CONSOLE_USER"@"$console_server"
	ssh "$SSH_CONNECT" "mkdir -p ${SSH_PATH}/bin" 2>&1 > /dev/null
	if [[ $? -ne 0 ]]; then
	    logError "Could not create path ${SSH_PATH}/bin"
	    return 1
	fi

	# Copy the files
	for app in ${APPS_OCS[@]}; do
	    local DIST_FILE_CONSOLE_VAR=DIST_FILE_CONSOLE_$app
	    verbose "Copying ${!DIST_FILE_CONSOLE_VAR} to ${SSH_CONNECT}:${SSH_PATH}"
	    scp "${!DIST_FILE_CONSOLE_VAR}" "$SSH_CONNECT":"$SSH_PATH" 2>&1 > /dev/null

	    if [[ $? -ne 0 ]]; then
		logError "Could not copy file ${DIST_FILE_CONSOLE_OT} to ${SSH_CONNECT}:${SSH_PATH}"
		return 1
	    fi
	done
	
        # Now finish setting up by running a script on the remote server.
	ssh "$SSH_CONNECT" "$CONSOLE_SCRIPT"
	if [[ $? -ne 0 ]]; then
	    logError "Could not set up $console_server"
	    return 1
	fi

	logInfo "Setting up $CONSOLE_VERSION on $console_server complete."
    done

    logInfo "Installing on obs consoles complete."
    return 0
}

if [[ "$SUPPRESS_OBSCONSOLES" != "TRUE" ]]; then
    performStep 6 installObsConsoles
fi



# ************************************************
# ***** 7: GSCONFIG / GNCONFIG DISTRIBUTIONS *****
# ************************************************

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

	    # Now for app_pkg, iterate over the APPS_${app_pkg} apps
	    local APPS_VAR=APPS_${app_pkg}[@]
	    for app in ${!APPS_VAR}; do
		local DIST_FILES_VAR=DIST_FILES_$app[@]

		for distfile in ${!DIST_FILES_VAR}; do
		    logInfo "Copying $distfile from package $app_pkg and application $app to ${SSH_CONNECT}:${!SSH_PATH_VAR}"

		    # Do the directory creation here so that if no distributions were prepared, we don't create an empty directory.
		    ssh "$SSH_CONNECT" "mkdir -p ${!SSH_PATH_VAR}" 2>&1 > /dev/null
		    if [[ $? -ne 0 ]]; then
			logError "Could not create ${!SSH_PATH_VAR}."
			return 1
		    fi

		    scp "$distfile" "$SSH_CONNECT":"${!SSH_PATH_VAR}" 2>&1 > /dev/null
		    if [[ $? -ne 0 ]]; then
			logError "Could not copy file $distfile to ${SSH_CONNECT}:${!SSH_PATH_VAR}"
			return 1
		    fi
		done
	    done
	done
    done

    logInfo "Installing distributions complete."
    return 0
}

if [[ "$SUPPRESS_GCONFIGS" != "TRUE" ]]; then
    performStep 7 installDistros
fi


# *******************
# ***** Cleanup *****
# *******************
configCleanup
