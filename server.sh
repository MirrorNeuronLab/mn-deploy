#!/usr/bin/env bash

DIR="${HOME}/.mirror_neuron"
PID_DIR="${DIR}/.pids"
LOG_DIR="${DIR}/.logs"
BEAM_PID_FILE="${PID_DIR}/beam.pid"
API_PID_FILE="${PID_DIR}/api.pid"
BEAM_LOG="${LOG_DIR}/beam.log"
API_LOG="${LOG_DIR}/api.log"
VENV_DIR="${HOME}/.local/share/mn_venv"

generate_mn_cookie() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
    fi
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

    cookie="$(generate_mn_cookie)"
    if [ -z "$cookie" ]; then
        echo "=> Error: failed to generate MN_COOKIE."
        exit 1
    fi

    printf '%s\n' "$cookie" > "$cookie_file"
    chmod 600 "$cookie_file" 2>/dev/null || true
    printf '%s\n' "$cookie"
}

resolve_grpc_auth_token() {
    local env_token="${MN_GRPC_AUTH_TOKEN:-}"
    local token_file="${DIR}/grpc_auth.token"
    local token

    if [ -n "$env_token" ]; then
        printf '%s\n' "$env_token"
        return 0
    fi

    mkdir -p "$DIR"
    if [ -s "$token_file" ]; then
        token="$(tr -d '[:space:]' < "$token_file")"
        if [ -n "$token" ]; then
            chmod 600 "$token_file" 2>/dev/null || true
            printf '%s\n' "$token"
            return 0
        fi
    fi

    token="$(generate_mn_cookie)"
    if [ -z "$token" ]; then
        echo "=> Error: failed to generate MN_GRPC_AUTH_TOKEN."
        exit 1
    fi

    printf '%s\n' "$token" > "$token_file"
    chmod 600 "$token_file" 2>/dev/null || true
    printf '%s\n' "$token"
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
    docker_names="$(docker ps --format '{{.Names}}')"
    if grep -qx "mirror-neuron-core" <<< "$docker_names"; then
        echo "=> Error: MirrorNeuron Core (Docker) is already running."
        echo "=> Use '$0 status' to check, or '$0 stop' to stop."
        exit 1
    fi

    mkdir -p "$PID_DIR" "$LOG_DIR"

    echo "==========================================="
    echo "Starting Services in Detached Mode..."
    echo "==========================================="

    echo "=> Starting MirrorNeuron Core Service (Docker)..."
    docker rm -f mirror-neuron-core >/dev/null 2>&1 || true
    mn_cookie="$(resolve_mn_cookie)"
    grpc_auth_token="$(resolve_grpc_auth_token)"
    export MN_GRPC_AUTH_TOKEN="${MN_GRPC_AUTH_TOKEN:-$grpc_auth_token}"
    core_cmd=(
        docker run -d --name mirror-neuron-core --network host
        -e "MN_COOKIE=${mn_cookie}"
        -e "MN_GRPC_AUTH_TOKEN=${MN_GRPC_AUTH_TOKEN}"
        -e "MN_CORE_HOST=${MN_CORE_HOST:-localhost}"
        -e "MN_REDIS_HOST=${MN_REDIS_HOST:-localhost}"
        -e "ERL_EPMD_ADDRESS=${MN_EPMD_HOST:-localhost}"
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

    echo "=> Waiting for Elixir to boot..."
    sleep 3

    API_BIN="${VENV_DIR}/bin/mn-api"
    if [ -x "$API_BIN" ]; then
        echo "=> Starting mn-api (REST on port 4001)..."
        nohup "$API_BIN" > "$API_LOG" 2>&1 &
        API_PID=$!
        echo $API_PID > "$API_PID_FILE"
        echo "   [Started] REST API (PID: $API_PID)"
    else
        echo "=> Warning: mn-api not found, skipping. Did you run setup.sh?"
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
    
    echo "   Stopping Core Service (Docker: mirror-neuron-core)..."
    docker stop mirror-neuron-core >/dev/null 2>&1 || true
    docker rm mirror-neuron-core >/dev/null 2>&1 || true
    
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
    
    docker_names="$(docker ps --format '{{.Names}}')"
    if grep -qx "mirror-neuron-core" <<< "$docker_names"; then
        echo "  [OK] Core Service (Docker: mirror-neuron-core) is running"
    else
        echo "  [--] Core Service (Docker: mirror-neuron-core) is not running"
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
