#!/bin/bash

# nas_mount.sh - Automates creation/deletion of systemd automount units for CIFS shares

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Default Values ---
DEFAULT_SMB_VERSION="3.0"
CREDENTIALS_DIR="/etc/samba"
SYSTEMD_DIR="/etc/systemd/system"

# --- Script Variables ---
ACTION=""
SERVER_SPEC="" # //server/share
LOCAL_MOUNTPOINT=""
NAS_USER=""
NAS_PASS=""
SMB_VERSION="$DEFAULT_SMB_VERSION"
TEST_MODE=false
LOCAL_USER_FOR_OWNERSHIP="" # Wird später ermittelt

# --- Helper Functions ---
usage() {
  echo "Usage: $0 --mount //<server>/<share> <local_mountpoint> --user <nas_user> --password <nas_pass> [options]"
  echo "       $0 --unmount <local_mountpoint>"
  echo ""
  echo "Options for --mount:"
  echo "  //<server>/<share>     : Network path (server can be FQDN or IP)."
  echo "  <local_mountpoint>     : Local directory to mount onto."
  echo "  --user <nas_user>      : Username for NAS authentication."
  echo "                           (Assumes the same username exists locally for file ownership)."
  echo "  --password <nas_pass>  : Password for NAS authentication."
  echo "                           WARNING: Providing password on CLI is insecure!"
  echo "  --smb-version <ver>    : Optional SMB version (e.g., 2.1, 3.0, 3.1.1). Default: $DEFAULT_SMB_VERSION"
  echo "  --test                 : Optional. Show what would be done without executing."
  echo ""
  echo "Options for --unmount:"
  echo "  <local_mountpoint>     : Local mountpoint of the setup to remove."
  echo "  --test                 : Optional. Show what would be done without executing."
  echo ""
  echo "Help:"
  echo "  --help                 : Show this help message."
  echo ""
  exit 1
}

# Function to check if running as root
check_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)."
    exit 1
  fi
}

# Function to execute commands or print them in test mode
execute_command() {
  local cmd_desc="$1"
  shift
  local cmd=("$@") # Restliche Argumente sind der Befehl

  echo "--------------------------------------------------"
  echo "ACTION: $cmd_desc"
  echo "COMMAND: ${cmd[*]}"
  if [ "$TEST_MODE" = true ]; then
    echo "TEST MODE: Command not executed."
  else
    if ! "${cmd[@]}"; then
       echo "ERROR: Command failed: ${cmd[*]}"
       exit 1
    fi
    echo "SUCCESS: Command executed."
  fi
   echo "--------------------------------------------------"
}

# Function to write content to a file or print it in test mode
write_file_content() {
  local file_desc="$1"
  local file_path="$2"
  local file_content="$3" # Use "$VAR" to pass content with newlines

  echo "--------------------------------------------------"
  echo "ACTION: $file_desc"
  echo "FILE: $file_path"
  if [ "$TEST_MODE" = true ]; then
    echo "TEST MODE: File not written. Content would be:"
    echo "--- BEGIN CONTENT ---"
    echo "$file_content"
    echo "--- END CONTENT ---"
  else
    # Create directory if it doesn't exist (relevant for credentials dir)
    local dir_path
    dir_path=$(dirname "$file_path")
    if [ ! -d "$dir_path" ]; then
      execute_command "Create directory $dir_path" mkdir -p "$dir_path"
    fi

    if echo "$file_content" > "$file_path"; then
      echo "SUCCESS: File written."
    else
      echo "ERROR: Failed to write to $file_path."
      exit 1
    fi
  fi
   echo "--------------------------------------------------"
}


# --- Argument Parsing ---
if [ $# -eq 0 ]; then
  usage
fi

while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --help)
      usage
      ;;
    --mount)
      ACTION="mount"
      shift # past argument
      if [[ $# -lt 4 ]]; then usage; fi # Need server, mountpoint, --user, --password minimally
      SERVER_SPEC="$1"
      shift
      LOCAL_MOUNTPOINT="$1"
      shift
      ;;
    --unmount)
      ACTION="unmount"
      shift
      if [[ $# -lt 1 ]]; then usage; fi # Need mountpoint
      LOCAL_MOUNTPOINT="$1"
      shift
      ;;
    --user)
      if [[ $# -lt 2 ]]; then usage; fi
      NAS_USER="$2"
      shift # past argument
      shift # past value
      ;;
    --password)
      if [[ $# -lt 2 ]]; then usage; fi
      NAS_PASS="$2"
      shift # past argument
      shift # past value
      ;;
    --smb-version)
      if [[ $# -lt 2 ]]; then usage; fi
      SMB_VERSION="$2"
      shift # past argument
      shift # past value
      ;;
     --test)
      TEST_MODE=true
      shift # past argument
      ;;
    *) # unknown option or positional argument after action keyword
      if [ -z "$ACTION" ]; then
         echo "ERROR: Unknown option or missing action (--mount or --unmount): $1"
         usage
      fi
      # Allow positional args only right after --mount or --unmount
      # This simplistic parsing assumes correct order after the action keyword
      shift
      ;;
  esac
done

# --- Sanity Checks ---
check_root

if [ "$ACTION" == "mount" ]; then
  if [ -z "$SERVER_SPEC" ] || [ -z "$LOCAL_MOUNTPOINT" ] || [ -z "$NAS_USER" ] || [ -z "$NAS_PASS" ]; then
    echo "ERROR: Missing required arguments for --mount."
    usage
  fi
  # Validate server spec format
  if [[ ! "$SERVER_SPEC" =~ ^//([^/]+)/(.+)$ ]]; then
     echo "ERROR: Invalid server/share format. Use //server/share."
     usage
  fi
  SERVER_NAME="${BASH_REMATCH[1]}"
  SHARE_NAME="/${BASH_REMATCH[2]}" # Add leading slash back

  # Check if local user (assumed same as NAS user) exists
  if ! id "$NAS_USER" &>/dev/null; then
    echo "ERROR: Local user '$NAS_USER' (specified with --user) not found. Cannot determine UID/GID."
    exit 1
  fi
  LOCAL_UID=$(id -u "$NAS_USER")
  LOCAL_GID=$(id -g "$NAS_USER")
  LOCAL_USER_FOR_OWNERSHIP="$NAS_USER"
  echo "INFO: Will use UID $LOCAL_UID and GID $LOCAL_GID for local file ownership (based on local user '$LOCAL_USER_FOR_OWNERSHIP')."

  # Resolve Server IP (best effort)
  echo "INFO: Attempting to resolve IP for server '$SERVER_NAME'..."
  SERVER_IP=$(getent hosts "$SERVER_NAME" | awk '{ print $1 }' | head -n 1)
  RESOLVE_COMMENT=""
  if [ -z "$SERVER_IP" ]; then
      echo "WARNING: Could not resolve IP address for '$SERVER_NAME'. Using '$SERVER_NAME' directly in mount command."
      echo "         Mounting might fail during boot if name resolution isn't ready."
      SERVER_IP="$SERVER_NAME" # Use original name if resolution fails
      RESOLVE_COMMENT="# WARNING: Could not resolve IP for $SERVER_NAME at script execution time."
  elif [ "$SERVER_IP" == "$SERVER_NAME" ]; then
      echo "INFO: Server '$SERVER_NAME' appears to be an IP address already."
      RESOLVE_COMMENT="# Server specified as IP address."
  else
       echo "INFO: Resolved '$SERVER_NAME' to IP address '$SERVER_IP'."
       RESOLVE_COMMENT="# Resolved $SERVER_NAME to $SERVER_IP at script execution time."
  fi
  WHAT_PATH="//${SERVER_IP}${SHARE_NAME}"


elif [ "$ACTION" == "unmount" ]; then
  if [ -z "$LOCAL_MOUNTPOINT" ]; then
    echo "ERROR: Missing local_mountpoint argument for --unmount."
    usage
  fi
else
  echo "ERROR: Invalid action specified."
  usage
fi

# Escape local mountpoint for systemd unit names
SYSTEMD_BASE_NAME=$(systemd-escape --path "$LOCAL_MOUNTPOINT")
MOUNT_UNIT_FILE="${SYSTEMD_DIR}/${SYSTEMD_BASE_NAME}.mount"
AUTOMOUNT_UNIT_FILE="${SYSTEMD_DIR}/${SYSTEMD_BASE_NAME}.automount"

# --- Perform Actions ---

if [ "$ACTION" == "mount" ]; then
  echo "*** Preparing to MOUNT configuration for $LOCAL_MOUNTPOINT ***"

  # 1. Check if mountpoint exists and is not already mounted
  if mountpoint -q "$LOCAL_MOUNTPOINT"; then
      echo "ERROR: '$LOCAL_MOUNTPOINT' is already a mountpoint. Aborting."
      exit 1
  fi
  if [ ! -d "$LOCAL_MOUNTPOINT" ]; then
      execute_command "Create local mountpoint directory" mkdir -p "$LOCAL_MOUNTPOINT"
      execute_command "Set permissions for mountpoint directory" chmod 755 "$LOCAL_MOUNTPOINT"
      # Ownership is typically root:root for mount points under /media or /mnt
      execute_command "Set ownership for mountpoint directory" chown root:root "$LOCAL_MOUNTPOINT"
  else
       echo "INFO: Local mountpoint directory '$LOCAL_MOUNTPOINT' already exists."
  fi

  # 2. Check if unit files already exist
  if [ -f "$MOUNT_UNIT_FILE" ] || [ -f "$AUTOMOUNT_UNIT_FILE" ]; then
      echo "ERROR: Systemd unit files ('$MOUNT_UNIT_FILE' or '$AUTOMOUNT_UNIT_FILE') already exist. Aborting."
      echo "       Use --unmount first if you want to replace the configuration."
      exit 1
  fi

  # 3. Prepare and handle credentials file
  # 3. Prepare and handle credentials file
  CREDENTIALS_FILE_NAME="credentials.${NAS_USER}@${SERVER_NAME}" # Use original server name here
  CREDENTIALS_FILE_PATH="${CREDENTIALS_DIR}/${CREDENTIALS_FILE_NAME}"
  if [ ! -f "$CREDENTIALS_FILE_PATH" ]; then
      # --- KORREKTUR HIER ---
      # Option A: printf verwenden (oft bevorzugt)
      CREDENTIALS_CONTENT=$(printf "username=%s\npassword=%s" "$NAS_USER" "$NAS_PASS")

      # Option B: Einfacher String mit echtem Zeilenumbruch (funktioniert auch gut)
      # CREDENTIALS_CONTENT="username=$NAS_USER
# password=$NAS_PASS"
      # --- ENDE KORREKTUR ---

      # Use write_file_content to handle test mode
      write_file_content "Create credentials file" "$CREDENTIALS_FILE_PATH" "$CREDENTIALS_CONTENT"
      # Set permissions only if not in test mode and file was created
      if [ "$TEST_MODE" = false ]; then
         execute_command "Set owner for credentials file" chown root:root "$CREDENTIALS_FILE_PATH"
         execute_command "Set permissions for credentials file" chmod 600 "$CREDENTIALS_FILE_PATH"
      fi
  else
      # ...
      echo "INFO: Credentials file '$CREDENTIALS_FILE_PATH' already exists. Using existing file."
      # Check permissions just in case
      CURRENT_PERMS=$(stat -c "%a" "$CREDENTIALS_FILE_PATH")
      CURRENT_OWNER=$(stat -c "%U:%G" "$CREDENTIALS_FILE_PATH")
       if [ "$CURRENT_PERMS" != "600" ] || [ "$CURRENT_OWNER" != "root:root" ]; then
           echo "WARNING: Existing credentials file '$CREDENTIALS_FILE_PATH' has incorrect permissions/owner ($CURRENT_PERMS, $CURRENT_OWNER). Should be 600 and root:root."
           # Optionally add commands to fix permissions here if desired
       fi
  fi

  # 4. Create .mount unit file content
  MOUNT_OPTIONS="credentials=${CREDENTIALS_FILE_PATH},uid=${LOCAL_UID},gid=${LOCAL_GID},iocharset=utf8,vers=${SMB_VERSION},nofail,_netdev,x-systemd.automount"
  MOUNT_UNIT_CONTENT=$(cat <<EOF
[Unit]
Description=Mount NAS Share $LOCAL_MOUNTPOINT
# Automatically manages network dependencies via Type=cifs and _netdev option

[Mount]
What=$WHAT_PATH
Where=$LOCAL_MOUNTPOINT
Type=cifs
Options=$MOUNT_OPTIONS
$RESOLVE_COMMENT

[Install]
WantedBy=multi-user.target
EOF
)
  # Use write_file_content to handle test mode
  write_file_content "Create .mount unit file" "$MOUNT_UNIT_FILE" "$MOUNT_UNIT_CONTENT"


  # 5. Create .automount unit file content
  AUTOMOUNT_UNIT_CONTENT=$(cat <<EOF
[Unit]
Description=Automount NAS Share $LOCAL_MOUNTPOINT
# Dependencies handled by the corresponding .mount unit

[Automount]
Where=$LOCAL_MOUNTPOINT
TimeoutIdleSec=0

[Install]
WantedBy=multi-user.target
EOF
)
   # Use write_file_content to handle test mode
  write_file_content "Create .automount unit file" "$AUTOMOUNT_UNIT_FILE" "$AUTOMOUNT_UNIT_CONTENT"

  # 6. Reload systemd and enable/start the automount unit
  execute_command "Reload systemd daemon configuration" systemctl daemon-reload
  execute_command "Enable and start the automount unit" systemctl enable --now "$SYSTEMD_BASE_NAME.automount"

  echo "*** MOUNT configuration potentially created/enabled for $LOCAL_MOUNTPOINT ***"
  if [ "$TEST_MODE" = true ]; then
      echo "*** REVIEW THE ABOVE STEPS CAREFULLY ***"
  else
      echo "*** Check status with: systemctl status $SYSTEMD_BASE_NAME.automount ***"
      echo "*** Access the mountpoint '$LOCAL_MOUNTPOINT' to trigger the mount. ***"
  fi

elif [ "$ACTION" == "unmount" ]; then
  echo "*** Preparing to UNMOUNT configuration for $LOCAL_MOUNTPOINT ***"

  AUTOMOUNT_UNIT_NAME="$SYSTEMD_BASE_NAME.automount"
  MOUNT_UNIT_NAME="$SYSTEMD_BASE_NAME.mount"

  # 1. Stop and disable the automount unit (best effort)
  echo "INFO: Stopping $AUTOMOUNT_UNIT_NAME (if active)..."
  if systemctl is-active --quiet "$AUTOMOUNT_UNIT_NAME"; then
      execute_command "Stop the automount unit" systemctl stop "$AUTOMOUNT_UNIT_NAME"
  else
      echo "INFO: Automount unit '$AUTOMOUNT_UNIT_NAME' was not active."
  fi

  echo "INFO: Disabling $AUTOMOUNT_UNIT_NAME (if enabled)..."
   if systemctl is-enabled --quiet "$AUTOMOUNT_UNIT_NAME"; then
      execute_command "Disable the automount unit" systemctl disable "$AUTOMOUNT_UNIT_NAME"
  else
       echo "INFO: Automount unit '$AUTOMOUNT_UNIT_NAME' was not enabled."
   fi

   # 2. Unmount the directory (best effort, might fail if busy)
   echo "INFO: Attempting to unmount '$LOCAL_MOUNTPOINT' (if mounted)..."
   if mountpoint -q "$LOCAL_MOUNTPOINT"; then
       # Use a separate function for umount as it might fail gracefully
       echo "--------------------------------------------------"
       echo "ACTION: Unmount $LOCAL_MOUNTPOINT"
       echo "COMMAND: umount $LOCAL_MOUNTPOINT"
       if [ "$TEST_MODE" = true ]; then
           echo "TEST MODE: Command not executed."
       else
            # Don't exit script if umount fails (target busy)
            if ! umount "$LOCAL_MOUNTPOINT"; then
                echo "WARNING: Failed to unmount '$LOCAL_MOUNTPOINT'. It might still be busy. Manual intervention may be needed."
            else
                 echo "SUCCESS: Unmounted '$LOCAL_MOUNTPOINT'."
            fi
       fi
       echo "--------------------------------------------------"
   else
        echo "INFO: '$LOCAL_MOUNTPOINT' was not mounted."
   fi

   # 3. Remove the unit files (best effort)
   if [ -f "$AUTOMOUNT_UNIT_FILE" ]; then
       execute_command "Remove .automount unit file" rm -f "$AUTOMOUNT_UNIT_FILE"
   else
       echo "INFO: Automount unit file '$AUTOMOUNT_UNIT_FILE' not found."
   fi
    if [ -f "$MOUNT_UNIT_FILE" ]; then
       execute_command "Remove .mount unit file" rm -f "$MOUNT_UNIT_FILE"
   else
        echo "INFO: Mount unit file '$MOUNT_UNIT_FILE' not found."
    fi

    # 4. Reload systemd
    execute_command "Reload systemd daemon configuration" systemctl daemon-reload

    echo "*** UNMOUNT configuration potentially removed for $LOCAL_MOUNTPOINT ***"
    echo "*** NOTE: Credentials file and mountpoint directory were NOT removed. ***"
     if [ "$TEST_MODE" = true ]; then
      echo "*** REVIEW THE ABOVE STEPS CAREFULLY ***"
    fi

fi

exit 0
