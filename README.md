# ENCRYPT Backup/Restore Toolkit

This repository contains a set of Python and shell scripts used to back up and restore a Linux workstation. The scripts focus on:

- Backing up system configuration files, user home data, and dotfiles.
- Creating compressed archives of backups.
- Optional VeraCrypt encryption for compressed archives.
- Restoring system settings and user data from a USB backup layout.

The scripts are opinionated and tailored to a specific workstation layout (user `ralexander`, USB label `netac`, ML4W/Hyprland configs). Review each script before using it on another machine.

## Common Conventions

- **USB mountpoint**: default `/run/media/<user>/<label>`.
- **Backup root** on USB: `START/` directory.
- **Timestamped folders**: `JULIAN-YYYY-HHMM` (e.g. `010-2026-1358`).
- **Compression**: `tar` + `pigz` (parallel gzip).
- **Rsync errors**: exit codes 23/24 are treated as partial transfer and do not abort.
- **Lock files**: backup scripts use `/tmp/*-v3/*.lock` to prevent concurrent runs.

## Requirements

Most scripts expect these commands to exist:

- `rsync`, `tar`, `sudo`, `mountpoint`, `cryptsetup` (varies per script)
- `pigz` (auto-installed via pacman if missing)
- `veracrypt` for encryption features
- `systemctl`, `sshd`, `smbpasswd`, `modprobe`, `pdbedit` for service restores
- `flatpak` for ML4W installer in restore flow

## Environment Variables

Used by one or more scripts:

- `BKP_MIN_FREE_GB` (default `20`): minimum free GB required on target.
- `BKP_LUKS_DEVICE` (default `/dev/nvme0n1p2`): device for LUKS header backup.
- `BKP_USB_LABEL` (default `netac`): USB volume label.
- `BKP_CREATE_ARCHIVE` (`y`/`n`): create archive in `backup-rsync`.
- `BKP_VC_PAD_PCT` (default `5`): VeraCrypt container padding percentage.
- `BKP_VC_PAD_MB` (default `200`): VeraCrypt container extra padding in MB.
- `BKP_DELETE_PLAINTEXT` (`y`/`n`): auto delete plaintext archive after encryption.

## Backup Scripts (Python)

### `backup-full-ssd.py`

**Purpose**: Full backup to an external drive with optional VeraCrypt encryption of the compressed archive.

**High-level flow**:

1. Select an external mountpoint under `/run/media` or `/media` (prefers `/run/media/<user>/<label>`).
2. Ask whether to create an encrypted container for the archive (prompt occurs at start).
3. Create a timestamped backup directory on the target.
4. Pre-flight checks: required commands, writable target, free space.
5. Ensure `pigz` is installed (auto-installs via pacman if missing).
6. Optionally back up LUKS header if the device is present.
7. Rsync selected system config files into `root/`.
8. Rsync user home into `home/` with extensive excludes.
9. Create a compressed archive `full-backup-<ts>.tar.gz` in the target.
10. If encryption enabled:
    - Create a VeraCrypt container sized to archive + padding.
    - Mount container (with sudo if needed).
    - Copy archive into container.
    - Verify copied file size matches.
    - Optionally delete plaintext archive (prompt or `BKP_DELETE_PLAINTEXT`).
    - Dismount container (cleanup on exit/signals too).
11. Prune older archives and timestamped folders (keep 3).

**Notes**:

- Uses `veracrypt --text --non-interactive` and handles sudo password prompting when needed.
- For VeraCrypt, only the **archive** is encrypted; raw `root/` and `home/` folders remain unencrypted in the timestamp folder.
- If `shred` is available and plaintext deletion is chosen, it uses a single-pass wipe.

**Usage**:

```
python3 backup-full-ssd.py
```

### `backup-rsync.py`

**Purpose**: Local backup to `/home/ralexander/Shared/ArchBKP` using rsync; optional archive.

**High-level flow**:

1. Create timestamped backup folder in `Shared/ArchBKP`.
2. Ensure required commands exist (`rsync`, `tar`, `sudo`, `pigz`).
3. Copy select system files into `root/` (rsync + chown).
4. Copy selected user directories into `home/` (rsync excludes applied).
5. Copy SSH keys (excluding agent) if present.
6. If `BKP_CREATE_ARCHIVE=y`, produce `<ts>.tar.gz`.

**Usage**:

```
python3 backup-rsync.py
```

### `backup-usb.py`

**Purpose**: Create a USB recovery structure in `START/` on an external drive, including restore scripts and user data.

**High-level flow**:

1. Select external mountpoint (prefers `/run/media/<user>/<label>`).
2. Create `START/` on USB and copy restore scripts into it.
3. Pre-flight checks (free space, required commands).
4. Copy user directories into `START/home` with excludes.
5. Copy dotfiles into `START/dots` with excludes.
6. Copy SSH keys into `START/Srv/ssh`.
7. Copy extras (cursors, hyprctl, Thunar custom actions).
8. Copy system files into `START/Srv` (samba, ssh, grub configs, etc.).
9. Optional LUKS header backup.

**Usage**:

```
python3 backup-usb.py
```

## Restore Scripts (Python)

### `restore-main.py`

**Purpose**: Restore user data, icons, themes, dotfiles, and run post-install steps from USB backup.

**High-level flow**:

1. Ensure USB is mounted at `/run/media/<user>/<label>`.
2. Locate backup root under `START/` (supports direct or newest subdir).
3. Create a backup folder for overwritten configs.
4. Back up and patch certain user/system configs (Hypr, SDDM).
5. Restore:
   - Thunar custom actions
   - User directories (Documents, Pictures, etc.)
   - Cursors, icons, themes
   - Dotfiles to home
6. Run fonts installer if found (non-fatal on failure).
7. Install `yay` on Arch (non-fatal on failure).
8. Install ML4W dotfiles installer via Flatpak (non-fatal on failure).

**Usage**:

```
python3 restore-main.py
```

### `restore-dots.py`

**Purpose**: Restore ML4W dotfiles and Hyprland settings from USB backup.

**High-level flow**:

1. Locate USB backup root and `dots/` directory.
2. Back up existing dotfiles into `~/.mydotfiles/restore-dots-backup-<ts>`.
3. Remove specific Flatpak apps (Pinta + calendar).
4. Restore key configs:
   - Hyprctl JSON
   - Keybindings
   - Wallpaper symlink
   - Hypridle settings
   - Hyprlock configuration
5. Overwrite various ML4W settings and styles.

**Usage**:

```
python3 restore-dots.py
```

### `restore-grub.py`

**Purpose**: Restore GRUB theme and ensure GRUB defaults are set for the custom theme.

**High-level flow**:

1. Require root (self-elevates via sudo).
2. Locate USB backup root and `Srv/grub` theme folder.
3. Back up `/etc/default/grub` and `/boot/grub/grub.cfg` into a timestamped backup dir.
4. Sync theme to `/boot/grub/themes/lateralus`.
5. Update `/etc/default/grub` values and run `grub-mkconfig`.

**Usage**:

```
sudo python3 restore-grub.py
```

### `restore-serv.py`

**Purpose**: Restore Samba and SSH configuration, recreate SMB shares, and enable services.

**High-level flow**:

1. Require root (self-elevates via sudo).
2. Locate USB backup root and `Srv/` folder.
3. Back up `/etc/samba` and `/etc/ssh` into a timestamped backup dir.
4. Restore Samba configuration (`/etc/samba/smb.conf`).
5. Create SMB directories and set ownership/permissions.
6. Ensure samba services are enabled and running.
7. Restore SSH config and keys, enforce file permissions.
8. Validate `smb.conf` and `sshd_config` and rollback on error.

**Usage**:

```
sudo python3 restore-serv.py
```

## Shell Script Equivalents

The `SH/` directory contains bash equivalents for many of the Python scripts. These follow similar logic but are typically more direct:

- `SH/backup-full-ssd.sh`: full backup + optional VeraCrypt encryption.
- `SH/backup-rsync.sh`: rsync-based local backup + optional archive.
- `SH/backup-usb.sh`: USB recovery layout builder.
- `SH/restore-main.sh`: restore user data and configs.
- `SH/restore-dots.sh`: restore dotfiles and Hyprland settings.
- `SH/restore-grub.sh`: restore GRUB theme and config.
- `SH/restore-serv.sh`: restore Samba + SSH services.

Usage example:

```
./SH/backup-full-ssd.sh
```

## Encryption Details

When encryption is enabled in `backup-full-ssd`:

- A VeraCrypt container (`.hc`) is created in the timestamp folder.
- The compressed archive is copied inside the container.
- The container size is computed as:
  - `archive_size * (1 + BKP_VC_PAD_PCT/100) + BKP_VC_PAD_MB`.
- The plaintext archive can be deleted automatically if:
  - You answer `y` when prompted, or
  - `BKP_DELETE_PLAINTEXT=y` is set.

**Important**: Only the **archive** is encrypted. The raw backup folders remain unencrypted unless you manually remove them after encryption.

## Safety Notes

- These scripts modify system files and services. Review before running on a new machine.
- Restore scripts frequently require root privileges.
- Ensure your USB mount label and user match the defaults or override with env vars.
- Always test restore steps on a non-critical machine before relying on them.

## Quick Start

1. Plug in USB drive (label `netac`).
2. Run a backup:

```
python3 backup-full-ssd.py
```

3. Restore on a new install:

```
python3 restore-main.py
```

4. Restore services and GRUB (root required):

```
sudo python3 restore-serv.py
sudo python3 restore-grub.py
```

## Troubleshooting

- **VeraCrypt errors**: ensure `veracrypt` is installed and you entered the correct password. Use `--text` mode for CLI-only environments.
- **Permission denied**: run scripts with sudo if they need system file access.
- **USB not found**: confirm the label and mountpoint match the expected path.

