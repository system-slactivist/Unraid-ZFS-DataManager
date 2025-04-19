#!/bin/bash
#set -x  # Uncomment for debugging (enables trace mode for debugging each command execution)
set -euo pipefail
trap 'unraid_notify "Script terminated unexpectedly." "failure"' ERR

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# #   Script for snapshotting and/or replication of a ZFS dataset locally or remotely using ZFS                                             # #
# #   (Requires Unraid 6.12 or above)                                                                                                       # #
# #   Original by SpaceInvaderOne                                                                                                           # #
# #   Modified by SystemSlactivist                                                                                                          # #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

####################
# Main Variables
####################

####################
# Dry-Run
# Enable simulation mode so the script reports intended actions without actually creating snapshots, pruning, or replicating.
####################
dry_run="yes"  # Set to "yes" to run in dry‑run mode, or "no" to perform real operations.

####################
# Unraid Notifications Configuration
# Configure how and when notifications are sent to the Unraid GUI.
####################
notification_type="all"  # "all" for both success & failure, "error" for only failure, "none" for no notifications

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

####################
# Retention policy
####################
snapshot_hours="0"  # Number of hourly snapshots to keep (0 = none)
snapshot_days="7"   # Number of daily snapshots to keep (0 = none)
snapshot_weeks="4"  # Number of weekly snapshots to keep (0 = none)
snapshot_months="3" # Number of monthly snapshots to keep (0 = none)
snapshot_years="0"  # Number of yearly snapshots to keep (0 = none)

####################
# Remote Server Configuration
# Configure settings if you plan to replicate data to a remote server.
####################
destination_remote="no"  # Set to "no" for local backup, "yes" for a remote backup or "both" to replicate locally and remotely.
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
destination_local_dataset="vault/replication" # Local parent dataset under which the replicated data will reside (e.g. "pool/dataset")
destination_remote_dataset="vault/replication_remote" # Remote parent dataset under which the replicated data will reside (e.g. "pool/dataset")

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
####################
global_pre_run_checks() {
    # Ensure ZFS utilities are installed
    if ! command -v zfs &>/dev/null; then
        msg="ZFS utilities are not found. Ensure you are using Unraid 6.12 or above."
        echo "$msg"; unraid_notify "$msg" "failure"; exit 1
    fi

    # Ensure Sanoid is installed
    if [ ! -x "/usr/local/sbin/sanoid" ]; then
        msg="Sanoid is not found or not executable. Please install Sanoid and try again."
        echo "$msg"; unraid_notify "$msg" "failure"; exit 1
    fi

    # Validate boolean settings (replication, snapshots)
    for var in replication auto_snapshots autoprune_snapshots; do
        if [[ "${!var}" != "yes" && "${!var}" != "no" ]]; then
            msg="Invalid setting for $var: ${!var}. Must be 'yes' or 'no'."
            echo "$msg"; unraid_notify "$msg" "failure"; exit 1
        fi
    done

    # Validate destination_remote can be "yes", "no", or "both"
    if [[ "$destination_remote" != "yes" && "$destination_remote" != "no" && "$destination_remote" != "both" ]]; then
        msg="Invalid setting for destination_remote: ${destination_remote}. Must be 'no', 'yes', or 'both'."
        echo "$msg"; unraid_notify "$msg" "failure"; exit 1
    fi

    # Sanity‑check local & remote destination variables
    if [[ -z "$destination_local_dataset" ]]; then
        msg="You must set destination_local_dataset in the script."
        echo "$msg"; unraid_notify "$msg" "failure"; exit 1
    fi
    if [[ ( "$destination_remote" = "yes" || "$destination_remote" = "both" ) && -z "$destination_remote_dataset" ]]; then
        msg="You must set destination_remote_dataset when destination_remote is 'yes' or 'both'."
        echo "$msg"; unraid_notify "$msg" "failure"; exit 1
    fi

    # Ensure at least one action is enabled
    if [[ "$replication" != "yes" && "$auto_snapshots" != "yes" ]]; then
        msg='Both replication and autosnap are disabled. Nothing to do.'
        echo "$msg"; unraid_notify "$msg" "failure"; exit 1
    fi

    # If remote or both, validate SSH & syncoid
    if [[ "$destination_remote" = "yes" || "$destination_remote" = "both" ]]; then
        helper_check_remote
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
# Function: helper_check_remote
# Validates remote settings, SSH connectivity, and syncoid on the remote host.
####################
helper_check_remote() {
    # Only run when destination_remote is "yes" or "both"
    if [[ "$destination_remote" = "yes" || "$destination_remote" = "both" ]]; then
        # Ensure remote_user and remote_server are set
        if [ -z "$remote_user" ] || [ -z "$remote_server" ]; then
            msg="Remote user and server must be set when destination_remote is 'yes' or 'both'."
            echo "$msg"; unraid_notify "$msg" "failure"; exit 1
        fi

        # Test SSH connection
        echo "Checking remote server availability..."
        if ! ssh -o BatchMode=yes -o ConnectTimeout=5 \
              "${remote_user}@${remote_server}" \
              "echo 'SSH connection successful'" &>/dev/null; then
            msg="SSH connection failed. Verify remote details and SSH keys."
            echo "$msg"; unraid_notify "$msg" "failure"; exit 1
        fi

        # Verify syncoid installation
        echo "Verifying syncoid on remote..."
        if ! ssh -o BatchMode=yes -o ConnectTimeout=5 \
              "${remote_user}@${remote_server}" \
              "command -v syncoid >/dev/null 2>&1"; then
            msg="Syncoid not found on ${remote_server}. Install it first."
            echo "$msg"; unraid_notify "$msg" "failure"; exit 1
        fi
    else
        echo "Replication target is local-only."
    fi
}

####################
# Function: helper_ensure_dataset_path
# Ensures the ZFS dataset hierarchy exists locally or remotely.
####################
helper_ensure_dataset_path() {
    local mode="$1"; shift
    local path="$1"

    # Dry‑run: simulate creating dataset path
    if [ "$dry_run" = "yes" ]; then
        echo "[DRY-RUN] Would ensure ${mode} dataset path exists: ${path}"
        return 0
    fi

    if [ "$mode" = "remote" ]; then
        # Create remote dataset path if missing
        if ! ssh "${remote_user}@${remote_server}" \
             "if ! zfs list -H \"${path}\" &>/dev/null; then zfs create -p \"${path}\"; fi"; then
            unraid_notify "Failed to create remote dataset ${path}" "failure"
            return 1
        fi
    else
        # Create local dataset path if missing
        if ! zfs list -H "${path}" &>/dev/null; then
            if ! zfs create -p "${path}"; then
                unraid_notify "Failed to create local dataset ${path}" "failure"
                return 1
            fi
        fi
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

    # Symlink the global sanoid.defaults.conf if not already present
    if [ ! -e "${sanoid_config_complete_path}sanoid.defaults.conf" ]; then
        ln -s /etc/sanoid/sanoid.defaults.conf "${sanoid_config_complete_path}sanoid.defaults.conf"
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
    # Dry‑run: just simulate
    if [ "$dry_run" = "yes" ]; then
        echo "[DRY-RUN] Would create snapshots for ${source_dataset}"
        return 0
    fi

    echo "Creating automatic snapshots for ${source_dataset} and its children using Sanoid."
    if /usr/local/sbin/sanoid --configdir="${sanoid_config_complete_path}" --take-snapshots; then
        unraid_notify "Snapshot creation successful for ${source_dataset}." "success"
    else
        msg="Snapshot creation failed for ${source_dataset}."
        echo "$msg"; unraid_notify "$msg" "failure"; exit 1
    fi
}

####################
# Function: autoprune
# Prunes old snapshots of the source dataset using Sanoid based on the retention policy.
####################
autoprune() {
    # Dry‑run: just simulate
    if [ "$dry_run" = "yes" ]; then
        echo "[DRY-RUN] Would prune snapshots for ${source_dataset}"
        return 0
    fi

    echo "Pruning snapshots for ${source_dataset} and its children using Sanoid."
    if /usr/local/sbin/sanoid --configdir="${sanoid_config_complete_path}" --prune-snapshots; then
        unraid_notify "Snapshot removal successful for ${source_dataset} and its children." "success"
    else
        msg="Snapshot removal failed for ${source_dataset} and its children."
        echo "$msg"; unraid_notify "$msg" "failure"; exit 1
    fi
}

####################
# Function: zfs_replication
# Uses ZFS (via syncoid) to replicate the source dataset locally, remotely, or both.
####################
zfs_replication() {
    local local_base="${destination_local_dataset}/${source_dataset//\//_}"
    local remote_base="${destination_remote_dataset}/${source_dataset//\//_}"
    local flags=( -r --no-sync-snap )

    case "${syncoid_mode}" in
        strict-mirror)
            flags+=( --delete-target-snapshots --force-delete )
            ;;
        basic) ;;
        *)
            msg="Invalid syncoid_mode: ${syncoid_mode}"
            echo "$msg"; exit 1
            ;;
    esac

    # Local replication
    if [[ "$destination_remote" = "no" || "$destination_remote" = "both" ]]; then
        if [[ "$dry_run" = "yes" ]]; then
            echo "[DRY-RUN] Would ensure local dataset path: ${local_base}"
            echo "[DRY-RUN] Would run: syncoid ${flags[@]} \"${source_dataset}\" \"${local_base}\""
        else
            helper_ensure_dataset_path local "${local_base}" || return 1
            echo "Running local replication: syncoid ${flags[@]} \"${source_dataset}\" \"${local_base}\""
            if /usr/local/sbin/syncoid "${flags[@]}" "${source_dataset}" "${local_base}"; then
                unraid_notify "Local replication succeeded: ${source_dataset} → ${local_base}" "success"
            else
                unraid_notify "Local replication FAILED: ${source_dataset} → ${local_base}" "failure"
                return 1
            fi
        fi
    fi

    # Remote replication
    if [[ "$destination_remote" = "yes" || "$destination_remote" = "both" ]]; then
        local remote_dest="${remote_user}@${remote_server}:${remote_base}"

        if [[ "$dry_run" = "yes" ]]; then
            echo "[DRY-RUN] Would ensure remote dataset path: ${remote_base}"
            echo "[DRY-RUN] Would run: syncoid ${flags[@]} \"${source_dataset}\" \"${remote_dest}\""
        else
            helper_ensure_dataset_path remote "${remote_base}" || return 1
            echo "Running remote replication: syncoid ${flags[@]} \"${source_dataset}\" \"${remote_dest}\""
            if /usr/local/sbin/syncoid "${flags[@]}" "${source_dataset}" "${remote_dest}"; then
                unraid_notify "Remote replication succeeded: ${source_dataset} → ${remote_dest}" "success"
            else
                unraid_notify "Remote replication FAILED: ${source_dataset} → ${remote_dest}" "failure"
                return 1
            fi
        fi
    fi
}

####################
# Function: cleanup_unwanted_sanoid_configs
# Removes Sanoid configuration files for datasets that have been removed.
####################
cleanup_unwanted_sanoid_configs() {
    local sanoid_state_file="${sanoid_config_dir}sanoid_state.txt"
    local found_unwanted=false
    local dataset_trimmed

    echo "Cleaning up stale Sanoid configs…"

    if [ -f "${sanoid_state_file}" ]; then
        mapfile -t previous_datasets < <(
            grep "^datasets:" "${sanoid_state_file}" \
            | sed 's/datasets: //' \
            | tr ' ' '\n'
        )
    else
        previous_datasets=()
    fi

    for dataset in "${previous_datasets[@]}"; do
        dataset_trimmed="$(echo "${dataset}" | xargs)"
        if [[ ! " ${source_datasets[*]} " =~ " ${dataset_trimmed} " ]]; then
            echo "Removing config for ${dataset_trimmed}"
            local config_dir="${sanoid_config_dir}${dataset_trimmed//\//_}/"
            if [ -d "${config_dir}" ]; then
                rm -rf "${config_dir}" \
                  && echo "Deleted ${config_dir}" \
                  || echo "Failed to delete ${config_dir}"
                found_unwanted=true
            fi
        fi
    done

    if [ "${found_unwanted}" = false ]; then
        echo "No stale configs found."
    fi

    echo "Saving new state."
    echo "datasets: ${source_datasets[*]}" > "${sanoid_state_file}"
}

####################
# Function: run_for_each_dataset
# Iterates over each selected dataset, performing snapshotting and replication tasks sequentially.
####################
run_for_each_dataset() {
    echo "=== Replicating to: local=${destination_local_dataset}, remote=${destination_remote_dataset} (mode=${destination_remote}) ==="
    echo "Starting the processing of defined datasets."

    echo "Performing global pre-run checks"
    global_pre_run_checks

    if [ "${#source_datasets[@]}" -eq 0 ]; then
        msg="No source datasets configured. Please set source_datasets in the script."
        echo "$msg"; unraid_notify "$msg" "failure"; exit 1
    fi

    for dataset in "${source_datasets[@]}"; do
        source_dataset="$dataset"
        dataset_pre_run_checks
        sanoid_config_complete_path="${sanoid_config_dir}${dataset//\//_}/"

        echo "Processing dataset: ${dataset}"
        if [ "$auto_snapshots" = "yes" ]; then
            echo "Creating sanoid config for ${dataset}"
            create_sanoid_config
            echo "Taking snapshots for ${dataset}"
            autosnap
            if [ "$autoprune_snapshots" = "yes" ]; then
                echo "Pruning old snapshots for ${dataset}"
                autoprune
            fi
        fi
    done

    if [ "$auto_snapshots" = "yes" ]; then
        cleanup_unwanted_sanoid_configs
    fi

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