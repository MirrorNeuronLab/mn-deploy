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

if [ -n "${MN_HOME:-}" ]; then
    export MIRROR_NEURON_HOME="$MN_HOME"
else
    export MIRROR_NEURON_HOME="${HOME}/.mn"
fi

INSTALL_DIR="${MIRROR_NEURON_HOME}"
BIN_DIR="${HOME}/.local/bin"
VENV_DIR="${HOME}/.local/share/mn_venv"
UI_LINK_DIR="${INSTALL_DIR}/webui"
LEGACY_UI_LINK_DIR="${INSTALL_DIR}_ui"
RUNTIME_COMPOSE_TEMPLATE="${SCRIPT_DIR}/docker-compose.yml"
RUNTIME_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
RUNTIME_COMPOSE_ENV="${INSTALL_DIR}/docker-compose.env"

CORE_DIR="${WORKSPACE_DIR}/MirrorNeuron"
CLI_DIR="${WORKSPACE_DIR}/mn-cli"
API_DIR="${WORKSPACE_DIR}/mn-api"
PY_SDK_DIR="${WORKSPACE_DIR}/mn-python-sdk"
WEB_UI_DIR="${WORKSPACE_DIR}/mn-web-ui"
SKILLS_DIR="${WORKSPACE_DIR}/mn-skills"
BLUEPRINT_SUPPORT_SKILL_DIR="${SKILLS_DIR}/blueprint_support_skill"
BLUEPRINTS_DIR="${WORKSPACE_DIR}/mn-blueprints"
DOCS_DIR="${WORKSPACE_DIR}/mn-docs"
SYSTEM_TESTS_DIR="${WORKSPACE_DIR}/mn-system-tests"
MEMBRANE_DIR="${WORKSPACE_DIR}/Membrane"
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
MN_PYTHON_BIN=""
MN_MANAGED_PYTHON="${MN_MANAGED_PYTHON:-1}"
MN_MANAGED_PYTHON_VERSION="${MN_MANAGED_PYTHON_VERSION:-3.11}"
MN_MANAGED_PYTHON_ROOT="${MN_MANAGED_PYTHON_DIR:-${HOME}/.local/share/mn_python}"
MN_UV_ROOT="${MN_UV_DIR:-${HOME}/.local/share/mn_uv}"
MN_UV_BIN=""

INSTALL_WEB_UI="Y"
INSTALL_REDIS="Y"
INSTALL_CONTEXT_ENGINE="Y"
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
  --context-engine      Install/start Membrane context engine.
  --no-context-engine   Skip Membrane context engine setup.
  --openshell           Install/start OpenShell gateway for sandbox workers.
  --no-openshell        Skip OpenShell gateway setup.
  --no-skills           Skip editable install of packages under mn-skills.
  --start               Start MirrorNeuron after install.
  --no-managed-python   Do not use uv to install a private Python runtime.
  MN_PYTHON=/path       Use a specific Python 3.11+ interpreter.
  MN_HOME=/path         Override the runtime state directory. Defaults to ${HOME}/.mn.
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
        --context-engine) INSTALL_CONTEXT_ENGINE="Y" ;;
        --no-context-engine) INSTALL_CONTEXT_ENGINE="N" ;;
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

    relpath="${abs_path#${repo_dir}/}"
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
    local install_path workspace_path source_path source_label
    install_path="$(canonical_path "$INSTALL_DIR")"
    workspace_path="$(canonical_path "$WORKSPACE_DIR")"

    if [ "$install_path" = "$workspace_path" ]; then
        print_error "Refusing to install MirrorNeuron state into the source workspace: ${INSTALL_DIR}"
        print_error "Unset MN_HOME or set it to a state directory such as ${HOME}/.mn."
        exit 1
    fi

    for source_label in CORE_DIR CLI_DIR API_DIR PY_SDK_DIR WEB_UI_DIR SKILLS_DIR BLUEPRINTS_DIR DOCS_DIR SYSTEM_TESTS_DIR MEMBRANE_DIR; do
        source_path="$(canonical_path "${!source_label}")"
        if [ "$install_path" = "$source_path" ]; then
            print_error "Refusing to install MirrorNeuron state into source directory ${source_label}: ${INSTALL_DIR}"
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
    local names
    names="$(docker ps --format '{{.Names}}')"
    grep -qx 'mirror-neuron-core' <<< "$names"
}

function generate_mn_cookie() {
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

    if ! cookie="$(generate_mn_cookie)"; then
        cookie=""
    fi
    if [ -z "$cookie" ]; then
        print_error "Failed to generate MN_COOKIE."
        exit 1
    fi

    printf '%s\n' "$cookie" > "$cookie_file"
    chmod 600 "$cookie_file" 2>/dev/null || true
    printf '%s\n' "$cookie"
}

function resolve_grpc_auth_token() {
    local env_token="${MN_GRPC_AUTH_TOKEN:-}"
    local token_file="${INSTALL_DIR}/grpc_auth.token"
    local token

    if [ -n "$env_token" ]; then
        printf '%s\n' "$env_token"
        return 0
    fi

    mkdir -p "$INSTALL_DIR"
    if [ -s "$token_file" ]; then
        token="$(tr -d '[:space:]' < "$token_file")"
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
        print_error "Failed to generate MN_GRPC_AUTH_TOKEN."
        exit 1
    fi

    printf '%s\n' "$token" > "$token_file"
    chmod 600 "$token_file" 2>/dev/null || true
    printf '%s\n' "$token"
}

function resolve_grpc_admin_token() {
    local env_token="${MN_GRPC_ADMIN_TOKEN:-${MN_MIRROR_NEURON_GRPC_ADMIN_TOKEN:-}}"
    local token_file="${INSTALL_DIR}/grpc_admin.token"
    local token

    if [ -n "$env_token" ]; then
        printf '%s\n' "$env_token"
        return 0
    fi

    mkdir -p "$INSTALL_DIR"
    if [ -s "$token_file" ]; then
        token="$(tr -d '[:space:]' < "$token_file")"
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
        print_error "Failed to generate MN_GRPC_ADMIN_TOKEN."
        exit 1
    fi

    printf '%s\n' "$token" > "$token_file"
    chmod 600 "$token_file" 2>/dev/null || true
    printf '%s\n' "$token"
}

function resolve_network_token() {
    local env_token="${MN_NETWORK_JOIN_TOKEN:-}"
    local token_file="${INSTALL_DIR}/network.token"
    local token

    if [ -n "$env_token" ]; then
        printf '%s\n' "$env_token" > "$token_file"
        chmod 600 "$token_file" 2>/dev/null || true
        printf '%s\n' "$env_token"
        return 0
    fi

    mkdir -p "$INSTALL_DIR"
    if [ -s "$token_file" ]; then
        token="$(tr -d '[:space:]' < "$token_file")"
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
    printf '%s\n' "$token" > "$token_file"
    chmod 600 "$token_file" 2>/dev/null || true
    printf '%s\n' "$token"
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

    if command -v lsof >/dev/null 2>&1 &&
       lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        return 1
    fi

    if [ -n "${MN_PYTHON_BIN:-}" ] &&
       "$MN_PYTHON_BIN" -c 'import socket, sys
host = sys.argv[1]
port = int(sys.argv[2])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(0.25)
try:
    raise SystemExit(0 if sock.connect_ex((host, port)) == 0 else 1)
finally:
    sock.close()
' "$probe_host" "$port" >/dev/null 2>&1; then
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

function start_core_container() {
    local cmd=("docker" "run" "-d" "--name" "mirror-neuron-core")
    local openshell_config_dir="$HOME/.config/openshell"
    local openshell_container_config_dir="${OPENSHELL_CONTAINER_CONFIG_DIR:-$HOME/.config/openshell-mirror-neuron}"
    local openshell_mount_dir="$openshell_config_dir"
    local core_host="${MN_CORE_HOST:-localhost}"
    local redis_host="${MN_REDIS_HOST:-localhost}"
    local epmd_host="${MN_EPMD_HOST:-localhost}"
    local dist_host="${MN_DIST_HOST:-localhost}"
    local grpc_port="${MN_GRPC_PORT:-55051}"
    local epmd_port="${MN_EPMD_PORT:-54369}"
    local dist_port="${MN_DIST_PORT:-54370}"
    local core_publish_host="$core_host"
    local epmd_publish_host="$epmd_host"
    local dist_publish_host="$dist_host"
    local mn_cookie
    local grpc_auth_token
    local grpc_admin_token
    mn_cookie="$(resolve_mn_cookie)"
    grpc_auth_token="$(resolve_grpc_auth_token)"
    grpc_admin_token="$(resolve_grpc_admin_token)"
    [ "$core_publish_host" = "localhost" ] && core_publish_host="127.0.0.1"
    [ "$epmd_publish_host" = "localhost" ] && epmd_publish_host="127.0.0.1"
    [ "$dist_publish_host" = "localhost" ] && dist_publish_host="127.0.0.1"

    cmd+=("-e" "MN_COOKIE=${mn_cookie}")
    cmd+=("-e" "MN_GRPC_AUTH_TOKEN=${grpc_auth_token}")
    cmd+=("-e" "MN_GRPC_ADMIN_TOKEN=${grpc_admin_token}")
    cmd+=("-e" "MN_GRPC_PORT=${grpc_port}")
    if [ -n "${MN_NODE_NAME:-}" ]; then
        cmd+=("-e" "MN_NODE_NAME=${MN_NODE_NAME}")
    fi

    if [ "$(uname -s)" = "Darwin" ]; then
        cmd+=("-p" "${core_publish_host}:${grpc_port}:${grpc_port}" "-p" "${epmd_publish_host}:${epmd_port}:4369")
        cmd+=("-p" "${dist_publish_host}:${dist_port}:${dist_port}")
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
    cmd+=("-e" "MN_DIST_PORT=${dist_port}")

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
    remove_stale_runtime_container mirror-neuron-core
    runtime_compose rm -sf mirror-neuron-core >/dev/null 2>&1 || true
    runtime_compose up -d mirror-neuron-core >/dev/null
}

function setup_context_engine() {
    remove_stale_runtime_containers_for_services context-engine-model membrane-context-engine
    ensure_docker_model_runner
    runtime_compose build membrane-context-engine
    runtime_compose up -d membrane-context-engine >/dev/null
}

function compose_profiles() {
    local profiles=()
    [ "$INSTALL_OPENSHELL" = "Y" ] && profiles+=("openshell")
    [ "$INSTALL_CONTEXT_ENGINE" = "Y" ] && profiles+=("context")
    local IFS=,
    printf '%s' "${profiles[*]}"
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

function resolve_docker_network_external() {
    local network_name="$1"
    local configured="${MN_DOCKER_NETWORK_EXTERNAL:-}"
    local labels compose_project compose_network

    if [ -n "$configured" ]; then
        printf '%s\n' "$configured"
        return 0
    fi

    if ! labels="$(docker network inspect -f '{{ index .Labels "com.docker.compose.project" }}|{{ index .Labels "com.docker.compose.network" }}' "$network_name" 2>/dev/null)"; then
        printf 'false\n'
        return 0
    fi

    compose_project="${labels%%|*}"
    compose_network="${labels#*|}"
    if [ "$compose_project" = "mirror-neuron" ] && [ "$compose_network" = "runtime" ]; then
        printf 'false\n'
    else
        print_warning "Docker network ${network_name} already exists outside this Compose project; reusing it as an external network."
        printf 'true\n'
    fi
}

function write_runtime_compose_files() {
    local model_runner_model profiles network_name network_external network_token redis_password mn_cookie grpc_auth_token grpc_admin_token
    model_runner_model="${MN_CONTEXT_MODEL_RUNNER_MODEL:-hf.co/homerquan/mn-context-engine-model-v-Q4_K_M}"
    profiles="$(compose_profiles)"
    network_name="${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
    network_external="$(resolve_docker_network_external "$network_name")"
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
MN_CONTEXT_MODEL_RUNNER_MODEL=${model_runner_model}
MN_GRPC_BIND_HOST=${MN_GRPC_BIND_HOST:-127.0.0.1}
MN_GRPC_PORT=${MN_GRPC_PORT:-55051}
MN_CORE_GRPC_TARGET=${MN_CORE_GRPC_TARGET:-localhost:${MN_GRPC_PORT:-55051}}
MN_API_HOST=${MN_API_HOST:-localhost}
MN_API_PORT=${MN_API_PORT:-54001}
MN_DIST_PORT=${MN_DIST_PORT:-54370}
MN_WEB_UI_HOST=${MN_WEB_UI_HOST:-localhost}
MN_WEB_UI_PORT=${MN_WEB_UI_PORT:-55173}
MN_BLUEPRINT_WEB_UI_BIND_HOST=${MN_BLUEPRINT_WEB_UI_BIND_HOST:-0.0.0.0}
MN_BLUEPRINT_WEB_UI_PUBLIC_HOST=${MN_BLUEPRINT_WEB_UI_PUBLIC_HOST:-localhost}
MN_BLUEPRINT_WEB_UI_PORT_START=${MN_BLUEPRINT_WEB_UI_PORT_START:-61000}
MN_BLUEPRINT_WEB_UI_PORT_END=${MN_BLUEPRINT_WEB_UI_PORT_END:-61049}
MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE=${MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE:-prepublished}
MN_DEFAULT_BLUEPRINT_REPO=${MN_DEFAULT_BLUEPRINT_REPO:-https://github.com/MirrorNeuronLab/mn-blueprints.git}
MN_BLUEPRINT_REPO=${MN_BLUEPRINT_REPO:-${MN_DEFAULT_BLUEPRINT_REPO:-https://github.com/MirrorNeuronLab/mn-blueprints.git}}
MN_DEV_LOCAL_BLUEPRINT_REPO=${MN_DEV_LOCAL_BLUEPRINT_REPO:-${DEV_LOCAL_BLUEPRINT_REPO:-}}
MN_RUNS_ROOT=${MN_RUNS_ROOT:-}
MN_DOCKER_NETWORK_MODE=${MN_DOCKER_NETWORK_MODE:-bridge}
MN_DOCKER_NETWORK_NAME=${network_name}
MN_DOCKER_NETWORK_EXTERNAL=${network_external}
MN_DOCKER_NETWORK_DRIVER=${MN_DOCKER_NETWORK_DRIVER:-bridge}
MN_DOCKER_NETWORK_ATTACHABLE=${MN_DOCKER_NETWORK_ATTACHABLE:-false}
MN_NODE_ALIAS=${MN_NODE_ALIAS:-}
MN_NODE_NAME=${MN_NODE_NAME:-}
MN_NODE_ROLE=${MN_NODE_ROLE:-runtime}
MN_CLUSTER_NODES=${MN_CLUSTER_NODES:-}
MN_NETWORK_JOIN_TOKEN=${network_token}
MN_REDIS_PASSWORD=${redis_password}
MN_REDIS_URL=${MN_REDIS_URL:-redis://:${redis_password}@redis:6379/0}
MN_CONTEXT_REDIS_URL=${MN_CONTEXT_REDIS_URL:-redis://:${redis_password}@redis:6379/1}
ERL_EPMD_ADDRESS=${ERL_EPMD_ADDRESS:-0.0.0.0}
ERL_AFLAGS=${ERL_AFLAGS:--kernel inet_dist_listen_min ${MN_DIST_PORT:-54370} inet_dist_listen_max ${MN_DIST_PORT:-54370}}
OPENSHELL_GATEWAY_PORT=${OPENSHELL_GATEWAY_PORT:-58080}
OPENSHELL_GATEWAY_ENDPOINT=${OPENSHELL_GATEWAY_ENDPOINT:-http://127.0.0.1:${OPENSHELL_GATEWAY_PORT:-58080}}
OPENSHELL_GATEWAY_USER=${OPENSHELL_GATEWAY_USER}
OPENSHELL_GATEWAY_DOCKER_GROUP=${OPENSHELL_GATEWAY_DOCKER_GROUP}
DOCKER_HOST_SOCKET=${DOCKER_HOST_SOCKET}
MN_COOKIE=${mn_cookie}
MN_GRPC_AUTH_TOKEN=${grpc_auth_token}
MN_GRPC_ADMIN_TOKEN=${grpc_admin_token}
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

function ensure_docker_model_runner() {
    if [ "$INSTALL_CONTEXT_ENGINE" != "Y" ] && [ "${INSTALL_DOCKER_MODEL_RUNNER:-N}" != "Y" ] && [ "${MN_ENABLE_DOCKER_MODEL_RUNNER:-N}" != "Y" ]; then
        return 0
    fi

    if ! docker model --help >/dev/null 2>&1; then
        print_error "Docker Model Runner CLI is not available. Upgrade Docker Desktop/Engine to a version with 'docker model' support."
        exit 1
    fi

    if docker model status >/dev/null 2>&1; then
        return 0
    fi

    print_warning "Docker Model Runner is not running; attempting to enable it."
    if docker desktop enable model-runner >/dev/null 2>&1 && docker model status >/dev/null 2>&1; then
        return 0
    fi

    if docker model install-runner --help >/dev/null 2>&1; then
        docker model install-runner >/dev/null 2>&1 || true
        docker model start-runner >/dev/null 2>&1 || true
        if docker model status >/dev/null 2>&1; then
            return 0
        fi
    fi

    print_error "Docker Model Runner is not ready. Enable it in Docker Desktop Settings > AI, or run 'docker model install-runner' and 'docker model start-runner' on Docker Engine."
    exit 1
}

function start_runtime_compose_sidecars() {
    local services=()
    [ "$INSTALL_REDIS" = "Y" ] && services+=("redis")
    [ "$INSTALL_OPENSHELL" = "Y" ] && services+=("openshell")
    if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
        services+=("membrane-context-engine")
    fi
    if [ "${#services[@]}" -gt 0 ]; then
        remove_stale_runtime_containers_for_services context-engine-model "${services[@]}"
        ensure_docker_model_runner
        if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
            runtime_compose build membrane-context-engine
        fi
        runtime_compose up -d "${services[@]}"
    fi
}

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
        print_warning "${BIN_DIR} is not in your PATH."
    fi
    if [ "$needs_runtime_home" = "Y" ]; then
        print_warning "Persisting MIRROR_NEURON_HOME=${INSTALL_DIR} for future terminal sessions."
    fi

    local detected_profiles=()
    [ -f "$HOME/.zshrc" ] && detected_profiles+=("$HOME/.zshrc")
    [ -f "$HOME/.bashrc" ] && detected_profiles+=("$HOME/.bashrc")
    [ -f "$HOME/.bash_profile" ] && detected_profiles+=("$HOME/.bash_profile")
    [ -f "$HOME/.profile" ] && detected_profiles+=("$HOME/.profile")

    if [ "${#detected_profiles[@]}" -eq 0 ]; then
        detected_profiles+=("$HOME/.profile")
    fi

    local profile path_line home_line wrote_header wrote_profile
    path_line="export PATH=\"$BIN_DIR:\$PATH\""
    home_line="export MIRROR_NEURON_HOME=$(shell_escape_value "$INSTALL_DIR")"

    for profile in "${detected_profiles[@]}"; do
        wrote_header="N"
        wrote_profile="N"
        if [ "$needs_path" = "Y" ] && ! profile_has_bin_path "$profile"; then
            [ "$wrote_header" = "N" ] && echo "" >> "$profile" && echo "# Added by MirrorNeuron local installer" >> "$profile" && wrote_header="Y"
            echo "$path_line" >> "$profile"
            wrote_profile="Y"
        fi
        if [ "$needs_runtime_home" = "Y" ] && ! profile_has_runtime_home "$profile"; then
            [ "$wrote_header" = "N" ] && echo "" >> "$profile" && echo "# Added by MirrorNeuron local installer" >> "$profile" && wrote_header="Y"
            echo "$home_line" >> "$profile"
            wrote_profile="Y"
        fi
        if [ "$wrote_profile" = "Y" ]; then
            echo -e "Added MirrorNeuron shell exports to ${CYAN}${profile}${RESET}" >&3
        fi
    done
}

print_header

require_install_dir_not_source
require_dir "$CORE_DIR" "MirrorNeuron core"
require_file "$CORE_DIR/Dockerfile" "MirrorNeuron Dockerfile"
require_mix_project_file "$CORE_DIR/mix.exs"
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
    INSTALL_CONTEXT_ENGINE=$(ask "Install/start Membrane context engine?" "$INSTALL_CONTEXT_ENGINE")
    INSTALL_SKILLS=$(ask "Install local mn-skills packages in editable mode?" "$INSTALL_SKILLS")
    INSTALL_OPENSHELL=$(ask "Install/start OpenShell gateway for sandbox workers?" "$INSTALL_OPENSHELL")
    START_NOW=$(ask "Start MirrorNeuron server automatically after install?" "$START_NOW")
fi
echo "" >&3

print_step "Checking dependencies"
require_cmd docker
resolve_python_runtime

if [ "$INSTALL_WEB_UI" = "Y" ]; then
    require_cmd npm
fi
if [ "$INSTALL_OPENSHELL" = "Y" ] && ! command -v openshell >/dev/null 2>&1; then
    require_cmd curl
fi
if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
    require_dir "$MEMBRANE_DIR" "Membrane context engine"
    require_file "$MEMBRANE_DIR/Dockerfile" "Membrane Dockerfile"
fi
require_file "$RUNTIME_COMPOSE_TEMPLATE" "MirrorNeuron runtime Docker Compose template"

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
if [ -d "$MEMBRANE_DIR" ]; then replace_symlink "$MEMBRANE_DIR" "$INSTALL_DIR/Membrane"; fi
replace_symlink "$CORE_DIR" "$INSTALL_DIR/core-source"
replace_symlink "$CLI_DIR" "$INSTALL_DIR/cli-source"
replace_symlink "$API_DIR" "$INSTALL_DIR/api-source"
replace_symlink "$PY_SDK_DIR" "$INSTALL_DIR/python-sdk-source"
write_local_install_metadata
print_step "Writing Docker Compose runtime configuration"
write_runtime_compose_files
print_success "Local component links created under ${INSTALL_DIR}."

print_step "Building MirrorNeuron Core Docker image from local source"
(
    cd "$CORE_DIR"
    docker build -t mirror-neuron-core:latest .
)
print_success "Built local core image mirror-neuron-core:latest."

print_step "Installing Python components from local source"
(
    "$MN_PYTHON_BIN" -m venv "$VENV_DIR" >/dev/null
    "$VENV_DIR/bin/pip" install --upgrade pip >/dev/null
    "$VENV_DIR/bin/pip" install -e "$PY_SDK_DIR" >/dev/null
    if [ -f "$BLUEPRINT_SUPPORT_SKILL_DIR/pyproject.toml" ]; then
        "$VENV_DIR/bin/pip" install -e "$BLUEPRINT_SUPPORT_SKILL_DIR[webui]" >/dev/null
    fi
    "$VENV_DIR/bin/pip" install -e "$CLI_DIR" >/dev/null
    "$VENV_DIR/bin/pip" install -e "$API_DIR" >/dev/null
    if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
        "$VENV_DIR/bin/pip" install -e "$MEMBRANE_DIR/mn-context-engine-python-sdk" >/dev/null
    fi

    if [ "$INSTALL_SKILLS" = "Y" ]; then
        shopt -s nullglob
        for skill_pyproject in "$SKILLS_DIR"/*/pyproject.toml; do
            if [ "$(dirname "$skill_pyproject")" = "$BLUEPRINT_SUPPORT_SKILL_DIR" ]; then
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
    if [ -e "$LEGACY_UI_LINK_DIR" ] || [ -L "$LEGACY_UI_LINK_DIR" ]; then
        rm -rf "$LEGACY_UI_LINK_DIR"
    fi
    if [ -e "$UI_LINK_DIR" ] || [ -L "$UI_LINK_DIR" ]; then
        rm -rf "$UI_LINK_DIR"
    fi
    replace_symlink "$WEB_UI_DIR" "$UI_LINK_DIR"
    replace_symlink "$WEB_UI_DIR" "$INSTALL_DIR/web-ui-source"
fi

if [ "$INSTALL_REDIS" = "Y" ] || [ "$INSTALL_CONTEXT_ENGINE" = "Y" ] || [ "$INSTALL_OPENSHELL" = "Y" ]; then
    print_step "Setting up Docker runtime services with Compose"
    if [ "$INSTALL_OPENSHELL" = "Y" ]; then
        install_openshell_cli
    fi
    start_runtime_compose_sidecars
    print_success "Docker runtime services are available."
fi

if [ "$CORE_WAS_RUNNING" = "Y" ] && [ "$START_NOW" != "Y" ]; then
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

ensure_shell_profile_exports

echo "" >&3
print_success "MirrorNeuron local installation completed."
echo -e "Core image: ${YELLOW}mirror-neuron-core:latest${RESET} built from ${CYAN}${CORE_DIR}${RESET}" >&3
echo -e "CLI/API:    ${YELLOW}editable Python installs${RESET} from local workspace" >&3
echo -e "State dir:  ${CYAN}${INSTALL_DIR}${RESET}" >&3
echo -e "Cookie:     ${CYAN}${INSTALL_DIR}/erlang.cookie${RESET}" >&3
if [ "$INSTALL_WEB_UI" = "Y" ]; then
    echo -e "Web UI:     ${CYAN}${UI_LINK_DIR}${RESET} -> ${WEB_UI_DIR}" >&3
fi
if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
    echo -e "Membrane:   ${CYAN}${MEMBRANE_DIR}${RESET} on ${YELLOW}${MN_CONTEXT_ADDR:-localhost:50052}${RESET}" >&3
fi

echo -e "\n${BOLD}Quick Start:${RESET}" >&3
echo -e "  1. Start server: ${GREEN}mn runtime start${RESET}" >&3
if [ "$INSTALL_WEB_UI" = "Y" ]; then
    echo -e "  2. Start UI:     ${GREEN}cd ${UI_LINK_DIR} && npm run dev${RESET}" >&3
fi
echo -e "  3. Use CLI:      ${GREEN}mn node list${RESET}" >&3
echo -e "  4. Rebuild core after Elixir changes: ${GREEN}${SCRIPT_DIR}/install_local.sh --yes --no-web-ui --no-skills${RESET}\n" >&3

if [ "$START_NOW" = "Y" ]; then
    print_step "Starting MirrorNeuron Server"
    "$VENV_DIR/bin/mn" runtime stop >/dev/null 2>&1 || true
    "$VENV_DIR/bin/mn" runtime start
fi
