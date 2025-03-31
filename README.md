# nas_mount.sh

A shell script to automate the setup and teardown of systemd `.mount` and `.automount` units for mounting CIFS (Samba) network shares on Linux systems, designed to be robust against common boot timing issues.

## Features

*   Automates the creation and removal of systemd `.mount` and `.automount` unit files for CIFS shares.
*   Uses `--mount` to set up and `--unmount` to tear down the configuration.
*   `--unmount` only requires the local mountpoint as an argument.
*   `--unmount` **does not** delete the credentials file or the (empty) mountpoint directory, allowing for easy reconfiguration.
*   Accepts server address as FQDN or IP (`//<server>/<share>`).
*   Takes the local directory path as the mount target.
*   Uses `--user` for the username on the server.
*   Uses `--password` for the user's password on the server.
*   Automatically determines necessary system information (like local UID/GID).
*   Creates the Samba credentials file if it doesn't exist (at `/etc/samba/credentials.<user>@<server>`).
*   Creates the local mountpoint directory if it doesn't exist.
*   Executes necessary `systemctl daemon-reload`, `enable --now`, `stop`, and `disable` commands.
*   Sets initial mountpoint directory permissions to `755` (root:root). (Mounted content ownership is determined by `uid`/`gid` options passed to `mount.cifs`).
*   Assumes the local username is the same as the NAS username (`--user`) to automatically determine the correct local UID/GID for file ownership.
*   Optional `--smb-version` parameter (defaults to 3.0).
*   Includes checks to prevent overwriting existing unit files or mounting onto an already active mountpoint.
*   Provides informative error messages.
*   Features a `--test` mode (dry run) to show what commands would be executed without making changes.
*   **Resolves FQDN to IP:** If a server FQDN is provided, the script resolves its IP address and uses the IP in the `.mount` unit's `What=` line. This helps avoid name resolution issues during early boot.

## Prerequisites

*   **Executable Permissions:** The script needs execute permissions (`chmod +x nas_mount.sh`).
*   **Root Privileges:** Must be run with `sudo` as it modifies files in `/etc`, creates directories, and uses `systemctl`.
*   **Password Security:** Be aware that providing the password via the `--password` flag is insecure (can appear in process lists and shell history). Consider securing the credentials file appropriately.
*   **`getent` Command:** Uses `getent hosts` for IP resolution. This should be available on standard Ubuntu/Debian-based systems (part of `libc-bin`).
*   **`systemd-escape` Command:** Uses `systemd-escape` to create valid unit file names from paths. This is part of the standard systemd tools.

## Usage

```bash
# To set up a new mount
sudo ./nas_mount.sh --mount //<server>/<share> <local_mountpoint> --user <nas_user> --password <nas_pass> [options]

# To remove an existing mount configuration
sudo ./nas_mount.sh --unmount <local_mountpoint> [--test]

##Options
###Options for --mount:
//<server>/<share>: Network path to the share (server can be FQDN or IP).

<local_mountpoint>: Local directory path where the share will be mounted.

--user <nas_user>: Username for authenticating to the NAS share. (The script assumes a local user with the same name exists to determine file ownership UID/GID).

--password <nas_pass>: Password for the NAS user. WARNING: Providing the password on the command line is insecure!

--smb-version <ver>: (Optional) Specify the SMB protocol version (e.g., 2.1, 3.0, 3.1.1). Defaults to 3.0.

--test: (Optional) Perform a dry run. Shows all actions that would be taken (creating files, running commands) without actually executing them.

###Options for --unmount:
<local_mountpoint>: The local directory path that was used as the mountpoint for the configuration you want to remove.

--test: (Optional) Perform a dry run. Shows all actions that would be taken.

###Help
--help: Show the built-in help message summarizing usage and options.

