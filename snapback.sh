#!/bin/bash
# snapback.sh 1.3
# Simple script to create regular snapshot-based backups for Citrix Xenserver
# Mark Round, scripts@markround.com
# http://www.markround.com/snapback
#
# 1.3 : Added basic lockfile
# 1.2 : Tidied output, removed VDIs before deleting snapshots and templates
# 1.1 : Added missing force=true paramaters to snapshot uninstall calls.

#
# Variables
#

# Temporary snapshots will be use this as a suffix
SNAPSHOT_SUFFIX=snapback
# Temporary backup templates will use this as a suffix
TEMP_SUFFIX=newbackup
# Backup templates will use this as a suffix, along with the date
BACKUP_SUFFIX=backup
# What day to run weekly backups on
WEEKLY_ON="Sun"
# What day to run monthly backups on. These will run on the first day
# specified below of the month.
MONTHLY_ON="Sun"
# Temporary file
TEMP=/tmp/snapback.$$
# UUID of the destination SR for backups

LOCKFILE=/tmp/snapback.lock

if [ -f $LOCKFILE ]; then
        echo "Lockfile $LOCKFILE exists, exiting!"
        exit 1
fi

touch $LOCKFILE

#
# Don't modify below this line
#

# Date format must be %Y%m%d so we can sort them
BACKUP_DATE=$(date +"%Y%m%d%H%S")

# Quick hack to grab the required paramater from the output of the xe command
function xe_param()
{
	PARAM=$1
	while read DATA; do
		LINE=$(echo $DATA | egrep "$PARAM")
		if [ $? -eq 0 ]; then
			echo "$LINE" | awk 'BEGIN{FS=": "}{print $2}'
		fi
	done

}

# Deletes a snapshot's VDIs before uninstalling it. This is needed as 
# snapshot-uninstall seems to sometimes leave "stray" VDIs in SRs
function delete_snapshot()
{
	DELETE_SNAPSHOT_UUID=$1
	# Now we can remove the snapshot itself
	echo "Removing snapshot with UUID : $DELETE_SNAPSHOT_UUID"
	xe snapshot-uninstall uuid=$DELETE_SNAPSHOT_UUID force=true
}

# See above - templates also seem to leave stray VDIs around...
function delete_template()
{
	DELETE_TEMPLATE_UUID=$1
	for VDI_UUID in $(xe vbd-list vm-uuid=$DELETE_TEMPLATE_UUID empty=false | xe_param "vdi-uuid"); do
        	echo "Deleting template VDI : $VDI_UUID"
        	xe vdi-destroy uuid=$VDI_UUID
	done

	# Now we can remove the template itself
	echo "Removing template with UUID : $DELETE_TEMPLATE_UUID"
	xe template-uninstall template-uuid=$DELETE_TEMPLATE_UUID force=true
}



echo "=== Snapshot backup started at $(date) ==="
echo " "

# Get all running VMs
# todo: Need to check this works across a pool
RUNNING_VMS=$(xe vm-list power-state=running is-control-domain=false | xe_param uuid)

for VM in $RUNNING_VMS; do
	VM_NAME="$(xe vm-list uuid=$VM | xe_param name-label)"

	# Useful for testing, if we only want to process one VM
	#if [ "$VM_NAME" != "testvm" ]; then
	#	continue
	#fi

	echo " "
	echo "== Backup for $VM_NAME started at $(date) =="
	echo "= Retrieving backup paramaters ="
	SCHEDULE=$(xe vm-param-get uuid=$VM param-name=other-config param-key=XenCenter.CustomFields.backup)	
	RETAIN=$(xe vm-param-get uuid=$VM param-name=other-config param-key=XenCenter.CustomFields.retain)	
	# Not using this yet, as there are some bugs to be worked out...
	# QUIESCE=$(xe vm-param-get uuid=$VM param-name=other-config param-key=XenCenter.CustomFields.quiesce)	

	if [[ "$SCHEDULE" == "" || "$RETAIN" == "" ]]; then
		echo "No schedule or retention set, skipping this VM"
		continue
	fi
	echo "VM backup schedule : $SCHEDULE"
	echo "VM retention : $RETAIN previous snapshots"

	# If weekly, see if this is the correct day
	if [ "$SCHEDULE" == "weekly" ]; then
		if [ "$(date +'%a')" == "$WEEKLY_ON" ]; then
			echo "On correct day for weekly backups, running..."
		else
			echo "Weekly backups scheduled on $WEEKLY_ON, skipping..."
			continue
		fi
	fi

	# If monthly, see if this is the correct day
	if [ "$SCHEDULE" == "monthly" ]; then
		if [[ "$(date +'%a')" == "$MONTHLY_ON" && $(date '+%e') -le 7 ]]; then
			echo "On correct day for monthly backups, running..."
		else
			echo "Monthly backups scheduled on 1st $MONTHLY_ON, skipping..."
			continue
		fi
	fi
	echo "== Backing up VM $VM =="
	SNAPSHOT_CMD="vm-snapshot"
        SNAPSHOT_UUID=$(xe $SNAPSHOT_CMD vm="$VM_NAME" new-name-label="$VM_NAME-$SNAPSHOT_SUFFIX-$BACKUP_DATE")
        echo "=== Created snapshot with UUID $SNAPSHOT_UUID ==="
        VM_NAME="$(xe vm-list uuid=$VM | xe_param name-label)"
        echo "== Checking Snapshots for $VM_NAME =="
        xe snapshot-list | grep "$VM_NAME-" | xe_param name-label | sort -n | head -n-$RETAIN > $TEMP
        while read OLD_SNAPSHOT; do
                OLD_SNAPSHOT_UUID=$(xe snapshot-list name-label="$OLD_SNAPSHOT" | xe_param uuid)
                echo "Removing $OLD_SNAPSHOT with UUID $OLD_SNAPSHOT_UUID"
                delete_snapshot $OLD_SNAPSHOT_UUID

        done < $TEMP
done


echo "=== Snapshot backup finished at $(date) ==="
rm $TEMP
rm $LOCKFILE
