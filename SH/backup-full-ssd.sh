#!/usr/bin/env bash

set -euo pipefail

QUIET=true
TOTAL_STEPS=7
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

VC_MOUNT_DIR=""
VC_MOUNTED=false
VC_USE_SUDO=false
VC_SUDO_NEEDS_PASS=false
VC_SUDO_PASS=""

cleanup_vc() {
  if ! $VC_MOUNTED || [[ -z "$VC_MOUNT_DIR" ]]; then
    return 0
  fi
  if ! vc_is_mounted "$VC_MOUNT_DIR"; then
    VC_MOUNTED=false
    VC_MOUNT_DIR=""
    return 0
  fi
  if $VC_USE_SUDO; then
    if $VC_SUDO_NEEDS_PASS; then
      sudo -S -k -p "" veracrypt --text --non-interactive -d "$VC_MOUNT_DIR" >/dev/null 2>&1 <<<"$VC_SUDO_PASS" || true
      sudo -S -k -p "" veracrypt --text --non-interactive -d --force "$VC_MOUNT_DIR" >/dev/null 2>&1 <<<"$VC_SUDO_PASS" || true
    else
      sudo -n veracrypt --text --non-interactive -d "$VC_MOUNT_DIR" >/dev/null 2>&1 || true
      sudo -n veracrypt --text --non-interactive -d --force "$VC_MOUNT_DIR" >/dev/null 2>&1 || true
    fi
  else
    veracrypt --text --non-interactive -d "$VC_MOUNT_DIR" >/dev/null 2>&1 || true
    veracrypt --text --non-interactive -d --force "$VC_MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  rmdir "$VC_MOUNT_DIR" 2>/dev/null || true
  VC_MOUNTED=false
  VC_MOUNT_DIR=""
}

vc_is_mounted() {
  local mount_dir="$1"
  local output=""
  if $VC_USE_SUDO; then
    if $VC_SUDO_NEEDS_PASS; then
      output="$(sudo -S -k -p "" veracrypt --text --non-interactive -l 2>/dev/null <<<"$VC_SUDO_PASS" || true)"
    else
      output="$(sudo -n veracrypt --text --non-interactive -l 2>/dev/null || true)"
    fi
  else
    output="$(veracrypt --text --non-interactive -l 2>/dev/null || true)"
  fi
  [[ "$output" == *"$mount_dir"* ]]
}

get_stat_size() {
  local path="$1"
  if $VC_USE_SUDO; then
    if $VC_SUDO_NEEDS_PASS; then
      sudo -S -k -p "" stat -c %s "$path" 2>/dev/null <<<"$VC_SUDO_PASS"
    else
      sudo -n stat -c %s "$path" 2>/dev/null
    fi
  else
    stat -c %s "$path" 2>/dev/null
  fi
}

calc_container_mb() {
  local archive="$1"
  local pad_pct="${BKP_VC_PAD_PCT:-5}"
  local pad_mb="${BKP_VC_PAD_MB:-200}"
  local size
  size=$(stat -c %s "$archive" 2>/dev/null || echo 0)
  if [[ "$size" -le 0 ]]; then
    printf '%s' 0
    return 0
  fi
  if [[ "$pad_pct" -lt 0 ]]; then
    pad_pct=0
  fi
  if [[ "$pad_mb" -lt 0 ]]; then
    pad_mb=0
  fi
  local padded=$((size + (size * pad_pct / 100) + pad_mb * 1024 * 1024))
  local mb=$(((padded + 1048575) / 1048576))
  if [[ "$mb" -lt 1 ]]; then
    mb=1
  fi
  printf '%s' "$mb"
}

is_block_device() {
  [[ -b "$1" ]]
}

prune_old() {
  local pattern="$1"
  local keep="$2"
  # shellcheck disable=SC2086
  mapfile -t items < <(ls -t -- $pattern 2>/dev/null)
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

  local ts
  ts="$(date '+%j-%Y-%H%M')"
  # Prevent concurrent runs.
  local lock_dir="/tmp/backup-full-ssd-v3"
  local lock_file="${lock_dir}/backup-full-ssd.lock"
  mkdir -p "$lock_dir"
  if ! ( set -o noclobber; : >"$lock_file" ) 2>/dev/null; then
    err "Backup already running (lock: ${lock_file})."
    exit 1
  fi
  trap 'cleanup_vc; rm -f "$lock_file"' EXIT INT TERM
  local mountpoint
  mountpoint="$(select_target)"

  local base_dir="${mountpoint}/${ts}"
  mkdir -p "$base_dir"
  local created="yes"

  status "Target: ${base_dir}"

  local encrypt_enabled=false
  local use_sudo=false
  local sudo_needs_pass=false
  local sudo_pass=""
  local vc_pass=""
  local vc_pass2=""
  local encrypt_choice
  if [[ "${EUID}" -ne 0 ]]; then
    use_sudo=true
  fi
  VC_USE_SUDO=$use_sudo
  read -r -p "Create encrypted container for archive? [y/N]: " encrypt_choice
  if [[ "$encrypt_choice" == "y" || "$encrypt_choice" == "Y" ]]; then
    encrypt_enabled=true
    if ! command_exists veracrypt; then
      local install_choice
      read -r -p "VeraCrypt not found. Install now? [y/N]: " install_choice
      if [[ "$install_choice" == "y" || "$install_choice" == "Y" ]]; then
        if command_exists pacman; then
          if [[ "${EUID}" -ne 0 ]]; then
            run_cmd sudo pacman -S --noconfirm veracrypt
          else
            run_cmd pacman -S --noconfirm veracrypt
          fi
        else
          err "pacman not available; install veracrypt manually."
        fi
      else
        err "Skipping encryption: VeraCrypt not installed."
      fi
    fi
    if ! command_exists veracrypt; then
      err "Skipping encryption: VeraCrypt not installed."
      encrypt_enabled=false
    else
      if $use_sudo; then
        if sudo -n true >/dev/null 2>&1; then
          sudo_needs_pass=false
        else
          sudo_needs_pass=true
          read -r -s -p "Sudo password (for VeraCrypt): " sudo_pass
          printf '\n'
          if [[ -z "$sudo_pass" ]]; then
            err "Empty sudo password. Skipping encryption."
            encrypt_enabled=false
          fi
        fi
      fi
      VC_SUDO_NEEDS_PASS=$sudo_needs_pass
      VC_SUDO_PASS=$sudo_pass
      read -r -s -p "VeraCrypt password: " vc_pass
      printf '\n'
      read -r -s -p "Confirm password: " vc_pass2
      printf '\n'
      if [[ -z "$vc_pass" || "$vc_pass" != "$vc_pass2" ]]; then
        err "Password mismatch or empty password. Skipping encryption."
        encrypt_enabled=false
      fi
    fi
  fi

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
    "/etc/samba/creds-euclid"
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
    --exclude=.rustup/ \
    --exclude=Shared/ArchBKP/ \
    --exclude=.ssh/agent/ \
    "${src_home}/" "${home_dir}/" || exit $?

  progress "Archive"
  run_cmd tar --ignore-failed-read -I pigz -cf "$archive_file" -C "$bkp_base" "$ts"
  status "Backup done."
  status "Target: ${base_dir}"
  status "Archive: ${archive_file}"

  progress "Encrypt archive (optional)"
  if $encrypt_enabled; then
    # Create + mount VeraCrypt container, then copy archive into it.
    if [[ ! -f "$archive_file" ]]; then
      err "Archive not found: ${archive_file}"
      exit 1
    fi
    local container_file="${bkp_base}/full-backup-${ts}.hc"
    local size_mb
    size_mb="$(calc_container_mb "$archive_file")"
    if [[ "$size_mb" -le 0 ]]; then
      err "Failed to calculate container size."
      exit 1
    fi
    local mount_dir="/tmp/vc-${ts}"
    mkdir -p "$mount_dir"
    if $use_sudo; then
      if $sudo_needs_pass; then
        if ! printf '%s\n%s\n' "$sudo_pass" "$vc_pass" | sudo -S -k -p "" \
          veracrypt --text --non-interactive --stdin \
          --create "$container_file" --size "${size_mb}M" --hash SHA-512 --encryption AES \
          --filesystem ext4 --pim 0 --keyfiles ""; then
          err "Failed to create VeraCrypt container."
          rmdir "$mount_dir" 2>/dev/null || true
          exit 1
        fi
      elif ! printf '%s\n' "$vc_pass" | sudo -n \
        veracrypt --text --non-interactive --stdin \
        --create "$container_file" --size "${size_mb}M" --hash SHA-512 --encryption AES \
        --filesystem ext4 --pim 0 --keyfiles ""; then
        err "Failed to create VeraCrypt container."
        rmdir "$mount_dir" 2>/dev/null || true
        exit 1
      fi
    elif ! printf '%s\n' "$vc_pass" | veracrypt --text --non-interactive --stdin \
      --create "$container_file" --size "${size_mb}M" --hash SHA-512 --encryption AES \
      --filesystem ext4 --pim 0 --keyfiles ""; then
      err "Failed to create VeraCrypt container."
      rmdir "$mount_dir" 2>/dev/null || true
      exit 1
    fi
    if $use_sudo; then
      if $sudo_needs_pass; then
        if ! printf '%s\n%s\n' "$sudo_pass" "$vc_pass" | sudo -S -k -p "" \
          veracrypt --text --non-interactive --stdin \
          --mount "$container_file" "$mount_dir" --pim 0 --keyfiles "" --protect-hidden no; then
          err "Failed to mount VeraCrypt container."
          sudo -S -k -p "" veracrypt --text --non-interactive -d "$mount_dir" >/dev/null 2>&1 <<<"$sudo_pass" || true
          sudo -S -k -p "" veracrypt --text --non-interactive -d --force "$mount_dir" >/dev/null 2>&1 <<<"$sudo_pass" || true
          rmdir "$mount_dir" 2>/dev/null || true
          exit 1
        fi
      elif ! printf '%s\n' "$vc_pass" | sudo -n \
        veracrypt --text --non-interactive --stdin \
        --mount "$container_file" "$mount_dir" --pim 0 --keyfiles "" --protect-hidden no; then
        err "Failed to mount VeraCrypt container."
        sudo -n veracrypt --text --non-interactive -d "$mount_dir" >/dev/null 2>&1 || true
        sudo -n veracrypt --text --non-interactive -d --force "$mount_dir" >/dev/null 2>&1 || true
        rmdir "$mount_dir" 2>/dev/null || true
        exit 1
      fi
    elif ! printf '%s\n' "$vc_pass" | veracrypt --text --non-interactive --stdin \
      --mount "$container_file" "$mount_dir" --pim 0 --keyfiles "" --protect-hidden no; then
      err "Failed to mount VeraCrypt container."
      veracrypt --text --non-interactive -d "$mount_dir" >/dev/null 2>&1 || true
      veracrypt --text --non-interactive -d --force "$mount_dir" >/dev/null 2>&1 || true
      rmdir "$mount_dir" 2>/dev/null || true
      exit 1
    fi
    VC_MOUNT_DIR="$mount_dir"
    VC_MOUNTED=true
    if $use_sudo; then
      if $sudo_needs_pass; then
        if ! printf '%s\n' "$sudo_pass" | sudo -S -k -p "" rsync -a --quiet "$archive_file" "$mount_dir/"; then
          err "Failed to copy archive into container."
          sudo -S -k -p "" veracrypt --text --non-interactive -d "$mount_dir" >/dev/null 2>&1 <<<"$sudo_pass" || true
          sudo -S -k -p "" veracrypt --text --non-interactive -d --force "$mount_dir" >/dev/null 2>&1 <<<"$sudo_pass" || true
          rmdir "$mount_dir" 2>/dev/null || true
          exit 1
        fi
      elif ! sudo -n rsync -a --quiet "$archive_file" "$mount_dir/"; then
        err "Failed to copy archive into container."
        sudo -n veracrypt --text --non-interactive -d "$mount_dir" >/dev/null 2>&1 || true
        sudo -n veracrypt --text --non-interactive -d --force "$mount_dir" >/dev/null 2>&1 || true
        rmdir "$mount_dir" 2>/dev/null || true
        exit 1
      fi
    elif ! run_cmd rsync -a --quiet "$archive_file" "$mount_dir/"; then
      err "Failed to copy archive into container."
      veracrypt --text --non-interactive -d "$mount_dir" >/dev/null 2>&1 || true
      veracrypt --text --non-interactive -d --force "$mount_dir" >/dev/null 2>&1 || true
      rmdir "$mount_dir" 2>/dev/null || true
      exit 1
    fi
    local dest_file
    dest_file="${mount_dir}/$(basename "$archive_file")"
    local src_size
    local dest_size
    src_size=$(stat -c %s "$archive_file" 2>/dev/null || echo "")
    dest_size=$(get_stat_size "$dest_file" || echo "")
    if [[ -z "$src_size" || -z "$dest_size" || "$src_size" -ne "$dest_size" ]]; then
      err "Encrypted archive verification failed."
      cleanup_vc
      exit 1
    fi

    local delete_choice="${BKP_DELETE_PLAINTEXT:-}"
    if [[ -n "$delete_choice" && "$delete_choice" != "y" && "$delete_choice" != "n" && "$delete_choice" != "Y" && "$delete_choice" != "N" ]]; then
      err "Invalid BKP_DELETE_PLAINTEXT value; use 'y' or 'n'."
      delete_choice=""
    fi
    if [[ -z "$delete_choice" ]]; then
      read -r -p "Delete plaintext archive after encryption? [y/N]: " delete_choice
    fi
    if [[ "$delete_choice" == "y" || "$delete_choice" == "Y" ]]; then
      if command_exists shred; then
        if shred -u -z -n 1 "$archive_file"; then
          status "Plaintext archive deleted: ${archive_file}"
        else
          err "Failed to delete plaintext archive."
        fi
      elif rm -f "$archive_file"; then
        status "Plaintext archive deleted: ${archive_file}"
      else
        err "Failed to delete plaintext archive."
      fi
    fi

    cleanup_vc
    status "Encrypted container: ${container_file}"
  else
    status "Encrypted container: skipped"
  fi

  prune_old "${bkp_base}/full-backup-*.tar.gz" 3
  prune_old "${bkp_base}/[0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9]" 3
}

main "$@"
