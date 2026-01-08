#!/usr/bin/env bash

set -u

QUIET=true
TOTAL_STEPS=6
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

require_command() {
  if ! command_exists "$1"; then
    err "Missing required command: $1"
    exit 1
  fi
}

is_block_device() {
  [[ -b "$1" ]]
}

prune_old() {
  local pattern="$1"
  local keep="$2"
  mapfile -t items < <(ls -t $pattern 2>/dev/null)
  local i=0
  local item
  for item in "${items[@]}"; do
    i=$((i + 1))
    if [[ $i -le $keep ]]; then
      continue
    fi
    if [[ -d "$item" ]]; then
      rm -rf "$item"
    else
      rm -f "$item"
    fi
  done
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
  local preferred="/run/media/ralexander/netac"
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

  local ts
  ts="$(date '+%j-%Y-%H%M')"
  local mountpoint
  mountpoint="$(select_target)"

  local base_dir="${mountpoint}/${ts}"
  mkdir -p "$base_dir"
  local created="yes"

  status "Target: ${base_dir}"

  local min_free_gb="${BKP_MIN_FREE_GB:-20}"
  local luks_device="${BKP_LUKS_DEVICE:-/dev/nvme0n1p2}"

  local bkp_base="$base_dir"
  local bkp_folder="${bkp_base}/${ts}"
  local root_dir="${bkp_folder}/root"
  local home_dir="${bkp_folder}/home"
  local archive_file="${bkp_base}/full-backup-${ts}.tar.gz"

  if ! command_exists mountpoint || ! mountpoint -q "$mountpoint"; then
    err "ERROR: ${mountpoint} is not a mountpoint."
    exit 1
  fi

  for cmd in rsync tar sudo cryptsetup; do
    require_command "$cmd"
  done

  if [[ ! -w "$base_dir" ]]; then
    err "Backup root not writable: ${base_dir}"
    exit 1
  fi

  local free_gb
  free_gb=$(df -BG "$mountpoint" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
  if [[ -n "$free_gb" && "$free_gb" -lt "$min_free_gb" ]]; then
    err "Not enough free space on ${mountpoint}: ${free_gb}G available, need ${min_free_gb}G"
    exit 1
  fi

  mkdir -p "$bkp_folder" "$root_dir" "$home_dir"
  status "Backup start: $(date '+%Y-%m-%dT%H:%M:%S')"
  status "Target: ${base_dir} (new dir: ${created})"
  progress "Pre-flight checks"

  progress "pigz"
  if ! command_exists pigz; then
    if command_exists pacman; then
      if [[ "${EUID}" -ne 0 ]]; then
        run_cmd sudo pacman -S --noconfirm pigz
      else
        run_cmd pacman -S --noconfirm pigz
      fi
    else
      err "pacman not available; install pigz manually."
      exit 1
    fi
  fi

  local src_home
  if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" ]]; then
    src_home="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
  else
    src_home="$HOME"
  fi

  progress "LUKS header (if present)"
  local luks_header_file="${bkp_base}/luks-header-${ts}.img"
  if is_block_device "$luks_device"; then
    run_cmd sudo cryptsetup luksHeaderBackup "$luks_device" --header-backup-file "$luks_header_file"
  fi

  local system_paths=(
    "/boot/grub/themes/lateralus"
    "/etc/default/grub"
    "/etc/mkinitcpio.conf"
    "/usr/share/plymouth/plymouthd.defaults"
    "/etc/samba/smb.conf"
    "/etc/samba/euclid"
    "/etc/ssh/sshd_config"
    "/usr/lib/sddm/sddm.conf.d/default.conf"
    "/etc/fstab"
  )

  progress "System files"
  local src
  for src in "${system_paths[@]}"; do
    [[ -e "$src" ]] || continue
    run_rsync_allow_partial sudo rsync -a --quiet "$src" "$root_dir" || exit $?
  done

  progress "User home"
  run_rsync_allow_partial rsync -aAX --quiet --partial --partial-dir=.rsync-partial \
    --exclude=.cache/ \
    --exclude=.var/app/ \
    --exclude=.subversion/ \
    --exclude=.mozilla/ \
    --exclude=.local/share/fonts/ \
    --exclude=.local/share/fonts/NerdFonts/ \
    --exclude=.vscode-oss/ \
    --exclude=Trash/ \
    --exclude=.config/*/Cache/ \
    --exclude=.config/*/cache/ \
    --exclude=.config/*/Code\ Cache/ \
    --exclude=.config/*/GPUCache/ \
    --exclude=.config/*/CachedData/ \
    --exclude=.config/*/CacheStorage/ \
    --exclude=.config/*/Service\ Worker/ \
    --exclude=.config/*/IndexedDB/ \
    --exclude=.config/*/Local\ Storage/ \
    --exclude=.config/rambox/ \
    --exclude=Shared/ArchBKP/ \
    --exclude=.ssh/agent/ \
    "${src_home}/" "${home_dir}/" || exit $?

  progress "Archive"
  run_cmd tar --ignore-failed-read -I pigz -cf "$archive_file" -C "$bkp_base" "$ts"
  status "Backup done."
  status "Target: ${base_dir}"
  status "Archive: ${archive_file}"

  prune_old "${bkp_base}/full-backup-*.tar.gz" 3
  prune_old "${bkp_base}/[0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]" 3
}

main "$@"
