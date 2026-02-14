#!/usr/bin/env bash
set -euo pipefail

# Activate local virtual environment and keep shell-friendly defaults.
# Resolve this file's directory for both bash and zsh.
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
	script_path="${BASH_SOURCE[0]}"
elif [[ -n "${ZSH_VERSION:-}" ]]; then
	script_path="${(%):-%N}"
else
	script_path="$0"
fi

# shellcheck disable=SC1091
source "$(cd "$(dirname "${script_path}")" && pwd)/.venv/bin/activate"
PYTHONPATH="$(pwd):${PYTHONPATH:-}"
export PYTHONPATH
