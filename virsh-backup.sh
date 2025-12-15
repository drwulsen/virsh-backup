#!/bin/bash

# virsh-backup.sh
# Script to hot-backup running libvirt guests and cold-backup stopped ones.
# Just set the desired backup target and run the script.
# A subdirectory named after the corresponding domain will be created in your target directory.
# It will dump the domains XML and the domains networks XML there,
# then issue 'virsh backup-begin' on each domain and move the produced backup there as well.
# For non-running machines, it will simply do the XML dumps as above, then copy the disk image(s) there.

# check if we are root (works via sudo, too) - otherwise exit
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Please run the backup script as root (UID 0)for proper access permissions"
  exit 1
fi

LANG_SYS="$LANG"
LANG="C"	# virsh domjobcomplete is later parsed as string, so language matters
backupdir="/mnt/data/backup"	# target base directory for all domain backups
separator="################"	# fancy decoration for output files
declare -a domain_networks all_domains
declare -i timestamp_begin

function dumpxml () {	# dump domain xml to file
	virsh dumpxml "$domain" > "$domain_xml" || quit "ERROR: failed to dump domain xml for $domain"
}
function dumpnetxml () {	# dump domain network(s) xml to file
	readarray -t domain_networks < <(virsh domiflist "$domain" | grep -i 'network' | awk ' {print $3} ')
	for network in "${domain_networks[@]}"; do
		virsh net-dumpxml "$network" >> "$net_xml" || quit "ERROR: failed to dump network xml for $domain"
	done
}
function virsh-backup () {	# start the actual backup command
	virsh backup-begin "$domain" > /dev/null	# this basically forks off into the background, no return value
	echo -e "INFO: Backup of domain $domain started"
	timestamp_begin="$(date +%s)"
}
function domjobcomplete () {	# check if our backup job has finished (yet), here having set LANG is important
	while [ "$(virsh domjobinfo "$domain" | grep 'Job type:' | awk '{ print $3 }')" != "None" ]; do
		sleep 5
	done
	# lucky for us, the output of 'virsh domjobinfo domain' does reset after being printed one time
	virsh domjobinfo --completed "$domain" >> "$logfile"
	job_complete="$(grep --count --ignore-case --max-count=1 'completed' "${logfile}")"
	job_isbackup="$(grep --count --ignore-case --max-count=1 'backup' "${logfile}")"
	if [ "$job_isbackup" -gt 0 ] && [ "$job_complete" -gt 0 ];then
		timestamp_end="$(date +%s)"
		duration="$(( (timestamp_end - timestamp_begin)/60 ))"
		echo "SUCCESS: Backup of domain $domain finished in ${duration}minutes at $(date)" #>> "$logfile"
	else
		echo "ERROR: Backup of domain $domain FAILED at $(date)" >> "$logfile"
		quit "ERROR: Backup of domain $domain FAILED, see $logfile for more info"
	fi
}
function quit () {
	# throw a message to syslog and stderr, reset LANG and terminate
	message="$1"
	logger -s -p 'user.error' "$message"
	echo "$message" >> "$logfile"
	LANG="$LANG_SYS"
	exit 1
}

# actual control flow begins here
# get all domain names, check which ones are running (hot backup) and which ones are off (cold backup)
# we depend on the exact output formatting of virsh, which is terrible but the best i could do
readarray -t all_domains < <(virsh list --all | tr -s ' ' | grep -E '^ ([[:digit:]]* |- )')

if [ "${#all_domains[@]}" -eq 0 ]; then
	quit "No domains to backup, quitting"
fi
for domainline in "${all_domains[@]}"; do
	domain="$(echo "$domainline" | tr -s ' ' | awk '{ print $2 }' )"
	mkdir -p "${backupdir}/${domain}"
	domain_active="$(echo "$domainline" | grep --count --max-count=1 '^ [[:digit:]]* ')"
	readarray -t disks < <(virsh domblklist "$domain" | grep '/' | awk ' {print $2} ')
	logfile="${backupdir}/${domain}/virsh-${domain}"
	domain_xml="${backupdir}/${domain}/machine-${domain}.xml"
	net_xml="${backupdir}/${domain}/net-${domain}.xml"
	dumpxml "$domain"
	dumpnetxml "$domain"
	if [ "$domain_active" -ne 0 ]; then
		virsh domjobinfo "$domain" > /dev/null	# clear any previous message
		timestamp_trunc="${timestamp_begin::-2}"	# cut 2 digits off the epoch for later locating the right file
		virsh-backup "$domain"
		domjobcomplete "$domain"
		for disk in "${disks[@]}"; do
			moveparams=("${disk}.${timestamp_trunc}"* "${backupdir}/${domain}/${disk##*/}")
			mv "${moveparams[@]}" || quit "ERROR: Error moving file ${disk}.${timestamp_trunc}'*' to ${backupdir}/${domain}/${disk##*/}"
		done
	else
		for disk in "${disks[@]}"; do
			cp -p "$disk" "${backupdir}/${domain}" || quit "ERROR: Error copying file $disk to ${backupdir}/${domain}"
		done
	fi
done
