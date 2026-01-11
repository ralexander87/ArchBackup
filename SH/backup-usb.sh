#!/usr/bin/env bash

set -euo pipefail

QUIET=true
TOTAL_STEPS=5
STEP=0

status() {
  printf '%s\n' "$*"
}

progress() {
  STEP=$((STEP + 1))
  status "[$STEP/$TOTAL_STEPS] $1"
}

err() {
  printf '%s\n' "$*" >&2
}

summary() {
  status "$@"
}

run_cmd() {
  if $QUIET; then
    "$@" >/dev/null
  else
    "$@"
  fi
}

run_rsync_allow_partial() {
  "$@"
  local rc=$?
  if [[ $rc -ne 0 && $rc -ne 23 && $rc -ne 24 ]]; then
    return "$rc"
  fi
  if [[ $rc -eq 23 || $rc -eq 24 ]]; then
    err "[!] rsync completed with partial transfer (code 23/24). Continuing."
  fi
  return 0
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

make_executable() {
  chmod +x "$1" 2>/dev/null || true
}

list_mounts() {
  local user="${SUDO_USER:-${USER:-$(whoami)}}"
  lsblk -P -o NAME,MOUNTPOINT,TRAN,SIZE,MODEL,TYPE |
    while read -r line; do
      eval "$line"
      if [[ "${TYPE:-}" != "part" ]]; then
        continue
      fi
      local mountpoint="${MOUNTPOINT:-}"
      if [[ -z "$mountpoint" ]]; then
        continue
      fi
      if [[ "$mountpoint" == "/run/media/${user}/"* || "$mountpoint" == "/media/${user}/"* ]]; then
        printf '%s|%s|%s|%s\n' "$mountpoint" "${NAME:-?}" "${SIZE:-?}" "${TRAN:-?}:${MODEL:-unknown}"
      fi
    done
}

select_target() {
  local user="${SUDO_USER:-${USER:-$(whoami)}}"
  local label="${BKP_USB_LABEL:-netac}"
  local preferred="/run/media/${user}/${label}"
  local mounts
  mounts="$(list_mounts)"
  if [[ -z "$mounts" ]]; then
    err "No mounted external devices found under /run/media or /media."
    exit 1
  fi
  if echo "$mounts" | cut -d'|' -f1 | grep -qx "$preferred"; then
    printf '%s\n' "$preferred"
    return 0
  fi
  status "Select target device:"
  local i=1
  local choices=()
  while IFS='|' read -r mpoint name size meta; do
    status "  ${i}) ${mpoint} (${name}, ${size}, ${meta})"
    choices+=("$mpoint")
    i=$((i + 1))
  done <<<"$mounts"
  read -r -p "Enter number: " choice
  if [[ ! "$choice" =~ ^[0-9]+$ || "$choice" -lt 1 || "$choice" -gt "${#choices[@]}" ]]; then
    err "Invalid selection."
    exit 1
  fi
  printf '%s\n' "${choices[$((choice - 1))]}"
}

main() {
  status "--------------------------------------------------------------------------------------------"
  umask 077

  # Prevent concurrent runs.
  local lock_dir="/tmp/backup-usb-v3"
  local lock_file="${lock_dir}/backup-usb.lock"
  mkdir -p "$lock_dir"
  if ! ( set -o noclobber; : >"$lock_file" ) 2>/dev/null; then
    err "Backup already running (lock: ${lock_file})."
    exit 1
  fi
  trap 'rm -f "$lock_file"' EXIT INT TERM

  local mountpoint
  mountpoint="$(select_target)"

  local base_root="${mountpoint}/START"
  mkdir -p "$base_root"

  # Stage restore scripts alongside the backup payload.
  for script in /home/ralexander/Code/PY/PY/restore-*; do
    if [[ -f "$script" ]]; then
      cp -a "$script" "$base_root/"
    fi
  done

  local min_free_gb="${BKP_MIN_FREE_GB:-20}"
  local luks_device="${BKP_LUKS_DEVICE:-/dev/nvme0n1p2}"
  local usb="${base_root}"
  local srv="${usb}/Srv"
  local dots="${HOME}/.mydotfiles/com.ml4w.dotfiles.stable/.config/"
  local dirs=("Documents" "Pictures" "Obsidian" "Working" "Shared" "VM" "Videos" "Code" ".icons" ".themes" ".zsh_history" ".zshrc" ".gitconfig")
  local excludes=(
    ".cache/" ".var/app/" ".subversion/" ".mozilla/" ".local/share/fonts/"
    ".local/share/fonts/NerdFonts/" ".vscode-oss/" "Trash/" ".config/*/Cache/"
    ".config/*/cache/" ".config/*/Code Cache/" ".config/*/GPUCache/" ".config/*/CachedData/"
    ".config/*/CacheStorage/" ".config/*/Service Worker/" ".config/*/IndexedDB/" ".config/*/Local Storage/"
    ".config/rambox/"
    ".rustup/"
    "Shared/ArchBKP/"
  )
  local exclude_args=()
  local ex
  for ex in "${excludes[@]}"; do
    exclude_args+=("--exclude=${ex}")
  done

  if ! command_exists mountpoint; then
    err "Missing required command: mountpoint"
    exit 1
  fi
  if ! mountpoint -q "$mountpoint"; then
    err "ERROR: ${mountpoint} is not a mountpoint."
    exit 1
  fi

  for cmd in rsync sudo cryptsetup; do
    if ! command_exists "$cmd"; then
      err "Missing required command: ${cmd}"
      exit 1
    fi
  done

  if [[ ! -w "$base_root" ]]; then
    err "Backup root not writable: ${base_root}"
    exit 1
  fi

  mkdir -p "${usb}/home" "${usb}/dots" "${srv}/grub" "${srv}/ssh" "${srv}/samba"

  for script in ./*.sh; do
    [[ -f "$script" ]] && make_executable "$script"
  done

  status "Backup start: $(date '+%Y-%m-%dT%H:%M:%S')"
  status "Target: ${usb}"
  progress "Pre-flight checks"

  local free_gb
  free_gb=$(df -BG "$mountpoint" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
  if [[ -n "$free_gb" && "$free_gb" -lt "$min_free_gb" ]]; then
    err "Not enough free space on ${mountpoint}: ${free_gb}G available, need ${min_free_gb}G"
    exit 1
  fi

  local luks_header_file
  luks_header_file="${usb}/luks-header-$(date '+%j-%Y-%H%M').img"
  if [[ -e "$luks_device" ]]; then
    run_cmd sudo cryptsetup luksHeaderBackup "$luks_device" --header-backup-file "$luks_header_file"
  fi

  progress "User files"
  local d
  for d in "${dirs[@]}"; do
    local src="${HOME}/${d}"
    [[ -e "$src" ]] || continue
    run_rsync_allow_partial rsync -arh --quiet --partial --partial-dir=.rsync-partial \
      "${exclude_args[@]}" \
      "$src" "${usb}/home" || exit $?
  done

  progress "Dotfiles and SSH"
  if [[ -d "$dots" ]]; then
    run_rsync_allow_partial rsync -arh --quiet --partial --partial-dir=.rsync-partial \
      "${exclude_args[@]}" \
      "$dots" "${usb}/dots" || exit $?
  fi

  local ssh_dir="${HOME}/.ssh"
  if [[ -d "$ssh_dir" ]]; then
    run_rsync_allow_partial rsync -arh --quiet --partial --partial-dir=.rsync-partial \
      --exclude "agent/" "${ssh_dir}/" "${srv}/ssh/.ssh/" || exit $?
  fi

  progress "Extras"
  local cursor_dir="${HOME}/.local/share/icons/LyraX-cursors"
  [[ -d "$cursor_dir" ]] && run_cmd cp -r "$cursor_dir" "${usb}/home"

  local hyprctl="${HOME}/.config/com.ml4w.hyprlandsettings/hyprctl.json"
  [[ -f "$hyprctl" ]] && run_cmd cp "$hyprctl" "${usb}/dots"

  local uca="${HOME}/.config/Thunar/uca.xml"
  [[ -f "$uca" ]] && run_cmd cp "$uca" "${usb}/dots"

  progress "System files"
  declare -A system_paths=(
    ["/boot/grub/themes/lateralus"]="${srv}/grub/"
    ["/etc/default/grub"]="${srv}/grub/"
    ["/etc/mkinitcpio.conf"]="${srv}/mkinitcpio.conf"
    ["/usr/share/plymouth/plymouthd.defaults"]="${srv}/plymouthd.defaults"
    ["/etc/samba/smb.conf"]="${srv}/samba/smb.conf"
    ["/etc/samba/euclid"]="${srv}/samba/euclid"
    ["/etc/ssh/sshd_config"]="${srv}/ssh/sshd_config"
    ["/etc/fstab"]="${srv}/fstab"
  )
  local src
  for src in "${!system_paths[@]}"; do
    [[ -e "$src" ]] || continue
    run_rsync_allow_partial sudo rsync -a --quiet "$src" "${system_paths[$src]}" || exit $?
  done

  summary "Backup done."
  summary "Target: ${usb}"
}

main "$@"
