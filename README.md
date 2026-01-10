PY Backup/Restore Scripts
=========================

Overview
--------
This repo contains a set of Python and Bash scripts for backing up and restoring
your personal system, dotfiles, and service configuration. The scripts are
tailored for your machine layout and USB mount conventions.

There are two parallel sets of scripts:
- Python: `backup-*.py`, `restore-*.py`
- Bash: `SH/*.sh`

The Bash versions mirror the Python behavior for the same task.


Directory Layout
----------------
- `backup-usb.py` / `SH/backup-usb.sh`
- `backup-rsync.py` / `SH/backup-rsync.sh`
- `backup-full-ssd.py` / `SH/backup-full-ssd.sh`
- `restore-main.py` / `SH/restore-main.sh`
- `restore-serv.py` / `SH/restore-serv.sh`
- `restore-grub.py` / `SH/restore-grub.sh`
- `restore-dots.py` / `SH/restore-dots.sh`

Other:
- `.venv/` local Python environment (ignored by git)
- `.gitignore`


Common Behavior
---------------
Pre-flight checks include:
- Verify required commands are present (e.g., `rsync`, `mountpoint`).
- Verify USB mount exists and is mounted.
- Verify expected backup folders exist.
- Ensure free space (backup scripts).

Security and safety:
- Some restore scripts require `sudo` and modify system files.
- Config files are backed up before modification where possible.
- Samba/SSH configs are validated before enabling services.
- `rsync` partial/vanished-file return codes (23/24) are allowed on backups.

Logging:
- File logging has been removed; status/progress is printed to console.
- In QUIET mode, stdout is suppressed but stderr still appears.


USB Layout (Expected)
---------------------
All scripts use the USB mount layout under:
`/run/media/<user>/<label>/START`

Current defaults:
- User: `ralexander`
- Label: `netac`

Backup contents:
- `START/home/` (user data)
- `START/dots/` (dotfiles)
- `START/Srv/` (system/service configs)


Backup Scripts
--------------

1) backup-usb
--------------
Files:
- `backup-usb.py`
- `SH/backup-usb.sh`

Purpose:
- Backup selected home folders, dotfiles, SSH keys, and system configs to USB.
- Copies `restore-*` scripts into `START/` for easy access on the USB.

Steps:
- Auto-select `/run/media/ralexander/netac` if mounted; otherwise prompt.
- Create `START/home`, `START/dots`, `START/Srv`.
- Optionally save LUKS header.
- `rsync` home folders and dotfiles with excludes.
- Copy SSH keys into `START/Srv/ssh/.ssh`.
- Copy system files into `START/Srv/...`.

Pre-flight:
- Check free space (default 20GB).
- Verify `rsync`, `sudo`, `cryptsetup` exist.
- Verify mount is valid.

Notes:
- No timestamped subfolder is created; everything goes directly under `START/`.
- Excludes include `.config/rambox/` and `Shared/ArchBKP/`.

Env vars:
- `BKP_MIN_FREE_GB` (default `20`)
- `BKP_LUKS_DEVICE` (default `/dev/nvme0n1p2`)


2) backup-rsync
---------------
Files:
- `backup-rsync.py`
- `SH/backup-rsync.sh`

Purpose:
- Local backup into `/home/ralexander/Shared/ArchBKP`.
- Optional archive via `tar + pigz`.

Steps:
- Copy system files to `root/`.
- Copy user data to `home/` with excludes.
- Backup SSH keys.
- Optional archive creation.

Env vars:
- `BKP_CREATE_ARCHIVE` (default `n`)


3) backup-full-ssd
------------------
Files:
- `backup-full-ssd.py`
- `SH/backup-full-ssd.sh`

Purpose:
- Full home backup + key system configs to USB.
- Always uses a timestamped directory under the mount.

Steps:
- Auto-select `/run/media/ralexander/netac` if mounted; otherwise prompt.
- Create timestamped target directory.
- Save LUKS header if device exists.
- `rsync` system files to `root/`.
- `rsync` full home with excludes to `home/`.
- Compress archive and prune old backups.

Env vars:
- `BKP_MIN_FREE_GB` (default `20`)
- `BKP_LUKS_DEVICE` (default `/dev/nvme0n1p2`)


Restore Scripts
---------------

1) restore-main
---------------
Files:
- `restore-main.py`
- `SH/restore-main.sh`

Purpose:
- Restore main user data + icons/themes + dotfiles.
- Install fonts, yay, and ML4W dotfiles installer.

Steps:
- Locate `START` backup root (direct or latest subdir).
- Restore Thunar UCA.
- Restore selected user directories.
- Restore icons/themes, dotfiles.
- Run fonts installer:
  1) `/run/media/<user>/<label>/BIG/fonts/install.sh` if present
  2) fallback to `~/Shared/fonts/install.sh`
- Install yay if on Arch.
- Install ML4W via Flatpak (interactive).


2) restore-serv
---------------
Files:
- `restore-serv.py`
- `SH/restore-serv.sh`

Purpose:
- Restore Samba and SSH configuration from `START/Srv`.
- Recreate SMB shares and enable services.

Steps:
- Back up existing Samba config.
- Install Samba config from backup.
- Create `/SMB` tree with permissions.
- Enable and validate Samba services.
- Restore SSH keys/config, validate `sshd_config`.
- Restart services and show status.

Notes:
- Requires root.
- Uses `testparm` and `sshd -t` validation.


3) restore-grub
---------------
Files:
- `restore-grub.py`
- `SH/restore-grub.sh`

Purpose:
- Restore GRUB theme and update GRUB defaults.

Steps:
- Back up `/etc/default/grub`.
- Restore theme to `/boot/grub/themes`.
- Set GRUB defaults (theme, gfxmode, cmdline).
- Regenerate `/boot/grub/grub.cfg`.

Notes:
- Requires root.


4) restore-dots
---------------
Files:
- `restore-dots.py`
- `SH/restore-dots.sh`

Purpose:
- Restore dotfiles and tweak Hyprland/ML4W settings.

Highlights:
- Hyprctl settings, keybindings, wallpapers symlink.
- Hypridle changes.
- Hyprlock is copied from backup without edits.
- Copy `hypr/logo-2.png` and `hypr/scripts/uptime.sh`.
- Restore ML4W settings files and theme configs.
- Restore `matugen`, `cava`, `waybar` themes.
- Link `~/.config/cava` to dotfiles `cava`.
- Restore `rofi`, `wlogout`, `kitty`, `fastfetch`, `nvim`, `gtk`, etc.
- Run ML4W shell script if present:
  `~/.mydotfiles/com.ml4w.dotfiles.stable/.config/ml4w/scripts/shell.sh`


Quick Start
-----------
1) Plug in USB so it mounts under `/run/media/ralexander/netac`.
2) Run backup script:
   - `python3 backup-usb.py`
   - or `bash SH/backup-usb.sh`
3) On restore machine, run the desired restore script:
   - `python3 restore-main.py`
   - `python3 restore-dots.py`
   - `sudo python3 restore-serv.py`
   - `sudo python3 restore-grub.py`


Notes
-----
- These scripts are tuned for your user and folder structure.
- Restore scripts can overwrite local config; backups are created where possible.
- The Bash scripts should be made executable if used directly:
  `chmod +x SH/*.sh`

