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

main() {
  status "--------------------------------------------------------------------------------------------"

  # Prevent concurrent runs.
  local lock_dir="/tmp/backup-rsync-v3"
  local lock_file="${lock_dir}/backup-rsync.lock"
  mkdir -p "$lock_dir"
  if ! ( set -o noclobber; : >"$lock_file" ) 2>/dev/null; then
    err "Backup already running (lock: ${lock_file})."
    exit 1
  fi
  trap 'rm -f "$lock_file"' EXIT INT TERM

  local ts
  ts="$(date '+%j-%Y-%H%M')"
  local bkp_base="/home/ralexander/Shared/ArchBKP"
  local create_archive="${BKP_CREATE_ARCHIVE:-n}"

  local bkp_folder="${bkp_base}/${ts}"
  local bkp_tar="${bkp_base}/${ts}.tar.gz"
  local root_dir="${bkp_folder}/root"
  local home_dir="${bkp_folder}/home"
  local user
  user="$(whoami)"
  mkdir -p "$bkp_base" "$bkp_folder" "$root_dir" "$home_dir"

  status "Backup start: $(date '+%Y-%m-%dT%H:%M:%S')"
  status "Target: ${bkp_base}"

  for cmd in rsync tar sudo; do
    require_command "$cmd"
  done

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

  if [[ ! -w "$bkp_base" ]]; then
    err "Backup base not writable: ${bkp_base}"
    exit 1
  fi

  progress "Pre-flight checks"

  local system_items=(
    "/boot/grub/themes/lateralus:${root_dir}"
    "/etc/mkinitcpio.conf:${root_dir}/mkinitcpio.conf"
    "/etc/default/grub:${root_dir}/grub"
    "/usr/share/plymouth/plymouthd.defaults:${root_dir}/plymouthd.defaults"
    "/etc/samba/smb.conf:${root_dir}/smb.conf"
    "/etc/samba/euclid:${root_dir}/euclid"
    "/etc/ssh/sshd_config:${root_dir}/sshd_config"
    "/usr/lib/sddm/sddm.conf.d/default.conf:${root_dir}/default.conf"
    "/etc/fstab:${root_dir}/fstab"
  )

  progress "System files"
  local item src dest
  for item in "${system_items[@]}"; do
    src="${item%%:*}"
    dest="${item##*:}"
    [[ -e "$src" ]] || continue
    mkdir -p "$(dirname "$dest")"
    run_rsync_allow_partial sudo rsync -a --quiet "--chown=${user}:${user}" "$src" "$dest" || exit $?
  done

  local user_paths=("Documents" "Obsidian" "Working" "Code" ".icons" ".themes" ".config" ".zshrc" ".zsh_history" ".mydotfiles" ".gitconfig")
  local excludes=(
    ".cache/" ".var/app/" ".subversion/" ".mozilla/" ".local/share/fonts/"
    ".vscode-oss/" "Trash/" ".config/*/Cache/" ".config/*/cache/" ".config/*/Code Cache/"
    ".config/*/GPUCache/" ".config/*/CachedData/" ".config/*/CacheStorage/"
    ".config/*/Service Worker/" ".config/*/IndexedDB/" ".config/*/Local Storage/"
    ".config/rambox/"
    ".rustup/"
    ".local/share/fonts/NerdFonts/"
  )
  local exclude_args=()
  local ex
  for ex in "${excludes[@]}"; do
    exclude_args+=("--exclude=${ex}")
  done

  progress "User files"
  local path
  for path in "${user_paths[@]}"; do
    src="${HOME}/${path}"
    [[ -e "$src" ]] || continue
    run_rsync_allow_partial rsync -a --human-readable --partial --partial-dir=.rsync-partial --quiet \
      "${exclude_args[@]}" \
      "$src" "$home_dir" || exit $?
  done

  progress "SSH keys"
  local ssh_dir="${HOME}/.ssh"
  if [[ -d "$ssh_dir" ]]; then
    run_rsync_allow_partial rsync -a --human-readable --partial --partial-dir=.rsync-partial --quiet \
      --exclude=agent/ "${ssh_dir}/" "${home_dir}/.ssh/" || exit $?
  fi

  progress "Archive"
  if [[ "${create_archive}" == "y" ]]; then
    run_cmd tar --ignore-failed-read -I pigz -cf "$bkp_tar" -C "$bkp_base" "$ts"
    status "Archive: ${bkp_tar}"
  else
    status "Archive: skipped"
  fi

  status "Backup done."
  status "Target: ${bkp_base}"
}

main "$@"
