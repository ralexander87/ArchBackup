#!/bin/bash

# Hardened setup for SMB (Samba) + SSH
# - Escalates to sudo if needed
# - Uses safe defaults, checks, backups, permissions
# - Validates sshd_config before applying
# - Idempotent where possible

set -euo pipefail
IFS=$'\n\t'
umask 027

### --- Config you can tweak ---
SRV="${SRV:-$HOME/Srv}"            # where your configs live
SMB_ROOT="/SMB"                    # top-level share directory
SMB_SUBDIRS=(euclid pneuma SCP)    # subdirectories
WSDD_SERVICE="wsdd.service"        # discoverability for Windows
SMB_SERVICES=(smb.service nmb.service avahi-daemon.service "$WSDD_SERVICE")
SSHD_SERVICE="sshd.service"
SMB_CONF_SRC="$SRV/samba/smb.conf"
SSHD_CONF_SRC="$SRV/ssh/sshd_config"

### ----------------------------

# Ensure we're root; if not, re-exec with sudo (preserve env)
if [[ $EUID -ne 0 ]]; then
  exec sudo -E -- "$0" "$@"
fi

# Determine the real login user (not root) for ownership and smbpasswd
RUN_AS_USER="${SUDO_USER:-${USER}}"
if ! id -u "$RUN_AS_USER" >/dev/null 2>&1; then
  echo "Error: user '$RUN_AS_USER' not found." >&2
  exit 1
fi
RUN_AS_GROUP="$(id -gn "$RUN_AS_USER")"
USER_HOME="$(getent passwd "$RUN_AS_USER" | cut -d: -f6)"

log() { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

require_file() {
  [[ -f "$1" ]] || die "Required file not found: $1"
}

# --- Pre-flight checks ---
require_file "$SMB_CONF_SRC"
require_file "$SSHD_CONF_SRC"

command -v systemctl >/dev/null || die "systemctl not found."
command -v modprobe  >/dev/null || die "modprobe not found."
command -v smbpasswd >/dev/null || die "smbpasswd (samba) not found."
command -v rsync     >/dev/null || die "rsync not found."
command -v sshd      >/dev/null || die "sshd not found."

# --- Kernel module for CIFS/SMB client (optional but harmless) ---
log "Loading CIFS kernel module (if available)…"
if ! modprobe cifs 2>/dev/null; then
  warn "Could not load cifs module (continuing)."
fi

# --- Samba configuration ---
log "Installing smb.conf with secure permissions (root:root, 0644)…"
install -D -o root -g root -m 0644 "$SMB_CONF_SRC" "/etc/samba/smb.conf.$(date +%Y%m%d%H%M%S).bak"
install -D -o root -g root -m 0644 "$SMB_CONF_SRC" "/etc/samba/smb.conf"

# Create SMB root and subdirs with restrictive perms.
#  - SMB_ROOT: 1750 (sticky + no world access)
#  - subdirs:  2750 (setgid so group sticks; adjust to your policy)
log "Creating $SMB_ROOT and subdirectories with strict permissions…"
install -d -m 1750 "$SMB_ROOT"
for d in "${SMB_SUBDIRS[@]}"; do
  install -d -m 2750 "$SMB_ROOT/$d"
done

# Ownership to the login user & primary group (adjust to 'sambashare' if desired)
log "Setting ownership of $SMB_ROOT to $RUN_AS_USER:$RUN_AS_GROUP…"
chown -R "$RUN_AS_USER:$RUN_AS_GROUP" "$SMB_ROOT"

# Add Samba user if missing (non-interactive add will prompt for password)
if ! pdbedit -L 2>/dev/null | awk -F: '{print $1}' | grep -qx "$RUN_AS_USER"; then
  log "Adding Samba account for $RUN_AS_USER (you'll be prompted for a password)…"
  smbpasswd -a "$RUN_AS_USER"
else
  log "Samba account for $RUN_AS_USER already exists—skipping."
fi

# Enable & start Samba-related services
log "Enabling and starting Samba-related services…"
for svc in "${SMB_SERVICES[@]}"; do
  systemctl enable --now "$svc"
done

# --- SSH configuration ---
# Sync user .ssh from $SRV to the user's home, then lock down perms
SRC_SSH_DIR="$SRV/ssh/.ssh"
DEST_SSH_DIR="$USER_HOME/.ssh"

sudo systemctl enable "$SSHD_SERVICE" ; sleep 2
sudo systemctl start "$SSHD_SERVICE" ; sleep 2

if [[ -d "$SRC_SSH_DIR" ]]; then
  log "Syncing SSH keys/config to $DEST_SSH_DIR…"
  install -d -o "$RUN_AS_USER" -g "$RUN_AS_GROUP" -m 0700 "$DEST_SSH_DIR"
  # Preserve perms/ownership; then harden after
  rsync -PraH --delete "$SRC_SSH_DIR/" "$DEST_SSH_DIR/"
  chown -R "$RUN_AS_USER:$RUN_AS_GROUP" "$DEST_SSH_DIR"

  # Harden permissions: 700 for dir, 600 for files, 644 for known public files
  chmod 700 "$DEST_SSH_DIR"
  find "$DEST_SSH_DIR" -type f ! -name "*.pub" -exec chmod 600 {} +
  find "$DEST_SSH_DIR" -type f -name "*.pub" -exec chmod 644 {} +
else
  warn "Source SSH directory not found: $SRC_SSH_DIR (skipping key sync)."
fi

# Install sshd_config with backup and strict perms, validate, then enable/restart
log "Installing sshd_config with secure permissions (root:root, 0600)…"
install -D -o root -g root -m 0600 "$SSHD_CONF_SRC" "/etc/ssh/sshd_config.$(date +%Y%m%d%H%M%S).bak"
install -o root -g root -m 0600 "$SSHD_CONF_SRC" "/etc/ssh/sshd_config"

log "Validating sshd_config…"
if sshd -t -f /etc/ssh/sshd_config; then
  log "sshd_config is valid. Enabling and (re)starting $SSHD_SERVICE…"
  systemctl enable --now "$SSHD_SERVICE"
else
  die "sshd_config validation failed; not restarting SSH. Restore the backup and fix errors."
fi

# --- Final health checks ---
log "Service status summary:"
for svc in "${SMB_SERVICES[@]}" "$SSHD_SERVICE"; do
  systemctl --no-pager --full status "$svc" | sed -n '1,5p' || true
  echo "----"
done

log "Done. Consider restricting your firewall to LAN and enabling only required ports (e.g., OpenSSH, Samba)."

