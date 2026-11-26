#!/usr/bin/env bash

set -euo pipefail

# Give streamed Linux installs a script path while keeping the streamed
# invocation's name and asset lookup behavior.
if [ -z "${BASH_SOURCE[0]:-}" ] && [ -z "${BASH_EXECUTION_STRING:-}" ] && [ "$(uname -s)" = "Linux" ]; then
  mn_streamed_installer="$(mktemp "${TMPDIR:-/tmp}/mn-install.XXXXXX")"
  trap 'rm -f "$mn_streamed_installer"' EXIT
  cat >"$mn_streamed_installer"
  MN_INSTALL_STREAM_NAME="$0" "$BASH" -euo pipefail "$mn_streamed_installer" "$@" </dev/null
  exit
fi

# Keep installer output visible even when a subcommand redirects stdout/stderr.
exec 3>&1

# =============================================================================
# COMPONENT VERSION AND IMAGE DEFAULTS — EDIT HERE
# =============================================================================
# These are the installer defaults, grouped by installation source so a release
# can advance one component without silently changing the others. A matching
# command-line option or component environment variable still takes precedence.
#
# Pip-installed add-ons are deliberately single-sourced in
# package-index/python-packages.toml. MN_DEFAULT_AGENT_PACKAGE_INDEX_VERSION
# selects that indexed inventory; do not duplicate its individual package pins
# here.

# MirrorNeuron releases by installation source.
# Core is a GAR Podman image.
MN_DEFAULT_CORE_VERSION="${MN_DEFAULT_CORE_VERSION:-v1.4.1}"
# The SDK uses pip. The native client has its own release line.
MN_DEFAULT_CLIENT_VERSION="${MN_DEFAULT_CLIENT_VERSION:-v2.0.0}"
MN_DEFAULT_PYTHON_SDK_VERSION="${MN_DEFAULT_PYTHON_SDK_VERSION:-v1.4.23}"
MN_DEFAULT_CLI_VERSION="${MN_DEFAULT_CLI_VERSION:-v2.0.0}"
MN_DEFAULT_API_VERSION="${MN_DEFAULT_API_VERSION:-v2.0.0}"
# Web UI is a GAR npm package (the installer strips the leading `v`).
MN_DEFAULT_WEB_UI_VERSION="${MN_DEFAULT_WEB_UI_VERSION:-v1.4.3}"
# Additional pip packages are selected from the versioned package index.
MN_DEFAULT_AGENT_PACKAGE_INDEX_VERSION="${MN_DEFAULT_AGENT_PACKAGE_INDEX_VERSION:-v2.0.0}"
# Membrane v2 context engine is a GAR Podman image.
MN_DEFAULT_MEMBRANE_CONTEXT_ENGINE_VERSION="${MN_DEFAULT_MEMBRANE_CONTEXT_ENGINE_VERSION:-v1.4.0}"

# Google Artifact Registry coordinates.
MN_DEFAULT_CORE_GAR_PROJECT="${MN_DEFAULT_CORE_GAR_PROJECT:-mirrorneuron-public-packages}"
MN_DEFAULT_CORE_GAR_LOCATION="${MN_DEFAULT_CORE_GAR_LOCATION:-us-central1}"
MN_DEFAULT_CORE_GAR_DOCKER_REPOSITORY="${MN_DEFAULT_CORE_GAR_DOCKER_REPOSITORY:-mirrorneuron-runtime}"
MN_DEFAULT_CORE_GAR_DOCKER_IMAGE_NAME="${MN_DEFAULT_CORE_GAR_DOCKER_IMAGE_NAME:-mirror-neuron-core}"
MN_DEFAULT_MEMBRANE_GAR_IMAGE="${MN_DEFAULT_MEMBRANE_GAR_IMAGE:-us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/membrane-context-engine}"
MN_DEFAULT_PIP_INDEX_URL="${MN_DEFAULT_PIP_INDEX_URL:-https://us-central1-python.pkg.dev/mirrorneuron-public-packages/agent-skills/simple/}"
MN_DEFAULT_PYTHON_GAR_LOCATION="${MN_DEFAULT_PYTHON_GAR_LOCATION:-us-central1}"
MN_DEFAULT_PYTHON_GAR_REPOSITORY="${MN_DEFAULT_PYTHON_GAR_REPOSITORY:-agent-skills}"
MN_DEFAULT_WEB_UI_GAR_NPM_REPOSITORY="${MN_DEFAULT_WEB_UI_GAR_NPM_REPOSITORY:-mirrorneuron-npm}"
MN_DEFAULT_WEB_UI_NPM_REGISTRY="${MN_DEFAULT_WEB_UI_NPM_REGISTRY:-https://us-central1-npm.pkg.dev/mirrorneuron-public-packages/mirrorneuron-npm/}"

# Podman images started directly by the installer or generated Compose config.
MN_DEFAULT_REDIS_IMAGE="${MN_DEFAULT_REDIS_IMAGE:-docker.io/library/redis:8}"
# These upstream images intentionally retain their existing mutable `latest`
# policy. Replace `latest` with a release tag or digest here to pin them.
MN_DEFAULT_SYNCTHING_IMAGE="${MN_DEFAULT_SYNCTHING_IMAGE:-docker.io/syncthing/syncthing:latest}"
# Keep the OpenShell gateway and supervisor on matching releases so the
# gateway can extract /openshell-sandbox at startup.
MN_DEFAULT_OPENSHELL_GATEWAY_IMAGE="${MN_DEFAULT_OPENSHELL_GATEWAY_IMAGE:-ghcr.io/nvidia/openshell/gateway:0.0.47}"
# The WAC release and the platform digests in mn_install_wac are one pin.
MN_WAC_VERSION="v0.12.0"

# Python toolchain. Leave MN_DEFAULT_UV_VERSION empty to preserve the upstream
# installer’s current-release behavior; set it to a uv release to pin it.
MN_DEFAULT_MANAGED_PYTHON_VERSION="${MN_DEFAULT_MANAGED_PYTHON_VERSION:-3.12}"
MN_MANAGED_PYTHON_VERSION="${MN_MANAGED_PYTHON_VERSION:-$MN_DEFAULT_MANAGED_PYTHON_VERSION}"
MN_DEFAULT_UV_VERSION="${MN_DEFAULT_UV_VERSION:-}"

# Model artifacts referenced by generated Compose configuration.
MN_DEFAULT_LLM_MODEL_RUNNER_MODEL="${MN_DEFAULT_LLM_MODEL_RUNNER_MODEL:-nemotron-3.5-bolt-e4b:q4_k_m}"

MN_INSTALL_MODE_EXPLICIT=N
if [ -n "${MN_INSTALL_MODE:-}" ]; then MN_INSTALL_MODE_EXPLICIT=Y; fi
MN_INSTALL_MODE="${MN_INSTALL_MODE:-binary}"
MN_INSTALL_HELP_REQUESTED="N"
MN_INSTALL_HELP_ALL="N"
MN_INSTALL_VERBOSE="${MN_INSTALL_VERBOSE:-N}"
MN_INSTALL_RESET="N"
MN_INSTALL_DETECT_ONLY="N"
MN_INSTALL_START_PODMAN="N"
MN_NO_RUNTIME="N"
MN_RUNTIME_ONLY="N"
MN_INSTALL_ROLE="full"
MN_BUILD_MEMBRANE="N"
MN_BUILD_MEMBRANE_DIR=""
MN_MEMBRANE_BUILD_PREPARED="N"
# The installer release has its own tag. It selects the versioned support
# snapshot while the component pins above select each published artifact.
MN_DEFAULT_INSTALL_VERSION="${MN_DEFAULT_INSTALL_VERSION:-v1.4.0}"
# Support snapshots can advance independently when repairing component packages.
MN_DEFAULT_INSTALL_SUPPORT_VERSION="${MN_DEFAULT_INSTALL_SUPPORT_VERSION:-v2.0.0}"
MN_INSTALL_VERSION="${MN_INSTALL_VERSION:-}"
MN_INSTALL_SCRIPT_NAME="$(basename "${MN_INSTALL_STREAM_NAME:-$0}")"
MN_INSTALL_ARGS=()

# Presentation is shared by every mode and stays self-contained for curl | bash.
# Only stage boundaries and actionable messages appear in the default output.
BOLD="" DIM="" RED="" GREEN="" YELLOW="" CYAN="" RESET=""
if [ -t 3 ] && [ -z "${NO_COLOR+x}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
  ESC="$(printf '\033')"
  BOLD="${ESC}[1m" DIM="${ESC}[2m" RED="${ESC}[31m" GREEN="${ESC}[32m"
  YELLOW="${ESC}[33m" CYAN="${ESC}[36m" RESET="${ESC}[0m"
fi
MN_INSTALL_STAGE=0
MN_INSTALL_STAGES=3
MN_INSTALL_STARTED=$SECONDS
MN_INSTALL_CLIENT_COMPONENTS=""

function mn_ui_animated() {
  [ -t 3 ] && [ -z "${NO_COLOR+x}" ] && [ "${TERM:-dumb}" != "dumb" ] && [ "$MN_INSTALL_VERBOSE" != "Y" ]
}

function mn_ui_clear_line() {
  if mn_ui_animated; then printf '\r\033[2K' >&3; fi
}

function print_header() {
  printf '\n  %sOtterDesk Installer%s\n  %s──────────────────────────────────────────%s\n' "$BOLD" "$RESET" "$DIM" "$RESET" >&3
}

function print_detail() {
  if [ "$MN_INSTALL_VERBOSE" = "Y" ]; then
    printf '    %s%s%s\n' "$DIM" "$1" "$RESET" >&3
  fi
}

function print_step() {
  print_detail "$1"
}

function print_success() {
  mn_ui_clear_line
  printf '%s✓%s %s\n' "${GREEN}${BOLD}" "$RESET" "$1" >&3
}

function print_error() {
  mn_ui_clear_line
  printf '%serror:%s %s\n' "${RED}${BOLD}" "$RESET" "$1" >&3
}

function print_warning() {
  mn_ui_clear_line
  printf '%swarning:%s %s\n' "${YELLOW}${BOLD}" "$RESET" "$1" >&3
}

function mn_print_stage() {
  MN_INSTALL_STAGE=$((MN_INSTALL_STAGE + 1))
  printf '%s==>%s [%s/%s] %s\n' "${CYAN}${BOLD}" "$RESET" "$MN_INSTALL_STAGE" "$MN_INSTALL_STAGES" "$1" >&3
}

function mn_print_stage_result() {
  printf '  %s✓%s %-22s %s\n' "${GREEN}${BOLD}" "$RESET" "$1" "$2" >&3
}

function mn_report_system() {
  local os arch platform ram="" gpu="" vendor device
  mn_print_stage "Checking the system"
  os="$(uname -s)"
  arch="$(uname -m)"
  platform="$os · $arch"
  case "$os" in
  Darwin)
    platform="macOS · $arch"
    if [ "$arch" = arm64 ] || [ "$arch" = aarch64 ]; then
      platform="macOS · Apple Silicon"
      gpu="Metal GPU (host)"
    fi
    ram="$(sysctl -n hw.memsize 2>/dev/null | LC_ALL=C awk '/^[0-9]+$/ {printf "%.1f GiB RAM", $1 / 1073741824}' 2>/dev/null || true)"
    ;;
  Linux)
    ram="$(LC_ALL=C awk '$1 == "MemTotal:" {printf "%.1f GiB RAM", $2 / 1048576; exit}' /proc/meminfo 2>/dev/null || true)"
    if [ -d /proc/driver/nvidia/gpus ]; then gpu="NVIDIA GPU"; fi
    for device in /sys/class/drm/card[0-9]*/device/vendor; do
      if [ -n "$gpu" ]; then break; fi
      [ -r "$device" ] && IFS= read -r vendor <"$device" || continue
      case "$vendor" in
      0x10de) gpu="NVIDIA GPU" ;;
      0x1002) gpu="AMD GPU" ;;
      0x8086) gpu="Intel GPU" ;;
      *) gpu="GPU present" ;;
      esac
    done
    ;;
  esac
  mn_print_stage_result "System detected" "$platform"
  mn_print_stage_result "Hardware detection" "${gpu:-GPU not detected}${ram:+ · $ram}"
}

# Capture chatty external tools without hiding failure details or changing their
# status. Logs live in the installer's private temporary directory.
function mn_run_logged() {
  local label="$1" status command_umask log_dir="${TMPDIR:-/tmp}/mirror_neuron_install"
  shift
  if [ "$MN_INSTALL_VERBOSE" = "Y" ]; then
    "$@"
    return $?
  fi
  local log_file="${log_dir}/${label//[^A-Za-z0-9_.-]/_}.$$.log"
  mkdir -p "$log_dir"
  if (
    command_umask="$(umask)"
    umask 077
    exec >"$log_file" 2>&1 || exit $?
    umask "$command_umask"
    "$@"
  ); then
    rm -f "$log_file"
    return 0
  else
    status=$?
  fi
  print_error "$label failed. Details: $log_file"
  printf '  Re-run with --verbose for command output.\n' >&3
  return "$status"
}

function spinner() {
  local pid=$1 msg=$2 started=$SECONDS status=0 frame=0
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  if mn_ui_animated; then
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r\033[2K  %s%s%s %s (%ss)' "$CYAN" "${frames[$frame]}" "$RESET" "$msg" "$((SECONDS - started))" >&3
      frame=$(((frame + 1) % ${#frames[@]}))
      sleep 0.1
    done
    mn_ui_clear_line
  fi
  wait "$pid" || status=$?
  if [ "$status" -ne 0 ]; then
    print_error "$msg failed."
    exit "$status"
  fi
  print_detail "$msg completed in $((SECONDS - started))s."
}

function ask() {
  local prompt="$1" default="$2" answer suffix input_fd=0
  if [ "$NON_INTERACTIVE" = "Y" ]; then
    printf '%s\n' "$default"
    return
  fi
  case "$default" in
  Y) suffix="Y/n" ;;
  N) suffix="y/N" ;;
  *) suffix="$default" ;;
  esac
  # curl | bash needs /dev/tty; a pipe or CI without a controlling terminal
  # must still support scripted input, and must fail clearly on EOF.
  if [ ! -t 0 ] && { exec 4</dev/tty; } 2>/dev/null; then input_fd=4; fi
  while true; do
    printf '  %s [%s]: ' "$prompt" "$suffix" >&3
    if ! IFS= read -r answer <&"$input_fd"; then
      [ "$input_fd" -ne 4 ] || exec 4<&-
      printf '\n' >&3
      print_error "No input available. Run with --yes for defaults, or --interactive in a terminal."
      return 1
    fi
    [ -n "$answer" ] || answer="$default"
    case "$answer" in
    [Yy] | [Yy][Ee][Ss]) answer="Y" ;;
    [Nn] | [Nn][Oo]) answer="N" ;;
    *)
      printf '  Enter y or n, or press Enter to accept the default.\n' >&3
      continue
      ;;
    esac
    [ "$input_fd" -ne 4 ] || exec 4<&-
    printf '%s\n' "$answer"
    return
  done
}

function print_unified_usage() {
  cat >&3 <<EOF
OtterDesk Installer

Usage: ./$MN_INSTALL_SCRIPT_NAME [--mode github|local|binary] [options]

Install the client and a local Podman runtime, or select either part.
Component choices use defaults. sudo can prompt in a terminal to install Podman.

Common options:
  --no-runtime       Client mode: CLI, API and client support. Home: ~/.mn.
  --runtime-only     Runtime mode: execution services only. Home: ~/.mn-runtime.
                     Binary only. Override either home with MN_HOME.
  --mode MODE        binary (default), github, or local source.
  --interactive      Choose components and startup interactively.
  --yes, -y          Use component defaults and require non-interactive sudo.
  --no-start         Prepare selected services without starting them.
  --no-web-ui        Skip the Web UI.
  --version TAG      Select a release (binary or GitHub mode).
  --reset            Permanently clear existing data; always requires typing YES.
  --start-podman     Start an existing Podman installation and exit.
  --detect-only      Print installation status as JSON without making changes.
  -v, --verbose      Show component details and diagnostics.
  -h, --help         Show this help; add --mode MODE for mode-specific options.
  --help-all         Show the full option reference for the selected mode.

Examples:
  ./$MN_INSTALL_SCRIPT_NAME --no-runtime
  ./$MN_INSTALL_SCRIPT_NAME --interactive
  ./$MN_INSTALL_SCRIPT_NAME --mode local

Runtime home: ~/.mn. Set MN_HOME to choose another directory.
EOF
}

function print_extended_usage() {
  cat >&3 <<EOF
OtterDesk Installer: full option reference

Common controls (available before mode-specific setup):
  --mode MODE          binary (released packages, default), github, or local.
  --no-runtime         Client mode: install CLI/API for remote execution only.
  --runtime-only       Runtime mode: execution services without CLI/API or Web UI.
                       Default home: ~/.mn-runtime.
  --start-podman       Start existing Podman only; install nothing.
  --detect-only        Print installation status as JSON; make no changes.
  --reset              Permanently clear existing data; always requires typing YES.
  --help-all           Show this reference for the selected mode; make no changes.
  MN_HOME=/path        Override the installation home (runtime default: ~/.mn).

Mode-specific options follow. Use --interactive to choose components.

EOF
}

# =============================================================================
# PODMAN INSTALLATION AND STARTUP
# =============================================================================

function mn_podman_admin() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif [ "${MN_PODMAN_SUDO_NON_INTERACTIVE:-Y}" = N ]; then
    sudo "$@"
  else
    sudo -n "$@"
  fi
}

function mn_install_podman_cli() {
  print_step "Installing the Podman CLI"
  case "$(uname -s)" in
  Darwin)
    if command -v brew >/dev/null 2>&1; then
      # Newer Homebrew asks by default; older versions use HOMEBREW_ASK to opt in.
      HOMEBREW_NO_ASK=1 HOMEBREW_ASK="" brew install --formula podman
      return
    fi
    (
      local pkg_dir package
      pkg_dir="$(mktemp -d)" || exit 1
      trap 'rm -rf "$pkg_dir"' EXIT
      package="$pkg_dir/podman.pkg"
      curl -fsSL --retry 3 https://github.com/containers/podman/releases/download/v5.6.2/podman-installer-macos-universal.pkg -o "$package" || exit 1
      printf '%s  %s\n' 0640ac3ac9351f76360ada0bf8bce905c13f68f1d212fb593a686e133064b7ce "$package" | shasum -a 256 -c - || exit 1
      mn_podman_admin /usr/sbin/installer -pkg "$package" -target /
    ) || return 1
    export PATH="/opt/podman/bin:$PATH"
    return 0
    ;;
  Linux)
    if command -v apt-get >/dev/null 2>&1; then
      local recommends=--no-install-recommends
      if [ "$(id -u)" -ne 0 ]; then
        # Debian and Ubuntu package rootless UID mapping and networking as Recommends.
        recommends=--install-recommends
      fi
      mn_podman_admin apt-get update && mn_podman_admin apt-get install -y "$recommends" podman
      return
    elif command -v dnf >/dev/null 2>&1; then
      mn_podman_admin dnf install -y --setopt=install_weak_deps=False podman
      return
    elif command -v pacman >/dev/null 2>&1; then
      mn_podman_admin pacman -S --needed --noconfirm podman
      return
    fi
    ;;
  esac
  print_error "Install the Podman CLI for this platform and rerun the installer."
  return 1
}

# Bind mounts are resolved by the engine. On a Mac this is the socket inside
# the Podman machine, even though the client connects via a forwarded socket.
function mn_resolve_podman_socket() {
  local socket_path="${PODMAN_HOST_SOCKET:-}"
  if [ -z "$socket_path" ]; then
    socket_path="$(podman info --format '{{.Host.RemoteSocket.Path}}')" || return 1
  fi
  socket_path="${socket_path#unix://}"
  if [[ "$socket_path" != /* || "$socket_path" == *:* ||
    "$socket_path" == *$'\n'* || "$socket_path" == *$'\r'* ]]; then
    print_error "Expected an absolute Podman API socket path. Check PODMAN_HOST_SOCKET or podman info."
    return 1
  fi
  printf '%s\n' "$socket_path"
}

function mn_start_podman() {
  local mode="${1:-only}" host_os socket_path
  if ! command -v podman >/dev/null 2>&1; then
    print_error "Podman CLI is missing. Install Podman or run the runtime installer."
    return 1
  fi
  host_os="$(uname -s)"
  case "$host_os" in
  Darwin | MINGW* | MSYS* | CYGWIN*)
    if ! podman info >/dev/null 2>&1; then
      if [ -n "${CONTAINER_HOST:-}${CONTAINER_CONNECTION:-}" ]; then
        print_error "The selected Podman connection is unreachable. Check it with podman info."
        return 1
      fi
      if ! podman machine inspect >/dev/null 2>&1; then
        if [ "$mode" != install ]; then
          print_error "No Podman machine is configured. Run podman machine init first."
          return 1
        fi
        podman machine init || return 1
      fi
      podman machine start || return 1
    fi
    ;;
  Linux)
    podman info >/dev/null || return 1
    socket_path="$(mn_resolve_podman_socket)" || return 1
    if [ -z "${CONTAINER_HOST:-}${CONTAINER_CONNECTION:-}" ] && [ ! -S "$socket_path" ]; then
      if [ "$(id -u)" -eq 0 ]; then
        systemctl start podman.socket || return 1
      else
        systemctl --user start podman.socket || return 1
      fi
    fi
    ;;
  *)
    print_error "Unsupported Podman host OS: $host_os"
    return 1
    ;;
  esac
  podman info >/dev/null || return 1
  [ "$mode" != only ] || print_success "Podman is ready."
}

function mn_ensure_podman_for_install() {
  if ! command -v podman >/dev/null 2>&1; then
    mn_install_podman_cli || return 1
  fi
  mn_start_podman install || return 1
  PODMAN_HOST_SOCKET="$(mn_resolve_podman_socket)" || return 1
  export PODMAN_HOST_SOCKET
}

function mn_prepare_runtime_podman() {
  mn_ensure_podman_for_install || return 1
  local rootless container_uid container_gid
  rootless="$(podman info --format '{{.Host.Security.Rootless}}')" || return 1
  if [ "$rootless" = true ]; then
    # UID/GID 0 inside the default rootless namespace map to the invoking user.
    container_uid=0
    container_gid=0
  else
    container_uid="$(id -u)"
    container_gid="$(id -g)"
    if [ -z "${OPENSHELL_GATEWAY_DOCKER_GROUP:-}" ] && [ -S "$PODMAN_HOST_SOCKET" ]; then
      OPENSHELL_GATEWAY_DOCKER_GROUP="$(stat -c '%g' "$PODMAN_HOST_SOCKET" 2>/dev/null || stat -f '%g' "$PODMAN_HOST_SOCKET" 2>/dev/null || true)"
    fi
  fi
  OPENSHELL_GATEWAY_USER="${OPENSHELL_GATEWAY_USER:-$container_uid:$container_gid}"
  OPENSHELL_GATEWAY_DOCKER_GROUP="${OPENSHELL_GATEWAY_DOCKER_GROUP:-0}"
  MN_SYNCTHING_UID="${MN_SYNCTHING_UID:-$container_uid}"
  MN_SYNCTHING_GID="${MN_SYNCTHING_GID:-$container_gid}"
}

# =============================================================================
# READ-ONLY RUNTIME DETECTION
# =============================================================================

function mn_detect_version_is_valid() {
  local version="$1"
  local version_regex='^v(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)([-+][0-9A-Za-z.-]+)?$'

  [[ "$version" =~ $version_regex ]]
}

function mn_detect_version_from_metadata() {
  local metadata_file="$1"
  local version=""

  [ -r "$metadata_file" ] || return 1
  version="$(sed -n 's/^[[:space:]]*"core_release_tag"[[:space:]]*:[[:space:]]*"\([^"]*\)"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p' "$metadata_file" | head -n 1)"
  mn_detect_version_is_valid "$version" || return 1
  printf '%s' "$version"
}

function mn_detect_version_from_podman() {
  local image=""
  local version=""

  image="$(podman container inspect --format '{{.Config.Image}}' mirror-neuron-core 2>/dev/null || true)"
  if [ -n "$image" ]; then
    version="$(podman image inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$image" 2>/dev/null || true)"
  fi
  if [ -z "$version" ]; then
    version="$(podman image inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' mirror-neuron-core:latest 2>/dev/null || true)"
  fi
  mn_detect_version_is_valid "$version" || return 1
  printf '%s' "$version"
}

function mn_detect_version_from_cli() {
  local cli="$1"
  local output=""
  local version=""

  [ -x "$cli" ] || return 1
  output="$(MN_DISABLE_UPDATE_CHECK=1 "$cli" --version 2>/dev/null || true)"
  version="$(printf '%s\n' "$output" | sed -n 's/.*\(v\{0,1\}[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\([-+][0-9A-Za-z.-][0-9A-Za-z.-]*\)\{0,1\}\).*/\1/p' | head -n 1)"
  [ -n "$version" ] || return 1
  case "$version" in
  v*) ;;
  *) version="v${version}" ;;
  esac
  mn_detect_version_is_valid "$version" || return 1
  printf '%s' "$version"
}

function mn_detect_runtime_is_ready() {
  local cli="$1"
  local report=""

  [ -x "$cli" ] || return 1
  if report="$(MN_DISABLE_UPDATE_CHECK=1 "$cli" status --json 2>/dev/null)"; then
    return 0
  fi
  if printf '%s' "$report" | grep -q 'MN_NODE_IDENTITY_INVALID'; then
    MN_DETECT_IDENTITY_INVALID="Y"
  fi
  return 1
}

function mn_has_runtime_files() {
  local home="$1"
  [ -f "$home/install_metadata.json" ] || [ -f "$home/docker-compose.yml" ] ||
    [ -f "$home/docker-compose.env" ] || [ -x "$home/bin/mn-runtime" ] ||
    [ -x "$home/venv/bin/mn-runtime" ] || [ -x "$home/venv/bin/mn" ] ||
    { [ -x "$home/bin/mn" ] && [ ! -L "$home/client-current" ]; }
}

function mn_detect_runtime() {
  local install_dir="${MN_HOME:-${HOME}/.mn}"
  local metadata_file="${install_dir}/install_metadata.json"
  local detected_role="$MN_INSTALL_ROLE"
  if [ -f "$metadata_file" ] && grep -Eq '"install_role"[[:space:]]*:[[:space:]]*"runtime"' "$metadata_file"; then detected_role="runtime"; fi
  if [ "$MN_NO_RUNTIME" = "Y" ] || mn_is_client_home "$install_dir"; then
    local client_installed=false client_version=null
    if mn_is_client_home "$install_dir" && [ -x "$install_dir/bin/mn" ] && [ -x "$install_dir/bin/mn-api" ]; then
      client_installed=true
      client_version="$(sed -n 's/.*"cli_version": "\([v0-9.a-z-]*\)".*/"\1"/p' "$metadata_file" | head -n 1)"
      client_version="${client_version:-null}"
    fi
    printf '{"installed":%s,"install_role":"client","running":false,"runtime_ready":false,"status":"client","version":%s,"podman_installed":null,"podman_running":null}\n' "$client_installed" "$client_version"
    return
  fi
  local installed="false"
  local running="false"
  local runtime_ready="false"
  local status="not_installed"
  local version=""
  local podman_installed="false"
  local podman_running="false"
  local core_container_exists="N"
  local cli=""
  local MN_DETECT_IDENTITY_INVALID="N"

  if command -v podman >/dev/null 2>&1; then
    podman_installed="true"
    if podman info >/dev/null 2>&1; then
      podman_running="true"
      if podman container inspect mirror-neuron-core >/dev/null 2>&1; then
        core_container_exists="Y"
      fi
    fi
  fi

  if mn_has_runtime_files "$install_dir" || [ "$core_container_exists" = "Y" ]; then
    installed="true"
  fi

  if [ -x "${install_dir}/bin/mn-runtime" ]; then
    cli="${install_dir}/bin/mn-runtime"
  elif [ -x "${install_dir}/venv/bin/mn-runtime" ]; then
    cli="${install_dir}/venv/bin/mn-runtime"
  fi

  if [ "$installed" = "true" ] && [ -n "$cli" ] && mn_detect_runtime_is_ready "$cli"; then
    runtime_ready="true"
  fi

  if [ "$installed" = "true" ]; then
    if [ "$podman_running" != "true" ]; then
      running="null"
      status="podman_not_running"
    elif [ "$(podman container inspect --format '{{.State.Running}}' mirror-neuron-core 2>/dev/null || true)" = "true" ]; then
      running="true"
      status="running"
    else
      status="stopped"
    fi
  fi

  if [ "$MN_DETECT_IDENTITY_INVALID" = "Y" ] && [ "$podman_running" = "true" ]; then
    status="identity_invalid"
  fi
  version="$(mn_detect_version_from_metadata "$metadata_file" || true)"
  if [ -z "$version" ] && [ "$podman_running" = "true" ]; then
    version="$(mn_detect_version_from_podman || true)"
  fi
  if [ -z "$version" ]; then
    [ -z "$cli" ] || version="$(mn_detect_version_from_cli "$cli" || true)"
  fi

  if [ -n "$version" ]; then
    printf '{"installed":%s,"install_role":"%s","running":%s,"runtime_ready":%s,"status":"%s","version":"%s","podman_installed":%s,"podman_running":%s}\n' \
      "$installed" "$detected_role" "$running" "$runtime_ready" "$status" "$version" "$podman_installed" "$podman_running"
  else
    printf '{"installed":%s,"install_role":"%s","running":%s,"runtime_ready":%s,"status":"%s","version":null,"podman_installed":%s,"podman_running":%s}\n' \
      "$installed" "$detected_role" "$running" "$runtime_ready" "$status" "$podman_installed" "$podman_running"
  fi
}

function mn_validate_version_tag_or_exit() {
  local tag="$1"
  local semver_tag_regex='^v(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)(-(alpha|beta|rc)[.](0|[1-9][0-9]*))?$'

  if [[ ! "$tag" =~ $semver_tag_regex ]]; then
    echo "install.sh: invalid release version '$tag'. Expected vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-rc.N." >&3
    exit 1
  fi
}

function mn_package_version_from_tag() {
  local tag="$1"
  local version="${tag#v}"
  version="${version/-alpha./a}"
  version="${version/-beta./b}"
  version="${version/-rc./rc}"
  printf '%s' "$version"
}

function mn_web_ui_package_version_from_tag() {
  local tag="$1"
  printf '%s' "${tag#v}"
}

function mn_default_membrane_engine_tag() {
  printf '%s' "$MN_DEFAULT_MEMBRANE_CONTEXT_ENGINE_VERSION"
}

function mn_run_uv_installer() {
  local installer="$1"
  local target_dir="$2"

  if [ -n "$MN_DEFAULT_UV_VERSION" ]; then
    UV_UNMANAGED_INSTALL="$target_dir" UV_VERSION="$MN_DEFAULT_UV_VERSION" sh "$installer"
  else
    UV_UNMANAGED_INSTALL="$target_dir" sh "$installer"
  fi
}

function mn_install_support_asset_path() {
  local relative_path="$1"
  local support_version="${MN_INSTALL_SUPPORT_VERSION:-${MN_INSTALL_VERSION:-}}"
  if [ "$relative_path" = "package-index/python-packages.toml" ]; then
    support_version="${PACKAGE_INDEX_VERSION:-$support_version}"
  fi
  if [ -n "$support_version" ]; then
    printf 'install_support/%s/%s' "$support_version" "$relative_path"
  else
    printf '%s' "$relative_path"
  fi
}

# The remote client loads credentials for every configured registry, even for
# cached images. Give public and local-only operations their own auth file.
function mn_anonymous_podman() (
  local action="$1"
  shift
  mn_podman_authfile="$(mktemp "${TMPDIR:-/tmp}/mn-podman-auth.XXXXXXXX")" || return 1
  trap 'rm -f "$mn_podman_authfile"' EXIT
  printf '{"auths":{}}\n' >"$mn_podman_authfile" || return 1
  podman "$action" --authfile "$mn_podman_authfile" "$@"
)

function mn_pull_public_gar_image() {
  local image="$1"
  case "$image" in
  us-central1-docker.pkg.dev/mirrorneuron-public-packages/*)
    mn_run_logged "Podman image download" mn_anonymous_podman pull "$image"
    ;;
  *) mn_run_logged "Podman image download" podman pull "$image" ;;
  esac
}

# Custom Dockerfiles may use private base images. Keep the caller's credentials
# unless Podman fails to read them before submitting the build to the engine.
function mn_build_with_registry_auth() (
  local status
  set -o pipefail
  mn_build_stderr="$(mktemp "${TMPDIR:-/tmp}/mn-podman-build.XXXXXXXX")" || return 1
  trap 'rm -f "$mn_build_stderr"' EXIT
  # Stream both channels as usual while keeping Podman's final diagnostic.
  exec 4>&1
  if podman build "$@" 2>&1 >&4 4>&- | tee "$mn_build_stderr" >&2; then
    return 0
  else
    status=$?
  fi
  if [ "$status" -eq 125 ] && tail -n 1 "$mn_build_stderr" | grep -q '^Error: error getting credentials - err:'; then
    printf 'Podman could not read registry credentials. Retrying the build anonymously.\n' >&2
    mn_anonymous_podman build "$@"
    return
  fi
  return "$status"
)

function mn_report_podman_failure() {
  if ! podman info >/dev/null 2>&1; then
    print_error "Podman stopped responding. Verify podman info and retry the installer."
  fi
}

# Hold temporary swap only while compiling on a small, locally managed Mac VM.
# The SSH session owns the file so a disconnected installer also releases it.
function mn_build_runtime_image() (
  local machine="" memory reply guest
  if [ "$(uname -s)" = Darwin ] && [ -z "${CONTAINER_HOST:-}" ]; then
    machine="$(podman system connection list --format '{{.Default}} {{.IsMachine}} {{.Name}} {{.URI}}' 2>/dev/null |
      awk -v selected="${CONTAINER_CONNECTION:-}" '
        $2 == "true" && (selected == "" ? $1 == "true" : $3 == selected) {
          if ($4 ~ /^ssh:\/\/root@/) sub(/-root$/, "", $3)
          print $3; exit
        }')" || machine=""
  fi
  memory=""
  if [ -n "$machine" ]; then
    memory="$(podman machine inspect --format '{{.Resources.Memory}}' "$machine" 2>/dev/null)" || memory=""
  fi
  if ! [[ "$memory" =~ ^[0-9]+$ ]] || [ "$memory" -ge 6144 ]; then
    mn_build_with_registry_auth "$@"
    return
  fi

  guest="$(
    cat <<'GUEST'
set -eu
umask 077
ram=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
# Other builds release their own swap as soon as they finish.
swap=$(awk 'NR > 1 && $1 !~ /^\/var\/tmp\/mn-build-swap\./ {sum += $3} END {print sum+0}' /proc/swaps)
needed=$(( (6144 * 1024 - ram - swap + 1023) / 1024 ))
if [ "$needed" -gt 0 ]; then
  file=$(mktemp /var/tmp/mn-build-swap.XXXXXXXX)
  active=0
  cleanup() {
    if [ "$active" = 1 ]; then swapoff "$file" || return 1; fi
    rm -f -- "$file"
  }
  trap 'cleanup || exit 1' EXIT
  trap 'exit 1' HUP INT TERM
  echo "Reserving ${needed} MiB of temporary Podman guest swap for the image build." >&2
  fallocate -l "${needed}M" "$file"
  mkswap "$file" >/dev/null
  swapon "$file"
  active=1
fi
echo ready
cat >/dev/null
GUEST
  )" || return 1
  mn_build_ready_dir="$(mktemp -d "${TMPDIR:-/tmp}/mn-build-ready.XXXXXXXX")" || return 1
  trap 'rm -f "$mn_build_ready_dir/ready"; rmdir "$mn_build_ready_dir"' EXIT
  mkfifo "$mn_build_ready_dir/ready" || return 1
  set -o pipefail
  exec 4>&1
  # The guest writes its readiness acknowledgement to the FIFO read by the build.
  # shellcheck disable=SC2094
  {
    if ! IFS= read -r reply <"$mn_build_ready_dir/ready" || [ "$reply" != ready ]; then
      printf 'Could not prepare build memory in Podman machine %s. Check free space in its /var/tmp or increase its memory to 6144 MiB.\n' "$machine" >&2
      return 1
    fi
    mn_build_with_registry_auth "$@" >&4
  } | podman machine ssh --username root "$machine" "$guest" >"$mn_build_ready_dir/ready" 4>&-
)

function mn_run_podman_build() {
  local status
  if mn_run_logged "Core image build" mn_build_runtime_image "$@"; then
    return 0
  else
    status=$?
  fi
  mn_report_podman_failure
  return "$status"
}

function mn_prepare_installer_paths() {
  MN_EXISTING_INSTALL="N"
  # A failed runtime setup can leave a ready client and download directories.
  if mn_has_runtime_files "$INSTALL_DIR" || [ -e "$VENV_DIR" ] || [ -L "$VENV_DIR" ]; then
    MN_EXISTING_INSTALL="Y"
  fi
  # Keep downloads, logs and package caches away from macOS protected folders.
  mkdir -p "$INSTALL_DIR/tmp" "$INSTALL_DIR/cache"
  export TMPDIR="$INSTALL_DIR/tmp"
  export PIP_CACHE_DIR="$INSTALL_DIR/cache/pip"
  export UV_PYTHON_BIN_DIR="$INSTALL_DIR/bin"
}

function mn_shell_quote() {
  local value="$1" syntax="${2:-posix}" character
  case "$value" in
  '' | *[!a-zA-Z0-9_./-]*)
    printf "'"
    while [ -n "$value" ]; do
      character="${value:0:1}"
      value="${value:1}"
      if [ "$syntax" = "fish" ] && { [ "$character" = "\\" ] || [ "$character" = "'" ]; }; then
        printf '\\%s' "$character"
      elif [ "$character" = "'" ]; then
        printf '%s' "'\\''"
      else
        printf '%s' "$character"
      fi
    done
    printf "'"
    ;;
  *) printf '%s' "$value" ;;
  esac
}

function mn_shell_environment_content() {
  local runtime_home="$1" syntax="$2" destination="$3" home_value
  home_value="$(mn_shell_quote "$runtime_home" "$syntax")"
  if [ "$destination" = "profile" ] && [ "$runtime_home" = "$HOME/.mn" ]; then
    # Expand HOME when the generated profile is sourced, not during install.
    # shellcheck disable=SC2016
    home_value='"$HOME/.mn"'
  fi
  if [ "$syntax" = "fish" ]; then
    printf 'set -gx MN_HOME %s\n' "$home_value"
    cat <<'EOF'
if not contains -- "$MN_HOME/bin" $PATH
    set -gx PATH "$MN_HOME/bin" $PATH
end
EOF
  else
    printf 'export MN_HOME=%s\n' "$home_value"
    cat <<'EOF'
case ":${PATH:-}:" in
    *":$MN_HOME/bin:"*) ;;
    *) export PATH="$MN_HOME/bin:$PATH" ;;
esac
EOF
  fi
}

# Resolve the login shell, not Bash running this script (including curl | bash).
function mn_login_shell() {
  local login_shell="${SHELL:-}" user_name
  if [ -z "$login_shell" ]; then
    user_name="$(id -un)"
    if command -v getent >/dev/null 2>&1; then
      login_shell="$(getent passwd "$user_name" 2>/dev/null | awk -F: 'NR == 1 {print $7}' || true)"
    elif command -v dscl >/dev/null 2>&1; then
      login_shell="$(dscl . -read "/Users/$user_name" UserShell 2>/dev/null | awk 'NR == 1 {print $2}' || true)"
    fi
    if [ -z "$login_shell" ] && [ -r /etc/passwd ]; then
      login_shell="$(awk -F: -v user="$user_name" '$1 == user {print $7; exit}' /etc/passwd || true)"
    fi
  fi
  printf '%s' "${login_shell##*/}"
}

# Replace only our marked block. Preserve dotfile symlinks and permissions, and
# publish the complete file atomically without running any user startup code.
function mn_update_shell_profile() (
  local profile="$1" runtime_home="$2" syntax="$3" target hops=0 temporary=""
  while [ -L "$profile" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 40 ] || return 1
    target="$(readlink "$profile")" || return 1
    case "$target" in
    /*) profile="$target" ;;
    *) profile="$(dirname "$profile")/$target" ;;
    esac
  done
  if [ -e "$profile" ]; then
    [ -f "$profile" ] && [ -r "$profile" ] && [ -w "$profile" ] || return 1
  fi
  mkdir -p "$(dirname "$profile")" || return 1
  temporary="$(mktemp "${profile}.mn.XXXXXX")" || return 1
  trap 'rm -f "$temporary"' EXIT
  if [ -f "$profile" ]; then
    cp -p "$profile" "$temporary" || return 1
    awk '
            $0 == "# >>> MirrorNeuron shell environment >>>" { managed = 1; next }
            $0 == "# <<< MirrorNeuron shell environment <<<" { managed = 0; next }
            managed { next }
            { print }
            END { if (managed) exit 1 }
        ' "$profile" >"$temporary" || return 1
  fi
  {
    printf '# >>> MirrorNeuron shell environment >>>\n'
    mn_shell_environment_content "$runtime_home" "$syntax" profile
    printf '# <<< MirrorNeuron shell environment <<<\n'
  } >>"$temporary" || return 1
  # Leave an unchanged profile (including its inode) alone on reinstall.
  if [ -f "$profile" ] && cmp -s "$profile" "$temporary"; then return 0; fi
  mv -f "$temporary" "$profile" || return 1
)

function mn_write_shell_environment() {
  local runtime_home login_shell syntax="posix" profile login_profile updated="Y"
  local -a profiles=()
  mkdir -p "$INSTALL_DIR"
  runtime_home="$(cd "$INSTALL_DIR" && pwd)"
  mn_shell_environment_content "$runtime_home" posix env >"$INSTALL_DIR/env"
  export MN_HOME="$runtime_home"
  case ":$PATH:" in
  *":$runtime_home/bin:"*) ;;
  *) export PATH="$runtime_home/bin:$PATH" ;;
  esac
  MN_SHELL_PROFILE_RELOAD_REQUIRED="Y"
  MN_SHELL_PROFILE_PATH="$runtime_home/env"
  MN_SHELL_PROFILE_SYNTAX="posix"
  MN_SHELL_PROFILE_SOURCE_COMMAND="."
  login_shell="$(mn_login_shell)"
  case "$login_shell" in
  bash)
    # Bash reads only the first existing login file, plus .bashrc for
    # non-login terminals. Do not create .bash_profile over .profile.
    login_profile="$HOME/.bash_profile"
    for profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
      if [ -e "$profile" ] || [ -L "$profile" ]; then
        login_profile="$profile"
        break
      fi
    done
    profiles=("$HOME/.bashrc" "$login_profile")
    MN_SHELL_PROFILE_SOURCE_COMMAND="source"
    ;;
  zsh)
    profiles=("${ZDOTDIR:-$HOME}/.zshrc" "${ZDOTDIR:-$HOME}/.zprofile")
    MN_SHELL_PROFILE_SOURCE_COMMAND="source"
    ;;
  fish)
    syntax="fish"
    MN_SHELL_PROFILE_SYNTAX="fish"
    profiles=("${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/mirrorneuron.fish")
    mn_shell_environment_content "$runtime_home" fish env >"$INSTALL_DIR/env.fish"
    MN_SHELL_PROFILE_PATH="$runtime_home/env.fish"
    MN_SHELL_PROFILE_SOURCE_COMMAND="source"
    ;;
  sh | dash | ash | ksh | ksh93) profiles=("$HOME/.profile") ;;
  *)
    print_warning "Could not configure startup for shell '${login_shell:-unknown}'. Add MN_HOME and its bin directory to your shell profile."
    updated="N"
    ;;
  esac
  for profile in ${profiles[@]+"${profiles[@]}"}; do
    if ! mn_update_shell_profile "$profile" "$runtime_home" "$syntax"; then
      print_warning "Could not update shell profile: $profile. Check its permissions and rerun the installer."
      updated="N"
    fi
  done
  if [ "$updated" = "Y" ]; then
    print_step "Shell startup configured. New terminals can use the installed commands."
  fi
  if [ "$MN_INSTALL_VERBOSE" = "Y" ]; then
    printf '    For this terminal: %s %s\n' "$MN_SHELL_PROFILE_SOURCE_COMMAND" "$(mn_shell_quote "$MN_SHELL_PROFILE_PATH" "$syntax")" >&3
  fi
}

function mn_print_next_shell_command() {
  local command_text="$1"

  if [ "${MN_SHELL_PROFILE_RELOAD_REQUIRED:-N}" = "Y" ]; then
    printf 'Next: %s %s && %s\n' "${MN_SHELL_PROFILE_SOURCE_COMMAND:-source}" "$(mn_shell_quote "$MN_SHELL_PROFILE_PATH" "${MN_SHELL_PROFILE_SYNTAX:-posix}")" "$command_text" >&3
  else
    printf 'Next: %s\n' "$command_text" >&3
  fi
}

# Presentation only: report the resolved selections after interactive prompts.
function mn_print_install_summary() {
  local client="" components="Core, Runtime" services="" mode="Full" source_label display_home="$INSTALL_DIR"
  case "$MN_INSTALL_MODE" in
  binary) source_label="released packages" ;;
  github) source_label="GitHub source" ;;
  local) source_label="local source" ;;
  esac
  # This is a display abbreviation; commands retain the fully quoted path.
  # shellcheck disable=SC2088
  case "$INSTALL_DIR" in
  "$HOME"/*) display_home="~/${INSTALL_DIR#"$HOME"/}" ;;
  esac
  [ "${INSTALL_PYTHON_SDK:-Y}" = "Y" ] && components="${components}, SDK"
  [ "${INSTALL_CLI:-Y}" != "Y" ] || client="CLI"
  [ "${INSTALL_API:-Y}" != "Y" ] || client="${client:+$client, }API"
  [ "${INSTALL_WEB_UI:-N}" != "Y" ] || client="${client:+$client, }Web UI server"
  MN_INSTALL_CLIENT_COMPONENTS="${client:+$client, client support}"
  [ "${INSTALL_AGENTS:-N}" = "Y" ] && components="${components}, Agents"
  [ "${INSTALL_SKILLS:-N}" = "Y" ] && components="${components}, Skills"
  [ "${INSTALL_WEB_UI:-N}" = "Y" ] && services="${services}, Web UI"
  [ "${INSTALL_REDIS:-N}" = "Y" ] && services="${services}, Redis"
  [ "${INSTALL_CONTEXT_ENGINE:-N}" = "Y" ] && services="${services}, Membrane"
  case "${MN_SYNCTHING_ENABLED:-0}" in
  '' | 0 | [Ff][Aa][Ll][Ss][Ee] | [Nn][Oo] | [Nn] | [Oo][Ff][Ff] | [Dd][Ii][Ss][Aa][Bb][Ll][Ee][Dd]) ;;
  *) services="${services}, Syncthing" ;;
  esac
  MN_INSTALL_STAGE=0
  MN_INSTALL_STAGES=1
  if [ -n "$MN_INSTALL_CLIENT_COMPONENTS" ]; then
    MN_INSTALL_STAGES=$((MN_INSTALL_STAGES + 1))
  fi
  if [ "$MN_NO_RUNTIME" = "Y" ]; then
    mode="Client"
    components="$MN_INSTALL_CLIENT_COMPONENTS"
    services=""
  else
    MN_INSTALL_STAGES=$((MN_INSTALL_STAGES + 1))
    if [ "$MN_RUNTIME_ONLY" = "Y" ]; then mode="Runtime"; fi
    if [ -n "$MN_INSTALL_CLIENT_COMPONENTS" ]; then
      components="$MN_INSTALL_CLIENT_COMPONENTS, $components"
    fi
  fi
  printf '  %sMode%s     %s (%s)\n' "$DIM" "$RESET" "$mode" "$source_label" >&3
  printf '  %sHome%s     %s\n' "$DIM" "$RESET" "$display_home" >&3
  printf '  %sInstall%s  %s\n' "$DIM" "$RESET" "$components" >&3
  if [ -n "$services" ]; then
    printf '  %sServices%s %s\n' "$DIM" "$RESET" "${services#, }" >&3
  fi
  if [ "$MN_NO_RUNTIME" = "Y" ]; then
    printf '  %sStartup%s  Manual; no services started\n' "$DIM" "$RESET" >&3
  elif [ "$START_NOW" = "Y" ]; then
    MN_INSTALL_STAGES=$((MN_INSTALL_STAGES + 1))
    printf '  %sStartup%s  Automatic\n' "$DIM" "$RESET" >&3
  else
    printf '  %sStartup%s  Manual; no services started\n' "$DIM" "$RESET" >&3
  fi
  printf '\n' >&3
}

function mn_print_cli_verification_prompt() {
  [ "${INSTALL_CLI:-Y}" = "Y" ] || return 0

  print_detail "Command help: mn --help"
}

function mn_print_runtime_connect_command() {
  # Read the endpoint written by startup. The local gRPC target can be loopback.
  if ! "$VENV_DIR/bin/python" - "$INSTALL_DIR" >&3 2>/dev/null <<'PY_CONNECT'; then
from pathlib import Path
import shlex
import sys

from mn_sdk.runtime_connection import DEFAULT_PORT, normalize_target, read_object

home = Path(sys.argv[1])
grpc = read_object(home / "runtime-endpoints.json")["grpc"]
host = grpc["host"]
if ":" in host and not host.startswith("["):
    host = f"[{host}]"
port = int(grpc["port"])
host = normalize_target(host, port).rsplit(":", 1)[0]
token = (home / "runtime.token").read_text(encoding="utf-8").strip()
if not token:
    raise SystemExit(1)

command = ["mn", "node", "add", host]
if port != DEFAULT_PORT:
    command.extend(["--grpc-port", str(port)])
command.extend(["--token", token])
print("  Connect to this runtime")
print(f"    {shlex.join(command)}")
PY_CONNECT
    print_warning "Could not display the runtime connection command. Check ${INSTALL_DIR}/runtime-endpoints.json and ${INSTALL_DIR}/runtime.token."
  fi
}

function mn_print_install_complete() {
  printf '\n' >&3
  if [ "$MN_NO_RUNTIME" = "Y" ]; then
    print_success "OtterDesk client installed ($((SECONDS - MN_INSTALL_STARTED))s)."
    printf '  Blueprints run on your remote node.\n' >&3
    printf '  Optional local API: mn-api (foreground)\n' >&3
    print_detail "Local API bearer credential: ${INSTALL_DIR}/api.token"
    if [ -f "$INSTALL_DIR/client.json" ] && ! grep -q '"api_url"' "$INSTALL_DIR/client.json"; then
      mn_print_next_shell_command "mn node list"
    else
      mn_print_next_shell_command 'mn node add <HOST> --token <RUNTIME_NODE_TOKEN>'
    fi
  else
    if [ "$START_NOW" = "Y" ]; then
      print_success "OtterDesk installed; runtime running ($((SECONDS - MN_INSTALL_STARTED))s)."
    else
      print_success "OtterDesk installed ($((SECONDS - MN_INSTALL_STARTED))s)."
    fi
    if [ "${INSTALL_WEB_UI:-N}" = "Y" ] && [ "$START_NOW" = "Y" ]; then
      printf '  Web UI: http://%s:%s\n' "${MN_WEB_UI_HOST:-localhost}" "${MN_WEB_UI_PORT:-55173}" >&3
    fi
    if [ "${INSTALL_CLI:-Y}" = "Y" ]; then
      if [ "$START_NOW" = "Y" ]; then
        mn_print_next_shell_command "mn node list"
      else
        mn_print_next_shell_command "mn runtime start"
      fi
    elif [ "$MN_INSTALL_ROLE" = "runtime" ]; then
      print_detail "Runtime credential: ${INSTALL_DIR}/runtime.token"
      if [ "$START_NOW" != "Y" ]; then
        mn_print_next_shell_command "mn-runtime start"
      fi
    fi
  fi
  mn_print_cli_verification_prompt
  if [ "$MN_NO_RUNTIME" != "Y" ] && [ "$START_NOW" = "Y" ]; then
    mn_print_runtime_connect_command
  fi
}

function runtime_compose() {
  "$VENV_DIR/bin/python" -m mn_sdk.containers.podman_compose --env-file "$RUNTIME_COMPOSE_ENV" -f "$RUNTIME_COMPOSE_FILE" "$@"
}

function mn_read_env_value() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$file"
}

function mn_runtime_network_external() {
  local network_name="$1"
  # Compose templates and saved installations share these environment keys.
  local configured="${MN_DOCKER_NETWORK_EXTERNAL:-}"
  local labels compose_project compose_network

  if [ -n "$configured" ]; then
    printf '%s\n' "$configured"
    return 0
  fi

  if ! labels="$(podman network inspect -f '{{ index .Labels "com.docker.compose.project" }}|{{ index .Labels "com.docker.compose.network" }}' "$network_name" 2>/dev/null)"; then
    printf 'false\n'
    return 0
  fi

  compose_project="${labels%%|*}"
  compose_network="${labels#*|}"
  if [ "$compose_project" = "mirror-neuron" ] && [ "$compose_network" = "runtime" ]; then
    printf 'false\n'
  else
    print_warning "Podman network ${network_name} already exists outside this Compose project; reusing it as an external network."
    printf 'true\n'
  fi
}

function pull_context_engine_image() {
  local image
  image="$(mn_read_env_value "$RUNTIME_COMPOSE_ENV" "MN_MEMBRANE_ENGINE_IMAGE")"
  [ -n "$image" ] || image="$(mn_read_env_value "$RUNTIME_COMPOSE_ENV" "ENGINE_IMAGE")"
  [ -n "$image" ] || {
    print_error "Membrane context-engine image is not configured."
    return 1
  }
  case "$image" in
  us-central1-docker.pkg.dev/mirrorneuron-public-packages/*)
    if ! mn_pull_public_gar_image "$image"; then
      print_error "Could not pull the public Membrane image from Google Artifact Registry."
      return 1
    fi
    ;;
  *)
    runtime_compose pull membrane-context-engine
    ;;
  esac
}

function remove_stale_runtime_container() {
  local name="$1"
  local project

  if ! podman container inspect "$name" >/dev/null 2>&1; then
    return 0
  fi

  project="$(podman container inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$name" 2>/dev/null || true)"
  if [ "$project" = "mirror-neuron" ]; then
    return 0
  fi

  podman rm -f "$name" >/dev/null 2>&1 || true
}

function prepare_runtime_compose_sidecars() {
  remove_stale_runtime_container mirror-neuron-context-engine-model
  if [ "$INSTALL_REDIS" = "Y" ]; then
    remove_stale_runtime_container mirror-neuron-redis
  fi
  if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
    remove_stale_runtime_container mirror-neuron-context-engine
    mn_prepare_membrane_image
  fi
}

function mn_runtime_port_settings() {
  local compose_env="$1" prefix
  local start_key end_key policy_key start end policy

  # The runtime selects the default ranges at startup. Keep saved values and
  # their allocation policy when a reinstall regenerates the Compose env file.
  for prefix in MN_BLUEPRINT_WEB_UI_PORT MN_AUTO_PORT; do
    start_key="${prefix}_START"
    end_key="${prefix}_END"
    policy_key="${prefix}_RANGE_POLICY"
    start="${!start_key:-$(mn_read_env_value "$compose_env" "$start_key")}" || return
    end="${!end_key:-$(mn_read_env_value "$compose_env" "$end_key")}" || return
    if [ -n "${!start_key:-}${!end_key:-}" ]; then
      policy=fixed
    else
      policy="$(mn_read_env_value "$compose_env" "$policy_key")" || return
    fi
    printf '%s=%s\n' "$start_key" "$start" "$end_key" "$end" "$policy_key" "$policy"
  done

  # Empty values let the runtime select available Syncthing ports. A default
  # written here would be treated as an explicit pin, preventing that search.
  printf 'MN_SYNCTHING_GUI_PORT=%s\nMN_SYNCTHING_SYNC_PORT=%s\n' \
    "${MN_SYNCTHING_GUI_PORT:-}" "${MN_SYNCTHING_SYNC_PORT:-}"
}

function mn_run_runtime_start_command() {
  local log_dir="${TMPDIR:-/tmp}/mirror_neuron_install"
  local log_file="${log_dir}/runtime-start.$$.log"
  local status busy_port="" port_setting="" bind_error
  local bind_error_pattern='(failed to bind host port |Bind for |listen tcp[46]? )[^[:space:]]+:([0-9]+)(/tcp: address already in use| failed: port is already allocated|: bind: address already in use)'
  local syncthing_error_pattern='(MN_SYNCTHING_(GUI|SYNC)_PORT)=([0-9]+) is already in use[.]'

  # Never hide command output while leaving it attached to interactive input.
  # A future CLI prompt must be visible instead of appearing as an installer hang.
  if [ "$MN_INSTALL_VERBOSE" = "Y" ] || [ "${NON_INTERACTIVE:-N}" != "Y" ]; then
    if MN_DISABLE_UPDATE_CHECK=1 "$@"; then
      return 0
    else
      status=$?
    fi
  else
    mkdir -p "$log_dir"
    if MN_DISABLE_UPDATE_CHECK=1 MN_CLI_OUTPUT=plain "$@" </dev/null >"$log_file" 2>&1; then
      grep -E '(^|[[:space:]])(Warning:|warning:|× Error:|error:)' "$log_file" >&3 2>/dev/null || true
      rm -f "$log_file"
      return 0
    else
      status=$?
    fi
    print_warning "Runtime startup details: $log_file"
    bind_error="$(grep -m 1 -E "$bind_error_pattern|$syncthing_error_pattern" "$log_file" || true)"
    if [[ "$bind_error" =~ $syncthing_error_pattern ]]; then
      port_setting="${BASH_REMATCH[1]}"
      busy_port="${BASH_REMATCH[3]}"
    elif [[ "$bind_error" =~ $bind_error_pattern ]]; then
      busy_port="${BASH_REMATCH[2]}"
    fi
  fi

  if [ -n "$port_setting" ]; then
    print_error "Runtime startup failed. $port_setting=$busy_port is already in use. Set $port_setting to a free port, then retry mn-runtime start."
  elif [ -n "$busy_port" ]; then
    print_error "Runtime startup failed. Podman could not publish TCP port $busy_port because it is already in use. Free the port or change its mapping, then retry mn-runtime start."
  else
    print_error "Runtime startup failed. Resolve the reported error, then retry mn-runtime start."
  fi
  return "$status"
}

function mn_wac_matches() {
  [ -f "$1" ] && "$VENV_DIR/bin/python" -c '
import hashlib, sys
with open(sys.argv[1], "rb") as binary:
    sys.exit(hashlib.file_digest(binary, "sha256").hexdigest() != sys.argv[2])
' "$1" "$2"
}

function mn_install_wac() (
  local platform target digest binary="wac" staged
  platform="$(uname -s):$(uname -m)"
  case "$platform" in
  Darwin:arm64 | Darwin:aarch64)
    target=aarch64-apple-darwin
    digest=891af0e6d591481daed3a7c52a3dc20fd34cc326e6e955d4c8fd85c4b1835e3d
    ;;
  Darwin:x86_64)
    target=x86_64-apple-darwin
    digest=805ff57132b81dfcd1f25632e5928eac1d5a1e1a32dead48e73f108571da4e17
    ;;
  Linux:aarch64 | Linux:arm64)
    target=aarch64-unknown-linux-musl
    digest=80fe01c4cbf1e59526069d46f51a8a396be6f8df09ecc060d949181a317c08f5
    ;;
  Linux:x86_64)
    target=x86_64-unknown-linux-musl
    digest=7cd490edbd452221ef89e6750fc43eacc9b71b1242095eb577cb9a3bf0d3beda
    ;;
  MINGW*:x86_64 | MSYS*:x86_64 | CYGWIN*:x86_64 | MINGW*:aarch64 | MSYS*:aarch64 | CYGWIN*:aarch64 | MINGW*:arm64 | MSYS*:arm64 | CYGWIN*:arm64)
    target=x86_64-pc-windows-gnu
    digest=33d92a2a73db1f8de69538038e594a14cc8f9e6feb8138bf29fdaf2598d425d9
    binary=wac.exe
    ;;
  *)
    print_error "No WAC runtime binary is available for $platform."
    return 1
    ;;
  esac
  mkdir -p "$BIN_DIR"
  if mn_wac_matches "$BIN_DIR/$binary" "$digest"; then
    chmod 755 "$BIN_DIR/$binary"
    return
  fi
  staged="$(mktemp "$BIN_DIR/.wac.XXXXXX")"
  trap 'rm -f "$staged"' EXIT
  curl --proto '=https' --proto-redir '=https' -fsSL --retry 3 --connect-timeout 15 --max-time 180 \
    -o "$staged" "https://github.com/bytecodealliance/wac/releases/download/$MN_WAC_VERSION/wac-cli-$target" || return 1
  if ! mn_wac_matches "$staged" "$digest"; then
    print_error "WAC $MN_WAC_VERSION checksum verification failed for $target."
    return 1
  fi
  chmod 755 "$staged" && mv -f "$staged" "$BIN_DIR/$binary"
)

function mn_configure_installed_runtime() {
  local client_command
  print_step "Preparing WAC $MN_WAC_VERSION for WebAssembly blueprints"
  mn_install_wac || return 1
  export PATH="$BIN_DIR:$PATH"
  # Runtime lifecycle also looks for the selected client commands in the venv.
  if [ -n "$MN_INSTALL_CLIENT_COMPONENTS" ]; then
    for client_command in "$INSTALL_DIR"/client-current/bin/*; do
      client_command="${client_command##*/}"
      ln -sfn "$BIN_DIR/$client_command" "$VENV_DIR/bin/$client_command"
    done
  fi
  run_quiet "runtime-installation" "$VENV_DIR/bin/python" -m mn_runtime.lifecycle prepare --role "$MN_INSTALL_ROLE"
  "$VENV_DIR/bin/python" - "$INSTALL_DIR" <<'PY_LAUNCHER'
from pathlib import Path
import shlex, sys
home = Path(sys.argv[1]).resolve()
(home / "bin").mkdir(exist_ok=True)
command = (
    "#!/usr/bin/env bash\nset -euo pipefail\nexport MN_HOME=" + shlex.quote(str(home))
    + '\nexport PATH="$MN_HOME/bin:$PATH"\nexec ' + shlex.quote(str(home / "venv/bin/python"))
    + ' -m mn_runtime.lifecycle "$@"\n'
)
for target in (home / "bin/mn-runtime", home / "server.sh"):
    target.write_text(command)
    target.chmod(0o700)
PY_LAUNCHER
}

function mn_begin_runtime_install() {
  mn_print_stage "Installing the execution runtime"
  if ! mn_prepare_runtime_podman; then
    print_error "Podman setup failed. Check the Podman output and rerun the installer."
    return 1
  fi
  mn_print_stage_result "Container engine" "Podman ready"
}

function mn_finish_runtime_install() {
  if [ "$START_NOW" = "Y" ]; then
    if [ "$INSTALL_REDIS" = "Y" ] || [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
      prepare_runtime_compose_sidecars
    fi
  elif [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
    mn_prepare_membrane_image
  fi

  if [ -z "$MN_INSTALL_CLIENT_COMPONENTS" ]; then mn_write_shell_environment; fi
  mn_print_stage_result "Runtime installation" "Complete"
  if [ "$START_NOW" = "Y" ]; then
    mn_print_stage "Starting and verifying the runtime"
    if [ "$MN_INSTALL_MODE" = local ]; then
      "$BIN_DIR/mn-runtime" stop >/dev/null 2>&1 || true
    fi
    mn_run_runtime_start_command "$BIN_DIR/mn-runtime" start || return 1
    mn_print_stage_result "Runtime verification" "Ready"
  else
    printf '  ○ %-22s Skipped (--no-start)\n' "Runtime verification" >&3
  fi
}

function mn_is_client_home() {
  [ -f "$1/install_metadata.json" ] && grep -Eq '"install_role"[[:space:]]*:[[:space:]]*"client"' "$1/install_metadata.json"
}

# Reset may need sudo before dispatching to an install mode.
NON_INTERACTIVE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
  --yes | -y) NON_INTERACTIVE="Y" ;;
  --interactive) NON_INTERACTIVE="N" ;;
  --mode)
    shift
    if [ "$#" -eq 0 ]; then
      echo "install.sh: --mode requires one of github, local, or binary." >&3
      print_unified_usage
      exit 1
    fi
    MN_INSTALL_MODE="$1"
    MN_INSTALL_MODE_EXPLICIT="Y"
    ;;
  --mode=*)
    MN_INSTALL_MODE="${1#*=}"
    MN_INSTALL_MODE_EXPLICIT="Y"
    ;;
  --version)
    shift
    if [ "$#" -eq 0 ]; then
      echo "install.sh: --version requires a release tag such as ${MN_DEFAULT_INSTALL_VERSION}." >&3
      print_unified_usage
      exit 1
    fi
    MN_INSTALL_VERSION="$1"
    ;;
  --version=*)
    MN_INSTALL_VERSION="${1#*=}"
    ;;
  -h | --help)
    MN_INSTALL_HELP_REQUESTED="Y"
    ;;
  --help-all)
    MN_INSTALL_HELP_REQUESTED="Y"
    MN_INSTALL_HELP_ALL="Y"
    ;;
  -v | --verbose)
    MN_INSTALL_VERBOSE="Y"
    ;;
  --build-membrane)
    MN_BUILD_MEMBRANE="Y"
    ;;
  --reset)
    MN_INSTALL_RESET="Y"
    ;;
  --detect-only)
    MN_INSTALL_DETECT_ONLY="Y"
    ;;
  --start-podman | --start-docker)
    # Accept the legacy spelling for scripts that start the selected engine.
    MN_INSTALL_START_PODMAN="Y"
    ;;
  --no-runtime)
    MN_NO_RUNTIME="Y"
    ;;
  --runtime-only)
    MN_RUNTIME_ONLY="Y"
    ;;
  *)
    MN_INSTALL_ARGS+=("$1")
    ;;
  esac
  shift
done

if [ "$MN_NO_RUNTIME" = "Y" ] && [ "$MN_RUNTIME_ONLY" = "Y" ]; then
  printf 'error: --no-runtime and --runtime-only cannot be combined.\n' >&3
  exit 1
fi
if [ "$MN_NO_RUNTIME" = Y ]; then
  MN_INSTALL_ROLE=client
  export MN_HOME="${MN_HOME:-${HOME}/.mn}"
elif [ "$MN_RUNTIME_ONLY" = Y ] && [ "$MN_INSTALL_MODE" = binary ]; then
  MN_INSTALL_ROLE=runtime
  export MN_HOME="${MN_HOME:-${HOME}/.mn-runtime}"
elif [ "$MN_RUNTIME_ONLY" = Y ]; then
  printf 'notice: --runtime-only is ignored in %s source mode; both parts are installed.\n' "$MN_INSTALL_MODE" >&3
  MN_RUNTIME_ONLY=N
fi
export MN_INSTALL_ROLE

if [ "$MN_INSTALL_START_PODMAN" = "Y" ]; then
  if [ "$MN_INSTALL_MODE_EXPLICIT" = "Y" ] || [ -n "$MN_INSTALL_VERSION" ] || [ -n "$NON_INTERACTIVE" ] ||
    [ "$MN_INSTALL_DETECT_ONLY" = "Y" ] || [ "$MN_INSTALL_RESET" = "Y" ] ||
    [ "$MN_BUILD_MEMBRANE" = "Y" ] || [ "$MN_NO_RUNTIME" = "Y" ] || [ "$MN_RUNTIME_ONLY" = "Y" ] || [ "${#MN_INSTALL_ARGS[@]}" -ne 0 ]; then
    printf 'error: --start-podman cannot be combined with detection or installation options.\n' >&3
    exit 1
  fi
  if [ "$MN_INSTALL_HELP_REQUESTED" = "Y" ]; then
    print_unified_usage
    exit 0
  fi
  mn_start_podman
  exit 0
fi

if [ "$MN_INSTALL_DETECT_ONLY" = "Y" ]; then
  if [ "$MN_INSTALL_MODE_EXPLICIT" = "Y" ] || [ -n "$MN_INSTALL_VERSION" ] || [ -n "$NON_INTERACTIVE" ] ||
    [ "$MN_INSTALL_HELP_REQUESTED" = "Y" ] || [ "$MN_INSTALL_VERBOSE" = "Y" ] ||
    [ "$MN_INSTALL_RESET" = "Y" ] || [ "$MN_BUILD_MEMBRANE" = "Y" ] ||
    [ "${#MN_INSTALL_ARGS[@]}" -ne 0 ]; then
    echo "install.sh: --detect-only cannot be combined with installation options." >&3
    exit 1
  fi
  mn_detect_runtime
  exit 0
fi

# With no explicit prompt flag, keep component defaults but allow terminal sudo.
# A streamed installer can have redirected stdin and a terminal on stderr.
MN_PODMAN_SUDO_NON_INTERACTIVE="${NON_INTERACTIVE:-Y}"
if [ -z "$NON_INTERACTIVE" ] && { [ -t 0 ] || [ -t 2 ]; }; then
  MN_PODMAN_SUDO_NON_INTERACTIVE=N
fi
NON_INTERACTIVE="${NON_INTERACTIVE:-Y}"

case "$MN_INSTALL_MODE" in
github | local | binary) ;;
*)
  echo "install.sh: invalid --mode '$MN_INSTALL_MODE'. Expected github, local, or binary." >&3
  print_unified_usage
  exit 1
  ;;
esac

case "$MN_INSTALL_MODE" in
local) MN_USE_LOCAL_SKILLS="${MN_USE_LOCAL_SKILLS:-1}" ;;
github | binary) MN_USE_LOCAL_SKILLS="${MN_USE_LOCAL_SKILLS:-0}" ;;
esac
export MN_USE_LOCAL_SKILLS

# Source builds are a local-development option. Other modes ignore the flag.
if [ "$MN_INSTALL_MODE" != "local" ]; then
  MN_BUILD_MEMBRANE="N"
fi

if [ -n "$MN_INSTALL_VERSION" ]; then
  mn_validate_version_tag_or_exit "$MN_INSTALL_VERSION"
fi

if [ "$MN_INSTALL_MODE" = "local" ] && [ -n "$MN_INSTALL_VERSION" ]; then
  echo "install.sh: --version is supported only for binary and github modes. Use --mode local without --version for local source installs." >&3
  exit 1
fi

if [ "$MN_INSTALL_HELP_REQUESTED" = "Y" ]; then
  if [ "$MN_INSTALL_HELP_ALL" = "Y" ]; then
    print_extended_usage
    MN_INSTALL_ARGS+=("--help")
  elif [ "$MN_NO_RUNTIME" = "Y" ]; then
    print_unified_usage
    exit 0
  elif [ "$MN_INSTALL_MODE_EXPLICIT" = "Y" ]; then
    MN_INSTALL_ARGS+=("--help")
  else
    print_unified_usage
    exit 0
  fi
fi

export MN_INSTALL_VERSION
export MN_HOME="${MN_HOME:-${HOME}/.mn}"

if [ "$MN_INSTALL_HELP_REQUESTED" != "Y" ]; then
  MN_EXISTING_ROLE=""
  if [ -f "$MN_HOME/install_metadata.json" ]; then
    MN_EXISTING_ROLE="$(sed -n 's/.*"install_role"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MN_HOME/install_metadata.json" | head -n 1)"
    MN_EXISTING_ROLE="${MN_EXISTING_ROLE:-full}"
  elif [ -e "$MN_HOME/docker-compose.yml" ] || [ -e "$MN_HOME/docker-compose.env" ]; then
    MN_EXISTING_ROLE="full"
  fi
  if [ -n "$MN_EXISTING_ROLE" ] && [ "$MN_EXISTING_ROLE" != "$MN_INSTALL_ROLE" ]; then
    printf 'error: MN_HOME contains a %s installation. Use its existing role flag to reinstall. Choose an empty directory for MN_HOME to install %s mode.\n' "$MN_EXISTING_ROLE" "$MN_INSTALL_ROLE" >&3
    exit 1
  fi
fi

# Preserve the last configured identity before any mode rewrites Compose env.
# The CLI validates it against its persistent record and running Core before start.
if [ "$MN_INSTALL_RESET" != "Y" ] && [ -z "${MN_NODE_NAME:-}" ] && [ -f "${MN_HOME}/docker-compose.env" ]; then
  MN_NODE_NAME="$(sed -n 's/^MN_NODE_NAME=//p' "${MN_HOME}/docker-compose.env" | head -n 1)"
  if [ "$MN_NODE_NAME" = "nonode@nohost" ]; then MN_NODE_NAME=""; fi
  export MN_NODE_NAME
fi

function mn_script_dir() {
  if [ -n "${MN_INSTALL_STREAM_NAME:-}" ]; then
    pwd
    return
  fi
  local source_path=""
  if [ "${BASH_SOURCE+x}" = "x" ]; then
    source_path="${BASH_SOURCE[0]:-}"
  fi
  source_path="${source_path:-$0}"

  case "$source_path" in
  "" | - | bash | sh | /dev/fd/* | /dev/stdin | /proc/self/fd/*)
    pwd
    ;;
  *)
    cd "$(dirname "$source_path")" && pwd
    ;;
  esac
}

# Building Membrane is installation-only and requires the explicit CLI flag.
# Non-local modes clear the flag before reaching this shared preparation path.
function mn_validate_membrane_build() {
  [ "$MN_BUILD_MEMBRANE" = "Y" ] || return 0
  local argument source_dir
  for argument in ${MN_INSTALL_ARGS[@]+"${MN_INSTALL_ARGS[@]}"}; do
    if [ "$argument" = "--no-context-engine" ]; then
      printf 'error: --build-membrane conflicts with --no-context-engine.\n' >&3
      return 1
    fi
  done
  source_dir="${MN_MEMBRANE_DIR:-$(mn_script_dir)/../Membrane}"
  if [ ! -f "$source_dir/Dockerfile" ] || [ ! -f "$source_dir/mn-context-engine/Cargo.toml" ]; then
    printf 'error: --build-membrane requires a local Membrane checkout containing Dockerfile and mn-context-engine/Cargo.toml: %s\n' "$source_dir" >&3
    printf 'Set MN_MEMBRANE_DIR to the local source directory.\n' >&3
    return 1
  fi
  MN_BUILD_MEMBRANE_DIR="$(cd "$source_dir" && pwd)"
}

function mn_selected_membrane_image() {
  if [ "$MN_BUILD_MEMBRANE" = "Y" ]; then
    printf '%s' 'mirror-neuron-memory-engine:local'
  else
    printf '%s' "$1"
  fi
}

function mn_selected_membrane_source_mode() {
  if [ "$MN_BUILD_MEMBRANE" = "Y" ]; then
    printf '%s' source
  else
    printf '%s' image
  fi
}

function mn_prepare_membrane_image() {
  if [ "$MN_BUILD_MEMBRANE" != "Y" ]; then
    pull_context_engine_image
    return
  fi
  [ "$MN_MEMBRANE_BUILD_PREPARED" != "Y" ] || return 0
  # Recheck before Podman is invoked; no fallback to an older image on failure.
  mn_validate_membrane_build || return 1
  print_step "Building Membrane Podman image from local source"
  if ! mn_run_logged "Membrane image build" mn_build_runtime_image --target runtime \
    --file "$MN_BUILD_MEMBRANE_DIR/Dockerfile" \
    --tag "$(mn_selected_membrane_image '')" "$MN_BUILD_MEMBRANE_DIR"; then
    print_error "Membrane image build failed. The GAR image was not used as a fallback."
    return 1
  fi
  MN_MEMBRANE_BUILD_PREPARED="Y"
}

function mn_reset_error() {
  printf 'error: %s\n' "$1" >&3
}

function mn_reset_warning() {
  printf 'warning: %s\n' "$1" >&3
}

function mn_reset_resolve_home_or_exit() {
  local configured_home="${MN_HOME:-}"
  local parent_dir base_name resolved_parent resolved_home
  local resolved_user_home resolved_pwd script_dir workspace_dir

  if [ -z "$configured_home" ]; then
    mn_reset_error "MN_HOME is empty; refusing to reset an unresolved path."
    exit 1
  fi

  case "$configured_home" in
  /*) ;;
  *) configured_home="${PWD}/${configured_home}" ;;
  esac

  while [ "$configured_home" != "/" ] && [[ "$configured_home" == */ ]]; do
    configured_home="${configured_home%/}"
  done

  parent_dir="$(dirname "$configured_home")"
  base_name="$(basename "$configured_home")"
  if [ "$base_name" = "." ] || [ "$base_name" = ".." ] || [ ! -d "$parent_dir" ]; then
    mn_reset_error "Cannot safely resolve reset target: ${configured_home}"
    mn_reset_error "Set MN_HOME to an installation path whose parent directory exists."
    exit 1
  fi

  resolved_parent="$(cd "$parent_dir" && pwd -P)"
  resolved_home="${resolved_parent}/${base_name}"
  resolved_user_home="$(cd "$HOME" && pwd -P)"
  resolved_pwd="$(pwd -P)"

  if [ "$resolved_home" = "/" ] || [ "$resolved_home" = "$resolved_user_home" ]; then
    mn_reset_error "Refusing to reset protected path: ${resolved_home}"
    exit 1
  fi
  if [ "$resolved_home" = "$resolved_pwd" ]; then
    mn_reset_error "Refusing to reset the current working directory: ${resolved_home}"
    exit 1
  fi
  if [ -L "$resolved_home" ]; then
    mn_reset_error "Refusing to reset symlinked MN_HOME: ${resolved_home}"
    mn_reset_error "Set MN_HOME to the symlink target explicitly, then rerun with --reset."
    exit 1
  fi
  if [ -e "$resolved_home" ] && [ ! -d "$resolved_home" ]; then
    mn_reset_error "Reset target is not a directory: ${resolved_home}"
    exit 1
  fi

  script_dir="$(mn_script_dir)"
  if [ -d "$script_dir" ]; then
    script_dir="$(cd "$script_dir" && pwd -P)"
    workspace_dir="$(dirname "$script_dir")"
    if [ "$resolved_home" = "$script_dir" ] || [ "$resolved_home" = "$workspace_dir" ] ||
      [ "$resolved_home" = "$workspace_dir/mn-client-support" ]; then
      mn_reset_error "Refusing to reset a MirrorNeuron source directory: ${resolved_home}"
      exit 1
    fi
    if [ "$(dirname "$resolved_home")" = "$workspace_dir" ] &&
      { [ -d "${resolved_home}/.git" ] || [ -f "${resolved_home}/.git" ]; }; then
      mn_reset_error "Refusing to reset a source repository in the MirrorNeuron workspace: ${resolved_home}"
      exit 1
    fi
  fi

  MN_RESET_HOME="$resolved_home"
}

MN_RESET_CLEANUP_IMAGES=()

function mn_reset_add_cleanup_image() {
  local image="$1"
  local existing_image

  [ -n "$image" ] || return 0
  for existing_image in "${MN_RESET_CLEANUP_IMAGES[@]:-}"; do
    [ "$existing_image" = "$image" ] && return 0
  done
  MN_RESET_CLEANUP_IMAGES+=("$image")
}

function mn_reset_capture_cleanup_images() {
  local compose_env_file="$1"
  local project_name="$2"
  local container_name resource_id image redis_image

  # Prefer images that are already running this runtime. They are guaranteed
  # to be available locally and avoid pulling an image during a reset.
  for container_name in \
    mirror-neuron-redis \
    mn-litellm-proxy \
    mirror-neuron-core \
    mirror-neuron-syncthing \
    mirror-neuron-context-engine-model \
    mirror-neuron-context-engine \
    mirror-neuron-native-sdk-grpc; do
    image="$(podman container inspect --format '{{.Config.Image}}' "$container_name" 2>/dev/null || true)"
    mn_reset_add_cleanup_image "$image"
  done

  while IFS= read -r resource_id; do
    [ -n "$resource_id" ] || continue
    image="$(podman container inspect --format '{{.Config.Image}}' "$resource_id" 2>/dev/null || true)"
    mn_reset_add_cleanup_image "$image"
  done < <(podman ps -aq --filter "label=com.docker.compose.project=${project_name}" 2>/dev/null || true)

  # A prior reset may already have removed the containers while leaving
  # container-owned bind-mount files behind. Redis is part of the managed
  # runtime, and its locally cached image provides a small POSIX shell.
  redis_image="$(mn_read_env_value "$compose_env_file" "MN_REDIS_IMAGE")"
  redis_image="${redis_image:-$MN_DEFAULT_REDIS_IMAGE}"
  if podman image inspect "$redis_image" >/dev/null 2>&1; then
    mn_reset_add_cleanup_image "$redis_image"
  fi
}

function mn_reset_remove_container_owned_files() {
  local cleanup_image
  local cleanup_command='rm -rf /mnt/mn-reset/* /mnt/mn-reset/.[!.]* /mnt/mn-reset/..?*'

  # MN_RESET_HOME was resolved and rejected if it is a symlink before this
  # function can run. Mount only that exact runtime directory, never its
  # parent or HOME, and use an image already available on the host.
  for cleanup_image in "${MN_RESET_CLEANUP_IMAGES[@]:-}"; do
    [ -n "$cleanup_image" ] || continue
    if mn_anonymous_podman run --pull=never --rm --user 0:0 \
      --volume "$MN_RESET_HOME:/mnt/mn-reset:rw" \
      --entrypoint /bin/sh \
      "$cleanup_image" -ec "$cleanup_command" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

function mn_reset_confirm_or_exit() {
  local confirmation=""

  mn_reset_warning "RESET PERMANENTLY DELETES all MirrorNeuron runtime data in ${MN_RESET_HOME}."
  if [ -n "${VENV_DIR:-}" ]; then
    mn_reset_warning "The MirrorNeuron Python virtual environment at ${VENV_DIR} will also be removed."
  fi
  mn_reset_warning "MirrorNeuron Podman containers and volumes will be removed, including all Redis data."
  mn_reset_warning "This cannot be undone, and --yes does not bypass this confirmation."
  printf 'Type YES to reset MirrorNeuron and continue with a fresh install: ' >&3

  if [ -t 0 ]; then
    IFS= read -r confirmation || confirmation=""
  elif { exec 4</dev/tty; } 2>/dev/null; then
    IFS= read -r confirmation <&4 || confirmation=""
    exec 4<&-
  else
    IFS= read -r confirmation || confirmation=""
  fi

  if [ "$confirmation" != "YES" ]; then
    mn_reset_warning "Reset cancelled; no data was changed."
    exit 0
  fi
}

function mn_reset_podman_state_or_exit() {
  local compose_file="${MN_RESET_HOME}/docker-compose.yml"
  local compose_env_file="${MN_RESET_HOME}/docker-compose.env"
  local project_name=""
  local cleanup_failed="N"
  local resource_id redis_volume container_name
  local redis_container="mirror-neuron-redis"
  local redis_cli_script
  local -a compose_args=()

  if ! command -v podman >/dev/null 2>&1; then
    mn_reset_error "podman is required to clear Redis and MirrorNeuron runtime volumes."
    exit 1
  fi
  if ! podman info >/dev/null 2>&1; then
    mn_reset_error "Podman is not running; reset stopped before deleting ${MN_RESET_HOME}."
    printf 'Next: start Podman, then rerun install.sh --reset.\n' >&3
    exit 1
  fi

  project_name="$(mn_read_env_value "$compose_env_file" "COMPOSE_PROJECT_NAME")"
  project_name="${project_name:-mirror-neuron}"
  if ! [[ "$project_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    mn_reset_error "Invalid Compose project name in ${compose_env_file}: ${project_name}"
    exit 1
  fi

  mn_reset_capture_cleanup_images "$compose_env_file" "$project_name"

  printf '==> Clearing Redis and stopping the existing MirrorNeuron runtime\n' >&3
  # Container environment variables must expand inside the container.
  # shellcheck disable=SC2016
  redis_cli_script='if [ -n "${MN_REDIS_PASSWORD:-}" ]; then
  redis-cli --no-auth-warning -a "$MN_REDIS_PASSWORD" FLUSHALL
  redis-cli --no-auth-warning -a "$MN_REDIS_PASSWORD" MEMORY PURGE >/dev/null 2>&1 || true
else
  redis-cli FLUSHALL
  redis-cli MEMORY PURGE >/dev/null 2>&1 || true
fi'
  if podman ps --format '{{.Names}}' 2>/dev/null | grep -Fx "$redis_container" >/dev/null; then
    if podman exec -i "$redis_container" sh -c "$redis_cli_script" >/dev/null 2>&1; then
      printf '✓ Cleared all Redis databases.\n' >&3
    else
      mn_reset_warning "Redis FLUSHALL failed; removing its persistent Podman volume instead."
    fi
  fi

  if [ -f "$compose_file" ]; then
    local python="$MN_RESET_HOME/venv/bin/python"
    if [ -x "$python" ]; then
      if [ -f "$compose_env_file" ]; then
        compose_args+=(--env-file "$compose_env_file")
      fi
      compose_args+=(-p "$project_name" -f "$compose_file")
      if ! "$python" -m mn_sdk.containers.podman_compose "${compose_args[@]}" down --remove-orphans --volumes >/dev/null 2>&1; then
        mn_reset_warning "Compose teardown was incomplete; cleaning owned resources by project label."
      fi
    fi
  fi

  while IFS= read -r resource_id; do
    [ -n "$resource_id" ] || continue
    if ! podman rm -f "$resource_id" >/dev/null 2>&1; then
      cleanup_failed="Y"
    fi
  done < <(podman ps -aq --filter "label=com.docker.compose.project=${project_name}" 2>/dev/null || true)

  for container_name in \
    mirror-neuron-core \
    mirror-neuron-redis \
    mirror-neuron-web-ui \
    mirror-neuron-syncthing \
    mirror-neuron-context-engine-model \
    mirror-neuron-context-engine \
    mirror-neuron-native-sdk-grpc \
    mn-litellm-proxy \
    openshell-cluster-openshell; do
    if podman container inspect "$container_name" >/dev/null 2>&1; then
      if ! podman rm -f "$container_name" >/dev/null 2>&1; then
        cleanup_failed="Y"
      fi
    fi
  done

  while IFS= read -r resource_id; do
    [ -n "$resource_id" ] || continue
    if ! podman volume rm -f "$resource_id" >/dev/null 2>&1; then
      cleanup_failed="Y"
    fi
  done < <(podman volume ls -q --filter "label=com.docker.compose.project=${project_name}" 2>/dev/null || true)

  redis_volume="${project_name}_redis-data"
  if podman volume inspect "$redis_volume" >/dev/null 2>&1; then
    if ! podman volume rm -f "$redis_volume" >/dev/null 2>&1; then
      cleanup_failed="Y"
    fi
  fi

  if [ "$cleanup_failed" = "Y" ]; then
    mn_reset_error "Could not remove all MirrorNeuron Podman containers or volumes."
    mn_reset_error "Reset stopped before deleting ${MN_RESET_HOME}."
    exit 1
  fi
  printf '✓ Removed MirrorNeuron Podman runtime and persistent Redis data.\n' >&3
}

function mn_reset_release_lock() {
  local lock_directory record
  if [ "${MN_RESET_OWNER_PID:-}" != "$$" ]; then return; fi
  for lock_directory in "${MN_RESET_LOCK:-}" "${MN_RUNTIME_LIFECYCLE_LOCK:-}"; do
    [ -n "$lock_directory" ] && [ -f "$lock_directory/owner" ] || continue
    record="$(cat "$lock_directory/owner")"
    case "$record" in
    "$$|"*)
      rm -f "$lock_directory/owner"
      rmdir "$lock_directory" 2>/dev/null || true
      ;;
    esac
  done
}

function mn_reset_acquire_lock_directory() {
  local lock_directory="$1"
  local owner_pid owner_started current_started
  if ! mkdir "$lock_directory" 2>/dev/null; then
    if [ ! -f "$lock_directory/owner" ] || [ -L "$lock_directory" ]; then
      mn_reset_error "Runtime reset lock is incomplete; inspect ${lock_directory} before retrying."
      exit 1
    fi
    IFS='|' read -r owner_pid owner_started <"$lock_directory/owner"
    case "$owner_pid" in '' | *[!0-9]*)
      mn_reset_error "Invalid runtime reset lock."
      exit 1
      ;;
    esac
    current_started="$(LC_ALL=C ps -p "$owner_pid" -o lstart= 2>/dev/null || true)"
    if { [ -n "$current_started" ] && [ "$current_started" = "$owner_started" ]; } ||
      { [ -z "$current_started" ] && kill -0 "$owner_pid" 2>/dev/null; }; then
      mn_reset_error "Another runtime start, install, or reset is in progress."
      exit 1
    fi
    rm -f "$lock_directory/owner"
    rmdir "$lock_directory" || exit 1
    mkdir "$lock_directory" || exit 1
  fi
  chmod 700 "$lock_directory"
  printf '%s|%s\n' "$$" "$(LC_ALL=C ps -p "$$" -o lstart= 2>/dev/null || true)" >"$lock_directory/owner"
}

function mn_reset_acquire_lock() {
  MN_RESET_LOCK="$(dirname "$MN_RESET_HOME")/.$(basename "$MN_RESET_HOME").reset.lock"
  MN_RUNTIME_LIFECYCLE_LOCK="$(dirname "$MN_RESET_HOME")/.$(basename "$MN_RESET_HOME").lifecycle.lock"
  mn_reset_acquire_lock_directory "$MN_RUNTIME_LIFECYCLE_LOCK"
  MN_RESET_OWNER_PID="$$"
  export MN_RESET_OWNER_PID MN_RESET_LOCK
  trap mn_reset_release_lock EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mn_reset_acquire_lock_directory "$MN_RESET_LOCK"
}

function mn_reset_verify_container_home_or_exit() {
  local reset_python
  reset_python="$(command -v python3 || command -v python || true)"
  if [ -z "$reset_python" ]; then
    mn_reset_error "Python is required to verify runtime ownership."
    exit 1
  fi
  if ! "$reset_python" - "$MN_RESET_HOME" <<'MN_RESET_CONTAINER_HOME'; then
import json
import os
from pathlib import Path
import subprocess
import sys

result = subprocess.run(["podman", "container", "inspect", "--format", "{{json .Mounts}}", "mirror-neuron-core"],
                        capture_output=True, text=True, timeout=10)
if result.returncode:
    existing = subprocess.run(["podman", "ps", "-aq", "--filter", "name=^mirror-neuron-core$"],
                              check=True, capture_output=True, text=True, timeout=10)
    if existing.stdout.strip():
        raise SystemExit("Could not verify the existing Core container; reset stopped.")
else:
    home = Path(sys.argv[1]).resolve()
    destination = os.environ.get("MN_CONTAINER_HOME_DIR", "/root/.mn")
    mounts = json.loads(result.stdout)
    homes = [Path(mount["Source"]).resolve() for mount in mounts if mount.get("Destination") == destination]
    if homes != [home]:
        raise SystemExit("The existing Core belongs to a different or unverified installation; reset stopped.")
MN_RESET_CONTAINER_HOME
    mn_reset_error "Runtime container ownership could not be verified; data was preserved."
    exit 1
  fi
}

function mn_reset_host_processes_or_exit() {
  local reset_python
  reset_python="$(command -v python3 || command -v python || true)"
  if [ -z "$reset_python" ]; then
    mn_reset_error "Python is required to verify runtime host-process cleanup."
    exit 1
  fi
  if ! "$reset_python" - "$MN_RESET_HOME" <<'MN_RESET_PROCESSES'; then
import datetime
import json
import os
from pathlib import Path
import signal
import shlex
import subprocess
import sys
import time

home = Path(sys.argv[1]).resolve()
metadata = {}
helper_commands = {}
for pattern in ("pids/*.pid", "runs/*/event_relay.json", "runs/*/pre_launch_process.json"):
    for path in home.glob(pattern):
        try:
            if path.is_symlink() or path.stat().st_size > 65536:
                continue
            value = path.read_text().strip()
            record = {} if path.suffix == ".pid" else json.loads(value)
            if not isinstance(record, dict):
                continue
            pid = int(value if path.suffix == ".pid" else record.get("pid", 0))
            if pid > 1:
                metadata[pid] = path.stat().st_mtime
                command = record.get("command")
                if path.name == "pre_launch_process.json" and isinstance(command, list) and all(isinstance(part, str) for part in command):
                    helper_commands[pid] = command
        except (OSError, ValueError, TypeError):
            continue

modules = ("mn_sdk.blueprint_support.event_relay", "mn_sdk_rag.shared_service",
           "mn_runtime.host.watchdog", "mn_runtime.host.model_sync_monitor",
           "mn_runtime.host.storage_sync_monitor", "mn_runtime.native_service",
           # Same-home cleanup must also recognize pre-split installed services.
           "mn_cli.runtime.watchdog", "mn_cli.runtime.model_sync_monitor",
           "mn_cli.runtime.storage_sync_monitor", "mn_sdk.native_runtime_service")
executables = ("mn-api", "mn-native-sdk-grpc", "mn-web-ui-server", "model-runner", "llama-server")

def processes():
    result = subprocess.run(["ps", "-axo", "pid=,uid=,stat=,lstart=,args="],
                            check=True, capture_output=True, text=True,
                            env={**os.environ, "LC_ALL": "C"}, timeout=5)
    matches = {}
    for line in result.stdout.splitlines():
        fields = line.split(None, 8)
        if len(fields) != 9:
            continue
        pid, uid = int(fields[0]), int(fields[1])
        if pid in (os.getpid(), os.getppid()) or uid != os.getuid() or "Z" in fields[2]:
            continue
        started = " ".join(fields[3:8])
        command = fields[8]
        try:
            arguments = shlex.split(command)
        except ValueError:
            continue
        known = any(value == "-m" and arguments[index + 1] in modules
                    for index, value in enumerate(arguments[:-1]))
        known = known or any(Path(value).name in executables for value in arguments[:2])
        expected = helper_commands.get(pid, [])
        parts = command.split(None, 1)
        recorded_helper = (len(expected) > 1 and len(parts) == 2 and
            Path(parts[0]).name == Path(expected[0]).name and parts[1] == " ".join(expected[1:]))
        known = known or recorded_helper
        if not known:
            continue
        scoped = str(home) + "/" in command
        if not scoped and pid in metadata:
            born = datetime.datetime.strptime(started, "%a %b %d %H:%M:%S %Y").timestamp()
            scoped = born <= metadata[pid] + 1
        if scoped:
            matches[pid] = (started, command)
    return matches

# Re-scan after stopping watchdogs, and verify birth identity immediately before
# every signal. A stale PID file never authorizes killing a replacement process.
deadline = time.monotonic() + 30
first_seen = {}
while True:
    remaining = processes()
    if not remaining:
        break
    now = time.monotonic()
    if now >= deadline:
        raise SystemExit("Runtime host processes did not stop; reset aborted before deleting data.")
    for pid, identity in sorted(remaining.items(), key=lambda item: "watchdog" not in item[1][1]):
        first_seen.setdefault((pid, identity), now)
        if processes().get(pid) != identity:
            continue
        try:
            os.kill(pid, signal.SIGKILL if now - first_seen[(pid, identity)] >= 2 else signal.SIGTERM)
        except ProcessLookupError:
            pass
    time.sleep(0.1)
MN_RESET_PROCESSES
    mn_reset_error "Owned runtime host-process cleanup failed; data was preserved."
    exit 1
  fi
}

function mn_reset_additional_podman_state_or_exit() {
  local reset_python
  reset_python="$(command -v python3 || command -v python)"
  if ! "$reset_python" - "$MN_RESET_HOME" <<'MN_RESET_PODMAN_OWNERS'; then
import hashlib
import json
from pathlib import Path
import subprocess
import sys

home = Path(sys.argv[1]).resolve()

def podman(*args):
    return subprocess.run(["podman", *args], check=True, capture_output=True, text=True, timeout=60).stdout.strip()

# Worker Compose uses a separate project. Bind mounts establish installation
# ownership even when its ledger was lost; a shared project label alone cannot.
project = "mirror-neuron-workers"
env = home / "docker-compose.env"
if env.exists():
    for line in env.read_text().splitlines():
        if line.startswith("MN_DOCKER_WORKER_COMPOSE_PROJECT="):
            project = line.split("=", 1)[1]
for container in podman("ps", "-aq", "--filter", f"label=com.docker.compose.project={project}").splitlines():
    mounts = json.loads(podman("inspect", "--format", "{{json .Mounts}}", container))
    if any(str(mount.get("Source", "")) == str(home) or
           str(mount.get("Source", "")).startswith(str(home) + "/") for mount in mounts):
        podman("rm", "-f", container)

# Clean also interrupted pulls that had not yet published a registry record.
home_filter = f"label=io.mirrorneuron.model.home={home}"
for container in podman("ps", "-aq", "--filter", home_filter).splitlines():
    podman("rm", "-f", container)
for volume in podman("volume", "ls", "-q", "--filter", home_filter).splitlines():
    podman("volume", "rm", volume)

# Podman models own labeled cache volumes outside MN_HOME. Only remove
# the exact model identities recorded by this installation, never shared images.
registry = home / "models/registry.json"
if registry.exists():
    models = json.loads(registry.read_text()).get("models", {})
    for model_id, model in models.items():
        if not isinstance(model, dict) or model.get("kind") not in {"docker", "dmr", "llama_cpp"}:
            continue
        digest = hashlib.sha256(model_id.encode()).hexdigest()[:20]
        container = f"mn-model-{digest}"
        volume = container + "-cache"
        for kind, name in (("container", container), ("volume", volume)):
            found = subprocess.run(["podman", kind, "inspect", "--format", "{{json .Config.Labels}}" if kind == "container" else "{{json .Labels}}", name],
                                   capture_output=True, text=True, timeout=10)
            if found.returncode:
                continue
            labels = json.loads(found.stdout)
            if not isinstance(labels, dict) or labels.get("io.mirrorneuron.model.id") != model_id:
                raise SystemExit("Model resource ownership could not be verified; reset stopped.")
            podman("rm", "-f", name) if kind == "container" else podman("volume", "rm", name)
MN_RESET_PODMAN_OWNERS
    mn_reset_error "Additional runtime Podman resources could not be cleared; data was preserved."
    exit 1
  fi
}

function mn_reset_install_state() {
  local host_remove_error workspace_dir

  mn_reset_resolve_home_or_exit
  mn_reset_confirm_or_exit
  mn_reset_acquire_lock
  if [ "$MN_INSTALL_MODE" = local ]; then
    workspace_dir="$(cd "$(mn_script_dir)/.." && pwd)" || exit 1
    mn_prepare_local_clients "$workspace_dir" || exit 1
  fi
  if ! mn_ensure_podman_for_install; then
    mn_reset_error "Podman setup failed. Reset stopped before host cleanup."
    exit 1
  fi
  mn_reset_verify_container_home_or_exit
  if compgen -G "$MN_RESET_HOME/models/llama.cpp/*/server.json" >/dev/null && [ -x "$MN_RESET_HOME/venv/bin/python" ]; then
    MN_HOME="$MN_RESET_HOME" "$MN_RESET_HOME/venv/bin/python" -m mn_sdk.models.native_llama stop-all || exit 1
  fi
  mn_reset_host_processes_or_exit
  mn_reset_additional_podman_state_or_exit
  mn_reset_podman_state_or_exit
  # An inherited environment from a previous sourced installation must not
  # restore its credentials, identity, endpoints, or old storage roots.
  unset MN_NODE_NAME MN_CLUSTER_NODES MN_GRPC_AUTH_TOKEN MN_GRPC_ADMIN_TOKEN
  unset MN_GRPC_AUTH_TOKEN_FILE MN_GRPC_ADMIN_TOKEN_FILE MN_API_TOKEN
  unset MN_COOKIE MN_NETWORK_JOIN_TOKEN MN_CONTEXT_AUTH_TOKEN MN_REDIS_PASSWORD MN_REDIS_URL
  unset MN_RUNS_ROOT MN_SHARED_STORAGE_ROOT MN_HOST_SHARED_STORAGE_ROOT
  unset MN_RUNTIME_SHARED_STORAGE_ROOT MN_CONTAINER_SHARED_STORAGE_ROOT MN_BUNDLE_CACHE_DIR

  if [ -n "${VENV_DIR:-}" ] && { [ -e "$VENV_DIR" ] || [ -L "$VENV_DIR" ]; }; then
    printf '==> Clearing MirrorNeuron Python virtual environment\n' >&3
    mn_remove_path_or_exit "$VENV_DIR" "MirrorNeuron Python virtual environment"
  fi

  printf '==> Recreating MirrorNeuron runtime data directory\n' >&3
  if [ -d "$MN_RESET_HOME" ]; then
    chmod -R u+rwX "$MN_RESET_HOME" 2>/dev/null || true
    # Podman can remove entries the host user cannot delete from the bind mount.
    if ! host_remove_error="$(rm -rf "$MN_RESET_HOME" 2>&1)"; then
      print_detail "Removing the remaining runtime files through Podman."
      if ! mn_reset_remove_container_owned_files; then
        if [ -n "$host_remove_error" ]; then
          printf '%s\n' "$host_remove_error" >&2
        fi
        mn_reset_error "Could not remove MirrorNeuron runtime data: ${MN_RESET_HOME}"
        mn_reset_error "Podman could not clean the remaining runtime files. Verify Podman access, then repair ownership and rerun --reset."
        exit 1
      fi
      if ! rm -rf "$MN_RESET_HOME"; then
        mn_reset_error "Could not remove MirrorNeuron runtime data after Podman cleanup: ${MN_RESET_HOME}"
        exit 1
      fi
    fi
  fi
  if ! mkdir -p "$MN_RESET_HOME"; then
    mn_reset_error "Could not recreate MirrorNeuron runtime data directory: ${MN_RESET_HOME}"
    exit 1
  fi
  chmod u+rwx "$MN_RESET_HOME" 2>/dev/null || true
  export MN_HOME="$MN_RESET_HOME"
  printf '✓ Reset MirrorNeuron runtime data. Continuing with a fresh install.\n' >&3
}

function mn_reset_drop_conflicting_install_args() {
  local arg
  local -a filtered_args=()

  # Bash 3.2 treats empty arrays as unset with nounset. Preserve zero arguments.

  for arg in ${MN_INSTALL_ARGS[@]+"${MN_INSTALL_ARGS[@]}"}; do
    if [ "$arg" = "--no-reinstall" ]; then
      mn_reset_warning "Ignoring --no-reinstall because --reset requires a fresh installation."
    else
      filtered_args+=("$arg")
    fi
  done
  MN_INSTALL_ARGS=(${filtered_args[@]+"${filtered_args[@]}"})
}

function mn_github_raw_asset_url() {
  local relative_path="$1"
  local repo="${MN_DEPLOY_ASSET_REPO:-MirrorNeuronLab/mn-deploy}"
  local ref="${MN_DEPLOY_ASSET_REF:-main}"
  local base_url="${MN_DEPLOY_RAW_BASE_URL:-https://raw.githubusercontent.com/${repo}/${ref}}"
  printf '%s/%s' "${base_url%/}" "$relative_path"
}

function mn_download_public_repo_asset() {
  local relative_path="$1"
  local target="$2"
  local description="$3"
  local url

  url="$(mn_github_raw_asset_url "$relative_path")"
  mkdir -p "$(dirname "$target")"
  if ! curl_github -fsSL "$url" -o "$target"; then
    print_error "Could not download ${description} from ${url}."
    exit 1
  fi
}

function mn_runtime_compose_template_is_valid() {
  local template="$1"
  [ -f "$template" ] &&
    grep -q '^name: mirror-neuron$' "$template" &&
    grep -q 'mirror-neuron-core' "$template" || return 1
}

function mn_ensure_runtime_compose_template_file() {
  local support_asset_path

  if mn_runtime_compose_template_is_valid "$RUNTIME_COMPOSE_TEMPLATE"; then
    return 0
  fi

  support_asset_path="$(mn_install_support_asset_path "docker-compose.yml")"
  RUNTIME_COMPOSE_TEMPLATE="${TMPDIR:-/tmp}/mirror_neuron_install/docker-compose.yml"
  mn_download_public_repo_asset "$support_asset_path" "$RUNTIME_COMPOSE_TEMPLATE" "MirrorNeuron runtime Compose template"
  if ! mn_runtime_compose_template_is_valid "$RUNTIME_COMPOSE_TEMPLATE"; then
    print_error "Downloaded MirrorNeuron runtime Compose template is invalid: $RUNTIME_COMPOSE_TEMPLATE"
    exit 1
  fi
}

function mn_write_runtime_compose_file() {
  RUNTIME_COMPOSE_TEMPLATE="$1"
  local target="$2"
  mn_ensure_runtime_compose_template_file
  mkdir -p "$(dirname "$target")"
  cp "$RUNTIME_COMPOSE_TEMPLATE" "$target"
  rm -f "$(dirname "$target")/docker-compose.models.yml"
}

function mn_stop_runtime_containers_for_reinstall() {
  local container_ids container_id kind resource_kind
  local runtime_ids=()

  if ! command -v podman >/dev/null 2>&1; then
    return 0
  fi

  container_ids="$(podman ps -aq --filter "label=com.docker.compose.project=mirror-neuron" 2>/dev/null || true)"
  if [ -z "$container_ids" ]; then
    return 0
  fi

  while IFS= read -r container_id; do
    [ -n "$container_id" ] || continue
    kind="$(podman inspect -f '{{ index .Config.Labels "mirror-neuron.kind" }}' "$container_id" 2>/dev/null || true)"
    resource_kind="$(podman inspect -f '{{ index .Config.Labels "mirror-neuron.resource-kind" }}' "$container_id" 2>/dev/null || true)"
    if [ "$kind" = "docker_worker" ] || [ "$resource_kind" = "docker-worker" ]; then
      print_detail "Preserving job-owned DockerWorker container ${container_id} during reinstall."
      continue
    fi
    runtime_ids+=("$container_id")
  done <<<"$container_ids"

  if [ "${#runtime_ids[@]}" -eq 0 ]; then
    return 0
  fi

  print_step "Stopping existing MirrorNeuron runtime"
  if ! podman rm -f "${runtime_ids[@]}" >/dev/null 2>&1; then
    print_error "Could not stop existing MirrorNeuron runtime containers."
    print_error "Stop them with: podman rm -f ${runtime_ids[*]}"
    exit 1
  fi
}

function mn_reconcile_native_resources_before_reinstall() {
  local cleanup_cli=""

  if [ -x "$BIN_DIR/mn" ]; then
    cleanup_cli="$BIN_DIR/mn"
  elif [ -x "$VENV_DIR/bin/mn" ]; then
    cleanup_cli="$VENV_DIR/bin/mn"
  fi
  [ -n "$cleanup_cli" ] || return 0

  print_step "Reconciling confirmed native-resource orphans"
  if ! "$cleanup_cli" runtime cleanup --yes >/dev/null 2>&1; then
    print_warning "Native-resource reconciliation was unavailable or inconclusive; preserving resources and cleanup evidence."
  fi
}

function mn_remove_path_or_exit() {
  local path="$1"
  local description="$2"

  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi

  if [ -d "$path" ] && [ ! -L "$path" ]; then
    chmod -R u+rwX "$path" 2>/dev/null || true
    if rm -rf "$path"; then
      return 0
    fi
  elif rm -f "$path"; then
    return 0
  fi

  print_error "Could not remove ${description}: ${path}"
  print_error "The path may still be mounted by Podman or owned by another user."
  print_error "Stop MirrorNeuron containers, repair ownership, and rerun the installer:"
  print_error "  podman rm -f \$(podman ps -aq --filter label=com.docker.compose.project=mirror-neuron)"
  print_error "  sudo chown -R $(id -u):$(id -g) \"${path}\""
  exit 1
}

function mn_remove_existing_install_paths() {
  mn_reconcile_native_resources_before_reinstall
  mn_stop_runtime_containers_for_reinstall
  # Durable state and the newly installed client commands stay in place.
  mn_remove_path_or_exit "$VENV_DIR" "MirrorNeuron Python virtual environment"
  if [ "$INSTALL_CLI" != "Y" ]; then mn_remove_path_or_exit "$BIN_DIR/mn" "MirrorNeuron CLI executable"; fi
  if [ "$INSTALL_API" != "Y" ]; then mn_remove_path_or_exit "$BIN_DIR/mn-api" "MirrorNeuron API executable"; fi
}

function mn_python_package_index_is_valid() {
  local index_file="$1"
  [ -f "$index_file" ] &&
    grep -q 'name = "mirrorneuron-python-sdk"' "$index_file" &&
    grep -q 'installer_groups = \["sdk"\]' "$index_file"
}

function mn_ensure_python_package_index_file() {
  local support_asset_path

  if mn_python_package_index_is_valid "$PACKAGE_INDEX_FILE"; then
    return 0
  fi

  if [ -n "${MN_PACKAGE_INDEX_FILE:-}" ]; then
    print_error "MirrorNeuron Python package index is required but was not found at $PACKAGE_INDEX_FILE."
    exit 1
  fi

  support_asset_path="$(mn_install_support_asset_path "package-index/python-packages.toml")"
  PACKAGE_INDEX_FILE="${TMPDIR:-/tmp}/mirror_neuron_install/python-packages.toml"
  mn_download_public_repo_asset "$support_asset_path" "$PACKAGE_INDEX_FILE" "MirrorNeuron Python package index"
  if ! mn_python_package_index_is_valid "$PACKAGE_INDEX_FILE"; then
    print_error "Downloaded MirrorNeuron Python package index is invalid: $PACKAGE_INDEX_FILE"
    exit 1
  fi
}

# Component rows are shared by local and GitHub source installs. Binary mode
# uses the same sdk installer group for versioned wheel requirements.
function mn_sdk_component_rows() {
  local PACKAGE_INDEX_FILE="${MN_PACKAGE_INDEX_FILE:-${PACKAGE_INDEX_FILE:-$(mn_script_dir)/package-index/python-packages.toml}}"
  mn_ensure_python_package_index_file
  if [ "$#" -eq 0 ]; then set -- sdk; fi
  "$MN_PYTHON_BIN" - "$PACKAGE_INDEX_FILE" "$@" <<'PYCODE'
import sys, tomllib
from pathlib import Path
packages = tomllib.loads(Path(sys.argv[1]).read_text())["packages"]
groups = set(sys.argv[2:])
for package in packages:
    name = package["name"]
    if groups.isdisjoint(package.get("installer_groups", [])):
        continue
    path = package["path"]
    # Component names need not share a prefix (for example mn-blueprint-blocks).
    if path == "mn-python-sdk":
        continue
    sdk_component = path.startswith("mn-python-sdk/packages/") and ".." not in Path(path).parts
    if not sdk_component:
        raise SystemExit(f"Invalid SDK component source path: {path}")
    extras = package.get("default_extras") or []
    suffix = "[" + ",".join(extras) + "]" if extras else ""
    print(f"{name}\t{path}\t{suffix}")
PYCODE
}

# Persist node policy and endpoints. The owner starts a gateway on first use.
function mn_openshell_plugin_env() {
  local endpoint="${OPENSHELL_GATEWAY_ENDPOINT:-}"
  local config_dir="${OPENSHELL_CONTAINER_CONFIG_DIR:-${OPENSHELL_CONFIG_DIR:-}}"
  if [ -z "$config_dir" ] && [ -n "${OPENSHELL_GATEWAY:-}" ]; then
    config_dir="$HOME/.config/openshell"
  fi
  if [ -z "$endpoint" ] && [ -z "${OPENSHELL_GATEWAY:-}" ]; then
    endpoint="http://openshell:${OPENSHELL_GATEWAY_PORT:-58080}"
  fi
  cat <<EOF
MN_HOST_OPENSHELL_CONFIG_DIR=${config_dir:-${INSTALL_DIR}/.config/openshell-mirror-neuron}
OPENSHELL_GATEWAY_PORT=${OPENSHELL_GATEWAY_PORT:-58080}
MN_OPENSHELL_MODE=${MN_OPENSHELL_MODE}
OPENSHELL_GATEWAY=${OPENSHELL_GATEWAY:-}
OPENSHELL_GATEWAY_ENDPOINT=${OPENSHELL_GATEWAY_ENDPOINT:-}
MN_CORE_OPENSHELL_GATEWAY_ENDPOINT=${endpoint}
OPENSHELL_GATEWAY_BIND_HOST=${OPENSHELL_GATEWAY_BIND_HOST:-127.0.0.1}
OPENSHELL_SANDBOX_IMAGE=${OPENSHELL_SANDBOX_IMAGE:-${MN_DEFAULT_OPENSHELL_SANDBOX_IMAGE:-}}
OPENSHELL_SUPERVISOR_IMAGE=${OPENSHELL_SUPERVISOR_IMAGE:-${MN_DEFAULT_OPENSHELL_SUPERVISOR_IMAGE:-}}
OPENSHELL_GATEWAY_USER=${OPENSHELL_GATEWAY_USER}
OPENSHELL_GATEWAY_DOCKER_GROUP=${OPENSHELL_GATEWAY_DOCKER_GROUP}
OPENSHELL_GATEWAY_IMAGE=${OPENSHELL_GATEWAY_IMAGE:-$MN_DEFAULT_OPENSHELL_GATEWAY_IMAGE}
EOF
}

# A PATH entry can belong to the runtime venv being replaced. Resolve its base
# interpreter and symlinks while it still exists; never build from a moved venv.
function mn_base_python_executable() {
  "$1" -c 'import os, sys
base = os.path.realpath(sys._base_executable)
venv = os.path.realpath(sys.argv[1])
if not os.path.isabs(base) or not os.access(base, os.X_OK) or os.path.commonpath([base, venv]) == venv:
    raise SystemExit(1)
print(base)' "$VENV_DIR"
}

# Native Rust packages. Source installs use Cargo to build the executables.
# Release assets are named <command>-<rust-target>, with a matching .sha256.
function mn_require_cargo() {
  local cargo_bin="${CARGO_HOME:-$HOME/.cargo}/bin"
  if command -v cargo >/dev/null; then return 0; fi
  if [ -f "$cargo_bin/cargo" ] && [ -x "$cargo_bin/cargo" ]; then
    export PATH="$PATH:$cargo_bin"
    return 0
  fi
  print_error "Cargo is required to build the Rust clients. Install Rust with rustup and rerun, or use a binary release."
  return 1
}

function mn_prepare_local_clients() {
  local root="$1" support="$1/mn-client-support" repo
  for repo in mn-cli mn-api; do
    if [ ! -f "$root/$repo/Cargo.toml" ]; then
      print_error "Missing Rust checkout at $root/$repo. Use its Rust main branch in the local workspace."
      return 1
    fi
  done
  mn_require_cargo || return 1
  if [ -f "$support/Cargo.toml" ]; then return 0; fi
  if [ -e "$support" ] || [ -L "$support" ]; then
    print_error "Missing Rust client support manifest: $support/Cargo.toml. Restore the checkout or move it aside and rerun."
    return 1
  fi
  if ! command -v git >/dev/null; then
    print_error "Git is required to clone the missing mn-client-support checkout. Install Git and rerun."
    return 1
  fi

  (
    local stage
    stage="$(mktemp -d "$root/.mn-client-support.XXXXXXXX")" || {
      print_error "Could not prepare a directory for mn-client-support in $root. Check workspace permissions and rerun."
      return 1
    }
    trap 'rm -rf "$stage"' EXIT
    printf '==> Cloning missing Rust client support into %s\n' "$support" >&3
    if ! GIT_TERMINAL_PROMPT=0 mn_run_logged "Clone mn-client-support" \
      git clone --branch main https://github.com/MirrorNeuronLab/mn-client-support.git "$stage/mn-client-support"; then
      printf 'Next: check access to the mn-client-support repository on GitHub and rerun the installer.\n' >&3
      return 1
    fi
    if [ ! -f "$stage/mn-client-support/Cargo.toml" ]; then
      print_error "The mn-client-support main branch is missing its Rust manifest. Check the repository and retry."
      return 1
    fi
    # Target the parent so mv cannot place the checkout inside an occupied path.
    mv -n "$stage/mn-client-support" "$root/" || true
    if [ ! -f "$support/Cargo.toml" ]; then
      print_error "Could not place the Rust client support checkout at $support. Check that path and rerun."
      return 1
    fi
  )
}

function mn_client_target() {
  case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) echo aarch64-apple-darwin ;;
  Darwin/x86_64) echo x86_64-apple-darwin ;;
  Linux/aarch64 | Linux/arm64) echo aarch64-unknown-linux-gnu ;;
  Linux/x86_64) echo x86_64-unknown-linux-gnu ;;
  *)
    print_error "No native client release for this platform. Use --mode local to build it."
    return 1
    ;;
  esac
}

function mn_client_asset() {
  local command="$1" repo="$2" tag="$3" dest="$4" target="$5" asset="$1-$5" url checksum actual
  mn_validate_version_tag_or_exit "$tag"
  if [ -n "${MN_CLIENT_DIST_DIR:-}" ]; then
    cp "$MN_CLIENT_DIST_DIR/$asset" "$dest" && cp "$MN_CLIENT_DIST_DIR/$asset.sha256" "$dest.sha256" || return 1
  else
    url="https://github.com/MirrorNeuronLab/$repo/releases/download/$tag/$asset"
    if ! curl --proto '=https' --proto-redir '=https' -fsSL --retry 2 "$url" -o "$dest" ||
      ! curl --proto '=https' --proto-redir '=https' -fsSL --retry 2 "$url.sha256" -o "$dest.sha256"; then
      print_error "Cannot download $command $tag for $target. Use a matching native release or --mode local."
      return 1
    fi
  fi
  checksum="$(awk 'NR == 1 {print $1}' "$dest.sha256")"
  if command -v shasum >/dev/null; then actual="$(shasum -a 256 "$dest")"; else actual="$(sha256sum "$dest")"; fi
  if ! [[ "$checksum" =~ ^[a-fA-F0-9]{64}$ ]] || [ "${actual%% *}" != "$checksum" ]; then
    print_error "Invalid checksum for $asset."
    return 1
  fi
  rm -f "$dest.sha256"
  chmod 755 "$dest"
}

function mn_install_native_clients() (
  set -e
  local mode="$MN_INSTALL_MODE" root tag cli_tag api_tag repo ref command target target_dir stage gen component_tag
  local -a repos=(mn-client-support) commands=(mn-client-support)
  root="$(cd "$(mn_script_dir)/.." && pwd)"
  tag="${MN_CLIENT_VERSION:-$MN_DEFAULT_CLIENT_VERSION}"
  if [ "$MN_INSTALL_ROLE" = client ]; then tag="${MN_CLIENT_VERSION:-${MN_INSTALL_VERSION:-$tag}}"; fi
  component_tag="${MN_CLIENT_VERSION:-}"
  if [ "$MN_INSTALL_ROLE" = client ]; then component_tag="${component_tag:-${MN_INSTALL_VERSION:-}}"; fi
  cli_tag="${MN_CLI_VERSION_OVERRIDE:-${MN_CLI_VERSION:-${component_tag:-$MN_DEFAULT_CLI_VERSION}}}"
  api_tag="${MN_API_VERSION_OVERRIDE:-${MN_API_VERSION:-${component_tag:-$MN_DEFAULT_API_VERSION}}}"
  tag="v${tag#v}"
  cli_tag="v${cli_tag#v}"
  api_tag="v${api_tag#v}"
  if [ "${INSTALL_CLI:-Y}" = Y ]; then
    repos+=(mn-cli)
    commands+=(mn)
  fi
  if [ "${INSTALL_API:-Y}" = Y ] || [ "${INSTALL_WEB_UI:-N}" = Y ]; then
    repos+=(mn-api)
    if [ "${INSTALL_API:-Y}" = Y ]; then commands+=(mn-api); fi
    commands+=(mn-web-ui-server)
  fi
  mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/client-releases"
  stage="$(mktemp -d "$INSTALL_DIR/client-releases/.stage.XXXXXXXX")"
  trap 'rm -rf "$stage"' EXIT
  mkdir "$stage/bin"
  case "$mode" in
  local | github)
    if [ "$mode" = local ]; then
      mn_prepare_local_clients "$root" || return 1
    else
      mn_require_cargo || return 1
      root="$stage/src"
      mkdir "$root"
      for repo in "${repos[@]}"; do
        ref="${MN_CLIENT_VERSION:-${MN_INSTALL_VERSION:-}}"
        case "$repo" in mn-cli) ref="${MN_CLI_VERSION_OVERRIDE:-${MN_CLI_VERSION:-$ref}}" ;; mn-api) ref="${MN_API_VERSION_OVERRIDE:-${MN_API_VERSION:-$ref}}" ;; esac
        if [ -n "$ref" ]; then
          GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$ref" "https://github.com/MirrorNeuronLab/$repo.git" "$root/$repo"
        else GIT_TERMINAL_PROMPT=0 git clone --depth 1 "https://github.com/MirrorNeuronLab/$repo.git" "$root/$repo"; fi
      done
    fi
    target_dir="${CARGO_TARGET_DIR:-$INSTALL_DIR/cache/rust-client}"
    for repo in "${repos[@]}"; do
      [ -f "$root/$repo/Cargo.toml" ] || {
        print_error "Missing Rust checkout at $root/$repo."
        return 1
      }
      cargo build --quiet --locked --release --bins --manifest-path "$root/$repo/Cargo.toml" --target-dir "$target_dir"
    done
    for command in "${commands[@]}"; do
      cp "$target_dir/release/$command" "$stage/bin/$command"
      chmod 755 "$stage/bin/$command"
    done
    ;;
  binary)
    target="$(mn_client_target)" || return 1
    for command in "${commands[@]}"; do
      case "$command" in mn)
        repo=mn-cli
        ref="$cli_tag"
        ;;
      mn-api | mn-web-ui-server)
        repo=mn-api
        ref="$api_tag"
        ;;
      *)
        repo=mn-client-support
        ref="$tag"
        ;;
      esac
      mn_client_asset "$command" "$repo" "$ref" "$stage/bin/$command" "$target" || return 1
    done
    ;;
  esac
  for command in "${commands[@]}"; do
    if ! "$stage/bin/$command" --version >/dev/null; then
      print_error "Could not run the staged $command executable. Check the client build or release target and rerun."
      return 1
    fi
  done
  # Keep running API processes paired with their original support executable.
  # The shared link changes only after every binary is present and executable.
  gen="$(mktemp -d "$INSTALL_DIR/client-releases/rust.XXXXXXXX")"
  mv "$stage/bin" "$gen/bin"
  ln -s "client-releases/${gen##*/}" "$stage/active"
  # GNU and BSD mv expose different flags for replacing a directory symlink.
  mv -fT "$stage/active" "$INSTALL_DIR/client-current" 2>/dev/null ||
    mv -fh "$stage/active" "$INSTALL_DIR/client-current"
  for command in "${commands[@]}"; do
    ln -s "../client-current/bin/$command" "$stage/$command"
    mv -f "$stage/$command" "$BIN_DIR/"
  done
  print_detail "Command links: $INSTALL_DIR/bin"
)

function mn_install_client_stage() {
  [ -n "$MN_INSTALL_CLIENT_COMPONENTS" ] || return 0
  mn_print_stage "Installing the client"
  print_step "Installing native client commands in $BIN_DIR"
  mn_install_native_clients
  if [ "$MN_INSTALL_ROLE" = client ]; then
    "$BIN_DIR/mn-client-support" init-client
  fi
  mn_write_shell_environment
  mn_print_stage_result "Client installation" "$MN_INSTALL_CLIENT_COMPONENTS ready"
}

# Full installations serve these static assets with mn-web-ui-server. Local
# checkouts can supply a built dist. Binary installs use the published web app.
function mn_prepare_native_web_assets() {
  local source="${MN_WEB_UI_DIST_DIR:-${1:-}}" destination="$INSTALL_DIR/webui"
  [ "${INSTALL_WEB_UI:-N}" = Y ] || return 0
  if [ -n "$source" ] && { [ -f "$source/dist/index.html" ] || [ -f "$source/index.html" ]; }; then
    source="$(cd "$source" && pwd -P)"
    if [ -L "$destination" ] || [ ! -e "$destination" ]; then
      ln -sfn "$source" "$destination"
      return
    fi
    if [ -f "$destination/dist/index.html" ] || [ -f "$destination/index.html" ]; then return; fi
    if [ ! -e "$INSTALL_DIR/web-ui-source" ] || [ -L "$INSTALL_DIR/web-ui-source" ]; then
      ln -sfn "$source" "$INSTALL_DIR/web-ui-source"
      return
    fi
  fi
  if [ "${MN_INSTALL_MODE:-}" != binary ] && { [ -f "$destination/dist/index.html" ] || [ -f "$destination/index.html" ]; }; then return 0; fi
  local registry="${MN_WEB_UI_NPM_REGISTRY:-https://${MN_GAR_LOCATION:-$MN_DEFAULT_PYTHON_GAR_LOCATION}-npm.pkg.dev/${MN_GAR_PROJECT:-$MN_DEFAULT_CORE_GAR_PROJECT}/${MN_GAR_NPM_REPOSITORY:-$MN_DEFAULT_WEB_UI_GAR_NPM_REPOSITORY}/}"
  local version="${MN_WEB_UI_PACKAGE_VERSION:-${MN_DEFAULT_WEB_UI_VERSION#v}}"
  print_step "Installing the Web UI assets for the native server"
  "${VENV_DIR}/bin/python" - "$INSTALL_DIR" "$registry" "$version" <<'PY_WEB_DIST'
import base64, hashlib, json, os, shutil, sys, tarfile, tempfile, urllib.request
from pathlib import Path, PurePosixPath
from urllib.parse import quote, urlsplit

home, registry, version = Path(sys.argv[1]), sys.argv[2].rstrip("/"), sys.argv[3]
target = home / "web-ui-assets" / version
if not (target / "dist/index.html").is_file():
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=target.parent) as tmp:
        tmp = Path(tmp)
        if urlsplit(registry).scheme != "https":
            raise SystemExit("The Web UI package registry must use HTTPS.")
        with urllib.request.urlopen(f"{registry}/mirrorneuron-web-ui/{quote(version, safe='')}", timeout=30) as response:
            artifact = json.load(response)["dist"]
        if urlsplit(artifact["tarball"]).scheme != "https":
            raise SystemExit("The Web UI download must use HTTPS.")
        with urllib.request.urlopen(artifact["tarball"], timeout=60) as response, (tmp / "package.tgz").open("wb") as out:
            shutil.copyfileobj(response, out)
        with (tmp / "package.tgz").open("rb") as source:
            digest = base64.b64encode(hashlib.file_digest(source, "sha512").digest()).decode()
        if "sha512-" + digest not in artifact["integrity"].split():
            raise SystemExit("Invalid Web UI package checksum.")
        with tarfile.open(tmp / "package.tgz") as archive:
            for item in archive:
                name = PurePosixPath(item.name)
                if name.parts[:2] != ("package", "dist") or not item.isfile():
                    continue
                if ".." in name.parts:
                    raise SystemExit("Invalid Web UI asset path.")
                out = tmp.joinpath("site", *name.parts[1:])
                out.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(item) as source, out.open("xb") as destination:
                    shutil.copyfileobj(source, destination)
        if not (tmp / "site/dist/index.html").is_file():
            raise SystemExit("Web UI package is missing dist/index.html.")
        os.rename(tmp / "site", target)
for name in ("webui", "web-ui-source"):
    link = home / name
    if link.is_symlink() or not link.exists():
        with tempfile.TemporaryDirectory(dir=home) as tmp:
            stage = Path(tmp) / "active"
            stage.symlink_to(target)
            os.replace(stage, link)
        break
else:
    raise SystemExit("Existing Web UI directories occupy both managed asset locations.")
PY_WEB_DIST
}

function mn_install_client() {
  local arg confirmation="" reinstall=Y
  while [ "$#" -gt 0 ]; do
    arg="$1"
    shift
    case "$arg" in
    --no-reinstall) reinstall=N ;;
    --no-start | --no-web-ui | --no-redis | --no-agents | --no-context-engine | --no-openshell | --cli | --api) ;;
    --gar-project | --gar-location | --gar-repository)
      [ "$#" -gt 0 ] || {
        print_error "Missing value after $arg."
        return 1
      }
      shift
      ;;
    --cli-version | --api-version)
      [ "$#" -gt 0 ] || {
        print_error "Missing version after $arg."
        return 1
      }
      mn_validate_version_tag_or_exit "$1"
      if [ "$arg" = --cli-version ]; then MN_CLI_VERSION="$1"; else MN_API_VERSION="$1"; fi
      shift
      ;;
    *)
      print_error "$arg conflicts with --no-runtime. Client mode installs the Rust CLI, API and client support."
      return 1
      ;;
    esac
  done
  if [ "$MN_BUILD_MEMBRANE" = Y ]; then
    print_error "--build-membrane conflicts with --no-runtime."
    return 1
  fi
  mn_reset_resolve_home_or_exit
  INSTALL_DIR="$MN_RESET_HOME"
  export MN_HOME="$INSTALL_DIR"
  BIN_DIR="$INSTALL_DIR/bin"
  local root
  root="$(cd "$(mn_script_dir)/.." && pwd)"
  # The unpinned workspace invocation tests the sibling checkouts. Explicit
  # binary mode, streamed installs and version pins always select release assets.
  if [ "$MN_INSTALL_MODE" = binary ] && [ "$MN_INSTALL_MODE_EXPLICIT" = N ] && [ -z "${MN_INSTALL_STREAM_NAME:-}${MN_INSTALL_VERSION:-}${MN_CLIENT_VERSION:-}${MN_CLIENT_DIST_DIR:-}${MN_CLI_VERSION:-}${MN_API_VERSION:-}${MN_CLI_VERSION_OVERRIDE:-}${MN_API_VERSION_OVERRIDE:-}" ] &&
    [ -f "$root/mn-client-support/Cargo.toml" ] && [ -f "$root/mn-cli/Cargo.toml" ] && [ -f "$root/mn-api/Cargo.toml" ]; then MN_INSTALL_MODE=local; fi
  INSTALL_CLI=Y
  INSTALL_API=Y
  INSTALL_WEB_UI=N
  print_header
  mn_print_install_summary
  mn_report_system
  if [ -L "$BIN_DIR" ] || [ -L "$INSTALL_DIR/client-releases" ] || [ -e "$INSTALL_DIR/docker-compose.yml" ] || [ -e "$INSTALL_DIR/docker-compose.env" ] ||
    { [ -d "$INSTALL_DIR" ] && [ -n "$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ] && ! mn_is_client_home "$INSTALL_DIR"; }; then
    print_error "Choose an empty directory or an existing client installation for MN_HOME."
    return 1
  fi
  if [ "$MN_INSTALL_RESET" = Y ]; then
    printf 'Reset removes this client connection, credentials, logs and downloads. Type YES to continue: ' >&3
    IFS= read -r confirmation || confirmation=""
    if [ "$confirmation" != YES ]; then
      print_warning "Reset cancelled."
      return 0
    fi
  elif [ "$reinstall" = N ] && [ -x "$BIN_DIR/mn" ] && [ -x "$BIN_DIR/mn-api" ] && [ -x "$BIN_DIR/mn-client-support" ]; then
    print_success "Keeping the existing Rust client."
    return 0
  fi
  if [ "$MN_INSTALL_RESET" = Y ]; then
    if [ "$MN_INSTALL_MODE" = local ]; then mn_prepare_local_clients "$root" || return 1; fi
    rm -f "$INSTALL_DIR/client.json" "$INSTALL_DIR/api.token"
    rm -rf "$INSTALL_DIR/outputs" "$INSTALL_DIR/logs"
  fi
  umask 077
  mkdir -p "$INSTALL_DIR"
  if [ ! -f "$INSTALL_DIR/install_metadata.json" ]; then
    printf '{"install_role":"client","install_type":"%s"}\n' "$MN_INSTALL_MODE" >"$INSTALL_DIR/install_metadata.json"
  fi
  mn_install_client_stage
  mn_print_install_complete
}

run_install_github() {
  # Never let git/pip block the installer by asking for GitHub credentials.
  export GIT_TERMINAL_PROMPT="${GIT_TERMINAL_PROMPT:-0}"
  export GH_PROMPT_DISABLED="${GH_PROMPT_DISABLED:-1}"
  export PIP_NO_INPUT="${PIP_NO_INPUT:-1}"

  MN_MANAGED_PYTHON="${MN_MANAGED_PYTHON:-1}"
  MN_MANAGED_PYTHON_VERSION="${MN_MANAGED_PYTHON_VERSION:-$MN_DEFAULT_MANAGED_PYTHON_VERSION}"
  MN_MANAGED_PYTHON_ROOT="${MN_MANAGED_PYTHON_DIR:-${MN_HOME:-${HOME}/.mn}/python}"
  MN_UV_ROOT="${MN_UV_DIR:-${MN_HOME:-${HOME}/.mn}/uv}"
  MN_UV_BIN=""
  MN_GITHUB_TOKEN_LOOKED_UP="N"
  MN_GITHUB_TOKEN_VALUE=""
  MN_GITHUB_GIT_AUTH_CONFIGURED="N"

  function run_quiet() {
    local label="$1"
    shift
    local log_dir="${TMPDIR:-/tmp}/mirror_neuron_install"
    mkdir -p "$log_dir"
    local log_file="${log_dir}/${label//[^A-Za-z0-9_.-]/_}.$$.log"

    if ! "$@" >"$log_file" 2>&1; then
      print_error "$label failed. Details: $log_file"
      if [ "$MN_INSTALL_VERBOSE" = "Y" ]; then
        tail -n 20 "$log_file" >&3 2>/dev/null || true
      else
        printf '  Re-run with --verbose to show the last log lines.\n' >&3
      fi
      if grep -Eqi "could not read Username for 'https://github.com'|authentication failed|repository not found" "$log_file" 2>/dev/null; then
        print_error "GitHub clone authentication failed. For private MirrorNeuron repositories, run 'gh auth login' or set GITHUB_TOKEN/GH_TOKEN and rerun."
      fi
      exit 1
    fi
  }

  function require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
      print_error "'$cmd' is required but not installed."
      exit 1
    fi
  }

  function resolve_github_token() {
    local token=""

    if [ "$MN_GITHUB_TOKEN_LOOKED_UP" = "Y" ]; then
      return 0
    fi

    token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    if [ -z "$token" ] && command -v gh >/dev/null 2>&1; then
      token="$(gh auth token 2>/dev/null || true)"
    fi

    MN_GITHUB_TOKEN_LOOKED_UP="Y"
    MN_GITHUB_TOKEN_VALUE="$token"
  }

  function configure_github_git_auth() {
    local token askpass log_dir

    if [ "$MN_GITHUB_GIT_AUTH_CONFIGURED" = "Y" ]; then
      return 0
    fi

    resolve_github_token
    token="$MN_GITHUB_TOKEN_VALUE"
    if [ -z "$token" ]; then
      return 0
    fi

    log_dir="${TMPDIR:-/tmp}/mirror_neuron_install"
    mkdir -p "$log_dir"
    askpass="${log_dir}/github-askpass.$$"
    cat >"$askpass" <<'EOF'
#!/usr/bin/env sh
case "$1" in
    *Username*) printf '%s\n' "x-access-token" ;;
    *Password*) printf '%s\n' "$MN_GITHUB_TOKEN_FOR_GIT" ;;
    *) printf '%s\n' "$MN_GITHUB_TOKEN_FOR_GIT" ;;
esac
EOF
    chmod 700 "$askpass"
    export MN_GITHUB_TOKEN_FOR_GIT="$token"
    export GIT_ASKPASS="$askpass"
    MN_GITHUB_GIT_AUTH_CONFIGURED="Y"
    print_detail "Configured GitHub authentication for non-interactive Git clones."
  }

  function python_version() {
    "$1" -c 'import sys; print(".".join(str(part) for part in sys.version_info[:3]))' 2>/dev/null
  }

  function python_is_supported() {
    "$1" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' >/dev/null 2>&1
  }

  function python_minor_version() {
    "$1" -c 'import sys; print(".".join(str(part) for part in sys.version_info[:2]))' 2>/dev/null
  }

  function python_is_selected_minor() {
    [ "$(python_minor_version "$1" || true)" = "$MN_MANAGED_PYTHON_VERSION" ]
  }

  function curl_github() {
    local token
    resolve_github_token
    token="$MN_GITHUB_TOKEN_VALUE"
    if [ -n "$token" ]; then
      curl -H "Authorization: Bearer $token" "$@"
    else
      curl "$@"
    fi
  }

  function managed_python_enabled() {
    case "$MN_MANAGED_PYTHON" in
    0 | false | FALSE | False | no | NO | No | n | N) return 1 ;;
    *) return 0 ;;
    esac
  }

  function validate_managed_python_version() {
    if [[ ! "$MN_MANAGED_PYTHON_VERSION" =~ ^[0-9]+[.][0-9]+$ ]]; then
      print_error "MN_MANAGED_PYTHON_VERSION must be a Python minor version like 3.12."
      exit 1
    fi
  }

  function install_uv() {
    local os uv_bin_dir installer
    os="$(uname -s)"

    case "$os" in
    Darwin | Linux) ;;
    *)
      print_error "Unsupported platform for uv-managed Python: ${os}."
      print_error "Set MN_PYTHON=/path/to/python${MN_MANAGED_PYTHON_VERSION} and rerun."
      exit 1
      ;;
    esac

    if ! command -v curl >/dev/null 2>&1; then
      print_error "'curl' is required to install uv."
      exit 1
    fi

    uv_bin_dir="${MN_UV_ROOT}/bin"
    installer="$(mktemp "${TMPDIR:-/tmp}/mn-uv-install.XXXXXX")"
    mkdir -p "$uv_bin_dir"

    print_step "Installing uv for private Python management"
    if ! curl_github -fsSL "https://astral.sh/uv/install.sh" -o "$installer"; then
      rm -f "$installer"
      print_error "Could not download the uv installer."
      print_error "Install uv manually or set MN_PYTHON=/path/to/python${MN_MANAGED_PYTHON_VERSION}."
      exit 1
    fi

    if ! mn_run_uv_installer "$installer" "$uv_bin_dir" >/dev/null 2>&1; then
      rm -f "$installer"
      print_error "Could not install uv."
      print_error "Install uv manually or set MN_PYTHON=/path/to/python${MN_MANAGED_PYTHON_VERSION}."
      exit 1
    fi
    rm -f "$installer"

    MN_UV_BIN="$uv_bin_dir/uv"
    if [ ! -x "$MN_UV_BIN" ]; then
      print_error "uv installer did not create $MN_UV_BIN."
      exit 1
    fi

    print_detail "Installed uv at $MN_UV_BIN."
  }

  function resolve_uv() {
    if [ -n "$MN_UV_BIN" ]; then
      return
    fi

    MN_UV_BIN="$(command -v uv 2>/dev/null || true)"
    if [ -n "$MN_UV_BIN" ]; then
      return
    fi

    MN_UV_BIN="${MN_UV_ROOT}/bin/uv"
    if [ -x "$MN_UV_BIN" ]; then
      return
    fi

    install_uv
  }

  function managed_python_is_expected() {
    local python_bin="$1"
    [ -x "$python_bin" ] &&
      python_is_supported "$python_bin" &&
      [ "$(python_minor_version "$python_bin" || true)" = "$MN_MANAGED_PYTHON_VERSION" ]
  }

  function find_uv_managed_python() {
    UV_PYTHON_INSTALL_DIR="$MN_MANAGED_PYTHON_ROOT" \
      UV_CACHE_DIR="${MN_UV_ROOT}/cache" \
      "$MN_UV_BIN" python find --managed-python --no-python-downloads "$MN_MANAGED_PYTHON_VERSION" 2>/dev/null || true
  }

  function install_managed_python() {
    validate_managed_python_version

    local managed_bin

    print_step "Resolving private Python ${MN_MANAGED_PYTHON_VERSION} runtime with uv"
    print_step "Installing private Python ${MN_MANAGED_PYTHON_VERSION} under ${MN_MANAGED_PYTHON_ROOT}."
    resolve_uv

    managed_bin="$(find_uv_managed_python)"
    if ! managed_python_is_expected "$managed_bin"; then
      run_quiet "uv-python-install" env \
        "UV_PYTHON_INSTALL_DIR=$MN_MANAGED_PYTHON_ROOT" \
        "UV_CACHE_DIR=${MN_UV_ROOT}/cache" \
        "UV_NO_PROGRESS=1" \
        "$MN_UV_BIN" python install "$MN_MANAGED_PYTHON_VERSION"
      managed_bin="$(find_uv_managed_python)"
    fi
    if [ -z "$managed_bin" ]; then
      managed_bin="$(find "$MN_MANAGED_PYTHON_ROOT" -path '*/bin/python3' -print | head -n 1 || true)"
    fi

    if ! managed_python_is_expected "$managed_bin"; then
      print_error "Managed Python install did not produce Python ${MN_MANAGED_PYTHON_VERSION} at ${managed_bin}."
      exit 1
    fi

    MN_PYTHON_BIN="$(mn_base_python_executable "$managed_bin")" || {
      print_error "Could not resolve a stable base Python interpreter from $managed_bin."
      exit 1
    }
    print_detail "Using uv-managed Python $(python_version "$managed_bin") at $managed_bin."
  }

  function print_python_requirement_error() {
    local selected="${1:-}"
    local version=""

    print_error "MirrorNeuron Python components require Python ${MN_MANAGED_PYTHON_VERSION}.x by default."
    if [ -n "$selected" ]; then
      version="$(python_version "$selected" || true)"
      if [ -n "$version" ]; then
        print_error "Selected Python '$selected' is version $version."
      else
        print_error "Selected Python '$selected' could not be run."
      fi
    fi
    print_error "Install Python ${MN_MANAGED_PYTHON_VERSION}.x yourself, or allow the uv-managed private runtime fallback."
    print_error "You can also rerun with: MN_PYTHON=/opt/homebrew/bin/python${MN_MANAGED_PYTHON_VERSION} ./$(basename "$0")"
  }

  function resolve_python_runtime() {
    local candidate resolved
    local candidates=()

    if [ -n "$MN_PYTHON_BIN" ]; then
      return
    fi

    if [ -n "${MN_PYTHON:-}" ]; then
      candidates+=("$MN_PYTHON")
    else
      candidates+=("python${MN_MANAGED_PYTHON_VERSION}" python3 python)
    fi

    for candidate in "${candidates[@]}"; do
      resolved="$(command -v "$candidate" 2>/dev/null || true)"
      if [ -z "$resolved" ]; then
        if [ -n "${MN_PYTHON:-}" ]; then
          print_python_requirement_error "$candidate"
          exit 1
        fi
        continue
      fi
      if python_is_supported "$resolved" && python_is_selected_minor "$resolved"; then
        MN_PYTHON_BIN="$(mn_base_python_executable "$resolved")" || {
          print_error "Could not resolve a stable base Python interpreter from $resolved."
          exit 1
        }
        print_detail "Using Python $(python_version "$MN_PYTHON_BIN") at $MN_PYTHON_BIN."
        return
      fi
      if [ -n "${MN_PYTHON:-}" ]; then
        print_python_requirement_error "$resolved"
        exit 1
      fi
    done

    if managed_python_enabled; then
      install_managed_python
      print_detail "Using Python $(python_version "$MN_PYTHON_BIN") at $MN_PYTHON_BIN."
      return
    fi

    print_warning "Managed Python fallback is disabled."
    resolved="$(command -v "python${MN_MANAGED_PYTHON_VERSION}" 2>/dev/null || true)"
    print_python_requirement_error "$resolved"
    exit 1
  }

  INSTALL_DIR="${MN_HOME:-${HOME}/.mn}"
  BIN_DIR="${INSTALL_DIR}/bin"
  VENV_DIR="${INSTALL_DIR}/venv"
  MN_PYTHON_BIN=""
  SCRIPT_DIR="$(mn_script_dir)"
  RUNTIME_COMPOSE_TEMPLATE="${MN_RUNTIME_COMPOSE_TEMPLATE:-}"
  RUNTIME_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
  RUNTIME_COMPOSE_ENV="${INSTALL_DIR}/docker-compose.env"
  MN_WEB_UI_SOURCE_MODE="${MN_WEB_UI_SOURCE_MODE:-source}"
  MN_WEB_UI_SOURCE_MOUNT="${MN_WEB_UI_SOURCE_MOUNT:-${INSTALL_DIR}/webui}"
  MN_WEB_UI_PACKAGE_VERSION="${MN_WEB_UI_PACKAGE_VERSION:-${MN_DEFAULT_WEB_UI_VERSION#v}}"
  INSTALL_CONTEXT_ENGINE="Y"
  MEMBRANE_REPO="${MN_MEMBRANE_REPO:-MirrorNeuronLab/Membrane}"
  MEMBRANE_GIT_URL="${MN_MEMBRANE_GIT_URL:-}"
  MEMBRANE_DIR="${MN_MEMBRANE_DIR:-${INSTALL_DIR}/Membrane}"
  AGENTS_REPO="${MN_AGENTS_REPO:-MirrorNeuronLab/mn-agents}"
  MN_AGENTS_GIT_URL="${MN_AGENTS_GIT_URL:-}"
  MN_AGENTS_ROOT="${MN_AGENTS_ROOT:-}"
  MN_AGENTS_REF="${MN_AGENTS_REF:-}"
  MN_HOST_HOME_DIR="${MN_HOST_HOME_DIR:-${MN_HOST_MN_DIR:-${INSTALL_DIR}}}"
  MN_HOST_ARTIFACTS_DIR="${MN_HOST_ARTIFACTS_DIR:-${MN_HOST_HOME_DIR}/runs}"
  MN_HOST_BLOB_STORE_DIR="${MN_HOST_BLOB_STORE_DIR:-${MN_HOST_HOME_DIR}/blobs}"
  MN_HOST_SHARED_STORAGE_ROOT="${MN_HOST_SHARED_STORAGE_ROOT:-${MN_HOST_SHARED_ARTIFACT_ROOT:-${MN_HOST_HOME_DIR}/shared}}"
  MN_SYNCTHING_ENABLED="${MN_SYNCTHING_ENABLED:-auto}"
  MN_SYNCTHING_IMAGE="${MN_SYNCTHING_IMAGE:-$MN_DEFAULT_SYNCTHING_IMAGE}"
  MN_SYNCTHING_RESCAN_INTERVAL_SECONDS="${MN_SYNCTHING_RESCAN_INTERVAL_SECONDS:-3600}"
  MN_BLUEPRINT_PYTHON_ENVS_DIR="${MN_BLUEPRINT_PYTHON_ENVS_DIR:-}"
  MN_HOST_OPENSHELL_STATE_DIR="${MN_HOST_OPENSHELL_STATE_DIR:-${INSTALL_DIR}/openshell-state}"

  INSTALL_WEB_UI="Y"
  INSTALL_REDIS="Y"
  MN_OPENSHELL_MODE="${MN_OPENSHELL_MODE:-lazy}"
  START_NOW="Y"
  REINSTALL="Y"
  INSTALL_PYTHON_SDK="Y"
  INSTALL_CLI="Y"
  INSTALL_API="Y"
  INSTALL_VERSION="${MN_INSTALL_VERSION:-}"
  MN_PACKAGE_VERSION=""
  CORE_REPO="${MN_CORE_REPO:-MirrorNeuronLab/MirrorNeuron}"
  MN_SKILLS_GIT_URL="${MN_SKILLS_GIT_URL:-}"
  CORE_RELEASE_TAG=""

  function github_usage() {
    local script_name="${MN_INSTALL_SCRIPT_NAME:-$(basename "$0")}"
    cat >&3 <<EOF
Usage: ./$script_name --mode github [options]

Installs MirrorNeuron from GitHub repositories. Use through --mode github.

Options:
  --version TAG                 Install this release tag from each GitHub repo. If omitted, use each repo's default branch.
  --yes                         Use component defaults and require non-interactive sudo.
  --interactive                 Ask each install question before proceeding.
  --reset                       Permanently clear runtime data first; requires typing YES.
  -v, --verbose                 Show installation details and command paths.
  --no-reinstall                Keep an existing install instead of overwriting it.
  --web-ui / --no-web-ui        Enable or skip the native Web UI.
  --redis / --no-redis          Enable or skip Redis Podman setup.
  --context-engine / --no-context-engine
                                Enable or skip Membrane context engine setup.
  --build-membrane              Local mode: build Membrane source instead of pulling GAR.
                                Ignored in github/binary modes. Source: MN_MEMBRANE_DIR
                                or the sibling Membrane checkout.
  --openshell / --no-openshell  Allow or disable on-demand OpenShell workers.
  --syncthing / --no-syncthing  Enable or skip Syncthing shared-storage replication.
  --start / --no-start          Start or skip starting MirrorNeuron after install.
  --python-components LIST      Install only these components: sdk,cli,api.
                                Use all or none as shortcuts.
  --python-sdk / --no-python-sdk
  --cli / --no-cli
  --api / --no-api
  --skills-git-url URL          Same as MN_SKILLS_GIT_URL.
  MN_AGENTS_ROOT=/path          Override the local agent template catalog.
  MN_AGENTS_REPO=OWNER/REPO     Agent template catalog repo. Default: MirrorNeuronLab/mn-agents.
  MN_AGENTS_GIT_URL=URL         Full agent template catalog Git URL override.
  MN_AGENTS_REF=REF             Agent template catalog ref. Default: --version or repo default branch.
  --python PATH                 Same as MN_PYTHON. Must match Python ${MN_MANAGED_PYTHON_VERSION}.x.
  --no-managed-python           Do not use uv to install a private Python runtime.
  MN_HOME=/path                 Override the runtime state directory. Defaults to ${HOME}/.mn.
  GITHUB_TOKEN/GH_TOKEN         Token for private GitHub repositories. An existing gh auth login is also used.
  -h, --help                    Show this help.

Examples:
  ./$script_name --mode github --no-web-ui
  ./$script_name --mode github --version ${MN_DEFAULT_INSTALL_VERSION}
  ./$script_name --mode github --interactive
  ./$script_name --mode github --python-components sdk,api
  MN_PYTHON=/opt/homebrew/bin/python${MN_MANAGED_PYTHON_VERSION} ./$script_name --mode github
EOF
  }

  function set_python_components() {
    local value="$1"
    local component
    local -a components

    INSTALL_PYTHON_SDK="N"
    INSTALL_CLI="N"
    INSTALL_API="N"

    IFS=',' read -r -a components <<<"$value"
    for component in ${components[@]+"${components[@]}"}; do
      component="$(echo "$component" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
      case "$component" in
      all)
        INSTALL_PYTHON_SDK="Y"
        INSTALL_CLI="Y"
        INSTALL_API="Y"
        ;;
      none) ;;
      sdk | python-sdk)
        INSTALL_PYTHON_SDK="Y"
        ;;
      cli)
        INSTALL_CLI="Y"
        ;;
      api)
        INSTALL_API="Y"
        ;;
      "") ;;
      *)
        print_error "Unknown Python component: $component"
        github_usage
        exit 1
        ;;
      esac
    done
  }

  while [ "$#" -gt 0 ]; do
    case "$1" in
    --no-reinstall) REINSTALL="N" ;;
    --web-ui) INSTALL_WEB_UI="Y" ;;
    --no-web-ui) INSTALL_WEB_UI="N" ;;
    --redis) INSTALL_REDIS="Y" ;;
    --no-redis) INSTALL_REDIS="N" ;;
    --context-engine) INSTALL_CONTEXT_ENGINE="Y" ;;
    --no-context-engine) INSTALL_CONTEXT_ENGINE="N" ;;
    --openshell) MN_OPENSHELL_MODE=lazy ;;
    --no-openshell) MN_OPENSHELL_MODE=disabled ;;
    --syncthing) MN_SYNCTHING_ENABLED="auto" ;;
    --no-syncthing) MN_SYNCTHING_ENABLED="0" ;;
    --start) START_NOW="Y" ;;
    --no-start) START_NOW="N" ;;
    --python-sdk) INSTALL_PYTHON_SDK="Y" ;;
    --no-python-sdk) INSTALL_PYTHON_SDK="N" ;;
    --cli) INSTALL_CLI="Y" ;;
    --no-cli) INSTALL_CLI="N" ;;
    --api) INSTALL_API="Y" ;;
    --no-api) INSTALL_API="N" ;;
    --version)
      shift
      if [ "$#" -eq 0 ]; then
        print_error "--version requires a release tag such as ${MN_DEFAULT_INSTALL_VERSION}."
        github_usage
        exit 1
      fi
      INSTALL_VERSION="$1"
      ;;
    --version=*)
      INSTALL_VERSION="${1#*=}"
      ;;
    --skills-repo)
      shift
      if [ "$#" -eq 0 ]; then
        print_error "--skills-repo requires a value."
        github_usage
        exit 1
      fi
      print_error "--skills-repo is no longer supported; skills are resolved from package dependencies."
      exit 1
      ;;
    --skills-repo=*)
      print_error "--skills-repo is no longer supported; skills are resolved from package dependencies."
      exit 1
      ;;
    --skills-git-url)
      shift
      if [ "$#" -eq 0 ]; then
        print_error "--skills-git-url requires a value."
        github_usage
        exit 1
      fi
      MN_SKILLS_GIT_URL="$1"
      ;;
    --skills-git-url=*) MN_SKILLS_GIT_URL="${1#*=}" ;;
    --python-components)
      shift
      if [ "$#" -eq 0 ]; then
        print_error "--python-components requires a value."
        github_usage
        exit 1
      fi
      set_python_components "$1"
      ;;
    --python-components=*) set_python_components "${1#*=}" ;;
    --python)
      shift
      if [ "$#" -eq 0 ]; then
        print_error "--python requires a path."
        github_usage
        exit 1
      fi
      MN_PYTHON="$1"
      ;;
    --python=*) MN_PYTHON="${1#*=}" ;;
    --no-managed-python) MN_MANAGED_PYTHON=0 ;;
    -h | --help)
      github_usage
      exit 0
      ;;
    *)
      print_error "Unknown option: $1"
      printf 'Use ./install.sh --help for common options or --help-all for the full reference.\n' >&3
      exit 1
      ;;
    esac
    shift
  done

  function finalize_github_install_version() {
    if [ -n "$INSTALL_VERSION" ]; then
      mn_validate_version_tag_or_exit "$INSTALL_VERSION"
      MN_INSTALL_VERSION="$INSTALL_VERSION"
      CORE_RELEASE_TAG="$INSTALL_VERSION"
      MN_PACKAGE_VERSION="$(mn_package_version_from_tag "$INSTALL_VERSION")"
      RUNTIME_COMPOSE_TEMPLATE="${RUNTIME_COMPOSE_TEMPLATE:-${SCRIPT_DIR}/install_support/${INSTALL_VERSION}/docker-compose.yml}"
    else
      MN_INSTALL_VERSION=""
      CORE_RELEASE_TAG=""
      RUNTIME_COMPOSE_TEMPLATE="${RUNTIME_COMPOSE_TEMPLATE:-${SCRIPT_DIR}/docker-compose.yml}"
    fi
    export MN_INSTALL_VERSION
  }

  finalize_github_install_version

  mn_prepare_installer_paths
  print_header

  function github_ref_suffix() {
    if [ -n "$INSTALL_VERSION" ]; then
      printf '@%s' "$INSTALL_VERSION"
    fi
  }

  function github_clone() {
    local url="$1"
    local target="$2"

    if [ -n "$INSTALL_VERSION" ]; then
      git clone --branch "$INSTALL_VERSION" --depth 1 "$url" "$target"
    else
      git clone --depth 1 "$url" "$target"
    fi
  }

  function should_install_python_packages() {
    [ "$INSTALL_PYTHON_SDK" = "Y" ] ||
      [ "$INSTALL_CLI" = "Y" ] ||
      [ "$INSTALL_API" = "Y" ] ||
      [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]
  }

  function validate_selections() {
    if [ "$INSTALL_WEB_UI" = "Y" ] && [ "$INSTALL_API" != "Y" ]; then
      print_warning "Installing Web UI without the API package. The UI will need an API service from another install."
    fi
  }

  function context_engine_git_url() {
    if [ -n "$MEMBRANE_GIT_URL" ]; then
      printf '%s' "$MEMBRANE_GIT_URL"
    else
      printf 'https://github.com/%s.git' "$MEMBRANE_REPO"
    fi
  }

  function core_git_url() {
    printf 'https://github.com/%s.git' "$CORE_REPO"
  }

  function agents_git_url() {
    if [ -n "$MN_AGENTS_GIT_URL" ]; then
      printf '%s' "$MN_AGENTS_GIT_URL"
    else
      printf 'https://github.com/%s.git' "$AGENTS_REPO"
    fi
  }

  function validate_agents_root() {
    local root="$1"
    if [ ! -f "${root}/index.json" ]; then
      print_error "mn-agents index was not found at ${root}/index.json."
      print_error "Set MN_AGENTS_ROOT to a valid mn-agents checkout or fix the catalog install."
      exit 1
    fi
  }

  function safe_agents_ref_path() {
    printf '%s' "$1" | tr '/: ' '___'
  }

  function resolve_agents_ref() {
    local default_branch
    if [ -n "${MN_AGENTS_REF:-}" ]; then
      printf '%s' "$MN_AGENTS_REF"
      return 0
    fi
    if [ -n "${INSTALL_VERSION:-}" ]; then
      printf '%s' "$INSTALL_VERSION"
      return 0
    fi
    default_branch="$(git ls-remote --symref "$(agents_git_url)" HEAD 2>/dev/null | sed -n 's#^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$#\1#p' | head -n 1)"
    if [ -z "$default_branch" ]; then
      print_error "Could not resolve the default branch for $(agents_git_url)."
      print_error "Set MN_AGENTS_REF explicitly and rerun."
      exit 1
    fi
    printf '%s' "$default_branch"
  }

  function ensure_agent_catalog_root() {
    local ref safe_ref root url
    if [ -n "${MN_AGENTS_ROOT:-}" ]; then
      validate_agents_root "$MN_AGENTS_ROOT"
      (cd "$MN_AGENTS_ROOT" && pwd)
      return 0
    fi

    ref="$(resolve_agents_ref)"
    safe_ref="$(safe_agents_ref_path "$ref")"
    root="${INSTALL_DIR}/agent-catalogs/mn-agents/${safe_ref}"
    url="$(agents_git_url)"
    mkdir -p "$(dirname "$root")"

    if [ -e "$root" ] && [ ! -d "${root}/.git" ]; then
      print_error "Expected cached mn-agents catalog to be a git checkout: ${root}"
      print_error "Move or remove that path, or set MN_AGENTS_ROOT to a valid catalog."
      exit 1
    fi

    if [ ! -d "${root}/.git" ]; then
      run_quiet "clone-mn-agents-${safe_ref}" git clone --branch "$ref" --depth 1 "$url" "$root"
    else
      (
        cd "$root"
        git remote set-url origin "$url" >/dev/null 2>&1 || true
        git fetch --tags origin "$ref" >/dev/null 2>&1
        git checkout --force "$ref" >/dev/null 2>&1
        if git show-ref --verify --quiet "refs/remotes/origin/${ref}"; then
          git pull --ff-only origin "$ref" >/dev/null 2>&1
        fi
      ) || {
        print_error "Could not update cached mn-agents catalog at ${root}."
        exit 1
      }
    fi

    validate_agents_root "$root"
    printf '%s\n' "$root"
  }

  function compose_profiles() {
    local profiles=()
    [ "$INSTALL_CONTEXT_ENGINE" = "Y" ] && profiles+=("context")
    case "$(printf '%s' "$MN_SYNCTHING_ENABLED" | tr '[:upper:]' '[:lower:]')" in
    '' | 0 | false | no | n | off | disabled) ;;
    *) profiles+=("syncthing") ;;
    esac
    if [ "${#profiles[@]}" -eq 0 ]; then
      printf ''
      return 0
    fi
    local IFS=,
    printf '%s' "${profiles[*]}"
  }

  function generate_mn_secret() {
    local secret
    local python_fallback="${MN_PYTHON_BIN:-}"

    if command -v openssl >/dev/null 2>&1; then
      if secret="$(openssl rand -hex 32 2>/dev/null)" && [ -n "$secret" ]; then
        printf '%s\n' "$secret"
        return 0
      fi
    fi

    if command -v od >/dev/null 2>&1 && [ -r /dev/urandom ]; then
      if secret="$(od -An -N32 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" && [ -n "$secret" ]; then
        printf '%s\n' "$secret"
        return 0
      fi
    fi

    if [ -z "$python_fallback" ]; then
      python_fallback="$(command -v "python${MN_MANAGED_PYTHON_VERSION}" 2>/dev/null || true)"
    fi
    if [ -n "$python_fallback" ]; then
      if secret="$("$python_fallback" -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null)" && [ -n "$secret" ]; then
        printf '%s\n' "$secret"
        return 0
      fi
    fi

    return 1
  }

  function resolve_secret_file() {
    local env_value="$1"
    local file="$2"
    local label="$3"
    local value

    case "$label:$env_value" in
    MN_GRPC_AUTH_TOKEN:mirror_neuron_password | MN_GRPC_ADMIN_TOKEN:mirror_neuron_password_admin) env_value="" ;;
    esac
    if [ -n "$env_value" ] && [ "$env_value" != "mirrorneuron" ]; then
      printf '%s\n' "$env_value" >"$file"
      chmod 600 "$file" 2>/dev/null || true
      printf '%s\n' "$env_value"
      return 0
    fi

    mkdir -p "$INSTALL_DIR"
    if [ -s "$file" ]; then
      value="$(tr -d '[:space:]' <"$file")"
      case "$label:$value" in
      MN_GRPC_AUTH_TOKEN:mirror_neuron_password | MN_GRPC_ADMIN_TOKEN:mirror_neuron_password_admin) value="" ;;
      esac
      if [ -n "$value" ] && [ "$value" != "mirrorneuron" ]; then
        chmod 600 "$file" 2>/dev/null || true
        printf '%s\n' "$value"
        return 0
      fi
    fi

    if ! value="$(generate_mn_secret)"; then
      value=""
    fi
    if [ -z "$value" ]; then
      print_error "Failed to generate ${label}."
      exit 1
    fi
    printf '%s\n' "$value" >"$file"
    chmod 600 "$file" 2>/dev/null || true
    printf '%s\n' "$value"
  }

  function resolve_mn_cookie() {
    resolve_secret_file "${MN_COOKIE:-}" "${INSTALL_DIR}/erlang.cookie" "MN_COOKIE"
  }

  function resolve_network_token() {
    resolve_secret_file "${MN_NETWORK_JOIN_TOKEN:-}" "${INSTALL_DIR}/network.token" "MN_NETWORK_JOIN_TOKEN"
  }

  function derive_network_secret() {
    local token="$1"
    local label="$2"
    local material="mirror-neuron:${label}:${token}"
    local digest
    local python_fallback="${MN_PYTHON_BIN:-}"

    if command -v shasum >/dev/null 2>&1; then
      if digest="$(printf '%s' "$material" | shasum -a 256 2>/dev/null | awk '{print $1}')" && [ -n "$digest" ]; then
        printf '%s\n' "$digest"
        return 0
      fi
    fi

    if command -v sha256sum >/dev/null 2>&1; then
      if digest="$(printf '%s' "$material" | sha256sum 2>/dev/null | awk '{print $1}')" && [ -n "$digest" ]; then
        printf '%s\n' "$digest"
        return 0
      fi
    fi

    if command -v openssl >/dev/null 2>&1; then
      if digest="$(printf '%s' "$material" | openssl dgst -sha256 -r 2>/dev/null | awk '{print $1}')" && [ -n "$digest" ]; then
        printf '%s\n' "$digest"
        return 0
      fi
    fi

    if [ -z "$python_fallback" ]; then
      python_fallback="$(command -v "python${MN_MANAGED_PYTHON_VERSION}" 2>/dev/null || true)"
    fi
    if [ -n "$python_fallback" ]; then
      if digest="$(printf '%s' "$material" | "$python_fallback" -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null)" && [ -n "$digest" ]; then
        printf '%s\n' "$digest"
        return 0
      fi
    fi

    print_error "Need shasum, sha256sum, a working openssl, or python${MN_MANAGED_PYTHON_VERSION} to derive Redis credentials."
    exit 1
  }

  function resolve_redis_password() {
    local admin_token="$1"
    local mn_env="${MN_ENV:-dev}"
    local password

    case "$mn_env" in
    prod | production)
      password="$(derive_network_secret "$admin_token" "redis")"
      mkdir -p "$INSTALL_DIR"
      printf '%s\n' "$password" >"${INSTALL_DIR}/redis.password"
      chmod 600 "${INSTALL_DIR}/redis.password" 2>/dev/null || true
      printf '%s\n' "$password"
      ;;
    *)
      printf '%s\n' "mirror_neuron_redis_dev"
      ;;
    esac
  }

  function ensure_runtime_host_directory() {
    local path="$1"
    local description="$2"
    local override_name="$3"

    if [ -e "$path" ] || [ -L "$path" ]; then
      if [ ! -d "$path" ]; then
        print_error "Expected ${description} to be a directory: ${path}"
        print_error "Move or remove that path, or set ${override_name} to a directory."
        exit 1
      fi
      chmod u+rwx "$path" 2>/dev/null || true
      if [ ! -w "$path" ]; then
        print_error "Expected ${description} to be writable: ${path}"
        print_error "Repair ownership or set ${override_name} to a writable directory."
        exit 1
      fi
      return 0
    fi

    mkdir -p "$path"
    chmod u+rwx "$path" 2>/dev/null || true
  }

  function prepare_litellm_gateway_config() {
    local gateway_dir="${MN_HOST_HOME_DIR}/models/litellm-gateway"
    mkdir -p "$gateway_dir"
    if [ ! -e "${gateway_dir}/config.yaml" ]; then
      printf '{"model_list":[]}\n' >"${gateway_dir}/config.yaml"
    fi
    chmod u+rwX "$gateway_dir" "${gateway_dir}/config.yaml" 2>/dev/null || true
  }

  function write_runtime_compose_files() {
    local context_auth_token profiles network_name network_external network_token redis_password mn_cookie runtime_skills_root runtime_agents_root runtime_package_index context_memory_enabled otterdesk_context_memory_enabled membrane_engine_tag membrane_engine_image litellm_gateway_bind_host api_host
    local grpc_auth_token grpc_admin_token runtime_port_settings
    grpc_auth_token="$(resolve_secret_file "${MN_GRPC_AUTH_TOKEN:-}" "${INSTALL_DIR}/grpc_auth.token" "MN_GRPC_AUTH_TOKEN")"
    grpc_admin_token="$(resolve_secret_file "${MN_GRPC_ADMIN_TOKEN:-}" "${INSTALL_DIR}/grpc_admin.token" "MN_GRPC_ADMIN_TOKEN")"
    context_auth_token="$(resolve_secret_file "${MN_CONTEXT_AUTH_TOKEN:-}" "${INSTALL_DIR}/context_auth.token" "MN_CONTEXT_AUTH_TOKEN")"
    profiles="$(compose_profiles)"
    api_host="${MN_API_HOST:-localhost}"
    litellm_gateway_bind_host="${MN_LITELLM_GATEWAY_BIND_HOST:-0.0.0.0}"
    network_name="${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
    network_external="$(mn_runtime_network_external "$network_name")"
    network_token="$(resolve_network_token)"
    redis_password="$(resolve_redis_password "mirror_neuron_password_admin")"
    mn_cookie="$(resolve_mn_cookie)"
    runtime_skills_root="${MN_SKILLS_ROOT:-${MN_HOST_HOME_DIR}/skills}"
    runtime_agents_root="$(ensure_agent_catalog_root)"
    runtime_package_index="${MN_PACKAGE_INDEX_FILE:-}"
    membrane_engine_tag="${MN_MEMBRANE_ENGINE_IMAGE_TAG:-$(mn_default_membrane_engine_tag)}"
    if [[ "$membrane_engine_tag" != v* ]]; then
      membrane_engine_tag="v${membrane_engine_tag}"
    fi
    membrane_engine_image="${MN_MEMBRANE_ENGINE_IMAGE:-${MN_CONTEXT_ENGINE_IMAGE:-${MN_DEFAULT_MEMBRANE_GAR_IMAGE}:${membrane_engine_tag}}}"
    membrane_engine_image="$(mn_selected_membrane_image "$membrane_engine_image")"
    if [ "$MN_BUILD_MEMBRANE" = "Y" ]; then membrane_engine_tag=""; fi
    context_memory_enabled="${MN_CONTEXT_MEMORY_ENABLED:-1}"
    otterdesk_context_memory_enabled="${OTTERDESK_CONTEXT_MEMORY_ENABLED:-$context_memory_enabled}"
    if [ -n "${PACKAGE_INDEX_FILE:-}" ] && [ -f "$PACKAGE_INDEX_FILE" ]; then
      runtime_package_index="${INSTALL_DIR}/package-index/python-packages.toml"
      mkdir -p "$(dirname "$runtime_package_index")"
      cp "$PACKAGE_INDEX_FILE" "$runtime_package_index"
    fi

    mkdir -p "$INSTALL_DIR"
    ensure_runtime_host_directory "$MN_HOST_HOME_DIR" "MirrorNeuron home mount" "MN_HOST_HOME_DIR"
    ensure_runtime_host_directory "$runtime_skills_root" "MirrorNeuron runtime modules root" "MN_SKILLS_ROOT"
    ensure_runtime_host_directory "$MN_HOST_ARTIFACTS_DIR" "run artifacts host mount" "MN_HOST_ARTIFACTS_DIR"
    ensure_runtime_host_directory "$MN_HOST_BLOB_STORE_DIR" "blob store host mount" "MN_HOST_BLOB_STORE_DIR"
    ensure_runtime_host_directory "$MN_HOST_SHARED_STORAGE_ROOT" "shared storage host mount" "MN_HOST_SHARED_STORAGE_ROOT"
    prepare_litellm_gateway_config
    mn_write_runtime_compose_file "$RUNTIME_COMPOSE_TEMPLATE" "$RUNTIME_COMPOSE_FILE"
    runtime_port_settings="$(mn_runtime_port_settings "$RUNTIME_COMPOSE_ENV")"
    cat >"$RUNTIME_COMPOSE_ENV" <<EOF
COMPOSE_PROJECT_NAME=mirror-neuron
COMPOSE_PROFILES=${profiles}
MN_HOST_STATE_DIR=${INSTALL_DIR}
MN_HOST_HOME_DIR=${MN_HOST_HOME_DIR}
MN_HOST_ARTIFACTS_DIR=${MN_HOST_ARTIFACTS_DIR}
MN_HOST_BLOB_STORE_DIR=${MN_HOST_BLOB_STORE_DIR}
MN_HOST_SHARED_STORAGE_ROOT=${MN_HOST_SHARED_STORAGE_ROOT}
MN_SYNCTHING_ENABLED=${MN_SYNCTHING_ENABLED}
MN_SYNCTHING_IMAGE=${MN_SYNCTHING_IMAGE}
MN_SYNCTHING_RESCAN_INTERVAL_SECONDS=${MN_SYNCTHING_RESCAN_INTERVAL_SECONDS}
MN_BLUEPRINT_PYTHON_ENVS_DIR=${MN_BLUEPRINT_PYTHON_ENVS_DIR}
MN_HOST_OPENSHELL_STATE_DIR=${MN_HOST_OPENSHELL_STATE_DIR}
MN_MEMBRANE_SOURCE_MODE=$(mn_selected_membrane_source_mode)
ENGINE_IMAGE=${membrane_engine_image}
MN_MEMBRANE_ENGINE_IMAGE=${membrane_engine_image}
MN_MEMBRANE_ENGINE_IMAGE_TAG=${membrane_engine_tag}
MN_REDIS_IMAGE=${MN_REDIS_IMAGE:-$MN_DEFAULT_REDIS_IMAGE}
MN_CONTEXT_AUTH_TOKEN=${context_auth_token}
MN_CONTEXT_MODEL_COMPRESSION_ENABLED=true
MN_CONTEXT_OBSERVABILITY=${MN_CONTEXT_OBSERVABILITY:-false}
MN_CONTEXT_TOKEN_COUNTER_FACTORY=${MN_CONTEXT_TOKEN_COUNTER_FACTORY:-}
MN_LLM_MODEL_RUNNER_MODEL=${MN_LLM_MODEL_RUNNER_MODEL:-$MN_DEFAULT_LLM_MODEL_RUNNER_MODEL}
MN_GRPC_BIND_HOST=${MN_GRPC_BIND_HOST:-127.0.0.1}
MN_GRPC_PORT=${MN_GRPC_PORT:-55051}
MN_GRPC_TARGET=${MN_GRPC_TARGET:-localhost:${MN_GRPC_PORT:-55051}}
MN_GRPC_ADVERTISE_PORT=${MN_GRPC_ADVERTISE_PORT:-${MN_GRPC_PORT:-55051}}
MN_NATIVE_SDK_GRPC_HOST=${MN_NATIVE_SDK_GRPC_HOST:-0.0.0.0}
MN_NATIVE_SDK_GRPC_PORT=${MN_NATIVE_SDK_GRPC_PORT:-55052}
MN_NATIVE_SDK_GRPC_ADVERTISE_HOST=${MN_NATIVE_SDK_GRPC_ADVERTISE_HOST:-${MN_NETWORK_ADVERTISE_HOST:-}}
MN_NATIVE_SDK_GRPC_ADVERTISE_PORT=${MN_NATIVE_SDK_GRPC_ADVERTISE_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_NATIVE_SDK_GRPC_TARGET=${MN_NATIVE_SDK_GRPC_TARGET:-mn-native-sdk-grpc:55052}
MN_RESOURCE_GC_ENABLED=${MN_RESOURCE_GC_ENABLED:-true}
MN_RESOURCE_GC_INTERVAL_SECONDS=${MN_RESOURCE_GC_INTERVAL_SECONDS:-1800}
MN_RESOURCE_GC_ORPHAN_GRACE_SECONDS=${MN_RESOURCE_GC_ORPHAN_GRACE_SECONDS:-3600}
MN_RESOURCE_GC_BATCH_SIZE=${MN_RESOURCE_GC_BATCH_SIZE:-100}
MN_DOCKER_WORKER_IMAGE_CACHE_TTL_SECONDS=${MN_DOCKER_WORKER_IMAGE_CACHE_TTL_SECONDS:-604800}
MN_DOCKER_WORKER_IMAGE_CACHE_MAX_BYTES=${MN_DOCKER_WORKER_IMAGE_CACHE_MAX_BYTES:-21474836480}
MN_NATIVE_SDK_GRPC_PROXY_PORT=${MN_NATIVE_SDK_GRPC_PROXY_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_NATIVE_SDK_GRPC_PROXY_TARGET_HOST=${MN_NATIVE_SDK_GRPC_PROXY_TARGET_HOST:-host.containers.internal}
MN_NATIVE_SDK_GRPC_PROXY_TARGET_PORT=${MN_NATIVE_SDK_GRPC_PROXY_TARGET_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_LITELLM_GATEWAY_BIND_HOST=${litellm_gateway_bind_host}
MN_LITELLM_GATEWAY_PORT=${MN_LITELLM_GATEWAY_PORT:-4000}
MN_LITELLM_GATEWAY_INTERNAL_API_BASE=${MN_LITELLM_GATEWAY_INTERNAL_API_BASE:-http://mn-litellm-proxy:4000/v1}
MN_API_HOST=${api_host}
MN_API_PORT=${MN_API_PORT:-54001}
MN_DIST_PORT=${MN_DIST_PORT:-54370}
MN_WEB_UI_HOST=${MN_WEB_UI_HOST:-localhost}
MN_WEB_UI_PORT=${MN_WEB_UI_PORT:-55173}
MN_WEB_UI_BIND_HOST=${MN_WEB_UI_BIND_HOST:-127.0.0.1}
MN_WEB_UI_NPM_REGISTRY=${MN_WEB_UI_NPM_REGISTRY:-https://${MN_GAR_LOCATION:-$MN_DEFAULT_PYTHON_GAR_LOCATION}-npm.pkg.dev/${MN_GAR_PROJECT:-$MN_DEFAULT_CORE_GAR_PROJECT}/${MN_GAR_NPM_REPOSITORY:-$MN_DEFAULT_WEB_UI_GAR_NPM_REPOSITORY}/}
MN_WEB_UI_SOURCE_MODE=${MN_WEB_UI_SOURCE_MODE}
MN_WEB_UI_SOURCE_MOUNT=${MN_WEB_UI_SOURCE_MOUNT}
MN_WEB_UI_PACKAGE_VERSION=${MN_WEB_UI_PACKAGE_VERSION}
MN_BLUEPRINT_WEB_UI_BIND_HOST=${MN_BLUEPRINT_WEB_UI_BIND_HOST:-0.0.0.0}
MN_BLUEPRINT_WEB_UI_PUBLIC_HOST=${MN_BLUEPRINT_WEB_UI_PUBLIC_HOST:-localhost}
${runtime_port_settings}
MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE=${MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE:-prepublished}
MN_ENV=${MN_ENV:-prod}
MN_USE_LOCAL_SKILLS=${MN_USE_LOCAL_SKILLS}
MN_BLUEPRINT_SOURCE=${MN_BLUEPRINT_SOURCE:-github}
MN_BLUEPRINT_REPO=${MN_BLUEPRINT_REPO:-https://github.com/MirrorNeuronLab/mn-blueprints.git}
MN_BLUEPRINT_LOCAL=${MN_BLUEPRINT_LOCAL:-}
MN_WORKSPACE_ROOT=${MN_WORKSPACE_ROOT:-}
MN_CONNECT_URL=${MN_CONNECT_URL:-}
MN_AGENTS_ROOT=${runtime_agents_root}
MN_SKILLS_ROOT=${runtime_skills_root}
MN_PACKAGE_INDEX_FILE=${runtime_package_index}
MN_PIP_INDEX_URL=${MN_PIP_INDEX_URL:-${MN_PYTHON_INDEX_URL:-${MN_DEFAULT_PIP_INDEX_URL}}}
MN_PIP_EXTRA_INDEX_URL=${MN_PIP_EXTRA_INDEX_URL:-${MN_PYTHON_EXTRA_INDEX_URL:-https://pypi.org/simple}}
MN_RUNTIME_MODULE_VERSION=${MN_RUNTIME_MODULE_VERSION:-${MN_PACKAGE_VERSION:-}}
MN_CONTEXT_MEMORY_ENABLED=${context_memory_enabled}
OTTERDESK_CONTEXT_MEMORY_ENABLED=${otterdesk_context_memory_enabled}
MN_RUNS_ROOT=${MN_RUNS_ROOT:-}
MN_DOCKER_NETWORK_MODE=${MN_DOCKER_NETWORK_MODE:-bridge}
MN_DOCKER_NETWORK_NAME=${network_name}
MN_DOCKER_NETWORK_EXTERNAL=${network_external}
MN_DOCKER_NETWORK_DRIVER=${MN_DOCKER_NETWORK_DRIVER:-bridge}
MN_DOCKER_NETWORK_ATTACHABLE=${MN_DOCKER_NETWORK_ATTACHABLE:-false}
MN_DOCKER_WORKER_ENABLED=${MN_DOCKER_WORKER_ENABLED:-1}
MN_NODE_ALIAS=${MN_NODE_ALIAS:-}
MN_NODE_NAME=${MN_NODE_NAME:-}
MN_NODE_ROLE=${MN_NODE_ROLE:-runtime}
MN_CLUSTER_NODES=${MN_CLUSTER_NODES:-}
MN_NETWORK_JOIN_TOKEN=${network_token}
MN_REDIS_PASSWORD=${redis_password}
MN_REDIS_URL=${MN_REDIS_URL:-redis://:${redis_password}@redis:6379/0}
MN_REDIS_HA_MODE=${MN_REDIS_HA_MODE:-single}
MN_REDIS_SENTINELS=${MN_REDIS_SENTINELS:-}
MN_REDIS_SENTINEL_MASTER=${MN_REDIS_SENTINEL_MASTER:-mirror-neuron}
MN_REDIS_SENTINEL_HOST_MAP=${MN_REDIS_SENTINEL_HOST_MAP:-}
MN_REDIS_DB=${MN_REDIS_DB:-0}
MN_REDIS_USERNAME=${MN_REDIS_USERNAME:-}
MN_REDIS_SENTINEL_USERNAME=${MN_REDIS_SENTINEL_USERNAME:-}
MN_REDIS_SENTINEL_PASSWORD=${MN_REDIS_SENTINEL_PASSWORD:-${redis_password}}
MN_REDIS_WAIT_REPLICAS=${MN_REDIS_WAIT_REPLICAS:-0}
MN_REDIS_WAIT_TIMEOUT_MS=${MN_REDIS_WAIT_TIMEOUT_MS:-100}
MN_REDIS_RECONNECT_ATTEMPTS=${MN_REDIS_RECONNECT_ATTEMPTS:-10}
MN_REDIS_RECONNECT_BACKOFF_MS=${MN_REDIS_RECONNECT_BACKOFF_MS:-250}
MN_REDIS_RECONNECT_MAX_BACKOFF_MS=${MN_REDIS_RECONNECT_MAX_BACKOFF_MS:-2000}
ERL_EPMD_ADDRESS=${ERL_EPMD_ADDRESS:-0.0.0.0}
ERL_AFLAGS=${ERL_AFLAGS:--kernel inet_dist_listen_min ${MN_DIST_PORT:-54370} inet_dist_listen_max ${MN_DIST_PORT:-54370}}
$(mn_openshell_plugin_env)
MN_SYNCTHING_UID=${MN_SYNCTHING_UID}
MN_SYNCTHING_GID=${MN_SYNCTHING_GID}
PODMAN_HOST_SOCKET=${PODMAN_HOST_SOCKET}
COMPOSE_PARALLEL_LIMIT=${COMPOSE_PARALLEL_LIMIT:-1}
MN_COOKIE=${mn_cookie}
MN_GRPC_AUTH_TOKEN=${grpc_auth_token}
MN_GRPC_ADMIN_TOKEN=${grpc_admin_token}
EOF
    chmod 600 "$RUNTIME_COMPOSE_ENV" 2>/dev/null || true
  }

  EXISTING_INSTALL="N"
  if [ "$MN_EXISTING_INSTALL" = "Y" ]; then
    if [ "$MN_INSTALL_RESET" != "Y" ]; then
      print_step "Refreshing the existing installation."
    fi
    if [ "$MN_INSTALL_RESET" = "Y" ]; then
      REINSTALL="Y"
    elif [ "$NON_INTERACTIVE" != "Y" ]; then
      REINSTALL=$(ask "Reinstall the existing installation?" "$REINSTALL")
    fi
    if [ "$REINSTALL" = "N" ]; then
      print_warning "Installation cancelled."
      exit 0
    fi
    echo "" >&3
    EXISTING_INSTALL="Y"
  fi

  # Interactive Prompts
  if [ "$NON_INTERACTIVE" != "Y" ]; then
    printf '\nChoose components. Press Enter to accept each default.\n' >&3
    INSTALL_WEB_UI=$(ask "Install the Web UI?" "$INSTALL_WEB_UI")
    INSTALL_REDIS=$(ask "Enable Redis?" "$INSTALL_REDIS")
    if [ "$MN_BUILD_MEMBRANE" != "Y" ]; then
      INSTALL_CONTEXT_ENGINE=$(ask "Enable the Membrane context engine?" "$INSTALL_CONTEXT_ENGINE")
    fi
    START_NOW=$(ask "Start the runtime after installation?" "$START_NOW")
  fi
  validate_selections

  mn_print_install_summary
  mn_report_system

  require_cmd git
  require_cmd curl
  configure_github_git_auth
  mn_install_client_stage

  mn_begin_runtime_install || return 1
  resolve_python_runtime
  if [ "$EXISTING_INSTALL" = "Y" ]; then
    print_step "Preparing fresh install"
    mn_remove_existing_install_paths
  fi

  print_step "Installing MirrorNeuron Core (Podman)"

  (
    mn_remove_path_or_exit "$INSTALL_DIR/core-source" "MirrorNeuron Core source"
    github_clone "$(core_git_url)" "$INSTALL_DIR/core-source" >/dev/null 2>&1
    cd "$INSTALL_DIR/core-source"

    if [ ! -f Dockerfile ]; then
      print_error "The Core checkout must include its runtime Dockerfile."
      exit 1
    fi

    mn_run_podman_build -t mirror-neuron-core .
  ) &
  spinner $! "Cloning and building Core (Podman image mirror-neuron-core)"
  write_runtime_compose_files

  if should_install_python_packages; then
    print_step "Installing selected Python components from GitHub"
    (
      "$MN_PYTHON_BIN" -m venv "$VENV_DIR" >/dev/null 2>&1
      run_quiet "pip-upgrade" "$VENV_DIR/bin/pip" install --upgrade pip
      # The Git runtime depends on the worker SDK even when only a surface was
      # explicitly selected. Use the requested ref in each source repository.
      local sdk_reference
      sdk_reference="git+https://github.com/MirrorNeuronLab/mn-python-sdk.git$(github_ref_suffix)"
      local -a sdk_requirements=("mirrorneuron-python-sdk @ $sdk_reference") sdk_groups=(sdk)
      local package_name package_path package_extras component_rows
      component_rows="$(mn_sdk_component_rows "${sdk_groups[@]}")" || return 1
      while IFS=$'\t' read -r package_name package_path package_extras; do
        [ -n "$package_name" ] || continue
        sdk_requirements+=("${package_name}${package_extras} @ ${sdk_reference}#subdirectory=${package_path#mn-python-sdk/}")
      done <<<"$component_rows"
      run_quiet "install-mn-python-sdk-github" "$VENV_DIR/bin/pip" install "${sdk_requirements[@]}"
      run_quiet "install-mn-runtime-github" "$VENV_DIR/bin/pip" install "mirrorneuron-runtime @ git+https://github.com/MirrorNeuronLab/mn-python-sdk.git$(github_ref_suffix)#subdirectory=packages/runtime"
      if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
        run_quiet "install-membrane-python-sdk-github" "$VENV_DIR/bin/pip" install "mirrorneuron-membrane-python-sdk @ git+$(context_engine_git_url)$(github_ref_suffix)#subdirectory=mn-context-engine-python-sdk"
      fi
    ) &
    spinner $! "Setting up virtualenv and installing Python packages"
  else
    print_step "Python component installation disabled by selection."
  fi

  mn_prepare_native_web_assets
  mn_configure_installed_runtime

  if [ "$INSTALL_CLI" = "Y" ]; then
    print_detail "CLI: mn"
  fi
  if [ "$INSTALL_API" = "Y" ]; then
    print_detail "API: mn-api"
  fi
  if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
    print_detail "Membrane endpoint: ${MN_CONTEXT_ADDR:-localhost:50052}"
  fi

  mn_finish_runtime_install
  mn_print_install_complete
}

run_install_local() {
  SCRIPT_DIR="$(mn_script_dir)"
  WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

  INSTALL_DIR="${MN_HOME:-${HOME}/.mn}"
  BIN_DIR="${INSTALL_DIR}/bin"
  VENV_DIR="${INSTALL_DIR}/venv"
  RUNTIME_COMPOSE_TEMPLATE="${SCRIPT_DIR}/docker-compose.yml"
  RUNTIME_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
  RUNTIME_COMPOSE_ENV="${INSTALL_DIR}/docker-compose.env"

  CORE_DIR="${WORKSPACE_DIR}/MirrorNeuron"
  CLI_DIR="${WORKSPACE_DIR}/mn-cli"
  API_DIR="${WORKSPACE_DIR}/mn-api"
  PY_SDK_DIR="${WORKSPACE_DIR}/mn-python-sdk"
  CLIENT_SUPPORT_DIR="${WORKSPACE_DIR}/mn-client-support"
  WEB_UI_DIR="${WORKSPACE_DIR}/mn-web-ui"
  MN_WEB_UI_SOURCE_MODE="${MN_WEB_UI_SOURCE_MODE:-source}"
  MN_WEB_UI_SOURCE_MOUNT="${MN_WEB_UI_SOURCE_MOUNT:-${WEB_UI_DIR}}"
  MN_WEB_UI_PACKAGE_VERSION="${MN_WEB_UI_PACKAGE_VERSION:-${MN_DEFAULT_WEB_UI_VERSION#v}}"
  SKILLS_DIR="${WORKSPACE_DIR}/mn-skills"
  AGENTS_DIR="${WORKSPACE_DIR}/mn-agents"
  BLUEPRINTS_DIR="${WORKSPACE_DIR}/mn-blueprints"
  DOCS_DIR="${WORKSPACE_DIR}/mn-docs"
  SYSTEM_TESTS_DIR="${WORKSPACE_DIR}/mn-system-tests"
  MEMBRANE_DIR="${WORKSPACE_DIR}/Membrane"
  MN_MEMBRANE_SOURCE_MODE="${MN_MEMBRANE_SOURCE_MODE:-image}"
  MN_HOST_HOME_DIR="${MN_HOST_HOME_DIR:-${MN_HOST_MN_DIR:-${INSTALL_DIR}}}"
  MN_AGENTS_ROOT="${MN_AGENTS_ROOT:-}"
  MN_HOST_ARTIFACTS_DIR="${MN_HOST_ARTIFACTS_DIR:-${MN_HOST_HOME_DIR}/runs}"
  MN_HOST_BLOB_STORE_DIR="${MN_HOST_BLOB_STORE_DIR:-${MN_HOST_HOME_DIR}/blobs}"
  MN_HOST_SHARED_STORAGE_ROOT="${MN_HOST_SHARED_STORAGE_ROOT:-${MN_HOST_SHARED_ARTIFACT_ROOT:-${MN_HOST_HOME_DIR}/shared}}"
  MN_SYNCTHING_ENABLED="${MN_SYNCTHING_ENABLED:-auto}"
  MN_SYNCTHING_IMAGE="${MN_SYNCTHING_IMAGE:-$MN_DEFAULT_SYNCTHING_IMAGE}"
  MN_SYNCTHING_RESCAN_INTERVAL_SECONDS="${MN_SYNCTHING_RESCAN_INTERVAL_SECONDS:-3600}"
  MN_BLUEPRINT_PYTHON_ENVS_DIR="${MN_BLUEPRINT_PYTHON_ENVS_DIR:-}"
  MN_HOST_OPENSHELL_STATE_DIR="${MN_HOST_OPENSHELL_STATE_DIR:-${INSTALL_DIR}/openshell-state}"
  MN_PYTHON_BIN=""
  MN_MANAGED_PYTHON="${MN_MANAGED_PYTHON:-1}"
  MN_MANAGED_PYTHON_VERSION="${MN_MANAGED_PYTHON_VERSION:-$MN_DEFAULT_MANAGED_PYTHON_VERSION}"
  MN_MANAGED_PYTHON_ROOT="${MN_MANAGED_PYTHON_DIR:-${MN_HOME:-${HOME}/.mn}/python}"
  MN_UV_ROOT="${MN_UV_DIR:-${MN_HOME:-${HOME}/.mn}/uv}"
  MN_UV_BIN=""

  INSTALL_WEB_UI="Y"
  INSTALL_REDIS="Y"
  INSTALL_CONTEXT_ENGINE="Y"
  MN_OPENSHELL_MODE="${MN_OPENSHELL_MODE:-lazy}"
  INSTALL_SKILLS="Y"
  START_NOW="Y"

  function run_quiet() {
    local label="$1"
    shift
    local log_dir="${TMPDIR:-/tmp}/mirror_neuron_install"
    mkdir -p "$log_dir"
    local log_file="${log_dir}/${label//[^A-Za-z0-9_.-]/_}.$$.log"

    if ! "$@" >"$log_file" 2>&1; then
      print_error "$label failed. Details: $log_file"
      if [ "$MN_INSTALL_VERBOSE" = "Y" ]; then
        tail -n 20 "$log_file" >&3 2>/dev/null || true
      else
        printf '  Re-run with --verbose to show the last log lines.\n' >&3
      fi
      exit 1
    fi
  }

  function python_version() {
    "$1" -c 'import sys; print(".".join(str(part) for part in sys.version_info[:3]))' 2>/dev/null
  }

  function python_is_supported() {
    "$1" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' >/dev/null 2>&1
  }

  function python_minor_version() {
    "$1" -c 'import sys; print(".".join(str(part) for part in sys.version_info[:2]))' 2>/dev/null
  }

  function python_is_selected_minor() {
    [ "$(python_minor_version "$1" || true)" = "$MN_MANAGED_PYTHON_VERSION" ]
  }

  function curl_github() {
    local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    if [ -n "$token" ]; then
      curl -H "Authorization: Bearer $token" "$@"
    else
      curl "$@"
    fi
  }

  function managed_python_enabled() {
    case "$MN_MANAGED_PYTHON" in
    0 | false | FALSE | False | no | NO | No | n | N) return 1 ;;
    *) return 0 ;;
    esac
  }

  function validate_managed_python_version() {
    if [[ ! "$MN_MANAGED_PYTHON_VERSION" =~ ^[0-9]+[.][0-9]+$ ]]; then
      print_error "MN_MANAGED_PYTHON_VERSION must be a Python minor version like 3.12."
      exit 1
    fi
  }

  function install_uv() {
    local os uv_bin_dir installer
    os="$(uname -s)"

    case "$os" in
    Darwin | Linux) ;;
    *)
      print_error "Unsupported platform for uv-managed Python: ${os}."
      print_error "Set MN_PYTHON=/path/to/python${MN_MANAGED_PYTHON_VERSION} and rerun."
      exit 1
      ;;
    esac

    if ! command -v curl >/dev/null 2>&1; then
      print_error "'curl' is required to install uv."
      exit 1
    fi

    uv_bin_dir="${MN_UV_ROOT}/bin"
    installer="$(mktemp "${TMPDIR:-/tmp}/mn-uv-install.XXXXXX")"
    mkdir -p "$uv_bin_dir"

    print_step "Installing uv for private Python management"
    if ! curl_github -fsSL "https://astral.sh/uv/install.sh" -o "$installer"; then
      rm -f "$installer"
      print_error "Could not download the uv installer."
      print_error "Install uv manually or set MN_PYTHON=/path/to/python${MN_MANAGED_PYTHON_VERSION}."
      exit 1
    fi

    if ! mn_run_uv_installer "$installer" "$uv_bin_dir" >/dev/null 2>&1; then
      rm -f "$installer"
      print_error "Could not install uv."
      print_error "Install uv manually or set MN_PYTHON=/path/to/python${MN_MANAGED_PYTHON_VERSION}."
      exit 1
    fi
    rm -f "$installer"

    MN_UV_BIN="$uv_bin_dir/uv"
    if [ ! -x "$MN_UV_BIN" ]; then
      print_error "uv installer did not create $MN_UV_BIN."
      exit 1
    fi

    print_detail "Installed uv at $MN_UV_BIN."
  }

  function resolve_uv() {
    if [ -n "$MN_UV_BIN" ]; then
      return
    fi

    MN_UV_BIN="$(command -v uv 2>/dev/null || true)"
    if [ -n "$MN_UV_BIN" ]; then
      return
    fi

    MN_UV_BIN="${MN_UV_ROOT}/bin/uv"
    if [ -x "$MN_UV_BIN" ]; then
      return
    fi

    install_uv
  }

  function managed_python_is_expected() {
    local python_bin="$1"
    [ -x "$python_bin" ] &&
      python_is_supported "$python_bin" &&
      [ "$(python_minor_version "$python_bin" || true)" = "$MN_MANAGED_PYTHON_VERSION" ]
  }

  function find_uv_managed_python() {
    UV_PYTHON_INSTALL_DIR="$MN_MANAGED_PYTHON_ROOT" \
      UV_CACHE_DIR="${MN_UV_ROOT}/cache" \
      "$MN_UV_BIN" python find --managed-python --no-python-downloads "$MN_MANAGED_PYTHON_VERSION" 2>/dev/null || true
  }

  function install_managed_python() {
    validate_managed_python_version

    local managed_bin

    print_step "Resolving private Python ${MN_MANAGED_PYTHON_VERSION} runtime with uv"
    print_step "Installing private Python ${MN_MANAGED_PYTHON_VERSION} under ${MN_MANAGED_PYTHON_ROOT}."
    resolve_uv

    managed_bin="$(find_uv_managed_python)"
    if ! managed_python_is_expected "$managed_bin"; then
      run_quiet "uv-python-install" env \
        "UV_PYTHON_INSTALL_DIR=$MN_MANAGED_PYTHON_ROOT" \
        "UV_CACHE_DIR=${MN_UV_ROOT}/cache" \
        "UV_NO_PROGRESS=1" \
        "$MN_UV_BIN" python install "$MN_MANAGED_PYTHON_VERSION"
      managed_bin="$(find_uv_managed_python)"
    fi
    if [ -z "$managed_bin" ]; then
      managed_bin="$(find "$MN_MANAGED_PYTHON_ROOT" -path '*/bin/python3' -print | head -n 1 || true)"
    fi

    if ! managed_python_is_expected "$managed_bin"; then
      print_error "Managed Python install did not produce Python ${MN_MANAGED_PYTHON_VERSION} at ${managed_bin}."
      exit 1
    fi

    MN_PYTHON_BIN="$(mn_base_python_executable "$managed_bin")" || {
      print_error "Could not resolve a stable base Python interpreter from $managed_bin."
      exit 1
    }
    print_detail "Using uv-managed Python $(python_version "$managed_bin") at $managed_bin."
  }

  function print_python_requirement_error() {
    local selected="${1:-}"
    local version=""

    print_error "MirrorNeuron Python components require Python ${MN_MANAGED_PYTHON_VERSION}.x by default."
    if [ -n "$selected" ]; then
      version="$(python_version "$selected" || true)"
      if [ -n "$version" ]; then
        print_error "Selected Python '$selected' is version $version."
      else
        print_error "Selected Python '$selected' could not be run."
      fi
    fi
    print_error "Install Python ${MN_MANAGED_PYTHON_VERSION}.x yourself, or allow the uv-managed private runtime fallback."
    print_error "You can also rerun with: MN_PYTHON=/opt/homebrew/bin/python${MN_MANAGED_PYTHON_VERSION} ./$(basename "$0")"
  }

  function resolve_python_runtime() {
    local candidate resolved
    local candidates=()

    if [ -n "$MN_PYTHON_BIN" ]; then
      return
    fi

    if [ -n "${MN_PYTHON:-}" ]; then
      candidates+=("$MN_PYTHON")
    else
      candidates+=("python${MN_MANAGED_PYTHON_VERSION}" python3 python)
    fi

    for candidate in "${candidates[@]}"; do
      resolved="$(command -v "$candidate" 2>/dev/null || true)"
      if [ -z "$resolved" ]; then
        if [ -n "${MN_PYTHON:-}" ]; then
          print_python_requirement_error "$candidate"
          exit 1
        fi
        continue
      fi
      if python_is_supported "$resolved" && python_is_selected_minor "$resolved"; then
        MN_PYTHON_BIN="$(mn_base_python_executable "$resolved")" || {
          print_error "Could not resolve a stable base Python interpreter from $resolved."
          exit 1
        }
        print_detail "Using Python $(python_version "$MN_PYTHON_BIN") at $MN_PYTHON_BIN."
        return
      fi
      if [ -n "${MN_PYTHON:-}" ]; then
        print_python_requirement_error "$resolved"
        exit 1
      fi
    done

    resolved="$(command -v "python${MN_MANAGED_PYTHON_VERSION}" 2>/dev/null || true)"
    if managed_python_enabled; then
      install_managed_python
      return
    fi

    print_warning "Managed Python fallback is disabled."
    print_python_requirement_error "$resolved"
    exit 1
  }

  function usage() {
    cat >&3 <<EOF
Usage: ./install.sh --mode local [options]

Installs MirrorNeuron from local sibling folders under:
  ${WORKSPACE_DIR}
Clones mn-client-support from GitHub if its sibling checkout is missing.

Options:
  --yes                 Use component defaults and require non-interactive sudo.
  --interactive         Ask each install question before proceeding.
  --reset               Permanently clear runtime data first; requires typing YES.
  -v, --verbose         Show installation details and command paths.
  --web-ui              Enable the native Web UI.
  --no-web-ui           Skip the native Web UI.
  --redis               Enable Redis Podman setup.
  --no-redis            Skip Redis Podman setup.
  --context-engine      Install/start Membrane context engine.
  --no-context-engine   Skip Membrane context engine setup.
  --build-membrane      Build local Membrane source instead of pulling GAR.
                        Override source location with MN_MEMBRANE_DIR.
  --openshell           Allow on-demand OpenShell workers (default).
  --no-openshell        Disable OpenShell workers on this node.
  --syncthing / --no-syncthing
                        Enable or skip Syncthing shared-storage replication.
  --no-skills           Skip optional packages under mn-skills. Skills required
                        by local runtime packages are still installed locally.
  --start               Start MirrorNeuron after install.
  --no-start            Skip starting MirrorNeuron after install.
  --python PATH         Same as MN_PYTHON. Must match Python ${MN_MANAGED_PYTHON_VERSION}.x.
  --no-managed-python   Do not use uv to install a private Python runtime.
  MN_PYTHON=/path       Use a specific Python ${MN_MANAGED_PYTHON_VERSION}.x interpreter.
  MN_HOME=/path         Override the runtime state directory. Defaults to ${HOME}/.mn.
  MN_AGENTS_ROOT=/path  Override the local agent template catalog. Defaults to ${WORKSPACE_DIR}/mn-agents.
  MN_MANAGED_PYTHON=0   Disable uv-managed private Python fallback.
  -h, --help            Show this help.
EOF
  }

  while [ "$#" -gt 0 ]; do
    case "$1" in
    --web-ui) INSTALL_WEB_UI="Y" ;;
    --no-web-ui) INSTALL_WEB_UI="N" ;;
    --redis) INSTALL_REDIS="Y" ;;
    --no-redis) INSTALL_REDIS="N" ;;
    --context-engine) INSTALL_CONTEXT_ENGINE="Y" ;;
    --no-context-engine) INSTALL_CONTEXT_ENGINE="N" ;;
    --openshell) MN_OPENSHELL_MODE=lazy ;;
    --no-openshell) MN_OPENSHELL_MODE=disabled ;;
    --no-skills) INSTALL_SKILLS="N" ;;
    --syncthing) MN_SYNCTHING_ENABLED="auto" ;;
    --no-syncthing) MN_SYNCTHING_ENABLED="0" ;;
    --start) START_NOW="Y" ;;
    --no-start) START_NOW="N" ;;
    --python)
      shift
      if [ "$#" -eq 0 ]; then
        print_error "--python requires a path."
        usage
        exit 1
      fi
      MN_PYTHON="$1"
      ;;
    --python=*) MN_PYTHON="${1#*=}" ;;
    --no-managed-python) MN_MANAGED_PYTHON=0 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      print_error "Unknown option: $1"
      printf 'Use ./install.sh --help for common options or --help-all for the full reference.\n' >&3
      exit 1
      ;;
    esac
    shift
  done

  function require_dir() {
    local path="$1"
    local name="$2"
    if [ ! -d "$path" ]; then
      print_error "Missing ${name}: ${path}"
      print_error "Run this installer from a complete mirror-neuron-set workspace."
      exit 1
    fi
  }

  function require_file() {
    local path="$1"
    local name="$2"
    if [ ! -f "$path" ]; then
      print_error "Missing ${name}: ${path}"
      exit 1
    fi
  }

  function validate_agents_root() {
    local root="$1"
    if [ ! -f "${root}/index.json" ]; then
      print_error "mn-agents index was not found at ${root}/index.json."
      print_error "Set MN_AGENTS_ROOT to a valid mn-agents checkout or run from a complete mirror-neuron-set workspace."
      exit 1
    fi
  }

  function ensure_agent_catalog_root() {
    local root="${MN_AGENTS_ROOT:-$AGENTS_DIR}"
    validate_agents_root "$root"
    (cd "$root" && pwd)
  }

  function mix_project_file_valid() {
    local path="$1"
    [ -s "$path" ] && grep -q "use Mix.Project" "$path"
  }

  function restore_mix_project_file_from_git() {
    local path="$1"
    local path_dir abs_path repo_dir relpath tmp_file commit

    if ! command -v git >/dev/null 2>&1; then
      return 1
    fi

    path_dir="$(dirname "$path")"
    if [ ! -d "$path_dir" ]; then
      return 1
    fi

    abs_path="$(cd "$path_dir" && pwd -P)/$(basename "$path")"
    repo_dir="$(cd "$path_dir" && git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -z "$repo_dir" ]; then
      return 1
    fi

    relpath="${abs_path#"${repo_dir}"/}"
    if [ "$relpath" = "$abs_path" ]; then
      return 1
    fi

    tmp_file="$(mktemp "${TMPDIR:-/tmp}/mn-mix-exs.XXXXXX")"
    while IFS= read -r commit; do
      if git -C "$repo_dir" show "${commit}:${relpath}" >"$tmp_file" 2>/dev/null && mix_project_file_valid "$tmp_file"; then
        cp "$tmp_file" "$path"
        rm -f "$tmp_file"
        print_warning "Repaired MirrorNeuron mix.exs from git history (${commit:0:12})."
        return 0
      fi
    done < <(git -C "$repo_dir" log --format='%H' -- "$relpath" 2>/dev/null)

    rm -f "$tmp_file"
    return 1
  }

  function require_mix_project_file() {
    local path="$1"
    if mix_project_file_valid "$path"; then
      return
    fi

    if [ ! -e "$path" ] || [ ! -s "$path" ]; then
      if restore_mix_project_file_from_git "$path" && mix_project_file_valid "$path"; then
        return
      fi
    fi

    if [ ! -f "$path" ]; then
      print_error "Missing MirrorNeuron mix.exs: ${path}"
      exit 1
    fi

    print_error "Invalid MirrorNeuron mix.exs: ${path}"
    print_error "Expected a non-empty Mix project file containing 'use Mix.Project'."
    exit 1
  }

  function canonical_path() {
    local path="$1"
    local dir base
    if [ -e "$path" ] || [ -L "$path" ]; then
      dir="$(cd "$(dirname "$path")" && pwd -P)"
      base="$(basename "$path")"
      printf '%s/%s\n' "$dir" "$base"
      return 0
    fi

    dir="$(dirname "$path")"
    base="$(basename "$path")"
    if [ -d "$dir" ]; then
      dir="$(cd "$dir" && pwd -P)"
    else
      dir="$(cd "$(dirname "$dir")" 2>/dev/null && pwd -P)/$(basename "$dir")"
    fi
    printf '%s/%s\n' "$dir" "$base"
  }

  function require_install_dir_not_source() {
    local install_path workspace_path source_path
    install_path="$(canonical_path "$INSTALL_DIR")"
    workspace_path="$(canonical_path "$WORKSPACE_DIR")"

    if [ "$install_path" = "$workspace_path" ]; then
      print_error "Refusing to install MirrorNeuron state into the source workspace: ${INSTALL_DIR}"
      print_error "Unset MN_HOME or set it to a state directory such as ${HOME}/.mn."
      exit 1
    fi

    for source_path in "$CORE_DIR" "$CLI_DIR" "$API_DIR" "$PY_SDK_DIR" "$CLIENT_SUPPORT_DIR" \
      "$WEB_UI_DIR" "$SKILLS_DIR" "$BLUEPRINTS_DIR" "$DOCS_DIR" "$SYSTEM_TESTS_DIR" "$MEMBRANE_DIR"; do
      if [ "$install_path" = "$(canonical_path "$source_path")" ]; then
        print_error "Refusing to install MirrorNeuron state into source directory: ${INSTALL_DIR}"
        print_error "Unset MN_HOME or set it to a state directory such as ${HOME}/.mn."
        exit 1
      fi
    done
  }

  function require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
      print_error "'$cmd' is required but not installed."
      exit 1
    fi
  }

  function replace_symlink() {
    local source="$1"
    local target="$2"
    if [ -e "$target" ] || [ -L "$target" ]; then
      rm -rf "$target"
    fi
    ln -s "$source" "$target"
  }

  function write_local_install_metadata() {
    local metadata_file="${INSTALL_DIR}/install_metadata.json"
    local updated_at
    updated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    cat >"$metadata_file" <<EOF
{
  "install_type": "local_source",
  "source_workspace": "${WORKSPACE_DIR}",
  "updated_at": "${updated_at}"
}
EOF
  }

  function generate_mn_cookie() {
    local secret
    local python_fallback="${MN_PYTHON_BIN:-}"

    if command -v openssl >/dev/null 2>&1; then
      if secret="$(openssl rand -hex 32 2>/dev/null)" && [ -n "$secret" ]; then
        printf '%s\n' "$secret"
        return 0
      fi
    fi

    if command -v od >/dev/null 2>&1 && [ -r /dev/urandom ]; then
      if secret="$(od -An -N32 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" && [ -n "$secret" ]; then
        printf '%s\n' "$secret"
        return 0
      fi
    fi

    if [ -z "$python_fallback" ]; then
      python_fallback="$(command -v "python${MN_MANAGED_PYTHON_VERSION}" 2>/dev/null || true)"
    fi
    if [ -n "$python_fallback" ]; then
      if secret="$("$python_fallback" -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null)" && [ -n "$secret" ]; then
        printf '%s\n' "$secret"
        return 0
      fi
    fi

    return 1
  }

  function resolve_secret_file() {
    local value="${1:-}" file="$2" label="$3"
    case "$label:$value" in
    MN_GRPC_AUTH_TOKEN:mirror_neuron_password | MN_GRPC_ADMIN_TOKEN:mirror_neuron_password_admin) value="" ;;
    esac
    mkdir -p "$INSTALL_DIR"
    if [ -z "$value" ] && [ -s "$file" ]; then
      value="$(tr -d '[:space:]' <"$file")"
      case "$label:$value" in
      MN_GRPC_AUTH_TOKEN:mirror_neuron_password | MN_GRPC_ADMIN_TOKEN:mirror_neuron_password_admin) value="" ;;
      esac
    fi
    if [ -z "$value" ]; then
      value="$(generate_mn_cookie)" || return 1
    fi
    if [ -z "$value" ]; then
      print_error "Failed to generate ${label}."
      return 1
    fi
    (
      umask 077
      printf '%s\n' "$value" >"$file"
    )
    chmod 600 "$file"
    printf '%s\n' "$value"
  }

  function resolve_mn_cookie() {
    local env_cookie="${MN_COOKIE:-}"
    local cookie_file="${INSTALL_DIR}/erlang.cookie"
    local cookie

    if [ -n "$env_cookie" ] && [ "$env_cookie" != "mirrorneuron" ]; then
      printf '%s\n' "$env_cookie"
      return 0
    fi

    mkdir -p "$INSTALL_DIR"
    if [ -s "$cookie_file" ]; then
      cookie="$(tr -d '[:space:]' <"$cookie_file")"
      if [ -n "$cookie" ] && [ "$cookie" != "mirrorneuron" ]; then
        chmod 600 "$cookie_file" 2>/dev/null || true
        printf '%s\n' "$cookie"
        return 0
      fi
    fi

    if ! cookie="$(generate_mn_cookie)"; then
      cookie=""
    fi
    if [ -z "$cookie" ]; then
      print_error "Failed to generate MN_COOKIE."
      exit 1
    fi

    printf '%s\n' "$cookie" >"$cookie_file"
    chmod 600 "$cookie_file" 2>/dev/null || true
    printf '%s\n' "$cookie"
  }

  function resolve_network_token() {
    local env_token="${MN_NETWORK_JOIN_TOKEN:-}"
    local token_file="${INSTALL_DIR}/network.token"
    local token

    if [ -n "$env_token" ]; then
      printf '%s\n' "$env_token" >"$token_file"
      chmod 600 "$token_file" 2>/dev/null || true
      printf '%s\n' "$env_token"
      return 0
    fi

    mkdir -p "$INSTALL_DIR"
    if [ -s "$token_file" ]; then
      token="$(tr -d '[:space:]' <"$token_file")"
      if [ -n "$token" ]; then
        chmod 600 "$token_file" 2>/dev/null || true
        printf '%s\n' "$token"
        return 0
      fi
    fi

    if ! token="$(generate_mn_cookie)"; then
      token=""
    fi
    if [ -z "$token" ]; then
      print_error "Failed to generate MN_NETWORK_JOIN_TOKEN."
      exit 1
    fi
    printf '%s\n' "$token" >"$token_file"
    chmod 600 "$token_file" 2>/dev/null || true
    printf '%s\n' "$token"
  }

  function derive_network_secret() {
    local token="$1"
    local label="$2"
    local material="mirror-neuron:${label}:${token}"
    local digest
    local python_fallback="${MN_PYTHON_BIN:-}"

    if command -v shasum >/dev/null 2>&1; then
      if digest="$(printf '%s' "$material" | shasum -a 256 2>/dev/null | awk '{print $1}')" && [ -n "$digest" ]; then
        printf '%s\n' "$digest"
        return 0
      fi
    fi

    if command -v sha256sum >/dev/null 2>&1; then
      if digest="$(printf '%s' "$material" | sha256sum 2>/dev/null | awk '{print $1}')" && [ -n "$digest" ]; then
        printf '%s\n' "$digest"
        return 0
      fi
    fi

    if command -v openssl >/dev/null 2>&1; then
      if digest="$(printf '%s' "$material" | openssl dgst -sha256 -r 2>/dev/null | awk '{print $1}')" && [ -n "$digest" ]; then
        printf '%s\n' "$digest"
        return 0
      fi
    fi

    if [ -z "$python_fallback" ]; then
      python_fallback="$(command -v "python${MN_MANAGED_PYTHON_VERSION}" 2>/dev/null || true)"
    fi
    if [ -n "$python_fallback" ]; then
      if digest="$(printf '%s' "$material" | "$python_fallback" -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null)" && [ -n "$digest" ]; then
        printf '%s\n' "$digest"
        return 0
      fi
    fi

    print_error "Need shasum, sha256sum, a working openssl, or python${MN_MANAGED_PYTHON_VERSION} to derive Redis credentials."
    exit 1
  }

  function resolve_redis_password() {
    local admin_token="$1"
    local mn_env="${MN_ENV:-dev}"
    local password

    case "$mn_env" in
    prod | production)
      password="$(derive_network_secret "$admin_token" "redis")"
      mkdir -p "$INSTALL_DIR"
      printf '%s\n' "$password" >"${INSTALL_DIR}/redis.password"
      chmod 600 "${INSTALL_DIR}/redis.password" 2>/dev/null || true
      printf '%s\n' "$password"
      ;;
    *)
      printf '%s\n' "mirror_neuron_redis_dev"
      ;;
    esac
  }

  function compose_profiles() {
    local profiles=()
    [ "$INSTALL_CONTEXT_ENGINE" = "Y" ] && profiles+=("context")
    case "$(printf '%s' "$MN_SYNCTHING_ENABLED" | tr '[:upper:]' '[:lower:]')" in
    '' | 0 | false | no | n | off | disabled) ;;
    *) profiles+=("syncthing") ;;
    esac
    if [ "${#profiles[@]}" -eq 0 ]; then
      printf ''
      return 0
    fi
    local IFS=,
    printf '%s' "${profiles[*]}"
  }

  function ensure_runtime_host_directory() {
    local path="$1"
    local description="$2"
    local override_name="$3"

    if [ -e "$path" ] || [ -L "$path" ]; then
      if [ ! -d "$path" ]; then
        print_error "Expected ${description} to be a directory: ${path}"
        print_error "Move or remove that path, or set ${override_name} to a directory."
        exit 1
      fi
      chmod u+rwx "$path" 2>/dev/null || true
      if [ ! -w "$path" ]; then
        print_error "Expected ${description} to be writable: ${path}"
        print_error "Repair ownership or set ${override_name} to a writable directory."
        exit 1
      fi
      return 0
    fi

    mkdir -p "$path"
    chmod u+rwx "$path" 2>/dev/null || true
  }

  function prepare_litellm_gateway_config() {
    local gateway_dir="${MN_HOST_HOME_DIR}/models/litellm-gateway"
    mkdir -p "$gateway_dir"
    if [ ! -e "${gateway_dir}/config.yaml" ]; then
      printf '{"model_list":[]}\n' >"${gateway_dir}/config.yaml"
    fi
    chmod u+rwX "$gateway_dir" "${gateway_dir}/config.yaml" 2>/dev/null || true
  }

  function write_runtime_compose_files() {
    local context_auth_token profiles network_name network_external network_token redis_password mn_cookie runtime_skills_root runtime_agents_root runtime_package_index context_memory_enabled otterdesk_context_memory_enabled membrane_engine_tag membrane_engine_image litellm_gateway_bind_host api_host
    local grpc_auth_token grpc_admin_token runtime_port_settings
    grpc_auth_token="$(resolve_secret_file "${MN_GRPC_AUTH_TOKEN:-}" "${INSTALL_DIR}/grpc_auth.token" "MN_GRPC_AUTH_TOKEN")"
    grpc_admin_token="$(resolve_secret_file "${MN_GRPC_ADMIN_TOKEN:-}" "${INSTALL_DIR}/grpc_admin.token" "MN_GRPC_ADMIN_TOKEN")"
    context_auth_token="$(resolve_secret_file "${MN_CONTEXT_AUTH_TOKEN:-}" "${INSTALL_DIR}/context_auth.token" "MN_CONTEXT_AUTH_TOKEN")"
    profiles="$(compose_profiles)"
    api_host="${MN_API_HOST:-localhost}"
    litellm_gateway_bind_host="${MN_LITELLM_GATEWAY_BIND_HOST:-0.0.0.0}"
    network_name="${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
    network_external="$(mn_runtime_network_external "$network_name")"
    network_token="$(resolve_network_token)"
    redis_password="$(resolve_redis_password "mirror_neuron_password_admin")"
    mn_cookie="$(resolve_mn_cookie)"
    runtime_skills_root="${MN_SKILLS_ROOT:-${MN_HOST_HOME_DIR}/skills}"
    runtime_agents_root="$(ensure_agent_catalog_root)"
    runtime_package_index="${MN_PACKAGE_INDEX_FILE:-}"
    membrane_engine_tag="${MN_MEMBRANE_ENGINE_IMAGE_TAG:-$(mn_default_membrane_engine_tag)}"
    if [[ "$membrane_engine_tag" != v* ]]; then
      membrane_engine_tag="v${membrane_engine_tag}"
    fi
    membrane_engine_image="${MN_MEMBRANE_ENGINE_IMAGE:-${MN_CONTEXT_ENGINE_IMAGE:-${MN_DEFAULT_MEMBRANE_GAR_IMAGE}:${membrane_engine_tag}}}"
    membrane_engine_image="$(mn_selected_membrane_image "$membrane_engine_image")"
    if [ "$MN_BUILD_MEMBRANE" = "Y" ]; then membrane_engine_tag=""; fi
    context_memory_enabled="${MN_CONTEXT_MEMORY_ENABLED:-1}"
    otterdesk_context_memory_enabled="${OTTERDESK_CONTEXT_MEMORY_ENABLED:-$context_memory_enabled}"
    if [ -n "${PACKAGE_INDEX_FILE:-}" ] && [ -f "$PACKAGE_INDEX_FILE" ]; then
      runtime_package_index="${INSTALL_DIR}/package-index/python-packages.toml"
      mkdir -p "$(dirname "$runtime_package_index")"
      cp "$PACKAGE_INDEX_FILE" "$runtime_package_index"
    fi

    mkdir -p "$INSTALL_DIR"
    ensure_runtime_host_directory "$MN_HOST_HOME_DIR" "MirrorNeuron home mount" "MN_HOST_HOME_DIR"
    ensure_runtime_host_directory "$runtime_skills_root" "MirrorNeuron runtime modules root" "MN_SKILLS_ROOT"
    ensure_runtime_host_directory "$MN_HOST_ARTIFACTS_DIR" "run artifacts host mount" "MN_HOST_ARTIFACTS_DIR"
    ensure_runtime_host_directory "$MN_HOST_BLOB_STORE_DIR" "blob store host mount" "MN_HOST_BLOB_STORE_DIR"
    ensure_runtime_host_directory "$MN_HOST_SHARED_STORAGE_ROOT" "shared storage host mount" "MN_HOST_SHARED_STORAGE_ROOT"
    prepare_litellm_gateway_config
    mn_write_runtime_compose_file "$RUNTIME_COMPOSE_TEMPLATE" "$RUNTIME_COMPOSE_FILE"
    runtime_port_settings="$(mn_runtime_port_settings "$RUNTIME_COMPOSE_ENV")"
    cat >"$RUNTIME_COMPOSE_ENV" <<EOF
COMPOSE_PROJECT_NAME=mirror-neuron
COMPOSE_PROFILES=${profiles}
MN_HOST_STATE_DIR=${INSTALL_DIR}
MN_HOST_HOME_DIR=${MN_HOST_HOME_DIR}
MN_HOST_ARTIFACTS_DIR=${MN_HOST_ARTIFACTS_DIR}
MN_HOST_BLOB_STORE_DIR=${MN_HOST_BLOB_STORE_DIR}
MN_HOST_SHARED_STORAGE_ROOT=${MN_HOST_SHARED_STORAGE_ROOT}
MN_SYNCTHING_ENABLED=${MN_SYNCTHING_ENABLED}
MN_SYNCTHING_IMAGE=${MN_SYNCTHING_IMAGE}
MN_SYNCTHING_RESCAN_INTERVAL_SECONDS=${MN_SYNCTHING_RESCAN_INTERVAL_SECONDS}
MN_BLUEPRINT_PYTHON_ENVS_DIR=${MN_BLUEPRINT_PYTHON_ENVS_DIR}
MN_HOST_OPENSHELL_STATE_DIR=${MN_HOST_OPENSHELL_STATE_DIR}
MN_MEMBRANE_SOURCE_MODE=$(mn_selected_membrane_source_mode)
ENGINE_IMAGE=${membrane_engine_image}
MN_MEMBRANE_ENGINE_IMAGE=${membrane_engine_image}
MN_MEMBRANE_ENGINE_IMAGE_TAG=${membrane_engine_tag}
MN_REDIS_IMAGE=${MN_REDIS_IMAGE:-$MN_DEFAULT_REDIS_IMAGE}
MN_CONTEXT_AUTH_TOKEN=${context_auth_token}
MN_CONTEXT_MODEL_COMPRESSION_ENABLED=true
MN_CONTEXT_OBSERVABILITY=${MN_CONTEXT_OBSERVABILITY:-false}
MN_CONTEXT_TOKEN_COUNTER_FACTORY=${MN_CONTEXT_TOKEN_COUNTER_FACTORY:-}
MN_LLM_MODEL_RUNNER_MODEL=${MN_LLM_MODEL_RUNNER_MODEL:-$MN_DEFAULT_LLM_MODEL_RUNNER_MODEL}
MN_GRPC_BIND_HOST=${MN_GRPC_BIND_HOST:-127.0.0.1}
MN_GRPC_PORT=${MN_GRPC_PORT:-55051}
MN_GRPC_TARGET=${MN_GRPC_TARGET:-localhost:${MN_GRPC_PORT:-55051}}
MN_GRPC_ADVERTISE_PORT=${MN_GRPC_ADVERTISE_PORT:-${MN_GRPC_PORT:-55051}}
MN_NATIVE_SDK_GRPC_HOST=${MN_NATIVE_SDK_GRPC_HOST:-0.0.0.0}
MN_NATIVE_SDK_GRPC_PORT=${MN_NATIVE_SDK_GRPC_PORT:-55052}
MN_NATIVE_SDK_GRPC_ADVERTISE_HOST=${MN_NATIVE_SDK_GRPC_ADVERTISE_HOST:-${MN_NETWORK_ADVERTISE_HOST:-}}
MN_NATIVE_SDK_GRPC_ADVERTISE_PORT=${MN_NATIVE_SDK_GRPC_ADVERTISE_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_NATIVE_SDK_GRPC_TARGET=${MN_NATIVE_SDK_GRPC_TARGET:-mn-native-sdk-grpc:55052}
MN_RESOURCE_GC_ENABLED=${MN_RESOURCE_GC_ENABLED:-true}
MN_RESOURCE_GC_INTERVAL_SECONDS=${MN_RESOURCE_GC_INTERVAL_SECONDS:-1800}
MN_RESOURCE_GC_ORPHAN_GRACE_SECONDS=${MN_RESOURCE_GC_ORPHAN_GRACE_SECONDS:-3600}
MN_RESOURCE_GC_BATCH_SIZE=${MN_RESOURCE_GC_BATCH_SIZE:-100}
MN_DOCKER_WORKER_IMAGE_CACHE_TTL_SECONDS=${MN_DOCKER_WORKER_IMAGE_CACHE_TTL_SECONDS:-604800}
MN_DOCKER_WORKER_IMAGE_CACHE_MAX_BYTES=${MN_DOCKER_WORKER_IMAGE_CACHE_MAX_BYTES:-21474836480}
MN_NATIVE_SDK_GRPC_PROXY_PORT=${MN_NATIVE_SDK_GRPC_PROXY_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_NATIVE_SDK_GRPC_PROXY_TARGET_HOST=${MN_NATIVE_SDK_GRPC_PROXY_TARGET_HOST:-host.containers.internal}
MN_NATIVE_SDK_GRPC_PROXY_TARGET_PORT=${MN_NATIVE_SDK_GRPC_PROXY_TARGET_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_LITELLM_GATEWAY_BIND_HOST=${litellm_gateway_bind_host}
MN_LITELLM_GATEWAY_PORT=${MN_LITELLM_GATEWAY_PORT:-4000}
MN_LITELLM_GATEWAY_INTERNAL_API_BASE=${MN_LITELLM_GATEWAY_INTERNAL_API_BASE:-http://mn-litellm-proxy:4000/v1}
MN_API_HOST=${api_host}
MN_API_PORT=${MN_API_PORT:-54001}
MN_DIST_PORT=${MN_DIST_PORT:-54370}
MN_WEB_UI_HOST=${MN_WEB_UI_HOST:-localhost}
MN_WEB_UI_PORT=${MN_WEB_UI_PORT:-55173}
MN_WEB_UI_BIND_HOST=${MN_WEB_UI_BIND_HOST:-127.0.0.1}
MN_WEB_UI_NPM_REGISTRY=${MN_WEB_UI_NPM_REGISTRY:-https://${MN_GAR_LOCATION:-$MN_DEFAULT_PYTHON_GAR_LOCATION}-npm.pkg.dev/${MN_GAR_PROJECT:-$MN_DEFAULT_CORE_GAR_PROJECT}/${MN_GAR_NPM_REPOSITORY:-$MN_DEFAULT_WEB_UI_GAR_NPM_REPOSITORY}/}
MN_WEB_UI_SOURCE_MODE=${MN_WEB_UI_SOURCE_MODE}
MN_WEB_UI_SOURCE_MOUNT=${MN_WEB_UI_SOURCE_MOUNT}
MN_WEB_UI_PACKAGE_VERSION=${MN_WEB_UI_PACKAGE_VERSION}
MN_BLUEPRINT_WEB_UI_BIND_HOST=${MN_BLUEPRINT_WEB_UI_BIND_HOST:-0.0.0.0}
MN_BLUEPRINT_WEB_UI_PUBLIC_HOST=${MN_BLUEPRINT_WEB_UI_PUBLIC_HOST:-localhost}
${runtime_port_settings}
MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE=${MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE:-prepublished}
MN_ENV=${MN_ENV:-prod}
MN_USE_LOCAL_SKILLS=${MN_USE_LOCAL_SKILLS}
MN_BLUEPRINT_SOURCE=${MN_BLUEPRINT_SOURCE:-github}
MN_BLUEPRINT_REPO=${MN_BLUEPRINT_REPO:-https://github.com/MirrorNeuronLab/mn-blueprints.git}
MN_BLUEPRINT_LOCAL=${MN_BLUEPRINT_LOCAL:-}
MN_WORKSPACE_ROOT=${MN_WORKSPACE_ROOT:-}
MN_CONNECT_URL=${MN_CONNECT_URL:-}
MN_AGENTS_ROOT=${runtime_agents_root}
MN_SKILLS_ROOT=${runtime_skills_root}
MN_PACKAGE_INDEX_FILE=${runtime_package_index}
MN_PIP_INDEX_URL=${MN_PIP_INDEX_URL:-${MN_PYTHON_INDEX_URL:-${MN_DEFAULT_PIP_INDEX_URL}}}
MN_PIP_EXTRA_INDEX_URL=${MN_PIP_EXTRA_INDEX_URL:-${MN_PYTHON_EXTRA_INDEX_URL:-https://pypi.org/simple}}
MN_RUNTIME_MODULE_VERSION=${MN_RUNTIME_MODULE_VERSION:-${MN_PACKAGE_VERSION:-}}
MN_CONTEXT_MEMORY_ENABLED=${context_memory_enabled}
OTTERDESK_CONTEXT_MEMORY_ENABLED=${otterdesk_context_memory_enabled}
MN_RUNS_ROOT=${MN_RUNS_ROOT:-}
MN_DOCKER_NETWORK_MODE=${MN_DOCKER_NETWORK_MODE:-bridge}
MN_DOCKER_NETWORK_NAME=${network_name}
MN_DOCKER_NETWORK_EXTERNAL=${network_external}
MN_DOCKER_NETWORK_DRIVER=${MN_DOCKER_NETWORK_DRIVER:-bridge}
MN_DOCKER_NETWORK_ATTACHABLE=${MN_DOCKER_NETWORK_ATTACHABLE:-false}
MN_DOCKER_WORKER_ENABLED=${MN_DOCKER_WORKER_ENABLED:-1}
MN_NODE_ALIAS=${MN_NODE_ALIAS:-}
MN_NODE_NAME=${MN_NODE_NAME:-}
MN_NODE_ROLE=${MN_NODE_ROLE:-runtime}
MN_CLUSTER_NODES=${MN_CLUSTER_NODES:-}
MN_NETWORK_JOIN_TOKEN=${network_token}
MN_REDIS_PASSWORD=${redis_password}
MN_REDIS_URL=${MN_REDIS_URL:-redis://:${redis_password}@redis:6379/0}
MN_REDIS_HA_MODE=${MN_REDIS_HA_MODE:-single}
MN_REDIS_SENTINELS=${MN_REDIS_SENTINELS:-}
MN_REDIS_SENTINEL_MASTER=${MN_REDIS_SENTINEL_MASTER:-mirror-neuron}
MN_REDIS_SENTINEL_HOST_MAP=${MN_REDIS_SENTINEL_HOST_MAP:-}
MN_REDIS_DB=${MN_REDIS_DB:-0}
MN_REDIS_USERNAME=${MN_REDIS_USERNAME:-}
MN_REDIS_SENTINEL_USERNAME=${MN_REDIS_SENTINEL_USERNAME:-}
MN_REDIS_SENTINEL_PASSWORD=${MN_REDIS_SENTINEL_PASSWORD:-${redis_password}}
MN_REDIS_WAIT_REPLICAS=${MN_REDIS_WAIT_REPLICAS:-0}
MN_REDIS_WAIT_TIMEOUT_MS=${MN_REDIS_WAIT_TIMEOUT_MS:-100}
MN_REDIS_RECONNECT_ATTEMPTS=${MN_REDIS_RECONNECT_ATTEMPTS:-10}
MN_REDIS_RECONNECT_BACKOFF_MS=${MN_REDIS_RECONNECT_BACKOFF_MS:-250}
MN_REDIS_RECONNECT_MAX_BACKOFF_MS=${MN_REDIS_RECONNECT_MAX_BACKOFF_MS:-2000}
ERL_EPMD_ADDRESS=${ERL_EPMD_ADDRESS:-0.0.0.0}
ERL_AFLAGS=${ERL_AFLAGS:--kernel inet_dist_listen_min ${MN_DIST_PORT:-54370} inet_dist_listen_max ${MN_DIST_PORT:-54370}}
$(mn_openshell_plugin_env)
MN_SYNCTHING_UID=${MN_SYNCTHING_UID}
MN_SYNCTHING_GID=${MN_SYNCTHING_GID}
PODMAN_HOST_SOCKET=${PODMAN_HOST_SOCKET}
COMPOSE_PARALLEL_LIMIT=${COMPOSE_PARALLEL_LIMIT:-1}
MN_COOKIE=${mn_cookie}
MN_GRPC_AUTH_TOKEN=${grpc_auth_token}
MN_GRPC_ADMIN_TOKEN=${grpc_admin_token}
EOF
    chmod 600 "$RUNTIME_COMPOSE_ENV" 2>/dev/null || true
  }

  require_install_dir_not_source
  mn_prepare_installer_paths
  print_header

  if [ "$MN_INSTALL_RESET" != "Y" ] && [ "$MN_EXISTING_INSTALL" = "Y" ]; then
    print_step "Refreshing the existing local source installation."
  fi

  if [ "$NON_INTERACTIVE" != "Y" ]; then
    printf '\nChoose components. Press Enter to accept each default.\n' >&3
    INSTALL_WEB_UI=$(ask "Install the Web UI?" "$INSTALL_WEB_UI")
    INSTALL_REDIS=$(ask "Enable Redis?" "$INSTALL_REDIS")
    if [ "$MN_BUILD_MEMBRANE" != "Y" ]; then
      INSTALL_CONTEXT_ENGINE=$(ask "Enable the Membrane context engine?" "$INSTALL_CONTEXT_ENGINE")
    fi
    INSTALL_SKILLS=$(ask "Install optional local skills?" "$INSTALL_SKILLS")
    START_NOW=$(ask "Start the runtime after installation?" "$START_NOW")
  fi

  mn_print_install_summary
  mn_report_system
  mn_install_client_stage

  mn_begin_runtime_install || return 1
  require_dir "$CORE_DIR" "MirrorNeuron core"
  require_file "$CORE_DIR/Dockerfile" "MirrorNeuron Dockerfile"
  require_mix_project_file "$CORE_DIR/mix.exs"
  require_dir "$PY_SDK_DIR" "mn-python-sdk"
  for component_project in "$PY_SDK_DIR"/packages/*/pyproject.toml; do
    require_file "$component_project" "SDK component project"
  done

  if [ "$INSTALL_WEB_UI" = "Y" ]; then require_dir "$WEB_UI_DIR" "mn-web-ui"; fi
  if [ "$INSTALL_SKILLS" = "Y" ]; then require_dir "$SKILLS_DIR" "mn-skills"; fi
  if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
    require_dir "$MEMBRANE_DIR" "Membrane context engine"
    require_file "$MEMBRANE_DIR/Dockerfile" "Membrane Dockerfile"
  fi

  resolve_python_runtime

  print_step "Preparing local install state"
  mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$INSTALL_DIR/.pids" "$INSTALL_DIR/.logs"

  if [ -d "$BLUEPRINTS_DIR" ]; then replace_symlink "$BLUEPRINTS_DIR" "$INSTALL_DIR/blueprints"; fi
  if [ -d "$SKILLS_DIR" ]; then replace_symlink "$SKILLS_DIR" "$INSTALL_DIR/skills"; fi
  if [ -d "$DOCS_DIR" ]; then replace_symlink "$DOCS_DIR" "$INSTALL_DIR/docs"; fi
  if [ -d "$SYSTEM_TESTS_DIR" ]; then replace_symlink "$SYSTEM_TESTS_DIR" "$INSTALL_DIR/system-tests"; fi
  if [ -d "$MEMBRANE_DIR" ]; then replace_symlink "$MEMBRANE_DIR" "$INSTALL_DIR/Membrane"; fi
  replace_symlink "$CORE_DIR" "$INSTALL_DIR/core-source"
  replace_symlink "$CLI_DIR" "$INSTALL_DIR/cli-source"
  replace_symlink "$API_DIR" "$INSTALL_DIR/api-source"
  replace_symlink "$PY_SDK_DIR" "$INSTALL_DIR/python-sdk-source"
  write_local_install_metadata
  print_step "Writing Compose runtime configuration"
  write_runtime_compose_files
  print_detail "Local component links: ${INSTALL_DIR}"

  print_step "Building MirrorNeuron Core Podman image from local source"
  (
    cd "$CORE_DIR"
    mn_run_podman_build -t mirror-neuron-core:latest .
  )
  print_detail "Built local core image: mirror-neuron-core:latest"

  function install_local_editable_python_packages() {
    local -a editable_requirements=(-e "${PY_SDK_DIR}")
    local component_pyproject skill_pyproject agent_pyproject
    local agents_root="${MN_AGENTS_ROOT:-$AGENTS_DIR}"
    # Local mode must keep the complete SDK component family on source paths.
    # Otherwise pip can resolve a CLI/API dependency (for example MCP) from GAR
    # even though its sibling checkout is present, or fail when it is unpublished.
    for component_pyproject in "$PY_SDK_DIR"/packages/*/pyproject.toml; do
      [ -f "$component_pyproject" ] || continue
      editable_requirements+=(-e "$(dirname "$component_pyproject")")
    done
    if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
      editable_requirements+=(-e "$MEMBRANE_DIR/mn-context-engine-python-sdk")
    fi
    # Block compilation fingerprints its selected default implementations before
    # isolated worker preparation, including the supervised-service agent.
    for agent_pyproject in "$agents_root"/*/pyproject.toml; do
      [ -f "$agent_pyproject" ] || continue
      editable_requirements+=(-e "$(dirname "$agent_pyproject")")
    done
    if [ "$INSTALL_SKILLS" = "Y" ]; then
      for skill_pyproject in "$SKILLS_DIR"/*/pyproject.toml; do
        [ -f "$skill_pyproject" ] || continue
        editable_requirements+=(-e "$(dirname "$skill_pyproject")")
      done
    fi
    # One resolution transaction selects local components over registry versions.
    "$VENV_DIR/bin/pip" install "${editable_requirements[@]}"
  }

  VENV_BACKUP_DIR=""
  VENV_INSTALL_OK="N"
  function restore_local_venv_backup_on_failure() {
    if [ "$VENV_INSTALL_OK" = "Y" ]; then
      if [ -n "$VENV_BACKUP_DIR" ]; then
        rm -rf "$VENV_BACKUP_DIR"
      fi
      return
    fi

    rm -rf "$VENV_DIR"
    if [ -n "$VENV_BACKUP_DIR" ] && { [ -e "$VENV_BACKUP_DIR" ] || [ -L "$VENV_BACKUP_DIR" ]; }; then
      mv "$VENV_BACKUP_DIR" "$VENV_DIR"
      print_error "Local Python install failed; restored the previous virtual environment at $VENV_DIR."
    fi
  }

  if [ -e "$VENV_DIR" ] || [ -L "$VENV_DIR" ]; then
    VENV_BACKUP_DIR="${VENV_DIR}.backup.$$"
    rm -rf "$VENV_BACKUP_DIR"
    mv "$VENV_DIR" "$VENV_BACKUP_DIR"
  fi
  trap 'restore_local_venv_backup_on_failure; mn_reset_release_lock' EXIT

  print_step "Installing Python components from local source"
  (
    mn_run_logged "local Python virtual environment" "$MN_PYTHON_BIN" -m venv "$VENV_DIR"
    mn_run_logged "pip upgrade" "$VENV_DIR/bin/pip" install --upgrade pip
    mn_run_logged "local editable Python packages" install_local_editable_python_packages
  ) &
  spinner $! "Installing local editable Python packages"
  "$VENV_DIR/bin/python" -c 'import mn_sdk, mn_runtime' || {
    print_error "Local SDK and runtime source checkouts are not import-compatible."
    exit 1
  }
  VENV_INSTALL_OK="Y"
  if [ -n "$VENV_BACKUP_DIR" ]; then
    rm -rf "$VENV_BACKUP_DIR"
  fi
  trap mn_reset_release_lock EXIT

  mn_prepare_native_web_assets "$WEB_UI_DIR"
  mn_configure_installed_runtime

  print_detail "Core image: mirror-neuron-core:latest (${CORE_DIR})"
  print_detail "CLI/API: native builds from the local workspace"
  print_detail "State: ${INSTALL_DIR}"
  print_detail "Cookie: ${INSTALL_DIR}/erlang.cookie"
  if [ "$INSTALL_WEB_UI" = "Y" ]; then
    print_detail "Web UI source: ${WEB_UI_DIR}"
  fi
  if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
    print_detail "Membrane: ${MEMBRANE_DIR} (${MN_CONTEXT_ADDR:-localhost:50052})"
  fi
  print_detail "Rebuild after Elixir changes: ${SCRIPT_DIR}/install.sh --mode local --no-web-ui --no-skills"

  mn_finish_runtime_install
  mn_print_install_complete
}

run_install_binary() {
  # Never let pip block the installer by asking for input.
  export PIP_NO_INPUT="${PIP_NO_INPUT:-1}"

  SCRIPT_DIR="$(mn_script_dir)"
  INSTALL_DIR="${MN_HOME:-${HOME}/.mn}"
  BIN_DIR="${INSTALL_DIR}/bin"
  VENV_DIR="${INSTALL_DIR}/venv"
  MN_WEB_UI_SOURCE_MODE="${MN_WEB_UI_SOURCE_MODE:-package}"
  MN_WEB_UI_SOURCE_MOUNT="${MN_WEB_UI_SOURCE_MOUNT:-${INSTALL_DIR}/web-ui-source}"
  MN_WEB_UI_PACKAGE_VERSION="${MN_WEB_UI_PACKAGE_VERSION:-}"
  RUNTIME_COMPOSE_TEMPLATE="${MN_RUNTIME_COMPOSE_TEMPLATE:-}"
  RUNTIME_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
  RUNTIME_COMPOSE_ENV="${INSTALL_DIR}/docker-compose.env"
  INSTALL_VERSION="${MN_INSTALL_VERSION:-}"
  CORE_RELEASE_TAG=""
  CORE_INSTALL_VERSION="${MN_CORE_VERSION:-}"
  PYTHON_SDK_INSTALL_VERSION="${MN_PYTHON_SDK_VERSION:-}"
  CLI_INSTALL_VERSION="${MN_CLI_VERSION:-}"
  API_INSTALL_VERSION="${MN_API_VERSION:-}"
  WEB_UI_INSTALL_VERSION="${MN_WEB_UI_VERSION:-}"
  DEFAULT_PYTHON_SDK_INSTALL_VERSION="$MN_DEFAULT_PYTHON_SDK_VERSION"
  DEFAULT_CLI_INSTALL_VERSION="$MN_DEFAULT_CLI_VERSION"
  DEFAULT_API_INSTALL_VERSION="$MN_DEFAULT_API_VERSION"
  DEFAULT_WEB_UI_INSTALL_VERSION="$MN_DEFAULT_WEB_UI_VERSION"
  CORE_IMAGE="${MN_CORE_IMAGE:-}"
  CORE_GAR_PROJECT="${MN_CORE_GAR_PROJECT:-$MN_DEFAULT_CORE_GAR_PROJECT}"
  CORE_GAR_LOCATION="${MN_CORE_GAR_LOCATION:-$MN_DEFAULT_CORE_GAR_LOCATION}"
  CORE_GAR_REPOSITORY="${MN_CORE_GAR_DOCKER_REPOSITORY:-$MN_DEFAULT_CORE_GAR_DOCKER_REPOSITORY}"
  CORE_GAR_IMAGE_NAME="${MN_CORE_GAR_DOCKER_IMAGE_NAME:-$MN_DEFAULT_CORE_GAR_DOCKER_IMAGE_NAME}"
  MN_PACKAGE_VERSION=""
  MN_PYTHON_SDK_PACKAGE_VERSION=""
  MEMBRANE_DIR="${MN_MEMBRANE_DIR:-${INSTALL_DIR}/Membrane}"
  MN_AGENTS_ROOT="${MN_AGENTS_ROOT:-}"
  PACKAGE_INDEX_FILE="${MN_PACKAGE_INDEX_FILE:-}"
  PACKAGE_INDEX_VERSION="${MN_PACKAGE_INDEX_VERSION:-}"
  MN_GAR_PROJECT="${MN_GAR_PROJECT:-}"
  MN_GAR_LOCATION="${MN_GAR_LOCATION:-$MN_DEFAULT_PYTHON_GAR_LOCATION}"
  MN_GAR_REPOSITORY="${MN_GAR_REPOSITORY:-$MN_DEFAULT_PYTHON_GAR_REPOSITORY}"
  MN_PIP_INDEX_URL="${MN_PIP_INDEX_URL:-${MN_PYTHON_INDEX_URL:-}}"
  MN_PIP_EXTRA_INDEX_URL="${MN_PIP_EXTRA_INDEX_URL:-${MN_PYTHON_EXTRA_INDEX_URL:-https://pypi.org/simple}}"
  MN_HOST_HOME_DIR="${MN_HOST_HOME_DIR:-${MN_HOST_MN_DIR:-${INSTALL_DIR}}}"
  MN_HOST_ARTIFACTS_DIR="${MN_HOST_ARTIFACTS_DIR:-${MN_HOST_HOME_DIR}/runs}"
  MN_HOST_BLOB_STORE_DIR="${MN_HOST_BLOB_STORE_DIR:-${MN_HOST_HOME_DIR}/blobs}"
  MN_HOST_SHARED_STORAGE_ROOT="${MN_HOST_SHARED_STORAGE_ROOT:-${MN_HOST_SHARED_ARTIFACT_ROOT:-${MN_HOST_HOME_DIR}/shared}}"
  MN_SYNCTHING_ENABLED="${MN_SYNCTHING_ENABLED:-auto}"
  MN_SYNCTHING_IMAGE="${MN_SYNCTHING_IMAGE:-$MN_DEFAULT_SYNCTHING_IMAGE}"
  MN_SYNCTHING_RESCAN_INTERVAL_SECONDS="${MN_SYNCTHING_RESCAN_INTERVAL_SECONDS:-3600}"
  MN_BLUEPRINT_PYTHON_ENVS_DIR="${MN_BLUEPRINT_PYTHON_ENVS_DIR:-}"
  MN_HOST_OPENSHELL_STATE_DIR="${MN_HOST_OPENSHELL_STATE_DIR:-${INSTALL_DIR}/openshell-state}"
  INSTALL_METADATA_FILE="${INSTALL_DIR}/install_metadata.json"
  MN_MANAGED_PYTHON="${MN_MANAGED_PYTHON:-1}"
  MN_MANAGED_PYTHON_VERSION="${MN_MANAGED_PYTHON_VERSION:-$MN_DEFAULT_MANAGED_PYTHON_VERSION}"
  MN_MANAGED_PYTHON_ROOT="${MN_MANAGED_PYTHON_DIR:-${MN_HOME:-${HOME}/.mn}/python}"
  MN_UV_ROOT="${MN_UV_DIR:-${MN_HOME:-${HOME}/.mn}/uv}"
  MN_UV_BIN=""
  MN_PYTHON_BIN=""

  INSTALL_WEB_UI="Y"
  INSTALL_REDIS="Y"
  INSTALL_CONTEXT_ENGINE="Y"
  MN_OPENSHELL_MODE="${MN_OPENSHELL_MODE:-lazy}"
  INSTALL_PYTHON_SDK="Y"
  INSTALL_AGENTS="Y"
  INSTALL_CLI="Y"
  INSTALL_API="Y"
  START_NOW="Y"
  REINSTALL="Y"

  function usage() {
    local script_name="${MN_INSTALL_SCRIPT_NAME:-$(basename "$0")}"
    cat >&3 <<EOF
Usage: ./$script_name [options]

Installs MirrorNeuron from released artifacts and packages. Use through --mode binary.

Options:
  --version TAG                 Install this release version. Default: ${MN_DEFAULT_INSTALL_VERSION}.
  --yes                         Use component defaults and require non-interactive sudo.
  --interactive                 Ask each install question before proceeding.
  --reset                       Permanently clear runtime data first; requires typing YES.
  -v, --verbose                 Show installation details and command paths.
  --no-reinstall                Keep an existing install instead of overwriting it.
  --web-ui / --no-web-ui        Enable or skip the native Web UI.
  --redis / --no-redis          Enable or skip Redis Podman setup.
  --context-engine / --no-context-engine
                                Enable or skip Membrane context engine setup.
  --build-membrane              Local mode: build Membrane source instead of pulling GAR.
                                Ignored in github/binary modes. Source: MN_MEMBRANE_DIR
                                or the sibling Membrane checkout.
  --openshell / --no-openshell  Allow or disable on-demand OpenShell workers.
  --syncthing / --no-syncthing  Enable or skip Syncthing shared-storage replication.
  --start / --no-start          Start or skip starting MirrorNeuron after install.

Python component options:
  --python-components LIST      Install only these components: sdk,agents,cli,api.
                                Use all or none as shortcuts.
  --python-sdk / --no-python-sdk
  --agents / --no-agents        Install or skip indexed agent packages from the configured pip index.
  --cli / --no-cli
  --api / --no-api

Release/source options:
  --version TAG                 Set the common default release for all components.
  --core-version TAG            Pin MirrorNeuron core. Env: MN_CORE_VERSION.
  --python-sdk-version TAG      Pin mirrorneuron-python-sdk. Env: MN_PYTHON_SDK_VERSION.
  --cli-version TAG             Pin the native mn CLI. Env: MN_CLI_VERSION.
  --api-version TAG             Pin the native mn-api server. Env: MN_API_VERSION.
  --web-ui-version TAG          Pin mirrorneuron-web-ui. Env: MN_WEB_UI_VERSION.
  --gar-project PROJECT         Same as MN_GAR_PROJECT. Overrides the default public package index.
  --gar-location LOCATION       Same as MN_GAR_LOCATION. Default: us-central1.
  --gar-repository NAME         Same as MN_GAR_REPOSITORY. Default: agent-skills.
  --python-index-url URL        Same as MN_PIP_INDEX_URL. Default: ${MN_DEFAULT_PIP_INDEX_URL}
  --python-extra-index-url URL  Additional dependency index. Default: https://pypi.org/simple.
  --python PATH                 Same as MN_PYTHON. Must match Python ${MN_MANAGED_PYTHON_VERSION}.x.
  --no-managed-python           Do not use uv to install a private Python runtime.
  MN_HOME=/path                 Override the runtime state directory. Defaults to ${HOME}/.mn.
  MN_AGENTS_ROOT=/path          Optional local development override for packaged agent discovery.
  -h, --help                    Show this help.

Examples:
  ./$script_name --no-web-ui
  ./$script_name --version ${MN_DEFAULT_INSTALL_VERSION}
  ./$script_name --interactive
  ./$script_name --no-web-ui --python-components sdk,api
  ./$script_name --gar-project my-gcp-project --gar-repository agent-skills
  ./$script_name --python-index-url https://us-central1-python.pkg.dev/my-gcp-project/agent-skills/simple/
  MN_PYTHON=/opt/homebrew/bin/python${MN_MANAGED_PYTHON_VERSION} ./$script_name
  ./$script_name --version ${MN_DEFAULT_INSTALL_VERSION} --no-web-ui
  ./$script_name --core-version ${MN_DEFAULT_INSTALL_VERSION} --python-sdk-version ${MN_DEFAULT_INSTALL_VERSION} --cli-version ${MN_DEFAULT_INSTALL_VERSION} --api-version ${MN_DEFAULT_INSTALL_VERSION} --web-ui-version ${MN_DEFAULT_INSTALL_VERSION}
EOF
  }

  function set_python_components() {
    local value="$1"
    local component
    local -a components

    INSTALL_PYTHON_SDK="N"
    INSTALL_AGENTS="N"
    INSTALL_CLI="N"
    INSTALL_API="N"

    IFS=',' read -r -a components <<<"$value"
    for component in ${components[@]+"${components[@]}"}; do
      component="$(echo "$component" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
      case "$component" in
      all)
        INSTALL_PYTHON_SDK="Y"
        INSTALL_AGENTS="Y"
        INSTALL_CLI="Y"
        INSTALL_API="Y"
        ;;
      agent | agents)
        INSTALL_AGENTS="Y"
        ;;
      none) ;;
      sdk | python-sdk)
        INSTALL_PYTHON_SDK="Y"
        ;;
      cli)
        INSTALL_CLI="Y"
        ;;
      api)
        INSTALL_API="Y"
        ;;
      "") ;;
      *)
        print_error "Unknown Python component: $component"
        usage
        exit 1
        ;;
      esac
    done
  }

  while [ "$#" -gt 0 ]; do
    case "$1" in
    --no-reinstall) REINSTALL="N" ;;
    --web-ui) INSTALL_WEB_UI="Y" ;;
    --no-web-ui) INSTALL_WEB_UI="N" ;;
    --redis) INSTALL_REDIS="Y" ;;
    --no-redis) INSTALL_REDIS="N" ;;
    --context-engine) INSTALL_CONTEXT_ENGINE="Y" ;;
    --no-context-engine) INSTALL_CONTEXT_ENGINE="N" ;;
    --openshell) MN_OPENSHELL_MODE=lazy ;;
    --no-openshell) MN_OPENSHELL_MODE=disabled ;;
    --syncthing) MN_SYNCTHING_ENABLED="auto" ;;
    --no-syncthing) MN_SYNCTHING_ENABLED="0" ;;
    --start) START_NOW="Y" ;;
    --no-start) START_NOW="N" ;;
    --python-sdk) INSTALL_PYTHON_SDK="Y" ;;
    --no-python-sdk) INSTALL_PYTHON_SDK="N" ;;
    --agents) INSTALL_AGENTS="Y" ;;
    --no-agents) INSTALL_AGENTS="N" ;;
    --cli) INSTALL_CLI="Y" ;;
    --no-cli) INSTALL_CLI="N" ;;
    --api) INSTALL_API="Y" ;;
    --no-api) INSTALL_API="N" ;;
    --version)
      shift
      if [ "$#" -eq 0 ]; then
        print_error "--version requires a release tag such as ${MN_DEFAULT_INSTALL_VERSION}."
        usage
        exit 1
      fi
      INSTALL_VERSION="$1"
      ;;
    --version=*)
      INSTALL_VERSION="${1#*=}"
      ;;
    --core-version)
      shift
      if [ "$#" -eq 0 ]; then
        print_error "--core-version requires a release tag such as ${MN_DEFAULT_INSTALL_VERSION}."
        usage
        exit 1
      fi
      CORE_INSTALL_VERSION="$1"
      ;;
    --core-version=*)
      CORE_INSTALL_VERSION="${1#*=}"
      ;;
    --python-sdk-version)
      shift
      if [ "$#" -eq 0 ]; then
        print_error "--python-sdk-version requires a release tag such as ${MN_DEFAULT_INSTALL_VERSION}."
        usage
        exit 1
      fi
      PYTHON_SDK_INSTALL_VERSION="$1"
      ;;
    --python-sdk-version=*)
      PYTHON_SDK_INSTALL_VERSION="${1#*=}"
      ;;
    --cli-version)
      shift
      if [ "$#" -eq 0 ]; then
        print_error "--cli-version requires a release tag such as ${MN_DEFAULT_INSTALL_VERSION}."
        usage
        exit 1
      fi
      CLI_INSTALL_VERSION="$1"
      ;;
    --cli-version=*)
      CLI_INSTALL_VERSION="${1#*=}"
      ;;
    --api-version)
      shift
      if [ "$#" -eq 0 ]; then
        print_error "--api-version requires a release tag such as ${MN_DEFAULT_INSTALL_VERSION}."
        usage
        exit 1
      fi
      API_INSTALL_VERSION="$1"
      ;;
    --api-version=*)
      API_INSTALL_VERSION="${1#*=}"
      ;;
    --web-ui-version)
      shift
      if [ "$#" -eq 0 ]; then
        print_error "--web-ui-version requires a release tag such as ${MN_DEFAULT_INSTALL_VERSION}."
        usage
        exit 1
      fi
      WEB_UI_INSTALL_VERSION="$1"
      ;;
    --web-ui-version=*)
      WEB_UI_INSTALL_VERSION="${1#*=}"
      ;;
    --python-components)
      shift
      if [ "$#" -eq 0 ]; then
        print_error "--python-components requires a value."
        usage
        exit 1
      fi
      set_python_components "$1"
      ;;
    --python-components=*)
      set_python_components "${1#*=}"
      ;;
    --gar-project)
      shift
      if [ "$#" -eq 0 ]; then
        print_error "--gar-project requires a value."
        usage
        exit 1
      fi
      MN_GAR_PROJECT="$1"
      ;;
    --gar-project=*)
      MN_GAR_PROJECT="${1#*=}"
      ;;
    --gar-location)
      shift
      if [ "$#" -eq 0 ]; then
        print_error "--gar-location requires a value."
        usage
        exit 1
      fi
      MN_GAR_LOCATION="$1"
      ;;
    --gar-location=*)
      MN_GAR_LOCATION="${1#*=}"
      ;;
    --gar-repository)
      shift
      if [ "$#" -eq 0 ]; then
        print_error "--gar-repository requires a value."
        usage
        exit 1
      fi
      MN_GAR_REPOSITORY="$1"
      ;;
    --gar-repository=*)
      MN_GAR_REPOSITORY="${1#*=}"
      ;;
    --python-index-url)
      shift
      if [ "$#" -eq 0 ]; then
        print_error "--python-index-url requires a value."
        usage
        exit 1
      fi
      MN_PIP_INDEX_URL="$1"
      ;;
    --python-index-url=*)
      MN_PIP_INDEX_URL="${1#*=}"
      ;;
    --python-extra-index-url)
      shift
      if [ "$#" -eq 0 ]; then
        print_error "--python-extra-index-url requires a value."
        usage
        exit 1
      fi
      MN_PIP_EXTRA_INDEX_URL="$1"
      ;;
    --python-extra-index-url=*)
      MN_PIP_EXTRA_INDEX_URL="${1#*=}"
      ;;
    --python)
      shift
      if [ "$#" -eq 0 ]; then
        print_error "--python requires a value."
        usage
        exit 1
      fi
      MN_PYTHON="$1"
      ;;
    --python=*)
      MN_PYTHON="${1#*=}"
      ;;
    --no-managed-python)
      MN_MANAGED_PYTHON=0
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      print_error "Unknown option: $1"
      printf 'Use ./install.sh --help for common options or --help-all for the full reference.\n' >&3
      exit 1
      ;;
    esac
    shift
  done

  function finalize_binary_install_version() {
    # Only explicit component overrides may replace a snapshot's package pins.
    MN_PYTHON_SDK_VERSION_OVERRIDE="${PYTHON_SDK_INSTALL_VERSION#v}"
    MN_CLI_VERSION_OVERRIDE="${CLI_INSTALL_VERSION#v}"
    MN_API_VERSION_OVERRIDE="${API_INSTALL_VERSION#v}"
    if [ -z "$INSTALL_VERSION" ] && [ -n "$CORE_INSTALL_VERSION" ]; then
      INSTALL_VERSION="$CORE_INSTALL_VERSION"
    fi
    INSTALL_VERSION="${INSTALL_VERSION:-$MN_DEFAULT_INSTALL_VERSION}"
    mn_validate_version_tag_or_exit "$INSTALL_VERSION"

    # Each component uses its explicit pin from the current release contract.
    CORE_INSTALL_VERSION="${CORE_INSTALL_VERSION:-$MN_DEFAULT_CORE_VERSION}"
    PYTHON_SDK_INSTALL_VERSION="${PYTHON_SDK_INSTALL_VERSION:-$DEFAULT_PYTHON_SDK_INSTALL_VERSION}"
    CLI_INSTALL_VERSION="${CLI_INSTALL_VERSION:-$DEFAULT_CLI_INSTALL_VERSION}"
    API_INSTALL_VERSION="${API_INSTALL_VERSION:-$DEFAULT_API_INSTALL_VERSION}"
    WEB_UI_INSTALL_VERSION="${WEB_UI_INSTALL_VERSION:-$DEFAULT_WEB_UI_INSTALL_VERSION}"
    PACKAGE_INDEX_VERSION="${PACKAGE_INDEX_VERSION:-$MN_DEFAULT_AGENT_PACKAGE_INDEX_VERSION}"
    MN_INSTALL_SUPPORT_VERSION="${MN_INSTALL_SUPPORT_VERSION:-$MN_DEFAULT_INSTALL_SUPPORT_VERSION}"
    mn_validate_version_tag_or_exit "$CORE_INSTALL_VERSION"
    mn_validate_version_tag_or_exit "$PYTHON_SDK_INSTALL_VERSION"
    mn_validate_version_tag_or_exit "$CLI_INSTALL_VERSION"
    mn_validate_version_tag_or_exit "$API_INSTALL_VERSION"
    mn_validate_version_tag_or_exit "$WEB_UI_INSTALL_VERSION"
    mn_validate_version_tag_or_exit "$PACKAGE_INDEX_VERSION"
    mn_validate_version_tag_or_exit "$MN_INSTALL_SUPPORT_VERSION"
    MN_INSTALL_VERSION="$INSTALL_VERSION"
    CORE_RELEASE_TAG="$CORE_INSTALL_VERSION"
    MN_PYTHON_SDK_PACKAGE_VERSION="$(mn_package_version_from_tag "$PYTHON_SDK_INSTALL_VERSION")"
    MN_PACKAGE_VERSION="$MN_PYTHON_SDK_PACKAGE_VERSION"
    MN_WEB_UI_PACKAGE_VERSION="${MN_WEB_UI_PACKAGE_VERSION:-$(mn_web_ui_package_version_from_tag "$WEB_UI_INSTALL_VERSION")}"
    RUNTIME_COMPOSE_TEMPLATE="${RUNTIME_COMPOSE_TEMPLATE:-${SCRIPT_DIR}/install_support/${MN_INSTALL_SUPPORT_VERSION}/docker-compose.yml}"
    PACKAGE_INDEX_FILE="${PACKAGE_INDEX_FILE:-${SCRIPT_DIR}/install_support/${PACKAGE_INDEX_VERSION}/package-index/python-packages.toml}"
    export MN_INSTALL_VERSION
  }

  finalize_binary_install_version

  function run_quiet() {
    local label="$1"
    shift
    local log_dir="${TMPDIR:-/tmp}/mirror_neuron_install"
    mkdir -p "$log_dir"
    local log_file="${log_dir}/${label//[^A-Za-z0-9_.-]/_}.$$.log"

    if ! "$@" >"$log_file" 2>&1; then
      print_error "$label failed. Details: $log_file"
      if [ "$MN_INSTALL_VERBOSE" = "Y" ]; then
        tail -n 30 "$log_file" >&3 2>/dev/null || true
      else
        printf '  Re-run with --verbose to show the last log lines.\n' >&3
      fi
      exit 1
    fi
  }

  function require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
      print_error "'$1' is required but not installed."
      exit 1
    fi
  }

  function require_file() {
    if [ ! -f "$1" ]; then
      print_error "$2 is required but was not found at $1."
      exit 1
    fi
  }

  function ensure_pip() {
    if "$MN_PYTHON_BIN" -m pip --version >/dev/null 2>&1; then
      return
    fi

    print_warning "pip was not found for $MN_PYTHON_BIN; trying ensurepip."
    "$MN_PYTHON_BIN" -m ensurepip --upgrade >/dev/null 2>&1 || {
      print_error "Could not install pip with ensurepip. Please install pip for $MN_PYTHON_BIN and rerun."
      exit 1
    }
  }

  function python_version() {
    "$1" -c 'import sys; print(".".join(str(part) for part in sys.version_info[:3]))' 2>/dev/null
  }

  function python_is_supported() {
    "$1" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' >/dev/null 2>&1
  }

  function python_minor_version() {
    "$1" -c 'import sys; print(".".join(str(part) for part in sys.version_info[:2]))' 2>/dev/null
  }

  function python_is_selected_minor() {
    [ "$(python_minor_version "$1" || true)" = "$MN_MANAGED_PYTHON_VERSION" ]
  }

  function curl_github() {
    local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    if [ -n "$token" ]; then
      curl -H "Authorization: Bearer $token" "$@"
    else
      curl "$@"
    fi
  }

  function managed_python_enabled() {
    case "$MN_MANAGED_PYTHON" in
    0 | false | FALSE | False | no | NO | No | n | N) return 1 ;;
    *) return 0 ;;
    esac
  }

  function validate_managed_python_version() {
    if [[ ! "$MN_MANAGED_PYTHON_VERSION" =~ ^[0-9]+[.][0-9]+$ ]]; then
      print_error "MN_MANAGED_PYTHON_VERSION must be a Python minor version like 3.12."
      exit 1
    fi
  }

  function install_uv() {
    local os uv_bin_dir installer
    os="$(uname -s)"

    case "$os" in
    Darwin | Linux) ;;
    *)
      print_error "Unsupported platform for uv-managed Python: ${os}."
      print_error "Set MN_PYTHON=/path/to/python${MN_MANAGED_PYTHON_VERSION} and rerun."
      exit 1
      ;;
    esac

    if ! command -v curl >/dev/null 2>&1; then
      print_error "'curl' is required to install uv."
      exit 1
    fi

    uv_bin_dir="${MN_UV_ROOT}/bin"
    installer="$(mktemp "${TMPDIR:-/tmp}/mn-uv-install.XXXXXX")"
    mkdir -p "$uv_bin_dir"

    print_step "Installing uv for private Python management"
    if ! curl_github -fsSL "https://astral.sh/uv/install.sh" -o "$installer"; then
      rm -f "$installer"
      print_error "Could not download the uv installer."
      print_error "Install uv manually or set MN_PYTHON=/path/to/python${MN_MANAGED_PYTHON_VERSION}."
      exit 1
    fi

    if ! mn_run_uv_installer "$installer" "$uv_bin_dir" >/dev/null 2>&1; then
      rm -f "$installer"
      print_error "Could not install uv."
      print_error "Install uv manually or set MN_PYTHON=/path/to/python${MN_MANAGED_PYTHON_VERSION}."
      exit 1
    fi
    rm -f "$installer"

    MN_UV_BIN="$uv_bin_dir/uv"
    if [ ! -x "$MN_UV_BIN" ]; then
      print_error "uv installer did not create $MN_UV_BIN."
      exit 1
    fi

    print_detail "Installed uv at $MN_UV_BIN."
  }

  function resolve_uv() {
    if [ -n "$MN_UV_BIN" ]; then
      return
    fi

    MN_UV_BIN="$(command -v uv 2>/dev/null || true)"
    if [ -n "$MN_UV_BIN" ]; then
      return
    fi

    MN_UV_BIN="${MN_UV_ROOT}/bin/uv"
    if [ -x "$MN_UV_BIN" ]; then
      return
    fi

    install_uv
  }

  function managed_python_is_expected() {
    local python_bin="$1"
    [ -x "$python_bin" ] &&
      python_is_supported "$python_bin" &&
      [ "$(python_minor_version "$python_bin" || true)" = "$MN_MANAGED_PYTHON_VERSION" ]
  }

  function find_uv_managed_python() {
    UV_PYTHON_INSTALL_DIR="$MN_MANAGED_PYTHON_ROOT" \
      UV_CACHE_DIR="${MN_UV_ROOT}/cache" \
      "$MN_UV_BIN" python find --managed-python --no-python-downloads "$MN_MANAGED_PYTHON_VERSION" 2>/dev/null || true
  }

  function install_managed_python() {
    validate_managed_python_version

    local managed_bin

    print_step "Resolving private Python ${MN_MANAGED_PYTHON_VERSION} runtime with uv"
    print_step "Installing private Python ${MN_MANAGED_PYTHON_VERSION} under ${MN_MANAGED_PYTHON_ROOT}."
    resolve_uv

    managed_bin="$(find_uv_managed_python)"
    if ! managed_python_is_expected "$managed_bin"; then
      run_quiet "uv-python-install" env \
        "UV_PYTHON_INSTALL_DIR=$MN_MANAGED_PYTHON_ROOT" \
        "UV_CACHE_DIR=${MN_UV_ROOT}/cache" \
        "UV_NO_PROGRESS=1" \
        "$MN_UV_BIN" python install "$MN_MANAGED_PYTHON_VERSION"
      managed_bin="$(find_uv_managed_python)"
    fi
    if [ -z "$managed_bin" ]; then
      managed_bin="$(find "$MN_MANAGED_PYTHON_ROOT" -path '*/bin/python3' -print | head -n 1 || true)"
    fi

    if ! managed_python_is_expected "$managed_bin"; then
      print_error "Managed Python install did not produce Python ${MN_MANAGED_PYTHON_VERSION} at ${managed_bin}."
      exit 1
    fi

    MN_PYTHON_BIN="$(mn_base_python_executable "$managed_bin")" || {
      print_error "Could not resolve a stable base Python interpreter from $managed_bin."
      exit 1
    }
    print_detail "Using uv-managed Python $(python_version "$managed_bin") at $managed_bin."
  }

  function print_python_requirement_error() {
    local selected="${1:-}"
    local script_name="${MN_INSTALL_SCRIPT_NAME:-$(basename "$0")}"
    local version=""

    print_error "MirrorNeuron Python components require Python ${MN_MANAGED_PYTHON_VERSION}.x by default."
    if [ -n "$selected" ]; then
      version="$(python_version "$selected" || true)"
      if [ -n "$version" ]; then
        print_error "Selected Python '$selected' is version $version."
      else
        print_error "Selected Python '$selected' could not be run."
      fi
    fi
    print_error "Install Python ${MN_MANAGED_PYTHON_VERSION}.x yourself, or allow the uv-managed private runtime fallback."
    print_error "You can also rerun with: MN_PYTHON=/opt/homebrew/bin/python${MN_MANAGED_PYTHON_VERSION} ./$script_name"
  }

  function resolve_python_runtime() {
    local candidate resolved
    local candidates=()

    if [ -n "$MN_PYTHON_BIN" ]; then
      return
    fi

    if [ -n "${MN_PYTHON:-}" ]; then
      candidates+=("$MN_PYTHON")
    else
      candidates+=("python${MN_MANAGED_PYTHON_VERSION}" python3 python)
    fi

    for candidate in "${candidates[@]}"; do
      resolved="$(command -v "$candidate" 2>/dev/null || true)"
      if [ -z "$resolved" ]; then
        if [ -n "${MN_PYTHON:-}" ]; then
          print_python_requirement_error "$candidate"
          exit 1
        fi
        continue
      fi
      if python_is_supported "$resolved" && python_is_selected_minor "$resolved"; then
        MN_PYTHON_BIN="$(mn_base_python_executable "$resolved")" || {
          print_error "Could not resolve a stable base Python interpreter from $resolved."
          exit 1
        }
        print_detail "Using Python $(python_version "$MN_PYTHON_BIN") at $MN_PYTHON_BIN."
        return
      fi
      if [ -n "${MN_PYTHON:-}" ]; then
        print_python_requirement_error "$resolved"
        exit 1
      fi
    done

    if managed_python_enabled; then
      install_managed_python
      print_detail "Using Python $(python_version "$MN_PYTHON_BIN") at $MN_PYTHON_BIN."
      return
    fi

    print_warning "Managed Python fallback is disabled."
    resolved="$(command -v "python${MN_MANAGED_PYTHON_VERSION}" 2>/dev/null || true)"
    print_python_requirement_error "$resolved"
    exit 1
  }

  function should_install_python_packages() {
    [ "$INSTALL_PYTHON_SDK" = "Y" ] ||
      [ "$INSTALL_AGENTS" = "Y" ] ||
      [ "$INSTALL_CLI" = "Y" ] ||
      [ "$INSTALL_API" = "Y" ] ||
      [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]
  }

  function validate_selections() {

    if [ "$INSTALL_WEB_UI" = "Y" ] && [ "$INSTALL_API" != "Y" ]; then
      print_warning "Installing Web UI without the API package. The UI will need an API service from another install."
    fi
  }

  function core_gar_image_for_tag() {
    local tag="$1"

    if [ -n "$CORE_IMAGE" ]; then
      printf '%s' "$CORE_IMAGE"
      return
    fi

    printf '%s-docker.pkg.dev/%s/%s/%s:%s' \
      "$CORE_GAR_LOCATION" \
      "$CORE_GAR_PROJECT" \
      "$CORE_GAR_REPOSITORY" \
      "$CORE_GAR_IMAGE_NAME" \
      "$tag"
  }

  function install_core_from_gar() {
    local tag image image_version image_revision image_digest

    tag="$CORE_RELEASE_TAG"
    image="$(core_gar_image_for_tag "$tag")"
    print_detail "Pulling Core GAR image $image."

    if ! mn_pull_public_gar_image "$image"; then
      print_error "Could not pull the required Core GAR image: $image"
      print_error "Binary installs require this immutable Core image. Verify the release image is published and public, then retry."
      exit 1
    fi

    image_version="$(podman image inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$image" 2>/dev/null || true)"
    image_revision="$(podman image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$image" 2>/dev/null || true)"
    image_digest="$(podman image inspect --format '{{ index .RepoDigests 0 }}' "$image" 2>/dev/null || true)"
    image_digest="${image_digest##*@}"

    if [ "$image_version" != "$tag" ]; then
      print_error "Core GAR image version label mismatch: expected $tag, got ${image_version:-missing}."
      exit 1
    fi
    if [[ ! "$image_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      print_error "Core GAR image did not expose a valid manifest digest: ${image_digest:-missing}."
      exit 1
    fi

    podman image tag "$image" mirror-neuron-core:latest
    mkdir -p "$INSTALL_DIR"
    "$MN_PYTHON_BIN" - "$INSTALL_METADATA_FILE" "$tag" "$image" "$image_digest" "$image_revision" <<'PY_METADATA'
import json, os, sys, tempfile
from pathlib import Path
from datetime import datetime, timezone
path = Path(sys.argv[1])
metadata = json.loads(path.read_text()) if path.exists() else {}
metadata.update(dict(zip(("core_release_tag", "core_image", "core_image_digest", "core_image_revision"), sys.argv[2:])))
metadata["updated_at"] = datetime.now(timezone.utc).isoformat()
metadata["install_role"] = os.environ["MN_INSTALL_ROLE"]
fd, name = tempfile.mkstemp(dir=path.parent, prefix=".install-metadata-")
with os.fdopen(fd, "w") as stream:
    json.dump(metadata, stream, indent=2)
    stream.write("\n")
os.replace(name, path)
PY_METADATA
  }

  function install_core_from_release() {
    install_core_from_gar
  }

  PIP_OWNED_INDEX_URL=""
  PIP_DEPENDENCY_INDEX_ARGS=()

  function normalize_python_distribution_name() {
    "$MN_PYTHON_BIN" - "$1" <<'PY'
import re
import sys

name = sys.argv[1].split("[", 1)[0].strip().lower()
print(re.sub(r"[-_.]+", "_", name))
PY
  }

  function bundled_wheel_for_requirement() {
    local requirement="$1"
    local package_part version dist_name wheel_dir wheel

    case "$requirement" in
    *"=="*) ;;
    *) return 1 ;;
    esac

    package_part="${requirement%%==*}"
    package_part="${package_part%%[*}"
    version="${requirement#*==}"
    version="${version%%[[:space:];,<>=!~]*}"
    [ -n "$package_part" ] && [ -n "$version" ] || return 1

    dist_name="$(normalize_python_distribution_name "$package_part")"
    wheel_dir="${MN_BUNDLED_WHEEL_DIR:-${SCRIPT_DIR}/install_support/${INSTALL_VERSION}/python-wheels}"
    [ -d "$wheel_dir" ] || return 1

    wheel="$(find "$wheel_dir" -maxdepth 1 -type f -name "${dist_name}-${version}-*.whl" -print | head -n 1 || true)"
    [ -n "$wheel" ] || return 1
    printf '%s\n' "$wheel"
  }

  function resolve_python_index_url() {
    local url="$MN_PIP_INDEX_URL"
    if [ -z "$url" ]; then
      if [ -n "$MN_GAR_PROJECT" ]; then
        url="https://${MN_GAR_LOCATION}-python.pkg.dev/${MN_GAR_PROJECT}/${MN_GAR_REPOSITORY}/simple/"
      else
        url="$MN_DEFAULT_PIP_INDEX_URL"
      fi
    fi
    case "$url" in
    */) printf '%s' "$url" ;;
    *) printf '%s/' "$url" ;;
    esac
  }

  function prepare_pip_index_args() {
    local index_url
    index_url="$(resolve_python_index_url)"
    PIP_OWNED_INDEX_URL="$index_url"
    if [ -n "$MN_PIP_EXTRA_INDEX_URL" ]; then
      PIP_DEPENDENCY_INDEX_ARGS=(
        --index-url "$index_url"
        --extra-index-url "$MN_PIP_EXTRA_INDEX_URL"
      )
    else
      PIP_DEPENDENCY_INDEX_ARGS=(--index-url "$index_url")
    fi
  }

  function indexed_requirements_for_group() {
    local group="$1"
    "$MN_PYTHON_BIN" - "$PACKAGE_INDEX_FILE" "$group" <<'PY'
from __future__ import annotations

import sys
import tomllib
from pathlib import Path

index_file = Path(sys.argv[1])
group = sys.argv[2]
data = tomllib.loads(index_file.read_text())

def requirement(package: dict) -> str:
    name = package["name"]
    extras = package.get("default_extras") or []
    if extras:
        name = f"{name}[{','.join(extras)}]"
    version = str(package.get("version") or "").strip().lstrip("vV")
    return f"{name}=={version}" if version else name

for package in data.get("packages", []):
    groups = package.get("installer_groups") or []
    if group == "__binary_default__":
        selected = bool(package.get("binary_default"))
    else:
        selected = group in groups
    if selected:
        print(requirement(package))
PY
  }

  function install_indexed_group() {
    local group="$1"
    local requirement package_name package_version pinned_requirement label bundled_wheel dependency_requirement installed="N"
    local dependency_links=()
    while IFS= read -r requirement; do
      [ -n "$requirement" ] || continue
      package_name="$(printf '%s' "$requirement" | sed -E 's/\[.*$//; s/[<>=!~].*$//')"
      package_version=""
      case "$package_name" in
      mirrorneuron-python-sdk) package_version="$MN_PYTHON_SDK_VERSION_OVERRIDE" ;;
      esac
      if [ -n "$package_version" ]; then
        pinned_requirement="${requirement%%[<>=!~]*}==${package_version}"
      else
        case "$requirement" in
        *"=="* | *">="* | *"<="* | *"~="* | *"!="* | *">"* | *"<"*) pinned_requirement="$requirement" ;;
        *) pinned_requirement="${requirement}==${MN_PACKAGE_VERSION}" ;;
        esac
      fi
      label="$(printf '%s' "$pinned_requirement" | tr -c 'A-Za-z0-9_.-' '_')"
      dependency_requirement="$pinned_requirement"
      dependency_links=()
      if bundled_wheel="$(bundled_wheel_for_requirement "$pinned_requirement")"; then
        local wheel_extras=""
        case "$pinned_requirement" in
        *\[*\]*)
          wheel_extras="[${pinned_requirement#*[}"
          wheel_extras="${wheel_extras%%]*}]"
          ;;
        esac
        dependency_requirement="${bundled_wheel}${wheel_extras}"
        dependency_links=(--find-links "$(dirname "$bundled_wheel")")
        run_quiet "install-${label}" "$VENV_DIR/bin/pip" install \
          --no-deps --force-reinstall "${bundled_wheel}${wheel_extras}"
      else
        run_quiet "install-${label}" "$VENV_DIR/bin/pip" install \
          --index-url "$PIP_OWNED_INDEX_URL" \
          --no-deps --force-reinstall "$pinned_requirement"
      fi
      # Bash 3.2 treats empty arrays as unset under nounset; omit optional arguments.
      run_quiet "dependencies-${label}" "$VENV_DIR/bin/pip" install \
        "${PIP_DEPENDENCY_INDEX_ARGS[@]}" ${dependency_links[@]+"${dependency_links[@]}"} --constraint "$VENV_DIR/mn-release-constraints.txt" "$dependency_requirement"
      installed="Y"
    done < <(indexed_requirements_for_group "$group")
    if [ "$installed" != "Y" ]; then
      print_error "No packages in ${PACKAGE_INDEX_FILE} matched installer group '${group}'."
      exit 1
    fi
  }

  function install_indexed_group_if_available() {
    local group="$1"
    local description="$2"
    if [ -n "$(indexed_requirements_for_group "$group")" ]; then
      install_indexed_group "$group"
    else
      print_warning "No ${description} are listed in ${PACKAGE_INDEX_FILE}; skipping them for ${INSTALL_VERSION}."
    fi
  }

  function install_python_packages() {
    "$MN_PYTHON_BIN" -m venv "$VENV_DIR" >/dev/null 2>&1
    run_quiet "pip-upgrade" "$VENV_DIR/bin/pip" install --upgrade pip
    prepare_pip_index_args
    "$MN_PYTHON_BIN" - "$PACKAGE_INDEX_FILE" "$MN_PYTHON_SDK_VERSION_OVERRIDE" \
      >"$VENV_DIR/mn-release-constraints.txt" <<'PYTHON'
import sys, tomllib
names = ("mirrorneuron-python-sdk",)
overrides = dict(zip(names, sys.argv[2:]))
for package in tomllib.loads(open(sys.argv[1]).read())["packages"]:
    version = overrides.get(package["name"]) or package["version"]
    print(f"{package['name']}=={version}")
PYTHON
    if [ "$INSTALL_PYTHON_SDK" = "Y" ]; then
      install_indexed_group sdk
    fi
    if [ "$MN_INSTALL_ROLE" != "client" ]; then
      install_indexed_group runtime-node
    fi
    if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
      install_indexed_group membrane-runtime
    fi
    if [ "$INSTALL_AGENTS" = "Y" ]; then
      install_indexed_group_if_available agent "packaged agents"
    fi
    run_quiet "python-dependency-check" "$VENV_DIR/bin/pip" check
  }

  function compose_profiles() {
    local profiles=()
    [ "$INSTALL_CONTEXT_ENGINE" = "Y" ] && profiles+=("context")
    case "$(printf '%s' "$MN_SYNCTHING_ENABLED" | tr '[:upper:]' '[:lower:]')" in
    '' | 0 | false | no | n | off | disabled) ;;
    *) profiles+=("syncthing") ;;
    esac
    if [ "${#profiles[@]}" -eq 0 ]; then
      printf ''
      return 0
    fi
    local IFS=,
    printf '%s' "${profiles[*]}"
  }

  function generate_mn_secret() {
    local secret
    local python_fallback="${MN_PYTHON_BIN:-}"

    if command -v openssl >/dev/null 2>&1; then
      if secret="$(openssl rand -hex 32 2>/dev/null)" && [ -n "$secret" ]; then
        printf '%s\n' "$secret"
        return 0
      fi
    fi

    if command -v od >/dev/null 2>&1 && [ -r /dev/urandom ]; then
      if secret="$(od -An -N32 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" && [ -n "$secret" ]; then
        printf '%s\n' "$secret"
        return 0
      fi
    fi

    if [ -z "$python_fallback" ]; then
      python_fallback="$(command -v "python${MN_MANAGED_PYTHON_VERSION}" 2>/dev/null || true)"
    fi
    if [ -n "$python_fallback" ]; then
      if secret="$("$python_fallback" -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null)" && [ -n "$secret" ]; then
        printf '%s\n' "$secret"
        return 0
      fi
    fi

    return 1
  }

  function resolve_secret_file() {
    local env_value="$1"
    local file="$2"
    local label="$3"
    local value

    case "$label:$env_value" in
    MN_GRPC_AUTH_TOKEN:mirror_neuron_password | MN_GRPC_ADMIN_TOKEN:mirror_neuron_password_admin) env_value="" ;;
    esac
    if [ -n "$env_value" ] && [ "$env_value" != "mirrorneuron" ]; then
      printf '%s\n' "$env_value" >"$file"
      chmod 600 "$file" 2>/dev/null || true
      printf '%s\n' "$env_value"
      return 0
    fi

    mkdir -p "$INSTALL_DIR"
    if [ -s "$file" ]; then
      value="$(tr -d '[:space:]' <"$file")"
      case "$label:$value" in
      MN_GRPC_AUTH_TOKEN:mirror_neuron_password | MN_GRPC_ADMIN_TOKEN:mirror_neuron_password_admin) value="" ;;
      esac
      if [ -n "$value" ] && [ "$value" != "mirrorneuron" ]; then
        chmod 600 "$file" 2>/dev/null || true
        printf '%s\n' "$value"
        return 0
      fi
    fi

    if ! value="$(generate_mn_secret)"; then
      value=""
    fi
    if [ -z "$value" ]; then
      print_error "Failed to generate ${label}."
      exit 1
    fi
    printf '%s\n' "$value" >"$file"
    chmod 600 "$file" 2>/dev/null || true
    printf '%s\n' "$value"
  }

  function resolve_mn_cookie() {
    resolve_secret_file "${MN_COOKIE:-}" "${INSTALL_DIR}/erlang.cookie" "MN_COOKIE"
  }

  function resolve_network_token() {
    resolve_secret_file "${MN_NETWORK_JOIN_TOKEN:-}" "${INSTALL_DIR}/network.token" "MN_NETWORK_JOIN_TOKEN"
  }

  function derive_network_secret() {
    local token="$1"
    local label="$2"
    local material="mirror-neuron:${label}:${token}"
    local digest
    local python_fallback="${MN_PYTHON_BIN:-}"

    if command -v shasum >/dev/null 2>&1; then
      if digest="$(printf '%s' "$material" | shasum -a 256 2>/dev/null | awk '{print $1}')" && [ -n "$digest" ]; then
        printf '%s\n' "$digest"
        return 0
      fi
    fi

    if command -v sha256sum >/dev/null 2>&1; then
      if digest="$(printf '%s' "$material" | sha256sum 2>/dev/null | awk '{print $1}')" && [ -n "$digest" ]; then
        printf '%s\n' "$digest"
        return 0
      fi
    fi

    if command -v openssl >/dev/null 2>&1; then
      if digest="$(printf '%s' "$material" | openssl dgst -sha256 -r 2>/dev/null | awk '{print $1}')" && [ -n "$digest" ]; then
        printf '%s\n' "$digest"
        return 0
      fi
    fi

    if [ -z "$python_fallback" ]; then
      python_fallback="$(command -v "python${MN_MANAGED_PYTHON_VERSION}" 2>/dev/null || true)"
    fi
    if [ -n "$python_fallback" ]; then
      if digest="$(printf '%s' "$material" | "$python_fallback" -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null)" && [ -n "$digest" ]; then
        printf '%s\n' "$digest"
        return 0
      fi
    fi

    print_error "Need shasum, sha256sum, a working openssl, or python${MN_MANAGED_PYTHON_VERSION} to derive Redis credentials."
    exit 1
  }

  function resolve_redis_password() {
    local admin_token="$1"
    local mn_env="${MN_ENV:-dev}"
    local password

    case "$mn_env" in
    prod | production)
      password="$(derive_network_secret "$admin_token" "redis")"
      mkdir -p "$INSTALL_DIR"
      printf '%s\n' "$password" >"${INSTALL_DIR}/redis.password"
      chmod 600 "${INSTALL_DIR}/redis.password" 2>/dev/null || true
      printf '%s\n' "$password"
      ;;
    *)
      printf '%s\n' "mirror_neuron_redis_dev"
      ;;
    esac
  }

  function ensure_runtime_host_directory() {
    local path="$1"
    local description="$2"
    local override_name="$3"

    if [ -e "$path" ] || [ -L "$path" ]; then
      if [ ! -d "$path" ]; then
        print_error "Expected ${description} to be a directory: ${path}"
        print_error "Move or remove that path, or set ${override_name} to a directory."
        exit 1
      fi
      chmod u+rwx "$path" 2>/dev/null || true
      if [ ! -w "$path" ]; then
        print_error "Expected ${description} to be writable: ${path}"
        print_error "Repair ownership or set ${override_name} to a writable directory."
        exit 1
      fi
      return 0
    fi

    mkdir -p "$path"
    chmod u+rwx "$path" 2>/dev/null || true
  }

  function prepare_litellm_gateway_config() {
    local gateway_dir="${MN_HOST_HOME_DIR}/models/litellm-gateway"
    mkdir -p "$gateway_dir"
    if [ ! -e "${gateway_dir}/config.yaml" ]; then
      printf '{"model_list":[]}\n' >"${gateway_dir}/config.yaml"
    fi
    chmod u+rwX "$gateway_dir" "${gateway_dir}/config.yaml" 2>/dev/null || true
  }

  function write_runtime_compose_files() {
    local context_auth_token profiles network_name network_external network_token redis_password mn_cookie runtime_skills_root runtime_agents_root runtime_package_index context_memory_enabled otterdesk_context_memory_enabled membrane_engine_tag membrane_engine_image litellm_gateway_bind_host api_host
    local grpc_auth_token grpc_admin_token runtime_port_settings
    grpc_auth_token="$(resolve_secret_file "${MN_GRPC_AUTH_TOKEN:-}" "${INSTALL_DIR}/grpc_auth.token" "MN_GRPC_AUTH_TOKEN")"
    grpc_admin_token="$(resolve_secret_file "${MN_GRPC_ADMIN_TOKEN:-}" "${INSTALL_DIR}/grpc_admin.token" "MN_GRPC_ADMIN_TOKEN")"
    context_auth_token="$(resolve_secret_file "${MN_CONTEXT_AUTH_TOKEN:-}" "${INSTALL_DIR}/context_auth.token" "MN_CONTEXT_AUTH_TOKEN")"
    profiles="$(compose_profiles)"
    api_host="${MN_API_HOST:-localhost}"
    litellm_gateway_bind_host="${MN_LITELLM_GATEWAY_BIND_HOST:-0.0.0.0}"
    network_name="${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
    network_external="$(mn_runtime_network_external "$network_name")"
    network_token="$(resolve_network_token)"
    redis_password="$(resolve_redis_password "mirror_neuron_password_admin")"
    mn_cookie="$(resolve_mn_cookie)"
    runtime_skills_root="${MN_SKILLS_ROOT:-${MN_HOST_HOME_DIR}/skills}"
    runtime_agents_root="${MN_AGENTS_ROOT:-}"
    runtime_package_index="${MN_PACKAGE_INDEX_FILE:-}"
    membrane_engine_tag="${MN_MEMBRANE_ENGINE_IMAGE_TAG:-$(mn_default_membrane_engine_tag)}"
    if [[ "$membrane_engine_tag" != v* ]]; then
      membrane_engine_tag="v${membrane_engine_tag}"
    fi
    membrane_engine_image="${MN_MEMBRANE_ENGINE_IMAGE:-${MN_CONTEXT_ENGINE_IMAGE:-${MN_DEFAULT_MEMBRANE_GAR_IMAGE}:${membrane_engine_tag}}}"
    membrane_engine_image="$(mn_selected_membrane_image "$membrane_engine_image")"
    if [ "$MN_BUILD_MEMBRANE" = "Y" ]; then membrane_engine_tag=""; fi
    context_memory_enabled="${MN_CONTEXT_MEMORY_ENABLED:-1}"
    otterdesk_context_memory_enabled="${OTTERDESK_CONTEXT_MEMORY_ENABLED:-$context_memory_enabled}"
    if [ -n "${PACKAGE_INDEX_FILE:-}" ] && [ -f "$PACKAGE_INDEX_FILE" ]; then
      runtime_package_index="${INSTALL_DIR}/package-index/python-packages.toml"
      mkdir -p "$(dirname "$runtime_package_index")"
      cp "$PACKAGE_INDEX_FILE" "$runtime_package_index"
    fi

    mkdir -p "$INSTALL_DIR"
    ensure_runtime_host_directory "$MN_HOST_HOME_DIR" "MirrorNeuron home mount" "MN_HOST_HOME_DIR"
    ensure_runtime_host_directory "$runtime_skills_root" "MirrorNeuron runtime modules root" "MN_SKILLS_ROOT"
    ensure_runtime_host_directory "$MN_HOST_ARTIFACTS_DIR" "run artifacts host mount" "MN_HOST_ARTIFACTS_DIR"
    ensure_runtime_host_directory "$MN_HOST_BLOB_STORE_DIR" "blob store host mount" "MN_HOST_BLOB_STORE_DIR"
    ensure_runtime_host_directory "$MN_HOST_SHARED_STORAGE_ROOT" "shared storage host mount" "MN_HOST_SHARED_STORAGE_ROOT"
    prepare_litellm_gateway_config
    mn_write_runtime_compose_file "$RUNTIME_COMPOSE_TEMPLATE" "$RUNTIME_COMPOSE_FILE"
    runtime_port_settings="$(mn_runtime_port_settings "$RUNTIME_COMPOSE_ENV")"
    cat >"$RUNTIME_COMPOSE_ENV" <<EOF
COMPOSE_PROJECT_NAME=mirror-neuron
COMPOSE_PROFILES=${profiles}
MN_HOST_STATE_DIR=${INSTALL_DIR}
MN_HOST_HOME_DIR=${MN_HOST_HOME_DIR}
MN_HOST_ARTIFACTS_DIR=${MN_HOST_ARTIFACTS_DIR}
MN_HOST_BLOB_STORE_DIR=${MN_HOST_BLOB_STORE_DIR}
MN_HOST_SHARED_STORAGE_ROOT=${MN_HOST_SHARED_STORAGE_ROOT}
MN_SYNCTHING_ENABLED=${MN_SYNCTHING_ENABLED}
MN_SYNCTHING_IMAGE=${MN_SYNCTHING_IMAGE}
MN_SYNCTHING_RESCAN_INTERVAL_SECONDS=${MN_SYNCTHING_RESCAN_INTERVAL_SECONDS}
MN_BLUEPRINT_PYTHON_ENVS_DIR=${MN_BLUEPRINT_PYTHON_ENVS_DIR}
MN_HOST_OPENSHELL_STATE_DIR=${MN_HOST_OPENSHELL_STATE_DIR}
MN_MEMBRANE_SOURCE_MODE=$(mn_selected_membrane_source_mode)
ENGINE_IMAGE=${membrane_engine_image}
MN_MEMBRANE_ENGINE_IMAGE=${membrane_engine_image}
MN_MEMBRANE_ENGINE_IMAGE_TAG=${membrane_engine_tag}
MN_REDIS_IMAGE=${MN_REDIS_IMAGE:-$MN_DEFAULT_REDIS_IMAGE}
MN_CONTEXT_AUTH_TOKEN=${context_auth_token}
MN_CONTEXT_MODEL_COMPRESSION_ENABLED=true
MN_CONTEXT_OBSERVABILITY=${MN_CONTEXT_OBSERVABILITY:-false}
MN_CONTEXT_TOKEN_COUNTER_FACTORY=${MN_CONTEXT_TOKEN_COUNTER_FACTORY:-}
MN_LLM_MODEL_RUNNER_MODEL=${MN_LLM_MODEL_RUNNER_MODEL:-$MN_DEFAULT_LLM_MODEL_RUNNER_MODEL}
MN_GRPC_BIND_HOST=${MN_GRPC_BIND_HOST:-127.0.0.1}
MN_GRPC_PORT=${MN_GRPC_PORT:-55051}
MN_GRPC_TARGET=${MN_GRPC_TARGET:-localhost:${MN_GRPC_PORT:-55051}}
MN_GRPC_ADVERTISE_PORT=${MN_GRPC_ADVERTISE_PORT:-${MN_GRPC_PORT:-55051}}
MN_NATIVE_SDK_GRPC_HOST=${MN_NATIVE_SDK_GRPC_HOST:-0.0.0.0}
MN_NATIVE_SDK_GRPC_PORT=${MN_NATIVE_SDK_GRPC_PORT:-55052}
MN_NATIVE_SDK_GRPC_ADVERTISE_HOST=${MN_NATIVE_SDK_GRPC_ADVERTISE_HOST:-${MN_NETWORK_ADVERTISE_HOST:-}}
MN_NATIVE_SDK_GRPC_ADVERTISE_PORT=${MN_NATIVE_SDK_GRPC_ADVERTISE_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_NATIVE_SDK_GRPC_TARGET=${MN_NATIVE_SDK_GRPC_TARGET:-mn-native-sdk-grpc:55052}
MN_RESOURCE_GC_ENABLED=${MN_RESOURCE_GC_ENABLED:-true}
MN_RESOURCE_GC_INTERVAL_SECONDS=${MN_RESOURCE_GC_INTERVAL_SECONDS:-1800}
MN_RESOURCE_GC_ORPHAN_GRACE_SECONDS=${MN_RESOURCE_GC_ORPHAN_GRACE_SECONDS:-3600}
MN_RESOURCE_GC_BATCH_SIZE=${MN_RESOURCE_GC_BATCH_SIZE:-100}
MN_DOCKER_WORKER_IMAGE_CACHE_TTL_SECONDS=${MN_DOCKER_WORKER_IMAGE_CACHE_TTL_SECONDS:-604800}
MN_DOCKER_WORKER_IMAGE_CACHE_MAX_BYTES=${MN_DOCKER_WORKER_IMAGE_CACHE_MAX_BYTES:-21474836480}
MN_NATIVE_SDK_GRPC_PROXY_PORT=${MN_NATIVE_SDK_GRPC_PROXY_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_NATIVE_SDK_GRPC_PROXY_TARGET_HOST=${MN_NATIVE_SDK_GRPC_PROXY_TARGET_HOST:-host.containers.internal}
MN_NATIVE_SDK_GRPC_PROXY_TARGET_PORT=${MN_NATIVE_SDK_GRPC_PROXY_TARGET_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_LITELLM_GATEWAY_BIND_HOST=${litellm_gateway_bind_host}
MN_LITELLM_GATEWAY_PORT=${MN_LITELLM_GATEWAY_PORT:-4000}
MN_LITELLM_GATEWAY_INTERNAL_API_BASE=${MN_LITELLM_GATEWAY_INTERNAL_API_BASE:-http://mn-litellm-proxy:4000/v1}
MN_API_HOST=${api_host}
MN_API_PORT=${MN_API_PORT:-54001}
MN_DIST_PORT=${MN_DIST_PORT:-54370}
MN_WEB_UI_HOST=${MN_WEB_UI_HOST:-localhost}
MN_WEB_UI_PORT=${MN_WEB_UI_PORT:-55173}
MN_WEB_UI_BIND_HOST=${MN_WEB_UI_BIND_HOST:-127.0.0.1}
MN_WEB_UI_NPM_REGISTRY=${MN_WEB_UI_NPM_REGISTRY:-https://${MN_GAR_LOCATION:-$MN_DEFAULT_PYTHON_GAR_LOCATION}-npm.pkg.dev/${MN_GAR_PROJECT:-$MN_DEFAULT_CORE_GAR_PROJECT}/${MN_GAR_NPM_REPOSITORY:-$MN_DEFAULT_WEB_UI_GAR_NPM_REPOSITORY}/}
MN_WEB_UI_SOURCE_MODE=${MN_WEB_UI_SOURCE_MODE}
MN_WEB_UI_SOURCE_MOUNT=${MN_WEB_UI_SOURCE_MOUNT}
MN_WEB_UI_PACKAGE_VERSION=${MN_WEB_UI_PACKAGE_VERSION}
MN_BLUEPRINT_WEB_UI_BIND_HOST=${MN_BLUEPRINT_WEB_UI_BIND_HOST:-0.0.0.0}
MN_BLUEPRINT_WEB_UI_PUBLIC_HOST=${MN_BLUEPRINT_WEB_UI_PUBLIC_HOST:-localhost}
${runtime_port_settings}
MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE=${MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE:-prepublished}
MN_ENV=${MN_ENV:-prod}
MN_USE_LOCAL_SKILLS=${MN_USE_LOCAL_SKILLS}
MN_BLUEPRINT_SOURCE=${MN_BLUEPRINT_SOURCE:-github}
MN_BLUEPRINT_REPO=${MN_BLUEPRINT_REPO:-https://github.com/MirrorNeuronLab/mn-blueprints.git}
MN_BLUEPRINT_LOCAL=${MN_BLUEPRINT_LOCAL:-}
MN_WORKSPACE_ROOT=${MN_WORKSPACE_ROOT:-}
MN_CONNECT_URL=${MN_CONNECT_URL:-}
MN_AGENTS_ROOT=${runtime_agents_root}
MN_SKILLS_ROOT=${runtime_skills_root}
MN_PACKAGE_INDEX_FILE=${runtime_package_index}
MN_PIP_INDEX_URL=${MN_PIP_INDEX_URL:-${MN_PYTHON_INDEX_URL:-${MN_DEFAULT_PIP_INDEX_URL}}}
MN_PIP_EXTRA_INDEX_URL=${MN_PIP_EXTRA_INDEX_URL:-${MN_PYTHON_EXTRA_INDEX_URL:-https://pypi.org/simple}}
MN_RUNTIME_MODULE_VERSION=${MN_RUNTIME_MODULE_VERSION:-${MN_PACKAGE_VERSION:-}}
MN_CONTEXT_MEMORY_ENABLED=${context_memory_enabled}
OTTERDESK_CONTEXT_MEMORY_ENABLED=${otterdesk_context_memory_enabled}
MN_RUNS_ROOT=${MN_RUNS_ROOT:-}
MN_DOCKER_NETWORK_MODE=${MN_DOCKER_NETWORK_MODE:-bridge}
MN_DOCKER_NETWORK_NAME=${network_name}
MN_DOCKER_NETWORK_EXTERNAL=${network_external}
MN_DOCKER_NETWORK_DRIVER=${MN_DOCKER_NETWORK_DRIVER:-bridge}
MN_DOCKER_NETWORK_ATTACHABLE=${MN_DOCKER_NETWORK_ATTACHABLE:-false}
MN_DOCKER_WORKER_ENABLED=${MN_DOCKER_WORKER_ENABLED:-1}
MN_NODE_ALIAS=${MN_NODE_ALIAS:-}
MN_NODE_NAME=${MN_NODE_NAME:-}
MN_NODE_ROLE=${MN_NODE_ROLE:-runtime}
MN_CLUSTER_NODES=${MN_CLUSTER_NODES:-}
MN_NETWORK_JOIN_TOKEN=${network_token}
MN_REDIS_PASSWORD=${redis_password}
MN_REDIS_URL=${MN_REDIS_URL:-redis://:${redis_password}@redis:6379/0}
MN_REDIS_HA_MODE=${MN_REDIS_HA_MODE:-single}
MN_REDIS_SENTINELS=${MN_REDIS_SENTINELS:-}
MN_REDIS_SENTINEL_MASTER=${MN_REDIS_SENTINEL_MASTER:-mirror-neuron}
MN_REDIS_SENTINEL_HOST_MAP=${MN_REDIS_SENTINEL_HOST_MAP:-}
MN_REDIS_DB=${MN_REDIS_DB:-0}
MN_REDIS_USERNAME=${MN_REDIS_USERNAME:-}
MN_REDIS_SENTINEL_USERNAME=${MN_REDIS_SENTINEL_USERNAME:-}
MN_REDIS_SENTINEL_PASSWORD=${MN_REDIS_SENTINEL_PASSWORD:-${redis_password}}
MN_REDIS_WAIT_REPLICAS=${MN_REDIS_WAIT_REPLICAS:-0}
MN_REDIS_WAIT_TIMEOUT_MS=${MN_REDIS_WAIT_TIMEOUT_MS:-100}
MN_REDIS_RECONNECT_ATTEMPTS=${MN_REDIS_RECONNECT_ATTEMPTS:-10}
MN_REDIS_RECONNECT_BACKOFF_MS=${MN_REDIS_RECONNECT_BACKOFF_MS:-250}
MN_REDIS_RECONNECT_MAX_BACKOFF_MS=${MN_REDIS_RECONNECT_MAX_BACKOFF_MS:-2000}
ERL_EPMD_ADDRESS=${ERL_EPMD_ADDRESS:-0.0.0.0}
ERL_AFLAGS=${ERL_AFLAGS:--kernel inet_dist_listen_min ${MN_DIST_PORT:-54370} inet_dist_listen_max ${MN_DIST_PORT:-54370}}
$(mn_openshell_plugin_env)
MN_SYNCTHING_UID=${MN_SYNCTHING_UID}
MN_SYNCTHING_GID=${MN_SYNCTHING_GID}
PODMAN_HOST_SOCKET=${PODMAN_HOST_SOCKET}
COMPOSE_PARALLEL_LIMIT=${COMPOSE_PARALLEL_LIMIT:-1}
MN_COOKIE=${mn_cookie}
MN_GRPC_AUTH_TOKEN=${grpc_auth_token}
MN_GRPC_ADMIN_TOKEN=${grpc_admin_token}
EOF
    chmod 600 "$RUNTIME_COMPOSE_ENV" 2>/dev/null || true
  }

  if [ "$MN_RUNTIME_ONLY" = "Y" ]; then
    for arg in "${MN_INSTALL_ARGS[@]:-}"; do
      case "$arg" in
      --cli | --api | --web-ui)
        print_error "${arg} conflicts with --runtime-only."
        return 1
        ;;
      esac
    done
    INSTALL_CLI="N"
    INSTALL_API="N"
    INSTALL_WEB_UI="N"
    NON_INTERACTIVE="Y"
  fi
  INSTALL_PYTHON_SDK="Y"

  mn_prepare_installer_paths
  print_header

  if [ "$NON_INTERACTIVE" != "Y" ]; then
    printf '\nChoose components. Press Enter to accept each default.\n' >&3
    INSTALL_WEB_UI=$(ask "Install the Web UI?" "$INSTALL_WEB_UI")
    INSTALL_REDIS=$(ask "Enable Redis?" "$INSTALL_REDIS")
    if [ "$MN_BUILD_MEMBRANE" != "Y" ]; then
      INSTALL_CONTEXT_ENGINE=$(ask "Enable the Membrane context engine?" "$INSTALL_CONTEXT_ENGINE")
    fi
    INSTALL_PYTHON_SDK=$(ask "Install the Python SDK?" "$INSTALL_PYTHON_SDK")
    INSTALL_AGENTS=$(ask "Install agent packages?" "$INSTALL_AGENTS")
    INSTALL_CLI=$(ask "Install the CLI?" "$INSTALL_CLI")
    INSTALL_API=$(ask "Install the API?" "$INSTALL_API")
    START_NOW=$(ask "Start the runtime after installation?" "$START_NOW")
    echo "" >&3
  fi

  validate_selections

  if [ "$MN_EXISTING_INSTALL" = "Y" ]; then
    if [ "$MN_INSTALL_RESET" = "Y" ]; then
      REINSTALL="Y"
    else
      print_step "Refreshing the existing installation."
      REINSTALL=$(ask "Reinstall the existing installation?" "$REINSTALL")
    fi
    if [ "$REINSTALL" = "N" ]; then
      print_warning "Installation cancelled."
      exit 0
    fi
  fi

  mn_print_install_summary
  mn_report_system
  require_cmd curl
  mn_install_client_stage

  mn_begin_runtime_install || return 1
  if should_install_python_packages; then
    mn_ensure_python_package_index_file
    resolve_python_runtime
    ensure_pip
  fi
  if [ "$MN_EXISTING_INSTALL" = "Y" ]; then mn_remove_existing_install_paths; fi

  print_step "Installing MirrorNeuron Core ${CORE_INSTALL_VERSION}"
  (install_core_from_release) &
  spinner $! "Installing Core runtime"
  print_step "Writing Compose runtime configuration"
  write_runtime_compose_files

  if should_install_python_packages; then
    print_step "Installing selected Python packages and dependencies"
    (install_python_packages) &
    spinner $! "Installing Python packages"
  else
    print_step "Python component installation disabled by selection."
  fi

  mn_prepare_native_web_assets
  mn_configure_installed_runtime

  print_detail "SDK ${PYTHON_SDK_INSTALL_VERSION}; CLI ${CLI_INSTALL_VERSION}; API ${API_INSTALL_VERSION}; Web UI ${WEB_UI_INSTALL_VERSION}"
  if [ "$INSTALL_CLI" = "Y" ]; then
    print_detail "CLI: mn"
  fi
  if [ "$INSTALL_API" = "Y" ]; then
    print_detail "API: mn-api"
  fi
  mn_finish_runtime_install
  mn_print_install_complete
}

# Ordinary installers and CLI starts share the same lock as reset. The owner
# stamp remains outside MN_HOME so deleting that tree cannot release the fence.
if [ "$MN_INSTALL_HELP_REQUESTED" != "Y" ] && { [ "$MN_INSTALL_RESET" != "Y" ] || [ "$MN_NO_RUNTIME" = "Y" ]; }; then
  mkdir -p "$(dirname "$MN_HOME")"
  MN_RUNTIME_LIFECYCLE_LOCK="$(cd "$(dirname "$MN_HOME")" && pwd -P)/.$(basename "$MN_HOME").lifecycle.lock"
  mn_reset_acquire_lock_directory "$MN_RUNTIME_LIFECYCLE_LOCK"
  MN_RESET_OWNER_PID="$$"
  MN_INSTALL_OWNER_PID="$$"
  export MN_INSTALL_OWNER_PID
  trap mn_reset_release_lock EXIT
fi

if [ "$MN_NO_RUNTIME" = Y ] && [ "$MN_INSTALL_HELP_REQUESTED" != Y ]; then
  mn_install_client ${MN_INSTALL_ARGS[@]+"${MN_INSTALL_ARGS[@]}"}
  exit
fi

if [ "$MN_INSTALL_HELP_REQUESTED" != "Y" ]; then
  mn_validate_membrane_build
fi

if [ "$MN_INSTALL_RESET" = "Y" ] && [ "$MN_INSTALL_HELP_REQUESTED" != "Y" ] && [ "$MN_NO_RUNTIME" != "Y" ]; then
  mn_reset_install_state
  mn_reset_drop_conflicting_install_args
fi

if [ "${#MN_INSTALL_ARGS[@]}" -eq 0 ]; then
  case "$MN_INSTALL_MODE" in
  github) run_install_github ;;
  local) run_install_local ;;
  binary) run_install_binary ;;
  esac
else
  case "$MN_INSTALL_MODE" in
  github) run_install_github "${MN_INSTALL_ARGS[@]}" ;;
  local) run_install_local "${MN_INSTALL_ARGS[@]}" ;;
  binary) run_install_binary "${MN_INSTALL_ARGS[@]}" ;;
  esac
fi
