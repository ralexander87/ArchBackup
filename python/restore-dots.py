#!/usr/bin/env python3
import getpass
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime


QUIET = True
TOTAL_STEPS = 4
STEP = 0


def command_exists(cmd):
    return shutil.which(cmd) is not None


def run(cmd, check=True):
    if QUIET:
        return subprocess.run(cmd, check=check, stdout=subprocess.DEVNULL)
    return subprocess.run(cmd, check=check)


def status(msg):
    print(msg)


def progress(msg):
    global STEP
    STEP += 1
    status(f"[{STEP}/{TOTAL_STEPS}] {msg}")


def err(msg):
    print(msg, file=sys.stderr)


def backup_path(path, backup_dir, label=None):
    if not os.path.exists(path):
        return None
    name = label or os.path.basename(path)
    dest = os.path.join(backup_dir, name)
    if os.path.isdir(path):
        shutil.copytree(path, dest, dirs_exist_ok=True)
    else:
        shutil.copy2(path, dest)
    return name


def replace_in_file(path, replacements):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            content = fh.read()
        for old, new in replacements:
            content = content.replace(old, new)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
        return True
    except OSError:
        return False


def regex_replace_in_file(path, pattern, repl):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            content = fh.read()
        content = re.sub(pattern, repl, content, flags=re.MULTILINE)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
        return True
    except OSError:
        return False


def resolve_backup_root(base_root, required):
    def has_required(path):
        return all(os.path.exists(os.path.join(path, name)) for name in required)
    if has_required(base_root):
        return base_root
    try:
        candidates = [
            os.path.join(base_root, name)
            for name in os.listdir(base_root)
            if os.path.isdir(os.path.join(base_root, name))
        ]
    except OSError:
        return None
    candidates.sort(key=os.path.getmtime, reverse=True)
    for candidate in candidates:
        if has_required(candidate):
            return candidate
    return None


def main():
    run_as_user = os.environ.get("SUDO_USER") or os.environ.get("USER") or getpass.getuser()
    user_home = os.path.expanduser(f"~{run_as_user}")
    usb_label = os.environ.get("BKP_USB_LABEL", "netac")
    usb_user = os.environ.get("SUDO_USER") or os.environ.get("USER") or run_as_user
    usb_mount = f"/run/media/{usb_user}/{usb_label}"
    base_root = os.path.join(usb_mount, "START")
    if not command_exists("mountpoint"):
        err("ERROR: mountpoint not found.")
        sys.exit(1)
    if run(["mountpoint", "-q", usb_mount], check=False).returncode != 0:
        err(f"ERROR: {usb_mount} is not a mountpoint. Is the USB plugged in and mounted?")
        sys.exit(1)
    backup_root = resolve_backup_root(base_root, ["dots"])
    if not backup_root:
        print(f"ERROR: backup root not found under {base_root}", file=sys.stderr)
        sys.exit(1)
    src = os.path.join(backup_root, "dots")
    dots = os.path.join(user_home, ".mydotfiles", "com.ml4w.dotfiles.stable", ".config")
    hypr = os.path.join(dots, "hypr", "conf")

    status(f"Restore dots start: {datetime.now().isoformat()}")
    progress("Pre-flight")

    if not os.path.isdir(src):
        err(f"ERROR: source not found: {src}")
        sys.exit(1)
    if not os.path.isdir(dots):
        err(f"ERROR: dotfiles config not found: {dots}")
        sys.exit(1)

    # Local backup directoory
    backup_dir = os.path.join(
        user_home, ".mydotfiles", f"restore-dots-backup-{datetime.now().strftime('%Y%m%d%H%M%S')}"
    )
    os.makedirs(backup_dir, exist_ok=True)
    restored_items = []
    backed_up_items = []

    # Remove PintaProject
    if command_exists("flatpak"):
        run(["flatpak", "uninstall", "-y", "com.github.PintaProject.Pinta", "com.ml4w.calendar"], check=False)

    # Hyprctl settings foor ML4w
    progress("Core settings")
    os.makedirs(os.path.join(user_home, ".config", "com.ml4w.hyprlandsettings"), exist_ok=True)
    hyprctl_src = os.path.join(src, "hyprctl.json")
    if os.path.isfile(hyprctl_src):
        shutil.copy2(hyprctl_src, os.path.join(user_home, ".config", "com.ml4w.hyprlandsettings", "hyprctl.json"))
        restored_items.append("hyprctl.json")

    # My keybinds
    os.makedirs(os.path.join(hypr, "keybindings"), exist_ok=True)
    kb_src = os.path.join(src, "hypr", "conf", "keybindings", "lateralus.conf")
    if os.path.isfile(kb_src):
        shutil.copy2(kb_src, os.path.join(hypr, "keybindings", "lateralus.conf"))
        keybinding_conf = os.path.join(hypr, "keybinding.conf")
        if os.path.isfile(keybinding_conf):
            backed_up_items.append(backup_path(keybinding_conf, backup_dir, "keybinding.conf"))
        with open(keybinding_conf, "w", encoding="utf-8") as fh:
            fh.write("source = ~/.config/hypr/conf/keybindings/lateralus.conf\n")
        restored_items.append("hypr/keybindings/lateralus.conf")

    # Wallpaper ln from Pictures to ml4w destination
    wp_path = os.path.join(dots, "ml4w", "wallpapers")
    if os.path.exists(wp_path):
        try:
            shutil.move(wp_path, os.path.join(backup_dir, "wallpapers"))
            backed_up_items.append("ml4w/wallpapers")
        except OSError:
            if os.path.isdir(wp_path):
                shutil.rmtree(wp_path)
            else:
                os.remove(wp_path)
    os.makedirs(os.path.join(dots, "ml4w"), exist_ok=True)
    os.symlink(os.path.join(user_home, "Pictures", "wallpapers"), wp_path)
    restored_items.append("ml4w/wallpapers -> ~/Pictures/wallpapers")

    # Hypridle changes
    hypridle = os.path.join(dots, "hypr", "hypridle.conf")
    if os.path.isfile(hypridle):
        backed_up_items.append(backup_path(hypridle, backup_dir, "hypridle.conf"))
        replace_in_file(
            hypridle,
            [("480", "5200"), ("600", "5600"), ("660", "5660"), ("1800", "6000")],
        )
        restored_items.append("hypr/hypridle.conf")

    # Hyprlock changes
    hyprlock = os.path.join(dots, "hypr", "hyprlock.conf")
    if os.path.isfile(hyprlock):
        backed_up_items.append(backup_path(hyprlock, backup_dir, "hyprlock.conf"))
        regex_replace_in_file(
            hyprlock,
            r'^([ \t]*)font_family([ \t]*=[ \t]*)?.*$',
            r'\1font_family = JetBrains Mono Nerd Font ExtraBold Italic',
        )
        regex_replace_in_file(
            hyprlock,
            r'^([ \t]*)path[ \t]*=[ \t]*\$ml4w_cache_folder/square_wallpaper\.png[ \t]*$',
            r'\1path = ~/.mydotfiles/com.ml4w.dotfiles.stable/.config/hypr/logo-2.png',
        )
        regex_replace_in_file(
            hyprlock,
            r'Input Password\.\.\.',
            r'Pedo mellon a minno!\.\.\.',
        )
        regex_replace_in_file(
            hyprlock,
            r'^([ \t]*)size[ \t]*=[ \t]*200,[ \t]*50[ \t]*$',
            r'\1size = 400, 50',
        )
        regex_replace_in_file(
            hyprlock,
            r'^([ \t]*)font_size[ \t]*=[ \t]*70[ \t]*$',
            r'\1font_size = 150',
        )
        regex_replace_in_file(
            hyprlock,
            r'^([ \t]*)halign[ \t]*=[ \t]*right[ \t]*$',
            r'\1halign = center',
        )
        regex_replace_in_file(
            hyprlock,
            r'^([ \t]*)ignore_empty_input[ \t]*=[ \t]*true[ \t]*$',
            r'\1ignore_empty_input = true\n\1animation = fade, 0',
        )
        weather_path = os.path.join(backup_root, "home", "Shared", "weather")
        if os.path.isfile(weather_path):
            try:
                with open(weather_path, "r", encoding="utf-8", errors="replace") as fh:
                    weather_text = fh.read().strip()
                with open(hyprlock, "a", encoding="utf-8") as fh:
                    fh.write("\n" + weather_text + "\n")
            except OSError:
                pass
        restored_items.append("hypr/hyprlock.conf")

    # Checking for default folders
    progress("Hyprland config")
    os.makedirs(os.path.join(hypr, "environments"), exist_ok=True)
    os.makedirs(os.path.join(hypr, "animations"), exist_ok=True)
    os.makedirs(os.path.join(hypr, "decorations"), exist_ok=True)
    os.makedirs(os.path.join(hypr, "layouts"), exist_ok=True)
    os.makedirs(os.path.join(hypr, "monitors"), exist_ok=True)
    os.makedirs(os.path.join(hypr, "windows"), exist_ok=True)

    # Add nVidia enviroments
    nvidia_conf = os.path.join(hypr, "environments", "nvidia.conf")
    if os.path.isfile(nvidia_conf):
        backed_up_items.append(backup_path(nvidia_conf, backup_dir, "nvidia.conf"))
    with open(nvidia_conf, "a", encoding="utf-8") as fh:
        fh.write("env = AQ_DRM_DEVICES,/dev/dri/card1:/dev/dri/card2\n")
    restored_items.append("hypr/environments/nvidia.conf")

    # Basic changes for my system
    for name, src_line in [
        ("animation.conf", "source = ~/.config/hypr/conf/animations/default.conf\n"),
        ("decoration.conf", "source = ~/.config/hypr/conf/decorations/no-rounding.conf\n"),
        ("environment.conf", "source = ~/.config/hypr/conf/environments/nvidia.conf\n"),
        ("layout.conf", "source = ~/.config/hypr/conf/layouts/laptop.conf\n"),
        ("monitor.conf", "source = ~/.config/hypr/conf/monitors/1920x1080.conf\n"),
        ("window.conf", "source = ~/.config/hypr/conf/windows/no-border.conf\n"),
    ]:
        path = os.path.join(hypr, name)
        if os.path.isfile(path):
            backed_up_items.append(backup_path(path, backup_dir, name))
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(src_line)
        restored_items.append(f"hypr/{name}")

    # Change some default location's and fonts
    settings_dir = os.path.join(dots, "ml4w", "settings")
    os.makedirs(settings_dir, exist_ok=True)
    for fname, content in [
        ("screenshot-folder.sh", 'screenshot_folder="$HOME/Pictures/SC"\n'),
        ("screenshot-editor.sh", "swappy -f\n"),
        ("filemanager.sh", "thunar\n"),
        ("rofi-border-radius.rasi", "* { border-radius: 0em; }\n"),
        ("rofi-border.rasi", "* { border-width: 0px; }\n"),
        ("rofi_bordersize.sh", "0\n"),
        ("rofi-font.rasi", 'configuration { font: "Monofur Nerd Font 12"; }\n'),
    ]:
        path = os.path.join(settings_dir, fname)
        if os.path.isfile(path):
            backed_up_items.append(backup_path(path, backup_dir, fname))
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
        restored_items.append(f"ml4w/settings/{fname}")

    # Matugen color's
    progress("Apps and themes")
    matugen_src = os.path.join(src, "matugen")
    if os.path.isdir(matugen_src):
        matugen_dest = os.path.join(dots, "matugen")
        if os.path.isdir(matugen_dest):
            backed_up_items.append(backup_path(matugen_dest, backup_dir, "matugen"))
            shutil.rmtree(matugen_dest)
        shutil.copytree(matugen_src, matugen_dest, dirs_exist_ok=True)
        restored_items.append("matugen")

    # Cava settings and theme
    cava_src = os.path.join(src, "cava")
    if os.path.isdir(cava_src):
        cava_dest = os.path.join(dots, "cava")
        if os.path.isdir(cava_dest):
            backed_up_items.append(backup_path(cava_dest, backup_dir, "cava"))
            shutil.rmtree(cava_dest)
        shutil.copytree(cava_src, cava_dest, dirs_exist_ok=True)
        restored_items.append("cava")
        config_cava = os.path.join(user_home, ".config", "cava")
        if os.path.islink(config_cava) or os.path.exists(config_cava):
            if os.path.isdir(config_cava) and not os.path.islink(config_cava):
                shutil.rmtree(config_cava)
            else:
                os.remove(config_cava)
        os.makedirs(os.path.join(user_home, ".config"), exist_ok=True)
        os.symlink(cava_dest, config_cava)

    # My waybar themes: lateralus and ralex
    waybar_src = os.path.join(src, "waybar", "themes", "lateralus")
    if os.path.isdir(waybar_src):
        waybar_dest = os.path.join(dots, "waybar", "themes")
        os.makedirs(waybar_dest, exist_ok=True)
        existing = os.path.join(waybar_dest, "lateralus")
        if os.path.isdir(existing):
            backed_up_items.append(backup_path(existing, backup_dir, "waybar-lateralus"))
            shutil.rmtree(existing)
        shutil.copytree(waybar_src, os.path.join(waybar_dest, "lateralus"), dirs_exist_ok=True)
        restored_items.append("waybar theme (lateralus)")

    waybar_src = os.path.join(src, "waybar", "themes", "ralex")
    if os.path.isdir(waybar_src):
        waybar_dest = os.path.join(dots, "waybar", "themes")
        os.makedirs(waybar_dest, exist_ok=True)
        existing = os.path.join(waybar_dest, "ralex")
        if os.path.isdir(existing):
            backed_up_items.append(backup_path(existing, backup_dir, "waybar-ralex"))
            shutil.rmtree(existing)
        shutil.copytree(waybar_src, os.path.join(waybar_dest, "ralex"), dirs_exist_ok=True)
        waybar_setting = os.path.join(settings_dir, "waybar-theme.sh")
        if os.path.isfile(waybar_setting):
            backed_up_items.append(backup_path(waybar_setting, backup_dir, "waybar-theme.sh"))
        with open(waybar_setting, "w", encoding="utf-8") as fh:
            fh.write("/ralex;/ralex\n")
        restored_items.append("waybar theme (ralex)")

    # Rofi changes
    rofi_src = os.path.join(src, "rofi")
    rofi_dest = os.path.join(dots, "rofi")
    if os.path.isdir(rofi_src):
        if os.path.isdir(rofi_dest):
            backed_up_items.append(backup_path(rofi_dest, backup_dir, "rofi"))
            shutil.rmtree(rofi_dest)
        shutil.copytree(rofi_src, rofi_dest, dirs_exist_ok=True)
        for root, _, files in os.walk(rofi_dest):
            for name in files:
                path = os.path.join(root, name)
                replace_in_file(path, [("Fira Sans 11", "Monofur Nerd Font 12")])
        restored_items.append("rofi")

    # Wlogout changes
    wlogout_style = os.path.join(dots, "wlogout", "style.css")
    if os.path.isfile(wlogout_style):
        backed_up_items.append(backup_path(wlogout_style, backup_dir, "wlogout-style.css"))
        replace_in_file(wlogout_style, [("Fira Sans Semibold", "Monofur Nerd Font")])
        restored_items.append("wlogout/style.css")

    # Kitty changes (kitty + zsh)
    kitty_src = os.path.join(src, "kitty")
    kitty_dest = os.path.join(dots, "kitty")
    if os.path.isdir(kitty_src):
        if os.path.isdir(kitty_dest):
            backed_up_items.append(backup_path(kitty_dest, backup_dir, "kitty"))
            shutil.rmtree(kitty_dest)
        shutil.copytree(kitty_src, kitty_dest, dirs_exist_ok=True)
        term_setting = os.path.join(settings_dir, "terminal.sh")
        if os.path.isfile(term_setting):
            backed_up_items.append(backup_path(term_setting, backup_dir, "terminal.sh"))
        with open(term_setting, "w", encoding="utf-8") as fh:
            fh.write("kitty\n")
        restored_items.append("kitty")

    # fastfetch, zshrc, nvim, gtk, qt6ct, ohmyposh
    for name in ["fastfetch", "zshrc", "nvim", "gtk-3.0", "gtk-4.0", "qt6ct", "ohmyposh"]:
        src_path = os.path.join(src, name)
        dest_path = os.path.join(dots, name)
        if os.path.isdir(src_path):
            if os.path.isdir(dest_path):
                backed_up_items.append(backup_path(dest_path, backup_dir, name))
                shutil.rmtree(dest_path)
            shutil.copytree(src_path, dest_path, dirs_exist_ok=True)
            restored_items.append(name)

    script_path = os.path.join(
        user_home,
        ".mydotfiles",
        "com.ml4w.dotfiles.stable",
        ".config",
        "ml4w",
        "scripts",
        "shell.sh",
    )
    if os.path.isfile(script_path):
        run(["bash", script_path], check=False)

    # Status
    status("Restore dots done.")
    status(f"Restored items: {len(restored_items)}")
    status(f"Backed up items: {len([i for i in backed_up_items if i])}")
    status(f"Target: {backup_root}")


if __name__ == "__main__":
    main()
