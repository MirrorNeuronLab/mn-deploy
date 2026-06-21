#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=""
FORCE="N"

usage() {
    cat <<EOF
Usage: ./save_install_support.sh --version v1.2.7 [--force]

Copy installer support files from this mn-deploy checkout into
install_support/<version>/.

Options:
  --version TAG   Release tag to snapshot, for example v1.2.7.
  --force         Overwrite an existing snapshot.
  -h, --help      Show this help.
EOF
}

validate_version() {
    local tag="$1"
    local semver_tag_regex='^v(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)(-(alpha|beta|rc)[.](0|[1-9][0-9]*))?$'

    if [[ ! "$tag" =~ $semver_tag_regex ]]; then
        echo "Invalid release version '$tag'." >&2
        echo "Expected vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-rc.N." >&2
        exit 1
    fi
}

validate_support_files() {
    local compose_file="$1"
    local package_index="$2"

    if [[ ! -f "$compose_file" ]]; then
        echo "Docker Compose template was not found: $compose_file" >&2
        exit 1
    fi
    if ! grep -q '^name: mirror-neuron$' "$compose_file" || ! grep -q 'mirror-neuron-core' "$compose_file"; then
        echo "Docker Compose template does not look like the MirrorNeuron runtime template: $compose_file" >&2
        exit 1
    fi

    if [[ ! -f "$package_index" ]]; then
        echo "Python package index was not found: $package_index" >&2
        exit 1
    fi
    if ! grep -q 'name = "mirrorneuron-python-sdk"' "$package_index" ||
       ! grep -q 'installer_groups = \["sdk"\]' "$package_index"; then
        echo "Python package index does not look like the MirrorNeuron installer index: $package_index" >&2
        exit 1
    fi
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --version)
            shift
            [[ "$#" -gt 0 ]] || { echo "--version requires a value." >&2; usage >&2; exit 1; }
            VERSION="$1"
            ;;
        --version=*)
            VERSION="${1#*=}"
            ;;
        --force)
            FORCE="Y"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

if [[ -z "$VERSION" ]]; then
    echo "--version is required." >&2
    usage >&2
    exit 1
fi

validate_version "$VERSION"

compose_source="${SCRIPT_DIR}/docker-compose.yml"
package_index_source="${SCRIPT_DIR}/package-index/python-packages.toml"
support_dir="${SCRIPT_DIR}/install_support/${VERSION}"
compose_target="${support_dir}/docker-compose.yml"
package_index_target="${support_dir}/package-index/python-packages.toml"

validate_support_files "$compose_source" "$package_index_source"

if [[ -d "$support_dir" && "$FORCE" != "Y" ]]; then
    if find "$support_dir" -mindepth 1 -print -quit | grep -q .; then
        echo "Install support snapshot already exists: $support_dir" >&2
        echo "Pass --force to overwrite it." >&2
        exit 1
    fi
fi

mkdir -p "${support_dir}/package-index"
cp "$compose_source" "$compose_target"
cp "$package_index_source" "$package_index_target"

validate_support_files "$compose_target" "$package_index_target"

echo "Saved install support snapshot: $support_dir"
