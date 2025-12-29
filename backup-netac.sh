#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

echo "------------------------------------------------------------------------------------"
# Notes:
# - This script is backup-only; it does not delete or modify source files.
# - LUKS header is backed up for recovery use only (no restore script touches it).
# - /etc/fstab is backed up as reference only (not restored).
# - Restore scripts expect the backup layout under $USB/Srv (grub, samba, ssh).

# Backup location on USB
USB_LABEL="${BKP_USB_LABEL:-netac}"
USB="/run/media/$USER/$USB_LABEL"
SRV="$USB/Srv"
DOTS="$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config/"
DIRS=(Documents Pictures Obsidian Working Shared VM Videos Code .icons .themes .zsh_history .zshrc .gitconfig)

# Ensure USB is actually mounted
if ! mountpoint -q "$USB"; then
  echo "ERROR: $USB is not a mountpoint. Is the USB plugged in and mounted?"
  exit 1
fi

# Prereqs
for cmd in rsync mountpoint sudo cryptsetup; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd"
    exit 1
  fi
done

# Ensure target dirs exist
mkdir -p "$USB"/{home,dots,Srv/{grub,ssh,samba}}

# Make local scripts executable (ignore if path missing)
chmod +x *.sh "$HOME/Working/bash" 2>/dev/null || true

echo "Starting backup to: $USB"

########################################
# LUKS header backup
########################################
TIMESTAMP=$(date '+%j-%Y-%H%M')
LUKS_HEADER_FILE="$USB/luks-header-$TIMESTAMP.img"
LUKS_DEVICE="${BKP_LUKS_DEVICE:-/dev/nvme0n1p2}"

if [[ -b "$LUKS_DEVICE" ]]; then
  echo "Backing up LUKS header of $LUKS_DEVICE to: $LUKS_HEADER_FILE"
  sudo cryptsetup luksHeaderBackup "$LUKS_DEVICE" --header-backup-file "$LUKS_HEADER_FILE"
else
  echo "Skipping LUKS header backup; device not found: $LUKS_DEVICE"
fi
########################################

# rsync directories from $DIRS
for d in "${DIRS[@]}"; do
  if [[ ! -e "$HOME/$d" ]]; then
    echo "Skipping missing $HOME/$d"
    continue
  fi
  rsync -Parh "$HOME/$d" "$USB/home/"
done

# rsync ml4w dotfiles
if [[ -d "$DOTS" ]]; then
  rsync -Parh "$DOTS" "$USB/dots/"
else
  echo "Skipping missing DOTS path: $DOTS"
fi

# .ssh without agent/
if [[ -d "$HOME/.ssh" ]]; then
  rsync -Parh --exclude 'agent/' "$HOME/.ssh/" "$SRV/ssh/.ssh/"
else
  echo "Skipping missing $HOME/.ssh"
fi

# Copy cursor pack and hyprctl settings
if [[ -d "$HOME/.local/share/icons/LyraX-cursors" ]]; then
  cp -r "$HOME/.local/share/icons/LyraX-cursors" "$USB/home/"
fi
if [[ -f "$HOME/.config/com.ml4w.hyprlandsettings/hyprctl.json" ]]; then
  cp "$HOME/.config/com.ml4w.hyprlandsettings/hyprctl.json" "$USB/dots/"
fi
if [[ -f "$HOME/.config/Thunar/uca.xml" ]]; then
  cp "$HOME/.config/Thunar/uca.xml" "$USB/dots/"
fi

echo "Copy Done..."
sleep 2

### System files (with sudo)
declare -A SYSTEM_PATHS=(
  ["/boot/grub/themes/lateralus"]="$SRV/grub/"
  ["/etc/default/grub"]="$SRV/grub/"
  ["/etc/mkinitcpio.conf"]="$SRV/mkinitcpio.conf"
  ["/usr/share/plymouth/plymouthd.defaults"]="$SRV/plymouthd.defaults"
  ["/etc/samba/smb.conf"]="$SRV/samba/smb.conf"
  ["/etc/samba/euclid"]="$SRV/samba/euclid"
  ["/etc/ssh/sshd_config"]="$SRV/ssh/sshd_config"
  # /etc/fstab is backup-only (not restored by restore scripts)
  ["/etc/fstab"]="$SRV/fstab"
)

for src in "${!SYSTEM_PATHS[@]}"; do
  if [[ ! -e "$src" ]]; then
    echo "Skipping missing $src"
    continue
  fi
  echo "Backing up $src..."
  sudo rsync -a "$src" "${SYSTEM_PATHS[$src]}"
done

echo "Backup done."
