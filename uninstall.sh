#!/usr/bin/env bash

set -e

# Keep uninstaller output visible even when prompts are piped.
exec 3>&1

# Define Colors
BOLD="\033[1m"
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
    echo -e "${RED}${BOLD} => Welcome to the MirrorNeuron Uninstaller${RESET}\n" >&3
}

function print_step() { echo -e "${CYAN}${BOLD}==>${RESET} ${BOLD}$1${RESET}" >&3; }
function print_success() { echo -e "${GREEN}${BOLD}==>${RESET} ${GREEN}$1${RESET}" >&3; }
function print_warning() { echo -e "${YELLOW}${BOLD}==>${RESET} ${YELLOW}$1${RESET}" >&3; }

ASSUME_YES="N"

function usage() {
    cat >&3 <<EOF
Usage: ./uninstall.sh [options]

Options:
  --yes, -y   Run non-interactively and answer yes to prompts.
  -h, --help  Show this help.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES="Y" ;;
        -h|--help) usage; exit 0 ;;
        *)
            print_warning "Unknown option: $arg"
            usage
            exit 1
            ;;
    esac
done

function ask() {
    local prompt="$1"
    local default="$2"
    local answer

    if [ "$ASSUME_YES" = "Y" ]; then
        echo "Y"
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

print_header

echo -e "${RED}${BOLD}Warning: This will permanently remove all MirrorNeuron components and configurations from your system.${RESET}" >&3
CONFIRM=$(ask "Are you sure you want to proceed?" "N")

if [ "$CONFIRM" != "Y" ]; then
    print_warning "Uninstallation aborted."
    exit 0
fi

INSTALL_DIR="${HOME}/.mirror_neuron"
UI_DIR="${INSTALL_DIR}_ui"
BIN_DIR="${HOME}/.local/bin"
VENV_DIR="${HOME}/.local/share/mn_venv"

print_step "Removing Symlinks"
rm -f "$BIN_DIR/mn" "$BIN_DIR/mn-api"
print_success "Removed mn and mn-api symlinks from $BIN_DIR"

print_step "Removing Python Virtual Environment"
if [ -d "$VENV_DIR" ]; then
    rm -rf "$VENV_DIR"
    print_success "Removed virtual environment at $VENV_DIR"
else
    print_success "Virtual environment not found, skipping."
fi

print_step "Removing Core Installation"
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    print_success "Removed core installation at $INSTALL_DIR"
else
    print_success "Core installation not found, skipping."
fi

print_step "Removing Web UI Installation"
if [ -d "$UI_DIR" ]; then
    rm -rf "$UI_DIR"
    print_success "Removed Web UI installation at $UI_DIR"
else
    print_success "Web UI installation not found, skipping."
fi

print_step "Removing Docker Containers and Images"
if command -v docker &> /dev/null; then
    REMOVE_CORE=$(ask "Do you want to stop and remove the Core container (mirror-neuron-core)?" "Y")
    if [ "$REMOVE_CORE" = "Y" ]; then
        if docker ps -a | grep -q mirror-neuron-core; then
            docker stop mirror-neuron-core >/dev/null 2>&1 || true
            docker rm mirror-neuron-core >/dev/null 2>&1 || true
            print_success "Removed Core container."
        else
            print_success "Core container not found, skipping."
        fi
        if docker images | grep -q mirror-neuron-core; then
            docker rmi mirror-neuron-core:latest >/dev/null 2>&1 || true
            print_success "Removed Core image."
        fi
    fi

    REMOVE_REDIS=$(ask "Do you want to stop and remove the Redis container (mirror-neuron-redis)?" "Y")
    if [ "$REMOVE_REDIS" = "Y" ]; then
        if docker ps -a | grep -q mirror-neuron-redis; then
            docker stop mirror-neuron-redis >/dev/null 2>&1 || true
            docker rm mirror-neuron-redis >/dev/null 2>&1 || true
            print_success "Removed Redis container."
        else
            print_success "Redis container not found, skipping."
        fi
    fi

    REMOVE_OPENSHELL=$(ask "Do you want to remove MirrorNeuron OpenShell gateway artifacts?" "Y")
    if [ "$REMOVE_OPENSHELL" = "Y" ]; then
        if command -v openshell >/dev/null 2>&1; then
            openshell gateway destroy --name openshell >/dev/null 2>&1 || true
        fi

        if docker ps -a --format '{{.Names}}' | grep -q '^openshell-cluster-openshell$'; then
            docker rm -f openshell-cluster-openshell >/dev/null 2>&1 || true
            print_success "Removed OpenShell gateway container."
        else
            print_success "OpenShell gateway container not found, skipping."
        fi

        removed_image="N"
        for image in \
            "ghcr.io/nvidia/openshell/cluster:0.0.16" \
            "ghcr.io/nvidia/openshell/cluster:latest" \
            "mirrorneuronlab/openshell:latest"; do
            if docker image inspect "$image" >/dev/null 2>&1; then
                docker rmi "$image" >/dev/null 2>&1 || true
                removed_image="Y"
            fi
        done

        if [ "$removed_image" = "Y" ]; then
            print_success "Removed OpenShell Docker image(s)."
        else
            print_success "OpenShell Docker images not found, skipping."
        fi

        OPENSHELL_CONTAINER_CONFIG_DIR="${OPENSHELL_CONTAINER_CONFIG_DIR:-$HOME/.config/openshell-mirror-neuron}"
        if [ -d "$OPENSHELL_CONTAINER_CONFIG_DIR" ]; then
            rm -rf "$OPENSHELL_CONTAINER_CONFIG_DIR"
            print_success "Removed MirrorNeuron OpenShell container config at $OPENSHELL_CONTAINER_CONFIG_DIR."
        else
            print_success "MirrorNeuron OpenShell container config not found, skipping."
        fi
    fi
else
    print_warning "Docker not installed, skipping container cleanup."
fi

echo "" >&3
print_success "MirrorNeuron uninstallation successfully completed! 🧹" >&3
