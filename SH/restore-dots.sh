#!/usr/bin/env bash

set -u

QUIET=true
TOTAL_STEPS=4
STEP=0

status() {
  printf '%s\n' "$*"
}

progress() {
  STEP=$((STEP + 1))
  status "[$STEP/$TOTAL_STEPS] $1"
}

err() {
  printf '%s\n' "$*" >&2
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_cmd() {
  if $QUIET; then
    "$@" >/dev/null
  else
    "$@"
  fi
}

run_cmd_no_check() {
  if $QUIET; then
    "$@" >/dev/null || true
  else
    "$@" || true
  fi
}

backup_path() {
  local path="$1"
  local backup_dir="$2"
  local label="${3:-}"
  if [[ ! -e "$path" ]]; then
    return 1
  fi
  local name
  if [[ -n "$label" ]]; then
    name="$label"
  else
    name="$(basename "$path")"
  fi
  local dest="${backup_dir}/${name}"
  if [[ -d "$path" ]]; then
    cp -a "$path" "$dest"
  else
    cp -a "$path" "$dest"
  fi
  printf '%s\n' "$name"
}

replace_in_file() {
  local path="$1"
  local old="$2"
  local new="$3"
  if [[ ! -f "$path" ]]; then
    return 1
  fi
  sed -i "s|${old}|${new}|g" "$path"
}

regex_replace_in_file() {
  local path="$1"
  local pattern="$2"
  local repl="$3"
  if [[ ! -f "$path" ]]; then
    return 1
  fi
  perl -0777 -pe "s/${pattern}/${repl}/mg" -i "$path"
}

has_required() {
  local base="$1"
  shift
  local name
  for name in "$@"; do
    if [[ ! -e "$base/$name" ]]; then
      return 1
    fi
  done
  return 0
}

resolve_backup_root() {
  local base_root="$1"
  shift
  local required=("$@")
  if has_required "$base_root" "${required[@]}"; then
    printf '%s\n' "$base_root"
    return 0
  fi
  local candidate
  for candidate in "$base_root"/*/; do
    if [[ ! -d "$candidate" ]]; then
      continue
    fi
    if has_required "${candidate%/}" "${required[@]}"; then
      printf '%s\n' "${candidate%/}"
      return 0
    fi
  done
  return 1
}

main() {
  local run_as_user="${SUDO_USER:-${USER:-$(whoami)}}"
  local user_home
  user_home="$(getent passwd "$run_as_user" | cut -d: -f6)"
  if [[ -z "$user_home" ]]; then
    user_home="$HOME"
  fi
  local usb_label="${BKP_USB_LABEL:-netac}"
  local usb_user="${SUDO_USER:-${USER:-$run_as_user}}"
  local usb_mount="/run/media/${usb_user}/${usb_label}"
  local base_root="${usb_mount}/START"

  if ! command_exists mountpoint; then
    err "ERROR: mountpoint not found."
    exit 1
  fi
  if ! mountpoint -q "$usb_mount"; then
    err "ERROR: ${usb_mount} is not a mountpoint. Is the USB plugged in and mounted?"
    exit 1
  fi
  local backup_root
  if ! backup_root="$(resolve_backup_root "$base_root" "dots")"; then
    err "ERROR: backup root not found under ${base_root}"
    exit 1
  fi
  local src="${backup_root}/dots"
  local dots="${user_home}/.mydotfiles/com.ml4w.dotfiles.stable/.config"
  local hypr="${dots}/hypr/conf"

  status "Restore dots start: $(date '+%Y-%m-%dT%H:%M:%S')"
  progress "Pre-flight"

  if [[ ! -d "$src" ]]; then
    err "ERROR: source not found: ${src}"
    exit 1
  fi
  if [[ ! -d "$dots" ]]; then
    err "ERROR: dotfiles config not found: ${dots}"
    exit 1
  fi

# Local backup directoory
  local backup_dir="${user_home}/.mydotfiles/restore-dots-backup-$(date '+%Y%m%d%H%M%S')"
  mkdir -p "$backup_dir"
  local restored_items=()
  local backed_up_items=()

# Remove PintaProject
  if command_exists flatpak; then
    run_cmd_no_check flatpak uninstall -y com.github.PintaProject.Pinta com.ml4w.calendar
  fi

# Hyprctl settings foor ML4w
  progress "Core settings"
  mkdir -p "${user_home}/.config/com.ml4w.hyprlandsettings"
  local hyprctl_src="${src}/hyprctl.json"
  if [[ -f "$hyprctl_src" ]]; then
    cp -a "$hyprctl_src" "${user_home}/.config/com.ml4w.hyprlandsettings/hyprctl.json"
    restored_items+=("hyprctl.json")
  fi

# My keybinds 
  mkdir -p "${hypr}/keybindings"
  local kb_src="${src}/hypr/conf/keybindings/lateralus.conf"
  if [[ -f "$kb_src" ]]; then
    cp -a "$kb_src" "${hypr}/keybindings/lateralus.conf"
    local keybinding_conf="${hypr}/keybinding.conf"
    if [[ -f "$keybinding_conf" ]]; then
      if name="$(backup_path "$keybinding_conf" "$backup_dir" "keybinding.conf")"; then
        backed_up_items+=("$name")
      fi
    fi
    printf '%s\n' "source = ~/.config/hypr/conf/keybindings/lateralus.conf" >"$keybinding_conf"
    restored_items+=("hypr/keybindings/lateralus.conf")
  fi

# Wallpaper ln from Pictures to ml4w destination
  local wp_path="${dots}/ml4w/wallpapers"
  if [[ -e "$wp_path" ]]; then
    if mv "$wp_path" "${backup_dir}/wallpapers" 2>/dev/null; then
      backed_up_items+=("ml4w/wallpapers")
    else
      if [[ -d "$wp_path" ]]; then
        rm -rf "$wp_path"
      else
        rm -f "$wp_path"
      fi
    fi
  fi
  mkdir -p "${dots}/ml4w"
  ln -sfn "${user_home}/Pictures/wallpapers" "$wp_path"
  restored_items+=("ml4w/wallpapers -> ~/Pictures/wallpapers")

# Hypridle changes
  local hypridle="${dots}/hypr/hypridle.conf"
  if [[ -f "$hypridle" ]]; then
    if name="$(backup_path "$hypridle" "$backup_dir" "hypridle.conf")"; then
      backed_up_items+=("$name")
    fi
    replace_in_file "$hypridle" "480" "5200"
    replace_in_file "$hypridle" "600" "5600"
    replace_in_file "$hypridle" "660" "5660"
    replace_in_file "$hypridle" "1800" "6000"
    restored_items+=("hypr/hypridle.conf")
  fi

# Hyprlock: restore from backup media without modifications.
  local src_hyprlock="${src}/hypr/hyprlock.conf"
  local dest_hyprlock="${dots}/hypr/hyprlock.conf"
  if [[ -f "$src_hyprlock" ]]; then
    if [[ -f "$dest_hyprlock" ]]; then
      if name="$(backup_path "$dest_hyprlock" "$backup_dir" "hyprlock.conf")"; then
        backed_up_items+=("$name")
      fi
    fi
    cp -a "$src_hyprlock" "$dest_hyprlock"
    restored_items+=("hypr/hyprlock.conf")
  fi

  local logo_src="${src}/hypr/logo-2.png"
  local logo_dest="${dots}/hypr/logo-2.png"
  if [[ -f "$logo_src" ]]; then
    if [[ -f "$logo_dest" ]]; then
      if name="$(backup_path "$logo_dest" "$backup_dir" "logo-2.png")"; then
        backed_up_items+=("$name")
      fi
    fi
    cp -a "$logo_src" "$logo_dest"
    restored_items+=("hypr/logo-2.png")
  fi

  local uptime_src="${src}/hypr/scripts/uptime.sh"
  local uptime_dest_dir="${dots}/hypr/scripts"
  local uptime_dest="${uptime_dest_dir}/uptime.sh"
  if [[ -f "$uptime_src" ]]; then
    mkdir -p "$uptime_dest_dir"
    if [[ -f "$uptime_dest" ]]; then
      if name="$(backup_path "$uptime_dest" "$backup_dir" "uptime.sh")"; then
        backed_up_items+=("$name")
      fi
    fi
    cp -a "$uptime_src" "$uptime_dest"
    restored_items+=("hypr/scripts/uptime.sh")
  fi

# Checking for default folders 
  progress "Hyprland config"
  mkdir -p "${hypr}/environments" "${hypr}/animations" "${hypr}/decorations" "${hypr}/layouts" "${hypr}/monitors" "${hypr}/windows"

# Add nVidia enviroments
  local nvidia_conf="${hypr}/environments/nvidia.conf"
  if [[ -f "$nvidia_conf" ]]; then
    if name="$(backup_path "$nvidia_conf" "$backup_dir" "nvidia.conf")"; then
      backed_up_items+=("$name")
    fi
  fi
  printf '%s\n' "env = AQ_DRM_DEVICES,/dev/dri/card1:/dev/dri/card2" >>"$nvidia_conf"
  restored_items+=("hypr/environments/nvidia.conf")

# Basic changes for my system
  local name src_line path
  for name in animation.conf decoration.conf environment.conf layout.conf monitor.conf window.conf; do
    case "$name" in
      animation.conf) src_line="source = ~/.config/hypr/conf/animations/default.conf" ;;
      decoration.conf) src_line="source = ~/.config/hypr/conf/decorations/no-rounding.conf" ;;
      environment.conf) src_line="source = ~/.config/hypr/conf/environments/nvidia.conf" ;;
      layout.conf) src_line="source = ~/.config/hypr/conf/layouts/laptop.conf" ;;
      monitor.conf) src_line="source = ~/.config/hypr/conf/monitors/1920x1080.conf" ;;
      window.conf) src_line="source = ~/.config/hypr/conf/windows/no-border.conf" ;;
    esac
    path="${hypr}/${name}"
    if [[ -f "$path" ]]; then
      if name_bk="$(backup_path "$path" "$backup_dir" "$name")"; then
        backed_up_items+=("$name_bk")
      fi
    fi
    printf '%s\n' "$src_line" >"$path"
    restored_items+=("hypr/${name}")
  done

# Change some default location's and fonts
  local settings_dir="${dots}/ml4w/settings"
  mkdir -p "$settings_dir"
  local fname content
  for fname in screenshot-folder screenshot-editor filemanager rofi-border-radius.rasi rofi-border.rasi rofi_bordersize.sh rofi-font.rasi; do
    case "$fname" in
      screenshot-folder) content='screenshot_folder="$HOME/Pictures/SC"' ;;
      screenshot-editor) content='swappy -f' ;;
      filemanager) content='thunar' ;;
      rofi-border-radius.rasi) content='* { border-radius: 0em; }' ;;
      rofi-border.rasi) content='* { border-width: 0px; }' ;;
      rofi_bordersize.sh) content='0' ;;
      rofi-font.rasi) content='configuration { font: "Monofur Nerd Font 12"; }' ;;
    esac
    path="${settings_dir}/${fname}"
    if [[ -f "$path" ]]; then
      if name_bk="$(backup_path "$path" "$backup_dir" "$fname")"; then
        backed_up_items+=("$name_bk")
      fi
    fi
    printf '%s\n' "$content" >"$path"
    restored_items+=("ml4w/settings/${fname}")
  done

# Matugen color's
  progress "Apps and themes"
  local matugen_src="${src}/matugen"
  if [[ -d "$matugen_src" ]]; then
    local matugen_dest="${dots}/matugen"
    if [[ -d "$matugen_dest" ]]; then
      if name="$(backup_path "$matugen_dest" "$backup_dir" "matugen")"; then
        backed_up_items+=("$name")
      fi
      rm -rf "$matugen_dest"
    fi
    cp -a "$matugen_src" "$matugen_dest"
    restored_items+=("matugen")
  fi

# Cava settings and theme
  local cava_src="${src}/cava"
  if [[ -d "$cava_src" ]]; then
    local cava_dest="${dots}/cava"
    if [[ -d "$cava_dest" ]]; then
      if name="$(backup_path "$cava_dest" "$backup_dir" "cava")"; then
        backed_up_items+=("$name")
      fi
      rm -rf "$cava_dest"
    fi
    cp -a "$cava_src" "$cava_dest"
    restored_items+=("cava")
    local config_cava="${user_home}/.config/cava"
    if [[ -L "$config_cava" || -e "$config_cava" ]]; then
      rm -rf "$config_cava"
    fi
    mkdir -p "${user_home}/.config"
    ln -sfn "$cava_dest" "$config_cava"
  fi

# My waybar themes: lateralus and ralex
  local waybar_src="${src}/waybar/themes/lateralus"
  if [[ -d "$waybar_src" ]]; then
    local waybar_dest="${dots}/waybar/themes"
    mkdir -p "$waybar_dest"
    local existing="${waybar_dest}/lateralus"
    if [[ -d "$existing" ]]; then
      if name="$(backup_path "$existing" "$backup_dir" "waybar-lateralus")"; then
        backed_up_items+=("$name")
      fi
      rm -rf "$existing"
    fi
    cp -a "$waybar_src" "${waybar_dest}/lateralus"
    restored_items+=("waybar theme (lateralus)")
  fi

  local waybar_src="${src}/waybar/themes/ralex"
  if [[ -d "$waybar_src" ]]; then
    local waybar_dest="${dots}/waybar/themes"
    mkdir -p "$waybar_dest"
    local existing="${waybar_dest}/ralex"
    if [[ -d "$existing" ]]; then
      if name="$(backup_path "$existing" "$backup_dir" "waybar-ralex")"; then
        backed_up_items+=("$name")
      fi
      rm -rf "$existing"
    fi
    cp -a "$waybar_src" "${waybar_dest}/ralex"
    local waybar_setting="${settings_dir}/waybar-theme.sh"
    if [[ -f "$waybar_setting" ]]; then
      if name="$(backup_path "$waybar_setting" "$backup_dir" "waybar-theme.sh")"; then
        backed_up_items+=("$name")
      fi
    fi
    printf '%s\n' "/ralex;/ralex" >"$waybar_setting"
    restored_items+=("waybar theme (ralex)")
  fi

# Rofi changes
  local rofi_src="${src}/rofi"
  local rofi_dest="${dots}/rofi"
  if [[ -d "$rofi_src" ]]; then
    if [[ -d "$rofi_dest" ]]; then
      if name="$(backup_path "$rofi_dest" "$backup_dir" "rofi")"; then
        backed_up_items+=("$name")
      fi
      rm -rf "$rofi_dest"
    fi
    cp -a "$rofi_src" "$rofi_dest"
    local file
    while IFS= read -r -d '' file; do
      replace_in_file "$file" "Fira Sans 11" "Monofur Nerd Font 12"
    done < <(find "$rofi_dest" -type f -print0)
    restored_items+=("rofi")
  fi

# Wlogout changes
  local wlogout_style="${dots}/wlogout/style.css"
  if [[ -f "$wlogout_style" ]]; then
    if name="$(backup_path "$wlogout_style" "$backup_dir" "wlogout-style.css")"; then
      backed_up_items+=("$name")
    fi
    replace_in_file "$wlogout_style" "Fira Sans Semibold" "Monofur Nerd Font"
    restored_items+=("wlogout/style.css")
  fi

# Kitty changes (kitty + zsh)
  local kitty_src="${src}/kitty"
  local kitty_dest="${dots}/kitty"
  if [[ -d "$kitty_src" ]]; then
    if [[ -d "$kitty_dest" ]]; then
      if name="$(backup_path "$kitty_dest" "$backup_dir" "kitty")"; then
        backed_up_items+=("$name")
      fi
      rm -rf "$kitty_dest"
    fi
    cp -a "$kitty_src" "$kitty_dest"
    local term_setting="${settings_dir}/terminal.sh"
    if [[ -f "$term_setting" ]]; then
      if name="$(backup_path "$term_setting" "$backup_dir" "terminal.sh")"; then
        backed_up_items+=("$name")
      fi
    fi
    printf '%s\n' "kitty" >"$term_setting"
    restored_items+=("kitty")
  fi

  local extra
  for extra in fastfetch zshrc nvim gtk-3.0 gtk-4.0 qt6ct ohmyposh; do
    local src_path="${src}/${extra}"
    local dest_path="${dots}/${extra}"
    if [[ -d "$src_path" ]]; then
      if [[ -d "$dest_path" ]]; then
        if name="$(backup_path "$dest_path" "$backup_dir" "$extra")"; then
          backed_up_items+=("$name")
        fi
        rm -rf "$dest_path"
      fi
      cp -a "$src_path" "$dest_path"
      restored_items+=("$extra")
    fi
  done

  local script_path="${user_home}/.mydotfiles/com.ml4w.dotfiles.stable/.config/ml4w/scripts/shell.sh"
  if [[ -f "$script_path" ]]; then
    run_cmd_no_check bash "$script_path"
  fi

# Status
  status "Restore dots done."
  status "Restored items: ${#restored_items[@]}"
  status "Backed up items: ${#backed_up_items[@]}"
  status "Target: ${backup_root}"
}

main "$@"
