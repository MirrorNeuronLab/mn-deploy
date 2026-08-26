#!/usr/bin/env bash

set -e

# Keep uninstaller output visible even when prompts are piped.
exec 3>&1

if [ -t 3 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    ESC="$(printf '\033')"
    BOLD="${ESC}[1m"
    RED="${ESC}[31m"
    GREEN="${ESC}[32m"
    YELLOW="${ESC}[33m"
    BLUE="${ESC}[34m"
    CYAN="${ESC}[36m"
    RESET="${ESC}[0m"
else
    BOLD=""
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    CYAN=""
    RESET=""
fi

function print_header() {
    printf '\n%s%s%s\n' "${RED}${BOLD}" "MirrorNeuron Uninstaller" "$RESET" >&3
}

function print_step() { printf '%s==>%s %s\n' "${CYAN}${BOLD}" "$RESET" "$1" >&3; }
function print_success() { printf '%s✓%s %s\n' "${GREEN}${BOLD}" "$RESET" "$1" >&3; }
function print_warning() { printf '%swarning:%s %s\n' "${YELLOW}${BOLD}" "$RESET" "$1" >&3; }
function print_error() { printf '%serror:%s %s\n' "${RED}${BOLD}" "$RESET" "$1" >&3; }

ASSUME_YES="N"

function usage() {
    cat >&3 <<EOF
Usage: ./uninstall.sh [options]

Options:
  --yes, -y   Run non-interactively and answer yes to prompts.
  MN_HOME=/path Override the runtime state directory. Defaults to ${HOME}/.mn.
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

print_warning "This permanently removes MirrorNeuron components and configuration."
CONFIRM=$(ask "Are you sure you want to proceed?" "N")

if [ "$CONFIRM" != "Y" ]; then
    print_warning "Uninstallation aborted."
    exit 0
fi

INSTALL_DIR="${MN_HOME:-${HOME}/.mn}"
UI_DIR="${INSTALL_DIR}/webui"
BIN_DIR="${HOME}/.local/bin"
RUNTIME_BIN_DIR="${INSTALL_DIR}/bin"
VENV_DIR="${HOME}/.local/share/mn_venv"

RUNTIME_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
RUNTIME_COMPOSE_ENV="${INSTALL_DIR}/docker-compose.env"

function read_env_value() {
    local file="$1"
    local key="$2"
    [ -f "$file" ] || return 0
    awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$file"
}

COMPOSE_PROJECT_NAME="$(read_env_value "$RUNTIME_COMPOSE_ENV" "COMPOSE_PROJECT_NAME")"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-mirror-neuron}"
DOCKER_NETWORK_NAME="$(read_env_value "$RUNTIME_COMPOSE_ENV" "MN_DOCKER_NETWORK_NAME")"
DOCKER_NETWORK_NAME="${DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
DOCKER_NETWORK_EXTERNAL_VALUE="$(read_env_value "$RUNTIME_COMPOSE_ENV" "MN_DOCKER_NETWORK_EXTERNAL")"
DOCKER_NETWORK_EXTERNAL_KNOWN="N"
if [ -n "$DOCKER_NETWORK_EXTERNAL_VALUE" ]; then
    DOCKER_NETWORK_EXTERNAL_KNOWN="Y"
fi
case "$(printf '%s' "$DOCKER_NETWORK_EXTERNAL_VALUE" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y) DOCKER_NETWORK_EXTERNAL="Y" ;;
    *) DOCKER_NETWORK_EXTERNAL="N" ;;
esac

function runtime_compose_down() {
    if docker compose version >/dev/null 2>&1; then
        if [ -f "$RUNTIME_COMPOSE_ENV" ]; then
            docker compose --env-file "$RUNTIME_COMPOSE_ENV" \
                --project-name "$COMPOSE_PROJECT_NAME" \
                -f "$RUNTIME_COMPOSE_FILE" \
                down --remove-orphans --volumes --rmi local
        else
            docker compose \
                --project-name "$COMPOSE_PROJECT_NAME" \
                -f "$RUNTIME_COMPOSE_FILE" \
                down --remove-orphans --volumes --rmi local
        fi
    elif command -v docker-compose >/dev/null 2>&1; then
        if [ -f "$RUNTIME_COMPOSE_ENV" ]; then
            docker-compose \
                --env-file "$RUNTIME_COMPOSE_ENV" \
                --project-name "$COMPOSE_PROJECT_NAME" \
                -f "$RUNTIME_COMPOSE_FILE" \
                down --remove-orphans --volumes --rmi local
        else
            docker-compose \
                --project-name "$COMPOSE_PROJECT_NAME" \
                -f "$RUNTIME_COMPOSE_FILE" \
                down --remove-orphans --volumes --rmi local
        fi
    else
        print_warning "Docker Compose is not available; using project-label cleanup."
        return 1
    fi
}

function remove_compose_project_resources() {
    local resource_id
    local resource_name
    local network_project
    local cleanup_failed="N"

    while IFS= read -r resource_id; do
        [ -n "$resource_id" ] || continue
        if ! docker rm -f "$resource_id" >/dev/null 2>&1; then
            cleanup_failed="Y"
        fi
    done < <(docker ps -aq --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" 2>/dev/null || true)

    while IFS= read -r resource_id; do
        [ -n "$resource_id" ] || continue
        if ! docker volume rm -f "$resource_id" >/dev/null 2>&1; then
            cleanup_failed="Y"
        fi
    done < <(docker volume ls -q --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" 2>/dev/null || true)

    while IFS=' ' read -r resource_id resource_name; do
        [ -n "$resource_id" ] || continue
        if [ "$DOCKER_NETWORK_EXTERNAL" = "Y" ] &&
           [ "$resource_name" = "$DOCKER_NETWORK_NAME" ]; then
            continue
        fi
        if ! docker network rm "$resource_id" >/dev/null 2>&1; then
            cleanup_failed="Y"
        fi
    done < <(
        docker network ls \
            --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
            --format '{{.ID}} {{.Name}}' 2>/dev/null || true
    )

    if [ "$DOCKER_NETWORK_EXTERNAL" != "Y" ] &&
       docker network inspect "$DOCKER_NETWORK_NAME" >/dev/null 2>&1; then
        network_project="$(docker network inspect -f '{{ index .Labels "com.docker.compose.project" }}' "$DOCKER_NETWORK_NAME" 2>/dev/null || true)"
        if [ "$network_project" = "$COMPOSE_PROJECT_NAME" ] ||
           [ "$DOCKER_NETWORK_EXTERNAL_KNOWN" = "Y" ]; then
            if ! docker network rm "$DOCKER_NETWORK_NAME" >/dev/null 2>&1; then
                cleanup_failed="Y"
            fi
        fi
    fi

    [ "$cleanup_failed" = "N" ]
}

function remove_docker_runtime_project() {
    local cleanup_failed="N"

    if ! docker info >/dev/null 2>&1; then
        print_error "Docker is installed but the daemon is not available."
        printf 'Next: start Docker, then rerun ./uninstall.sh --yes\n' >&3
        return 1
    fi

    print_step "Removing complete Docker Compose project"
    if [ -f "$RUNTIME_COMPOSE_FILE" ]; then
        if ! runtime_compose_down >/dev/null 2>&1; then
            print_warning "Docker Compose teardown was incomplete; cleaning resources by project label."
        fi
    else
        print_warning "Installed Compose file not found; cleaning resources by project label."
    fi

    if ! remove_compose_project_resources; then
        cleanup_failed="Y"
    fi
    if [ "$cleanup_failed" = "Y" ]; then
        print_error "Some MirrorNeuron Docker resources could not be removed."
        printf 'Next: resolve active Docker attachments, then rerun ./uninstall.sh --yes\n' >&3
        return 1
    fi

    print_success "Removed Compose containers, orphan services, named volumes, and owned networks."
}

if command -v docker >/dev/null 2>&1; then
    if ! remove_docker_runtime_project; then
        exit 1
    fi
else
    print_warning "Docker not installed, skipping container, volume, and network cleanup."
fi

print_step "Removing Symlinks"
rm -f "$BIN_DIR/mn" "$BIN_DIR/mn-api" "$RUNTIME_BIN_DIR/mn" "$RUNTIME_BIN_DIR/mn-api"
print_success "Removed mn and mn-api command links."

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
if [ -d "$UI_DIR" ] || [ -L "$UI_DIR" ]; then
    rm -rf "$UI_DIR"
    print_success "Removed Web UI installation at $UI_DIR"
else
    print_success "Web UI installation not found, skipping."
fi
print_step "Removing Docker Images and OpenShell Artifacts"
if command -v docker &> /dev/null; then
    if docker image inspect mirror-neuron-core:latest >/dev/null 2>&1; then
        docker rmi mirror-neuron-core:latest >/dev/null 2>&1 || true
        print_success "Removed Core image."
    else
        print_success "Core image not found, skipping."
    fi

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
        "ghcr.io/nvidia/openshell/gateway:latest" \
        "ghcr.io/nvidia/openshell/gateway:0.0.47" \
        "ghcr.io/nvidia/openshell/cluster:0.0.16" \
        "ghcr.io/nvidia/openshell/cluster:latest"; do
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
else
    print_warning "Docker not installed, skipping image cleanup."
fi

echo "" >&3
print_success "MirrorNeuron uninstallation completed."
