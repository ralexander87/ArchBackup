#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

echo "------------------------------------------------------------------------------------"

TOTAL_STEPS=5
STEP=0
status() { printf '%s\n' "$*" >/dev/tty; }
progress() {
  STEP=$((STEP + 1))
  printf '[%d/%d] %s\n' "$STEP" "$TOTAL_STEPS" "$*" >/dev/tty
}
err() { printf '[!] %s\n' "$*" >/dev/tty; }

rsync_allow_partial() {
  set +e
  rsync "$@"
  local rc=$?
  set -e
  if [[ $rc -ne 0 && $rc -ne 23 && $rc -ne 24 ]]; then
    return $rc
  fi
  if [[ $rc -eq 23 || $rc -eq 24 ]]; then
    echo "[!] rsync completed with partial transfer (code $rc). Continuing."
  fi
  return 0
}

TS=$(date '+%j-%Y-%H%M')
BKP_BASE="/home/ralexander/Shared/ArchBKP"
printf 'Create compressed archive? [y/N]: ' >/dev/tty
read -r CREATE_ARCHIVE

BKP_FOLDER="$BKP_BASE/$TS"
BKP_TAR="$BKP_BASE/$TS.tar.gz"
LOG_FILE="$BKP_BASE/backup-rsync-$TS.log"
ROOT_DIR="$BKP_FOLDER/root"
HOME_DIR="$BKP_FOLDER/home"

cleanup() {
  if [[ -f "$BKP_TAR" ]]; then
    rm -f "$BKP_TAR"
  fi
}

trap 'err "Backup failed."; cleanup' ERR

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
mkdir -p "$BKP_BASE" "$BKP_FOLDER" "$ROOT_DIR" "$HOME_DIR"
exec >>"$LOG_FILE" 2>&1
status "Backup start: $(date -Is)"
status "Log: $LOG_FILE"
status "Target: $BKP_BASE"

##### Prereqs
REQUIRED_CMDS=(rsync tar sudo)
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "Missing required command: $cmd"
    exit 1
  fi
done

if [[ ! -w "$BKP_BASE" ]]; then
  err "Backup base not writable: $BKP_BASE"
  exit 1
fi

progress "Pre-flight checks"
##### System files (with sudo)
progress "System files"
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
  sudo rsync -a --quiet --chown="$USER:$USER" "$src" "$dest"
done

##### User files (except .ssh, handled separately)
progress "User files"
RSYNC_OPTS=(--human-readable --partial --partial-dir=.rsync-partial --quiet)
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
  rsync_allow_partial -a \
    "${RSYNC_OPTS[@]}" \
    "${EXCLUDE_ARGS[@]}" \
    "$HOME/$path" "$HOME_DIR/"
done

##### .ssh with exclude for agent/
progress "SSH keys"
if [[ -d "$HOME/.ssh" ]]; then
  echo "Backing up $HOME/.ssh (excluding agent/)..."
  rsync_allow_partial -a \
    "${RSYNC_OPTS[@]}" \
    --exclude 'agent/' \
    "$HOME/.ssh/" "$HOME_DIR/.ssh/"
else
  echo "Skipping missing $HOME/.ssh"
fi

##### Start bully the backup
progress "Archive"
if [[ "$CREATE_ARCHIVE" =~ ^[Yy]$ ]]; then
  echo "Compressing backup to $BKP_TAR ..."
  tar --ignore-failed-read -I pigz -cf "$BKP_TAR" -C "$BKP_BASE" "$TS"
  ARCHIVE_STATUS="$BKP_TAR"
else
  ARCHIVE_STATUS="skipped"
fi

status "Backup done."
status "Target: $BKP_BASE"
status "Archive: $ARCHIVE_STATUS"
status "Log: $LOG_FILE"
