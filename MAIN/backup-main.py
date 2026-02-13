#!/usr/bin/env python3
"""Main backup Python script."""

from __future__ import annotations

import logging
import os
import shutil
import signal
import subprocess
import sys
from collections.abc import Sequence
from pathlib import Path

sys.path.append(str(Path(__file__).resolve().parents[1] / "scripts"))

from common import (
    check_free_space,
    list_destinations,
    select_destination,
    write_manifest,
)


def run_rsync(args: Sequence[str], logger: logging.Logger) -> None:
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
            logger.error("rsync: %s", line)
    if result.returncode in {23, 24}:
        logger.warning(
            "rsync returned partial transfer code %s; continuing.", result.returncode
        )
        return
    if result.returncode != 0:
        raise RuntimeError(f"rsync failed with code {result.returncode}")


def setup_logging(log_path: Path) -> logging.Logger:
    """Log to file and stdout."""
    logger = logging.getLogger("backup-main")
    logger.setLevel(logging.INFO)
    formatter = logging.Formatter("%(asctime)s %(levelname)s %(message)s")

    file_handler = logging.FileHandler(log_path, encoding="utf-8")
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)

    stream_handler = logging.StreamHandler(sys.stdout)
    stream_handler.setFormatter(formatter)
    logger.addHandler(stream_handler)

    return logger


def trim_log(
    log_path: Path, max_bytes: int = 5 * 1024 * 1024, max_lines: int = 5000
) -> None:
    """Trim log file size."""
    try:
        if log_path.stat().st_size <= max_bytes:
            return
        with log_path.open("r", encoding="utf-8", errors="ignore") as handle:
            lines = handle.readlines()[-max_lines:]
        with log_path.open("w", encoding="utf-8") as handle:
            handle.writelines(lines)
    except OSError:
        pass


def main() -> int:
    # Banner and flags.
    user_name = os.environ.get("USER") or os.getlogin()
    show_banner = "--no-banner" not in sys.argv
    auto_yes = "--yes" in sys.argv
    if show_banner:
        print("""Backup MAIN
Options:
  --no-compress     Skip compression prompt
  --log-dir <dir>   Write logs to a custom directory
  --manifest-only   Write manifests and exit
  --no-banner       Skip this prompt
  --yes             Auto-confirm prompts
""")
        input("Press Enter to continue...")
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
    main_dir = selected_dest / "MAIN"
    backup_dir = main_dir / f"BKP-{timestamp}"
    backup_dir.mkdir(parents=True, exist_ok=True)

    # Logging location.
    if log_dir:
        log_path = Path(log_dir) / f"BKP-{timestamp}.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
    else:
        log_path = backup_dir / f"BKP-{timestamp}.log"
    logger = setup_logging(log_path)

    def handle_signal(signum: int, _frame: object) -> None:
        logger.warning("Interrupted by signal %s; exiting.", signum)
        trim_log(log_path)
        raise SystemExit(130)

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    # Ensure free space.
    check_free_space(selected_dest, min_gb=20)

    rsync_opts = [
        "rsync",
        "-aAXH",
        "--numeric-ids",
        "--sparse",
        "--info=stats1",
    ]

    # Global excludes and sources list.
    common_excludes = [
        "--exclude",
        ".cache/",
        "--exclude",
        ".var/app/",
        "--exclude",
        ".subversion/",
        "--exclude",
        ".mozilla/",
        "--exclude",
        ".local/share/fonts/",
        "--exclude",
        ".local/share/fonts/NerdFonts/",
        "--exclude",
        ".vscode-oss/",
        "--exclude",
        "Trash/",
        "--exclude",
        ".config/*/Cache/",
        "--exclude",
        ".config/*/cache/",
        "--exclude",
        ".config/*/Code Cache/",
        "--exclude",
        ".config/*/GPUCache/",
        "--exclude",
        ".config/*/CachedData/",
        "--exclude",
        ".config/*/CacheStorage/",
        "--exclude",
        ".config/*/Service Worker/",
        "--exclude",
        ".config/*/IndexedDB/",
        "--exclude",
        ".config/*/Local Storage/",
        "--exclude",
        ".config/rambox/",
        "--exclude",
        ".rustup/",
    ]

    sources = [
        Path(f"/home/{user_name}/Documents"),
        Path(f"/home/{user_name}/Downloads"),
        Path(f"/home/{user_name}/Pictures"),
        Path(f"/home/{user_name}/Obsidian"),
        Path(f"/home/{user_name}/Working"),
        Path(f"/home/{user_name}/Shared"),
        Path(f"/home/{user_name}/VM"),
        Path(f"/home/{user_name}/Code"),
        Path(f"/home/{user_name}/Videos"),
        Path(f"/home/{user_name}/.config"),
        Path(f"/home/{user_name}/.var"),
        Path(f"/home/{user_name}/.ssh"),
        Path(f"/home/{user_name}/.icons"),
        Path(f"/home/{user_name}/.themes"),
        Path(f"/home/{user_name}/.mydotfiles"),
        Path(f"/home/{user_name}/.local"),
        Path(f"/home/{user_name}/.oh-my-zsh"),
        Path(f"/home/{user_name}/Code/BACKUP/MAIN/restore-main.sh"),
        Path(f"/home/{user_name}/Code/BACKUP/MAIN/restore-main.py"),
    ]

    # Write manifests for traceability.
    write_manifest(
        backup_dir / "sources.txt",
        "Sources",
        [str(path) for path in sources],
    )
    write_manifest(
        backup_dir / "excludes.txt",
        "Excludes",
        [common_excludes[i + 1] for i in range(0, len(common_excludes), 2)],
    )

    # Skip copy/compress when manifest-only.
    if manifest_only:
        logger.info("Manifest-only mode: skipping file copy and compression.")
        return 0

    rsync_failures = 0
    sources_total = 0
    sources_skipped = 0
    for src in sources:
        if not src.exists():
            logger.info("Skipping missing source: %s", src)
            sources_skipped += 1
            continue
        sources_total += 1
        extra_excludes: list[str] = []
        if src.name == "VM":
            extra_excludes += ["--exclude", "ISO/"]
        if src.name == "Downloads":
            extra_excludes += ["--exclude", "*.iso"]
        if src.name == ".ssh":
            extra_excludes += ["--exclude", "agent/"]
        logger.info("Copying: %s -> %s", src, backup_dir)
        try:
            run_rsync(
                [
                    *rsync_opts,
                    *common_excludes,
                    *extra_excludes,
                    str(src),
                    f"{backup_dir}/",
                ],
                logger,
            )
        except RuntimeError as exc:
            logger.error("%s", exc)
            rsync_failures += 1

    # Optional compression inside run directory.
    tar_failed = False
    if compress_backup:
        archive_path = backup_dir / f"BKP-{timestamp}.tar.gz"
        # Write archive directly into backup_dir to avoid filling /tmp on large backups.
        tar_cmd = [
            "tar",
            "--use-compress-program=pigz",
            "--warning=no-file-changed",
            "--exclude",
            f"./BKP-{timestamp}.tar.gz",
            "--exclude",
            f"./BKP-{timestamp}.log",
            "-cpf",
            str(archive_path),
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
                logger.error("tar: %s", result.stderr.strip())
            logger.info("Compressed archive created: %s", archive_path)
        except subprocess.CalledProcessError as exc:
            if exc.returncode == 1:
                logger.warning(
                    "Compression completed with warnings for %s (exit %s).",
                    backup_dir,
                    exc.returncode,
                )
                if exc.stderr:
                    logger.error("tar: %s", exc.stderr.strip())
            else:
                logger.error(
                    "Compression failed for %s (exit %s).", backup_dir, exc.returncode
                )
                if exc.stderr:
                    logger.error("tar: %s", exc.stderr.strip())
                tar_failed = True

    logger.info("Backup completed: %s", backup_dir)
    logger.info(
        "Summary: sources=%s, skipped=%s, rsync_failures=%s, tar_failed=%s",
        sources_total,
        sources_skipped,
        rsync_failures,
        tar_failed,
    )
    trim_log(log_path)
    if rsync_failures or tar_failed:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
