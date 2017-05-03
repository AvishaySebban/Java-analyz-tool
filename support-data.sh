#!/usr/bin/env bash

##############################################################################
#
# This script collects threadumps, cpu usage etc data from JIRA
# You can do it manually following instructions from
# https://confluence.atlassian.com/display/JIRAKB/Troubleshooting+Performance+Issues+with+Thread+Dumps
#
##############################################################################

# Is jstack installed? should be present by default
command -v jstack >/dev/null 2>&1 || {
    >&2 echo "Error: jstack is not present in your system. Please install Java JDK"
	>&2 echo "You can download it from Oracle website (http://www.oracle.com/technetwork/java/javase/downloads) or your system package manager"
	exit -1;
}


# If more than one JIRA is running users will be asked which one they want to collect data from
function multiple_instances {
	IFS=$'\n' read -rd '' -a PRODUCT_PIDS <<<"$PRODUCT_PID"
	PRODUCT_PID=""
	echo "More than one ${PRODUCT} instances detected:"
	while [ -z "${PRODUCT_PID}" ]; do
		for i in "${!PRODUCT_PIDS[@]}"; do
			BASE_DIR=$(ps aux | grep -i ${PRODUCT_LOWER} | grep -i "${PRODUCT_PIDS[$i]}" | tr " " "\n" | grep "\-Dcatalina.base" | awk -F '=' '{ print $2 }')
			echo "${i}) ${PRODUCT_PIDS[$i]} ${BASE_DIR}"
		done
		read -e -p "Enter option: " option
		if [ "${option}" -le "${i}" ]; then
			PRODUCT_PID="${PRODUCT_PIDS[$option]}"
		else
			echo "Invalid otpion"
		fi
	done

	echo "Selected ${PRODUCT_PID}"
}


# Called from thread dump collection loop, does a jstack and waits 10 secs
function threads_report_and_wait {
	DUMP="${DATA_FOLDER}/${PRODUCT_LOWER}_threads.$(date +%s).txt"
	jstack -l "$PRODUCT_PID" > "$DUMP" || jstack -F -m -l "$PRODUCT_PID" > "$DUMP"
	echo -ne "Capturing thread dumps in ${DATA_FOLDER} $(( $i * 16 )) %\r"
	if [ "${i}" -lt 6 ]; then
		sleep 10;
	fi
}

# Captures threaddumps and cpu usage, it hacks the threaddumps so they can be opened with TDA
function capture_threaddumps {
	read -p "Do you want to capture thread dumps? (y/n) "
	if [[ ! $REPLY == [Yy]* ]]; then
		return
	fi
	
	if [ -z "${PRODUCT_PID}" ]; then
		>&2 echo "No running ${PRODUCT} detected."
		((RETCODE++))
		return 1
	fi

	echo "Collecting information about the running ${PRODUCT} instance. It will take approximately 1 minute."
	mkdir -p "${DATA_FOLDER}"
	
	if [ "$(uname)" == "Darwin" ]; then
		# Mac
		for i in {1..6}; do
			top -l 1 -pid "$PRODUCT_PID" > "${DATA_FOLDER}/${PRODUCT_LOWER}_cpu_usage.$(date +%s).txt";
			threads_report_and_wait
			sed -i '' -E 's/prio=[0-9]{1,2} os_prio=-?[0-9]{1,2}/prio=5/g' "$DUMP" # Java 8 hack - Mac version
		done
	elif [ "$(expr substr $(uname -s) 1 5)" == "Linux" ]; then
	    # Linux system
		for i in {1..6}; do
			top -b -H -p "$PRODUCT_PID" -n 1 > "${DATA_FOLDER}/${PRODUCT_LOWER}_cpu_usage.$(date +%s).txt";
			threads_report_and_wait
			sed -i 's/prio=[0-9]\{1,2\} os_prio=-\?[0-9]\{1,2\}/prio=5/g' "$DUMP" # Java 8 hack
		done
	else # solaris?
		echo "No Linux or OSX detected, asuming Solaris"
		for i in {1..6}; do
			prstat -L -p "$PRODUCT_PID" -n 500 1 1 > "${DATA_FOLDER}/${PRODUCT_LOWER}_cpu_usage.$(date +%Y-%m-%d_%H%M%S).txt";
			threads_report_and_wait
			sed -i 's/prio=[0-9]\{1,2\} os_prio=-\?[0-9]\{1,2\}/prio=5/g' "$DUMP" # Java 8 hack
		done
	fi
	
	echo -e "Capturing thread dumps in ${DATA_FOLDER} 100 %"
	command -v pmap >/dev/null 2>&1 && {
		# Linux and Solaris
		echo "Capturing ${PRODUCT} pmap"
		pmap "$PRODUCT_PID" > "${DATA_FOLDER}/pmap_output.txt"
	}

	command -v vmmap >/dev/null 2>&1 && {
		# Mac
		echo "Capturing ${PRODUCT} vmmap, you may be requested your sudo password."
		sudo vmmap "$PRODUCT_PID" > "${DATA_FOLDER}/vmmap_output.txt"
	}	
}

function capture_heapdump {
	echo ""
	read -p "Do you want to capture a heap dump? (y/n) "
	echo ""
	if [[ ! $REPLY == [Yy]* ]]; then
		return
	fi

	if [ -z "${PRODUCT_PID}" ]; then
		>&2 echo "No running ${PRODUCT} detected."
		((RETCODE++))
		return 1
	fi

	if [ -z ${JIRA_JAVA_HOME} ]; then
		JMAP_COMMAND="jmap"
		JSTAT_COMMAND="jstat"
	else
		JMAP_COMMAND="${JIRA_JAVA_HOME}/bin/jmap"
		JSTAT_COMMAND="${JIRA_JAVA_HOME}/bin/jstat"
	fi	
	command -v $JMAP_COMMAND >/dev/null 2>&1 || {
	    echo "jmap not found, attemting to find it in JAVA_HOME"
		if [ -z "${JAVA_HOME}" ]; then
			if [ "$(uname)" == "Darwin" ]; then
				JAVA_HOME=`$(dirname $(readlink $(which javac)))/java_home`
		 	else
				JAVA_HOME=`$(dirname $(dirname $(readlink $(which javac))))`
			fi
			echo "JAVA_HOME detected in ${JAVA_HOME}"
			JMAP_COMMAND="${JAVA_HOME}/bin/jmap"
			JSTAT_COMMAND="${JAVA_HOME}/bin/jstat"
		fi
	}

	mkdir -p "${DATA_FOLDER}"
	if [ $(command -v $JMAP_COMMAND >/dev/null 2>&1) ]; then
		>&2 echo "Error: jmap is not present in your system. Please install Java JDK"
	else
		HEAPDUMP="heap.$(date +%Y-%m-%d_%H%M%S).bin"
		echo "Running $JMAP_COMMAND -dump:format=b,file=$HEAPDUMP $PRODUCT_PID"
		$JMAP_COMMAND -dump:format=b,file=$HEAPDUMP $PRODUCT_PID
		mv $HEAPDUMP ${DATA_FOLDER}/
	fi
	
	if [ $(command -v $JSTAT_COMMAND >/dev/null 2>&1) ]; then
		>&2 echo "Error: jstat is not present in your system. Please install Java JDK"
	else
		JSTAT_INFO="jstat.$(date +%Y-%m-%d_%H%M%S).txt"
		echo "Running $JSTAT_COMMAND -gc ${PRODUCT_PID} 1s 10"
		$JSTAT_COMMAND -gc ${PRODUCT_PID} 1s 10 > ${DATA_FOLDER}/${JSTAT_INFO}
	fi
}

# Downloads support-tools.jar and does a disk usage benchmark
function disk_access {
	command -v wget >/dev/null 2>&1 || {
		>&2 echo "wget is not present in your system, please install wget and try again"
		exit 0
	}
	echo ""
	read -p "Do you want to test disk access speed? (y/n) "
	echo ""
	if [[ ! $REPLY == [Yy]* ]]; then
		return
	fi
	if [ ! -f "support-tools.jar" ]; then
		wget -O support-tools.jar https://bitbucket.org/juliasimon/atlassian-support-benchmark/downloads/support-tools.jar
	fi

	if [ -z "${PRODUCT_HOME}" ]; then
		read -e -p "Enter your ${PRODUCT_HOME} home directory: " PRODUCT_HOME
	fi
	
	mkdir -p "${DATA_FOLDER}"
	
	echo "Testing disk access in ${PRODUCT_HOME}"
	echo ""

	${JAVA_BIN} -Djava.io.tmpdir=$PRODUCT_HOME -jar support-tools.jar | tee ${DATA_FOLDER}/${PRODUCT_LOWER}_home_diskspeed.txt

	if [[ "$PRODUCT" == 'JIRA' ]]; then
		echo ""
		echo "Testing disk access in ${PRODUCT_HOME}/caches/indexes"

		${JAVA_BIN} -Djava.io.tmpdir="${PRODUCT_HOME}/caches/indexes" -jar support-tools.jar | tee ${DATA_FOLDER}/caches_indexes_diskspeed.txt
	fi

	echo ""
	echo "Grade the results in https://confluence.atlassian.com/display/JIRAKB/Testing+Disk+Access+Speed#TestingDiskAccessSpeed-grade"
	echo ""
}

function ssl_poke {
	echo ""
	read -p "Do you want to check the Java SSL connection? (y/n) "
	if [[ ! $REPLY == [Yy]* ]]; then
		return
	fi
	command -v wget >/dev/null 2>&1 || {
		>&2 echo "wget is not present in your system, please install wget and try again"
		((RETCODE++))
		return 1
	}
	
	if [ ! -f "SSLPoke.class" ]; then
		wget -O SSLPoke.class "https://confluence.atlassian.com/download/attachments/779355358/SSLPoke.class?version=1&modificationDate=1441897666313&api=v2"
	fi
	
	read -e -p "Enter the port to test (443): " TEST_PORT
	[ -z "${TEST_PORT}" ] && TEST_PORT='443'
	read -e -p "Enter the URL for the SSL connection: " PRODUCT_URL
	read -e -p "Enter custom truststore or leave this empty to use the default cacerts trust store: " TRUST_STORE
	mkdir -p ${DATA_FOLDER}
	if [ -z "$TRUST_STORE" ]; then
		echo "${JAVA_BIN} SSLPoke $PRODUCT_URL $TEST_PORT | tee ${DATA_FOLDER}/ssl_poke.txt"
		${JAVA_BIN} SSLPoke ${PRODUCT_URL} ${TEST_PORT} 2>&1 | tee ${DATA_FOLDER}/ssl_poke.txt
	else
		echo "${JAVA_BIN} SSLPoke -Djavax.net.ssl.trustStore=$TRUST_STORE ${PRODUCT_URL} ${TEST_PORT} 2>&1 | tee ${DATA_FOLDER}/ssl_poke.txt"
		${JAVA_BIN} SSLPoke -Djavax.net.ssl.trustStore=${TRUST_STORE} ${PRODUCT_URL} ${TEST_PORT} 2>&1 | tee ${DATA_FOLDER}/ssl_poke.txt
	fi
}

# Compresses data gathered in DATA_FOLDER
function compress_data {
	if [ ! -d "${DATA_FOLDER}" ]; then
		return
	fi
	
	echo -ne "Compressing ${DATA_FOLDER}..."
	TAR_SUCCESS=$(tar -zcf "${DATA_FOLDER}.tar.gz" "${DATA_FOLDER}")

	if [ -s ${DATA_FOLDER}.tar.gz ]; then
		rm -rf "${DATA_FOLDER}";
		echo "${DATA_FOLDER}.tar.gz generated, please attach it to your support ticket."
	else
		echo "Something went wrong, please compress ${DATA_FOLDER} and attach it to your support ticket."
		((RETCODE++))
		return 1
	fi
}

#################################################### Parse the Command line for product ##############################
# Detect the prodcut that the data is to be collected for and if none is specified, default to Jira
case "$1" in
  "") PRODUCT='JIRA';;
  * ) PRODUCT=$1;;     # Otherwise, $1.
esac

case $PRODUCT in
	"jira" | "JIRA" ) 
		PRODUCT='JIRA'
		PRODUCT_LOWER='jira';;
	"bitbucket"  | "BITBUCKET" )
		PRODUCT='BITBUCKET'
		PRODUCT_LOWER='bitbucket';;
	"stash" | "STASH" )
		PRODUCT='STASH'
		PRODUCT_LOWER='stash';;
	"fisheye" | "FISHEYE" )
		PRODUCT='FISHEYE'
		PRODUCT_LOWER='fisheye';;
	"bamboo" | "BAMBOO" )
		PRODUCT='BAMBOO'
		PRODUCT_LOWER='bamboo';;
	"confluence" | "CONFLUENCE" )
		PRODUCT='CONFLUENCE'
		PRODUCT_LOWER='confluence';;
	* )
		PRODUCT='JIRA'
		PRODUCT_LOWER='jira';;
esac

#################################################### MAIN PROGRAM ####################################################
# Detect running PRODUCT PID, PRODUCT_HOME and JAVA_HOME  (if possible)
PRODUCT_PID=$(ps aux | grep -i ${PRODUCT_LOWER} | grep -i java | grep -v elasticsearch | awk  -F '[ ]*' '{print $2}');
if [ ! -z "${PRODUCT_PID}" ]; then
	if [[ "${PRODUCT_PID}" == *$'\n'* ]]; then
		multiple_instances  # Deambiguate which jira
	else
		echo "${PRODUCT} PID detected ${PRODUCT_PID}"
	fi
	if [ -z "${PRODUCT_HOME}" ]; then  # Could be set as an env variable
	    PRODUCT_HOME=$(ps aux | grep -i ${PRODUCT_LOWER} | grep -i ${PRODUCT_PID} | tr " " "\n" | grep "\-D${PRODUCT_LOWER}.home=" | awk -F '=' '{ print $2 }')
		if [ -n "${PRODUCT_HOME}" ]; then
			echo "${PRODUCT}_HOME detected in ${PRODUCT_HOME}"			
		fi
	fi

	JAVA_BIN=$(ps aux | grep -i ${PRODUCT_LOWER} | grep -i ${PRODUCT_PID} | awk  -F '[ ]*' '{print $11}')
	if [[ "$JAVA_BIN" == *java ]]
	then
		echo "JAVA_BIN detected ${JAVA_BIN}"
		PRODUCT_JAVA_HOME=${JAVA_BIN%"/bin/java"}
	else
		JAVA_BIN="java"
	fi
fi

declare -i RETCODE=0
# Folder where all gathered data is going to be stored
DATA_FOLDER="${PRODUCT}-dumps-"$(date +%s)

disk_access
capture_threaddumps
capture_heapdump
ssl_poke
compress_data
exit $RETCODE