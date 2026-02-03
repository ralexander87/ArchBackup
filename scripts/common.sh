#!/usr/bin/env bash
set -euo pipefail

# Ensure required executables exist.
require_commands() {
	local cmd
	for cmd in "$@"; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			echo "Missing required command: ${cmd}" >&2
			exit 1
		fi
	done
}

# Resolve filesystem type for a mountpoint.
get_fstype() {
	local target="$1"
	if command -v findmnt >/dev/null 2>&1; then
		findmnt -no FSTYPE --target "$target"
		return 0
	fi
	awk -v t="$target" '$2==t {print $3; exit}' /proc/mounts
}

# Filter out pseudo/unsafe mount types.
is_safe_mount() {
	local target="$1"
	if ! mountpoint -q "$target"; then
		return 1
	fi
	local fstype
	fstype="$(get_fstype "$target")"
	case "$fstype" in
	tmpfs | overlay | squashfs | nsfs | proc | sysfs | cgroup* | devtmpfs | ramfs | autofs)
		return 1
		;;
	esac
	return 0
}

# Populate destinations[] with external mount roots.
collect_destinations() {
	local user_name="$1"
	local root
	destinations=()
	for root in "/run/media/${user_name}" "/media/${user_name}"; do
		if [[ -d "$root" ]]; then
			while IFS= read -r -d '' dir; do
				if is_safe_mount "$dir"; then
					destinations+=("$dir")
				fi
			done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print0)
		fi
	done
}

# Prompt user to select a destination (auto if only one).
select_destination() {
	if [[ ${#destinations[@]} -eq 0 ]]; then
		echo "No external mounted devices found under /run/media or /media." >&2
		exit 1
	fi

	echo "Mounted destinations:"
	for i in "${!destinations[@]}"; do
		printf "  [%d] %s\n" "$((i + 1))" "${destinations[$i]}"
	done

	if [[ ${#destinations[@]} -eq 1 ]]; then
		selected_dest="${destinations[0]}"
		echo "Using the only available destination: ${selected_dest}"
		return
	fi

	read -r -p "Select destination number: " choice
	if [[ ! "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#destinations[@]})); then
		echo "Invalid selection." >&2
		exit 1
	fi
	selected_dest="${destinations[$((choice - 1))]}"
	read -r -p "Confirm destination (${selected_dest}) and press Enter to continue..."
}

# Enforce minimum free space in GB on destination.
check_free_space() {
	local target="$1"
	local min_gb="$2"
	local avail_gb
	avail_gb="$(df -BG --output=avail "$target" | tail -1 | tr -d ' G')"
	if [[ -z "$avail_gb" ]] || ((avail_gb < min_gb)); then
		echo "Insufficient free space on destination (${avail_gb}G available, need >= ${min_gb}G)." >&2
		exit 1
	fi
}
