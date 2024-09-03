#!/bin/bash
#set -x  # Uncomment for debugging (enables trace mode for debugging each command execution)

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# #   Script for snapshotting and/or replication of a ZFS dataset locally or remotely using ZFS                                             # #
# #   (Requires Unraid 6.12 or above)                                                                                                       # #
# #   Original by SpaceInvaderOne                                                                                                           # #
# #   Modified by rjwaters147 using ChatGPT Data Analyzer                                                                                   # #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

####################
# Main Variables 
####################

####################
# Unraid Notifications Configuration
# Configure how and when notifications are sent to the Unraid GUI.
####################
notification_type="error"  # "all" for both success & failure, "error" for only failure, "none" for no notifications

####################
# ZFS Dataset Configuration
# Define the ZFS datasets (and their pools) that you want to process.
####################
source_datasets=("cache/appdata" "cache/downloads" "grid/vms") # Add all the pools/datasets you want to process here e.g. ("pool1/dataset1" "pool1/dataset2" "pool2/dataset3")

####################
# ZFS Snapshot Settings
# Enable having automatic snapshot capture and cleanup.
# Set the retention policy for ZFS snapshots.
####################
auto_snapshots="yes" # Set to "yes" to automatically take snapshots when the script is ran or "no" to skip. 
autoprune_snapshots="yes" # Set to "yes" to automatically remove snapshots beyond the retention policy set to "no" to disable retention and keep snapshots forever.

# Retention policy:
snapshot_hours="0"  # Number of hourly snapshots to keep (0 = none)
snapshot_days="7"   # Number of daily snapshots to keep (0 = none)
snapshot_weeks="4"  # Number of weekly snapshots to keep (0 = none)
snapshot_months="3" # Number of monthly snapshots to keep (0 = none)
snapshot_years="0"  # Number of yearly snapshots to keep (0 = none)

####################
# Remote Server Configuration
# Configure settings if you plan to replicate data to a remote server.
####################
destination_remote="no"  # Set to "no" for local backup or "yes" for a remote backup
remote_user="root"       # Remote server user (Unraid server typically uses "root")
remote_server="10.10.20.197" # Remote server's name or IP address

####################
# Replication Settings
# Requires having a second ZFS pool that is either local or remote
####################
replication="no"  # Choose between "yes" for ZFS replication or "no" for just using snapshots.

####################
# Replication Variables
####################
destination_dataset="vault/replication" # Parent dataset under which the replicated data will reside (e.g. "pool/dataset")

# Syncoid replication mode:
# "strict-mirror" - Mirrors the source dataset strictly, deleting snapshots in the destination that are not in the source.
# "basic" - Basic replication without extra flags; does not delete snapshots in the destination that are missing from the source.
syncoid_mode="strict-mirror"

####################
# Advanced Variables
# These settings are typically set correctly by default and do not need to be changed.
####################
sanoid_config_dir="/mnt/user/system/sanoid/"  # Location of the Sanoid configuration directory

####################
# Function: unraid_notify
# Sends notifications to the Unraid GUI based on the notification_type configuration.
# Usage: unraid_notify "<message>" "<success|failure>"
####################
unraid_notify() {
    local message="$1"
    local flag="$2"
    
    # Exit if notifications are disabled
    if [[ "$notification_type" == "none" ]]; then
        return 0
    fi
    
    # Exit if only error notifications are enabled and the message is a success
    if [[ "$notification_type" == "error" && "$flag" == "success" ]]; then
        return 0
    fi
    
    # Determine notification severity based on the message type
    local severity="normal"
    if [[ "$flag" == "success" ]]; then
        severity="normal"
    else
        severity="warning"
    fi
    
    /usr/local/emhttp/webGui/scripts/notify -s "Backup Notification" -d "$message" -i "$severity"
}

####################
# Function: global_pre_run_checks
# Performs essential checks before processing any datasets. 
# Ensures required tools are installed and configurations are valid.
####################
global_pre_run_checks() {
    # Ensure ZFS utilities are installed and executable
    if [ ! -x "$(which zfs)" ]; then
        msg="ZFS utilities are not found. Ensure you are using Unraid 6.12 or above."
        echo "$msg"
        unraid_notify "$msg" "failure"
        exit 1
    fi
    
    # Ensure Sanoid is installed and executable
    if [ ! -x /usr/local/sbin/sanoid ]; then
        msg="Sanoid is not found or not executable. Please install Sanoid and try again."
        echo "$msg"
        unraid_notify "$msg" "failure"
        exit 1
    fi

    # Validate the replication setting
    if [ "$replication" != "yes" ] && [ "$replication" != "no" ]; then
        msg="Invalid replication method: ${replication}. Set to 'yes', or 'no'."
        echo "$msg"
        unraid_notify "$msg" "failure"
        exit 1
    fi

    # Validate the autosnap setting
    if [ "$auto_snapshots" != "yes" ] && [ "$auto_snapshots" != "no" ]; then
        msg="The 'auto_snapshots' variable is not set to a valid value. Please set it to either 'yes' or 'no'."
        echo "$msg"
        unraid_notify "$msg" "failure"
        exit 1
    fi

    # Validate the autoprune setting
    if [ "$autoprune_snapshots" != "yes" ] && [ "$autoprune_snapshots" != "no" ]; then
        msg="The 'autoprune_snapshots' variable is not set to a valid value. Please set it to either 'yes' or 'no'."
        echo "$msg"
        unraid_notify "$msg" "failure"
        exit 1
    fi

    # Verify the script is set to complete work
    if [ "$replication" != "yes" ] && [ "$auto_snapshots" = "no" ]; then
        msg='Both replication and autosnap are disabled. The script has been run with nothing to do.'
        echo "$msg"
        unraid_notify "$msg" "failure"
        exit 1
    fi
    
    # Validate the remote destination configuration
    if [ "$destination_remote" != "yes" ] && [ "$destination_remote" != "no" ]; then
        msg="Invalid destination_remote setting. Set to 'yes' or 'no'."
        echo "$msg"
        unraid_notify "$msg" "failure"
        exit 1
    fi
    
    # Ensure remote_user and remote_server are set if remote backup is enabled
    if [ "$destination_remote" = "yes" ] && { [ -z "$remote_user" ] || [ -z "$remote_server" ]; }; then
        msg="Remote user and server must be set when destination_remote is 'yes'."
        echo "$msg"
        unraid_notify "$msg" "failure"
        exit 1
    fi

    # Check if the remote server is reachable (if remote backup is enabled)
    if [ "$destination_remote" = "yes" ]; then
        echo "Checking remote server availability..."
        if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${remote_user}@${remote_server}" echo 'SSH connection successful' &>/dev/null; then
            msg="SSH connection failed. Verify remote server details and ensure SSH keys are exchanged."
            echo "$msg"
            unraid_notify "$msg" "failure"
            exit 1
        fi
    else
        echo "Replication target is a local/same server."
    fi
}

#####################
# Function: dataset_pre_run_checks
# Performs checks specific to each dataset, ensuring the dataset exists, is named correctly, and contains data.
####################
dataset_pre_run_checks() {
    # Verify the source dataset exists in the ZFS pool
    if ! zfs list -H "${source_dataset}" &>/dev/null; then
        msg="Error: The source dataset '${source_dataset}' does not exist."
        echo "$msg"
        unraid_notify "$msg" "failure"
        exit 1
    fi
    
    # Ensure the dataset name does not contain spaces (required for autosnapshots)
    if [[ "${source_dataset}" == *" "* ]]; then
        msg="Error: The source dataset name '${source_dataset}' contains spaces. Rename the dataset and try again."
        echo "$msg"
        unraid_notify "$msg" "failure"
        exit 1
    fi
    
    # Check if the dataset contains any data
    local used
    used=$(zfs get -H -o value used "${source_dataset}")
    if [[ ${used} == 0B ]]; then
        msg="The source dataset '${source_dataset}' is empty. Nothing to replicate."
        echo "$msg"
        unraid_notify "$msg" "failure"
        exit 1
    fi
}

####################
# Function: create_sanoid_config
# Generates a Sanoid configuration file for the dataset based on the snapshot retention policy.
####################
create_sanoid_config() {
    # Ensure the Sanoid config directory exists
    if [ ! -d "${sanoid_config_complete_path}" ]; then
        mkdir -p "${sanoid_config_complete_path}"
    fi
    
    # Copy default Sanoid configuration if not already present
    if [ ! -f "${sanoid_config_complete_path}sanoid.defaults.conf" ]; then
        cp /etc/sanoid/sanoid.defaults.conf "${sanoid_config_complete_path}sanoid.defaults.conf"
    fi

    # Build the new Sanoid configuration content
    new_content="[${source_dataset}]
use_template = production
recursive = yes

[template_production]
hourly = ${snapshot_hours}
daily = ${snapshot_days}
weekly = ${snapshot_weeks}
monthly = ${snapshot_months}
yearly = ${snapshot_years}
autosnap = ${auto_snapshots}
autoprune = ${autoprune_snapshots}"

    # Update the Sanoid configuration file if there are changes
    if [ -f "${sanoid_config_complete_path}sanoid.conf" ]; then
        existing_content=$(cat "${sanoid_config_complete_path}sanoid.conf")
        if [ "$new_content" != "$existing_content" ]; then
            echo "Differences found in Sanoid config, updating the config file."
            echo "$new_content" > "${sanoid_config_complete_path}sanoid.conf"
        else
            echo "No differences found in Sanoid config, keeping the existing config."
        fi
    else
        echo "Sanoid config file not found, creating a new one."
        echo "$new_content" > "${sanoid_config_complete_path}sanoid.conf"
    fi
}

####################
# Function: autosnap
# Creates automatic snapshots of the source dataset using Sanoid based on the retention policy.
####################
autosnap() {
    echo "Creating automatic snapshots for ${source_dataset} and its children using Sanoid."

    # Run Sanoid in verbose mode and capture all output
    if /usr/local/sbin/sanoid --configdir="${sanoid_config_complete_path}" --take-snapshots; then
            unraid_notify "Snapshot creation successful for ${source_dataset}." "success"
    else
        msg="Snapshot creation failed for ${source_dataset}."
        echo "$msg"
        unraid_notify "$msg" "failure"
        exit 1
    fi
}


####################
# Function: autoprune
# Prunes old snapshots of the source dataset using Sanoid based on the retention policy.
####################
autoprune() {
    echo "Pruning snapshots for ${source_dataset} and its children using Sanoid."
    
    # Run Sanoid in verbose mode and capture all output
    if /usr/local/sbin/sanoid --configdir="${sanoid_config_complete_path}" --prune-snapshots; then
        unraid_notify "Snapshot removal successful for ${source_dataset} and its children." "success"
    else
        msg="Snapshot removal failed for ${source_dataset} and its children."
        echo "$msg"
        unraid_notify "$msg" "failure"
        exit 1
    fi
}

####################
# Function: zfs_replication
# Uses ZFS to replicate the source dataset to the destination.
####################
zfs_replication() {
        zfs_destination_path="${destination_dataset}/${source_dataset//\//_}"

        # Determine if replication is to a remote or local destination
        if [ "$destination_remote" = "yes" ]; then
            destination="${remote_user}@${remote_server}:${zfs_destination_path}"
            # Check or create the full destination ZFS dataset hierarchy on the remote server
            if ! ssh "${remote_user}@${remote_server}" "if ! zfs list -o name -H '\${zfs_destination_path}' &>/dev/null; then zfs create -p '\${zfs_destination_path}'; fi"; then
                unraid_notify "Failed to check or create ZFS dataset hierarchy on remote server: ${destination}" "failure"
                return 1
            fi
        else
            destination="${zfs_destination_path}"
            # Check or create the full destination ZFS dataset hierarchy locally
            if ! zfs list -o name -H "${zfs_destination_path}" &>/dev/null; then
                if ! zfs create -p "${zfs_destination_path}"; then
                    unraid_notify "Failed to check or create local ZFS dataset hierarchy: ${zfs_destination_path}" "failure"
                    return 1
                fi
            fi
        fi

        # Validate that the latest snapshot exists
        latest_snapshot=$(zfs list -t snapshot -o name -s creation -H -r "${source_dataset}" | tail -n 1)
        if [ -z "$latest_snapshot" ]; then
            unraid_notify "No snapshot found for ${source_dataset}. Skipping ZFS replication." "failure"
            return 1
        fi

        # Prepare syncoid flags with the --no-sync-snap option to avoid creating extra snapshots
        syncoid_flags=("-r" "--no-sync-snap")
        case "${syncoid_mode}" in
            "strict-mirror")
                syncoid_flags+=("--delete-target-snapshots" "--force-delete")
                ;;
            "basic")
                # No additional flags other than -r and --no-sync-snap
                ;;
            *)
                echo "Invalid syncoid_mode. Please set it to 'strict-mirror' or 'basic'."
                exit 1
                ;;
        esac

        # Perform ZFS replication using syncoid
        echo "Starting ZFS replication using syncoid with mode: ${syncoid_mode}"
        echo "Running Command: /usr/local/sbin/syncoid ${syncoid_flags[*]} ${source_dataset} ${destination}"

        if /usr/local/sbin/syncoid "${syncoid_flags[@]}" "${source_dataset}" "${destination}"; then
            unraid_notify "ZFS replication was successful from source: ${source_dataset} to destination: ${destination}" "success"
        else
            unraid_notify "ZFS replication failed from source: ${source_dataset} to ${destination}" "failure"
            return 1
        fi
}

####################
# Function: cleanup_unwanted_sanoid_configs
# Removes Sanoid configuration files for datasets that have been removed.
####################
cleanup_unwanted_sanoid_configs() {
    local sanoid_state_file="${sanoid_config_dir}sanoid_state.txt"
    local found_unwanted=false

    echo "Starting cleanup of unwanted Sanoid configs."

    if [ -f "$sanoid_state_file" ]; then
        echo "Loading previous state from ${sanoid_state_file}."

        # Extract the datasets from the previous run
        mapfile -t previous_datasets < <(grep "^datasets:" "$sanoid_state_file" | sed 's/datasets: //' | tr ' ' '\n')

        if [ ${#previous_datasets[@]} -eq 0 ]; then
            echo "No previous datasets found in the state file."
        else
            echo "Previous datasets: ${previous_datasets[*]}"
        fi
    else
        echo "No previous state file found, creating a new state file after cleanup."
        previous_datasets=()
    fi

    echo "Checking for unwanted Sanoid configs."
    for dataset in "${previous_datasets[@]}"; do
        local dataset_trimmed
        dataset_trimmed=$(echo "$dataset" | xargs)  # Trim spaces around dataset name
        if [[ ! " ${source_datasets[*]} " =~ ${dataset_trimmed} ]]; then
            echo "Dataset $dataset_trimmed is no longer in the source list, removing its Sanoid config..."
            sanoid_config_complete_path="${sanoid_config_dir}${dataset_trimmed//\//_}/"

            if [ -d "$sanoid_config_complete_path" ]; then
                echo "Deleting Sanoid config directory: $sanoid_config_complete_path"
                if rm -rf "$sanoid_config_complete_path"; then
                    echo "Successfully deleted: $sanoid_config_complete_path"
                    found_unwanted=true
                else
                    echo "Failed to delete: $sanoid_config_complete_path"
                fi
            fi
        fi
    done

    if ! $found_unwanted; then
        echo "No unwanted Sanoid configs found."
    fi

    echo "Saving current state to ${sanoid_state_file}."
    echo "datasets: ${source_datasets[*]}" > "$sanoid_state_file"

    echo "Cleanup of unwanted Sanoid configs completed."
}

####################
# Function: run_for_each_dataset
# Iterates over each selected dataset, performing snapshotting and replication tasks sequentially.
####################
run_for_each_dataset() {
    echo "Starting the processing of defined datasets."

    # Perform global pre-run checks
    echo "Performing global pre-run checks"
    global_pre_run_checks

    # Iterate over each defined dataset
    for dataset in "${source_datasets[@]}"; do
        source_dataset="$dataset"
        sanoid_config_complete_path="${sanoid_config_dir}${dataset//\//_}/"

        echo "Processing dataset: ${dataset}"

        # Only run autosnap and related functions if enabled
        if [ "$auto_snapshots" = "yes" ]; then
            # Create Sanoid configuration for each dataset
            echo "Creating sanoid config for ${dataset}"
            create_sanoid_config

            # Take snapshots for each dataset
            echo "Taking snapshots for ${dataset}"
            autosnap

            # Prune old snapshots for each dataset (if pruning is enabled)
            if [ "$autoprune_snapshots" = "yes" ]; then
                echo "Pruning old snapshots for ${dataset}"
                autoprune
            fi
        fi
    done

    # Clean up unwanted Sanoid configurations (if autosnap is enabled)
    if [ "$auto_snapshots" = "yes" ]; then
        cleanup_unwanted_sanoid_configs
    fi

    # Perform ZFS replication (if enabled) after all datasets have been processed
    if [ "$replication" = "yes" ]; then
        echo "Performing ZFS replication"
        for dataset in "${source_datasets[@]}"; do
            source_dataset="$dataset"
            zfs_replication
        done
    fi
}

####################
# Main Script Execution
####################
run_for_each_dataset