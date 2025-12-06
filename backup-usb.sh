#!/bin/bash

### Script who alos include `Home backup` script
### Var
USB="/run/media/ralexander/netac" # Make sure that name is: netac
SRV="$USB/Srv"
DOTS="$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config/"
DIRS=(Documents Pictures Obsidian Working Shared VM Videos Code .icons .themes .zsh_history .zshrc .gitconfig)

# Add `chmod +x` to bash directory
chmod +x *.sh "$HOME/Working/bash"

# Create, if not, 3 main directory to $USB
# Sanity check: echo "$USB"/{home,dots,Srv/{grub,ssh,samba}}
## List what will be created
mkdir -p $USB/{home,dots,Srv/{grub,ssh,samba}}
sleep 2

### Run bkp
set -e

# rsync directories from `$DIRS` variable 
for d in "${DIRS[@]}"; do
  rsync -Parh "$HOME/$d" "$USB/home"
done

########################################
# LUKS header backup
########################################
TIMESTAMP=$(date '+%j-%Y-%R')
LUKS_HEADER_FILE="$USB/luks-header-$TIMESTAMP.img"

echo "Backing up LUKS header of /dev/nvme0n1p2 to: $LUKS_HEADER_FILE"
sudo cryptsetup luksHeaderBackup /dev/nvme0n1p2 --header-backup-file "$LUKS_HEADER_FILE"
########################################

# Remove agent content from .ssh, and then rsync rest of content
# rsync ml4w dotfiles
sleep 2
rsync -Parh "$DOTS" "$USB/dots"
rsync -Parh "$HOME/.ssh" "$SRV/ssh/"
rm -rf "$SRV/ssh/.ssh/agent"

# Copy cursor pack and hyprctl settings
sleep 2
cp -r "$HOME/.local/share/icons/LyraX-cursors" "$USB/home/"
cp "$HOME/.config/com.ml4w.hyprlandsettings/hyprctl.json" "$USB/dots"/
cp "$HOME/.config/Thunar/uca.xml" "$USB/dots/"

echo "Copy Done..."
sleep 5 ; clear

### System files (with sudo)
declare -A SYSTEM_PATHS=(
  ["/boot/grub/themes/lateralus"]="$SRV/grub/"
  ["/etc/default/grub"]="$SRV/grub/"
  ["/etc/mkinitcpio.conf"]="$SRV/mkinitcpio.conf"
  ["/usr/share/plymouth/plymouthd.defaults"]="$SRV/plymouthd.defaults"
  ["/etc/samba/smb.conf"]="$SRV/samba/smb.conf"
  ["/etc/samba/euclid"]="$SRV/samba/euclid"
  ["/etc/ssh/sshd_config"]="$SRV/ssh/sshd_config"
  ["/etc/fstab"]="$SRV/ssh/fstab"
)

for src in "${!SYSTEM_PATHS[@]}"; do
  echo "Backing up $src..."
  sudo rsync -a "$src" "${SYSTEM_PATHS[$src]}"
done

# Separate restore scripts
cp ~/Working/bash/01-restore-main.sh "$USB/"
cp ~/Working/bash/restore-dots.sh "$USB/dots/"
cp ~/Working/bash/restore-grub.sh "$SRV/grub/"
cp ~/Working/bash/restore-serv.sh "$SRV/"
sleep 2
