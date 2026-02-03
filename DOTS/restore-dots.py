#!/usr/bin/env python3
"""Dots restore Python script."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
import urllib.request
from collections.abc import Sequence
from pathlib import Path


def run_rsync(args: Sequence[str]) -> None:
    result = subprocess.run(
        args,
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.stderr:
        for line in result.stderr.splitlines():
            print(f"rsync: {line}", file=sys.stderr)
    if result.returncode in {23, 24}:
        print(
            f"rsync returned partial transfer code {result.returncode}; continuing.",
            file=sys.stderr,
        )
        return
    if result.returncode != 0:
        raise RuntimeError(f"rsync failed with code {result.returncode}")


def main() -> int:
    # Banner and CLI flags.
    user_name = os.environ.get("USER") or os.getlogin()
    show_banner = "--no-banner" not in sys.argv
    auto_yes = "--yes" in sys.argv
    if show_banner:
        print("""Restore DOTS
Options:
  --confirm   Ask before destructive restore
  --yes       Auto-confirm destructive prompt
  --no-banner Skip this prompt
""")
        input("Press Enter to continue...")
    confirm_restore = "--confirm" in sys.argv
    # Validate required tools.
    if shutil.which("rsync") is None:
        print("Missing required command: rsync", file=sys.stderr)
        return 1

    # Source is the folder containing this restore script.
    script_dir = Path(__file__).resolve().parent
    dest_dir = Path(f"/home/{user_name}/.mydotfiles/com.ml4w.dotfiles.stable/.config")
    dest_dir.mkdir(parents=True, exist_ok=True)

    # Rsync defaults for metadata-preserving restore.
    rsync_opts = [
        "rsync",
        "-aAXH",
        "--numeric-ids",
        "--sparse",
        "--delete-delay",
        "--info=stats1",
    ]

    # Create symlinks for cava and wallpapers (backup existing targets).
    backup_ts = time.strftime("%j-%d-%m-%H-%M-%S")
    config_dir = Path(f"/home/{user_name}/.config")
    cava_dir = config_dir / "cava"
    if cava_dir.exists():
        shutil.move(str(cava_dir), f"{cava_dir}.bak-{backup_ts}")
    cava_target = Path(
        f"/home/{user_name}/.mydotfiles/com.ml4w.dotfiles.stable/.config/cava"
    )
    try:
        cava_dir.symlink_to(cava_target)
    except OSError:
        pass

    ml4w_dir = Path(
        f"/home/{user_name}/.mydotfiles/com.ml4w.dotfiles.stable/.config/ml4w"
    )
    wallpapers_dir = ml4w_dir / "wallpapers"
    if wallpapers_dir.exists():
        shutil.move(str(wallpapers_dir), f"{wallpapers_dir}.bak-{backup_ts}")
    wallpapers_target = Path(f"/home/{user_name}/Pictures/wallpapers")
    try:
        wallpapers_dir.symlink_to(wallpapers_target)
    except OSError:
        pass

    # Append Hyprland environment line if missing.
    hypr_env = Path(
        f"/home/{user_name}/.mydotfiles/com.ml4w.dotfiles.stable/.config/hypr/conf/environments/nvidia.conf"
    )
    if hypr_env.is_file():
        line = "env = AQ_DRM_DEVICES,/dev/dri/card1:/dev/dri/card2"
        try:
            content = hypr_env.read_text(encoding="utf-8")
            if line not in content:
                hypr_env.write_text(f"{content.rstrip()}\n{line}\n", encoding="utf-8")
        except OSError:
            pass

    # Optional destructive confirmation.
    if confirm_restore:
        if auto_yes:
            answer = "y"
        else:
            answer = input(
                f"This restore may delete files in {dest_dir}. Continue? [y/N]: "
            ).strip()
        if answer.lower() != "y":
            print("Restore cancelled.")
            return 0

    # Groups of files to restore from the backup folder.
    groups: dict[Path, list[str]] = {
        dest_dir: ["fastfetch", "cava", "matugen", "kitty", "rofi", "zshrc"],
        dest_dir / "waybar/themes": ["waybar/themes/ralex"],
        dest_dir / "gtk-3.0": ["gtk-3.0/settings.ini", "gtk-3.0/bookmarks"],
        dest_dir / "gtk-4.0": ["gtk-4.0/settings.ini"],
        dest_dir / "qt6ct": ["qt6ct/qt6ct.conf"],
        dest_dir
        / "hypr": [
            "hypr/hyprlock.conf",
            "hypr/hypridle.conf",
            "hypr/logo-2.png",
        ],
        dest_dir / "hypr/scripts": ["hypr/scripts/uptime.sh"],
        dest_dir
        / "hypr/conf": [
            "hypr/conf/animation.conf",
            "hypr/conf/cursor.conf",
            "hypr/conf/decoration.conf",
            "hypr/conf/environment.conf",
            "hypr/conf/keybinding.conf",
            "hypr/conf/layout.conf",
            "hypr/conf/monitor.conf",
            "hypr/conf/window.conf",
        ],
        dest_dir / "hypr/conf/keybindings": ["hypr/conf/keybindings/lateralus.conf"],
        dest_dir
        / "ml4w/settings": [
            "ml4w/settings/editor.sh",
            "ml4w/settings/filemanager",
            "ml4w/settings/filemanager.sh",
            "ml4w/settings/rofi-border-radius.rasi",
            "ml4w/settings/rofi-border.rasi",
            "ml4w/settings/rofi-font.rasi",
            "ml4w/settings/rofi_bordersize.sh",
            "ml4w/settings/screenshot-editor",
            "ml4w/settings/screenshot-folder",
            "ml4w/settings/terminal.sh",
            "ml4w/settings/wallpaper-folder",
            "ml4w/settings/waybar-theme.sh",
        ],
        dest_dir / "wlogout/themes/glass": ["wlogout/themes/glass/style.css"],
        Path(f"/home/{user_name}/.config/com.ml4w.hyprlandsettings"): ["hyprctl.json"],
    }

    # Restore each group and track soft failures.
    rsync_failures = 0
    for dest, items in groups.items():
        dest.mkdir(parents=True, exist_ok=True)
        sources: list[str] = []
        for item in items:
            src = script_dir / item
            if src.exists():
                sources.append(str(src))
            else:
                print(f"Skipping missing source: {src}")
        if not sources:
            continue
        print(f"Restoring: {', '.join(sources)} -> {dest}")
        try:
            run_rsync([*rsync_opts, *sources, f"{dest}/"])
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            rsync_failures += 1

    print(f"Restore completed from: {script_dir}")
    print(f"Summary: rsync_failures={rsync_failures}")
    return 1 if rsync_failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
