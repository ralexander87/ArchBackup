#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

echo "------------------------------------------------------------------------------------"
# Notes:
# - This script is backup-only; it does not delete or modify source files.
# - LUKS header is backed up for recovery use only (no restore script touches it).
# - /etc/fstab is backed up as reference only (not restored).
# - Restore scripts expect the backup layout under $USB/Srv (grub, samba, ssh).

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

select_mountpoint() {
  local user="${SUDO_USER:-$USER}"
  local -a mounts=()
  local -a descs=()
  local line
  while read -r line; do
    eval "$line"
    [[ "${TYPE:-}" != "part" ]] && continue
    [[ -z "${MOUNTPOINT:-}" ]] && continue
    if [[ "$MOUNTPOINT" != "/run/media/$user/"* && "$MOUNTPOINT" != "/media/$user/"* ]]; then
      continue
    fi
    mounts+=("$MOUNTPOINT")
    descs+=("$MOUNTPOINT ($NAME, ${SIZE:-?}, ${TRAN:-?}, ${MODEL:-unknown})")
  done < <(lsblk -P -o NAME,MOUNTPOINT,TRAN,SIZE,MODEL,TYPE)

  if (( ${#mounts[@]} == 0 )); then
    err "No mounted external devices found under /run/media/$user or /media/$user."
    exit 1
  fi

  printf 'Select target device:\n' >/dev/tty
  local i
  for i in "${!mounts[@]}"; do
    printf '  %d) %s\n' $((i + 1)) "${descs[$i]}" >/dev/tty
  done
  printf 'Enter number: ' >/dev/tty
  read -r choice
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#mounts[@]} )); then
    err "Invalid selection."
    exit 1
  fi
  SELECTED_MOUNT="${mounts[$((choice - 1))]}"
}

TS=$(date '+%j-%Y-%H%M')
select_mountpoint

printf 'Create timestamped directory under %s? [y/N]: ' "$SELECTED_MOUNT" >/dev/tty
read -r create_dir
if [[ "$create_dir" =~ ^[Yy]$ ]]; then
  USB="$SELECTED_MOUNT/$TS"
  mkdir -p "$USB"
  CREATED_DIR="yes"
else
  USB="$SELECTED_MOUNT"
  CREATED_DIR="no"
fi

printf 'Target: %s\n' "$USB" >/dev/tty
printf 'Proceed with backup? [y/N]: ' >/dev/tty
read -r confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  status "Cancelled."
  exit 0
fi

SRV="$USB/Srv"
DOTS="$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config/"
DIRS=(Documents Pictures Obsidian Working Shared VM Videos Code .icons .themes .zsh_history .zshrc .gitconfig)

# Prereqs
for cmd in rsync mountpoint sudo cryptsetup; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "Missing required command: $cmd"
    exit 1
  fi
done

if ! mountpoint -q "$SELECTED_MOUNT"; then
  err "ERROR: $SELECTED_MOUNT is not a mountpoint."
  exit 1
fi

LOG_TS=$(date '+%Y%m%d%H%M%S')
LOG_DIR="$USB/logs"
LOG_FILE="$LOG_DIR/backup-usb-$LOG_TS.log"
mkdir -p "$LOG_DIR"
exec >"$LOG_FILE" 2> >(tee -a "$LOG_FILE" >/dev/tty)
status "Backup start: $(date -Is)"
status "Log: $LOG_FILE"
status "Target: $USB (new dir: $CREATED_DIR)"

# Ensure target dirs exist
mkdir -p "$USB"/{home,dots,Srv/{grub,ssh,samba}}

# Make local scripts executable (ignore if path missing)
chmod +x *.sh "$HOME/Working/bash" 2>/dev/null || true

progress "Pre-flight checks"

########################################
# LUKS header backup
########################################
LUKS_HEADER_FILE="$USB/luks-header-$TS.img"
LUKS_DEVICE="${BKP_LUKS_DEVICE:-/dev/nvme0n1p2}"

if [[ -b "$LUKS_DEVICE" ]]; then
  echo "Backing up LUKS header of $LUKS_DEVICE to: $LUKS_HEADER_FILE"
  sudo cryptsetup luksHeaderBackup "$LUKS_DEVICE" --header-backup-file "$LUKS_HEADER_FILE"
else
  echo "Skipping LUKS header backup; device not found: $LUKS_DEVICE"
fi
########################################

# rsync directories from $DIRS
progress "User files"
for d in "${DIRS[@]}"; do
  if [[ ! -e "$HOME/$d" ]]; then
    echo "Skipping missing $HOME/$d"
    continue
  fi
  rsync_allow_partial -arh --quiet --partial --partial-dir=.rsync-partial "$HOME/$d" "$USB/home/"
done

# rsync ml4w dotfiles
progress "Dotfiles and SSH"
if [[ -d "$DOTS" ]]; then
  rsync_allow_partial -arh --quiet --partial --partial-dir=.rsync-partial "$DOTS" "$USB/dots/"
else
  echo "Skipping missing DOTS path: $DOTS"
fi

# .ssh without agent/
if [[ -d "$HOME/.ssh" ]]; then
  rsync_allow_partial -arh --quiet --partial --partial-dir=.rsync-partial --exclude 'agent/' "$HOME/.ssh/" "$SRV/ssh/.ssh/"
else
  echo "Skipping missing $HOME/.ssh"
fi

# Copy cursor pack and hyprctl settings
progress "Extras"
if [[ -d "$HOME/.local/share/icons/LyraX-cursors" ]]; then
  cp -r "$HOME/.local/share/icons/LyraX-cursors" "$USB/home/"
fi
if [[ -f "$HOME/.config/com.ml4w.hyprlandsettings/hyprctl.json" ]]; then
  cp "$HOME/.config/com.ml4w.hyprlandsettings/hyprctl.json" "$USB/dots/"
fi
if [[ -f "$HOME/.config/Thunar/uca.xml" ]]; then
  cp "$HOME/.config/Thunar/uca.xml" "$USB/dots/"
fi

### System files (with sudo)
progress "System files"
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
  sudo rsync -a --quiet "$src" "${SYSTEM_PATHS[$src]}"
done

status "Backup done."
