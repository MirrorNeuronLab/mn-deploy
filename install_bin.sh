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

INSTALL_DIR="${HOME}/.mirror_neuron"
BIN_DIR="${HOME}/.local/bin"
VENV_DIR="${HOME}/.local/share/mn_venv"
UI_DIR="${INSTALL_DIR}_ui"
CORE_REPO="${MN_CORE_REPO:-MirrorNeuronLab/MirrorNeuron}"
CORE_RELEASE_TAG="${MN_CORE_RELEASE_TAG:-latest}"
CORE_ASSET_URL="${MN_CORE_ASSET_URL:-}"
SKILLS_REPO="${MN_SKILLS_REPO:-MirrorNeuronLab/mn-skills}"
INSTALL_METADATA_FILE="${INSTALL_DIR}/install_metadata.json"
MN_MANAGED_PYTHON="${MN_MANAGED_PYTHON:-1}"
MN_MANAGED_PYTHON_VERSION="${MN_MANAGED_PYTHON_VERSION:-3.11}"
MN_MANAGED_PYTHON_ROOT="${MN_MANAGED_PYTHON_DIR:-${HOME}/.local/share/mn_python}"
MN_UV_ROOT="${MN_UV_DIR:-${HOME}/.local/share/mn_uv}"
MN_UV_BIN=""
MN_PYTHON_BIN=""

INSTALL_WEB_UI="Y"
INSTALL_REDIS="Y"
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
  --skills-repo OWNER/REPO      Same as MN_SKILLS_REPO.
  --skills-git-url URL          Same as MN_SKILLS_GIT_URL.
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

    openshell_bin="$(resolve_openshell_bin || true)"
    if [ -z "$openshell_bin" ]; then
        local installer="${TMPDIR:-/tmp}/mirror_neuron_openshell_install.sh"
        curl_github -fLsS https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh -o "$installer"
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
    [ "$INSTALL_API" = "Y" ]
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

ARG OPENSHELL_VERSION=v0.0.16
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      arm64) openshell_target="aarch64-unknown-linux-musl"; openshell_sha="7301b47e37f498e6535c0fa3c1f8db505d385719cbe94de10fc1dc69b83e37fb" ;; \
      amd64) openshell_target="x86_64-unknown-linux-musl"; openshell_sha="c95ffd08705f3fce6198e5cb9992fa4e8c5eea63b581758c761db5925b92fec5" ;; \
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
EXPOSE 50051 4369 9000-9010

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

function install_web_ui_package() {
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
const apiPort = process.env.MN_API_PORT || '4001'

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

function add_path_if_needed() {
    if [[ ":$PATH:" == *":$BIN_DIR:"* ]]; then
        return
    fi

    echo -e "\n${YELLOW}${BOLD}Note:${RESET} ${YELLOW}$BIN_DIR is not in your PATH.${RESET}" >&3

    local detected_profiles=()
    [ -f "$HOME/.zshrc" ] && detected_profiles+=("$HOME/.zshrc")
    [ -f "$HOME/.bashrc" ] && detected_profiles+=("$HOME/.bashrc")
    [ -f "$HOME/.bash_profile" ] && detected_profiles+=("$HOME/.bash_profile")
    [ -f "$HOME/.profile" ] && detected_profiles+=("$HOME/.profile")

    if [ ${#detected_profiles[@]} -eq 0 ]; then
        detected_profiles+=("$HOME/.profile")
    fi

    local profile
    for profile in "${detected_profiles[@]}"; do
        if ! grep -q "export PATH=\"$BIN_DIR:\$PATH\"" "$profile" 2>/dev/null; then
            echo -e "\n# Added by MirrorNeuron Installer" >> "$profile"
            echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$profile"
            echo -e "Automatically added to ${CYAN}$profile${RESET}" >&3
        fi
    done

    echo -e "${YELLOW}Please restart your terminal or run \`source ~/.zshrc\` to use the 'mn' command.${RESET}" >&3
}

print_header

echo -e "${CYAN}${BOLD}Configuration${RESET}" >&3
INSTALL_WEB_UI=$(ask "Do you want to install the Web UI from npm?" "$INSTALL_WEB_UI")
INSTALL_REDIS=$(ask "Do you want to install Redis via Docker?" "$INSTALL_REDIS")
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
if should_install_python_packages; then
    resolve_python_runtime
    ensure_pip
fi
require_cmd docker
if [ "$INSTALL_BLUEPRINT_SUPPORT_SKILL" = "Y" ]; then
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
    rm -rf "$INSTALL_DIR" "$VENV_DIR" "$UI_DIR" "$BIN_DIR/mn" "$BIN_DIR/mn-api"
fi

print_step "Installing MirrorNeuron Core from GitHub Release"
( install_core_from_release ) &
spinner $! "Downloading OTP release and building Docker image"

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

if [ "$INSTALL_REDIS" = "Y" ]; then
    print_step "Setting up Redis"
    (
        if ! docker ps --format '{{.Names}}' | grep -q '^mirror-neuron-redis$'; then
            docker rm -f mirror-neuron-redis >/dev/null 2>&1 || true
            docker run -d --name mirror-neuron-redis -p 6379:6379 redis:7 >/dev/null
        fi
    ) &
    spinner $! "Starting Redis via Docker"
fi

if [ "$INSTALL_OPENSHELL" = "Y" ]; then
    print_step "Setting up OpenShell"
    ( setup_openshell_gateway ) &
    spinner $! "OpenShell gateway is available"
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
if [ "$INSTALL_CLI" = "Y" ] || [ "$INSTALL_API" = "Y" ]; then
    add_path_if_needed
fi

echo -e "\n${BOLD}Quick Start:${RESET}" >&3
if [ "$INSTALL_CLI" = "Y" ]; then
    echo -e "  1. Start the server (Core & API): ${GREEN}mn start${RESET}" >&3
fi
if [ "$INSTALL_WEB_UI" = "Y" ]; then
    echo -e "  2. Start the UI:   ${GREEN}mn start${RESET} starts it with the services${RESET}" >&3
fi
if [ "$INSTALL_CLI" = "Y" ]; then
    echo -e "  3. Use the CLI:    ${GREEN}mn nodes${RESET}\n" >&3
fi

if [ "$START_NOW" = "Y" ]; then
    print_step "Starting MirrorNeuron Server..."
    "$VENV_DIR/bin/mn" start
fi
