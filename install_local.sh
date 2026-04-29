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
TS_SDK_DIR="${WORKSPACE_DIR}/mn-ts-sdk"
WEB_UI_DIR="${WORKSPACE_DIR}/mn-web-ui"
SKILLS_DIR="${WORKSPACE_DIR}/mn-skills"
BLUEPRINTS_DIR="${WORKSPACE_DIR}/mn-blueprints"
DOCS_DIR="${WORKSPACE_DIR}/mn-docs"
SYSTEM_TESTS_DIR="${WORKSPACE_DIR}/mn-system-tests"

INSTALL_WEB_UI="Y"
INSTALL_REDIS="Y"
INSTALL_OPENSHELL="N"
INSTALL_SKILLS="Y"
INSTALL_TS_SDK="Y"
START_NOW="N"
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
    echo -e "${BLUE}${BOLD} => MirrorNeuron Local Workspace Installer${RESET}\n" >&3
}

function print_step() { echo -e "${CYAN}${BOLD}==>${RESET} ${BOLD}$1${RESET}" >&3; }
function print_success() { echo -e "${GREEN}${BOLD}==>${RESET} ${GREEN}$1${RESET}" >&3; }
function print_error() { echo -e "${RED}${BOLD}==>${RESET} ${RED}$1${RESET}" >&3; }
function print_warning() { echo -e "${YELLOW}${BOLD}==>${RESET} ${YELLOW}$1${RESET}" >&3; }

function usage() {
    cat >&3 <<EOF
Usage: ./install_local.sh [options]

Installs MirrorNeuron from local sibling folders under:
  ${WORKSPACE_DIR}

Options:
  --yes                 Run non-interactively with defaults.
  --no-reinstall        Keep the existing venv/state where possible.
  --no-web-ui           Skip local Web UI npm install/build.
  --no-redis            Skip Redis Docker setup.
  --openshell           Try to use a local OpenShell folder if present.
  --no-skills           Skip editable install of packages under mn-skills.
  --no-ts-sdk           Skip local TypeScript SDK npm install/build.
  --start               Start MirrorNeuron after install.
  -h, --help            Show this help.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --yes) NON_INTERACTIVE="Y" ;;
        --no-reinstall) REINSTALL="N" ;;
        --no-web-ui) INSTALL_WEB_UI="N" ;;
        --no-redis) INSTALL_REDIS="N" ;;
        --openshell) INSTALL_OPENSHELL="Y" ;;
        --no-skills) INSTALL_SKILLS="N" ;;
        --no-ts-sdk) INSTALL_TS_SDK="N" ;;
        --start) START_NOW="Y" ;;
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

function core_container_running() {
    docker ps --format '{{.Names}}' | grep -q '^mirror-neuron-core$'
}

function start_core_container() {
    local cmd=("docker" "run" "-d" "--name" "mirror-neuron-core")

    if [ "$(uname -s)" = "Darwin" ]; then
        cmd+=("-p" "50051:50051" "-p" "4369:4369")
        for port in $(seq 9000 9010); do
            cmd+=("-p" "${port}:${port}")
        done
        cmd+=("-e" "MIRROR_NEURON_REDIS_URL=redis://host.docker.internal:6379/0")
        cmd+=("-e" "MIRROR_NEURON_EXECUTOR_MAX_CONCURRENCY=50")
    else
        cmd+=("--network" "host")
        cmd+=("-e" "MIRROR_NEURON_EXECUTOR_MAX_CONCURRENCY=50")
    fi

    cmd+=("mirror-neuron-core:latest")
    "${cmd[@]}" >/dev/null
}

function restart_core_container() {
    docker rm -f mirror-neuron-core >/dev/null 2>&1 || true
    start_core_container
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
if [ "$INSTALL_TS_SDK" = "Y" ]; then require_dir "$TS_SDK_DIR" "mn-ts-sdk"; fi
if [ "$INSTALL_SKILLS" = "Y" ]; then require_dir "$SKILLS_DIR" "mn-skills"; fi

if [ -d "$INSTALL_DIR" ] || [ -L "$INSTALL_DIR" ] || [ -d "$VENV_DIR" ] || [ -f "$BIN_DIR/mn" ]; then
    print_warning "MirrorNeuron appears to be already installed."
    if [ "$REINSTALL" != "N" ]; then
        REINSTALL=$(ask "Do you want to reinstall local components?" "Y")
    fi
    if [ "$REINSTALL" = "N" ]; then
        print_warning "Keeping existing install directories and refreshing local links/packages."
    else
        print_step "Cleaning previous local install state"
        rm -rf "$VENV_DIR" "$BIN_DIR/mn" "$BIN_DIR/mn-api"
        if [ -L "$INSTALL_DIR" ] || [ -d "$INSTALL_DIR" ]; then
            rm -rf "$INSTALL_DIR"
        fi
        if [ -L "$UI_LINK_DIR" ] || [ -d "$UI_LINK_DIR" ]; then
            rm -rf "$UI_LINK_DIR"
        fi
    fi
fi

echo -e "${CYAN}${BOLD}Configuration${RESET}" >&3
if [ "$NON_INTERACTIVE" != "Y" ]; then
    INSTALL_WEB_UI=$(ask "Install/build local Web UI?" "$INSTALL_WEB_UI")
    INSTALL_REDIS=$(ask "Install/start Redis via Docker?" "$INSTALL_REDIS")
    INSTALL_SKILLS=$(ask "Install local mn-skills packages in editable mode?" "$INSTALL_SKILLS")
    INSTALL_TS_SDK=$(ask "Install/build local TypeScript SDK?" "$INSTALL_TS_SDK")
    INSTALL_OPENSHELL=$(ask "Use local OpenShell if a sibling folder exists?" "$INSTALL_OPENSHELL")
    START_NOW=$(ask "Start MirrorNeuron server automatically after install?" "$START_NOW")
fi
echo "" >&3

print_step "Checking dependencies"
for cmd in python3 docker; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        print_error "'$cmd' is required but not installed."
        exit 1
    fi
done

if [ "$INSTALL_WEB_UI" = "Y" ] || [ "$INSTALL_TS_SDK" = "Y" ]; then
    if ! command -v npm >/dev/null 2>&1; then
        print_error "'npm' is required for local Web UI or TypeScript SDK install."
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
print_success "Local component links created under ${INSTALL_DIR}."

print_step "Building MirrorNeuron Core Docker image from local source"
(
    cd "$CORE_DIR"
    docker build -t mirror-neuron-core:latest . >/dev/null
) &
spinner $! "Built local core image mirror-neuron-core:latest"

if [ "$CORE_WAS_RUNNING" = "Y" ]; then
    print_step "Restarting MirrorNeuron gRPC Core from rebuilt image"
    (
        restart_core_container
    ) &
    spinner $! "Restarted MirrorNeuron gRPC Core"
fi

print_step "Installing Python components from local source"
(
    python3 -m venv "$VENV_DIR" >/dev/null
    "$VENV_DIR/bin/pip" install --upgrade pip >/dev/null
    "$VENV_DIR/bin/pip" install -e "$PY_SDK_DIR" >/dev/null
    "$VENV_DIR/bin/pip" install -e "$CLI_DIR" >/dev/null
    "$VENV_DIR/bin/pip" install -e "$API_DIR" >/dev/null

    if [ "$INSTALL_SKILLS" = "Y" ]; then
        shopt -s nullglob
        for skill_pyproject in "$SKILLS_DIR"/*/pyproject.toml; do
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

if [ "$INSTALL_TS_SDK" = "Y" ]; then
    print_step "Installing TypeScript SDK from local source"
    (
        cd "$TS_SDK_DIR"
        npm install >/dev/null
        npm run build >/dev/null
    ) &
    spinner $! "Installed and built local TypeScript SDK"
    replace_symlink "$TS_SDK_DIR" "$INSTALL_DIR/ts-sdk-source"
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
    print_step "Checking local OpenShell"
    if [ -d "$WORKSPACE_DIR/OpenShell" ]; then
        (
            cd "$WORKSPACE_DIR/OpenShell"
            if [ -f Dockerfile ]; then
                docker build -t mirror-neuron-openshell:latest . >/dev/null
            fi
        ) &
        spinner $! "Configured local OpenShell"
    else
        print_warning "No local OpenShell folder found at ${WORKSPACE_DIR}/OpenShell. Skipping remote pull."
    fi
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
if [ "$INSTALL_WEB_UI" = "Y" ]; then
    echo -e "Web UI:     ${CYAN}${UI_LINK_DIR}${RESET} -> ${WEB_UI_DIR}" >&3
fi

echo -e "\n${BOLD}Quick Start:${RESET}" >&3
echo -e "  1. Start server: ${GREEN}mn start${RESET}" >&3
if [ "$INSTALL_WEB_UI" = "Y" ]; then
    echo -e "  2. Start UI:     ${GREEN}cd ${UI_LINK_DIR} && npm run dev${RESET}" >&3
fi
echo -e "  3. Use CLI:      ${GREEN}mn nodes${RESET}" >&3
echo -e "  4. Rebuild core after Elixir changes: ${GREEN}${SCRIPT_DIR}/install_local.sh --yes --no-web-ui --no-ts-sdk --no-skills${RESET}\n" >&3

if [ "$START_NOW" = "Y" ]; then
    print_step "Starting MirrorNeuron Server"
    "$VENV_DIR/bin/mn" start
fi
