#!/usr/bin/env python3
import datetime
import getpass
import glob
import hashlib
import os
import shlex
import shutil
import stat
import subprocess
import sys


LOG_FH = None
QUIET = True
TOTAL_STEPS = 5
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


def run(cmd, check=True, live_preview=False, show_output=True):
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in proc.stdout:
        if LOG_FH:
            LOG_FH.write(line)
            LOG_FH.flush()
        if live_preview and not QUIET:
            preview = line.rstrip()
            if preview:
                width = shutil.get_terminal_size((80, 20)).columns
                if len(preview) >= width:
                    preview = preview[: width - 1]
                sys.stdout.write("\r" + preview)
                sys.stdout.flush()
        elif show_output and not QUIET:
            sys.stdout.write(line)
            sys.stdout.flush()
    rc = proc.wait()
    if live_preview and not QUIET:
        sys.stdout.write("\n")
        sys.stdout.flush()
    if check and rc != 0:
        raise subprocess.CalledProcessError(rc, cmd)
    return rc


def command_exists(cmd):
    return shutil.which(cmd) is not None


def require_command(cmd):
    if not command_exists(cmd):
        err(f"Missing required command: {cmd}")
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


def list_mounts():
    user = os.environ.get("SUDO_USER") or os.environ.get("USER") or getpass.getuser()
    proc = subprocess.run(
        ["lsblk", "-P", "-o", "NAME,MOUNTPOINT,TRAN,SIZE,MODEL,TYPE"],
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        err("Failed to list devices with lsblk.")
        sys.exit(1)
    mounts = []
    for line in proc.stdout.splitlines():
        info = {}
        for token in shlex.split(line):
            key, val = token.split("=", 1)
            info[key] = val
        if info.get("TYPE") != "part":
            continue
        mountpoint = info.get("MOUNTPOINT") or ""
        if not mountpoint:
            continue
        if not (
            mountpoint.startswith(f"/run/media/{user}/")
            or mountpoint.startswith(f"/media/{user}/")
        ):
            continue
        mounts.append(info)
    return mounts


def select_target():
    mounts = list_mounts()
    if not mounts:
        err("No mounted external devices found under /run/media or /media.")
        sys.exit(1)
    print("Select target device:")
    for i, m in enumerate(mounts, 1):
        desc = f"{m['MOUNTPOINT']} ({m.get('NAME','?')}, {m.get('SIZE','?')}, {m.get('TRAN','?')}, {m.get('MODEL','unknown')})"
        print(f"  {i}) {desc}")
    choice = input("Enter number: ").strip()
    if not choice.isdigit() or not (1 <= int(choice) <= len(mounts)):
        err("Invalid selection.")
        sys.exit(1)
    mountpoint = mounts[int(choice) - 1]["MOUNTPOINT"]
    return mountpoint


def main():
    status("-" * 92)

    ts = datetime.datetime.now().strftime("%j-%Y-%H%M")
    mountpoint = select_target()

    create_dir = input(f"Create timestamped directory under {mountpoint}? [y/N]: ").strip()
    if create_dir.lower() == "y":
        base_dir = os.path.join(mountpoint, ts)
        os.makedirs(base_dir, exist_ok=True)
        created = "yes"
    else:
        base_dir = mountpoint
        created = "no"

    print(f"Target: {base_dir}")
    confirm = input("Proceed with backup? [y/N]: ").strip()
    if confirm.lower() != "y":
        status("Cancelled.")
        return

    user = getpass.getuser()
    min_free_gb = int(os.environ.get("BKP_MIN_FREE_GB", "20"))
    luks_device = os.environ.get("BKP_LUKS_DEVICE", "/dev/nvme0n1p2")

    bkp_base = base_dir
    bkp_folder = os.path.join(bkp_base, ts)
    root_dir = os.path.join(bkp_folder, "root")
    home_dir = os.path.join(bkp_folder, "home")
    log_dir = os.path.join(bkp_base, "logs")
    log_file = os.path.join(log_dir, f"backup-full-ssd-{ts}.log")
    archive_file = os.path.join(bkp_base, f"full-backup-{ts}.tar.gz")

    if not command_exists("mountpoint") or subprocess.run(
        ["mountpoint", "-q", mountpoint]
    ).returncode != 0:
        err(f"ERROR: {mountpoint} is not a mountpoint.")
        sys.exit(1)

    for cmd in ["rsync", "tar", "sudo", "cryptsetup"]:
        require_command(cmd)

    if not os.access(base_dir, os.W_OK):
        err(f"Backup root not writable: {base_dir}")
        sys.exit(1)

    free_gb = shutil.disk_usage(mountpoint).free // (1024**3)
    if free_gb < min_free_gb:
        err(f"Not enough free space on {mountpoint}: {free_gb}G available, need {min_free_gb}G")
        sys.exit(1)

    os.makedirs(bkp_folder, exist_ok=True)
    os.makedirs(root_dir, exist_ok=True)
    os.makedirs(home_dir, exist_ok=True)
    os.makedirs(log_dir, exist_ok=True)

    global LOG_FH
    with open(log_file, "a", encoding="utf-8", errors="replace") as log_fh:
        LOG_FH = log_fh
        try:
            status(f"Backup start: {datetime.datetime.now().isoformat()}")
            status(f"Log: {log_file}")
            status(f"Target: {base_dir} (new dir: {created})")
            progress("Pre-flight checks")
            log(f"Starting full BKP to: {bkp_folder}")

            if not command_exists("pigz"):
                progress("pigz install")
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

            luks_header_file = os.path.join(bkp_base, f"luks-header-{ts}.img")
            progress("LUKS header (if present)")
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

            progress("System files")
            for src in system_paths:
                if not os.path.exists(src):
                    log(f"Skipping missing {src}")
                    continue
                log(f"Backing up {src}...")
                run(["sudo", "rsync", "-a", "--quiet", src, root_dir], live_preview=True)

            progress("User home")
            log(f"Backing up {src_home}...")
            rsync_cmd = [
                "rsync",
                "-aAX",
                "--quiet",
                "--partial",
                "--partial-dir=.rsync-partial",
                "--exclude=.cache/",
                "--exclude=.var/app/",
                "--exclude=.subversion/",
                "--exclude=.mozilla/",
                "--exclude=.local/share/fonts/",
                "--exclude=.vscode-oss/",
                "--exclude=Trash/",
                f"{src_home}/",
                f"{home_dir}/",
            ]
            rsync_rc = run(rsync_cmd, live_preview=True, check=False)
            if rsync_rc not in (0, 23, 24):
                raise subprocess.CalledProcessError(rsync_rc, rsync_cmd)
            if rsync_rc in (23, 24):
                log("[!] rsync completed with partial transfer (code 23/24). Continuing.")

            progress("Archive")
            log(f"Compressing full backup to: {archive_file}")
            run(
                ["tar", "--ignore-failed-read", "-I", "pigz", "-cf", archive_file, "-C", bkp_base, ts],
                live_preview=True,
            )
            log("Archive checksum:")
            log(sha256_file(archive_file))

            status("Backup done.")
            status(f"Target: {base_dir}")
            status(f"Archive: {archive_file}")
            status(f"Log: {log_file}")

            prune_old(os.path.join(bkp_base, "full-backup-*.tar.gz"), keep=3)
            prune_old(os.path.join(bkp_base, "[0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]"), keep=3)
        except Exception:
            if os.path.exists(archive_file):
                log(f"Removing partial archive: {archive_file}")
                try:
                    os.remove(archive_file)
                except OSError:
                    pass
            err("Backup failed.")
            raise


if __name__ == "__main__":
    lock_file = None
    try:
        user = getpass.getuser()
        lock_dir = os.path.join("/tmp", "backup-full-ssd-v3")
        os.makedirs(lock_dir, exist_ok=True)
        lock_file = os.path.join(lock_dir, "backup-full-ssd.lock")
        fd = os.open(lock_file, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.close(fd)
        main()
    finally:
        if lock_file and os.path.exists(lock_file):
            os.remove(lock_file)
