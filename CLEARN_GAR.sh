#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${MN_CLEAN_GAR_PYTHON:-python3}" "${SCRIPT_DIR}/scripts/clean-gar.py" "$@"
