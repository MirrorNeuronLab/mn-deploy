#!/usr/bin/env bash
set -euo pipefail

detect_lan_ip() {
  if ! command -v python3 >/dev/null 2>&1; then
    return 0
  fi
  python3 - <<'PY'
import ipaddress
import socket
import subprocess


def physical_interface_addresses():
    """Return ordinary interface addresses before VPN/tunnel addresses.

    A UDP route probe can select an overlay route (for example macOS ipsec0),
    whose address is often unreachable from a peer on the physical LAN.  The
    advertised cluster endpoint must prefer an address on a non-point-to-point
    network interface instead.
    """
    try:
        output = subprocess.run(
            ["ifconfig"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return []

    addresses = []
    is_usable_interface = False
    for raw_line in output.splitlines():
        if raw_line and not raw_line[0].isspace() and ":" in raw_line:
            interface, details = raw_line.split(":", 1)
            is_virtual = interface.startswith(
                ("docker", "br-", "veth", "virbr", "tailscale", "utun", "ipsec", "tun", "tap", "wg")
            )
            is_usable_interface = (
                "LOOPBACK" not in details
                and "POINTOPOINT" not in details
                and not is_virtual
            )
            continue

        fields = raw_line.split()
        if not is_usable_interface or len(fields) < 2 or fields[0] != "inet":
            continue
        try:
            address = ipaddress.ip_address(fields[1])
        except ValueError:
            continue
        if not address.is_loopback and not address.is_link_local:
            addresses.append(address)

    private_addresses = [address for address in addresses if address.is_private]
    return [str(address) for address in private_addresses or addresses]


for candidate in physical_interface_addresses():
    print(candidate)
    raise SystemExit(0)

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
