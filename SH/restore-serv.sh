#!/usr/bin/env bash

set -euo pipefail

QUIET=true
TOTAL_STEPS=4
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

run_cmd_no_check() {
  if $QUIET; then
    "$@" >/dev/null || true
  else
    "$@" || true
  fi
}

run_interactive() {
  "$@"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_file() {
  if [[ ! -f "$1" ]]; then
    err "Required file not found: $1"
    exit 1
  fi
}

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
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
  local newest=""
  local newest_mtime=0
  local candidate
  for candidate in "$base_root"/*/; do
    [[ -d "$candidate" ]] || continue
    if has_required "${candidate%/}" "${required[@]}"; then
      local mtime
      mtime=$(stat -c %Y "$candidate" 2>/dev/null || echo 0)
      if [[ "$mtime" -gt "$newest_mtime" ]]; then
        newest_mtime="$mtime"
        newest="$candidate"
      fi
    fi
  done
  if [[ -n "$newest" ]]; then
    printf '%s\n' "${newest%/}"
    return 0
  fi
  return 1
}

main() {
  ensure_root "$@"

  # Run as the original user, but apply system-level changes.
  local run_as_user="${SUDO_USER:-${USER:-ralexander}}"
  local run_as_group
  run_as_group="$(id -g "$run_as_user")"
  local user_home
  user_home="$(getent passwd "$run_as_user" | cut -d: -f6)"

  local usb_user="${SUDO_USER:-${USER:-$run_as_user}}"
  local usb_label="${BKP_USB_LABEL:-netac}"
  local usb_mount="/run/media/${usb_user}/${usb_label}"
  local base_root="${usb_mount}/START"

  if ! command_exists mountpoint; then
    err "mountpoint not found."
    exit 1
  fi
  if ! mountpoint -q "$usb_mount"; then
    err "${usb_mount} is not a mountpoint. Is the USB plugged in and mounted?"
    exit 1
  fi

  # Locate backup root that contains Srv.
  local backup_root
  if ! backup_root="$(resolve_backup_root "$base_root" "Srv")"; then
    err "Backup root not found under ${base_root}"
    exit 1
  fi
  local srv="${backup_root}/Srv"

  # Samba + SSH restore sources.
  local smb_root="/SMB"
  local smb_subdirs=("euclid" "pneuma" "SCP" "lateralus")
  local wsdd_service="wsdd.service"
  local smb_services=("smb.service" "nmb.service" "avahi-daemon.service" "${wsdd_service}")
  local sshd_service="sshd.service"
  local smb_conf_src="${srv}/samba/smb.conf"
  local smb_creds_src="${srv}/samba/creds-euclid"
  local sshd_conf_src="${srv}/ssh/sshd_config"
  local yubi_service="pcscd.service"
  local fstab_entry="//192.168.8.60/d   /SMB/euclid   cifs   _netdev,credentials=/etc/samba/creds-euclid,uid=1000,gid=1000   0 0"

  for cmd in systemctl modprobe smbpasswd rsync sshd pdbedit; do
    if ! command_exists "$cmd"; then
      err "Missing required command: ${cmd}"
      exit 1
    fi
  done

  if [[ ! -d "$srv" ]]; then
    err "Backup directory not found: ${srv}"
    exit 1
  fi

  require_file "$smb_conf_src"
  require_file "$sshd_conf_src"

  local ts
  ts="$(date '+%Y%m%d%H%M%S')"
  local backup_dir="/var/backups/restore-serv-${ts}"
  mkdir -p "$backup_dir"
  status "Restore start: $(date '+%Y-%m-%dT%H:%M:%S')"

  progress "Kernel module"
  # Load CIFS for SMB mounts.
  run_cmd_no_check modprobe cifs

  progress "Samba config"
  # Backup existing Samba/SSH config before applying new ones.
  if [[ -d "/etc/samba" ]]; then
    run_cmd rsync -a --quiet /etc/samba/ "${backup_dir}/etc-samba/"
  fi
  if [[ -d "/etc/ssh" ]]; then
    run_cmd rsync -a --quiet /etc/ssh/ "${backup_dir}/etc-ssh/"
  fi
  if [[ -f "/etc/ssh/sshd_config" ]]; then
    cp -a /etc/ssh/sshd_config "${backup_dir}/sshd_config"
  fi
  if [[ -f "/etc/fstab" ]]; then
    cp -a /etc/fstab "${backup_dir}/fstab"
  fi

  local smb_conf_bak="/etc/samba/smb.conf.${ts}.bak"
  cp -a "$smb_conf_src" "$smb_conf_bak"
  chown 0:0 "$smb_conf_bak"
  chmod 0644 "$smb_conf_bak"
  cp -a "$smb_conf_src" /etc/samba/smb.conf
  chown 0:0 /etc/samba/smb.conf
  chmod 0644 /etc/samba/smb.conf
  if [[ -f "$smb_creds_src" ]]; then
    cp -a "$smb_creds_src" /etc/samba/creds-euclid
    chown 0:0 /etc/samba/creds-euclid
    chmod 0600 /etc/samba/creds-euclid
  fi

  # Create SMB share structure.
  mkdir -p "$smb_root"
  chmod 1750 "$smb_root"
  local d path
  for d in "${smb_subdirs[@]}"; do
    path="${smb_root}/${d}"
    mkdir -p "$path"
    chmod 2750 "$path"
  done
  chown "$(id -u "$run_as_user")":"$run_as_group" "$smb_root"
  for d in "${smb_subdirs[@]}"; do
    chown "$(id -u "$run_as_user")":"$run_as_group" "${smb_root}/${d}"
  done

  progress "Samba users/services"
  # Ensure ownership and enable services.
  run_cmd chown -R "${run_as_user}:${run_as_group}" "$smb_root"

  if ! pdbedit -L | grep -q "^${run_as_user}\b"; then
    run_interactive smbpasswd -a "$run_as_user"
  fi

  for svc in "${smb_services[@]}"; do
    run_cmd systemctl enable --now "$svc"
  done

  if command_exists testparm; then
    # Validate config before continuing.
    if ! testparm -s /etc/samba/smb.conf >/dev/null 2>&1; then
      err "[!] smb.conf validation failed; restoring backup."
      cp -a "$smb_conf_bak" /etc/samba/smb.conf
      chown 0:0 /etc/samba/smb.conf
      chmod 0644 /etc/samba/smb.conf
      for svc in "${smb_services[@]}"; do
        run_cmd_no_check systemctl restart "$svc"
      done
      exit 1
    fi
  fi

  for svc in "${smb_services[@]}"; do
    if ! systemctl is-active --quiet "$svc"; then
      err "[!] Service failed: ${svc}. Restoring smb.conf backup."
      cp -a "$smb_conf_bak" /etc/samba/smb.conf
      chown 0:0 /etc/samba/smb.conf
      chmod 0644 /etc/samba/smb.conf
      for s in "${smb_services[@]}"; do
        run_cmd_no_check systemctl restart "$s"
      done
      exit 1
    fi
  done

  progress "SSH config"
  # Restore SSH keys and config.
  local src_ssh_dir="${srv}/ssh/.ssh"
  local dest_ssh_dir="${user_home}/.ssh"

  run_cmd systemctl enable --now "$sshd_service"
  run_cmd systemctl enable --now "$yubi_service"

  if [[ -d "$src_ssh_dir" ]]; then
    if [[ -d "$dest_ssh_dir" ]]; then
      run_cmd rsync -a --quiet "${dest_ssh_dir}/" "${backup_dir}/ssh/"
    fi
    mkdir -p "$dest_ssh_dir"
    run_cmd chown "${run_as_user}:${run_as_group}" "$dest_ssh_dir"
    chmod 700 "$dest_ssh_dir"
    run_cmd rsync -aH --quiet --delete "${src_ssh_dir}/" "${dest_ssh_dir}/"
    run_cmd chown -R "${run_as_user}:${run_as_group}" "$dest_ssh_dir"

    local root name
    while IFS= read -r -d '' root; do
      for name in "$root"/*; do
        [[ -f "$name" ]] || continue
        if [[ "$name" == *.pub ]]; then
          chmod 0644 "$name"
        else
          chmod 0600 "$name"
        fi
      done
    done < <(find "$dest_ssh_dir" -type d -print0)
  else
    err "[!] Source SSH directory not found: ${src_ssh_dir} (skipping key sync)."
  fi

  local sshd_conf_bak="/etc/ssh/sshd_config.${ts}.bak"
  # Replace sshd_config and validate.
  cp -a "$sshd_conf_src" "$sshd_conf_bak"
  chown 0:0 "$sshd_conf_bak"
  chmod 0600 "$sshd_conf_bak"
  cp -a "$sshd_conf_src" /etc/ssh/sshd_config
  chown 0:0 /etc/ssh/sshd_config
  chmod 0600 /etc/ssh/sshd_config

  if sshd -t -f /etc/ssh/sshd_config >/dev/null 2>&1; then
    run_cmd systemctl enable --now "$sshd_service"
  else
    err "[!] sshd_config validation failed; restoring backup."
    cp -a "$sshd_conf_bak" /etc/ssh/sshd_config
    chown 0:0 /etc/ssh/sshd_config
    chmod 0600 /etc/ssh/sshd_config
    exit 1
  fi

  progress "Fstab"
  if [[ -f /etc/fstab ]]; then
    if ! grep -Fqx "$fstab_entry" /etc/fstab; then
      if [[ -n "$(tail -c1 /etc/fstab 2>/dev/null)" ]]; then
        printf '\n' >>/etc/fstab
      fi
      printf '%s\n' "$fstab_entry" >>/etc/fstab
    else
      err "fstab entry already present; skipping append."
    fi
  fi

  # Service status summary for quick checks.
  local svc
  for svc in "${smb_services[@]}" "$sshd_service"; do
    run_cmd_no_check systemctl --no-pager --full status "$svc"
  done

  status "[*] Restore services done."
  status "Target: ${backup_root}"
}

main "$@"
