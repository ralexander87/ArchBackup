#!/usr/bin/env bash
set -euo pipefail

# Dots restore shell script.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
user_name="${USER:-$(id -un)}"
backup_ts="$(date +%j-%d-%m-%H-%M-%S)"
confirm_restore=false
show_banner=true
auto_yes=false

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
Restore DOTS
Options:
  --confirm   Ask before destructive restore
  --yes       Auto-confirm destructive prompt
  --no-banner Skip this prompt
EOF
	read -r -p "Press Enter to continue..." _
fi

# Ensure required tools are available.
required_cmds=(rsync)
for required_cmd in "${required_cmds[@]}"; do
	if ! command -v "$required_cmd" >/dev/null 2>&1; then
		echo "Missing required command: ${required_cmd}" >&2
		exit 1
	fi
done

# Base destination for dotfiles.
dest_dir="/home/${user_name}/.mydotfiles/com.ml4w.dotfiles.stable/.config"

mkdir -p "$dest_dir"

# Rsync defaults for metadata-preserving restore.
rsync_opts=(
	-aAXH
	--numeric-ids
	--sparse
	--delete-delay
	--info=stats1
)

# Track soft failures for summary.
rsync_failures=0

run_rsync() {
	local dest="${*: -1}"
	local sources=("${@:1:$#-1}")
	if [[ ${#sources[@]} -eq 0 ]]; then
		return 0
	fi
	echo "Restoring: ${sources[*]} -> ${dest}"
	rsync "${rsync_opts[@]}" "${sources[@]}" "$dest"
	rc=$?
	if [[ $rc -eq 23 || $rc -eq 24 ]]; then
		echo "rsync returned partial transfer code ${rc}; continuing." >&2
		return 0
	fi
	if [[ $rc -ne 0 ]]; then
		echo "rsync failed with code ${rc} for ${sources[*]}" >&2
		rsync_failures=$((rsync_failures + 1))
		return 0
	fi
	return 0
}

# Replace ~/.config/cava with symlink to dotfiles version.
config_dir="/home/${user_name}/.config"
if [[ -e "${config_dir}/cava" ]]; then
	mv "${config_dir}/cava" "${config_dir}/cava.bak-${backup_ts}" || true
fi
ln -sfn "/home/${user_name}/.mydotfiles/com.ml4w.dotfiles.stable/.config/cava" "${config_dir}/cava"

# Replace ml4w wallpapers directory with symlink to Pictures.
ml4w_dir="/home/${user_name}/.mydotfiles/com.ml4w.dotfiles.stable/.config/ml4w"
if [[ -e "${ml4w_dir}/wallpapers" ]]; then
	mv "${ml4w_dir}/wallpapers" "${ml4w_dir}/wallpapers.bak-${backup_ts}" || true
fi
ln -sfn "/home/${user_name}/Pictures/wallpapers" "${ml4w_dir}/wallpapers"

# Append Hyprland env line if missing.
hypr_env="/home/${user_name}/.mydotfiles/com.ml4w.dotfiles.stable/.config/hypr/conf/environments/nvidia.conf"
if [[ -f "$hypr_env" ]]; then
	if ! grep -q "^env = AQ_DRM_DEVICES,/dev/dri/card1:/dev/dri/card2$" "$hypr_env"; then
		printf "\n%s\n" "env = AQ_DRM_DEVICES,/dev/dri/card1:/dev/dri/card2" >>"$hypr_env"
	fi
fi

# Optional destructive confirmation.
if $confirm_restore; then
	if $auto_yes; then
		answer="y"
	else
		read -r -p "This restore may delete files in ${dest_dir}. Continue? [y/N]: " answer
	fi
	if [[ ! "$answer" =~ ^[yY]$ ]]; then
		echo "Restore cancelled."
		exit 0
	fi
fi

# Collect existing sources from the backup folder and rsync to destination.
collect_and_rsync() {
	local dest="$1"
	shift
	local items=("$@")
	local paths=()
	local item
	for item in "${items[@]}"; do
		local src="${script_dir}/${item}"
		if [[ -e "$src" ]]; then
			paths+=("$src")
		else
			echo "Skipping missing source: ${src}"
		fi
	done
	if [[ ${#paths[@]} -gt 0 ]]; then
		mkdir -p "$dest"
		run_rsync "${paths[@]}" "$dest"
	fi
}

# Groups to restore from the backup folder.
items_default=("fastfetch" "cava" "matugen" "kitty" "rofi" "zshrc")
items_waybar=("waybar/themes/ralex")
items_gtk3=("gtk-3.0/settings.ini" "gtk-3.0/bookmarks")
items_gtk4=("gtk-4.0/settings.ini")
items_qt6=("qt6ct/qt6ct.conf")
items_hypr=("hypr/hyprlock.conf" "hypr/hypridle.conf" "hypr/logo-2.png")
items_hypr_scripts=("hypr/scripts/uptime.sh")
items_hypr_conf=("hypr/conf/animation.conf" "hypr/conf/cursor.conf" "hypr/conf/decoration.conf" "hypr/conf/environment.conf" "hypr/conf/keybinding.conf" "hypr/conf/layout.conf" "hypr/conf/monitor.conf" "hypr/conf/window.conf")
items_hypr_keybindings=("hypr/conf/keybindings/lateralus.conf")
items_ml4w_settings=("ml4w/settings/editor.sh" "ml4w/settings/filemanager" "ml4w/settings/filemanager.sh" "ml4w/settings/rofi-border-radius.rasi" "ml4w/settings/rofi-border.rasi" "ml4w/settings/rofi-font.rasi" "ml4w/settings/rofi_bordersize.sh" "ml4w/settings/screenshot-editor" "ml4w/settings/screenshot-folder" "ml4w/settings/terminal.sh" "ml4w/settings/wallpaper-folder" "ml4w/settings/waybar-theme.sh")
items_wlogout=("wlogout/themes/glass/style.css")
items_hyprctl=("hyprctl.json")

# Restore groups to their target locations.
collect_and_rsync "${dest_dir}/" "${items_default[@]}"
collect_and_rsync "${dest_dir}/waybar/themes/" "${items_waybar[@]}"
collect_and_rsync "${dest_dir}/gtk-3.0/" "${items_gtk3[@]}"
collect_and_rsync "${dest_dir}/gtk-4.0/" "${items_gtk4[@]}"
collect_and_rsync "${dest_dir}/qt6ct/" "${items_qt6[@]}"
collect_and_rsync "${dest_dir}/hypr/" "${items_hypr[@]}"
collect_and_rsync "${dest_dir}/hypr/scripts/" "${items_hypr_scripts[@]}"
collect_and_rsync "${dest_dir}/hypr/conf/" "${items_hypr_conf[@]}"
collect_and_rsync "${dest_dir}/hypr/conf/keybindings/" "${items_hypr_keybindings[@]}"
collect_and_rsync "${dest_dir}/ml4w/settings/" "${items_ml4w_settings[@]}"
collect_and_rsync "${dest_dir}/wlogout/themes/glass/" "${items_wlogout[@]}"
# Restore hyprctl.json to app settings location.
mkdir -p "/home/${user_name}/.config/com.ml4w.hyprlandsettings"
collect_and_rsync "/home/${user_name}/.config/com.ml4w.hyprlandsettings/" "${items_hyprctl[@]}"

echo "Restore completed from: ${script_dir}"
echo "Summary: rsync_failures=${rsync_failures}"
if ((rsync_failures > 0)); then
	exit 1
fi
