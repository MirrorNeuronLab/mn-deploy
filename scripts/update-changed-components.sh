#!/usr/bin/env bash
# Publish component fixes without advancing Core or the installer release.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLISH_PYTHON="${MN_PUBLISH_PYTHON:-${MN_GAR_PUBLISH_VENV:-${SCRIPT_DIR}/../.venv-gar-publish}/bin/python}"
if ! command -v "$PUBLISH_PYTHON" >/dev/null 2>&1; then
    PUBLISH_PYTHON="${MN_PUBLISH_PYTHON:-python3}"
fi
exec "$PUBLISH_PYTHON" "${SCRIPT_DIR}/update-changed-components.py" "$@"
