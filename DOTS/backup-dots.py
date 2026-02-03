#!/usr/bin/env python3
"""Dots backup Python script."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Sequence
from pathlib import Path

sys.path.append(str(Path(__file__).resolve().parents[1]))

from common import (
    check_free_space,
    list_destinations,
    select_destination,
    write_manifest,
)


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
        print("""Backup DOTS
Options:
  --no-compress     Skip compression prompt
  --log-dir <dir>   Write logs to a custom directory
  --manifest-only   Write manifests and exit
  --no-banner       Skip this prompt
  --yes             Auto-confirm prompts
""")
        input("Press Enter to continue...")
    # Parse simple flags.
    log_dir = ""
    manifest_only = False
    compress_override: bool | None = None
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--log-dir" and i + 1 < len(args):
            log_dir = args[i + 1]
            i += 2
            continue
        if args[i] == "--no-compress":
            compress_override = False
            i += 1
            continue
        if args[i] == "--manifest-only":
            manifest_only = True
            i += 1
            continue
        i += 1

    # Decide whether to compress the archive.
    if auto_yes:
        compress_backup = True
    elif compress_override is False:
        compress_backup = False
    else:
        compress_reply = (
            input("Create compressed archive with pigz? [Y/n]: ").strip() or "Y"
        )
        compress_backup = compress_reply.lower() != "n"
    # Validate required tools.
    if shutil.which("rsync") is None:
        print("Missing required command: rsync", file=sys.stderr)
        return 1
    if compress_backup and shutil.which("pigz") is None:
        print("pigz not found; cannot create compressed archive.", file=sys.stderr)
        return 1

    # Select destination mount.
    destinations = list_destinations(user_name)
    selected_dest = select_destination(destinations)

    # Create per-run backup directory.
    timestamp = subprocess.check_output(
        ["date", "+%j-%d-%m-%H-%M-%S"], text=True
    ).strip()
    dots_dir = selected_dest / "DOTS"
    backup_dir = dots_dir / f"DOTS-{timestamp}"
    backup_dir.mkdir(parents=True, exist_ok=True)

    # Ensure there is enough space.
    check_free_space(selected_dest, min_gb=20)

    # Rsync defaults for metadata preservation.
    rsync_opts = [
        "rsync",
        "-aAXH",
        "--numeric-ids",
        "--sparse",
        "--info=stats1",
    ]

    rsync_failures = 0

    # Sources to back up.
    source_root = Path(
        f"/home/{user_name}/.mydotfiles/com.ml4w.dotfiles.stable/.config"
    )
    restore_scripts = [
        Path(f"/home/{user_name}/Code/BACKUP/DOTS/restore-dots.sh"),
        Path(f"/home/{user_name}/Code/BACKUP/DOTS/restore-dots.py"),
    ]
    sources_manifest = [
        str(source_root),
        f"/home/{user_name}/.config/com.ml4w.hyprlandsettings/hyprctl.json",
        *[str(path) for path in restore_scripts],
    ]
    write_manifest(backup_dir / "sources.txt", "Sources", sources_manifest)

    # Optional log redirection.
    if log_dir:
        log_path = Path(log_dir) / f"DOTS-{timestamp}.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_handle = log_path.open("a", encoding="utf-8")
        sys.stdout = log_handle
        sys.stderr = log_handle

    # Stop early if only manifests are requested.
    if manifest_only:
        print("Manifest-only mode: skipping file copy and compression.")
        return 0
    # Copy the dotfiles config tree.
    if source_root.is_dir():
        print(f"Copying: {source_root} -> {backup_dir}")
        try:
            run_rsync([*rsync_opts, f"{source_root}/", f"{backup_dir}/"])
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            rsync_failures += 1
    else:
        print(f"Source folder not found: {source_root}", file=sys.stderr)
        rsync_failures += 1

    # Copy hyprctl settings file.
    hyprctl_json = Path(
        f"/home/{user_name}/.config/com.ml4w.hyprlandsettings/hyprctl.json"
    )
    if hyprctl_json.is_file():
        print(f"Copying: {hyprctl_json} -> {backup_dir}")
        try:
            run_rsync([*rsync_opts, str(hyprctl_json), f"{backup_dir}/"])
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            rsync_failures += 1
    else:
        print(f"Source file not found: {hyprctl_json}", file=sys.stderr)
        rsync_failures += 1

    # Copy restore scripts alongside the backup.
    for restore_script in restore_scripts:
        if restore_script.is_file():
            print(f"Copying: {restore_script} -> {backup_dir}")
            try:
                run_rsync([*rsync_opts, str(restore_script), f"{backup_dir}/"])
            except RuntimeError as exc:
                print(str(exc), file=sys.stderr)
                rsync_failures += 1
        else:
            print(f"Restore script not found: {restore_script}", file=sys.stderr)
            rsync_failures += 1

    # Optional compression.
    tar_failed = False
    if compress_backup:
        archive_path = backup_dir / f"DOTS-{timestamp}.tar.gz"
        tmp_handle = tempfile.NamedTemporaryFile(delete=False, suffix=".tar.gz")
        tmp_handle.close()
        tar_cmd = [
            "tar",
            "--use-compress-program=pigz",
            "-cpf",
            tmp_handle.name,
            "-C",
            str(backup_dir),
            ".",
        ]
        try:
            result = subprocess.run(
                tar_cmd,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
            if result.stderr:
                print(f"tar: {result.stderr.strip()}", file=sys.stderr)
            shutil.move(tmp_handle.name, archive_path)
            print(f"Compressed archive created: {archive_path}")
        except subprocess.CalledProcessError as exc:
            print(
                f"Compression failed for {backup_dir} (exit {exc.returncode}).",
                file=sys.stderr,
            )
            if exc.stderr:
                print(f"tar: {exc.stderr.strip()}", file=sys.stderr)
            tar_failed = True
            try:
                Path(tmp_handle.name).unlink(missing_ok=True)
            except OSError:
                pass

    print(f"Backup destination ready: {backup_dir}")
    print(f"Summary: rsync_failures={rsync_failures}, tar_failed={tar_failed}")
    if rsync_failures or tar_failed:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
