#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 027

# Notes:
# - Restores Samba + SSH configs and enables services.
# - Overwrites /etc/samba/smb.conf and /etc/ssh/sshd_config (with backups).
# - Restores ~/.ssh from backup and enforces strict permissions.
# - Does NOT restore LUKS header or /etc/fstab.

# Where backup configs live (should point to backup-usb.sh output)
USB_LABEL="${BKP_USB_LABEL:-netac}"
USB_USER="${SUDO_USER:-$USER}"
USB_MOUNT="/run/media/$USB_USER/$USB_LABEL"
USB_BASE="$USB_MOUNT/START"
resolve_backup_root() {
  local base="$1"
  shift
  local root=""
  local ok=0
  for root in "$base"; do
    ok=1
    for req in "$@"; do
      [[ -e "$root/$req" ]] || ok=0
    done
    if (( ok )); then
      printf '%s\n' "$root"
      return 0
    fi
  done
  local candidate
  candidate=$(ls -1dt "$base"/*/ 2>/dev/null | head -n1)
  candidate="${candidate%/}"
  if [[ -n "$candidate" ]]; then
    ok=1
    for req in "$@"; do
      [[ -e "$candidate/$req" ]] || ok=0
    done
    if (( ok )); then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi
  return 1
}
SMB_ROOT="/SMB"
SMB_SUBDIRS=(euclid pneuma SCP)
WSDD_SERVICE="wsdd.service"
SMB_SERVICES=(smb.service nmb.service avahi-daemon.service "$WSDD_SERVICE")
SSHD_SERVICE="sshd.service"
SMB_CONF_SRC="$SRV/samba/smb.conf"
SSHD_CONF_SRC="$SRV/ssh/sshd_config"
YUBI_SERVICE="pcscd"

log() { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }
status() { printf '%s\n' "$*" >/dev/tty; }
progress() {
  STEP=$((STEP + 1))
  printf '[%d/%d] %s\n' "$STEP" "$TOTAL_STEPS" "$*" >/dev/tty
}

TOTAL_STEPS=4
STEP=0

require_file() {
  [[ -f "$1" ]] || die "Required file not found: $1"
}

# Ensure we're root; if not, re-exec with sudo (preserve env)
if [[ $EUID -ne 0 ]]; then
  exec sudo -E -- "$0" "$@"
fi

if ! command -v mountpoint >/dev/null 2>&1; then
  die "mountpoint not found."
fi
if ! mountpoint -q "$USB_MOUNT"; then
  die "$USB_MOUNT is not a mountpoint. Is the USB plugged in and mounted?"
fi

BACKUP_ROOT="$(resolve_backup_root "$USB_BASE" Srv || true)"
if [[ -z "$BACKUP_ROOT" ]]; then
  die "Backup root not found under $USB_BASE"
fi
SRV="$BACKUP_ROOT/Srv"

RUN_AS_USER="${SUDO_USER:-${USER}}"
if ! id -u "$RUN_AS_USER" >/dev/null 2>&1; then
  die "User '$RUN_AS_USER' not found."
fi
RUN_AS_GROUP="$(id -gn "$RUN_AS_USER")"
USER_HOME="$(getent passwd "$RUN_AS_USER" | cut -d: -f6)"
TS="$(date +%Y%m%d%H%M%S)"
BACKUP_DIR="/var/backups/restore-serv-$TS"
mkdir -p "$BACKUP_DIR"

# Pre-flight checks
command -v systemctl >/dev/null || die "systemctl not found."
command -v modprobe  >/dev/null || die "modprobe not found."
command -v smbpasswd >/dev/null || die "smbpasswd (samba) not found."
command -v rsync     >/dev/null || die "rsync not found."
command -v sshd      >/dev/null || die "sshd not found."

if [[ ! -d "$SRV" ]]; then
  die "Backup directory not found: $SRV"
fi

if [[ -n "${BACKUP_ROOT:-}" ]]; then
  LOG_DIR="$BACKUP_ROOT/logs"
else
  LOG_DIR="$(dirname "$SRV")/logs"
fi
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/restore-serv-$(date +%Y%m%d%H%M%S).log"
exec >"$LOG_FILE" 2> >(tee -a "$LOG_FILE" >/dev/tty)
status "Restore services start: $(date -Is)"
status "Log: $LOG_FILE"

require_file "$SMB_CONF_SRC"
require_file "$SSHD_CONF_SRC"

# Kernel module for CIFS/SMB client
progress "Kernel module"
log "Loading CIFS kernel module (if available)…"
if ! modprobe cifs 2>/dev/null; then
  warn "Could not load cifs module (continuing)."
fi

# Samba configuration
progress "Samba config"
log "Installing smb.conf with secure permissions (root:root, 0644)…"
if [[ -d /etc/samba ]]; then
  log "Backing up /etc/samba to $BACKUP_DIR/etc-samba..."
  rsync -a --quiet /etc/samba/ "$BACKUP_DIR/etc-samba/"
fi
SMB_CONF_BAK="/etc/samba/smb.conf.$TS.bak"
install -D -o root -g root -m 0644 "$SMB_CONF_SRC" "$SMB_CONF_BAK"
install -D -o root -g root -m 0644 "$SMB_CONF_SRC" "/etc/samba/smb.conf"

log "Creating $SMB_ROOT and subdirectories with strict permissions…"
install -d -m 1750 "$SMB_ROOT"
for d in "${SMB_SUBDIRS[@]}"; do
  install -d -m 2750 "$SMB_ROOT/$d"
done

log "Setting ownership of $SMB_ROOT to $RUN_AS_USER:$RUN_AS_GROUP…"
chown -R "$RUN_AS_USER:$RUN_AS_GROUP" "$SMB_ROOT"

progress "Samba users/services"
if ! pdbedit -L 2>/dev/null | awk -F: '{print $1}' | grep -qx "$RUN_AS_USER"; then
  log "Adding Samba account for $RUN_AS_USER (you'll be prompted for a password)…"
  smbpasswd -a "$RUN_AS_USER"
else
  log "Samba account for $RUN_AS_USER already exists—skipping."
fi

log "Enabling and starting Samba-related services…"
for svc in "${SMB_SERVICES[@]}"; do
  systemctl enable --now "$svc"
done

if command -v testparm >/dev/null 2>&1; then
  log "Validating smb.conf…"
  if ! testparm -s /etc/samba/smb.conf >/dev/null 2>&1; then
    warn "smb.conf validation failed; restoring backup."
    if [[ -f "$SMB_CONF_BAK" ]]; then
      install -D -o root -g root -m 0644 "$SMB_CONF_BAK" "/etc/samba/smb.conf"
    fi
    for svc in "${SMB_SERVICES[@]}"; do
      systemctl restart "$svc" || true
    done
    die "smb.conf validation failed; backup restored. Fix errors and retry."
  fi
fi

for svc in "${SMB_SERVICES[@]}"; do
  if ! systemctl is-active --quiet "$svc"; then
    warn "Service failed: $svc. Restoring smb.conf backup."
    if [[ -f "$SMB_CONF_BAK" ]]; then
      install -D -o root -g root -m 0644 "$SMB_CONF_BAK" "/etc/samba/smb.conf"
    fi
    for s in "${SMB_SERVICES[@]}"; do
      systemctl restart "$s" || true
    done
    die "Samba services failed to start; backup restored. Fix errors and retry."
  fi
done

# SSH configuration
progress "SSH config"
SRC_SSH_DIR="$SRV/ssh/.ssh"
DEST_SSH_DIR="$USER_HOME/.ssh"

systemctl enable --now "$SSHD_SERVICE"
systemctl enable --now "$YUBI_SERVICE"

if [[ -d "$SRC_SSH_DIR" ]]; then
  log "Syncing SSH keys/config to $DEST_SSH_DIR…"
  if [[ -d "$DEST_SSH_DIR" ]]; then
    log "Backing up existing SSH directory to $BACKUP_DIR/ssh..."
    rsync -a --quiet "$DEST_SSH_DIR/" "$BACKUP_DIR/ssh/"
  fi
  install -d -o "$RUN_AS_USER" -g "$RUN_AS_GROUP" -m 0700 "$DEST_SSH_DIR"
  rsync -aH --quiet --delete "$SRC_SSH_DIR/" "$DEST_SSH_DIR/"
  chown -R "$RUN_AS_USER:$RUN_AS_GROUP" "$DEST_SSH_DIR"
  chmod 700 "$DEST_SSH_DIR"
  find "$DEST_SSH_DIR" -type f ! -name "*.pub" -exec chmod 600 {} +
  find "$DEST_SSH_DIR" -type f -name "*.pub" -exec chmod 644 {} +
else
  warn "Source SSH directory not found: $SRC_SSH_DIR (skipping key sync)."
fi

log "Installing sshd_config with secure permissions (root:root, 0600)…"
SSHD_CONF_BAK="/etc/ssh/sshd_config.$TS.bak"
install -D -o root -g root -m 0600 "$SSHD_CONF_SRC" "$SSHD_CONF_BAK"
install -o root -g root -m 0600 "$SSHD_CONF_SRC" "/etc/ssh/sshd_config"

log "Validating sshd_config…"
if sshd -t -f /etc/ssh/sshd_config; then
  log "sshd_config is valid. Enabling and (re)starting $SSHD_SERVICE…"
  systemctl enable --now "$SSHD_SERVICE"
else
  warn "sshd_config validation failed; restoring backup."
  if [[ -f "$SSHD_CONF_BAK" ]]; then
    install -o root -g root -m 0600 "$SSHD_CONF_BAK" "/etc/ssh/sshd_config"
  fi
  die "sshd_config validation failed; backup restored. Fix errors and retry."
fi

log "Service status summary:"
for svc in "${SMB_SERVICES[@]}" "$SSHD_SERVICE"; do
  systemctl --no-pager --full status "$svc" | sed -n '1,5p' || true
  echo "----"
done

status "Restore services done."
TARGET_ROOT="${BACKUP_ROOT:-$(dirname "$SRV")}"
status "Target: $TARGET_ROOT"
status "Log: $LOG_FILE"status "Restore services done."
