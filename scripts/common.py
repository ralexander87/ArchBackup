"""Shared helpers for backup scripts."""

from __future__ import annotations

import sys
from collections.abc import Iterable
from pathlib import Path


def read_mount_fstypes() -> dict[str, str]:
    """Return mountpoint -> fstype mapping from /proc/mounts."""
    mounts: dict[str, str] = {}
    try:
        with open("/proc/mounts", encoding="utf-8") as handle:
            for line in handle:
                parts = line.split()
                if len(parts) >= 3:
                    mounts[parts[1]] = parts[2]
    except OSError:
        pass
    return mounts


def is_safe_mount(path: Path, mount_fstypes: dict[str, str]) -> bool:
    """Exclude pseudo/unsafe mount types."""
    if not path.is_mount():
        return False
    fstype = mount_fstypes.get(str(path))
    if fstype in {
        "tmpfs",
        "overlay",
        "squashfs",
        "nsfs",
        "proc",
        "sysfs",
        "devtmpfs",
        "ramfs",
        "autofs",
    }:
        return False
    return True


def list_destinations(user_name: str) -> list[Path]:
    """List external mount directories under /run/media or /media."""
    roots = [Path("/run/media") / user_name, Path("/media") / user_name]
    mount_fstypes = read_mount_fstypes()
    destinations: list[Path] = []
    for root in roots:
        if root.is_dir():
            for entry in root.iterdir():
                if entry.is_dir() and is_safe_mount(entry, mount_fstypes):
                    destinations.append(entry)
    return destinations


def select_destination(destinations: list[Path]) -> Path:
    """Prompt user to select a destination (auto if only one)."""
    if not destinations:
        print(
            "No external mounted devices found under /run/media or /media.",
            file=sys.stderr,
        )
        raise SystemExit(1)

    print("Mounted destinations:")
    for i, dest in enumerate(destinations, start=1):
        print(f"  [{i}] {dest}")

    if len(destinations) == 1:
        selected = destinations[0]
        print(f"Using the only available destination: {selected}")
        return selected

    choice = input("Select destination number: ").strip()
    if not choice.isdigit():
        print("Invalid selection.", file=sys.stderr)
        raise SystemExit(1)
    index = int(choice)
    if index < 1 or index > len(destinations):
        print("Invalid selection.", file=sys.stderr)
        raise SystemExit(1)
    selected = destinations[index - 1]
    input(f"Confirm destination ({selected}) and press Enter to continue...")
    return selected


def check_free_space(path: Path, min_gb: int = 20) -> None:
    """Exit if destination free space is below min_gb."""
    import shutil

    usage = shutil.disk_usage(path)
    avail_gb = usage.free // (1024**3)
    if avail_gb < min_gb:
        message = (
            f"Insufficient free space on destination ({avail_gb}G available, "
            f"need >= {min_gb}G)."
        )
        print(message, file=sys.stderr)
        raise SystemExit(1)


def write_manifest(path: Path, title: str, items: Iterable[str]) -> None:
    """Write a simple manifest file with a header and items."""
    try:
        with path.open("w", encoding="utf-8") as handle:
            handle.write(f"{title}\n")
            for item in items:
                handle.write(f"{item}\n")
    except OSError:
        pass
