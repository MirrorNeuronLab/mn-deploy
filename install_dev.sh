#!/usr/bin/env bash
# Install from the sibling source checkouts (default) or GitHub repositories.
set -euo pipefail
dev_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$dev_dir/install.sh"
if [ "$MN_INSTALL_MODE_EXPLICIT" = N ]; then MN_INSTALL_MODE=local; fi
MN_BUILD_MEMBRANE=N
MN_MEMBRANE_BUILD_PREPARED=N

function print_unified_usage() {
  cat >&3 <<EOF
OtterDesk Developer Installer

Usage: ./install_dev.sh [--mode local|github] [options]

  --mode local       Build from sibling checkouts (default).
  --mode github      Clone and build from GitHub. Use --version TAG to pin a release.
  --no-runtime       Build only the Wasm CLI, API and client support.
  --build-membrane   Build the local Membrane checkout with its runtime.
  --interactive      Choose components and startup interactively.
  --no-start         Prepare services without starting them.
  --help-all         Show the full options for the selected source.
  -v, --verbose      Show build details.

Run scripts/preapare_dev.sh to prepare the WASI SDK ahead of the first API build.
EOF
}

function mn_configure_install_mode() {
  case "$MN_INSTALL_MODE" in
    local) MN_INSTALL_SOURCE_LABEL="local source"; export MN_USE_LOCAL_SKILLS="${MN_USE_LOCAL_SKILLS:-1}" ;;
    github) MN_INSTALL_SOURCE_LABEL="GitHub source"; export MN_USE_LOCAL_SKILLS="${MN_USE_LOCAL_SKILLS:-0}" ;;
    *) print_error "Unknown developer source '$MN_INSTALL_MODE'. Select --mode local or --mode github."; return 1 ;;
  esac
  if [ "$MN_RUNTIME_ONLY" = Y ]; then
    printf 'notice: --runtime-only is ignored in %s source mode; both parts are installed.\n' "$MN_INSTALL_MODE" >&3
    MN_RUNTIME_ONLY=N
  fi
  if [ "$MN_INSTALL_MODE" = local ] && [ -n "$MN_INSTALL_VERSION" ]; then
    print_error "--version selects a GitHub tag. Use --mode github with --version."
    return 1
  fi
  local arg
  local -a remaining=()
  for arg in ${MN_INSTALL_ARGS[@]+"${MN_INSTALL_ARGS[@]}"}; do
    if [ "$arg" = --build-membrane ]; then
      if [ "$MN_INSTALL_START_PODMAN" = Y ] || [ "$MN_INSTALL_DETECT_ONLY" = Y ]; then
        print_error "--build-membrane requires an installation."
        return 1
      fi
      if [ "$MN_INSTALL_MODE" = local ]; then MN_BUILD_MEMBRANE=Y; fi
    else
      remaining+=("$arg")
    fi
  done
  MN_INSTALL_ARGS=(${remaining[@]+"${remaining[@]}"})
  if [ "$MN_INSTALL_HELP_REQUESTED" != Y ] && [ "$MN_BUILD_MEMBRANE" = Y ]; then
    if [ "$MN_NO_RUNTIME" = Y ]; then
      print_error "--build-membrane conflicts with --no-runtime."
      return 1
    fi
    mn_validate_membrane_build
  fi
}

function mn_preflight_reset() {
  if [ "$MN_INSTALL_MODE" = local ]; then
    mn_prepare_local_clients "$(mn_local_client_root)"
  fi
}

# Custom Dockerfiles may use private base images. Keep the caller's credentials
# unless Podman fails to read them before submitting the build to the engine.
function mn_build_with_registry_auth() (
  local status
  set -o pipefail
  mn_build_stderr="$(mktemp "${TMPDIR:-/tmp}/mn-podman-build.XXXXXXXX")" || return 1
  trap 'rm -f "$mn_build_stderr"' EXIT
  # Stream both channels as usual while keeping Podman's final diagnostic.
  exec 4>&1
  if podman build "$@" 2>&1 >&4 4>&- | tee "$mn_build_stderr" >&2; then
    return 0
  else
    status=$?
  fi
  if [ "$status" -eq 125 ] && tail -n 1 "$mn_build_stderr" | grep -q '^Error: error getting credentials - err:'; then
    printf 'Podman could not read registry credentials. Retrying the build anonymously.\n' >&2
    mn_anonymous_podman build "$@"
    return
  fi
  return "$status"
)

function mn_report_podman_failure() {
  if ! podman info >/dev/null 2>&1; then
    print_error "Podman stopped responding. Verify podman info and retry the installer."
  fi
}

# Hold temporary swap only while compiling on a small, locally managed Mac VM.
# The SSH session owns the file so a disconnected installer also releases it.
function mn_build_runtime_image() (
  local machine="" memory reply guest
  if [ "$(uname -s)" = Darwin ] && [ -z "${CONTAINER_HOST:-}" ]; then
    machine="$(podman system connection list --format '{{.Default}} {{.IsMachine}} {{.Name}} {{.URI}}' 2>/dev/null |
      awk -v selected="${CONTAINER_CONNECTION:-}" '
        $2 == "true" && (selected == "" ? $1 == "true" : $3 == selected) {
          if ($4 ~ /^ssh:\/\/root@/) sub(/-root$/, "", $3)
          print $3; exit
        }')" || machine=""
  fi
  memory=""
  if [ -n "$machine" ]; then
    memory="$(podman machine inspect --format '{{.Resources.Memory}}' "$machine" 2>/dev/null)" || memory=""
  fi
  if ! [[ "$memory" =~ ^[0-9]+$ ]] || [ "$memory" -ge 6144 ]; then
    mn_build_with_registry_auth "$@"
    return
  fi

  guest="$(
    cat <<'GUEST'
set -eu
umask 077
ram=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
# Other builds release their own swap as soon as they finish.
swap=$(awk 'NR > 1 && $1 !~ /^\/var\/tmp\/mn-build-swap\./ {sum += $3} END {print sum+0}' /proc/swaps)
needed=$(( (6144 * 1024 - ram - swap + 1023) / 1024 ))
if [ "$needed" -gt 0 ]; then
  file=$(mktemp /var/tmp/mn-build-swap.XXXXXXXX)
  active=0
  cleanup() {
    if [ "$active" = 1 ]; then swapoff "$file" || return 1; fi
    rm -f -- "$file"
  }
  trap 'cleanup || exit 1' EXIT
  trap 'exit 1' HUP INT TERM
  echo "Reserving ${needed} MiB of temporary Podman guest swap for the image build." >&2
  fallocate -l "${needed}M" "$file"
  mkswap "$file" >/dev/null
  swapon "$file"
  active=1
fi
echo ready
cat >/dev/null
GUEST
  )" || return 1
  mn_build_ready_dir="$(mktemp -d "${TMPDIR:-/tmp}/mn-build-ready.XXXXXXXX")" || return 1
  trap 'rm -f "$mn_build_ready_dir/ready"; rmdir "$mn_build_ready_dir"' EXIT
  mkfifo "$mn_build_ready_dir/ready" || return 1
  set -o pipefail
  exec 4>&1
  # The guest writes its readiness acknowledgement to the FIFO read by the build.
  # shellcheck disable=SC2094
  {
    if ! IFS= read -r reply <"$mn_build_ready_dir/ready" || [ "$reply" != ready ]; then
      printf 'Could not prepare build memory in Podman machine %s. Check free space in its /var/tmp or increase its memory to 6144 MiB.\n' "$machine" >&2
      return 1
    fi
    mn_build_with_registry_auth "$@" >&4
  } | podman machine ssh --username root "$machine" "$guest" >"$mn_build_ready_dir/ready" 4>&-
)

function mn_run_podman_build() {
  local status
  if mn_run_logged "Core image build" mn_build_runtime_image "$@"; then
    return 0
  else
    status=$?
  fi
  mn_report_podman_failure
  return "$status"
}

function mn_validate_membrane_build() {
  [ "$MN_BUILD_MEMBRANE" = "Y" ] || return 0
  local argument source_dir
  for argument in ${MN_INSTALL_ARGS[@]+"${MN_INSTALL_ARGS[@]}"}; do
    if [ "$argument" = "--no-context-engine" ]; then
      printf 'error: --build-membrane conflicts with --no-context-engine.\n' >&3
      return 1
    fi
  done
  source_dir="${MN_MEMBRANE_DIR:-$(mn_script_dir)/../Membrane}"
  if [ ! -f "$source_dir/Dockerfile" ] || [ ! -f "$source_dir/mn-context-engine/Cargo.toml" ]; then
    printf 'error: --build-membrane requires a local Membrane checkout containing Dockerfile and mn-context-engine/Cargo.toml: %s\n' "$source_dir" >&3
    printf 'Set MN_MEMBRANE_DIR to the local source directory.\n' >&3
    return 1
  fi
  MN_BUILD_MEMBRANE_DIR="$(cd "$source_dir" && pwd)"
}

function mn_selected_membrane_image() {
  if [ "$MN_BUILD_MEMBRANE" = "Y" ]; then
    printf '%s' 'mirror-neuron-memory-engine:local'
  else
    printf '%s' "$1"
  fi
}

function mn_selected_membrane_source_mode() {
  if [ "$MN_BUILD_MEMBRANE" = "Y" ]; then
    printf '%s' source
  else
    printf '%s' image
  fi
}

function mn_prepare_membrane_image() {
  if [ "$MN_BUILD_MEMBRANE" != "Y" ]; then
    pull_context_engine_image
    return
  fi
  [ "$MN_MEMBRANE_BUILD_PREPARED" != "Y" ] || return 0
  # Recheck before Podman is invoked; no fallback to an older image on failure.
  mn_validate_membrane_build || return 1
  print_step "Building Membrane Podman image from local source"
  if ! mn_run_logged "Membrane image build" mn_build_runtime_image --target runtime \
    --file "$MN_BUILD_MEMBRANE_DIR/Dockerfile" \
    --tag "$(mn_selected_membrane_image '')" "$MN_BUILD_MEMBRANE_DIR"; then
    print_error "Membrane image build failed. The GAR image was not used as a fallback."
    return 1
  fi
  MN_MEMBRANE_BUILD_PREPARED="Y"
}

function mn_require_cargo() {
  local cargo_bin="${CARGO_HOME:-$HOME/.cargo}/bin"
  if command -v cargo >/dev/null; then return 0; fi
  if [ -f "$cargo_bin/cargo" ] && [ -x "$cargo_bin/cargo" ]; then
    export PATH="$PATH:$cargo_bin"
    return 0
  fi
  print_error "Cargo is required to build the Rust clients. Install Rust with rustup and rerun, or use a binary release."
  return 1
}

function mn_prepare_local_clients() {
  local root="$1" support="$1/mn-client-support" repo
  for repo in mn-cli mn-api; do
    if [ ! -f "$root/$repo/Cargo.toml" ]; then
      print_error "Missing Rust checkout at $root/$repo. Use its Rust main branch in the local workspace."
      return 1
    fi
  done
  mn_require_cargo || return 1
  if [ -f "$support/Cargo.toml" ]; then return 0; fi
  if [ -e "$support" ] || [ -L "$support" ]; then
    print_error "Missing Rust client support manifest: $support/Cargo.toml. Restore the checkout or move it aside and rerun."
    return 1
  fi
  if ! command -v git >/dev/null; then
    print_error "Git is required to clone the missing mn-client-support checkout. Install Git and rerun."
    return 1
  fi

  (
    local stage
    stage="$(mktemp -d "$root/.mn-client-support.XXXXXXXX")" || {
      print_error "Could not prepare a directory for mn-client-support in $root. Check workspace permissions and rerun."
      return 1
    }
    trap 'rm -rf "$stage"' EXIT
    printf '==> Cloning missing Rust client support into %s\n' "$support" >&3
    if ! GIT_TERMINAL_PROMPT=0 mn_run_logged "Clone mn-client-support" \
      git clone --branch main https://github.com/MirrorNeuronLab/mn-client-support.git "$stage/mn-client-support"; then
      printf 'Next: check access to the mn-client-support repository on GitHub and rerun the installer.\n' >&3
      return 1
    fi
    if [ ! -f "$stage/mn-client-support/Cargo.toml" ]; then
      print_error "The mn-client-support main branch is missing its Rust manifest. Check the repository and retry."
      return 1
    fi
    # Target the parent so mv cannot place the checkout inside an occupied path.
    mv -n "$stage/mn-client-support" "$root/" || true
    if [ ! -f "$support/Cargo.toml" ]; then
      print_error "Could not place the Rust client support checkout at $support. Check that path and rerun."
      return 1
    fi
  )
}

function mn_local_client_root() {
  local siblings
  if [ -n "${MN_CLIENT_SOURCE_ROOT:-}" ]; then
    printf '%s' "$MN_CLIENT_SOURCE_ROOT"
    return
  fi
  siblings="$(cd "$(mn_script_dir)/.." && pwd -P)" || return 1
  if [ -f "$PWD/mn-cli/Cargo.toml" ] && { [ -n "${MN_INSTALL_STREAM_NAME:-}" ] || [ ! -f "$siblings/mn-cli/Cargo.toml" ]; }; then
    pwd -P
  else
    printf '%s' "$siblings"
  fi
}

function mn_stage_client_commands() {
  local stage=$1 root repo ref command target_dir
  local -a repos=(mn-client-support)
  shift
  if [ "$MN_INSTALL_MODE" = local ]; then
    root=$(mn_local_client_root)
    mn_prepare_local_clients "$root" || return 1
  else
    mn_require_cargo || return 1
    root="$stage/src"
    mkdir "$root" || return 1
    if [ "${INSTALL_CLI:-Y}" = Y ]; then repos+=(mn-cli); fi
    if [ "${INSTALL_API:-Y}" = Y ] || [ "${INSTALL_WEB_UI:-N}" = Y ]; then repos+=(mn-api); fi
    for repo in "${repos[@]}"; do
      ref="${MN_CLIENT_VERSION:-${MN_INSTALL_VERSION:-}}"
      case "$repo" in mn-cli) ref="${MN_CLI_VERSION_OVERRIDE:-${MN_CLI_VERSION:-$ref}}" ;; mn-api) ref="${MN_API_VERSION_OVERRIDE:-${MN_API_VERSION:-$ref}}" ;; esac
      if [ -n "$ref" ]; then
        GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$ref" "https://github.com/MirrorNeuronLab/$repo.git" "$root/$repo" || return 1
      else GIT_TERMINAL_PROMPT=0 git clone --depth 1 "https://github.com/MirrorNeuronLab/$repo.git" "$root/$repo" || return 1; fi
    done
  fi
  target_dir="${CARGO_TARGET_DIR:-$INSTALL_DIR/cache/rust-client}"
  for command in "$@"; do
    case "$command" in mn) repo=mn-cli ;; mn-web-ui-server | mn-api) repo=mn-api ;; *) repo=mn-client-support ;; esac
    if [ "$command" = mn-api ] && [ -z "${CC_wasm32_wasip2:-}${WASI_SDK_PATH:-}" ] &&
      ! command -v wasm32-wasip2-clang >/dev/null; then
      WASI_SDK_PATH=$("$dev_dir/scripts/preapare_dev.sh") || return 1
      export WASI_SDK_PATH
    fi
    if [ "$command" = mn-web-ui-server ]; then
      cargo build --quiet --locked --release --bin "$command" --manifest-path "$root/$repo/Cargo.toml" --target-dir "$target_dir" || return 1
      cp "$target_dir/release/$command" "$stage/bin/$command" || return 1
    else
      "$root/mn-client-support/scripts/build-wasm.sh" "$root/$repo" "$command" "$target_dir" || return 1
      cp "$target_dir/wasm32-wasip2/release/$command.wasm" "$stage/bin/" || return 1
    fi
  done
}

function mn_prepare_native_web_assets() {
  local source="${MN_WEB_UI_DIST_DIR:-${1:-}}" destination="$INSTALL_DIR/webui"
  [ "${INSTALL_WEB_UI:-N}" = Y ] || return 0
  if [ -n "$source" ] && { [ -f "$source/dist/index.html" ] || [ -f "$source/index.html" ]; }; then
    source="$(cd "$source" && pwd -P)"
    if [ -L "$destination" ] || [ ! -e "$destination" ]; then
      ln -sfn "$source" "$destination"
      return
    fi
    if [ -f "$destination/dist/index.html" ] || [ -f "$destination/index.html" ]; then return; fi
    if [ ! -e "$INSTALL_DIR/web-ui-source" ] || [ -L "$INSTALL_DIR/web-ui-source" ]; then
      ln -sfn "$source" "$INSTALL_DIR/web-ui-source"
      return
    fi
  fi
  if [ -f "$destination/dist/index.html" ] || [ -f "$destination/index.html" ]; then return 0; fi
  mn_install_web_package
}

run_install_github() {
  # Never let git/pip block the installer by asking for GitHub credentials.
  export GIT_TERMINAL_PROMPT="${GIT_TERMINAL_PROMPT:-0}"
  export GH_PROMPT_DISABLED="${GH_PROMPT_DISABLED:-1}"
  export PIP_NO_INPUT="${PIP_NO_INPUT:-1}"

  MN_MANAGED_PYTHON="${MN_MANAGED_PYTHON:-1}"
  MN_MANAGED_PYTHON_VERSION="${MN_MANAGED_PYTHON_VERSION:-$MN_DEFAULT_MANAGED_PYTHON_VERSION}"
  MN_MANAGED_PYTHON_ROOT="${MN_MANAGED_PYTHON_DIR:-${MN_HOME:-${HOME}/.mn}/python}"
  MN_UV_ROOT="${MN_UV_DIR:-${MN_HOME:-${HOME}/.mn}/uv}"
  MN_UV_BIN=""
  MN_GITHUB_TOKEN_LOOKED_UP="N"
  MN_GITHUB_TOKEN_VALUE=""
  MN_GITHUB_GIT_AUTH_CONFIGURED="N"

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
    cat >"$askpass" <<'EOF'
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
    "$1" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' >/dev/null 2>&1
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
    0 | false | FALSE | False | no | NO | No | n | N) return 1 ;;
    *) return 0 ;;
    esac
  }

  function validate_managed_python_version() {
    if [[ ! "$MN_MANAGED_PYTHON_VERSION" =~ ^[0-9]+[.][0-9]+$ ]]; then
      print_error "MN_MANAGED_PYTHON_VERSION must be a Python minor version like 3.12."
      exit 1
    fi
  }

  function install_uv() {
    local os uv_bin_dir installer
    os="$(uname -s)"

    case "$os" in
    Darwin | Linux) ;;
    *)
      print_error "Unsupported platform for uv-managed Python: ${os}."
      print_error "Set MN_PYTHON=/path/to/python${MN_MANAGED_PYTHON_VERSION} and rerun."
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
      print_error "Install uv manually or set MN_PYTHON=/path/to/python${MN_MANAGED_PYTHON_VERSION}."
      exit 1
    fi

    if ! mn_run_uv_installer "$installer" "$uv_bin_dir" >/dev/null 2>&1; then
      rm -f "$installer"
      print_error "Could not install uv."
      print_error "Install uv manually or set MN_PYTHON=/path/to/python${MN_MANAGED_PYTHON_VERSION}."
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
    [ -x "$python_bin" ] &&
      python_is_supported "$python_bin" &&
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
    print_step "Installing private Python ${MN_MANAGED_PYTHON_VERSION} under ${MN_MANAGED_PYTHON_ROOT}."
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

    MN_PYTHON_BIN="$(mn_base_python_executable "$managed_bin")" || {
      print_error "Could not resolve a stable base Python interpreter from $managed_bin."
      exit 1
    }
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
        MN_PYTHON_BIN="$(mn_base_python_executable "$resolved")" || {
          print_error "Could not resolve a stable base Python interpreter from $resolved."
          exit 1
        }
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
  BIN_DIR="${INSTALL_DIR}/bin"
  VENV_DIR="${INSTALL_DIR}/venv"
  MN_PYTHON_BIN=""
  SCRIPT_DIR="$(mn_script_dir)"
  RUNTIME_COMPOSE_TEMPLATE="${MN_RUNTIME_COMPOSE_TEMPLATE:-}"
  RUNTIME_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
  RUNTIME_COMPOSE_ENV="${INSTALL_DIR}/docker-compose.env"
  MN_WEB_UI_SOURCE_MODE="${MN_WEB_UI_SOURCE_MODE:-source}"
  MN_WEB_UI_SOURCE_MOUNT="${MN_WEB_UI_SOURCE_MOUNT:-${INSTALL_DIR}/webui}"
  MN_WEB_UI_PACKAGE_VERSION="${MN_WEB_UI_PACKAGE_VERSION:-${MN_DEFAULT_WEB_UI_VERSION#v}}"
  INSTALL_CONTEXT_ENGINE="Y"
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
  MN_SYNCTHING_IMAGE="${MN_SYNCTHING_IMAGE:-$MN_DEFAULT_SYNCTHING_IMAGE}"
  MN_SYNCTHING_RESCAN_INTERVAL_SECONDS="${MN_SYNCTHING_RESCAN_INTERVAL_SECONDS:-3600}"
  MN_BLUEPRINT_PYTHON_ENVS_DIR="${MN_BLUEPRINT_PYTHON_ENVS_DIR:-}"
  MN_HOST_OPENSHELL_STATE_DIR="${MN_HOST_OPENSHELL_STATE_DIR:-${INSTALL_DIR}/openshell-state}"

  INSTALL_WEB_UI="Y"
  INSTALL_REDIS="Y"
  MN_OPENSHELL_MODE="${MN_OPENSHELL_MODE:-lazy}"
  START_NOW="Y"
  REINSTALL="Y"
  INSTALL_PYTHON_SDK="Y"
  INSTALL_CLI="Y"
  INSTALL_API="Y"
  INSTALL_VERSION="${MN_INSTALL_VERSION:-}"
  MN_PACKAGE_VERSION=""
  CORE_REPO="${MN_CORE_REPO:-MirrorNeuronLab/MirrorNeuron}"
  MN_SKILLS_GIT_URL="${MN_SKILLS_GIT_URL:-}"
  CORE_RELEASE_TAG=""

  function github_usage() {
    local script_name="${MN_INSTALL_SCRIPT_NAME:-$(basename "$0")}"
    cat >&3 <<EOF
Usage: ./$script_name --mode github [options]

Installs MirrorNeuron from GitHub repositories. Use ./install_dev.sh --mode github.

Options:
  --version TAG                 Install this release tag from each GitHub repo. If omitted, use each repo's default branch.
  --yes                         Use component defaults and require non-interactive sudo.
  --interactive                 Ask each install question before proceeding.
  --reset                       Permanently clear runtime data first; requires typing YES.
  -v, --verbose                 Show installation details and command paths.
  --no-reinstall                Keep an existing install instead of overwriting it.
  --web-ui / --no-web-ui        Enable or skip the native Web UI.
  --redis / --no-redis          Enable or skip Redis Podman setup.
  --context-engine / --no-context-engine
                                Enable or skip Membrane context engine setup.
  --build-membrane              Local mode: build Membrane source instead of pulling GAR.
                                Ignored in github/binary modes. Source: MN_MEMBRANE_DIR
                                or the sibling Membrane checkout.
  --openshell / --no-openshell  Allow or disable on-demand OpenShell workers.
  --syncthing / --no-syncthing  Enable or skip Syncthing shared-storage replication.
  --start / --no-start          Start or skip starting MirrorNeuron after install.
  --python-components LIST      Install only these components: sdk,cli,api.
                                Use all or none as shortcuts.
  --python-sdk / --no-python-sdk
  --cli / --no-cli
  --api / --no-api
  --skills-git-url URL          Same as MN_SKILLS_GIT_URL.
  MN_AGENTS_ROOT=/path          Override the local agent template catalog.
  MN_AGENTS_REPO=OWNER/REPO     Agent template catalog repo. Default: MirrorNeuronLab/mn-agents.
  MN_AGENTS_GIT_URL=URL         Full agent template catalog Git URL override.
  MN_AGENTS_REF=REF             Agent template catalog ref. Default: --version or repo default branch.
  --python PATH                 Same as MN_PYTHON. Must match Python ${MN_MANAGED_PYTHON_VERSION}.x.
  --no-managed-python           Do not use uv to install a private Python runtime.
  MN_HOME=/path                 Override the runtime state directory. Defaults to ${HOME}/.mn.
  GITHUB_TOKEN/GH_TOKEN         Token for private GitHub repositories. An existing gh auth login is also used.
  -h, --help                    Show this help.

Examples:
  ./$script_name --mode github --no-web-ui
  ./$script_name --mode github --version ${MN_DEFAULT_INSTALL_VERSION}
  ./$script_name --mode github --interactive
  ./$script_name --mode github --python-components sdk,api
  MN_PYTHON=/opt/homebrew/bin/python${MN_MANAGED_PYTHON_VERSION} ./$script_name --mode github
EOF
  }

  function set_python_components() {
    local value="$1"
    local component
    local -a components

    INSTALL_PYTHON_SDK="N"
    INSTALL_CLI="N"
    INSTALL_API="N"

    IFS=',' read -r -a components <<<"$value"
    for component in ${components[@]+"${components[@]}"}; do
      component="$(echo "$component" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
      case "$component" in
      all)
        INSTALL_PYTHON_SDK="Y"
        INSTALL_CLI="Y"
        INSTALL_API="Y"
        ;;
      none) ;;
      sdk | python-sdk)
        INSTALL_PYTHON_SDK="Y"
        ;;
      cli)
        INSTALL_CLI="Y"
        ;;
      api)
        INSTALL_API="Y"
        ;;
      "") ;;
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
    --no-reinstall) REINSTALL="N" ;;
    --web-ui) INSTALL_WEB_UI="Y" ;;
    --no-web-ui) INSTALL_WEB_UI="N" ;;
    --redis) INSTALL_REDIS="Y" ;;
    --no-redis) INSTALL_REDIS="N" ;;
    --context-engine) INSTALL_CONTEXT_ENGINE="Y" ;;
    --no-context-engine) INSTALL_CONTEXT_ENGINE="N" ;;
    --openshell) MN_OPENSHELL_MODE=lazy ;;
    --no-openshell) MN_OPENSHELL_MODE=disabled ;;
    --syncthing) MN_SYNCTHING_ENABLED="auto" ;;
    --no-syncthing) MN_SYNCTHING_ENABLED="0" ;;
    --start) START_NOW="Y" ;;
    --no-start) START_NOW="N" ;;
    --python-sdk) INSTALL_PYTHON_SDK="Y" ;;
    --no-python-sdk) INSTALL_PYTHON_SDK="N" ;;
    --cli) INSTALL_CLI="Y" ;;
    --no-cli) INSTALL_CLI="N" ;;
    --api) INSTALL_API="Y" ;;
    --no-api) INSTALL_API="N" ;;
    --version)
      shift
      if [ "$#" -eq 0 ]; then
        print_error "--version requires a release tag such as ${MN_DEFAULT_INSTALL_VERSION}."
        github_usage
        exit 1
      fi
      INSTALL_VERSION="$1"
      ;;
    --version=*)
      INSTALL_VERSION="${1#*=}"
      ;;
    --skills-repo)
      shift
      if [ "$#" -eq 0 ]; then
        print_error "--skills-repo requires a value."
        github_usage
        exit 1
      fi
      print_error "--skills-repo is no longer supported; skills are resolved from package dependencies."
      exit 1
      ;;
    --skills-repo=*)
      print_error "--skills-repo is no longer supported; skills are resolved from package dependencies."
      exit 1
      ;;
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
    -h | --help)
      github_usage
      exit 0
      ;;
    *)
      print_error "Unknown option: $1"
      printf 'Use ./install_dev.sh --help for common options or --help-all for the full reference.\n' >&3
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

  mn_prepare_installer_paths
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

  function should_install_python_packages() {
    [ "$INSTALL_PYTHON_SDK" = "Y" ] ||
      [ "$INSTALL_CLI" = "Y" ] ||
      [ "$INSTALL_API" = "Y" ] ||
      [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]
  }

  function validate_selections() {
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

  function compose_profiles() {
    local profiles=()
    [ "$INSTALL_CONTEXT_ENGINE" = "Y" ] && profiles+=("context")
    case "$(printf '%s' "$MN_SYNCTHING_ENABLED" | tr '[:upper:]' '[:lower:]')" in
    '' | 0 | false | no | n | off | disabled) ;;
    *) profiles+=("syncthing") ;;
    esac
    if [ "${#profiles[@]}" -eq 0 ]; then
      printf ''
      return 0
    fi
    local IFS=,
    printf '%s' "${profiles[*]}"
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

    case "$label:$env_value" in
    MN_GRPC_AUTH_TOKEN:mirror_neuron_password | MN_GRPC_ADMIN_TOKEN:mirror_neuron_password_admin) env_value="" ;;
    esac
    if [ -n "$env_value" ] && [ "$env_value" != "mirrorneuron" ]; then
      printf '%s\n' "$env_value" >"$file"
      chmod 600 "$file" 2>/dev/null || true
      printf '%s\n' "$env_value"
      return 0
    fi

    mkdir -p "$INSTALL_DIR"
    if [ -s "$file" ]; then
      value="$(tr -d '[:space:]' <"$file")"
      case "$label:$value" in
      MN_GRPC_AUTH_TOKEN:mirror_neuron_password | MN_GRPC_ADMIN_TOKEN:mirror_neuron_password_admin) value="" ;;
      esac
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
    printf '%s\n' "$value" >"$file"
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
    prod | production)
      password="$(derive_network_secret "$admin_token" "redis")"
      mkdir -p "$INSTALL_DIR"
      printf '%s\n' "$password" >"${INSTALL_DIR}/redis.password"
      chmod 600 "${INSTALL_DIR}/redis.password" 2>/dev/null || true
      printf '%s\n' "$password"
      ;;
    *)
      printf '%s\n' "mirror_neuron_redis_dev"
      ;;
    esac
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
      printf '{"model_list":[]}\n' >"${gateway_dir}/config.yaml"
    fi
    chmod u+rwX "$gateway_dir" "${gateway_dir}/config.yaml" 2>/dev/null || true
  }

  function write_runtime_compose_files() {
    local context_auth_token profiles network_name network_external network_token redis_password mn_cookie runtime_skills_root runtime_agents_root runtime_package_index context_memory_enabled otterdesk_context_memory_enabled membrane_engine_tag membrane_engine_image litellm_gateway_bind_host api_host
    local grpc_auth_token grpc_admin_token runtime_port_settings
    grpc_auth_token="$(resolve_secret_file "${MN_GRPC_AUTH_TOKEN:-}" "${INSTALL_DIR}/grpc_auth.token" "MN_GRPC_AUTH_TOKEN")"
    grpc_admin_token="$(resolve_secret_file "${MN_GRPC_ADMIN_TOKEN:-}" "${INSTALL_DIR}/grpc_admin.token" "MN_GRPC_ADMIN_TOKEN")"
    context_auth_token="$(resolve_secret_file "${MN_CONTEXT_AUTH_TOKEN:-}" "${INSTALL_DIR}/context_auth.token" "MN_CONTEXT_AUTH_TOKEN")"
    profiles="$(compose_profiles)"
    api_host="${MN_API_HOST:-localhost}"
    litellm_gateway_bind_host="${MN_LITELLM_GATEWAY_BIND_HOST:-0.0.0.0}"
    network_name="${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
    network_external="$(mn_runtime_network_external "$network_name")"
    network_token="$(resolve_network_token)"
    redis_password="$(resolve_redis_password "mirror_neuron_password_admin")"
    mn_cookie="$(resolve_mn_cookie)"
    runtime_skills_root="${MN_SKILLS_ROOT:-${MN_HOST_HOME_DIR}/skills}"
    runtime_agents_root="$(ensure_agent_catalog_root)"
    runtime_package_index="${MN_PACKAGE_INDEX_FILE:-}"
    membrane_engine_tag="${MN_MEMBRANE_ENGINE_IMAGE_TAG:-$(mn_default_membrane_engine_tag)}"
    if [[ "$membrane_engine_tag" != v* ]]; then
      membrane_engine_tag="v${membrane_engine_tag}"
    fi
    membrane_engine_image="${MN_MEMBRANE_ENGINE_IMAGE:-${MN_CONTEXT_ENGINE_IMAGE:-${MN_DEFAULT_MEMBRANE_GAR_IMAGE}:${membrane_engine_tag}}}"
    membrane_engine_image="$(mn_selected_membrane_image "$membrane_engine_image")"
    if [ "$MN_BUILD_MEMBRANE" = "Y" ]; then membrane_engine_tag=""; fi
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
    prepare_litellm_gateway_config
    mn_write_runtime_compose_file "$RUNTIME_COMPOSE_TEMPLATE" "$RUNTIME_COMPOSE_FILE"
    runtime_port_settings="$(mn_runtime_port_settings "$RUNTIME_COMPOSE_ENV")"
    cat >"$RUNTIME_COMPOSE_ENV" <<EOF
COMPOSE_PROJECT_NAME=mirror-neuron
COMPOSE_PROFILES=${profiles}
MN_HOST_STATE_DIR=${INSTALL_DIR}
MN_HOST_HOME_DIR=${MN_HOST_HOME_DIR}
MN_HOST_ARTIFACTS_DIR=${MN_HOST_ARTIFACTS_DIR}
MN_HOST_BLOB_STORE_DIR=${MN_HOST_BLOB_STORE_DIR}
MN_HOST_SHARED_STORAGE_ROOT=${MN_HOST_SHARED_STORAGE_ROOT}
MN_SYNCTHING_ENABLED=${MN_SYNCTHING_ENABLED}
MN_SYNCTHING_IMAGE=${MN_SYNCTHING_IMAGE}
MN_SYNCTHING_RESCAN_INTERVAL_SECONDS=${MN_SYNCTHING_RESCAN_INTERVAL_SECONDS}
MN_BLUEPRINT_PYTHON_ENVS_DIR=${MN_BLUEPRINT_PYTHON_ENVS_DIR}
MN_HOST_OPENSHELL_STATE_DIR=${MN_HOST_OPENSHELL_STATE_DIR}
MN_MEMBRANE_SOURCE_MODE=$(mn_selected_membrane_source_mode)
ENGINE_IMAGE=${membrane_engine_image}
MN_MEMBRANE_ENGINE_IMAGE=${membrane_engine_image}
MN_MEMBRANE_ENGINE_IMAGE_TAG=${membrane_engine_tag}
MN_REDIS_IMAGE=${MN_REDIS_IMAGE:-$MN_DEFAULT_REDIS_IMAGE}
MN_CONTEXT_AUTH_TOKEN=${context_auth_token}
MN_CONTEXT_MODEL_COMPRESSION_ENABLED=true
MN_CONTEXT_OBSERVABILITY=${MN_CONTEXT_OBSERVABILITY:-false}
MN_CONTEXT_TOKEN_COUNTER_FACTORY=${MN_CONTEXT_TOKEN_COUNTER_FACTORY:-}
MN_LLM_MODEL_RUNNER_MODEL=${MN_LLM_MODEL_RUNNER_MODEL:-$MN_DEFAULT_LLM_MODEL_RUNNER_MODEL}
MN_GRPC_BIND_HOST=${MN_GRPC_BIND_HOST:-127.0.0.1}
MN_GRPC_PORT=${MN_GRPC_PORT:-55051}
MN_GRPC_TARGET=${MN_GRPC_TARGET:-localhost:${MN_GRPC_PORT:-55051}}
MN_GRPC_ADVERTISE_PORT=${MN_GRPC_ADVERTISE_PORT:-${MN_GRPC_PORT:-55051}}
MN_NATIVE_SDK_GRPC_HOST=${MN_NATIVE_SDK_GRPC_HOST:-0.0.0.0}
MN_NATIVE_SDK_GRPC_PORT=${MN_NATIVE_SDK_GRPC_PORT:-55052}
MN_NATIVE_SDK_GRPC_ADVERTISE_HOST=${MN_NATIVE_SDK_GRPC_ADVERTISE_HOST:-${MN_NETWORK_ADVERTISE_HOST:-}}
MN_NATIVE_SDK_GRPC_ADVERTISE_PORT=${MN_NATIVE_SDK_GRPC_ADVERTISE_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_NATIVE_SDK_GRPC_TARGET=${MN_NATIVE_SDK_GRPC_TARGET:-mn-native-sdk-grpc:55052}
MN_RESOURCE_GC_ENABLED=${MN_RESOURCE_GC_ENABLED:-true}
MN_RESOURCE_GC_INTERVAL_SECONDS=${MN_RESOURCE_GC_INTERVAL_SECONDS:-1800}
MN_RESOURCE_GC_ORPHAN_GRACE_SECONDS=${MN_RESOURCE_GC_ORPHAN_GRACE_SECONDS:-3600}
MN_RESOURCE_GC_BATCH_SIZE=${MN_RESOURCE_GC_BATCH_SIZE:-100}
MN_DOCKER_WORKER_IMAGE_CACHE_TTL_SECONDS=${MN_DOCKER_WORKER_IMAGE_CACHE_TTL_SECONDS:-604800}
MN_DOCKER_WORKER_IMAGE_CACHE_MAX_BYTES=${MN_DOCKER_WORKER_IMAGE_CACHE_MAX_BYTES:-21474836480}
MN_NATIVE_SDK_GRPC_PROXY_PORT=${MN_NATIVE_SDK_GRPC_PROXY_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_NATIVE_SDK_GRPC_PROXY_TARGET_HOST=${MN_NATIVE_SDK_GRPC_PROXY_TARGET_HOST:-host.containers.internal}
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
MN_WEB_UI_NPM_REGISTRY=${MN_WEB_UI_NPM_REGISTRY:-https://${MN_GAR_LOCATION:-$MN_DEFAULT_PYTHON_GAR_LOCATION}-npm.pkg.dev/${MN_GAR_PROJECT:-$MN_DEFAULT_CORE_GAR_PROJECT}/${MN_GAR_NPM_REPOSITORY:-$MN_DEFAULT_WEB_UI_GAR_NPM_REPOSITORY}/}
MN_WEB_UI_SOURCE_MODE=${MN_WEB_UI_SOURCE_MODE}
MN_WEB_UI_SOURCE_MOUNT=${MN_WEB_UI_SOURCE_MOUNT}
MN_WEB_UI_PACKAGE_VERSION=${MN_WEB_UI_PACKAGE_VERSION}
MN_BLUEPRINT_WEB_UI_BIND_HOST=${MN_BLUEPRINT_WEB_UI_BIND_HOST:-0.0.0.0}
MN_BLUEPRINT_WEB_UI_PUBLIC_HOST=${MN_BLUEPRINT_WEB_UI_PUBLIC_HOST:-localhost}
${runtime_port_settings}
MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE=${MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE:-prepublished}
MN_ENV=${MN_ENV:-prod}
MN_USE_LOCAL_SKILLS=${MN_USE_LOCAL_SKILLS}
MN_BLUEPRINT_SOURCE=${MN_BLUEPRINT_SOURCE:-github}
MN_BLUEPRINT_REPO=${MN_BLUEPRINT_REPO:-https://github.com/MirrorNeuronLab/mn-blueprints.git}
MN_BLUEPRINT_LOCAL=${MN_BLUEPRINT_LOCAL:-}
MN_WORKSPACE_ROOT=${MN_WORKSPACE_ROOT:-}
MN_CONNECT_URL=${MN_CONNECT_URL:-}
MN_AGENTS_ROOT=${runtime_agents_root}
MN_SKILLS_ROOT=${runtime_skills_root}
MN_PACKAGE_INDEX_FILE=${runtime_package_index}
MN_PIP_INDEX_URL=${MN_PIP_INDEX_URL:-${MN_PYTHON_INDEX_URL:-${MN_DEFAULT_PIP_INDEX_URL}}}
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
$(mn_openshell_plugin_env)
MN_SYNCTHING_UID=${MN_SYNCTHING_UID}
MN_SYNCTHING_GID=${MN_SYNCTHING_GID}
PODMAN_HOST_SOCKET=${PODMAN_HOST_SOCKET}
COMPOSE_PARALLEL_LIMIT=${COMPOSE_PARALLEL_LIMIT:-1}
MN_COOKIE=${mn_cookie}
MN_GRPC_AUTH_TOKEN=${grpc_auth_token}
MN_GRPC_ADMIN_TOKEN=${grpc_admin_token}
EOF
    chmod 600 "$RUNTIME_COMPOSE_ENV" 2>/dev/null || true
  }

  EXISTING_INSTALL="N"
  if [ "$MN_EXISTING_INSTALL" = "Y" ]; then
    if [ "$MN_INSTALL_RESET" != "Y" ]; then
      print_step "Refreshing the existing installation."
    fi
    if [ "$MN_INSTALL_RESET" = "Y" ]; then
      REINSTALL="Y"
    elif [ "$NON_INTERACTIVE" != "Y" ]; then
      REINSTALL=$(ask "Reinstall the existing installation?" "$REINSTALL")
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
    printf '\nChoose components. Press Enter to accept each default.\n' >&3
    INSTALL_WEB_UI=$(ask "Install the Web UI?" "$INSTALL_WEB_UI")
    INSTALL_REDIS=$(ask "Enable Redis?" "$INSTALL_REDIS")
    if [ "$MN_BUILD_MEMBRANE" != "Y" ]; then
      INSTALL_CONTEXT_ENGINE=$(ask "Enable the Membrane context engine?" "$INSTALL_CONTEXT_ENGINE")
    fi
    START_NOW=$(ask "Start the runtime after installation?" "$START_NOW")
  fi
  validate_selections

  mn_print_install_summary
  mn_report_system

  require_cmd git
  require_cmd curl
  configure_github_git_auth
  mn_install_client_stage

  mn_begin_runtime_install || return 1
  resolve_python_runtime
  if [ "$EXISTING_INSTALL" = "Y" ]; then
    print_step "Preparing fresh install"
    mn_remove_existing_install_paths
  fi

  print_step "Installing MirrorNeuron Core (Podman)"

  (
    mn_remove_path_or_exit "$INSTALL_DIR/core-source" "MirrorNeuron Core source"
    github_clone "$(core_git_url)" "$INSTALL_DIR/core-source" >/dev/null 2>&1
    cd "$INSTALL_DIR/core-source"

    if [ ! -f Dockerfile ]; then
      print_error "The Core checkout must include its runtime Dockerfile."
      exit 1
    fi

    mn_run_podman_build -t mirror-neuron-core .
  ) &
  spinner $! "Cloning and building Core (Podman image mirror-neuron-core)"
  write_runtime_compose_files

  if should_install_python_packages; then
    print_step "Installing selected Python components from GitHub"
    (
      "$MN_PYTHON_BIN" -m venv "$VENV_DIR" >/dev/null 2>&1
      run_quiet "pip-upgrade" "$VENV_DIR/bin/pip" install --upgrade pip
      # The Git runtime depends on the worker SDK even when only a surface was
      # explicitly selected. Use the requested ref in each source repository.
      local sdk_reference
      sdk_reference="git+https://github.com/MirrorNeuronLab/mn-python-sdk.git$(github_ref_suffix)"
      local -a sdk_requirements=("mirrorneuron-python-sdk @ $sdk_reference") sdk_groups=(sdk)
      local package_name package_path package_extras component_rows
      component_rows="$(mn_sdk_component_rows "${sdk_groups[@]}")" || return 1
      while IFS=$'\t' read -r package_name package_path package_extras; do
        [ -n "$package_name" ] || continue
        sdk_requirements+=("${package_name}${package_extras} @ ${sdk_reference}#subdirectory=${package_path#mn-python-sdk/}")
      done <<<"$component_rows"
      run_quiet "install-mn-python-sdk-github" "$VENV_DIR/bin/pip" install "${sdk_requirements[@]}"
      run_quiet "install-mn-runtime-github" "$VENV_DIR/bin/pip" install "mirrorneuron-runtime @ git+https://github.com/MirrorNeuronLab/mn-python-sdk.git$(github_ref_suffix)#subdirectory=packages/runtime"
      if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
        run_quiet "install-membrane-python-sdk-github" "$VENV_DIR/bin/pip" install "mirrorneuron-membrane-python-sdk @ git+$(context_engine_git_url)$(github_ref_suffix)#subdirectory=mn-context-engine-python-sdk"
      fi
    ) &
    spinner $! "Setting up virtualenv and installing Python packages"
  else
    print_step "Python component installation disabled by selection."
  fi

  mn_prepare_native_web_assets
  mn_configure_installed_runtime

  if [ "$INSTALL_CLI" = "Y" ]; then
    print_detail "CLI: mn"
  fi
  if [ "$INSTALL_API" = "Y" ]; then
    print_detail "API: mn-api"
  fi
  if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
    print_detail "Membrane endpoint: ${MN_CONTEXT_ADDR:-localhost:50052}"
  fi

  mn_finish_runtime_install
  mn_print_install_complete
}

run_install_local() {
  SCRIPT_DIR="$(mn_script_dir)"
  WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

  INSTALL_DIR="${MN_HOME:-${HOME}/.mn}"
  BIN_DIR="${INSTALL_DIR}/bin"
  VENV_DIR="${INSTALL_DIR}/venv"
  RUNTIME_COMPOSE_TEMPLATE="${SCRIPT_DIR}/docker-compose.yml"
  RUNTIME_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
  RUNTIME_COMPOSE_ENV="${INSTALL_DIR}/docker-compose.env"

  CORE_DIR="${WORKSPACE_DIR}/MirrorNeuron"
  CLI_DIR="${WORKSPACE_DIR}/mn-cli"
  API_DIR="${WORKSPACE_DIR}/mn-api"
  PY_SDK_DIR="${WORKSPACE_DIR}/mn-python-sdk"
  CLIENT_SUPPORT_DIR="${WORKSPACE_DIR}/mn-client-support"
  WEB_UI_DIR="${WORKSPACE_DIR}/mn-web-ui"
  MN_WEB_UI_SOURCE_MODE="${MN_WEB_UI_SOURCE_MODE:-source}"
  MN_WEB_UI_SOURCE_MOUNT="${MN_WEB_UI_SOURCE_MOUNT:-${WEB_UI_DIR}}"
  MN_WEB_UI_PACKAGE_VERSION="${MN_WEB_UI_PACKAGE_VERSION:-${MN_DEFAULT_WEB_UI_VERSION#v}}"
  SKILLS_DIR="${WORKSPACE_DIR}/mn-skills"
  AGENTS_DIR="${WORKSPACE_DIR}/mn-agents"
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
  MN_SYNCTHING_IMAGE="${MN_SYNCTHING_IMAGE:-$MN_DEFAULT_SYNCTHING_IMAGE}"
  MN_SYNCTHING_RESCAN_INTERVAL_SECONDS="${MN_SYNCTHING_RESCAN_INTERVAL_SECONDS:-3600}"
  MN_BLUEPRINT_PYTHON_ENVS_DIR="${MN_BLUEPRINT_PYTHON_ENVS_DIR:-}"
  MN_HOST_OPENSHELL_STATE_DIR="${MN_HOST_OPENSHELL_STATE_DIR:-${INSTALL_DIR}/openshell-state}"
  MN_PYTHON_BIN=""
  MN_MANAGED_PYTHON="${MN_MANAGED_PYTHON:-1}"
  MN_MANAGED_PYTHON_VERSION="${MN_MANAGED_PYTHON_VERSION:-$MN_DEFAULT_MANAGED_PYTHON_VERSION}"
  MN_MANAGED_PYTHON_ROOT="${MN_MANAGED_PYTHON_DIR:-${MN_HOME:-${HOME}/.mn}/python}"
  MN_UV_ROOT="${MN_UV_DIR:-${MN_HOME:-${HOME}/.mn}/uv}"
  MN_UV_BIN=""

  INSTALL_WEB_UI="Y"
  INSTALL_REDIS="Y"
  INSTALL_CONTEXT_ENGINE="Y"
  MN_OPENSHELL_MODE="${MN_OPENSHELL_MODE:-lazy}"
  INSTALL_SKILLS="Y"
  START_NOW="Y"

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
    "$1" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' >/dev/null 2>&1
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
    0 | false | FALSE | False | no | NO | No | n | N) return 1 ;;
    *) return 0 ;;
    esac
  }

  function validate_managed_python_version() {
    if [[ ! "$MN_MANAGED_PYTHON_VERSION" =~ ^[0-9]+[.][0-9]+$ ]]; then
      print_error "MN_MANAGED_PYTHON_VERSION must be a Python minor version like 3.12."
      exit 1
    fi
  }

  function install_uv() {
    local os uv_bin_dir installer
    os="$(uname -s)"

    case "$os" in
    Darwin | Linux) ;;
    *)
      print_error "Unsupported platform for uv-managed Python: ${os}."
      print_error "Set MN_PYTHON=/path/to/python${MN_MANAGED_PYTHON_VERSION} and rerun."
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
      print_error "Install uv manually or set MN_PYTHON=/path/to/python${MN_MANAGED_PYTHON_VERSION}."
      exit 1
    fi

    if ! mn_run_uv_installer "$installer" "$uv_bin_dir" >/dev/null 2>&1; then
      rm -f "$installer"
      print_error "Could not install uv."
      print_error "Install uv manually or set MN_PYTHON=/path/to/python${MN_MANAGED_PYTHON_VERSION}."
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
    [ -x "$python_bin" ] &&
      python_is_supported "$python_bin" &&
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
    print_step "Installing private Python ${MN_MANAGED_PYTHON_VERSION} under ${MN_MANAGED_PYTHON_ROOT}."
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

    MN_PYTHON_BIN="$(mn_base_python_executable "$managed_bin")" || {
      print_error "Could not resolve a stable base Python interpreter from $managed_bin."
      exit 1
    }
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
        MN_PYTHON_BIN="$(mn_base_python_executable "$resolved")" || {
          print_error "Could not resolve a stable base Python interpreter from $resolved."
          exit 1
        }
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
Usage: ./install_dev.sh --mode local [options]

Installs MirrorNeuron from local sibling folders under:
  ${WORKSPACE_DIR}
Clones mn-client-support from GitHub if its sibling checkout is missing.

Options:
  --yes                 Use component defaults and require non-interactive sudo.
  --interactive         Ask each install question before proceeding.
  --reset               Permanently clear runtime data first; requires typing YES.
  -v, --verbose         Show installation details and command paths.
  --web-ui              Enable the native Web UI.
  --no-web-ui           Skip the native Web UI.
  --redis               Enable Redis Podman setup.
  --no-redis            Skip Redis Podman setup.
  --context-engine      Install/start Membrane context engine.
  --no-context-engine   Skip Membrane context engine setup.
  --build-membrane      Build local Membrane source instead of pulling GAR.
                        Override source location with MN_MEMBRANE_DIR.
  --openshell           Allow on-demand OpenShell workers (default).
  --no-openshell        Disable OpenShell workers on this node.
  --syncthing / --no-syncthing
                        Enable or skip Syncthing shared-storage replication.
  --no-skills           Skip optional packages under mn-skills. Skills required
                        by local runtime packages are still installed locally.
  --start               Start MirrorNeuron after install.
  --no-start            Skip starting MirrorNeuron after install.
  --python PATH         Same as MN_PYTHON. Must match Python ${MN_MANAGED_PYTHON_VERSION}.x.
  --no-managed-python   Do not use uv to install a private Python runtime.
  MN_PYTHON=/path       Use a specific Python ${MN_MANAGED_PYTHON_VERSION}.x interpreter.
  MN_HOME=/path         Override the runtime state directory. Defaults to ${HOME}/.mn.
  MN_AGENTS_ROOT=/path  Override the local agent template catalog. Defaults to ${WORKSPACE_DIR}/mn-agents.
  MN_MANAGED_PYTHON=0   Disable uv-managed private Python fallback.
  -h, --help            Show this help.
EOF
  }

  while [ "$#" -gt 0 ]; do
    case "$1" in
    --web-ui) INSTALL_WEB_UI="Y" ;;
    --no-web-ui) INSTALL_WEB_UI="N" ;;
    --redis) INSTALL_REDIS="Y" ;;
    --no-redis) INSTALL_REDIS="N" ;;
    --context-engine) INSTALL_CONTEXT_ENGINE="Y" ;;
    --no-context-engine) INSTALL_CONTEXT_ENGINE="N" ;;
    --openshell) MN_OPENSHELL_MODE=lazy ;;
    --no-openshell) MN_OPENSHELL_MODE=disabled ;;
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
    -h | --help)
      usage
      exit 0
      ;;
    *)
      print_error "Unknown option: $1"
      printf 'Use ./install_dev.sh --help for common options or --help-all for the full reference.\n' >&3
      exit 1
      ;;
    esac
    shift
  done

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

    relpath="${abs_path#"${repo_dir}"/}"
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
    local install_path workspace_path source_path
    install_path="$(canonical_path "$INSTALL_DIR")"
    workspace_path="$(canonical_path "$WORKSPACE_DIR")"

    if [ "$install_path" = "$workspace_path" ]; then
      print_error "Refusing to install MirrorNeuron state into the source workspace: ${INSTALL_DIR}"
      print_error "Unset MN_HOME or set it to a state directory such as ${HOME}/.mn."
      exit 1
    fi

    for source_path in "$CORE_DIR" "$CLI_DIR" "$API_DIR" "$PY_SDK_DIR" "$CLIENT_SUPPORT_DIR" \
      "$WEB_UI_DIR" "$SKILLS_DIR" "$BLUEPRINTS_DIR" "$DOCS_DIR" "$SYSTEM_TESTS_DIR" "$MEMBRANE_DIR"; do
      if [ "$install_path" = "$(canonical_path "$source_path")" ]; then
        print_error "Refusing to install MirrorNeuron state into source directory: ${INSTALL_DIR}"
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

  function write_local_install_metadata() {
    local metadata_file="${INSTALL_DIR}/install_metadata.json"
    local updated_at
    updated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    cat >"$metadata_file" <<EOF
{
  "install_type": "local_source",
  "source_workspace": "${WORKSPACE_DIR}",
  "updated_at": "${updated_at}"
}
EOF
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

  function resolve_secret_file() {
    local value="${1:-}" file="$2" label="$3"
    case "$label:$value" in
    MN_GRPC_AUTH_TOKEN:mirror_neuron_password | MN_GRPC_ADMIN_TOKEN:mirror_neuron_password_admin) value="" ;;
    esac
    mkdir -p "$INSTALL_DIR"
    if [ -z "$value" ] && [ -s "$file" ]; then
      value="$(tr -d '[:space:]' <"$file")"
      case "$label:$value" in
      MN_GRPC_AUTH_TOKEN:mirror_neuron_password | MN_GRPC_ADMIN_TOKEN:mirror_neuron_password_admin) value="" ;;
      esac
    fi
    if [ -z "$value" ]; then
      value="$(generate_mn_cookie)" || return 1
    fi
    if [ -z "$value" ]; then
      print_error "Failed to generate ${label}."
      return 1
    fi
    (
      umask 077
      printf '%s\n' "$value" >"$file"
    )
    chmod 600 "$file"
    printf '%s\n' "$value"
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
      cookie="$(tr -d '[:space:]' <"$cookie_file")"
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

    printf '%s\n' "$cookie" >"$cookie_file"
    chmod 600 "$cookie_file" 2>/dev/null || true
    printf '%s\n' "$cookie"
  }

  function resolve_network_token() {
    local env_token="${MN_NETWORK_JOIN_TOKEN:-}"
    local token_file="${INSTALL_DIR}/network.token"
    local token

    if [ -n "$env_token" ]; then
      printf '%s\n' "$env_token" >"$token_file"
      chmod 600 "$token_file" 2>/dev/null || true
      printf '%s\n' "$env_token"
      return 0
    fi

    mkdir -p "$INSTALL_DIR"
    if [ -s "$token_file" ]; then
      token="$(tr -d '[:space:]' <"$token_file")"
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
    printf '%s\n' "$token" >"$token_file"
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
    prod | production)
      password="$(derive_network_secret "$admin_token" "redis")"
      mkdir -p "$INSTALL_DIR"
      printf '%s\n' "$password" >"${INSTALL_DIR}/redis.password"
      chmod 600 "${INSTALL_DIR}/redis.password" 2>/dev/null || true
      printf '%s\n' "$password"
      ;;
    *)
      printf '%s\n' "mirror_neuron_redis_dev"
      ;;
    esac
  }

  function compose_profiles() {
    local profiles=()
    [ "$INSTALL_CONTEXT_ENGINE" = "Y" ] && profiles+=("context")
    case "$(printf '%s' "$MN_SYNCTHING_ENABLED" | tr '[:upper:]' '[:lower:]')" in
    '' | 0 | false | no | n | off | disabled) ;;
    *) profiles+=("syncthing") ;;
    esac
    if [ "${#profiles[@]}" -eq 0 ]; then
      printf ''
      return 0
    fi
    local IFS=,
    printf '%s' "${profiles[*]}"
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
      printf '{"model_list":[]}\n' >"${gateway_dir}/config.yaml"
    fi
    chmod u+rwX "$gateway_dir" "${gateway_dir}/config.yaml" 2>/dev/null || true
  }

  function write_runtime_compose_files() {
    local context_auth_token profiles network_name network_external network_token redis_password mn_cookie runtime_skills_root runtime_agents_root runtime_package_index context_memory_enabled otterdesk_context_memory_enabled membrane_engine_tag membrane_engine_image litellm_gateway_bind_host api_host
    local grpc_auth_token grpc_admin_token runtime_port_settings
    grpc_auth_token="$(resolve_secret_file "${MN_GRPC_AUTH_TOKEN:-}" "${INSTALL_DIR}/grpc_auth.token" "MN_GRPC_AUTH_TOKEN")"
    grpc_admin_token="$(resolve_secret_file "${MN_GRPC_ADMIN_TOKEN:-}" "${INSTALL_DIR}/grpc_admin.token" "MN_GRPC_ADMIN_TOKEN")"
    context_auth_token="$(resolve_secret_file "${MN_CONTEXT_AUTH_TOKEN:-}" "${INSTALL_DIR}/context_auth.token" "MN_CONTEXT_AUTH_TOKEN")"
    profiles="$(compose_profiles)"
    api_host="${MN_API_HOST:-localhost}"
    litellm_gateway_bind_host="${MN_LITELLM_GATEWAY_BIND_HOST:-0.0.0.0}"
    network_name="${MN_DOCKER_NETWORK_NAME:-mirror-neuron-runtime}"
    network_external="$(mn_runtime_network_external "$network_name")"
    network_token="$(resolve_network_token)"
    redis_password="$(resolve_redis_password "mirror_neuron_password_admin")"
    mn_cookie="$(resolve_mn_cookie)"
    runtime_skills_root="${MN_SKILLS_ROOT:-${MN_HOST_HOME_DIR}/skills}"
    runtime_agents_root="$(ensure_agent_catalog_root)"
    runtime_package_index="${MN_PACKAGE_INDEX_FILE:-}"
    membrane_engine_tag="${MN_MEMBRANE_ENGINE_IMAGE_TAG:-$(mn_default_membrane_engine_tag)}"
    if [[ "$membrane_engine_tag" != v* ]]; then
      membrane_engine_tag="v${membrane_engine_tag}"
    fi
    membrane_engine_image="${MN_MEMBRANE_ENGINE_IMAGE:-${MN_CONTEXT_ENGINE_IMAGE:-${MN_DEFAULT_MEMBRANE_GAR_IMAGE}:${membrane_engine_tag}}}"
    membrane_engine_image="$(mn_selected_membrane_image "$membrane_engine_image")"
    if [ "$MN_BUILD_MEMBRANE" = "Y" ]; then membrane_engine_tag=""; fi
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
    prepare_litellm_gateway_config
    mn_write_runtime_compose_file "$RUNTIME_COMPOSE_TEMPLATE" "$RUNTIME_COMPOSE_FILE"
    runtime_port_settings="$(mn_runtime_port_settings "$RUNTIME_COMPOSE_ENV")"
    cat >"$RUNTIME_COMPOSE_ENV" <<EOF
COMPOSE_PROJECT_NAME=mirror-neuron
COMPOSE_PROFILES=${profiles}
MN_HOST_STATE_DIR=${INSTALL_DIR}
MN_HOST_HOME_DIR=${MN_HOST_HOME_DIR}
MN_HOST_ARTIFACTS_DIR=${MN_HOST_ARTIFACTS_DIR}
MN_HOST_BLOB_STORE_DIR=${MN_HOST_BLOB_STORE_DIR}
MN_HOST_SHARED_STORAGE_ROOT=${MN_HOST_SHARED_STORAGE_ROOT}
MN_SYNCTHING_ENABLED=${MN_SYNCTHING_ENABLED}
MN_SYNCTHING_IMAGE=${MN_SYNCTHING_IMAGE}
MN_SYNCTHING_RESCAN_INTERVAL_SECONDS=${MN_SYNCTHING_RESCAN_INTERVAL_SECONDS}
MN_BLUEPRINT_PYTHON_ENVS_DIR=${MN_BLUEPRINT_PYTHON_ENVS_DIR}
MN_HOST_OPENSHELL_STATE_DIR=${MN_HOST_OPENSHELL_STATE_DIR}
MN_MEMBRANE_SOURCE_MODE=$(mn_selected_membrane_source_mode)
ENGINE_IMAGE=${membrane_engine_image}
MN_MEMBRANE_ENGINE_IMAGE=${membrane_engine_image}
MN_MEMBRANE_ENGINE_IMAGE_TAG=${membrane_engine_tag}
MN_REDIS_IMAGE=${MN_REDIS_IMAGE:-$MN_DEFAULT_REDIS_IMAGE}
MN_CONTEXT_AUTH_TOKEN=${context_auth_token}
MN_CONTEXT_MODEL_COMPRESSION_ENABLED=true
MN_CONTEXT_OBSERVABILITY=${MN_CONTEXT_OBSERVABILITY:-false}
MN_CONTEXT_TOKEN_COUNTER_FACTORY=${MN_CONTEXT_TOKEN_COUNTER_FACTORY:-}
MN_LLM_MODEL_RUNNER_MODEL=${MN_LLM_MODEL_RUNNER_MODEL:-$MN_DEFAULT_LLM_MODEL_RUNNER_MODEL}
MN_GRPC_BIND_HOST=${MN_GRPC_BIND_HOST:-127.0.0.1}
MN_GRPC_PORT=${MN_GRPC_PORT:-55051}
MN_GRPC_TARGET=${MN_GRPC_TARGET:-localhost:${MN_GRPC_PORT:-55051}}
MN_GRPC_ADVERTISE_PORT=${MN_GRPC_ADVERTISE_PORT:-${MN_GRPC_PORT:-55051}}
MN_NATIVE_SDK_GRPC_HOST=${MN_NATIVE_SDK_GRPC_HOST:-0.0.0.0}
MN_NATIVE_SDK_GRPC_PORT=${MN_NATIVE_SDK_GRPC_PORT:-55052}
MN_NATIVE_SDK_GRPC_ADVERTISE_HOST=${MN_NATIVE_SDK_GRPC_ADVERTISE_HOST:-${MN_NETWORK_ADVERTISE_HOST:-}}
MN_NATIVE_SDK_GRPC_ADVERTISE_PORT=${MN_NATIVE_SDK_GRPC_ADVERTISE_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_NATIVE_SDK_GRPC_TARGET=${MN_NATIVE_SDK_GRPC_TARGET:-mn-native-sdk-grpc:55052}
MN_RESOURCE_GC_ENABLED=${MN_RESOURCE_GC_ENABLED:-true}
MN_RESOURCE_GC_INTERVAL_SECONDS=${MN_RESOURCE_GC_INTERVAL_SECONDS:-1800}
MN_RESOURCE_GC_ORPHAN_GRACE_SECONDS=${MN_RESOURCE_GC_ORPHAN_GRACE_SECONDS:-3600}
MN_RESOURCE_GC_BATCH_SIZE=${MN_RESOURCE_GC_BATCH_SIZE:-100}
MN_DOCKER_WORKER_IMAGE_CACHE_TTL_SECONDS=${MN_DOCKER_WORKER_IMAGE_CACHE_TTL_SECONDS:-604800}
MN_DOCKER_WORKER_IMAGE_CACHE_MAX_BYTES=${MN_DOCKER_WORKER_IMAGE_CACHE_MAX_BYTES:-21474836480}
MN_NATIVE_SDK_GRPC_PROXY_PORT=${MN_NATIVE_SDK_GRPC_PROXY_PORT:-${MN_NATIVE_SDK_GRPC_PORT:-55052}}
MN_NATIVE_SDK_GRPC_PROXY_TARGET_HOST=${MN_NATIVE_SDK_GRPC_PROXY_TARGET_HOST:-host.containers.internal}
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
MN_WEB_UI_NPM_REGISTRY=${MN_WEB_UI_NPM_REGISTRY:-https://${MN_GAR_LOCATION:-$MN_DEFAULT_PYTHON_GAR_LOCATION}-npm.pkg.dev/${MN_GAR_PROJECT:-$MN_DEFAULT_CORE_GAR_PROJECT}/${MN_GAR_NPM_REPOSITORY:-$MN_DEFAULT_WEB_UI_GAR_NPM_REPOSITORY}/}
MN_WEB_UI_SOURCE_MODE=${MN_WEB_UI_SOURCE_MODE}
MN_WEB_UI_SOURCE_MOUNT=${MN_WEB_UI_SOURCE_MOUNT}
MN_WEB_UI_PACKAGE_VERSION=${MN_WEB_UI_PACKAGE_VERSION}
MN_BLUEPRINT_WEB_UI_BIND_HOST=${MN_BLUEPRINT_WEB_UI_BIND_HOST:-0.0.0.0}
MN_BLUEPRINT_WEB_UI_PUBLIC_HOST=${MN_BLUEPRINT_WEB_UI_PUBLIC_HOST:-localhost}
${runtime_port_settings}
MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE=${MN_BLUEPRINT_WEB_UI_PORT_ALLOCATION_MODE:-prepublished}
MN_ENV=${MN_ENV:-prod}
MN_USE_LOCAL_SKILLS=${MN_USE_LOCAL_SKILLS}
MN_BLUEPRINT_SOURCE=${MN_BLUEPRINT_SOURCE:-github}
MN_BLUEPRINT_REPO=${MN_BLUEPRINT_REPO:-https://github.com/MirrorNeuronLab/mn-blueprints.git}
MN_BLUEPRINT_LOCAL=${MN_BLUEPRINT_LOCAL:-}
MN_WORKSPACE_ROOT=${MN_WORKSPACE_ROOT:-}
MN_CONNECT_URL=${MN_CONNECT_URL:-}
MN_AGENTS_ROOT=${runtime_agents_root}
MN_SKILLS_ROOT=${runtime_skills_root}
MN_PACKAGE_INDEX_FILE=${runtime_package_index}
MN_PIP_INDEX_URL=${MN_PIP_INDEX_URL:-${MN_PYTHON_INDEX_URL:-${MN_DEFAULT_PIP_INDEX_URL}}}
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
$(mn_openshell_plugin_env)
MN_SYNCTHING_UID=${MN_SYNCTHING_UID}
MN_SYNCTHING_GID=${MN_SYNCTHING_GID}
PODMAN_HOST_SOCKET=${PODMAN_HOST_SOCKET}
COMPOSE_PARALLEL_LIMIT=${COMPOSE_PARALLEL_LIMIT:-1}
MN_COOKIE=${mn_cookie}
MN_GRPC_AUTH_TOKEN=${grpc_auth_token}
MN_GRPC_ADMIN_TOKEN=${grpc_admin_token}
EOF
    chmod 600 "$RUNTIME_COMPOSE_ENV" 2>/dev/null || true
  }

  require_install_dir_not_source
  mn_prepare_installer_paths
  print_header

  if [ "$MN_INSTALL_RESET" != "Y" ] && [ "$MN_EXISTING_INSTALL" = "Y" ]; then
    print_step "Refreshing the existing local source installation."
  fi

  if [ "$NON_INTERACTIVE" != "Y" ]; then
    printf '\nChoose components. Press Enter to accept each default.\n' >&3
    INSTALL_WEB_UI=$(ask "Install the Web UI?" "$INSTALL_WEB_UI")
    INSTALL_REDIS=$(ask "Enable Redis?" "$INSTALL_REDIS")
    if [ "$MN_BUILD_MEMBRANE" != "Y" ]; then
      INSTALL_CONTEXT_ENGINE=$(ask "Enable the Membrane context engine?" "$INSTALL_CONTEXT_ENGINE")
    fi
    INSTALL_SKILLS=$(ask "Install optional local skills?" "$INSTALL_SKILLS")
    START_NOW=$(ask "Start the runtime after installation?" "$START_NOW")
  fi

  mn_print_install_summary
  mn_report_system
  mn_install_client_stage

  mn_begin_runtime_install || return 1
  require_dir "$CORE_DIR" "MirrorNeuron core"
  require_file "$CORE_DIR/Dockerfile" "MirrorNeuron Dockerfile"
  require_mix_project_file "$CORE_DIR/mix.exs"
  require_dir "$PY_SDK_DIR" "mn-python-sdk"
  for component_project in "$PY_SDK_DIR"/packages/*/pyproject.toml; do
    require_file "$component_project" "SDK component project"
  done

  if [ "$INSTALL_WEB_UI" = "Y" ]; then require_dir "$WEB_UI_DIR" "mn-web-ui"; fi
  if [ "$INSTALL_SKILLS" = "Y" ]; then require_dir "$SKILLS_DIR" "mn-skills"; fi
  if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
    require_dir "$MEMBRANE_DIR" "Membrane context engine"
    require_file "$MEMBRANE_DIR/Dockerfile" "Membrane Dockerfile"
  fi

  resolve_python_runtime

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
  print_step "Writing Compose runtime configuration"
  write_runtime_compose_files
  print_detail "Local component links: ${INSTALL_DIR}"

  print_step "Building MirrorNeuron Core Podman image from local source"
  (
    cd "$CORE_DIR"
    mn_run_podman_build -t mirror-neuron-core:latest .
  )
  print_detail "Built local core image: mirror-neuron-core:latest"

  function install_local_editable_python_packages() {
    local -a editable_requirements=(-e "${PY_SDK_DIR}")
    local component_pyproject skill_pyproject agent_pyproject
    local agents_root="${MN_AGENTS_ROOT:-$AGENTS_DIR}"
    # Local mode must keep the complete SDK component family on source paths.
    # Otherwise pip can resolve a CLI/API dependency (for example MCP) from GAR
    # even though its sibling checkout is present, or fail when it is unpublished.
    for component_pyproject in "$PY_SDK_DIR"/packages/*/pyproject.toml; do
      [ -f "$component_pyproject" ] || continue
      editable_requirements+=(-e "$(dirname "$component_pyproject")")
    done
    if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
      editable_requirements+=(-e "$MEMBRANE_DIR/mn-context-engine-python-sdk")
    fi
    # Block compilation fingerprints its selected default implementations before
    # isolated worker preparation, including the supervised-service agent.
    for agent_pyproject in "$agents_root"/*/pyproject.toml; do
      [ -f "$agent_pyproject" ] || continue
      editable_requirements+=(-e "$(dirname "$agent_pyproject")")
    done
    if [ "$INSTALL_SKILLS" = "Y" ]; then
      for skill_pyproject in "$SKILLS_DIR"/*/pyproject.toml; do
        [ -f "$skill_pyproject" ] || continue
        editable_requirements+=(-e "$(dirname "$skill_pyproject")")
      done
    fi
    # One resolution transaction selects local components over registry versions.
    "$VENV_DIR/bin/pip" install "${editable_requirements[@]}"
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
  trap 'restore_local_venv_backup_on_failure; mn_reset_release_lock' EXIT

  print_step "Installing Python components from local source"
  (
    mn_run_logged "local Python virtual environment" "$MN_PYTHON_BIN" -m venv "$VENV_DIR"
    mn_run_logged "pip upgrade" "$VENV_DIR/bin/pip" install --upgrade pip
    mn_run_logged "local editable Python packages" install_local_editable_python_packages
  ) &
  spinner $! "Installing local editable Python packages"
  "$VENV_DIR/bin/python" -c 'import mn_sdk, mn_runtime' || {
    print_error "Local SDK and runtime source checkouts are not import-compatible."
    exit 1
  }
  VENV_INSTALL_OK="Y"
  if [ -n "$VENV_BACKUP_DIR" ]; then
    rm -rf "$VENV_BACKUP_DIR"
  fi
  trap mn_reset_release_lock EXIT

  mn_prepare_native_web_assets "$WEB_UI_DIR"
  mn_configure_installed_runtime

  print_detail "Core image: mirror-neuron-core:latest (${CORE_DIR})"
  print_detail "CLI/API: native builds from the local workspace"
  print_detail "State: ${INSTALL_DIR}"
  print_detail "Cookie: ${INSTALL_DIR}/erlang.cookie"
  if [ "$INSTALL_WEB_UI" = "Y" ]; then
    print_detail "Web UI source: ${WEB_UI_DIR}"
  fi
  if [ "$INSTALL_CONTEXT_ENGINE" = "Y" ]; then
    print_detail "Membrane: ${MEMBRANE_DIR} (${MN_CONTEXT_ADDR:-localhost:50052})"
  fi
  print_detail "Rebuild after Elixir changes: ${SCRIPT_DIR}/install_dev.sh --no-web-ui --no-skills"

  mn_finish_runtime_install
  mn_print_install_complete
}

function mn_install_runtime() {
  case "$MN_INSTALL_MODE" in
    local) run_install_local "$@" ;;
    github) run_install_github "$@" ;;
  esac
}

mn_install_main "$@"
