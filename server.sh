#!/usr/bin/env bash

DIR="${MN_HOME:-${HOME}/.mn}"
PID_DIR="${DIR}/.pids"
LOG_DIR="${DIR}/.logs"
BEAM_PID_FILE="${PID_DIR}/beam.pid"
API_PID_FILE="${PID_DIR}/api.pid"
BEAM_LOG="${LOG_DIR}/beam.log"
API_LOG="${LOG_DIR}/api.log"
VENV_DIR="${HOME}/.local/share/mn_venv"
RUNTIME_COMPOSE_FILE="${DIR}/docker-compose.yml"
RUNTIME_COMPOSE_ENV="${DIR}/docker-compose.env"
RUNTIME_ENDPOINTS_FILE="${DIR}/runtime-endpoints.json"
MN_BLUEPRINT_SOURCE="${MN_BLUEPRINT_SOURCE:-github}"
MN_BLUEPRINT_REPO="${MN_BLUEPRINT_REPO:-https://github.com/MirrorNeuronLab/mn-blueprints.git}"
MN_BLUEPRINT_LOCAL="${MN_BLUEPRINT_LOCAL:-}"
MN_MANAGED_PYTHON_VERSION="${MN_MANAGED_PYTHON_VERSION:-3.11}"
MN_VERBOSE="${MN_VERBOSE:-N}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
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

ui_title() { printf '\n%s%s%s\n' "${BLUE}${BOLD}" "$1" "$RESET"; }
ui_step() { printf '%s==>%s %s\n' "${CYAN}${BOLD}" "$RESET" "$1"; }
ui_success() { printf '%s✓%s %s\n' "${GREEN}${BOLD}" "$RESET" "$1"; }
ui_warning() { printf '%swarning:%s %s\n' "${YELLOW}${BOLD}" "$RESET" "$1"; }
ui_error() { printf '%serror:%s %s\n' "${RED}${BOLD}" "$RESET" "$1"; }
ui_detail() {
    if [ "$MN_VERBOSE" = "Y" ]; then
        printf '    %s\n' "$1"
    fi
}
ui_status() { printf '  %-14s %s\n' "$1" "$2"; }

generate_mn_cookie() {
    local secret
    local python_fallback

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

    python_fallback="$(command -v "python${MN_MANAGED_PYTHON_VERSION}" 2>/dev/null || true)"
    if [ -n "$python_fallback" ]; then
        if secret="$("$python_fallback" -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null)" && [ -n "$secret" ]; then
            printf '%s\n' "$secret"
            return 0
        fi
    fi

    return 1
}

resolve_mn_cookie() {
    local env_cookie="${MN_COOKIE:-}"
    local cookie_file="${DIR}/erlang.cookie"
    local cookie

    if [ -n "$env_cookie" ] && [ "$env_cookie" != "mirrorneuron" ]; then
        printf '%s\n' "$env_cookie"
        return 0
    fi

    mkdir -p "$DIR"
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
        ui_error "Failed to generate MN_COOKIE."
        exit 1
    fi

    printf '%s\n' "$cookie" > "$cookie_file"
    chmod 600 "$cookie_file" 2>/dev/null || true
    printf '%s\n' "$cookie"
}

print_ascii_art() {
    ui_title "MirrorNeuron runtime"
}

check_status() {
    local pid_file=$1
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            return 0 # Running
        else
            return 1 # Stale
        fi
    fi
    return 2 # Not running
}

runtime_compose_available() {
    [ -f "$RUNTIME_COMPOSE_FILE" ] && [ -f "$RUNTIME_COMPOSE_ENV" ]
}

runtime_compose() {
    if command -v docker-compose >/dev/null 2>&1; then
        docker-compose --env-file "$RUNTIME_COMPOSE_ENV" -f "$RUNTIME_COMPOSE_FILE" "$@"
    else
        docker compose --env-file "$RUNTIME_COMPOSE_ENV" -f "$RUNTIME_COMPOSE_FILE" "$@"
    fi
}

read_runtime_env_value() {
    local key="$1"
    local line
    if [ ! -f "$RUNTIME_COMPOSE_ENV" ]; then
        return 0
    fi
    line="$(grep -E "^${key}=" "$RUNTIME_COMPOSE_ENV" | tail -n 1 || true)"
    if [ -n "$line" ]; then
        printf '%s\n' "${line#*=}"
    fi
}

apply_runtime_env_default() {
    local key="$1"
    local value
    if [ -n "${!key:-}" ]; then
        return 0
    fi
    value="$(read_runtime_env_value "$key")"
    if [ -n "$value" ]; then
        export "${key}=${value}"
    fi
}

local_endpoint_host() {
    case "${1:-}" in
        "" ) printf '%s\n' "localhost" ;;
        "0.0.0.0"|"::" ) printf '%s\n' "127.0.0.1" ;;
        * ) printf '%s\n' "$1" ;;
    esac
}

json_escape() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/ }"
    printf '%s' "$value"
}

runtime_env_or_default() {
    local key="$1"
    local fallback="$2"
    local value="${!key:-}"
    if [ -z "$value" ]; then
        value="$(read_runtime_env_value "$key")"
    fi
    printf '%s\n' "${value:-$fallback}"
}

write_runtime_endpoints_file() {
    local api_host api_port api_base_url grpc_host grpc_port grpc_target updated_at
    api_host="$(local_endpoint_host "$(runtime_env_or_default "MN_API_HOST" "localhost")")"
    api_port="$(runtime_env_or_default "MN_API_PORT" "54001")"
    api_base_url="${MN_API_BASE_URL:-http://${api_host}:${api_port}/api/v1}"
    grpc_host="$(local_endpoint_host "$(runtime_env_or_default "MN_GRPC_BIND_HOST" "localhost")")"
    grpc_port="$(runtime_env_or_default "MN_GRPC_PORT" "55051")"
    grpc_target="${MN_GRPC_TARGET:-}"
    if [ -z "$grpc_target" ]; then
        grpc_target="$(read_runtime_env_value "MN_GRPC_TARGET")"
    fi
    grpc_target="${grpc_target:-${grpc_host}:${grpc_port}}"
    updated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    mkdir -p "$DIR"
    cat > "$RUNTIME_ENDPOINTS_FILE" <<EOF
{
  "api": {
    "base_url": "$(json_escape "$api_base_url")",
    "host": "$(json_escape "$api_host")",
    "port": "$(json_escape "$api_port")"
  },
  "grpc": {
    "host": "$(json_escape "$grpc_host")",
    "port": "$(json_escape "$grpc_port")",
    "target": "$(json_escape "$grpc_target")"
  },
  "updated_at": "$(json_escape "$updated_at")",
  "version": 1
}
EOF
    chmod 600 "$RUNTIME_ENDPOINTS_FILE" 2>/dev/null || true
}

kill_tree() {
    local parent=$1
    if kill -0 "$parent" 2>/dev/null; then
        local children=$(pgrep -P "$parent" 2>/dev/null || true)
        for child in $children; do
            kill_tree "$child"
        done
        kill -15 "$parent" 2>/dev/null || true
    fi
}

start_services() {
    print_ascii_art
    if check_status "$API_PID_FILE"; then
        ui_error "MirrorNeuron API is already running."
        printf 'Hint: use %s status or %s stop.\n' "$0" "$0"
        exit 1
    fi
    if ! runtime_compose_available; then
        docker_names="$(docker ps --format '{{.Names}}')"
        if grep -qx "mirror-neuron-core" <<< "$docker_names"; then
            ui_error "MirrorNeuron Core is already running."
            printf 'Hint: use %s status or %s stop.\n' "$0" "$0"
            exit 1
        fi
    fi

    mkdir -p "$PID_DIR" "$LOG_DIR"

    ui_step "Starting MirrorNeuron"

    mn_cookie="$(resolve_mn_cookie)"
    if runtime_compose_available; then
        runtime_compose up -d >/dev/null
        ui_success "Docker runtime started."
        ui_detail "Compose project: mirror-neuron"
    else
        docker rm -f mirror-neuron-core >/dev/null 2>&1 || true
        core_cmd=(
            docker run -d --name mirror-neuron-core --network host
            -e "MN_COOKIE=${mn_cookie}"
            -e "MN_GRPC_AUTH_TOKEN=mirror_neuron_password"
            -e "MN_GRPC_ADMIN_TOKEN=mirror_neuron_password_admin"
            -e "MN_CORE_HOST=${MN_CORE_HOST:-localhost}"
            -e "MN_REDIS_HOST=${MN_REDIS_HOST:-localhost}"
            -e "ERL_EPMD_ADDRESS=${MN_EPMD_HOST:-localhost}"
            -e "MN_DIST_PORT=${MN_DIST_PORT:-54370}"
        )
        if [ -n "${MN_NODE_NAME:-}" ]; then
            core_cmd+=("-e" "MN_NODE_NAME=${MN_NODE_NAME}")
        fi
        openshell_config_dir="$HOME/.config/openshell"
        openshell_container_config_dir="${OPENSHELL_CONTAINER_CONFIG_DIR:-$HOME/.config/openshell-mirror-neuron}"
        openshell_mount_dir="$openshell_config_dir"
        if [ -d "$openshell_container_config_dir/gateways/openshell" ]; then
            openshell_mount_dir="$openshell_container_config_dir"
        fi
        if [ -d "$openshell_mount_dir/gateways/openshell" ]; then
            core_cmd+=("-v" "$openshell_mount_dir:/root/.config/openshell:ro")
            core_cmd+=("-v" "$openshell_mount_dir:/opt/mirror_neuron/.config/openshell:ro")
        fi
        core_cmd+=(mirror-neuron-core:latest)
        "${core_cmd[@]}" >/dev/null
        ui_success "Core service started."
    fi

    ui_step "Waiting for the runtime to boot"
    sleep 3

    apply_runtime_env_default "MN_API_HOST"
    apply_runtime_env_default "MN_API_PORT"
    apply_runtime_env_default "MN_GRPC_BIND_HOST"
    apply_runtime_env_default "MN_GRPC_PORT"
    apply_runtime_env_default "MN_GRPC_TARGET"
    apply_runtime_env_default "MN_BLUEPRINT_SOURCE"
    export MN_BLUEPRINT_SOURCE="${MN_BLUEPRINT_SOURCE:-github}"
    apply_runtime_env_default "MN_BLUEPRINT_REPO"
    export MN_BLUEPRINT_REPO="${MN_BLUEPRINT_REPO:-https://github.com/MirrorNeuronLab/mn-blueprints.git}"
    apply_runtime_env_default "MN_BLUEPRINT_LOCAL"
    export MN_BLUEPRINT_LOCAL="${MN_BLUEPRINT_LOCAL:-}"
    apply_runtime_env_default "MN_RUNS_ROOT"
    apply_runtime_env_default "MN_BLUEPRINT_WEB_UI_PORT_START"
    export MN_BLUEPRINT_WEB_UI_PORT_START="${MN_BLUEPRINT_WEB_UI_PORT_START:-61000}"
    apply_runtime_env_default "MN_BLUEPRINT_WEB_UI_PORT_END"
    export MN_BLUEPRINT_WEB_UI_PORT_END="${MN_BLUEPRINT_WEB_UI_PORT_END:-61049}"
    apply_runtime_env_default "MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE"
    export MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE="${MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE:-prepublished}"

    api_started=0
    API_BIN="${VENV_DIR}/bin/mn-api"
    if [ -x "$API_BIN" ]; then
        nohup "$API_BIN" > "$API_LOG" 2>&1 &
        API_PID=$!
        echo $API_PID > "$API_PID_FILE"
        api_started=1
        ui_success "REST API started."
        ui_detail "REST API PID: $API_PID"
    else
        ui_warning "mn-api is not installed; REST API was skipped."
    fi

    if [ "$api_started" -eq 1 ]; then
        write_runtime_endpoints_file
        ui_detail "Runtime endpoints: $RUNTIME_ENDPOINTS_FILE"
    fi

    printf '\n'
    ui_success "MirrorNeuron is running."
    printf 'Next: mn node list\n'
    ui_detail "Core log: $BEAM_LOG"
    ui_detail "API log: $API_LOG"
    ui_detail "Stop services: $0 stop"
}

stop_services() {
    ui_step "Stopping MirrorNeuron"
    
    if runtime_compose_available; then
        ui_detail "Stopping Docker runtime."
        runtime_compose down >/dev/null 2>&1 || true
    else
        ui_detail "Stopping Core service."
        docker stop mirror-neuron-core >/dev/null 2>&1 || true
        docker rm mirror-neuron-core >/dev/null 2>&1 || true
    fi
    
    for pid_file in "$API_PID_FILE" "$BEAM_PID_FILE"; do
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file")
            if kill -0 "$pid" 2>/dev/null; then
                if [ "$pid_file" == "$API_PID_FILE" ]; then
                    ui_detail "Stopping REST API (PID: $pid)."
                else
                    ui_detail "Stopping legacy Core service (PID: $pid)."
                fi
                kill_tree "$pid"
                sleep 1
            fi
            rm -f "$pid_file"
        fi
    done
    
    ui_success "MirrorNeuron stopped."
}

status_services() {
    print_ascii_art
    printf 'Service status\n'
    
    if runtime_compose_available; then
        if runtime_compose ps --status running --services 2>/dev/null | grep -qx "mirror-neuron-core"; then
            ui_status "Core" "running"
        else
            ui_status "Core" "stopped"
        fi
    else
        docker_names="$(docker ps --format '{{.Names}}')"
        if grep -qx "mirror-neuron-core" <<< "$docker_names"; then
            ui_status "Core" "running"
        else
            ui_status "Core" "stopped"
        fi
    fi

    check_status "$API_PID_FILE"
    local api_stat=$?
    if [ $api_stat -eq 0 ]; then
        ui_status "REST API" "running"
        ui_detail "REST API PID: $(cat "$API_PID_FILE")"
    elif [ $api_stat -eq 1 ]; then
        ui_status "REST API" "stale PID removed"
        rm -f "$API_PID_FILE"
    else
        ui_status "REST API" "stopped"
    fi
}

if [ "${1:-}" = "-v" ] || [ "${1:-}" = "--verbose" ]; then
    MN_VERBOSE="Y"
    shift
fi

case "${1:-}" in
    start) start_services ;;
    stop) stop_services ;;
    restart) stop_services; sleep 2; start_services ;;
    status) status_services ;;
    *)
        echo "Usage: $0 [--verbose] {start|stop|restart|status}"
        exit 1
        ;;
esac
