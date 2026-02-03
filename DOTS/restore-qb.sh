#!/usr/bin/env bash
set -euo pipefail

# Restore qBittorrent Dracula theme and config.

user_name="${USER:-$(id -un)}"
qb_dir="/home/${user_name}/.config/qBittorrent"
qb_theme="${qb_dir}/dracula.qbtheme"
qb_conf="${qb_dir}/qBittorrent.conf"
theme_url="https://github.com/dracula/qbittorrent/raw/master/dracula.qbtheme"

mkdir -p "$qb_dir"

need_download=true
if [[ -f "$qb_theme" && -f "$qb_conf" ]]; then
	if grep -q "^General\\\\CustomUIThemePath=${qb_theme}$" "$qb_conf" \
		&& grep -q "^General\\\\UseCustomUITheme=true$" "$qb_conf"; then
		need_download=false
	fi
fi

if $need_download; then
	if command -v curl >/dev/null 2>&1; then
		curl -L -o "$qb_theme" "$theme_url" || true
	elif command -v wget >/dev/null 2>&1; then
		wget -O "$qb_theme" "$theme_url" || true
	else
		echo "Neither curl nor wget found; skipping qBittorrent theme download."
	fi
fi

if [[ -f "$qb_conf" ]]; then
	if grep -q "^General\\\\CustomUIThemePath=" "$qb_conf"; then
		sed -i "s|^General\\\\CustomUIThemePath=.*|General\\\\CustomUIThemePath=${qb_theme}|" "$qb_conf"
	else
		printf "%s\n" "General\\CustomUIThemePath=${qb_theme}" >>"$qb_conf"
	fi
	if grep -q "^General\\\\UseCustomUITheme=" "$qb_conf"; then
		sed -i "s|^General\\\\UseCustomUITheme=.*|General\\\\UseCustomUITheme=true|" "$qb_conf"
	else
		printf "%s\n" "General\\UseCustomUITheme=true" >>"$qb_conf"
	fi
else
	echo "qBittorrent config not found at ${qb_conf}; skipping config edits."
fi
