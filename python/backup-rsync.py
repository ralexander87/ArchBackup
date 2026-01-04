#!/usr/bin/env python3
import datetime
import getpass
import os
import shutil
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


def run_rsync_allow_partial(cmd, live_preview=False):
    rc = run(cmd, check=False, live_preview=live_preview)
    if rc not in (0, 23, 24):
        raise subprocess.CalledProcessError(rc, cmd)
    if rc in (23, 24):
        log("[!] rsync completed with partial transfer (code 23/24). Continuing.")
    return rc


def main():
    status("-" * 92)

    ts = datetime.datetime.now().strftime("%j-%Y-%H%M")
    bkp_base = "/home/ralexander/Shared/ArchBKP"
    create_archive = input("Create compressed archive? [y/N]: ").strip()

    bkp_folder = os.path.join(bkp_base, ts)
    bkp_tar = os.path.join(bkp_base, f"{ts}.tar.gz")
    log_file = os.path.join(bkp_base, f"backup-rsync-{ts}.log")
    root_dir = os.path.join(bkp_folder, "root")
    home_dir = os.path.join(bkp_folder, "home")
    user = getpass.getuser()

    os.makedirs(bkp_base, exist_ok=True)
    os.makedirs(bkp_folder, exist_ok=True)
    os.makedirs(root_dir, exist_ok=True)
    os.makedirs(home_dir, exist_ok=True)

    global LOG_FH
    with open(log_file, "a", encoding="utf-8", errors="replace") as log_fh:
        LOG_FH = log_fh
        try:
            status(f"Backup start: {datetime.datetime.now().isoformat()}")
            status(f"Log: {log_file}")
            status(f"Target: {bkp_base}")

            for cmd in ["rsync", "tar", "sudo"]:
                require_command(cmd)

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
                    log(f"Skipping missing {src}")
                    continue
                log(f"Backing up {src}...")
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                run(["sudo", "rsync", "-a", "--quiet", f"--chown={user}:{user}", src, dest], live_preview=True)

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

            progress("User files")
            for path in user_paths:
                src = os.path.join(os.path.expanduser("~"), path)
                if not os.path.exists(src):
                    log(f"Skipping missing {src}")
                    continue
                log(f"Backing up {src}...")
                run_rsync_allow_partial(["rsync", *rsync_opts, *exclude_args, src, home_dir], live_preview=True)

            ssh_dir = os.path.join(os.path.expanduser("~"), ".ssh")
            progress("SSH keys")
            if os.path.isdir(ssh_dir):
                log(f"Backing up {ssh_dir} (excluding agent/)...")
                run_rsync_allow_partial(
                    ["rsync", *rsync_opts, "--exclude=agent/", f"{ssh_dir}/", os.path.join(home_dir, ".ssh/")],
                    live_preview=True,
                )
            else:
                log(f"Skipping missing {ssh_dir}")

            progress("Archive")
            if create_archive.lower() == "y":
                log(f"Compressing backup to {bkp_tar} ...")
                run(["tar", "--ignore-failed-read", "-I", "pigz", "-cf", bkp_tar, "-C", bkp_base, ts], live_preview=True)
                archive_status = bkp_tar
            else:
                archive_status = "skipped"

            status("Backup done.")
            status(f"Target: {bkp_base}")
            status(f"Archive: {archive_status}")
            status(f"Log: {log_file}")
        except Exception:
            if os.path.exists(bkp_tar):
                log(f"Removing partial archive: {bkp_tar}")
                try:
                    os.remove(bkp_tar)
                except OSError:
                    pass
            err("Backup failed.")
            raise


if __name__ == "__main__":
    main()
