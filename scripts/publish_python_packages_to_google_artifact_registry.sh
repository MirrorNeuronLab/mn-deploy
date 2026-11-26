#!/usr/bin/env bash
# setup_google_artifact_registry.sh prints this command after registry setup.
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/publish.sh" python "$@"
