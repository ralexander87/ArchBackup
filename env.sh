#!/usr/bin/env bash
set -euo pipefail

# Activate local virtual environment and keep shell-friendly defaults.
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.venv/bin/activate"
PYTHONPATH="$(pwd):${PYTHONPATH:-}"
export PYTHONPATH
