#!/usr/bin/env bash
set -euo pipefail

# Main backup shell script.

timestamp="$(date +%j-%d-%m-%H-%M-%S)"
user_name="${USER:-$(id -un)}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_dir=""
compress_override=""
manifest_only=false
show_banner=true
auto_yes=false

# Parse flags for automation.
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
	*)
		shift
		;;
	esac
done

# Show banner/flags summary.
if $show_banner; then
	cat <<'EOF'
Backup MAIN
Options:
  --no-compress     Skip compression prompt
  --log-dir <dir>   Write logs to a custom directory
  --manifest-only   Write manifests and exit
  --no-banner       Skip this prompt
  --yes             Auto-confirm prompts
EOF
	read -r -p "Press Enter to continue..." _
fi

# shellcheck disable=SC1091
source "${script_dir}/../scripts/common.sh"

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

# Select destination mount.
collect_destinations "$user_name"
select_destination

# shellcheck disable=SC2154
main_dir="${selected_dest}/MAIN"
backup_dir="${main_dir}/BKP-${timestamp}"

mkdir -p "$backup_dir"

# Set up logging.
if [[ -n "$log_dir" ]]; then
	mkdir -p "$log_dir"
	log_file="${log_dir}/BKP-${timestamp}.log"
else
	log_file="${backup_dir}/BKP-${timestamp}.log"
fi
exec > >(tee -a "$log_file") 2>&1

# Trim log size on exit/interrupt.
trim_log() {
	if [[ -f "$log_file" ]]; then
		local size
		size="$(stat -c%s "$log_file" 2>/dev/null || echo 0)"
		if [[ "$size" -gt 5242880 ]]; then
			tail -n 5000 "$log_file" >"${log_file}.tmp"
			mv "${log_file}.tmp" "$log_file"
		fi
	fi
}

on_interrupt() {
	echo "Interrupted. Exiting."
	trim_log
	exit 130
}

trap on_interrupt INT TERM
trap trim_log EXIT

check_free_space "$selected_dest" 20

# Rsync defaults for metadata preservation.
rsync_opts=(
	-aAXH
	--numeric-ids
	--sparse
	--info=stats1
)

rsync_failures=0
sources_total=0
sources_skipped=0

run_rsync() {
	local src="$1"
	local dest="$2"
	shift 2
	echo "Copying: ${src} -> ${dest}"
	rsync "${rsync_opts[@]}" "$@" "$src" "$dest"
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

# Global excludes and sources list.
common_excludes=(
	--exclude ".cache/"
	--exclude ".var/app/"
	--exclude ".subversion/"
	--exclude ".mozilla/"
	--exclude ".local/share/fonts/"
	--exclude ".local/share/fonts/NerdFonts/"
	--exclude ".vscode-oss/"
	--exclude "Trash/"
	--exclude ".config/*/Cache/"
	--exclude ".config/*/cache/"
	--exclude ".config/*/Code Cache/"
	--exclude ".config/*/GPUCache/"
	--exclude ".config/*/CachedData/"
	--exclude ".config/*/CacheStorage/"
	--exclude ".config/*/Service Worker/"
	--exclude ".config/*/IndexedDB/"
	--exclude ".config/*/Local Storage/"
	--exclude ".config/rambox/"
	--exclude ".rustup/"
)

sources=(
	"/home/${user_name}/Documents"
	"/home/${user_name}/Downloads"
	"/home/${user_name}/Pictures"
	"/home/${user_name}/Obsidian"
	"/home/${user_name}/Working"
	"/home/${user_name}/Shared"
	"/home/${user_name}/VM"
	"/home/${user_name}/Code"
	"/home/${user_name}/Videos"
	"/home/${user_name}/.config"
	"/home/${user_name}/.var"
	"/home/${user_name}/.ssh"
	"/home/${user_name}/.icons"
	"/home/${user_name}/.themes"
	"/home/${user_name}/.mydotfiles"
	"/home/${user_name}/.local"
	"/home/${user_name}/.oh-my-zsh"
	"/home/${user_name}/Code/BACKUP/MAIN/restore-main.sh"
	"/home/${user_name}/Code/BACKUP/MAIN/restore-main.py"
)

{
	echo "Sources"
	printf "%s\n" "${sources[@]}"
} >"${backup_dir}/sources.txt"

{
	echo "Excludes"
	for ((i = 1; i < ${#common_excludes[@]}; i += 2)); do
		printf "%s\n" "${common_excludes[$i]}"
	done
} >"${backup_dir}/excludes.txt"

for src in "${sources[@]}"; do
	if [[ ! -e "$src" ]]; then
		echo "Skipping missing source: ${src}"
		sources_skipped=$((sources_skipped + 1))
		continue
	fi
	sources_total=$((sources_total + 1))
	extra_excludes=()
	case "$src" in
	*/VM) extra_excludes+=(--exclude "ISO/") ;;
	*/Downloads) extra_excludes+=(--exclude "*.iso") ;;
	*/.ssh) extra_excludes+=(--exclude "agent/") ;;
	*/restore-main.sh | */restore-main.py) ;;
	esac
	run_rsync "$src" "$backup_dir"/ "${common_excludes[@]}" "${extra_excludes[@]}"
done

# Exit early if only manifest requested.
if [[ "$manifest_only" == true ]]; then
	echo "Manifest-only mode: skipping file copy and compression."
	echo "Backup completed: ${backup_dir}"
	exit 0
fi

# Optional compression into run directory.
tar_failed=false
if [[ "$compress_backup" == true ]]; then
	archive_path="${backup_dir}/BKP-${timestamp}.tar.gz"
	tar_err="$(mktemp)"
	# Write archive directly into backup_dir to avoid filling /tmp on large backups.
	if tar --use-compress-program=pigz \
		--warning=no-file-changed \
		--exclude "./BKP-${timestamp}.tar.gz" \
		--exclude "./BKP-${timestamp}.log" \
		-cpf "$archive_path" \
		-C "$backup_dir" "." 2>"$tar_err"; then
		echo "Compressed archive created: ${archive_path}"
	else
		rc=$?
		if [[ $rc -eq 1 ]]; then
			echo "Compression completed with warnings for ${backup_dir} (exit ${rc})." >&2
			if [[ -s "$tar_err" ]]; then
				echo "Details:" >&2
				tail -n 20 "$tar_err" >&2
			fi
		else
			echo "Compression failed for ${backup_dir} (exit ${rc})." >&2
			if [[ -s "$tar_err" ]]; then
				echo "Details:" >&2
				tail -n 20 "$tar_err" >&2
			fi
			tar_failed=true
		fi
	fi
	rm -f "$tar_err"
fi

echo "Backup completed: ${backup_dir}"
echo "Summary: sources=${sources_total}, skipped=${sources_skipped}, rsync_failures=${rsync_failures}, tar_failed=${tar_failed}"
if ((rsync_failures > 0)) || [[ "$tar_failed" == true ]]; then
	exit 1
fi
