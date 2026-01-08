#!/usr/bin/env python3
import datetime
import getpass
import os
import shutil
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


def run(cmd, check=True, live_preview=False, show_output=True):
    if QUIET:
        rc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, text=True).wait()
    else:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in proc.stdout:
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


def run_rsync_allow_partial(cmd, live_preview=False):
    rc = run(cmd, check=False, live_preview=live_preview)
    if rc not in (0, 23, 24):
        raise subprocess.CalledProcessError(rc, cmd)
    if rc in (23, 24):
        err("[!] rsync completed with partial transfer (code 23/24). Continuing.")
    return rc


def main():
    status("-" * 92)

    ts = datetime.datetime.now().strftime("%j-%Y-%H%M")
    bkp_base = "/home/ralexander/Shared/ArchBKP"
    create_archive = os.environ.get("BKP_CREATE_ARCHIVE", "n").strip()

    bkp_folder = os.path.join(bkp_base, ts)
    bkp_tar = os.path.join(bkp_base, f"{ts}.tar.gz")
    root_dir = os.path.join(bkp_folder, "root")
    home_dir = os.path.join(bkp_folder, "home")
    user = getpass.getuser()
    os.makedirs(bkp_base, exist_ok=True)
    os.makedirs(bkp_folder, exist_ok=True)
    os.makedirs(root_dir, exist_ok=True)
    os.makedirs(home_dir, exist_ok=True)

    try:
        status(f"Backup start: {datetime.datetime.now().isoformat()}")
        status(f"Target: {bkp_base}")

        for cmd in ["rsync", "tar", "sudo"]:
            require_command(cmd)

        if not command_exists("pigz"):
            if command_exists("pacman"):
                if os.geteuid() != 0:
                    run(["sudo", "pacman", "-S", "--noconfirm", "pigz"], live_preview=True)
                else:
                    run(["pacman", "-S", "--noconfirm", "pigz"], live_preview=True)
            else:
                err("pacman not available; install pigz manually.")
                sys.exit(1)

        if not os.access(bkp_base, os.W_OK):
            err(f"Backup base not writable: {bkp_base}")
            sys.exit(1)

        progress("Pre-flight checks")

        system_items = [
            ("/boot/grub/themes/lateralus", root_dir),
            ("/etc/mkinitcpio.conf", os.path.join(root_dir, "mkinitcpio.conf")),
            ("/etc/default/grub", os.path.join(root_dir, "grub")),
            ("/usr/share/plymouth/plymouthd.defaults", os.path.join(root_dir, "plymouthd.defaults")),
            ("/etc/samba/smb.conf", os.path.join(root_dir, "smb.conf")),
            ("/etc/samba/euclid", os.path.join(root_dir, "euclid")),
            ("/etc/ssh/sshd_config", os.path.join(root_dir, "sshd_config")),
            ("/usr/lib/sddm/sddm.conf.d/default.conf", os.path.join(root_dir, "default.conf")),
            ("/etc/fstab", os.path.join(root_dir, "fstab")),
        ]

        progress("System files")
        for src, dest in system_items:
            if not os.path.exists(src):
                continue
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            run_rsync_allow_partial(
                ["sudo", "rsync", "-a", "--quiet", f"--chown={user}:{user}", src, dest],
                live_preview=True,
            )

        user_paths = [
            "Documents",
            "Obsidian",
            "Working",
            "Code",
            ".icons",
            ".themes",
            ".config",
            ".zshrc",
            ".zsh_history",
            ".mydotfiles",
            ".gitconfig",
        ]

        rsync_opts = ["-a", "--human-readable", "--partial", "--partial-dir=.rsync-partial", "--quiet"]
        excludes = [
            ".cache/",
            ".var/app/",
            ".subversion/",
            ".mozilla/",
            ".local/share/fonts/",
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
            ".config/rambox/",
            ".local/share/fonts/NerdFonts/",
        ]
        exclude_args = [f"--exclude={pattern}" for pattern in excludes]

        progress("User files")
        for path in user_paths:
            src = os.path.join(os.path.expanduser("~"), path)
            if not os.path.exists(src):
                continue
            run_rsync_allow_partial(["rsync", *rsync_opts, *exclude_args, src, home_dir], live_preview=True)

        ssh_dir = os.path.join(os.path.expanduser("~"), ".ssh")
        progress("SSH keys")
        if os.path.isdir(ssh_dir):
            run_rsync_allow_partial(
                ["rsync", *rsync_opts, "--exclude=agent/", f"{ssh_dir}/", os.path.join(home_dir, ".ssh/")],
                live_preview=True,
            )

        progress("Archive")
        if create_archive.lower() == "y":
            run(["tar", "--ignore-failed-read", "-I", "pigz", "-cf", bkp_tar, "-C", bkp_base, ts], live_preview=True)
            archive_status = bkp_tar
        else:
            archive_status = "skipped"

        status("Backup done.")
        status(f"Target: {bkp_base}")
        status(f"Archive: {archive_status}")
    except Exception:
        if os.path.exists(bkp_tar):
            try:
                os.remove(bkp_tar)
            except OSError:
                pass
        err("Backup failed.")
        raise


if __name__ == "__main__":
    main()
