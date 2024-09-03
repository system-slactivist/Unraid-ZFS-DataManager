#!/bin/bash
#set -x  # Uncomment for debugging (enables trace mode for debugging each command execution)

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# #   Script for restoring replication of a ZFS dataset locally or remotely using ZFS                                                       # #
# #   (Requires Unraid 6.12 or above)                                                                                                       # #
# #   By rjwaters147 using ChatGPT Data Analyzer                                                                                            # #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

####################
# Configuration
####################

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
# Dry Run Mode
####################
# Set this to "yes" to simulate the restoration process without making any actual changes.
# This is useful for testing and ensuring that the script is configured correctly.
# Set this to "no" to perform the actual restoration.
dry_run="yes"

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
    available_snapshots=$(zfs list -t snapshot -o name -s creation -H "${destination}")
    echo "Available snapshots for ${source_dataset}:"
    echo "$available_snapshots"
    read -r -p "Enter the snapshot to restore (or press Enter to restore the latest): " selected_snapshot
    if [ -z "$selected_snapshot" ]; then
        selected_snapshot=$(echo "$available_snapshots" | tail -n 1)
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
# Restores the dataset from the selected snapshot on the backup pool.
####################
restore_snapshot() {
    echo "Restoring dataset ${source_dataset} from ${destination}."

    # Verify that the destination dataset exists and has snapshots
    if ! zfs list -H "${destination}" &>/dev/null; then
        unraid_notify "Destination ${destination} does not exist. Cannot restore ${source_dataset}." "failure"
        log_message "ERROR: Destination ${destination} does not exist. Cannot restore ${source_dataset}."
        return 1
    fi

    # Select the snapshot to restore
    select_snapshot

    # Check if the source dataset already exists
    check_existing_dataset

    # Restore the dataset
    echo "Restoring ${source_dataset} from snapshot ${latest_snapshot}."
    if ! run_restore zfs send "${latest_snapshot}" | run_restore zfs receive -F "${source_dataset}"; then
        unraid_notify "Restoration failed for ${source_dataset}." "failure"
        log_message "ERROR: Restoration failed for ${source_dataset} from snapshot ${latest_snapshot}."
        return 1
    else
        unraid_notify "Restoration successful for ${source_dataset} from snapshot ${latest_snapshot}." "success"
        log_message "SUCCESS: Restoration successful for ${source_dataset} from snapshot ${latest_snapshot}."
    fi
}

####################
# Function: run_for_each_dataset
# Iterates over each defined dataset, performing restoration tasks sequentially.
# Sends a final summary notification after processing all datasets.
####################
run_for_each_dataset() {
    echo "Starting the restoration process for defined datasets."

    final_status="success"
    final_message="All datasets were restored successfully."

    for dataset in "${source_datasets[@]}"; do
        source_dataset="$dataset"
        destination="${destination_dataset}/${source_dataset//\//_}"

        echo "Processing dataset: ${dataset}"
        echo "destination=${destination}"

        # Restore the dataset from the backup
        if ! restore_snapshot; then
            final_status="failure"
            final_message="One or more datasets failed to restore."
            # Continue with the next dataset instead of exiting
        fi

        # If the specified dataset is a parent, restore its child datasets
        if zfs list -H -r -o name "${destination}" | grep -q "^${destination}/"; then
            child_datasets=$(zfs list -H -r -o name "${destination}" | grep "^${destination}/")
            for child in $child_datasets; do
                # Correctly construct the child_source_dataset path
                child_relative_path="${child#"${destination_dataset}"/}"  # Remove base destination dataset path
                child_source_dataset="${child_relative_path//_//}"  # Rebuild correct source path

                echo "Restoring child dataset: ${child_source_dataset}"
                child_latest_snapshot=$(zfs list -t snapshot -o name -s creation -H "${child}" | tail -n 1)
                if ! run_restore zfs send "${child_latest_snapshot}" | run_restore zfs receive -F "${child_source_dataset}"; then
                    unraid_notify "Restoration failed for child dataset ${child_source_dataset}." "failure"
                    log_message "ERROR: Restoration failed for child dataset ${child_source_dataset}."
                    final_status="failure"
                    final_message="One or more datasets failed to restore."
                else
                    unraid_notify "Restoration successful for child dataset ${child_source_dataset}." "success"
                    log_message "SUCCESS: Restoration successful for child dataset ${child_source_dataset}."
                fi
            done
        fi
    done

    # Send final summary notification
    if [ "$final_status" = "success" ]; then
        unraid_notify "$final_message" "success"
        log_message "SUMMARY: $final_message"
    else
        unraid_notify "$final_message" "failure"
        log_message "SUMMARY: $final_message"
    fi
}

# Run restoration for each dataset
run_for_each_dataset