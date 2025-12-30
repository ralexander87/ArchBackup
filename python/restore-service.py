#!/usr/bin/env python3
import datetime
import getpass
import os
import pwd
import shutil
import subprocess
import sys


LOG_FH = None
QUIET = True
TOTAL_STEPS = 4
STEP = 0


def log(msg):
    if LOG_FH:
        LOG_FH.write(msg + "\n")
        LOG_FH.flush()


def status(msg):
    print(msg)
    if LOG_FH:
        LOG_FH.write(msg + "\n")
        LOG_FH.flush()


def progress(msg):
    global STEP
    STEP += 1
    status(f"[{STEP}/{TOTAL_STEPS}] {msg}")


def err(msg):
    print(msg, file=sys.stderr)
    if LOG_FH:
        LOG_FH.write(msg + "\n")
        LOG_FH.flush()

def run(cmd, check=True):
    if QUIET and LOG_FH:
        return subprocess.run(cmd, check=check, stdout=LOG_FH, stderr=LOG_FH)
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
        os.execvp("sudo", ["sudo", "-E", sys.executable, script] + sys.argv[1:])


def main():
    ensure_root()

    run_as_user = "ralexander"
    run_as_group = pwd.getpwnam(run_as_user).pw_gid
    user_home = pwd.getpwnam(run_as_user).pw_dir

    usb_user = os.environ.get("SUDO_USER") or os.environ.get("USER") or run_as_user
    usb_label = os.environ.get("BKP_USB_LABEL", "netac")
    srv = os.environ.get("SRV") or f"/run/media/{usb_user}/{usb_label}/Srv"

    smb_root = "/SMB"
    smb_subdirs = ["euclid", "pneuma", "SCP"]
    wsdd_service = "wsdd.service"
    smb_services = ["smb.service", "nmb.service", "avahi-daemon.service", wsdd_service]
    sshd_service = "sshd.service"
    smb_conf_src = os.path.join(srv, "samba", "smb.conf")
    sshd_conf_src = os.path.join(srv, "ssh", "sshd_config")
    yubi_service = "pcscd.service"

    for cmd in ["systemctl", "modprobe", "smbpasswd", "rsync", "sshd"]:
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
    log_dir = os.path.join(srv, "logs")
    try:
        os.makedirs(log_dir, exist_ok=True)
        log_path = os.path.join(log_dir, f"restore-serv-{ts}.log")
        global LOG_FH
        LOG_FH = open(log_path, "a", encoding="utf-8", errors="replace")
    except OSError:
        log_path = f"/tmp/restore-serv-{ts}.log"
        LOG_FH = open(log_path, "a", encoding="utf-8", errors="replace")
        err(f"[!] USB log path unavailable, using {log_path}")
    status(f"Restore start: {datetime.datetime.now().isoformat()}")
    status(f"Log: {log_path}")
    progress("Kernel module")
    log("[*] Loading CIFS kernel module (if available)…")
    run(["modprobe", "cifs"], check=False)

    progress("Samba config")
    if os.path.isdir("/etc/samba"):
        log(f"[*] Backing up /etc/samba to {backup_dir}/etc-samba...")
        run(["rsync", "-a", "--quiet", "/etc/samba/", f"{backup_dir}/etc-samba/"])

    smb_conf_bak = f"/etc/samba/smb.conf.{ts}.bak"
    shutil.copy2(smb_conf_src, smb_conf_bak)
    os.chown(smb_conf_bak, 0, 0)
    os.chmod(smb_conf_bak, 0o644)
    shutil.copy2(smb_conf_src, "/etc/samba/smb.conf")
    os.chown("/etc/samba/smb.conf", 0, 0)
    os.chmod("/etc/samba/smb.conf", 0o644)

    log("[*] Creating SMB root and subdirectories with strict permissions…")
    os.makedirs(smb_root, exist_ok=True)
    os.chmod(smb_root, 0o1750)
    for d in smb_subdirs:
        path = os.path.join(smb_root, d)
        os.makedirs(path, exist_ok=True)
        os.chmod(path, 0o2750)
    os.chown(smb_root, pwd.getpwnam(run_as_user).pw_uid, run_as_group)
    for d in smb_subdirs:
        os.chown(os.path.join(smb_root, d), pwd.getpwnam(run_as_user).pw_uid, run_as_group)

    progress("Samba users/services")
    log(f"[*] Setting ownership of {smb_root} to {run_as_user}...")
    run(["chown", "-R", f"{run_as_user}:{run_as_group}", smb_root])

    proc = subprocess.run(["pdbedit", "-L"], text=True, capture_output=True, check=False)
    if run_as_user not in proc.stdout:
        log(f"[*] Adding Samba account for {run_as_user} (you'll be prompted for a password)…")
        run(["smbpasswd", "-a", run_as_user], check=True)
    else:
        log("[*] Samba account already exists—skipping.")

    log("[*] Enabling and starting Samba-related services…")
    for svc in smb_services:
        run(["systemctl", "enable", "--now", svc])

    if command_exists("testparm"):
        log("[*] Validating smb.conf…")
        if run(["testparm", "-s", "/etc/samba/smb.conf"], check=False).returncode != 0:
            log("[!] smb.conf validation failed; restoring backup.")
            shutil.copy2(smb_conf_bak, "/etc/samba/smb.conf")
            os.chown("/etc/samba/smb.conf", 0, 0)
            os.chmod("/etc/samba/smb.conf", 0o644)
            for svc in smb_services:
                run(["systemctl", "restart", svc], check=False)
            raise SystemExit("smb.conf validation failed; backup restored. Fix errors and retry.")

    for svc in smb_services:
        if run(["systemctl", "is-active", "--quiet", svc], check=False).returncode != 0:
            log(f"[!] Service failed: {svc}. Restoring smb.conf backup.")
            shutil.copy2(smb_conf_bak, "/etc/samba/smb.conf")
            os.chown("/etc/samba/smb.conf", 0, 0)
            os.chmod("/etc/samba/smb.conf", 0o644)
            for s in smb_services:
                run(["systemctl", "restart", s], check=False)
            raise SystemExit("Samba services failed to start; backup restored. Fix errors and retry.")

    progress("SSH config")
    src_ssh_dir = os.path.join(srv, "ssh", ".ssh")
    dest_ssh_dir = os.path.join(user_home, ".ssh")

    run(["systemctl", "enable", "--now", sshd_service])
    run(["systemctl", "enable", "--now", yubi_service])

    if os.path.isdir(src_ssh_dir):
        log("[*] Syncing SSH keys/config…")
        if os.path.isdir(dest_ssh_dir):
            log(f"[*] Backing up existing SSH directory to {backup_dir}/ssh...")
            run(["rsync", "-a", "--quiet", f"{dest_ssh_dir}/", f"{backup_dir}/ssh/"])
        os.makedirs(dest_ssh_dir, exist_ok=True)
        run(["chown", f"{run_as_user}:{run_as_group}", dest_ssh_dir])
        os.chmod(dest_ssh_dir, 0o700)
        run(["rsync", "-aH", "--quiet", "--delete", f"{src_ssh_dir}/", f"{dest_ssh_dir}/"])
        run(["chown", "-R", f"{run_as_user}:{run_as_group}", dest_ssh_dir])

        for root, _, files in os.walk(dest_ssh_dir):
            for name in files:
                path = os.path.join(root, name)
                if name.endswith(".pub"):
                    os.chmod(path, 0o644)
                else:
                    os.chmod(path, 0o600)
    else:
        log(f"[!] Source SSH directory not found: {src_ssh_dir} (skipping key sync).")

    sshd_conf_bak = f"/etc/ssh/sshd_config.{ts}.bak"
    shutil.copy2(sshd_conf_src, sshd_conf_bak)
    os.chown(sshd_conf_bak, 0, 0)
    os.chmod(sshd_conf_bak, 0o600)
    shutil.copy2(sshd_conf_src, "/etc/ssh/sshd_config")
    os.chown("/etc/ssh/sshd_config", 0, 0)
    os.chmod("/etc/ssh/sshd_config", 0o600)

    log("[*] Validating sshd_config…")
    if run(["sshd", "-t", "-f", "/etc/ssh/sshd_config"], check=False).returncode == 0:
        run(["systemctl", "enable", "--now", sshd_service])
    else:
        log("[!] sshd_config validation failed; restoring backup.")
        shutil.copy2(sshd_conf_bak, "/etc/ssh/sshd_config")
        os.chown("/etc/ssh/sshd_config", 0, 0)
        os.chmod("/etc/ssh/sshd_config", 0o600)
        raise SystemExit("sshd_config validation failed; backup restored. Fix errors and retry.")

    log("[*] Service status summary:")
    for svc in smb_services + [sshd_service]:
        run(["systemctl", "--no-pager", "--full", "status", svc], check=False)
        log("----")

    status("[*] Restore services done.")
    if LOG_FH:
        LOG_FH.close()


if __name__ == "__main__":
    main()
