#!/usr/bin/env bash
# Publish one component to Google Artifact Registry.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/publish.sh COMPONENT [OPTIONS]

  clients       CLI, API and support Wasm components
  core          Core runtime image
  membrane      Membrane runtime image and native archives
  web-ui        Web UI npm package
  python        Indexed Python distributions
  otterdesk     OtterDesk desktop packages
  dmr           Restore the SDK catalog's native model runners
  computer-use  Signed macOS computer-use app

Run a component with --help for its options. Publishing requires --apply.
EOF
}

scripts=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
component=${1:-}
case "$component" in
"" | -h | --help) usage ;;
clients | core | membrane | web-ui | python | otterdesk)
  shift
  exec bash "$scripts/publish/$component.sh" "$@"
  ;;
dmr | computer-use)
  shift
  # shellcheck source=release/commands.sh
  source "$scripts/release/commands.sh"
  python=$(release_python "$scripts/.." python3.12)
  export PYTHONDONTWRITEBYTECODE=1
  if [[ "$component" == dmr ]]; then
    export CLOUDSDK_PYTHON="${CLOUDSDK_PYTHON:-$python}"
    exec "$python" "$scripts/publish-prepared-dmr.py" --match-catalog "$@"
  fi
  exec "$python" "$scripts/publish_computer_use_to_google_artifact_registry.py" "$@"
  ;;
*)
  printf 'error: unknown publish component %s\n' "$component" >&2
  usage >&2
  exit 2
  ;;
esac
