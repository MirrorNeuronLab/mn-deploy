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
           [ -d "$candidate/mn-skills/blueprint_support_skill" ] &&
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

INSTALL_DIR="${HOME}/.mirror_neuron"
BIN_DIR="${HOME}/.local/bin"
VENV_DIR="${HOME}/.local/share/mn_venv"
MN_PYTHON_BIN=""
SOURCE_WORKSPACE="$(find_source_workspace || true)"

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
    rm -rf "$INSTALL_DIR" "$VENV_DIR" "${INSTALL_DIR}_ui" "$BIN_DIR/mn" "$BIN_DIR/mn-api"
fi

# Interactive Prompts
echo -e "${CYAN}${BOLD}Configuration${RESET}" >&3
INSTALL_WEB_UI=$(ask "Do you want to install the Web UI?" "Y")
INSTALL_REDIS=$(ask "Do you want to install Redis via Docker?" "Y")
INSTALL_OPENSHELL=$(ask "Do you want to install/start the OpenShell gateway for sandbox workers?" "Y")
START_NOW=$(ask "Do you want to start the MirrorNeuron server automatically after install?" "Y")
echo "" >&3

print_step "Checking Dependencies"

for cmd in git; do
    if ! command -v $cmd &> /dev/null; then
        print_error "'$cmd' is required but not installed."
        exit 1
    fi
done
resolve_python_runtime

if [ "$INSTALL_WEB_UI" = "Y" ] && ! command -v npm &> /dev/null; then
    print_error "'npm' is required for Web UI but not installed."
    exit 1
fi

if ! command -v docker &> /dev/null; then
    print_error "'docker' is required but not installed."
    exit 1
fi
if [ "$INSTALL_OPENSHELL" = "Y" ] && ! command -v curl >/dev/null 2>&1; then
    print_error "'curl' is required to install/start OpenShell."
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

EXPOSE 50051

# Set the default command
CMD ["mix", "run", "--no-halt"]
EOF
    fi

    docker build -t mirror-neuron-core . >/dev/null 2>&1
) &
spinner $! "Cloning and building Core (Docker image mirror-neuron-core)"

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
        run_quiet "install-blueprint-support-skill-local" "$VENV_DIR/bin/pip" install "$SOURCE_WORKSPACE/mn-skills/blueprint_support_skill[webui]"
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
) &
spinner $! "Setting up virtualenv and installing Python packages"

if [ "$INSTALL_WEB_UI" = "Y" ]; then
    print_step "Installing Web UI"
    if [ -n "$SOURCE_WORKSPACE" ] && [ -d "$SOURCE_WORKSPACE/mn-web-ui" ]; then
        print_success "Using local Web UI source from $SOURCE_WORKSPACE/mn-web-ui."
    fi
    (
        UI_DIR="${INSTALL_DIR}_ui"
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

if [ "$INSTALL_REDIS" = "Y" ]; then
    print_step "Setting up Redis"
    (
        if ! docker ps | grep -q mirror-neuron-redis; then
            docker run -d --name mirror-neuron-redis -p 6379:6379 redis:7 >/dev/null 2>&1 || true
        fi
    ) &
    spinner $! "Starting Redis via Docker"
fi

if [ "$INSTALL_OPENSHELL" = "Y" ]; then
    print_step "Setting up OpenShell"
    ( setup_openshell_gateway ) &
    spinner $! "OpenShell gateway is available"
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

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo -e "\n${YELLOW}${BOLD}Note:${RESET} ${YELLOW}$BIN_DIR is not in your PATH.${RESET}" >&3
    
    DETECTED_PROFILES=()
    [ -f "$HOME/.zshrc" ] && DETECTED_PROFILES+=("$HOME/.zshrc")
    [ -f "$HOME/.bashrc" ] && DETECTED_PROFILES+=("$HOME/.bashrc")
    [ -f "$HOME/.bash_profile" ] && DETECTED_PROFILES+=("$HOME/.bash_profile")
    [ -f "$HOME/.profile" ] && DETECTED_PROFILES+=("$HOME/.profile")

    if [ ${#DETECTED_PROFILES[@]} -eq 0 ]; then
        DETECTED_PROFILES+=("$HOME/.profile")
    fi

    for profile in "${DETECTED_PROFILES[@]}"; do
        if ! grep -q "export PATH=\"$BIN_DIR:\$PATH\"" "$profile" 2>/dev/null; then
            echo -e "\n# Added by MirrorNeuron Installer" >> "$profile"
            echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$profile"
            echo -e "Automatically added to ${CYAN}$profile${RESET}" >&3
        fi
    done
    
    echo -e "${YELLOW}Please restart your terminal or run \`source ~/.zshrc\` (or your shell's configuration file) to use the 'mn' command.${RESET}" >&3
fi

echo -e "\n${BOLD}Quick Start:${RESET}" >&3
echo -e "  1. Start the server (Core & API): ${GREEN}mn start${RESET}" >&3
if [ "$INSTALL_WEB_UI" = "Y" ]; then
    echo -e "  2. Start the UI:   ${GREEN}cd ${INSTALL_DIR}_ui && npm run dev${RESET}" >&3
fi
echo -e "  3. Use the CLI:    ${GREEN}mn nodes${RESET}\n" >&3

if [ "$START_NOW" = "Y" ]; then
    print_step "Starting MirrorNeuron Server..."
    "$VENV_DIR/bin/mn" start
fi
