#!/usr/bin/env python3
import datetime
import getpass
import os
import shutil
import subprocess
import sys


QUIET = True
TOTAL_STEPS = 3
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


def command_exists(cmd):
    return shutil.which(cmd) is not None


def ensure_root():
    if os.geteuid() != 0:
        script = os.path.abspath(sys.argv[0])
        os.execvp(
            "sudo", ["sudo", "-E", sys.executable, script] + sys.argv[1:]
        )


def replace_or_append(lines, key, value):
    prefix = f"{key}="
    replaced = False
    new_lines = []
    for line in lines:
        stripped = line.lstrip()
        if stripped.startswith("#"):
            check = stripped.lstrip("#").lstrip()
        else:
            check = stripped
        if check.startswith(prefix):
            new_lines.append(f'{key}="{value}"\n')
            replaced = True
        else:
            new_lines.append(line)
    if not replaced:
        new_lines.append(f'{key}="{value}"\n')
    return new_lines


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

    # Locate backup root and required GRUB theme files.
    user = (
        os.environ.get("SUDO_USER")
        or os.environ.get("USER")
        or getpass.getuser()
    )
    usb_label = os.environ.get("BKP_USB_LABEL", "netac")
    usb_mount = f"/run/media/{user}/{usb_label}"
    base_root = os.path.join(usb_mount, "START")
    if not command_exists("mountpoint"):
        err("Error: mountpoint not found.")
        sys.exit(1)
    if run(["mountpoint", "-q", usb_mount], check=False).returncode != 0:
        err(
            f"Error: {usb_mount} is not a mountpoint. "
            "Is the USB plugged in and mounted?"
        )
        sys.exit(1)
    # Find the backup root that contains Srv.
    backup_root = resolve_backup_root(base_root, ["Srv"])
    if not backup_root:
        err(f"Error: backup root not found under {base_root}")
        sys.exit(1)
    srv = os.path.join(backup_root, "Srv")
    theme = os.path.join(srv, "grub", "lateralus")
    grub_default = "/etc/default/grub"
    ts = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    backup = f"/etc/default/grub.bak.{ts}"
    backup_dir = f"/var/backups/restore-grub-{ts}"

    if not os.path.isfile(grub_default):
        err(f"Error: {grub_default} not found.")
        sys.exit(1)
    if not os.path.isdir(srv):
        err(f"Error: backup directory not found: {srv}")
        sys.exit(1)
    if not os.path.isdir(theme):
        err(f"Error: theme directory not found: {theme}")
        sys.exit(1)
    if not command_exists("grub-mkconfig"):
        err("Error: grub-mkconfig not found in PATH.")
        sys.exit(1)

    # Keep a backup of current settings and theme before changing GRUB.
    os.makedirs(backup_dir, exist_ok=True)
    try:
        status(f"Restore GRUB start: {datetime.datetime.now().isoformat()}")
        progress("Backup defaults")
        shutil.copy2(grub_default, backup)
        shutil.copy2(grub_default, os.path.join(backup_dir, "grub.default"))
        if os.path.isfile("/boot/grub/grub.cfg"):
            shutil.copy2(
                "/boot/grub/grub.cfg",
                os.path.join(backup_dir, "grub.cfg"),
            )

        os.makedirs("/boot/grub/themes", exist_ok=True)
        if os.path.isdir("/boot/grub/themes/lateralus"):
            run(
                [
                    "rsync",
                    "-a",
                    "--quiet",
                    "/boot/grub/themes/lateralus/",
                    f"{backup_dir}/lateralus/",
                ]
            )

        # Restore theme files from backup media.
        progress("Restore theme")
        run(["rsync", "-a", "--quiet", theme, "/boot/grub/themes/"])

        with open(grub_default, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()

        # Ensure required GRUB settings are present.
        lines = replace_or_append(
            lines, "GRUB_CMDLINE_LINUX_DEFAULT", "loglevel=3 quiet splash"
        )
        lines = replace_or_append(lines, "GRUB_GFXMODE", "1440x1080x32")
        lines = replace_or_append(
            lines, "GRUB_THEME", "/boot/grub/themes/lateralus/theme.txt"
        )
        lines = replace_or_append(lines, "GRUB_TERMINAL_OUTPUT", "gfxterm")

        with open(grub_default, "w", encoding="utf-8") as fh:
            fh.writelines(lines)

        # Rebuild grub.cfg.
        progress("Update grub.cfg")
        run(["grub-mkconfig", "-o", "/boot/grub/grub.cfg"])
        status("Restore GRUB done.")
        target_root = backup_root or os.path.dirname(srv.rstrip("/"))
        status(f"Target: {target_root}")
    finally:
        pass


if __name__ == "__main__":
    main()
