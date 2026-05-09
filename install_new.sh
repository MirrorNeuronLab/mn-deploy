#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MN_INSTALL_SCRIPT_NAME="$(basename "$0")" exec bash "$SCRIPT_DIR/install_bin.sh" "$@"
