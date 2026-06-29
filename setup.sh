#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

VENV_DIR="${HOME}/.local/share/mn_venv"
BIN_DIR="${HOME}/.local/bin"
PYTHON_BIN="${MN_PYTHON:-python3.11}"
FORCE_REINSTALL=false
REPO_ROOT="$(cd "$DIR/.." && pwd)"
MN_HOME_DIR="\$HOME/.mn"
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
    ' "$rc_file" > "$tmp_file"

    {
        cat "$tmp_file"
        printf "\n%s\n" "$begin_marker"
        printf "%s\n" "$block_content"
        printf "%s\n" "$end_marker"
    } > "$rc_file"

    rm -f "$tmp_file"
}

for arg in "$@"; do
    if [ "$arg" == "--reinstall" ]; then
        FORCE_REINSTALL=true
    fi
done

echo "=> Checking dependencies and environment..."
echo "=> Fetching Elixir dependencies..."
mix deps.get
mix compile

if [ "$FORCE_REINSTALL" = true ] && [ -d "$VENV_DIR" ]; then
    echo "=> Force reinstall requested. Removing old venv..."
    rm -rf "$VENV_DIR"
fi

if [ ! -d "$VENV_DIR" ]; then
    echo "=> Creating Python virtual environment in $VENV_DIR..."
    "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

echo "=> Installing Python packages (SDK, CLI, API)..."
"$VENV_DIR/bin/pip" install --upgrade pip

echo "=> Installing mn-python-sdk from local folder..."
"$VENV_DIR/bin/pip" install -e ../mn-python-sdk

echo "=> Installing mn-cli from local folder..."
"$VENV_DIR/bin/pip" install -e ../mn-cli

echo "=> Installing mn-api from local folder..."
"$VENV_DIR/bin/pip" install -e ../mn-api

echo "=> Setting up mn CLI in $BIN_DIR..."
mkdir -p "$BIN_DIR"
rm -f "$BIN_DIR/mn" "$BIN_DIR/mn-api"

if [ -f "$VENV_DIR/bin/mn" ]; then ln -s "$VENV_DIR/bin/mn" "$BIN_DIR/mn"; fi
if [ -f "$VENV_DIR/bin/mn-api" ]; then ln -s "$VENV_DIR/bin/mn-api" "$BIN_DIR/mn-api"; fi

SHELL_RC="$(detect_shell_rc)"

if ! grep -q "$BIN_DIR" "$SHELL_RC" 2>/dev/null; then
    echo -e "\nexport PATH=\"\$PATH:$BIN_DIR\"" >> "$SHELL_RC"
    echo "=> Added $BIN_DIR to $SHELL_RC"
fi

MN_ENV_BLOCK="$(cat <<EOF
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
