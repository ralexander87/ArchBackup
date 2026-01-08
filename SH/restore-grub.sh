#!/usr/bin/env bash

set -u

QUIET=true
TOTAL_STEPS=3
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

run_cmd() {
  if $QUIET; then
    "$@" >/dev/null
  else
    "$@"
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
  fi
}

replace_or_append() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}=" "$file"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}=.*|${key}=\"${value}\"|" "$file"
  else
    printf '%s\n' "${key}=\"${value}\"" >>"$file"
  fi
}

has_required() {
  local base="$1"
  shift
  local name
  for name in "$@"; do
    if [[ ! -e "$base/$name" ]]; then
      return 1
    fi
  done
  return 0
}

resolve_backup_root() {
  local base_root="$1"
  shift
  local required=("$@")
  if has_required "$base_root" "${required[@]}"; then
    printf '%s\n' "$base_root"
    return 0
  fi
  local candidate
  for candidate in "$base_root"/*/; do
    if [[ ! -d "$candidate" ]]; then
      continue
    fi
    if has_required "${candidate%/}" "${required[@]}"; then
      printf '%s\n' "${candidate%/}"
      return 0
    fi
  done
  return 1
}

main() {
  ensure_root "$@"

  # Locate backup root and required GRUB theme files.
  local user="${SUDO_USER:-${USER:-$(whoami)}}"
  local usb_label="${BKP_USB_LABEL:-netac}"
  local usb_mount="/run/media/${user}/${usb_label}"
  local base_root="${usb_mount}/START"

  if ! command_exists mountpoint; then
    err "Error: mountpoint not found."
    exit 1
  fi
  if ! mountpoint -q "$usb_mount"; then
    err "Error: ${usb_mount} is not a mountpoint. Is the USB plugged in and mounted?"
    exit 1
  fi

  # Find the backup root that contains Srv.
  local backup_root
  if ! backup_root="$(resolve_backup_root "$base_root" "Srv")"; then
    err "Error: backup root not found under ${base_root}"
    exit 1
  fi
  local srv="${backup_root}/Srv"
  local theme="${srv}/grub/lateralus"
  local grub_default="/etc/default/grub"
  local backup="/etc/default/grub.bak.$(date '+%Y%m%d-%H%M%S')"
  local ts
  ts="$(date '+%Y%m%d%H%M%S')"
  local backup_dir="/var/backups/restore-grub-${ts}"

  if [[ ! -f "$grub_default" ]]; then
    err "Error: ${grub_default} not found."
    exit 1
  fi
  if [[ ! -d "$srv" ]]; then
    err "Error: backup directory not found: ${srv}"
    exit 1
  fi
  if [[ ! -d "$theme" ]]; then
    err "Error: theme directory not found: ${theme}"
    exit 1
  fi
  if ! command_exists grub-mkconfig; then
    err "Error: grub-mkconfig not found in PATH."
    exit 1
  fi

  # Keep a backup of current settings and theme.
  mkdir -p "$backup_dir"
  status "Restore GRUB start: $(date '+%Y-%m-%dT%H:%M:%S')"
  progress "Backup defaults"
  cp -a "$grub_default" "$backup"

  mkdir -p /boot/grub/themes
  if [[ -d "/boot/grub/themes/lateralus" ]]; then
    run_cmd rsync -a --quiet /boot/grub/themes/lateralus/ "${backup_dir}/lateralus/"
  fi

  # Restore theme files from backup media.
  progress "Restore theme"
  run_cmd rsync -a --quiet "$theme" /boot/grub/themes/

  # Ensure required GRUB settings are present.
  replace_or_append "$grub_default" "GRUB_CMDLINE_LINUX_DEFAULT" "loglevel=3 quiet splash"
  replace_or_append "$grub_default" "GRUB_GFXMODE" "1440x1080x32"
  replace_or_append "$grub_default" "GRUB_THEME" "/boot/grub/themes/lateralus/theme.txt"
  replace_or_append "$grub_default" "GRUB_TERMINAL_OUTPUT" "gfxterm"

  # Rebuild grub.cfg.
  progress "Update grub.cfg"
  run_cmd grub-mkconfig -o /boot/grub/grub.cfg

  status "Restore GRUB done."
  status "Target: ${backup_root}"
}

main "$@"
