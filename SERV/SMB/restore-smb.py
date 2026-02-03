#!/usr/bin/env python3
"""SMB restore Python script."""

from __future__ import annotations

import os
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
        print("""Restore SMB
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

    if shutil.which("systemctl") is None:
        print("systemctl not found; cannot manage services.", file=sys.stderr)
        return 1

    def list_units() -> set[str]:
        listed = subprocess.run(
            ["systemctl", "list-unit-files", "--type=service", "--no-legend"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        return {line.split()[0] for line in listed.stdout.splitlines() if line.strip()}

    def resolve_service(candidates: list[str]) -> str | None:
        units = list_units()
        for candidate in candidates:
            if candidate in units:
                return candidate
        return None

    service_groups = [
        ("avahi-daemon", ["avahi-daemon.service"]),
        ("nmb/nmbd", ["nmb.service", "nmbd.service"]),
        ("smb/smbd", ["smb.service", "smbd.service"]),
        ("sshd", ["sshd.service"]),
        ("wsdd/wsdd2", ["wsdd.service", "wsdd2.service"]),
    ]

    resolved_services: list[str] = []
    for label, candidates in service_groups:
        svc = resolve_service(candidates)
        if svc:
            resolved_services.append(svc)
            continue
        answer = input(
            f"Service {label} is not installed. Install it now? [y/N]: "
        ).strip()
        if answer.lower() != "y":
            print(f"Required service missing: {label}. Exiting.")
            return 1
        print(f"Please install {label}, then press Enter to continue.")
        input("")
        svc = resolve_service(candidates)
        if not svc:
            print(f"Service {label} still not found. Exiting.")
            return 1
        resolved_services.append(svc)

    # Optional smbpasswd user setup (non-sudo discovery).
    smb_user_to_add = ""
    if shutil.which("pdbedit") is not None:
        smb_user = input("Enter SMB username for smbpasswd: ").strip()
        if smb_user:
            existing = subprocess.run(
                ["pdbedit", "-L"], check=False, stdout=subprocess.PIPE, text=True
            )
            users = {line.split(":")[0] for line in existing.stdout.splitlines()}
            if smb_user in users:
                print(f"SMB user {smb_user} already exists; skipping smbpasswd.")
            else:
                smb_user_to_add = smb_user
        else:
            print("No SMB username provided; skipping smbpasswd.")
    else:
        print("pdbedit not found; skipping smbpasswd user check.")

    if shutil.which("sudo") is None:
        print("sudo not found; cannot restore SMB files.", file=sys.stderr)
        return 1
    print("Sudo required to restore SMB files. You may be prompted.")
    if subprocess.run(["sudo", "-v"], check=False).returncode != 0:
        return 1

    for svc in resolved_services:
        enabled = subprocess.run(
            ["sudo", "systemctl", "enable", svc], check=False
        ).returncode
        if enabled != 0:
            print(f"Warning: failed to enable {svc}", file=sys.stderr)

    # Load CIFS module.
    subprocess.run(["sudo", "modprobe", "cifs"], check=False)

    if smb_user_to_add:
        subprocess.run(["sudo", "smbpasswd", "-a", smb_user_to_add], check=False)

    # Create local /SMB structure.
    user_name = os.environ.get("USER") or os.getlogin()
    subprocess.run(["sudo", "mkdir", "-p", "/SMB"], check=False)
    subprocess.run(["sudo", "chown", f"{user_name}:{user_name}", "/SMB"], check=False)
    subprocess.run(["sudo", "chmod", "750", "/SMB"], check=False)

    subdirs = [
        "/SMB/euclid",
        "/SMB/pneuma",
        "/SMB/lateralus",
        "/SMB/SCP",
        "/SMB/SCP/HDD-01",
        "/SMB/SCP/HDD-02",
        "/SMB/SCP/HDD-03",
    ]
    for path in subdirs:
        subprocess.run(["sudo", "mkdir", "-p", path], check=False)
        subprocess.run(["sudo", "chown", f"{user_name}:{user_name}", path], check=False)
        subprocess.run(["sudo", "chmod", "750", path], check=False)

    fstab_lines = [
        (
            "//192.168.8.60/d   /SMB/euclid   cifs   "
            "_netdev,credentials=/etc/samba/creds-euclid,uid=1000,gid=1000   0 0"
        ),
        (
            "//192.168.8.155/hdd-01   /SMB/SCP/HDD-01   cifs   "
            "_netdev,credentials=/etc/samba/creds-scp,uid=1000,gid=1000   0 0"
        ),
        (
            "//192.168.8.155/hdd-02   /SMB/SCP/HDD-02   cifs   "
            "_netdev,credentials=/etc/samba/creds-scp,uid=1000,gid=1000   0 0"
        ),
        (
            "//192.168.8.155/hdd-03   /SMB/SCP/HDD-03   cifs   "
            "_netdev,credentials=/etc/samba/creds-scp,uid=1000,gid=1000   0 0"
        ),
    ]
    fstab_path = Path("/etc/fstab")
    if fstab_path.is_file():
        current = subprocess.run(
            ["sudo", "cat", str(fstab_path)],
            check=False,
            stdout=subprocess.PIPE,
            text=True,
        ).stdout.splitlines()
        missing = [line for line in fstab_lines if line not in current]
        if missing:
            subprocess.run(
                ["sudo", "sh", "-c", 'printf "\\n" >> /etc/fstab'], check=False
            )
            for line in missing:
                subprocess.run(
                    ["sudo", "sh", "-c", f"printf '%s\\n' \"{line}\" >> /etc/fstab"],
                    check=False,
                )
    else:
        print("File not found: /etc/fstab", file=sys.stderr)

    # Restore smb.conf and creds-*.
    samba_dir = Path("/etc/samba")
    if not samba_dir.is_dir():
        subprocess.run(["sudo", "mkdir", "-p", str(samba_dir)], check=False)
        subprocess.run(["sudo", "chown", "root:root", str(samba_dir)], check=False)
        subprocess.run(["sudo", "chmod", "755", str(samba_dir)], check=False)

    smb_conf = samba_dir / "smb.conf"
    if smb_conf.is_file():
        backup_path = Path(__file__).resolve().parent / "smb.conf.backup"
        subprocess.run(["sudo", "cp", str(smb_conf), str(backup_path)], check=False)

    source_conf = Path(__file__).resolve().parent / "smb.conf"
    if source_conf.is_file():
        subprocess.run(["sudo", "cp", str(source_conf), str(smb_conf)], check=False)
        subprocess.run(["sudo", "chown", "root:root", str(smb_conf)], check=False)
        subprocess.run(["sudo", "chmod", "644", str(smb_conf)], check=False)
    else:
        print(f"Source not found: {source_conf}", file=sys.stderr)

    creds_files = list(Path(__file__).resolve().parent.glob("creds-*"))
    if not creds_files:
        print("No creds-* files found in backup folder.")
    else:
        for src in creds_files:
            if src.is_file():
                subprocess.run(["sudo", "cp", str(src), str(samba_dir)], check=False)
                dest_path = samba_dir / src.name
                subprocess.run(
                    ["sudo", "chown", "root:root", str(dest_path)], check=False
                )
                subprocess.run(["sudo", "chmod", "600", str(dest_path)], check=False)
            else:
                print(f"Skipping missing creds file: {src}")

    # Validate smb.conf after restore.
    smb_conf_check = Path("/etc/samba/smb.conf")
    if smb_conf_check.is_file():
        if shutil.which("testparm") is not None:
            result = subprocess.run(["sudo", "testparm", "-s"], check=False)
            if result.returncode != 0:
                print("Error: testparm reported errors in smb.conf", file=sys.stderr)
                return 1
        else:
            print(
                "Warning: testparm not found; skipping smb.conf validation.",
                file=sys.stderr,
            )

    # Restart services and verify status.
    for svc in resolved_services:
        restarted = subprocess.run(
            ["sudo", "systemctl", "restart", svc], check=False
        ).returncode
        if restarted != 0:
            print(f"Warning: failed to restart {svc}", file=sys.stderr)
        active = subprocess.run(
            ["sudo", "systemctl", "is-active", "--quiet", svc], check=False
        ).returncode
        if active != 0:
            print(f"Warning: {svc} is not active after restart.", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
