#!/usr/bin/env bash

set -euo pipefail

# Keep installer output visible even when a subcommand redirects stdout/stderr.
exec 3>&1

MN_INSTALL_MODE="${MN_INSTALL_MODE:-binary}"
MN_INSTALL_MODE_EXPLICIT="N"
MN_INSTALL_HELP_REQUESTED="N"
LATEST="v1.2.18"
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
  --version TAG                 Install this release version, for example v1.2.18.
  --yes, -y                     Run non-interactively with defaults and flags. This is the default.
  --interactive                 Ask each install question before proceeding.
  --no-reinstall                Keep an existing install instead of overwriting it.
  --web-ui / --no-web-ui        Enable or skip Web UI setup.
  --redis / --no-redis          Enable or skip Redis Docker setup.
  --context-engine / --no-context-engine
                                Enable or skip Membrane context engine setup.
  --openshell / --no-openshell  Enable or skip OpenShell gateway setup.
  --syncthing / --no-syncthing  Enable or skip Syncthing shared-storage replication.
  --start / --no-start          Start or skip starting MirrorNeuron after install.
  --start-as-worker             Start MirrorNeuron as a worker node after install.
  --python PATH                 Same as MN_PYTHON. Must be Python 3.11.x.
  --no-managed-python           Do not use uv to install a private Python runtime.
  --python-components LIST      Install only these Python components where supported.
  --core-release-tag TAG        Legacy alias for --version in binary mode.
  --core-asset-url URL          Binary mode release asset URL.
  --gar-project PROJECT         Binary mode Google Artifact Registry project override.
  --gar-location LOCATION       Binary mode GAR location. Default: us-central1.
  --gar-repository NAME         Binary mode GAR Python repository override.
  --python-index-url URL        Binary mode pip index URL override.
  --python-extra-index-url URL  Binary mode dependency fallback index URL.
  -h, --help                    Show this help.

Examples:
  ./$MN_INSTALL_SCRIPT_NAME --no-web-ui
  ./$MN_INSTALL_SCRIPT_NAME --interactive
  ./$MN_INSTALL_SCRIPT_NAME --mode github
  ./$MN_INSTALL_SCRIPT_NAME --mode local --no-web-ui --no-skills
  ./$MN_INSTALL_SCRIPT_NAME --version v1.2.18
  ./$MN_INSTALL_SCRIPT_NAME --mode github --version v1.2.18
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

function mn_npm_version_from_tag() {
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
                echo "install.sh: --version requires a release tag such as v1.2.18." >&3
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
    if [ "${START_AS_WORKER:-N}" = "Y" ]; then
        grep -q 'mn-native-sdk-grpc:' "$template" &&
            grep -q 'mn-litellm-proxy:' "$template" &&
            grep -q 'MN_NATIVE_SDK_GRPC_TARGET' "$template"
    fi
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
    mn_remove_path_or_exit "$LEGACY_UI_DIR" "legacy MirrorNeuron Web UI directory"
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

MN_MANAGED_PYTHON="${MN_MANAGED_PYTHON:-1}"
MN_MANAGED_PYTHON_VERSION="${MN_MANAGED_PYTHON_VERSION:-3.11}"
MN_MANAGED_PYTHON_ROOT="${MN_MANAGED_PYTHON_DIR:-${HOME}/.local/share/mn_python}"
MN_UV_ROOT="${MN_UV_DIR:-${HOME}/.local/share/mn_uv}"
MN_UV_BIN=""
MN_GITHUB_TOKEN_LOOKED_UP="N"
MN_GITHUB_TOKEN_VALUE=""
MN_GITHUB_GIT_AUTH_CONFIGURED="N"

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
        print_error "$label failed. Log: $log_file"
        tail -n 20 "$log_file" >&3 2>/dev/null || true
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
    print_success "Configured GitHub authentication for non-interactive Git clones."
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

    print_success "Installed uv at $MN_UV_BIN."
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
    print_success "Using uv-managed Python $(python_version "$managed_bin") at $managed_bin."
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
            print_success "Using Python $(python_version "$MN_PYTHON_BIN") at $MN_PYTHON_BIN."
            return
        fi
        if [ -n "${MN_PYTHON:-}" ]; then
            print_python_requirement_error "$resolved"
            exit 1
        fi
    done

    if managed_python_enabled; then
        install_managed_python
        print_success "Using Python $(python_version "$MN_PYTHON_BIN") at $MN_PYTHON_BIN."
        return
    fi

    print_warning "Managed Python fallback is disabled."
    resolved="$(command -v "python${MN_MANAGED_PYTHON_VERSION}" 2>/dev/null || true)"
    print_python_requirement_error "$resolved"
    exit 1
}

print_header

INSTALL_DIR="${MN_HOME:-${HOME}/.mn}"
BIN_DIR="${HOME}/.local/bin"
VENV_DIR="${HOME}/.local/share/mn_venv"
MN_PYTHON_BIN=""
SOURCE_WORKSPACE=""
SCRIPT_DIR="$(mn_script_dir)"
RUNTIME_COMPOSE_TEMPLATE="${MN_RUNTIME_COMPOSE_TEMPLATE:-}"
RUNTIME_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
RUNTIME_COMPOSE_ENV="${INSTALL_DIR}/docker-compose.env"
LEGACY_UI_DIR="${INSTALL_DIR}_ui"
INSTALL_CONTEXT_ENGINE="N"
MEMBRANE_REPO="${MN_MEMBRANE_REPO:-MirrorNeuronLab/Membrane}"
MEMBRANE_GIT_URL="${MN_MEMBRANE_GIT_URL:-}"
MEMBRANE_DIR="${MN_MEMBRANE_DIR:-${INSTALL_DIR}/Membrane}"
MN_HOST_HOME_DIR="${MN_HOST_HOME_DIR:-${MN_HOST_MN_DIR:-${INSTALL_DIR}}}"
MN_HOST_ARTIFACTS_DIR="${MN_HOST_ARTIFACTS_DIR:-${MN_HOST_HOME_DIR}/runs}"
MN_HOST_BLOB_STORE_DIR="${MN_HOST_BLOB_STORE_DIR:-${MN_HOST_HOME_DIR}/blobs}"
MN_HOST_SHARED_STORAGE_ROOT="${MN_HOST_SHARED_STORAGE_ROOT:-${MN_HOST_SHARED_ARTIFACT_ROOT:-${MN_HOST_HOME_DIR}/shared}}"
MN_SYNCTHING_ENABLED="${MN_SYNCTHING_ENABLED:-auto}"
MN_SYNCTHING_IMAGE="${MN_SYNCTHING_IMAGE:-syncthing/syncthing:latest}"
MN_SYNCTHING_GUI_PORT="${MN_SYNCTHING_GUI_PORT:-58384}"
MN_SYNCTHING_SYNC_PORT="${MN_SYNCTHING_SYNC_PORT:-22000}"
MN_HOST_OPENSHELL_CONFIG_DIR="${OPENSHELL_CONTAINER_CONFIG_DIR:-${HOME}/.config/openshell-mirror-neuron}"
MN_HOST_OPENSHELL_STATE_DIR="${MN_HOST_OPENSHELL_STATE_DIR:-${INSTALL_DIR}/openshell-state}"
OPENSHELL_GATEWAY_USER="${OPENSHELL_GATEWAY_USER:-$(id -u):$(id -g)}"
if [ -z "${DOCKER_HOST_SOCKET:-}" ]; then
    if [ -S "${HOME}/.docker/run/docker.sock" ]; then
        DOCKER_HOST_SOCKET="${HOME}/.docker/run/docker.sock"
    else
        DOCKER_HOST_SOCKET="/var/run/docker.sock"
    fi
fi
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
MN_NPM_PACKAGE_VERSION=""
CORE_REPO="${MN_CORE_REPO:-MirrorNeuronLab/MirrorNeuron}"
SKILLS_REPO="${MN_SKILLS_REPO:-MirrorNeuronLab/mn-skills}"
MN_SKILLS_GIT_URL="${MN_SKILLS_GIT_URL:-}"
CORE_RELEASE_TAG="${MN_CORE_RELEASE_TAG:-}"
CORE_ASSET_URL="${MN_CORE_ASSET_URL:-}"
START_AS_WORKER="N"

function github_usage() {
    local script_name="${MN_INSTALL_SCRIPT_NAME:-$(basename "$0")}";
    cat >&3 <<EOF
Usage: ./$script_name --mode github [options]

Installs MirrorNeuron from GitHub repositories. Use through --mode github.

Options:
  --version TAG                 Install this release tag from each GitHub repo. If omitted, use each repo's default branch.
  --yes                         Run non-interactively with defaults and flags. This is the default.
  --interactive                 Ask each install question before proceeding.
  --no-reinstall                Keep an existing install instead of overwriting it.
  --web-ui / --no-web-ui        Enable or skip GitHub Web UI install/build.
  --redis / --no-redis          Enable or skip Redis Docker setup.
  --context-engine / --no-context-engine
                                Enable or skip Membrane context engine setup.
  --openshell / --no-openshell  Enable or skip OpenShell gateway setup.
  --syncthing / --no-syncthing  Enable or skip Syncthing shared-storage replication.
  --start / --no-start          Start or skip starting MirrorNeuron after install.
  --start-as-worker             Start MirrorNeuron as a worker node after install.
  --python-components LIST      Install only these components: sdk,skill,cli,api.
                                Use all or none as shortcuts.
  --python-sdk / --no-python-sdk
  --skill / --no-skill          Blueprint support skill from GitHub.
  --cli / --no-cli
  --api / --no-api
  --skills-repo OWNER/REPO      Same as MN_SKILLS_REPO. Default: MirrorNeuronLab/mn-skills.
  --skills-git-url URL          Same as MN_SKILLS_GIT_URL.
  --python PATH                 Same as MN_PYTHON. Must be Python 3.11.x.
  --no-managed-python           Do not use uv to install a private Python runtime.
  --core-release-tag TAG        Legacy alias for --version.
  --core-asset-url URL          Accepted for CLI compatibility; used by binary mode.
  MN_HOME=/path                 Override the runtime state directory. Defaults to ${HOME}/.mn.
  GITHUB_TOKEN/GH_TOKEN         Token for private GitHub repositories. An existing gh auth login is also used.
  -h, --help                    Show this help.

Examples:
  ./$script_name --mode github --no-web-ui
  ./$script_name --mode github --version v1.2.18
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
        --start-as-worker) START_AS_WORKER="Y"; START_NOW="Y" ;;
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
                print_error "--version requires a release tag such as v1.2.18."
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
        --core-release-tag)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--core-release-tag requires a value."
                github_usage
                exit 1
            fi
            CORE_RELEASE_TAG="$1"
            ;;
        --core-release-tag=*) CORE_RELEASE_TAG="${1#*=}" ;;
        --core-asset-url)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--core-asset-url requires a value."
                github_usage
                exit 1
            fi
            CORE_ASSET_URL="$1"
            ;;
        --core-asset-url=*) CORE_ASSET_URL="${1#*=}" ;;
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
    if [ -n "$CORE_RELEASE_TAG" ]; then
        if [ "$INSTALL_VERSION_EXPLICIT" = "Y" ] && [ "$INSTALL_VERSION" != "$CORE_RELEASE_TAG" ]; then
            print_error "--version (${INSTALL_VERSION}) and --core-release-tag (${CORE_RELEASE_TAG}) must match."
            exit 1
        fi
        INSTALL_VERSION="$CORE_RELEASE_TAG"
        INSTALL_VERSION_EXPLICIT="Y"
    fi

    if [ -n "$INSTALL_VERSION" ]; then
        mn_validate_version_tag_or_exit "$INSTALL_VERSION"
        MN_INSTALL_VERSION="$INSTALL_VERSION"
        CORE_RELEASE_TAG="$INSTALL_VERSION"
        MN_PACKAGE_VERSION="$(mn_package_version_from_tag "$INSTALL_VERSION")"
        MN_NPM_PACKAGE_VERSION="$(mn_npm_version_from_tag "$INSTALL_VERSION")"
        RUNTIME_COMPOSE_TEMPLATE="${RUNTIME_COMPOSE_TEMPLATE:-${SCRIPT_DIR}/install_support/${INSTALL_VERSION}/docker-compose.yml}"
    else
        MN_INSTALL_VERSION=""
        CORE_RELEASE_TAG=""
        RUNTIME_COMPOSE_TEMPLATE="${RUNTIME_COMPOSE_TEMPLATE:-${SCRIPT_DIR}/docker-compose.yml}"
    fi
    export MN_INSTALL_VERSION
}

finalize_github_install_version

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
    context_engine_source_dir >/dev/null
    remove_stale_runtime_containers_for_services context-engine-model membrane-context-engine
    ensure_docker_model_runner
    runtime_compose build membrane-context-engine
    runtime_compose up -d membrane-context-engine >/dev/null
}

function compose_profiles() {
    local profiles=()
    [ "$INSTALL_OPENSHELL" = "Y" ] && profiles+=("openshell")
    [ "$INSTALL_CONTEXT_ENGINE" = "Y" ] && profiles+=("context")
    if [ "${#profiles[@]}" -eq 0 ]; then
        printf ''
        return 0
    fi
    local IFS=,
    printf '%s' "${profiles[*]}"
}

function openssl_supports_ed25519() {
    local bin="$1"
    local tmp_file
    tmp_file="$(mktemp "${TMPDIR:-/tmp}/mn-ed25519-test.XXXXXX")"
    if "$bin" genpkey -algorithm ED25519 -out "$tmp_file" >/dev/null 2>&1; then
        rm -f "$tmp_file"
        return 0
    fi
    rm -f "$tmp_file"
    return 1
}

function resolve_ed25519_openssl() {
    local candidates=()
    local candidate resolved

    if [ -n "${OPENSSL_BIN:-}" ]; then
        if resolved="$(command -v "$OPENSSL_BIN" 2>/dev/null)" && [ -n "$resolved" ] && [ -x "$resolved" ] && openssl_supports_ed25519 "$resolved"; then
            printf '%s\n' "$resolved"
            return 0
        fi
        print_error "OPENSSL_BIN=${OPENSSL_BIN} does not support ED25519 key generation."
        print_error "Set OPENSSL_BIN to an OpenSSL 3 binary, for example /opt/homebrew/bin/openssl."
        exit 1
    fi
    if resolved="$(command -v openssl 2>/dev/null)" && [ -n "$resolved" ]; then
        candidates+=("$resolved")
    fi
    candidates+=(
        /opt/homebrew/bin/openssl
        /usr/local/bin/openssl
        /usr/local/opt/openssl@3/bin/openssl
        /opt/local/bin/openssl
    )

    for candidate in "${candidates[@]}"; do
        [ -x "$candidate" ] || continue
        if openssl_supports_ed25519 "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    print_error "An ED25519-capable OpenSSL is required to create OpenShell sandbox JWT keys."
    print_error "Install OpenSSL 3, put it on PATH, or set OPENSSL_BIN=/path/to/openssl."
    exit 1
}

function write_openshell_compose_config() {
    local gateway_dir="${MN_HOST_OPENSHELL_CONFIG_DIR}/gateways/openshell"
    local jwt_dir="${MN_HOST_OPENSHELL_STATE_DIR}/jwt"
    local openssl_bin tmp_dir
    mkdir -p "$gateway_dir"
    mkdir -p "$jwt_dir"
    if [ ! -s "${jwt_dir}/signing.pem" ] || [ ! -s "${jwt_dir}/public.pem" ] || [ ! -s "${jwt_dir}/kid" ]; then
        openssl_bin="$(resolve_ed25519_openssl)"
        tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mn-openshell-jwt.XXXXXX")"
        if ! "$openssl_bin" genpkey -algorithm ED25519 -out "${tmp_dir}/signing.pem" >/dev/null; then
            print_error "Failed to create OpenShell JWT signing key with ${openssl_bin}."
            rm -rf "$tmp_dir"
            exit 1
        fi
        if ! "$openssl_bin" pkey -in "${tmp_dir}/signing.pem" -pubout -out "${tmp_dir}/public.pem" >/dev/null; then
            print_error "Failed to create OpenShell JWT public key with ${openssl_bin}."
            rm -rf "$tmp_dir"
            exit 1
        fi
        if ! "$openssl_bin" rand -hex 8 > "${tmp_dir}/kid"; then
            print_error "Failed to create OpenShell JWT key id with ${openssl_bin}."
            rm -rf "$tmp_dir"
            exit 1
        fi
        mv "${tmp_dir}/signing.pem" "${jwt_dir}/signing.pem"
        mv "${tmp_dir}/public.pem" "${jwt_dir}/public.pem"
        mv "${tmp_dir}/kid" "${jwt_dir}/kid"
        rm -rf "$tmp_dir"
        chmod 600 "${jwt_dir}/signing.pem" 2>/dev/null || true
        chmod 644 "${jwt_dir}/public.pem" "${jwt_dir}/kid" 2>/dev/null || true
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
grpc_endpoint = "http://host.openshell.internal:${OPENSHELL_GATEWAY_PORT:-58080}"
network_name = "openshell-docker"
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

function write_runtime_compose_files() {
    local model_runner_model profiles network_name network_external network_token redis_password mn_cookie runtime_skills_root runtime_package_index context_memory_enabled otterdesk_context_memory_enabled membrane_engine_tag membrane_engine_image
    if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
        context_engine_source_dir >/dev/null
    fi
    model_runner_model="${MN_CONTEXT_MODEL_RUNNER_MODEL:-hf.co/homerquan/mn-context-engine-model-v-Q4_K_M}"
    profiles="$(compose_profiles)"
    network_name="${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
    network_external="$(resolve_docker_network_external "$network_name")"
    network_token="$(resolve_network_token)"
    redis_password="$(resolve_redis_password "mirror_neuron_password_admin")"
    mn_cookie="$(resolve_mn_cookie)"
    printf '%s\n' "mirror_neuron_password" > "${INSTALL_DIR}/grpc_auth.token"
    printf '%s\n' "mirror_neuron_password_admin" > "${INSTALL_DIR}/grpc_admin.token"
    chmod 600 "${INSTALL_DIR}/grpc_auth.token" "${INSTALL_DIR}/grpc_admin.token" 2>/dev/null || true
    runtime_skills_root="${MN_SKILLS_ROOT:-${MN_HOST_HOME_DIR}/skills}"
    runtime_package_index="${MN_PACKAGE_INDEX_FILE:-}"
    membrane_engine_tag="${MN_MEMBRANE_ENGINE_IMAGE_TAG:-${INSTALL_VERSION:-v${MN_PACKAGE_VERSION:-1.2.18}}}"
    if [[ "$membrane_engine_tag" != v* ]]; then
        membrane_engine_tag="v${membrane_engine_tag}"
    fi
    membrane_engine_image="${ENGINE_IMAGE:-${MN_MEMBRANE_ENGINE_IMAGE:-us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/membrane-context-engine:${membrane_engine_tag}}}"
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
MN_HOST_OPENSHELL_CONFIG_DIR=${MN_HOST_OPENSHELL_CONFIG_DIR}
MN_HOST_OPENSHELL_STATE_DIR=${MN_HOST_OPENSHELL_STATE_DIR}
MEMBRANE_DIR=${MEMBRANE_DIR}
ENGINE_IMAGE=${membrane_engine_image}
MN_MEMBRANE_ENGINE_IMAGE=${membrane_engine_image}
MN_MEMBRANE_ENGINE_IMAGE_TAG=${membrane_engine_tag}
MN_REDIS_IMAGE=${MN_REDIS_IMAGE:-redis:8}
MN_CONTEXT_MODEL_RUNNER_MODEL=${model_runner_model}
MN_GRPC_BIND_HOST=${MN_GRPC_BIND_HOST:-127.0.0.1}
MN_GRPC_PORT=${MN_GRPC_PORT:-55051}
MN_GRPC_TARGET=${MN_GRPC_TARGET:-localhost:${MN_GRPC_PORT:-55051}}
MN_GRPC_ADVERTISE_PORT=${MN_GRPC_ADVERTISE_PORT:-${MN_GRPC_PORT:-55051}}
MN_NATIVE_SDK_GRPC_HOST=${MN_NATIVE_SDK_GRPC_HOST:-127.0.0.1}
MN_NATIVE_SDK_GRPC_PORT=${MN_NATIVE_SDK_GRPC_PORT:-55052}
MN_NATIVE_SDK_GRPC_ADVERTISE_HOST=${MN_NATIVE_SDK_GRPC_ADVERTISE_HOST:-${MN_NETWORK_ADVERTISE_HOST:-}}
MN_NATIVE_SDK_GRPC_ADVERTISE_PORT=${MN_NATIVE_SDK_GRPC_ADVERTISE_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_NATIVE_SDK_GRPC_TARGET=${MN_NATIVE_SDK_GRPC_TARGET:-mn-native-sdk-grpc:55052}
MN_NATIVE_SDK_GRPC_PROXY_PORT=${MN_NATIVE_SDK_GRPC_PROXY_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_NATIVE_SDK_GRPC_PROXY_TARGET_HOST=${MN_NATIVE_SDK_GRPC_PROXY_TARGET_HOST:-host.docker.internal}
MN_NATIVE_SDK_GRPC_PROXY_TARGET_PORT=${MN_NATIVE_SDK_GRPC_PROXY_TARGET_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_LITELLM_GATEWAY_BIND_HOST=${MN_LITELLM_GATEWAY_BIND_HOST:-127.0.0.1}
MN_LITELLM_GATEWAY_PORT=${MN_LITELLM_GATEWAY_PORT:-4000}
MN_LITELLM_GATEWAY_INTERNAL_API_BASE=${MN_LITELLM_GATEWAY_INTERNAL_API_BASE:-http://mn-litellm-proxy:4000/v1}
MN_API_HOST=${MN_API_HOST:-localhost}
MN_API_PORT=${MN_API_PORT:-54001}
MN_DIST_PORT=${MN_DIST_PORT:-54370}
MN_WEB_UI_HOST=${MN_WEB_UI_HOST:-localhost}
MN_WEB_UI_PORT=${MN_WEB_UI_PORT:-55173}
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
MN_SKILLS_ROOT=${runtime_skills_root}
MN_PACKAGE_INDEX_FILE=${runtime_package_index}
MN_PIP_INDEX_URL=${MN_PIP_INDEX_URL:-${MN_PYTHON_INDEX_URL:-}}
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
OPENSHELL_GATEWAY_ENDPOINT=${OPENSHELL_GATEWAY_ENDPOINT:-http://127.0.0.1:${OPENSHELL_GATEWAY_PORT:-58080}}
OPENSHELL_GATEWAY_USER=${OPENSHELL_GATEWAY_USER}
OPENSHELL_GATEWAY_DOCKER_GROUP=${OPENSHELL_GATEWAY_DOCKER_GROUP}
DOCKER_HOST_SOCKET=${DOCKER_HOST_SOCKET}
MN_COOKIE=${mn_cookie}
MN_GRPC_AUTH_TOKEN=mirror_neuron_password
MN_GRPC_ADMIN_TOKEN=mirror_neuron_password_admin
EOF
    chmod 600 "$RUNTIME_COMPOSE_ENV" 2>/dev/null || true
}

function runtime_compose() {
    if command -v docker-compose >/dev/null 2>&1; then
        docker-compose --env-file "$RUNTIME_COMPOSE_ENV" -f "$RUNTIME_COMPOSE_FILE" "$@"
    else
        docker compose --env-file "$RUNTIME_COMPOSE_ENV" -f "$RUNTIME_COMPOSE_FILE" "$@"
    fi
}

function runtime_container_name_for_service() {
    case "$1" in
        redis) echo "mirror-neuron-redis" ;;
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
}

function ensure_docker_model_runner() {
    if [ "$INSTALL_CONTEXT_ENGINE" != "Y" ] && [ "${INSTALL_DOCKER_MODEL_RUNNER:-N}" != "Y" ] && [ "${MN_ENABLE_DOCKER_MODEL_RUNNER:-N}" != "Y" ]; then
        return 0
    fi

    if ! docker model --help >/dev/null 2>&1; then
        print_error "Docker Model Runner CLI is not available. Upgrade Docker Desktop/Engine to a version with 'docker model' support."
        exit 1
    fi

    if docker model status >/dev/null 2>&1; then
        return 0
    fi

    print_warning "Docker Model Runner is not running; attempting to enable it."
    if docker desktop enable model-runner >/dev/null 2>&1 && docker model status >/dev/null 2>&1; then
        return 0
    fi

    if docker model install-runner --help >/dev/null 2>&1; then
        docker model install-runner >/dev/null 2>&1 || true
        docker model start-runner >/dev/null 2>&1 || true
        if docker model status >/dev/null 2>&1; then
            return 0
        fi
    fi

    print_error "Docker Model Runner is not ready. Enable it in Docker Desktop Settings > AI, or run 'docker model install-runner' and 'docker model start-runner' on Docker Engine."
    exit 1
}

function start_runtime_compose_sidecars() {
    local services=()
    [ "$INSTALL_REDIS" = "Y" ] && services+=("redis")
    grep -q '^  mn-native-sdk-grpc:' "$RUNTIME_COMPOSE_FILE" 2>/dev/null && services+=("mn-native-sdk-grpc")
    grep -q '^  mn-litellm-proxy:' "$RUNTIME_COMPOSE_FILE" 2>/dev/null && services+=("mn-litellm-proxy")
    [ "$INSTALL_OPENSHELL" = "Y" ] && services+=("openshell")
    if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
        services+=("membrane-context-engine")
    fi
    if [ "${#services[@]}" -gt 0 ]; then
        remove_stale_runtime_containers_for_services context-engine-model "${services[@]}"
        ensure_docker_model_runner
        if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
            runtime_compose build membrane-context-engine
        fi
        runtime_compose up -d "${services[@]}" >/dev/null
    fi
}

print_step "Checking Python runtime"
resolve_python_runtime

EXISTING_INSTALL="N"
if [ -d "$INSTALL_DIR" ] || [ -f "$BIN_DIR/mn" ]; then
    print_warning "MirrorNeuron appears to be already installed."
    if [ "$NON_INTERACTIVE" != "Y" ]; then
        REINSTALL=$(ask "Do you want to reinstall (overwrite old ones)?" "$REINSTALL")
    fi
    if [ "$REINSTALL" = "N" ]; then
        echo -e "${YELLOW}Installation cancelled by user.${RESET}" >&3
        exit 0
    fi
    echo "" >&3
    EXISTING_INSTALL="Y"
fi

# Interactive Prompts
echo -e "${CYAN}${BOLD}Configuration${RESET}" >&3
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

if [ "$INSTALL_WEB_UI" = "Y" ]; then
    require_cmd npm
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

    DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-1}" docker build -t mirror-neuron-core . >/dev/null 2>&1
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
    print_step "Installing Web UI"
    if [ -z "${INSTALL_VERSION:-}" ] && [ -n "$SOURCE_WORKSPACE" ] && [ -d "$SOURCE_WORKSPACE/mn-web-ui" ]; then
        print_success "Using local Web UI source from $SOURCE_WORKSPACE/mn-web-ui."
    fi
    (
        UI_DIR="${INSTALL_DIR}/webui"
        rm -rf "$LEGACY_UI_DIR"
        if [ -z "${INSTALL_VERSION:-}" ] && [ -n "$SOURCE_WORKSPACE" ] && [ -d "$SOURCE_WORKSPACE/mn-web-ui" ]; then
            cd "$SOURCE_WORKSPACE/mn-web-ui"
            run_quiet "web-ui-npm-install-local" npm install
            run_quiet "web-ui-npm-build-local" npm run build
            rm -rf "$UI_DIR"
            ln -s "$SOURCE_WORKSPACE/mn-web-ui" "$UI_DIR"
        elif [ -d "$UI_DIR" ]; then
            cd "$UI_DIR"
            github_checkout_existing
            run_quiet "web-ui-npm-install-existing" npm install
            run_quiet "web-ui-npm-build-existing" npm run build
        else
            run_quiet "web-ui-git-clone" github_clone https://github.com/MirrorNeuronLab/mn-web-ui.git "$UI_DIR"
            cd "$UI_DIR"
            run_quiet "web-ui-npm-install-github" npm install
            run_quiet "web-ui-npm-build-github" npm run build
        fi
    ) &
    spinner $! "Cloning and building Web UI (React)"
fi

if [ "$INSTALL_REDIS" = "Y" ] || [ "$INSTALL_CONTEXT_ENGINE" = "Y" ] || [ "$INSTALL_OPENSHELL" = "Y" ]; then
    print_step "Setting up Docker runtime services with Compose"
    if [ "$INSTALL_OPENSHELL" = "Y" ]; then
        install_openshell_cli
    fi
    ( start_runtime_compose_sidecars ) &
    spinner $! "Docker runtime services are available"
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
    print_success "Command symlinks created."
else
    print_warning "Skipping command symlink creation because CLI/API installation is disabled."
fi

echo "" >&3
print_success "MirrorNeuron GitHub installation successfully completed!" >&3
if [ "$INSTALL_CLI" = "Y" ]; then
    echo -e "CLI is available as ${YELLOW}mn${RESET}." >&3
fi
if [ "$INSTALL_API" = "Y" ]; then
    echo -e "API is available as ${YELLOW}mn-api${RESET}." >&3
fi
if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
    echo -e "Membrane context engine is available on ${YELLOW}${MN_CONTEXT_ADDR:-localhost:50052}${RESET}." >&3
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
        if [[ "$line" == *"PATH"* && "$line" == *"$BIN_DIR"* ]]; then
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

    [[ ":$PATH:" != *":$BIN_DIR:"* ]] && needs_path="Y"

    if [ "$needs_path" = "N" ] && [ "$needs_runtime_home" = "N" ]; then
        return
    fi

    if [ "$needs_path" = "Y" ]; then
        echo -e "\n${YELLOW}${BOLD}Note:${RESET} ${YELLOW}$BIN_DIR is not in your PATH.${RESET}" >&3
    fi
    if [ "$needs_runtime_home" = "Y" ]; then
        echo -e "${YELLOW}Persisting MN_HOME=${INSTALL_DIR} for future terminal sessions.${RESET}" >&3
    fi

    local detected_profiles=()
    [ -f "$HOME/.zshrc" ] && detected_profiles+=("$HOME/.zshrc")
    [ -f "$HOME/.bashrc" ] && detected_profiles+=("$HOME/.bashrc")
    [ -f "$HOME/.bash_profile" ] && detected_profiles+=("$HOME/.bash_profile")
    [ -f "$HOME/.profile" ] && detected_profiles+=("$HOME/.profile")

    if [ ${#detected_profiles[@]} -eq 0 ]; then
        detected_profiles+=("$HOME/.profile")
    fi

    local profile path_line home_line wrote_header wrote_profile
    path_line="export PATH=\"$BIN_DIR:\$PATH\""
    if [ "$INSTALL_DIR" = "$default_home" ]; then
        home_line='export MN_HOME="$HOME/.mn"'
    else
        home_line="export MN_HOME=$(shell_escape_value "$INSTALL_DIR")"
    fi

    for profile in "${detected_profiles[@]}"; do
        wrote_header="N"
        wrote_profile="N"
        if [ "$needs_path" = "Y" ] && ! profile_has_bin_path "$profile"; then
            [ "$wrote_header" = "N" ] && echo -e "\n# MN and OTTERDESK" >> "$profile" && wrote_header="Y"
            echo "$path_line" >> "$profile"
            wrote_profile="Y"
        fi
        if [ "$needs_runtime_home" = "Y" ] && ! profile_has_runtime_home "$profile"; then
            [ "$wrote_header" = "N" ] && echo -e "\n# MN and OTTERDESK" >> "$profile" && wrote_header="Y"
            echo "$home_line" >> "$profile"
            wrote_profile="Y"
        fi
        if [ "$wrote_profile" = "Y" ]; then
            echo -e "Automatically added MirrorNeuron shell exports to ${CYAN}$profile${RESET}" >&3
        fi
    done

    echo -e "${YELLOW}Please restart your terminal or run \`source ~/.zshrc\` (or your shell's configuration file) to use the updated MirrorNeuron environment.${RESET}" >&3
}

ensure_shell_profile_exports

echo -e "\n${BOLD}Quick Start:${RESET}" >&3
if [ "$START_AS_WORKER" = "Y" ]; then
    echo -e "  1. Start the server (Core & API): ${GREEN}mn runtime start --worker-node${RESET}" >&3
else
    echo -e "  1. Start the server (Core & API): ${GREEN}mn runtime start${RESET}" >&3
fi
if [ "$INSTALL_WEB_UI" = "Y" ]; then
    echo -e "  2. Start the UI:   ${GREEN}cd ${INSTALL_DIR}/webui && npm run dev${RESET}" >&3
fi
echo -e "  3. Use the CLI:    ${GREEN}mn node list${RESET}\n" >&3

if [ "$START_NOW" = "Y" ]; then
    print_step "Starting MirrorNeuron Server..."
    if [ "$START_AS_WORKER" = "Y" ]; then
        if ! "$VENV_DIR/bin/mn" runtime start --worker-node; then
            print_warning "mn runtime start --worker-node failed; starting worker gateway services with Docker Compose."
            runtime_compose up -d mn-native-sdk-grpc mn-litellm-proxy
        fi
    else
        if ! "$VENV_DIR/bin/mn" runtime start; then
            print_warning "mn runtime start failed; starting MirrorNeuron Docker Compose runtime."
            runtime_compose up -d
            "$VENV_DIR/bin/mn" runtime restart-sidecars --api >/dev/null 2>&1 || print_warning "MirrorNeuron Core started, but the REST API sidecar did not start automatically."
        fi
    fi
fi
}

run_install_local() {
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

SCRIPT_DIR="$(mn_script_dir)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

INSTALL_DIR="${MN_HOME:-${HOME}/.mn}"
BIN_DIR="${HOME}/.local/bin"
VENV_DIR="${HOME}/.local/share/mn_venv"
UI_LINK_DIR="${INSTALL_DIR}/webui"
LEGACY_UI_LINK_DIR="${INSTALL_DIR}_ui"
RUNTIME_COMPOSE_TEMPLATE="${SCRIPT_DIR}/docker-compose.yml"
RUNTIME_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
RUNTIME_COMPOSE_ENV="${INSTALL_DIR}/docker-compose.env"

CORE_DIR="${WORKSPACE_DIR}/MirrorNeuron"
CLI_DIR="${WORKSPACE_DIR}/mn-cli"
API_DIR="${WORKSPACE_DIR}/mn-api"
PY_SDK_DIR="${WORKSPACE_DIR}/mn-python-sdk"
WEB_UI_DIR="${WORKSPACE_DIR}/mn-web-ui"
SKILLS_DIR="${WORKSPACE_DIR}/mn-skills"
BLUEPRINT_SUPPORT_SKILL_DIR="${SKILLS_DIR}/blueprint_support_skill"
BLUEPRINTS_DIR="${WORKSPACE_DIR}/mn-blueprints"
DOCS_DIR="${WORKSPACE_DIR}/mn-docs"
SYSTEM_TESTS_DIR="${WORKSPACE_DIR}/mn-system-tests"
MEMBRANE_DIR="${WORKSPACE_DIR}/Membrane"
MN_HOST_HOME_DIR="${MN_HOST_HOME_DIR:-${MN_HOST_MN_DIR:-${INSTALL_DIR}}}"
MN_HOST_ARTIFACTS_DIR="${MN_HOST_ARTIFACTS_DIR:-${MN_HOST_HOME_DIR}/runs}"
MN_HOST_BLOB_STORE_DIR="${MN_HOST_BLOB_STORE_DIR:-${MN_HOST_HOME_DIR}/blobs}"
MN_HOST_SHARED_STORAGE_ROOT="${MN_HOST_SHARED_STORAGE_ROOT:-${MN_HOST_SHARED_ARTIFACT_ROOT:-${MN_HOST_HOME_DIR}/shared}}"
MN_SYNCTHING_ENABLED="${MN_SYNCTHING_ENABLED:-auto}"
MN_SYNCTHING_IMAGE="${MN_SYNCTHING_IMAGE:-syncthing/syncthing:latest}"
MN_SYNCTHING_GUI_PORT="${MN_SYNCTHING_GUI_PORT:-58384}"
MN_SYNCTHING_SYNC_PORT="${MN_SYNCTHING_SYNC_PORT:-22000}"
MN_HOST_OPENSHELL_CONFIG_DIR="${OPENSHELL_CONTAINER_CONFIG_DIR:-${HOME}/.config/openshell-mirror-neuron}"
MN_HOST_OPENSHELL_STATE_DIR="${MN_HOST_OPENSHELL_STATE_DIR:-${INSTALL_DIR}/openshell-state}"
OPENSHELL_GATEWAY_USER="${OPENSHELL_GATEWAY_USER:-$(id -u):$(id -g)}"
if [ -z "${DOCKER_HOST_SOCKET:-}" ]; then
    if [ -S "${HOME}/.docker/run/docker.sock" ]; then
        DOCKER_HOST_SOCKET="${HOME}/.docker/run/docker.sock"
    else
        DOCKER_HOST_SOCKET="/var/run/docker.sock"
    fi
fi
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
START_AS_WORKER="N"
NON_INTERACTIVE="Y"

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

function run_quiet() {
    local label="$1"
    shift
    local log_dir="${TMPDIR:-/tmp}/mirror_neuron_install"
    mkdir -p "$log_dir"
    local log_file="${log_dir}/${label//[^A-Za-z0-9_.-]/_}.$$.log"

    if ! "$@" >"$log_file" 2>&1; then
        print_error "$label failed. Log: $log_file"
        tail -n 20 "$log_file" >&3 2>/dev/null || true
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

    print_success "Installed uv at $MN_UV_BIN."
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
    print_success "Using uv-managed Python $(python_version "$managed_bin") at $managed_bin."
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
            print_success "Using Python $(python_version "$MN_PYTHON_BIN") at $MN_PYTHON_BIN."
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
  --web-ui              Enable local Web UI npm install/build.
  --no-web-ui           Skip local Web UI npm install/build.
  --redis               Enable Redis Docker setup.
  --no-redis            Skip Redis Docker setup.
  --context-engine      Install/start Membrane context engine.
  --no-context-engine   Skip Membrane context engine setup.
  --openshell           Install/start OpenShell gateway for sandbox workers.
  --no-openshell        Skip OpenShell gateway setup.
  --syncthing / --no-syncthing
                        Enable or skip Syncthing shared-storage replication.
  --no-skills           Skip editable install of packages under mn-skills.
  --start               Start MirrorNeuron after install.
  --no-start            Skip starting MirrorNeuron after install.
  --start-as-worker     Start MirrorNeuron as a worker node after install.
  --python PATH         Same as MN_PYTHON. Must be Python 3.11.x.
  --no-managed-python   Do not use uv to install a private Python runtime.
  MN_PYTHON=/path       Use a specific Python 3.11.x interpreter.
  MN_HOME=/path         Override the runtime state directory. Defaults to ${HOME}/.mn.
  MN_MANAGED_PYTHON=0   Disable uv-managed private Python fallback.
  -h, --help            Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes|-y) NON_INTERACTIVE="Y" ;;
        --interactive) NON_INTERACTIVE="N" ;;
        --no-reinstall) ;; # Backward-compatible no-op; local installs refresh in place.
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
        --start-as-worker) START_AS_WORKER="Y"; START_NOW="Y" ;;
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

function openssl_supports_ed25519() {
    local bin="$1"
    local tmp_file
    tmp_file="$(mktemp "${TMPDIR:-/tmp}/mn-ed25519-test.XXXXXX")"
    if "$bin" genpkey -algorithm ED25519 -out "$tmp_file" >/dev/null 2>&1; then
        rm -f "$tmp_file"
        return 0
    fi
    rm -f "$tmp_file"
    return 1
}

function resolve_ed25519_openssl() {
    local candidates=()
    local candidate resolved

    if [ -n "${OPENSSL_BIN:-}" ]; then
        if resolved="$(command -v "$OPENSSL_BIN" 2>/dev/null)" && [ -n "$resolved" ] && [ -x "$resolved" ] && openssl_supports_ed25519 "$resolved"; then
            printf '%s\n' "$resolved"
            return 0
        fi
        print_error "OPENSSL_BIN=${OPENSSL_BIN} does not support ED25519 key generation."
        print_error "Set OPENSSL_BIN to an OpenSSL 3 binary, for example /opt/homebrew/bin/openssl."
        exit 1
    fi
    if resolved="$(command -v openssl 2>/dev/null)" && [ -n "$resolved" ]; then
        candidates+=("$resolved")
    fi
    candidates+=(
        /opt/homebrew/bin/openssl
        /usr/local/bin/openssl
        /usr/local/opt/openssl@3/bin/openssl
        /opt/local/bin/openssl
    )

    for candidate in "${candidates[@]}"; do
        [ -x "$candidate" ] || continue
        if openssl_supports_ed25519 "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    print_error "An ED25519-capable OpenSSL is required to create OpenShell sandbox JWT keys."
    print_error "Install OpenSSL 3, put it on PATH, or set OPENSSL_BIN=/path/to/openssl."
    exit 1
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
    runtime_compose build membrane-context-engine
    runtime_compose up -d membrane-context-engine >/dev/null
}

function compose_profiles() {
    local profiles=()
    [ "$INSTALL_OPENSHELL" = "Y" ] && profiles+=("openshell")
    [ "$INSTALL_CONTEXT_ENGINE" = "Y" ] && profiles+=("context")
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
    local openssl_bin tmp_dir
    mkdir -p "$gateway_dir"
    mkdir -p "$jwt_dir"
    if [ ! -s "${jwt_dir}/signing.pem" ] || [ ! -s "${jwt_dir}/public.pem" ] || [ ! -s "${jwt_dir}/kid" ]; then
        openssl_bin="$(resolve_ed25519_openssl)"
        tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mn-openshell-jwt.XXXXXX")"
        if ! "$openssl_bin" genpkey -algorithm ED25519 -out "${tmp_dir}/signing.pem" >/dev/null; then
            print_error "Failed to create OpenShell JWT signing key with ${openssl_bin}."
            rm -rf "$tmp_dir"
            exit 1
        fi
        if ! "$openssl_bin" pkey -in "${tmp_dir}/signing.pem" -pubout -out "${tmp_dir}/public.pem" >/dev/null; then
            print_error "Failed to create OpenShell JWT public key with ${openssl_bin}."
            rm -rf "$tmp_dir"
            exit 1
        fi
        if ! "$openssl_bin" rand -hex 8 > "${tmp_dir}/kid"; then
            print_error "Failed to create OpenShell JWT key id with ${openssl_bin}."
            rm -rf "$tmp_dir"
            exit 1
        fi
        mv "${tmp_dir}/signing.pem" "${jwt_dir}/signing.pem"
        mv "${tmp_dir}/public.pem" "${jwt_dir}/public.pem"
        mv "${tmp_dir}/kid" "${jwt_dir}/kid"
        rm -rf "$tmp_dir"
        chmod 600 "${jwt_dir}/signing.pem" 2>/dev/null || true
        chmod 644 "${jwt_dir}/public.pem" "${jwt_dir}/kid" 2>/dev/null || true
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
grpc_endpoint = "http://host.openshell.internal:${OPENSHELL_GATEWAY_PORT:-58080}"
network_name = "openshell-docker"
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

function write_runtime_compose_files() {
    local model_runner_model profiles network_name network_external network_token redis_password mn_cookie runtime_skills_root runtime_package_index context_memory_enabled otterdesk_context_memory_enabled membrane_engine_tag membrane_engine_image
    model_runner_model="${MN_CONTEXT_MODEL_RUNNER_MODEL:-hf.co/homerquan/mn-context-engine-model-v-Q4_K_M}"
    profiles="$(compose_profiles)"
    network_name="${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
    network_external="$(resolve_docker_network_external "$network_name")"
    network_token="$(resolve_network_token)"
    redis_password="$(resolve_redis_password "mirror_neuron_password_admin")"
    mn_cookie="$(resolve_mn_cookie)"
    printf '%s\n' "mirror_neuron_password" > "${INSTALL_DIR}/grpc_auth.token"
    printf '%s\n' "mirror_neuron_password_admin" > "${INSTALL_DIR}/grpc_admin.token"
    chmod 600 "${INSTALL_DIR}/grpc_auth.token" "${INSTALL_DIR}/grpc_admin.token" 2>/dev/null || true
    runtime_skills_root="${MN_SKILLS_ROOT:-${MN_HOST_HOME_DIR}/skills}"
    runtime_package_index="${MN_PACKAGE_INDEX_FILE:-}"
    membrane_engine_tag="${MN_MEMBRANE_ENGINE_IMAGE_TAG:-${INSTALL_VERSION:-v${MN_PACKAGE_VERSION:-1.2.18}}}"
    if [[ "$membrane_engine_tag" != v* ]]; then
        membrane_engine_tag="v${membrane_engine_tag}"
    fi
    membrane_engine_image="${ENGINE_IMAGE:-${MN_MEMBRANE_ENGINE_IMAGE:-us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/membrane-context-engine:${membrane_engine_tag}}}"
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
MN_HOST_OPENSHELL_CONFIG_DIR=${MN_HOST_OPENSHELL_CONFIG_DIR}
MN_HOST_OPENSHELL_STATE_DIR=${MN_HOST_OPENSHELL_STATE_DIR}
MEMBRANE_DIR=${MEMBRANE_DIR}
ENGINE_IMAGE=${membrane_engine_image}
MN_MEMBRANE_ENGINE_IMAGE=${membrane_engine_image}
MN_MEMBRANE_ENGINE_IMAGE_TAG=${membrane_engine_tag}
MN_REDIS_IMAGE=${MN_REDIS_IMAGE:-redis:8}
MN_CONTEXT_MODEL_RUNNER_MODEL=${model_runner_model}
MN_GRPC_BIND_HOST=${MN_GRPC_BIND_HOST:-127.0.0.1}
MN_GRPC_PORT=${MN_GRPC_PORT:-55051}
MN_GRPC_TARGET=${MN_GRPC_TARGET:-localhost:${MN_GRPC_PORT:-55051}}
MN_GRPC_ADVERTISE_PORT=${MN_GRPC_ADVERTISE_PORT:-${MN_GRPC_PORT:-55051}}
MN_NATIVE_SDK_GRPC_HOST=${MN_NATIVE_SDK_GRPC_HOST:-127.0.0.1}
MN_NATIVE_SDK_GRPC_PORT=${MN_NATIVE_SDK_GRPC_PORT:-55052}
MN_NATIVE_SDK_GRPC_ADVERTISE_HOST=${MN_NATIVE_SDK_GRPC_ADVERTISE_HOST:-${MN_NETWORK_ADVERTISE_HOST:-}}
MN_NATIVE_SDK_GRPC_ADVERTISE_PORT=${MN_NATIVE_SDK_GRPC_ADVERTISE_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_NATIVE_SDK_GRPC_TARGET=${MN_NATIVE_SDK_GRPC_TARGET:-mn-native-sdk-grpc:55052}
MN_NATIVE_SDK_GRPC_PROXY_PORT=${MN_NATIVE_SDK_GRPC_PROXY_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_NATIVE_SDK_GRPC_PROXY_TARGET_HOST=${MN_NATIVE_SDK_GRPC_PROXY_TARGET_HOST:-host.docker.internal}
MN_NATIVE_SDK_GRPC_PROXY_TARGET_PORT=${MN_NATIVE_SDK_GRPC_PROXY_TARGET_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_LITELLM_GATEWAY_BIND_HOST=${MN_LITELLM_GATEWAY_BIND_HOST:-127.0.0.1}
MN_LITELLM_GATEWAY_PORT=${MN_LITELLM_GATEWAY_PORT:-4000}
MN_LITELLM_GATEWAY_INTERNAL_API_BASE=${MN_LITELLM_GATEWAY_INTERNAL_API_BASE:-http://mn-litellm-proxy:4000/v1}
MN_API_HOST=${MN_API_HOST:-localhost}
MN_API_PORT=${MN_API_PORT:-54001}
MN_DIST_PORT=${MN_DIST_PORT:-54370}
MN_WEB_UI_HOST=${MN_WEB_UI_HOST:-localhost}
MN_WEB_UI_PORT=${MN_WEB_UI_PORT:-55173}
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
MN_SKILLS_ROOT=${runtime_skills_root}
MN_PACKAGE_INDEX_FILE=${runtime_package_index}
MN_PIP_INDEX_URL=${MN_PIP_INDEX_URL:-${MN_PYTHON_INDEX_URL:-}}
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
OPENSHELL_GATEWAY_ENDPOINT=${OPENSHELL_GATEWAY_ENDPOINT:-http://127.0.0.1:${OPENSHELL_GATEWAY_PORT:-58080}}
OPENSHELL_GATEWAY_USER=${OPENSHELL_GATEWAY_USER}
OPENSHELL_GATEWAY_DOCKER_GROUP=${OPENSHELL_GATEWAY_DOCKER_GROUP}
DOCKER_HOST_SOCKET=${DOCKER_HOST_SOCKET}
MN_COOKIE=${mn_cookie}
MN_GRPC_AUTH_TOKEN=mirror_neuron_password
MN_GRPC_ADMIN_TOKEN=mirror_neuron_password_admin
EOF
    chmod 600 "$RUNTIME_COMPOSE_ENV" 2>/dev/null || true
}

function runtime_compose() {
    if command -v docker-compose >/dev/null 2>&1; then
        docker-compose --env-file "$RUNTIME_COMPOSE_ENV" -f "$RUNTIME_COMPOSE_FILE" "$@"
    else
        docker compose --env-file "$RUNTIME_COMPOSE_ENV" -f "$RUNTIME_COMPOSE_FILE" "$@"
    fi
}

function runtime_container_name_for_service() {
    case "$1" in
        redis) echo "mirror-neuron-redis" ;;
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
}

function ensure_docker_model_runner() {
    if [ "$INSTALL_CONTEXT_ENGINE" != "Y" ] && [ "${INSTALL_DOCKER_MODEL_RUNNER:-N}" != "Y" ] && [ "${MN_ENABLE_DOCKER_MODEL_RUNNER:-N}" != "Y" ]; then
        return 0
    fi

    if ! docker model --help >/dev/null 2>&1; then
        print_error "Docker Model Runner CLI is not available. Upgrade Docker Desktop/Engine to a version with 'docker model' support."
        exit 1
    fi

    if docker model status >/dev/null 2>&1; then
        return 0
    fi

    print_warning "Docker Model Runner is not running; attempting to enable it."
    if docker desktop enable model-runner >/dev/null 2>&1 && docker model status >/dev/null 2>&1; then
        return 0
    fi

    if docker model install-runner --help >/dev/null 2>&1; then
        docker model install-runner >/dev/null 2>&1 || true
        docker model start-runner >/dev/null 2>&1 || true
        if docker model status >/dev/null 2>&1; then
            return 0
        fi
    fi

    print_error "Docker Model Runner is not ready. Enable it in Docker Desktop Settings > AI, or run 'docker model install-runner' and 'docker model start-runner' on Docker Engine."
    exit 1
}

function start_runtime_compose_sidecars() {
    local services=()
    [ "$INSTALL_REDIS" = "Y" ] && services+=("redis")
    grep -q '^  mn-native-sdk-grpc:' "$RUNTIME_COMPOSE_FILE" 2>/dev/null && services+=("mn-native-sdk-grpc")
    grep -q '^  mn-litellm-proxy:' "$RUNTIME_COMPOSE_FILE" 2>/dev/null && services+=("mn-litellm-proxy")
    [ "$INSTALL_OPENSHELL" = "Y" ] && services+=("openshell")
    if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
        services+=("membrane-context-engine")
    fi
    if [ "${#services[@]}" -gt 0 ]; then
        remove_stale_runtime_containers_for_services context-engine-model "${services[@]}"
        ensure_docker_model_runner
        if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
            runtime_compose build membrane-context-engine
        fi
        runtime_compose up -d "${services[@]}"
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
        if [[ "$line" == *"PATH"* && "$line" == *"$BIN_DIR"* ]]; then
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

    [[ ":$PATH:" != *":$BIN_DIR:"* ]] && needs_path="Y"

    if [ "$needs_path" = "N" ] && [ "$needs_runtime_home" = "N" ]; then
        return
    fi

    if [ "$needs_path" = "Y" ]; then
        print_warning "${BIN_DIR} is not in your PATH."
    fi
    if [ "$needs_runtime_home" = "Y" ]; then
        print_warning "Persisting MN_HOME=${INSTALL_DIR} for future terminal sessions."
    fi

    local detected_profiles=()
    [ -f "$HOME/.zshrc" ] && detected_profiles+=("$HOME/.zshrc")
    [ -f "$HOME/.bashrc" ] && detected_profiles+=("$HOME/.bashrc")
    [ -f "$HOME/.bash_profile" ] && detected_profiles+=("$HOME/.bash_profile")
    [ -f "$HOME/.profile" ] && detected_profiles+=("$HOME/.profile")

    if [ "${#detected_profiles[@]}" -eq 0 ]; then
        detected_profiles+=("$HOME/.profile")
    fi

    local profile path_line home_line wrote_header wrote_profile
    path_line="export PATH=\"$BIN_DIR:\$PATH\""
    if [ "$INSTALL_DIR" = "$default_home" ]; then
        home_line='export MN_HOME="$HOME/.mn"'
    else
        home_line="export MN_HOME=$(shell_escape_value "$INSTALL_DIR")"
    fi

    for profile in "${detected_profiles[@]}"; do
        wrote_header="N"
        wrote_profile="N"
        if [ "$needs_path" = "Y" ] && ! profile_has_bin_path "$profile"; then
            [ "$wrote_header" = "N" ] && echo "" >> "$profile" && echo "# MN and OTTERDESK" >> "$profile" && wrote_header="Y"
            echo "$path_line" >> "$profile"
            wrote_profile="Y"
        fi
        if [ "$needs_runtime_home" = "Y" ] && ! profile_has_runtime_home "$profile"; then
            [ "$wrote_header" = "N" ] && echo "" >> "$profile" && echo "# MN and OTTERDESK" >> "$profile" && wrote_header="Y"
            echo "$home_line" >> "$profile"
            wrote_profile="Y"
        fi
        if [ "$wrote_profile" = "Y" ]; then
            echo -e "Added MirrorNeuron shell exports to ${CYAN}${profile}${RESET}" >&3
        fi
    done
}

print_header

require_install_dir_not_source
require_dir "$CORE_DIR" "MirrorNeuron core"
require_file "$CORE_DIR/Dockerfile" "MirrorNeuron Dockerfile"
require_mix_project_file "$CORE_DIR/mix.exs"
require_dir "$CLI_DIR" "mn-cli"
require_dir "$API_DIR" "mn-api"
require_dir "$PY_SDK_DIR" "mn-python-sdk"

if [ "$INSTALL_WEB_UI" = "Y" ]; then require_dir "$WEB_UI_DIR" "mn-web-ui"; fi
if [ "$INSTALL_SKILLS" = "Y" ]; then require_dir "$SKILLS_DIR" "mn-skills"; fi

print_step "Checking Python runtime"
resolve_python_runtime

if [ -d "$INSTALL_DIR" ] || [ -L "$INSTALL_DIR" ] || [ -d "$VENV_DIR" ] || [ -f "$BIN_DIR/mn" ]; then
    print_warning "MirrorNeuron appears to be already installed; refreshing local source install."
fi

echo -e "${CYAN}${BOLD}Configuration${RESET}" >&3
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

if [ "$INSTALL_WEB_UI" = "Y" ]; then
    require_cmd npm
fi
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
print_success "Local component links created under ${INSTALL_DIR}."

print_step "Building MirrorNeuron Core Docker image from local source"
(
    cd "$CORE_DIR"
    DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-1}" docker build -t mirror-neuron-core:latest .
)
print_success "Built local core image mirror-neuron-core:latest."

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
    "$VENV_DIR/bin/pip" install -e "$PY_SDK_DIR" >/dev/null
    if [ -f "$BLUEPRINT_SUPPORT_SKILL_DIR/pyproject.toml" ]; then
        "$VENV_DIR/bin/pip" install -e "$BLUEPRINT_SUPPORT_SKILL_DIR[webui]" >/dev/null
    fi
    "$VENV_DIR/bin/pip" install -e "$CLI_DIR" >/dev/null
    "$VENV_DIR/bin/pip" install -e "$API_DIR" >/dev/null
    if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
        "$VENV_DIR/bin/pip" install -e "$MEMBRANE_DIR/mn-context-engine-python-sdk" >/dev/null
    fi

    if [ "$INSTALL_SKILLS" = "Y" ]; then
        shopt -s nullglob
        for skill_pyproject in "$SKILLS_DIR"/*/pyproject.toml; do
            if [ "$(dirname "$skill_pyproject")" = "$BLUEPRINT_SUPPORT_SKILL_DIR" ]; then
                continue
            fi
            "$VENV_DIR/bin/pip" install -e "$(dirname "$skill_pyproject")" >/dev/null
        done
    fi
) &
spinner $! "Installed local editable Python packages"
require_local_cli_target_executables
VENV_INSTALL_OK="Y"
if [ -n "$VENV_BACKUP_DIR" ]; then
    rm -rf "$VENV_BACKUP_DIR"
fi
trap - EXIT

if [ "$INSTALL_WEB_UI" = "Y" ]; then
    print_step "Installing Web UI from local source"
    (
        cd "$WEB_UI_DIR"
        run_quiet "web-ui-npm-install-local" npm install
        run_quiet "web-ui-npm-build-local" npm run build
    ) &
    spinner $! "Installed and built local Web UI"
    if [ -e "$LEGACY_UI_LINK_DIR" ] || [ -L "$LEGACY_UI_LINK_DIR" ]; then
        rm -rf "$LEGACY_UI_LINK_DIR"
    fi
    if [ -e "$UI_LINK_DIR" ] || [ -L "$UI_LINK_DIR" ]; then
        rm -rf "$UI_LINK_DIR"
    fi
    replace_symlink "$WEB_UI_DIR" "$UI_LINK_DIR"
    replace_symlink "$WEB_UI_DIR" "$INSTALL_DIR/web-ui-source"
fi

if [ "$INSTALL_REDIS" = "Y" ] || [ "$INSTALL_CONTEXT_ENGINE" = "Y" ] || [ "$INSTALL_OPENSHELL" = "Y" ]; then
    print_step "Setting up Docker runtime services with Compose"
    if [ "$INSTALL_OPENSHELL" = "Y" ]; then
        install_openshell_cli
    fi
    start_runtime_compose_sidecars
    print_success "Docker runtime services are available."
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
print_success "Symlinks created in ${BIN_DIR}."

ensure_shell_profile_exports

echo "" >&3
print_success "MirrorNeuron local installation completed."
echo -e "Core image: ${YELLOW}mirror-neuron-core:latest${RESET} built from ${CYAN}${CORE_DIR}${RESET}" >&3
echo -e "CLI/API:    ${YELLOW}editable Python installs${RESET} from local workspace" >&3
echo -e "State dir:  ${CYAN}${INSTALL_DIR}${RESET}" >&3
echo -e "Cookie:     ${CYAN}${INSTALL_DIR}/erlang.cookie${RESET}" >&3
if [ "$INSTALL_WEB_UI" = "Y" ]; then
    echo -e "Web UI:     ${CYAN}${UI_LINK_DIR}${RESET} -> ${WEB_UI_DIR}" >&3
fi
if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
    echo -e "Membrane:   ${CYAN}${MEMBRANE_DIR}${RESET} on ${YELLOW}${MN_CONTEXT_ADDR:-localhost:50052}${RESET}" >&3
fi

echo -e "\n${BOLD}Quick Start:${RESET}" >&3
if [ "$START_AS_WORKER" = "Y" ]; then
    echo -e "  1. Start server: ${GREEN}mn runtime start --worker-node${RESET}" >&3
else
    echo -e "  1. Start server: ${GREEN}mn runtime start${RESET}" >&3
fi
if [ "$INSTALL_WEB_UI" = "Y" ]; then
    echo -e "  2. Start UI:     ${GREEN}cd ${UI_LINK_DIR} && npm run dev${RESET}" >&3
fi
echo -e "  3. Use CLI:      ${GREEN}mn node list${RESET}" >&3
echo -e "  4. Rebuild core after Elixir changes: ${GREEN}${SCRIPT_DIR}/install.sh --mode local --no-web-ui --no-skills${RESET}\n" >&3

if [ "$START_NOW" = "Y" ]; then
    print_step "Starting MirrorNeuron Server"
    "$VENV_DIR/bin/mn" runtime stop >/dev/null 2>&1 || true
    if [ "$START_AS_WORKER" = "Y" ]; then
        if ! "$VENV_DIR/bin/mn" runtime start --worker-node; then
            print_warning "mn runtime start --worker-node failed; starting worker gateway services with Docker Compose."
            runtime_compose up -d mn-native-sdk-grpc mn-litellm-proxy
        fi
    else
        if ! "$VENV_DIR/bin/mn" runtime start; then
            print_warning "mn runtime start failed; starting MirrorNeuron Docker Compose runtime."
            runtime_compose up -d
            "$VENV_DIR/bin/mn" runtime restart-sidecars --api >/dev/null 2>&1 || print_warning "MirrorNeuron Core started, but the REST API sidecar did not start automatically."
        fi
    fi
fi
}

run_install_binary() {
#!/usr/bin/env bash

set -euo pipefail

# Keep installer output visible even when a subcommand redirects stdout/stderr.
exec 3>&1

# Never let git/pip block the installer by asking for GitHub credentials.
export GIT_TERMINAL_PROMPT="${GIT_TERMINAL_PROMPT:-0}"
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new}"
export PIP_NO_INPUT="${PIP_NO_INPUT:-1}"

BOLD="\033[1m"
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
MAGENTA="\033[35m"
RESET="\033[0m"

SCRIPT_DIR="$(mn_script_dir)"
INSTALL_DIR="${MN_HOME:-${HOME}/.mn}"
BIN_DIR="${HOME}/.local/bin"
VENV_DIR="${HOME}/.local/share/mn_venv"
UI_DIR="${INSTALL_DIR}/webui"
LEGACY_UI_DIR="${INSTALL_DIR}_ui"
RUNTIME_COMPOSE_TEMPLATE="${MN_RUNTIME_COMPOSE_TEMPLATE:-}"
RUNTIME_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
RUNTIME_COMPOSE_ENV="${INSTALL_DIR}/docker-compose.env"
CORE_REPO="${MN_CORE_REPO:-MirrorNeuronLab/MirrorNeuron}"
INSTALL_VERSION="${MN_INSTALL_VERSION:-}"
INSTALL_VERSION_EXPLICIT="N"
[ -n "$INSTALL_VERSION" ] && INSTALL_VERSION_EXPLICIT="Y"
CORE_RELEASE_TAG="${MN_CORE_RELEASE_TAG:-}"
CORE_ASSET_URL="${MN_CORE_ASSET_URL:-}"
MN_PACKAGE_VERSION=""
MN_NPM_PACKAGE_VERSION=""
SKILLS_REPO="${MN_SKILLS_REPO:-MirrorNeuronLab/mn-skills}"
MEMBRANE_REPO="${MN_MEMBRANE_REPO:-MirrorNeuronLab/Membrane}"
MEMBRANE_GIT_URL="${MN_MEMBRANE_GIT_URL:-}"
MEMBRANE_DIR="${MN_MEMBRANE_DIR:-${INSTALL_DIR}/Membrane}"
PACKAGE_INDEX_FILE="${MN_PACKAGE_INDEX_FILE:-}"
MN_GAR_PROJECT="${MN_GAR_PROJECT:-}"
MN_GAR_LOCATION="${MN_GAR_LOCATION:-us-central1}"
MN_GAR_REPOSITORY="${MN_GAR_REPOSITORY:-mirrorneuron-python}"
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
MN_HOST_OPENSHELL_CONFIG_DIR="${OPENSHELL_CONTAINER_CONFIG_DIR:-${HOME}/.config/openshell-mirror-neuron}"
MN_HOST_OPENSHELL_STATE_DIR="${MN_HOST_OPENSHELL_STATE_DIR:-${INSTALL_DIR}/openshell-state}"
OPENSHELL_GATEWAY_USER="${OPENSHELL_GATEWAY_USER:-$(id -u):$(id -g)}"
if [ -z "${DOCKER_HOST_SOCKET:-}" ]; then
    if [ -S "${HOME}/.docker/run/docker.sock" ]; then
        DOCKER_HOST_SOCKET="${HOME}/.docker/run/docker.sock"
    else
        DOCKER_HOST_SOCKET="/var/run/docker.sock"
    fi
fi
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
INSTALL_BLUEPRINT_SUPPORT_SKILL="Y"
INSTALL_ALL_SKILLS="Y"
INSTALL_CLI="Y"
INSTALL_API="Y"
START_NOW="Y"
START_AS_WORKER="N"
REINSTALL="Y"
NON_INTERACTIVE="Y"

function print_header() {
    echo -e "${BLUE}${BOLD}Installing MirrorNeuron ${INSTALL_VERSION}${RESET}" >&3
    echo -e "${CYAN}Released package install${RESET}\n" >&3
}

function print_step() { echo -e "${CYAN}${BOLD}==>${RESET} ${BOLD}$1${RESET}" >&3; }
function print_success() { echo -e "${GREEN}${BOLD}==>${RESET} ${GREEN}$1${RESET}" >&3; }
function print_error() { echo -e "${RED}${BOLD}==>${RESET} ${RED}$1${RESET}" >&3; }
function print_warning() { echo -e "${YELLOW}${BOLD}==>${RESET} ${YELLOW}$1${RESET}" >&3; }

function usage() {
    local script_name="${MN_INSTALL_SCRIPT_NAME:-$(basename "$0")}"
    cat >&3 <<EOF
Usage: ./$script_name [options]

Installs MirrorNeuron from released artifacts and packages. Use through --mode binary.

Options:
  --version TAG                 Install this release version. Default: ${MN_DEFAULT_INSTALL_VERSION}.
  --yes                         Run non-interactively with defaults and flags. This is the default.
  --interactive                 Ask each install question before proceeding.
  --no-reinstall                Keep an existing install instead of overwriting it.
  --web-ui / --no-web-ui        Enable or skip the Web UI npm package.
  --redis / --no-redis          Enable or skip Redis Docker setup.
  --context-engine / --no-context-engine
                                Enable or skip Membrane context engine setup.
  --openshell / --no-openshell  Enable or skip OpenShell gateway setup.
  --syncthing / --no-syncthing  Enable or skip Syncthing shared-storage replication.
  --start / --no-start          Start or skip starting MirrorNeuron after install.
  --start-as-worker             Start MirrorNeuron as a worker node after install.

Python component options:
  --python-components LIST      Install only these components: sdk,skill,all-skills,cli,api.
                                Use all or none as shortcuts.
  --python-sdk / --no-python-sdk
  --skill / --no-skill          Blueprint support skill from the configured pip index.
  --all-skills / --no-all-skills
                                Install every indexed skill package from the configured pip index.
  --cli / --no-cli
  --api / --no-api

Release/source options:
  --core-release-tag TAG        Legacy alias for --version.
  --core-asset-url URL          Same as MN_CORE_ASSET_URL.
  --gar-project PROJECT         Same as MN_GAR_PROJECT. Overrides the default public package index.
  --gar-location LOCATION       Same as MN_GAR_LOCATION. Default: us-central1.
  --gar-repository NAME         Same as MN_GAR_REPOSITORY. Default: mirrorneuron-python.
  --python-index-url URL        Same as MN_PIP_INDEX_URL. Default: ${MN_DEFAULT_PIP_INDEX_URL}
  --python-extra-index-url URL  Same as MN_PIP_EXTRA_INDEX_URL. Default: https://pypi.org/simple.
  --python PATH                 Same as MN_PYTHON. Must be Python 3.11+.
  --no-managed-python           Do not use uv to install a private Python runtime.
  MN_HOME=/path                 Override the runtime state directory. Defaults to ${HOME}/.mn.
  --skills-repo OWNER/REPO      Same as MN_SKILLS_REPO.
  --skills-git-url URL          Same as MN_SKILLS_GIT_URL.
  --membrane-repo OWNER/REPO    Same as MN_MEMBRANE_REPO.
  --membrane-git-url URL        Same as MN_MEMBRANE_GIT_URL.
  -h, --help                    Show this help.

Examples:
  ./$script_name --no-web-ui
  ./$script_name --version v1.2.18
  ./$script_name --interactive
  ./$script_name --no-web-ui --python-components sdk,api
  ./$script_name --gar-project my-gcp-project --gar-repository mirrorneuron-python
  ./$script_name --python-index-url https://us-central1-python.pkg.dev/my-gcp-project/mirrorneuron-python/simple/
  MN_PYTHON=/opt/homebrew/bin/python3.11 ./$script_name
  ./$script_name --version v1.2.18 --no-web-ui
EOF
}

function set_python_components() {
    local value="$1"
    local component
    local -a components

    INSTALL_PYTHON_SDK="N"
    INSTALL_BLUEPRINT_SUPPORT_SKILL="N"
    INSTALL_ALL_SKILLS="N"
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
            all-skills|skills-all)
                INSTALL_ALL_SKILLS="Y"
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
        --start-as-worker) START_AS_WORKER="Y"; START_NOW="Y" ;;
        --python-sdk) INSTALL_PYTHON_SDK="Y" ;;
        --no-python-sdk) INSTALL_PYTHON_SDK="N" ;;
        --skill|--skills) INSTALL_BLUEPRINT_SUPPORT_SKILL="Y" ;;
        --no-skill|--no-skills) INSTALL_BLUEPRINT_SUPPORT_SKILL="N" ;;
        --all-skills) INSTALL_ALL_SKILLS="Y" ;;
        --no-all-skills) INSTALL_ALL_SKILLS="N" ;;
        --cli) INSTALL_CLI="Y" ;;
        --no-cli) INSTALL_CLI="N" ;;
        --api) INSTALL_API="Y" ;;
        --no-api) INSTALL_API="N" ;;
        --version)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--version requires a release tag such as v1.2.18."
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
        --core-release-tag)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--core-release-tag requires a value."
                usage
                exit 1
            fi
            CORE_RELEASE_TAG="$1"
            ;;
        --core-release-tag=*)
            CORE_RELEASE_TAG="${1#*=}"
            ;;
        --core-asset-url)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--core-asset-url requires a value."
                usage
                exit 1
            fi
            CORE_ASSET_URL="$1"
            ;;
        --core-asset-url=*)
            CORE_ASSET_URL="${1#*=}"
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
        --skills-repo)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--skills-repo requires a value."
                usage
                exit 1
            fi
            SKILLS_REPO="$1"
            ;;
        --skills-repo=*)
            SKILLS_REPO="${1#*=}"
            ;;
        --skills-git-url)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--skills-git-url requires a value."
                usage
                exit 1
            fi
            MN_SKILLS_GIT_URL="$1"
            ;;
        --skills-git-url=*)
            MN_SKILLS_GIT_URL="${1#*=}"
            ;;
        --membrane-repo)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--membrane-repo requires a value."
                usage
                exit 1
            fi
            MEMBRANE_REPO="$1"
            ;;
        --membrane-repo=*)
            MEMBRANE_REPO="${1#*=}"
            ;;
        --membrane-git-url)
            shift
            if [ "$#" -eq 0 ]; then
                print_error "--membrane-git-url requires a value."
                usage
                exit 1
            fi
            MEMBRANE_GIT_URL="$1"
            ;;
        --membrane-git-url=*)
            MEMBRANE_GIT_URL="${1#*=}"
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
    if [ -n "$CORE_RELEASE_TAG" ]; then
        if [ "$INSTALL_VERSION_EXPLICIT" = "Y" ] && [ "$INSTALL_VERSION" != "$CORE_RELEASE_TAG" ]; then
            print_error "--version (${INSTALL_VERSION}) and --core-release-tag (${CORE_RELEASE_TAG}) must match."
            exit 1
        fi
        INSTALL_VERSION="$CORE_RELEASE_TAG"
    fi
    INSTALL_VERSION="${INSTALL_VERSION:-$MN_DEFAULT_INSTALL_VERSION}"
    mn_validate_version_tag_or_exit "$INSTALL_VERSION"
    MN_INSTALL_VERSION="$INSTALL_VERSION"
    CORE_RELEASE_TAG="$INSTALL_VERSION"
    MN_PACKAGE_VERSION="$(mn_package_version_from_tag "$INSTALL_VERSION")"
    MN_NPM_PACKAGE_VERSION="$(mn_npm_version_from_tag "$INSTALL_VERSION")"
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
        print_error "$label failed. Log: $log_file"
        tail -n 30 "$log_file" >&3 2>/dev/null || true
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

    print_success "Installed uv at $MN_UV_BIN."
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
    print_success "Using uv-managed Python $(python_version "$managed_bin") at $managed_bin."
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
            print_success "Using Python $(python_version "$MN_PYTHON_BIN") at $MN_PYTHON_BIN."
            return
        fi
        if [ -n "${MN_PYTHON:-}" ]; then
            print_python_requirement_error "$resolved"
            exit 1
        fi
    done

    if managed_python_enabled; then
        install_managed_python
        print_success "Using Python $(python_version "$MN_PYTHON_BIN") at $MN_PYTHON_BIN."
        return
    fi

    print_warning "Managed Python fallback is disabled."
    resolved="$(command -v "python${MN_MANAGED_PYTHON_VERSION}" 2>/dev/null || true)"
    print_python_requirement_error "$resolved"
    exit 1
}

function should_install_python_packages() {
    [ "$INSTALL_PYTHON_SDK" = "Y" ] || \
    [ "$INSTALL_BLUEPRINT_SUPPORT_SKILL" = "Y" ] || \
    [ "$INSTALL_ALL_SKILLS" = "Y" ] || \
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

function resolve_core_release_tag() {
    local effective_url tag

    if [ "$CORE_RELEASE_TAG" != "latest" ]; then
        printf '%s' "$CORE_RELEASE_TAG"
        return 0
    fi

    effective_url="$(curl_github -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/${CORE_REPO}/releases/latest")"
    tag="${effective_url##*/releases/tag/}"
    tag="${tag%%\?*}"

    if [ -z "$tag" ] || [ "$tag" = "$effective_url" ]; then
        local script_name="${MN_INSTALL_SCRIPT_NAME:-$(basename "$0")}"
        print_error "Could not resolve the latest MirrorNeuron release tag from $effective_url."
        print_error "Set MN_CORE_RELEASE_TAG explicitly, for example: MN_CORE_RELEASE_TAG=v1.2.18 ./$script_name"
        exit 1
    fi

    printf '%s' "$tag"
}

function core_asset_url_for_tag() {
    local tag="$1"
    local platform="$2"

    printf 'https://github.com/%s/releases/download/%s/MirrorNeuron-%s-%s-otp-release.tar.gz' "$CORE_REPO" "$tag" "$tag" "$platform"
}

function install_core_from_release() {
    local platform tag asset_url work_dir tarball context_dir
    platform="$(docker_platform)"
    work_dir="${TMPDIR:-/tmp}/mirror_neuron_core_release.$$"
    tarball="$work_dir/core.tar.gz"
    context_dir="$work_dir/docker-context"

    mkdir -p "$work_dir" "$context_dir"

    if [ -n "$CORE_ASSET_URL" ]; then
        tag="$CORE_RELEASE_TAG"
        asset_url="$CORE_ASSET_URL"
    else
        tag="$(resolve_core_release_tag)"
        asset_url="$(core_asset_url_for_tag "$tag" "$platform")"
    fi

    print_success "Using MirrorNeuron core release $tag for Docker platform $platform."
    run_quiet "download-core-release" curl_github -fL "$asset_url" -o "$tarball"

    mn_remove_path_or_exit "$INSTALL_DIR" "MirrorNeuron state directory"
    mkdir -p "$INSTALL_DIR"
    tar -xzf "$tarball" -C "$INSTALL_DIR"

    cp -R "$INSTALL_DIR/mirror_neuron" "$context_dir/mirror_neuron"
    cat > "$context_dir/Dockerfile" <<'EOF'
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    docker.io \
    docker-buildx \
    libgcc-s1 \
    libstdc++6 \
    libssl3t64 \
    ncurses-bin \
    openssl \
    procps \
    && rm -rf /var/lib/apt/lists/*

ARG OPENSHELL_VERSION=v0.0.47
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      arm64) openshell_target="aarch64-unknown-linux-musl"; openshell_sha="a6aa05593aa5bd6936bbb87fa3958510c1a6d82ef11b8ed8498e884de50847c0" ;; \
      amd64) openshell_target="x86_64-unknown-linux-musl"; openshell_sha="75ea23c19c23a931ac34b274f719c60dd20c6f788f2a4551862ec17572d84c17" ;; \
      *) echo "unsupported architecture for OpenShell: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fLsS -o /tmp/openshell.tar.gz \
      "https://github.com/NVIDIA/OpenShell/releases/download/${OPENSHELL_VERSION}/openshell-${openshell_target}.tar.gz"; \
    echo "${openshell_sha}  /tmp/openshell.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/openshell.tar.gz -C /usr/local/bin openshell; \
    chmod 0755 /usr/local/bin/openshell; \
    rm -f /tmp/openshell.tar.gz; \
    openshell --version

WORKDIR /opt/mirror_neuron
COPY mirror_neuron /opt/mirror_neuron

ARG CORE_RELEASE_TAG
LABEL org.opencontainers.image.version="${CORE_RELEASE_TAG}"

ENV HOME=/opt/mirror_neuron
EXPOSE 50051 4369 54370

CMD ["bin/mirror_neuron", "start"]
EOF

    DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-1}" docker build --build-arg "CORE_RELEASE_TAG=$tag" -t mirror-neuron-core:latest "$context_dir" >/dev/null
    cat > "$INSTALL_METADATA_FILE" <<EOF
{
  "core_release_tag": "$tag",
  "core_platform": "$platform",
  "core_asset_url": "$asset_url",
  "updated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
    rm -rf "$work_dir"
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
    local requirement pinned_requirement label bundled_wheel installed="N"
    while IFS= read -r requirement; do
        [ -n "$requirement" ] || continue
        case "$requirement" in
            *"=="*|*">="*|*"<="*|*"~="*|*"!="*|*">"*|*"<"*) pinned_requirement="$requirement" ;;
            *) pinned_requirement="${requirement}==${MN_PACKAGE_VERSION}" ;;
        esac
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
    if [ "$INSTALL_ALL_SKILLS" = "Y" ]; then
        install_indexed_group skill
    elif [ "$INSTALL_BLUEPRINT_SUPPORT_SKILL" = "Y" ]; then
        install_indexed_group blueprint-support
    fi
}

function context_engine_git_url() {
    if [ -n "$MEMBRANE_GIT_URL" ]; then
        printf '%s' "$MEMBRANE_GIT_URL"
    else
        printf 'https://github.com/%s.git' "$MEMBRANE_REPO"
    fi
}

function local_context_engine_dir() {
    if [ -z "${INSTALL_VERSION:-}" ] && [ -n "${MN_MEMBRANE_DIR:-}" ] && [ -f "$MN_MEMBRANE_DIR/Dockerfile" ]; then
        (cd "$MN_MEMBRANE_DIR" && pwd)
        return 0
    fi
    return 1
}

function ensure_context_engine_source() {
    local source_dir
    source_dir="$(local_context_engine_dir || true)"
    if [ -n "$source_dir" ]; then
        mkdir -p "$(dirname "$MEMBRANE_DIR")"
        if [ -L "$MEMBRANE_DIR" ] && [ ! -e "$MEMBRANE_DIR" ]; then
            rm -f "$MEMBRANE_DIR"
        fi
        if [ -d "$MEMBRANE_DIR" ] && [ ! -f "$MEMBRANE_DIR/Dockerfile" ] && [ -z "$(find "$MEMBRANE_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
            rmdir "$MEMBRANE_DIR"
        fi
        if [ ! -e "$MEMBRANE_DIR" ]; then
            ln -s "$source_dir" "$MEMBRANE_DIR"
        fi
        if [ ! -f "$MEMBRANE_DIR/Dockerfile" ]; then
            print_error "Membrane source at $MEMBRANE_DIR is missing Dockerfile."
            print_error "Remove that path or set MN_MEMBRANE_DIR to a valid Membrane checkout."
            exit 1
        fi
        printf '%s' "$MEMBRANE_DIR"
        return 0
    fi

    mkdir -p "$(dirname "$MEMBRANE_DIR")"
    if [ ! -d "$MEMBRANE_DIR" ]; then
        run_quiet "clone-membrane-context-engine" git clone --branch "$INSTALL_VERSION" --depth 1 "$(context_engine_git_url)" "$MEMBRANE_DIR"
    else
        (
            cd "$MEMBRANE_DIR"
            git fetch --tags origin "$INSTALL_VERSION" >/dev/null 2>&1
            git checkout --force "$INSTALL_VERSION" >/dev/null 2>&1
        )
    fi
    MEMBRANE_DIR="$(cd "$MEMBRANE_DIR" && pwd)"
    mn_remove_dockerfile_frontend_directive "$MEMBRANE_DIR/Dockerfile"
    printf '%s' "$MEMBRANE_DIR"
}

function setup_context_engine() {
    remove_stale_runtime_containers_for_services context-engine-model membrane-context-engine
    ensure_docker_model_runner
    runtime_compose up -d membrane-context-engine >/dev/null
}

function compose_profiles() {
    local profiles=()
    [ "$INSTALL_OPENSHELL" = "Y" ] && profiles+=("openshell")
    [ "$INSTALL_CONTEXT_ENGINE" = "Y" ] && profiles+=("context")
    if [ "${#profiles[@]}" -eq 0 ]; then
        printf ''
        return 0
    fi
    local IFS=,
    printf '%s' "${profiles[*]}"
}

function openssl_supports_ed25519() {
    local bin="$1"
    local tmp_file
    tmp_file="$(mktemp "${TMPDIR:-/tmp}/mn-ed25519-test.XXXXXX")"
    if "$bin" genpkey -algorithm ED25519 -out "$tmp_file" >/dev/null 2>&1; then
        rm -f "$tmp_file"
        return 0
    fi
    rm -f "$tmp_file"
    return 1
}

function resolve_ed25519_openssl() {
    local candidates=()
    local candidate resolved

    if [ -n "${OPENSSL_BIN:-}" ]; then
        if resolved="$(command -v "$OPENSSL_BIN" 2>/dev/null)" && [ -n "$resolved" ] && [ -x "$resolved" ] && openssl_supports_ed25519 "$resolved"; then
            printf '%s\n' "$resolved"
            return 0
        fi
        print_error "OPENSSL_BIN=${OPENSSL_BIN} does not support ED25519 key generation."
        print_error "Set OPENSSL_BIN to an OpenSSL 3 binary, for example /opt/homebrew/bin/openssl."
        exit 1
    fi
    if resolved="$(command -v openssl 2>/dev/null)" && [ -n "$resolved" ]; then
        candidates+=("$resolved")
    fi
    candidates+=(
        /opt/homebrew/bin/openssl
        /usr/local/bin/openssl
        /usr/local/opt/openssl@3/bin/openssl
        /opt/local/bin/openssl
    )

    for candidate in "${candidates[@]}"; do
        [ -x "$candidate" ] || continue
        if openssl_supports_ed25519 "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    print_error "An ED25519-capable OpenSSL is required to create OpenShell sandbox JWT keys."
    print_error "Install OpenSSL 3, put it on PATH, or set OPENSSL_BIN=/path/to/openssl."
    exit 1
}

function write_openshell_compose_config() {
    local gateway_dir="${MN_HOST_OPENSHELL_CONFIG_DIR}/gateways/openshell"
    local jwt_dir="${MN_HOST_OPENSHELL_STATE_DIR}/jwt"
    local openssl_bin tmp_dir
    mkdir -p "$gateway_dir"
    mkdir -p "$jwt_dir"
    if [ ! -s "${jwt_dir}/signing.pem" ] || [ ! -s "${jwt_dir}/public.pem" ] || [ ! -s "${jwt_dir}/kid" ]; then
        openssl_bin="$(resolve_ed25519_openssl)"
        tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mn-openshell-jwt.XXXXXX")"
        if ! "$openssl_bin" genpkey -algorithm ED25519 -out "${tmp_dir}/signing.pem" >/dev/null; then
            print_error "Failed to create OpenShell JWT signing key with ${openssl_bin}."
            rm -rf "$tmp_dir"
            exit 1
        fi
        if ! "$openssl_bin" pkey -in "${tmp_dir}/signing.pem" -pubout -out "${tmp_dir}/public.pem" >/dev/null; then
            print_error "Failed to create OpenShell JWT public key with ${openssl_bin}."
            rm -rf "$tmp_dir"
            exit 1
        fi
        if ! "$openssl_bin" rand -hex 8 > "${tmp_dir}/kid"; then
            print_error "Failed to create OpenShell JWT key id with ${openssl_bin}."
            rm -rf "$tmp_dir"
            exit 1
        fi
        mv "${tmp_dir}/signing.pem" "${jwt_dir}/signing.pem"
        mv "${tmp_dir}/public.pem" "${jwt_dir}/public.pem"
        mv "${tmp_dir}/kid" "${jwt_dir}/kid"
        rm -rf "$tmp_dir"
        chmod 600 "${jwt_dir}/signing.pem" 2>/dev/null || true
        chmod 644 "${jwt_dir}/public.pem" "${jwt_dir}/kid" 2>/dev/null || true
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
grpc_endpoint = "http://host.openshell.internal:${OPENSHELL_GATEWAY_PORT:-58080}"
network_name = "openshell-docker"
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

function write_runtime_compose_files() {
    local model_runner_model profiles network_name network_external network_token redis_password mn_cookie runtime_skills_root runtime_package_index context_memory_enabled otterdesk_context_memory_enabled membrane_engine_tag membrane_engine_image
    model_runner_model="${MN_CONTEXT_MODEL_RUNNER_MODEL:-hf.co/homerquan/mn-context-engine-model-v-Q4_K_M}"
    profiles="$(compose_profiles)"
    network_name="${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
    network_external="$(resolve_docker_network_external "$network_name")"
    network_token="$(resolve_network_token)"
    redis_password="$(resolve_redis_password "mirror_neuron_password_admin")"
    mn_cookie="$(resolve_mn_cookie)"
    printf '%s\n' "mirror_neuron_password" > "${INSTALL_DIR}/grpc_auth.token"
    printf '%s\n' "mirror_neuron_password_admin" > "${INSTALL_DIR}/grpc_admin.token"
    chmod 600 "${INSTALL_DIR}/grpc_auth.token" "${INSTALL_DIR}/grpc_admin.token" 2>/dev/null || true
    runtime_skills_root="${MN_SKILLS_ROOT:-${MN_HOST_HOME_DIR}/skills}"
    runtime_package_index="${MN_PACKAGE_INDEX_FILE:-}"
    membrane_engine_tag="${MN_MEMBRANE_ENGINE_IMAGE_TAG:-${INSTALL_VERSION:-v${MN_PACKAGE_VERSION:-1.2.18}}}"
    if [[ "$membrane_engine_tag" != v* ]]; then
        membrane_engine_tag="v${membrane_engine_tag}"
    fi
    membrane_engine_image="${ENGINE_IMAGE:-${MN_MEMBRANE_ENGINE_IMAGE:-us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/membrane-context-engine:${membrane_engine_tag}}}"
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
MN_HOST_OPENSHELL_CONFIG_DIR=${MN_HOST_OPENSHELL_CONFIG_DIR}
MN_HOST_OPENSHELL_STATE_DIR=${MN_HOST_OPENSHELL_STATE_DIR}
MEMBRANE_DIR=${MEMBRANE_DIR}
ENGINE_IMAGE=${membrane_engine_image}
MN_MEMBRANE_ENGINE_IMAGE=${membrane_engine_image}
MN_MEMBRANE_ENGINE_IMAGE_TAG=${membrane_engine_tag}
MN_REDIS_IMAGE=${MN_REDIS_IMAGE:-redis:8}
MN_CONTEXT_MODEL_RUNNER_MODEL=${model_runner_model}
MN_GRPC_BIND_HOST=${MN_GRPC_BIND_HOST:-127.0.0.1}
MN_GRPC_PORT=${MN_GRPC_PORT:-55051}
MN_GRPC_TARGET=${MN_GRPC_TARGET:-localhost:${MN_GRPC_PORT:-55051}}
MN_GRPC_ADVERTISE_PORT=${MN_GRPC_ADVERTISE_PORT:-${MN_GRPC_PORT:-55051}}
MN_NATIVE_SDK_GRPC_HOST=${MN_NATIVE_SDK_GRPC_HOST:-127.0.0.1}
MN_NATIVE_SDK_GRPC_PORT=${MN_NATIVE_SDK_GRPC_PORT:-55052}
MN_NATIVE_SDK_GRPC_ADVERTISE_HOST=${MN_NATIVE_SDK_GRPC_ADVERTISE_HOST:-${MN_NETWORK_ADVERTISE_HOST:-}}
MN_NATIVE_SDK_GRPC_ADVERTISE_PORT=${MN_NATIVE_SDK_GRPC_ADVERTISE_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_NATIVE_SDK_GRPC_TARGET=${MN_NATIVE_SDK_GRPC_TARGET:-mn-native-sdk-grpc:55052}
MN_NATIVE_SDK_GRPC_PROXY_PORT=${MN_NATIVE_SDK_GRPC_PROXY_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_NATIVE_SDK_GRPC_PROXY_TARGET_HOST=${MN_NATIVE_SDK_GRPC_PROXY_TARGET_HOST:-host.docker.internal}
MN_NATIVE_SDK_GRPC_PROXY_TARGET_PORT=${MN_NATIVE_SDK_GRPC_PROXY_TARGET_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_LITELLM_GATEWAY_BIND_HOST=${MN_LITELLM_GATEWAY_BIND_HOST:-127.0.0.1}
MN_LITELLM_GATEWAY_PORT=${MN_LITELLM_GATEWAY_PORT:-4000}
MN_LITELLM_GATEWAY_INTERNAL_API_BASE=${MN_LITELLM_GATEWAY_INTERNAL_API_BASE:-http://mn-litellm-proxy:4000/v1}
MN_API_HOST=${MN_API_HOST:-localhost}
MN_API_PORT=${MN_API_PORT:-54001}
MN_DIST_PORT=${MN_DIST_PORT:-54370}
MN_WEB_UI_HOST=${MN_WEB_UI_HOST:-localhost}
MN_WEB_UI_PORT=${MN_WEB_UI_PORT:-55173}
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
MN_SKILLS_ROOT=${runtime_skills_root}
MN_PACKAGE_INDEX_FILE=${runtime_package_index}
MN_PIP_INDEX_URL=${MN_PIP_INDEX_URL:-${MN_PYTHON_INDEX_URL:-}}
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
OPENSHELL_GATEWAY_ENDPOINT=${OPENSHELL_GATEWAY_ENDPOINT:-http://127.0.0.1:${OPENSHELL_GATEWAY_PORT:-58080}}
OPENSHELL_GATEWAY_USER=${OPENSHELL_GATEWAY_USER}
OPENSHELL_GATEWAY_DOCKER_GROUP=${OPENSHELL_GATEWAY_DOCKER_GROUP}
DOCKER_HOST_SOCKET=${DOCKER_HOST_SOCKET}
MN_COOKIE=${mn_cookie}
MN_GRPC_AUTH_TOKEN=mirror_neuron_password
MN_GRPC_ADMIN_TOKEN=mirror_neuron_password_admin
EOF
    chmod 600 "$RUNTIME_COMPOSE_ENV" 2>/dev/null || true
}

function runtime_compose() {
    if command -v docker-compose >/dev/null 2>&1; then
        docker-compose --env-file "$RUNTIME_COMPOSE_ENV" -f "$RUNTIME_COMPOSE_FILE" "$@"
    else
        docker compose --env-file "$RUNTIME_COMPOSE_ENV" -f "$RUNTIME_COMPOSE_FILE" "$@"
    fi
}

function runtime_container_name_for_service() {
    case "$1" in
        redis) echo "mirror-neuron-redis" ;;
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
}

function ensure_docker_model_runner() {
    if [ "$INSTALL_CONTEXT_ENGINE" != "Y" ] && [ "${INSTALL_DOCKER_MODEL_RUNNER:-N}" != "Y" ] && [ "${MN_ENABLE_DOCKER_MODEL_RUNNER:-N}" != "Y" ]; then
        return 0
    fi

    if ! docker model --help >/dev/null 2>&1; then
        print_error "Docker Model Runner CLI is not available. Upgrade Docker Desktop/Engine to a version with 'docker model' support."
        exit 1
    fi

    if docker model status >/dev/null 2>&1; then
        return 0
    fi

    print_warning "Docker Model Runner is not running; attempting to enable it."
    if docker desktop enable model-runner >/dev/null 2>&1 && docker model status >/dev/null 2>&1; then
        return 0
    fi

    if docker model install-runner --help >/dev/null 2>&1; then
        docker model install-runner >/dev/null 2>&1 || true
        docker model start-runner >/dev/null 2>&1 || true
        if docker model status >/dev/null 2>&1; then
            return 0
        fi
    fi

    print_error "Docker Model Runner is not ready. Enable it in Docker Desktop Settings > AI, or run 'docker model install-runner' and 'docker model start-runner' on Docker Engine."
    exit 1
}

function start_runtime_compose_sidecars() {
    local services=()
    [ "$INSTALL_REDIS" = "Y" ] && services+=("redis")
    grep -q '^  mn-native-sdk-grpc:' "$RUNTIME_COMPOSE_FILE" 2>/dev/null && services+=("mn-native-sdk-grpc")
    grep -q '^  mn-litellm-proxy:' "$RUNTIME_COMPOSE_FILE" 2>/dev/null && services+=("mn-litellm-proxy")
    [ "$INSTALL_OPENSHELL" = "Y" ] && services+=("openshell")
    if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
        services+=("membrane-context-engine")
    fi
    if [ "${#services[@]}" -gt 0 ]; then
        remove_stale_runtime_containers_for_services context-engine-model "${services[@]}"
        ensure_docker_model_runner
        runtime_compose up -d "${services[@]}" >/dev/null
    fi
}

function install_web_ui_package() {
    rm -rf "$LEGACY_UI_DIR"
    rm -rf "$UI_DIR"
    mkdir -p "$UI_DIR"

    cat > "$UI_DIR/package.json" <<EOF
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
    "mirrorneuron-web-ui": "${MN_NPM_PACKAGE_VERSION}"
  },
  "devDependencies": {}
}
EOF

    cat > "$UI_DIR/vite.config.mjs" <<'EOF'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

const apiHost = process.env.MN_API_HOST || 'localhost'
const apiPort = process.env.MN_API_PORT || '54001'

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

function shell_escape_value() {
    printf '%q' "$1"
}

function profile_has_bin_path() {
    local profile="$1"
    [ -f "$profile" ] || return 1
    local line
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" == *"PATH"* && "$line" == *"$BIN_DIR"* ]]; then
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

    if [ "$include_path" = "Y" ]; then
        [[ ":$PATH:" != *":$BIN_DIR:"* ]] && needs_path="Y"
    fi

    if [ "$needs_path" = "N" ] && [ "$needs_runtime_home" = "N" ]; then
        return
    fi

    if [ "$needs_path" = "Y" ]; then
        echo -e "\n${YELLOW}${BOLD}Note:${RESET} ${YELLOW}$BIN_DIR is not in your PATH.${RESET}" >&3
    fi
    if [ "$needs_runtime_home" = "Y" ]; then
        echo -e "${YELLOW}Persisting MN_HOME=${INSTALL_DIR} for future terminal sessions.${RESET}" >&3
    fi

    local detected_profiles=()
    [ -f "$HOME/.zshrc" ] && detected_profiles+=("$HOME/.zshrc")
    [ -f "$HOME/.bashrc" ] && detected_profiles+=("$HOME/.bashrc")
    [ -f "$HOME/.bash_profile" ] && detected_profiles+=("$HOME/.bash_profile")
    [ -f "$HOME/.profile" ] && detected_profiles+=("$HOME/.profile")

    if [ ${#detected_profiles[@]} -eq 0 ]; then
        detected_profiles+=("$HOME/.profile")
    fi

    local profile path_line home_line wrote_header wrote_profile
    path_line="export PATH=\"$BIN_DIR:\$PATH\""
    if [ "$INSTALL_DIR" = "$default_home" ]; then
        home_line='export MN_HOME="$HOME/.mn"'
    else
        home_line="export MN_HOME=$(shell_escape_value "$INSTALL_DIR")"
    fi

    for profile in "${detected_profiles[@]}"; do
        wrote_header="N"
        wrote_profile="N"
        if [ "$needs_path" = "Y" ] && ! profile_has_bin_path "$profile"; then
            [ "$wrote_header" = "N" ] && echo -e "\n# MN and OTTERDESK" >> "$profile" && wrote_header="Y"
            echo "$path_line" >> "$profile"
            wrote_profile="Y"
        fi
        if [ "$needs_runtime_home" = "Y" ] && ! profile_has_runtime_home "$profile"; then
            [ "$wrote_header" = "N" ] && echo -e "\n# MN and OTTERDESK" >> "$profile" && wrote_header="Y"
            echo "$home_line" >> "$profile"
            wrote_profile="Y"
        fi
        if [ "$wrote_profile" = "Y" ]; then
            echo -e "Automatically added MirrorNeuron shell exports to ${CYAN}$profile${RESET}" >&3
        fi
    done

    echo -e "${YELLOW}Please restart your terminal or run \`source ~/.zshrc\` to use the updated MirrorNeuron environment.${RESET}" >&3
}

print_header

if [ "$NON_INTERACTIVE" != "Y" ]; then
    echo -e "${CYAN}${BOLD}Configuration${RESET}" >&3
    INSTALL_WEB_UI=$(ask "Do you want to install the Web UI from npm?" "$INSTALL_WEB_UI")
    INSTALL_REDIS=$(ask "Do you want to install Redis via Docker?" "$INSTALL_REDIS")
    INSTALL_CONTEXT_ENGINE=$(ask "Do you want to install/start the Membrane context engine?" "$INSTALL_CONTEXT_ENGINE")
    INSTALL_OPENSHELL=$(ask "Do you want to install/start the OpenShell gateway for sandbox workers?" "$INSTALL_OPENSHELL")
    INSTALL_PYTHON_SDK=$(ask "Do you want to install the Python SDK from the configured pip index?" "$INSTALL_PYTHON_SDK")
    INSTALL_BLUEPRINT_SUPPORT_SKILL=$(ask "Do you want to install the blueprint support skill from the configured pip index?" "$INSTALL_BLUEPRINT_SUPPORT_SKILL")
    INSTALL_ALL_SKILLS=$(ask "Do you want to install every indexed skill package from the configured pip index?" "$INSTALL_ALL_SKILLS")
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
if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
    require_cmd git
fi

if [ "$INSTALL_WEB_UI" = "Y" ]; then
    require_cmd npm
fi

if ! docker info >/dev/null 2>&1; then
    print_error "Docker is not running. Please start Docker first."
    exit 1
fi

print_success "System ready."

if [ -d "$INSTALL_DIR" ] || [ -f "$BIN_DIR/mn" ]; then
    print_warning "MirrorNeuron appears to be already installed."
    REINSTALL=$(ask "Do you want to reinstall (overwrite old ones)?" "$REINSTALL")
    if [ "$REINSTALL" = "N" ]; then
        echo -e "${YELLOW}Installation cancelled by user.${RESET}" >&3
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
    print_step "Installing Web UI"
    ( install_web_ui_package ) &
    spinner $! "Installing Web UI package"
fi

if [ "$INSTALL_REDIS" = "Y" ] || [ "$INSTALL_CONTEXT_ENGINE" = "Y" ] || [ "$INSTALL_OPENSHELL" = "Y" ]; then
    print_step "Preparing services"
    if [ "$INSTALL_OPENSHELL" = "Y" ]; then
        install_openshell_cli
    fi
    ( start_runtime_compose_sidecars ) &
    spinner $! "Runtime services ready"
fi

print_step "Finishing setup"
mkdir -p "$BIN_DIR" "$INSTALL_DIR"
rm -f "$BIN_DIR/mn" "$BIN_DIR/mn-api" "$INSTALL_DIR/mn"
if [ "$INSTALL_CLI" = "Y" ]; then
    ln -s "$VENV_DIR/bin/mn" "$BIN_DIR/mn"
    ln -s "$VENV_DIR/bin/mn" "$INSTALL_DIR/mn"
fi
if [ "$INSTALL_API" = "Y" ]; then
    ln -s "$VENV_DIR/bin/mn-api" "$BIN_DIR/mn-api"
fi
print_success "Command links ready."
if [ "$INSTALL_CLI" = "Y" ] || [ "$INSTALL_API" = "Y" ]; then
    add_shell_profile_exports "Y"
else
    add_shell_profile_exports "N"
fi

if [ "$START_NOW" = "Y" ]; then
    print_step "Starting MirrorNeuron"
    if [ "$START_AS_WORKER" = "Y" ]; then
        if ! "$VENV_DIR/bin/mn" runtime start --worker-node; then
            print_warning "mn runtime start --worker-node failed; starting worker gateway services with Docker Compose."
            runtime_compose up -d mn-native-sdk-grpc mn-litellm-proxy
        fi
    else
        if ! "$VENV_DIR/bin/mn" runtime start; then
            print_warning "mn runtime start failed; starting MirrorNeuron Docker Compose runtime."
            runtime_compose up -d
            "$VENV_DIR/bin/mn" runtime restart-sidecars --api >/dev/null 2>&1 || print_warning "MirrorNeuron Core started, but the REST API sidecar did not start automatically."
        fi
    fi
fi

echo "" >&3
print_success "MirrorNeuron ${INSTALL_VERSION} installed." >&3
if [ "$INSTALL_CLI" = "Y" ]; then
    echo -e "CLI: ${YELLOW}mn${RESET}" >&3
fi
if [ "$INSTALL_API" = "Y" ]; then
    echo -e "API: ${YELLOW}mn-api${RESET}" >&3
fi
if [ "$INSTALL_CLI" = "Y" ]; then
    if [ "$START_NOW" = "Y" ]; then
        echo -e "Next: ${GREEN}mn node list${RESET}" >&3
    elif [ "$START_AS_WORKER" = "Y" ]; then
        echo -e "Next: ${GREEN}mn runtime start --worker-node${RESET}" >&3
    else
        echo -e "Next: ${GREEN}mn runtime start${RESET}" >&3
    fi
fi
}

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
