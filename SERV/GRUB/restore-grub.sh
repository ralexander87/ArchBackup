#!/usr/bin/env bash
set -euo pipefail

# GRUB restore shell script.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
show_banner=true
auto_yes=false
confirm_restore=false

# Parse flags.
while [[ $# -gt 0 ]]; do
	case "$1" in
	--no-banner)
		show_banner=false
		shift
		;;
	--yes)
		auto_yes=true
		shift
		;;
	--confirm)
		confirm_restore=true
		shift
		;;
	*)
		shift
		;;
	esac
done

# Banner.
if $show_banner; then
	cat <<'EOF'
Restore GRUB
Options:
  --confirm    Ask before destructive restore
  --yes        Auto-confirm destructive prompt
  --no-banner  Skip this prompt
EOF
	read -r -p "Press Enter to continue..." _
fi

# Confirm destructive restore if requested.
if $confirm_restore; then
	if $auto_yes; then
		answer="y"
	else
		read -r -p "This restore will modify system files. Continue? [y/N]: " answer
	fi
	if [[ ! "$answer" =~ ^[yY]$ ]]; then
		echo "Restore cancelled."
		exit 0
	fi
fi

# Validate non-sudo prerequisites.
dest="/boot/grub/themes"
src="${script_dir}/lateralus"
if [[ ! -d "$dest" ]]; then
	echo "Destination not found: ${dest}" >&2
	exit 1
fi
if [[ ! -d "$src" ]]; then
	echo "Source not found: ${src}" >&2
	exit 1
fi

# Require sudo.
if command -v sudo >/dev/null 2>&1; then
	echo "Sudo required to restore GRUB files. You may be prompted."
	sudo -v || exit 1
else
	echo "sudo not found; cannot restore GRUB files." >&2
	exit 1
fi

# Restore theme and update /etc/default/grub.
echo "Restoring: ${src} -> /boot/grub/themes/"
if sudo rsync -aHAX --numeric-ids --info=stats1 --sparse "$src" /boot/grub/themes/; then
	grub_conf="/etc/default/grub"
	if [[ -f "$grub_conf" ]]; then
		echo "Backing up ${grub_conf} to ${script_dir}"
		sudo cp "$grub_conf" "${script_dir}/grub.backup"
		sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet splash\"/' "$grub_conf"
		sudo sed -i 's/^#GRUB_GFXMODE=.*/GRUB_GFXMODE=1440x1080x32/' "$grub_conf"
		sudo sed -i 's|^#GRUB_THEME=.*|GRUB_THEME=\"/boot/grub/themes/lateralus/theme.txt\"|' "$grub_conf"
		sudo sed -i 's/^#GRUB_TERMINAL_OUTPUT=.*/GRUB_TERMINAL_OUTPUT=gfxterm/' "$grub_conf"
		sudo sed -i 's/^GRUB_TERMINAL_INPUT=console/#GRUB_TERMINAL_INPUT=console/' "$grub_conf"
		sudo grub-mkconfig -o /boot/grub/grub.cfg
	else
		echo "File not found: ${grub_conf}" >&2
	fi
fi
