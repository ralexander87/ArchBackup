#!/usr/bin/env bash
set -euo pipefail

# Notes:
# - Restores GRUB theme from backup and updates /etc/default/grub.
# - Overwrites GRUB config settings (with backup).
# - Does NOT restore LUKS header or /etc/fstab.

USB_LABEL="${BKP_USB_LABEL:-netac}"
SRV="${SRV:-/run/media/$USER/$USB_LABEL/Srv}"
THEME="$SRV/grub/lateralus"
GRUB_DEFAULT_FILE="/etc/default/grub"
BACKUP="/etc/default/grub.bak.$(date +%Y%m%d-%H%M%S)"
TS="$(date +%Y%m%d%H%M%S)"
BACKUP_DIR="/var/backups/restore-grub-$TS"

TOTAL_STEPS=3
STEP=0
status() { printf '%s\n' "$*" >/dev/tty; }
progress() {
  STEP=$((STEP + 1))
  printf '[%d/%d] %s\n' "$STEP" "$TOTAL_STEPS" "$*" >/dev/tty
}

LOG_FILE="/tmp/restore-grub-v2-$TS.log"
exec >"$LOG_FILE" 2> >(tee -a "$LOG_FILE" >/dev/tty)
status "Restore GRUB start: $(date -Is)"
status "Log: $LOG_FILE"

# Re-run as root if needed
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo -p "[sudo] password for %u: " "$0" "$@"
fi

if [[ ! -f "$GRUB_DEFAULT_FILE" ]]; then
  echo "Error: $GRUB_DEFAULT_FILE not found." >&2
  exit 1
fi

if [[ ! -d "$SRV" ]]; then
  echo "Error: backup directory not found: $SRV" >&2
  exit 1
fi

if [[ ! -d "$THEME" ]]; then
  echo "Error: theme directory not found: $THEME" >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"
progress "Backup defaults"
echo "Creating backup: $BACKUP"
cp -a "$GRUB_DEFAULT_FILE" "$BACKUP"

mkdir -p "/boot/grub/themes"
if [[ -d "/boot/grub/themes/lateralus" ]]; then
  echo "Backing up existing theme to: $BACKUP_DIR/lateralus"
  rsync -a --quiet "/boot/grub/themes/lateralus/" "$BACKUP_DIR/lateralus/"
fi
progress "Restore theme"
rsync -a --quiet "$THEME" "/boot/grub/themes/"

sed -Ei \
  -e 's|^#?GRUB_CMDLINE_LINUX_DEFAULT=.*$|GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet splash"|' \
  -e 's|^#?GRUB_GFXMODE=.*$|GRUB_GFXMODE=1440x1080x32|' \
  -e 's|^#?GRUB_THEME=.*$|GRUB_THEME="/boot/grub/themes/lateralus/theme.txt"|' \
  -e 's|^#?GRUB_TERMINAL_OUTPUT=.*$|GRUB_TERMINAL_OUTPUT=gfxterm|' \
  -e 's|^#?GRUB_TERMINAL_OUTPUTconsole$|GRUB_TERMINAL_OUTPUT=gfxterm|' \
  "$GRUB_DEFAULT_FILE"

if ! grep -Eq '^[#]?GRUB_THEME=' "$GRUB_DEFAULT_FILE"; then
  echo 'GRUB_THEME="/boot/grub/themes/lateralus/theme.txt"' >> "$GRUB_DEFAULT_FILE"
fi

progress "Update grub.cfg"
echo "Updated $GRUB_DEFAULT_FILE"

if ! command -v grub-mkconfig >/dev/null 2>&1; then
  echo "Error: grub-mkconfig not found in PATH." >&2
  exit 1
fi

grub-mkconfig -o /boot/grub/grub.cfg
status "Restore GRUB done."
