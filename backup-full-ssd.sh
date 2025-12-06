#!/bin/bash

set -euo pipefail
echo "------------------------------------------------------------------------------------"

# Backup location on USB
BKP_ROOT="/run/media/$USER/Lateralus"
BKP_BASE="$BKP_ROOT/BKP"
BKP_FOLDER="$BKP_BASE"

# Ensure USB is actually mounted
if ! mountpoint -q "$BKP_ROOT"; then
  echo "ERROR: $BKP_ROOT is not a mountpoint. Is the USB plugged in and mounted?"
  exit 1
fi

# Install pigz if it is not installed
if ! command -v pigz >/dev/null 2>&1; then
  echo "pigz not found, installing..."
  if [[ $EUID -ne 0 ]]; then
    sudo pacman -S --noconfirm pigz
  else
    pacman -S --noconfirm pigz
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

mkdir -p "$BKP_FOLDER"
echo "Starting fucking BKP to: $BKP_FOLDER"

########################################
# LUKS header backup
########################################
TIMESTAMP=$(date '+%j-%Y-%R')
LUKS_HEADER_FILE="$BKP_BASE/luks-header-$TIMESTAMP.img"

echo "Backing up LUKS header of /dev/nvme0n1p2 to: $LUKS_HEADER_FILE"
sudo cryptsetup luksHeaderBackup /dev/nvme0n1p2 --header-backup-file "$LUKS_HEADER_FILE"
########################################

##### System files (with sudo, preserving paths)
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
  echo "Backing up $src..."
  sudo rsync -aR "$src" "$BKP_FOLDER/"
done

##### User files
echo "Backing up $SRC_HOME..."
rsync -aAXP \
  --delete-after \
  --exclude=".cache/" \
  --exclude=".var/app/" \
  --exclude=".subversion/" \
  --exclude=".mozilla/" \
  --exclude=".local/share/fonts/" \
  --exclude="Trash/" \
  "$SRC_HOME/" "$BKP_FOLDER/$(basename "$SRC_HOME")/"

# Optional: create compressed archive of HOME using pigz
# ARCHIVE="$BKP_BASE/home-$(date +%F_%H-%M-%S).tar.gz"
# echo "Creating compressed archive: $ARCHIVE"
# tar -C "$(dirname "$SRC_HOME")" -I pigz -cvf "$ARCHIVE" "$(basename "$SRC_HOME")"

echo "Bully complete."
echo "Uncompressed folder: $BKP_FOLDER"
echo "LUKS header backup:  $LUKS_HEADER_FILE"


