#!/usr/bin/env bash

set -euo pipefail

# Keep installer output visible even when a subcommand redirects stdout/stderr.
exec 3>&1

# Never let git/pip block the installer by asking for GitHub credentials.
export GIT_TERMINAL_PROMPT="${GIT_TERMINAL_PROMPT:-0}"
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new}"
export PIP_NO_INPUT="${PIP_NO_INPUT:-1}"

BOLD="\033[1m"
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
MAGENTA="\033[35m"
RESET="\033[0m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${MN_HOME:-}" ]; then
    export MIRROR_NEURON_HOME="$MN_HOME"
else
    export MIRROR_NEURON_HOME="${HOME}/.mn"
fi

INSTALL_DIR="${MIRROR_NEURON_HOME}"
BIN_DIR="${HOME}/.local/bin"
VENV_DIR="${HOME}/.local/share/mn_venv"
UI_DIR="${INSTALL_DIR}/webui"
LEGACY_UI_DIR="${INSTALL_DIR}_ui"
RUNTIME_COMPOSE_TEMPLATE="${SCRIPT_DIR}/docker-compose.yml"
RUNTIME_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
RUNTIME_COMPOSE_ENV="${INSTALL_DIR}/docker-compose.env"
CORE_REPO="${MN_CORE_REPO:-MirrorNeuronLab/MirrorNeuron}"
CORE_RELEASE_TAG="${MN_CORE_RELEASE_TAG:-latest}"
CORE_ASSET_URL="${MN_CORE_ASSET_URL:-}"
SKILLS_REPO="${MN_SKILLS_REPO:-MirrorNeuronLab/mn-skills}"
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
INSTALL_METADATA_FILE="${INSTALL_DIR}/install_metadata.json"
MN_MANAGED_PYTHON="${MN_MANAGED_PYTHON:-1}"
MN_MANAGED_PYTHON_VERSION="${MN_MANAGED_PYTHON_VERSION:-3.11}"
MN_MANAGED_PYTHON_ROOT="${MN_MANAGED_PYTHON_DIR:-${HOME}/.local/share/mn_python}"
MN_UV_ROOT="${MN_UV_DIR:-${HOME}/.local/share/mn_uv}"
MN_UV_BIN=""
MN_PYTHON_BIN=""

INSTALL_WEB_UI="Y"
INSTALL_REDIS="Y"
INSTALL_CONTEXT_ENGINE="Y"
INSTALL_OPENSHELL="Y"
INSTALL_PYTHON_SDK="Y"
INSTALL_BLUEPRINT_SUPPORT_SKILL="Y"
INSTALL_CLI="Y"
INSTALL_API="Y"
START_NOW="Y"
REINSTALL="Y"
NON_INTERACTIVE="N"

function print_header() {
    echo -e "${MAGENTA}${BOLD}" >&3
    echo "  __  __ _                     _   _                           " >&3
    echo " |  \/  (_)_ __ _ __ ___  _ __| \ | | ___ _   _ _ __ ___  _ __ " >&3
    echo " | |\/| | | '__| '__/ _ \| '__|  \| |/ _ \ | | | '__/ _ \| '_ \\" >&3
    echo " | |  | | | |  | | | (_) | |  | |\  |  __/ |_| | | | (_) | | | |" >&3
    echo " |_|  |_|_|_|  |_|  \___/|_|  |_| \_|\___|\__,_|_|  \___/|_| |_|" >&3
    echo -e "${RESET}" >&3
    echo -e "${BLUE}${BOLD} => Welcome to the MirrorNeuron Released Package Installer${RESET}\n" >&3
}

function print_step() { echo -e "${CYAN}${BOLD}==>${RESET} ${BOLD}$1${RESET}" >&3; }
function print_success() { echo -e "${GREEN}${BOLD}==>${RESET} ${GREEN}$1${RESET}" >&3; }
function print_error() { echo -e "${RED}${BOLD}==>${RESET} ${RED}$1${RESET}" >&3; }
function print_warning() { echo -e "${YELLOW}${BOLD}==>${RESET} ${YELLOW}$1${RESET}" >&3; }

function usage() {
    local script_name="${MN_INSTALL_SCRIPT_NAME:-$(basename "$0")}"
    cat >&3 <<EOF
Usage: ./$script_name [options]

Installs MirrorNeuron from released artifacts and packages.

Options:
  --yes                         Run non-interactively with defaults and flags.
  --no-reinstall                Keep an existing install instead of overwriting it.
  --web-ui / --no-web-ui        Enable or skip the Web UI npm package.
  --redis / --no-redis          Enable or skip Redis Docker setup.
  --context-engine / --no-context-engine
                                Enable or skip Membrane context engine setup.
  --openshell / --no-openshell  Enable or skip OpenShell gateway setup.
  --start / --no-start          Start or skip starting MirrorNeuron after install.

Python component options:
  --python-components LIST      Install only these components: sdk,skill,cli,api.
                                Use all or none as shortcuts.
  --python-sdk / --no-python-sdk
  --skill / --no-skill          Blueprint support skill from GitHub.
  --cli / --no-cli
  --api / --no-api

Release/source options:
  --core-release-tag TAG        Same as MN_CORE_RELEASE_TAG.
  --core-asset-url URL          Same as MN_CORE_ASSET_URL.
  --python PATH                 Same as MN_PYTHON. Must be Python 3.11+.
  --no-managed-python           Do not use uv to install a private Python runtime.
  MN_HOME=/path                 Override the runtime state directory. Defaults to ${HOME}/.mn.
  --skills-repo OWNER/REPO      Same as MN_SKILLS_REPO.
  --skills-git-url URL          Same as MN_SKILLS_GIT_URL.
  --membrane-repo OWNER/REPO    Same as MN_MEMBRANE_REPO.
  --membrane-git-url URL        Same as MN_MEMBRANE_GIT_URL.
  -h, --help                    Show this help.

Examples:
  ./$script_name --yes --no-web-ui
  ./$script_name --yes --no-web-ui --python-components sdk,api
  MN_PYTHON=/opt/homebrew/bin/python3.11 ./$script_name --yes
  ./$script_name --yes --core-release-tag v1.1.0 --no-web-ui
EOF
}

function set_python_components() {
    local value="$1"
    local component
    local -a components

    INSTALL_PYTHON_SDK="N"
    INSTALL_BLUEPRINT_SUPPORT_SKILL="N"
    INSTALL_CLI="N"
    INSTALL_API="N"

    IFS=',' read -r -a components <<< "$value"
    for component in "${components[@]}"; do
        component="$(echo "$component" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
        case "$component" in
            all)
                INSTALL_PYTHON_SDK="Y"
                INSTALL_BLUEPRINT_SUPPORT_SKILL="Y"
                INSTALL_CLI="Y"
                INSTALL_API="Y"
                ;;
            none)
                ;;
            sdk|python-sdk)
                INSTALL_PYTHON_SDK="Y"
                ;;
            skill|skills|blueprint-support|blueprint-support-skill)
                INSTALL_BLUEPRINT_SUPPORT_SKILL="Y"
                ;;
            cli)
                INSTALL_CLI="Y"
                ;;
            api)
                INSTALL_API="Y"
                ;;
            "")
                ;;
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
        --yes|-y) NON_INTERACTIVE="Y" ;;
        --no-reinstall) REINSTALL="N" ;;
        --web-ui) INSTALL_WEB_UI="Y" ;;
        --no-web-ui) INSTALL_WEB_UI="N" ;;
        --redis) INSTALL_REDIS="Y" ;;
        --no-redis) INSTALL_REDIS="N" ;;
        --context-engine) INSTALL_CONTEXT_ENGINE="Y" ;;
        --no-context-engine) INSTALL_CONTEXT_ENGINE="N" ;;
        --openshell) INSTALL_OPENSHELL="Y" ;;
        --no-openshell) INSTALL_OPENSHELL="N" ;;
        --start) START_NOW="Y" ;;
        --no-start) START_NOW="N" ;;
        --python-sdk) INSTALL_PYTHON_SDK="Y" ;;
        --no-python-sdk) INSTALL_PYTHON_SDK="N" ;;
        --skill|--skills) INSTALL_BLUEPRINT_SUPPORT_SKILL="Y" ;;
        --no-skill|--no-skills) INSTALL_BLUEPRINT_SUPPORT_SKILL="N" ;;
        --cli) INSTALL_CLI="Y" ;;
        --no-cli) INSTALL_CLI="N" ;;
        --api) INSTALL_API="Y" ;;
        --no-api) INSTALL_API="N" ;;
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
        --core-release-tag)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--core-release-tag requires a value."
                usage
                exit 1
            fi
            CORE_RELEASE_TAG="$1"
            ;;
        --core-release-tag=*)
            CORE_RELEASE_TAG="${1#*=}"
            ;;
        --core-asset-url)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--core-asset-url requires a value."
                usage
                exit 1
            fi
            CORE_ASSET_URL="$1"
            ;;
        --core-asset-url=*)
            CORE_ASSET_URL="${1#*=}"
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
        --skills-repo)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--skills-repo requires a value."
                usage
                exit 1
            fi
            SKILLS_REPO="$1"
            ;;
        --skills-repo=*)
            SKILLS_REPO="${1#*=}"
            ;;
        --skills-git-url)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--skills-git-url requires a value."
                usage
                exit 1
            fi
            MN_SKILLS_GIT_URL="$1"
            ;;
        --skills-git-url=*)
            MN_SKILLS_GIT_URL="${1#*=}"
            ;;
        --membrane-repo)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--membrane-repo requires a value."
                usage
                exit 1
            fi
            MEMBRANE_REPO="$1"
            ;;
        --membrane-repo=*)
            MEMBRANE_REPO="${1#*=}"
            ;;
        --membrane-git-url)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--membrane-git-url requires a value."
                usage
                exit 1
            fi
            MEMBRANE_GIT_URL="$1"
            ;;
        --membrane-git-url=*)
            MEMBRANE_GIT_URL="${1#*=}"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

function run_quiet() {
    local label="$1"
    shift
    local log_dir="${TMPDIR:-/tmp}/mirror_neuron_install"
    mkdir -p "$log_dir"
    local log_file="${log_dir}/${label//[^A-Za-z0-9_.-]/_}.$$.log"

    if ! "$@" >"$log_file" 2>&1; then
        print_error "$label failed. Log: $log_file"
        tail -n 30 "$log_file" >&3 2>/dev/null || true
        exit 1
    fi
}

function try_quiet() {
    local label="$1"
    shift
    local log_dir="${TMPDIR:-/tmp}/mirror_neuron_install"
    mkdir -p "$log_dir"
    LAST_LOG_FILE="${log_dir}/${label//[^A-Za-z0-9_.-]/_}.$$.log"

    "$@" >"$LAST_LOG_FILE" 2>&1
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
    local script_name="${MN_INSTALL_SCRIPT_NAME:-$(basename "$0")}"
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
    print_error "You can also rerun with: MN_PYTHON=/opt/homebrew/bin/python3.11 ./$script_name"
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

function should_install_python_packages() {
    [ "$INSTALL_PYTHON_SDK" = "Y" ] || \
    [ "$INSTALL_BLUEPRINT_SUPPORT_SKILL" = "Y" ] || \
    [ "$INSTALL_CLI" = "Y" ] || \
    [ "$INSTALL_API" = "Y" ] || \
    [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]
}

function validate_selections() {
    if [ "$START_NOW" = "Y" ] && [ "$INSTALL_CLI" != "Y" ]; then
        print_warning "Automatic start requires the CLI package; disabling start."
        START_NOW="N"
    fi

    if [ "$INSTALL_WEB_UI" = "Y" ] && [ "$INSTALL_API" != "Y" ]; then
        print_warning "Installing Web UI without the API package. The UI will need an API service from another install."
    fi
}

function docker_platform() {
    local arch
    arch="$(docker version --format '{{.Server.Arch}}' 2>/dev/null || uname -m)"
    case "$arch" in
        arm64|aarch64) echo "linux-arm64" ;;
        amd64|x86_64) echo "linux-x64" ;;
        *)
            print_error "Unsupported Docker architecture '$arch'. Expected amd64/x86_64 or arm64/aarch64."
            exit 1
            ;;
    esac
}

function resolve_core_release_tag() {
    local effective_url tag

    if [ "$CORE_RELEASE_TAG" != "latest" ]; then
        printf '%s' "$CORE_RELEASE_TAG"
        return 0
    fi

    effective_url="$(curl_github -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/${CORE_REPO}/releases/latest")"
    tag="${effective_url##*/releases/tag/}"
    tag="${tag%%\?*}"

    if [ -z "$tag" ] || [ "$tag" = "$effective_url" ]; then
        local script_name="${MN_INSTALL_SCRIPT_NAME:-$(basename "$0")}"
        print_error "Could not resolve the latest MirrorNeuron release tag from $effective_url."
        print_error "Set MN_CORE_RELEASE_TAG explicitly, for example: MN_CORE_RELEASE_TAG=v1.1.0 ./$script_name"
        exit 1
    fi

    printf '%s' "$tag"
}

function core_asset_url_for_tag() {
    local tag="$1"
    local platform="$2"

    printf 'https://github.com/%s/releases/download/%s/MirrorNeuron-%s-%s-otp-release.tar.gz' "$CORE_REPO" "$tag" "$tag" "$platform"
}

function install_core_from_release() {
    local platform tag asset_url work_dir tarball context_dir
    platform="$(docker_platform)"
    work_dir="${TMPDIR:-/tmp}/mirror_neuron_core_release.$$"
    tarball="$work_dir/core.tar.gz"
    context_dir="$work_dir/docker-context"

    mkdir -p "$work_dir" "$context_dir"

    if [ -n "$CORE_ASSET_URL" ]; then
        tag="$CORE_RELEASE_TAG"
        asset_url="$CORE_ASSET_URL"
    else
        tag="$(resolve_core_release_tag)"
        asset_url="$(core_asset_url_for_tag "$tag" "$platform")"
    fi

    print_success "Using MirrorNeuron core release $tag for Docker platform $platform."
    run_quiet "download-core-release" curl_github -fL "$asset_url" -o "$tarball"

    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    tar -xzf "$tarball" -C "$INSTALL_DIR"

    cp -R "$INSTALL_DIR/mirror_neuron" "$context_dir/mirror_neuron"
    cat > "$context_dir/Dockerfile" <<'EOF'
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    libgcc-s1 \
    libstdc++6 \
    libssl3 \
    ncurses-bin \
    openssl \
    procps \
    && rm -rf /var/lib/apt/lists/*

ARG OPENSHELL_VERSION=v0.0.47
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      arm64) openshell_target="aarch64-unknown-linux-musl"; openshell_sha="a6aa05593aa5bd6936bbb87fa3958510c1a6d82ef11b8ed8498e884de50847c0" ;; \
      amd64) openshell_target="x86_64-unknown-linux-musl"; openshell_sha="75ea23c19c23a931ac34b274f719c60dd20c6f788f2a4551862ec17572d84c17" ;; \
      *) echo "unsupported architecture for OpenShell: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fLsS -o /tmp/openshell.tar.gz \
      "https://github.com/NVIDIA/OpenShell/releases/download/${OPENSHELL_VERSION}/openshell-${openshell_target}.tar.gz"; \
    echo "${openshell_sha}  /tmp/openshell.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/openshell.tar.gz -C /usr/local/bin openshell; \
    chmod 0755 /usr/local/bin/openshell; \
    rm -f /tmp/openshell.tar.gz; \
    openshell --version

WORKDIR /opt/mirror_neuron
COPY mirror_neuron /opt/mirror_neuron

ARG CORE_RELEASE_TAG
LABEL org.opencontainers.image.version="${CORE_RELEASE_TAG}"

ENV HOME=/opt/mirror_neuron
EXPOSE 55051 4369 54370

CMD ["bin/mirror_neuron", "foreground"]
EOF

    docker build --build-arg "CORE_RELEASE_TAG=$tag" -t mirror-neuron-core:latest "$context_dir" >/dev/null
    cat > "$INSTALL_METADATA_FILE" <<EOF
{
  "core_release_tag": "$tag",
  "core_platform": "$platform",
  "core_asset_url": "$asset_url",
  "updated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
    rm -rf "$work_dir"
}

function install_python_packages() {
    "$MN_PYTHON_BIN" -m venv "$VENV_DIR" >/dev/null 2>&1
    run_quiet "pip-upgrade" "$VENV_DIR/bin/pip" install --upgrade pip
    if [ "$INSTALL_PYTHON_SDK" = "Y" ]; then
        run_quiet "install-mirrorneuron-python-sdk" "$VENV_DIR/bin/pip" install --upgrade mirrorneuron-python-sdk
    fi
    if [ "$INSTALL_BLUEPRINT_SUPPORT_SKILL" = "Y" ]; then
        install_blueprint_support_skill
    fi
    if [ "$INSTALL_CLI" = "Y" ]; then
        run_quiet "install-mirrorneuron-cli" "$VENV_DIR/bin/pip" install --upgrade mirrorneuron-cli
    fi
    if [ "$INSTALL_API" = "Y" ]; then
        run_quiet "install-mirrorneuron-api" "$VENV_DIR/bin/pip" install --upgrade mirrorneuron-api
    fi
    if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
        run_quiet "install-membrane-python-sdk" "$VENV_DIR/bin/pip" install --upgrade mirrorneuron-membrane-python-sdk
    fi
}

function normalize_git_url() {
    local url="$1"
    if [[ "$url" == git@github.com:* ]]; then
        url="ssh://git@github.com/${url#git@github.com:}"
    fi
    printf '%s' "$url"
}

function skill_requirement_for_url() {
    local url
    url="$(normalize_git_url "$1")"

    if [[ "$url" != git+* ]]; then
        url="git+$url"
    fi

    if [[ "$url" != *"#"* ]]; then
        url="${url}#subdirectory=blueprint_support_skill"
    elif [[ "$url" != *"subdirectory="* ]]; then
        url="${url}&subdirectory=blueprint_support_skill"
    fi

    printf 'mirrorneuron-blueprint-support-skill[webui] @ %s' "$url"
}

function install_blueprint_support_skill() {
    local urls=()
    local url req last_log

    if [ -n "${MN_SKILLS_GIT_URL:-}" ]; then
        urls+=("$MN_SKILLS_GIT_URL")
    else
        urls+=(
            "https://github.com/${SKILLS_REPO}.git"
            "ssh://git@github.com/${SKILLS_REPO}.git"
        )
    fi

    for url in "${urls[@]}"; do
        req="$(skill_requirement_for_url "$url")"
        if try_quiet "install-blueprint-support-skill-github" "$VENV_DIR/bin/pip" install --upgrade "$req"; then
            return 0
        fi
        last_log="$LAST_LOG_FILE"
    done

    print_error "install-blueprint-support-skill-github failed. Tried GitHub URLs:"
    for url in "${urls[@]}"; do
        echo "  - $(normalize_git_url "$url")" >&3
    done
    if [ -n "${last_log:-}" ]; then
        echo "Last log: $last_log" >&3
        tail -n 30 "$last_log" >&3 2>/dev/null || true
    fi
    exit 1
}

function context_engine_git_url() {
    if [ -n "$MEMBRANE_GIT_URL" ]; then
        printf '%s' "$MEMBRANE_GIT_URL"
    else
        printf 'https://github.com/%s.git' "$MEMBRANE_REPO"
    fi
}

function local_context_engine_dir() {
    local script_dir candidate
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for candidate in \
        "${MN_MEMBRANE_DIR:-}" \
        "$script_dir/../Membrane" \
        "$PWD/Membrane" \
        "$PWD/../Membrane" \
        "$HOME/Projects/mirror-neuron-set/Membrane" \
        "$MEMBRANE_DIR"; do
        if [ -n "$candidate" ] && [ -f "$candidate/Dockerfile" ]; then
            (cd "$candidate" && pwd)
            return 0
        fi
    done
    return 1
}

function ensure_context_engine_source() {
    local source_dir
    source_dir="$(local_context_engine_dir || true)"
    if [ -n "$source_dir" ]; then
        printf '%s' "$source_dir"
        return 0
    fi

    mkdir -p "$(dirname "$MEMBRANE_DIR")"
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
    ensure_context_engine_source >/dev/null
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
    local model_runner_model profiles redis_bind_host persisted_redis_port redis_port network_token redis_password mn_cookie grpc_auth_token grpc_admin_token
    if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
        ensure_context_engine_source >/dev/null
    fi
    model_runner_model="${MN_CONTEXT_MODEL_RUNNER_MODEL:-hf.co/homerquan/mn-context-engine-model-v-Q4_K_M}"
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
MN_CONTEXT_MODEL_RUNNER_MODEL=${model_runner_model}
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
MN_DOCKER_NETWORK_MODE=${MN_DOCKER_NETWORK_MODE:-bridge}
MN_DOCKER_NETWORK_NAME=${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}
MN_DOCKER_NETWORK_EXTERNAL=${MN_DOCKER_NETWORK_EXTERNAL:-false}
MN_DOCKER_NETWORK_DRIVER=${MN_DOCKER_NETWORK_DRIVER:-bridge}
MN_DOCKER_NETWORK_ATTACHABLE=${MN_DOCKER_NETWORK_ATTACHABLE:-false}
MN_NODE_ALIAS=${MN_NODE_ALIAS:-}
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
        runtime_compose up -d "${services[@]}" >/dev/null
    fi
}

function install_web_ui_package() {
    rm -rf "$LEGACY_UI_DIR"
    rm -rf "$UI_DIR"
    mkdir -p "$UI_DIR"

    cat > "$UI_DIR/package.json" <<'EOF'
{
  "name": "mirrorneuron-web-ui-installed",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite --host ${MN_WEB_UI_HOST:-localhost}"
  },
  "dependencies": {
    "@vitejs/plugin-react": "^6.0.1",
    "vite": "^8.0.4",
    "mirrorneuron-web-ui": "latest"
  },
  "devDependencies": {}
}
EOF

    cat > "$UI_DIR/vite.config.mjs" <<'EOF'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

const apiHost = process.env.MN_API_HOST || 'localhost'
const apiPort = process.env.MN_API_PORT || '54001'

export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      '/api': {
        target: `http://${apiHost}:${apiPort}`,
        changeOrigin: true,
      }
    }
  }
})
EOF

    run_quiet "web-ui-npm-install" npm --prefix "$UI_DIR" install
    cp -R "$UI_DIR/node_modules/mirrorneuron-web-ui/dist/." "$UI_DIR/"
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

function add_shell_profile_exports() {
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

    echo -e "${YELLOW}Please restart your terminal or run \`source ~/.zshrc\` to use the updated MirrorNeuron environment.${RESET}" >&3
}

print_header

echo -e "${CYAN}${BOLD}Configuration${RESET}" >&3
INSTALL_WEB_UI=$(ask "Do you want to install the Web UI from npm?" "$INSTALL_WEB_UI")
INSTALL_REDIS=$(ask "Do you want to install Redis via Docker?" "$INSTALL_REDIS")
INSTALL_CONTEXT_ENGINE=$(ask "Do you want to install/start the Membrane context engine?" "$INSTALL_CONTEXT_ENGINE")
INSTALL_OPENSHELL=$(ask "Do you want to install/start the OpenShell gateway for sandbox workers?" "$INSTALL_OPENSHELL")
INSTALL_PYTHON_SDK=$(ask "Do you want to install the Python SDK from PyPI?" "$INSTALL_PYTHON_SDK")
INSTALL_BLUEPRINT_SUPPORT_SKILL=$(ask "Do you want to install the blueprint support skill from GitHub?" "$INSTALL_BLUEPRINT_SUPPORT_SKILL")
INSTALL_CLI=$(ask "Do you want to install the CLI from PyPI?" "$INSTALL_CLI")
INSTALL_API=$(ask "Do you want to install the API from PyPI?" "$INSTALL_API")
START_NOW=$(ask "Do you want to start the MirrorNeuron server automatically after install?" "$START_NOW")
echo "" >&3

validate_selections

print_step "Checking dependencies"
require_cmd curl
require_cmd docker
require_file "$RUNTIME_COMPOSE_TEMPLATE" "MirrorNeuron runtime Docker Compose template"
if should_install_python_packages; then
    resolve_python_runtime
    ensure_pip
fi
if [ "$INSTALL_BLUEPRINT_SUPPORT_SKILL" = "Y" ] || [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
    require_cmd git
fi

if [ "$INSTALL_WEB_UI" = "Y" ]; then
    require_cmd npm
fi

if ! docker info >/dev/null 2>&1; then
    print_error "Docker is not running. Please start Docker first."
    exit 1
fi

print_success "All dependencies found."

if [ -d "$INSTALL_DIR" ] || [ -f "$BIN_DIR/mn" ]; then
    print_warning "MirrorNeuron appears to be already installed."
    REINSTALL=$(ask "Do you want to reinstall (overwrite old ones)?" "$REINSTALL")
    if [ "$REINSTALL" = "N" ]; then
        echo -e "${YELLOW}Installation cancelled by user.${RESET}" >&3
        exit 0
    fi
    echo "" >&3
    rm -rf "$INSTALL_DIR" "$VENV_DIR" "$LEGACY_UI_DIR" "$BIN_DIR/mn" "$BIN_DIR/mn-api"
fi

print_step "Installing MirrorNeuron Core from GitHub Release"
( install_core_from_release ) &
spinner $! "Downloading OTP release and building Docker image"
write_runtime_compose_files

if should_install_python_packages; then
    print_step "Installing selected Python components"
    ( install_python_packages ) &
    spinner $! "Setting up virtualenv and installing Python packages"
else
    print_warning "Skipping Python component installation."
fi

if [ "$INSTALL_WEB_UI" = "Y" ]; then
    print_step "Installing Web UI from npm"
    ( install_web_ui_package ) &
    spinner $! "Installing mirrorneuron-web-ui npm package"
fi

if [ "$INSTALL_REDIS" = "Y" ] || [ "$INSTALL_CONTEXT_ENGINE" = "Y" ] || [ "$INSTALL_OPENSHELL" = "Y" ]; then
    print_step "Setting up Docker runtime services with Compose"
    if [ "$INSTALL_OPENSHELL" = "Y" ]; then
        install_openshell_cli
    fi
    ( start_runtime_compose_sidecars ) &
    spinner $! "Docker runtime services are available"
fi

print_step "Creating symlinks"
mkdir -p "$BIN_DIR" "$INSTALL_DIR"
rm -f "$BIN_DIR/mn" "$BIN_DIR/mn-api" "$INSTALL_DIR/mn"
if [ "$INSTALL_CLI" = "Y" ]; then
    ln -s "$VENV_DIR/bin/mn" "$BIN_DIR/mn"
    ln -s "$VENV_DIR/bin/mn" "$INSTALL_DIR/mn"
fi
if [ "$INSTALL_API" = "Y" ]; then
    ln -s "$VENV_DIR/bin/mn-api" "$BIN_DIR/mn-api"
fi
print_success "Symlinks created in $BIN_DIR and $INSTALL_DIR."

echo "" >&3
print_success "MirrorNeuron installation successfully completed!" >&3
if [ "$INSTALL_CLI" = "Y" ]; then
    echo -e "CLI is available as ${YELLOW}mn${RESET}." >&3
fi
if [ "$INSTALL_API" = "Y" ]; then
    echo -e "API is available as ${YELLOW}mn-api${RESET}." >&3
fi
if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
    echo -e "Membrane context engine is available on ${YELLOW}${MN_CONTEXT_ADDR:-localhost:50052}${RESET}." >&3
fi
if [ "$INSTALL_CLI" = "Y" ] || [ "$INSTALL_API" = "Y" ]; then
    add_shell_profile_exports
fi

echo -e "\n${BOLD}Quick Start:${RESET}" >&3
if [ "$INSTALL_CLI" = "Y" ]; then
    echo -e "  1. Start the server (Core & API): ${GREEN}mn runtime start${RESET}" >&3
fi
if [ "$INSTALL_WEB_UI" = "Y" ]; then
    echo -e "  2. Start the UI:   ${GREEN}mn runtime start${RESET} starts it with the services${RESET}" >&3
fi
if [ "$INSTALL_CLI" = "Y" ]; then
    echo -e "  3. Use the CLI:    ${GREEN}mn node list${RESET}\n" >&3
fi

if [ "$START_NOW" = "Y" ]; then
    print_step "Starting MirrorNeuron Server..."
    "$VENV_DIR/bin/mn" runtime start
fi
