#!/usr/bin/env bash

set -euo pipefail

# Keep installer output visible even when a subcommand redirects stdout/stderr.
exec 3>&1

MN_INSTALL_MODE="${MN_INSTALL_MODE:-binary}"
MN_INSTALL_MODE_EXPLICIT="N"
MN_INSTALL_HELP_REQUESTED="N"
MN_INSTALL_VERBOSE="${MN_INSTALL_VERBOSE:-N}"
MN_INSTALL_RESET="N"
LATEST="v1.2.31"
MN_DEFAULT_INSTALL_VERSION="${MN_DEFAULT_INSTALL_VERSION:-$LATEST}"
MN_INSTALL_VERSION="${MN_INSTALL_VERSION:-}"
MN_INSTALL_SCRIPT_NAME="$(basename "$0")"
MN_INSTALL_ARGS=()

function print_unified_usage() {
    cat >&3 <<EOF
Usage: ./$MN_INSTALL_SCRIPT_NAME [--mode github|local|binary] [options]

Unified MirrorNeuron installer.

Modes:
  github   Install from GitHub repositories.
  local    Install from local sibling repositories in a mirror-neuron-set checkout.
  binary   Install released artifacts/packages. This is the default.

Common options:
  --version TAG                 Install this release version, for example v1.2.31.
  --yes, -y                     Run non-interactively with defaults and flags. This is the default.
  --interactive                 Ask each install question before proceeding.
  --reset                       Permanently clear existing runtime data before installing.
                                Always requires typing YES; --yes does not bypass it.
  -v, --verbose                 Show installation details and command paths.
  --no-reinstall                Keep an existing install instead of overwriting it.
  --web-ui / --no-web-ui        Enable or skip Web UI setup.
  --redis / --no-redis          Enable or skip Redis Docker setup.
  --context-engine / --no-context-engine
                                Enable or skip Membrane context engine setup.
  --openshell / --no-openshell  Enable or skip OpenShell gateway setup.
  --syncthing / --no-syncthing  Enable or skip Syncthing shared-storage replication.
  --start / --no-start          Start or skip starting MirrorNeuron after install.
  --python PATH                 Same as MN_PYTHON. Must be Python 3.11.x.
  --no-managed-python           Do not use uv to install a private Python runtime.
  --python-components LIST      Install only these Python components where supported.
  --core-version TAG            Binary mode: pin the MirrorNeuron core release.
  --python-sdk-version TAG      Binary mode: pin mirrorneuron-python-sdk.
  --cli-version TAG             Binary mode: pin mirrorneuron-cli.
  --api-version TAG             Binary mode: pin mirrorneuron-api.
  --web-ui-version TAG          Binary mode: pin mirrorneuron-web-ui.
  --gar-project PROJECT         Binary mode Google Artifact Registry project override.
  --gar-location LOCATION       Binary mode GAR location. Default: us-central1.
  --gar-repository NAME         Binary mode GAR Python repository override.
  --python-index-url URL        Binary mode pip index URL override.
  --python-extra-index-url URL  Binary mode dependency fallback index URL.
  -h, --help                    Show this help.

Examples:
  ./$MN_INSTALL_SCRIPT_NAME --no-web-ui
  ./$MN_INSTALL_SCRIPT_NAME --interactive
  ./$MN_INSTALL_SCRIPT_NAME --reset
  ./$MN_INSTALL_SCRIPT_NAME --mode github
  ./$MN_INSTALL_SCRIPT_NAME --mode local --no-web-ui --no-skills
  ./$MN_INSTALL_SCRIPT_NAME --version v1.2.31
  ./$MN_INSTALL_SCRIPT_NAME --mode github --version v1.2.31
  ./$MN_INSTALL_SCRIPT_NAME --core-version v1.2.31 --python-sdk-version v1.2.31 --cli-version v1.2.31 --api-version v1.2.31 --web-ui-version v1.2.31
EOF
}

function mn_validate_version_tag_or_exit() {
    local tag="$1"
    local semver_tag_regex='^v(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)(-(alpha|beta|rc)[.](0|[1-9][0-9]*))?$'

    if [[ ! "$tag" =~ $semver_tag_regex ]]; then
        echo "install.sh: invalid release version '$tag'. Expected vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-rc.N." >&3
        exit 1
    fi
}

function mn_package_version_from_tag() {
    local tag="$1"
    local version="${tag#v}"
    version="${version/-alpha./a}"
    version="${version/-beta./b}"
    version="${version/-rc./rc}"
    printf '%s' "$version"
}

function mn_web_ui_package_version_from_tag() {
    local tag="$1"
    printf '%s' "${tag#v}"
}

function mn_install_support_asset_path() {
    local relative_path="$1"
    if [ -n "${MN_INSTALL_VERSION:-}" ]; then
        printf 'install_support/%s/%s' "$MN_INSTALL_VERSION" "$relative_path"
    else
        printf '%s' "$relative_path"
    fi
}

function mn_is_linux_nvidia_host() {
    [ "$(uname -s)" = "Linux" ] || return 1
    command -v nvidia-smi >/dev/null 2>&1 || return 1

    local gpu_list
    gpu_list="$(nvidia-smi -L 2>/dev/null || true)"
    [ -n "$gpu_list" ]
}

function mn_is_ubuntu_linux_host() {
    [ "$(uname -s)" = "Linux" ] || return 1
    [ -r /etc/os-release ] || return 1

    local distro_id distro_like
    distro_id="$(. /etc/os-release; printf '%s' "${ID:-}")"
    distro_like="$(. /etc/os-release; printf '%s' "${ID_LIKE:-}")"
    case " ${distro_id} ${distro_like} " in
        *" ubuntu "*) return 0 ;;
        *) return 1 ;;
    esac
}

function mn_is_docker_desktop_host() {
    local host_os docker_os
    host_os="$(uname -s)"
    case "$host_os" in
        Darwin|MINGW*|MSYS*|CYGWIN*) return 0 ;;
    esac

    docker_os="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
    case "$docker_os" in
        *"docker desktop"*|*"windows"*) return 0 ;;
        *) return 1 ;;
    esac
}

function mn_print_docker_model_runner_install_hint() {
    if mn_is_docker_desktop_host; then
        printf 'Next: docker desktop enable model-runner\n' >&3
    elif mn_is_ubuntu_linux_host; then
        printf 'Next: run these commands, then rerun install.sh:\n' >&3
        printf '  sudo apt-get update\n' >&3
        printf '  sudo apt-get install docker-model-plugin -y\n' >&3
    else
        printf "Next: install the Docker Model Runner plugin for this platform, then run 'docker model start-runner'.\n" >&3
    fi
}

function mn_install_ubuntu_docker_model_plugin() {
    local -a privilege=()

    if ! command -v apt-get >/dev/null 2>&1; then
        print_error "'apt-get' is required to install docker-model-plugin on Ubuntu."
        mn_print_docker_model_runner_install_hint
        exit 1
    fi

    if [ "$(id -u)" -ne 0 ]; then
        if ! command -v sudo >/dev/null 2>&1; then
            print_error "'sudo' is required to install docker-model-plugin on Ubuntu."
            mn_print_docker_model_runner_install_hint
            exit 1
        fi
        if [ "${NON_INTERACTIVE:-Y}" = "Y" ]; then
            if ! sudo -n true >/dev/null 2>&1; then
                print_error "Installing docker-model-plugin requires sudo access."
                mn_print_docker_model_runner_install_hint
                exit 1
            fi
            privilege=(sudo -n)
        else
            privilege=(sudo)
        fi
    fi

    print_step "Installing Docker Model Runner plugin for Ubuntu"
    if ! "${privilege[@]}" apt-get update; then
        print_error "Could not refresh Ubuntu package metadata."
        mn_print_docker_model_runner_install_hint
        exit 1
    fi
    if ! "${privilege[@]}" apt-get install docker-model-plugin -y; then
        print_error "Could not install docker-model-plugin."
        mn_print_docker_model_runner_install_hint
        exit 1
    fi
}

function mn_prepare_docker_model_runner_cli() {
    if mn_is_docker_desktop_host; then
        if docker model status >/dev/null 2>&1; then
            return 0
        fi
        print_step "Enabling Docker Model Runner in Docker Desktop"
        if ! docker desktop enable model-runner >/dev/null 2>&1; then
            print_warning "Docker Desktop did not enable Model Runner automatically."
        fi
        return 0
    fi

    if mn_is_ubuntu_linux_host && ! docker model --help >/dev/null 2>&1; then
        mn_install_ubuntu_docker_model_plugin
    fi
}

function mn_docker_model_runner_endpoint_ready() {
    command -v curl >/dev/null 2>&1 || return 1
    curl --fail --silent --show-error --max-time 5 \
        "http://127.0.0.1:12434/engines/v1/models" >/dev/null 2>&1 || \
        curl --fail --silent --show-error --max-time 5 \
            "http://127.0.0.1:12434/v1/models" >/dev/null 2>&1
}

function mn_wait_for_docker_model_runner() {
    local attempts="${MN_DOCKER_MODEL_RUNNER_START_ATTEMPTS:-30}"
    while [ "$attempts" -gt 0 ]; do
        if mn_docker_model_runner_endpoint_ready; then
            return 0
        fi
        sleep 1
        attempts=$((attempts - 1))
    done
    return 1
}

function mn_nvidia_llamacpp_runner_image() {
    printf '%s' 'docker/model-runner:local-cuda-b10524'
}

function mn_nvidia_llamacpp_runner_is_current() {
    local image
    image="$(docker container inspect -f '{{.Config.Image}}' docker-model-runner 2>/dev/null || true)"
    [ "$image" = "$(mn_nvidia_llamacpp_runner_image)" ]
}

function mn_ensure_nvidia_llamacpp_runner() {
    local runner_image build_dir
    runner_image="$(mn_nvidia_llamacpp_runner_image)"

    if mn_nvidia_llamacpp_runner_is_current; then
        if mn_docker_model_runner_endpoint_ready; then
            return 0
        fi
        print_step "Starting the NVIDIA llama.cpp Docker Model Runner"
        docker start docker-model-runner >/dev/null 2>&1 || true
        if mn_wait_for_docker_model_runner; then
            return 0
        fi
        print_warning "The installed NVIDIA llama.cpp Docker Model Runner did not start; rebuilding it."
    fi

    if ! command -v git >/dev/null 2>&1; then
        print_error "git is required to build the NVIDIA llama.cpp Docker Model Runner."
        exit 1
    fi

    build_dir="$(mktemp -d "${TMPDIR:-/tmp}/mn-dmr-llamacpp.XXXXXX")"
    print_step "Updating Docker Model Runner to llama.cpp b10524 for NVIDIA"
    if ! git clone --depth 1 https://github.com/docker/model-runner.git "$build_dir"; then
        rm -rf "$build_dir"
        print_error "Could not fetch the Docker Model Runner source needed for the NVIDIA llama.cpp update."
        exit 1
    fi
    if ! docker pull ghcr.io/ggml-org/llama.cpp:server-cuda13-b10524; then
        rm -rf "$build_dir"
        print_error "Could not pull llama.cpp CUDA build b10524."
        exit 1
    fi
    if ! (
        cd "$build_dir"
        mn_run_docker_build --target final-llamacpp \
            --build-arg VERSION=v1.2.6-local-b10524 \
            --build-arg LLAMA_SERVER_VERSION=b10524 \
            --build-arg LLAMA_SERVER_VARIANT=cuda \
            --build-arg LLAMA_UPSTREAM_IMAGE=ghcr.io/ggml-org/llama.cpp:server-cuda13-b10524 \
            -t "$runner_image" .
    ); then
        rm -rf "$build_dir"
        print_error "Could not build the NVIDIA llama.cpp Docker Model Runner."
        exit 1
    fi
    rm -rf "$build_dir"

    # This replaces only the controller container; its named model volume is
    # retained, so existing model artifacts survive the runtime upgrade.
    docker rm -f docker-model-runner >/dev/null 2>&1 || true
    if ! docker run -d \
        --name docker-model-runner \
        --restart unless-stopped \
        --runtime nvidia \
        --gpus all \
        --device /dev/dri:/dev/dri \
        --network bridge \
        -p 127.0.0.1:12434:12434 \
        -p 172.17.0.1:12434:12434 \
        -v docker-model-runner-models:/models:z \
        -e MODEL_RUNNER_PORT=12434 \
        -e MODEL_RUNNER_ENVIRONMENT=moby \
        -e MODEL_RUNNER_SOCK=/var/run/model-runner/model-runner.sock \
        -e LLAMA_SERVER_PATH=/app \
        -e LD_LIBRARY_PATH=/app \
        -e HOME=/home/modelrunner \
        -e MODELS_PATH=/models \
        -e NVIDIA_VISIBLE_DEVICES=all \
        -e NVIDIA_DRIVER_CAPABILITIES=compute,utility \
        --label com.docker.desktop.service=model-runner \
        --label com.docker.model-runner.role=controller \
        "$runner_image" >/dev/null; then
        print_error "Could not start the NVIDIA llama.cpp Docker Model Runner."
        exit 1
    fi
    if ! mn_wait_for_docker_model_runner; then
        print_error "The NVIDIA llama.cpp Docker Model Runner did not become ready."
        exit 1
    fi
    print_success "Docker Model Runner is using llama.cpp CUDA build b10524."
}

function mn_resolve_docker_host_socket() {
    local context_host=""

    case "${DOCKER_HOST:-}" in
        unix://*)
            printf '%s\n' "${DOCKER_HOST#unix://}"
            return 0
            ;;
    esac

    if command -v docker >/dev/null 2>&1; then
        context_host="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null | head -n 1 || true)"
        case "$context_host" in
            unix://*)
                printf '%s\n' "${context_host#unix://}"
                return 0
                ;;
        esac
    fi

    if [ "$(uname -s)" = "Darwin" ]; then
        printf '%s/.docker/run/docker.sock\n' "$HOME"
    else
        printf '/var/run/docker.sock\n'
    fi
}

function mn_report_docker_daemon_failure() {
    if docker info >/dev/null 2>&1; then
        return 0
    fi

    print_error "Docker stopped responding during installation."
    if [ "$(uname -s)" = "Darwin" ]; then
        print_error "Restart Docker Desktop and rerun install.sh; the installer is safe to retry."
        print_error "If Docker reports a containerd/bbolt assertion, collect diagnostics before resetting Docker data."
    else
        print_error "Restart the Docker daemon and rerun install.sh; the installer is safe to retry."
    fi
}

function mn_run_docker_build() {
    local status
    if docker build "$@"; then
        return 0
    else
        status=$?
    fi
    mn_report_docker_daemon_failure
    return "$status"
}

function mn_print_docker_desktop_permission_notice() {
    [ "$(uname -s)" = "Darwin" ] || return 0

    printf '==> Preparing Docker Desktop access\n' >&3
    printf 'Docker Desktop may ask Terminal to access data from other apps. Select Allow so the installer can configure Docker services and Model Runner.\n' >&3
}

function mn_preferred_shell_profile() {
    local shell_path="${SHELL:-}"
    local shell_name="${shell_path##*/}"

    case "$shell_name" in
        zsh)
            printf '%s/.zshrc\n' "$HOME"
            ;;
        bash)
            if [ "$(uname -s)" = "Darwin" ]; then
                printf '%s/.bash_profile\n' "$HOME"
            else
                printf '%s/.bashrc\n' "$HOME"
            fi
            ;;
        sh)
            printf '%s/.profile\n' "$HOME"
            ;;
        *)
            if [ "$(uname -s)" = "Darwin" ]; then
                printf '%s/.zshrc\n' "$HOME"
            else
                printf '%s/.profile\n' "$HOME"
            fi
            ;;
    esac
}

function mn_deduplicate_profile_line() {
    local profile="$1"
    local target_line="$2"
    local line_count
    local temporary_profile

    [ -f "$profile" ] || return 0
    line_count="$(grep -Fxc -- "$target_line" "$profile" 2>/dev/null || true)"
    [ "${line_count:-0}" -gt 1 ] || return 0

    temporary_profile="$(mktemp "${profile}.mn.XXXXXX")"
    if ! MN_PROFILE_TARGET_LINE="$target_line" awk '
        $0 == ENVIRON["MN_PROFILE_TARGET_LINE"] {
            if (found) next
            found = 1
        }
        { print }
    ' "$profile" > "$temporary_profile"; then
        rm -f "$temporary_profile"
        return 1
    fi
    if ! cat "$temporary_profile" > "$profile"; then
        rm -f "$temporary_profile"
        return 1
    fi
    rm -f "$temporary_profile"
}

function mn_deduplicate_generated_profile_exports() {
    local profile="$1"
    local path_line="$2"
    local home_line="$3"

    mn_deduplicate_profile_line "$profile" "# MN and OTTERDESK"
    mn_deduplicate_profile_line "$profile" "$path_line"
    mn_deduplicate_profile_line "$profile" "$home_line"
}

function mn_print_next_shell_command() {
    local command_text="$1"

    if [ "${MN_SHELL_PROFILE_RELOAD_REQUIRED:-N}" = "Y" ]; then
        printf 'Next: source %q && %s\n' "$MN_SHELL_PROFILE_PATH" "$command_text" >&3
    else
        printf 'Next: %s\n' "$command_text" >&3
    fi
}

function mn_print_cli_verification_prompt() {
    [ "${INSTALL_CLI:-N}" = "Y" ] || return 0

    printf 'Next: Open a new terminal session, then run mn --help to confirm the CLI is available.\n' >&3
}

function mn_run_runtime_compose() {
    local log_dir="${TMPDIR:-/tmp}/mirror_neuron_install"
    local log_file="${log_dir}/docker-compose.$$.log"
    local status

    if [ "$MN_INSTALL_VERBOSE" = "Y" ]; then
        runtime_compose "$@"
        return
    fi

    mkdir -p "$log_dir"
    if runtime_compose "$@" >"$log_file" 2>&1; then
        rm -f "$log_file"
        return 0
    else
        status=$?
    fi

    print_error "Docker Compose failed. Details: $log_file"
    printf '  Re-run with --verbose to show Compose output directly.\n' >&3
    return "$status"
}

MN_RUNTIME_START_LOG=""
function mn_run_runtime_start_command() {
    local log_dir="${TMPDIR:-/tmp}/mirror_neuron_install"
    local log_file="${log_dir}/runtime-start.$$.log"
    local status

    # Never hide command output while leaving it attached to interactive input.
    # A future CLI prompt must be visible instead of appearing as an installer hang.
    if [ "$MN_INSTALL_VERBOSE" = "Y" ] || [ -t 0 ]; then
        MN_DISABLE_UPDATE_CHECK=1 "$@"
        return
    fi

    mkdir -p "$log_dir"
    if MN_DISABLE_UPDATE_CHECK=1 MN_CLI_OUTPUT=plain "$@" </dev/null >"$log_file" 2>&1; then
        grep -E '(^|[[:space:]])(! Warning:|warning:|× Error:|error:)' "$log_file" >&3 2>/dev/null || true
        awk '
            /^Runtime node ready (successful|confirmed)[.]$/ { showing = 1 }
            showing { print }
            showing && /^Next: mn node add / { showing = 0 }
        ' "$log_file" >&3
        rm -f "$log_file"
        return 0
    else
        status=$?
    fi

    MN_RUNTIME_START_LOG="$log_file"
    return "$status"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --mode)
            shift
            if [ "$#" -eq 0 ]; then
                echo "install.sh: --mode requires one of github, local, or binary." >&3
                print_unified_usage
                exit 1
            fi
            MN_INSTALL_MODE="$1"
            MN_INSTALL_MODE_EXPLICIT="Y"
            ;;
        --mode=*)
            MN_INSTALL_MODE="${1#*=}"
            MN_INSTALL_MODE_EXPLICIT="Y"
            ;;
        --version)
            shift
            if [ "$#" -eq 0 ]; then
                echo "install.sh: --version requires a release tag such as v1.2.31." >&3
                print_unified_usage
                exit 1
            fi
            MN_INSTALL_VERSION="$1"
            ;;
        --version=*)
            MN_INSTALL_VERSION="${1#*=}"
            ;;
        -h|--help)
            MN_INSTALL_HELP_REQUESTED="Y"
            ;;
        -v|--verbose)
            MN_INSTALL_VERBOSE="Y"
            ;;
        --reset)
            MN_INSTALL_RESET="Y"
            ;;
        *)
            MN_INSTALL_ARGS+=("$1")
            ;;
    esac
    shift
done

case "$MN_INSTALL_MODE" in
    github|local|binary) ;;
    *)
        echo "install.sh: invalid --mode '$MN_INSTALL_MODE'. Expected github, local, or binary." >&3
        print_unified_usage
        exit 1
        ;;
esac

if [ -n "$MN_INSTALL_VERSION" ]; then
    mn_validate_version_tag_or_exit "$MN_INSTALL_VERSION"
fi

if [ "$MN_INSTALL_MODE" = "local" ] && [ -n "$MN_INSTALL_VERSION" ]; then
    echo "install.sh: --version is supported only for binary and github modes. Use --mode local without --version for local source installs." >&3
    exit 1
fi

if [ "$MN_INSTALL_HELP_REQUESTED" = "Y" ]; then
    if [ "$MN_INSTALL_MODE_EXPLICIT" = "Y" ]; then
        MN_INSTALL_ARGS+=("--help")
    else
        print_unified_usage
        exit 0
    fi
fi

export MN_INSTALL_VERSION
export MN_HOME="${MN_HOME:-${HOME}/.mn}"

function mn_script_dir() {
    local source_path=""
    if [ "${BASH_SOURCE+x}" = "x" ]; then
        source_path="${BASH_SOURCE[0]:-}"
    fi
    source_path="${source_path:-$0}"

    case "$source_path" in
        ""|-|bash|sh|/dev/fd/*|/dev/stdin|/proc/self/fd/*)
            pwd
            ;;
        *)
            cd "$(dirname "$source_path")" && pwd
            ;;
    esac
}

function mn_reset_error() {
    printf 'error: %s\n' "$1" >&3
}

function mn_reset_warning() {
    printf 'warning: %s\n' "$1" >&3
}

function mn_reset_resolve_home_or_exit() {
    local configured_home="${MN_HOME:-}"
    local parent_dir base_name resolved_parent resolved_home
    local resolved_user_home resolved_pwd script_dir workspace_dir

    if [ -z "$configured_home" ]; then
        mn_reset_error "MN_HOME is empty; refusing to reset an unresolved path."
        exit 1
    fi

    case "$configured_home" in
        /*) ;;
        *) configured_home="${PWD}/${configured_home}" ;;
    esac

    while [ "$configured_home" != "/" ] && [[ "$configured_home" == */ ]]; do
        configured_home="${configured_home%/}"
    done

    parent_dir="$(dirname "$configured_home")"
    base_name="$(basename "$configured_home")"
    if [ "$base_name" = "." ] || [ "$base_name" = ".." ] || [ ! -d "$parent_dir" ]; then
        mn_reset_error "Cannot safely resolve reset target: ${configured_home}"
        mn_reset_error "Set MN_HOME to an installation path whose parent directory exists."
        exit 1
    fi

    resolved_parent="$(cd "$parent_dir" && pwd -P)"
    resolved_home="${resolved_parent}/${base_name}"
    resolved_user_home="$(cd "$HOME" && pwd -P)"
    resolved_pwd="$(pwd -P)"

    if [ "$resolved_home" = "/" ] || [ "$resolved_home" = "$resolved_user_home" ]; then
        mn_reset_error "Refusing to reset protected path: ${resolved_home}"
        exit 1
    fi
    if [ "$resolved_home" = "$resolved_pwd" ]; then
        mn_reset_error "Refusing to reset the current working directory: ${resolved_home}"
        exit 1
    fi
    if [ -L "$resolved_home" ]; then
        mn_reset_error "Refusing to reset symlinked MN_HOME: ${resolved_home}"
        mn_reset_error "Set MN_HOME to the symlink target explicitly, then rerun with --reset."
        exit 1
    fi
    if [ -e "$resolved_home" ] && [ ! -d "$resolved_home" ]; then
        mn_reset_error "Reset target is not a directory: ${resolved_home}"
        exit 1
    fi

    script_dir="$(mn_script_dir)"
    if [ -d "$script_dir" ]; then
        script_dir="$(cd "$script_dir" && pwd -P)"
        workspace_dir="$(dirname "$script_dir")"
        if [ "$resolved_home" = "$script_dir" ] || [ "$resolved_home" = "$workspace_dir" ]; then
            mn_reset_error "Refusing to reset a MirrorNeuron source directory: ${resolved_home}"
            exit 1
        fi
        if [ "$(dirname "$resolved_home")" = "$workspace_dir" ] &&
           { [ -d "${resolved_home}/.git" ] || [ -f "${resolved_home}/.git" ]; }; then
            mn_reset_error "Refusing to reset a source repository in the MirrorNeuron workspace: ${resolved_home}"
            exit 1
        fi
    fi

    MN_RESET_HOME="$resolved_home"
}

function mn_reset_read_env_value() {
    local file="$1"
    local key="$2"
    [ -f "$file" ] || return 0
    awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$file"
}

MN_RESET_CLEANUP_IMAGES=()

function mn_reset_add_cleanup_image() {
    local image="$1"
    local existing_image

    [ -n "$image" ] || return 0
    for existing_image in "${MN_RESET_CLEANUP_IMAGES[@]:-}"; do
        [ "$existing_image" = "$image" ] && return 0
    done
    MN_RESET_CLEANUP_IMAGES+=("$image")
}

function mn_reset_capture_cleanup_images() {
    local compose_env_file="$1"
    local project_name="$2"
    local container_name resource_id image redis_image

    # Prefer images that are already running this runtime. They are guaranteed
    # to be available locally and avoid pulling an image during a reset.
    for container_name in \
        mirror-neuron-redis \
        mn-litellm-proxy \
        mirror-neuron-core \
        mirror-neuron-syncthing \
        mirror-neuron-context-engine-model \
        mirror-neuron-context-engine \
        mirror-neuron-native-sdk-grpc; do
        image="$(docker container inspect --format '{{.Config.Image}}' "$container_name" 2>/dev/null || true)"
        mn_reset_add_cleanup_image "$image"
    done

    while IFS= read -r resource_id; do
        [ -n "$resource_id" ] || continue
        image="$(docker container inspect --format '{{.Config.Image}}' "$resource_id" 2>/dev/null || true)"
        mn_reset_add_cleanup_image "$image"
    done < <(docker ps -aq --filter "label=com.docker.compose.project=${project_name}" 2>/dev/null || true)

    # A prior reset may already have removed the containers while leaving
    # Docker-owned bind-mount files behind. Redis is part of the managed
    # runtime, and its locally cached image provides a small POSIX shell.
    redis_image="$(mn_reset_read_env_value "$compose_env_file" "MN_REDIS_IMAGE")"
    redis_image="${redis_image:-redis:8}"
    if docker image inspect "$redis_image" >/dev/null 2>&1; then
        mn_reset_add_cleanup_image "$redis_image"
    fi
}

function mn_reset_remove_docker_owned_files() {
    local cleanup_image
    local cleanup_command='rm -rf /mnt/mn-reset/* /mnt/mn-reset/.[!.]* /mnt/mn-reset/..?*'

    # MN_RESET_HOME was resolved and rejected if it is a symlink before this
    # function can run. Mount only that exact runtime directory, never its
    # parent or HOME, and use an image already available on the host.
    for cleanup_image in "${MN_RESET_CLEANUP_IMAGES[@]:-}"; do
        [ -n "$cleanup_image" ] || continue
        if docker run --rm --user 0:0 \
            --volume "$MN_RESET_HOME:/mnt/mn-reset:rw" \
            --entrypoint /bin/sh \
            "$cleanup_image" -ec "$cleanup_command" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

function mn_reset_confirm_or_exit() {
    local confirmation=""

    mn_reset_warning "RESET PERMANENTLY DELETES all MirrorNeuron runtime data in ${MN_RESET_HOME}."
    if [ -n "${VENV_DIR:-}" ]; then
        mn_reset_warning "The MirrorNeuron Python virtual environment at ${VENV_DIR} will also be removed."
    fi
    mn_reset_warning "MirrorNeuron Docker containers and volumes will be removed, including all Redis data."
    mn_reset_warning "This cannot be undone, and --yes does not bypass this confirmation."
    printf 'Type YES to reset MirrorNeuron and continue with a fresh install: ' >&3

    if [ -t 0 ]; then
        IFS= read -r confirmation || confirmation=""
    elif { exec 4</dev/tty; } 2>/dev/null; then
        IFS= read -r confirmation <&4 || confirmation=""
        exec 4<&-
    else
        IFS= read -r confirmation || confirmation=""
    fi

    if [ "$confirmation" != "YES" ]; then
        mn_reset_warning "Reset cancelled; no data was changed."
        exit 0
    fi
}

function mn_reset_docker_state_or_exit() {
    local compose_file="${MN_RESET_HOME}/docker-compose.yml"
    local compose_env_file="${MN_RESET_HOME}/docker-compose.env"
    local project_name=""
    local cleanup_failed="N"
    local resource_id redis_volume container_name
    local redis_container="mirror-neuron-redis"
    local redis_cli_script
    local -a compose_args=()

    if ! command -v docker >/dev/null 2>&1; then
        mn_reset_error "docker is required to clear Redis and MirrorNeuron runtime volumes."
        exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        mn_reset_error "Docker is not running; reset stopped before deleting ${MN_RESET_HOME}."
        printf 'Next: start Docker, then rerun install.sh --reset.\n' >&3
        exit 1
    fi

    project_name="$(mn_reset_read_env_value "$compose_env_file" "COMPOSE_PROJECT_NAME")"
    project_name="${project_name:-mirror-neuron}"
    if ! [[ "$project_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
        mn_reset_error "Invalid Compose project name in ${compose_env_file}: ${project_name}"
        exit 1
    fi

    mn_reset_capture_cleanup_images "$compose_env_file" "$project_name"

    printf '==> Clearing Redis and stopping the existing MirrorNeuron runtime\n' >&3
    redis_cli_script='if [ -n "${MN_REDIS_PASSWORD:-}" ]; then
  redis-cli --no-auth-warning -a "$MN_REDIS_PASSWORD" FLUSHALL
  redis-cli --no-auth-warning -a "$MN_REDIS_PASSWORD" MEMORY PURGE >/dev/null 2>&1 || true
else
  redis-cli FLUSHALL
  redis-cli MEMORY PURGE >/dev/null 2>&1 || true
fi'
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$redis_container"; then
        if docker exec -i "$redis_container" sh -c "$redis_cli_script" >/dev/null 2>&1; then
            printf '✓ Cleared all Redis databases.\n' >&3
        else
            mn_reset_warning "Redis FLUSHALL failed; removing its persistent Docker volume instead."
        fi
    fi

    if [ -f "$compose_file" ]; then
        if docker compose version >/dev/null 2>&1; then
            compose_args=(--project-name "$project_name" -f "$compose_file")
            if [ -f "$compose_env_file" ]; then
                compose_args=(--env-file "$compose_env_file" "${compose_args[@]}")
            fi
            if ! docker compose "${compose_args[@]}" down --remove-orphans --volumes >/dev/null 2>&1; then
                mn_reset_warning "Docker Compose teardown was incomplete; cleaning owned resources by project label."
            fi
        elif command -v docker-compose >/dev/null 2>&1; then
            compose_args=(--project-name "$project_name" -f "$compose_file")
            if [ -f "$compose_env_file" ]; then
                compose_args=(--env-file "$compose_env_file" "${compose_args[@]}")
            fi
            if ! docker-compose "${compose_args[@]}" down --remove-orphans --volumes >/dev/null 2>&1; then
                mn_reset_warning "Docker Compose teardown was incomplete; cleaning owned resources by project label."
            fi
        fi
    fi

    while IFS= read -r resource_id; do
        [ -n "$resource_id" ] || continue
        if ! docker rm -f "$resource_id" >/dev/null 2>&1; then
            cleanup_failed="Y"
        fi
    done < <(docker ps -aq --filter "label=com.docker.compose.project=${project_name}" 2>/dev/null || true)

    for container_name in \
        mirror-neuron-core \
        mirror-neuron-redis \
        mirror-neuron-web-ui \
        mirror-neuron-syncthing \
        mirror-neuron-context-engine-model \
        mirror-neuron-context-engine \
        mirror-neuron-native-sdk-grpc \
        mn-litellm-proxy \
        openshell-cluster-openshell; do
        if docker container inspect "$container_name" >/dev/null 2>&1; then
            if ! docker rm -f "$container_name" >/dev/null 2>&1; then
                cleanup_failed="Y"
            fi
        fi
    done

    while IFS= read -r resource_id; do
        [ -n "$resource_id" ] || continue
        if ! docker volume rm -f "$resource_id" >/dev/null 2>&1; then
            cleanup_failed="Y"
        fi
    done < <(docker volume ls -q --filter "label=com.docker.compose.project=${project_name}" 2>/dev/null || true)

    redis_volume="${project_name}_redis-data"
    if docker volume inspect "$redis_volume" >/dev/null 2>&1; then
        if ! docker volume rm -f "$redis_volume" >/dev/null 2>&1; then
            cleanup_failed="Y"
        fi
    fi

    if [ "$cleanup_failed" = "Y" ]; then
        mn_reset_error "Could not remove all MirrorNeuron Docker containers or volumes."
        mn_reset_error "Reset stopped before deleting ${MN_RESET_HOME}."
        exit 1
    fi
    printf '✓ Removed MirrorNeuron Docker runtime and persistent Redis data.\n' >&3
}

function mn_reset_install_state() {
    mn_reset_resolve_home_or_exit
    mn_reset_confirm_or_exit
    mn_reset_docker_state_or_exit

    if [ -n "${VENV_DIR:-}" ] && { [ -e "$VENV_DIR" ] || [ -L "$VENV_DIR" ]; }; then
        printf '==> Clearing MirrorNeuron Python virtual environment\n' >&3
        mn_remove_path_or_exit "$VENV_DIR" "MirrorNeuron Python virtual environment"
    fi

    printf '==> Recreating MirrorNeuron runtime data directory\n' >&3
    if [ -d "$MN_RESET_HOME" ]; then
        chmod -R u+rwX "$MN_RESET_HOME" 2>/dev/null || true
        if ! rm -rf "$MN_RESET_HOME"; then
            mn_reset_warning "Host removal failed; cleaning Docker-owned runtime files through Docker."
            if ! mn_reset_remove_docker_owned_files; then
                mn_reset_error "Could not remove MirrorNeuron runtime data: ${MN_RESET_HOME}"
                mn_reset_error "Docker could not clean the remaining runtime files. Verify Docker access, then repair ownership and rerun --reset."
                exit 1
            fi
            if ! rm -rf "$MN_RESET_HOME"; then
                mn_reset_error "Could not remove MirrorNeuron runtime data after Docker cleanup: ${MN_RESET_HOME}"
                exit 1
            fi
        fi
    fi
    if ! mkdir -p "$MN_RESET_HOME"; then
        mn_reset_error "Could not recreate MirrorNeuron runtime data directory: ${MN_RESET_HOME}"
        exit 1
    fi
    chmod u+rwx "$MN_RESET_HOME" 2>/dev/null || true
    export MN_HOME="$MN_RESET_HOME"
    printf '✓ Reset MirrorNeuron runtime data. Continuing with a fresh install.\n' >&3
}

function mn_reset_drop_conflicting_install_args() {
    local arg
    local -a filtered_args=()

    for arg in "${MN_INSTALL_ARGS[@]}"; do
        if [ "$arg" = "--no-reinstall" ]; then
            mn_reset_warning "Ignoring --no-reinstall because --reset requires a fresh installation."
        else
            filtered_args+=("$arg")
        fi
    done
    MN_INSTALL_ARGS=("${filtered_args[@]}")
}

function mn_github_raw_asset_url() {
    local relative_path="$1"
    local repo="${MN_DEPLOY_ASSET_REPO:-MirrorNeuronLab/mn-deploy}"
    local ref="${MN_DEPLOY_ASSET_REF:-main}"
    local base_url="${MN_DEPLOY_RAW_BASE_URL:-https://raw.githubusercontent.com/${repo}/${ref}}"
    printf '%s/%s' "${base_url%/}" "$relative_path"
}

function mn_download_public_repo_asset() {
    local relative_path="$1"
    local target="$2"
    local description="$3"
    local url

    url="$(mn_github_raw_asset_url "$relative_path")"
    mkdir -p "$(dirname "$target")"
    if ! curl_github -fsSL "$url" -o "$target"; then
        print_error "Could not download ${description} from ${url}."
        exit 1
    fi
}

function mn_runtime_compose_template_is_valid() {
    local template="$1"
    [ -f "$template" ] &&
        grep -q '^name: mirror-neuron$' "$template" &&
        grep -q 'mirror-neuron-core' "$template" || return 1
}

function mn_ensure_runtime_compose_template_file() {
    local support_asset_path

    if mn_runtime_compose_template_is_valid "$RUNTIME_COMPOSE_TEMPLATE"; then
        return 0
    fi

    support_asset_path="$(mn_install_support_asset_path "docker-compose.yml")"
    RUNTIME_COMPOSE_TEMPLATE="${TMPDIR:-/tmp}/mirror_neuron_install/docker-compose.yml"
    mn_download_public_repo_asset "$support_asset_path" "$RUNTIME_COMPOSE_TEMPLATE" "MirrorNeuron runtime Docker Compose template"
    if ! mn_runtime_compose_template_is_valid "$RUNTIME_COMPOSE_TEMPLATE"; then
        print_error "Downloaded MirrorNeuron runtime Docker Compose template is invalid: $RUNTIME_COMPOSE_TEMPLATE"
        exit 1
    fi
}

function mn_write_runtime_compose_file() {
    RUNTIME_COMPOSE_TEMPLATE="$1"
    local target="$2"
    mn_ensure_runtime_compose_template_file
    mkdir -p "$(dirname "$target")"
    cp "$RUNTIME_COMPOSE_TEMPLATE" "$target"
    rm -f "$(dirname "$target")/docker-compose.models.yml"
}

function mn_remove_dockerfile_frontend_directive() {
    local dockerfile="$1"
    local first_line tmp_file

    [ -f "$dockerfile" ] || return 0
    IFS= read -r first_line < "$dockerfile" || return 0
    case "$first_line" in
        "# syntax=docker/dockerfile:"*|"# syntax = docker/dockerfile:"*) ;;
        *) return 0 ;;
    esac

    tmp_file="$(mktemp "${TMPDIR:-/tmp}/mn-dockerfile.XXXXXX")"
    tail -n +2 "$dockerfile" > "$tmp_file"
    cat "$tmp_file" > "$dockerfile"
    rm -f "$tmp_file"
}

function mn_stop_runtime_containers_for_reinstall() {
    local container_ids

    if ! command -v docker >/dev/null 2>&1; then
        return 0
    fi

    container_ids="$(docker ps -aq --filter "label=com.docker.compose.project=mirror-neuron" 2>/dev/null || true)"
    if [ -z "$container_ids" ]; then
        return 0
    fi

    print_step "Stopping existing MirrorNeuron runtime"
    if ! docker rm -f $container_ids >/dev/null 2>&1; then
        print_error "Could not stop existing MirrorNeuron runtime containers."
        print_error "Stop them with: docker rm -f $container_ids"
        exit 1
    fi
}

function mn_remove_path_or_exit() {
    local path="$1"
    local description="$2"

    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        return 0
    fi

    if [ -d "$path" ] && [ ! -L "$path" ]; then
        chmod -R u+rwX "$path" 2>/dev/null || true
        if rm -rf "$path"; then
            return 0
        fi
    elif rm -f "$path"; then
        return 0
    fi

    print_error "Could not remove ${description}: ${path}"
    print_error "The path may still be mounted by Docker or owned by another user."
    print_error "Stop MirrorNeuron containers, repair ownership, and rerun the installer:"
    print_error "  docker rm -f \$(docker ps -aq --filter label=com.docker.compose.project=mirror-neuron)"
    print_error "  sudo chown -R $(id -u):$(id -g) \"${path}\""
    exit 1
}

function mn_remove_existing_install_paths() {
    mn_stop_runtime_containers_for_reinstall
    mn_remove_path_or_exit "$INSTALL_DIR" "MirrorNeuron state directory"
    mn_remove_path_or_exit "$VENV_DIR" "MirrorNeuron Python virtual environment"
    mn_remove_path_or_exit "$BIN_DIR/mn" "MirrorNeuron CLI executable"
    mn_remove_path_or_exit "$BIN_DIR/mn-api" "MirrorNeuron API executable"
}

function mn_python_package_index_is_valid() {
    local index_file="$1"
    [ -f "$index_file" ] &&
        grep -q 'name = "mirrorneuron-python-sdk"' "$index_file" &&
        grep -q 'installer_groups = \["sdk"\]' "$index_file"
}

function mn_ensure_python_package_index_file() {
    local support_asset_path

    if mn_python_package_index_is_valid "$PACKAGE_INDEX_FILE"; then
        return 0
    fi

    if [ -n "${MN_PACKAGE_INDEX_FILE:-}" ]; then
        print_error "MirrorNeuron Python package index is required but was not found at $PACKAGE_INDEX_FILE."
        exit 1
    fi

    support_asset_path="$(mn_install_support_asset_path "package-index/python-packages.toml")"
    PACKAGE_INDEX_FILE="${TMPDIR:-/tmp}/mirror_neuron_install/python-packages.toml"
    mn_download_public_repo_asset "$support_asset_path" "$PACKAGE_INDEX_FILE" "MirrorNeuron Python package index"
    if ! mn_python_package_index_is_valid "$PACKAGE_INDEX_FILE"; then
        print_error "Downloaded MirrorNeuron Python package index is invalid: $PACKAGE_INDEX_FILE"
        exit 1
    fi
}

run_install_github() {
#!/usr/bin/env bash

set -euo pipefail

# Keep installer output visible even when a subcommand redirects stdout/stderr.
exec 3>&1

# Never let git/pip block the installer by asking for GitHub credentials.
export GIT_TERMINAL_PROMPT="${GIT_TERMINAL_PROMPT:-0}"
export GH_PROMPT_DISABLED="${GH_PROMPT_DISABLED:-1}"
export PIP_NO_INPUT="${PIP_NO_INPUT:-1}"

# Use color only for an interactive terminal and respect the NO_COLOR convention.
if [ -t 3 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    ESC="$(printf '\033')"
    BOLD="${ESC}[1m"
    DIM="${ESC}[2m"
    RED="${ESC}[31m"
    GREEN="${ESC}[32m"
    YELLOW="${ESC}[33m"
    BLUE="${ESC}[34m"
    CYAN="${ESC}[36m"
    MAGENTA="${ESC}[35m"
    RESET="${ESC}[0m"
else
    BOLD=""
    DIM=""
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    CYAN=""
    MAGENTA=""
    RESET=""
fi

MN_MANAGED_PYTHON="${MN_MANAGED_PYTHON:-1}"
MN_MANAGED_PYTHON_VERSION="${MN_MANAGED_PYTHON_VERSION:-3.11}"
MN_MANAGED_PYTHON_ROOT="${MN_MANAGED_PYTHON_DIR:-${HOME}/.local/share/mn_python}"
MN_UV_ROOT="${MN_UV_DIR:-${HOME}/.local/share/mn_uv}"
MN_UV_BIN=""
MN_GITHUB_TOKEN_LOOKED_UP="N"
MN_GITHUB_TOKEN_VALUE=""
MN_GITHUB_GIT_AUTH_CONFIGURED="N"

function print_header() {
    printf '\n%s%s%s\n' "${BLUE}${BOLD}" "MirrorNeuron Installer" "$RESET" >&3
    printf '  Source: GitHub repositories\n' >&3
}

function print_step() { printf '%s==>%s %s\n' "${CYAN}${BOLD}" "$RESET" "$1" >&3; }
function print_success() { printf '%s✔%s %s\n' "${GREEN}${BOLD}" "$RESET" "$1" >&3; }
function print_error() { printf '%serror:%s %s\n' "${RED}${BOLD}" "$RESET" "$1" >&3; }
function print_warning() { printf '%swarning:%s %s\n' "${YELLOW}${BOLD}" "$RESET" "$1" >&3; }
function print_detail() {
    if [ "$MN_INSTALL_VERBOSE" = "Y" ]; then
        printf '    %s\n' "$1" >&3
    fi
}

function find_source_workspace() {
    local script_dir
    script_dir="$(mn_script_dir)"

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
        print_error "$label failed. Details: $log_file"
        if [ "$MN_INSTALL_VERBOSE" = "Y" ]; then
            tail -n 20 "$log_file" >&3 2>/dev/null || true
        else
            printf '  Re-run with --verbose to show the last log lines.\n' >&3
        fi
        if grep -Eqi "could not read Username for 'https://github.com'|authentication failed|repository not found" "$log_file" 2>/dev/null; then
            print_error "GitHub clone authentication failed. For private MirrorNeuron repositories, run 'gh auth login' or set GITHUB_TOKEN/GH_TOKEN and rerun."
        fi
        exit 1
    fi
}

function spinner() {
    local pid=$1
    local msg=$2
    local delay=0.1
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local frame_index=0
    local interactive="N"
    if [ -t 3 ]; then
        interactive="Y"
        tput civis >&3 2>/dev/null || true
        while kill -0 "$pid" 2>/dev/null; do
            printf '\r%s%s%s %s' "${MAGENTA}${BOLD}" "${frames[$frame_index]}" "$RESET" "$msg" >&3
            frame_index=$(((frame_index + 1) % ${#frames[@]}))
            sleep "$delay"
        done
    else
        print_step "$msg"
    fi
    set +e
    wait "$pid"
    local exit_code=$?
    set -e
    if [ "$exit_code" -eq 0 ]; then
        if [ "$interactive" = "Y" ]; then printf '\r\033[2K' >&3; fi
        print_success "$msg"
    else
        if [ "$interactive" = "Y" ]; then printf '\r\033[2K' >&3; fi
        print_error "$msg failed."
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
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        print_error "'$cmd' is required but not installed."
        exit 1
    fi
}

function resolve_github_token() {
    local token=""

    if [ "$MN_GITHUB_TOKEN_LOOKED_UP" = "Y" ]; then
        return 0
    fi

    token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
    if [ -z "$token" ] && command -v gh >/dev/null 2>&1; then
        token="$(gh auth token 2>/dev/null || true)"
    fi

    MN_GITHUB_TOKEN_LOOKED_UP="Y"
    MN_GITHUB_TOKEN_VALUE="$token"
}

function configure_github_git_auth() {
    local token askpass log_dir

    if [ "$MN_GITHUB_GIT_AUTH_CONFIGURED" = "Y" ]; then
        return 0
    fi

    resolve_github_token
    token="$MN_GITHUB_TOKEN_VALUE"
    if [ -z "$token" ]; then
        return 0
    fi

    log_dir="${TMPDIR:-/tmp}/mirror_neuron_install"
    mkdir -p "$log_dir"
    askpass="${log_dir}/github-askpass.$$"
    cat > "$askpass" <<'EOF'
#!/usr/bin/env sh
case "$1" in
    *Username*) printf '%s\n' "x-access-token" ;;
    *Password*) printf '%s\n' "$MN_GITHUB_TOKEN_FOR_GIT" ;;
    *) printf '%s\n' "$MN_GITHUB_TOKEN_FOR_GIT" ;;
esac
EOF
    chmod 700 "$askpass"
    export MN_GITHUB_TOKEN_FOR_GIT="$token"
    export GIT_ASKPASS="$askpass"
    MN_GITHUB_GIT_AUTH_CONFIGURED="Y"
    print_detail "Configured GitHub authentication for non-interactive Git clones."
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

function python_is_selected_minor() {
    [ "$(python_minor_version "$1" || true)" = "$MN_MANAGED_PYTHON_VERSION" ]
}

function curl_github() {
    local token
    resolve_github_token
    token="$MN_GITHUB_TOKEN_VALUE"
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

    print_detail "Installed uv at $MN_UV_BIN."
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
    print_warning "No Python ${MN_MANAGED_PYTHON_VERSION}.x interpreter was found; uv will manage a private runtime under ${MN_MANAGED_PYTHON_ROOT}."
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
    print_detail "Using uv-managed Python $(python_version "$managed_bin") at $managed_bin."
}

function print_python_requirement_error() {
    local selected="${1:-}"
    local version=""

    print_error "MirrorNeuron Python components require Python ${MN_MANAGED_PYTHON_VERSION}.x by default."
    if [ -n "$selected" ]; then
        version="$(python_version "$selected" || true)"
        if [ -n "$version" ]; then
            print_error "Selected Python '$selected' is version $version."
        else
            print_error "Selected Python '$selected' could not be run."
        fi
    fi
    print_error "Install Python ${MN_MANAGED_PYTHON_VERSION}.x yourself, or allow the uv-managed private runtime fallback."
    print_error "You can also rerun with: MN_PYTHON=/opt/homebrew/bin/python${MN_MANAGED_PYTHON_VERSION} ./$(basename "$0")"
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
        candidates+=("python${MN_MANAGED_PYTHON_VERSION}" python3 python)
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
        if python_is_supported "$resolved" && python_is_selected_minor "$resolved"; then
            MN_PYTHON_BIN="$resolved"
            print_detail "Using Python $(python_version "$MN_PYTHON_BIN") at $MN_PYTHON_BIN."
            return
        fi
        if [ -n "${MN_PYTHON:-}" ]; then
            print_python_requirement_error "$resolved"
            exit 1
        fi
    done

    if managed_python_enabled; then
        install_managed_python
        print_detail "Using Python $(python_version "$MN_PYTHON_BIN") at $MN_PYTHON_BIN."
        return
    fi

    print_warning "Managed Python fallback is disabled."
    resolved="$(command -v "python${MN_MANAGED_PYTHON_VERSION}" 2>/dev/null || true)"
    print_python_requirement_error "$resolved"
    exit 1
}

INSTALL_DIR="${MN_HOME:-${HOME}/.mn}"
BIN_DIR="${HOME}/.local/bin"
VENV_DIR="${HOME}/.local/share/mn_venv"
MN_PYTHON_BIN=""
SOURCE_WORKSPACE=""
SCRIPT_DIR="$(mn_script_dir)"
RUNTIME_COMPOSE_TEMPLATE="${MN_RUNTIME_COMPOSE_TEMPLATE:-}"
RUNTIME_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
RUNTIME_COMPOSE_ENV="${INSTALL_DIR}/docker-compose.env"
MN_WEB_UI_SOURCE_MODE="${MN_WEB_UI_SOURCE_MODE:-source}"
MN_WEB_UI_SOURCE_MOUNT="${MN_WEB_UI_SOURCE_MOUNT:-${INSTALL_DIR}/webui}"
MN_WEB_UI_PACKAGE_VERSION="${MN_WEB_UI_PACKAGE_VERSION:-}"
INSTALL_CONTEXT_ENGINE="N"
MEMBRANE_REPO="${MN_MEMBRANE_REPO:-MirrorNeuronLab/Membrane}"
MEMBRANE_GIT_URL="${MN_MEMBRANE_GIT_URL:-}"
MEMBRANE_DIR="${MN_MEMBRANE_DIR:-${INSTALL_DIR}/Membrane}"
AGENTS_REPO="${MN_AGENTS_REPO:-MirrorNeuronLab/mn-agents}"
MN_AGENTS_GIT_URL="${MN_AGENTS_GIT_URL:-}"
MN_AGENTS_ROOT="${MN_AGENTS_ROOT:-}"
MN_AGENTS_REF="${MN_AGENTS_REF:-}"
MN_HOST_HOME_DIR="${MN_HOST_HOME_DIR:-${MN_HOST_MN_DIR:-${INSTALL_DIR}}}"
MN_HOST_ARTIFACTS_DIR="${MN_HOST_ARTIFACTS_DIR:-${MN_HOST_HOME_DIR}/runs}"
MN_HOST_BLOB_STORE_DIR="${MN_HOST_BLOB_STORE_DIR:-${MN_HOST_HOME_DIR}/blobs}"
MN_HOST_SHARED_STORAGE_ROOT="${MN_HOST_SHARED_STORAGE_ROOT:-${MN_HOST_SHARED_ARTIFACT_ROOT:-${MN_HOST_HOME_DIR}/shared}}"
MN_SYNCTHING_ENABLED="${MN_SYNCTHING_ENABLED:-auto}"
MN_SYNCTHING_IMAGE="${MN_SYNCTHING_IMAGE:-syncthing/syncthing:latest}"
MN_SYNCTHING_GUI_PORT="${MN_SYNCTHING_GUI_PORT:-58384}"
MN_SYNCTHING_SYNC_PORT="${MN_SYNCTHING_SYNC_PORT:-22000}"
MN_SYNCTHING_RESCAN_INTERVAL_SECONDS="${MN_SYNCTHING_RESCAN_INTERVAL_SECONDS:-3600}"
MN_BLUEPRINT_PYTHON_ENVS_DIR="${MN_BLUEPRINT_PYTHON_ENVS_DIR:-}"
MN_HOST_OPENSHELL_CONFIG_DIR="${OPENSHELL_CONTAINER_CONFIG_DIR:-${HOME}/.config/openshell-mirror-neuron}"
MN_HOST_OPENSHELL_STATE_DIR="${MN_HOST_OPENSHELL_STATE_DIR:-${INSTALL_DIR}/openshell-state}"
OPENSHELL_GATEWAY_USER="${OPENSHELL_GATEWAY_USER:-$(id -u):$(id -g)}"
mn_print_docker_desktop_permission_notice
DOCKER_HOST_SOCKET="${DOCKER_HOST_SOCKET:-$(mn_resolve_docker_host_socket)}"
if [ -z "${OPENSHELL_GATEWAY_DOCKER_GROUP:-}" ] && [ "$(uname -s)" = "Darwin" ]; then
    OPENSHELL_GATEWAY_DOCKER_GROUP="0"
elif [ -z "${OPENSHELL_GATEWAY_DOCKER_GROUP:-}" ] && [ -S "${DOCKER_HOST_SOCKET}" ]; then
    OPENSHELL_GATEWAY_DOCKER_GROUP="$(stat -c '%g' "${DOCKER_HOST_SOCKET}" 2>/dev/null || stat -f '%g' "${DOCKER_HOST_SOCKET}" 2>/dev/null || true)"
fi
OPENSHELL_GATEWAY_DOCKER_GROUP="${OPENSHELL_GATEWAY_DOCKER_GROUP:-0}"
MN_DYNAMIC_REDIS_PORT_START="${MN_DYNAMIC_REDIS_PORT_START:-56379}"
MN_DYNAMIC_REDIS_PORT_END="${MN_DYNAMIC_REDIS_PORT_END:-56478}"

INSTALL_WEB_UI="Y"
INSTALL_REDIS="Y"
INSTALL_OPENSHELL="Y"
START_NOW="Y"
REINSTALL="Y"
NON_INTERACTIVE="Y"
INSTALL_PYTHON_SDK="Y"
INSTALL_BLUEPRINT_SUPPORT_SKILL="Y"
INSTALL_CLI="Y"
INSTALL_API="Y"
INSTALL_VERSION="${MN_INSTALL_VERSION:-}"
INSTALL_VERSION_EXPLICIT="N"
[ -n "$INSTALL_VERSION" ] && INSTALL_VERSION_EXPLICIT="Y"
MN_PACKAGE_VERSION=""
CORE_REPO="${MN_CORE_REPO:-MirrorNeuronLab/MirrorNeuron}"
SKILLS_REPO="${MN_SKILLS_REPO:-MirrorNeuronLab/mn-skills}"
MN_SKILLS_GIT_URL="${MN_SKILLS_GIT_URL:-}"
CORE_RELEASE_TAG=""

function github_usage() {
    local script_name="${MN_INSTALL_SCRIPT_NAME:-$(basename "$0")}";
    cat >&3 <<EOF
Usage: ./$script_name --mode github [options]

Installs MirrorNeuron from GitHub repositories. Use through --mode github.

Options:
  --version TAG                 Install this release tag from each GitHub repo. If omitted, use each repo's default branch.
  --yes                         Run non-interactively with defaults and flags. This is the default.
  --interactive                 Ask each install question before proceeding.
  --reset                       Permanently clear runtime data first; requires typing YES.
  -v, --verbose                 Show installation details and command paths.
  --no-reinstall                Keep an existing install instead of overwriting it.
  --web-ui / --no-web-ui        Enable or skip GitHub Web UI install/build.
  --redis / --no-redis          Enable or skip Redis Docker setup.
  --context-engine / --no-context-engine
                                Enable or skip Membrane context engine setup.
  --openshell / --no-openshell  Enable or skip OpenShell gateway setup.
  --syncthing / --no-syncthing  Enable or skip Syncthing shared-storage replication.
  --start / --no-start          Start or skip starting MirrorNeuron after install.
  --python-components LIST      Install only these components: sdk,skill,cli,api.
                                Use all or none as shortcuts.
  --python-sdk / --no-python-sdk
  --skill / --no-skill          Blueprint support skill from GitHub.
  --cli / --no-cli
  --api / --no-api
  --skills-repo OWNER/REPO      Same as MN_SKILLS_REPO. Default: MirrorNeuronLab/mn-skills.
  --skills-git-url URL          Same as MN_SKILLS_GIT_URL.
  MN_AGENTS_ROOT=/path          Override the local agent template catalog.
  MN_AGENTS_REPO=OWNER/REPO     Agent template catalog repo. Default: MirrorNeuronLab/mn-agents.
  MN_AGENTS_GIT_URL=URL         Full agent template catalog Git URL override.
  MN_AGENTS_REF=REF             Agent template catalog ref. Default: --version or repo default branch.
  --python PATH                 Same as MN_PYTHON. Must be Python 3.11.x.
  --no-managed-python           Do not use uv to install a private Python runtime.
  MN_HOME=/path                 Override the runtime state directory. Defaults to ${HOME}/.mn.
  GITHUB_TOKEN/GH_TOKEN         Token for private GitHub repositories. An existing gh auth login is also used.
  -h, --help                    Show this help.

Examples:
  ./$script_name --mode github --no-web-ui
  ./$script_name --mode github --version v1.2.31
  ./$script_name --mode github --interactive
  ./$script_name --mode github --python-components sdk,api
  MN_PYTHON=/opt/homebrew/bin/python3.11 ./$script_name --mode github
EOF
}

function set_python_components() {
    local value="$1"
    local component
    local -a components

    INSTALL_PYTHON_SDK="N"
    INSTALL_BLUEPRINT_SUPPORT_SKILL="N"
    INSTALL_CLI="N"
    INSTALL_API="N"

    IFS=',' read -r -a components <<< "$value"
    for component in "${components[@]}"; do
        component="$(echo "$component" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
        case "$component" in
            all)
                INSTALL_PYTHON_SDK="Y"
                INSTALL_BLUEPRINT_SUPPORT_SKILL="Y"
                INSTALL_CLI="Y"
                INSTALL_API="Y"
                ;;
            none)
                ;;
            sdk|python-sdk)
                INSTALL_PYTHON_SDK="Y"
                ;;
            skill|skills|blueprint-support|blueprint-support-skill)
                INSTALL_BLUEPRINT_SUPPORT_SKILL="Y"
                ;;
            cli)
                INSTALL_CLI="Y"
                ;;
            api)
                INSTALL_API="Y"
                ;;
            "")
                ;;
            *)
                print_error "Unknown Python component: $component"
                github_usage
                exit 1
                ;;
        esac
    done
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes|-y) NON_INTERACTIVE="Y" ;;
        --interactive) NON_INTERACTIVE="N" ;;
        --no-reinstall) REINSTALL="N" ;;
        --web-ui) INSTALL_WEB_UI="Y" ;;
        --no-web-ui) INSTALL_WEB_UI="N" ;;
        --redis) INSTALL_REDIS="Y" ;;
        --no-redis) INSTALL_REDIS="N" ;;
        --context-engine) INSTALL_CONTEXT_ENGINE="Y" ;;
        --no-context-engine) INSTALL_CONTEXT_ENGINE="N" ;;
        --openshell) INSTALL_OPENSHELL="Y" ;;
        --no-openshell) INSTALL_OPENSHELL="N" ;;
        --syncthing) MN_SYNCTHING_ENABLED="auto" ;;
        --no-syncthing) MN_SYNCTHING_ENABLED="0" ;;
        --start) START_NOW="Y" ;;
        --no-start) START_NOW="N" ;;
        --python-sdk) INSTALL_PYTHON_SDK="Y" ;;
        --no-python-sdk) INSTALL_PYTHON_SDK="N" ;;
        --skill|--skills) INSTALL_BLUEPRINT_SUPPORT_SKILL="Y" ;;
        --no-skill|--no-skills) INSTALL_BLUEPRINT_SUPPORT_SKILL="N" ;;
        --cli) INSTALL_CLI="Y" ;;
        --no-cli) INSTALL_CLI="N" ;;
        --api) INSTALL_API="Y" ;;
        --no-api) INSTALL_API="N" ;;
        --version)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--version requires a release tag such as v1.2.31."
                github_usage
                exit 1
            fi
            INSTALL_VERSION="$1"
            INSTALL_VERSION_EXPLICIT="Y"
            ;;
        --version=*) INSTALL_VERSION="${1#*=}"; INSTALL_VERSION_EXPLICIT="Y" ;;
        --skills-repo)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--skills-repo requires a value."
                github_usage
                exit 1
            fi
            SKILLS_REPO="$1"
            ;;
        --skills-repo=*) SKILLS_REPO="${1#*=}" ;;
        --skills-git-url)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--skills-git-url requires a value."
                github_usage
                exit 1
            fi
            MN_SKILLS_GIT_URL="$1"
            ;;
        --skills-git-url=*) MN_SKILLS_GIT_URL="${1#*=}" ;;
        --python-components)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--python-components requires a value."
                github_usage
                exit 1
            fi
            set_python_components "$1"
            ;;
        --python-components=*) set_python_components "${1#*=}" ;;
        --python)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--python requires a path."
                github_usage
                exit 1
            fi
            MN_PYTHON="$1"
            ;;
        --python=*) MN_PYTHON="${1#*=}" ;;
        --no-managed-python) MN_MANAGED_PYTHON=0 ;;
        -h|--help) github_usage; exit 0 ;;
        *)
            print_error "Unknown option: $1"
            github_usage
            exit 1
            ;;
    esac
    shift
done

function finalize_github_install_version() {
    if [ -n "$INSTALL_VERSION" ]; then
        mn_validate_version_tag_or_exit "$INSTALL_VERSION"
        MN_INSTALL_VERSION="$INSTALL_VERSION"
        CORE_RELEASE_TAG="$INSTALL_VERSION"
        MN_PACKAGE_VERSION="$(mn_package_version_from_tag "$INSTALL_VERSION")"
        RUNTIME_COMPOSE_TEMPLATE="${RUNTIME_COMPOSE_TEMPLATE:-${SCRIPT_DIR}/install_support/${INSTALL_VERSION}/docker-compose.yml}"
    else
        MN_INSTALL_VERSION=""
        CORE_RELEASE_TAG=""
        RUNTIME_COMPOSE_TEMPLATE="${RUNTIME_COMPOSE_TEMPLATE:-${SCRIPT_DIR}/docker-compose.yml}"
    fi
    export MN_INSTALL_VERSION
}

finalize_github_install_version

print_header

function github_ref_suffix() {
    if [ -n "$INSTALL_VERSION" ]; then
        printf '@%s' "$INSTALL_VERSION"
    fi
}

function github_clone() {
    local url="$1"
    local target="$2"

    if [ -n "$INSTALL_VERSION" ]; then
        git clone --branch "$INSTALL_VERSION" --depth 1 "$url" "$target"
    else
        git clone --depth 1 "$url" "$target"
    fi
}

function github_checkout_existing() {
    local default_branch

    if [ -n "$INSTALL_VERSION" ]; then
        git fetch --tags origin "$INSTALL_VERSION" >/dev/null 2>&1
        git checkout --force "$INSTALL_VERSION" >/dev/null 2>&1
        return 0
    fi

    default_branch="$(git remote show origin 2>/dev/null | awk -F': ' '/HEAD branch/ {print $2; exit}')"
    if [ -n "$default_branch" ]; then
        git fetch origin "$default_branch" >/dev/null 2>&1
        git checkout --force "$default_branch" >/dev/null 2>&1
        git pull --ff-only origin "$default_branch" >/dev/null 2>&1
    else
        git pull --ff-only >/dev/null 2>&1
    fi
}

function should_install_python_packages() {
    [ "$INSTALL_PYTHON_SDK" = "Y" ] || \
    [ "$INSTALL_BLUEPRINT_SUPPORT_SKILL" = "Y" ] || \
    [ "$INSTALL_CLI" = "Y" ] || \
    [ "$INSTALL_API" = "Y" ] || \
    [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]
}

function validate_selections() {
    if [ "$START_NOW" = "Y" ] && [ "$INSTALL_CLI" != "Y" ]; then
        print_warning "Automatic start requires the CLI package; disabling start."
        START_NOW="N"
    fi
    if [ "$INSTALL_WEB_UI" = "Y" ] && [ "$INSTALL_API" != "Y" ]; then
        print_warning "Installing Web UI without the API package. The UI will need an API service from another install."
    fi
}


function context_engine_git_url() {
    if [ -n "$MEMBRANE_GIT_URL" ]; then
        printf '%s' "$MEMBRANE_GIT_URL"
    else
        printf 'https://github.com/%s.git' "$MEMBRANE_REPO"
    fi
}

function core_git_url() {
    printf 'https://github.com/%s.git' "$CORE_REPO"
}

function blueprint_support_skill_git_url() {
    if [ -n "$MN_SKILLS_GIT_URL" ]; then
        printf '%s' "$MN_SKILLS_GIT_URL"
    else
        printf 'https://github.com/%s.git' "$SKILLS_REPO"
    fi
}

function agents_git_url() {
    if [ -n "$MN_AGENTS_GIT_URL" ]; then
        printf '%s' "$MN_AGENTS_GIT_URL"
    else
        printf 'https://github.com/%s.git' "$AGENTS_REPO"
    fi
}

function validate_agents_root() {
    local root="$1"
    if [ ! -f "${root}/index.json" ]; then
        print_error "mn-agents index was not found at ${root}/index.json."
        print_error "Set MN_AGENTS_ROOT to a valid mn-agents checkout or fix the catalog install."
        exit 1
    fi
}

function safe_agents_ref_path() {
    printf '%s' "$1" | tr '/: ' '___'
}

function resolve_agents_ref() {
    local default_branch
    if [ -n "${MN_AGENTS_REF:-}" ]; then
        printf '%s' "$MN_AGENTS_REF"
        return 0
    fi
    if [ -n "${INSTALL_VERSION:-}" ]; then
        printf '%s' "$INSTALL_VERSION"
        return 0
    fi
    default_branch="$(git ls-remote --symref "$(agents_git_url)" HEAD 2>/dev/null | sed -n 's#^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$#\1#p' | head -n 1)"
    if [ -z "$default_branch" ]; then
        print_error "Could not resolve the default branch for $(agents_git_url)."
        print_error "Set MN_AGENTS_REF explicitly and rerun."
        exit 1
    fi
    printf '%s' "$default_branch"
}

function ensure_agent_catalog_root() {
    local ref safe_ref root url
    if [ -n "${MN_AGENTS_ROOT:-}" ]; then
        validate_agents_root "$MN_AGENTS_ROOT"
        (cd "$MN_AGENTS_ROOT" && pwd)
        return 0
    fi

    ref="$(resolve_agents_ref)"
    safe_ref="$(safe_agents_ref_path "$ref")"
    root="${INSTALL_DIR}/agent-catalogs/mn-agents/${safe_ref}"
    url="$(agents_git_url)"
    mkdir -p "$(dirname "$root")"

    if [ -e "$root" ] && [ ! -d "${root}/.git" ]; then
        print_error "Expected cached mn-agents catalog to be a git checkout: ${root}"
        print_error "Move or remove that path, or set MN_AGENTS_ROOT to a valid catalog."
        exit 1
    fi

    if [ ! -d "${root}/.git" ]; then
        run_quiet "clone-mn-agents-${safe_ref}" git clone --branch "$ref" --depth 1 "$url" "$root"
    else
        (
            cd "$root"
            git remote set-url origin "$url" >/dev/null 2>&1 || true
            git fetch --tags origin "$ref" >/dev/null 2>&1
            git checkout --force "$ref" >/dev/null 2>&1
            if git show-ref --verify --quiet "refs/remotes/origin/${ref}"; then
                git pull --ff-only origin "$ref" >/dev/null 2>&1
            fi
        ) || {
            print_error "Could not update cached mn-agents catalog at ${root}."
            exit 1
        }
    fi

    validate_agents_root "$root"
    printf '%s\n' "$root"
}

function context_engine_source_dir() {
    if [ -z "${INSTALL_VERSION:-}" ] && [ -n "$SOURCE_WORKSPACE" ] && [ -f "$SOURCE_WORKSPACE/Membrane/Dockerfile" ]; then
        MEMBRANE_DIR="$(cd "$SOURCE_WORKSPACE/Membrane" && pwd)"
        printf '%s' "$SOURCE_WORKSPACE/Membrane"
        return 0
    fi
    if [ -z "${INSTALL_VERSION:-}" ] && [ -n "${MN_MEMBRANE_DIR:-}" ] && [ -f "$MN_MEMBRANE_DIR/Dockerfile" ]; then
        MEMBRANE_DIR="$(cd "$MN_MEMBRANE_DIR" && pwd)"
        printf '%s' "$MN_MEMBRANE_DIR"
        return 0
    fi
    if [ ! -d "$MEMBRANE_DIR" ]; then
        run_quiet "clone-membrane-context-engine" github_clone "$(context_engine_git_url)" "$MEMBRANE_DIR"
    else
        (
            cd "$MEMBRANE_DIR"
            github_checkout_existing
        )
    fi
    MEMBRANE_DIR="$(cd "$MEMBRANE_DIR" && pwd)"
    mn_remove_dockerfile_frontend_directive "$MEMBRANE_DIR/Dockerfile"
    printf '%s' "$MEMBRANE_DIR"
}

function setup_context_engine() {
    remove_stale_runtime_containers_for_services context-engine-model membrane-context-engine
    ensure_docker_model_runner
    runtime_compose pull membrane-context-engine
    runtime_compose up -d --no-build membrane-context-engine >/dev/null
}

function compose_profiles() {
    local profiles=()
    [ "$INSTALL_WEB_UI" = "Y" ] && profiles+=("web-ui")
    [ "$INSTALL_OPENSHELL" = "Y" ] && profiles+=("openshell")
    [ "$INSTALL_CONTEXT_ENGINE" = "Y" ] && profiles+=("context")
    case "$(printf '%s' "$MN_SYNCTHING_ENABLED" | tr '[:upper:]' '[:lower:]')" in
        ''|0|false|no|n|off|disabled) ;;
        *) profiles+=("syncthing") ;;
    esac
    if [ "${#profiles[@]}" -eq 0 ]; then
        printf ''
        return 0
    fi
    local IFS=,
    printf '%s' "${profiles[*]}"
}

function generate_openshell_jwt_keys() {
    local jwt_dir="$1"
    local gateway_image="${OPENSHELL_GATEWAY_IMAGE:-ghcr.io/nvidia/openshell/gateway:0.0.47}"
    local bootstrap_dir name

    bootstrap_dir="$(mktemp -d "${MN_HOST_OPENSHELL_STATE_DIR}/.jwt-bootstrap.XXXXXX")"
    if ! docker run --rm \
        --user "$OPENSHELL_GATEWAY_USER" \
        --env HOME=/tmp/openshell-bootstrap \
        --volume "${bootstrap_dir}:/bootstrap" \
        "$gateway_image" \
        generate-certs \
        --output-dir /bootstrap/output \
        --server-san host.openshell.internal >/dev/null; then
        print_error "Failed to create OpenShell sandbox JWT keys with ${gateway_image}."
        print_error "Check that Docker is running and can pull the OpenShell gateway image, then retry."
        rm -rf "$bootstrap_dir"
        exit 1
    fi

    for name in signing.pem public.pem kid; do
        if [ ! -s "${bootstrap_dir}/output/jwt/${name}" ]; then
            print_error "OpenShell certificate bootstrap did not create jwt/${name}."
            print_error "Check that ${gateway_image} supports the generate-certs command, then retry."
            rm -rf "$bootstrap_dir"
            exit 1
        fi
    done

    mv "${bootstrap_dir}/output/jwt/signing.pem" "${jwt_dir}/signing.pem"
    mv "${bootstrap_dir}/output/jwt/public.pem" "${jwt_dir}/public.pem"
    mv "${bootstrap_dir}/output/jwt/kid" "${jwt_dir}/kid"
    rm -rf "$bootstrap_dir"
    chmod 600 "${jwt_dir}/signing.pem" 2>/dev/null || true
    chmod 644 "${jwt_dir}/public.pem" "${jwt_dir}/kid" 2>/dev/null || true
}

function write_openshell_compose_config() {
    local gateway_dir="${MN_HOST_OPENSHELL_CONFIG_DIR}/gateways/openshell"
    local jwt_dir="${MN_HOST_OPENSHELL_STATE_DIR}/jwt"
    mkdir -p "$gateway_dir"
    mkdir -p "$jwt_dir"
    if [ ! -s "${jwt_dir}/signing.pem" ] || [ ! -s "${jwt_dir}/public.pem" ] || [ ! -s "${jwt_dir}/kid" ]; then
        generate_openshell_jwt_keys "$jwt_dir"
    fi
    printf 'openshell\n' > "${MN_HOST_OPENSHELL_CONFIG_DIR}/active_gateway"
    cat > "${gateway_dir}/metadata.json" <<EOF
{
  "name": "openshell",
  "gateway_endpoint": "http://openshell:${OPENSHELL_GATEWAY_PORT:-58080}",
  "is_remote": false,
  "gateway_port": ${OPENSHELL_GATEWAY_PORT:-58080}
}
EOF
    cat > "${MN_HOST_OPENSHELL_STATE_DIR}/gateway.toml" <<EOF
[openshell]
version = 1

[openshell.gateway]
bind_address = "0.0.0.0:${OPENSHELL_GATEWAY_PORT:-58080}"
log_level = "info"
compute_drivers = ["docker"]
sandbox_namespace = "mirror-neuron"
default_image = "ghcr.io/nvidia/openshell/sandbox:latest"
supervisor_image = "ghcr.io/nvidia/openshell/supervisor:latest"

[openshell.gateway.gateway_jwt]
signing_key_path = "${jwt_dir}/signing.pem"
public_key_path = "${jwt_dir}/public.pem"
kid_path = "${jwt_dir}/kid"
gateway_id = "openshell"
ttl_secs = 3600

[openshell.gateway.auth]
allow_unauthenticated_users = true

[openshell.drivers.docker]
default_image = "ghcr.io/nvidia/openshell/sandbox:latest"
image_pull_policy = "IfNotPresent"
sandbox_namespace = "mirror-neuron"
grpc_endpoint = "http://openshell:${OPENSHELL_GATEWAY_PORT:-58080}"
network_name = "${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
EOF
}

function install_openshell_cli() {
    if command -v openshell >/dev/null 2>&1; then
        return 0
    fi
    local installer="${TMPDIR:-/tmp}/mirror_neuron_openshell_install.sh"
    curl_github -fLsS https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh -o "$installer"
    OPENSHELL_VERSION="${OPENSHELL_VERSION:-v0.0.47}" sh "$installer" >/dev/null
    rm -f "$installer"
}

function generate_mn_secret() {
    local secret
    local python_fallback="${MN_PYTHON_BIN:-}"

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

    if [ -z "$python_fallback" ]; then
        python_fallback="$(command -v "python${MN_MANAGED_PYTHON_VERSION}" 2>/dev/null || true)"
    fi
    if [ -n "$python_fallback" ]; then
        if secret="$("$python_fallback" -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null)" && [ -n "$secret" ]; then
            printf '%s\n' "$secret"
            return 0
        fi
    fi

    return 1
}

function resolve_secret_file() {
    local env_value="$1"
    local file="$2"
    local label="$3"
    local value

    if [ -n "$env_value" ] && [ "$env_value" != "mirrorneuron" ]; then
        printf '%s\n' "$env_value" > "$file"
        chmod 600 "$file" 2>/dev/null || true
        printf '%s\n' "$env_value"
        return 0
    fi

    mkdir -p "$INSTALL_DIR"
    if [ -s "$file" ]; then
        value="$(tr -d '[:space:]' < "$file")"
        if [ -n "$value" ] && [ "$value" != "mirrorneuron" ]; then
            chmod 600 "$file" 2>/dev/null || true
            printf '%s\n' "$value"
            return 0
        fi
    fi

    if ! value="$(generate_mn_secret)"; then
        value=""
    fi
    if [ -z "$value" ]; then
        print_error "Failed to generate ${label}."
        exit 1
    fi
    printf '%s\n' "$value" > "$file"
    chmod 600 "$file" 2>/dev/null || true
    printf '%s\n' "$value"
}

function resolve_mn_cookie() {
    resolve_secret_file "${MN_COOKIE:-}" "${INSTALL_DIR}/erlang.cookie" "MN_COOKIE"
}

function resolve_network_token() {
    resolve_secret_file "${MN_NETWORK_JOIN_TOKEN:-}" "${INSTALL_DIR}/network.token" "MN_NETWORK_JOIN_TOKEN"
}

function derive_network_secret() {
    local token="$1"
    local label="$2"
    local material="mirror-neuron:${label}:${token}"
    local digest
    local python_fallback="${MN_PYTHON_BIN:-}"

    if command -v shasum >/dev/null 2>&1; then
        if digest="$(printf '%s' "$material" | shasum -a 256 2>/dev/null | awk '{print $1}')" && [ -n "$digest" ]; then
            printf '%s\n' "$digest"
            return 0
        fi
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        if digest="$(printf '%s' "$material" | sha256sum 2>/dev/null | awk '{print $1}')" && [ -n "$digest" ]; then
            printf '%s\n' "$digest"
            return 0
        fi
    fi

    if command -v openssl >/dev/null 2>&1; then
        if digest="$(printf '%s' "$material" | openssl dgst -sha256 -r 2>/dev/null | awk '{print $1}')" && [ -n "$digest" ]; then
            printf '%s\n' "$digest"
            return 0
        fi
    fi

    if [ -z "$python_fallback" ]; then
        python_fallback="$(command -v "python${MN_MANAGED_PYTHON_VERSION}" 2>/dev/null || true)"
    fi
    if [ -n "$python_fallback" ]; then
        if digest="$(printf '%s' "$material" | "$python_fallback" -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null)" && [ -n "$digest" ]; then
            printf '%s\n' "$digest"
            return 0
        fi
    fi

    print_error "Need shasum, sha256sum, a working openssl, or python${MN_MANAGED_PYTHON_VERSION} to derive Redis credentials."
    exit 1
}

function resolve_redis_password() {
    local admin_token="$1"
    local mn_env="${MN_ENV:-dev}"
    local password

    case "$mn_env" in
        prod|production)
            password="$(derive_network_secret "$admin_token" "redis")"
            mkdir -p "$INSTALL_DIR"
            printf '%s\n' "$password" > "${INSTALL_DIR}/redis.password"
            chmod 600 "${INSTALL_DIR}/redis.password" 2>/dev/null || true
            printf '%s\n' "$password"
            ;;
        *)
            printf '%s\n' "mirror_neuron_redis_dev"
            ;;
    esac
}

function read_env_value() {
    local file="$1"
    local key="$2"
    [ -f "$file" ] || return 0
    awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$file"
}

function redis_probe_host() {
    case "${1:-}" in
        ""|0.0.0.0|::|localhost) printf '127.0.0.1' ;;
        *) printf '%s' "$1" ;;
    esac
}

function redis_container_owns_port() {
    local port="$1"
    docker port mirror-neuron-redis 6379/tcp 2>/dev/null | awk -F: -v port="$port" '$NF == port {found=1} END {exit found ? 0 : 1}'
}

function redis_port_available() {
    local host="$1"
    local port="$2"
    local probe_host
    probe_host="$(redis_probe_host "$host")"

    if redis_container_owns_port "$port"; then
        return 0
    fi
    if (echo >"/dev/tcp/${probe_host}/${port}") >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

function resolve_redis_port() {
    local bind_host="$1"
    local persisted_port="$2"
    local candidate

    if [ -n "${MN_REDIS_PORT:-}" ]; then
        candidate="$MN_REDIS_PORT"
        if ! [[ "$candidate" =~ ^[0-9]+$ ]] || [ "$candidate" -lt 1 ] || [ "$candidate" -gt 65535 ]; then
            print_error "MN_REDIS_PORT must be a TCP port between 1 and 65535."
            exit 1
        fi
        if ! redis_port_available "$bind_host" "$candidate"; then
            print_error "Redis port ${candidate} is already in use."
            exit 1
        fi
        printf '%s\n' "$candidate"
        return 0
    fi

    if [[ "$persisted_port" =~ ^[0-9]+$ ]] &&
       [ "$persisted_port" -ge "$MN_DYNAMIC_REDIS_PORT_START" ] &&
       [ "$persisted_port" -le "$MN_DYNAMIC_REDIS_PORT_END" ] &&
       redis_port_available "$bind_host" "$persisted_port"; then
        printf '%s\n' "$persisted_port"
        return 0
    fi

    for candidate in $(seq "$MN_DYNAMIC_REDIS_PORT_START" "$MN_DYNAMIC_REDIS_PORT_END"); do
        if redis_port_available "$bind_host" "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    print_error "No Redis port is available in ${MN_DYNAMIC_REDIS_PORT_START}-${MN_DYNAMIC_REDIS_PORT_END}."
    exit 1
}

function resolve_docker_network_external() {
    local network_name="$1"
    local configured="${MN_DOCKER_NETWORK_EXTERNAL:-}"
    local labels compose_project compose_network

    if [ -n "$configured" ]; then
        printf '%s\n' "$configured"
        return 0
    fi

    if ! labels="$(docker network inspect -f '{{ index .Labels "com.docker.compose.project" }}|{{ index .Labels "com.docker.compose.network" }}' "$network_name" 2>/dev/null)"; then
        printf 'false\n'
        return 0
    fi

    compose_project="${labels%%|*}"
    compose_network="${labels#*|}"
    if [ "$compose_project" = "mirror-neuron" ] && [ "$compose_network" = "runtime" ]; then
        printf 'false\n'
    else
        print_warning "Docker network ${network_name} already exists outside this Compose project; reusing it as an external network."
        printf 'true\n'
    fi
}

function resolve_openshell_gateway_bind_host() {
    local network_name="$1"
    local docker_os gateway

    if [ -n "${OPENSHELL_GATEWAY_BIND_HOST:-}" ]; then
        printf '%s\n' "$OPENSHELL_GATEWAY_BIND_HOST"
        return 0
    fi

    docker_os="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
    if [ "$(uname -s)" = "Darwin" ] || [[ "$docker_os" == *"docker desktop"* ]]; then
        printf '127.0.0.1\n'
        return 0
    fi

    gateway="$(docker network inspect -f '{{ (index .IPAM.Config 0).Gateway }}' "$network_name" 2>/dev/null || true)"
    printf '%s\n' "${gateway:-127.0.0.1}"
}

function reconcile_openshell_gateway_bind_host() {
    local network_name="$1"
    local desired_bind_host desired_endpoint current_bind_host current_endpoint tmp_env
    desired_bind_host="$(resolve_openshell_gateway_bind_host "$network_name")"
    desired_endpoint="${OPENSHELL_GATEWAY_ENDPOINT:-http://${desired_bind_host}:${OPENSHELL_GATEWAY_PORT:-58080}}"
    current_bind_host="$(sed -n 's/^OPENSHELL_GATEWAY_BIND_HOST=//p' "$RUNTIME_COMPOSE_ENV" | tail -1)"
    current_endpoint="$(sed -n 's/^OPENSHELL_GATEWAY_ENDPOINT=//p' "$RUNTIME_COMPOSE_ENV" | tail -1)"
    if [ "$current_bind_host" = "$desired_bind_host" ] && [ "$current_endpoint" = "$desired_endpoint" ]; then
        return 0
    fi

    tmp_env="${RUNTIME_COMPOSE_ENV}.tmp"
    awk -v bind_host="$desired_bind_host" -v endpoint="$desired_endpoint" '
        BEGIN { replaced_bind_host = 0; replaced_endpoint = 0 }
        /^OPENSHELL_GATEWAY_BIND_HOST=/ {
            if (!replaced_bind_host) print "OPENSHELL_GATEWAY_BIND_HOST=" bind_host
            replaced_bind_host = 1
            next
        }
        /^OPENSHELL_GATEWAY_ENDPOINT=/ {
            if (!replaced_endpoint) print "OPENSHELL_GATEWAY_ENDPOINT=" endpoint
            replaced_endpoint = 1
            next
        }
        { print }
        END {
            if (!replaced_bind_host) print "OPENSHELL_GATEWAY_BIND_HOST=" bind_host
            if (!replaced_endpoint) print "OPENSHELL_GATEWAY_ENDPOINT=" endpoint
        }
    ' "$RUNTIME_COMPOSE_ENV" > "$tmp_env"
    mv "$tmp_env" "$RUNTIME_COMPOSE_ENV"
    chmod 600 "$RUNTIME_COMPOSE_ENV" 2>/dev/null || true
    if [ "$current_bind_host" != "$desired_bind_host" ]; then
        mn_run_runtime_compose up -d --force-recreate openshell
    fi
}

function wait_for_openshell_worker_service() {
    local network_name="${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
    local gateway_endpoint="http://openshell:${OPENSHELL_GATEWAY_PORT:-58080}"
    local attempt=1
    local max_attempts=60
    local readiness_announced="N"

    while [ "$attempt" -le "$max_attempts" ]; do
        if docker run --rm \
            --network "$network_name" \
            --entrypoint openshell \
            mirror-neuron-core:latest \
            --gateway-endpoint "$gateway_endpoint" \
            sandbox list >/dev/null 2>&1; then
            if [ "$readiness_announced" = "Y" ]; then
                print_success "OpenShell gateway is ready."
            fi
            return 0
        fi
        if [ "$readiness_announced" != "Y" ]; then
            print_step "Waiting for OpenShell gateway to become ready"
            readiness_announced="Y"
        fi
        sleep 1
        attempt=$((attempt + 1))
    done

    print_error "OpenShell worker service did not become ready at ${gateway_endpoint} after ${max_attempts} seconds."
    print_error "Next: docker logs openshell-cluster-openshell"
    return 1
}

function ensure_runtime_host_directory() {
    local path="$1"
    local description="$2"
    local override_name="$3"

    if [ -e "$path" ] || [ -L "$path" ]; then
        if [ ! -d "$path" ]; then
            print_error "Expected ${description} to be a directory: ${path}"
            print_error "Move or remove that path, or set ${override_name} to a directory."
            exit 1
        fi
        chmod u+rwx "$path" 2>/dev/null || true
        if [ ! -w "$path" ]; then
            print_error "Expected ${description} to be writable: ${path}"
            print_error "Repair ownership or set ${override_name} to a writable directory."
            exit 1
        fi
        return 0
    fi

    mkdir -p "$path"
    chmod u+rwx "$path" 2>/dev/null || true
}

function prepare_litellm_gateway_config() {
    local gateway_dir="${MN_HOST_HOME_DIR}/models/litellm-gateway"
    mkdir -p "$gateway_dir"
    if [ ! -e "${gateway_dir}/config.yaml" ]; then
        printf '{"model_list":[]}\n' > "${gateway_dir}/config.yaml"
    fi
    chmod u+rwX "$gateway_dir" "${gateway_dir}/config.yaml" 2>/dev/null || true
}

function write_runtime_compose_files() {
    local model_runner_model profiles network_name network_external network_token redis_password mn_cookie runtime_skills_root runtime_agents_root runtime_package_index context_memory_enabled otterdesk_context_memory_enabled membrane_engine_tag membrane_engine_image litellm_gateway_bind_host openshell_gateway_bind_host openshell_gateway_endpoint api_host
    model_runner_model="${MN_CONTEXT_MODEL_RUNNER_MODEL:-hf.co/homerquan/mn-context-engine-model-v-Q4_K_M}"
    profiles="$(compose_profiles)"
    api_host="${MN_API_HOST:-}"
    if [ -z "$api_host" ]; then
        if [ "$INSTALL_WEB_UI" = "Y" ]; then
            api_host="0.0.0.0"
        else
            api_host="localhost"
        fi
    fi
    litellm_gateway_bind_host="${MN_LITELLM_GATEWAY_BIND_HOST:-0.0.0.0}"
    network_name="${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
    openshell_gateway_bind_host="$(resolve_openshell_gateway_bind_host "$network_name")"
    openshell_gateway_endpoint="${OPENSHELL_GATEWAY_ENDPOINT:-http://${openshell_gateway_bind_host}:${OPENSHELL_GATEWAY_PORT:-58080}}"
    network_external="$(resolve_docker_network_external "$network_name")"
    network_token="$(resolve_network_token)"
    redis_password="$(resolve_redis_password "mirror_neuron_password_admin")"
    mn_cookie="$(resolve_mn_cookie)"
    printf '%s\n' "mirror_neuron_password" > "${INSTALL_DIR}/grpc_auth.token"
    printf '%s\n' "mirror_neuron_password_admin" > "${INSTALL_DIR}/grpc_admin.token"
    chmod 600 "${INSTALL_DIR}/grpc_auth.token" "${INSTALL_DIR}/grpc_admin.token" 2>/dev/null || true
    runtime_skills_root="${MN_SKILLS_ROOT:-${MN_HOST_HOME_DIR}/skills}"
    runtime_agents_root="$(ensure_agent_catalog_root)"
    runtime_package_index="${MN_PACKAGE_INDEX_FILE:-}"
    membrane_engine_tag="${MN_MEMBRANE_ENGINE_IMAGE_TAG:-${INSTALL_VERSION:-v${MN_PACKAGE_VERSION:-1.2.31}}}"
    if [[ "$membrane_engine_tag" != v* ]]; then
        membrane_engine_tag="v${membrane_engine_tag}"
    fi
    membrane_engine_image="${MN_MEMBRANE_ENGINE_IMAGE:-${MN_CONTEXT_ENGINE_IMAGE:-us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/membrane-context-engine:${membrane_engine_tag}}}"
    context_memory_enabled="${MN_CONTEXT_MEMORY_ENABLED:-1}"
    otterdesk_context_memory_enabled="${OTTERDESK_CONTEXT_MEMORY_ENABLED:-$context_memory_enabled}"
    if [ -n "${PACKAGE_INDEX_FILE:-}" ] && [ -f "$PACKAGE_INDEX_FILE" ]; then
        runtime_package_index="${INSTALL_DIR}/package-index/python-packages.toml"
        mkdir -p "$(dirname "$runtime_package_index")"
        cp "$PACKAGE_INDEX_FILE" "$runtime_package_index"
    fi

    mkdir -p "$INSTALL_DIR"
    ensure_runtime_host_directory "$MN_HOST_HOME_DIR" "MirrorNeuron home mount" "MN_HOST_HOME_DIR"
    ensure_runtime_host_directory "$runtime_skills_root" "MirrorNeuron runtime modules root" "MN_SKILLS_ROOT"
    ensure_runtime_host_directory "$MN_HOST_ARTIFACTS_DIR" "run artifacts host mount" "MN_HOST_ARTIFACTS_DIR"
    ensure_runtime_host_directory "$MN_HOST_BLOB_STORE_DIR" "blob store host mount" "MN_HOST_BLOB_STORE_DIR"
    ensure_runtime_host_directory "$MN_HOST_SHARED_STORAGE_ROOT" "shared storage host mount" "MN_HOST_SHARED_STORAGE_ROOT"
    ensure_runtime_host_directory "$MN_HOST_OPENSHELL_CONFIG_DIR" "OpenShell config host mount" "MN_HOST_OPENSHELL_CONFIG_DIR"
    ensure_runtime_host_directory "$MN_HOST_OPENSHELL_STATE_DIR" "OpenShell state host mount" "MN_HOST_OPENSHELL_STATE_DIR"
    prepare_litellm_gateway_config
    mn_write_runtime_compose_file "$RUNTIME_COMPOSE_TEMPLATE" "$RUNTIME_COMPOSE_FILE"
    if [ "$INSTALL_OPENSHELL" = "Y" ]; then
        write_openshell_compose_config
    fi
    cat > "$RUNTIME_COMPOSE_ENV" <<EOF
COMPOSE_PROJECT_NAME=mirror-neuron
COMPOSE_PROFILES=${profiles}
MN_HOST_STATE_DIR=${INSTALL_DIR}
MN_HOST_HOME_DIR=${MN_HOST_HOME_DIR}
MN_HOST_ARTIFACTS_DIR=${MN_HOST_ARTIFACTS_DIR}
MN_HOST_BLOB_STORE_DIR=${MN_HOST_BLOB_STORE_DIR}
MN_HOST_SHARED_STORAGE_ROOT=${MN_HOST_SHARED_STORAGE_ROOT}
MN_SYNCTHING_ENABLED=${MN_SYNCTHING_ENABLED}
MN_SYNCTHING_IMAGE=${MN_SYNCTHING_IMAGE}
MN_SYNCTHING_GUI_PORT=${MN_SYNCTHING_GUI_PORT}
MN_SYNCTHING_SYNC_PORT=${MN_SYNCTHING_SYNC_PORT}
MN_SYNCTHING_RESCAN_INTERVAL_SECONDS=${MN_SYNCTHING_RESCAN_INTERVAL_SECONDS}
MN_BLUEPRINT_PYTHON_ENVS_DIR=${MN_BLUEPRINT_PYTHON_ENVS_DIR}
MN_HOST_OPENSHELL_CONFIG_DIR=${MN_HOST_OPENSHELL_CONFIG_DIR}
MN_HOST_OPENSHELL_STATE_DIR=${MN_HOST_OPENSHELL_STATE_DIR}
MN_MEMBRANE_SOURCE_MODE=${MN_MEMBRANE_SOURCE_MODE:-image}
ENGINE_IMAGE=${membrane_engine_image}
MN_MEMBRANE_ENGINE_IMAGE=${membrane_engine_image}
MN_MEMBRANE_ENGINE_IMAGE_TAG=${membrane_engine_tag}
MN_REDIS_IMAGE=${MN_REDIS_IMAGE:-redis:8}
MN_CONTEXT_MODEL_RUNNER_MODEL=${model_runner_model}
MN_LLM_MODEL_RUNNER_MODEL=${MN_LLM_MODEL_RUNNER_MODEL:-gemma4:e2b}
MN_GRPC_BIND_HOST=${MN_GRPC_BIND_HOST:-127.0.0.1}
MN_GRPC_PORT=${MN_GRPC_PORT:-55051}
MN_GRPC_TARGET=${MN_GRPC_TARGET:-localhost:${MN_GRPC_PORT:-55051}}
MN_GRPC_ADVERTISE_PORT=${MN_GRPC_ADVERTISE_PORT:-${MN_GRPC_PORT:-55051}}
MN_NATIVE_SDK_GRPC_HOST=${MN_NATIVE_SDK_GRPC_HOST:-0.0.0.0}
MN_NATIVE_SDK_GRPC_PORT=${MN_NATIVE_SDK_GRPC_PORT:-55052}
MN_NATIVE_SDK_GRPC_ADVERTISE_HOST=${MN_NATIVE_SDK_GRPC_ADVERTISE_HOST:-${MN_NETWORK_ADVERTISE_HOST:-}}
MN_NATIVE_SDK_GRPC_ADVERTISE_PORT=${MN_NATIVE_SDK_GRPC_ADVERTISE_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_NATIVE_SDK_GRPC_TARGET=${MN_NATIVE_SDK_GRPC_TARGET:-mn-native-sdk-grpc:55052}
MN_NATIVE_SDK_GRPC_PROXY_PORT=${MN_NATIVE_SDK_GRPC_PROXY_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_NATIVE_SDK_GRPC_PROXY_TARGET_HOST=${MN_NATIVE_SDK_GRPC_PROXY_TARGET_HOST:-host.docker.internal}
MN_NATIVE_SDK_GRPC_PROXY_TARGET_PORT=${MN_NATIVE_SDK_GRPC_PROXY_TARGET_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_LITELLM_GATEWAY_BIND_HOST=${litellm_gateway_bind_host}
MN_LITELLM_GATEWAY_PORT=${MN_LITELLM_GATEWAY_PORT:-4000}
MN_LITELLM_GATEWAY_INTERNAL_API_BASE=${MN_LITELLM_GATEWAY_INTERNAL_API_BASE:-http://mn-litellm-proxy:4000/v1}
MN_API_HOST=${api_host}
MN_API_PORT=${MN_API_PORT:-54001}
MN_DIST_PORT=${MN_DIST_PORT:-54370}
MN_WEB_UI_HOST=${MN_WEB_UI_HOST:-localhost}
MN_WEB_UI_PORT=${MN_WEB_UI_PORT:-55173}
MN_WEB_UI_BIND_HOST=${MN_WEB_UI_BIND_HOST:-127.0.0.1}
MN_WEB_UI_IMAGE=${MN_WEB_UI_IMAGE:-node:22-alpine}
MN_WEB_UI_SOURCE_MODE=${MN_WEB_UI_SOURCE_MODE}
MN_WEB_UI_SOURCE_MOUNT=${MN_WEB_UI_SOURCE_MOUNT}
MN_WEB_UI_PACKAGE_VERSION=${MN_WEB_UI_PACKAGE_VERSION}
MN_WEB_UI_API_HOST=${MN_WEB_UI_API_HOST:-host.docker.internal}
MN_BLUEPRINT_WEB_UI_BIND_HOST=${MN_BLUEPRINT_WEB_UI_BIND_HOST:-0.0.0.0}
MN_BLUEPRINT_WEB_UI_PUBLIC_HOST=${MN_BLUEPRINT_WEB_UI_PUBLIC_HOST:-localhost}
MN_BLUEPRINT_WEB_UI_PORT_START=${MN_BLUEPRINT_WEB_UI_PORT_START:-61000}
MN_BLUEPRINT_WEB_UI_PORT_END=${MN_BLUEPRINT_WEB_UI_PORT_END:-61049}
MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE=${MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE:-prepublished}
MN_ENV=${MN_ENV:-dev}
MN_BLUEPRINT_SOURCE=${MN_BLUEPRINT_SOURCE:-github}
MN_BLUEPRINT_REPO=${MN_BLUEPRINT_REPO:-https://github.com/MirrorNeuronLab/mn-blueprints.git}
MN_BLUEPRINT_LOCAL=${MN_BLUEPRINT_LOCAL:-}
MN_WORKSPACE_ROOT=${MN_WORKSPACE_ROOT:-}
MN_AGENTS_ROOT=${runtime_agents_root}
MN_SKILLS_ROOT=${runtime_skills_root}
MN_PACKAGE_INDEX_FILE=${runtime_package_index}
MN_PIP_INDEX_URL=${MN_PIP_INDEX_URL:-${MN_PYTHON_INDEX_URL:-${MN_DEFAULT_PIP_INDEX_URL:-https://us-central1-python.pkg.dev/mirrorneuron-public-packages/agent-skills/simple/}}}
MN_PIP_EXTRA_INDEX_URL=${MN_PIP_EXTRA_INDEX_URL:-${MN_PYTHON_EXTRA_INDEX_URL:-https://pypi.org/simple}}
MN_RUNTIME_MODULE_VERSION=${MN_RUNTIME_MODULE_VERSION:-${MN_PACKAGE_VERSION:-}}
MN_CONTEXT_MEMORY_ENABLED=${context_memory_enabled}
OTTERDESK_CONTEXT_MEMORY_ENABLED=${otterdesk_context_memory_enabled}
MN_RUNS_ROOT=${MN_RUNS_ROOT:-}
MN_DOCKER_NETWORK_MODE=${MN_DOCKER_NETWORK_MODE:-bridge}
MN_DOCKER_NETWORK_NAME=${network_name}
MN_DOCKER_NETWORK_EXTERNAL=${network_external}
MN_DOCKER_NETWORK_DRIVER=${MN_DOCKER_NETWORK_DRIVER:-bridge}
MN_DOCKER_NETWORK_ATTACHABLE=${MN_DOCKER_NETWORK_ATTACHABLE:-false}
MN_DOCKER_WORKER_ENABLED=${MN_DOCKER_WORKER_ENABLED:-1}
MN_NODE_ALIAS=${MN_NODE_ALIAS:-}
MN_NODE_NAME=${MN_NODE_NAME:-}
MN_NODE_ROLE=${MN_NODE_ROLE:-runtime}
MN_CLUSTER_NODES=${MN_CLUSTER_NODES:-}
MN_NETWORK_JOIN_TOKEN=${network_token}
MN_REDIS_PASSWORD=${redis_password}
MN_REDIS_URL=${MN_REDIS_URL:-redis://:${redis_password}@redis:6379/0}
MN_CONTEXT_REDIS_URL=${MN_CONTEXT_REDIS_URL:-redis://:${redis_password}@redis:6379/1}
MN_REDIS_HA_MODE=${MN_REDIS_HA_MODE:-single}
MN_REDIS_SENTINELS=${MN_REDIS_SENTINELS:-}
MN_REDIS_SENTINEL_MASTER=${MN_REDIS_SENTINEL_MASTER:-mirror-neuron}
MN_REDIS_SENTINEL_HOST_MAP=${MN_REDIS_SENTINEL_HOST_MAP:-}
MN_REDIS_DB=${MN_REDIS_DB:-0}
MN_REDIS_USERNAME=${MN_REDIS_USERNAME:-}
MN_REDIS_SENTINEL_USERNAME=${MN_REDIS_SENTINEL_USERNAME:-}
MN_REDIS_SENTINEL_PASSWORD=${MN_REDIS_SENTINEL_PASSWORD:-${redis_password}}
MN_REDIS_WAIT_REPLICAS=${MN_REDIS_WAIT_REPLICAS:-0}
MN_REDIS_WAIT_TIMEOUT_MS=${MN_REDIS_WAIT_TIMEOUT_MS:-100}
MN_REDIS_RECONNECT_ATTEMPTS=${MN_REDIS_RECONNECT_ATTEMPTS:-10}
MN_REDIS_RECONNECT_BACKOFF_MS=${MN_REDIS_RECONNECT_BACKOFF_MS:-250}
MN_REDIS_RECONNECT_MAX_BACKOFF_MS=${MN_REDIS_RECONNECT_MAX_BACKOFF_MS:-2000}
ERL_EPMD_ADDRESS=${ERL_EPMD_ADDRESS:-0.0.0.0}
ERL_AFLAGS=${ERL_AFLAGS:--kernel inet_dist_listen_min ${MN_DIST_PORT:-54370} inet_dist_listen_max ${MN_DIST_PORT:-54370}}
OPENSHELL_GATEWAY_PORT=${OPENSHELL_GATEWAY_PORT:-58080}
OPENSHELL_GATEWAY_ENDPOINT=${openshell_gateway_endpoint}
OPENSHELL_GATEWAY_BIND_HOST=${openshell_gateway_bind_host}
OPENSHELL_GATEWAY_USER=${OPENSHELL_GATEWAY_USER}
OPENSHELL_GATEWAY_DOCKER_GROUP=${OPENSHELL_GATEWAY_DOCKER_GROUP}
DOCKER_HOST_SOCKET=${DOCKER_HOST_SOCKET}
COMPOSE_PARALLEL_LIMIT=${COMPOSE_PARALLEL_LIMIT:-1}
MN_COOKIE=${mn_cookie}
MN_GRPC_AUTH_TOKEN=mirror_neuron_password
MN_GRPC_ADMIN_TOKEN=mirror_neuron_password_admin
EOF
    chmod 600 "$RUNTIME_COMPOSE_ENV" 2>/dev/null || true
}

function runtime_compose() {
    local status
    if command -v docker-compose >/dev/null 2>&1; then
        if COMPOSE_PARALLEL_LIMIT="${COMPOSE_PARALLEL_LIMIT:-1}" docker-compose --env-file "$RUNTIME_COMPOSE_ENV" -f "$RUNTIME_COMPOSE_FILE" "$@"; then
            return 0
        else
            status=$?
        fi
    else
        if COMPOSE_PARALLEL_LIMIT="${COMPOSE_PARALLEL_LIMIT:-1}" docker compose --env-file "$RUNTIME_COMPOSE_ENV" -f "$RUNTIME_COMPOSE_FILE" "$@"; then
            return 0
        else
            status=$?
        fi
    fi
    mn_report_docker_daemon_failure
    return "$status"
}

function runtime_container_name_for_service() {
    case "$1" in
        redis) echo "mirror-neuron-redis" ;;
        web-ui) echo "mirror-neuron-web-ui" ;;
        openshell) echo "openshell-cluster-openshell" ;;
        context-engine-model) echo "mirror-neuron-context-engine-model" ;;
        membrane-context-engine) echo "mirror-neuron-context-engine" ;;
        mirror-neuron-core) echo "mirror-neuron-core" ;;
        *) return 1 ;;
    esac
}

function remove_stale_runtime_container() {
    local name="$1"
    local project

    if ! docker container inspect "$name" >/dev/null 2>&1; then
        return 0
    fi

    project="$(docker container inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$name" 2>/dev/null || true)"
    if [ "$project" = "mirror-neuron" ]; then
        return 0
    fi

    docker rm -f "$name" >/dev/null 2>&1 || true
}

function remove_stale_runtime_containers_for_services() {
    local service name
    for service in "$@"; do
        name="$(runtime_container_name_for_service "$service" || true)"
        [ -n "$name" ] && remove_stale_runtime_container "$name"
    done
    return 0
}

function ensure_docker_model_runner() {
    local linux_nvidia="N"
    if mn_is_linux_nvidia_host; then
        linux_nvidia="Y"
    fi

    if [ "$linux_nvidia" != "Y" ] && [ "$INSTALL_CONTEXT_ENGINE" != "Y" ] && [ "${INSTALL_DOCKER_MODEL_RUNNER:-N}" != "Y" ] && [ "${MN_ENABLE_DOCKER_MODEL_RUNNER:-N}" != "Y" ]; then
        return 0
    fi

    mn_prepare_docker_model_runner_cli
    if ! docker model --help >/dev/null 2>&1; then
        print_error "Docker Model Runner CLI is not available."
        mn_print_docker_model_runner_install_hint
        exit 1
    fi

    if [ "$linux_nvidia" = "Y" ]; then
        mn_ensure_nvidia_llamacpp_runner
        return 0
    else
        if docker model status >/dev/null 2>&1; then
            return 0
        fi

        if mn_is_docker_desktop_host; then
            print_warning "Docker Model Runner is not running after the Docker Desktop enable command."
        else
            print_warning "Docker Model Runner is not running; attempting to install and start it."
        fi

        if docker model install-runner --help >/dev/null 2>&1; then
            docker model install-runner >/dev/null 2>&1 || true
            docker model start-runner >/dev/null 2>&1 || true
            if docker model status >/dev/null 2>&1; then
                return 0
            fi
        fi
    fi

    print_error "Docker Model Runner is not ready."
    mn_print_docker_model_runner_install_hint
    exit 1
}

function prepare_runtime_compose_sidecars() {
    RUNTIME_COMPOSE_SIDECARS=()
    [ "$INSTALL_REDIS" = "Y" ] && RUNTIME_COMPOSE_SIDECARS+=("redis")
    [ "$INSTALL_WEB_UI" = "Y" ] && RUNTIME_COMPOSE_SIDECARS+=("web-ui")
    grep -q '^  mn-native-sdk-grpc:' "$RUNTIME_COMPOSE_FILE" 2>/dev/null && RUNTIME_COMPOSE_SIDECARS+=("mn-native-sdk-grpc")
    grep -q '^  mn-litellm-proxy:' "$RUNTIME_COMPOSE_FILE" 2>/dev/null && RUNTIME_COMPOSE_SIDECARS+=("mn-litellm-proxy")
    [ "$INSTALL_OPENSHELL" = "Y" ] && RUNTIME_COMPOSE_SIDECARS+=("openshell")
    if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
        RUNTIME_COMPOSE_SIDECARS+=("membrane-context-engine")
    fi
    if mn_is_linux_nvidia_host; then
        ensure_docker_model_runner
    fi
    if [ "${#RUNTIME_COMPOSE_SIDECARS[@]}" -gt 0 ]; then
        remove_stale_runtime_containers_for_services context-engine-model "${RUNTIME_COMPOSE_SIDECARS[@]}"
        ensure_docker_model_runner
        if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
            mn_run_runtime_compose pull membrane-context-engine
        fi
    fi
}

function start_runtime_compose_sidecars() {
    prepare_runtime_compose_sidecars
    if [ "${#RUNTIME_COMPOSE_SIDECARS[@]}" -gt 0 ]; then
        mn_run_runtime_compose up -d --no-build "${RUNTIME_COMPOSE_SIDECARS[@]}"
    fi
    if [ "$INSTALL_OPENSHELL" = "Y" ]; then
        reconcile_openshell_gateway_bind_host "${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
        wait_for_openshell_worker_service
    fi
}

print_step "Checking Python runtime"
resolve_python_runtime

EXISTING_INSTALL="N"
if [ -d "$INSTALL_DIR" ] || [ -f "$BIN_DIR/mn" ]; then
    if [ "$MN_INSTALL_RESET" != "Y" ]; then
        print_warning "MirrorNeuron appears to be already installed."
    fi
    if [ "$MN_INSTALL_RESET" = "Y" ]; then
        REINSTALL="Y"
    elif [ "$NON_INTERACTIVE" != "Y" ]; then
        REINSTALL=$(ask "Do you want to reinstall (overwrite old ones)?" "$REINSTALL")
    fi
    if [ "$REINSTALL" = "N" ]; then
        print_warning "Installation cancelled."
        exit 0
    fi
    echo "" >&3
    EXISTING_INSTALL="Y"
fi

# Interactive Prompts
if [ "$NON_INTERACTIVE" != "Y" ]; then
    INSTALL_WEB_UI=$(ask "Do you want to install the Web UI?" "$INSTALL_WEB_UI")
    INSTALL_REDIS=$(ask "Do you want to install Redis via Docker?" "$INSTALL_REDIS")
    INSTALL_CONTEXT_ENGINE=$(ask "Do you want to install/start the Membrane context engine?" "$INSTALL_CONTEXT_ENGINE")
    INSTALL_OPENSHELL=$(ask "Do you want to install/start the OpenShell gateway for sandbox workers?" "$INSTALL_OPENSHELL")
    START_NOW=$(ask "Do you want to start the MirrorNeuron server automatically after install?" "$START_NOW")
fi
validate_selections
echo "" >&3

print_step "Checking Dependencies"

require_cmd git
require_cmd curl
require_cmd docker
configure_github_git_auth
if should_install_python_packages; then
    resolve_python_runtime
fi

if ! docker info >/dev/null 2>&1; then
    print_error "Docker is not running. Please start Docker first."
    exit 1
fi

print_success "All dependencies found or installed."

if [ "$EXISTING_INSTALL" = "Y" ]; then
    print_step "Preparing fresh install"
    mn_remove_existing_install_paths
fi

print_step "Installing MirrorNeuron Core (Docker)"

(
    github_clone "$(core_git_url)" "$INSTALL_DIR" >/dev/null 2>&1
    cd "$INSTALL_DIR"
    
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

EXPOSE 55051

# Set the default command
CMD ["mix", "run", "--no-halt"]
EOF
    fi

    DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-1}" mn_run_docker_build -t mirror-neuron-core . >/dev/null 2>&1
) &
spinner $! "Cloning and building Core (Docker image mirror-neuron-core)"
write_runtime_compose_files

if should_install_python_packages; then
    print_step "Installing selected Python components from GitHub"
    (
        "$MN_PYTHON_BIN" -m venv "$VENV_DIR" >/dev/null 2>&1
        run_quiet "pip-upgrade" "$VENV_DIR/bin/pip" install --upgrade pip
        if [ "$INSTALL_PYTHON_SDK" = "Y" ]; then
            run_quiet "install-mn-python-sdk-github" "$VENV_DIR/bin/pip" install "git+https://github.com/MirrorNeuronLab/mn-python-sdk.git$(github_ref_suffix)"
        fi
        if [ "$INSTALL_BLUEPRINT_SUPPORT_SKILL" = "Y" ]; then
            run_quiet "install-blueprint-support-skill-github" "$VENV_DIR/bin/pip" install "mirrorneuron-blueprint-support-skill[webui] @ git+$(blueprint_support_skill_git_url)$(github_ref_suffix)#subdirectory=blueprint_support_skill"
        fi
        if [ "$INSTALL_CLI" = "Y" ]; then
            run_quiet "install-mn-cli-github" "$VENV_DIR/bin/pip" install "git+https://github.com/MirrorNeuronLab/mn-cli.git$(github_ref_suffix)"
        fi
        if [ "$INSTALL_API" = "Y" ]; then
            run_quiet "install-mn-api-github" "$VENV_DIR/bin/pip" install "git+https://github.com/MirrorNeuronLab/mn-api.git$(github_ref_suffix)"
        fi
        if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
            run_quiet "install-membrane-python-sdk-github" "$VENV_DIR/bin/pip" install "mirrorneuron-membrane-python-sdk @ git+$(context_engine_git_url)$(github_ref_suffix)#subdirectory=mn-context-engine-python-sdk"
        fi
    ) &
    spinner $! "Setting up virtualenv and installing Python packages"
else
    print_warning "Skipping Python component installation."
fi

function require_github_command_targets() {
    local missing="N"
    if [ "$INSTALL_CLI" = "Y" ] && [ ! -x "$VENV_DIR/bin/mn" ]; then
        print_error "Expected executable mn CLI target was not created: $VENV_DIR/bin/mn"
        missing="Y"
    fi
    if [ "$INSTALL_API" = "Y" ] && [ ! -x "$VENV_DIR/bin/mn-api" ]; then
        print_error "Expected executable mn-api target was not created: $VENV_DIR/bin/mn-api"
        missing="Y"
    fi
    if [ "$missing" = "Y" ]; then
        print_error "GitHub Python install did not produce the required command targets; command symlinks were not created."
        exit 1
    fi
}

if [ "$INSTALL_WEB_UI" = "Y" ]; then
    print_step "Preparing Web UI source for Docker Compose"
    if [ -z "${INSTALL_VERSION:-}" ] && [ -n "$SOURCE_WORKSPACE" ] && [ -d "$SOURCE_WORKSPACE/mn-web-ui" ]; then
        print_detail "Using local Web UI source: $SOURCE_WORKSPACE/mn-web-ui"
    fi
    (
        UI_DIR="${INSTALL_DIR}/webui"
        if [ -z "${INSTALL_VERSION:-}" ] && [ -n "$SOURCE_WORKSPACE" ] && [ -d "$SOURCE_WORKSPACE/mn-web-ui" ]; then
            rm -rf "$UI_DIR"
            ln -s "$SOURCE_WORKSPACE/mn-web-ui" "$UI_DIR"
        elif [ -d "$UI_DIR" ]; then
            cd "$UI_DIR"
            github_checkout_existing
        else
            run_quiet "web-ui-git-clone" github_clone https://github.com/MirrorNeuronLab/mn-web-ui.git "$UI_DIR"
        fi
    ) &
    spinner $! "Preparing Web UI source"
fi

if [ "$INSTALL_REDIS" = "Y" ] || [ "$INSTALL_CONTEXT_ENGINE" = "Y" ] || [ "$INSTALL_OPENSHELL" = "Y" ] || [ "$INSTALL_WEB_UI" = "Y" ]; then
    if [ "$INSTALL_OPENSHELL" = "Y" ]; then
        install_openshell_cli
    fi
    if [ "$START_NOW" = "Y" ]; then
        prepare_runtime_compose_sidecars
        print_detail "Docker services are prepared; automatic startup is deferred to mn runtime start."
    else
        print_step "Starting selected Docker runtime services"
        ( start_runtime_compose_sidecars ) &
        spinner $! "Selected Docker runtime services are available"
    fi
fi

if [ "$INSTALL_CLI" = "Y" ] || [ "$INSTALL_API" = "Y" ]; then
    print_step "Creating command symlinks"
    require_github_command_targets
    mkdir -p "$BIN_DIR" "$INSTALL_DIR"
    if [ "$INSTALL_CLI" = "Y" ]; then
        rm -f "$BIN_DIR/mn" "$INSTALL_DIR/mn"
        ln -s "$VENV_DIR/bin/mn" "$BIN_DIR/mn"
        ln -s "$VENV_DIR/bin/mn" "$INSTALL_DIR/mn"
    fi
    if [ "$INSTALL_API" = "Y" ]; then
        rm -f "$BIN_DIR/mn-api"
        ln -s "$VENV_DIR/bin/mn-api" "$BIN_DIR/mn-api"
    fi
    print_detail "Command links: ${BIN_DIR}"
else
    print_warning "Skipping command symlink creation because CLI/API installation is disabled."
fi

echo "" >&3
print_success "MirrorNeuron installation completed."
if [ "$INSTALL_CLI" = "Y" ]; then
    print_detail "CLI: mn"
fi
if [ "$INSTALL_API" = "Y" ]; then
    print_detail "API: mn-api"
fi
if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
    print_detail "Membrane endpoint: ${MN_CONTEXT_ADDR:-localhost:50052}"
fi

function shell_escape_value() {
    printf '%q' "$1"
}

function profile_has_bin_path() {
    local profile="$1"
    [ -f "$profile" ] || return 1
    local line
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" == *'PATH'* && "$line" == *'$MN_HOME/bin'* ]]; then
            return 0
        fi
    done < "$profile"
    return 1
}

function profile_has_runtime_home() {
    local profile="$1"
    [ -f "$profile" ] || return 1
    local line
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?MN_HOME= ]]; then
            return 0
        fi
    done < "$profile"
    return 1
}

function ensure_shell_profile_exports() {
    local needs_path="N"
    local needs_runtime_home="Y"
    local default_home="${HOME}/.mn"
    local shell_profile
    local profile_updated="N"

    [[ ":$PATH:" != *":$BIN_DIR:"* ]] && needs_path="Y"

    if [ "$needs_path" = "N" ] && [ "$needs_runtime_home" = "N" ]; then
        return
    fi

    if [ "$needs_path" = "Y" ]; then
        print_warning "${BIN_DIR} is not in your PATH."
    fi
    if [ "$needs_runtime_home" = "Y" ]; then
        print_detail "Persisting MN_HOME=${INSTALL_DIR} for future terminal sessions."
    fi

    shell_profile="$(mn_preferred_shell_profile)"
    local detected_profiles=("$shell_profile")

    local profile path_line home_line wrote_header wrote_profile
    if [ "$INSTALL_DIR" = "$default_home" ]; then
        home_line='export MN_HOME="$HOME/.mn"'
    else
        home_line="export MN_HOME=$(shell_escape_value "$INSTALL_DIR")"
    fi
    path_line='export PATH="$MN_HOME/bin:$PATH"'

    for profile in "${detected_profiles[@]}"; do
        wrote_header="N"
        wrote_profile="N"
        mn_deduplicate_generated_profile_exports "$profile" "$path_line" "$home_line"
        if [ "$needs_runtime_home" = "Y" ] && ! profile_has_runtime_home "$profile"; then
            [ "$wrote_header" = "N" ] && echo -e "\n# MN and OTTERDESK" >> "$profile" && wrote_header="Y"
            echo "$home_line" >> "$profile"
            wrote_profile="Y"
        fi
        if [ "$needs_path" = "Y" ] && ! profile_has_bin_path "$profile"; then
            [ "$wrote_header" = "N" ] && echo -e "\n# MN and OTTERDESK" >> "$profile" && wrote_header="Y"
            echo "$path_line" >> "$profile"
            wrote_profile="Y"
        fi
        if [ "$wrote_profile" = "Y" ]; then
            print_detail "Updated shell exports: ${profile}"
            profile_updated="Y"
        fi
    done

    if [ "$needs_path" = "Y" ]; then
        export PATH="${BIN_DIR}:${PATH}"
    fi
    if [ "$needs_path" = "Y" ] || [ "$profile_updated" = "Y" ]; then
        MN_SHELL_PROFILE_RELOAD_REQUIRED="Y"
        MN_SHELL_PROFILE_PATH="$shell_profile"
        print_warning "Open a new terminal, or run: source $(shell_escape_value "$shell_profile")"
    fi
}

ensure_shell_profile_exports

print_detail "Start the server: mn runtime start"
if [ "$INSTALL_CLI" = "Y" ]; then
    mn_print_next_shell_command "mn node list"
fi

if [ "$START_NOW" = "Y" ]; then
    print_step "Starting MirrorNeuron services"
    if ! mn_run_runtime_start_command "$VENV_DIR/bin/mn" runtime start; then
        [ -n "$MN_RUNTIME_START_LOG" ] && print_warning "CLI startup details: $MN_RUNTIME_START_LOG"
        print_warning "mn runtime start failed; starting MirrorNeuron Docker Compose runtime."
        mn_run_runtime_compose up -d --no-build
        "$VENV_DIR/bin/mn" runtime restart-sidecars --api >/dev/null 2>&1 || print_warning "MirrorNeuron Core started, but the REST API sidecar did not start automatically."
    fi
    if [ "$INSTALL_OPENSHELL" = "Y" ]; then
        reconcile_openshell_gateway_bind_host "${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
        wait_for_openshell_worker_service
    fi
    print_success "MirrorNeuron services are running."
fi

mn_print_cli_verification_prompt
}

run_install_local() {
#!/usr/bin/env bash

set -euo pipefail

# Keep installer output visible even when a subcommand redirects stdout/stderr.
exec 3>&1

if [ -t 3 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    ESC="$(printf '\033')"
    BOLD="${ESC}[1m"
    DIM="${ESC}[2m"
    RED="${ESC}[31m"
    GREEN="${ESC}[32m"
    YELLOW="${ESC}[33m"
    BLUE="${ESC}[34m"
    CYAN="${ESC}[36m"
    MAGENTA="${ESC}[35m"
    RESET="${ESC}[0m"
else
    BOLD=""
    DIM=""
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    CYAN=""
    MAGENTA=""
    RESET=""
fi

SCRIPT_DIR="$(mn_script_dir)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

INSTALL_DIR="${MN_HOME:-${HOME}/.mn}"
BIN_DIR="${HOME}/.local/bin"
VENV_DIR="${HOME}/.local/share/mn_venv"
UI_LINK_DIR="${INSTALL_DIR}/webui"
RUNTIME_COMPOSE_TEMPLATE="${SCRIPT_DIR}/docker-compose.yml"
RUNTIME_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
RUNTIME_COMPOSE_ENV="${INSTALL_DIR}/docker-compose.env"

CORE_DIR="${WORKSPACE_DIR}/MirrorNeuron"
CLI_DIR="${WORKSPACE_DIR}/mn-cli"
API_DIR="${WORKSPACE_DIR}/mn-api"
PY_SDK_DIR="${WORKSPACE_DIR}/mn-python-sdk"
WEB_UI_DIR="${WORKSPACE_DIR}/mn-web-ui"
MN_WEB_UI_SOURCE_MODE="${MN_WEB_UI_SOURCE_MODE:-source}"
MN_WEB_UI_SOURCE_MOUNT="${MN_WEB_UI_SOURCE_MOUNT:-${WEB_UI_DIR}}"
MN_WEB_UI_PACKAGE_VERSION="${MN_WEB_UI_PACKAGE_VERSION:-}"
SKILLS_DIR="${WORKSPACE_DIR}/mn-skills"
AGENTS_DIR="${WORKSPACE_DIR}/mn-agents"
BLUEPRINT_SUPPORT_SKILL_DIR="${SKILLS_DIR}/blueprint_support_skill"
JOB_RESPONSE_SKILL_DIR="${SKILLS_DIR}/job_response_skill"
MCP_CLIENT_SKILL_DIR="${SKILLS_DIR}/mcp_client_skill"
RAG_SKILL_DIR="${SKILLS_DIR}/rag_skill"
WEB_UI_SKILL_DIR="${SKILLS_DIR}/web_ui_skill"
BLUEPRINTS_DIR="${WORKSPACE_DIR}/mn-blueprints"
DOCS_DIR="${WORKSPACE_DIR}/mn-docs"
SYSTEM_TESTS_DIR="${WORKSPACE_DIR}/mn-system-tests"
MEMBRANE_DIR="${WORKSPACE_DIR}/Membrane"
MN_MEMBRANE_SOURCE_MODE="${MN_MEMBRANE_SOURCE_MODE:-image}"
MN_HOST_HOME_DIR="${MN_HOST_HOME_DIR:-${MN_HOST_MN_DIR:-${INSTALL_DIR}}}"
MN_AGENTS_ROOT="${MN_AGENTS_ROOT:-}"
MN_HOST_ARTIFACTS_DIR="${MN_HOST_ARTIFACTS_DIR:-${MN_HOST_HOME_DIR}/runs}"
MN_HOST_BLOB_STORE_DIR="${MN_HOST_BLOB_STORE_DIR:-${MN_HOST_HOME_DIR}/blobs}"
MN_HOST_SHARED_STORAGE_ROOT="${MN_HOST_SHARED_STORAGE_ROOT:-${MN_HOST_SHARED_ARTIFACT_ROOT:-${MN_HOST_HOME_DIR}/shared}}"
MN_SYNCTHING_ENABLED="${MN_SYNCTHING_ENABLED:-auto}"
MN_SYNCTHING_IMAGE="${MN_SYNCTHING_IMAGE:-syncthing/syncthing:latest}"
MN_SYNCTHING_GUI_PORT="${MN_SYNCTHING_GUI_PORT:-58384}"
MN_SYNCTHING_SYNC_PORT="${MN_SYNCTHING_SYNC_PORT:-22000}"
MN_SYNCTHING_RESCAN_INTERVAL_SECONDS="${MN_SYNCTHING_RESCAN_INTERVAL_SECONDS:-3600}"
MN_BLUEPRINT_PYTHON_ENVS_DIR="${MN_BLUEPRINT_PYTHON_ENVS_DIR:-}"
MN_HOST_OPENSHELL_CONFIG_DIR="${OPENSHELL_CONTAINER_CONFIG_DIR:-${HOME}/.config/openshell-mirror-neuron}"
MN_HOST_OPENSHELL_STATE_DIR="${MN_HOST_OPENSHELL_STATE_DIR:-${INSTALL_DIR}/openshell-state}"
OPENSHELL_GATEWAY_USER="${OPENSHELL_GATEWAY_USER:-$(id -u):$(id -g)}"
mn_print_docker_desktop_permission_notice
DOCKER_HOST_SOCKET="${DOCKER_HOST_SOCKET:-$(mn_resolve_docker_host_socket)}"
if [ -z "${OPENSHELL_GATEWAY_DOCKER_GROUP:-}" ] && [ "$(uname -s)" = "Darwin" ]; then
    OPENSHELL_GATEWAY_DOCKER_GROUP="0"
elif [ -z "${OPENSHELL_GATEWAY_DOCKER_GROUP:-}" ] && [ -S "${DOCKER_HOST_SOCKET}" ]; then
    OPENSHELL_GATEWAY_DOCKER_GROUP="$(stat -c '%g' "${DOCKER_HOST_SOCKET}" 2>/dev/null || stat -f '%g' "${DOCKER_HOST_SOCKET}" 2>/dev/null || true)"
fi
OPENSHELL_GATEWAY_DOCKER_GROUP="${OPENSHELL_GATEWAY_DOCKER_GROUP:-0}"
MN_DYNAMIC_REDIS_PORT_START="${MN_DYNAMIC_REDIS_PORT_START:-56379}"
MN_DYNAMIC_REDIS_PORT_END="${MN_DYNAMIC_REDIS_PORT_END:-56478}"
MN_PYTHON_BIN=""
MN_MANAGED_PYTHON="${MN_MANAGED_PYTHON:-1}"
MN_MANAGED_PYTHON_VERSION="${MN_MANAGED_PYTHON_VERSION:-3.11}"
MN_MANAGED_PYTHON_ROOT="${MN_MANAGED_PYTHON_DIR:-${HOME}/.local/share/mn_python}"
MN_UV_ROOT="${MN_UV_DIR:-${HOME}/.local/share/mn_uv}"
MN_UV_BIN=""

INSTALL_WEB_UI="Y"
INSTALL_REDIS="Y"
INSTALL_CONTEXT_ENGINE="N"
INSTALL_OPENSHELL="Y"
INSTALL_SKILLS="Y"
START_NOW="Y"
NON_INTERACTIVE="Y"

function print_header() {
    printf '\n%s%s%s\n' "${BLUE}${BOLD}" "MirrorNeuron Installer" "$RESET" >&3
    printf '  Source: local workspace\n' >&3
}

function print_step() { printf '%s==>%s %s\n' "${CYAN}${BOLD}" "$RESET" "$1" >&3; }
function print_success() { printf '%s✔%s %s\n' "${GREEN}${BOLD}" "$RESET" "$1" >&3; }
function print_error() { printf '%serror:%s %s\n' "${RED}${BOLD}" "$RESET" "$1" >&3; }
function print_warning() { printf '%swarning:%s %s\n' "${YELLOW}${BOLD}" "$RESET" "$1" >&3; }
function print_detail() {
    if [ "$MN_INSTALL_VERBOSE" = "Y" ]; then
        printf '    %s\n' "$1" >&3
    fi
}

function run_quiet() {
    local label="$1"
    shift
    local log_dir="${TMPDIR:-/tmp}/mirror_neuron_install"
    mkdir -p "$log_dir"
    local log_file="${log_dir}/${label//[^A-Za-z0-9_.-]/_}.$$.log"

    if ! "$@" >"$log_file" 2>&1; then
        print_error "$label failed. Details: $log_file"
        if [ "$MN_INSTALL_VERBOSE" = "Y" ]; then
            tail -n 20 "$log_file" >&3 2>/dev/null || true
        else
            printf '  Re-run with --verbose to show the last log lines.\n' >&3
        fi
        exit 1
    fi
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

function python_is_selected_minor() {
    [ "$(python_minor_version "$1" || true)" = "$MN_MANAGED_PYTHON_VERSION" ]
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

    print_detail "Installed uv at $MN_UV_BIN."
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
    print_warning "No Python ${MN_MANAGED_PYTHON_VERSION}.x interpreter was found; uv will manage a private runtime under ${MN_MANAGED_PYTHON_ROOT}."
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
    print_detail "Using uv-managed Python $(python_version "$managed_bin") at $managed_bin."
}

function print_python_requirement_error() {
    local selected="${1:-}"
    local version=""

    print_error "MirrorNeuron Python components require Python ${MN_MANAGED_PYTHON_VERSION}.x by default."
    if [ -n "$selected" ]; then
        version="$(python_version "$selected" || true)"
        if [ -n "$version" ]; then
            print_error "Selected Python '$selected' is version $version."
        else
            print_error "Selected Python '$selected' could not be run."
        fi
    fi
    print_error "Install Python ${MN_MANAGED_PYTHON_VERSION}.x yourself, or allow the uv-managed private runtime fallback."
    print_error "You can also rerun with: MN_PYTHON=/opt/homebrew/bin/python${MN_MANAGED_PYTHON_VERSION} ./$(basename "$0")"
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
        candidates+=("python${MN_MANAGED_PYTHON_VERSION}" python3 python)
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
        if python_is_supported "$resolved" && python_is_selected_minor "$resolved"; then
            MN_PYTHON_BIN="$resolved"
            print_detail "Using Python $(python_version "$MN_PYTHON_BIN") at $MN_PYTHON_BIN."
            return
        fi
        if [ -n "${MN_PYTHON:-}" ]; then
            print_python_requirement_error "$resolved"
            exit 1
        fi
    done

    resolved="$(command -v "python${MN_MANAGED_PYTHON_VERSION}" 2>/dev/null || true)"
    if managed_python_enabled; then
        install_managed_python
        return
    fi

    print_warning "Managed Python fallback is disabled."
    print_python_requirement_error "$resolved"
    exit 1
}

function usage() {
    cat >&3 <<EOF
Usage: ./install.sh --mode local [options]

Installs MirrorNeuron from local sibling folders under:
  ${WORKSPACE_DIR}

Options:
  --yes                 Run non-interactively with defaults. This is the default.
  --interactive         Ask each install question before proceeding.
  --reset               Permanently clear runtime data first; requires typing YES.
  -v, --verbose         Show installation details and command paths.
  --web-ui              Enable the local-source Web UI Compose service.
  --no-web-ui           Skip the local-source Web UI Compose service.
  --redis               Enable Redis Docker setup.
  --no-redis            Skip Redis Docker setup.
  --context-engine      Install/start Membrane context engine.
  --no-context-engine   Skip Membrane context engine setup.
  --openshell           Install/start OpenShell gateway for sandbox workers.
  --no-openshell        Skip OpenShell gateway setup.
  --syncthing / --no-syncthing
                        Enable or skip Syncthing shared-storage replication.
  --no-skills           Skip optional packages under mn-skills. Skills required
                        by local runtime packages are still installed locally.
  --start               Start MirrorNeuron after install.
  --no-start            Skip starting MirrorNeuron after install.
  --python PATH         Same as MN_PYTHON. Must be Python 3.11.x.
  --no-managed-python   Do not use uv to install a private Python runtime.
  MN_PYTHON=/path       Use a specific Python 3.11.x interpreter.
  MN_HOME=/path         Override the runtime state directory. Defaults to ${HOME}/.mn.
  MN_AGENTS_ROOT=/path  Override the local agent template catalog. Defaults to ${WORKSPACE_DIR}/mn-agents.
  MN_MANAGED_PYTHON=0   Disable uv-managed private Python fallback.
  -h, --help            Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes|-y) NON_INTERACTIVE="Y" ;;
        --interactive) NON_INTERACTIVE="N" ;;
        --web-ui) INSTALL_WEB_UI="Y" ;;
        --no-web-ui) INSTALL_WEB_UI="N" ;;
        --redis) INSTALL_REDIS="Y" ;;
        --no-redis) INSTALL_REDIS="N" ;;
        --context-engine) INSTALL_CONTEXT_ENGINE="Y" ;;
        --no-context-engine) INSTALL_CONTEXT_ENGINE="N" ;;
        --openshell) INSTALL_OPENSHELL="Y" ;;
        --no-openshell) INSTALL_OPENSHELL="N" ;;
        --no-skills) INSTALL_SKILLS="N" ;;
        --syncthing) MN_SYNCTHING_ENABLED="auto" ;;
        --no-syncthing) MN_SYNCTHING_ENABLED="0" ;;
        --start) START_NOW="Y" ;;
        --no-start) START_NOW="N" ;;
        --python)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--python requires a path."
                usage
                exit 1
            fi
            MN_PYTHON="$1"
            ;;
        --python=*) MN_PYTHON="${1#*=}" ;;
        --no-managed-python) MN_MANAGED_PYTHON=0 ;;
        -h|--help) usage; exit 0 ;;
        *)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

function spinner() {
    local pid=$1
    local msg=$2
    local delay=0.1
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local frame_index=0
    local interactive="N"
    if [ -t 3 ]; then
        interactive="Y"
        tput civis >&3 2>/dev/null || true
        while kill -0 "$pid" 2>/dev/null; do
            printf '\r%s%s%s %s' "${MAGENTA}${BOLD}" "${frames[$frame_index]}" "$RESET" "$msg" >&3
            frame_index=$(((frame_index + 1) % ${#frames[@]}))
            sleep "$delay"
        done
    else
        print_step "$msg"
    fi
    set +e
    wait "$pid"
    local exit_code=$?
    set -e
    if [ "$exit_code" -eq 0 ]; then
        if [ "$interactive" = "Y" ]; then printf '\r\033[2K' >&3; fi
        print_success "$msg"
    else
        if [ "$interactive" = "Y" ]; then printf '\r\033[2K' >&3; fi
        print_error "$msg failed."
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

function validate_agents_root() {
    local root="$1"
    if [ ! -f "${root}/index.json" ]; then
        print_error "mn-agents index was not found at ${root}/index.json."
        print_error "Set MN_AGENTS_ROOT to a valid mn-agents checkout or run from a complete mirror-neuron-set workspace."
        exit 1
    fi
}

function ensure_agent_catalog_root() {
    local root="${MN_AGENTS_ROOT:-$AGENTS_DIR}"
    validate_agents_root "$root"
    (cd "$root" && pwd)
}

function mix_project_file_valid() {
    local path="$1"
    [ -s "$path" ] && grep -q "use Mix.Project" "$path"
}

function restore_mix_project_file_from_git() {
    local path="$1"
    local path_dir abs_path repo_dir relpath tmp_file commit

    if ! command -v git >/dev/null 2>&1; then
        return 1
    fi

    path_dir="$(dirname "$path")"
    if [ ! -d "$path_dir" ]; then
        return 1
    fi

    abs_path="$(cd "$path_dir" && pwd -P)/$(basename "$path")"
    repo_dir="$(cd "$path_dir" && git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -z "$repo_dir" ]; then
        return 1
    fi

    relpath="${abs_path#${repo_dir}/}"
    if [ "$relpath" = "$abs_path" ]; then
        return 1
    fi

    tmp_file="$(mktemp "${TMPDIR:-/tmp}/mn-mix-exs.XXXXXX")"
    while IFS= read -r commit; do
        if git -C "$repo_dir" show "${commit}:${relpath}" >"$tmp_file" 2>/dev/null && mix_project_file_valid "$tmp_file"; then
            cp "$tmp_file" "$path"
            rm -f "$tmp_file"
            print_warning "Repaired MirrorNeuron mix.exs from git history (${commit:0:12})."
            return 0
        fi
    done < <(git -C "$repo_dir" log --format='%H' -- "$relpath" 2>/dev/null)

    rm -f "$tmp_file"
    return 1
}

function require_mix_project_file() {
    local path="$1"
    if mix_project_file_valid "$path"; then
        return
    fi

    if [ ! -e "$path" ] || [ ! -s "$path" ]; then
        if restore_mix_project_file_from_git "$path" && mix_project_file_valid "$path"; then
            return
        fi
    fi

    if [ ! -f "$path" ]; then
        print_error "Missing MirrorNeuron mix.exs: ${path}"
        exit 1
    fi

    print_error "Invalid MirrorNeuron mix.exs: ${path}"
    print_error "Expected a non-empty Mix project file containing 'use Mix.Project'."
    exit 1
}

function canonical_path() {
    local path="$1"
    local dir base
    if [ -e "$path" ] || [ -L "$path" ]; then
        dir="$(cd "$(dirname "$path")" && pwd -P)"
        base="$(basename "$path")"
        printf '%s/%s\n' "$dir" "$base"
        return 0
    fi

    dir="$(dirname "$path")"
    base="$(basename "$path")"
    if [ -d "$dir" ]; then
        dir="$(cd "$dir" && pwd -P)"
    else
        dir="$(cd "$(dirname "$dir")" 2>/dev/null && pwd -P)/$(basename "$dir")"
    fi
    printf '%s/%s\n' "$dir" "$base"
}

function require_install_dir_not_source() {
    local install_path workspace_path source_path source_label
    install_path="$(canonical_path "$INSTALL_DIR")"
    workspace_path="$(canonical_path "$WORKSPACE_DIR")"

    if [ "$install_path" = "$workspace_path" ]; then
        print_error "Refusing to install MirrorNeuron state into the source workspace: ${INSTALL_DIR}"
        print_error "Unset MN_HOME or set it to a state directory such as ${HOME}/.mn."
        exit 1
    fi

    for source_label in CORE_DIR CLI_DIR API_DIR PY_SDK_DIR WEB_UI_DIR SKILLS_DIR BLUEPRINTS_DIR DOCS_DIR SYSTEM_TESTS_DIR MEMBRANE_DIR; do
        source_path="$(canonical_path "${!source_label}")"
        if [ "$install_path" = "$source_path" ]; then
            print_error "Refusing to install MirrorNeuron state into source directory ${source_label}: ${INSTALL_DIR}"
            print_error "Unset MN_HOME or set it to a state directory such as ${HOME}/.mn."
            exit 1
        fi
    done
}

function require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        print_error "'$cmd' is required but not installed."
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

function generate_openshell_jwt_keys() {
    local jwt_dir="$1"
    local gateway_image="${OPENSHELL_GATEWAY_IMAGE:-ghcr.io/nvidia/openshell/gateway:0.0.47}"
    local bootstrap_dir name

    bootstrap_dir="$(mktemp -d "${MN_HOST_OPENSHELL_STATE_DIR}/.jwt-bootstrap.XXXXXX")"
    if ! docker run --rm \
        --user "$OPENSHELL_GATEWAY_USER" \
        --env HOME=/tmp/openshell-bootstrap \
        --volume "${bootstrap_dir}:/bootstrap" \
        "$gateway_image" \
        generate-certs \
        --output-dir /bootstrap/output \
        --server-san host.openshell.internal >/dev/null; then
        print_error "Failed to create OpenShell sandbox JWT keys with ${gateway_image}."
        print_error "Check that Docker is running and can pull the OpenShell gateway image, then retry."
        rm -rf "$bootstrap_dir"
        exit 1
    fi

    for name in signing.pem public.pem kid; do
        if [ ! -s "${bootstrap_dir}/output/jwt/${name}" ]; then
            print_error "OpenShell certificate bootstrap did not create jwt/${name}."
            print_error "Check that ${gateway_image} supports the generate-certs command, then retry."
            rm -rf "$bootstrap_dir"
            exit 1
        fi
    done

    mv "${bootstrap_dir}/output/jwt/signing.pem" "${jwt_dir}/signing.pem"
    mv "${bootstrap_dir}/output/jwt/public.pem" "${jwt_dir}/public.pem"
    mv "${bootstrap_dir}/output/jwt/kid" "${jwt_dir}/kid"
    rm -rf "$bootstrap_dir"
    chmod 600 "${jwt_dir}/signing.pem" 2>/dev/null || true
    chmod 644 "${jwt_dir}/public.pem" "${jwt_dir}/kid" 2>/dev/null || true
}

function write_local_install_metadata() {
    local metadata_file="${INSTALL_DIR}/install_metadata.json"
    local updated_at
    updated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    cat > "$metadata_file" <<EOF
{
  "install_type": "local_source",
  "source_workspace": "${WORKSPACE_DIR}",
  "updated_at": "${updated_at}"
}
EOF
}

function core_container_running() {
    local names
    names="$(docker ps --format '{{.Names}}')"
    grep -qx 'mirror-neuron-core' <<< "$names"
}

function generate_mn_cookie() {
    local secret
    local python_fallback="${MN_PYTHON_BIN:-}"

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

    if [ -z "$python_fallback" ]; then
        python_fallback="$(command -v "python${MN_MANAGED_PYTHON_VERSION}" 2>/dev/null || true)"
    fi
    if [ -n "$python_fallback" ]; then
        if secret="$("$python_fallback" -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null)" && [ -n "$secret" ]; then
            printf '%s\n' "$secret"
            return 0
        fi
    fi

    return 1
}

function resolve_mn_cookie() {
    local env_cookie="${MN_COOKIE:-}"
    local cookie_file="${INSTALL_DIR}/erlang.cookie"
    local cookie

    if [ -n "$env_cookie" ] && [ "$env_cookie" != "mirrorneuron" ]; then
        printf '%s\n' "$env_cookie"
        return 0
    fi

    mkdir -p "$INSTALL_DIR"
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
        print_error "Failed to generate MN_COOKIE."
        exit 1
    fi

    printf '%s\n' "$cookie" > "$cookie_file"
    chmod 600 "$cookie_file" 2>/dev/null || true
    printf '%s\n' "$cookie"
}

function resolve_network_token() {
    local env_token="${MN_NETWORK_JOIN_TOKEN:-}"
    local token_file="${INSTALL_DIR}/network.token"
    local token

    if [ -n "$env_token" ]; then
        printf '%s\n' "$env_token" > "$token_file"
        chmod 600 "$token_file" 2>/dev/null || true
        printf '%s\n' "$env_token"
        return 0
    fi

    mkdir -p "$INSTALL_DIR"
    if [ -s "$token_file" ]; then
        token="$(tr -d '[:space:]' < "$token_file")"
        if [ -n "$token" ]; then
            chmod 600 "$token_file" 2>/dev/null || true
            printf '%s\n' "$token"
            return 0
        fi
    fi

    if ! token="$(generate_mn_cookie)"; then
        token=""
    fi
    if [ -z "$token" ]; then
        print_error "Failed to generate MN_NETWORK_JOIN_TOKEN."
        exit 1
    fi
    printf '%s\n' "$token" > "$token_file"
    chmod 600 "$token_file" 2>/dev/null || true
    printf '%s\n' "$token"
}

function derive_network_secret() {
    local token="$1"
    local label="$2"
    local material="mirror-neuron:${label}:${token}"
    local digest
    local python_fallback="${MN_PYTHON_BIN:-}"

    if command -v shasum >/dev/null 2>&1; then
        if digest="$(printf '%s' "$material" | shasum -a 256 2>/dev/null | awk '{print $1}')" && [ -n "$digest" ]; then
            printf '%s\n' "$digest"
            return 0
        fi
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        if digest="$(printf '%s' "$material" | sha256sum 2>/dev/null | awk '{print $1}')" && [ -n "$digest" ]; then
            printf '%s\n' "$digest"
            return 0
        fi
    fi

    if command -v openssl >/dev/null 2>&1; then
        if digest="$(printf '%s' "$material" | openssl dgst -sha256 -r 2>/dev/null | awk '{print $1}')" && [ -n "$digest" ]; then
            printf '%s\n' "$digest"
            return 0
        fi
    fi

    if [ -z "$python_fallback" ]; then
        python_fallback="$(command -v "python${MN_MANAGED_PYTHON_VERSION}" 2>/dev/null || true)"
    fi
    if [ -n "$python_fallback" ]; then
        if digest="$(printf '%s' "$material" | "$python_fallback" -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null)" && [ -n "$digest" ]; then
            printf '%s\n' "$digest"
            return 0
        fi
    fi

    print_error "Need shasum, sha256sum, a working openssl, or python${MN_MANAGED_PYTHON_VERSION} to derive Redis credentials."
    exit 1
}

function resolve_redis_password() {
    local admin_token="$1"
    local mn_env="${MN_ENV:-dev}"
    local password

    case "$mn_env" in
        prod|production)
            password="$(derive_network_secret "$admin_token" "redis")"
            mkdir -p "$INSTALL_DIR"
            printf '%s\n' "$password" > "${INSTALL_DIR}/redis.password"
            chmod 600 "${INSTALL_DIR}/redis.password" 2>/dev/null || true
            printf '%s\n' "$password"
            ;;
        *)
            printf '%s\n' "mirror_neuron_redis_dev"
            ;;
    esac
}

function read_env_value() {
    local file="$1"
    local key="$2"
    [ -f "$file" ] || return 0
    awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$file"
}

function redis_probe_host() {
    case "${1:-}" in
        ""|0.0.0.0|::|localhost) printf '127.0.0.1' ;;
        *) printf '%s' "$1" ;;
    esac
}

function redis_container_owns_port() {
    local port="$1"
    docker port mirror-neuron-redis 6379/tcp 2>/dev/null | awk -F: -v port="$port" '$NF == port {found=1} END {exit found ? 0 : 1}'
}

function redis_port_available() {
    local host="$1"
    local port="$2"
    local probe_host
    probe_host="$(redis_probe_host "$host")"

    if redis_container_owns_port "$port"; then
        return 0
    fi

    if command -v lsof >/dev/null 2>&1 &&
       lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        return 1
    fi

    if [ -n "${MN_PYTHON_BIN:-}" ] &&
       "$MN_PYTHON_BIN" -c 'import socket, sys
host = sys.argv[1]
port = int(sys.argv[2])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(0.25)
try:
    raise SystemExit(0 if sock.connect_ex((host, port)) == 0 else 1)
finally:
    sock.close()
' "$probe_host" "$port" >/dev/null 2>&1; then
        return 1
    fi

    return 0
}

function resolve_redis_port() {
    local bind_host="$1"
    local persisted_port="$2"
    local candidate

    if [ -n "${MN_REDIS_PORT:-}" ]; then
        candidate="$MN_REDIS_PORT"
        if ! [[ "$candidate" =~ ^[0-9]+$ ]] || [ "$candidate" -lt 1 ] || [ "$candidate" -gt 65535 ]; then
            print_error "MN_REDIS_PORT must be a TCP port between 1 and 65535."
            exit 1
        fi
        if ! redis_port_available "$bind_host" "$candidate"; then
            print_error "Redis port ${candidate} is already in use."
            exit 1
        fi
        printf '%s\n' "$candidate"
        return 0
    fi

    if [[ "$persisted_port" =~ ^[0-9]+$ ]] &&
       [ "$persisted_port" -ge "$MN_DYNAMIC_REDIS_PORT_START" ] &&
       [ "$persisted_port" -le "$MN_DYNAMIC_REDIS_PORT_END" ] &&
       redis_port_available "$bind_host" "$persisted_port"; then
        printf '%s\n' "$persisted_port"
        return 0
    fi

    for candidate in $(seq "$MN_DYNAMIC_REDIS_PORT_START" "$MN_DYNAMIC_REDIS_PORT_END"); do
        if redis_port_available "$bind_host" "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    print_error "No Redis port is available in ${MN_DYNAMIC_REDIS_PORT_START}-${MN_DYNAMIC_REDIS_PORT_END}."
    exit 1
}

function start_core_container() {
    local cmd=("docker" "run" "-d" "--name" "mirror-neuron-core")
    local openshell_config_dir="$HOME/.config/openshell"
    local openshell_container_config_dir="${OPENSHELL_CONTAINER_CONFIG_DIR:-$HOME/.config/openshell-mirror-neuron}"
    local openshell_mount_dir="$openshell_config_dir"
    local core_host="${MN_CORE_HOST:-localhost}"
    local redis_host="${MN_REDIS_HOST:-localhost}"
    local epmd_host="${MN_EPMD_HOST:-localhost}"
    local dist_host="${MN_DIST_HOST:-localhost}"
    local grpc_port="${MN_GRPC_PORT:-55051}"
    local epmd_port="${MN_EPMD_PORT:-54369}"
    local dist_port="${MN_DIST_PORT:-54370}"
    local core_publish_host="$core_host"
    local epmd_publish_host="$epmd_host"
    local dist_publish_host="$dist_host"
    local mn_cookie
    mn_cookie="$(resolve_mn_cookie)"
    [ "$core_publish_host" = "localhost" ] && core_publish_host="127.0.0.1"
    [ "$epmd_publish_host" = "localhost" ] && epmd_publish_host="127.0.0.1"
    [ "$dist_publish_host" = "localhost" ] && dist_publish_host="127.0.0.1"

    cmd+=("-e" "MN_COOKIE=${mn_cookie}")
    cmd+=("-e" "MN_GRPC_AUTH_TOKEN=mirror_neuron_password")
    cmd+=("-e" "MN_GRPC_ADMIN_TOKEN=mirror_neuron_password_admin")
    cmd+=("-e" "MN_GRPC_PORT=${grpc_port}")
    if [ -n "${MN_NODE_NAME:-}" ]; then
        cmd+=("-e" "MN_NODE_NAME=${MN_NODE_NAME}")
    fi

    if [ "$(uname -s)" = "Darwin" ]; then
        cmd+=("-p" "${core_publish_host}:${grpc_port}:${grpc_port}" "-p" "${epmd_publish_host}:${epmd_port}:4369")
        cmd+=("-p" "${dist_publish_host}:${dist_port}:${dist_port}")
        cmd+=("-e" "MN_REDIS_URL=redis://host.docker.internal:6379/0")
        cmd+=("-e" "MN_CORE_HOST=0.0.0.0")
        cmd+=("-e" "MN_EXECUTOR_MAX_CONCURRENCY=50")
    else
        cmd+=("--network" "host")
        cmd+=("-e" "MN_CORE_HOST=${core_host}")
        cmd+=("-e" "MN_REDIS_HOST=${redis_host}")
        cmd+=("-e" "ERL_EPMD_ADDRESS=${epmd_host}")
        cmd+=("-e" "MN_EXECUTOR_MAX_CONCURRENCY=50")
    fi
    cmd+=("-e" "MN_DIST_PORT=${dist_port}")

    if [ -d "$openshell_container_config_dir/gateways/openshell" ]; then
        openshell_mount_dir="$openshell_container_config_dir"
    fi
    if [ -d "$openshell_mount_dir/gateways/openshell" ]; then
        cmd+=("-v" "$openshell_mount_dir:/root/.config/openshell:ro")
        cmd+=("-v" "$openshell_mount_dir:/opt/mirror_neuron/.config/openshell:ro")
    fi

    for env_name in \
        SLACK_BOT_TOKEN \
        SLACK_DEFAULT_CHANNEL \
        SLACK_API_BASE_URL \
        MN_SLACK_BOT_TOKEN \
        MN_SLACK_DEFAULT_CHANNEL \
        MN_SLACK_API_BASE_URL; do
        if [ -n "${!env_name:-}" ]; then
            cmd+=("-e" "$env_name")
        fi
    done

    cmd+=("mirror-neuron-core:latest")
    "${cmd[@]}" >/dev/null
}

function restart_core_container() {
    remove_stale_runtime_container mirror-neuron-core
    runtime_compose rm -sf mirror-neuron-core >/dev/null 2>&1 || true
    runtime_compose up -d mirror-neuron-core >/dev/null
}

function setup_context_engine() {
    remove_stale_runtime_containers_for_services context-engine-model membrane-context-engine
    ensure_docker_model_runner
    runtime_compose pull membrane-context-engine
    runtime_compose up -d --no-build membrane-context-engine >/dev/null
}

function compose_profiles() {
    local profiles=()
    [ "$INSTALL_WEB_UI" = "Y" ] && profiles+=("web-ui")
    [ "$INSTALL_OPENSHELL" = "Y" ] && profiles+=("openshell")
    [ "$INSTALL_CONTEXT_ENGINE" = "Y" ] && profiles+=("context")
    case "$(printf '%s' "$MN_SYNCTHING_ENABLED" | tr '[:upper:]' '[:lower:]')" in
        ''|0|false|no|n|off|disabled) ;;
        *) profiles+=("syncthing") ;;
    esac
    if [ "${#profiles[@]}" -eq 0 ]; then
        printf ''
        return 0
    fi
    local IFS=,
    printf '%s' "${profiles[*]}"
}

function write_openshell_compose_config() {
    local gateway_dir="${MN_HOST_OPENSHELL_CONFIG_DIR}/gateways/openshell"
    local jwt_dir="${MN_HOST_OPENSHELL_STATE_DIR}/jwt"
    mkdir -p "$gateway_dir"
    mkdir -p "$jwt_dir"
    if [ ! -s "${jwt_dir}/signing.pem" ] || [ ! -s "${jwt_dir}/public.pem" ] || [ ! -s "${jwt_dir}/kid" ]; then
        generate_openshell_jwt_keys "$jwt_dir"
    fi
    printf 'openshell\n' > "${MN_HOST_OPENSHELL_CONFIG_DIR}/active_gateway"
    cat > "${gateway_dir}/metadata.json" <<EOF
{
  "name": "openshell",
  "gateway_endpoint": "http://openshell:${OPENSHELL_GATEWAY_PORT:-58080}",
  "is_remote": false,
  "gateway_port": ${OPENSHELL_GATEWAY_PORT:-58080}
}
EOF
    cat > "${MN_HOST_OPENSHELL_STATE_DIR}/gateway.toml" <<EOF
[openshell]
version = 1

[openshell.gateway]
bind_address = "0.0.0.0:${OPENSHELL_GATEWAY_PORT:-58080}"
log_level = "info"
compute_drivers = ["docker"]
sandbox_namespace = "mirror-neuron"
default_image = "ghcr.io/nvidia/openshell/sandbox:latest"
supervisor_image = "ghcr.io/nvidia/openshell/supervisor:latest"

[openshell.gateway.gateway_jwt]
signing_key_path = "${jwt_dir}/signing.pem"
public_key_path = "${jwt_dir}/public.pem"
kid_path = "${jwt_dir}/kid"
gateway_id = "openshell"
ttl_secs = 3600

[openshell.gateway.auth]
allow_unauthenticated_users = true

[openshell.drivers.docker]
default_image = "ghcr.io/nvidia/openshell/sandbox:latest"
image_pull_policy = "IfNotPresent"
sandbox_namespace = "mirror-neuron"
grpc_endpoint = "http://openshell:${OPENSHELL_GATEWAY_PORT:-58080}"
network_name = "${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
EOF
}

function install_openshell_cli() {
    if command -v openshell >/dev/null 2>&1; then
        return 0
    fi
    local installer="${TMPDIR:-/tmp}/mirror_neuron_openshell_install.sh"
    curl_github -fLsS https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh -o "$installer"
    OPENSHELL_VERSION="${OPENSHELL_VERSION:-v0.0.47}" sh "$installer" >/dev/null
    rm -f "$installer"
}

function resolve_docker_network_external() {
    local network_name="$1"
    local configured="${MN_DOCKER_NETWORK_EXTERNAL:-}"
    local labels compose_project compose_network

    if [ -n "$configured" ]; then
        printf '%s\n' "$configured"
        return 0
    fi

    if ! labels="$(docker network inspect -f '{{ index .Labels "com.docker.compose.project" }}|{{ index .Labels "com.docker.compose.network" }}' "$network_name" 2>/dev/null)"; then
        printf 'false\n'
        return 0
    fi

    compose_project="${labels%%|*}"
    compose_network="${labels#*|}"
    if [ "$compose_project" = "mirror-neuron" ] && [ "$compose_network" = "runtime" ]; then
        printf 'false\n'
    else
        print_warning "Docker network ${network_name} already exists outside this Compose project; reusing it as an external network."
        printf 'true\n'
    fi
}

function resolve_openshell_gateway_bind_host() {
    local network_name="$1"
    local docker_os gateway

    if [ -n "${OPENSHELL_GATEWAY_BIND_HOST:-}" ]; then
        printf '%s\n' "$OPENSHELL_GATEWAY_BIND_HOST"
        return 0
    fi

    docker_os="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
    if [ "$(uname -s)" = "Darwin" ] || [[ "$docker_os" == *"docker desktop"* ]]; then
        printf '127.0.0.1\n'
        return 0
    fi

    gateway="$(docker network inspect -f '{{ (index .IPAM.Config 0).Gateway }}' "$network_name" 2>/dev/null || true)"
    printf '%s\n' "${gateway:-127.0.0.1}"
}

function reconcile_openshell_gateway_bind_host() {
    local network_name="$1"
    local desired_bind_host desired_endpoint current_bind_host current_endpoint tmp_env
    desired_bind_host="$(resolve_openshell_gateway_bind_host "$network_name")"
    desired_endpoint="${OPENSHELL_GATEWAY_ENDPOINT:-http://${desired_bind_host}:${OPENSHELL_GATEWAY_PORT:-58080}}"
    current_bind_host="$(sed -n 's/^OPENSHELL_GATEWAY_BIND_HOST=//p' "$RUNTIME_COMPOSE_ENV" | tail -1)"
    current_endpoint="$(sed -n 's/^OPENSHELL_GATEWAY_ENDPOINT=//p' "$RUNTIME_COMPOSE_ENV" | tail -1)"
    if [ "$current_bind_host" = "$desired_bind_host" ] && [ "$current_endpoint" = "$desired_endpoint" ]; then
        return 0
    fi

    tmp_env="${RUNTIME_COMPOSE_ENV}.tmp"
    awk -v bind_host="$desired_bind_host" -v endpoint="$desired_endpoint" '
        BEGIN { replaced_bind_host = 0; replaced_endpoint = 0 }
        /^OPENSHELL_GATEWAY_BIND_HOST=/ {
            if (!replaced_bind_host) print "OPENSHELL_GATEWAY_BIND_HOST=" bind_host
            replaced_bind_host = 1
            next
        }
        /^OPENSHELL_GATEWAY_ENDPOINT=/ {
            if (!replaced_endpoint) print "OPENSHELL_GATEWAY_ENDPOINT=" endpoint
            replaced_endpoint = 1
            next
        }
        { print }
        END {
            if (!replaced_bind_host) print "OPENSHELL_GATEWAY_BIND_HOST=" bind_host
            if (!replaced_endpoint) print "OPENSHELL_GATEWAY_ENDPOINT=" endpoint
        }
    ' "$RUNTIME_COMPOSE_ENV" > "$tmp_env"
    mv "$tmp_env" "$RUNTIME_COMPOSE_ENV"
    chmod 600 "$RUNTIME_COMPOSE_ENV" 2>/dev/null || true
    if [ "$current_bind_host" != "$desired_bind_host" ]; then
        mn_run_runtime_compose up -d --force-recreate openshell
    fi
}

function wait_for_openshell_worker_service() {
    local network_name="${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
    local gateway_endpoint="http://openshell:${OPENSHELL_GATEWAY_PORT:-58080}"
    local attempt=1
    local max_attempts=60
    local readiness_announced="N"

    while [ "$attempt" -le "$max_attempts" ]; do
        if docker run --rm \
            --network "$network_name" \
            --entrypoint openshell \
            mirror-neuron-core:latest \
            --gateway-endpoint "$gateway_endpoint" \
            sandbox list >/dev/null 2>&1; then
            if [ "$readiness_announced" = "Y" ]; then
                print_success "OpenShell gateway is ready."
            fi
            return 0
        fi
        if [ "$readiness_announced" != "Y" ]; then
            print_step "Waiting for OpenShell gateway to become ready"
            readiness_announced="Y"
        fi
        sleep 1
        attempt=$((attempt + 1))
    done

    print_error "OpenShell worker service did not become ready at ${gateway_endpoint} after ${max_attempts} seconds."
    print_error "Next: docker logs openshell-cluster-openshell"
    return 1
}

function ensure_runtime_host_directory() {
    local path="$1"
    local description="$2"
    local override_name="$3"

    if [ -e "$path" ] || [ -L "$path" ]; then
        if [ ! -d "$path" ]; then
            print_error "Expected ${description} to be a directory: ${path}"
            print_error "Move or remove that path, or set ${override_name} to a directory."
            exit 1
        fi
        chmod u+rwx "$path" 2>/dev/null || true
        if [ ! -w "$path" ]; then
            print_error "Expected ${description} to be writable: ${path}"
            print_error "Repair ownership or set ${override_name} to a writable directory."
            exit 1
        fi
        return 0
    fi

    mkdir -p "$path"
    chmod u+rwx "$path" 2>/dev/null || true
}

function prepare_litellm_gateway_config() {
    local gateway_dir="${MN_HOST_HOME_DIR}/models/litellm-gateway"
    mkdir -p "$gateway_dir"
    if [ ! -e "${gateway_dir}/config.yaml" ]; then
        printf '{"model_list":[]}\n' > "${gateway_dir}/config.yaml"
    fi
    chmod u+rwX "$gateway_dir" "${gateway_dir}/config.yaml" 2>/dev/null || true
}

function write_runtime_compose_files() {
    local model_runner_model profiles network_name network_external network_token redis_password mn_cookie runtime_skills_root runtime_agents_root runtime_package_index context_memory_enabled otterdesk_context_memory_enabled membrane_engine_tag membrane_engine_image litellm_gateway_bind_host openshell_gateway_bind_host openshell_gateway_endpoint api_host blueprint_web_ui_port_start blueprint_web_ui_port_end
    model_runner_model="${MN_CONTEXT_MODEL_RUNNER_MODEL:-hf.co/homerquan/mn-context-engine-model-v-Q4_K_M}"
    profiles="$(compose_profiles)"
    api_host="${MN_API_HOST:-}"
    if [ -z "$api_host" ]; then
        if [ "$INSTALL_WEB_UI" = "Y" ]; then
            api_host="0.0.0.0"
        else
            api_host="localhost"
        fi
    fi
    litellm_gateway_bind_host="${MN_LITELLM_GATEWAY_BIND_HOST:-0.0.0.0}"
    network_name="${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
    openshell_gateway_bind_host="$(resolve_openshell_gateway_bind_host "$network_name")"
    openshell_gateway_endpoint="${OPENSHELL_GATEWAY_ENDPOINT:-http://${openshell_gateway_bind_host}:${OPENSHELL_GATEWAY_PORT:-58080}}"
    network_external="$(resolve_docker_network_external "$network_name")"
    network_token="$(resolve_network_token)"
    redis_password="$(resolve_redis_password "mirror_neuron_password_admin")"
    mn_cookie="$(resolve_mn_cookie)"
    printf '%s\n' "mirror_neuron_password" > "${INSTALL_DIR}/grpc_auth.token"
    printf '%s\n' "mirror_neuron_password_admin" > "${INSTALL_DIR}/grpc_admin.token"
    chmod 600 "${INSTALL_DIR}/grpc_auth.token" "${INSTALL_DIR}/grpc_admin.token" 2>/dev/null || true
    runtime_skills_root="${MN_SKILLS_ROOT:-${MN_HOST_HOME_DIR}/skills}"
    runtime_agents_root="$(ensure_agent_catalog_root)"
    runtime_package_index="${MN_PACKAGE_INDEX_FILE:-}"
    membrane_engine_tag="${MN_MEMBRANE_ENGINE_IMAGE_TAG:-${INSTALL_VERSION:-v${MN_PACKAGE_VERSION:-1.2.31}}}"
    if [[ "$membrane_engine_tag" != v* ]]; then
        membrane_engine_tag="v${membrane_engine_tag}"
    fi
    membrane_engine_image="${MN_MEMBRANE_ENGINE_IMAGE:-${MN_CONTEXT_ENGINE_IMAGE:-us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/membrane-context-engine:${membrane_engine_tag}}}"
    context_memory_enabled="${MN_CONTEXT_MEMORY_ENABLED:-1}"
    otterdesk_context_memory_enabled="${OTTERDESK_CONTEXT_MEMORY_ENABLED:-$context_memory_enabled}"
    if [ -n "${PACKAGE_INDEX_FILE:-}" ] && [ -f "$PACKAGE_INDEX_FILE" ]; then
        runtime_package_index="${INSTALL_DIR}/package-index/python-packages.toml"
        mkdir -p "$(dirname "$runtime_package_index")"
        cp "$PACKAGE_INDEX_FILE" "$runtime_package_index"
    fi

    mkdir -p "$INSTALL_DIR"
    ensure_runtime_host_directory "$MN_HOST_HOME_DIR" "MirrorNeuron home mount" "MN_HOST_HOME_DIR"
    ensure_runtime_host_directory "$runtime_skills_root" "MirrorNeuron runtime modules root" "MN_SKILLS_ROOT"
    ensure_runtime_host_directory "$MN_HOST_ARTIFACTS_DIR" "run artifacts host mount" "MN_HOST_ARTIFACTS_DIR"
    ensure_runtime_host_directory "$MN_HOST_BLOB_STORE_DIR" "blob store host mount" "MN_HOST_BLOB_STORE_DIR"
    ensure_runtime_host_directory "$MN_HOST_SHARED_STORAGE_ROOT" "shared storage host mount" "MN_HOST_SHARED_STORAGE_ROOT"
    ensure_runtime_host_directory "$MN_HOST_OPENSHELL_CONFIG_DIR" "OpenShell config host mount" "MN_HOST_OPENSHELL_CONFIG_DIR"
    ensure_runtime_host_directory "$MN_HOST_OPENSHELL_STATE_DIR" "OpenShell state host mount" "MN_HOST_OPENSHELL_STATE_DIR"
    prepare_litellm_gateway_config
    mn_write_runtime_compose_file "$RUNTIME_COMPOSE_TEMPLATE" "$RUNTIME_COMPOSE_FILE"
    if [ "$INSTALL_OPENSHELL" = "Y" ]; then
        write_openshell_compose_config
    fi
    # Preserve a locally selected Blueprint UI range on later local-source
    # refreshes. Docker Desktop reserves every prepublished port in the range.
    blueprint_web_ui_port_start="${MN_BLUEPRINT_WEB_UI_PORT_START:-$(read_env_value "$RUNTIME_COMPOSE_ENV" "MN_BLUEPRINT_WEB_UI_PORT_START")}"
    blueprint_web_ui_port_end="${MN_BLUEPRINT_WEB_UI_PORT_END:-$(read_env_value "$RUNTIME_COMPOSE_ENV" "MN_BLUEPRINT_WEB_UI_PORT_END")}"
    blueprint_web_ui_port_start="${blueprint_web_ui_port_start:-61000}"
    blueprint_web_ui_port_end="${blueprint_web_ui_port_end:-61049}"
    cat > "$RUNTIME_COMPOSE_ENV" <<EOF
COMPOSE_PROJECT_NAME=mirror-neuron
COMPOSE_PROFILES=${profiles}
MN_HOST_STATE_DIR=${INSTALL_DIR}
MN_HOST_HOME_DIR=${MN_HOST_HOME_DIR}
MN_HOST_ARTIFACTS_DIR=${MN_HOST_ARTIFACTS_DIR}
MN_HOST_BLOB_STORE_DIR=${MN_HOST_BLOB_STORE_DIR}
MN_HOST_SHARED_STORAGE_ROOT=${MN_HOST_SHARED_STORAGE_ROOT}
MN_SYNCTHING_ENABLED=${MN_SYNCTHING_ENABLED}
MN_SYNCTHING_IMAGE=${MN_SYNCTHING_IMAGE}
MN_SYNCTHING_GUI_PORT=${MN_SYNCTHING_GUI_PORT}
MN_SYNCTHING_SYNC_PORT=${MN_SYNCTHING_SYNC_PORT}
MN_SYNCTHING_RESCAN_INTERVAL_SECONDS=${MN_SYNCTHING_RESCAN_INTERVAL_SECONDS}
MN_BLUEPRINT_PYTHON_ENVS_DIR=${MN_BLUEPRINT_PYTHON_ENVS_DIR}
MN_HOST_OPENSHELL_CONFIG_DIR=${MN_HOST_OPENSHELL_CONFIG_DIR}
MN_HOST_OPENSHELL_STATE_DIR=${MN_HOST_OPENSHELL_STATE_DIR}
MN_MEMBRANE_SOURCE_MODE=${MN_MEMBRANE_SOURCE_MODE:-image}
ENGINE_IMAGE=${membrane_engine_image}
MN_MEMBRANE_ENGINE_IMAGE=${membrane_engine_image}
MN_MEMBRANE_ENGINE_IMAGE_TAG=${membrane_engine_tag}
MN_REDIS_IMAGE=${MN_REDIS_IMAGE:-redis:8}
MN_CONTEXT_MODEL_RUNNER_MODEL=${model_runner_model}
MN_LLM_MODEL_RUNNER_MODEL=${MN_LLM_MODEL_RUNNER_MODEL:-gemma4:e2b}
MN_GRPC_BIND_HOST=${MN_GRPC_BIND_HOST:-127.0.0.1}
MN_GRPC_PORT=${MN_GRPC_PORT:-55051}
MN_GRPC_TARGET=${MN_GRPC_TARGET:-localhost:${MN_GRPC_PORT:-55051}}
MN_GRPC_ADVERTISE_PORT=${MN_GRPC_ADVERTISE_PORT:-${MN_GRPC_PORT:-55051}}
MN_NATIVE_SDK_GRPC_HOST=${MN_NATIVE_SDK_GRPC_HOST:-0.0.0.0}
MN_NATIVE_SDK_GRPC_PORT=${MN_NATIVE_SDK_GRPC_PORT:-55052}
MN_NATIVE_SDK_GRPC_ADVERTISE_HOST=${MN_NATIVE_SDK_GRPC_ADVERTISE_HOST:-${MN_NETWORK_ADVERTISE_HOST:-}}
MN_NATIVE_SDK_GRPC_ADVERTISE_PORT=${MN_NATIVE_SDK_GRPC_ADVERTISE_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_NATIVE_SDK_GRPC_TARGET=${MN_NATIVE_SDK_GRPC_TARGET:-mn-native-sdk-grpc:55052}
MN_NATIVE_SDK_GRPC_PROXY_PORT=${MN_NATIVE_SDK_GRPC_PROXY_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_NATIVE_SDK_GRPC_PROXY_TARGET_HOST=${MN_NATIVE_SDK_GRPC_PROXY_TARGET_HOST:-host.docker.internal}
MN_NATIVE_SDK_GRPC_PROXY_TARGET_PORT=${MN_NATIVE_SDK_GRPC_PROXY_TARGET_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_LITELLM_GATEWAY_BIND_HOST=${litellm_gateway_bind_host}
MN_LITELLM_GATEWAY_PORT=${MN_LITELLM_GATEWAY_PORT:-4000}
MN_LITELLM_GATEWAY_INTERNAL_API_BASE=${MN_LITELLM_GATEWAY_INTERNAL_API_BASE:-http://mn-litellm-proxy:4000/v1}
MN_API_HOST=${api_host}
MN_API_PORT=${MN_API_PORT:-54001}
MN_DIST_PORT=${MN_DIST_PORT:-54370}
MN_WEB_UI_HOST=${MN_WEB_UI_HOST:-localhost}
MN_WEB_UI_PORT=${MN_WEB_UI_PORT:-55173}
MN_WEB_UI_BIND_HOST=${MN_WEB_UI_BIND_HOST:-127.0.0.1}
MN_WEB_UI_IMAGE=${MN_WEB_UI_IMAGE:-node:22-alpine}
MN_WEB_UI_SOURCE_MODE=${MN_WEB_UI_SOURCE_MODE}
MN_WEB_UI_SOURCE_MOUNT=${MN_WEB_UI_SOURCE_MOUNT}
MN_WEB_UI_PACKAGE_VERSION=${MN_WEB_UI_PACKAGE_VERSION}
MN_WEB_UI_API_HOST=${MN_WEB_UI_API_HOST:-host.docker.internal}
MN_BLUEPRINT_WEB_UI_BIND_HOST=${MN_BLUEPRINT_WEB_UI_BIND_HOST:-0.0.0.0}
MN_BLUEPRINT_WEB_UI_PUBLIC_HOST=${MN_BLUEPRINT_WEB_UI_PUBLIC_HOST:-localhost}
MN_BLUEPRINT_WEB_UI_PORT_START=${blueprint_web_ui_port_start}
MN_BLUEPRINT_WEB_UI_PORT_END=${blueprint_web_ui_port_end}
MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE=${MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE:-prepublished}
MN_ENV=${MN_ENV:-dev}
MN_BLUEPRINT_SOURCE=${MN_BLUEPRINT_SOURCE:-github}
MN_BLUEPRINT_REPO=${MN_BLUEPRINT_REPO:-https://github.com/MirrorNeuronLab/mn-blueprints.git}
MN_BLUEPRINT_LOCAL=${MN_BLUEPRINT_LOCAL:-}
MN_WORKSPACE_ROOT=${MN_WORKSPACE_ROOT:-}
MN_AGENTS_ROOT=${runtime_agents_root}
MN_SKILLS_ROOT=${runtime_skills_root}
MN_PACKAGE_INDEX_FILE=${runtime_package_index}
MN_PIP_INDEX_URL=${MN_PIP_INDEX_URL:-${MN_PYTHON_INDEX_URL:-${MN_DEFAULT_PIP_INDEX_URL:-https://us-central1-python.pkg.dev/mirrorneuron-public-packages/agent-skills/simple/}}}
MN_PIP_EXTRA_INDEX_URL=${MN_PIP_EXTRA_INDEX_URL:-${MN_PYTHON_EXTRA_INDEX_URL:-https://pypi.org/simple}}
MN_RUNTIME_MODULE_VERSION=${MN_RUNTIME_MODULE_VERSION:-${MN_PACKAGE_VERSION:-}}
MN_CONTEXT_MEMORY_ENABLED=${context_memory_enabled}
OTTERDESK_CONTEXT_MEMORY_ENABLED=${otterdesk_context_memory_enabled}
MN_RUNS_ROOT=${MN_RUNS_ROOT:-}
MN_DOCKER_NETWORK_MODE=${MN_DOCKER_NETWORK_MODE:-bridge}
MN_DOCKER_NETWORK_NAME=${network_name}
MN_DOCKER_NETWORK_EXTERNAL=${network_external}
MN_DOCKER_NETWORK_DRIVER=${MN_DOCKER_NETWORK_DRIVER:-bridge}
MN_DOCKER_NETWORK_ATTACHABLE=${MN_DOCKER_NETWORK_ATTACHABLE:-false}
MN_DOCKER_WORKER_ENABLED=${MN_DOCKER_WORKER_ENABLED:-1}
MN_NODE_ALIAS=${MN_NODE_ALIAS:-}
MN_NODE_NAME=${MN_NODE_NAME:-}
MN_NODE_ROLE=${MN_NODE_ROLE:-runtime}
MN_CLUSTER_NODES=${MN_CLUSTER_NODES:-}
MN_NETWORK_JOIN_TOKEN=${network_token}
MN_REDIS_PASSWORD=${redis_password}
MN_REDIS_URL=${MN_REDIS_URL:-redis://:${redis_password}@redis:6379/0}
MN_CONTEXT_REDIS_URL=${MN_CONTEXT_REDIS_URL:-redis://:${redis_password}@redis:6379/1}
MN_REDIS_HA_MODE=${MN_REDIS_HA_MODE:-single}
MN_REDIS_SENTINELS=${MN_REDIS_SENTINELS:-}
MN_REDIS_SENTINEL_MASTER=${MN_REDIS_SENTINEL_MASTER:-mirror-neuron}
MN_REDIS_SENTINEL_HOST_MAP=${MN_REDIS_SENTINEL_HOST_MAP:-}
MN_REDIS_DB=${MN_REDIS_DB:-0}
MN_REDIS_USERNAME=${MN_REDIS_USERNAME:-}
MN_REDIS_SENTINEL_USERNAME=${MN_REDIS_SENTINEL_USERNAME:-}
MN_REDIS_SENTINEL_PASSWORD=${MN_REDIS_SENTINEL_PASSWORD:-${redis_password}}
MN_REDIS_WAIT_REPLICAS=${MN_REDIS_WAIT_REPLICAS:-0}
MN_REDIS_WAIT_TIMEOUT_MS=${MN_REDIS_WAIT_TIMEOUT_MS:-100}
MN_REDIS_RECONNECT_ATTEMPTS=${MN_REDIS_RECONNECT_ATTEMPTS:-10}
MN_REDIS_RECONNECT_BACKOFF_MS=${MN_REDIS_RECONNECT_BACKOFF_MS:-250}
MN_REDIS_RECONNECT_MAX_BACKOFF_MS=${MN_REDIS_RECONNECT_MAX_BACKOFF_MS:-2000}
ERL_EPMD_ADDRESS=${ERL_EPMD_ADDRESS:-0.0.0.0}
ERL_AFLAGS=${ERL_AFLAGS:--kernel inet_dist_listen_min ${MN_DIST_PORT:-54370} inet_dist_listen_max ${MN_DIST_PORT:-54370}}
OPENSHELL_GATEWAY_PORT=${OPENSHELL_GATEWAY_PORT:-58080}
OPENSHELL_GATEWAY_ENDPOINT=${openshell_gateway_endpoint}
OPENSHELL_GATEWAY_BIND_HOST=${openshell_gateway_bind_host}
OPENSHELL_GATEWAY_USER=${OPENSHELL_GATEWAY_USER}
OPENSHELL_GATEWAY_DOCKER_GROUP=${OPENSHELL_GATEWAY_DOCKER_GROUP}
DOCKER_HOST_SOCKET=${DOCKER_HOST_SOCKET}
COMPOSE_PARALLEL_LIMIT=${COMPOSE_PARALLEL_LIMIT:-1}
MN_COOKIE=${mn_cookie}
MN_GRPC_AUTH_TOKEN=mirror_neuron_password
MN_GRPC_ADMIN_TOKEN=mirror_neuron_password_admin
EOF
    chmod 600 "$RUNTIME_COMPOSE_ENV" 2>/dev/null || true
}

function runtime_compose() {
    local status
    if command -v docker-compose >/dev/null 2>&1; then
        if COMPOSE_PARALLEL_LIMIT="${COMPOSE_PARALLEL_LIMIT:-1}" docker-compose --env-file "$RUNTIME_COMPOSE_ENV" -f "$RUNTIME_COMPOSE_FILE" "$@"; then
            return 0
        else
            status=$?
        fi
    else
        if COMPOSE_PARALLEL_LIMIT="${COMPOSE_PARALLEL_LIMIT:-1}" docker compose --env-file "$RUNTIME_COMPOSE_ENV" -f "$RUNTIME_COMPOSE_FILE" "$@"; then
            return 0
        else
            status=$?
        fi
    fi
    mn_report_docker_daemon_failure
    return "$status"
}

function runtime_container_name_for_service() {
    case "$1" in
        redis) echo "mirror-neuron-redis" ;;
        web-ui) echo "mirror-neuron-web-ui" ;;
        openshell) echo "openshell-cluster-openshell" ;;
        context-engine-model) echo "mirror-neuron-context-engine-model" ;;
        membrane-context-engine) echo "mirror-neuron-context-engine" ;;
        mirror-neuron-core) echo "mirror-neuron-core" ;;
        *) return 1 ;;
    esac
}

function remove_stale_runtime_container() {
    local name="$1"
    local project

    if ! docker container inspect "$name" >/dev/null 2>&1; then
        return 0
    fi

    project="$(docker container inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$name" 2>/dev/null || true)"
    if [ "$project" = "mirror-neuron" ]; then
        return 0
    fi

    docker rm -f "$name" >/dev/null 2>&1 || true
}

function remove_stale_runtime_containers_for_services() {
    local service name
    for service in "$@"; do
        name="$(runtime_container_name_for_service "$service" || true)"
        [ -n "$name" ] && remove_stale_runtime_container "$name"
    done
    return 0
}

function ensure_docker_model_runner() {
    local linux_nvidia="N"
    if mn_is_linux_nvidia_host; then
        linux_nvidia="Y"
    fi

    if [ "$linux_nvidia" != "Y" ] && [ "$INSTALL_CONTEXT_ENGINE" != "Y" ] && [ "${INSTALL_DOCKER_MODEL_RUNNER:-N}" != "Y" ] && [ "${MN_ENABLE_DOCKER_MODEL_RUNNER:-N}" != "Y" ]; then
        return 0
    fi

    mn_prepare_docker_model_runner_cli
    if ! docker model --help >/dev/null 2>&1; then
        print_error "Docker Model Runner CLI is not available."
        mn_print_docker_model_runner_install_hint
        exit 1
    fi

    if [ "$linux_nvidia" = "Y" ]; then
        mn_ensure_nvidia_llamacpp_runner
        return 0
    else
        if docker model status >/dev/null 2>&1; then
            return 0
        fi

        if mn_is_docker_desktop_host; then
            print_warning "Docker Model Runner is not running after the Docker Desktop enable command."
        else
            print_warning "Docker Model Runner is not running; attempting to install and start it."
        fi

        if docker model install-runner --help >/dev/null 2>&1; then
            docker model install-runner >/dev/null 2>&1 || true
            docker model start-runner >/dev/null 2>&1 || true
            if docker model status >/dev/null 2>&1; then
                return 0
            fi
        fi
    fi

    print_error "Docker Model Runner is not ready."
    mn_print_docker_model_runner_install_hint
    exit 1
}

function prepare_runtime_compose_sidecars() {
    RUNTIME_COMPOSE_SIDECARS=()
    [ "$INSTALL_REDIS" = "Y" ] && RUNTIME_COMPOSE_SIDECARS+=("redis")
    [ "$INSTALL_WEB_UI" = "Y" ] && RUNTIME_COMPOSE_SIDECARS+=("web-ui")
    grep -q '^  mn-native-sdk-grpc:' "$RUNTIME_COMPOSE_FILE" 2>/dev/null && RUNTIME_COMPOSE_SIDECARS+=("mn-native-sdk-grpc")
    grep -q '^  mn-litellm-proxy:' "$RUNTIME_COMPOSE_FILE" 2>/dev/null && RUNTIME_COMPOSE_SIDECARS+=("mn-litellm-proxy")
    [ "$INSTALL_OPENSHELL" = "Y" ] && RUNTIME_COMPOSE_SIDECARS+=("openshell")
    if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
        RUNTIME_COMPOSE_SIDECARS+=("membrane-context-engine")
    fi
    if mn_is_linux_nvidia_host; then
        ensure_docker_model_runner
    fi
    if [ "${#RUNTIME_COMPOSE_SIDECARS[@]}" -gt 0 ]; then
        remove_stale_runtime_containers_for_services context-engine-model "${RUNTIME_COMPOSE_SIDECARS[@]}"
        ensure_docker_model_runner
        if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
            mn_run_runtime_compose pull membrane-context-engine
        fi
    fi
}

function start_runtime_compose_sidecars() {
    prepare_runtime_compose_sidecars
    if [ "${#RUNTIME_COMPOSE_SIDECARS[@]}" -gt 0 ]; then
        mn_run_runtime_compose up -d --no-build "${RUNTIME_COMPOSE_SIDECARS[@]}"
    fi
    if [ "$INSTALL_OPENSHELL" = "Y" ]; then
        reconcile_openshell_gateway_bind_host "${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
        wait_for_openshell_worker_service
    fi
}

function shell_escape_value() {
    printf '%q' "$1"
}

function profile_has_bin_path() {
    local profile="$1"
    [ -f "$profile" ] || return 1
    local line
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" == *'PATH'* && "$line" == *'$MN_HOME/bin'* ]]; then
            return 0
        fi
    done < "$profile"
    return 1
}

function profile_has_runtime_home() {
    local profile="$1"
    [ -f "$profile" ] || return 1
    local line
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?MN_HOME= ]]; then
            return 0
        fi
    done < "$profile"
    return 1
}

function ensure_shell_profile_exports() {
    local needs_path="N"
    local needs_runtime_home="Y"
    local default_home="${HOME}/.mn"
    local shell_profile
    local profile_updated="N"

    [[ ":$PATH:" != *":$BIN_DIR:"* ]] && needs_path="Y"

    if [ "$needs_path" = "N" ] && [ "$needs_runtime_home" = "N" ]; then
        return
    fi

    if [ "$needs_path" = "Y" ]; then
        print_warning "${BIN_DIR} is not in your PATH."
    fi
    if [ "$needs_runtime_home" = "Y" ]; then
        print_detail "Persisting MN_HOME=${INSTALL_DIR} for future terminal sessions."
    fi

    shell_profile="$(mn_preferred_shell_profile)"
    local detected_profiles=("$shell_profile")

    local profile path_line home_line wrote_header wrote_profile
    if [ "$INSTALL_DIR" = "$default_home" ]; then
        home_line='export MN_HOME="$HOME/.mn"'
    else
        home_line="export MN_HOME=$(shell_escape_value "$INSTALL_DIR")"
    fi
    path_line='export PATH="$MN_HOME/bin:$PATH"'

    for profile in "${detected_profiles[@]}"; do
        wrote_header="N"
        wrote_profile="N"
        mn_deduplicate_generated_profile_exports "$profile" "$path_line" "$home_line"
        if [ "$needs_runtime_home" = "Y" ] && ! profile_has_runtime_home "$profile"; then
            [ "$wrote_header" = "N" ] && echo "" >> "$profile" && echo "# MN and OTTERDESK" >> "$profile" && wrote_header="Y"
            echo "$home_line" >> "$profile"
            wrote_profile="Y"
        fi
        if [ "$needs_path" = "Y" ] && ! profile_has_bin_path "$profile"; then
            [ "$wrote_header" = "N" ] && echo "" >> "$profile" && echo "# MN and OTTERDESK" >> "$profile" && wrote_header="Y"
            echo "$path_line" >> "$profile"
            wrote_profile="Y"
        fi
        if [ "$wrote_profile" = "Y" ]; then
            print_detail "Updated shell exports: ${profile}"
            profile_updated="Y"
        fi
    done

    if [ "$needs_path" = "Y" ]; then
        export PATH="${BIN_DIR}:${PATH}"
    fi
    if [ "$needs_path" = "Y" ] || [ "$profile_updated" = "Y" ]; then
        MN_SHELL_PROFILE_RELOAD_REQUIRED="Y"
        MN_SHELL_PROFILE_PATH="$shell_profile"
        print_warning "Open a new terminal, or run: source $(shell_escape_value "$shell_profile")"
    fi
}

print_header

require_install_dir_not_source
require_dir "$CORE_DIR" "MirrorNeuron core"
require_file "$CORE_DIR/Dockerfile" "MirrorNeuron Dockerfile"
require_mix_project_file "$CORE_DIR/mix.exs"
require_dir "$CLI_DIR" "mn-cli"
require_dir "$API_DIR" "mn-api"
require_dir "$PY_SDK_DIR" "mn-python-sdk"
require_file \
    "$JOB_RESPONSE_SKILL_DIR/pyproject.toml" \
    "mn-skills Job response skill project"
require_file \
    "$MCP_CLIENT_SKILL_DIR/pyproject.toml" \
    "mn-skills MCP client skill project"
require_file "$RAG_SKILL_DIR/pyproject.toml" "mn-skills RAG skill project"
require_file "$WEB_UI_SKILL_DIR/pyproject.toml" "mn-skills Web UI skill project"

if [ "$INSTALL_WEB_UI" = "Y" ]; then require_dir "$WEB_UI_DIR" "mn-web-ui"; fi
if [ "$INSTALL_SKILLS" = "Y" ]; then require_dir "$SKILLS_DIR" "mn-skills"; fi

print_step "Checking Python runtime"
resolve_python_runtime

if [ "$MN_INSTALL_RESET" != "Y" ] &&
   { [ -d "$INSTALL_DIR" ] || [ -L "$INSTALL_DIR" ] || [ -d "$VENV_DIR" ] || [ -f "$BIN_DIR/mn" ]; }; then
    print_warning "MirrorNeuron appears to be already installed; refreshing local source install."
fi

if [ "$NON_INTERACTIVE" != "Y" ]; then
    INSTALL_WEB_UI=$(ask "Install/build local Web UI?" "$INSTALL_WEB_UI")
    INSTALL_REDIS=$(ask "Install/start Redis via Docker?" "$INSTALL_REDIS")
    INSTALL_CONTEXT_ENGINE=$(ask "Install/start Membrane context engine?" "$INSTALL_CONTEXT_ENGINE")
    INSTALL_SKILLS=$(ask "Install local mn-skills packages in editable mode?" "$INSTALL_SKILLS")
    INSTALL_OPENSHELL=$(ask "Install/start OpenShell gateway for sandbox workers?" "$INSTALL_OPENSHELL")
    START_NOW=$(ask "Start MirrorNeuron server automatically after install?" "$START_NOW")
fi
echo "" >&3

print_step "Checking dependencies"
require_cmd docker
resolve_python_runtime

if [ "$INSTALL_OPENSHELL" = "Y" ] && ! command -v openshell >/dev/null 2>&1; then
    require_cmd curl
fi
if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
    require_dir "$MEMBRANE_DIR" "Membrane context engine"
    require_file "$MEMBRANE_DIR/Dockerfile" "Membrane Dockerfile"
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
if [ -d "$MEMBRANE_DIR" ]; then replace_symlink "$MEMBRANE_DIR" "$INSTALL_DIR/Membrane"; fi
replace_symlink "$CORE_DIR" "$INSTALL_DIR/core-source"
replace_symlink "$CLI_DIR" "$INSTALL_DIR/cli-source"
replace_symlink "$API_DIR" "$INSTALL_DIR/api-source"
replace_symlink "$PY_SDK_DIR" "$INSTALL_DIR/python-sdk-source"
write_local_install_metadata
print_step "Writing Docker Compose runtime configuration"
write_runtime_compose_files
print_detail "Local component links: ${INSTALL_DIR}"

print_step "Building MirrorNeuron Core Docker image from local source"
(
    cd "$CORE_DIR"
    DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-1}" mn_run_docker_build -t mirror-neuron-core:latest .
)
print_detail "Built local core image: mirror-neuron-core:latest"

function require_local_cli_target_executables() {
    local missing="N"
    if [ ! -x "$VENV_DIR/bin/mn" ]; then
        print_error "Expected executable mn CLI target was not created: $VENV_DIR/bin/mn"
        missing="Y"
    fi
    if [ ! -x "$VENV_DIR/bin/mn-api" ]; then
        print_error "Expected executable mn-api target was not created: $VENV_DIR/bin/mn-api"
        missing="Y"
    fi
    if [ "$missing" = "Y" ]; then
        print_error "Local Python install did not produce the required command targets; leaving command symlinks unchanged."
        exit 1
    fi
}

function install_local_editable_python_packages() {
    local -a editable_requirements=(
        -e "$PY_SDK_DIR"
    )
    local skill_dir
    local skill_pyproject

    if [ -f "$BLUEPRINT_SUPPORT_SKILL_DIR/pyproject.toml" ]; then
        editable_requirements+=(-e "$BLUEPRINT_SUPPORT_SKILL_DIR")
    fi
    editable_requirements+=(
        -e "$JOB_RESPONSE_SKILL_DIR"
        -e "$MCP_CLIENT_SKILL_DIR"
        -e "$RAG_SKILL_DIR"
        -e "$WEB_UI_SKILL_DIR"
        -e "$CLI_DIR"
        -e "$API_DIR"
    )
    if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
        editable_requirements+=(-e "$MEMBRANE_DIR/mn-context-engine-python-sdk")
    fi

    if [ "$INSTALL_SKILLS" = "Y" ]; then
        shopt -s nullglob
        for skill_pyproject in "$SKILLS_DIR"/*/pyproject.toml; do
            skill_dir="$(dirname "$skill_pyproject")"
            case "$skill_dir" in
                "$BLUEPRINT_SUPPORT_SKILL_DIR"|"$JOB_RESPONSE_SKILL_DIR"|"$MCP_CLIENT_SKILL_DIR"|"$RAG_SKILL_DIR"|"$WEB_UI_SKILL_DIR") continue ;;
            esac
            editable_requirements+=(-e "$skill_dir")
        done
    fi

    # Resolve all selected workspace projects together so dependencies between
    # unreleased MirrorNeuron packages use their sibling editable checkouts.
    "$VENV_DIR/bin/pip" install "${editable_requirements[@]}" >/dev/null
}

VENV_BACKUP_DIR=""
VENV_INSTALL_OK="N"
function restore_local_venv_backup_on_failure() {
    if [ "$VENV_INSTALL_OK" = "Y" ]; then
        if [ -n "$VENV_BACKUP_DIR" ]; then
            rm -rf "$VENV_BACKUP_DIR"
        fi
        return
    fi

    rm -rf "$VENV_DIR"
    if [ -n "$VENV_BACKUP_DIR" ] && { [ -e "$VENV_BACKUP_DIR" ] || [ -L "$VENV_BACKUP_DIR" ]; }; then
        mv "$VENV_BACKUP_DIR" "$VENV_DIR"
        print_error "Local Python install failed; restored the previous virtual environment at $VENV_DIR."
    fi
}

if [ -e "$VENV_DIR" ] || [ -L "$VENV_DIR" ]; then
    VENV_BACKUP_DIR="${VENV_DIR}.backup.$$"
    rm -rf "$VENV_BACKUP_DIR"
    mv "$VENV_DIR" "$VENV_BACKUP_DIR"
fi
trap restore_local_venv_backup_on_failure EXIT

print_step "Installing Python components from local source"
(
    "$MN_PYTHON_BIN" -m venv "$VENV_DIR" >/dev/null
    "$VENV_DIR/bin/pip" install --upgrade pip >/dev/null
    install_local_editable_python_packages
) &
spinner $! "Installed local editable Python packages"
require_local_cli_target_executables
VENV_INSTALL_OK="Y"
if [ -n "$VENV_BACKUP_DIR" ]; then
    rm -rf "$VENV_BACKUP_DIR"
fi
trap - EXIT

if [ "$INSTALL_WEB_UI" = "Y" ]; then
    print_step "Preparing local Web UI source for Docker Compose"
    if [ -e "$UI_LINK_DIR" ] || [ -L "$UI_LINK_DIR" ]; then
        rm -rf "$UI_LINK_DIR"
    fi
    replace_symlink "$WEB_UI_DIR" "$UI_LINK_DIR"
    replace_symlink "$WEB_UI_DIR" "$INSTALL_DIR/web-ui-source"
fi

if [ "$INSTALL_REDIS" = "Y" ] || [ "$INSTALL_CONTEXT_ENGINE" = "Y" ] || [ "$INSTALL_OPENSHELL" = "Y" ] || [ "$INSTALL_WEB_UI" = "Y" ]; then
    if [ "$INSTALL_OPENSHELL" = "Y" ]; then
        install_openshell_cli
    fi
    if [ "$START_NOW" = "Y" ]; then
        prepare_runtime_compose_sidecars
        print_detail "Docker services are prepared; automatic startup is deferred to mn runtime start."
    else
        print_step "Starting selected Docker runtime services"
        start_runtime_compose_sidecars
        print_success "Selected Docker runtime services are available."
    fi
fi

if [ "$CORE_WAS_RUNNING" = "Y" ] && [ "$START_NOW" != "Y" ]; then
    print_step "Restarting MirrorNeuron gRPC Core from rebuilt image"
    (
        restart_core_container
    ) &
    spinner $! "Restarted MirrorNeuron gRPC Core"
fi

print_step "Creating command symlinks"
require_local_cli_target_executables
rm -f "$BIN_DIR/mn" "$BIN_DIR/mn-api" "$INSTALL_DIR/mn"
replace_symlink "$VENV_DIR/bin/mn" "$BIN_DIR/mn"
replace_symlink "$VENV_DIR/bin/mn-api" "$BIN_DIR/mn-api"
replace_symlink "$VENV_DIR/bin/mn" "$INSTALL_DIR/mn"
print_detail "Command links: ${BIN_DIR}"

ensure_shell_profile_exports

if [ "$START_NOW" = "Y" ]; then
    print_step "Starting MirrorNeuron services"
    "$VENV_DIR/bin/mn" runtime stop >/dev/null 2>&1 || true
    if ! mn_run_runtime_start_command "$VENV_DIR/bin/mn" runtime start; then
        [ -n "$MN_RUNTIME_START_LOG" ] && print_warning "CLI startup details: $MN_RUNTIME_START_LOG"
        print_warning "mn runtime start failed; starting MirrorNeuron Docker Compose runtime."
        mn_run_runtime_compose up -d --no-build
        "$VENV_DIR/bin/mn" runtime restart-sidecars --api >/dev/null 2>&1 || print_warning "MirrorNeuron Core started, but the REST API sidecar did not start automatically."
    fi
    if [ "$INSTALL_OPENSHELL" = "Y" ]; then
        reconcile_openshell_gateway_bind_host "${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
        wait_for_openshell_worker_service
    fi
    print_success "MirrorNeuron services are running."
fi

echo "" >&3
print_success "MirrorNeuron installation completed."
print_detail "Core image: mirror-neuron-core:latest (${CORE_DIR})"
print_detail "CLI/API: editable installs from the local workspace"
print_detail "State: ${INSTALL_DIR}"
print_detail "Cookie: ${INSTALL_DIR}/erlang.cookie"
if [ "$INSTALL_WEB_UI" = "Y" ]; then
    print_detail "Web UI source: ${WEB_UI_DIR} (built inside Docker Compose)"
fi
if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
    print_detail "Membrane: ${MEMBRANE_DIR} (${MN_CONTEXT_ADDR:-localhost:50052})"
fi
print_detail "Rebuild after Elixir changes: ${SCRIPT_DIR}/install.sh --mode local --no-web-ui --no-skills"

if [ "$START_NOW" = "Y" ]; then
    mn_print_next_shell_command "mn node list"
else
    mn_print_next_shell_command "mn runtime start"
fi
if [ "$MN_INSTALL_VERBOSE" = "Y" ]; then
    mn_print_cli_verification_prompt
fi
}

run_install_binary() {
#!/usr/bin/env bash

set -euo pipefail

# Keep installer output visible even when a subcommand redirects stdout/stderr.
exec 3>&1

# Never let pip block the installer by asking for input.
export PIP_NO_INPUT="${PIP_NO_INPUT:-1}"

if [ -t 3 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    ESC="$(printf '\033')"
    BOLD="${ESC}[1m"
    DIM="${ESC}[2m"
    RED="${ESC}[31m"
    GREEN="${ESC}[32m"
    YELLOW="${ESC}[33m"
    BLUE="${ESC}[34m"
    CYAN="${ESC}[36m"
    MAGENTA="${ESC}[35m"
    RESET="${ESC}[0m"
else
    BOLD=""
    DIM=""
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    CYAN=""
    MAGENTA=""
    RESET=""
fi

SCRIPT_DIR="$(mn_script_dir)"
INSTALL_DIR="${MN_HOME:-${HOME}/.mn}"
BIN_DIR="${INSTALL_DIR}/bin"
VENV_DIR="${HOME}/.local/share/mn_venv"
MN_WEB_UI_SOURCE_MODE="${MN_WEB_UI_SOURCE_MODE:-package}"
MN_WEB_UI_SOURCE_MOUNT="${MN_WEB_UI_SOURCE_MOUNT:-${INSTALL_DIR}/web-ui-source}"
MN_WEB_UI_PACKAGE_VERSION="${MN_WEB_UI_PACKAGE_VERSION:-}"
RUNTIME_COMPOSE_TEMPLATE="${MN_RUNTIME_COMPOSE_TEMPLATE:-}"
RUNTIME_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
RUNTIME_COMPOSE_ENV="${INSTALL_DIR}/docker-compose.env"
CORE_REPO="${MN_CORE_REPO:-MirrorNeuronLab/MirrorNeuron}"
INSTALL_VERSION="${MN_INSTALL_VERSION:-}"
INSTALL_VERSION_EXPLICIT="N"
[ -n "$INSTALL_VERSION" ] && INSTALL_VERSION_EXPLICIT="Y"
CORE_RELEASE_TAG=""
CORE_INSTALL_VERSION="${MN_CORE_VERSION:-}"
PYTHON_SDK_INSTALL_VERSION="${MN_PYTHON_SDK_VERSION:-}"
CLI_INSTALL_VERSION="${MN_CLI_VERSION:-}"
API_INSTALL_VERSION="${MN_API_VERSION:-}"
WEB_UI_INSTALL_VERSION="${MN_WEB_UI_VERSION:-}"
DEFAULT_PYTHON_SDK_INSTALL_VERSION="${MN_DEFAULT_PYTHON_SDK_VERSION:-v1.2.31}"
DEFAULT_CLI_INSTALL_VERSION="${MN_DEFAULT_CLI_VERSION:-v1.2.32}"
DEFAULT_API_INSTALL_VERSION="${MN_DEFAULT_API_VERSION:-v1.2.31}"
DEFAULT_WEB_UI_INSTALL_VERSION="${MN_DEFAULT_WEB_UI_VERSION:-v1.2.31}"
CORE_IMAGE="${MN_CORE_IMAGE:-}"
CORE_GAR_PROJECT="${MN_CORE_GAR_PROJECT:-mirrorneuron-public-packages}"
CORE_GAR_LOCATION="${MN_CORE_GAR_LOCATION:-us-central1}"
CORE_GAR_DOCKER_REPOSITORY="${MN_CORE_GAR_DOCKER_REPOSITORY:-mirrorneuron-runtime}"
CORE_GAR_DOCKER_IMAGE_NAME="${MN_CORE_GAR_DOCKER_IMAGE_NAME:-mirror-neuron-core}"
MN_PACKAGE_VERSION=""
MN_PYTHON_SDK_PACKAGE_VERSION=""
MN_CLI_PACKAGE_VERSION=""
MN_API_PACKAGE_VERSION=""
MEMBRANE_DIR="${MN_MEMBRANE_DIR:-${INSTALL_DIR}/Membrane}"
MN_AGENTS_ROOT="${MN_AGENTS_ROOT:-}"
PACKAGE_INDEX_FILE="${MN_PACKAGE_INDEX_FILE:-}"
MN_GAR_PROJECT="${MN_GAR_PROJECT:-}"
MN_GAR_LOCATION="${MN_GAR_LOCATION:-us-central1}"
MN_GAR_REPOSITORY="${MN_GAR_REPOSITORY:-agent-skills}"
MN_DEFAULT_PIP_INDEX_URL="${MN_DEFAULT_PIP_INDEX_URL:-https://us-central1-python.pkg.dev/mirrorneuron-public-packages/agent-skills/simple/}"
MN_PIP_INDEX_URL="${MN_PIP_INDEX_URL:-${MN_PYTHON_INDEX_URL:-}}"
MN_PIP_EXTRA_INDEX_URL="${MN_PIP_EXTRA_INDEX_URL:-${MN_PYTHON_EXTRA_INDEX_URL:-https://pypi.org/simple}}"
MN_HOST_HOME_DIR="${MN_HOST_HOME_DIR:-${MN_HOST_MN_DIR:-${INSTALL_DIR}}}"
MN_HOST_ARTIFACTS_DIR="${MN_HOST_ARTIFACTS_DIR:-${MN_HOST_HOME_DIR}/runs}"
MN_HOST_BLOB_STORE_DIR="${MN_HOST_BLOB_STORE_DIR:-${MN_HOST_HOME_DIR}/blobs}"
MN_HOST_SHARED_STORAGE_ROOT="${MN_HOST_SHARED_STORAGE_ROOT:-${MN_HOST_SHARED_ARTIFACT_ROOT:-${MN_HOST_HOME_DIR}/shared}}"
MN_SYNCTHING_ENABLED="${MN_SYNCTHING_ENABLED:-auto}"
MN_SYNCTHING_IMAGE="${MN_SYNCTHING_IMAGE:-syncthing/syncthing:latest}"
MN_SYNCTHING_GUI_PORT="${MN_SYNCTHING_GUI_PORT:-58384}"
MN_SYNCTHING_SYNC_PORT="${MN_SYNCTHING_SYNC_PORT:-22000}"
MN_SYNCTHING_RESCAN_INTERVAL_SECONDS="${MN_SYNCTHING_RESCAN_INTERVAL_SECONDS:-3600}"
MN_BLUEPRINT_PYTHON_ENVS_DIR="${MN_BLUEPRINT_PYTHON_ENVS_DIR:-}"
MN_HOST_OPENSHELL_CONFIG_DIR="${OPENSHELL_CONTAINER_CONFIG_DIR:-${HOME}/.config/openshell-mirror-neuron}"
MN_HOST_OPENSHELL_STATE_DIR="${MN_HOST_OPENSHELL_STATE_DIR:-${INSTALL_DIR}/openshell-state}"
OPENSHELL_GATEWAY_USER="${OPENSHELL_GATEWAY_USER:-$(id -u):$(id -g)}"
mn_print_docker_desktop_permission_notice
DOCKER_HOST_SOCKET="${DOCKER_HOST_SOCKET:-$(mn_resolve_docker_host_socket)}"
if [ -z "${OPENSHELL_GATEWAY_DOCKER_GROUP:-}" ] && [ "$(uname -s)" = "Darwin" ]; then
    OPENSHELL_GATEWAY_DOCKER_GROUP="0"
elif [ -z "${OPENSHELL_GATEWAY_DOCKER_GROUP:-}" ] && [ -S "${DOCKER_HOST_SOCKET}" ]; then
    OPENSHELL_GATEWAY_DOCKER_GROUP="$(stat -c '%g' "${DOCKER_HOST_SOCKET}" 2>/dev/null || stat -f '%g' "${DOCKER_HOST_SOCKET}" 2>/dev/null || true)"
fi
OPENSHELL_GATEWAY_DOCKER_GROUP="${OPENSHELL_GATEWAY_DOCKER_GROUP:-0}"
MN_DYNAMIC_REDIS_PORT_START="${MN_DYNAMIC_REDIS_PORT_START:-56379}"
MN_DYNAMIC_REDIS_PORT_END="${MN_DYNAMIC_REDIS_PORT_END:-56478}"
INSTALL_METADATA_FILE="${INSTALL_DIR}/install_metadata.json"
MN_MANAGED_PYTHON="${MN_MANAGED_PYTHON:-1}"
MN_MANAGED_PYTHON_VERSION="${MN_MANAGED_PYTHON_VERSION:-3.11}"
MN_MANAGED_PYTHON_ROOT="${MN_MANAGED_PYTHON_DIR:-${HOME}/.local/share/mn_python}"
MN_UV_ROOT="${MN_UV_DIR:-${HOME}/.local/share/mn_uv}"
MN_UV_BIN=""
MN_PYTHON_BIN=""

INSTALL_WEB_UI="Y"
INSTALL_REDIS="Y"
INSTALL_CONTEXT_ENGINE="N"
INSTALL_OPENSHELL="Y"
INSTALL_PYTHON_SDK="Y"
INSTALL_AGENTS="Y"
INSTALL_CLI="Y"
INSTALL_API="Y"
START_NOW="Y"
REINSTALL="Y"
NON_INTERACTIVE="Y"

function print_header() {
    printf '\n%s%s%s\n' "${BLUE}${BOLD}" "MirrorNeuron Installer" "$RESET" >&3
    printf '  Release: %s\n' "$CORE_INSTALL_VERSION" >&3
    print_detail "SDK ${PYTHON_SDK_INSTALL_VERSION}; CLI ${CLI_INSTALL_VERSION}; API ${API_INSTALL_VERSION}; Web UI ${WEB_UI_INSTALL_VERSION}"
}

function print_step() { printf '%s==>%s %s\n' "${CYAN}${BOLD}" "$RESET" "$1" >&3; }
function print_success() { printf '%s✔%s %s\n' "${GREEN}${BOLD}" "$RESET" "$1" >&3; }
function print_error() { printf '%serror:%s %s\n' "${RED}${BOLD}" "$RESET" "$1" >&3; }
function print_warning() { printf '%swarning:%s %s\n' "${YELLOW}${BOLD}" "$RESET" "$1" >&3; }
function print_detail() {
    if [ "$MN_INSTALL_VERBOSE" = "Y" ]; then
        printf '    %s\n' "$1" >&3
    fi
}

function usage() {
    local script_name="${MN_INSTALL_SCRIPT_NAME:-$(basename "$0")}"
    cat >&3 <<EOF
Usage: ./$script_name [options]

Installs MirrorNeuron from released artifacts and packages. Use through --mode binary.

Options:
  --version TAG                 Install this release version. Default: ${MN_DEFAULT_INSTALL_VERSION}.
  --yes                         Run non-interactively with defaults and flags. This is the default.
  --interactive                 Ask each install question before proceeding.
  --reset                       Permanently clear runtime data first; requires typing YES.
  -v, --verbose                 Show installation details and command paths.
  --no-reinstall                Keep an existing install instead of overwriting it.
  --web-ui / --no-web-ui        Enable or skip the Web UI Compose service.
  --redis / --no-redis          Enable or skip Redis Docker setup.
  --context-engine / --no-context-engine
                                Enable or skip Membrane context engine setup.
  --openshell / --no-openshell  Enable or skip OpenShell gateway setup.
  --syncthing / --no-syncthing  Enable or skip Syncthing shared-storage replication.
  --start / --no-start          Start or skip starting MirrorNeuron after install.

Python component options:
  --python-components LIST      Install only these components: sdk,agents,cli,api.
                                Use all or none as shortcuts.
  --python-sdk / --no-python-sdk
  --agents / --no-agents        Install or skip indexed agent packages from the configured pip index.
  --cli / --no-cli
  --api / --no-api

Release/source options:
  --version TAG                 Set the common default release for all components.
  --core-version TAG            Pin MirrorNeuron core. Env: MN_CORE_VERSION.
  --python-sdk-version TAG      Pin mirrorneuron-python-sdk. Env: MN_PYTHON_SDK_VERSION.
  --cli-version TAG             Pin mirrorneuron-cli. Env: MN_CLI_VERSION.
  --api-version TAG             Pin mirrorneuron-api. Env: MN_API_VERSION.
  --web-ui-version TAG          Pin mirrorneuron-web-ui. Env: MN_WEB_UI_VERSION.
  --gar-project PROJECT         Same as MN_GAR_PROJECT. Overrides the default public package index.
  --gar-location LOCATION       Same as MN_GAR_LOCATION. Default: us-central1.
  --gar-repository NAME         Same as MN_GAR_REPOSITORY. Default: agent-skills.
  --python-index-url URL        Same as MN_PIP_INDEX_URL. Default: ${MN_DEFAULT_PIP_INDEX_URL}
  --python-extra-index-url URL  Same as MN_PIP_EXTRA_INDEX_URL. Default: https://pypi.org/simple.
  --python PATH                 Same as MN_PYTHON. Must be Python 3.11+.
  --no-managed-python           Do not use uv to install a private Python runtime.
  MN_HOME=/path                 Override the runtime state directory. Defaults to ${HOME}/.mn.
  MN_AGENTS_ROOT=/path          Optional local development override for packaged agent discovery.
  -h, --help                    Show this help.

Examples:
  ./$script_name --no-web-ui
  ./$script_name --version v1.2.31
  ./$script_name --interactive
  ./$script_name --no-web-ui --python-components sdk,api
  ./$script_name --gar-project my-gcp-project --gar-repository agent-skills
  ./$script_name --python-index-url https://us-central1-python.pkg.dev/my-gcp-project/agent-skills/simple/
  MN_PYTHON=/opt/homebrew/bin/python3.11 ./$script_name
  ./$script_name --version v1.2.31 --no-web-ui
  ./$script_name --core-version v1.2.31 --python-sdk-version v1.2.31 --cli-version v1.2.31 --api-version v1.2.31 --web-ui-version v1.2.31
EOF
}

function set_python_components() {
    local value="$1"
    local component
    local -a components

    INSTALL_PYTHON_SDK="N"
    INSTALL_AGENTS="N"
    INSTALL_CLI="N"
    INSTALL_API="N"

    IFS=',' read -r -a components <<< "$value"
    for component in "${components[@]}"; do
        component="$(echo "$component" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
        case "$component" in
            all)
                INSTALL_PYTHON_SDK="Y"
                INSTALL_AGENTS="Y"
                INSTALL_CLI="Y"
                INSTALL_API="Y"
                ;;
            agent|agents)
                INSTALL_AGENTS="Y"
                ;;
            none)
                ;;
            sdk|python-sdk)
                INSTALL_PYTHON_SDK="Y"
                ;;
            cli)
                INSTALL_CLI="Y"
                ;;
            api)
                INSTALL_API="Y"
                ;;
            "")
                ;;
            *)
                print_error "Unknown Python component: $component"
                usage
                exit 1
                ;;
        esac
    done
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes|-y) NON_INTERACTIVE="Y" ;;
        --interactive) NON_INTERACTIVE="N" ;;
        --no-reinstall) REINSTALL="N" ;;
        --web-ui) INSTALL_WEB_UI="Y" ;;
        --no-web-ui) INSTALL_WEB_UI="N" ;;
        --redis) INSTALL_REDIS="Y" ;;
        --no-redis) INSTALL_REDIS="N" ;;
        --context-engine) INSTALL_CONTEXT_ENGINE="Y" ;;
        --no-context-engine) INSTALL_CONTEXT_ENGINE="N" ;;
        --openshell) INSTALL_OPENSHELL="Y" ;;
        --no-openshell) INSTALL_OPENSHELL="N" ;;
        --syncthing) MN_SYNCTHING_ENABLED="auto" ;;
        --no-syncthing) MN_SYNCTHING_ENABLED="0" ;;
        --start) START_NOW="Y" ;;
        --no-start) START_NOW="N" ;;
        --python-sdk) INSTALL_PYTHON_SDK="Y" ;;
        --no-python-sdk) INSTALL_PYTHON_SDK="N" ;;
        --agents) INSTALL_AGENTS="Y" ;;
        --no-agents) INSTALL_AGENTS="N" ;;
        --cli) INSTALL_CLI="Y" ;;
        --no-cli) INSTALL_CLI="N" ;;
        --api) INSTALL_API="Y" ;;
        --no-api) INSTALL_API="N" ;;
        --version)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--version requires a release tag such as v1.2.31."
                usage
                exit 1
            fi
            INSTALL_VERSION="$1"
            INSTALL_VERSION_EXPLICIT="Y"
            ;;
        --version=*)
            INSTALL_VERSION="${1#*=}"
            INSTALL_VERSION_EXPLICIT="Y"
            ;;
        --core-version)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--core-version requires a release tag such as v1.2.31."
                usage
                exit 1
            fi
            CORE_INSTALL_VERSION="$1"
            ;;
        --core-version=*)
            CORE_INSTALL_VERSION="${1#*=}"
            ;;
        --python-sdk-version)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--python-sdk-version requires a release tag such as v1.2.31."
                usage
                exit 1
            fi
            PYTHON_SDK_INSTALL_VERSION="$1"
            ;;
        --python-sdk-version=*)
            PYTHON_SDK_INSTALL_VERSION="${1#*=}"
            ;;
        --cli-version)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--cli-version requires a release tag such as v1.2.31."
                usage
                exit 1
            fi
            CLI_INSTALL_VERSION="$1"
            ;;
        --cli-version=*)
            CLI_INSTALL_VERSION="${1#*=}"
            ;;
        --api-version)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--api-version requires a release tag such as v1.2.31."
                usage
                exit 1
            fi
            API_INSTALL_VERSION="$1"
            ;;
        --api-version=*)
            API_INSTALL_VERSION="${1#*=}"
            ;;
        --web-ui-version)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--web-ui-version requires a release tag such as v1.2.31."
                usage
                exit 1
            fi
            WEB_UI_INSTALL_VERSION="$1"
            ;;
        --web-ui-version=*)
            WEB_UI_INSTALL_VERSION="${1#*=}"
            ;;
        --python-components)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--python-components requires a value."
                usage
                exit 1
            fi
            set_python_components "$1"
            ;;
        --python-components=*)
            set_python_components "${1#*=}"
            ;;
        --gar-project)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--gar-project requires a value."
                usage
                exit 1
            fi
            MN_GAR_PROJECT="$1"
            ;;
        --gar-project=*)
            MN_GAR_PROJECT="${1#*=}"
            ;;
        --gar-location)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--gar-location requires a value."
                usage
                exit 1
            fi
            MN_GAR_LOCATION="$1"
            ;;
        --gar-location=*)
            MN_GAR_LOCATION="${1#*=}"
            ;;
        --gar-repository)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--gar-repository requires a value."
                usage
                exit 1
            fi
            MN_GAR_REPOSITORY="$1"
            ;;
        --gar-repository=*)
            MN_GAR_REPOSITORY="${1#*=}"
            ;;
        --python-index-url)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--python-index-url requires a value."
                usage
                exit 1
            fi
            MN_PIP_INDEX_URL="$1"
            ;;
        --python-index-url=*)
            MN_PIP_INDEX_URL="${1#*=}"
            ;;
        --python-extra-index-url)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--python-extra-index-url requires a value."
                usage
                exit 1
            fi
            MN_PIP_EXTRA_INDEX_URL="$1"
            ;;
        --python-extra-index-url=*)
            MN_PIP_EXTRA_INDEX_URL="${1#*=}"
            ;;
        --python)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--python requires a value."
                usage
                exit 1
            fi
            MN_PYTHON="$1"
            ;;
        --python=*)
            MN_PYTHON="${1#*=}"
            ;;
        --no-managed-python)
            MN_MANAGED_PYTHON=0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

function finalize_binary_install_version() {
    if [ -z "$INSTALL_VERSION" ] && [ -n "$CORE_INSTALL_VERSION" ]; then
        INSTALL_VERSION="$CORE_INSTALL_VERSION"
    fi
    INSTALL_VERSION="${INSTALL_VERSION:-$MN_DEFAULT_INSTALL_VERSION}"
    mn_validate_version_tag_or_exit "$INSTALL_VERSION"
    CORE_INSTALL_VERSION="${CORE_INSTALL_VERSION:-$INSTALL_VERSION}"
    if [ "$INSTALL_VERSION_EXPLICIT" = "Y" ]; then
        PYTHON_SDK_INSTALL_VERSION="${PYTHON_SDK_INSTALL_VERSION:-$INSTALL_VERSION}"
        CLI_INSTALL_VERSION="${CLI_INSTALL_VERSION:-$INSTALL_VERSION}"
        API_INSTALL_VERSION="${API_INSTALL_VERSION:-$INSTALL_VERSION}"
        WEB_UI_INSTALL_VERSION="${WEB_UI_INSTALL_VERSION:-$INSTALL_VERSION}"
    else
        PYTHON_SDK_INSTALL_VERSION="${PYTHON_SDK_INSTALL_VERSION:-$DEFAULT_PYTHON_SDK_INSTALL_VERSION}"
        CLI_INSTALL_VERSION="${CLI_INSTALL_VERSION:-$DEFAULT_CLI_INSTALL_VERSION}"
        API_INSTALL_VERSION="${API_INSTALL_VERSION:-$DEFAULT_API_INSTALL_VERSION}"
        WEB_UI_INSTALL_VERSION="${WEB_UI_INSTALL_VERSION:-$DEFAULT_WEB_UI_INSTALL_VERSION}"
    fi
    mn_validate_version_tag_or_exit "$CORE_INSTALL_VERSION"
    mn_validate_version_tag_or_exit "$PYTHON_SDK_INSTALL_VERSION"
    mn_validate_version_tag_or_exit "$CLI_INSTALL_VERSION"
    mn_validate_version_tag_or_exit "$API_INSTALL_VERSION"
    mn_validate_version_tag_or_exit "$WEB_UI_INSTALL_VERSION"
    MN_INSTALL_VERSION="$INSTALL_VERSION"
    CORE_RELEASE_TAG="$CORE_INSTALL_VERSION"
    MN_PYTHON_SDK_PACKAGE_VERSION="$(mn_package_version_from_tag "$PYTHON_SDK_INSTALL_VERSION")"
    MN_CLI_PACKAGE_VERSION="$(mn_package_version_from_tag "$CLI_INSTALL_VERSION")"
    MN_API_PACKAGE_VERSION="$(mn_package_version_from_tag "$API_INSTALL_VERSION")"
    MN_PACKAGE_VERSION="$MN_PYTHON_SDK_PACKAGE_VERSION"
    MN_WEB_UI_PACKAGE_VERSION="${MN_WEB_UI_PACKAGE_VERSION:-$(mn_web_ui_package_version_from_tag "$WEB_UI_INSTALL_VERSION")}"
    RUNTIME_COMPOSE_TEMPLATE="${RUNTIME_COMPOSE_TEMPLATE:-${SCRIPT_DIR}/install_support/${INSTALL_VERSION}/docker-compose.yml}"
    PACKAGE_INDEX_FILE="${PACKAGE_INDEX_FILE:-${SCRIPT_DIR}/install_support/${INSTALL_VERSION}/package-index/python-packages.toml}"
    export MN_INSTALL_VERSION
}

finalize_binary_install_version

function run_quiet() {
    local label="$1"
    shift
    local log_dir="${TMPDIR:-/tmp}/mirror_neuron_install"
    mkdir -p "$log_dir"
    local log_file="${log_dir}/${label//[^A-Za-z0-9_.-]/_}.$$.log"

    if ! "$@" >"$log_file" 2>&1; then
        print_error "$label failed. Details: $log_file"
        if [ "$MN_INSTALL_VERBOSE" = "Y" ]; then
            tail -n 30 "$log_file" >&3 2>/dev/null || true
        else
            printf '  Re-run with --verbose to show the last log lines.\n' >&3
        fi
        exit 1
    fi
}

function try_quiet() {
    local label="$1"
    shift
    local log_dir="${TMPDIR:-/tmp}/mirror_neuron_install"
    mkdir -p "$log_dir"
    LAST_LOG_FILE="${log_dir}/${label//[^A-Za-z0-9_.-]/_}.$$.log"

    "$@" >"$LAST_LOG_FILE" 2>&1
}

function spinner() {
    local pid=$1
    local msg=$2
    local delay=0.1
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local frame_index=0
    local interactive="N"
    if [ -t 3 ]; then
        interactive="Y"
        tput civis >&3 2>/dev/null || true
        while kill -0 "$pid" 2>/dev/null; do
            printf '\r%s%s%s %s' "${MAGENTA}${BOLD}" "${frames[$frame_index]}" "$RESET" "$msg" >&3
            frame_index=$(((frame_index + 1) % ${#frames[@]}))
            sleep "$delay"
        done
    else
        print_step "$msg"
    fi
    set +e
    wait "$pid"
    local exit_code=$?
    set -e
    if [ "$exit_code" -eq 0 ]; then
        if [ "$interactive" = "Y" ]; then printf '\r\033[2K' >&3; fi
        print_success "$msg"
    else
        if [ "$interactive" = "Y" ]; then printf '\r\033[2K' >&3; fi
        print_error "$msg failed."
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

function require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        print_error "'$1' is required but not installed."
        exit 1
    fi
}

function require_file() {
    if [ ! -f "$1" ]; then
        print_error "$2 is required but was not found at $1."
        exit 1
    fi
}

function ensure_pip() {
    if "$MN_PYTHON_BIN" -m pip --version >/dev/null 2>&1; then
        return
    fi

    print_warning "pip was not found for $MN_PYTHON_BIN; trying ensurepip."
    "$MN_PYTHON_BIN" -m ensurepip --upgrade >/dev/null 2>&1 || {
        print_error "Could not install pip with ensurepip. Please install pip for $MN_PYTHON_BIN and rerun."
        exit 1
    }
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

function python_is_selected_minor() {
    [ "$(python_minor_version "$1" || true)" = "$MN_MANAGED_PYTHON_VERSION" ]
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

    print_detail "Installed uv at $MN_UV_BIN."
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
    print_warning "No Python ${MN_MANAGED_PYTHON_VERSION}.x interpreter was found; uv will manage a private runtime under ${MN_MANAGED_PYTHON_ROOT}."
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
    print_detail "Using uv-managed Python $(python_version "$managed_bin") at $managed_bin."
}

function print_python_requirement_error() {
    local selected="${1:-}"
    local script_name="${MN_INSTALL_SCRIPT_NAME:-$(basename "$0")}"
    local version=""

    print_error "MirrorNeuron Python components require Python ${MN_MANAGED_PYTHON_VERSION}.x by default."
    if [ -n "$selected" ]; then
        version="$(python_version "$selected" || true)"
        if [ -n "$version" ]; then
            print_error "Selected Python '$selected' is version $version."
        else
            print_error "Selected Python '$selected' could not be run."
        fi
    fi
    print_error "Install Python ${MN_MANAGED_PYTHON_VERSION}.x yourself, or allow the uv-managed private runtime fallback."
    print_error "You can also rerun with: MN_PYTHON=/opt/homebrew/bin/python${MN_MANAGED_PYTHON_VERSION} ./$script_name"
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
        candidates+=("python${MN_MANAGED_PYTHON_VERSION}" python3 python)
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
        if python_is_supported "$resolved" && python_is_selected_minor "$resolved"; then
            MN_PYTHON_BIN="$resolved"
            print_detail "Using Python $(python_version "$MN_PYTHON_BIN") at $MN_PYTHON_BIN."
            return
        fi
        if [ -n "${MN_PYTHON:-}" ]; then
            print_python_requirement_error "$resolved"
            exit 1
        fi
    done

    if managed_python_enabled; then
        install_managed_python
        print_detail "Using Python $(python_version "$MN_PYTHON_BIN") at $MN_PYTHON_BIN."
        return
    fi

    print_warning "Managed Python fallback is disabled."
    resolved="$(command -v "python${MN_MANAGED_PYTHON_VERSION}" 2>/dev/null || true)"
    print_python_requirement_error "$resolved"
    exit 1
}

function should_install_python_packages() {
    [ "$INSTALL_PYTHON_SDK" = "Y" ] || \
    [ "$INSTALL_AGENTS" = "Y" ] || \
    [ "$INSTALL_CLI" = "Y" ] || \
    [ "$INSTALL_API" = "Y" ] || \
    [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]
}

function validate_selections() {
    if [ "$START_NOW" = "Y" ] && [ "$INSTALL_CLI" != "Y" ]; then
        print_warning "Automatic start requires the CLI package; disabling start."
        START_NOW="N"
    fi

    if [ "$INSTALL_WEB_UI" = "Y" ] && [ "$INSTALL_API" != "Y" ]; then
        print_warning "Installing Web UI without the API package. The UI will need an API service from another install."
    fi
}

function core_gar_image_for_tag() {
    local tag="$1"

    if [ -n "$CORE_IMAGE" ]; then
        printf '%s' "$CORE_IMAGE"
        return
    fi

    printf '%s-docker.pkg.dev/%s/%s/%s:%s' \
        "$CORE_GAR_LOCATION" \
        "$CORE_GAR_PROJECT" \
        "$CORE_GAR_DOCKER_REPOSITORY" \
        "$CORE_GAR_DOCKER_IMAGE_NAME" \
        "$tag"
}

function install_core_from_gar() {
    local tag image image_version image_revision image_digest

    tag="$CORE_RELEASE_TAG"
    image="$(core_gar_image_for_tag "$tag")"
    print_detail "Pulling Core GAR image $image."

    if ! docker pull "$image"; then
        print_error "Could not pull the required Core GAR image: $image"
        print_error "Binary installs require this immutable Core image. Verify the release image is published and public, then retry."
        exit 1
    fi

    image_version="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$image" 2>/dev/null || true)"
    image_revision="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$image" 2>/dev/null || true)"
    image_digest="$(docker image inspect --format '{{ index .RepoDigests 0 }}' "$image" 2>/dev/null || true)"
    image_digest="${image_digest##*@}"

    if [ "$image_version" != "$tag" ]; then
        print_error "Core GAR image version label mismatch: expected $tag, got ${image_version:-missing}."
        exit 1
    fi
    if [[ ! "$image_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        print_error "Core GAR image did not expose a valid manifest digest: ${image_digest:-missing}."
        exit 1
    fi

    docker image tag "$image" mirror-neuron-core:latest
    mn_remove_path_or_exit "$INSTALL_DIR" "MirrorNeuron state directory"
    mkdir -p "$INSTALL_DIR"
    cat > "$INSTALL_METADATA_FILE" <<EOF
{
  "core_release_tag": "$tag",
  "core_image": "$image",
  "core_image_digest": "$image_digest",
  "core_image_revision": "$image_revision",
  "updated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
}

function install_core_from_release() {
    install_core_from_gar
}

PIP_INDEX_ARGS=()

function normalize_python_distribution_name() {
    "$MN_PYTHON_BIN" - "$1" <<'PY'
import re
import sys

name = sys.argv[1].split("[", 1)[0].strip().lower()
print(re.sub(r"[-_.]+", "_", name))
PY
}

function bundled_wheel_for_requirement() {
    local requirement="$1"
    local package_part version dist_name wheel_dir wheel

    case "$requirement" in
        *"=="*) ;;
        *) return 1 ;;
    esac

    package_part="${requirement%%==*}"
    package_part="${package_part%%[*}"
    version="${requirement#*==}"
    version="${version%%[[:space:];,<>=!~]*}"
    [ -n "$package_part" ] && [ -n "$version" ] || return 1

    dist_name="$(normalize_python_distribution_name "$package_part")"
    wheel_dir="${MN_BUNDLED_WHEEL_DIR:-${SCRIPT_DIR}/install_support/${INSTALL_VERSION}/python-wheels}"
    [ -d "$wheel_dir" ] || return 1

    wheel="$(find "$wheel_dir" -maxdepth 1 -type f -name "${dist_name}-${version}-*.whl" -print | head -n 1 || true)"
    [ -n "$wheel" ] || return 1
    printf '%s\n' "$wheel"
}

function resolve_python_index_url() {
    local url="$MN_PIP_INDEX_URL"
    if [ -z "$url" ]; then
        if [ -n "$MN_GAR_PROJECT" ]; then
            url="https://${MN_GAR_LOCATION}-python.pkg.dev/${MN_GAR_PROJECT}/${MN_GAR_REPOSITORY}/simple/"
        else
            url="$MN_DEFAULT_PIP_INDEX_URL"
        fi
    fi
    case "$url" in
        */) printf '%s' "$url" ;;
        *) printf '%s/' "$url" ;;
    esac
}

function prepare_pip_index_args() {
    local index_url
    index_url="$(resolve_python_index_url)"
    PIP_INDEX_ARGS=(--index-url "$index_url")
    if [ -n "$MN_PIP_EXTRA_INDEX_URL" ]; then
        PIP_INDEX_ARGS+=(--extra-index-url "$MN_PIP_EXTRA_INDEX_URL")
    fi
}

function bootstrap_gar_keyring_auth() {
    local index_url
    index_url="$(resolve_python_index_url)"
    if [[ "$index_url" == *".pkg.dev/"* ]]; then
        run_quiet "install-gar-keyring-auth" "$VENV_DIR/bin/pip" install --upgrade \
            --index-url https://pypi.org/simple \
            keyring \
            keyrings.google-artifactregistry-auth
    fi
}

function indexed_requirements_for_group() {
    local group="$1"
    "$MN_PYTHON_BIN" - "$PACKAGE_INDEX_FILE" "$group" <<'PY'
from __future__ import annotations

import sys
import tomllib
from pathlib import Path

index_file = Path(sys.argv[1])
group = sys.argv[2]
data = tomllib.loads(index_file.read_text())

def requirement(package: dict) -> str:
    name = package["name"]
    extras = package.get("default_extras") or []
    if extras:
        name = f"{name}[{','.join(extras)}]"
    version = str(package.get("version") or "").strip().lstrip("vV")
    return f"{name}=={version}" if version else name

for package in data.get("packages", []):
    groups = package.get("installer_groups") or []
    if group == "__binary_default__":
        selected = bool(package.get("binary_default"))
    else:
        selected = group in groups
    if selected:
        print(requirement(package))
PY
}

function install_indexed_group() {
    local group="$1"
    local requirement package_name package_version pinned_requirement label bundled_wheel installed="N"
    while IFS= read -r requirement; do
        [ -n "$requirement" ] || continue
        package_name="$(printf '%s' "$requirement" | sed -E 's/\[.*$//; s/[<>=!~].*$//')"
        package_version=""
        case "$package_name" in
            mirrorneuron-python-sdk) package_version="$MN_PYTHON_SDK_PACKAGE_VERSION" ;;
            mirrorneuron-cli) package_version="$MN_CLI_PACKAGE_VERSION" ;;
            mirrorneuron-api) package_version="$MN_API_PACKAGE_VERSION" ;;
        esac
        if [ -n "$package_version" ]; then
            pinned_requirement="${requirement%%[<>=!~]*}==${package_version}"
        else
            case "$requirement" in
                *"=="*|*">="*|*"<="*|*"~="*|*"!="*|*">"*|*"<"*) pinned_requirement="$requirement" ;;
                *) pinned_requirement="${requirement}==${MN_PACKAGE_VERSION}" ;;
            esac
        fi
        label="$(printf '%s' "$pinned_requirement" | tr -c 'A-Za-z0-9_.-' '_')"
        if bundled_wheel="$(bundled_wheel_for_requirement "$pinned_requirement")"; then
            run_quiet "install-${label}" "$VENV_DIR/bin/pip" install --upgrade "$bundled_wheel"
        else
            run_quiet "install-${label}" "$VENV_DIR/bin/pip" install "${PIP_INDEX_ARGS[@]}" --upgrade "$pinned_requirement"
        fi
        installed="Y"
    done < <(indexed_requirements_for_group "$group")
    if [ "$installed" != "Y" ]; then
        print_error "No packages in ${PACKAGE_INDEX_FILE} matched installer group '${group}'."
        exit 1
    fi
}

function install_indexed_group_if_available() {
    local group="$1"
    local description="$2"
    if [ -n "$(indexed_requirements_for_group "$group")" ]; then
        install_indexed_group "$group"
    else
        print_warning "No ${description} are listed in ${PACKAGE_INDEX_FILE}; skipping them for ${INSTALL_VERSION}."
    fi
}

function install_python_packages() {
    "$MN_PYTHON_BIN" -m venv "$VENV_DIR" >/dev/null 2>&1
    run_quiet "pip-upgrade" "$VENV_DIR/bin/pip" install --upgrade pip
    prepare_pip_index_args
    bootstrap_gar_keyring_auth
    if [ "$INSTALL_PYTHON_SDK" = "Y" ]; then
        install_indexed_group sdk
    fi
    if [ "$INSTALL_CLI" = "Y" ]; then
        install_indexed_group cli
    fi
    if [ "$INSTALL_API" = "Y" ]; then
        install_indexed_group api
    fi
    if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
        install_indexed_group membrane-runtime
    fi
    if [ "$INSTALL_AGENTS" = "Y" ]; then
        install_indexed_group_if_available agent "packaged agents"
    fi
}

function setup_context_engine() {
    remove_stale_runtime_containers_for_services context-engine-model membrane-context-engine
    ensure_docker_model_runner
    runtime_compose pull membrane-context-engine
    runtime_compose up -d --no-build membrane-context-engine >/dev/null
}

function compose_profiles() {
    local profiles=()
    [ "$INSTALL_WEB_UI" = "Y" ] && profiles+=("web-ui")
    [ "$INSTALL_OPENSHELL" = "Y" ] && profiles+=("openshell")
    [ "$INSTALL_CONTEXT_ENGINE" = "Y" ] && profiles+=("context")
    case "$(printf '%s' "$MN_SYNCTHING_ENABLED" | tr '[:upper:]' '[:lower:]')" in
        ''|0|false|no|n|off|disabled) ;;
        *) profiles+=("syncthing") ;;
    esac
    if [ "${#profiles[@]}" -eq 0 ]; then
        printf ''
        return 0
    fi
    local IFS=,
    printf '%s' "${profiles[*]}"
}

function generate_openshell_jwt_keys() {
    local jwt_dir="$1"
    local gateway_image="${OPENSHELL_GATEWAY_IMAGE:-ghcr.io/nvidia/openshell/gateway:0.0.47}"
    local bootstrap_dir name

    bootstrap_dir="$(mktemp -d "${MN_HOST_OPENSHELL_STATE_DIR}/.jwt-bootstrap.XXXXXX")"
    if ! docker run --rm \
        --user "$OPENSHELL_GATEWAY_USER" \
        --env HOME=/tmp/openshell-bootstrap \
        --volume "${bootstrap_dir}:/bootstrap" \
        "$gateway_image" \
        generate-certs \
        --output-dir /bootstrap/output \
        --server-san host.openshell.internal >/dev/null; then
        print_error "Failed to create OpenShell sandbox JWT keys with ${gateway_image}."
        print_error "Check that Docker is running and can pull the OpenShell gateway image, then retry."
        rm -rf "$bootstrap_dir"
        exit 1
    fi

    for name in signing.pem public.pem kid; do
        if [ ! -s "${bootstrap_dir}/output/jwt/${name}" ]; then
            print_error "OpenShell certificate bootstrap did not create jwt/${name}."
            print_error "Check that ${gateway_image} supports the generate-certs command, then retry."
            rm -rf "$bootstrap_dir"
            exit 1
        fi
    done

    mv "${bootstrap_dir}/output/jwt/signing.pem" "${jwt_dir}/signing.pem"
    mv "${bootstrap_dir}/output/jwt/public.pem" "${jwt_dir}/public.pem"
    mv "${bootstrap_dir}/output/jwt/kid" "${jwt_dir}/kid"
    rm -rf "$bootstrap_dir"
    chmod 600 "${jwt_dir}/signing.pem" 2>/dev/null || true
    chmod 644 "${jwt_dir}/public.pem" "${jwt_dir}/kid" 2>/dev/null || true
}

function write_openshell_compose_config() {
    local gateway_dir="${MN_HOST_OPENSHELL_CONFIG_DIR}/gateways/openshell"
    local jwt_dir="${MN_HOST_OPENSHELL_STATE_DIR}/jwt"
    mkdir -p "$gateway_dir"
    mkdir -p "$jwt_dir"
    if [ ! -s "${jwt_dir}/signing.pem" ] || [ ! -s "${jwt_dir}/public.pem" ] || [ ! -s "${jwt_dir}/kid" ]; then
        generate_openshell_jwt_keys "$jwt_dir"
    fi
    printf 'openshell\n' > "${MN_HOST_OPENSHELL_CONFIG_DIR}/active_gateway"
    cat > "${gateway_dir}/metadata.json" <<EOF
{
  "name": "openshell",
  "gateway_endpoint": "http://openshell:${OPENSHELL_GATEWAY_PORT:-58080}",
  "is_remote": false,
  "gateway_port": ${OPENSHELL_GATEWAY_PORT:-58080}
}
EOF
    cat > "${MN_HOST_OPENSHELL_STATE_DIR}/gateway.toml" <<EOF
[openshell]
version = 1

[openshell.gateway]
bind_address = "0.0.0.0:${OPENSHELL_GATEWAY_PORT:-58080}"
log_level = "info"
compute_drivers = ["docker"]
sandbox_namespace = "mirror-neuron"
default_image = "ghcr.io/nvidia/openshell/sandbox:latest"
supervisor_image = "ghcr.io/nvidia/openshell/supervisor:latest"

[openshell.gateway.gateway_jwt]
signing_key_path = "${jwt_dir}/signing.pem"
public_key_path = "${jwt_dir}/public.pem"
kid_path = "${jwt_dir}/kid"
gateway_id = "openshell"
ttl_secs = 3600

[openshell.gateway.auth]
allow_unauthenticated_users = true

[openshell.drivers.docker]
default_image = "ghcr.io/nvidia/openshell/sandbox:latest"
image_pull_policy = "IfNotPresent"
sandbox_namespace = "mirror-neuron"
grpc_endpoint = "http://openshell:${OPENSHELL_GATEWAY_PORT:-58080}"
network_name = "${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
EOF
}

function generate_mn_secret() {
    local secret
    local python_fallback="${MN_PYTHON_BIN:-}"

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

    if [ -z "$python_fallback" ]; then
        python_fallback="$(command -v "python${MN_MANAGED_PYTHON_VERSION}" 2>/dev/null || true)"
    fi
    if [ -n "$python_fallback" ]; then
        if secret="$("$python_fallback" -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null)" && [ -n "$secret" ]; then
            printf '%s\n' "$secret"
            return 0
        fi
    fi

    return 1
}

function resolve_secret_file() {
    local env_value="$1"
    local file="$2"
    local label="$3"
    local value

    if [ -n "$env_value" ] && [ "$env_value" != "mirrorneuron" ]; then
        printf '%s\n' "$env_value" > "$file"
        chmod 600 "$file" 2>/dev/null || true
        printf '%s\n' "$env_value"
        return 0
    fi

    mkdir -p "$INSTALL_DIR"
    if [ -s "$file" ]; then
        value="$(tr -d '[:space:]' < "$file")"
        if [ -n "$value" ] && [ "$value" != "mirrorneuron" ]; then
            chmod 600 "$file" 2>/dev/null || true
            printf '%s\n' "$value"
            return 0
        fi
    fi

    if ! value="$(generate_mn_secret)"; then
        value=""
    fi
    if [ -z "$value" ]; then
        print_error "Failed to generate ${label}."
        exit 1
    fi
    printf '%s\n' "$value" > "$file"
    chmod 600 "$file" 2>/dev/null || true
    printf '%s\n' "$value"
}

function resolve_mn_cookie() {
    resolve_secret_file "${MN_COOKIE:-}" "${INSTALL_DIR}/erlang.cookie" "MN_COOKIE"
}

function resolve_network_token() {
    resolve_secret_file "${MN_NETWORK_JOIN_TOKEN:-}" "${INSTALL_DIR}/network.token" "MN_NETWORK_JOIN_TOKEN"
}

function derive_network_secret() {
    local token="$1"
    local label="$2"
    local material="mirror-neuron:${label}:${token}"
    local digest
    local python_fallback="${MN_PYTHON_BIN:-}"

    if command -v shasum >/dev/null 2>&1; then
        if digest="$(printf '%s' "$material" | shasum -a 256 2>/dev/null | awk '{print $1}')" && [ -n "$digest" ]; then
            printf '%s\n' "$digest"
            return 0
        fi
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        if digest="$(printf '%s' "$material" | sha256sum 2>/dev/null | awk '{print $1}')" && [ -n "$digest" ]; then
            printf '%s\n' "$digest"
            return 0
        fi
    fi

    if command -v openssl >/dev/null 2>&1; then
        if digest="$(printf '%s' "$material" | openssl dgst -sha256 -r 2>/dev/null | awk '{print $1}')" && [ -n "$digest" ]; then
            printf '%s\n' "$digest"
            return 0
        fi
    fi

    if [ -z "$python_fallback" ]; then
        python_fallback="$(command -v "python${MN_MANAGED_PYTHON_VERSION}" 2>/dev/null || true)"
    fi
    if [ -n "$python_fallback" ]; then
        if digest="$(printf '%s' "$material" | "$python_fallback" -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null)" && [ -n "$digest" ]; then
            printf '%s\n' "$digest"
            return 0
        fi
    fi

    print_error "Need shasum, sha256sum, a working openssl, or python${MN_MANAGED_PYTHON_VERSION} to derive Redis credentials."
    exit 1
}

function resolve_redis_password() {
    local admin_token="$1"
    local mn_env="${MN_ENV:-dev}"
    local password

    case "$mn_env" in
        prod|production)
            password="$(derive_network_secret "$admin_token" "redis")"
            mkdir -p "$INSTALL_DIR"
            printf '%s\n' "$password" > "${INSTALL_DIR}/redis.password"
            chmod 600 "${INSTALL_DIR}/redis.password" 2>/dev/null || true
            printf '%s\n' "$password"
            ;;
        *)
            printf '%s\n' "mirror_neuron_redis_dev"
            ;;
    esac
}

function read_env_value() {
    local file="$1"
    local key="$2"
    [ -f "$file" ] || return 0
    awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$file"
}

function redis_probe_host() {
    case "${1:-}" in
        ""|0.0.0.0|::|localhost) printf '127.0.0.1' ;;
        *) printf '%s' "$1" ;;
    esac
}

function redis_container_owns_port() {
    local port="$1"
    docker port mirror-neuron-redis 6379/tcp 2>/dev/null | awk -F: -v port="$port" '$NF == port {found=1} END {exit found ? 0 : 1}'
}

function redis_port_available() {
    local host="$1"
    local port="$2"
    local probe_host
    probe_host="$(redis_probe_host "$host")"

    if redis_container_owns_port "$port"; then
        return 0
    fi
    if (echo >"/dev/tcp/${probe_host}/${port}") >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

function resolve_redis_port() {
    local bind_host="$1"
    local persisted_port="$2"
    local candidate

    if [ -n "${MN_REDIS_PORT:-}" ]; then
        candidate="$MN_REDIS_PORT"
        if ! [[ "$candidate" =~ ^[0-9]+$ ]] || [ "$candidate" -lt 1 ] || [ "$candidate" -gt 65535 ]; then
            print_error "MN_REDIS_PORT must be a TCP port between 1 and 65535."
            exit 1
        fi
        if ! redis_port_available "$bind_host" "$candidate"; then
            print_error "Redis port ${candidate} is already in use."
            exit 1
        fi
        printf '%s\n' "$candidate"
        return 0
    fi

    if [[ "$persisted_port" =~ ^[0-9]+$ ]] &&
       [ "$persisted_port" -ge "$MN_DYNAMIC_REDIS_PORT_START" ] &&
       [ "$persisted_port" -le "$MN_DYNAMIC_REDIS_PORT_END" ] &&
       redis_port_available "$bind_host" "$persisted_port"; then
        printf '%s\n' "$persisted_port"
        return 0
    fi

    for candidate in $(seq "$MN_DYNAMIC_REDIS_PORT_START" "$MN_DYNAMIC_REDIS_PORT_END"); do
        if redis_port_available "$bind_host" "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    print_error "No Redis port is available in ${MN_DYNAMIC_REDIS_PORT_START}-${MN_DYNAMIC_REDIS_PORT_END}."
    exit 1
}

function resolve_docker_network_external() {
    local network_name="$1"
    local configured="${MN_DOCKER_NETWORK_EXTERNAL:-}"
    local labels compose_project compose_network

    if [ -n "$configured" ]; then
        printf '%s\n' "$configured"
        return 0
    fi

    if ! labels="$(docker network inspect -f '{{ index .Labels "com.docker.compose.project" }}|{{ index .Labels "com.docker.compose.network" }}' "$network_name" 2>/dev/null)"; then
        printf 'false\n'
        return 0
    fi

    compose_project="${labels%%|*}"
    compose_network="${labels#*|}"
    if [ "$compose_project" = "mirror-neuron" ] && [ "$compose_network" = "runtime" ]; then
        printf 'false\n'
    else
        print_warning "Docker network ${network_name} already exists outside this Compose project; reusing it as an external network."
        printf 'true\n'
    fi
}

function resolve_openshell_gateway_bind_host() {
    local network_name="$1"
    local docker_os gateway

    if [ -n "${OPENSHELL_GATEWAY_BIND_HOST:-}" ]; then
        printf '%s\n' "$OPENSHELL_GATEWAY_BIND_HOST"
        return 0
    fi

    docker_os="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
    if [ "$(uname -s)" = "Darwin" ] || [[ "$docker_os" == *"docker desktop"* ]]; then
        printf '127.0.0.1\n'
        return 0
    fi

    gateway="$(docker network inspect -f '{{ (index .IPAM.Config 0).Gateway }}' "$network_name" 2>/dev/null || true)"
    printf '%s\n' "${gateway:-127.0.0.1}"
}

function reconcile_openshell_gateway_bind_host() {
    local network_name="$1"
    local desired_bind_host desired_endpoint current_bind_host current_endpoint tmp_env
    desired_bind_host="$(resolve_openshell_gateway_bind_host "$network_name")"
    desired_endpoint="${OPENSHELL_GATEWAY_ENDPOINT:-http://${desired_bind_host}:${OPENSHELL_GATEWAY_PORT:-58080}}"
    current_bind_host="$(sed -n 's/^OPENSHELL_GATEWAY_BIND_HOST=//p' "$RUNTIME_COMPOSE_ENV" | tail -1)"
    current_endpoint="$(sed -n 's/^OPENSHELL_GATEWAY_ENDPOINT=//p' "$RUNTIME_COMPOSE_ENV" | tail -1)"
    if [ "$current_bind_host" = "$desired_bind_host" ] && [ "$current_endpoint" = "$desired_endpoint" ]; then
        return 0
    fi

    tmp_env="${RUNTIME_COMPOSE_ENV}.tmp"
    awk -v bind_host="$desired_bind_host" -v endpoint="$desired_endpoint" '
        BEGIN { replaced_bind_host = 0; replaced_endpoint = 0 }
        /^OPENSHELL_GATEWAY_BIND_HOST=/ {
            if (!replaced_bind_host) print "OPENSHELL_GATEWAY_BIND_HOST=" bind_host
            replaced_bind_host = 1
            next
        }
        /^OPENSHELL_GATEWAY_ENDPOINT=/ {
            if (!replaced_endpoint) print "OPENSHELL_GATEWAY_ENDPOINT=" endpoint
            replaced_endpoint = 1
            next
        }
        { print }
        END {
            if (!replaced_bind_host) print "OPENSHELL_GATEWAY_BIND_HOST=" bind_host
            if (!replaced_endpoint) print "OPENSHELL_GATEWAY_ENDPOINT=" endpoint
        }
    ' "$RUNTIME_COMPOSE_ENV" > "$tmp_env"
    mv "$tmp_env" "$RUNTIME_COMPOSE_ENV"
    chmod 600 "$RUNTIME_COMPOSE_ENV" 2>/dev/null || true
    if [ "$current_bind_host" != "$desired_bind_host" ]; then
        mn_run_runtime_compose up -d --force-recreate openshell
    fi
}

function wait_for_openshell_worker_service() {
    local network_name="${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
    local gateway_endpoint="http://openshell:${OPENSHELL_GATEWAY_PORT:-58080}"
    local attempt=1
    local max_attempts=60
    local readiness_announced="N"

    while [ "$attempt" -le "$max_attempts" ]; do
        if docker run --rm \
            --network "$network_name" \
            --entrypoint openshell \
            mirror-neuron-core:latest \
            --gateway-endpoint "$gateway_endpoint" \
            sandbox list >/dev/null 2>&1; then
            if [ "$readiness_announced" = "Y" ]; then
                print_success "OpenShell gateway is ready."
            fi
            return 0
        fi
        if [ "$readiness_announced" != "Y" ]; then
            print_step "Waiting for OpenShell gateway to become ready"
            readiness_announced="Y"
        fi
        sleep 1
        attempt=$((attempt + 1))
    done

    print_error "OpenShell worker service did not become ready at ${gateway_endpoint} after ${max_attempts} seconds."
    print_error "Next: docker logs openshell-cluster-openshell"
    return 1
}

function ensure_runtime_host_directory() {
    local path="$1"
    local description="$2"
    local override_name="$3"

    if [ -e "$path" ] || [ -L "$path" ]; then
        if [ ! -d "$path" ]; then
            print_error "Expected ${description} to be a directory: ${path}"
            print_error "Move or remove that path, or set ${override_name} to a directory."
            exit 1
        fi
        chmod u+rwx "$path" 2>/dev/null || true
        if [ ! -w "$path" ]; then
            print_error "Expected ${description} to be writable: ${path}"
            print_error "Repair ownership or set ${override_name} to a writable directory."
            exit 1
        fi
        return 0
    fi

    mkdir -p "$path"
    chmod u+rwx "$path" 2>/dev/null || true
}

function prepare_litellm_gateway_config() {
    local gateway_dir="${MN_HOST_HOME_DIR}/models/litellm-gateway"
    mkdir -p "$gateway_dir"
    if [ ! -e "${gateway_dir}/config.yaml" ]; then
        printf '{"model_list":[]}\n' > "${gateway_dir}/config.yaml"
    fi
    chmod u+rwX "$gateway_dir" "${gateway_dir}/config.yaml" 2>/dev/null || true
}

function write_runtime_compose_files() {
    local model_runner_model profiles network_name network_external network_token redis_password mn_cookie runtime_skills_root runtime_agents_root runtime_package_index context_memory_enabled otterdesk_context_memory_enabled membrane_engine_tag membrane_engine_image litellm_gateway_bind_host openshell_gateway_bind_host openshell_gateway_endpoint api_host
    model_runner_model="${MN_CONTEXT_MODEL_RUNNER_MODEL:-hf.co/homerquan/mn-context-engine-model-v-Q4_K_M}"
    profiles="$(compose_profiles)"
    api_host="${MN_API_HOST:-}"
    if [ -z "$api_host" ]; then
        if [ "$INSTALL_WEB_UI" = "Y" ]; then
            api_host="0.0.0.0"
        else
            api_host="localhost"
        fi
    fi
    litellm_gateway_bind_host="${MN_LITELLM_GATEWAY_BIND_HOST:-0.0.0.0}"
    network_name="${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
    openshell_gateway_bind_host="$(resolve_openshell_gateway_bind_host "$network_name")"
    openshell_gateway_endpoint="${OPENSHELL_GATEWAY_ENDPOINT:-http://${openshell_gateway_bind_host}:${OPENSHELL_GATEWAY_PORT:-58080}}"
    network_external="$(resolve_docker_network_external "$network_name")"
    network_token="$(resolve_network_token)"
    redis_password="$(resolve_redis_password "mirror_neuron_password_admin")"
    mn_cookie="$(resolve_mn_cookie)"
    printf '%s\n' "mirror_neuron_password" > "${INSTALL_DIR}/grpc_auth.token"
    printf '%s\n' "mirror_neuron_password_admin" > "${INSTALL_DIR}/grpc_admin.token"
    chmod 600 "${INSTALL_DIR}/grpc_auth.token" "${INSTALL_DIR}/grpc_admin.token" 2>/dev/null || true
    runtime_skills_root="${MN_SKILLS_ROOT:-${MN_HOST_HOME_DIR}/skills}"
    runtime_agents_root="${MN_AGENTS_ROOT:-}"
    runtime_package_index="${MN_PACKAGE_INDEX_FILE:-}"
    membrane_engine_tag="${MN_MEMBRANE_ENGINE_IMAGE_TAG:-${INSTALL_VERSION:-v${MN_PACKAGE_VERSION:-1.2.31}}}"
    if [[ "$membrane_engine_tag" != v* ]]; then
        membrane_engine_tag="v${membrane_engine_tag}"
    fi
    membrane_engine_image="${MN_MEMBRANE_ENGINE_IMAGE:-${MN_CONTEXT_ENGINE_IMAGE:-us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/membrane-context-engine:${membrane_engine_tag}}}"
    context_memory_enabled="${MN_CONTEXT_MEMORY_ENABLED:-1}"
    otterdesk_context_memory_enabled="${OTTERDESK_CONTEXT_MEMORY_ENABLED:-$context_memory_enabled}"
    if [ -n "${PACKAGE_INDEX_FILE:-}" ] && [ -f "$PACKAGE_INDEX_FILE" ]; then
        runtime_package_index="${INSTALL_DIR}/package-index/python-packages.toml"
        mkdir -p "$(dirname "$runtime_package_index")"
        cp "$PACKAGE_INDEX_FILE" "$runtime_package_index"
    fi

    mkdir -p "$INSTALL_DIR"
    ensure_runtime_host_directory "$MN_HOST_HOME_DIR" "MirrorNeuron home mount" "MN_HOST_HOME_DIR"
    ensure_runtime_host_directory "$runtime_skills_root" "MirrorNeuron runtime modules root" "MN_SKILLS_ROOT"
    ensure_runtime_host_directory "$MN_HOST_ARTIFACTS_DIR" "run artifacts host mount" "MN_HOST_ARTIFACTS_DIR"
    ensure_runtime_host_directory "$MN_HOST_BLOB_STORE_DIR" "blob store host mount" "MN_HOST_BLOB_STORE_DIR"
    ensure_runtime_host_directory "$MN_HOST_SHARED_STORAGE_ROOT" "shared storage host mount" "MN_HOST_SHARED_STORAGE_ROOT"
    ensure_runtime_host_directory "$MN_HOST_OPENSHELL_CONFIG_DIR" "OpenShell config host mount" "MN_HOST_OPENSHELL_CONFIG_DIR"
    ensure_runtime_host_directory "$MN_HOST_OPENSHELL_STATE_DIR" "OpenShell state host mount" "MN_HOST_OPENSHELL_STATE_DIR"
    prepare_litellm_gateway_config
    mn_write_runtime_compose_file "$RUNTIME_COMPOSE_TEMPLATE" "$RUNTIME_COMPOSE_FILE"
    if [ "$INSTALL_OPENSHELL" = "Y" ]; then
        write_openshell_compose_config
    fi
    cat > "$RUNTIME_COMPOSE_ENV" <<EOF
COMPOSE_PROJECT_NAME=mirror-neuron
COMPOSE_PROFILES=${profiles}
MN_HOST_STATE_DIR=${INSTALL_DIR}
MN_HOST_HOME_DIR=${MN_HOST_HOME_DIR}
MN_HOST_ARTIFACTS_DIR=${MN_HOST_ARTIFACTS_DIR}
MN_HOST_BLOB_STORE_DIR=${MN_HOST_BLOB_STORE_DIR}
MN_HOST_SHARED_STORAGE_ROOT=${MN_HOST_SHARED_STORAGE_ROOT}
MN_SYNCTHING_ENABLED=${MN_SYNCTHING_ENABLED}
MN_SYNCTHING_IMAGE=${MN_SYNCTHING_IMAGE}
MN_SYNCTHING_GUI_PORT=${MN_SYNCTHING_GUI_PORT}
MN_SYNCTHING_SYNC_PORT=${MN_SYNCTHING_SYNC_PORT}
MN_SYNCTHING_RESCAN_INTERVAL_SECONDS=${MN_SYNCTHING_RESCAN_INTERVAL_SECONDS}
MN_BLUEPRINT_PYTHON_ENVS_DIR=${MN_BLUEPRINT_PYTHON_ENVS_DIR}
MN_HOST_OPENSHELL_CONFIG_DIR=${MN_HOST_OPENSHELL_CONFIG_DIR}
MN_HOST_OPENSHELL_STATE_DIR=${MN_HOST_OPENSHELL_STATE_DIR}
MN_MEMBRANE_SOURCE_MODE=${MN_MEMBRANE_SOURCE_MODE:-image}
ENGINE_IMAGE=${membrane_engine_image}
MN_MEMBRANE_ENGINE_IMAGE=${membrane_engine_image}
MN_MEMBRANE_ENGINE_IMAGE_TAG=${membrane_engine_tag}
MN_REDIS_IMAGE=${MN_REDIS_IMAGE:-redis:8}
MN_CONTEXT_MODEL_RUNNER_MODEL=${model_runner_model}
MN_LLM_MODEL_RUNNER_MODEL=${MN_LLM_MODEL_RUNNER_MODEL:-gemma4:e2b}
MN_GRPC_BIND_HOST=${MN_GRPC_BIND_HOST:-127.0.0.1}
MN_GRPC_PORT=${MN_GRPC_PORT:-55051}
MN_GRPC_TARGET=${MN_GRPC_TARGET:-localhost:${MN_GRPC_PORT:-55051}}
MN_GRPC_ADVERTISE_PORT=${MN_GRPC_ADVERTISE_PORT:-${MN_GRPC_PORT:-55051}}
MN_NATIVE_SDK_GRPC_HOST=${MN_NATIVE_SDK_GRPC_HOST:-0.0.0.0}
MN_NATIVE_SDK_GRPC_PORT=${MN_NATIVE_SDK_GRPC_PORT:-55052}
MN_NATIVE_SDK_GRPC_ADVERTISE_HOST=${MN_NATIVE_SDK_GRPC_ADVERTISE_HOST:-${MN_NETWORK_ADVERTISE_HOST:-}}
MN_NATIVE_SDK_GRPC_ADVERTISE_PORT=${MN_NATIVE_SDK_GRPC_ADVERTISE_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_NATIVE_SDK_GRPC_TARGET=${MN_NATIVE_SDK_GRPC_TARGET:-mn-native-sdk-grpc:55052}
MN_NATIVE_SDK_GRPC_PROXY_PORT=${MN_NATIVE_SDK_GRPC_PROXY_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_NATIVE_SDK_GRPC_PROXY_TARGET_HOST=${MN_NATIVE_SDK_GRPC_PROXY_TARGET_HOST:-host.docker.internal}
MN_NATIVE_SDK_GRPC_PROXY_TARGET_PORT=${MN_NATIVE_SDK_GRPC_PROXY_TARGET_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_LITELLM_GATEWAY_BIND_HOST=${litellm_gateway_bind_host}
MN_LITELLM_GATEWAY_PORT=${MN_LITELLM_GATEWAY_PORT:-4000}
MN_LITELLM_GATEWAY_INTERNAL_API_BASE=${MN_LITELLM_GATEWAY_INTERNAL_API_BASE:-http://mn-litellm-proxy:4000/v1}
MN_API_HOST=${api_host}
MN_API_PORT=${MN_API_PORT:-54001}
MN_DIST_PORT=${MN_DIST_PORT:-54370}
MN_WEB_UI_HOST=${MN_WEB_UI_HOST:-localhost}
MN_WEB_UI_PORT=${MN_WEB_UI_PORT:-55173}
MN_WEB_UI_BIND_HOST=${MN_WEB_UI_BIND_HOST:-127.0.0.1}
MN_WEB_UI_IMAGE=${MN_WEB_UI_IMAGE:-node:22-alpine}
MN_WEB_UI_SOURCE_MODE=${MN_WEB_UI_SOURCE_MODE}
MN_WEB_UI_SOURCE_MOUNT=${MN_WEB_UI_SOURCE_MOUNT}
MN_WEB_UI_PACKAGE_VERSION=${MN_WEB_UI_PACKAGE_VERSION}
MN_WEB_UI_API_HOST=${MN_WEB_UI_API_HOST:-host.docker.internal}
MN_BLUEPRINT_WEB_UI_BIND_HOST=${MN_BLUEPRINT_WEB_UI_BIND_HOST:-0.0.0.0}
MN_BLUEPRINT_WEB_UI_PUBLIC_HOST=${MN_BLUEPRINT_WEB_UI_PUBLIC_HOST:-localhost}
MN_BLUEPRINT_WEB_UI_PORT_START=${MN_BLUEPRINT_WEB_UI_PORT_START:-61000}
MN_BLUEPRINT_WEB_UI_PORT_END=${MN_BLUEPRINT_WEB_UI_PORT_END:-61049}
MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE=${MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE:-prepublished}
MN_ENV=${MN_ENV:-dev}
MN_BLUEPRINT_SOURCE=${MN_BLUEPRINT_SOURCE:-github}
MN_BLUEPRINT_REPO=${MN_BLUEPRINT_REPO:-https://github.com/MirrorNeuronLab/mn-blueprints.git}
MN_BLUEPRINT_LOCAL=${MN_BLUEPRINT_LOCAL:-}
MN_WORKSPACE_ROOT=${MN_WORKSPACE_ROOT:-}
MN_AGENTS_ROOT=${runtime_agents_root}
MN_SKILLS_ROOT=${runtime_skills_root}
MN_PACKAGE_INDEX_FILE=${runtime_package_index}
MN_PIP_INDEX_URL=${MN_PIP_INDEX_URL:-${MN_PYTHON_INDEX_URL:-${MN_DEFAULT_PIP_INDEX_URL:-https://us-central1-python.pkg.dev/mirrorneuron-public-packages/agent-skills/simple/}}}
MN_PIP_EXTRA_INDEX_URL=${MN_PIP_EXTRA_INDEX_URL:-${MN_PYTHON_EXTRA_INDEX_URL:-https://pypi.org/simple}}
MN_RUNTIME_MODULE_VERSION=${MN_RUNTIME_MODULE_VERSION:-${MN_PACKAGE_VERSION:-}}
MN_CONTEXT_MEMORY_ENABLED=${context_memory_enabled}
OTTERDESK_CONTEXT_MEMORY_ENABLED=${otterdesk_context_memory_enabled}
MN_RUNS_ROOT=${MN_RUNS_ROOT:-}
MN_DOCKER_NETWORK_MODE=${MN_DOCKER_NETWORK_MODE:-bridge}
MN_DOCKER_NETWORK_NAME=${network_name}
MN_DOCKER_NETWORK_EXTERNAL=${network_external}
MN_DOCKER_NETWORK_DRIVER=${MN_DOCKER_NETWORK_DRIVER:-bridge}
MN_DOCKER_NETWORK_ATTACHABLE=${MN_DOCKER_NETWORK_ATTACHABLE:-false}
MN_DOCKER_WORKER_ENABLED=${MN_DOCKER_WORKER_ENABLED:-1}
MN_NODE_ALIAS=${MN_NODE_ALIAS:-}
MN_NODE_NAME=${MN_NODE_NAME:-}
MN_NODE_ROLE=${MN_NODE_ROLE:-runtime}
MN_CLUSTER_NODES=${MN_CLUSTER_NODES:-}
MN_NETWORK_JOIN_TOKEN=${network_token}
MN_REDIS_PASSWORD=${redis_password}
MN_REDIS_URL=${MN_REDIS_URL:-redis://:${redis_password}@redis:6379/0}
MN_CONTEXT_REDIS_URL=${MN_CONTEXT_REDIS_URL:-redis://:${redis_password}@redis:6379/1}
MN_REDIS_HA_MODE=${MN_REDIS_HA_MODE:-single}
MN_REDIS_SENTINELS=${MN_REDIS_SENTINELS:-}
MN_REDIS_SENTINEL_MASTER=${MN_REDIS_SENTINEL_MASTER:-mirror-neuron}
MN_REDIS_SENTINEL_HOST_MAP=${MN_REDIS_SENTINEL_HOST_MAP:-}
MN_REDIS_DB=${MN_REDIS_DB:-0}
MN_REDIS_USERNAME=${MN_REDIS_USERNAME:-}
MN_REDIS_SENTINEL_USERNAME=${MN_REDIS_SENTINEL_USERNAME:-}
MN_REDIS_SENTINEL_PASSWORD=${MN_REDIS_SENTINEL_PASSWORD:-${redis_password}}
MN_REDIS_WAIT_REPLICAS=${MN_REDIS_WAIT_REPLICAS:-0}
MN_REDIS_WAIT_TIMEOUT_MS=${MN_REDIS_WAIT_TIMEOUT_MS:-100}
MN_REDIS_RECONNECT_ATTEMPTS=${MN_REDIS_RECONNECT_ATTEMPTS:-10}
MN_REDIS_RECONNECT_BACKOFF_MS=${MN_REDIS_RECONNECT_BACKOFF_MS:-250}
MN_REDIS_RECONNECT_MAX_BACKOFF_MS=${MN_REDIS_RECONNECT_MAX_BACKOFF_MS:-2000}
ERL_EPMD_ADDRESS=${ERL_EPMD_ADDRESS:-0.0.0.0}
ERL_AFLAGS=${ERL_AFLAGS:--kernel inet_dist_listen_min ${MN_DIST_PORT:-54370} inet_dist_listen_max ${MN_DIST_PORT:-54370}}
OPENSHELL_GATEWAY_PORT=${OPENSHELL_GATEWAY_PORT:-58080}
OPENSHELL_GATEWAY_ENDPOINT=${openshell_gateway_endpoint}
OPENSHELL_GATEWAY_BIND_HOST=${openshell_gateway_bind_host}
OPENSHELL_GATEWAY_USER=${OPENSHELL_GATEWAY_USER}
OPENSHELL_GATEWAY_DOCKER_GROUP=${OPENSHELL_GATEWAY_DOCKER_GROUP}
DOCKER_HOST_SOCKET=${DOCKER_HOST_SOCKET}
COMPOSE_PARALLEL_LIMIT=${COMPOSE_PARALLEL_LIMIT:-1}
MN_COOKIE=${mn_cookie}
MN_GRPC_AUTH_TOKEN=mirror_neuron_password
MN_GRPC_ADMIN_TOKEN=mirror_neuron_password_admin
EOF
    chmod 600 "$RUNTIME_COMPOSE_ENV" 2>/dev/null || true
}

function runtime_compose() {
    local status
    if command -v docker-compose >/dev/null 2>&1; then
        if COMPOSE_PARALLEL_LIMIT="${COMPOSE_PARALLEL_LIMIT:-1}" docker-compose --env-file "$RUNTIME_COMPOSE_ENV" -f "$RUNTIME_COMPOSE_FILE" "$@"; then
            return 0
        else
            status=$?
        fi
    else
        if COMPOSE_PARALLEL_LIMIT="${COMPOSE_PARALLEL_LIMIT:-1}" docker compose --env-file "$RUNTIME_COMPOSE_ENV" -f "$RUNTIME_COMPOSE_FILE" "$@"; then
            return 0
        else
            status=$?
        fi
    fi
    mn_report_docker_daemon_failure
    return "$status"
}

function runtime_container_name_for_service() {
    case "$1" in
        redis) echo "mirror-neuron-redis" ;;
        web-ui) echo "mirror-neuron-web-ui" ;;
        openshell) echo "openshell-cluster-openshell" ;;
        context-engine-model) echo "mirror-neuron-context-engine-model" ;;
        membrane-context-engine) echo "mirror-neuron-context-engine" ;;
        mirror-neuron-core) echo "mirror-neuron-core" ;;
        *) return 1 ;;
    esac
}

function remove_stale_runtime_container() {
    local name="$1"
    local project

    if ! docker container inspect "$name" >/dev/null 2>&1; then
        return 0
    fi

    project="$(docker container inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$name" 2>/dev/null || true)"
    if [ "$project" = "mirror-neuron" ]; then
        return 0
    fi

    docker rm -f "$name" >/dev/null 2>&1 || true
}

function remove_stale_runtime_containers_for_services() {
    local service name
    for service in "$@"; do
        name="$(runtime_container_name_for_service "$service" || true)"
        [ -n "$name" ] && remove_stale_runtime_container "$name"
    done
    return 0
}

function ensure_docker_model_runner() {
    local linux_nvidia="N"
    if mn_is_linux_nvidia_host; then
        linux_nvidia="Y"
    fi

    if [ "$linux_nvidia" != "Y" ] && [ "$INSTALL_CONTEXT_ENGINE" != "Y" ] && [ "${INSTALL_DOCKER_MODEL_RUNNER:-N}" != "Y" ] && [ "${MN_ENABLE_DOCKER_MODEL_RUNNER:-N}" != "Y" ]; then
        return 0
    fi

    mn_prepare_docker_model_runner_cli
    if ! docker model --help >/dev/null 2>&1; then
        print_error "Docker Model Runner CLI is not available."
        mn_print_docker_model_runner_install_hint
        exit 1
    fi

    if [ "$linux_nvidia" = "Y" ]; then
        mn_ensure_nvidia_llamacpp_runner
        return 0
    else
        if docker model status >/dev/null 2>&1; then
            return 0
        fi

        if mn_is_docker_desktop_host; then
            print_warning "Docker Model Runner is not running after the Docker Desktop enable command."
        else
            print_warning "Docker Model Runner is not running; attempting to install and start it."
        fi

        if docker model install-runner --help >/dev/null 2>&1; then
            docker model install-runner >/dev/null 2>&1 || true
            docker model start-runner >/dev/null 2>&1 || true
            if docker model status >/dev/null 2>&1; then
                return 0
            fi
        fi
    fi

    print_error "Docker Model Runner is not ready."
    mn_print_docker_model_runner_install_hint
    exit 1
}

function prepare_runtime_compose_sidecars() {
    RUNTIME_COMPOSE_SIDECARS=()
    [ "$INSTALL_REDIS" = "Y" ] && RUNTIME_COMPOSE_SIDECARS+=("redis")
    [ "$INSTALL_WEB_UI" = "Y" ] && RUNTIME_COMPOSE_SIDECARS+=("web-ui")
    grep -q '^  mn-native-sdk-grpc:' "$RUNTIME_COMPOSE_FILE" 2>/dev/null && RUNTIME_COMPOSE_SIDECARS+=("mn-native-sdk-grpc")
    grep -q '^  mn-litellm-proxy:' "$RUNTIME_COMPOSE_FILE" 2>/dev/null && RUNTIME_COMPOSE_SIDECARS+=("mn-litellm-proxy")
    [ "$INSTALL_OPENSHELL" = "Y" ] && RUNTIME_COMPOSE_SIDECARS+=("openshell")
    if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
        RUNTIME_COMPOSE_SIDECARS+=("membrane-context-engine")
    fi
    if mn_is_linux_nvidia_host; then
        ensure_docker_model_runner
    fi
    if [ "${#RUNTIME_COMPOSE_SIDECARS[@]}" -gt 0 ]; then
        remove_stale_runtime_containers_for_services context-engine-model "${RUNTIME_COMPOSE_SIDECARS[@]}"
        ensure_docker_model_runner
        if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
            mn_run_runtime_compose pull membrane-context-engine
        fi
    fi
}

function start_runtime_compose_sidecars() {
    prepare_runtime_compose_sidecars
    if [ "${#RUNTIME_COMPOSE_SIDECARS[@]}" -gt 0 ]; then
        mn_run_runtime_compose up -d --no-build "${RUNTIME_COMPOSE_SIDECARS[@]}"
    fi
    if [ "$INSTALL_OPENSHELL" = "Y" ]; then
        reconcile_openshell_gateway_bind_host "${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
        wait_for_openshell_worker_service
    fi
}

function shell_escape_value() {
    printf '%q' "$1"
}

function profile_has_bin_path() {
    local profile="$1"
    [ -f "$profile" ] || return 1
    local line
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" == *'PATH'* && "$line" == *'$MN_HOME/bin'* ]]; then
            return 0
        fi
    done < "$profile"
    return 1
}

function profile_has_runtime_home() {
    local profile="$1"
    [ -f "$profile" ] || return 1
    local line
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?MN_HOME= ]]; then
            return 0
        fi
    done < "$profile"
    return 1
}

function add_shell_profile_exports() {
    local include_path="${1:-Y}"
    local needs_path="N"
    local needs_runtime_home="Y"
    local default_home="${HOME}/.mn"
    local shell_profile
    local profile_updated="N"

    if [ "$include_path" = "Y" ]; then
        [[ ":$PATH:" != *":$BIN_DIR:"* ]] && needs_path="Y"
    fi

    if [ "$needs_path" = "N" ] && [ "$needs_runtime_home" = "N" ]; then
        return
    fi

    if [ "$needs_path" = "Y" ]; then
        print_warning "${BIN_DIR} is not in your PATH."
    fi
    if [ "$needs_runtime_home" = "Y" ]; then
        print_detail "Persisting MN_HOME=${INSTALL_DIR} for future terminal sessions."
    fi

    shell_profile="$(mn_preferred_shell_profile)"
    local detected_profiles=("$shell_profile")

    local profile path_line home_line wrote_header wrote_profile
    if [ "$INSTALL_DIR" = "$default_home" ]; then
        home_line='export MN_HOME="$HOME/.mn"'
    else
        home_line="export MN_HOME=$(shell_escape_value "$INSTALL_DIR")"
    fi
    path_line='export PATH="$MN_HOME/bin:$PATH"'

    for profile in "${detected_profiles[@]}"; do
        wrote_header="N"
        wrote_profile="N"
        mn_deduplicate_generated_profile_exports "$profile" "$path_line" "$home_line"
        if [ "$needs_runtime_home" = "Y" ] && ! profile_has_runtime_home "$profile"; then
            [ "$wrote_header" = "N" ] && echo -e "\n# MN and OTTERDESK" >> "$profile" && wrote_header="Y"
            echo "$home_line" >> "$profile"
            wrote_profile="Y"
        fi
        if [ "$needs_path" = "Y" ] && ! profile_has_bin_path "$profile"; then
            [ "$wrote_header" = "N" ] && echo -e "\n# MN and OTTERDESK" >> "$profile" && wrote_header="Y"
            echo "$path_line" >> "$profile"
            wrote_profile="Y"
        fi
        if [ "$wrote_profile" = "Y" ]; then
            print_detail "Updated shell exports: ${profile}"
            profile_updated="Y"
        fi
    done

    if [ "$needs_path" = "Y" ]; then
        export PATH="${BIN_DIR}:${PATH}"
    fi
    if [ "$needs_path" = "Y" ] || [ "$profile_updated" = "Y" ]; then
        MN_SHELL_PROFILE_RELOAD_REQUIRED="Y"
        MN_SHELL_PROFILE_PATH="$shell_profile"
        print_warning "Open a new terminal, or run: source $(shell_escape_value "$shell_profile")"
    fi
}

print_header

if [ "$NON_INTERACTIVE" != "Y" ]; then
    INSTALL_WEB_UI=$(ask "Do you want to enable the Web UI Compose service?" "$INSTALL_WEB_UI")
    INSTALL_REDIS=$(ask "Do you want to install Redis via Docker?" "$INSTALL_REDIS")
    INSTALL_CONTEXT_ENGINE=$(ask "Do you want to install/start the Membrane context engine?" "$INSTALL_CONTEXT_ENGINE")
    INSTALL_OPENSHELL=$(ask "Do you want to install/start the OpenShell gateway for sandbox workers?" "$INSTALL_OPENSHELL")
    INSTALL_PYTHON_SDK=$(ask "Do you want to install the Python SDK from the configured pip index?" "$INSTALL_PYTHON_SDK")
    INSTALL_AGENTS=$(ask "Do you want to install indexed agent packages from the configured pip index?" "$INSTALL_AGENTS")
    INSTALL_CLI=$(ask "Do you want to install the CLI from the configured pip index?" "$INSTALL_CLI")
    INSTALL_API=$(ask "Do you want to install the API from the configured pip index?" "$INSTALL_API")
    START_NOW=$(ask "Do you want to start the MirrorNeuron server automatically after install?" "$START_NOW")
    echo "" >&3
fi

validate_selections

print_step "Checking system"
require_cmd curl
require_cmd docker
if should_install_python_packages; then
    mn_ensure_python_package_index_file
    resolve_python_runtime
    ensure_pip
fi
if ! docker info >/dev/null 2>&1; then
    print_error "Docker is not running. Please start Docker first."
    exit 1
fi

print_success "System ready."

if [ -d "$INSTALL_DIR" ] || [ -f "$BIN_DIR/mn" ]; then
    if [ "$MN_INSTALL_RESET" = "Y" ]; then
        REINSTALL="Y"
    else
        print_warning "MirrorNeuron appears to be already installed."
        REINSTALL=$(ask "Do you want to reinstall (overwrite old ones)?" "$REINSTALL")
    fi
    if [ "$REINSTALL" = "N" ]; then
        print_warning "Installation cancelled."
        exit 0
    fi
    echo "" >&3
    mn_remove_existing_install_paths
fi

print_step "Installing product"
( install_core_from_release ) &
spinner $! "Installing core runtime"
write_runtime_compose_files

if should_install_python_packages; then
    print_step "Installing tools"
    ( install_python_packages ) &
    spinner $! "Installing Python packages"
else
    print_warning "Skipping Python component installation."
fi

if [ "$INSTALL_WEB_UI" = "Y" ]; then
    print_step "Preparing Web UI package for Docker Compose"
    mkdir -p "$MN_WEB_UI_SOURCE_MOUNT"
fi

if [ "$INSTALL_REDIS" = "Y" ] || [ "$INSTALL_CONTEXT_ENGINE" = "Y" ] || [ "$INSTALL_OPENSHELL" = "Y" ] || [ "$INSTALL_WEB_UI" = "Y" ]; then
    if [ "$START_NOW" = "Y" ]; then
        prepare_runtime_compose_sidecars
        print_detail "Docker services are prepared; automatic startup is deferred to mn runtime start."
    else
        print_step "Starting selected Docker runtime services"
        ( start_runtime_compose_sidecars ) &
        spinner $! "Selected Docker runtime services are available"
    fi
fi

print_step "Finishing setup"
mkdir -p "$BIN_DIR" "$INSTALL_DIR"
rm -f "$BIN_DIR/mn" "$BIN_DIR/mn-api" "$INSTALL_DIR/mn"
if [ "$INSTALL_CLI" = "Y" ]; then
    ln -s "$VENV_DIR/bin/mn" "$BIN_DIR/mn"
fi
if [ "$INSTALL_API" = "Y" ]; then
    ln -s "$VENV_DIR/bin/mn-api" "$BIN_DIR/mn-api"
fi
print_detail "Command links: ${BIN_DIR}"
if [ "$INSTALL_CLI" = "Y" ] || [ "$INSTALL_API" = "Y" ]; then
    add_shell_profile_exports "Y"
else
    add_shell_profile_exports "N"
fi

if [ "$START_NOW" = "Y" ]; then
    print_step "Starting MirrorNeuron services"
    if ! mn_run_runtime_start_command "$VENV_DIR/bin/mn" runtime start; then
        [ -n "$MN_RUNTIME_START_LOG" ] && print_warning "CLI startup details: $MN_RUNTIME_START_LOG"
        print_warning "mn runtime start failed; starting MirrorNeuron Docker Compose runtime."
        mn_run_runtime_compose up -d --no-build
        "$VENV_DIR/bin/mn" runtime restart-sidecars --api >/dev/null 2>&1 || print_warning "MirrorNeuron Core started, but the REST API sidecar did not start automatically."
    fi
    if [ "$INSTALL_OPENSHELL" = "Y" ]; then
        reconcile_openshell_gateway_bind_host "${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
        wait_for_openshell_worker_service
    fi
    print_success "MirrorNeuron services are running."
fi

echo "" >&3
print_success "MirrorNeuron ${CORE_INSTALL_VERSION} installed."
if [ "$INSTALL_WEB_UI" = "Y" ]; then
    printf '  Web UI: %s\n' "http://${MN_WEB_UI_HOST:-localhost}:${MN_WEB_UI_PORT:-55173}" >&3
fi
print_detail "SDK ${PYTHON_SDK_INSTALL_VERSION}; CLI ${CLI_INSTALL_VERSION}; API ${API_INSTALL_VERSION}; Web UI ${WEB_UI_INSTALL_VERSION}"
if [ "$INSTALL_CLI" = "Y" ]; then
    print_detail "CLI: mn"
fi
if [ "$INSTALL_API" = "Y" ]; then
    print_detail "API: mn-api"
fi
if [ "$INSTALL_CLI" = "Y" ]; then
    if [ "$START_NOW" = "Y" ]; then
        mn_print_next_shell_command "mn node list"
    else
        mn_print_next_shell_command "mn runtime start"
    fi
fi
mn_print_cli_verification_prompt
}

if [ "$MN_INSTALL_RESET" = "Y" ] && [ "$MN_INSTALL_HELP_REQUESTED" != "Y" ]; then
    mn_reset_install_state
    mn_reset_drop_conflicting_install_args
fi

if [ "${#MN_INSTALL_ARGS[@]}" -eq 0 ]; then
    case "$MN_INSTALL_MODE" in
        github) run_install_github ;;
        local) run_install_local ;;
        binary) run_install_binary ;;
    esac
else
    case "$MN_INSTALL_MODE" in
        github) run_install_github "${MN_INSTALL_ARGS[@]}" ;;
        local) run_install_local "${MN_INSTALL_ARGS[@]}" ;;
        binary) run_install_binary "${MN_INSTALL_ARGS[@]}" ;;
    esac
fi
