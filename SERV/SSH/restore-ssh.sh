#!/usr/bin/env bash
set -euo pipefail

# SSH restore shell script.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
user_name="${USER:-$(id -un)}"
show_banner=true
confirm_restore=false
auto_yes=false
log_dir=""
manifest_only=false
no_restart=false

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
	--manifest-only)
		manifest_only=true
		shift
		;;
	--no-restart)
		no_restart=true
		shift
		;;
	--log-dir)
		log_dir="$2"
		shift 2
		;;
	*)
		shift
		;;
	esac
done

# Banner.
if $show_banner; then
	cat <<'EOF_BANNER'
Restore SSH
Options:
  --confirm    Ask before destructive restore
  --yes        Auto-confirm destructive prompt
  --log-dir <dir>   Write logs to a custom directory
  --manifest-only   Print expected sources and exit
  --no-restart      Skip restarting sshd.service
  --no-banner  Skip this prompt
EOF_BANNER
	read -r -p "Press Enter to continue..." _
fi

# Optional log redirection.
if [[ -n "$log_dir" ]]; then
	mkdir -p "$log_dir"
	log_file="${log_dir}/restore-ssh.log"
	exec > >(tee -a "$log_file") 2>&1
fi

if [[ "$manifest_only" == true ]]; then
	echo "Sources:"
	echo "${script_dir}/.ssh"
	echo "${script_dir}/sshd_config"
	exit 0
fi

# Confirm destructive restore if requested.
if $confirm_restore; then
	if $auto_yes; then
		answer="y"
	else
		read -r -p "This restore will modify SSH configs. Continue? [y/N]: " answer
	fi
	if [[ ! "$answer" =~ ^[yY]$ ]]; then
		echo "Restore cancelled."
		exit 0
	fi
else
	echo "Warning: --confirm not set; proceeding without confirmation."
fi

# Require systemctl for service discovery.
if ! command -v systemctl >/dev/null 2>&1; then
	echo "systemctl not found; cannot manage sshd.service." >&2
	exit 1
fi

# Ensure sshd.service is installed.
if ! systemctl list-unit-files --type=service | awk '{print $1}' | grep -qx "sshd.service"; then
	read -r -p "Service sshd.service is not installed. Install it now? [y/N]: " answer
	if [[ ! "$answer" =~ ^[yY]$ ]]; then
		echo "Required service missing: sshd.service. Exiting."
		exit 1
	fi
	echo "Please install sshd.service, then press Enter to continue."
	read -r _
	if ! systemctl list-unit-files --type=service | awk '{print $1}' | grep -qx "sshd.service"; then
		echo "Service sshd.service still not found. Exiting."
		exit 1
	fi
fi

# Rsync defaults.
rsync_opts=(
	-aHAX
	--numeric-ids
	--sparse
	--delete-delay
	--info=stats1
)

rsync_failures=0
validation_failed=false

run_rsync() {
	local src="$1"
	local dest="$2"
	echo "Restoring: ${src} -> ${dest}"
	rsync "${rsync_opts[@]}" "$src" "$dest"
	rc=$?
	if [[ $rc -eq 23 || $rc -eq 24 ]]; then
		echo "rsync returned partial transfer code ${rc}; continuing." >&2
		return 0
	fi
	if [[ $rc -ne 0 ]]; then
		echo "rsync failed with code ${rc} for ${src}" >&2
		rsync_failures=$((rsync_failures + 1))
		return 0
	fi
	return 0
}

# Restore ~/.ssh folder.
ssh_dest="/home/${user_name}/.ssh"
if [[ -d "${script_dir}/.ssh" ]]; then
	mkdir -p "$ssh_dest"
	run_rsync "${script_dir}/.ssh" "/home/${user_name}/"
else
	echo "Source folder not found: ${script_dir}/.ssh" >&2
	rsync_failures=$((rsync_failures + 1))
fi

# Restore sshd_config.
if [[ -f "${script_dir}/sshd_config" ]]; then
	:
else
	echo "Source file not found: ${script_dir}/sshd_config" >&2
	rsync_failures=$((rsync_failures + 1))
fi

# Enforce ssh directory/file permissions.
if [[ -d "$ssh_dest" ]]; then
	chmod 700 "$ssh_dest"
	find "$ssh_dest" -type f -name "*.pub" -exec chmod 644 {} +
	find "$ssh_dest" -type f ! -name "*.pub" -exec chmod 600 {} +
fi

# Optional key fingerprint verification.
if command -v ssh-keygen >/dev/null 2>&1; then
	for src in "${script_dir}/.ssh/"*; do
		[[ -e "$src" ]] || continue
		if [[ -d "$src" ]]; then
			continue
		fi
		if [[ "$(basename "$src")" == "agent" ]]; then
			continue
		fi
		if ssh-keygen -lf "$src" >/dev/null 2>&1; then
			dest_file="${ssh_dest}/$(basename "$src")"
			if [[ -f "$dest_file" ]] && ssh-keygen -lf "$dest_file" >/dev/null 2>&1; then
				src_fp="$(ssh-keygen -lf "$src" | awk '{print $2,$3}')"
				dest_fp="$(ssh-keygen -lf "$dest_file" | awk '{print $2,$3}')"
				if [[ "$src_fp" != "$dest_fp" ]]; then
					echo "Warning: fingerprint mismatch for $(basename "$src")" >&2
					validation_failed=true
				fi
			fi
		fi
	done
else
	echo "Warning: ssh-keygen not found; skipping key verification." >&2
fi

# Require sudo for sshd_config and service management.
if command -v sudo >/dev/null 2>&1; then
	echo "Sudo required to restore SSH files. You may be prompted."
	sudo -v || exit 1
else
	echo "sudo not found; cannot restore SSH files." >&2
	exit 1
fi

# Ensure correct ownership for restored .ssh.
if [[ -d "$ssh_dest" ]]; then
	sudo chown -R "${user_name}:${user_name}" "$ssh_dest" || true
fi

if [[ -f "${script_dir}/sshd_config" ]]; then
	if command -v sshd >/dev/null 2>&1; then
		if sudo sshd -t -f "${script_dir}/sshd_config" >/dev/null 2>&1; then
			:
		else
			echo "Warning: sshd -t reported errors in backup sshd_config" >&2
			validation_failed=true
		fi
	else
		echo "Warning: sshd not found; skipping backup config validation." >&2
	fi
	sudo cp "${script_dir}/sshd_config" /etc/ssh/sshd_config
	sudo chown root:root /etc/ssh/sshd_config
	sudo chmod 600 /etc/ssh/sshd_config
	if command -v sshd >/dev/null 2>&1; then
		if sudo sshd -t -f /etc/ssh/sshd_config >/dev/null 2>&1; then
			:
		else
			echo "Warning: sshd -t reported errors in sshd_config" >&2
			validation_failed=true
		fi
	else
		echo "Warning: sshd not found; skipping config validation." >&2
	fi
fi

if sudo systemctl enable sshd.service; then
	:
else
	echo "Warning: failed to enable sshd.service" >&2
fi
if sudo systemctl start sshd.service; then
	:
else
	echo "Warning: failed to start sshd.service" >&2
fi

# Restart sshd and confirm it is active.
if [[ "$no_restart" == false ]]; then
	if sudo systemctl restart sshd.service; then
		:
	else
		echo "Warning: failed to restart sshd.service" >&2
	fi
	if ! sudo systemctl is-active --quiet sshd.service; then
		echo "Warning: sshd.service is not active after restart." >&2
	fi
fi

echo "Restore completed from: ${script_dir}"
echo "Summary: rsync_failures=${rsync_failures}, validation_failed=${validation_failed}"
if ((rsync_failures > 0)) || [[ "$validation_failed" == true ]]; then
	exit 1
fi
