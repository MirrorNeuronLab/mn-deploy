#!/usr/bin/env bash
set -euo pipefail

DEST_ROOT="${DEST_ROOT:-${HOME}/Projects/mirror-neuron-set}"
CLEAN=0
DRY_RUN=0
RECURSE_SUBMODULES=0

usage() {
  cat <<'EOF_USAGE'
Usage:
  clone_all_repos.sh [--dest-root PATH] [--clean] [--dry-run] [--recurse-submodules] [--help]

Options:
  --dest-root PATH        Target root directory for clones (default: /Users/homer/Projects/mirror-neuron-set)
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
      echo "Unknown option: $1"
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
        echo "[dry-run] rm -rf -- '${target}'"
      else
        echo "[clean] removing: $target"
        rm -rf -- "$target"
      fi
    else
      echo "[skip] exists: $target (use --clean to replace)"
      continue
    fi
  fi

  if (( RECURSE_SUBMODULES )); then
    if (( DRY_RUN )); then
      echo "[dry-run] git clone --recurse-submodules '$url' '$target'"
    else
      echo "Cloning (with submodules): $url -> $target"
      git clone --recurse-submodules "$url" "$target"
    fi
  else
    if (( DRY_RUN )); then
      echo "[dry-run] git clone '$url' '$target'"
    else
      echo "Cloning: $url -> $target"
      git clone "$url" "$target"
    fi
  fi
done

echo "Done."
