#!/usr/bin/env python3
"""SSH backup Python script."""

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


def run_rsync_sudo(args: Sequence[str]) -> None:
    """Run rsync via sudo and normalize partial transfer codes."""
    result = subprocess.run(
        ["sudo", *args],
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


def ensure_sudo() -> bool:
    if shutil.which("sudo") is None:
        print("sudo not found; cannot read /etc/ssh/sshd_config.", file=sys.stderr)
        return False
    return subprocess.run(["sudo", "-v"], check=False).returncode == 0


def main() -> int:
    # Banner and flags.
    user_name = os.environ.get("USER") or os.getlogin()
    show_banner = "--no-banner" not in sys.argv
    auto_yes = "--yes" in sys.argv
    if show_banner:
        print("""Backup SSH
Options:
  --no-compress     Skip compression prompt
  --log-dir <dir>   Write logs to a custom directory
  --manifest-only   Write manifests and exit
  --keep <count>    Keep last N backups (default: 5)
  --no-banner       Skip this prompt
  --yes             Auto-confirm prompts
""")
        input("Press Enter to continue...")

    # Parse simple flags.
    log_dir = ""
    manifest_only = False
    compress_override: bool | None = None
    keep_count = 5
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
        if args[i] == "--keep" and i + 1 < len(args):
            try:
                keep_count = int(args[i + 1])
            except ValueError:
                keep_count = 5
            i += 2
            continue
        i += 1

    # Compression choice.
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

    # Select destination.
    destinations = list_destinations(user_name)
    selected_dest = select_destination(destinations)

    timestamp = subprocess.check_output(
        ["date", "+%j-%d-%m-%H-%M-%S"], text=True
    ).strip()
    dest_root = selected_dest / "SERV" / "SSH"
    run_dir = dest_root / f"SSH-{timestamp}"
    run_dir.mkdir(parents=True, exist_ok=True)

    # Optional log redirection.
    if log_dir:
        log_path = Path(log_dir) / f"SSH-{timestamp}.log"
    else:
        log_path = run_dir / f"SSH-{timestamp}.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_handle = log_path.open("a", encoding="utf-8")
    sys.stdout = log_handle
    sys.stderr = log_handle

    # Ensure there is enough space.
    check_free_space(selected_dest, min_gb=20)

    # Rsync defaults.
    rsync_opts = [
        "rsync",
        "-aHAX",
        "--numeric-ids",
        "--info=stats1",
        "--sparse",
    ]

    rsync_failures = 0

    # Sources and manifest.
    ssh_dir = Path(f"/home/{user_name}/.ssh")
    sshd_config = Path("/etc/ssh/sshd_config")
    restore_scripts = [
        Path(f"/home/{user_name}/Code/BACKUP/SERV/SSH/restore-ssh.sh"),
        Path(f"/home/{user_name}/Code/BACKUP/SERV/SSH/restore-ssh.py"),
    ]
    sources = [str(ssh_dir), str(sshd_config), *[str(path) for path in restore_scripts]]
    excludes = [f"{ssh_dir}/agent"]
    try:
        (run_dir / "sources.txt").write_text(
            "Sources\n"
            + "\n".join(sources)
            + "\n\nExcludes\n"
            + "\n".join(excludes)
            + "\n",
            encoding="utf-8",
        )
    except OSError:
        pass

    if manifest_only:
        print("Manifest-only mode: skipping file copy and compression.")
        return 0

    # Backup ~/.ssh (exclude agent socket).
    if ssh_dir.is_dir():
        print(f"Copying: {ssh_dir} -> {run_dir}")
        try:
            run_rsync(
                [
                    *rsync_opts,
                    "--exclude",
                    "agent",
                    "--exclude",
                    "agent/",
                    "--exclude",
                    "/agent",
                    str(ssh_dir),
                    f"{run_dir}/",
                ]
            )
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            rsync_failures += 1
    else:
        print(f"Source folder not found: {ssh_dir}", file=sys.stderr)
        rsync_failures += 1

    # Backup sshd_config and restore scripts.
    for src in [sshd_config, *restore_scripts]:
        if src.is_file():
            print(f"Copying: {src} -> {run_dir}")
            try:
                if src == sshd_config:
                    if ensure_sudo():
                        run_rsync_sudo([*rsync_opts, str(src), f"{run_dir}/"])
                        try:
                            subprocess.run(
                                [
                                    "sudo",
                                    "chown",
                                    f"{user_name}:{user_name}",
                                    str(run_dir / "sshd_config"),
                                ],
                                check=False,
                            )
                            subprocess.run(
                                ["sudo", "chmod", "644", str(run_dir / "sshd_config")],
                                check=False,
                            )
                        except OSError:
                            pass
                    else:
                        rsync_failures += 1
                        continue
                else:
                    run_rsync([*rsync_opts, str(src), f"{run_dir}/"])
                if src.name in {"restore-ssh.sh", "restore-ssh.py"}:
                    try:
                        (run_dir / src.name).chmod(0o755)
                    except OSError:
                        pass
            except RuntimeError as exc:
                print(str(exc), file=sys.stderr)
                rsync_failures += 1
        else:
            print(f"Source file not found: {src}", file=sys.stderr)
            rsync_failures += 1

    # Ensure agent socket directory is not present in the backup.
    agent_path = run_dir / ".ssh" / "agent"
    if agent_path.is_dir():
        shutil.rmtree(agent_path, ignore_errors=True)

    # Optional compression.
    tar_failed = False
    if compress_backup:
        archive_path = run_dir / f"SSH-{timestamp}.tar.gz"
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

    def rotate_backups(root: Path, keep: int) -> None:
        if keep < 0:
            return
        backups = sorted(
            [path for path in root.glob("SSH-*") if path.is_dir()],
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        for old in backups[keep:]:
            try:
                shutil.rmtree(old)
            except OSError:
                pass

    print(f"Backup completed: {run_dir}")
    print(f"Summary: rsync_failures={rsync_failures}, tar_failed={tar_failed}")
    if rsync_failures or tar_failed:
        return 1
    rotate_backups(dest_root, keep_count)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
