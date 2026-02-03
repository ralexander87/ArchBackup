#!/usr/bin/env bash
set -euo pipefail

# Dots backup shell script.

timestamp="$(date +%j-%d-%m-%H-%M-%S)"
user_name="${USER:-$(id -un)}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_dir=""
compress_override=""
manifest_only=false
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

# Banner.
if $show_banner; then
	cat <<'EOF'
Backup DOTS
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

# Decide whether to compress the backup archive.

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

require_commands rsync df find mountpoint

# Validate required tools based on compression choice.
if [[ "$compress_backup" == true ]]; then
	if ! command -v pigz >/dev/null 2>&1; then
		echo "pigz not found; cannot create compressed archive." >&2
		exit 1
	fi
fi

# Select backup destination.
collect_destinations "$user_name"
select_destination

# shellcheck disable=SC2154
dots_dir="${selected_dest}/DOTS"
backup_dir="${dots_dir}/DOTS-${timestamp}"

mkdir -p "$backup_dir"

# Optional log redirection.
if [[ -n "$log_dir" ]]; then
	mkdir -p "$log_dir"
	log_file="${log_dir}/DOTS-${timestamp}.log"
	exec > >(tee -a "$log_file") 2>&1
fi

# Ensure destination has enough free space.
check_free_space "$selected_dest" 20

# Rsync defaults.
rsync_opts=(
	-aAXH
	--numeric-ids
	--sparse
	--info=stats1
)

# Track soft failures without aborting immediately.
rsync_failures=0

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

source_root="/home/${user_name}/.mydotfiles/com.ml4w.dotfiles.stable/.config"
hyprctl_json="/home/${user_name}/.config/com.ml4w.hyprlandsettings/hyprctl.json"
restore_sh="/home/${user_name}/Code/BACKUP/DOTS/restore-dots.sh"
restore_py="/home/${user_name}/Code/BACKUP/DOTS/restore-dots.py"
# Write sources manifest for traceability.
{
	echo "Sources"
	printf "%s\n" \
		"$source_root" \
		"/home/${user_name}/.config/com.ml4w.hyprlandsettings/hyprctl.json" \
		"$restore_sh" \
		"$restore_py"
} >"${backup_dir}/sources.txt"

# Stop after writing manifests if requested.
if [[ "$manifest_only" == true ]]; then
	echo "Manifest-only mode: skipping file copy and compression."
	echo "Backup destination ready: ${backup_dir}"
	exit 0
fi

# Copy source config tree.
if [[ -d "$source_root" ]]; then
	run_rsync "$source_root"/ "$backup_dir"/
else
	echo "Source folder not found: ${source_root}" >&2
	rsync_failures=$((rsync_failures + 1))
fi

# Copy hyprctl settings file.
if [[ -f "$hyprctl_json" ]]; then
	run_rsync "$hyprctl_json" "$backup_dir"/
else
	echo "Source file not found: ${hyprctl_json}" >&2
	rsync_failures=$((rsync_failures + 1))
fi

# Copy restore scripts alongside the backup.
for restore_script in "$restore_sh" "$restore_py"; do
	if [[ -f "$restore_script" ]]; then
		run_rsync "$restore_script" "$backup_dir"/
	else
		echo "Restore script not found: ${restore_script}" >&2
		rsync_failures=$((rsync_failures + 1))
	fi
done

# Optional compression.
tar_failed=false
if [[ "$compress_backup" == true ]]; then
	archive_path="${backup_dir}/DOTS-${timestamp}.tar.gz"
	tar_err="$(mktemp)"
	archive_tmp="$(mktemp --suffix=.tar.gz)"
	if tar --use-compress-program=pigz -cpf "$archive_tmp" -C "$backup_dir" "." 2>"$tar_err"; then
		mv -f "$archive_tmp" "$archive_path"
		echo "Compressed archive created: ${archive_path}"
	else
		rc=$?
		echo "Compression failed for ${backup_dir} (exit ${rc})." >&2
		echo "Details:" >&2
		tail -n 20 "$tar_err" >&2
		tar_failed=true
		rm -f "$archive_tmp"
	fi
	rm -f "$tar_err"
fi

echo "Backup destination ready: ${backup_dir}"
echo "Summary: rsync_failures=${rsync_failures}, tar_failed=${tar_failed}"
if ((rsync_failures > 0)); then
	exit 1
fi
