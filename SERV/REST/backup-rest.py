#!/usr/bin/env python3
"""REST backup Python script."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
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
    user_name = os.environ.get("USER") or os.getlogin()
    show_banner = "--no-banner" not in sys.argv
    auto_yes = "--yes" in sys.argv
    if show_banner:
        print("""Backup REST
Options:
  --no-banner  Skip this prompt
  --yes        Auto-confirm prompts
""")
        input("Press Enter to continue...")

    if auto_yes:
        compress_backup = True
    else:
        compress_reply = (
            input("Create compressed archive with pigz? [Y/n]: ").strip() or "Y"
        )
        compress_backup = compress_reply.lower() != "n"

    if shutil.which("rsync") is None:
        print("Missing required command: rsync", file=sys.stderr)
        return 1
    if shutil.which("sudo") is None:
        print("sudo not found; cannot read required REST files.", file=sys.stderr)
        return 1
    print("Sudo required to read REST files. You may be prompted.")
    if subprocess.run(["sudo", "-v"], check=False).returncode != 0:
        return 1
    if compress_backup and shutil.which("pigz") is None:
        print("pigz not found; cannot create compressed archive.", file=sys.stderr)
        return 1

    destinations = list_destinations(user_name)
    selected_dest = select_destination(destinations)

    timestamp = subprocess.check_output(
        ["date", "+%j-%d-%m-%H-%M-%S"], text=True
    ).strip()
    dest_root = Path(selected_dest) / "SERV" / "REST"
    run_dir = dest_root / f"REST-{timestamp}"
    run_dir.mkdir(parents=True, exist_ok=True)

    check_free_space(selected_dest, min_gb=5)

    rsync_opts = [
        "rsync",
        "-aHAX",
        "--numeric-ids",
        "--info=stats1",
        "--sparse",
    ]

    sources = [
        Path("/etc/mkinitcpio.conf"),
        Path("/usr/share/plymouth/plymouthd.defaults"),
        Path("/usr/lib/sddm/sddm.conf.d/default.conf"),
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
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            rsync_failures += 1

    # LUKS header backup (NVMe partitions).
    if shutil.which("cryptsetup") is None:
        print("cryptsetup not found; skipping LUKS header backup.")
    else:
        luks_found = False
        for dev in Path("/dev").glob("nvme*n*p*"):
            if subprocess.run(
                ["sudo", "cryptsetup", "isLuks", str(dev)],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ).returncode == 0:
                luks_found = True
                header_path = run_dir / f"luks-header-{dev.name}.bin"
                print(f"Backing up LUKS header: {dev} -> {header_path}")
                result = subprocess.run(
                    [
                        "sudo",
                        "cryptsetup",
                        "luksHeaderBackup",
                        str(dev),
                        "--header-backup-file",
                        str(header_path),
                    ],
                    check=False,
                )
                if result.returncode == 0:
                    subprocess.run(
                        ["sudo", "chown", f"{user_name}:{user_name}", str(header_path)],
                        check=False,
                    )
                else:
                    print(
                        f"Warning: failed to back up LUKS header for {dev}",
                        file=sys.stderr,
                    )
        if not luks_found:
            print("No LUKS headers found on /dev/nvme* partitions.")

    tar_failed = False
    if compress_backup:
        archive_path = run_dir / f"REST-{timestamp}.tar.gz"
        tar_cmd = [
            "sudo",
            "tar",
            "--use-compress-program=pigz",
            "--warning=no-file-changed",
            "--exclude",
            f"./REST-{timestamp}.tar.gz",
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
                    "Compression completed with warnings for "
                    f"{run_dir} (exit {exc.returncode}).",
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
