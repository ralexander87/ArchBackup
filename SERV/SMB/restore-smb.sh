#!/usr/bin/env bash
set -euo pipefail

# SMB restore shell script.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
user_name="${USER:-$(id -un)}"
show_banner=true
confirm_restore=false
auto_yes=false

# Parse flags.
while [[ $# -gt 0 ]]; do
	case "$1" in
	--no-banner)
		show_banner=false
		shift
		;;
	--confirm)
		confirm_restore=true
		shift
		;;
	--yes)
		auto_yes=true
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
Restore SMB
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

# Require systemctl for service discovery.
if ! command -v systemctl >/dev/null 2>&1; then
	echo "systemctl not found; cannot manage services." >&2
	exit 1
fi

# Resolve service names across distros (e.g. smbd vs smb).
list_units() {
	systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}'
}
find_service() {
	local candidate
	for candidate in "$@"; do
		if list_units | grep -qx "$candidate"; then
			echo "$candidate"
			return 0
		fi
	done
	return 1
}

service_labels=(
	"avahi-daemon"
	"nmb/nmbd"
	"smb/smbd"
	"sshd"
	"wsdd/wsdd2"
)
service_groups=(
	"avahi-daemon.service"
	"nmb.service nmbd.service"
	"smb.service smbd.service"
	"sshd.service"
	"wsdd.service wsdd2.service"
)

resolved_services=()
for i in "${!service_groups[@]}"; do
	if svc="$(find_service ${service_groups[$i]})"; then
		resolved_services+=("$svc")
		continue
	fi
	read -r -p "Service ${service_labels[$i]} is not installed. Install it now? [y/N]: " answer
	if [[ ! "$answer" =~ ^[yY]$ ]]; then
		echo "Required service missing: ${service_labels[$i]}. Exiting."
		exit 1
	fi
	echo "Please install ${service_labels[$i]}, then press Enter to continue."
	read -r _
	if svc="$(find_service ${service_groups[$i]})"; then
		resolved_services+=("$svc")
	else
		echo "Service ${service_labels[$i]} still not found. Exiting."
		exit 1
	fi
done

# Optional smbpasswd user setup.
smb_user_to_add=""
if command -v pdbedit >/dev/null 2>&1; then
	read -r -p "Enter SMB username for smbpasswd: " smb_user
	if [[ -n "$smb_user" ]]; then
		if pdbedit -L 2>/dev/null | awk -F: '{print $1}' | grep -qx "$smb_user"; then
			echo "SMB user ${smb_user} already exists; skipping smbpasswd."
		else
			smb_user_to_add="$smb_user"
		fi
	else
		echo "No SMB username provided; skipping smbpasswd."
	fi
else
	echo "pdbedit not found; skipping smbpasswd user check."
fi

# Require sudo for install/enable and system changes.
if command -v sudo >/dev/null 2>&1; then
	echo "Sudo required to restore SMB files. You may be prompted."
	sudo -v || exit 1
else
	echo "sudo not found; cannot restore SMB files." >&2
	exit 1
fi

if [[ -n "$smb_user_to_add" ]]; then
	sudo smbpasswd -a "$smb_user_to_add"
fi

for svc in "${resolved_services[@]}"; do
	if sudo systemctl enable "$svc"; then
		:
	else
		echo "Warning: failed to enable ${svc}" >&2
	fi
done

sudo modprobe cifs

# Create local /SMB structure.
owner_user="${SUDO_USER:-$user_name}"
sudo mkdir -p /SMB
sudo chown "${owner_user}:${owner_user}" /SMB
sudo chmod 750 /SMB

subdirs=(
	"/SMB/euclid"
	"/SMB/pneuma"
	"/SMB/lateralus"
	"/SMB/SCP"
	"/SMB/SCP/HDD-01"
	"/SMB/SCP/HDD-02"
	"/SMB/SCP/HDD-03"
)
for dir in "${subdirs[@]}"; do
	sudo mkdir -p "$dir"
	sudo chown "${owner_user}:${owner_user}" "$dir"
	sudo chmod 750 "$dir"
done

# Append SMB mounts to /etc/fstab if missing.
fstab_lines=(
	"//192.168.8.60/d   /SMB/euclid   cifs   _netdev,credentials=/etc/samba/creds-euclid,uid=1000,gid=1000   0 0"
	"//192.168.8.150/hdd-01   /SMB/SCP/HDD-01   cifs   _netdev,credentials=/etc/samba/creds-scp,uid=1000,gid=1000   0 0"
	"//192.168.8.150/hdd-02   /SMB/SCP/HDD-02   cifs   _netdev,credentials=/etc/samba/creds-scp,uid=1000,gid=1000   0 0"
	"//192.168.8.150/hdd-03   /SMB/SCP/HDD-03   cifs   _netdev,credentials=/etc/samba/creds-scp,uid=1000,gid=1000   0 0"
)

if sudo test -f /etc/fstab; then
	need_append=false
	for line in "${fstab_lines[@]}"; do
		if ! sudo grep -Fqx "$line" /etc/fstab; then
			need_append=true
			break
		fi
	done
	if $need_append; then
		printf "\n" | sudo tee -a /etc/fstab >/dev/null
		for line in "${fstab_lines[@]}"; do
			if ! sudo grep -Fqx "$line" /etc/fstab; then
				printf "%s\n" "$line" | sudo tee -a /etc/fstab >/dev/null
			fi
		done
	fi
else
	echo "File not found: /etc/fstab" >&2
fi

# Ensure /etc/samba exists and restore smb.conf/creds.
if [[ ! -d "/etc/samba" ]]; then
	sudo mkdir -p /etc/samba
	sudo chown root:root /etc/samba
	sudo chmod 755 /etc/samba
fi

# Validate smb.conf after restore.
if [[ -f "/etc/samba/smb.conf" ]]; then
	sudo cp /etc/samba/smb.conf "${script_dir}/smb.conf.backup"
fi

if [[ -f "${script_dir}/smb.conf" ]]; then
	sudo cp "${script_dir}/smb.conf" /etc/samba/smb.conf
	sudo chown root:root /etc/samba/smb.conf
	sudo chmod 644 /etc/samba/smb.conf
else
	echo "Source not found: ${script_dir}/smb.conf" >&2
fi

creds_files=("${script_dir}"/creds-*)
if [[ ${#creds_files[@]} -eq 1 && "${creds_files[0]}" == "${script_dir}/creds-*" ]]; then
	echo "No creds-* files found in ${script_dir}/"
else
	for src in "${creds_files[@]}"; do
		if [[ -f "$src" ]]; then
			sudo cp "$src" /etc/samba/
			sudo chown root:root "/etc/samba/$(basename "$src")"
			sudo chmod 600 "/etc/samba/$(basename "$src")"
		else
			echo "Skipping missing creds file: ${src}"
		fi
	done
fi

if [[ -f "/etc/samba/smb.conf" ]]; then
	if command -v testparm >/dev/null 2>&1; then
		if sudo testparm -s >/dev/null 2>&1; then
			:
		else
			echo "Error: testparm reported errors in smb.conf" >&2
			exit 1
		fi
	else
		echo "Warning: testparm not found; skipping smb.conf validation." >&2
	fi
fi

# Restart services and check status.
for svc in "${resolved_services[@]}"; do
	if sudo systemctl restart "$svc"; then
		:
	else
		echo "Warning: failed to restart ${svc}" >&2
	fi
	if ! sudo systemctl is-active --quiet "$svc"; then
		echo "Warning: ${svc} is not active after restart." >&2
	fi
done
