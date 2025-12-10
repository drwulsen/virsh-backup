#!/bin/bash
#set -x
backupdir="/mnt/data/backup"
separator="################"
declare -a domain_networks all_domains

function dumpxml () {
	virsh dumpxml "$domain" > "$domain_xml"
}
function dumpnetxml () {
	readarray -t domain_networks < <(virsh domiflist "$domain" | grep -i 'network' | awk ' {print $3} ')
	for network in "${domain_networks[@]}"; do
		virsh net-dumpxml "$network" >> "$net_xml"
	done
}
function virsh-backup () {
	virsh backup-begin "$domain"
}
function domjobcomplete () {
	while [ "$(virsh domjobinfo "$domain" | grep 'Job type:' | awk '{ print $3 }')" != "None" ]; do
		echo -e "Backup of domain: $domain is running...\t$(date)"
		sleep 5
	done
	virsh domjobinfo --completed "$domain" >> "$logfile"
	job_complete="$(grep --count --ignore-case --max-count=1 'completed' "${logfile}")"
	job_isbackup="$(grep --count --ignore-case --max-count=1 'backup' "${logfile}")"
	if [ "$job_isbackup" -gt 0 ] && [ "$job_complete" -gt 0 ];then
		echo "Backup finished at $(date)" >> "$logfile"
	else
		echo "Backup FAILED at $(date)" >> "$logfile"
	fi
}

readarray -t all_domains < <(virsh list --all | tr -s ' ' | grep -E '^ ([[:digit:]]* |- )')
for domainline in "${all_domains[@]}"; do
	domain="$(echo "$domainline" | tr -s ' ' | awk '{ print $2 }' )"
	mkdir -p "${backupdir}/${domain}"
	domain_active="$(echo "$domainline" | grep --count --max-count=1 '^ [[:digit:]]* ')"
	readarray -t disks < <(virsh domblklist "$domain" | grep '/' | awk ' {print $2} ')
	logfile="${backupdir}/${domain}/virsh-${domain}"
	domain_xml="${backupdir}/${domain}/machine-${domain}.xml"
	net_xml="${backupdir}/${domain}/net-${domain}.xml"
	echo -e "$(date)\n$separator" | tee --append "$logfile" "$domain_xml" "$net_xml"
	dumpxml "$domain"
	dumpnetxml "$domain"
	if [ "$domain_active" -ne 0 ]; then
		virsh domjobinfo "$domain" > /dev/null
		epoch="$(date +%s)"
		epoch_trunc="${epoch::-2}"
		virsh-backup "$domain"
		domjobcomplete "$domain"
		for disk in "${disks[@]}"; do
			moveparams=(${disk}.${epoch_trunc}* ${backupdir}/${domain}/${disk##*/})
			mv "${moveparams[@]}"
		done
	else
		for disk in "${disks[@]}"; do
			cp -p "$disk" "${backupdir}/${domain}"
		done
	fi
done
