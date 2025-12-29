#!/usr/bin/env bash
set -euo pipefail
echo "------------------------------------------------------------------------------------"

# Backup location on USB
BKP_ROOT="/run/media/$USER/Lateralus"
TIMESTAMP=$(date '+%j-%Y-%H%M')
BKP_BASE="$BKP_ROOT/BKP"
BKP_FOLDER="$BKP_BASE/$TIMESTAMP"
ROOT_DIR="$BKP_FOLDER/root"
HOME_DIR="$BKP_FOLDER/home"

LOG_DIR="$BKP_BASE/logs"
LOG_FILE="$LOG_DIR/backup-full-ssd-$TIMESTAMP.log"
ARCHIVE_FILE="$BKP_BASE/full-backup-$TIMESTAMP.tar.gz"

# Ensure USB is actually mounted
if ! mountpoint -q "$BKP_ROOT"; then
  echo "ERROR: $BKP_ROOT is not a mountpoint. Is the USB plugged in and mounted?"
  exit 1
fi

# Prereqs
REQUIRED_CMDS=(rsync mountpoint sudo cryptsetup)
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd"
    exit 1
  fi
done
if ! command -v sha256sum >/dev/null 2>&1; then
  echo "Missing required command: sha256sum"
  exit 1
fi

if [[ ! -w "$BKP_ROOT" ]]; then
  echo "Backup root not writable: $BKP_ROOT"
  exit 1
fi

MIN_FREE_GB=20
FREE_GB=$(df -P -BG "$BKP_ROOT" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
if [[ -n "$FREE_GB" && "$FREE_GB" -lt "$MIN_FREE_GB" ]]; then
  echo "Not enough free space on $BKP_ROOT: ${FREE_GB}G available, need ${MIN_FREE_GB}G"
  exit 1
fi

mkdir -p "$BKP_FOLDER" "$ROOT_DIR" "$HOME_DIR" "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Backup start: $(date -Is)"
echo "Starting full BKP to: $BKP_FOLDER"

# Install pigz if it is not installed
if ! command -v pigz >/dev/null 2>&1; then
  echo "pigz not found, installing..."
  if command -v pacman >/dev/null 2>&1; then
    if [[ $EUID -ne 0 ]]; then
      sudo pacman -S --noconfirm pigz
    else
      pacman -S --noconfirm pigz
    fi
  else
    echo "pacman not available; install pigz manually."
    exit 1
  fi
else
  echo "pigz already installed, continuing..."
fi

# Determine which home to back up (avoid backing up /root by accident)
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
  SRC_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  SRC_HOME="$HOME"
fi

########################################
# LUKS header backup
########################################
LUKS_HEADER_FILE="$BKP_BASE/luks-header-$TIMESTAMP.img"
LUKS_DEVICE="/dev/nvme0n1p2"

if [[ -b "$LUKS_DEVICE" ]]; then
  echo "Backing up LUKS header of $LUKS_DEVICE to: $LUKS_HEADER_FILE"
  sudo cryptsetup luksHeaderBackup "$LUKS_DEVICE" --header-backup-file "$LUKS_HEADER_FILE"
else
  echo "Skipping LUKS header backup; device not found: $LUKS_DEVICE"
fi
########################################

##### System files (with sudo, preserving paths under root/)
SYSTEM_PATHS=(
  "/boot/grub/themes/lateralus"
  "/etc/default/grub"
  "/etc/mkinitcpio.conf"
  "/usr/share/plymouth/plymouthd.defaults"
  "/etc/samba/smb.conf"
  "/etc/samba/euclid"
  "/etc/ssh/sshd_config"
  "/usr/lib/sddm/sddm.conf.d/default.conf"
  "/etc/fstab"
)

for src in "${SYSTEM_PATHS[@]}"; do
  if [[ ! -e "$src" ]]; then
    echo "Skipping missing $src"
    continue
  fi
  echo "Backing up $src..."
  sudo rsync -aR "$src" "$ROOT_DIR/"
done

##### User files
echo "Backing up $SRC_HOME..."
rsync -aAXP \
  --exclude=".cache/" \
  --exclude=".var/app/" \
  --exclude=".subversion/" \
  --exclude=".mozilla/" \
  --exclude=".local/share/fonts/" \
  --exclude=".vscode-oss/" \
  --exclude="Trash/" \
  "$SRC_HOME/" "$HOME_DIR/$(basename "$SRC_HOME")/"

echo "Compressing full backup to: $ARCHIVE_FILE"
tar -I pigz -cf "$ARCHIVE_FILE" -C "$BKP_BASE" "$TIMESTAMP"
echo "Archive checksum:"
sha256sum "$ARCHIVE_FILE"

echo "Backed up system paths:"
for src in "${SYSTEM_PATHS[@]}"; do
  echo "  $src"
done
echo "Backed up user home: $SRC_HOME"

echo "Bully complete."
echo "Uncompressed folder: $BKP_FOLDER"
echo "Compressed archive : $ARCHIVE_FILE"
echo "LUKS header backup:  $LUKS_HEADER_FILE"
echo "Log file:            $LOG_FILE"
echo "Backup end: $(date -Is)"

##### Keep only last 3 backups (folders + archives)
shopt -s nullglob
folders=("$BKP_BASE"/[0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9])
if (( ${#folders[@]} > 3 )); then
  IFS=$'\n' sorted_dirs=($(ls -1td "${folders[@]}"))
  for old in "${sorted_dirs[@]:3}"; do
    echo "Removing old backup folder: $old"
    rm -rf "$old"
  done
fi
archives=("$BKP_BASE"/full-backup-*.tar.gz)
if (( ${#archives[@]} > 3 )); then
  IFS=$'\n' sorted_archives=($(ls -1t "${archives[@]}"))
  for old in "${sorted_archives[@]:3}"; do
    echo "Removing old archive: $old"
    rm -f "$old"
  done
fi
shopt -u nullglob
