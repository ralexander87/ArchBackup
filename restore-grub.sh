#!/bin/bash

THEME="/home/$USER/Srv/grub/lateralus"
GRUB_DEFAULT_FILE="/etc/default/grub"
BACKUP="/etc/default/grub.bak.$(date +%Y%m%d-%H%M%S)"


# Edit /etc/default/grub and regenerate config with:
# grub-mkconfig -o /boot/grub/grub.cfg

set -euo pipefail

# Re-run as root if needed
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo -p "[sudo] password for %u: " "$0" "$@"
fi

if [[ ! -f "$GRUB_DEFAULT_FILE" ]]; then
  echo "Error: $GRUB_DEFAULT_FILE not found." >&2
  exit 1
fi

echo "Creating backup: $BACKUP"
cp -a "$GRUB_DEFAULT_FILE" "$BACKUP"
cp -r "$THEME" "/boot/grub/themes"

# Apply edits in-place
#  - ^#? matches commented or uncommented variants
#  - Use | as delimiter to avoid escaping slashes
sed -Ei \
  -e 's|^#?GRUB_CMDLINE_LINUX_DEFAULT=.*$|GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet splash"|' \
  -e 's|^#?GRUB_GFXMODE=.*$|GRUB_GFXMODE=1440x1080x32|' \
  -e 's|^#?GRUB_THEME=.*$|GRUB_THEME="/boot/grub/themes/lateralus/theme.txt"|' \
  -e 's|^#?GRUB_TERMINAL_OUTPUT=.*$|GRUB_TERMINAL_OUTPUT=gfxterm|' \
  -e 's|^#?GRUB_TERMINAL_OUTPUTconsole$|GRUB_TERMINAL_OUTPUT=gfxterm|' \
  "$GRUB_DEFAULT_FILE"

# Ensure GRUB_THEME exists if it wasn't present at all (append once)
if ! grep -Eq '^[#]?GRUB_THEME=' "$GRUB_DEFAULT_FILE"; then
  echo 'GRUB_THEME="/boot/grub/themes/lateralus/theme.txt"' >> "$GRUB_DEFAULT_FILE"
fi

echo "Updated $GRUB_DEFAULT_FILE"

# Regenerate GRUB config using your command
if ! command -v grub-mkconfig >/dev/null 2>&1; then
  echo "Error: grub-mkconfig not found in PATH." >&2
  exit 1
fi

# re-generate grub.cfg
sudo grub-mkconfig -o /boot/grub/grub.cfg

echo "Done: /boot/grub/grub.cfg rebuilt."
