#!/usr/bin/env bash
set -euo pipefail

# REST backup shell script.

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
Backup REST
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
	echo "Sudo required to read REST files. You may be prompted."
	sudo -v || exit 1
else
	echo "sudo not found; cannot read required REST files." >&2
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

# Per-run folder.
# shellcheck disable=SC2154
dest_root="${selected_dest}/SERV/REST"
run_dir="${dest_root}/REST-${timestamp}"
mkdir -p "$run_dir"

check_free_space "$selected_dest" 5

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
	"/etc/mkinitcpio.conf"
	"/usr/share/plymouth/plymouthd.defaults"
	"/usr/lib/sddm/sddm.conf.d/default.conf"
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
done

# LUKS header backup (NVMe partitions).
if command -v cryptsetup >/dev/null 2>&1; then
	luks_found=false
	shopt -s nullglob
	for dev in /dev/nvme*n*p*; do
		if sudo cryptsetup isLuks "$dev" >/dev/null 2>&1; then
			luks_found=true
			base_name="$(basename "$dev")"
			header_path="${run_dir}/luks-header-${base_name}.bin"
			echo "Backing up LUKS header: ${dev} -> ${header_path}"
			if sudo cryptsetup luksHeaderBackup "$dev" --header-backup-file "$header_path"; then
				sudo chown "${user_name}:${user_name}" "$header_path" || true
			else
				echo "Warning: failed to back up LUKS header for ${dev}" >&2
			fi
		fi
	done
	shopt -u nullglob
	if [[ "$luks_found" == false ]]; then
		echo "No LUKS headers found on /dev/nvme* partitions."
	fi
else
	echo "cryptsetup not found; skipping LUKS header backup."
fi

# Optional compression.
tar_failed=false
if [[ "$compress_backup" == true ]]; then
	archive_path="${run_dir}/REST-${timestamp}.tar.gz"
	tar_err="$(mktemp)"
	if sudo tar --use-compress-program=pigz \
		--warning=no-file-changed \
		--exclude "./REST-${timestamp}.tar.gz" \
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
