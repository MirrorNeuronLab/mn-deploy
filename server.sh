#!/usr/bin/env bash
set -euo pipefail

# The installed lifecycle entry point owns startup ordering and role checks.
MN_INSTALL_HOME="${MN_HOME:-${HOME}/.mn}"
export MN_HOME="$MN_INSTALL_HOME"
if [ -f "$MN_INSTALL_HOME/install_metadata.json" ] && grep -Eq '"install_role"[[:space:]]*:[[:space:]]*"client"' "$MN_INSTALL_HOME/install_metadata.json"; then
  if [ "${1:-status}" = "status" ]; then
    printf '{"status":"client","runtime_installed":false}\n'
    exit 0
  fi
  printf 'error: No runtime is installed in client mode. Connect with mn node add.\n' >&2
  exit 1
fi
if [ -x "$MN_INSTALL_HOME/venv/bin/python" ]; then
  if [ "$#" -eq 0 ]; then set -- status; fi
  exec "$MN_INSTALL_HOME/venv/bin/python" -m mn_runtime.lifecycle "$@"
fi
printf 'error: No runtime installation found at %s. Use install.sh or set MN_HOME.\n' "$MN_INSTALL_HOME" >&2
exit 1
