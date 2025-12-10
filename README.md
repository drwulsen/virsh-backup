# virsh-backup
Script to hot-backup running libvirt guests and cold-backup stopped ones.
Just set the desired backup target and run the script.
It will dump the domains XML and the domains networks XML to your target,
then issue 'virsh backup-begin' on each domain and move the produced backup files to your target.

For non-running machines, it will simply do the XML dumps as above, then copy the disk image(s) to your target.

That's basically all, it is nude, rude, crude - but worksforme™
