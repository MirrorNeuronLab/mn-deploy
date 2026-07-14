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
        echo "=> Error: failed to generate MN_COOKIE."
        exit 1
    fi

    printf '%s\n' "$cookie" > "$cookie_file"
    chmod 600 "$cookie_file" 2>/dev/null || true
    printf '%s\n' "$cookie"
}

print_ascii_art() {
    cat << "ASCIIEOF"
  __  __ _                     _   _                     
 |  \/  (_)_ __ _ __ ___  _ __| \ | | ___ _   _ _ __ ___  _ __ 
 | |\/| | | '__| '__/ _ \| '__|  \| |/ _ \ | | | '__/ _ \| '_ \ 
 | |  | | | |  | | | (_) | |  | |\  |  __/ |_| | | | (_) | | | |
 |_|  |_|_|_|  |_|  \___/|_|  |_| \_|\___|\__,_|_|  \___/|_| |_|
                                                               
===================================================================
                  MirrorNeuron Server Manager                      
===================================================================
ASCIIEOF
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
        echo "=> Error: MirrorNeuron API is already running."
        echo "=> Use '$0 status' to check, or '$0 stop' to stop."
        exit 1
    fi
    if ! runtime_compose_available; then
        docker_names="$(docker ps --format '{{.Names}}')"
        if grep -qx "mirror-neuron-core" <<< "$docker_names"; then
            echo "=> Error: MirrorNeuron Core (Docker) is already running."
            echo "=> Use '$0 status' to check, or '$0 stop' to stop."
            exit 1
        fi
    fi

    mkdir -p "$PID_DIR" "$LOG_DIR"

    echo "==========================================="
    echo "Starting Services in Detached Mode..."
    echo "==========================================="

    mn_cookie="$(resolve_mn_cookie)"
    if runtime_compose_available; then
        echo "=> Starting MirrorNeuron Docker runtime (Compose)..."
        runtime_compose up -d >/dev/null
        echo "   [Started] Docker runtime (Compose project: mirror-neuron)"
    else
        echo "=> Starting MirrorNeuron Core Service (Docker)..."
        docker rm -f mirror-neuron-core >/dev/null 2>&1 || true
        core_cmd=(
            docker run -d --name mirror-neuron-core --network host
            -e "MN_COOKIE=${mn_cookie}"
            -e "MN_GRPC_AUTH_TOKEN=mirror_neuron_password"
            -e "MN_GRPC_ADMIN_TOKEN=mirror_neuron_password_admin"
            -e "MN_CORE_ALLOW_NATIVE_SANDBOX_PREP=${MN_CORE_ALLOW_NATIVE_SANDBOX_PREP:-0}"
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
        echo "   [Started] Core Service (Docker: mirror-neuron-core)"
    fi

    echo "=> Waiting for Elixir to boot..."
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
        echo "=> Starting mn-api (REST on port ${MN_API_PORT:-54001})..."
        nohup "$API_BIN" > "$API_LOG" 2>&1 &
        API_PID=$!
        echo $API_PID > "$API_PID_FILE"
        api_started=1
        echo "   [Started] REST API (PID: $API_PID)"
    else
        echo "=> Warning: mn-api not found, skipping. Did you run setup.sh?"
    fi

    if [ "$api_started" -eq 1 ]; then
        write_runtime_endpoints_file
        echo "   Runtime endpoints: $RUNTIME_ENDPOINTS_FILE"
    fi

    echo ""
    echo "==========================================="
    echo "MirrorNeuron is running in the background!"
    echo "Logs are available at:"
    echo "  Core: $BEAM_LOG"
    echo "  API:  $API_LOG"
    echo ""
    echo "Run 'mn' anywhere in your terminal to use the CLI."
    echo "Run '$0 stop' to shut down the services."
    echo "==========================================="
}

stop_services() {
    echo "=> Stopping MirrorNeuron Services..."
    
    if runtime_compose_available; then
        echo "   Stopping Docker runtime (Compose)..."
        runtime_compose down >/dev/null 2>&1 || true
    else
        echo "   Stopping Core Service (Docker: mirror-neuron-core)..."
        docker stop mirror-neuron-core >/dev/null 2>&1 || true
        docker rm mirror-neuron-core >/dev/null 2>&1 || true
    fi
    
    for pid_file in "$API_PID_FILE" "$BEAM_PID_FILE"; do
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file")
            if kill -0 "$pid" 2>/dev/null; then
                if [ "$pid_file" == "$API_PID_FILE" ]; then
                    echo "   Stopping REST API (PID: $pid)..."
                else
                    echo "   Stopping Legacy Core Service (PID: $pid)..."
                fi
                kill_tree "$pid"
                sleep 1
            fi
            rm -f "$pid_file"
        fi
    done
    
    echo "=> All services stopped."
}

status_services() {
    print_ascii_art
    echo "Service Status:"
    
    if runtime_compose_available; then
        if runtime_compose ps --status running --services 2>/dev/null | grep -qx "mirror-neuron-core"; then
            echo "  [OK] Docker runtime (Compose) is running"
        else
            echo "  [--] Docker runtime (Compose) is not running"
        fi
    else
        docker_names="$(docker ps --format '{{.Names}}')"
        if grep -qx "mirror-neuron-core" <<< "$docker_names"; then
            echo "  [OK] Core Service (Docker: mirror-neuron-core) is running"
        else
            echo "  [--] Core Service (Docker: mirror-neuron-core) is not running"
        fi
    fi

    check_status "$API_PID_FILE"
    local api_stat=$?
    if [ $api_stat -eq 0 ]; then
        echo "  [OK] REST API is running (PID: $(cat "$API_PID_FILE"))"
    elif [ $api_stat -eq 1 ]; then
        echo "  [!!] REST API PID file exists but process is dead."
        rm -f "$API_PID_FILE"
    else
        echo "  [--] REST API is not running."
    fi
}

case "$1" in
    start) start_services ;;
    stop) stop_services ;;
    restart) stop_services; sleep 2; start_services ;;
    status) status_services ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
