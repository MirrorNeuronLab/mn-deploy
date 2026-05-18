#!/usr/bin/env bash

set -euo pipefail

# Keep installer output visible even when a subcommand redirects stdout/stderr.
exec 3>&1

BOLD="\033[1m"
DIM="\033[2m"
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
MAGENTA="\033[35m"
RESET="\033[0m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

INSTALL_DIR="${HOME}/.mirror_neuron"
BIN_DIR="${HOME}/.local/bin"
VENV_DIR="${HOME}/.local/share/mn_venv"
UI_LINK_DIR="${INSTALL_DIR}_ui"

CORE_DIR="${WORKSPACE_DIR}/MirrorNeuron"
CLI_DIR="${WORKSPACE_DIR}/mn-cli"
API_DIR="${WORKSPACE_DIR}/mn-api"
PY_SDK_DIR="${WORKSPACE_DIR}/mn-python-sdk"
WEB_UI_DIR="${WORKSPACE_DIR}/mn-web-ui"
SKILLS_DIR="${WORKSPACE_DIR}/mn-skills"
BLUEPRINTS_DIR="${WORKSPACE_DIR}/mn-blueprints"
DOCS_DIR="${WORKSPACE_DIR}/mn-docs"
SYSTEM_TESTS_DIR="${WORKSPACE_DIR}/mn-system-tests"
MN_PYTHON_BIN=""
MN_MANAGED_PYTHON="${MN_MANAGED_PYTHON:-1}"
MN_MANAGED_PYTHON_VERSION="${MN_MANAGED_PYTHON_VERSION:-3.11}"
MN_MANAGED_PYTHON_ROOT="${MN_MANAGED_PYTHON_DIR:-${HOME}/.local/share/mn_python}"
MN_UV_ROOT="${MN_UV_DIR:-${HOME}/.local/share/mn_uv}"
MN_UV_BIN=""

INSTALL_WEB_UI="Y"
INSTALL_REDIS="Y"
INSTALL_OPENSHELL="Y"
INSTALL_SKILLS="Y"
START_NOW="N"
NON_INTERACTIVE="N"

function print_header() {
    echo -e "${MAGENTA}${BOLD}" >&3
    echo "  __  __ _                     _   _                           " >&3
    echo " |  \/  (_)_ __ _ __ ___  _ __| \ | | ___ _   _ _ __ ___  _ __ " >&3
    echo " | |\/| | | '__| '__/ _ \| '__|  \| |/ _ \ | | | '__/ _ \| '_ \\" >&3
    echo " | |  | | | |  | | | (_) | |  | |\  |  __/ |_| | | | (_) | | | |" >&3
    echo " |_|  |_|_|_|  |_|  \___/|_|  |_| \_|\___|\__,_|_|  \___/|_| |_|" >&3
    echo -e "${RESET}" >&3
    echo -e "${BLUE}${BOLD} => MirrorNeuron Local Workspace Installer${RESET}\n" >&3
}

function print_step() { echo -e "${CYAN}${BOLD}==>${RESET} ${BOLD}$1${RESET}" >&3; }
function print_success() { echo -e "${GREEN}${BOLD}==>${RESET} ${GREEN}$1${RESET}" >&3; }
function print_error() { echo -e "${RED}${BOLD}==>${RESET} ${RED}$1${RESET}" >&3; }
function print_warning() { echo -e "${YELLOW}${BOLD}==>${RESET} ${YELLOW}$1${RESET}" >&3; }

function run_quiet() {
    local label="$1"
    shift
    local log_dir="${TMPDIR:-/tmp}/mirror_neuron_install"
    mkdir -p "$log_dir"
    local log_file="${log_dir}/${label//[^A-Za-z0-9_.-]/_}.$$.log"

    if ! "$@" >"$log_file" 2>&1; then
        print_error "$label failed. Log: $log_file"
        tail -n 20 "$log_file" >&3 2>/dev/null || true
        exit 1
    fi
}

function python_version() {
    "$1" -c 'import sys; print(".".join(str(part) for part in sys.version_info[:3]))' 2>/dev/null
}

function python_is_supported() {
    "$1" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1
}

function python_minor_version() {
    "$1" -c 'import sys; print(".".join(str(part) for part in sys.version_info[:2]))' 2>/dev/null
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
        0|false|FALSE|False|no|NO|No|n|N) return 1 ;;
        *) return 0 ;;
    esac
}

function validate_managed_python_version() {
    if [[ ! "$MN_MANAGED_PYTHON_VERSION" =~ ^[0-9]+[.][0-9]+$ ]]; then
        print_error "MN_MANAGED_PYTHON_VERSION must be a Python minor version like 3.11."
        exit 1
    fi
}

function install_uv() {
    local os uv_bin_dir installer
    os="$(uname -s)"

    case "$os" in
        Darwin|Linux) ;;
        *)
            print_error "Unsupported platform for uv-managed Python: ${os}."
            print_error "Set MN_PYTHON=/path/to/python3.11 and rerun."
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
        print_error "Install uv manually or set MN_PYTHON=/path/to/python3.11."
        exit 1
    fi

    if ! UV_UNMANAGED_INSTALL="$uv_bin_dir" sh "$installer" >/dev/null 2>&1; then
        rm -f "$installer"
        print_error "Could not install uv."
        print_error "Install uv manually or set MN_PYTHON=/path/to/python3.11."
        exit 1
    fi
    rm -f "$installer"

    MN_UV_BIN="$uv_bin_dir/uv"
    if [ ! -x "$MN_UV_BIN" ]; then
        print_error "uv installer did not create $MN_UV_BIN."
        exit 1
    fi

    print_success "Installed uv at $MN_UV_BIN."
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
    [ -x "$python_bin" ] && \
    python_is_supported "$python_bin" && \
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
    print_warning "No Python 3.11+ interpreter was found; uv will manage a private runtime under ${MN_MANAGED_PYTHON_ROOT}."
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

    MN_PYTHON_BIN="$managed_bin"
    print_success "Using uv-managed Python $(python_version "$managed_bin") at $managed_bin."
}

function print_python_requirement_error() {
    local selected="${1:-}"
    local version=""

    print_error "MirrorNeuron Python components require Python 3.11 or newer."
    if [ -n "$selected" ]; then
        version="$(python_version "$selected" || true)"
        if [ -n "$version" ]; then
            print_error "Selected Python '$selected' is version $version."
        else
            print_error "Selected Python '$selected' could not be run."
        fi
    fi
    print_error "Install Python 3.11 yourself, or allow the uv-managed private runtime fallback."
    print_error "You can also rerun with: MN_PYTHON=/opt/homebrew/bin/python3.11 ./$(basename "$0")"
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
        candidates+=(python3.11 python3.12 python3)
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
        if python_is_supported "$resolved"; then
            MN_PYTHON_BIN="$resolved"
            print_success "Using Python $(python_version "$MN_PYTHON_BIN") at $MN_PYTHON_BIN."
            return
        fi
        if [ -n "${MN_PYTHON:-}" ]; then
            print_python_requirement_error "$resolved"
            exit 1
        fi
    done

    resolved="$(command -v python3 2>/dev/null || true)"
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
Usage: ./install_local.sh [options]

Installs MirrorNeuron from local sibling folders under:
  ${WORKSPACE_DIR}

Options:
  --yes                 Run non-interactively with defaults.
  --no-web-ui           Skip local Web UI npm install/build.
  --no-redis            Skip Redis Docker setup.
  --openshell           Install/start OpenShell gateway for sandbox workers.
  --no-openshell        Skip OpenShell gateway setup.
  --no-skills           Skip editable install of packages under mn-skills.
  --start               Start MirrorNeuron after install.
  --no-managed-python   Do not use uv to install a private Python runtime.
  MN_PYTHON=/path       Use a specific Python 3.11+ interpreter.
  MN_MANAGED_PYTHON=0   Disable uv-managed private Python fallback.
  -h, --help            Show this help.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --yes) NON_INTERACTIVE="Y" ;;
        --no-reinstall) ;; # Backward-compatible no-op; local installs refresh in place.
        --no-web-ui) INSTALL_WEB_UI="N" ;;
        --no-redis) INSTALL_REDIS="N" ;;
        --openshell) INSTALL_OPENSHELL="Y" ;;
        --no-openshell) INSTALL_OPENSHELL="N" ;;
        --no-skills) INSTALL_SKILLS="N" ;;
        --start) START_NOW="Y" ;;
        --no-managed-python) MN_MANAGED_PYTHON=0 ;;
        -h|--help) usage; exit 0 ;;
        *)
            print_error "Unknown option: $arg"
            usage
            exit 1
            ;;
    esac
done

function spinner() {
    local pid=$1
    local msg=$2
    local delay=0.1
    local spinstr='|/-\'
    tput civis >&3 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf "\r${MAGENTA}${BOLD}[%c]${RESET} %s" "$spinstr" "$msg" >&3
        spinstr=$temp${spinstr%"$temp"}
        sleep "$delay"
    done
    set +e
    wait "$pid"
    local exit_code=$?
    set -e
    if [ "$exit_code" -eq 0 ]; then
        printf "\r${GREEN}${BOLD}[OK]${RESET} %s                               \n" "$msg" >&3
    else
        printf "\r${RED}${BOLD}[ERR]${RESET} %s                               \n" "$msg" >&3
        tput cnorm >&3 2>/dev/null || true
        exit "$exit_code"
    fi
    tput cnorm >&3 2>/dev/null || true
}

function ask() {
    local prompt="$1"
    local default="$2"
    local answer

    if [ "$NON_INTERACTIVE" = "Y" ]; then
        echo "$default"
        return
    fi

    if [ "$default" = "Y" ]; then
        prompt="${prompt} [Y/n]: "
    elif [ "$default" = "N" ]; then
        prompt="${prompt} [y/N]: "
    else
        prompt="${prompt} [${default}]: "
    fi

    echo -ne "${BLUE}${BOLD}?${RESET} ${prompt}" >&3
    if [ -c /dev/tty ]; then
        read -r answer < /dev/tty
    else
        read -r answer
    fi

    if [ -z "$answer" ]; then
        answer="$default"
    fi

    answer=$(echo "$answer" | tr '[:upper:]' '[:lower:]')
    case "$answer" in
        y|yes) echo "Y" ;;
        n|no) echo "N" ;;
        *) echo "$answer" ;;
    esac
}

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
    cat > "$metadata_file" <<EOF
{
  "install_type": "local_source",
  "source_workspace": "${WORKSPACE_DIR}",
  "updated_at": "${updated_at}"
}
EOF
}

function core_container_running() {
    docker ps --format '{{.Names}}' | grep -q '^mirror-neuron-core$'
}

function generate_mn_cookie() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
    fi
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
        cookie="$(tr -d '[:space:]' < "$cookie_file")"
        if [ -n "$cookie" ] && [ "$cookie" != "mirrorneuron" ]; then
            chmod 600 "$cookie_file" 2>/dev/null || true
            printf '%s\n' "$cookie"
            return 0
        fi
    fi

    cookie="$(generate_mn_cookie)"
    if [ -z "$cookie" ]; then
        print_error "Failed to generate MN_COOKIE."
        exit 1
    fi

    printf '%s\n' "$cookie" > "$cookie_file"
    chmod 600 "$cookie_file" 2>/dev/null || true
    printf '%s\n' "$cookie"
}

function start_core_container() {
    local cmd=("docker" "run" "-d" "--name" "mirror-neuron-core")
    local openshell_config_dir="$HOME/.config/openshell"
    local openshell_container_config_dir="${OPENSHELL_CONTAINER_CONFIG_DIR:-$HOME/.config/openshell-mirror-neuron}"
    local openshell_mount_dir="$openshell_config_dir"
    local core_host="${MN_CORE_HOST:-localhost}"
    local redis_host="${MN_REDIS_HOST:-localhost}"
    local epmd_host="${MN_EPMD_HOST:-localhost}"
    local dist_host="${MN_DIST_HOST:-localhost}"
    local core_publish_host="$core_host"
    local epmd_publish_host="$epmd_host"
    local dist_publish_host="$dist_host"
    local mn_cookie
    mn_cookie="$(resolve_mn_cookie)"
    [ "$core_publish_host" = "localhost" ] && core_publish_host="127.0.0.1"
    [ "$epmd_publish_host" = "localhost" ] && epmd_publish_host="127.0.0.1"
    [ "$dist_publish_host" = "localhost" ] && dist_publish_host="127.0.0.1"

    cmd+=("-e" "MN_COOKIE=${mn_cookie}")
    if [ -n "${MN_NODE_NAME:-}" ]; then
        cmd+=("-e" "MN_NODE_NAME=${MN_NODE_NAME}")
    fi

    if [ "$(uname -s)" = "Darwin" ]; then
        cmd+=("-p" "${core_publish_host}:50051:50051" "-p" "${epmd_publish_host}:4369:4369")
        for port in $(seq 9000 9010); do
            cmd+=("-p" "${dist_publish_host}:${port}:${port}")
        done
        cmd+=("-e" "MN_REDIS_URL=redis://host.docker.internal:6379/0")
        cmd+=("-e" "MN_CORE_HOST=0.0.0.0")
        cmd+=("-e" "MN_EXECUTOR_MAX_CONCURRENCY=50")
    else
        cmd+=("--network" "host")
        cmd+=("-e" "MN_CORE_HOST=${core_host}")
        cmd+=("-e" "MN_REDIS_HOST=${redis_host}")
        cmd+=("-e" "ERL_EPMD_ADDRESS=${epmd_host}")
        cmd+=("-e" "MN_EXECUTOR_MAX_CONCURRENCY=50")
    fi

    if [ -d "$openshell_container_config_dir/gateways/openshell" ]; then
        openshell_mount_dir="$openshell_container_config_dir"
    fi
    if [ -d "$openshell_mount_dir/gateways/openshell" ]; then
        cmd+=("-v" "$openshell_mount_dir:/root/.config/openshell:ro")
        cmd+=("-v" "$openshell_mount_dir:/opt/mirror_neuron/.config/openshell:ro")
    fi

    for env_name in \
        SLACK_BOT_TOKEN \
        SLACK_DEFAULT_CHANNEL \
        SLACK_API_BASE_URL \
        MN_SLACK_BOT_TOKEN \
        MN_SLACK_DEFAULT_CHANNEL \
        MN_SLACK_API_BASE_URL; do
        if [ -n "${!env_name:-}" ]; then
            cmd+=("-e" "$env_name")
        fi
    done

    cmd+=("mirror-neuron-core:latest")
    "${cmd[@]}" >/dev/null
}

function restart_core_container() {
    docker rm -f mirror-neuron-core >/dev/null 2>&1 || true
    start_core_container
}

function resolve_openshell_bin() {
    if [ -n "${OPENSHELL_BIN:-}" ]; then
        if [ -x "$OPENSHELL_BIN" ]; then
            printf '%s\n' "$OPENSHELL_BIN"
            return 0
        fi
        if command -v "$OPENSHELL_BIN" >/dev/null 2>&1; then
            command -v "$OPENSHELL_BIN"
            return 0
        fi
    fi

    if command -v openshell >/dev/null 2>&1; then
        command -v openshell
        return 0
    fi

    if [ -x "$BIN_DIR/openshell" ]; then
        printf '%s\n' "$BIN_DIR/openshell"
        return 0
    fi

    if [ -x "$HOME/.local/bin/openshell" ]; then
        printf '%s\n' "$HOME/.local/bin/openshell"
        return 0
    fi

    return 1
}

function prepare_openshell_container_config() {
    local gateway_host="$1"
    local gateway_port="$2"
    local source_root="$HOME/.config/openshell"
    local source_gateway_dir="$source_root/gateways/openshell"
    local target_root="${OPENSHELL_CONTAINER_CONFIG_DIR:-$HOME/.config/openshell-mirror-neuron}"
    local target_gateway_dir="$target_root/gateways/openshell"

    if [ -z "$gateway_host" ]; then
        return 0
    fi

    if [ ! -d "$source_gateway_dir/mtls" ]; then
        return 1
    fi

    rm -rf "$target_root"
    mkdir -p "$target_gateway_dir"
    cp "$source_root/active_gateway" "$target_root/active_gateway"
    cp -R "$source_gateway_dir/mtls" "$target_gateway_dir/mtls"
    if [ -f "$source_gateway_dir/last_sandbox" ]; then
        cp "$source_gateway_dir/last_sandbox" "$target_gateway_dir/last_sandbox"
    fi
    cat > "$target_gateway_dir/metadata.json" <<EOF
{
  "name": "openshell",
  "gateway_endpoint": "https://${gateway_host}:${gateway_port}",
  "is_remote": false,
  "gateway_port": ${gateway_port}
}
EOF
}

function setup_openshell_gateway() {
    local version="${OPENSHELL_VERSION:-v0.0.16}"
    local image_tag="${OPENSHELL_GATEWAY_IMAGE_TAG:-${version#v}}"
    local gateway_image="${OPENSHELL_GATEWAY_IMAGE:-ghcr.io/nvidia/openshell/cluster:${image_tag}}"
    local gateway_port="${OPENSHELL_GATEWAY_PORT:-8080}"
    local container_gateway_host="${OPENSHELL_GATEWAY_HOST:-}"
    local gateway_start_args=("gateway" "start" "--port" "$gateway_port")
    local openshell_bin

    if [ "$(uname -s)" = "Darwin" ] && [ -z "$container_gateway_host" ]; then
        container_gateway_host="host.docker.internal"
    fi

    if [ -d "$WORKSPACE_DIR/OpenShell" ] && [ -f "$WORKSPACE_DIR/OpenShell/Dockerfile" ]; then
        (
            cd "$WORKSPACE_DIR/OpenShell"
            docker build -t mirror-neuron-openshell:latest . >/dev/null
        )
    fi

    openshell_bin="$(resolve_openshell_bin || true)"
    if [ -z "$openshell_bin" ]; then
        local installer="${TMPDIR:-/tmp}/mirror_neuron_openshell_install.sh"
        curl -fLsS https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh -o "$installer"
        OPENSHELL_VERSION="$version" sh "$installer" >/dev/null
        rm -f "$installer"
        openshell_bin="$(resolve_openshell_bin || true)"
    fi

    if [ -z "$openshell_bin" ]; then
        print_error "OpenShell CLI install finished, but no openshell binary was found."
        print_error "Set OPENSHELL_BIN=/path/to/openshell and rerun."
        exit 1
    fi

    docker pull "$gateway_image" >/dev/null

    if "$openshell_bin" status >/dev/null 2>&1 && NO_COLOR=1 "$openshell_bin" sandbox list >/dev/null 2>&1; then
        prepare_openshell_container_config "$container_gateway_host" "$gateway_port"
        return
    fi

    "$openshell_bin" "${gateway_start_args[@]}" >/dev/null 2>&1 || true
    if ! NO_COLOR=1 "$openshell_bin" sandbox list >/dev/null 2>&1; then
        "$openshell_bin" "${gateway_start_args[@]}" --recreate >/dev/null
    fi
    NO_COLOR=1 "$openshell_bin" sandbox list >/dev/null
    prepare_openshell_container_config "$container_gateway_host" "$gateway_port"
}

function ensure_path_export() {
    if [[ ":$PATH:" == *":$BIN_DIR:"* ]]; then
        return
    fi

    print_warning "${BIN_DIR} is not in your PATH."
    local detected_profiles=()
    [ -f "$HOME/.zshrc" ] && detected_profiles+=("$HOME/.zshrc")
    [ -f "$HOME/.bashrc" ] && detected_profiles+=("$HOME/.bashrc")
    [ -f "$HOME/.bash_profile" ] && detected_profiles+=("$HOME/.bash_profile")
    [ -f "$HOME/.profile" ] && detected_profiles+=("$HOME/.profile")

    if [ "${#detected_profiles[@]}" -eq 0 ]; then
        detected_profiles+=("$HOME/.profile")
    fi

    for profile in "${detected_profiles[@]}"; do
        if ! grep -q "export PATH=\"$BIN_DIR:\$PATH\"" "$profile" 2>/dev/null; then
            echo "" >> "$profile"
            echo "# Added by MirrorNeuron local installer" >> "$profile"
            echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$profile"
            echo -e "Added PATH update to ${CYAN}${profile}${RESET}" >&3
        fi
    done
}

print_header

require_dir "$CORE_DIR" "MirrorNeuron core"
require_file "$CORE_DIR/Dockerfile" "MirrorNeuron Dockerfile"
require_dir "$CLI_DIR" "mn-cli"
require_dir "$API_DIR" "mn-api"
require_dir "$PY_SDK_DIR" "mn-python-sdk"

if [ "$INSTALL_WEB_UI" = "Y" ]; then require_dir "$WEB_UI_DIR" "mn-web-ui"; fi
if [ "$INSTALL_SKILLS" = "Y" ]; then require_dir "$SKILLS_DIR" "mn-skills"; fi

print_step "Checking Python runtime"
resolve_python_runtime

if [ -d "$INSTALL_DIR" ] || [ -L "$INSTALL_DIR" ] || [ -d "$VENV_DIR" ] || [ -f "$BIN_DIR/mn" ]; then
    print_warning "MirrorNeuron appears to be already installed; refreshing local source install."
fi

echo -e "${CYAN}${BOLD}Configuration${RESET}" >&3
if [ "$NON_INTERACTIVE" != "Y" ]; then
    INSTALL_WEB_UI=$(ask "Install/build local Web UI?" "$INSTALL_WEB_UI")
    INSTALL_REDIS=$(ask "Install/start Redis via Docker?" "$INSTALL_REDIS")
    INSTALL_SKILLS=$(ask "Install local mn-skills packages in editable mode?" "$INSTALL_SKILLS")
    INSTALL_OPENSHELL=$(ask "Install/start OpenShell gateway for sandbox workers?" "$INSTALL_OPENSHELL")
    START_NOW=$(ask "Start MirrorNeuron server automatically after install?" "$START_NOW")
fi
echo "" >&3

print_step "Checking dependencies"
for cmd in docker; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        print_error "'$cmd' is required but not installed."
        exit 1
    fi
done
if [ "$INSTALL_OPENSHELL" = "Y" ] && ! command -v curl >/dev/null 2>&1; then
    print_error "'curl' is required to install/start OpenShell."
    exit 1
fi
resolve_python_runtime

if [ "$INSTALL_WEB_UI" = "Y" ]; then
    if ! command -v npm >/dev/null 2>&1; then
        print_error "'npm' is required for local Web UI install."
        exit 1
    fi
fi

if ! docker info >/dev/null 2>&1; then
    print_error "Docker is not running. Please start Docker first."
    exit 1
fi
print_success "Dependencies look good."

CORE_WAS_RUNNING="N"
if core_container_running; then
    CORE_WAS_RUNNING="Y"
fi

print_step "Preparing local install state"
mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$INSTALL_DIR/.pids" "$INSTALL_DIR/.logs"

if [ -d "$BLUEPRINTS_DIR" ]; then replace_symlink "$BLUEPRINTS_DIR" "$INSTALL_DIR/blueprints"; fi
if [ -d "$SKILLS_DIR" ]; then replace_symlink "$SKILLS_DIR" "$INSTALL_DIR/skills"; fi
if [ -d "$DOCS_DIR" ]; then replace_symlink "$DOCS_DIR" "$INSTALL_DIR/docs"; fi
if [ -d "$SYSTEM_TESTS_DIR" ]; then replace_symlink "$SYSTEM_TESTS_DIR" "$INSTALL_DIR/system-tests"; fi
replace_symlink "$CORE_DIR" "$INSTALL_DIR/core-source"
replace_symlink "$CLI_DIR" "$INSTALL_DIR/cli-source"
replace_symlink "$API_DIR" "$INSTALL_DIR/api-source"
replace_symlink "$PY_SDK_DIR" "$INSTALL_DIR/python-sdk-source"
write_local_install_metadata
print_success "Local component links created under ${INSTALL_DIR}."

print_step "Building MirrorNeuron Core Docker image from local source"
(
    cd "$CORE_DIR"
    docker build -t mirror-neuron-core:latest . >/dev/null
) &
spinner $! "Built local core image mirror-neuron-core:latest"

print_step "Installing Python components from local source"
(
    "$MN_PYTHON_BIN" -m venv "$VENV_DIR" >/dev/null
    "$VENV_DIR/bin/pip" install --upgrade pip >/dev/null
    "$VENV_DIR/bin/pip" install -e "$PY_SDK_DIR" >/dev/null
    if [ -d "$SKILLS_DIR/blueprint_support_skill" ]; then
        "$VENV_DIR/bin/pip" install -e "$SKILLS_DIR/blueprint_support_skill[webui]" >/dev/null
    fi
    "$VENV_DIR/bin/pip" install -e "$CLI_DIR" >/dev/null
    "$VENV_DIR/bin/pip" install -e "$API_DIR" >/dev/null

    if [ "$INSTALL_SKILLS" = "Y" ]; then
        shopt -s nullglob
        for skill_pyproject in "$SKILLS_DIR"/*/pyproject.toml; do
            if [ "$(dirname "$skill_pyproject")" = "$SKILLS_DIR/blueprint_support_skill" ]; then
                continue
            fi
            "$VENV_DIR/bin/pip" install -e "$(dirname "$skill_pyproject")" >/dev/null
        done
    fi
) &
spinner $! "Installed local editable Python packages"

if [ "$INSTALL_WEB_UI" = "Y" ]; then
    print_step "Installing Web UI from local source"
    (
        cd "$WEB_UI_DIR"
        npm install >/dev/null
        npm run build >/dev/null
    ) &
    spinner $! "Installed and built local Web UI"
    if [ -e "$UI_LINK_DIR" ] || [ -L "$UI_LINK_DIR" ]; then
        rm -rf "$UI_LINK_DIR"
    fi
    replace_symlink "$WEB_UI_DIR" "$UI_LINK_DIR"
    replace_symlink "$WEB_UI_DIR" "$INSTALL_DIR/web-ui-source"
fi

if [ "$INSTALL_REDIS" = "Y" ]; then
    print_step "Setting up Redis"
    (
        if ! docker ps --format '{{.Names}}' | grep -q '^mirror-neuron-redis$'; then
            docker rm -f mirror-neuron-redis >/dev/null 2>&1 || true
            docker run -d --name mirror-neuron-redis -p 6379:6379 redis:7 >/dev/null
        fi
    ) &
    spinner $! "Redis container is available"
fi

if [ "$INSTALL_OPENSHELL" = "Y" ]; then
    print_step "Setting up OpenShell"
    ( setup_openshell_gateway ) &
    spinner $! "OpenShell gateway is available"
fi

if [ "$CORE_WAS_RUNNING" = "Y" ]; then
    print_step "Restarting MirrorNeuron gRPC Core from rebuilt image"
    (
        restart_core_container
    ) &
    spinner $! "Restarted MirrorNeuron gRPC Core"
fi

print_step "Creating command symlinks"
rm -f "$BIN_DIR/mn" "$BIN_DIR/mn-api" "$INSTALL_DIR/mn"
replace_symlink "$VENV_DIR/bin/mn" "$BIN_DIR/mn"
replace_symlink "$VENV_DIR/bin/mn-api" "$BIN_DIR/mn-api"
replace_symlink "$VENV_DIR/bin/mn" "$INSTALL_DIR/mn"
print_success "Symlinks created in ${BIN_DIR}."

ensure_path_export

echo "" >&3
print_success "MirrorNeuron local installation completed."
echo -e "Core image: ${YELLOW}mirror-neuron-core:latest${RESET} built from ${CYAN}${CORE_DIR}${RESET}" >&3
echo -e "CLI/API:    ${YELLOW}editable Python installs${RESET} from local workspace" >&3
echo -e "State dir:  ${CYAN}${INSTALL_DIR}${RESET}" >&3
echo -e "Cookie:     ${CYAN}${INSTALL_DIR}/erlang.cookie${RESET}" >&3
if [ "$INSTALL_WEB_UI" = "Y" ]; then
    echo -e "Web UI:     ${CYAN}${UI_LINK_DIR}${RESET} -> ${WEB_UI_DIR}" >&3
fi

echo -e "\n${BOLD}Quick Start:${RESET}" >&3
echo -e "  1. Start server: ${GREEN}mn start${RESET}" >&3
if [ "$INSTALL_WEB_UI" = "Y" ]; then
    echo -e "  2. Start UI:     ${GREEN}cd ${UI_LINK_DIR} && npm run dev${RESET}" >&3
fi
echo -e "  3. Use CLI:      ${GREEN}mn nodes${RESET}" >&3
echo -e "  4. Rebuild core after Elixir changes: ${GREEN}${SCRIPT_DIR}/install_local.sh --yes --no-web-ui --no-skills${RESET}\n" >&3

if [ "$START_NOW" = "Y" ]; then
    print_step "Starting MirrorNeuron Server"
    "$VENV_DIR/bin/mn" start
fi
