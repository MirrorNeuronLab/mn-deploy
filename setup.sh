#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

VENV_DIR="${HOME}/.local/share/mn_venv"
BIN_DIR="${HOME}/.local/bin"
PYTHON_BIN="${MN_PYTHON:-python3.12}"
FORCE_REINSTALL=false
REPO_ROOT="$(cd "$DIR/.." && pwd)"
MN_HOME_DIR="${MN_HOME:-\$HOME/.mn}"
MN_SKILLS_ROOT_DIR="${MN_SKILLS_ROOT:-$REPO_ROOT/mn-skills}"
MN_BLUEPRINT_LOCAL_DIR="${MN_BLUEPRINT_LOCAL:-$REPO_ROOT/otterdesk-blueprints}"
MN_ENV_VALUE="${MN_ENV:-dev}"
MN_BLUEPRINT_SOURCE_VALUE="${MN_BLUEPRINT_SOURCE:-local}"
MN_USE_LOCAL_SKILLS_VALUE="${MN_USE_LOCAL_SKILLS:-1}"

detect_shell_rc() {
  local shell_name
  shell_name="$(basename "${SHELL:-}")"
  case "$shell_name" in
  zsh)
    echo "$HOME/.zshrc"
    ;;
  bash)
    if [ -f "$HOME/.bashrc" ]; then
      echo "$HOME/.bashrc"
    elif [ "$(uname -s)" = "Darwin" ]; then
      echo "$HOME/.bash_profile"
    else
      echo "$HOME/.bashrc"
    fi
    ;;
  *)
    if [ -n "${ZSH_VERSION:-}" ]; then
      echo "$HOME/.zshrc"
    elif [ -n "${BASH_VERSION:-}" ]; then
      if [ -f "$HOME/.bashrc" ]; then
        echo "$HOME/.bashrc"
      elif [ "$(uname -s)" = "Darwin" ]; then
        echo "$HOME/.bash_profile"
      else
        echo "$HOME/.bashrc"
      fi
    else
      echo "$HOME/.profile"
    fi
    ;;
  esac
}

upsert_shell_rc_block() {
  local rc_file="$1"
  local begin_marker="$2"
  local end_marker="$3"
  local block_content="$4"
  local tmp_file

  mkdir -p "$(dirname "$rc_file")"
  touch "$rc_file"
  tmp_file="$(mktemp)"

  awk -v begin="$begin_marker" -v end="$end_marker" '
        $0 == begin { skip = 1; next }
        $0 == end { skip = 0; next }
        !skip { print }
    ' "$rc_file" >"$tmp_file"

  {
    cat "$tmp_file"
    printf "\n%s\n" "$begin_marker"
    printf "%s\n" "$block_content"
    printf "%s\n" "$end_marker"
  } >"$rc_file"

  rm -f "$tmp_file"
}

for arg in "$@"; do
  if [ "$arg" == "--reinstall" ]; then
    FORCE_REINSTALL=true
  fi
done

echo "=> Checking dependencies and environment..."
echo "=> Fetching Elixir dependencies..."
(cd "$REPO_ROOT/MirrorNeuron" && mix deps.get && mix compile)

if [ "$FORCE_REINSTALL" = true ] && [ -d "$VENV_DIR" ]; then
  echo "=> Force reinstall requested. Removing old venv..."
  rm -rf "$VENV_DIR"
fi

if [ ! -d "$VENV_DIR" ]; then
  echo "=> Creating Python virtual environment in $VENV_DIR..."
  "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

echo "=> Updating Python package tools..."
"$VENV_DIR/bin/pip" install --upgrade pip

echo "=> Installing the SDK from local folders..."
"$VENV_DIR/bin/pip" install -e ../mn-python-sdk/packages/common \
  -e ../mn-python-sdk/packages/contracts -e ../mn-python-sdk/packages/web-ui \
  -e ../mn-python-sdk

echo "=> Building the local Rust clients as Wasm in $BIN_DIR..."
install_dev_clients() (
  set -eu
  local builds="$VENV_DIR/wasm-clients" target="${CARGO_TARGET_DIR:-$VENV_DIR/rust-client-build}"
  local source_root="${MN_CLIENT_SOURCE_ROOT:-$REPO_ROOT}" work release engine cargo
  local profile="${MN_HOME:-$HOME/.mn}" client
  local cargo_home="${CARGO_HOME:-$HOME/.cargo}" rustup_home="${RUSTUP_HOME:-$HOME/.rustup}"
  local dev_data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
  cargo=$(command -v cargo || printf '%s' "$cargo_home/bin/cargo")
  mkdir -p "$BIN_DIR" "$builds" "$target"
  work=$(mktemp -d "$builds/.setup.XXXXXXXX")
  trap 'rm -rf "$work"' EXIT
  mkdir "$work/home"
  engine=${MN_WASMTIME_BIN:-$(command -v wasmtime || true)}
  if [ -z "$engine" ] && [ -x "$builds/current/bin/wasmtime" ]; then engine="$builds/current/bin/wasmtime"; fi
  if [ -z "$engine" ] && [ -x "$HOME/.mn/client-current/bin/wasmtime" ]; then engine="$HOME/.mn/client-current/bin/wasmtime"; fi
  # Initialize a fresh client profile through the installer. Stage the binaries
  # separately when the developer already has a full runtime or other data.
  client=$work/client
  if [ ! -e "$profile" ] && [ ! -L "$profile" ]; then
    client=$profile
  elif [ -d "$profile" ] && [ ! -L "$profile" ] && [ -z "$(find "$profile" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    client=$profile
  fi
  HOME="$work/home" XDG_DATA_HOME="$dev_data_home" MN_HOME="$client" MN_ENV=dev MN_WASMTIME_BIN="$engine" \
    CARGO_HOME="$cargo_home" RUSTUP_HOME="$rustup_home" CARGO_TARGET_DIR="$target" \
    MN_CLIENT_SOURCE_ROOT="$source_root" "$DIR/install_dev.sh" --no-runtime --yes
  "$cargo" build --locked --release --bin mn-web-ui-server --manifest-path "$source_root/mn-api/Cargo.toml" --target-dir "$target"
  release=$(mktemp -d "$builds/local.XXXXXXXX")
  if [ "$client" = "$work/client" ]; then
    mv "$client/client-current/bin" "$release/bin"
  else
    cp -Rp "$client/client-current/bin" "$release/bin"
  fi
  cp "$target/release/mn-web-ui-server" "$release/bin/"
  ln -s "${release##*/}" "$work/current"
  mv -fT "$work/current" "$builds/current" 2>/dev/null || mv -fh "$work/current" "$builds/current"
  for command in mn mn-api mn-client-support mn-web-ui-server; do
    ln -sfn "$builds/current/bin/$command" "$BIN_DIR/$command"
  done
)
install_dev_clients

SHELL_RC="$(detect_shell_rc)"

if ! grep -q "$BIN_DIR" "$SHELL_RC" 2>/dev/null; then
  echo -e "\nexport PATH=\"\$PATH:$BIN_DIR\"" >>"$SHELL_RC"
  echo "=> Added $BIN_DIR to $SHELL_RC"
fi

MN_ENV_BLOCK="$(
  cat <<EOF
case "\$PATH:" in
  "$VENV_DIR/wasm-clients/current/bin:"*) ;;
  *) export PATH="$VENV_DIR/wasm-clients/current/bin:\$PATH" ;;
esac
export MN_HOME="$MN_HOME_DIR"
export MN_ENV="$MN_ENV_VALUE"
export MN_BLUEPRINT_SOURCE="$MN_BLUEPRINT_SOURCE_VALUE"
export MN_BLUEPRINT_LOCAL="$MN_BLUEPRINT_LOCAL_DIR"
export MN_USE_LOCAL_SKILLS="$MN_USE_LOCAL_SKILLS_VALUE"
export MN_SKILLS_ROOT="$MN_SKILLS_ROOT_DIR"
EOF
)"

upsert_shell_rc_block \
  "$SHELL_RC" \
  "# >>> mirror neuron env >>>" \
  "# <<< mirror neuron env <<<" \
  "$MN_ENV_BLOCK"
echo "=> Updated Mirror Neuron environment in $SHELL_RC"

echo "=> Environment setup complete."
