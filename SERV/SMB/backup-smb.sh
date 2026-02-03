#!/usr/bin/env bash
set -euo pipefail

# SMB backup shell script.

timestamp="$(date +%j-%d-%m-%H-%M-%S)"
user_name="${USER:-$(id -un)}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
show_banner=true
auto_yes=false

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
	*)
		shift
		;;
	esac
done

# Banner.
if $show_banner; then
	cat <<'EOF'
Backup SMB
Options:
  --no-banner  Skip this prompt
  --yes        Auto-confirm prompts
EOF
	read -r -p "Press Enter to continue..." _
fi

# shellcheck disable=SC1091
source "${script_dir}/../../scripts/common.sh"

# Compression choice.
if $auto_yes; then
	compress_backup=true
else
	read -r -p "Create compressed archive with pigz? [Y/n]: " compress_reply
	compress_reply="${compress_reply:-Y}"
	case "$compress_reply" in
	[nN]) compress_backup=false ;;
	*) compress_backup=true ;;
	esac
fi

# Validate required tools and sudo.
require_commands rsync df find mountpoint

if command -v sudo >/dev/null 2>&1; then
	echo "Sudo required to read SMB files. You may be prompted."
	sudo -v || exit 1
else
	echo "sudo not found; cannot read required SMB files." >&2
	exit 1
fi

if [[ "$compress_backup" == true ]]; then
	if ! command -v pigz >/dev/null 2>&1; then
		echo "pigz not found; cannot create compressed archive." >&2
		exit 1
	fi
fi

collect_destinations "$user_name"
select_destination

# Create per-run folder.
# shellcheck disable=SC2154
dest_root="${selected_dest}/SERV/SMB"
run_dir="${dest_root}/SMB-${timestamp}"
mkdir -p "$run_dir"

check_free_space "$selected_dest" 20

# Rsync defaults.
rsync_opts=(
	-aHAX
	--numeric-ids
	--info=stats1
	--sparse
)

rsync_failures=0

run_rsync() {
	local src="$1"
	local dest="$2"
	echo "Copying: ${src} -> ${dest}"
	sudo rsync "${rsync_opts[@]}" "$src" "$dest"
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

# Sources and manifest.
sources=(
	"/etc/samba/smb.conf"
	"/etc/fstab"
	"/home/${user_name}/Code/BACKUP/SERV/SMB/restore-smb.sh"
	"/home/${user_name}/Code/BACKUP/SERV/SMB/restore-smb.py"
)

{
	echo "Sources"
	printf "%s\n" "${sources[@]}"
} >"${run_dir}/sources.txt"

for src in "${sources[@]}"; do
	if [[ ! -e "$src" ]]; then
		echo "Skipping missing source: ${src}"
		continue
	fi
	run_rsync "$src" "${run_dir}/"
	if [[ "$src" == *"/restore-smb.sh" || "$src" == *"/restore-smb.py" ]]; then
		sudo chmod 755 "${run_dir}/$(basename "$src")" || true
	fi
done

# creds-* files from /etc/samba.
creds_files=(/etc/samba/creds-*)
if [[ ${#creds_files[@]} -eq 1 && "${creds_files[0]}" == "/etc/samba/creds-*" ]]; then
	echo "No creds-* files found under /etc/samba/"
else
	for src in "${creds_files[@]}"; do
		if [[ ! -e "$src" ]]; then
			echo "Skipping missing source: ${src}"
			continue
		fi
		run_rsync "$src" "${run_dir}/"
	done
fi

# Optional compression.
tar_failed=false
if [[ "$compress_backup" == true ]]; then
	archive_path="${run_dir}/SMB-${timestamp}.tar.gz"
	tar_err="$(mktemp)"
	if sudo tar --use-compress-program=pigz \
		--warning=no-file-changed \
		--exclude "./SMB-${timestamp}.tar.gz" \
		-cpf "$archive_path" \
		-C "$run_dir" "." 2>"$tar_err"; then
		sudo chown "${user_name}:${user_name}" "$archive_path" || true
		echo "Compressed archive created: ${archive_path}"
	else
		rc=$?
		if [[ $rc -eq 1 ]]; then
			echo "Compression completed with warnings for ${run_dir} (exit ${rc})." >&2
			if [[ -s "$tar_err" ]]; then
				echo "Details:" >&2
				tail -n 20 "$tar_err" >&2
			fi
		else
			echo "Compression failed for ${run_dir} (exit ${rc})." >&2
			if [[ -s "$tar_err" ]]; then
				echo "Details:" >&2
				tail -n 20 "$tar_err" >&2
			fi
			tar_failed=true
		fi
	fi
	rm -f "$tar_err"
fi

echo "Backup completed: ${run_dir}"
echo "Summary: rsync_failures=${rsync_failures}, tar_failed=${tar_failed}"
if ((rsync_failures > 0)) || [[ "$tar_failed" == true ]]; then
	exit 1
fi
