#!/usr/bin/env python3
"""Notify on repo changes and optionally run checks/commit."""

from __future__ import annotations

import argparse
import datetime as dt
import os
import subprocess
import time
from pathlib import Path


def run(cmd: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=check, text=True)


def repo_root() -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    return Path(result.stdout.strip())


def list_tracked_files() -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files"],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    return [Path(line) for line in result.stdout.splitlines() if line.strip()]


def list_status_files() -> list[Path]:
    result = subprocess.run(
        ["git", "status", "--porcelain"],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    files: list[Path] = []
    for line in result.stdout.splitlines():
        if not line:
            continue
        path = line[3:]
        if path:
            files.append(Path(path))
    return files


def snapshot(paths: list[Path]) -> dict[Path, tuple[float, int]]:
    data: dict[Path, tuple[float, int]] = {}
    for path in paths:
        try:
            stat = path.stat()
        except FileNotFoundError:
            continue
        data[path] = (stat.st_mtime, stat.st_size)
    return data


def is_clean() -> bool:
    result = subprocess.run(
        ["git", "status", "--porcelain"],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    return not result.stdout.strip()


def pick_tool(path: str) -> str:
    tool_path = Path(".venv") / "bin" / path
    if tool_path.is_file():
        return str(tool_path)
    return path


def run_formatting(py_files: list[str]) -> bool:
    ruff = pick_tool("ruff")
    black = pick_tool("black")
    try:
        run([ruff, "check", "--fix", *py_files], check=True)
        run([black, *py_files], check=True)
    except subprocess.CalledProcessError:
        return False
    return True


def run_quality_checks(py_files: list[str]) -> bool:
    ruff = pick_tool("ruff")
    black = pick_tool("black")
    try:
        run([ruff, "check", *py_files], check=True)
        run([black, "--check", *py_files], check=True)
    except subprocess.CalledProcessError:
        return False
    return True


def prompt_yes_no(prompt: str) -> bool:
    try:
        answer = input(prompt).strip().lower()
    except EOFError:
        return False
    return answer in {"y", "yes"}


def handle_changes(message: str, quiet_seconds: float) -> None:
    root = repo_root()
    os.chdir(root)

    while True:
        if is_clean():
            time.sleep(0.5)
            continue

        dirty_files = list_status_files()
        tracked_files = list_tracked_files()
        watch_files = {*(tracked_files), *(dirty_files)}
        watch_list = [root / path for path in watch_files]

        stable_since = None
        prev = snapshot(watch_list)
        while True:
            time.sleep(0.5)
            curr = snapshot(watch_list)
            if curr != prev:
                stable_since = None
                prev = curr
                continue
            if stable_since is None:
                stable_since = time.monotonic()
            if time.monotonic() - stable_since >= quiet_seconds:
                break

        py_files = [str(path) for path in list_tracked_files() if path.suffix == ".py"]
        print("Detected repo changes.")
        if not prompt_yes_no("Run format/lint now? [y/N]: "):
            time.sleep(1.0)
            continue
        if py_files and not run_formatting(py_files):
            print("Formatting failed; leaving changes uncommitted.")
            time.sleep(1.0)
            continue
        if py_files and not run_quality_checks(py_files):
            print("Quality checks failed; leaving changes uncommitted.")
            time.sleep(1.0)
            continue

        if not prompt_yes_no("Commit all current changes? [y/N]: "):
            time.sleep(1.0)
            continue
        run(["git", "add", "-A"], check=True)
        if is_clean():
            continue
        stamped = message.replace(
            "{timestamp}", dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        )
        run(["git", "commit", "-m", stamped], check=True)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Auto-format, lint, and commit on repo changes."
    )
    parser.add_argument(
        "--message",
        default="Auto-update {timestamp}",
        help="Commit message (use {timestamp} placeholder).",
    )
    parser.add_argument(
        "--quiet-seconds",
        type=float,
        default=2.0,
        help="Seconds of no file changes before committing.",
    )
    args = parser.parse_args()
    try:
        handle_changes(args.message, args.quiet_seconds)
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
