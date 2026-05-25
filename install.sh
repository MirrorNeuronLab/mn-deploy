#!/usr/bin/env bash

set -euo pipefail

# Keep installer output visible even when a subcommand redirects stdout/stderr.
exec 3>&1

# Never let git/pip block the installer by asking for GitHub credentials.
export GIT_TERMINAL_PROMPT="${GIT_TERMINAL_PROMPT:-0}"
export PIP_NO_INPUT="${PIP_NO_INPUT:-1}"

# Define Colors
BOLD="\033[1m"
DIM="\033[2m"
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
MAGENTA="\033[35m"
RESET="\033[0m"

MN_MANAGED_PYTHON="${MN_MANAGED_PYTHON:-1}"
MN_MANAGED_PYTHON_VERSION="${MN_MANAGED_PYTHON_VERSION:-3.11}"
MN_MANAGED_PYTHON_ROOT="${MN_MANAGED_PYTHON_DIR:-${HOME}/.local/share/mn_python}"
MN_UV_ROOT="${MN_UV_DIR:-${HOME}/.local/share/mn_uv}"
MN_UV_BIN=""

function print_header() {
    echo -e "${MAGENTA}${BOLD}" >&3
    echo "  __  __ _                     _   _                           " >&3
    echo " |  \/  (_)_ __ _ __ ___  _ __| \ | | ___ _   _ _ __ ___  _ __ " >&3
    echo " | |\/| | | '__| '__/ _ \| '__|  \| |/ _ \ | | | '__/ _ \| '_ \\" >&3
    echo " | |  | | | |  | | | (_) | |  | |\  |  __/ |_| | | | (_) | | | |" >&3
    echo " |_|  |_|_|_|  |_|  \___/|_|  |_| \_|\___|\__,_|_|  \___/|_| |_|" >&3
    echo -e "${RESET}" >&3
    echo -e "${BLUE}${BOLD} => Welcome to the MirrorNeuron Installer${RESET}\n" >&3
}

function print_step() { echo -e "${CYAN}${BOLD}==>${RESET} ${BOLD}$1${RESET}" >&3; }
function print_success() { echo -e "${GREEN}${BOLD}==>${RESET} ${GREEN}$1${RESET}" >&3; }
function print_error() { echo -e "${RED}${BOLD}==>${RESET} ${RED}$1${RESET}" >&3; }
function print_warning() { echo -e "${YELLOW}${BOLD}==>${RESET} ${YELLOW}$1${RESET}" >&3; }

function find_source_workspace() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    local candidates=()
    [ -n "${MN_SOURCE_DIR:-}" ] && candidates+=("$MN_SOURCE_DIR")
    candidates+=(
        "$PWD"
        "$(dirname "$PWD")"
        "$(dirname "$script_dir")"
        "$HOME/Projects/mirror-neuron-set"
    )

    local candidate
    for candidate in "${candidates[@]}"; do
        [ -n "$candidate" ] || continue
        if [ -d "$candidate/mn-python-sdk" ] &&
           { [ -d "$candidate/mn-skills/blueprint_support_skill" ] || [ -d "$candidate/mn-skills/blueprint-support-skill" ]; } &&
           [ -d "$candidate/mn-cli" ] &&
           [ -d "$candidate/mn-api" ]; then
            (cd "$candidate" && pwd)
            return 0
        fi
    done

    return 1
}

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

function spinner() {
    local pid=$1
    local msg=$2
    local delay=0.1
    local spinstr='|/-\'
    tput civis >&3 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf "\r${MAGENTA}${BOLD}[%c]${RESET} ${msg}" "$spinstr" >&3
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
    done
    set +e
    wait "$pid"
    local exit_code=$?
    set -e
    if [ "$exit_code" -eq 0 ]; then
        printf "\r${GREEN}${BOLD}[✔]${RESET} ${msg}                               \n" >&3
    else
        printf "\r${RED}${BOLD}[✖]${RESET} ${msg} (Failed)                      \n" >&3
        tput cnorm >&3 2>/dev/null || true
        exit $exit_code
    fi
    tput cnorm >&3 2>/dev/null || true
}

function ask() {
    local prompt="$1"
    local default="$2"
    local answer
    
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

function require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        print_error "'$cmd' is required but not installed."
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

    if managed_python_enabled; then
        install_managed_python
        print_success "Using Python $(python_version "$MN_PYTHON_BIN") at $MN_PYTHON_BIN."
        return
    fi

    print_warning "Managed Python fallback is disabled."
    resolved="$(command -v python3 2>/dev/null || true)"
    print_python_requirement_error "$resolved"
    exit 1
}

print_header

if [ -n "${MN_HOME:-}" ]; then
    export MIRROR_NEURON_HOME="$MN_HOME"
else
    export MIRROR_NEURON_HOME="${HOME}/.mn"
fi

INSTALL_DIR="${MIRROR_NEURON_HOME}"
BIN_DIR="${HOME}/.local/bin"
VENV_DIR="${HOME}/.local/share/mn_venv"
MN_PYTHON_BIN=""
SOURCE_WORKSPACE="$(find_source_workspace || true)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_COMPOSE_TEMPLATE="${SCRIPT_DIR}/docker-compose.yml"
RUNTIME_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
RUNTIME_COMPOSE_ENV="${INSTALL_DIR}/docker-compose.env"
LEGACY_UI_DIR="${INSTALL_DIR}_ui"
INSTALL_CONTEXT_ENGINE="Y"
MEMBRANE_REPO="${MN_MEMBRANE_REPO:-MirrorNeuronLab/Membrane}"
MEMBRANE_GIT_URL="${MN_MEMBRANE_GIT_URL:-}"
MEMBRANE_DIR="${MN_MEMBRANE_DIR:-${INSTALL_DIR}/Membrane}"
MN_HOST_MN_DIR="${MN_HOST_MN_DIR:-${INSTALL_DIR}}"
MN_HOST_OPENSHELL_CONFIG_DIR="${OPENSHELL_CONTAINER_CONFIG_DIR:-${HOME}/.config/openshell-mirror-neuron}"
MN_HOST_OPENSHELL_STATE_DIR="${MN_HOST_OPENSHELL_STATE_DIR:-${INSTALL_DIR}/openshell-state}"
OPENSHELL_GATEWAY_USER="${OPENSHELL_GATEWAY_USER:-$(id -u):$(id -g)}"
if [ -z "${DOCKER_HOST_SOCKET:-}" ]; then
    if [ -S "${HOME}/.docker/run/docker.sock" ]; then
        DOCKER_HOST_SOCKET="${HOME}/.docker/run/docker.sock"
    else
        DOCKER_HOST_SOCKET="/var/run/docker.sock"
    fi
fi
if [ -z "${OPENSHELL_GATEWAY_DOCKER_GROUP:-}" ] && [ "$(uname -s)" = "Darwin" ]; then
    OPENSHELL_GATEWAY_DOCKER_GROUP="0"
elif [ -z "${OPENSHELL_GATEWAY_DOCKER_GROUP:-}" ] && [ -S "${DOCKER_HOST_SOCKET}" ]; then
    OPENSHELL_GATEWAY_DOCKER_GROUP="$(stat -c '%g' "${DOCKER_HOST_SOCKET}" 2>/dev/null || stat -f '%g' "${DOCKER_HOST_SOCKET}" 2>/dev/null || true)"
fi
OPENSHELL_GATEWAY_DOCKER_GROUP="${OPENSHELL_GATEWAY_DOCKER_GROUP:-0}"
MN_DYNAMIC_REDIS_PORT_START="${MN_DYNAMIC_REDIS_PORT_START:-56379}"
MN_DYNAMIC_REDIS_PORT_END="${MN_DYNAMIC_REDIS_PORT_END:-56478}"

function context_engine_git_url() {
    if [ -n "$MEMBRANE_GIT_URL" ]; then
        printf '%s' "$MEMBRANE_GIT_URL"
    else
        printf 'https://github.com/%s.git' "$MEMBRANE_REPO"
    fi
}

function context_engine_source_dir() {
    if [ -n "$SOURCE_WORKSPACE" ] && [ -f "$SOURCE_WORKSPACE/Membrane/Dockerfile" ]; then
        printf '%s' "$SOURCE_WORKSPACE/Membrane"
        return 0
    fi
    if [ -n "${MN_MEMBRANE_DIR:-}" ] && [ -f "$MN_MEMBRANE_DIR/Dockerfile" ]; then
        printf '%s' "$MN_MEMBRANE_DIR"
        return 0
    fi
    if [ ! -d "$MEMBRANE_DIR" ]; then
        run_quiet "clone-membrane-context-engine" git clone "$(context_engine_git_url)" "$MEMBRANE_DIR"
    else
        (
            cd "$MEMBRANE_DIR"
            git pull --ff-only >/dev/null 2>&1 || true
        )
    fi
    printf '%s' "$MEMBRANE_DIR"
}

function setup_context_engine() {
    context_engine_source_dir >/dev/null
    remove_stale_runtime_containers_for_services context-engine-model membrane-context-engine
    runtime_compose build context-engine-model membrane-context-engine
    runtime_compose up -d context-engine-model membrane-context-engine >/dev/null
}

function context_model_target() {
    local requested="${MN_DOCKER_TARGET:-auto}"
    case "$requested" in
        cpu|mac|nvidia|amd|intel) echo "$requested"; return 0 ;;
        auto) ;;
        *) echo "cpu"; return 0 ;;
    esac

    if command -v nvidia-smi >/dev/null 2>&1; then
        echo "nvidia"
    elif [ -e /dev/kfd ] || command -v rocminfo >/dev/null 2>&1 || command -v rocm-smi >/dev/null 2>&1; then
        echo "amd"
    elif [ -e /dev/dri ] && { command -v sycl-ls >/dev/null 2>&1 || lspci 2>/dev/null | grep -Eiq 'intel.*(vga|3d|display)'; }; then
        echo "intel"
    elif [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ]; then
        echo "mac"
    else
        echo "cpu"
    fi
}

function context_model_build_target() {
    case "$1" in
        mac) echo "mac-arm64-context-model" ;;
        nvidia) echo "nvidia-context-model" ;;
        amd) echo "amd-context-model" ;;
        intel) echo "intel-context-model" ;;
        *) echo "context-model-cpu" ;;
    esac
}

function context_model_image() {
    case "$1" in
        mac) echo "mirror-neuron-context-model:mac-arm64" ;;
        nvidia) echo "mirror-neuron-context-model:nvidia" ;;
        amd) echo "mirror-neuron-context-model:amd" ;;
        intel) echo "mirror-neuron-context-model:intel" ;;
        *) echo "mirror-neuron-context-model:cpu" ;;
    esac
}

function compose_profiles() {
    local profiles=()
    [ "$INSTALL_OPENSHELL" = "Y" ] && profiles+=("openshell")
    [ "$INSTALL_CONTEXT_ENGINE" = "Y" ] && profiles+=("context")
    local IFS=,
    printf '%s' "${profiles[*]}"
}

function openssl_supports_ed25519() {
    local bin="$1"
    local tmp_file
    tmp_file="$(mktemp "${TMPDIR:-/tmp}/mn-ed25519-test.XXXXXX")"
    if "$bin" genpkey -algorithm ED25519 -out "$tmp_file" >/dev/null 2>&1; then
        rm -f "$tmp_file"
        return 0
    fi
    rm -f "$tmp_file"
    return 1
}

function resolve_ed25519_openssl() {
    local candidates=()
    local candidate resolved

    if [ -n "${OPENSSL_BIN:-}" ]; then
        if resolved="$(command -v "$OPENSSL_BIN" 2>/dev/null)" && [ -n "$resolved" ] && [ -x "$resolved" ] && openssl_supports_ed25519 "$resolved"; then
            printf '%s\n' "$resolved"
            return 0
        fi
        print_error "OPENSSL_BIN=${OPENSSL_BIN} does not support ED25519 key generation."
        print_error "Set OPENSSL_BIN to an OpenSSL 3 binary, for example /opt/homebrew/bin/openssl."
        exit 1
    fi
    if resolved="$(command -v openssl 2>/dev/null)" && [ -n "$resolved" ]; then
        candidates+=("$resolved")
    fi
    candidates+=(
        /opt/homebrew/bin/openssl
        /usr/local/bin/openssl
        /usr/local/opt/openssl@3/bin/openssl
        /opt/local/bin/openssl
    )

    for candidate in "${candidates[@]}"; do
        [ -x "$candidate" ] || continue
        if openssl_supports_ed25519 "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    print_error "An ED25519-capable OpenSSL is required to create OpenShell sandbox JWT keys."
    print_error "Install OpenSSL 3, put it on PATH, or set OPENSSL_BIN=/path/to/openssl."
    exit 1
}

function write_openshell_compose_config() {
    local gateway_dir="${MN_HOST_OPENSHELL_CONFIG_DIR}/gateways/openshell"
    local jwt_dir="${MN_HOST_OPENSHELL_STATE_DIR}/jwt"
    local openssl_bin tmp_dir
    mkdir -p "$gateway_dir"
    mkdir -p "$jwt_dir"
    if [ ! -s "${jwt_dir}/signing.pem" ] || [ ! -s "${jwt_dir}/public.pem" ] || [ ! -s "${jwt_dir}/kid" ]; then
        openssl_bin="$(resolve_ed25519_openssl)"
        tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mn-openshell-jwt.XXXXXX")"
        if ! "$openssl_bin" genpkey -algorithm ED25519 -out "${tmp_dir}/signing.pem" >/dev/null; then
            print_error "Failed to create OpenShell JWT signing key with ${openssl_bin}."
            rm -rf "$tmp_dir"
            exit 1
        fi
        if ! "$openssl_bin" pkey -in "${tmp_dir}/signing.pem" -pubout -out "${tmp_dir}/public.pem" >/dev/null; then
            print_error "Failed to create OpenShell JWT public key with ${openssl_bin}."
            rm -rf "$tmp_dir"
            exit 1
        fi
        if ! "$openssl_bin" rand -hex 8 > "${tmp_dir}/kid"; then
            print_error "Failed to create OpenShell JWT key id with ${openssl_bin}."
            rm -rf "$tmp_dir"
            exit 1
        fi
        mv "${tmp_dir}/signing.pem" "${jwt_dir}/signing.pem"
        mv "${tmp_dir}/public.pem" "${jwt_dir}/public.pem"
        mv "${tmp_dir}/kid" "${jwt_dir}/kid"
        rm -rf "$tmp_dir"
        chmod 600 "${jwt_dir}/signing.pem" 2>/dev/null || true
        chmod 644 "${jwt_dir}/public.pem" "${jwt_dir}/kid" 2>/dev/null || true
    fi
    printf 'openshell\n' > "${MN_HOST_OPENSHELL_CONFIG_DIR}/active_gateway"
    cat > "${gateway_dir}/metadata.json" <<EOF
{
  "name": "openshell",
  "gateway_endpoint": "http://openshell:${OPENSHELL_GATEWAY_PORT:-58080}",
  "is_remote": false,
  "gateway_port": ${OPENSHELL_GATEWAY_PORT:-58080}
}
EOF
    cat > "${MN_HOST_OPENSHELL_STATE_DIR}/gateway.toml" <<EOF
[openshell]
version = 1

[openshell.gateway]
bind_address = "0.0.0.0:${OPENSHELL_GATEWAY_PORT:-58080}"
log_level = "info"
compute_drivers = ["docker"]
sandbox_namespace = "mirror-neuron"
default_image = "ghcr.io/nvidia/openshell/sandbox:latest"
supervisor_image = "ghcr.io/nvidia/openshell/supervisor:latest"

[openshell.gateway.gateway_jwt]
signing_key_path = "${jwt_dir}/signing.pem"
public_key_path = "${jwt_dir}/public.pem"
kid_path = "${jwt_dir}/kid"
gateway_id = "openshell"
ttl_secs = 3600

[openshell.gateway.auth]
allow_unauthenticated_users = true

[openshell.drivers.docker]
default_image = "ghcr.io/nvidia/openshell/sandbox:latest"
image_pull_policy = "IfNotPresent"
sandbox_namespace = "mirror-neuron"
grpc_endpoint = "http://host.openshell.internal:${OPENSHELL_GATEWAY_PORT:-58080}"
network_name = "openshell-docker"
EOF
}

function install_openshell_cli() {
    if command -v openshell >/dev/null 2>&1; then
        return 0
    fi
    local installer="${TMPDIR:-/tmp}/mirror_neuron_openshell_install.sh"
    curl_github -fLsS https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh -o "$installer"
    OPENSHELL_VERSION="${OPENSHELL_VERSION:-v0.0.47}" sh "$installer" >/dev/null
    rm -f "$installer"
}

function generate_mn_secret() {
    local secret

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

    if command -v python3 >/dev/null 2>&1; then
        if secret="$(python3 -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null)" && [ -n "$secret" ]; then
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

    if [ -n "$env_value" ] && [ "$env_value" != "mirrorneuron" ]; then
        printf '%s\n' "$env_value" > "$file"
        chmod 600 "$file" 2>/dev/null || true
        printf '%s\n' "$env_value"
        return 0
    fi

    mkdir -p "$INSTALL_DIR"
    if [ -s "$file" ]; then
        value="$(tr -d '[:space:]' < "$file")"
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
    printf '%s\n' "$value" > "$file"
    chmod 600 "$file" 2>/dev/null || true
    printf '%s\n' "$value"
}

function resolve_mn_cookie() {
    resolve_secret_file "${MN_COOKIE:-}" "${INSTALL_DIR}/erlang.cookie" "MN_COOKIE"
}

function resolve_grpc_auth_token() {
    resolve_secret_file "${MN_GRPC_AUTH_TOKEN:-}" "${INSTALL_DIR}/grpc_auth.token" "MN_GRPC_AUTH_TOKEN"
}

function resolve_grpc_admin_token() {
    resolve_secret_file "${MN_MIRROR_NEURON_GRPC_ADMIN_TOKEN:-}" "${INSTALL_DIR}/grpc_admin.token" "MN_MIRROR_NEURON_GRPC_ADMIN_TOKEN"
}

function resolve_network_token() {
    resolve_secret_file "${MN_NETWORK_JOIN_TOKEN:-}" "${INSTALL_DIR}/network.token" "MN_NETWORK_JOIN_TOKEN"
}

function derive_network_secret() {
    local token="$1"
    local label="$2"
    local material="mirror-neuron:${label}:${token}"
    local digest

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

    if command -v python3 >/dev/null 2>&1; then
        if digest="$(printf '%s' "$material" | python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null)" && [ -n "$digest" ]; then
            printf '%s\n' "$digest"
            return 0
        fi
    fi

    print_error "Need shasum, sha256sum, a working openssl, or python3 to derive Redis credentials."
    exit 1
}

function read_env_value() {
    local file="$1"
    local key="$2"
    [ -f "$file" ] || return 0
    awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$file"
}

function redis_probe_host() {
    case "${1:-}" in
        ""|0.0.0.0|::|localhost) printf '127.0.0.1' ;;
        *) printf '%s' "$1" ;;
    esac
}

function redis_container_owns_port() {
    local port="$1"
    docker port mirror-neuron-redis 6379/tcp 2>/dev/null | awk -F: -v port="$port" '$NF == port {found=1} END {exit found ? 0 : 1}'
}

function redis_port_available() {
    local host="$1"
    local port="$2"
    local probe_host
    probe_host="$(redis_probe_host "$host")"

    if redis_container_owns_port "$port"; then
        return 0
    fi
    if (echo >"/dev/tcp/${probe_host}/${port}") >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

function resolve_redis_port() {
    local bind_host="$1"
    local persisted_port="$2"
    local candidate

    if [ -n "${MN_REDIS_PORT:-}" ]; then
        candidate="$MN_REDIS_PORT"
        if ! [[ "$candidate" =~ ^[0-9]+$ ]] || [ "$candidate" -lt 1 ] || [ "$candidate" -gt 65535 ]; then
            print_error "MN_REDIS_PORT must be a TCP port between 1 and 65535."
            exit 1
        fi
        if ! redis_port_available "$bind_host" "$candidate"; then
            print_error "Redis port ${candidate} is already in use."
            exit 1
        fi
        printf '%s\n' "$candidate"
        return 0
    fi

    if [[ "$persisted_port" =~ ^[0-9]+$ ]] &&
       [ "$persisted_port" -ge "$MN_DYNAMIC_REDIS_PORT_START" ] &&
       [ "$persisted_port" -le "$MN_DYNAMIC_REDIS_PORT_END" ] &&
       redis_port_available "$bind_host" "$persisted_port"; then
        printf '%s\n' "$persisted_port"
        return 0
    fi

    for candidate in $(seq "$MN_DYNAMIC_REDIS_PORT_START" "$MN_DYNAMIC_REDIS_PORT_END"); do
        if redis_port_available "$bind_host" "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    print_error "No Redis port is available in ${MN_DYNAMIC_REDIS_PORT_START}-${MN_DYNAMIC_REDIS_PORT_END}."
    exit 1
}

function write_runtime_compose_files() {
    local target build_target model_image profiles redis_bind_host persisted_redis_port redis_port network_token redis_password mn_cookie grpc_auth_token grpc_admin_token
    if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
        context_engine_source_dir >/dev/null
    fi
    target="$(context_model_target)"
    build_target="$(context_model_build_target "$target")"
    model_image="$(context_model_image "$target")"
    profiles="$(compose_profiles)"
    redis_bind_host="${MN_REDIS_BIND_HOST:-0.0.0.0}"
    persisted_redis_port="$(read_env_value "$RUNTIME_COMPOSE_ENV" "MN_REDIS_PORT")"
    redis_port="$(resolve_redis_port "$redis_bind_host" "$persisted_redis_port")"
    network_token="$(resolve_network_token)"
    redis_password="$(derive_network_secret "$network_token" "redis")"
    mn_cookie="$(resolve_mn_cookie)"
    grpc_auth_token="$(resolve_grpc_auth_token)"
    grpc_admin_token="$(resolve_grpc_admin_token)"

    mkdir -p "$INSTALL_DIR" "$MN_HOST_MN_DIR" "$MN_HOST_OPENSHELL_CONFIG_DIR" "$MN_HOST_OPENSHELL_STATE_DIR"
    cp "$RUNTIME_COMPOSE_TEMPLATE" "$RUNTIME_COMPOSE_FILE"
    if [ "$INSTALL_OPENSHELL" = "Y" ]; then
        write_openshell_compose_config
    fi
    cat > "$RUNTIME_COMPOSE_ENV" <<EOF
COMPOSE_PROJECT_NAME=mirror-neuron
COMPOSE_PROFILES=${profiles}
MN_HOST_STATE_DIR=${INSTALL_DIR}
MN_HOST_MN_DIR=${MN_HOST_MN_DIR}
MN_HOST_OPENSHELL_CONFIG_DIR=${MN_HOST_OPENSHELL_CONFIG_DIR}
MN_HOST_OPENSHELL_STATE_DIR=${MN_HOST_OPENSHELL_STATE_DIR}
MEMBRANE_DIR=${MEMBRANE_DIR}
ENGINE_IMAGE=mirror-neuron-memory-engine:latest
MN_CONTEXT_MODEL_BUILD_TARGET=${build_target}
MN_CONTEXT_MODEL_IMAGE=${model_image}
MN_GRPC_BIND_HOST=${MN_GRPC_BIND_HOST:-127.0.0.1}
MN_GRPC_PORT=${MN_GRPC_PORT:-55051}
MN_CORE_GRPC_TARGET=${MN_CORE_GRPC_TARGET:-localhost:${MN_GRPC_PORT:-55051}}
MN_API_HOST=${MN_API_HOST:-localhost}
MN_API_PORT=${MN_API_PORT:-54001}
MN_EPMD_BIND_HOST=${MN_EPMD_BIND_HOST:-127.0.0.1}
MN_EPMD_PORT=${MN_EPMD_PORT:-54369}
MN_DIST_BIND_HOST=${MN_DIST_BIND_HOST:-127.0.0.1}
MN_DIST_PORT=${MN_DIST_PORT:-54370}
MN_WEB_UI_HOST=${MN_WEB_UI_HOST:-localhost}
MN_WEB_UI_PORT=${MN_WEB_UI_PORT:-55173}
MN_BLUEPRINT_WEB_UI_PUBLISH_HOST=${MN_BLUEPRINT_WEB_UI_PUBLISH_HOST:-127.0.0.1}
MN_BLUEPRINT_WEB_UI_BIND_HOST=${MN_BLUEPRINT_WEB_UI_BIND_HOST:-0.0.0.0}
MN_BLUEPRINT_WEB_UI_PUBLIC_HOST=${MN_BLUEPRINT_WEB_UI_PUBLIC_HOST:-localhost}
MN_BLUEPRINT_WEB_UI_PORT_START=${MN_BLUEPRINT_WEB_UI_PORT_START:-61000}
MN_BLUEPRINT_WEB_UI_PORT_END=${MN_BLUEPRINT_WEB_UI_PORT_END:-61049}
MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE=${MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE:-prepublished}
MN_DEFAULT_BLUEPRINT_REPO=${MN_DEFAULT_BLUEPRINT_REPO:-https://github.com/MirrorNeuronLab/mn-blueprints.git}
MN_BLUEPRINT_REPO=${MN_BLUEPRINT_REPO:-${MN_DEFAULT_BLUEPRINT_REPO:-https://github.com/MirrorNeuronLab/mn-blueprints.git}}
MN_DEV_LOCAL_BLUEPRINT_REPO=${MN_DEV_LOCAL_BLUEPRINT_REPO:-${DEV_LOCAL_BLUEPRINT_REPO:-}}
MN_RUNS_ROOT=${MN_RUNS_ROOT:-}
MN_NODE_NAME=${MN_NODE_NAME:-}
MN_NODE_ROLE=${MN_NODE_ROLE:-runtime}
MN_CLUSTER_NODES=${MN_CLUSTER_NODES:-}
MN_NETWORK_JOIN_TOKEN=${network_token}
MN_REDIS_BIND_HOST=${redis_bind_host}
MN_REDIS_PORT=${redis_port}
MN_REDIS_PASSWORD=${redis_password}
MN_REDIS_URL=${MN_REDIS_URL:-redis://:${redis_password}@redis:6379/0}
MN_CONTEXT_REDIS_URL=${MN_CONTEXT_REDIS_URL:-redis://:${redis_password}@redis:6379/1}
ERL_EPMD_ADDRESS=${ERL_EPMD_ADDRESS:-0.0.0.0}
ERL_AFLAGS=${ERL_AFLAGS:--kernel inet_dist_listen_min ${MN_DIST_PORT:-54370} inet_dist_listen_max ${MN_DIST_PORT:-54370}}
OPENSHELL_GATEWAY_BIND_HOST=${OPENSHELL_GATEWAY_BIND_HOST:-127.0.0.1}
OPENSHELL_GATEWAY_PORT=${OPENSHELL_GATEWAY_PORT:-58080}
OPENSHELL_GATEWAY_ENDPOINT=${OPENSHELL_GATEWAY_ENDPOINT:-http://127.0.0.1:${OPENSHELL_GATEWAY_PORT:-58080}}
OPENSHELL_GATEWAY_USER=${OPENSHELL_GATEWAY_USER}
OPENSHELL_GATEWAY_DOCKER_GROUP=${OPENSHELL_GATEWAY_DOCKER_GROUP}
DOCKER_HOST_SOCKET=${DOCKER_HOST_SOCKET}
MN_COOKIE=${mn_cookie}
MN_GRPC_AUTH_TOKEN=${grpc_auth_token}
MN_MIRROR_NEURON_GRPC_ADMIN_TOKEN=${grpc_admin_token}
EOF
    chmod 600 "$RUNTIME_COMPOSE_ENV" 2>/dev/null || true
}

function runtime_compose() {
    docker compose --env-file "$RUNTIME_COMPOSE_ENV" -f "$RUNTIME_COMPOSE_FILE" "$@"
}

function runtime_container_name_for_service() {
    case "$1" in
        redis) echo "mirror-neuron-redis" ;;
        openshell) echo "openshell-cluster-openshell" ;;
        context-engine-model) echo "mirror-neuron-context-engine-model" ;;
        membrane-context-engine) echo "mirror-neuron-context-engine" ;;
        mirror-neuron-core) echo "mirror-neuron-core" ;;
        *) return 1 ;;
    esac
}

function remove_stale_runtime_container() {
    local name="$1"
    local project

    if ! docker container inspect "$name" >/dev/null 2>&1; then
        return 0
    fi

    project="$(docker container inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$name" 2>/dev/null || true)"
    if [ "$project" = "mirror-neuron" ]; then
        return 0
    fi

    docker rm -f "$name" >/dev/null 2>&1 || true
}

function remove_stale_runtime_containers_for_services() {
    local service name
    for service in "$@"; do
        name="$(runtime_container_name_for_service "$service" || true)"
        [ -n "$name" ] && remove_stale_runtime_container "$name"
    done
}

function start_runtime_compose_sidecars() {
    local services=()
    [ "$INSTALL_REDIS" = "Y" ] && services+=("redis")
    [ "$INSTALL_OPENSHELL" = "Y" ] && services+=("openshell")
    if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
        services+=("context-engine-model" "membrane-context-engine")
    fi
    if [ "${#services[@]}" -gt 0 ]; then
        remove_stale_runtime_containers_for_services "${services[@]}"
        if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
            runtime_compose build context-engine-model membrane-context-engine
        fi
        runtime_compose up -d "${services[@]}" >/dev/null
    fi
}

print_step "Checking Python runtime"
resolve_python_runtime

if [ -d "$INSTALL_DIR" ] || [ -f "$BIN_DIR/mn" ]; then
    print_warning "MirrorNeuron appears to be already installed."
    REINSTALL=$(ask "Do you want to reinstall (overwrite old ones)?" "Y")
    if [ "$REINSTALL" = "N" ]; then
        echo -e "${YELLOW}Installation cancelled by user.${RESET}" >&3
        exit 0
    fi
    echo "" >&3
    # Clean up to ensure a fresh overwrite
    rm -rf "$INSTALL_DIR" "$VENV_DIR" "$LEGACY_UI_DIR" "$BIN_DIR/mn" "$BIN_DIR/mn-api"
fi

# Interactive Prompts
echo -e "${CYAN}${BOLD}Configuration${RESET}" >&3
INSTALL_WEB_UI=$(ask "Do you want to install the Web UI?" "Y")
INSTALL_REDIS=$(ask "Do you want to install Redis via Docker?" "Y")
INSTALL_CONTEXT_ENGINE=$(ask "Do you want to install/start the Membrane context engine?" "$INSTALL_CONTEXT_ENGINE")
INSTALL_OPENSHELL=$(ask "Do you want to install/start the OpenShell gateway for sandbox workers?" "Y")
START_NOW=$(ask "Do you want to start the MirrorNeuron server automatically after install?" "Y")
echo "" >&3

print_step "Checking Dependencies"

require_cmd git
require_cmd curl
require_cmd docker
resolve_python_runtime

if [ "$INSTALL_WEB_UI" = "Y" ]; then
    require_cmd npm
fi

if [ ! -f "$RUNTIME_COMPOSE_TEMPLATE" ]; then
    print_error "MirrorNeuron runtime Docker Compose template is missing: $RUNTIME_COMPOSE_TEMPLATE"
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    print_error "Docker is not running. Please start Docker first."
    exit 1
fi

print_success "All dependencies found or installed."

print_step "Installing MirrorNeuron Core (Docker)"

(
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR"
        git fetch origin >/dev/null 2>&1
        git pull origin main >/dev/null 2>&1 || true
    else
        git clone https://github.com/homerquan/MirrorNeuron.git "$INSTALL_DIR" >/dev/null 2>&1
        cd "$INSTALL_DIR"
    fi
    
    if [ ! -f "Dockerfile" ]; then
        cat << 'EOF' > Dockerfile
FROM elixir:1.16-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    make \
    g++ \
    libssl-dev \
    protobuf-compiler \
    curl \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# Install hex and rebar
RUN mix local.rebar --force && mix local.hex --force

WORKDIR /app

# Copy dependency files and fetch deps
COPY mix.exs mix.lock ./
RUN mix deps.get

# Copy the rest of the application
COPY . .

# Compile the application
RUN mix compile

EXPOSE 55051

# Set the default command
CMD ["mix", "run", "--no-halt"]
EOF
    fi

    docker build -t mirror-neuron-core . >/dev/null 2>&1
) &
spinner $! "Cloning and building Core (Docker image mirror-neuron-core)"
write_runtime_compose_files

print_step "Installing Python CLI & API"
if [ -n "$SOURCE_WORKSPACE" ]; then
    print_success "Using local Python sources from $SOURCE_WORKSPACE."
else
    print_warning "Local Python sources were not found; falling back to anonymous GitHub installs."
    print_warning "Run from a mirror-neuron-set checkout or set MN_SOURCE_DIR=/path/to/mirror-neuron-set to use local packages."
fi
(
    "$MN_PYTHON_BIN" -m venv "$VENV_DIR" >/dev/null 2>&1
    run_quiet "pip-upgrade" "$VENV_DIR/bin/pip" install --upgrade pip
    
    if [ -n "$SOURCE_WORKSPACE" ]; then
        run_quiet "install-mn-python-sdk-local" "$VENV_DIR/bin/pip" install "$SOURCE_WORKSPACE/mn-python-sdk"
    else
        run_quiet "install-mn-python-sdk-github" "$VENV_DIR/bin/pip" install git+https://github.com/MirrorNeuronLab/mn-python-sdk.git
    fi

    if [ -n "$SOURCE_WORKSPACE" ]; then
        if [ -f "$SOURCE_WORKSPACE/mn-skills/blueprint_support_skill/pyproject.toml" ]; then
            run_quiet "install-blueprint-support-skill-local" "$VENV_DIR/bin/pip" install "$SOURCE_WORKSPACE/mn-skills/blueprint_support_skill[webui]"
        elif [ -f "$SOURCE_WORKSPACE/mn-skills/blueprint-support-skill/pyproject.toml" ]; then
            run_quiet "install-blueprint-support-skill-local" "$VENV_DIR/bin/pip" install "$SOURCE_WORKSPACE/mn-skills/blueprint-support-skill[webui]"
        else
            print_error "Could not find the blueprint support Python package under $SOURCE_WORKSPACE/mn-skills."
            exit 1
        fi
    else
        run_quiet "install-blueprint-support-skill-github" "$VENV_DIR/bin/pip" install "mirrorneuron-blueprint-support-skill[webui] @ git+https://github.com/MirrorNeuronLab/mn-skills.git#subdirectory=blueprint_support_skill"
    fi
    
    if [ -n "$SOURCE_WORKSPACE" ]; then
        run_quiet "install-mn-cli-local" "$VENV_DIR/bin/pip" install "$SOURCE_WORKSPACE/mn-cli"
    else
        run_quiet "install-mn-cli-github" "$VENV_DIR/bin/pip" install git+https://github.com/MirrorNeuronLab/mn-cli.git
    fi
    
    if [ -n "$SOURCE_WORKSPACE" ]; then
        run_quiet "install-mn-api-local" "$VENV_DIR/bin/pip" install "$SOURCE_WORKSPACE/mn-api"
    else
        run_quiet "install-mn-api-github" "$VENV_DIR/bin/pip" install git+https://github.com/MirrorNeuronLab/mn-api.git
    fi

    if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
        if [ -n "$SOURCE_WORKSPACE" ] && [ -d "$SOURCE_WORKSPACE/Membrane/mn-context-engine-python-sdk" ]; then
            run_quiet "install-membrane-python-sdk-local" "$VENV_DIR/bin/pip" install "$SOURCE_WORKSPACE/Membrane/mn-context-engine-python-sdk"
        else
            run_quiet "install-membrane-python-sdk-pypi" "$VENV_DIR/bin/pip" install --upgrade mirrorneuron-membrane-python-sdk
        fi
    fi
) &
spinner $! "Setting up virtualenv and installing Python packages"

if [ "$INSTALL_WEB_UI" = "Y" ]; then
    print_step "Installing Web UI"
    if [ -n "$SOURCE_WORKSPACE" ] && [ -d "$SOURCE_WORKSPACE/mn-web-ui" ]; then
        print_success "Using local Web UI source from $SOURCE_WORKSPACE/mn-web-ui."
    fi
    (
        UI_DIR="${INSTALL_DIR}/webui"
        rm -rf "$LEGACY_UI_DIR"
        if [ -n "$SOURCE_WORKSPACE" ] && [ -d "$SOURCE_WORKSPACE/mn-web-ui" ]; then
            cd "$SOURCE_WORKSPACE/mn-web-ui"
            run_quiet "web-ui-npm-install-local" npm install
            run_quiet "web-ui-npm-build-local" npm run build
            rm -rf "$UI_DIR"
            ln -s "$SOURCE_WORKSPACE/mn-web-ui" "$UI_DIR"
        elif [ -d "$UI_DIR" ]; then
            cd "$UI_DIR"
            git pull origin main >/dev/null 2>&1 || true
            run_quiet "web-ui-npm-install-existing" npm install
            run_quiet "web-ui-npm-build-existing" npm run build
        else
            run_quiet "web-ui-git-clone" git clone https://github.com/MirrorNeuronLab/mn-web-ui.git "$UI_DIR"
            cd "$UI_DIR"
            run_quiet "web-ui-npm-install-github" npm install
            run_quiet "web-ui-npm-build-github" npm run build
        fi
    ) &
    spinner $! "Cloning and building Web UI (React)"
fi

if [ "$INSTALL_REDIS" = "Y" ] || [ "$INSTALL_CONTEXT_ENGINE" = "Y" ] || [ "$INSTALL_OPENSHELL" = "Y" ]; then
    print_step "Setting up Docker runtime services with Compose"
    if [ "$INSTALL_OPENSHELL" = "Y" ]; then
        install_openshell_cli
    fi
    ( start_runtime_compose_sidecars ) &
    spinner $! "Docker runtime services are available"
fi

print_step "Creating Symlinks"
mkdir -p "$BIN_DIR"
rm -f "$BIN_DIR/mn" "$BIN_DIR/mn-api" "$INSTALL_DIR/mn"
ln -s "$VENV_DIR/bin/mn" "$BIN_DIR/mn"
ln -s "$VENV_DIR/bin/mn-api" "$BIN_DIR/mn-api"
ln -s "$VENV_DIR/bin/mn" "$INSTALL_DIR/mn"
print_success "Symlinks created in $BIN_DIR and $INSTALL_DIR."

echo "" >&3
print_success "MirrorNeuron installation successfully completed! 🚀" >&3
echo -e "CLI is available as ${YELLOW}mn${RESET}." >&3
echo -e "API is available as ${YELLOW}mn-api${RESET}." >&3
if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
    echo -e "Membrane context engine is available on ${YELLOW}${MN_CONTEXT_ADDR:-localhost:50052}${RESET}." >&3
fi

function shell_escape_value() {
    printf '%q' "$1"
}

function profile_has_bin_path() {
    local profile="$1"
    [ -f "$profile" ] || return 1
    local line
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" == *"PATH"* && "$line" == *"$BIN_DIR"* ]]; then
            return 0
        fi
    done < "$profile"
    return 1
}

function profile_has_runtime_home() {
    local profile="$1"
    [ -f "$profile" ] || return 1
    local line
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?MIRROR_NEURON_HOME= ]]; then
            return 0
        fi
    done < "$profile"
    return 1
}

function ensure_shell_profile_exports() {
    local needs_path="N"
    local needs_runtime_home="N"
    local default_home="${HOME}/.mn"

    [[ ":$PATH:" != *":$BIN_DIR:"* ]] && needs_path="Y"
    [ "$INSTALL_DIR" != "$default_home" ] && needs_runtime_home="Y"

    if [ "$needs_path" = "N" ] && [ "$needs_runtime_home" = "N" ]; then
        return
    fi

    if [ "$needs_path" = "Y" ]; then
        echo -e "\n${YELLOW}${BOLD}Note:${RESET} ${YELLOW}$BIN_DIR is not in your PATH.${RESET}" >&3
    fi
    if [ "$needs_runtime_home" = "Y" ]; then
        echo -e "${YELLOW}Persisting MIRROR_NEURON_HOME=${INSTALL_DIR} for future terminal sessions.${RESET}" >&3
    fi

    local detected_profiles=()
    [ -f "$HOME/.zshrc" ] && detected_profiles+=("$HOME/.zshrc")
    [ -f "$HOME/.bashrc" ] && detected_profiles+=("$HOME/.bashrc")
    [ -f "$HOME/.bash_profile" ] && detected_profiles+=("$HOME/.bash_profile")
    [ -f "$HOME/.profile" ] && detected_profiles+=("$HOME/.profile")

    if [ ${#detected_profiles[@]} -eq 0 ]; then
        detected_profiles+=("$HOME/.profile")
    fi

    local profile path_line home_line wrote_header wrote_profile
    path_line="export PATH=\"$BIN_DIR:\$PATH\""
    home_line="export MIRROR_NEURON_HOME=$(shell_escape_value "$INSTALL_DIR")"

    for profile in "${detected_profiles[@]}"; do
        wrote_header="N"
        wrote_profile="N"
        if [ "$needs_path" = "Y" ] && ! profile_has_bin_path "$profile"; then
            [ "$wrote_header" = "N" ] && echo -e "\n# Added by MirrorNeuron Installer" >> "$profile" && wrote_header="Y"
            echo "$path_line" >> "$profile"
            wrote_profile="Y"
        fi
        if [ "$needs_runtime_home" = "Y" ] && ! profile_has_runtime_home "$profile"; then
            [ "$wrote_header" = "N" ] && echo -e "\n# Added by MirrorNeuron Installer" >> "$profile" && wrote_header="Y"
            echo "$home_line" >> "$profile"
            wrote_profile="Y"
        fi
        if [ "$wrote_profile" = "Y" ]; then
            echo -e "Automatically added MirrorNeuron shell exports to ${CYAN}$profile${RESET}" >&3
        fi
    done

    echo -e "${YELLOW}Please restart your terminal or run \`source ~/.zshrc\` (or your shell's configuration file) to use the updated MirrorNeuron environment.${RESET}" >&3
}

ensure_shell_profile_exports

echo -e "\n${BOLD}Quick Start:${RESET}" >&3
echo -e "  1. Start the server (Core & API): ${GREEN}mn start${RESET}" >&3
if [ "$INSTALL_WEB_UI" = "Y" ]; then
    echo -e "  2. Start the UI:   ${GREEN}cd ${INSTALL_DIR}/webui && npm run dev${RESET}" >&3
fi
echo -e "  3. Use the CLI:    ${GREEN}mn nodes${RESET}\n" >&3

if [ "$START_NOW" = "Y" ]; then
    print_step "Starting MirrorNeuron Server..."
    "$VENV_DIR/bin/mn" start
fi
