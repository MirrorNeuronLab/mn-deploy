#!/usr/bin/env bash

set -euo pipefail

MN_HOME_DIR="${MN_HOME:-${HOME}/.mn}"
COMPOSE_FILE="${MN_HOME_DIR}/docker-compose.yml"
COMPOSE_ENV_FILE="${MN_HOME_DIR}/docker-compose.env"
CONTAINER_NAME="${MN_REDIS_CONTAINER:-mirror-neuron-redis}"
DATABASE=""
ASSUME_YES="N"
ASYNC="N"

usage() {
    cat <<EOF
Usage: scripts/clear-redis.sh [options]

Clear MirrorNeuron Redis state.

Options:
  --yes, -y           Run without confirmation.
  --db <number>       Clear one Redis database with FLUSHDB instead of FLUSHALL.
  --async             Use Redis asynchronous flush.
  --container <name>  Redis container name. Defaults to mirror-neuron-redis.
  --mn-home <path>    Runtime state directory. Defaults to MN_HOME or ~/.mn.
  -h, --help          Show this help.

Examples:
  scripts/clear-redis.sh
  scripts/clear-redis.sh --yes
  scripts/clear-redis.sh --db 1 --yes
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes|-y)
            ASSUME_YES="Y"
            shift
            ;;
        --async)
            ASYNC="Y"
            shift
            ;;
        --db)
            if [ "$#" -lt 2 ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --db requires a numeric database index." >&2
                exit 1
            fi
            DATABASE="$2"
            shift 2
            ;;
        --container)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                echo "Error: --container requires a container name." >&2
                exit 1
            fi
            CONTAINER_NAME="$2"
            shift 2
            ;;
        --mn-home)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                echo "Error: --mn-home requires a path." >&2
                exit 1
            fi
            MN_HOME_DIR="$2"
            COMPOSE_FILE="${MN_HOME_DIR}/docker-compose.yml"
            COMPOSE_ENV_FILE="${MN_HOME_DIR}/docker-compose.env"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if ! command -v docker >/dev/null 2>&1; then
    echo "Error: docker is required." >&2
    exit 1
fi

target="all Redis databases"
redis_command="FLUSHALL"
if [ -n "$DATABASE" ]; then
    target="Redis database ${DATABASE}"
    redis_command="FLUSHDB"
fi
if [ "$ASYNC" = "Y" ]; then
    redis_command="${redis_command} ASYNC"
fi

if [ "$ASSUME_YES" != "Y" ]; then
    printf 'This will permanently clear %s for MirrorNeuron. Continue? [y/N]: ' "$target" >&2
    read -r answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *)
            echo "Aborted."
            exit 0
            ;;
    esac
fi

run_redis_cli_script='
set -eu
database="${MN_CLEAR_REDIS_DB:-}"
command="${MN_CLEAR_REDIS_COMMAND:-FLUSHALL}"
auth_args=""
if [ -n "${MN_REDIS_PASSWORD:-}" ]; then
  auth_args="-a ${MN_REDIS_PASSWORD} --no-auth-warning"
fi
if [ -n "$database" ]; then
  redis-cli $auth_args -n "$database" $command
else
  redis-cli $auth_args $command
fi
redis-cli $auth_args MEMORY PURGE >/dev/null 2>&1 || true
redis-cli $auth_args BGREWRITEAOF >/dev/null 2>&1 || true
'

if [ -f "$COMPOSE_FILE" ]; then
    compose_args=(-f "$COMPOSE_FILE")
    if [ -f "$COMPOSE_ENV_FILE" ]; then
        compose_args=(--env-file "$COMPOSE_ENV_FILE" "${compose_args[@]}")
    fi
    docker compose "${compose_args[@]}" exec -T \
        -e "MN_CLEAR_REDIS_DB=${DATABASE}" \
        -e "MN_CLEAR_REDIS_COMMAND=${redis_command}" \
        redis sh -c "$run_redis_cli_script"
else
    if ! docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
        echo "Error: Redis container not found: ${CONTAINER_NAME}" >&2
        echo "Hint: set MN_HOME, pass --mn-home, or pass --container." >&2
        exit 1
    fi
    docker exec -i \
        -e "MN_CLEAR_REDIS_DB=${DATABASE}" \
        -e "MN_CLEAR_REDIS_COMMAND=${redis_command}" \
        "$CONTAINER_NAME" sh -c "$run_redis_cli_script"
fi

echo "Cleared ${target}."
