# Unraid ZFS DataManager

This script automates the process of creating snapshots and replicating ZFS datasets on Unraid, making backups and data recovery easier and more reliable. It’s designed for Unraid version 6.12 and above, providing flexible options for both local and remote backups using either ZFS replication.

## Features

- **Automated Snapshots**: Uses Sanoid to manage snapshots with a user-defined retention policy.
- **ZFS Replication**: Supports local and remote ZFS replication with Syncoid.
- **Unraid Notifications**: Sends notifications via Unraid's GUI, alerting you to the success or failure of tasks.
- **Multiple Dataset Support**: Allows processing of multiple ZFS pools and datasets in a single run.
- **Automatic Configuration Management**: Automatically generates and updates Sanoid configuration files.

## Requirements

- **Unraid 6.12 or above**
- **ZFS Pool(s)/Dataset(s)**
- **Sanoid**: Automatic snapshot management. [Sanoid/Syncoid Plugin](https://forums.unraid.net/topic/94549-sanoidsyncoid-zfs-snapshots-and-replication/)

## Installation

1. **Install Community Apps**: Follow the [Unraid documentation and guide](https://unraid.net/community/apps/c/plugins).
2. **Install Sanoid**: Install the Sanoid plugin from Community Apps.

## Configuration

Edit the variables at the beginning of the script to match your environment.

## Key Differences Between the Original Script and This Modified Version

This modified script builds upon the foundation of the original script by SpaceInvaderOne, with several enhancements and changes to make the backup and replication process more versatile and robust. Below are the key differences:
### 1. Support for Multiple Pools and Datasets

- **Original Script**: Focuses on processing a single ZFS pool and dataset.
- **Modified Script**: Allows for multiple ZFS pools and datasets to be processed in a single run, making it more flexible for environments with multiple datasets.

### 2. Improved Configuration Management

- **Original Script**: Relies on hardcoded variables for pool and dataset names.
- **Modified Script**: Uses arrays to allow multiple pools and datasets to be specified easily. This approach simplifies managing configurations for large environments.

### 3. Automated Sanoid Configuration Generation

- **Original Script**: Manages snapshots and pruning through Sanoid but without automated configuration adjustments.
- **Modified Script**: Automatically generates and updates Sanoid (as needed) based on the specified retention policies and datasets, reducing manual configuration steps.

### 4. Enhanced Snapshot and Pruning Checks

- **Modified Script**: Adds additional checks to ensure snapshots are created and pruned as expected. The script now exits with a failure notification if these operations do not occur as intended.

## Usage

1. **Edit the Script**: Configure the variables at the beginning of the script according to your environment.
2. **Run the Script**: Execute the script via Unraid's terminal or schedule it as a cron job. For example, to run the script daily at midnight, add the following to your crontab: `0 0 * * *`

## License

This script is provided as-is, without warranty of any kind. Please review and test it before using it.

## Credits

- **Original Script**: [SpaceInvaderOne](https://github.com/SpaceinvaderOne/Unraid_ZFS_Dataset_Snapshot_and_Replications)
- **Modifications**: ChatGPT Data Analyzer