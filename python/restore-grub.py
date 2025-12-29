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


def ensure_root():
    if os.geteuid() != 0:
        script = os.path.abspath(sys.argv[0])
        os.execvp("sudo", ["sudo", "-E", sys.executable, script] + sys.argv[1:])


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


def main():
    ensure_root()

    user = os.environ.get("SUDO_USER") or os.environ.get("USER") or getpass.getuser()
    usb_label = os.environ.get("BKP_USB_LABEL", "netac")
    srv = os.environ.get("SRV") or f"/run/media/{user}/{usb_label}/Srv"
    theme = os.path.join(srv, "grub", "lateralus")
    grub_default = "/etc/default/grub"
    backup = f"/etc/default/grub.bak.{datetime.datetime.now().strftime('%Y%m%d-%H%M%S')}"
    ts = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    backup_dir = f"/var/backups/restore-grub-{ts}"

    if not os.path.isfile(grub_default):
        print(f"Error: {grub_default} not found.", file=sys.stderr)
        sys.exit(1)
    if not os.path.isdir(srv):
        print(f"Error: backup directory not found: {srv}", file=sys.stderr)
        sys.exit(1)
    if not os.path.isdir(theme):
        print(f"Error: theme directory not found: {theme}", file=sys.stderr)
        sys.exit(1)
    if not command_exists("grub-mkconfig"):
        print("Error: grub-mkconfig not found in PATH.", file=sys.stderr)
        sys.exit(1)

    os.makedirs(backup_dir, exist_ok=True)
    log_dir = os.path.join(srv, "logs")
    try:
        os.makedirs(log_dir, exist_ok=True)
        log_path = os.path.join(log_dir, f"restore-grub-{ts}.log")
        global LOG_FH
        LOG_FH = open(log_path, "a", encoding="utf-8", errors="replace")
    except OSError:
        log_path = f"/tmp/restore-grub-{ts}.log"
        LOG_FH = open(log_path, "a", encoding="utf-8", errors="replace")
        print(f"[!] USB log path unavailable, using {log_path}")

    try:
        log(f"Creating backup: {backup}")
        shutil.copy2(grub_default, backup)

        os.makedirs("/boot/grub/themes", exist_ok=True)
        if os.path.isdir("/boot/grub/themes/lateralus"):
            log(f"Backing up existing theme to: {backup_dir}/lateralus")
            run(["rsync", "-a", "/boot/grub/themes/lateralus/", f"{backup_dir}/lateralus/"])

        run(["rsync", "-a", theme, "/boot/grub/themes/"])

        with open(grub_default, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()

        lines = replace_or_append(lines, "GRUB_CMDLINE_LINUX_DEFAULT", "loglevel=3 quiet splash")
        lines = replace_or_append(lines, "GRUB_GFXMODE", "1440x1080x32")
        lines = replace_or_append(lines, "GRUB_THEME", "/boot/grub/themes/lateralus/theme.txt")
        lines = replace_or_append(lines, "GRUB_TERMINAL_OUTPUT", "gfxterm")

        with open(grub_default, "w", encoding="utf-8") as fh:
            fh.writelines(lines)

        log(f"Updated {grub_default}")
        run(["grub-mkconfig", "-o", "/boot/grub/grub.cfg"])
        log("Done: /boot/grub/grub.cfg rebuilt.")
    finally:
        if LOG_FH:
            LOG_FH.close()


if __name__ == "__main__":
    main()
