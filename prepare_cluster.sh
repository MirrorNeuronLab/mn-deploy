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

advertise_host="${MN_NETWORK_ADVERTISE_HOST:-${1:-}}"
if [ -z "$advertise_host" ]; then
  advertise_host="$(detect_lan_ip)"
fi
if [ -z "$advertise_host" ]; then
  echo "Could not infer MN_NETWORK_ADVERTISE_HOST; set it or pass the host as the first argument." >&2
  exit 1
fi

mn stop

MN_NETWORK_ADVERTISE_HOST="$advertise_host" \
MN_GRPC_BIND_HOST="${MN_GRPC_BIND_HOST:-0.0.0.0}" \
MN_EPMD_BIND_HOST="${MN_EPMD_BIND_HOST:-0.0.0.0}" \
MN_DIST_BIND_HOST="${MN_DIST_BIND_HOST:-0.0.0.0}" \
ERL_EPMD_ADDRESS="${ERL_EPMD_ADDRESS:-0.0.0.0}" \
mn start

docker port mirror-neuron-core 50051
