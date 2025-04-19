#!/bin/bash
#set -x  # Uncomment for debugging (enables trace mode for debugging each command execution)
set -euo pipefail
trap 'unraid_notify "Script terminated unexpectedly." "failure"' ERR

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# #   Script for restoring replication of a ZFS dataset locally or remotely using ZFS                                                       # #
# #   (Requires Unraid 6.12 or above)                                                                                                       # #
# #   By SystemSlactivist                                                                                                                   # #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

####################
# Configuration
####################

####################
# Dry Run Mode
####################
# Set this to "yes" to simulate the restoration process without making any actual changes.
# This is useful for testing and ensuring that the script is configured correctly.
# Set this to "no" to perform the actual restoration.
dry_run="yes"

####################
# Dataset(s) to Restore
####################
# This is an array where each entry is a ZFS dataset that you want to restore.
# You can specify a parent dataset (which will restore it and all its children)
# or a specific child dataset if you want to restore only that.
# Example:
#   - To restore a parent dataset and all its children: ("pool1/dataset1")
#   - To restore only a specific child dataset: ("pool1/dataset1/child1")
# In this example, we are restoring a dataset named "appdata" from the "cache" pool.
source_datasets=("cache/appdata")

####################
# Backup to Restore From
####################
# This is the ZFS dataset or pool where your backup (snapshot) is stored.
# You should replace this with the location of your backup dataset.
# Example:
#   - If your backup is stored in "pool1" and it is under the parent dataset "dataset1" set this to "pool1/dataset1"
# In this example, we are restoring from the "replication" dataset in the "vault" pool.
destination_dataset="vault/replication"

####################
# Remote Server Configuration
# Configure settings if you plan to replicate data from a remote server.
####################
destination_remote="no"  # Set to "no" for local, "yes" for remote
remote_user="root"       # Remote server user (Unraid server typically uses "root")
remote_server="10.10.20.197" # Remote server's name or IP address

####################
# Main Script
####################

####################
# Function: unraid_notify
# Wrapper for Unraid's notification system.
####################
unraid_notify() {
    local message="$1"
    local flag="$2"
    local severity="normal"

    if [[ $flag == "success" ]]; then
        severity="normal"
    elif [[ $flag == "failure" ]]; then
        severity="warning"
    fi

    /usr/local/emhttp/webGui/scripts/notify -s "Restore Notification" -d "$message" -i "$severity"
}

####################
# Function: run_restore
# Executes a command or prints it for a dry run.
####################
run_restore() {
    if [ "$dry_run" = "yes" ]; then
        echo "DRY RUN: $*"
    else
        eval "$*"
    fi
}

####################
# Function: select_snapshot
# Allows user to select a specific snapshot to restore.
####################
select_snapshot() {
    # 'dest' must be set in the caller (restore_snapshot)
    local snaps
    snaps=$(zfs list -t snapshot -o name -s creation -H "${dest}")
    echo "Available snapshots for ${source_dataset} (in ${dest}):"
    echo "$snaps"
    read -r -p "Enter the snapshot to restore (or press Enter to restore the latest): " selected_snapshot
    if [ -z "$selected_snapshot" ]; then
        selected_snapshot=$(echo "$snaps" | tail -n1)
        echo "No snapshot selected. Defaulting to the latest snapshot: $selected_snapshot"
    fi
    echo "Selected snapshot: $selected_snapshot"
    latest_snapshot="$selected_snapshot"
}

####################
# Function: check_existing_dataset
# Checks if the source dataset already exists before restoring.
####################
check_existing_dataset() {
    if zfs list -H "${source_dataset}" &>/dev/null; then
        echo "WARNING: The destination dataset ${source_dataset} already exists."
        read -r -p "Do you want to overwrite it? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            unraid_notify "Restoration aborted by user. ${source_dataset} already exists." "failure"
            exit 1
        fi
    fi
}

####################
# Function: restore_snapshot
# Restores the dataset from the selected snapshot, either locally or remotely.
####################
restore_snapshot() {
    # single base path for both local and remote
    local dest="${destination_dataset}/${source_dataset//\//_}"
    local remote_target="${remote_user}@${remote_server}:${dest}"

    # verify backup exists
    if ! zfs list -H "${dest}" &>/dev/null; then
        unraid_notify "Backup ${dest} not found." "failure"
        echo "ERROR: Backup ${dest} not found."
        return 1
    fi

    select_snapshot
    check_existing_dataset

    # Local restore
    if [[ "$destination_remote" == "no" ]]; then
        if [[ "$dry_run" == "yes" ]]; then
            echo "DRY RUN: zfs send \"${latest_snapshot}\" | zfs receive -F \"${dest}\""
        else
            echo "Restoring locally → ${dest}"
            if ! run_restore zfs send "${latest_snapshot}" \
                 | run_restore zfs receive -F "${dest}"; then
                unraid_notify "Local restore failed: ${source_dataset}" "failure"
                return 1
            fi
            unraid_notify "Local restore succeeded: ${source_dataset}" "success"
        fi
    fi

    # Remote restore
    if [[ "$destination_remote" == "yes" ]]; then
        if [[ "$dry_run" == "yes" ]]; then
            echo "DRY RUN: zfs send \"${latest_snapshot}\" | ssh ${remote_target} zfs receive -F \"${dest}\""
        else
            echo "Restoring remotely → ${remote_target}"
            ssh "${remote_user}@${remote_server}" "zfs create -p \"${dest}\"" 2>/dev/null || true
            if ! run_restore zfs send "${latest_snapshot}" \
                 | run_restore ssh "${remote_user}@${remote_server}" zfs receive -F "${dest}"; then
                unraid_notify "Remote restore failed: ${source_dataset}" "failure"
                return 1
            fi
            unraid_notify "Remote restore succeeded: ${source_dataset}" "success"
        fi
    fi

    return 0
}

####################
# Function: run_for_each_dataset
# Iterates over each defined dataset, performing restoration tasks (including children).
####################
run_for_each_dataset() {
    echo "Starting the restoration process for defined datasets."

    local final_status="success"
    local final_message="All datasets were restored successfully."

    for source_dataset in "${source_datasets[@]}"; do
        echo "Processing dataset: ${source_dataset}"
        echo "  backup location: ${destination_dataset}/${source_dataset//\//_}"

        if ! restore_snapshot; then
            final_status="failure"
            final_message="One or more datasets failed to restore."
        fi

        # if parent has children
        local dest="${destination_dataset}/${source_dataset//\//_}"
        if zfs list -H -r -o name "${dest}" | grep -q "^${dest}/"; then
            local child_list
            child_list=$(zfs list -H -r -o name "${dest}" | grep "^${dest}/")

            for child in $child_list; do
                local child_relative="${child#${dest}/}"
                local child_source="${source_dataset}/${child_relative//_//}"
                local child_snapshot
                child_snapshot=$(zfs list -t snapshot -o name -s creation -H "${child}" | tail -n1)
                local child_dest="${dest}/${child_relative}"
                local child_remote_target="${remote_user}@${remote_server}:${child_dest}"

                # LOCAL child
                if [[ "$destination_remote" == "no" ]]; then
                    if [[ "$dry_run" == "yes" ]]; then
                        echo "DRY RUN: zfs send \"${child_snapshot}\" | zfs receive -F \"${child_dest}\""
                    else
                        run_restore zfs send "${child_snapshot}" \
                          | run_restore zfs receive -F "${child_dest}"
                        unraid_notify "Local child restore succeeded: ${child_source}" "success"
                    fi
                fi

                # REMOTE child
                if [[ "$destination_remote" == "yes" ]]; then
                    if [[ "$dry_run" == "yes" ]]; then
                        echo "DRY RUN: zfs send \"${child_snapshot}\" | ssh ${child_remote_target%:*} zfs receive -F \"${child_dest}\""
                    else
                        ssh "${remote_user}@${remote_server}" "zfs create -p \"${child_dest%/*}\"" 2>/dev/null || true
                        run_restore zfs send "${child_snapshot}" \
                          | run_restore ssh "${remote_user}@${remote_server}" zfs receive -F "${child_dest}"
                        unraid_notify "Remote child restore succeeded: ${child_source}" "success"
                    fi
                fi
            done
        fi
    done

    if [[ "$final_status" == "success" ]]; then
        unraid_notify "$final_message" "success"
        echo "SUMMARY: $final_message"
    else
        unraid_notify "$final_message" "failure"
        echo "SUMMARY: $final_message"
    fi
}

# Run restoration for each dataset
run_for_each_dataset