# Full Backup & Restore Guide

This is a short GitHub README for all backup/restore scripts in this repo.
v2 uses fixed paths, v3 uses interactive device selection.

## Quick map

- Daily rsync backup:
  - v2: `rsync/backup-rsync-v2.sh`, `rsync/backup-rsync-v2.py`
  - v3: `v3/backup-rsync-v3.sh`, `v3/backup-rsync-v3.py`
- Full SSD backup:
  - v2: `full/backup-full-ssd-v2.sh`, `full/backup-full-ssd-v2.py`
  - v3: `v3/backup-full-ssd-v3.sh`, `v3/backup-full-ssd-v3.py`
- Pre-reinstall USB backup + restore:
  - v2 Bash: `BR/v2/*.sh`
  - v2 Python: `BR/v2/py/*.py`

## v3 behavior

- Lists mounted external devices and prompts to select one.
- Optionally creates a timestamped directory on the device.
- Asks for confirmation before starting.

## Daily backup (rsync)

Scripts:

- v2: `rsync/backup-rsync-v2.sh`, `rsync/backup-rsync-v2.py`
- v3: `v3/backup-rsync-v3.sh`, `v3/backup-rsync-v3.py`

What it does:

- Backs up a curated set of user and system files.
- Creates a compressed archive in a timestamped folder.
- Logs are quiet on terminal; detailed logs go to the log file.

## Full backup (SSD -> USB)

Scripts:

- v2: `full/backup-full-ssd-v2.sh`, `full/backup-full-ssd-v2.py`
- v3: `v3/backup-full-ssd-v3.sh`, `v3/backup-full-ssd-v3.py`

What it does:

- Creates a timestamped folder with `root/` + `home/`.
- Creates `full-backup-<timestamp>.tar.gz`.
- Stores a LUKS header backup (backup-only).

Run (v3 example):

```bash
./v3/backup-full-ssd-v3.sh
```

## Pre-reinstall USB backup + restore (BR/v2)

Backup:

- `BR/v2/backup-usb-v2.sh`
- `BR/v2/py/backup-usb-v2.py`

Restore:

- `BR/v2/restore-main-v2.*`
- `BR/v2/restore-dots-v2.*`
- `BR/v2/restore-serv-v2.*`
- `BR/v2/restore-grub-v2.*`

Recommended order:

1. Mount the USB at `/run/media/$USER/netac` (or set `BKP_USB_LABEL`).
2. `restore-main-v2.*`
3. `restore-dots-v2.*`
4. `sudo restore-serv-v2.*`
5. `sudo restore-grub-v2.*`

## Notes

- LUKS header backups are backup-only and never auto-restored.
- `/etc/fstab` is backed up for reference only.
- Restore scripts create safety backups before overwriting configs.

## Env overrides (Python)

- `BKP_MIN_FREE_GB`
- `BKP_LUKS_DEVICE`
- `BKP_USB_LABEL` (v2 only)

