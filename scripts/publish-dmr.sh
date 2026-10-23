#!/usr/bin/env bash
# Restore the SDK catalog's shared native DMR runner archives to public GAR.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLISH_PYTHON="${MN_PUBLISH_PYTHON:-${MN_GAR_PUBLISH_VENV:-${SCRIPT_DIR}/../.venv-gar-publish}/bin/python}"
if ! command -v "$PUBLISH_PYTHON" >/dev/null 2>&1; then
    PUBLISH_PYTHON="${MN_PUBLISH_PYTHON:-python3.12}"
fi
if ! command -v "$PUBLISH_PYTHON" >/dev/null 2>&1; then
    printf '%s\n' 'error: Set MN_PUBLISH_PYTHON to Python 3.12+ with the matching MirrorNeuron SDK installed.' >&2
    exit 1
fi
export CLOUDSDK_PYTHON="${CLOUDSDK_PYTHON:-$PUBLISH_PYTHON}"
exec "$PUBLISH_PYTHON" "${SCRIPT_DIR}/publish-prepared-dmr.py" --match-catalog "$@"
