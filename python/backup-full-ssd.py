#!/usr/bin/env python3
import datetime
import getpass
import glob
import hashlib
import os
import shutil
import stat
import subprocess
import sys


LOG_FH = None


def log(msg):
    print(msg)
    if LOG_FH:
        LOG_FH.write(msg + "\n")
        LOG_FH.flush()


def log_to_file(msg):
    if LOG_FH:
        LOG_FH.write(msg + "\n")
        LOG_FH.flush()


def run(cmd, check=True, live_preview=False, show_output=True):
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in proc.stdout:
        if LOG_FH:
            LOG_FH.write(line)
            LOG_FH.flush()
        if live_preview:
            preview = line.rstrip()
            if preview:
                width = shutil.get_terminal_size((80, 20)).columns
                if len(preview) >= width:
                    preview = preview[: width - 1]
                sys.stdout.write("\r" + preview)
                sys.stdout.flush()
        elif show_output:
            sys.stdout.write(line)
            sys.stdout.flush()
    rc = proc.wait()
    if live_preview:
        sys.stdout.write("\n")
        sys.stdout.flush()
    if check and rc != 0:
        raise subprocess.CalledProcessError(rc, cmd)
    return rc


def command_exists(cmd):
    return shutil.which(cmd) is not None


def require_command(cmd):
    if not command_exists(cmd):
        log(f"Missing required command: {cmd}")
        sys.exit(1)


def is_block_device(path):
    try:
        return stat.S_ISBLK(os.stat(path).st_mode)
    except FileNotFoundError:
        return False


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def prune_old(path_glob, keep=3):
    items = [p for p in glob.glob(path_glob)]
    items.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    for old in items[keep:]:
        if os.path.isdir(old):
            log(f"Removing old backup folder: {old}")
            shutil.rmtree(old)
        else:
            log(f"Removing old archive: {old}")
            os.remove(old)


def main():
    print("-" * 92)

    user = getpass.getuser()
    timestamp = datetime.datetime.now().strftime("%j-%Y-%H%M")

    usb_label = os.environ.get("BKP_USB_LABEL", "Lateralus")
    min_free_gb = int(os.environ.get("BKP_MIN_FREE_GB", "20"))
    luks_device = os.environ.get("BKP_LUKS_DEVICE", "/dev/nvme0n1p2")
    bkp_root = f"/run/media/{user}/{usb_label}"
    bkp_base = os.path.join(bkp_root, "BKP")
    bkp_folder = os.path.join(bkp_base, timestamp)
    root_dir = os.path.join(bkp_folder, "root")
    home_dir = os.path.join(bkp_folder, "home")
    log_dir = os.path.join(bkp_base, "logs")
    log_file = os.path.join(log_dir, f"backup-full-ssd-{timestamp}.log")
    archive_file = os.path.join(bkp_base, f"full-backup-{timestamp}.tar.gz")

    if not command_exists("mountpoint") or not subprocess.run(
        ["mountpoint", "-q", bkp_root]
    ).returncode == 0:
        print(f"ERROR: {bkp_root} is not a mountpoint. Is the USB plugged in and mounted?")
        sys.exit(1)

    if command_exists("acpi"):
        acpi_out = subprocess.run(["acpi", "-a"], text=True, capture_output=True).stdout.strip()
        log_to_file(f"AC power status: {acpi_out}")
        if "off-line" in acpi_out:
            log("AC power not connected; aborting backup.")
            sys.exit(1)

    for cmd in ["rsync", "tar", "sudo", "cryptsetup"]:
        require_command(cmd)

    if not os.access(bkp_root, os.W_OK):
        log(f"Backup root not writable: {bkp_root}")
        sys.exit(1)

    free_gb = shutil.disk_usage(bkp_root).free // (1024**3)
    if free_gb < min_free_gb:
        log(f"Not enough free space on {bkp_root}: {free_gb}G available, need {min_free_gb}G")
        sys.exit(1)

    os.makedirs(bkp_folder, exist_ok=True)
    os.makedirs(root_dir, exist_ok=True)
    os.makedirs(home_dir, exist_ok=True)
    os.makedirs(log_dir, exist_ok=True)

    global LOG_FH
    with open(log_file, "a", encoding="utf-8", errors="replace") as log_fh:
        LOG_FH = log_fh
        try:
            log(f"Backup start: {datetime.datetime.now().isoformat()}")
            log(f"Starting full BKP to: {bkp_folder}")
            if command_exists("lsblk"):
                log_to_file("lsblk -f:")
                lsblk_out = subprocess.run(["lsblk", "-f"], text=True, capture_output=True).stdout
                log_to_file(lsblk_out.rstrip())
            rsync_ver = subprocess.run(
                ["rsync", "--version"], check=True, text=True, capture_output=True
            ).stdout.splitlines()[0]
            tar_ver = subprocess.run(
                ["tar", "--version"], check=True, text=True, capture_output=True
            ).stdout.splitlines()[0]
            log_to_file(f"rsync version: {rsync_ver}")
            log_to_file(f"tar version: {tar_ver}")

            if not command_exists("pigz"):
                log("pigz not found, installing...")
                if command_exists("pacman"):
                    if os.geteuid() != 0:
                        run(["sudo", "pacman", "-S", "--noconfirm", "pigz"], live_preview=True)
                    else:
                        run(["pacman", "-S", "--noconfirm", "pigz"], live_preview=True)
                else:
                    log("pacman not available; install pigz manually.")
                    sys.exit(1)
            else:
                log("pigz already installed, continuing...")

            if os.geteuid() == 0 and os.environ.get("SUDO_USER"):
                src_home = (
                    subprocess.run(
                        ["getent", "passwd", os.environ["SUDO_USER"]],
                        check=True,
                        text=True,
                        capture_output=True,
                    )
                    .stdout.split(":")[5]
                    .strip()
                )
            else:
                src_home = os.path.expanduser("~")

            luks_header_file = os.path.join(bkp_base, f"luks-header-{timestamp}.img")
            if is_block_device(luks_device):
                log(f"Backing up LUKS header of {luks_device} to: {luks_header_file}")
                run(
                    ["sudo", "cryptsetup", "luksHeaderBackup", luks_device, "--header-backup-file", luks_header_file],
                    live_preview=True,
                )
            else:
                log(f"Skipping LUKS header backup; device not found: {luks_device}")

            system_paths = [
                "/boot/grub/themes/lateralus",
                "/etc/default/grub",
                "/etc/mkinitcpio.conf",
                "/usr/share/plymouth/plymouthd.defaults",
                "/etc/samba/smb.conf",
                "/etc/samba/euclid",
                "/etc/ssh/sshd_config",
                "/usr/lib/sddm/sddm.conf.d/default.conf",
                "/etc/fstab",
            ]

            for src in system_paths:
                if not os.path.exists(src):
                    log(f"Skipping missing {src}")
                    continue
                log(f"Backing up {src}...")
                run(["sudo", "rsync", "-aR", src, root_dir], live_preview=True)

            log(f"Backing up {src_home}...")
            rsync_cmd = [
                "rsync",
                "-aAXP",
                "--exclude=.cache/",
                "--exclude=.var/app/",
                "--exclude=.subversion/",
                "--exclude=.mozilla/",
                "--exclude=.local/share/fonts/",
                "--exclude=.vscode-oss/",
                "--exclude=Trash/",
                f"{src_home}/",
                os.path.join(home_dir, os.path.basename(src_home)) + "/",
            ]
            run(rsync_cmd, live_preview=True)

            log(f"Compressing full backup to: {archive_file}")
            run(["tar", "-I", "pigz", "-cf", archive_file, "-C", bkp_base, timestamp], live_preview=True)
            log("Archive checksum written to log.")
            log_to_file("Archive checksum:")
            log_to_file(sha256_file(archive_file))
            log("Verifying archive contents...")
            run(["tar", "-tf", archive_file], live_preview=True, show_output=False)

            log("Backed up system paths written to log.")
            log_to_file("Backed up system paths:")
            for src in system_paths:
                log_to_file(f"  {src}")
            log(f"Backed up user home: {src_home}")

            log("Bully complete.")
            log(f"Uncompressed folder: {bkp_folder}")
            log(f"Compressed archive : {archive_file}")
            log(f"LUKS header backup:  {luks_header_file}")
            log(f"Log file:            {log_file}")
            log(f"Backup end: {datetime.datetime.now().isoformat()}")

            prune_old(os.path.join(bkp_base, "full-backup-*.tar.gz"), keep=3)
            prune_old(
                os.path.join(bkp_base, "[0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]"),
                keep=3,
            )
            if command_exists("notify-send"):
                run(["notify-send", "Backup complete", f"Full backup saved to {bkp_folder}"], check=False)
        except Exception:
            if os.path.exists(archive_file):
                log(f"Removing partial archive: {archive_file}")
                try:
                    os.remove(archive_file)
                except OSError:
                    pass
            if command_exists("notify-send"):
                run(["notify-send", "Backup failed", "Full backup did not complete"], check=False)
            log("Backup failed.")
            raise


if __name__ == "__main__":
    lock_file = None
    try:
        user = getpass.getuser()
        usb_label = os.environ.get("BKP_USB_LABEL", "Lateralus")
        bkp_root = f"/run/media/{user}/{usb_label}"
        bkp_base = os.path.join(bkp_root, "BKP")
        log_dir = os.path.join(bkp_base, "logs")
        os.makedirs(log_dir, exist_ok=True)
        lock_file = os.path.join(log_dir, "backup-full-ssd.lock")
        fd = os.open(lock_file, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.close(fd)
        main()
    finally:
        if lock_file and os.path.exists(lock_file):
            os.remove(lock_file)
