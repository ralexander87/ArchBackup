#!/usr/bin/env python3
import datetime
import os
import pwd
import shutil
import subprocess
import sys


QUIET = True
TOTAL_STEPS = 4
STEP = 0


def status(msg):
    print(msg)


def progress(msg):
    global STEP
    STEP += 1
    status(f"[{STEP}/{TOTAL_STEPS}] {msg}")


def err(msg):
    print(msg, file=sys.stderr)


def run(cmd, check=True):
    if QUIET:
        return subprocess.run(cmd, check=check, stdout=subprocess.DEVNULL)
    return subprocess.run(cmd, check=check)


def run_interactive(cmd, check=True):
    return subprocess.run(cmd, check=check)


def command_exists(cmd):
    return shutil.which(cmd) is not None


def require_file(path):
    if not os.path.isfile(path):
        err(f"Required file not found: {path}")
        raise SystemExit(1)


def ensure_root():
    if os.geteuid() != 0:
        script = os.path.abspath(sys.argv[0])
        os.execvp(
            "sudo", ["sudo", "-E", sys.executable, script] + sys.argv[1:]
        )


def resolve_backup_root(base_root, required):
    def has_required(path):
        return all(
            os.path.exists(os.path.join(path, name)) for name in required
        )

    if has_required(base_root):
        return base_root
    try:
        candidates = [
            os.path.join(base_root, name)
            for name in os.listdir(base_root)
            if os.path.isdir(os.path.join(base_root, name))
        ]
    except OSError:
        return None
    candidates.sort(key=os.path.getmtime, reverse=True)
    for candidate in candidates:
        if has_required(candidate):
            return candidate
    return None


def main():
    ensure_root()

    # Run as the original user, but apply system-level changes.
    run_as_user = (
        os.environ.get("SUDO_USER") or os.environ.get("USER") or "ralexander"
    )
    run_as_group = pwd.getpwnam(run_as_user).pw_gid
    user_home = pwd.getpwnam(run_as_user).pw_dir

    usb_user = (
        os.environ.get("SUDO_USER") or os.environ.get("USER") or run_as_user
    )
    usb_label = os.environ.get("BKP_USB_LABEL", "netac")
    usb_mount = f"/run/media/{usb_user}/{usb_label}"
    base_root = os.path.join(usb_mount, "START")
    if not command_exists("mountpoint"):
        err("mountpoint not found.")
        raise SystemExit(1)
    if run(["mountpoint", "-q", usb_mount], check=False).returncode != 0:
        err(
            f"{usb_mount} is not a mountpoint. "
            "Is the USB plugged in and mounted?"
        )
        raise SystemExit(1)
    # Locate backup root that contains Srv.
    backup_root = resolve_backup_root(base_root, ["Srv"])
    if not backup_root:
        err(f"Backup root not found under {base_root}")
        raise SystemExit(1)
    srv = os.path.join(backup_root, "Srv")

    # Samba + SSH restore sources.
    smb_root = "/SMB"
    smb_subdirs = ["euclid", "pneuma", "SCP"]
    wsdd_service = "wsdd.service"
    smb_services = [
        "smb.service",
        "nmb.service",
        "avahi-daemon.service",
        wsdd_service,
    ]
    sshd_service = "sshd.service"
    smb_conf_src = os.path.join(srv, "samba", "smb.conf")
    sshd_conf_src = os.path.join(srv, "ssh", "sshd_config")
    yubi_service = "pcscd.service"

    for cmd in [
        "systemctl",
        "modprobe",
        "smbpasswd",
        "rsync",
        "sshd",
        "pdbedit",
    ]:
        if not command_exists(cmd):
            err(f"Missing required command: {cmd}")
            raise SystemExit(1)

    if not os.path.isdir(srv):
        err(f"Backup directory not found: {srv}")
        raise SystemExit(1)

    require_file(smb_conf_src)
    require_file(sshd_conf_src)

    ts = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    backup_dir = f"/var/backups/restore-serv-{ts}"
    os.makedirs(backup_dir, exist_ok=True)
    status(f"Restore start: {datetime.datetime.now().isoformat()}")
    progress("Kernel module")
    # Load CIFS for SMB mounts.
    run(["modprobe", "cifs"], check=False)

    progress("Samba config")
    # Backup existing Samba/SSH config before applying new ones.
    if os.path.isdir("/etc/samba"):
        run(
            [
                "rsync",
                "-a",
                "--quiet",
                "/etc/samba/",
                f"{backup_dir}/etc-samba/",
            ]
        )
    if os.path.isdir("/etc/ssh"):
        run(["rsync", "-a", "--quiet", "/etc/ssh/", f"{backup_dir}/etc-ssh/"])
    if os.path.isfile("/etc/ssh/sshd_config"):
        shutil.copy2(
            "/etc/ssh/sshd_config",
            os.path.join(backup_dir, "sshd_config"),
        )

    smb_conf_bak = f"/etc/samba/smb.conf.{ts}.bak"
    shutil.copy2(smb_conf_src, smb_conf_bak)
    os.chown(smb_conf_bak, 0, 0)
    os.chmod(smb_conf_bak, 0o644)
    shutil.copy2(smb_conf_src, "/etc/samba/smb.conf")
    os.chown("/etc/samba/smb.conf", 0, 0)
    os.chmod("/etc/samba/smb.conf", 0o644)

    # Create SMB share structure.
    os.makedirs(smb_root, exist_ok=True)
    os.chmod(smb_root, 0o1750)
    for d in smb_subdirs:
        path = os.path.join(smb_root, d)
        os.makedirs(path, exist_ok=True)
        os.chmod(path, 0o2750)
    os.chown(smb_root, pwd.getpwnam(run_as_user).pw_uid, run_as_group)
    for d in smb_subdirs:
        os.chown(
            os.path.join(smb_root, d),
            pwd.getpwnam(run_as_user).pw_uid,
            run_as_group,
        )

    progress("Samba users/services")
    # Ensure ownership and enable services.
    run(["chown", "-R", f"{run_as_user}:{run_as_group}", smb_root])

    proc = subprocess.run(
        ["pdbedit", "-L"], text=True, capture_output=True, check=False
    )
    if run_as_user not in proc.stdout:
        run_interactive(["smbpasswd", "-a", run_as_user], check=True)
    else:
        pass

    for svc in smb_services:
        run(["systemctl", "enable", "--now", svc])

    if command_exists("testparm"):
        # Validate config before continuing.
        if (
            run(
                ["testparm", "-s", "/etc/samba/smb.conf"], check=False
            ).returncode
            != 0
        ):
            err("[!] smb.conf validation failed; restoring backup.")
            shutil.copy2(smb_conf_bak, "/etc/samba/smb.conf")
            os.chown("/etc/samba/smb.conf", 0, 0)
            os.chmod("/etc/samba/smb.conf", 0o644)
            for svc in smb_services:
                run(["systemctl", "restart", svc], check=False)
            raise SystemExit(
                "smb.conf validation failed; backup restored. "
                "Fix errors and retry."
            )

    for svc in smb_services:
        if (
            run(
                ["systemctl", "is-active", "--quiet", svc], check=False
            ).returncode
            != 0
        ):
            err(f"[!] Service failed: {svc}. Restoring smb.conf backup.")
            shutil.copy2(smb_conf_bak, "/etc/samba/smb.conf")
            os.chown("/etc/samba/smb.conf", 0, 0)
            os.chmod("/etc/samba/smb.conf", 0o644)
            for s in smb_services:
                run(["systemctl", "restart", s], check=False)
            raise SystemExit(
                "Samba services failed to start; backup restored. "
                "Fix errors and retry."
            )

    progress("SSH config")
    # Restore SSH keys and config.
    src_ssh_dir = os.path.join(srv, "ssh", ".ssh")
    dest_ssh_dir = os.path.join(user_home, ".ssh")

    run(["systemctl", "enable", "--now", sshd_service])
    run(["systemctl", "enable", "--now", yubi_service])

    if os.path.isdir(src_ssh_dir):
        if os.path.isdir(dest_ssh_dir):
            run(
                [
                    "rsync",
                    "-a",
                    "--quiet",
                    f"{dest_ssh_dir}/",
                    f"{backup_dir}/ssh/",
                ]
            )
        os.makedirs(dest_ssh_dir, exist_ok=True)
        run(["chown", f"{run_as_user}:{run_as_group}", dest_ssh_dir])
        os.chmod(dest_ssh_dir, 0o700)
        run(
            [
                "rsync",
                "-aH",
                "--quiet",
                "--delete",
                f"{src_ssh_dir}/",
                f"{dest_ssh_dir}/",
            ]
        )
        run(["chown", "-R", f"{run_as_user}:{run_as_group}", dest_ssh_dir])

        for root, _, files in os.walk(dest_ssh_dir):
            for name in files:
                path = os.path.join(root, name)
                if name.endswith(".pub"):
                    os.chmod(path, 0o644)
                else:
                    os.chmod(path, 0o600)
    else:
        err(
            f"[!] Source SSH directory not found: {src_ssh_dir} "
            "(skipping key sync)."
        )

    sshd_conf_bak = f"/etc/ssh/sshd_config.{ts}.bak"
    # Replace sshd_config and validate.
    shutil.copy2(sshd_conf_src, sshd_conf_bak)
    os.chown(sshd_conf_bak, 0, 0)
    os.chmod(sshd_conf_bak, 0o600)
    shutil.copy2(sshd_conf_src, "/etc/ssh/sshd_config")
    os.chown("/etc/ssh/sshd_config", 0, 0)
    os.chmod("/etc/ssh/sshd_config", 0o600)

    if (
        run(
            ["sshd", "-t", "-f", "/etc/ssh/sshd_config"], check=False
        ).returncode
        == 0
    ):
        run(["systemctl", "enable", "--now", sshd_service])
    else:
        err("[!] sshd_config validation failed; restoring backup.")
        shutil.copy2(sshd_conf_bak, "/etc/ssh/sshd_config")
        os.chown("/etc/ssh/sshd_config", 0, 0)
        os.chmod("/etc/ssh/sshd_config", 0o600)
        raise SystemExit(
            "sshd_config validation failed; backup restored. "
            "Fix errors and retry."
        )

    # Service status summary for quick checks.
    for svc in smb_services + [sshd_service]:
        run(["systemctl", "--no-pager", "--full", "status", svc], check=False)

    status("[*] Restore services done.")
    target_root = backup_root or os.path.dirname(srv.rstrip("/"))
    status(f"Target: {target_root}")


if __name__ == "__main__":
    main()
