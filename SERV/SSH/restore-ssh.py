#!/usr/bin/env python3
"""SSH restore Python script."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
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
    user_name = os.environ.get("USER") or os.getlogin()
    show_banner = "--no-banner" not in sys.argv
    auto_yes = "--yes" in sys.argv
    confirm_restore = "--confirm" in sys.argv
    log_dir = ""
    manifest_only = False
    no_restart = False
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--log-dir" and i + 1 < len(args):
            log_dir = args[i + 1]
            i += 2
            continue
        if args[i] == "--manifest-only":
            manifest_only = True
            i += 1
            continue
        if args[i] == "--no-restart":
            no_restart = True
            i += 1
            continue
        i += 1
    if show_banner:
        print("""Restore SSH
Options:
  --confirm    Ask before destructive restore
  --yes        Auto-confirm destructive prompt
  --log-dir <dir>   Write logs to a custom directory
  --manifest-only   Print expected sources and exit
  --no-restart      Skip restarting sshd.service
  --no-banner  Skip this prompt
""")
        input("Press Enter to continue...")

    if log_dir:
        log_path = Path(log_dir) / "restore-ssh.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_handle = log_path.open("a", encoding="utf-8")
        sys.stdout = log_handle
        sys.stderr = log_handle

    if manifest_only:
        script_dir = Path(__file__).resolve().parent
        print("Sources:")
        print(script_dir / ".ssh")
        print(script_dir / "sshd_config")
        return 0

    if confirm_restore:
        if auto_yes:
            answer = "y"
        else:
            answer = input(
                "This restore will modify SSH configs. Continue? [y/N]: "
            ).strip()
        if answer.lower() != "y":
            print("Restore cancelled.")
            return 0
    else:
        print("Warning: --confirm not set; proceeding without confirmation.")

    if shutil.which("systemctl") is None:
        print("systemctl not found; cannot manage sshd.service.", file=sys.stderr)
        return 1
    if shutil.which("sudo") is None:
        print("sudo not found; cannot restore SSH files.", file=sys.stderr)
        return 1
    if subprocess.run(["sudo", "-v"], check=False).returncode != 0:
        return 1

    script_dir = Path(__file__).resolve().parent
    ssh_dest = Path(f"/home/{user_name}/.ssh")

    rsync_opts = [
        "rsync",
        "-aHAX",
        "--numeric-ids",
        "--sparse",
        "--delete-delay",
        "--info=stats1",
    ]

    rsync_failures = 0
    validation_failed = False

    # Ensure sshd.service is installed.
    result = subprocess.run(
        ["systemctl", "list-unit-files", "--type=service"],
        check=False,
        stdout=subprocess.PIPE,
        text=True,
    )
    if "sshd.service" not in result.stdout:
        answer = input(
            "Service sshd.service is not installed. Install it now? [y/N]: "
        ).strip()
        if answer.lower() != "y":
            print("Required service missing: sshd.service. Exiting.")
            return 1
        input("Please install sshd.service, then press Enter to continue.")
        result = subprocess.run(
            ["systemctl", "list-unit-files", "--type=service"],
            check=False,
            stdout=subprocess.PIPE,
            text=True,
        )
        if "sshd.service" not in result.stdout:
            print("Service sshd.service still not found. Exiting.")
            return 1

    ssh_source = script_dir / ".ssh"
    if ssh_source.is_dir():
        ssh_dest.mkdir(parents=True, exist_ok=True)
        print(f"Restoring: {ssh_source} -> {ssh_dest.parent}")
        try:
            run_rsync([*rsync_opts, str(ssh_source), f"{ssh_dest.parent}/"])
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            rsync_failures += 1
    else:
        print(f"Source folder not found: {ssh_source}", file=sys.stderr)
        rsync_failures += 1

    sshd_source = script_dir / "sshd_config"
    sshd_source_exists = sshd_source.is_file()
    if not sshd_source_exists:
        print(f"Source file not found: {sshd_source}", file=sys.stderr)
        rsync_failures += 1

    if ssh_dest.is_dir():
        subprocess.run(["chmod", "700", str(ssh_dest)], check=False)
        subprocess.run(
            [
                "find",
                str(ssh_dest),
                "-type",
                "f",
                "-name",
                "*.pub",
                "-exec",
                "chmod",
                "644",
                "{}",
                "+",
            ],
            check=False,
        )
        subprocess.run(
            [
                "find",
                str(ssh_dest),
                "-type",
                "f",
                "!",
                "-name",
                "*.pub",
                "-exec",
                "chmod",
                "600",
                "{}",
                "+",
            ],
            check=False,
        )

    # Optional key fingerprint verification.
    if shutil.which("ssh-keygen") is not None:
        for src in (script_dir / ".ssh").glob("*"):
            if src.is_dir() or src.name == "agent":
                continue
            if (
                subprocess.run(["ssh-keygen", "-lf", str(src)], check=False).returncode
                != 0
            ):
                continue
            dest_file = ssh_dest / src.name
            if dest_file.is_file():
                src_fp = subprocess.run(
                    ["ssh-keygen", "-lf", str(src)],
                    check=False,
                    stdout=subprocess.PIPE,
                    text=True,
                ).stdout.strip()
                dest_fp = subprocess.run(
                    ["ssh-keygen", "-lf", str(dest_file)],
                    check=False,
                    stdout=subprocess.PIPE,
                    text=True,
                ).stdout.strip()
                if src_fp and dest_fp and src_fp != dest_fp:
                    print(
                        f"Warning: fingerprint mismatch for {src.name}",
                        file=sys.stderr,
                    )
                    validation_failed = True
    else:
        print(
            "Warning: ssh-keygen not found; skipping key verification.", file=sys.stderr
        )

    if shutil.which("sudo") is None:
        print("sudo not found; cannot restore SSH files.", file=sys.stderr)
        return 1
    if subprocess.run(["sudo", "-v"], check=False).returncode != 0:
        return 1

    if ssh_dest.is_dir():
        subprocess.run(
            ["sudo", "chown", "-R", f"{user_name}:{user_name}", str(ssh_dest)],
            check=False,
        )

    if sshd_source_exists:
        try:
            if shutil.which("sshd") is not None:
                if (
                    subprocess.run(
                        ["sudo", "sshd", "-t", "-f", str(sshd_source)],
                        check=False,
                    ).returncode
                    != 0
                ):
                    print(
                        "Warning: sshd -t reported errors in backup sshd_config",
                        file=sys.stderr,
                    )
                    validation_failed = True
            else:
                print(
                    "Warning: sshd not found; skipping backup config validation.",
                    file=sys.stderr,
                )
            subprocess.run(
                ["sudo", "cp", str(sshd_source), "/etc/ssh/sshd_config"],
                check=True,
            )
            subprocess.run(
                ["sudo", "chown", "root:root", "/etc/ssh/sshd_config"], check=True
            )
            subprocess.run(["sudo", "chmod", "600", "/etc/ssh/sshd_config"], check=True)
            if shutil.which("sshd") is not None:
                if (
                    subprocess.run(
                        ["sudo", "sshd", "-t", "-f", "/etc/ssh/sshd_config"],
                        check=False,
                    ).returncode
                    != 0
                ):
                    print(
                        "Warning: sshd -t reported errors in sshd_config",
                        file=sys.stderr,
                    )
                    validation_failed = True
            else:
                print(
                    "Warning: sshd not found; skipping config validation.",
                    file=sys.stderr,
                )
        except subprocess.CalledProcessError as exc:
            print(str(exc), file=sys.stderr)
            rsync_failures += 1

    subprocess.run(["sudo", "systemctl", "enable", "sshd.service"], check=False)
    subprocess.run(["sudo", "systemctl", "start", "sshd.service"], check=False)

    # Restart sshd and confirm it is active.
    if not no_restart:
        subprocess.run(["sudo", "systemctl", "restart", "sshd.service"], check=False)
        if (
            subprocess.run(
                ["sudo", "systemctl", "is-active", "--quiet", "sshd.service"],
                check=False,
            ).returncode
            != 0
        ):
            print("Warning: sshd.service is not active after restart.", file=sys.stderr)

    print(f"Restore completed from: {script_dir}")
    print(
        "Summary: rsync_failures="
        f"{rsync_failures}, validation_failed={validation_failed}"
    )
    return 1 if (rsync_failures or validation_failed) else 0


if __name__ == "__main__":
    raise SystemExit(main())
