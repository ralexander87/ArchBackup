#!/usr/bin/env python3
"""GRUB restore Python script."""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path


def main() -> int:
    # Banner and flags.
    show_banner = "--no-banner" not in sys.argv
    confirm_restore = "--confirm" in sys.argv
    auto_yes = "--yes" in sys.argv
    if show_banner:
        print("""Restore GRUB
Options:
  --confirm    Ask before destructive restore
  --yes        Auto-confirm destructive prompt
  --no-banner  Skip this prompt
""")
        input("Press Enter to continue...")

    # Confirm destructive restore if requested.
    if confirm_restore:
        if auto_yes:
            answer = "y"
        else:
            answer = input(
                "This restore will modify system files. Continue? [y/N]: "
            ).strip()
        if answer.lower() != "y":
            print("Restore cancelled.")
            return 0

    # Restore theme and update /etc/default/grub.
    src = Path(__file__).resolve().parent / "lateralus"
    dest = Path("/boot/grub/themes")
    if not dest.is_dir():
        print("Destination not found: /boot/grub/themes", file=sys.stderr)
        return 1
    if not src.is_dir():
        print(f"Source not found: {src}", file=sys.stderr)
        return 1

    # Require sudo.
    if shutil.which("sudo") is None:
        print("sudo not found; cannot restore GRUB files.", file=sys.stderr)
        return 1
    print("Sudo required to restore GRUB files. You may be prompted.")
    if subprocess.run(["sudo", "-v"], check=False).returncode != 0:
        return 1

    print(f"Restoring: {src} -> {dest}")
    result = subprocess.run(
        [
            "sudo",
            "rsync",
            "-aHAX",
            "--numeric-ids",
            "--info=stats1",
            "--sparse",
            str(src),
            f"{dest}/",
        ],
        check=False,
    )
    if result.returncode in {23, 24}:
        return 0
    if result.returncode != 0:
        return result.returncode

    grub_conf = Path("/etc/default/grub")
    if grub_conf.is_file():
        backup_path = Path(__file__).resolve().parent / "grub.backup"
        subprocess.run(["sudo", "cp", str(grub_conf), str(backup_path)], check=False)
        cmdline = (
            's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 '
            'quiet splash"/'
        )
        subprocess.run(["sudo", "sed", "-i", cmdline, str(grub_conf)], check=False)
        subprocess.run(
            [
                "sudo",
                "sed",
                "-i",
                "s/^#GRUB_GFXMODE=.*/GRUB_GFXMODE=1440x1080x32/",
                str(grub_conf),
            ],
            check=False,
        )
        subprocess.run(
            [
                "sudo",
                "sed",
                "-i",
                's|^#GRUB_THEME=.*|GRUB_THEME="/boot/grub/themes/lateralus/theme.txt"|',
                str(grub_conf),
            ],
            check=False,
        )
        subprocess.run(
            [
                "sudo",
                "sed",
                "-i",
                "s/^#GRUB_TERMINAL_OUTPUT=.*/GRUB_TERMINAL_OUTPUT=gfxterm/",
                str(grub_conf),
            ],
            check=False,
        )
        subprocess.run(
            [
                "sudo",
                "sed",
                "-i",
                "s/^GRUB_TERMINAL_INPUT=console/#GRUB_TERMINAL_INPUT=console/",
                str(grub_conf),
            ],
            check=False,
        )
        subprocess.run(
            ["sudo", "grub-mkconfig", "-o", "/boot/grub/grub.cfg"],
            check=False,
        )
    else:
        print("File not found: /etc/default/grub", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
