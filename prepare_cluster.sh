#!/usr/bin/env bash
set -euo pipefail

detect_lan_ip() {
  if ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi
  python3 - <<'PY'
import socket

probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    probe.connect(("10.255.255.255", 1))
    print(probe.getsockname()[0])
except OSError:
    pass
finally:
    probe.close()
PY
}

syncthing_gui_port() {
  if [ -n "${MN_SYNCTHING_GUI_PORT:-}" ]; then
    printf '%s\n' "$MN_SYNCTHING_GUI_PORT"
    return 0
  fi

  local mn_runtime_dir="${MN_HOME:-${HOME:-}/.mn}"
  local compose_env_file="$mn_runtime_dir/docker-compose.env"
  if [ -f "$compose_env_file" ]; then
    awk -F= '$1 == "MN_SYNCTHING_GUI_PORT" { port = $2 } END { print port }' "$compose_env_file"
  fi
}

syncthing_gui_port_is_released() {
  local port="$1"
  python3 - "$port" <<'PY'
import socket
import sys

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    sock.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
PY
}

wait_for_syncthing_gui_port_release() {
  local port="$1"
  local attempt

  case "$port" in
    ''|*[!0-9]*) return 0 ;;
  esac

  for ((attempt = 0; attempt < 40; attempt += 1)); do
    if syncthing_gui_port_is_released "$port"; then
      return 0
    fi
    sleep 0.5
  done

  echo "Syncthing GUI port $port was not released after stopping the runtime." >&2
  return 1
}

advertise_host="${MN_NETWORK_ADVERTISE_HOST:-${1:-}}"
if [ -z "$advertise_host" ]; then
  advertise_host="$(detect_lan_ip)"
fi
if [ -z "$advertise_host" ]; then
  echo "Could not infer MN_NETWORK_ADVERTISE_HOST; set it or pass the host as the first argument." >&2
  exit 1
fi

mn runtime stop

configured_syncthing_gui_port="$(syncthing_gui_port)"
if [ -n "$configured_syncthing_gui_port" ]; then
  wait_for_syncthing_gui_port_release "$configured_syncthing_gui_port"
fi

MN_NETWORK_ADVERTISE_HOST="$advertise_host" \
MN_GRPC_BIND_HOST="${MN_GRPC_BIND_HOST:-0.0.0.0}" \
MN_EPMD_BIND_HOST="${MN_EPMD_BIND_HOST:-0.0.0.0}" \
MN_DIST_BIND_HOST="${MN_DIST_BIND_HOST:-0.0.0.0}" \
ERL_EPMD_ADDRESS="${ERL_EPMD_ADDRESS:-0.0.0.0}" \
mn runtime start

docker port mirror-neuron-core 50051
