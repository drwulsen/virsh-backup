#!/bin/bash
# virsh-backup.sh
# Script to hot-backup running libvirt guests and cold-backup stopped ones.
# Just set the desired backup target and run the script.
# A subdirectory named after the corresponding domain will be created in your target directory.
# It will dump the domains XML and the domains networks XML there,
# then issue 'virsh backup-begin' on each domain and move the produced backup there as well.
# For non-running machines, it will simply do the XML dumps as above, then copy the disk image(s) there.
#set -x
LANG_SYS="$LANG"
LANG="C"	# virsh domjobcomplete is later parsed as string, so language matters
backupdir="/mnt/data/vm_backup"	# target base directory for all domain backups
declare -a all_domains disks domain_networks
declare domain_active duration timestamp_begin timestamp_end
function _chain () {
	backup ||	quit "ERROR: Backup of running domain $domain FAILED at $(date)"
	moveimages || quit "ERROR: Error copying files/images to backup destination"
	dumpxml || quit "ERROR: failed to dump domain xml for $domain"
	dumpnetxml || quit "ERROR: failed to dump network xml for $domain"
}
function backup () {	# start the actual backup command
	mkdir -p "${backupdir}/${domain}"
	if [ "$domain_active" -ne 0 ]; then
		log "INFO: Backup of running domain $domain started at $(date)" 'log'
		timestamp_begin="$(date +%s)"
		timestamp_trunc="${timestamp_begin::-2}"	# cut 2 digits off the epoch for later locating the right file
		virsh domjobinfo "$domain" > /dev/null	# clear any previous message
		virsh backup-begin "$domain" > /dev/null	# this basically forks off into the background, no return value
		domjobcomplete || return 1
return 0
	fi
}
function checkroot () {	# check if we are root (works via sudo, too) - otherwise exit
	uid="$(id -u)"
	if [ "$uid" -ne 0 ]; then
		return "$uid"
	else
		return 0
	fi
}
function domjobcomplete () {	# check if our backup job has finished (yet), here having set LANG is important
	while [ "$(virsh domjobinfo "$domain" | grep 'Job type:' | awk '{ print $3 }')" != 'None' ]; do
		sleep 5
	done
	# lucky for us, the output of 'virsh domjobinfo domain' does reset after being printed one time
	virsh domjobinfo --completed "$domain" >> "$logfile"
	job_complete="$(grep --count --ignore-case --max-count=1 'completed' "${logfile}")"
	job_isbackup="$(grep --count --ignore-case --max-count=1 'backup' "${logfile}")"
	if [[ "$job_isbackup" -gt 0 && "$job_complete" -gt 0 ]];then
		timestamp_end="$(date +%s)"
		duration="$(( (timestamp_end - timestamp_begin)/60 ))"
		log "SUCCESS: Backup of domain $domain finished in ${duration}minute(s) at $(date)" 'log'
		return 0
	else
		return 1
	fi
}
function dumpnetxml () {	# dump domain network(s) xml to file
	readarray -t domain_networks < <(virsh domiflist "$domain" | grep -i 'network' | awk ' {print $3} ')
	for network in "${domain_networks[@]}"; do
		virsh net-dumpxml "$network" > "$net_xml" || return 1
	done
	return 0
}
function dumpxml () {	# dump domain xml to file
	virsh dumpxml "$domain" > "$domain_xml" || return 1
	return 0
}
function log () {	# log message to stdout, optional log to syslog
	echo "$1"
	if [ "$2" = 'log' ]; then
		logger -t "rdiff-backup-script" "$1"
	fi
}
function moveimages () {
	if [ "$domain_active" -ne 0 ]; then
	for disk in "${disks[@]}"; do
		moveparams=("${disk}.${timestamp_trunc}"* "${backupdir}/${domain}/${disk##*/}")
		if ! mv "${moveparams[@]}"; then
			log "ERROR: Error moving file ${disk}.${timestamp_trunc}\* to ${backupdir}/${domain}/${disk##*/}" 'log'
			return 1
		else
			log "SUCCESS: Moved ${disk}.${timestamp_trunc}\* to ${backupdir}/${domain}/${disk##*/}" 'log'
			return 0
		fi
	done
else
	log "INFO: Backup of stopped domain $domain started at $(date)" 'log'
	for disk in "${disks[@]}"; do
		if ! cp -p "$disk" "${backupdir}/${domain}/"; then
			log "ERROR: Error copying stopped domain file $disk to ${backupdir}/${domain}/" 'log'
			return 1
		else
			return 0
		fi
	done
	fi
}
function quit () {	# exit point with message and errorlevel
	if [ -n "$2" ]; then
		exitcode='1'
	else
		exitcode="$2"
	fi
	log "$1" "log"
	LANG="$LANG_SYS"
	exit "$exitcode"
}
# actual control flow begins here
# get all domain names, check which ones are running (hot backup) and which ones are off (cold backup)
# we depend on the exact output formatting of virsh, which is terrible but the best i could do
checkroot || quit "ERROR: Please run this script as root"
readarray -t all_domains < <(virsh list --all | tr -s ' ' | grep -E '^ ([[:digit:]]* |- )')
if [ "${#all_domains[@]}" -eq 0 ]; then	# quit if there's no domains
	quit "INFO: No domains to backup, quitting" "0"
fi
for domainline in "${all_domains[@]}"; do	# loop through all domains and call _chain
	domain="$(echo "$domainline" | tr -s ' ' | awk '{ print $2 }' )"
	domain_active="$(echo "$domainline" | grep --count --max-count=1 '^ [[:digit:]]* ')"
	readarray -t disks < <(virsh domblklist "$domain" | grep '/' | awk ' {print $2} ')
	logfile="${backupdir}/${domain}/virsh-${domain}"
	domain_xml="${backupdir}/${domain}/machine-${domain}.xml"
	net_xml="${backupdir}/${domain}/net-${domain}.xml"
	_chain
done
LANG="$LANG_SYS"
exit 0
