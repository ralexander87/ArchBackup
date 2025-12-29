#!/usr/bin/env bash
set -euo pipefail  # safer: exit on error, unset vars, fail on pipe errors

echo "------------------------------------------------------------------------------------"

TIMESTAMP=$(date '+%j-%Y-%H%M')
BKP_BASE="$HOME/Shared/ArchBKP"
BKP_FOLDER="$BKP_BASE/$TIMESTAMP"
BKP_TAR="$BKP_BASE/$TIMESTAMP.tar.gz"
LOG_FILE="$BKP_FOLDER/backup.log"
ROOT_DIR="$BKP_FOLDER/root"
HOME_DIR="$BKP_FOLDER/home"

cleanup() {
  if [[ -f "$BKP_TAR" ]]; then
    rm -f "$BKP_TAR"
  fi
}

trap 'echo "Backup failed."; cleanup' ERR

##### Install pigz if it is not...
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

### Start BKP
mkdir -p "$BKP_FOLDER" "$ROOT_DIR" "$HOME_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Backup start: $(date -Is)"
echo "Starting BKP to: $BKP_FOLDER"

##### Prereqs
REQUIRED_CMDS=(rsync tar sudo)
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd"
    exit 1
  fi
done
echo "rsync version: $(rsync --version | head -n 1)"
echo "tar version: $(tar --version | head -n 1)"

if [[ ! -d "$BKP_BASE" ]]; then
  echo "Backup base does not exist: $BKP_BASE"
  exit 1
fi
if [[ ! -w "$BKP_BASE" ]]; then
  echo "Backup base not writable: $BKP_BASE"
  exit 1
fi

##### System files (with sudo)
SYSTEM_ITEMS=(
  "/boot/grub/themes/lateralus:$ROOT_DIR"
  "/etc/mkinitcpio.conf:$ROOT_DIR/mkinitcpio.conf"
  "/etc/default/grub:$ROOT_DIR/grub"
  "/usr/share/plymouth/plymouthd.defaults:$ROOT_DIR/plymouthd.defaults"
  "/etc/samba/smb.conf:$ROOT_DIR/smb.conf"
  "/etc/samba/euclid:$ROOT_DIR/euclid"
  "/etc/ssh/sshd_config:$ROOT_DIR/sshd_config"
  "/usr/lib/sddm/sddm.conf.d/default.conf:$ROOT_DIR/default.conf"
  "/etc/fstab:$ROOT_DIR/fstab"
)

for item in "${SYSTEM_ITEMS[@]}"; do
  src=${item%%:*}
  dest=${item#*:}
  if [[ ! -e "$src" ]]; then
    echo "Skipping missing $src"
    continue
  fi
  echo "Backing up $src..."
  mkdir -p "$(dirname "$dest")"
  sudo rsync -a --chown="$USER:$USER" "$src" "$dest"
done

##### User files (except .ssh, handled separately)
RSYNC_OPTS=(--human-readable --info=progress2 --partial --partial-dir=.rsync-partial)
EXCLUDES=(
  ".config/*/Cache/"
  ".config/*/cache/"
  ".config/*/Code Cache/"
  ".config/*/GPUCache/"
  ".config/*/CachedData/"
  ".config/*/CacheStorage/"
  ".config/*/Service Worker/"
  ".config/*/IndexedDB/"
  ".config/*/Local Storage/"
)
EXCLUDE_ARGS=()
for pattern in "${EXCLUDES[@]}"; do
  EXCLUDE_ARGS+=(--exclude="$pattern")
done
USER_PATHS=(Documents Obsidian Working Code .icons .themes .config .zshrc .zsh_history .mydotfiles .gitconfig)

for path in "${USER_PATHS[@]}"; do
  if [[ ! -e "$HOME/$path" ]]; then
    echo "Skipping missing $HOME/$path"
    continue
  fi
  echo "Backing up $HOME/$path..."
  rsync -a \
    "${RSYNC_OPTS[@]}" \
    "${EXCLUDE_ARGS[@]}" \
    "$HOME/$path" "$HOME_DIR/"
done

##### .ssh with exclude for agent/
if [[ -d "$HOME/.ssh" ]]; then
  echo "Backing up $HOME/.ssh (excluding agent/)..."
  rsync -a \
    "${RSYNC_OPTS[@]}" \
    --exclude 'agent/' \
    "$HOME/.ssh/" "$HOME_DIR/.ssh/"
else
  echo "Skipping missing $HOME/.ssh"
fi

##### Start bully the backup
echo "Compressing backup to $BKP_TAR ..."
tar -I pigz -cf "$BKP_TAR" -C "$BKP_BASE" "$TIMESTAMP"

echo "Bully complete."
echo "Uncompressed folder: $BKP_FOLDER"
echo "Compressed archive : $BKP_TAR"
du -sh "$BKP_FOLDER" "$BKP_TAR"
echo "Backed up user paths:"
for path in "${USER_PATHS[@]}"; do
  echo "  $HOME/$path"
done
echo "Backed up system paths:"
for item in "${SYSTEM_ITEMS[@]}"; do
  echo "  ${item%%:*}"
done
echo "Backup end: $(date -Is)"
