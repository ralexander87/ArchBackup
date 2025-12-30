#!/usr/bin/env bash
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
  BASE_DIR="$SELECTED_MOUNT/$TS"
  mkdir -p "$BASE_DIR"
  CREATED_DIR="yes"
else
  BASE_DIR="$SELECTED_MOUNT"
  CREATED_DIR="no"
fi

printf 'Target: %s\n' "$BASE_DIR" >/dev/tty
printf 'Proceed with backup? [y/N]: ' >/dev/tty
read -r confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  status "Cancelled."
  exit 0
fi

# Backup location on selected device
BKP_BASE="$BASE_DIR"
BKP_FOLDER="$BKP_BASE/$TS"
ROOT_DIR="$BKP_FOLDER/root"
HOME_DIR="$BKP_FOLDER/home"
LOG_DIR="$BKP_BASE/logs"
LOG_FILE="$LOG_DIR/backup-full-ssd-$TS.log"
ARCHIVE_FILE="$BKP_BASE/full-backup-$TS.tar.gz"

# Prereqs
REQUIRED_CMDS=(rsync mountpoint sudo cryptsetup)
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "Missing required command: $cmd"
    exit 1
  fi
done
if ! command -v sha256sum >/dev/null 2>&1; then
  err "Missing required command: sha256sum"
  exit 1
fi

if ! mountpoint -q "$SELECTED_MOUNT"; then
  err "ERROR: $SELECTED_MOUNT is not a mountpoint."
  exit 1
fi

if [[ ! -w "$BASE_DIR" ]]; then
  err "Backup root not writable: $BASE_DIR"
  exit 1
fi

MIN_FREE_GB=20
FREE_GB=$(df -P -BG "$SELECTED_MOUNT" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
if [[ -n "$FREE_GB" && "$FREE_GB" -lt "$MIN_FREE_GB" ]]; then
  err "Not enough free space on $SELECTED_MOUNT: ${FREE_GB}G available, need ${MIN_FREE_GB}G"
  exit 1
fi

mkdir -p "$BKP_FOLDER" "$ROOT_DIR" "$HOME_DIR" "$LOG_DIR"
exec >"$LOG_FILE" 2> >(tee -a "$LOG_FILE" >/dev/tty)
status "Backup start: $(date -Is)"
status "Log: $LOG_FILE"
status "Target: $BASE_DIR (new dir: $CREATED_DIR)"

progress "Pre-flight checks"
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

progress "LUKS header (if present)"
# Determine which home to back up (avoid backing up /root by accident)
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
  SRC_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  SRC_HOME="$HOME"
fi

########################################
# LUKS header backup
########################################
LUKS_HEADER_FILE="$BKP_BASE/luks-header-$TS.img"
LUKS_DEVICE="/dev/nvme0n1p2"

if [[ -b "$LUKS_DEVICE" ]]; then
  echo "Backing up LUKS header of $LUKS_DEVICE to: $LUKS_HEADER_FILE"
  sudo cryptsetup luksHeaderBackup "$LUKS_DEVICE" --header-backup-file "$LUKS_HEADER_FILE"
else
  echo "Skipping LUKS header backup; device not found: $LUKS_DEVICE"
fi
########################################

progress "System files"
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
  sudo rsync -aR --quiet "$src" "$ROOT_DIR/"
done

##### User files
progress "User home"
echo "Backing up $SRC_HOME..."
rsync_allow_partial -aAX --quiet --partial --partial-dir=.rsync-partial \
  --exclude=".cache/" \
  --exclude=".var/app/" \
  --exclude=".subversion/" \
  --exclude=".mozilla/" \
  --exclude=".local/share/fonts/" \
  --exclude=".vscode-oss/" \
  --exclude="Trash/" \
  "$SRC_HOME/" "$HOME_DIR/$(basename "$SRC_HOME")/"

progress "Archive"
echo "Compressing full backup to: $ARCHIVE_FILE"
tar --ignore-failed-read -I pigz -cf "$ARCHIVE_FILE" -C "$BKP_BASE" "$TS"
echo "Archive checksum:"
sha256sum "$ARCHIVE_FILE"

echo "Bully complete."

status "Backup done: $ARCHIVE_FILE"
