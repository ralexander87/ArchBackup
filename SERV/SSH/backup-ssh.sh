#!/usr/bin/env bash
set -euo pipefail

# SSH backup shell script.

timestamp="$(date +%j-%d-%m-%H-%M-%S)"
user_name="${USER:-$(id -un)}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
show_banner=true
auto_yes=false
log_dir=""
compress_override=""
manifest_only=false
keep_count=5

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
	--log-dir)
		log_dir="$2"
		shift 2
		;;
	--no-compress)
		compress_override="false"
		shift
		;;
	--manifest-only)
		manifest_only=true
		shift
		;;
	--keep)
		keep_count="$2"
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
Backup SSH
Options:
  --no-compress     Skip compression prompt
  --log-dir <dir>   Write logs to a custom directory
  --manifest-only   Write manifests and exit
  --keep <count>    Keep last N backups (default: 5)
  --no-banner       Skip this prompt
  --yes             Auto-confirm prompts
EOF_BANNER
	read -r -p "Press Enter to continue..." _
fi

# shellcheck disable=SC1091
source "${script_dir}/../../scripts/common.sh"

# Compression choice.
if $auto_yes; then
	compress_backup=true
elif [[ "$compress_override" == "false" ]]; then
	compress_backup=false
else
	read -r -p "Create compressed archive with pigz? [Y/n]: " compress_reply
	compress_reply="${compress_reply:-Y}"
	case "$compress_reply" in
	[nN]) compress_backup=false ;;
	*) compress_backup=true ;;
	esac
fi

# Validate required tools.
require_commands rsync df find mountpoint
if [[ "$compress_backup" == true ]]; then
	if ! command -v pigz >/dev/null 2>&1; then
		echo "pigz not found; cannot create compressed archive." >&2
		exit 1
	fi
fi

# Select destination.
collect_destinations "$user_name"
select_destination

# Create per-run folder.
# shellcheck disable=SC2154
dest_root="${selected_dest}/SERV/SSH"
run_dir="${dest_root}/SSH-${timestamp}"
mkdir -p "$run_dir"

# Optional log redirection.
if [[ -n "$log_dir" ]]; then
	mkdir -p "$log_dir"
	log_file="${log_dir}/SSH-${timestamp}.log"
	exec > >(tee -a "$log_file") 2>&1
else
	log_file="${run_dir}/SSH-${timestamp}.log"
	exec > >(tee -a "$log_file") 2>&1
fi

# Ensure destination has enough free space.
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

# Sources and manifest.
ssh_dir="/home/${user_name}/.ssh"
sshd_config="/etc/ssh/sshd_config"
sources=(
	"${ssh_dir}"
	"${sshd_config}"
	"/home/${user_name}/Code/BACKUP/SERV/SSH/restore-ssh.sh"
	"/home/${user_name}/Code/BACKUP/SERV/SSH/restore-ssh.py"
)
{
	echo "Sources"
	printf "%s\n" "${sources[@]}"
	echo ""
	echo "Excludes"
	printf "%s\n" "${ssh_dir}/agent"
} >"${run_dir}/sources.txt"

# Stop after writing manifests if requested.
if [[ "$manifest_only" == true ]]; then
	echo "Manifest-only mode: skipping file copy and compression."
	echo "Backup destination ready: ${run_dir}"
	exit 0
fi

# Backup ~/.ssh (exclude agent socket) and sshd_config.
if [[ -d "$ssh_dir" ]]; then
	run_rsync "$ssh_dir" "${run_dir}/" --exclude "agent" --exclude "agent/" --exclude "/agent"
else
	echo "Source folder not found: ${ssh_dir}" >&2
	rsync_failures=$((rsync_failures + 1))
fi

for src in "${sources[@]}"; do
	if [[ "$src" == "$ssh_dir" ]]; then
		continue
	fi
	if [[ -f "$src" ]]; then
		run_rsync "$src" "${run_dir}/"
		if [[ "$src" == *"/restore-ssh.sh" || "$src" == *"/restore-ssh.py" ]]; then
			chmod 755 "${run_dir}/$(basename "$src")" || true
		fi
	else
		echo "Source file not found: ${src}" >&2
		rsync_failures=$((rsync_failures + 1))
	fi
done

# Ensure agent socket directory is not present in the backup.
if [[ -d "${run_dir}/.ssh/agent" ]]; then
	rm -rf "${run_dir}/.ssh/agent"
fi

# Optional compression.
tar_failed=false
if [[ "$compress_backup" == true ]]; then
	archive_path="${run_dir}/SSH-${timestamp}.tar.gz"
	tar_err="$(mktemp)"
	archive_tmp="$(mktemp --suffix=.tar.gz)"
	if tar --use-compress-program=pigz -cpf "$archive_tmp" -C "$run_dir" "." 2>"$tar_err"; then
		mv -f "$archive_tmp" "$archive_path"
		echo "Compressed archive created: ${archive_path}"
	else
		rc=$?
		echo "Compression failed for ${run_dir} (exit ${rc})." >&2
		echo "Details:" >&2
		tail -n 20 "$tar_err" >&2
		tar_failed=true
		rm -f "$archive_tmp"
	fi
	rm -f "$tar_err"
fi

rotate_backups() {
	local keep="${1:-5}"
	[[ "$keep" =~ ^[0-9]+$ ]] || return 0
	mapfile -t backups < <(ls -1dt "${dest_root}"/SSH-* 2>/dev/null || true)
	if ((${#backups[@]} > keep)); then
		for old in "${backups[@]:keep}"; do
			rm -rf "$old"
		done
	fi
}

echo "Backup completed: ${run_dir}"
echo "Summary: rsync_failures=${rsync_failures}, tar_failed=${tar_failed}"
if ((rsync_failures > 0)) || [[ "$tar_failed" == true ]]; then
	exit 1
fi

# Rotate old backups after successful run.
rotate_backups "$keep_count"
