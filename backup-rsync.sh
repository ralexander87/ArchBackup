#!/usr/bin/env bash
set -euo pipefail  # safer: exit on error, unset vars, fail on pipe errors

echo "------------------------------------------------------------------------------------"

TIMESTAMP=$(date '+%j-%Y-%R')
BKP_BASE="$HOME/Shared/ArchBKP"
BKP_FOLDER="$BKP_BASE/$TIMESTAMP"
BKP_TAR="$BKP_BASE/$TIMESTAMP.tar.gz"

##### Install pigz if it is not...
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

### Start BKP
mkdir -p "$BKP_FOLDER"
echo "Starting fucking BKP to: $BKP_FOLDER"

##### System files (with sudo)
declare -A SYSTEM_PATHS=(
    ["/boot/grub/themes/lateralus"]="$BKP_FOLDER"
    ["/etc/mkinitcpio.conf"]="$BKP_FOLDER/mkinitcpio.conf"
    ["/etc/default/grub"]="$BKP_FOLDER/grub"
    ["/usr/share/plymouth/plymouthd.defaults"]="$BKP_FOLDER/plymouthd.defaults"
    ["/etc/samba/smb.conf"]="$BKP_FOLDER/smb.conf"
    ["/etc/samba/euclid"]="$BKP_FOLDER/euclid"
    ["/etc/ssh/sshd_config"]="$BKP_FOLDER/sshd_config"
    ["/usr/lib/sddm/sddm.conf.d/default.conf"]="$BKP_FOLDER/default.conf"
    ["/etc/fstab"]="$BKP_FOLDER/fstab"
)

for src in "${!SYSTEM_PATHS[@]}"; do
    echo "Backing up $src..."
    sudo rsync -a --chown="$USER:$USER" "$src" "${SYSTEM_PATHS[$src]}"
done

##### User files (except .ssh, handled separately)
USER_PATHS=(Documents Obsidian Working Code .icons .themes .config .zshrc .zsh_history .gitconfig)

for path in "${USER_PATHS[@]}"; do
    echo "Backing up $HOME/$path..."
    rsync -a "$HOME/$path" "$BKP_FOLDER/"
done

##### .ssh with exclude for agent/
echo "Backing up $HOME/.ssh (excluding agent/)..."
rsync -a \
  --exclude 'agent/' \
  "$HOME/.ssh/" "$BKP_FOLDER/.ssh/"

##### Start bully the backup
echo "Compressing backup to $BKP_TAR ..."
sudo tar -I pigz -cf "$BKP_TAR" -C "$BKP_BASE" "$TIMESTAMP"

echo "Bully complete."
echo "Uncompressed folder: $BKP_FOLDER"
echo "Compressed archive : $BKP_TAR"
