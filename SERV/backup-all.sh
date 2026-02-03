#!/usr/bin/env bash
set -uo pipefail

# Run all backups (DOTS + SERV submodules) in one go.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_file="${script_dir}/backup-all.log"

# Parse flags (forwarded to sub-scripts).
args=(--no-banner --yes)
while [[ $# -gt 0 ]]; do
	args+=("$1")
	shift
done

exec > >(tee -a "$log_file") 2>&1

run_script() {
	local label="$1"
	local path="$2"
	echo "==== ${label} ===="
	if [[ -x "$path" ]]; then
		"$path" "${args[@]}"
		return $?
	else
		echo "Missing or not executable: ${path}" >&2
		return 1
	fi
}

failures=0
run_script "DOTS" "${script_dir}/../DOTS/backup-dots.sh" || failures=$((failures + 1))
run_script "GRUB" "${script_dir}/GRUB/backup-grub.sh" || failures=$((failures + 1))
run_script "SMB" "${script_dir}/SMB/backup-smb.sh" || failures=$((failures + 1))
run_script "SSH" "${script_dir}/SSH/backup-ssh.sh" || failures=$((failures + 1))

echo "SERV backups completed. failures=${failures}"
if ((failures > 0)); then
	exit 1
fi
