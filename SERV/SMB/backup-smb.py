#!/usr/bin/env python3
"""SMB backup Python script."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Sequence
from pathlib import Path

sys.path.append(str(Path(__file__).resolve().parents[2]))

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
        print("""Backup SMB
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
        print("sudo not found; cannot read required SMB files.", file=sys.stderr)
        return 1
    print("Sudo required to read SMB files. You may be prompted.")
    if subprocess.run(["sudo", "-v"], check=False).returncode != 0:
        return 1
    if compress_backup and shutil.which("pigz") is None:
        print("pigz not found; cannot create compressed archive.", file=sys.stderr)
        return 1

    # Select destination.
    destinations = list_destinations(user_name)
    selected_dest = select_destination(destinations)

    timestamp = subprocess.check_output(
        ["date", "+%j-%d-%m-%H-%M-%S"], text=True
    ).strip()
    # Per-run folder.
    dest_root = Path(selected_dest) / "SERV" / "SMB"
    run_dir = dest_root / f"SMB-{timestamp}"
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

    # Sources and manifest.
    sources = [
        Path("/etc/samba/smb.conf"),
        Path("/etc/fstab"),
        Path(f"/home/{user_name}/Code/BACKUP/SERV/SMB/restore-smb.sh"),
        Path(f"/home/{user_name}/Code/BACKUP/SERV/SMB/restore-smb.py"),
    ]
    try:
        (run_dir / "sources.txt").write_text(
            "Sources\n" + "\n".join(str(path) for path in sources) + "\n",
            encoding="utf-8",
        )
    except OSError:
        pass
    rsync_failures = 0
    for src in sources:
        if not src.exists():
            print(f"Skipping missing source: {src}")
            continue
        print(f"Copying: {src} -> {run_dir}")
        try:
            run_rsync(["sudo", *rsync_opts, str(src), f"{run_dir}/"])
            if src.name in {"restore-smb.sh", "restore-smb.py"}:
                subprocess.run(
                    ["sudo", "chmod", "755", str(run_dir / src.name)], check=False
                )
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            rsync_failures += 1

    # creds-* files from /etc/samba.
    creds_files = list(Path("/etc/samba").glob("creds-*"))
    if not creds_files:
        print("No creds-* files found under /etc/samba/")
    else:
        for src in creds_files:
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
        timestamp = subprocess.check_output(
            ["date", "+%j-%d-%m-%H-%M-%S"], text=True
        ).strip()
        archive_path = run_dir / f"SMB-{timestamp}.tar.gz"
        tar_cmd = [
            "sudo",
            "tar",
            "--use-compress-program=pigz",
            "--warning=no-file-changed",
            "--exclude",
            f"./SMB-{timestamp}.tar.gz",
            "-cpf",
            str(archive_path),
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
            try:
                subprocess.run(
                    [
                        "sudo",
                        "chown",
                        f"{user_name}:{user_name}",
                        str(archive_path),
                    ],
                    check=False,
                )
            except OSError:
                pass
            print(f"Compressed archive created: {archive_path}")
        except subprocess.CalledProcessError as exc:
            if exc.returncode == 1:
                print(
                    f"Compression completed with warnings for {run_dir} (exit {exc.returncode}).",
                    file=sys.stderr,
                )
                if exc.stderr:
                    print(f"tar: {exc.stderr.strip()}", file=sys.stderr)
            else:
                print(
                    f"Compression failed for {run_dir} (exit {exc.returncode}).",
                    file=sys.stderr,
                )
                if exc.stderr:
                    print(f"tar: {exc.stderr.strip()}", file=sys.stderr)
                tar_failed = True

    print(f"Backup completed: {run_dir}")
    print(f"Summary: rsync_failures={rsync_failures}, tar_failed={tar_failed}")
    if rsync_failures or tar_failed:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
