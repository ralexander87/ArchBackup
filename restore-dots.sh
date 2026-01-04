#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Restore dotfile configs from ~/dots into your active dotfiles tree.

USB_LABEL="${BKP_USB_LABEL:-netac}"
USB_USER="${SUDO_USER:-$USER}"
USB_MOUNT="/run/media/$USB_USER/$USB_LABEL"
USB_BASE="$USB_MOUNT/START"
resolve_backup_root() {
  local base="$1"
  shift
  local root=""
  local ok=0
  for root in "$base"; do
    ok=1
    for req in "$@"; do
      [[ -e "$root/$req" ]] || ok=0
    done
    if (( ok )); then
      printf '%s\n' "$root"
      return 0
    fi
  done
  local candidate
  candidate=$(ls -1dt "$base"/*/ 2>/dev/null | head -n1)
  candidate="${candidate%/}"
  if [[ -n "$candidate" ]]; then
    ok=1
    for req in "$@"; do
      [[ -e "$candidate/$req" ]] || ok=0
    done
    if (( ok )); then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi
  return 1
}
if ! command -v mountpoint >/dev/null 2>&1; then
  err "ERROR: mountpoint not found."
  exit 1
fi
if ! mountpoint -q "$USB_MOUNT"; then
  err "ERROR: $USB_MOUNT is not a mountpoint. Is the USB plugged in and mounted?"
  exit 1
fi
RUN_AS_USER="${SUDO_USER:-$USER}"
USER_HOME="$(getent passwd "$RUN_AS_USER" | cut -d: -f6)"
BACKUP_ROOT="$(resolve_backup_root "$USB_BASE" dots || true)"
if [[ -z "$BACKUP_ROOT" ]]; then
  err "ERROR: backup root not found under $USB_BASE"
  exit 1
fi
SRC="$BACKUP_ROOT/dots"
DOTS="$USER_HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config"
HYPR="$DOTS/hypr/conf"
BACKUP_DIR="$USER_HOME/.mydotfiles/restore-dots-backup-$(date +%Y%m%d%H%M%S)"
RESTORED_ITEMS=()
BACKED_UP_ITEMS=()

TOTAL_STEPS=4
STEP=0
status() { printf '%s\n' "$*" >/dev/tty; }
progress() {
  STEP=$((STEP + 1))
  printf '[%d/%d] %s\n' "$STEP" "$TOTAL_STEPS" "$*" >/dev/tty
}
err() { printf '[!] %s\n' "$*" >/dev/tty; }

LOG_DIR="$BACKUP_ROOT/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/restore-dots-$(date +%Y%m%d%H%M%S).log"
exec >"$LOG_FILE" 2> >(tee -a "$LOG_FILE" >/dev/tty)
status "Restore dots start: $(date -Is)"
status "Log: $LOG_FILE"

if [[ ! -d "$SRC" ]]; then
  err "ERROR: source not found: $SRC"
  exit 1
fi
if [[ ! -d "$DOTS" ]]; then
  err "ERROR: dotfiles config not found: $DOTS"
  exit 1
fi
mkdir -p "$BACKUP_DIR"

# Remove not needed apps (if flatpak exists)
progress "Pre-flight"
if command -v flatpak >/dev/null 2>&1; then
  flatpak uninstall -y com.github.PintaProject.Pinta com.ml4w.calendar || true
fi

# Restore hyprctl settings
progress "Core settings"
mkdir -p "$USER_HOME/.config/com.ml4w.hyprlandsettings"
if [[ -f "$SRC/hyprctl.json" ]]; then
  cp -f "$SRC/hyprctl.json" "$USER_HOME/.config/com.ml4w.hyprlandsettings/hyprctl.json"
fi

# Restore keybindings
mkdir -p "$HYPR/keybindings"
if [[ -f "$SRC/hypr/conf/keybindings/lateralus.conf" ]]; then
  cp -f "$SRC/hypr/conf/keybindings/lateralus.conf" "$HYPR/keybindings/"
  if [[ -f "$HYPR/keybinding.conf" ]]; then
    cp -a "$HYPR/keybinding.conf" "$BACKUP_DIR/keybinding.conf"
    BACKED_UP_ITEMS+=("hypr/keybinding.conf")
  fi
  echo 'source = ~/.config/hypr/conf/keybindings/lateralus.conf' > "$HYPR/keybinding.conf"
fi

# Update wallpapers directory
if [[ -e "$DOTS/ml4w/wallpapers" ]]; then
  mv "$DOTS/ml4w/wallpapers" "$BACKUP_DIR/wallpapers" 2>/dev/null || rm -rf "$DOTS/ml4w/wallpapers"
  BACKED_UP_ITEMS+=("ml4w/wallpapers")
fi
mkdir -p "$DOTS/ml4w"
ln -s "$USER_HOME/Pictures/wallpapers" "$DOTS/ml4w/wallpapers"
RESTORED_ITEMS+=("ml4w/wallpapers -> ~/Pictures/wallpapers")

# Update hypridle configuration
if [[ -f "$DOTS/hypr/hypridle.conf" ]]; then
  cp -a "$DOTS/hypr/hypridle.conf" "$BACKUP_DIR/hypridle.conf"
  BACKED_UP_ITEMS+=("hypr/hypridle.conf")
  sed -i -e 's/480/5200/g' -e 's/600/5600/g' -e 's/660/5660/g' -e 's/1800/6000/g' "$DOTS/hypr/hypridle.conf"
  RESTORED_ITEMS+=("hypr/hypridle.conf")
fi
if [[ -f "$DOTS/hypr/hyprlock.conf" ]]; then
  cp -a "$DOTS/hypr/hyprlock.conf" "$BACKUP_DIR/hyprlock.conf"
  BACKED_UP_ITEMS+=("hypr/hyprlock.conf")
  sed -i -E 's/^([[:space:]]*)font_family([[:space:]]*=[[:space:]]*)?.*$/\1font_family = Monofur Nerd Font/' "$DOTS/hypr/hyprlock.conf"
  RESTORED_ITEMS+=("hypr/hyprlock.conf")
fi

# Hyprland configuration
progress "Hyprland config"
mkdir -p "$HYPR/environments" "$HYPR/animations" "$HYPR/decorations" "$HYPR/layouts" "$HYPR/monitors" "$HYPR/windows"
echo 'env = AQ_DRM_DEVICES,/dev/dri/card1:/dev/dri/card2' >> "$HYPR/environments/nvidia.conf"
RESTORED_ITEMS+=("hypr/environments/nvidia.conf")
cp -a "$HYPR/animation.conf" "$BACKUP_DIR/animation.conf" 2>/dev/null || true
BACKED_UP_ITEMS+=("hypr/animation.conf")
echo 'source = ~/.config/hypr/conf/animations/default.conf' > "$HYPR/animation.conf"
RESTORED_ITEMS+=("hypr/animation.conf")
cp -a "$HYPR/decoration.conf" "$BACKUP_DIR/decoration.conf" 2>/dev/null || true
BACKED_UP_ITEMS+=("hypr/decoration.conf")
echo 'source = ~/.config/hypr/conf/decorations/no-rounding.conf' > "$HYPR/decoration.conf"
RESTORED_ITEMS+=("hypr/decoration.conf")
cp -a "$HYPR/environment.conf" "$BACKUP_DIR/environment.conf" 2>/dev/null || true
BACKED_UP_ITEMS+=("hypr/environment.conf")
echo 'source = ~/.config/hypr/conf/environments/nvidia.conf' > "$HYPR/environment.conf"
RESTORED_ITEMS+=("hypr/environment.conf")
cp -a "$HYPR/layout.conf" "$BACKUP_DIR/layout.conf" 2>/dev/null || true
BACKED_UP_ITEMS+=("hypr/layout.conf")
echo 'source = ~/.config/hypr/conf/layouts/laptop.conf' > "$HYPR/layout.conf"
RESTORED_ITEMS+=("hypr/layout.conf")
cp -a "$HYPR/monitor.conf" "$BACKUP_DIR/monitor.conf" 2>/dev/null || true
BACKED_UP_ITEMS+=("hypr/monitor.conf")
echo 'source = ~/.config/hypr/conf/monitors/1920x1080.conf' > "$HYPR/monitor.conf"
RESTORED_ITEMS+=("hypr/monitor.conf")
cp -a "$HYPR/window.conf" "$BACKUP_DIR/window.conf" 2>/dev/null || true
BACKED_UP_ITEMS+=("hypr/window.conf")
echo 'source = ~/.config/hypr/conf/windows/no-border.conf' > "$HYPR/window.conf"
RESTORED_ITEMS+=("hypr/window.conf")

# Screenshot folder + tools
mkdir -p "$DOTS/ml4w/settings"
cp -a "$DOTS/ml4w/settings/screenshot-folder.sh" "$BACKUP_DIR/screenshot-folder.sh" 2>/dev/null || true
BACKED_UP_ITEMS+=("ml4w/settings/screenshot-folder.sh")
echo 'screenshot_folder="$HOME/Pictures/SC"' > "$DOTS/ml4w/settings/screenshot-folder.sh"
RESTORED_ITEMS+=("ml4w/settings/screenshot-folder.sh")
cp -a "$DOTS/ml4w/settings/screenshot-editor.sh" "$BACKUP_DIR/screenshot-editor.sh" 2>/dev/null || true
BACKED_UP_ITEMS+=("ml4w/settings/screenshot-editor.sh")
echo "swappy -f" > "$DOTS/ml4w/settings/screenshot-editor.sh"
RESTORED_ITEMS+=("ml4w/settings/screenshot-editor.sh")
cp -a "$DOTS/ml4w/settings/filemanager.sh" "$BACKUP_DIR/filemanager.sh" 2>/dev/null || true
BACKED_UP_ITEMS+=("ml4w/settings/filemanager.sh")
echo "thunar" > "$DOTS/ml4w/settings/filemanager.sh"
RESTORED_ITEMS+=("ml4w/settings/filemanager.sh")

# Matugen
if [[ -d "$SRC/matugen" ]]; then
  if [[ -d "$DOTS/matugen" ]]; then
    cp -a "$DOTS/matugen" "$BACKUP_DIR/matugen"
    BACKED_UP_ITEMS+=("matugen")
  fi
  rm -rf "$DOTS/matugen"
  cp -r "$SRC/matugen" "$DOTS"
  RESTORED_ITEMS+=("matugen")
fi

# Waybar
progress "Apps and themes"
if [[ -d "$SRC/waybar/themes/lateralus" ]]; then
  mkdir -p "$DOTS/waybar/themes"
  if [[ -d "$DOTS/waybar/themes/lateralus" ]]; then
    cp -a "$DOTS/waybar/themes/lateralus" "$BACKUP_DIR/waybar-lateralus"
    BACKED_UP_ITEMS+=("waybar/themes/lateralus")
  fi
  cp -r "$SRC/waybar/themes/lateralus" "$DOTS/waybar/themes/"
  cp -a "$DOTS/ml4w/settings/waybar-theme.sh" "$BACKUP_DIR/waybar-theme.sh" 2>/dev/null || true
  BACKED_UP_ITEMS+=("ml4w/settings/waybar-theme.sh")
  echo '/lateralus;/lateralus' > "$DOTS/ml4w/settings/waybar-theme.sh"
  RESTORED_ITEMS+=("waybar theme")
fi

# ROFI app launcher settings
cp -a "$DOTS/ml4w/settings/rofi-border-radius.rasi" "$BACKUP_DIR/rofi-border-radius.rasi" 2>/dev/null || true
BACKED_UP_ITEMS+=("ml4w/settings/rofi-border-radius.rasi")
echo '* { border-radius: 0em; }' > "$DOTS/ml4w/settings/rofi-border-radius.rasi"
RESTORED_ITEMS+=("ml4w/settings/rofi-border-radius.rasi")
cp -a "$DOTS/ml4w/settings/rofi-border.rasi" "$BACKUP_DIR/rofi-border.rasi" 2>/dev/null || true
BACKED_UP_ITEMS+=("ml4w/settings/rofi-border.rasi")
echo '* { border-width: 0px; }' > "$DOTS/ml4w/settings/rofi-border.rasi"
RESTORED_ITEMS+=("ml4w/settings/rofi-border.rasi")
cp -a "$DOTS/ml4w/settings/rofi_bordersize.sh" "$BACKUP_DIR/rofi_bordersize.sh" 2>/dev/null || true
BACKED_UP_ITEMS+=("ml4w/settings/rofi_bordersize.sh")
echo '0' > "$DOTS/ml4w/settings/rofi_bordersize.sh"
RESTORED_ITEMS+=("ml4w/settings/rofi_bordersize.sh")
cp -a "$DOTS/ml4w/settings/rofi-font.rasi" "$BACKUP_DIR/rofi-font.rasi" 2>/dev/null || true
BACKED_UP_ITEMS+=("ml4w/settings/rofi-font.rasi")
echo 'configuration { font: "Monofur Nerd Font 12"; }' > "$DOTS/ml4w/settings/rofi-font.rasi"
RESTORED_ITEMS+=("ml4w/settings/rofi-font.rasi")

# ROFI configuration and font settings
if [[ -d "$SRC/rofi" ]]; then
  if [[ -d "$DOTS/rofi" ]]; then
    cp -a "$DOTS/rofi" "$BACKUP_DIR/rofi"
    BACKED_UP_ITEMS+=("rofi")
  fi
  rm -rf "$DOTS/rofi"
  cp -r "$SRC/rofi" "$DOTS"
  find "$DOTS/rofi/" -type f -exec sed -i 's/Fira Sans 11/Monofur Nerd Font 12/g' {} +
  RESTORED_ITEMS+=("rofi")
fi

# Wlogout
if [[ -f "$DOTS/wlogout/style.css" ]]; then
  cp -a "$DOTS/wlogout/style.css" "$BACKUP_DIR/wlogout-style.css"
  BACKED_UP_ITEMS+=("wlogout/style.css")
  sed -i 's/Fira Sans Semibold/Monofur Nerd Font/g' "$DOTS/wlogout/style.css"
  RESTORED_ITEMS+=("wlogout/style.css")
fi

# Kitty
if [[ -d "$SRC/kitty" ]]; then
  if [[ -d "$DOTS/kitty" ]]; then
    cp -a "$DOTS/kitty" "$BACKUP_DIR/kitty"
    BACKED_UP_ITEMS+=("kitty")
  fi
  rm -rf "$DOTS/kitty"
  cp -r "$SRC/kitty" "$DOTS"
  cp -a "$DOTS/ml4w/settings/terminal.sh" "$BACKUP_DIR/terminal.sh" 2>/dev/null || true
  BACKED_UP_ITEMS+=("ml4w/settings/terminal.sh")
  echo 'kitty' > "$DOTS/ml4w/settings/terminal.sh"
  RESTORED_ITEMS+=("kitty")
fi

# Fastfetch
if [[ -d "$SRC/fastfetch" ]]; then
  if [[ -d "$DOTS/fastfetch" ]]; then
    cp -a "$DOTS/fastfetch" "$BACKUP_DIR/fastfetch"
    BACKED_UP_ITEMS+=("fastfetch")
  fi
  rm -rf "$DOTS/fastfetch"
  cp -r "$SRC/fastfetch" "$DOTS"
  RESTORED_ITEMS+=("fastfetch")
fi

# ZSHRC
if [[ -d "$SRC/zshrc" ]]; then
  if [[ -d "$DOTS/zshrc" ]]; then
    cp -a "$DOTS/zshrc" "$BACKUP_DIR/zshrc"
    BACKED_UP_ITEMS+=("zshrc")
  fi
  rm -rf "$DOTS/zshrc"
  cp -r "$SRC/zshrc" "$DOTS"
  RESTORED_ITEMS+=("zshrc")
fi

# nVim
if [[ -d "$SRC/nvim" ]]; then
  if [[ -d "$DOTS/nvim" ]]; then
    cp -a "$DOTS/nvim" "$BACKUP_DIR/nvim"
    BACKED_UP_ITEMS+=("nvim")
  fi
  rm -rf "$DOTS/nvim"
  cp -r "$SRC/nvim" "$DOTS"
  RESTORED_ITEMS+=("nvim")
fi

# GTK 3&4
if [[ -d "$SRC/gtk-3.0" ]]; then
  if [[ -d "$DOTS/gtk-3.0" ]]; then
    cp -a "$DOTS/gtk-3.0" "$BACKUP_DIR/gtk-3.0"
    BACKED_UP_ITEMS+=("gtk-3.0")
  fi
  rm -rf "$DOTS/gtk-3.0"
  cp -r "$SRC/gtk-3.0" "$DOTS"
  RESTORED_ITEMS+=("gtk-3.0")
fi
if [[ -d "$SRC/gtk-4.0" ]]; then
  if [[ -d "$DOTS/gtk-4.0" ]]; then
    cp -a "$DOTS/gtk-4.0" "$BACKUP_DIR/gtk-4.0"
    BACKED_UP_ITEMS+=("gtk-4.0")
  fi
  rm -rf "$DOTS/gtk-4.0"
  cp -r "$SRC/gtk-4.0" "$DOTS"
  RESTORED_ITEMS+=("gtk-4.0")
fi

# qt6
if [[ -d "$SRC/qt6ct" ]]; then
  if [[ -d "$DOTS/qt6ct" ]]; then
    cp -a "$DOTS/qt6ct" "$BACKUP_DIR/qt6ct"
    BACKED_UP_ITEMS+=("qt6ct")
  fi
  rm -rf "$DOTS/qt6ct"
  cp -r "$SRC/qt6ct" "$DOTS"
  RESTORED_ITEMS+=("qt6ct")
fi

# OhMyPosh
if [[ -d "$SRC/ohmyposh" ]]; then
  if [[ -d "$DOTS/ohmyposh" ]]; then
    cp -a "$DOTS/ohmyposh" "$BACKUP_DIR/ohmyposh"
    BACKED_UP_ITEMS+=("ohmyposh")
  fi
  rm -rf "$DOTS/ohmyposh"
  cp -r "$SRC/ohmyposh" "$DOTS"
  RESTORED_ITEMS+=("ohmyposh")
fi

status "Restore dots done."
status "Target: $BACKUP_ROOT"
status "Log: $LOG_FILE"
