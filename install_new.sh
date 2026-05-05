#!/usr/bin/env bash

set -euo pipefail

# Keep installer output visible even when a subcommand redirects stdout/stderr.
exec 3>&1

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
    if ! command -v "$1" >/dev/null 2>&1; then
        print_error "'$1' is required but not installed."
        exit 1
    fi
}

function ensure_pip() {
    if python3 -m pip --version >/dev/null 2>&1; then
        return
    fi

    print_warning "pip was not found for python3; trying ensurepip."
    python3 -m ensurepip --upgrade >/dev/null 2>&1 || {
        print_error "Could not install pip with ensurepip. Please install pip for python3 and rerun."
        exit 1
    }
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

function fetch_core_release_metadata() {
    local api_url
    if [ "$CORE_RELEASE_TAG" = "latest" ]; then
        api_url="https://api.github.com/repos/${CORE_REPO}/releases/latest"
    else
        api_url="https://api.github.com/repos/${CORE_REPO}/releases/tags/${CORE_RELEASE_TAG}"
    fi

    curl -fsSL "$api_url"
}

function json_field() {
    python3 -c '
import json
import sys

field = sys.argv[1]
data = json.load(sys.stdin)
value = data
for part in field.split("."):
    value = value[part]
print(value)
' "$1"
}

function core_asset_url() {
    local platform="$1"
    python3 -c '
import json
import sys

platform = sys.argv[1]
data = json.load(sys.stdin)
suffix = f"-{platform}-otp-release.tar.gz"

for asset in data.get("assets", []):
    name = asset.get("name", "")
    if name.endswith(suffix):
        print(asset["browser_download_url"])
        raise SystemExit(0)

available = "\n".join(sorted(asset.get("name", "") for asset in data.get("assets", [])))
raise SystemExit(f"Could not find OTP release asset ending with {suffix}. Available assets:\n{available}")
' "$platform"
}

function install_core_from_release() {
    local platform metadata tag asset_url work_dir tarball context_dir
    platform="$(docker_platform)"
    work_dir="${TMPDIR:-/tmp}/mirror_neuron_core_release.$$"
    tarball="$work_dir/core.tar.gz"
    context_dir="$work_dir/docker-context"

    mkdir -p "$work_dir" "$context_dir"
    metadata="$(fetch_core_release_metadata)"
    tag="$(printf '%s' "$metadata" | json_field tag_name)"
    asset_url="$(printf '%s' "$metadata" | core_asset_url "$platform")"

    print_success "Using MirrorNeuron core release $tag for Docker platform $platform."
    run_quiet "download-core-release" curl -fL "$asset_url" -o "$tarball"

    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    tar -xzf "$tarball" -C "$INSTALL_DIR"

    cp -R "$INSTALL_DIR/mirror_neuron" "$context_dir/mirror_neuron"
    cat > "$context_dir/Dockerfile" <<'EOF'
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    libgcc-s1 \
    libstdc++6 \
    libssl3 \
    ncurses-bin \
    openssl \
    procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/mirror_neuron
COPY mirror_neuron /opt/mirror_neuron

ENV HOME=/opt/mirror_neuron
EXPOSE 50051 4369 9000-9010

CMD ["bin/mirror_neuron", "foreground"]
EOF

    docker build -t mirror-neuron-core:latest "$context_dir" >/dev/null
    rm -rf "$work_dir"
}

function install_python_packages() {
    python3 -m venv "$VENV_DIR" >/dev/null 2>&1
    run_quiet "pip-upgrade" "$VENV_DIR/bin/pip" install --upgrade pip
    run_quiet "install-mirrorneuron-python-sdk" "$VENV_DIR/bin/pip" install --upgrade mirrorneuron-python-sdk
    run_quiet "install-mirrorneuron-blueprint-support-skill" "$VENV_DIR/bin/pip" install --upgrade "mirrorneuron-blueprint-support-skill[webui]"
    run_quiet "install-mirrorneuron-cli" "$VENV_DIR/bin/pip" install --upgrade mirrorneuron-cli
    run_quiet "install-mirrorneuron-api" "$VENV_DIR/bin/pip" install --upgrade mirrorneuron-api
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

if [ -d "$INSTALL_DIR" ] || [ -f "$BIN_DIR/mn" ]; then
    print_warning "MirrorNeuron appears to be already installed."
    REINSTALL=$(ask "Do you want to reinstall (overwrite old ones)?" "Y")
    if [ "$REINSTALL" = "N" ]; then
        echo -e "${YELLOW}Installation cancelled by user.${RESET}" >&3
        exit 0
    fi
    echo "" >&3
    rm -rf "$INSTALL_DIR" "$VENV_DIR" "$UI_DIR" "$BIN_DIR/mn" "$BIN_DIR/mn-api"
fi

echo -e "${CYAN}${BOLD}Configuration${RESET}" >&3
INSTALL_WEB_UI=$(ask "Do you want to install the Web UI from npm?" "Y")
INSTALL_REDIS=$(ask "Do you want to install Redis via Docker?" "Y")
INSTALL_OPENSHELL=$(ask "Do you want to install OpenShell (or reuse existing one)?" "Y")
START_NOW=$(ask "Do you want to start the MirrorNeuron server automatically after install?" "Y")
echo "" >&3

print_step "Checking dependencies"
require_cmd curl
require_cmd docker
require_cmd python3
ensure_pip

if [ "$INSTALL_WEB_UI" = "Y" ]; then
    require_cmd npm
fi

if ! docker info >/dev/null 2>&1; then
    print_error "Docker is not running. Please start Docker first."
    exit 1
fi

print_success "All dependencies found."

print_step "Installing MirrorNeuron Core from GitHub Release"
( install_core_from_release ) &
spinner $! "Downloading OTP release and building Docker image"

print_step "Installing Python CLI & API from PyPI"
( install_python_packages ) &
spinner $! "Setting up virtualenv and installing PyPI packages"

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
    (
        docker pull mirrorneuronlab/openshell:latest >/dev/null 2>&1 || true
    ) &
    spinner $! "Configuring OpenShell sandbox environment"
fi

print_step "Creating symlinks"
mkdir -p "$BIN_DIR" "$INSTALL_DIR"
rm -f "$BIN_DIR/mn" "$BIN_DIR/mn-api" "$INSTALL_DIR/mn"
ln -s "$VENV_DIR/bin/mn" "$BIN_DIR/mn"
ln -s "$VENV_DIR/bin/mn-api" "$BIN_DIR/mn-api"
ln -s "$VENV_DIR/bin/mn" "$INSTALL_DIR/mn"
print_success "Symlinks created in $BIN_DIR and $INSTALL_DIR."

echo "" >&3
print_success "MirrorNeuron installation successfully completed!" >&3
echo -e "CLI is available as ${YELLOW}mn${RESET}." >&3
echo -e "API is available as ${YELLOW}mn-api${RESET}." >&3

add_path_if_needed

echo -e "\n${BOLD}Quick Start:${RESET}" >&3
echo -e "  1. Start the server (Core & API): ${GREEN}mn start${RESET}" >&3
if [ "$INSTALL_WEB_UI" = "Y" ]; then
    echo -e "  2. Start the UI:   ${GREEN}mn start${RESET} starts it with the services${RESET}" >&3
fi
echo -e "  3. Use the CLI:    ${GREEN}mn nodes${RESET}\n" >&3

if [ "$START_NOW" = "Y" ]; then
    print_step "Starting MirrorNeuron Server..."
    "$VENV_DIR/bin/mn" start
fi
