#!/usr/bin/env bash
set -euo pipefail

DEST_ROOT="${DEST_ROOT:-${HOME}/Projects/mirror-neuron-set}"
CLEAN=0
DRY_RUN=0
RECURSE_SUBMODULES=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
  ESC="$(printf '\033')"
  BOLD="${ESC}[1m"
  RED="${ESC}[31m"
  GREEN="${ESC}[32m"
  YELLOW="${ESC}[33m"
  CYAN="${ESC}[36m"
  RESET="${ESC}[0m"
else
  BOLD=""
  RED=""
  GREEN=""
  YELLOW=""
  CYAN=""
  RESET=""
fi

ui_step() { printf '%s==>%s %s\n' "${CYAN}${BOLD}" "$RESET" "$1"; }
ui_success() { printf '%s✓%s %s\n' "${GREEN}${BOLD}" "$RESET" "$1"; }
ui_warning() { printf '%swarning:%s %s\n' "${YELLOW}${BOLD}" "$RESET" "$1"; }
ui_error() { printf '%serror:%s %s\n' "${RED}${BOLD}" "$RESET" "$1" >&2; }

usage() {
  cat <<'EOF_USAGE'
Usage:
  clone_all_repos.sh [--dest-root PATH] [--clean] [--dry-run] [--recurse-submodules] [--help]

Options:
  --dest-root PATH        Target root directory for clones (default: $HOME/Projects/mirror-neuron-set)
  --clean                 Remove existing destination repo folders before cloning
  --dry-run               Print actions without changing disk
  --recurse-submodules    Pass --recurse-submodules to git clone
  --help                  Show this message
EOF_USAGE
}

while (( "$#" > 0 )); do
  case "${1}" in
    --dest-root)
      DEST_ROOT="${2:?missing value}"
      shift 2
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --recurse-submodules)
      RECURSE_SUBMODULES=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      ui_error "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

mkdir -p "${DEST_ROOT}"

repos=(
  "git@github.com:MirrorNeuronLab/Membrane.git"
  "git@github.com:MirrorNeuronLab/MirrorNeuron.git"
  "git@github.com:MirrorNeuronLab/mn-agents.git"
  "git@github.com:MirrorNeuronLab/mn-api.git"
  "git@github.com:MirrorNeuronLab/mn-cli.git"
  "git@github.com:MirrorNeuronLab/mn-deploy.git"
  "git@github.com:MirrorNeuronLab/mn-docs.git"
  "git@github.com:MirrorNeuronLab/mn-python-sdk.git"
  "git@github.com:MirrorNeuronLab/mn-skills.git"
  "git@github.com:MirrorNeuronLab/mn-system-tests.git"
  "git@github.com:MirrorNeuronLab/mn-web-ui.git"
  "git@github.com:MirrorNeuronLab/otterdesk-blueprints.git"
  "git@github.com:MirrorNeuronLab/otterdesk-desktop-app.git"
)

for url in "${repos[@]}"; do
  name="${url##*/}"
  name="${name%.git}"
  target="${DEST_ROOT}/${name}"

  if [ -d "$target" ]; then
    if (( CLEAN )); then
      if (( DRY_RUN )); then
        ui_step "Would remove ${target}"
      else
        ui_step "Removing ${target}"
        rm -rf -- "$target"
      fi
    else
      ui_warning "Skipped ${target}; use --clean to replace it."
      continue
    fi
  fi

  if (( RECURSE_SUBMODULES )); then
    if (( DRY_RUN )); then
      ui_step "Would clone ${name} with submodules"
    else
      ui_step "Cloning ${name} with submodules"
      git clone --recurse-submodules "$url" "$target"
    fi
  else
    if (( DRY_RUN )); then
      ui_step "Would clone ${name}"
    else
      ui_step "Cloning ${name}"
      git clone "$url" "$target"
    fi
  fi
done

ui_success "Repository setup completed."
