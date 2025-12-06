#!/bin/bash

### Variables
DOTS="$HOME/.mydotfiles/com.ml4w.dotfiles.stable/.config"
HYPR="$DOTS/hypr/conf"
SRC="$HOME/dots"

### Remove not needed app's
flatpak uninstall -y com.github.PintaProject.Pinta && flatpak uninstall -y com.ml4w.calendar && sleep 5 && clear

### Restore hyprctl settings
### Create config directory
mkdir -p "$HOME/.config/com.ml4w.hyprlandsettings"
cp -r "$SRC/hyprctl.json" "$HOME/.config/com.ml4w.hyprlandsettings/hyprctl.json"

### Restore keybindings
cp "$SRC/hypr/conf/keybindings/lateralus.conf" "$HYPR/keybindings/"
echo 'source = ~/.config/hypr/conf/keybindings/lateralus.conf' > "$HYPR/keybinding.conf"

### Update wallpapers directory
rm -rf "$DOTS/ml4w/wallpapers" && ln -s ~/Pictures/wallpapers "$DOTS/ml4w"
# bash "$DOTS/hypr/scripts/wallpaper.sh" # TODO re-check why is wrong =/

### Update hypridle configuration
sed -i -e 's/480/5200/g' -e 's/600/5600/g' -e 's/660/5660/g' -e 's/1800/6000/g' "$DOTS/hypr/hypridle.conf"
sed -i -E 's/^([[:space:]]*)font_family([[:space:]]*=[[:space:]]*)?.*$/\1font_family = Monofur Nerd Font/' "$DOTS/hypr/hyprlock.conf"

### Hyprland configuration
echo 'env = AQ_DRM_DEVICES,/dev/dri/card1:/dev/dri/card2' >> "$HYPR/environments/nvidia.conf"
echo 'source = ~/.config/hypr/conf/animations/default.conf' > "$HYPR/animation.conf"
echo 'source = ~/.config/hypr/conf/decorations/no-rounding.conf' > "$HYPR/decoration.conf"
echo 'source = ~/.config/hypr/conf/environments/nvidia.conf' > "$HYPR/environment.conf"
echo 'source = ~/.config/hypr/conf/layouts/laptop.conf' > "$HYPR/layout.conf"
echo 'source = ~/.config/hypr/conf/monitors/1920x1080.conf' > "$HYPR/monitor.conf"
echo 'source = ~/.config/hypr/conf/windows/no-border.conf' > "$HYPR/window.conf"

### Screenshot folder
echo 'screenshot_folder="$HOME/Pictures/SC"' > "$DOTS/ml4w/settings/screenshot-folder.sh"
echo "swappy -f" > "$DOTS/ml4w/settings/screenshot-editor.sh" && echo "thunar" > "$DOTS/ml4w/settings/filemanager.sh"

### Matugen
rm -rf "$DOTS/matugen" && cp -r "$SRC/matugen" "$DOTS"

### Waybar
cp -r "$SRC/waybar/themes/lateralus" "$DOTS/waybar/themes/"
echo '/lateralus;/lateralus' > "$DOTS/ml4w/settings/waybar-theme.sh"
# bash "$HOME/.config/waybar/launch.sh"

### ROFI app launcher settings
echo '* { border-radius: 0em; }' > "$DOTS/ml4w/settings/rofi-border-radius.rasi"
echo '* { border-width: 0px; }' > "$DOTS/ml4w/settings/rofi-border.rasi"
echo '0' > "$DOTS/ml4w/settings/rofi_bordersize.sh"
echo 'configuration { font: "Monofur Nerd Font 12"; }' > "$DOTS/ml4w/settings/rofi-font.rasi"

### ROFI configuration and font settings
rm -rf "$DOTS/rofi" && cp -r "$SRC/rofi" "$DOTS"
find "$DOTS/rofi/" -type f -exec sed -i 's/Fira Sans 11/Monofur Nerd Font 12/g' {} +

### Wlogout
sed -i 's/Fira Sans Semibold/Monofur Nerd Font/g' "$DOTS/wlogout/style.css"

### Kitty
rm -rf "$DOTS/kitty" && cp -r "$SRC/kitty" "$DOTS" && echo 'kitty' > "$DOTS/ml4w/settings/terminal.sh"

### Fastfetch
rm -rf "$DOTS/fastfetch" && cp -r "$SRC/fastfetch" "$DOTS"

### ZSHRC
rm -rf "$DOTS/zshrc" && cp -r "$SRC/zshrc" "$DOTS"

### nVim; Run nvim to install 
rm -rf "$DOTS/nvim" && cp -r "$SRC/nvim" "$DOTS"

### GTK 3&4
rm -rf "$DOTS/gtk-3.0" && cp -r "$SRC/gtk-3.0" "$DOTS"
rm -rf "$DOTS/gtk-4.0" && cp -r "$SRC/gtk-4.0" "$DOTS"

### qt6
rm -rf "$DOTS/qt6ct" && cp -r "$SRC/qt6ct" "$DOTS"

### OhMyPosh
rm -rf "$DOTS/ohmyposh" && cp -r "$SRC/ohmyposh" "$DOTS"

### Pacman extra settings & shell change
bash "$DOTS/ml4w/scripts/arch/pacman.sh"
bash "$DOTS/ml4w/scripts/shell.sh"
