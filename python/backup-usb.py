#!/usr/bin/env python3
import datetime
import getpass
import glob
import os
import shlex
import shutil
import stat
import subprocess
import sys


QUIET = True
TOTAL_STEPS = 5
STEP = 0


def status(msg):
    print(msg)


def progress(msg):
    global STEP
    STEP += 1
    status(f"[{STEP}/{TOTAL_STEPS}] {msg}")


def err(msg):
    print(msg, file=sys.stderr)


def summary(msg):
    status(msg)


def run(cmd, check=True):
    if QUIET:
        return subprocess.run(cmd, check=check, stdout=subprocess.DEVNULL)
    return subprocess.run(cmd, check=check)


def run_rsync_allow_partial(cmd):
    rc = run(cmd, check=False).returncode
    if rc not in (0, 23, 24):
        raise subprocess.CalledProcessError(rc, cmd)
    if rc in (23, 24):
        err("[!] rsync completed with partial transfer (code 23/24). Continuing.")
    return rc


def command_exists(cmd):
    return shutil.which(cmd) is not None


def make_executable(path):
    try:
        mode = os.stat(path).st_mode
        os.chmod(path, mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    except OSError:
        pass


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
    preferred = "/run/media/ralexander/netac"
    for m in mounts:
        if m.get("MOUNTPOINT") == preferred:
            return preferred
    print("Select target device:")
    for i, m in enumerate(mounts, 1):
        desc = f"{m['MOUNTPOINT']} ({m.get('NAME','?')}, {m.get('SIZE','?')}, {m.get('TRAN','?')}, {m.get('MODEL','unknown')})"
        print(f"  {i}) {desc}")
    choice = input("Enter number: ").strip()
    if not choice.isdigit() or not (1 <= int(choice) <= len(mounts)):
        err("Invalid selection.")
        sys.exit(1)
    return mounts[int(choice) - 1]["MOUNTPOINT"]


def main():
    status("-" * 92)
    os.umask(0o077)

    mountpoint = select_target()

    base_root = os.path.join(mountpoint, "START")
    os.makedirs(base_root, exist_ok=True)
    for script in glob.glob("/home/ralexander/Code/PY/PY/restore-*"):
        if os.path.isfile(script):
            shutil.copy2(script, base_root)

    usb = base_root

    status(f"Target: {usb}")
    min_free_gb = int(os.environ.get("BKP_MIN_FREE_GB", "20"))
    luks_device = os.environ.get("BKP_LUKS_DEVICE", "/dev/nvme0n1p2")
    srv = os.path.join(usb, "Srv")
    dots = os.path.expanduser("~/.mydotfiles/com.ml4w.dotfiles.stable/.config/")
    dirs = [
        "Documents",
        "Pictures",
        "Obsidian",
        "Working",
        "Shared",
        "VM",
        "Videos",
        "Code",
        ".icons",
        ".themes",
        ".zsh_history",
        ".zshrc",
        ".gitconfig",
    ]
    excludes = [
        ".cache/",
        ".var/app/",
        ".subversion/",
        ".mozilla/",
        ".local/share/fonts/",
        ".local/share/fonts/NerdFonts/",
        ".vscode-oss/",
        "Trash/",
        ".config/*/Cache/",
        ".config/*/cache/",
        ".config/*/Code Cache/",
        ".config/*/GPUCache/",
        ".config/*/CachedData/",
        ".config/*/CacheStorage/",
        ".config/*/Service Worker/",
        ".config/*/IndexedDB/",
        ".config/*/Local Storage/",
    ]
    exclude_args = [f"--exclude={pattern}" for pattern in excludes]

    if not command_exists("mountpoint"):
        err("Missing required command: mountpoint")
        sys.exit(1)
    if subprocess.run(["mountpoint", "-q", mountpoint]).returncode != 0:
        err(f"ERROR: {mountpoint} is not a mountpoint.")
        sys.exit(1)

    for cmd in ["rsync", "sudo", "cryptsetup"]:
        if not command_exists(cmd):
            err(f"Missing required command: {cmd}")
            sys.exit(1)

    if not os.access(base_root, os.W_OK):
        err(f"Backup root not writable: {base_root}")
        sys.exit(1)

    os.makedirs(os.path.join(usb, "home"), exist_ok=True)
    os.makedirs(os.path.join(usb, "dots"), exist_ok=True)
    os.makedirs(os.path.join(srv, "grub"), exist_ok=True)
    os.makedirs(os.path.join(srv, "ssh"), exist_ok=True)
    os.makedirs(os.path.join(srv, "samba"), exist_ok=True)
    for script in glob.glob("*.sh"):
        make_executable(script)

    try:
        status(f"Backup start: {datetime.datetime.now().isoformat()}")
        status(f"Target: {usb}")
        progress("Pre-flight checks")

        free_gb = shutil.disk_usage(mountpoint).free // (1024**3)
        if free_gb < min_free_gb:
            err(f"Not enough free space on {mountpoint}: {free_gb}G available, need {min_free_gb}G")
            sys.exit(1)

        luks_header_file = os.path.join(usb, f"luks-header-{datetime.datetime.now().strftime('%j-%Y-%H%M')}.img")

        if os.path.exists(luks_device):
            run(["sudo", "cryptsetup", "luksHeaderBackup", luks_device, "--header-backup-file", luks_header_file])
        else:
            pass

        progress("User files")
        for d in dirs:
            src = os.path.join(os.path.expanduser("~"), d)
            if not os.path.exists(src):
                continue
            run_rsync_allow_partial(
                [
                    "rsync",
                    "-arh",
                    "--quiet",
                    "--partial",
                    "--partial-dir=.rsync-partial",
                    *exclude_args,
                    src,
                    os.path.join(usb, "home"),
                ]
            )

        progress("Dotfiles and SSH")
        if os.path.isdir(dots):
            run_rsync_allow_partial(
                [
                    "rsync",
                    "-arh",
                    "--quiet",
                    "--partial",
                    "--partial-dir=.rsync-partial",
                    *exclude_args,
                    dots,
                    os.path.join(usb, "dots"),
                ]
            )
        else:
            pass

        ssh_dir = os.path.expanduser("~/.ssh")
        if os.path.isdir(ssh_dir):
            run_rsync_allow_partial(
                [
                    "rsync",
                    "-arh",
                    "--quiet",
                    "--partial",
                    "--partial-dir=.rsync-partial",
                    "--exclude",
                    "agent/",
                    f"{ssh_dir}/",
                    os.path.join(srv, "ssh", ".ssh") + "/",
                ]
            )
        else:
            pass

        progress("Extras")
        cursor_dir = os.path.expanduser("~/.local/share/icons/LyraX-cursors")
        if os.path.isdir(cursor_dir):
            run(["cp", "-r", cursor_dir, os.path.join(usb, "home")])

        hyprctl = os.path.expanduser("~/.config/com.ml4w.hyprlandsettings/hyprctl.json")
        if os.path.isfile(hyprctl):
            run(["cp", hyprctl, os.path.join(usb, "dots")])

        uca = os.path.expanduser("~/.config/Thunar/uca.xml")
        if os.path.isfile(uca):
            run(["cp", uca, os.path.join(usb, "dots")])

        system_paths = {
            "/boot/grub/themes/lateralus": os.path.join(srv, "grub") + "/",
            "/etc/default/grub": os.path.join(srv, "grub") + "/",
            "/etc/mkinitcpio.conf": os.path.join(srv, "mkinitcpio.conf"),
            "/usr/share/plymouth/plymouthd.defaults": os.path.join(srv, "plymouthd.defaults"),
            "/etc/samba/smb.conf": os.path.join(srv, "samba", "smb.conf"),
            "/etc/samba/euclid": os.path.join(srv, "samba", "euclid"),
            "/etc/ssh/sshd_config": os.path.join(srv, "ssh", "sshd_config"),
            "/etc/fstab": os.path.join(srv, "fstab"),
        }

        progress("System files")
        for src, dest in system_paths.items():
            if not os.path.exists(src):
                continue
            run_rsync_allow_partial(["sudo", "rsync", "-a", "--quiet", src, dest])

        summary("Backup done.")
        summary(f"Target: {usb}")
    finally:
        pass


if __name__ == "__main__":
    lock_file = None
    try:
        lock_dir = os.path.join("/tmp", "backup-usb-v3")
        os.makedirs(lock_dir, exist_ok=True)
        lock_file = os.path.join(lock_dir, "backup-usb.lock")
        fd = os.open(lock_file, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.close(fd)
        main()
    finally:
        if lock_file and os.path.exists(lock_file):
            os.remove(lock_file)
