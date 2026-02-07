#!/usr/bin/env python3
"""GRUB backup Python script."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Sequence
from pathlib import Path

sys.path.append(str(Path(__file__).resolve().parents[2] / "scripts"))

from common import check_free_space, list_destinations, select_destination


def run_rsync(args: Sequence[str]) -> None:
    """Run rsync and normalize partial transfer codes."""
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
    # Banner and flags.
    user_name = os.environ.get("USER") or os.getlogin()
    show_banner = "--no-banner" not in sys.argv
    auto_yes = "--yes" in sys.argv
    if show_banner:
        print("""Backup GRUB
Options:
  --no-banner  Skip this prompt
  --yes        Auto-confirm prompts
""")
        input("Press Enter to continue...")

    # Compression choice.
    if auto_yes:
        compress_backup = True
    else:
        compress_reply = (
            input("Create compressed archive with pigz? [Y/n]: ").strip() or "Y"
        )
        compress_backup = compress_reply.lower() != "n"

    # Validate required tools and sudo.
    if shutil.which("rsync") is None:
        print("Missing required command: rsync", file=sys.stderr)
        return 1
    if shutil.which("sudo") is None:
        print("sudo not found; cannot read required GRUB files.", file=sys.stderr)
        return 1
    print("Sudo required to read GRUB files. You may be prompted.")
    if subprocess.run(["sudo", "-v"], check=False).returncode != 0:
        return 1
    if compress_backup and shutil.which("pigz") is None:
        print("pigz not found; cannot create compressed archive.", file=sys.stderr)
        return 1

    # Select destination.
    destinations = list_destinations(user_name)
    selected_dest = select_destination(destinations)

    # Per-run folder.
    timestamp = subprocess.check_output(
        ["date", "+%j-%d-%m-%H-%M-%S"], text=True
    ).strip()
    dest_root = Path(selected_dest) / "SERV" / "GRUB"
    run_dir = dest_root / f"GRUB-{timestamp}"
    run_dir.mkdir(parents=True, exist_ok=True)

    check_free_space(selected_dest, min_gb=20)

    # Rsync defaults.
    rsync_opts = [
        "rsync",
        "-aHAX",
        "--numeric-ids",
        "--info=stats1",
        "--sparse",
    ]

    # Sources list.
    sources = [
        Path("/boot/grub/themes/lateralus"),
        Path("/etc/default/grub"),
        Path(f"/home/{user_name}/Code/BACKUP/SERV/GRUB/restore-grub.sh"),
        Path(f"/home/{user_name}/Code/BACKUP/SERV/GRUB/restore-grub.py"),
    ]

    rsync_failures = 0
    for src in sources:
        if not src.exists():
            print(f"Skipping missing source: {src}")
            continue
            print(f"Copying: {src} -> {run_dir}")
            try:
                run_rsync(["sudo", *rsync_opts, str(src), f"{run_dir}/"])
            except RuntimeError as exc:
                print(str(exc), file=sys.stderr)
                rsync_failures += 1

    # Optional compression.
    tar_failed = False
    if compress_backup:
        archive_path = run_dir / f"GRUB-{timestamp}.tar.gz"
        tmp_handle = tempfile.NamedTemporaryFile(delete=False, suffix=".tar.gz")
        tmp_handle.close()
        tar_cmd = [
            "tar",
            "--use-compress-program=pigz",
            "-cpf",
            tmp_handle.name,
            "-C",
            str(run_dir),
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
                f"Compression failed for {run_dir} (exit {exc.returncode}).",
                file=sys.stderr,
            )
            if exc.stderr:
                print(f"tar: {exc.stderr.strip()}", file=sys.stderr)
            tar_failed = True
            try:
                Path(tmp_handle.name).unlink(missing_ok=True)
            except OSError:
                pass

    print(f"Backup completed: {run_dir}")
    print(f"Summary: rsync_failures={rsync_failures}, tar_failed={tar_failed}")
    if rsync_failures or tar_failed:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
