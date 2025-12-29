---
code: BASH PY
device: lateralus
---
# Full Backup & Restore Guide

This is the single, comprehensive guide for all backup/restore scripts in this repo.
All scripts are v2-only.

## Quick map

- Daily rsync backup: `backup-rsync-v2.sh`, `backup-rsync-v2.py`
- Full SSD backup: `backup-full-ssd-v2.sh`, `backup-full-ssd-v2.py`

## Daily backup (rsync)

Scripts:

- `backup-rsync-v2.sh`
- `backup-rsync-v2.py`

What it does:

- Backs up a curated set of user and system files into `~/Shared/ArchBKP/<timestamp>`.
- Logs to `backup.log` inside the backup folder.
- Compresses the backup into `*.tar.gz`.

Notes:

- Safe timestamp format (no `:`).
- Uses `pigz` if installed (auto-installs on Arch).

## Full backup (SSD → USB)

Scripts:

- `backup-full-ssd-v2.sh`
- `backup-full-ssd-v2.py`

What it does:

- Creates a timestamped folder under `BKP/` with `root/` + `home/`.
- Creates `full-backup-<timestamp>.tar.gz`.
- Writes logs to `BKP/logs/`.
- Stores a LUKS header backup (backup-only).
- Keeps only the last 3 snapshots + archives.

Backup layout:

```
Lateralus/
BKP/
<timestamp>/
root/
home/
full-backup-<timestamp>.tar.gz
logs/
backup-full-ssd-<timestamp>.log

```

Run:

```bash
./full/backup-full-ssd-v2.sh
```

or

```bash
python3 full/backup-full-ssd-v2.py
```

Python env overrides:

- `BKP_USB_LABEL` (USB label)
- `BKP_MIN_FREE_GB` (free-space threshold)
- `BKP_LUKS_DEVICE` (LUKS device path)

## Pre-reinstall USB backup + restore (BR/v2)

### Backup

Scripts:

- `backup-usb-v2.sh`
- `backup-usb-v2.py`

Backs up:

- User data → `USB/home/`
- Dotfiles → `USB/dots/`
- Service/system configs → `USB/Srv/`
- LUKS header → `USB/luks-header-<timestamp>.img` (backup-only)
- `fstab` → `USB/Srv/fstab` (backup-only)

USB layout:

```

netac/
home/
dots/
Srv/
grub/
samba/
ssh/
mkinitcpio.conf
plymouthd.defaults
fstab

```

### Restore (fresh install)

Scripts:

- `restore-main-v2.sh` / `restore-main-v2.py`
- `restore-dots-v2.sh` / `restore-dots-v2.py`
- `restore-serv-v2.sh` / `restore-serv-v2.py`
- `restore-grub-v2.sh` / `restore-grub-v2.py`

Recommended order:

1. Mount the USB at `/run/media/$USER/netac` (or set `BKP_USB_LABEL`).
2. `restore-main-v2.sh`
Restores home directories, dotfiles, installs fonts, installs yay.

3. `restore-dots-v2.sh`
Applies dotfile tweaks from `~/dots` and backs up overwritten files.

4. `sudo ./restore-serv-v2.sh`
Restores Samba + SSH configs, enables services, validates and rolls back on failure.

5. `sudo ./restore-grub-v2.sh`
Restores GRUB theme and rebuilds `grub.cfg`.

Notes:

- `restore-main` does **not** touch Samba/SSH; `restore-serv` handles those.
- `restore-dots` makes a timestamped backup of all overwritten files.
- LUKS header and `/etc/fstab` are **backup-only** (never restored automatically).

## Environment overrides (BR/v2)

- `BKP_USB_LABEL=<label>` to use a non-default USB label.
- `SRV=/run/media/$USER/<label>/Srv` to override service/grub restore source.

## Safety

- Restore scripts create backups before overwriting configs.
- SSH and Samba restores validate configs and roll back on failure.
- Logs are written to USB when possible; Python restore scripts fall back to `/tmp`.
