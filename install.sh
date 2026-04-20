#!/usr/bin/env bash

set -e

# Make sure we can read from tty even if piped
exec 3<&1

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

function spinner() {
    local pid=$1
    local msg=$2
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    tput civis >&3 2>/dev/null || true
    while kill -0 $pid 2>/dev/null; do
        local temp=${spinstr#?}
        printf "\r${MAGENTA}${BOLD}[%c]${RESET} ${msg}" "$spinstr" >&3
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
    done
    wait $pid
    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
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

print_header

# Interactive Prompts
echo -e "${CYAN}${BOLD}Configuration${RESET}" >&3
INSTALL_WEB_UI=$(ask "Do you want to install the Web UI?" "Y")
INSTALL_REDIS=$(ask "Do you want to install Redis via Docker?" "Y")
INSTALL_OPENSHELL=$(ask "Do you want to install OpenShell (or reuse existing one)?" "Y")
START_NOW=$(ask "Do you want to start the MirrorNeuron server automatically after install?" "Y")
echo "" >&3

INSTALL_DIR="${HOME}/.mirror_neuron"
BIN_DIR="${HOME}/.local/bin"
VENV_DIR="${HOME}/.local/share/mn_venv"

print_step "Checking Dependencies"

for cmd in git python3; do
    if ! command -v $cmd &> /dev/null; then
        print_error "'$cmd' is required but not installed."
        exit 1
    fi
done

if [ "$INSTALL_WEB_UI" = "Y" ] && ! command -v npm &> /dev/null; then
    print_error "'npm' is required for Web UI but not installed."
    exit 1
fi

if ! command -v docker &> /dev/null; then
    print_error "'docker' is required but not installed."
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
(
    python3 -m venv "$VENV_DIR" >/dev/null 2>&1
    "$VENV_DIR/bin/pip" install --upgrade pip >/dev/null 2>&1
    
    # Use local directories if available (for testing/development)
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    PARENT_DIR="$( dirname "$SCRIPT_DIR" )"
    
    if [ -d "$PARENT_DIR/mn-python-sdk" ]; then
        "$VENV_DIR/bin/pip" install "$PARENT_DIR/mn-python-sdk" >/dev/null 2>&1
    else
        "$VENV_DIR/bin/pip" install git+https://github.com/MirrorNeuronLab/mn-python-sdk.git >/dev/null 2>&1
    fi
    
    if [ -d "$PARENT_DIR/mn-cli" ]; then
        "$VENV_DIR/bin/pip" install "$PARENT_DIR/mn-cli" >/dev/null 2>&1
    else
        "$VENV_DIR/bin/pip" install git+https://github.com/MirrorNeuronLab/mn-cli.git >/dev/null 2>&1
    fi
    
    if [ -d "$PARENT_DIR/mn-api" ]; then
        "$VENV_DIR/bin/pip" install "$PARENT_DIR/mn-api" >/dev/null 2>&1
    else
        "$VENV_DIR/bin/pip" install git+https://github.com/MirrorNeuronLab/mn-api.git >/dev/null 2>&1
    fi
) &
spinner $! "Setting up virtualenv and installing Python packages"

if [ "$INSTALL_WEB_UI" = "Y" ]; then
    print_step "Installing Web UI"
    (
        UI_DIR="${INSTALL_DIR}_ui"
        if [ -d "$UI_DIR" ]; then
            cd "$UI_DIR"
            git pull origin main >/dev/null 2>&1 || true
        else
            git clone https://github.com/MirrorNeuronLab/mn-web-ui.git "$UI_DIR" >/dev/null 2>&1
            cd "$UI_DIR"
        fi
        npm install >/dev/null 2>&1
        npm run build >/dev/null 2>&1
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
    # Using Docker for standard OpenShell sandbox
    (
        if ! docker images | grep -q mirror-neuron-openshell; then
            # Placeholder: pull openshell or set it up
            # Assume there is an openshell docker image
            docker pull mirrorneuronlab/openshell:latest >/dev/null 2>&1 || true
        fi
    ) &
    spinner $! "Configuring OpenShell sandbox environment"
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
        if ! grep -q "$BIN_DIR" "$profile" 2>/dev/null; then
            echo -e "\n# Added by MirrorNeuron Installer" >> "$profile"
            echo "export PATH=\"\$BIN_DIR:\$PATH\"" >> "$profile"
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
