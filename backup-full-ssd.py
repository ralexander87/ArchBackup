#!/usr/bin/env python3
import atexit
import datetime
import getpass
import glob
import math
import os
import shlex
import shutil
import signal
import stat
import subprocess
import sys


QUIET = True
TOTAL_STEPS = 7
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
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
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


def run_with_input(cmd, input_text, check=True):
    if QUIET:
        proc = subprocess.run(
            cmd, input=input_text, text=True, stdout=subprocess.DEVNULL
        )
    else:
        proc = subprocess.run(cmd, input=input_text, text=True)
    if check and proc.returncode != 0:
        raise subprocess.CalledProcessError(proc.returncode, cmd)
    return proc.returncode


def run_quiet_with_input(cmd, input_text, check=True):
    proc = subprocess.run(
        cmd,
        input=input_text,
        text=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if check and proc.returncode != 0:
        raise subprocess.CalledProcessError(proc.returncode, cmd)
    return proc.returncode


def get_file_size(
    path, use_sudo=False, sudo_needs_pass=False, sudo_password=None
):
    if use_sudo:
        if sudo_needs_pass:
            proc = subprocess.run(
                ["sudo", "-S", "-k", "-p", "", "stat", "-c", "%s", path],
                input=f"{sudo_password}\n",
                text=True,
                capture_output=True,
            )
        else:
            proc = subprocess.run(
                ["sudo", "-n", "stat", "-c", "%s", path],
                text=True,
                capture_output=True,
            )
    else:
        proc = subprocess.run(
            ["stat", "-c", "%s", path],
            text=True,
            capture_output=True,
        )
    if proc.returncode != 0:
        return None
    try:
        return int(proc.stdout.strip())
    except ValueError:
        return None


def vc_is_mounted(
    mount_dir, use_sudo=False, sudo_needs_pass=False, sudo_password=None
):
    cmd = ["veracrypt", "--text", "--non-interactive", "-l"]
    if use_sudo:
        if sudo_needs_pass:
            proc = subprocess.run(
                ["sudo", "-S", "-k", "-p", "", *cmd],
                input=f"{sudo_password}\n",
                text=True,
                capture_output=True,
            )
        else:
            proc = subprocess.run(
                ["sudo", "-n", *cmd],
                text=True,
                capture_output=True,
            )
    else:
        proc = subprocess.run(cmd, text=True, capture_output=True)
    if proc.returncode != 0:
        return False
    return mount_dir in proc.stdout


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


def prune_old(path_glob, keep=3):
    items = [p for p in glob.glob(path_glob)]
    items.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    for old in items[keep:]:
        if os.path.isdir(old):
            shutil.rmtree(old)
        else:
            os.remove(old)


def run_rsync_allow_partial(cmd, live_preview=False):
    rc = run(cmd, check=False, live_preview=live_preview)
    if rc not in (0, 23, 24):
        raise subprocess.CalledProcessError(rc, cmd)
    if rc in (23, 24):
        err(
            "[!] rsync completed with partial transfer "
            "(code 23/24). Continuing."
        )
    return rc


def list_mounts():
    user = (
        os.environ.get("SUDO_USER")
        or os.environ.get("USER")
        or getpass.getuser()
    )
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
    user = (
        os.environ.get("SUDO_USER")
        or os.environ.get("USER")
        or getpass.getuser()
    )
    label = os.environ.get("BKP_USB_LABEL", "netac")
    preferred = f"/run/media/{user}/{label}"
    for m in mounts:
        if m.get("MOUNTPOINT") == preferred:
            return preferred
    print("Select target device:")
    for i, m in enumerate(mounts, 1):
        desc = (
            f"{m['MOUNTPOINT']} ("
            f"{m.get('NAME', '?')}, "
            f"{m.get('SIZE', '?')}, "
            f"{m.get('TRAN', '?')}, "
            f"{m.get('MODEL', 'unknown')})"
        )
        print(f"  {i}) {desc}")
    choice = input("Enter number: ").strip()
    if not choice.isdigit() or not (1 <= int(choice) <= len(mounts)):
        err("Invalid selection.")
        sys.exit(1)
    return mounts[int(choice) - 1]["MOUNTPOINT"]


def main():
    status("-" * 92)

    ts = datetime.datetime.now().strftime("%j-%Y-%H%M")
    mountpoint = select_target()

    base_dir = os.path.join(mountpoint, ts)
    os.makedirs(base_dir, exist_ok=True)
    created = "yes"

    print(f"Target: {base_dir}")

    encrypt_enabled = False
    vc_password = None
    sudo_password = None
    sudo_needs_pass = False
    use_sudo = os.geteuid() != 0
    encrypt_choice = (
        input("Create encrypted container for archive? [y/N]: ")
        .strip()
        .lower()
    )
    active_mount = {"path": None}

    def cleanup_mount():
        # Best-effort dismount to avoid leaving VeraCrypt mounted.
        mount_dir = active_mount.get("path")
        if not mount_dir:
            return
        if use_sudo and vc_is_mounted(
            mount_dir,
            use_sudo=use_sudo,
            sudo_needs_pass=sudo_needs_pass,
            sudo_password=sudo_password,
        ):
            if sudo_needs_pass:
                run_quiet_with_input(
                    [
                        "sudo",
                        "-S",
                        "-k",
                        "-p",
                        "",
                        "veracrypt",
                        "--text",
                        "--non-interactive",
                        "-d",
                        mount_dir,
                    ],
                    f"{sudo_password}\n",
                    check=False,
                )
                run_quiet_with_input(
                    [
                        "sudo",
                        "-S",
                        "-k",
                        "-p",
                        "",
                        "veracrypt",
                        "--text",
                        "--non-interactive",
                        "-d",
                        "--force",
                        mount_dir,
                    ],
                    f"{sudo_password}\n",
                    check=False,
                )
            else:
                run_quiet_with_input(
                    [
                        "sudo",
                        "-n",
                        "veracrypt",
                        "--text",
                        "--non-interactive",
                        "-d",
                        mount_dir,
                    ],
                    "",
                    check=False,
                )
                run_quiet_with_input(
                    [
                        "sudo",
                        "-n",
                        "veracrypt",
                        "--text",
                        "--non-interactive",
                        "-d",
                        "--force",
                        mount_dir,
                    ],
                    "",
                    check=False,
                )
        elif not use_sudo and vc_is_mounted(mount_dir):
            run_quiet_with_input(
                ["veracrypt", "--text", "--non-interactive", "-d", mount_dir],
                "",
                check=False,
            )
            run_quiet_with_input(
                [
                    "veracrypt",
                    "--text",
                    "--non-interactive",
                    "-d",
                    "--force",
                    mount_dir,
                ],
                "",
                check=False,
            )
        try:
            os.rmdir(mount_dir)
        except OSError:
            pass
        active_mount["path"] = None

    def handle_signal(signum, frame):
        cleanup_mount()
        raise SystemExit(1)

    atexit.register(cleanup_mount)
    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    if encrypt_choice == "y":
        # Gather encryption settings early to avoid blocking late in the run.
        encrypt_enabled = True
        if not command_exists("veracrypt"):
            install_choice = (
                input("VeraCrypt not found. Install now? [y/N]: ")
                .strip()
                .lower()
            )
            if install_choice == "y":
                if command_exists("pacman"):
                    if os.geteuid() != 0:
                        run(
                            [
                                "sudo",
                                "pacman",
                                "-S",
                                "--noconfirm",
                                "veracrypt",
                            ],
                            live_preview=True,
                        )
                    else:
                        run(
                            ["pacman", "-S", "--noconfirm", "veracrypt"],
                            live_preview=True,
                        )
                else:
                    err("pacman not available; install veracrypt manually.")
            else:
                err("Skipping encryption: VeraCrypt not installed.")
        if not command_exists("veracrypt"):
            err("Skipping encryption: VeraCrypt not installed.")
            encrypt_enabled = False
        else:
            if use_sudo:
                if (
                    subprocess.run(
                        ["sudo", "-n", "true"],
                        check=False,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    ).returncode
                    != 0
                ):
                    sudo_needs_pass = True
                    sudo_password = getpass.getpass(
                        "Sudo password (for VeraCrypt): "
                    )
                    if not sudo_password:
                        err("Empty sudo password. Skipping encryption.")
                        encrypt_enabled = False
            pw1 = getpass.getpass("VeraCrypt password: ")
            pw2 = getpass.getpass("Confirm password: ")
            if not pw1 or pw1 != pw2:
                err(
                    "Password mismatch or empty password. Skipping encryption."
                )
                encrypt_enabled = False
            else:
                vc_password = pw1

    min_free_gb = int(os.environ.get("BKP_MIN_FREE_GB", "20"))
    luks_device = os.environ.get("BKP_LUKS_DEVICE", "/dev/nvme0n1p2")

    bkp_base = base_dir
    bkp_folder = os.path.join(bkp_base, ts)
    root_dir = os.path.join(bkp_folder, "root")
    home_dir = os.path.join(bkp_folder, "home")
    archive_file = os.path.join(bkp_base, f"full-backup-{ts}.tar.gz")

    if (
        not command_exists("mountpoint")
        or subprocess.run(["mountpoint", "-q", mountpoint]).returncode != 0
    ):
        err(f"ERROR: {mountpoint} is not a mountpoint.")
        sys.exit(1)

    for cmd in ["rsync", "tar", "sudo", "cryptsetup"]:
        require_command(cmd)

    if not os.access(base_dir, os.W_OK):
        err(f"Backup root not writable: {base_dir}")
        sys.exit(1)

    free_gb = shutil.disk_usage(mountpoint).free // (1024**3)
    if free_gb < min_free_gb:
        err(
            f"Not enough free space on {mountpoint}: {free_gb}G available, "
            f"need {min_free_gb}G"
        )
        sys.exit(1)

    os.makedirs(bkp_folder, exist_ok=True)
    os.makedirs(root_dir, exist_ok=True)
    os.makedirs(home_dir, exist_ok=True)
    try:
        status(f"Backup start: {datetime.datetime.now().isoformat()}")
        status(f"Target: {base_dir} (new dir: {created})")
        progress("Pre-flight checks")

        progress("pigz")
        if not command_exists("pigz"):
            if command_exists("pacman"):
                if os.geteuid() != 0:
                    run(
                        ["sudo", "pacman", "-S", "--noconfirm", "pigz"],
                        live_preview=True,
                    )
                else:
                    run(
                        ["pacman", "-S", "--noconfirm", "pigz"],
                        live_preview=True,
                    )
            else:
                err("pacman not available; install pigz manually.")
                sys.exit(1)

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
            run(
                [
                    "sudo",
                    "cryptsetup",
                    "luksHeaderBackup",
                    luks_device,
                    "--header-backup-file",
                    luks_header_file,
                ],
                live_preview=True,
            )

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
                continue
            run_rsync_allow_partial(
                ["sudo", "rsync", "-a", "--quiet", src, root_dir],
                live_preview=True,
            )

        progress("User home")
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
            "--exclude=.local/share/fonts/NerdFonts/",
            "--exclude=.vscode-oss/",
            "--exclude=Trash/",
            "--exclude=.config/*/Cache/",
            "--exclude=.config/*/cache/",
            "--exclude=.config/*/Code Cache/",
            "--exclude=.config/*/GPUCache/",
            "--exclude=.config/*/CachedData/",
            "--exclude=.config/*/CacheStorage/",
            "--exclude=.config/*/Service Worker/",
            "--exclude=.config/*/IndexedDB/",
            "--exclude=.config/*/Local Storage/",
            "--exclude=.config/rambox/",
            "--exclude=.rustup/",
            "--exclude=Shared/ArchBKP/",
            "--exclude=.ssh/agent/",
            f"{src_home}/",
            f"{home_dir}/",
        ]
        rsync_rc = run(rsync_cmd, live_preview=True, check=False)
        if rsync_rc not in (0, 23, 24):
            raise subprocess.CalledProcessError(rsync_rc, rsync_cmd)
        if rsync_rc in (23, 24):
            err(
                "[!] rsync completed with partial transfer "
                "(code 23/24). Continuing."
            )

        progress("Archive")
        run(
            [
                "tar",
                "--ignore-failed-read",
                "-I",
                "pigz",
                "-cf",
                archive_file,
                "-C",
                bkp_base,
                ts,
            ],
            live_preview=True,
        )
        status("Backup done.")
        status(f"Target: {base_dir}")
        status(f"Archive: {archive_file}")

        progress("Encrypt archive (optional)")
        if encrypt_enabled:
            if not os.path.isfile(archive_file):
                err(f"Archive not found: {archive_file}")
                sys.exit(1)

            container_file = os.path.join(bkp_base, f"full-backup-{ts}.hc")
            archive_bytes = os.path.getsize(archive_file)
            pad_pct = float(os.environ.get("BKP_VC_PAD_PCT", "5"))
            pad_mb = int(os.environ.get("BKP_VC_PAD_MB", "200"))
            if pad_pct < 0:
                pad_pct = 0
            if pad_mb < 0:
                pad_mb = 0
            size_bytes = int(archive_bytes * (1 + pad_pct / 100.0)) + (
                pad_mb * 1024 * 1024
            )
            size_mb = max(1, int(math.ceil(size_bytes / (1024 * 1024))))
            mount_dir = os.path.join("/tmp", f"vc-{ts}")
            os.makedirs(mount_dir, exist_ok=True)

            try:
                create_cmd = [
                    "veracrypt",
                    "--text",
                    "--non-interactive",
                    "--stdin",
                    "--create",
                    container_file,
                    "--size",
                    f"{size_mb}M",
                    "--hash",
                    "SHA-512",
                    "--encryption",
                    "AES",
                    "--filesystem",
                    "ext4",
                    "--pim",
                    "0",
                    "--keyfiles",
                    "",
                ]
                mount_cmd = [
                    "veracrypt",
                    "--text",
                    "--non-interactive",
                    "--stdin",
                    "--mount",
                    container_file,
                    mount_dir,
                    "--pim",
                    "0",
                    "--keyfiles",
                    "",
                    "--protect-hidden",
                    "no",
                ]
                if use_sudo:
                    if sudo_needs_pass:
                        create_cmd = [
                            "sudo",
                            "-S",
                            "-k",
                            "-p",
                            "",
                        ] + create_cmd
                        mount_cmd = ["sudo", "-S", "-k", "-p", ""] + mount_cmd
                        input_text = f"{sudo_password}\n{vc_password}\n"
                    else:
                        create_cmd = ["sudo", "-n"] + create_cmd
                        mount_cmd = ["sudo", "-n"] + mount_cmd
                        input_text = f"{vc_password}\n"
                else:
                    input_text = f"{vc_password}\n"

                # Create+mount VeraCrypt container, then copy archive into it.
                run_with_input(create_cmd, input_text)
                run_with_input(mount_cmd, input_text)
                active_mount["path"] = mount_dir
                if use_sudo:
                    if sudo_needs_pass:
                        run_with_input(
                            [
                                "sudo",
                                "-S",
                                "-k",
                                "-p",
                                "",
                                "rsync",
                                "-a",
                                "--quiet",
                                archive_file,
                                mount_dir,
                            ],
                            f"{sudo_password}\n",
                        )
                    else:
                        run_with_input(
                            [
                                "sudo",
                                "-n",
                                "rsync",
                                "-a",
                                "--quiet",
                                archive_file,
                                mount_dir,
                            ],
                            "",
                        )
                else:
                    run(["rsync", "-a", "--quiet", archive_file, mount_dir])

                dest_file = os.path.join(
                    mount_dir, os.path.basename(archive_file)
                )
                src_size = os.path.getsize(archive_file)
                dest_size = get_file_size(
                    dest_file,
                    use_sudo=use_sudo,
                    sudo_needs_pass=sudo_needs_pass,
                    sudo_password=sudo_password,
                )
                if dest_size is None or dest_size != src_size:
                    err("Encrypted archive verification failed.")
                    raise RuntimeError(
                        "Encrypted archive verification failed."
                    )

                delete_choice = (
                    os.environ.get("BKP_DELETE_PLAINTEXT", "").strip().lower()
                )
                if delete_choice not in ("y", "n", ""):
                    err("Invalid BKP_DELETE_PLAINTEXT value; use 'y' or 'n'.")
                    delete_choice = ""
                if not delete_choice:
                    delete_choice = (
                        input(
                            "Delete plaintext archive after encryption? "
                            "[y/N]: "
                        )
                        .strip()
                        .lower()
                    )
                if delete_choice == "y":
                    try:
                        if command_exists("shred"):
                            run(
                                ["shred", "-u", "-z", "-n", "1", archive_file],
                                live_preview=True,
                            )
                        else:
                            os.remove(archive_file)
                        status(f"Plaintext archive deleted: {archive_file}")
                    except OSError as exc:
                        err(f"Failed to delete plaintext archive: {exc}")

                status(f"Encrypted container: {container_file}")
            finally:
                cleanup_mount()
        else:
            status("Encrypted container: skipped")

        prune_old(os.path.join(bkp_base, "full-backup-*.tar.gz"), keep=3)
        prune_old(
            os.path.join(
                bkp_base,
                "[0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]",
            ),
            keep=3,
        )
    except Exception:
        if os.path.exists(archive_file):
            try:
                os.remove(archive_file)
            except OSError:
                pass
        err("Backup failed.")
        raise


if __name__ == "__main__":
    lock_file = None
    try:
        lock_dir = os.path.join("/tmp", "backup-full-ssd-v3")
        os.makedirs(lock_dir, exist_ok=True)
        lock_file = os.path.join(lock_dir, "backup-full-ssd.lock")
        fd = os.open(lock_file, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.close(fd)
        main()
    finally:
        if lock_file and os.path.exists(lock_file):
            os.remove(lock_file)
