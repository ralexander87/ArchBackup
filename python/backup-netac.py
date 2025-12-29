#!/usr/bin/env python3
import datetime
import getpass
import os
import shutil
import subprocess
import sys


LOG_FH = None


def log(msg):
    print(msg)
    if LOG_FH:
        LOG_FH.write(msg + "\n")
        LOG_FH.flush()


def run(cmd, check=True):
    return subprocess.run(cmd, check=check)


def command_exists(cmd):
    return shutil.which(cmd) is not None


def main():
    print("-" * 92)
    os.umask(0o077)

    user = os.environ.get("USER") or getpass.getuser()
    usb_label = os.environ.get("BKP_USB_LABEL", "netac")
    min_free_gb = int(os.environ.get("BKP_MIN_FREE_GB", "20"))
    luks_device = os.environ.get("BKP_LUKS_DEVICE", "/dev/nvme0n1p2")
    usb = f"/run/media/{user}/{usb_label}"
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

    if not command_exists("mountpoint"):
        print("Missing required command: mountpoint")
        sys.exit(1)
    if subprocess.run(["mountpoint", "-q", usb]).returncode != 0:
        print(f"ERROR: {usb} is not a mountpoint. Is the USB plugged in and mounted?")
        sys.exit(1)

    for cmd in ["rsync", "sudo", "cryptsetup"]:
        if not command_exists(cmd):
            print(f"Missing required command: {cmd}")
            sys.exit(1)

    os.makedirs(os.path.join(usb, "home"), exist_ok=True)
    os.makedirs(os.path.join(usb, "dots"), exist_ok=True)
    os.makedirs(os.path.join(srv, "grub"), exist_ok=True)
    os.makedirs(os.path.join(srv, "ssh"), exist_ok=True)
    os.makedirs(os.path.join(srv, "samba"), exist_ok=True)
    log_dir = os.path.join(usb, "logs")
    os.makedirs(log_dir, exist_ok=True)
    log_path = os.path.join(
        log_dir, f"backup-usb-{datetime.datetime.now().strftime('%Y%m%d-%H%M%S')}.log"
    )
    global LOG_FH
    LOG_FH = open(log_path, "a", encoding="utf-8", errors="replace")
    try:
        log(f"Starting backup to: {usb}")

        free_gb = shutil.disk_usage(usb).free // (1024**3)
        if free_gb < min_free_gb:
            log(f"Not enough free space on {usb}: {free_gb}G available, need {min_free_gb}G")
            sys.exit(1)

        timestamp = datetime.datetime.now().strftime("%j-%Y-%H%M")
        luks_header_file = os.path.join(usb, f"luks-header-{timestamp}.img")

        if os.path.exists(luks_device):
            log(f"Backing up LUKS header of {luks_device} to: {luks_header_file}")
            run(["sudo", "cryptsetup", "luksHeaderBackup", luks_device, "--header-backup-file", luks_header_file])
        else:
            log(f"Skipping LUKS header backup; device not found: {luks_device}")

        for d in dirs:
            src = os.path.join(os.path.expanduser("~"), d)
            if not os.path.exists(src):
                log(f"Skipping missing {src}")
                continue
            run(["rsync", "-Parh", src, os.path.join(usb, "home")])

        if os.path.isdir(dots):
            run(["rsync", "-Parh", dots, os.path.join(usb, "dots")])
        else:
            log(f"Skipping missing DOTS path: {dots}")

        ssh_dir = os.path.expanduser("~/.ssh")
        if os.path.isdir(ssh_dir):
            run(["rsync", "-Parh", "--exclude", "agent/", f"{ssh_dir}/", os.path.join(srv, "ssh", ".ssh") + "/"])
        else:
            log(f"Skipping missing {ssh_dir}")

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
            # /etc/fstab is backup-only (not restored)
            "/etc/fstab": os.path.join(srv, "fstab"),
        }

        for src, dest in system_paths.items():
            if not os.path.exists(src):
                log(f"Skipping missing {src}")
                continue
            log(f"Backing up {src}...")
            run(["sudo", "rsync", "-a", src, dest])

        log("Backup done.")
    finally:
        if LOG_FH:
            LOG_FH.close()


if __name__ == "__main__":
    main()
