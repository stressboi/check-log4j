#! /bin/sh
#
# Originally written by Jan Schaumann
# <jans@yahooinc.com> in December 2021.
#
# This script attempts to determine whether the host
# it runs on is likely to be vulnerable to log4j RCE
# CVE-2021-44228.
#
# Copyright 2021 Yahoo Inc.
# 
# Licensed under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in
# compliance with the License.  You may obtain a copy of
# the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in
# writing, software distributed under the License is
# distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
# CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing
# permissions and limitations under the License.


set -eu
IFS="$(printf '\n\t')"

umask 077

###
### Globals
###

# set a date format so we can output a date for each line
DATETIME=$(date '+%Y-%m-%d %H:%M:%S %Z')
# what's the IP address of the machine?
IPADD=$(hostname -I)
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin

# We broadly only care about versions >= 2.16.
# 1.x has been determined not to be vulnerable, and we
# boldly hope any version after 2.16 (including new
# major versions, if any) will not regress.
MAJOR_WANTED="2"
MINOR_MINIMUM="16"

# log4j-2.16.0 _disables_ JNDI lookups, but leaves in
# place the class, meaning it could be enabled if
# log4j2.enableJndi=true.
KNOWN_DISABLED="log4j-core-${MAJOR_WANTED}.${MINOR_MINIMUM}"
FATAL_SETTING="-Dlog4j2.enableJndi=true"
FATAL_CLASS="JndiLookup.class"

_TMPDIR=""
CHECK_JARS=""
ENV_VAR_SET="no"
FIX="no"
FIXED=""
PROGNAME="${0##*/}"
VERSION="1.6"
FOUND_JARS=""
SEARCH_PATHS=""
SKIP=""
SEEN_JARS=""
SUSPECT_CLASSES=""
SUSPECT_JARS=""
SUSPECT_PACKAGES=""
UNZIP="$(which unzip 2>/dev/null || true)"
VERBOSITY=0

LOGPREFIX="${DATETIME} ${IPADD} ${PROGNAME} ${VERSION} ${HOSTNAME:-"localhost"}"

###
### Functions
###


cdtmp() {
	if [ -z "${_TMPDIR}" ]; then
		_TMPDIR=$(mktemp -d ${TMPDIR:-/tmp}/${PROGNAME}.XXXX)
	fi
	cd "${_TMPDIR}"
}

checkFilesystem() {
	local class=""
	local classes=""
	local okVersion=""
	local newjars=""

	if expr "${SKIP}" : ".*files" >/dev/null; then
		verbose "Skipping files check." 2
		return
	fi

	verbose "Searching for jars/wars on the filesystem..." 3
	newjars=$(find "${SEARCH_PATHS:-/}" -type f -name '*.[jw]ar' 2>/dev/null || true)
	FOUND_JARS="${FOUND_JARS:+${FOUND_JARS} }${newjars}"

	verbose "Searching for ${FATAL_CLASS} on the filesystem..." 3
	classes=$(find "${SEARCH_PATHS:-/}" -type f -name "${FATAL_CLASS}" 2>/dev/null || true)

	for class in ${classes}; do
		okVersion="$(checkFixedVersion "${class}")"
		if [ -z "${okVersion}" ]; then
			log "Possibly vulnerable class ${class}."
			SUSPECT_CLASSES="${SUSPECT_CLASSES:+${SUSPECT_CLASSES} }${class}"
		fi
	done
}

checkFixedVersion() {
	local file="${1}"
	local ver=""
	local mgrClass=""
	local suffix="${file##*.}"
	local dir=""

	set +e
	if [ x"${suffix}" = x"jar" -o x"${suffix}" = x"war" ]; then
		if [ -z "${UNZIP}" ]; then
			warn "Unable to check if ${suffix} contains a fixed version since unzip(1) is miggin."
			return
		fi
		verbose "Checking for fixed classes in '${file}'..." 6

		mgrClass="$(${UNZIP} -l "${file}" | awk '/JndiManager.class$/ { print $NF; }')"
	if [ -n "${mgrClass}" ]; then
		cdtmp
			${UNZIP} -o -q "${file}" "${mgrClass}" 2>/dev/null
		fi
	elif [ x"${suffix}" = x"class" ]; then
		# If we find the fatal class outside of a jar, let's guess that
		# there might be an accompanying JndiManager.class nearby...
		mgrClass="${file%/*}/../net/JndiManager.class"
	fi

		if [ -f "${mgrClass}" ]; then
			if grep -q 'log4j2.enableJndi' "${mgrClass}" ; then
				echo "log4j2.enableJndi found"
			fi
		fi
	set -e
}

checkInJar() {
	local jar="${1}"
	local needle="${2}"
	local pid="${3}"
	local parent="${4:-""}"
	local msg=""
	local match=""
	local flags=""
	local okVersion=""
	local rval=0

	local thisJar="${parent:+${parent}:}${jar}"
	for j in $(echo "${SEEN_JARS}" | tr ' ' '\n'); do
		if [ x"${j}" = x"${thisJar}" ]; then
			verbose "Skipping already seen archive '${thisJar}'..." 6
			return
		fi
	done
	SEEN_JARS="${SEEN_JARS:+${SEEN_JARS} }${thisJar}"

	verbose "Checking for '${needle}' inside of ${jar}..." 5

	set +e
	if [ -n "${UNZIP}" ]; then
		${UNZIP} -l "${jar}" | grep -q "${needle}"
	else
		warn "unzip(1) not found, trying to grep..."
		grep -q "${needle}" "${jar}"
	fi
	rval=$?
	set -e

	if [ ${rval} -eq 0 ]; then
		if [ -n "${parent}" ]; then
			msg=" (inside of ${parent})"
		fi
		if [ x"${jar}" != x"${pid}" ] && expr "${pid}" : "[0-9]*$" >/dev/null; then
			if checkPid "${pid}" ; then
				flags="JNDI Lookups enabled via command-line flags"
			fi
			msg="${msg} used by process ${pid}"
		fi

		okVersion="$(checkFixedVersion "${jar}")"

		match="$(echo "${jar}" | sed -n -e "s|.*/\(${KNOWN_DISABLED}[0-9.]*.jar\)$|\1|p")"
		if [ -n "${match}" -o -n "${okVersion}" ]; then
			if [ -n "${flags}" ]; then
				log "Normally non-vulnerable archive '${jar}'${msg} found, but ${flags}!"
			fi
			verbose "Allowing archive with known disabled JNDI Lookup." 6
			return
		fi
		if [ -z "${flags}" ]; then
			log "Possibly vulnerable archive '${jar}'${msg}."
		fi
		SUSPECT_JARS="${SUSPECT_JARS} ${thisJar}"
	fi
}

checkJars() {
	local found jar jarjar msg pid

	if [ -z "${CHECK_JARS}" ]; then
		findJars
	fi

	if [ -z "${FOUND_JARS}" ]; then
		return
	fi

	verbose "Checking all found jars and wars..." 2

	if [ -z "${UNZIP}" ]; then
		warn "unzip(1) not found, unable to peek into jars inside of jar!"
	fi
	for found in ${FOUND_JARS}; do
		pid="${found%%--*}"
		jar="${found#*--}"

		if [ -n "${UNZIP}" ]; then
			jarjar="$(${UNZIP} -l "${jar}" | awk '/^ .*log4j.*[jw]ar$/ { print $NF; }')"
			if [ -n "${jarjar}" ]; then
				extractAndInspect "${jar}" "${jarjar}" ${pid}
			fi
		fi

		checkInJar "${jar}" "${FATAL_CLASS}" "${pid}"
	done

	if [ -n "${SUSPECT_JARS}" ]; then
		echo
	fi
}

checkOnlyGivenJars() {
	verbose "Checking only given jars..." 1
	FOUND_JARS="${CHECK_JARS}"
	checkJars
}

checkRpms() {
	verbose "Checking rpms..." 4

	local pkg version

	for pkg in $(rpm -qa --queryformat '%{NAME}--%{VERSION}\n' | grep log4j); do
		version="${pkg##*--}"
		if ! isFixedVersion "${version}"; then
			# Squeeze '--' so users don't get confused.
			pkg="$(echo "${pkg}" | tr -s -)"
			SUSPECT_PACKAGES="${SUSPECT_PACKAGES} ${pkg}"
		fi
	done
}

checkPackages() {
	if expr "${SKIP}" : ".*packages" >/dev/null; then
		verbose "Skipping package check." 2
		return
	fi

	verbose "Checking for vulnerable packages..." 2

	if [ x"$(which rpm 2>/dev/null)" != x"" ]; then
		checkRpms
	fi
}

checkPid() {
	local pid="${1}"
	verbose "Checking process ${pid} for command-line flags..." 6

	ps -www -q "${pid}" -o command= | grep -q -- "${FATAL_SETTING}"
}

checkProcesses() {
	local jars
	if expr "${SKIP}" : ".*processes" >/dev/null; then
		verbose "Skipping process check." 2
		return
	fi

	verbose "Checking running processes..." 3
	local lsof="$(which lsof 2>/dev/null || true)"
	if [ -z "${lsof}" ]; then
		jars="$(ps -o pid,command= -wwwax | awk '/[jw]ar$/ { print $1 "--" $NF; }' | uniq)"
	else
		jars="$(${lsof} -c java | awk '/REG.*[jw]ar$/ { print $2 "--" $NF; }' | uniq)"
	fi
	FOUND_JARS="${FOUND_JARS:+${FOUND_JARS} }${jars}"
}

cleanup() {
	if [ -n "${_TMPDIR}" ]; then
		rm -fr "${_TMPDIR}"
	fi
}

extractAndInspect() {
	local jar="${1}"
	local jarjar="${2}"
	local pid="${3}"
	local f

	verbose "Extracting ${jar} to look inside jars inside of jars..." 5

	cdtmp
	unzip -o -q "${jar}" ${jarjar}
	for f in ${jarjar}; do
		checkInJar "${f}" "${FATAL_CLASS}" ${pid} "${jar}"
	done
}

findJars() {
	verbose "Looking for jars..." 2
	checkProcesses
	checkFilesystem
}

fixJars() {
	verbose "Trying to fix suspect jars..." 3
	local jar

	for jar in ${SUSPECT_JARS}; do
		if expr "${jar}" : ".*[jw]ar:" >/dev/null; then
			warn "Unable to fix '${jar} -- it's a jar inside another jar."
			continue
		fi

		verbose "Fixing ${jar}..." 4
		cp "${jar}" "${jar}.bak" && \
			zip -q -d "${jar}" org/apache/logging/log4j/core/lookup/${FATAL_CLASS} && \
			FIXED="${FIXED} ${jar}.bak"
	done
}

isFixedVersion () {
	local version="${1}"
	local major minor

	major="${version%%.*}"  # 2.15.0 => 2
	minor="${version#*.}"   # 2.15.0 => 15.0
	minor="${minor%%.*}"   # 15.0 => 15

	# NaN => unknown
	if ! expr "${major}" : "[0-9]*$" >/dev/null; then
		return 1
	fi
	if ! expr "${minor}" : "[0-9]*$" >/dev/null; then
		return 1
	fi

	if [ ${major} -lt ${MAJOR_WANTED} -o ${minor} -ge ${MINOR_MINIMUM} ]; then
		return 0
	fi

	return 1
}

log() {
	msg="${1}"
	echo "${LOGPREFIX}: ${msg}"
}

log4jcheck() {
	verbose "Running all checks..." 1

	checkPackages
	checkJars

	if [ x"${FIX}" = x"yes" ]; then
		fixJars
	fi
}

usage() {
	cat <<EOH
Usage: ${PROGNAME} [-fhv] [-j jar] [-s skip] [-p path]
	-f       attempt to fix the issue by applїing some mitigations
	-h       print this help and exit
	-j jar   check only this jar
        -p path  limit filesystem traversal to this directory
        -s skip  skip these checks (files, packages, processes)
	-v       be verbose
EOH
}

verbose() {
	local readonly msg="${1}"
	local level="${2:-1}"
	local i=0

	if [ "${level}" -le "${VERBOSITY}" ]; then
		while [ ${i} -lt ${level} ]; do
			printf "=" >&2
			i=$(( ${i} + 1 ))
		done
		echo "> ${msg}" >&2
	fi
}

verdict() {
	local pkg found

	if [ -z "${SUSPECT_JARS}" -a -z "${SUSPECT_PACKAGES}" -a -z "${SUSPECT_CLASSES}" ]; then
		log "No obvious indicators of vulnerability found."
		exit 0
	fi

	if [ -n "${SUSPECT_JARS}" -a x"${FIX}" = x"yes" ]; then
		echo "The following archives were found to include '${FATAL_CLASS}':"
		echo "${SUSPECT_JARS# *}" | tr ' ' '\n'
		echo

		echo "I tried to fix them by removing that class."
		if [ -n "${FIXED}" ]; then
			echo "Backup copies of the following are left on the system:"
			echo "${FIXED}"
			echo
			echo "Remember to restart any services using these."
			echo
		else
			echo "Looks like I was unable to do that, though."
		fi
		echo
	fi

	if [ -n "${SUSPECT_PACKAGES}" ]; then
		echo "The following packages might still be vulnerable:"
		echo "${SUSPECT_PACKAGES}"
		echo
	fi
}

warn() {
	msg="${1}"
	echo "${LOGPREFIX}: ${msg}" >&2
}

###
### Main
###

trap 'cleanup' 0

while getopts 'fhj:s:p:v' opt; do
	case "${opt}" in
		f)
			FIX="yes"
		;;
		h\?)
			usage
			exit 0
			# NOTREACHED
		;;
		j)
			f="$(cd "${OPTARG%/*}" && pwd)/${OPTARG##*/}"
			CHECK_JARS="${CHECK_JARS:+${CHECK_JARS} }${f}"
		;;
		p)
			SEARCH_PATHS="${SEARCH_PATHS:+${SEARCH_PATHS} }$(cd "${OPTARG}" && pwd)/."
		;;
		s)
			SKIP="${SKIP} ${OPTARG}"
		;;
		v)
			VERBOSITY=$(( ${VERBOSITY} + 1 ))
		;;
		*)
			usage
			exit 1
			# NOTREACHED
		;;
	esac
done
shift $(($OPTIND - 1))

if [ $# -gt 0 ]; then
	usage
	exit 1
	# NOTREACHED
fi

if [ -z "${CHECK_JARS}" ]; then
	log4jcheck
else
	checkOnlyGivenJars
fi
verdict

exit 1
