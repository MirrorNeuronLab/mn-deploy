#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT="${MN_GAR_PROJECT:-mirrorneuron-public-packages}"
LOCATION="${MN_GAR_LOCATION:-us-central1}"
MEMBRANE_DIR="${MN_MEMBRANE_DIR:-${WORKSPACE_ROOT}/Membrane}"
VERSION="${MN_MEMBRANE_VERSION:-${MN_PACKAGE_VERSION:-}}"
DIST_DIR="${MN_MEMBRANE_DIST_DIR:-${SCRIPT_DIR}/dist/membrane}"
BINARY_ARTIFACTS_DIR="${MN_MEMBRANE_BINARY_ARTIFACTS_DIR:-}"
BINARY_REPOSITORY="${MN_MEMBRANE_GAR_BINARY_REPOSITORY:-mirrorneuron-binaries}"
BINARY_PACKAGE="${MN_MEMBRANE_GAR_BINARY_PACKAGE:-membrane}"
DOCKER_REPOSITORY="${MN_MEMBRANE_GAR_DOCKER_REPOSITORY:-mirrorneuron-runtime}"
DOCKER_IMAGE_NAME="${MN_MEMBRANE_DOCKER_IMAGE_NAME:-membrane-context-engine}"
DOCKER_PLATFORMS="${MN_MEMBRANE_DOCKER_PLATFORMS:-linux/amd64,linux/arm64}"
GCLOUD_BIN="${MN_GCLOUD_BIN:-gcloud}"
DOCKER_BIN="${MN_DOCKER_BIN:-docker}"
CARGO_BIN="${MN_CARGO_BIN:-cargo}"
APPLY="N"
PUBLISH_BINARY="Y"
PUBLISH_DOCKER="Y"
TAG_LATEST="Y"
PREPARED_BINARY_ARTIFACT_DIR=""

usage() {
    cat <<EOF
Usage: ./publish_public_membrane_to_google_artifact_registry.sh [options]

Publish public Membrane Rust binary archives and Docker runtime images to
Google Artifact Registry using the public MirrorNeuron package project.

Defaults to dry-run. Pass --apply to create repositories, grant public read,
upload generic binary artifacts, and push Docker images.

Options:
  --apply                         Publish artifacts. Default is dry-run.
  --version VERSION               Release version/tag, for example v1.2.24.
                                   Env: MN_MEMBRANE_VERSION or MN_PACKAGE_VERSION.
  --project PROJECT               GAR project. Env: MN_GAR_PROJECT.
                                   Default: mirrorneuron-public-packages.
  --location LOCATION             GAR location. Env: MN_GAR_LOCATION.
                                   Default: us-central1.
  --membrane-dir PATH             Membrane checkout. Env: MN_MEMBRANE_DIR.
  --dist-dir PATH                 Local binary packaging output directory.
                                   Env: MN_MEMBRANE_DIST_DIR.
  --binary-artifacts-dir PATH     Upload existing release archives instead of
                                   building a local host Rust package.
                                   Env: MN_MEMBRANE_BINARY_ARTIFACTS_DIR.
  --binary-repository NAME        GAR generic repository for Rust archives.
                                   Env: MN_MEMBRANE_GAR_BINARY_REPOSITORY.
                                   Default: mirrorneuron-binaries.
  --binary-package NAME           GAR generic package name.
                                   Env: MN_MEMBRANE_GAR_BINARY_PACKAGE.
                                   Default: membrane.
  --docker-repository NAME        GAR Docker repository for runtime images.
                                   Env: MN_MEMBRANE_GAR_DOCKER_REPOSITORY.
                                   Default: mirrorneuron-runtime.
  --docker-image-name NAME        Docker image name.
                                   Env: MN_MEMBRANE_DOCKER_IMAGE_NAME.
                                   Default: membrane-context-engine.
  --docker-platforms LIST         Docker buildx platforms.
                                   Env: MN_MEMBRANE_DOCKER_PLATFORMS.
                                   Default: linux/amd64,linux/arm64.
  --skip-binary                   Do not publish generic Rust binary archives.
  --skip-docker                   Do not publish the Docker runtime image.
  --no-latest                     Do not tag the Docker image as latest.
  --gcloud PATH                   gcloud executable. Env: MN_GCLOUD_BIN.
  --docker PATH                   docker executable. Env: MN_DOCKER_BIN.
  --cargo PATH                    cargo executable. Env: MN_CARGO_BIN.
  -h, --help                      Show this help.

Examples:
  ./publish_public_membrane_to_google_artifact_registry.sh --version v1.2.24

  ./publish_public_membrane_to_google_artifact_registry.sh \\
    --apply \\
    --version v1.2.24

  ./publish_public_membrane_to_google_artifact_registry.sh \\
    --apply \\
    --version v1.2.24 \\
    --binary-artifacts-dir /tmp/membrane-release-assets
EOF
}

log() {
    printf '%s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

quote_args() {
    local arg
    for arg in "$@"; do
        printf ' %q' "$arg"
    done
    printf '\n'
}

run_or_echo() {
    if [ "$APPLY" = "Y" ]; then
        "$@"
    else
        printf 'DRY RUN:'
        quote_args "$@"
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply) APPLY="Y" ;;
        --version)
            shift
            [ "$#" -gt 0 ] || die "--version requires a value."
            VERSION="$1"
            ;;
        --version=*) VERSION="${1#*=}" ;;
        --project)
            shift
            [ "$#" -gt 0 ] || die "--project requires a value."
            PROJECT="$1"
            ;;
        --project=*) PROJECT="${1#*=}" ;;
        --location)
            shift
            [ "$#" -gt 0 ] || die "--location requires a value."
            LOCATION="$1"
            ;;
        --location=*) LOCATION="${1#*=}" ;;
        --membrane-dir)
            shift
            [ "$#" -gt 0 ] || die "--membrane-dir requires a value."
            MEMBRANE_DIR="$1"
            ;;
        --membrane-dir=*) MEMBRANE_DIR="${1#*=}" ;;
        --dist-dir)
            shift
            [ "$#" -gt 0 ] || die "--dist-dir requires a value."
            DIST_DIR="$1"
            ;;
        --dist-dir=*) DIST_DIR="${1#*=}" ;;
        --binary-artifacts-dir)
            shift
            [ "$#" -gt 0 ] || die "--binary-artifacts-dir requires a value."
            BINARY_ARTIFACTS_DIR="$1"
            ;;
        --binary-artifacts-dir=*) BINARY_ARTIFACTS_DIR="${1#*=}" ;;
        --binary-repository)
            shift
            [ "$#" -gt 0 ] || die "--binary-repository requires a value."
            BINARY_REPOSITORY="$1"
            ;;
        --binary-repository=*) BINARY_REPOSITORY="${1#*=}" ;;
        --binary-package)
            shift
            [ "$#" -gt 0 ] || die "--binary-package requires a value."
            BINARY_PACKAGE="$1"
            ;;
        --binary-package=*) BINARY_PACKAGE="${1#*=}" ;;
        --docker-repository)
            shift
            [ "$#" -gt 0 ] || die "--docker-repository requires a value."
            DOCKER_REPOSITORY="$1"
            ;;
        --docker-repository=*) DOCKER_REPOSITORY="${1#*=}" ;;
        --docker-image-name)
            shift
            [ "$#" -gt 0 ] || die "--docker-image-name requires a value."
            DOCKER_IMAGE_NAME="$1"
            ;;
        --docker-image-name=*) DOCKER_IMAGE_NAME="${1#*=}" ;;
        --docker-platforms)
            shift
            [ "$#" -gt 0 ] || die "--docker-platforms requires a value."
            DOCKER_PLATFORMS="$1"
            ;;
        --docker-platforms=*) DOCKER_PLATFORMS="${1#*=}" ;;
        --skip-binary) PUBLISH_BINARY="N" ;;
        --skip-docker) PUBLISH_DOCKER="N" ;;
        --no-latest) TAG_LATEST="N" ;;
        --gcloud)
            shift
            [ "$#" -gt 0 ] || die "--gcloud requires a value."
            GCLOUD_BIN="$1"
            ;;
        --gcloud=*) GCLOUD_BIN="${1#*=}" ;;
        --docker)
            shift
            [ "$#" -gt 0 ] || die "--docker requires a value."
            DOCKER_BIN="$1"
            ;;
        --docker=*) DOCKER_BIN="${1#*=}" ;;
        --cargo)
            shift
            [ "$#" -gt 0 ] || die "--cargo requires a value."
            CARGO_BIN="$1"
            ;;
        --cargo=*) CARGO_BIN="${1#*=}" ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
    shift
done

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

normalize_version_tag() {
    local value="$1"
    value="${value#refs/tags/}"
    value="${value#release/}"
    case "$value" in
        v*) printf '%s' "$value" ;;
        *) printf 'v%s' "$value" ;;
    esac
}

infer_version() {
    if [ -n "$VERSION" ]; then
        normalize_version_tag "$VERSION"
        return
    fi

    if [ -d "${MEMBRANE_DIR}/.git" ] && command_exists git; then
        local tag
        tag="$(git -C "$MEMBRANE_DIR" describe --tags --exact-match 2>/dev/null || true)"
        if [ -n "$tag" ]; then
            normalize_version_tag "$tag"
            return
        fi
    fi

    die "Release version is required. Pass --version v1.2.24 or set MN_MEMBRANE_VERSION."
}

host_package_suffix() {
    local os_name arch_name
    os_name="$(uname -s)"
    arch_name="$(uname -m)"
    case "${os_name}:${arch_name}" in
        Darwin:arm64|Darwin:aarch64) printf 'darwin-arm64' ;;
        Darwin:x86_64|Darwin:amd64) printf 'darwin-x86_64' ;;
        Linux:arm64|Linux:aarch64) printf 'linux-arm64' ;;
        Linux:x86_64|Linux:amd64) printf 'linux-x86_64' ;;
        *) die "Unsupported host for local Rust packaging: ${os_name} ${arch_name}. Use --binary-artifacts-dir instead." ;;
    esac
}

sha256_file() {
    if command_exists sha256sum; then
        sha256sum "$@"
    else
        shasum -a 256 "$@"
    fi
}

require_common_tools() {
    command_exists "$GCLOUD_BIN" || die "'$GCLOUD_BIN' was not found."
    if [ "$PUBLISH_DOCKER" = "Y" ]; then
        command_exists "$DOCKER_BIN" || die "'$DOCKER_BIN' was not found."
    fi
    if [ "$PUBLISH_BINARY" = "Y" ] && [ -z "$BINARY_ARTIFACTS_DIR" ]; then
        command_exists "$CARGO_BIN" || die "'$CARGO_BIN' was not found."
        command_exists tar || die "'tar' was not found."
        command_exists zip || die "'zip' was not found."
        command_exists sha256sum || command_exists shasum || die "'sha256sum' or 'shasum' is required."
    fi
}

check_gcloud_auth_for_apply() {
    local active_account
    active_account="$("$GCLOUD_BIN" auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1 || true)"
    if [ -z "$active_account" ]; then
        cat >&2 <<EOF
No active gcloud account was found.
Run:
  gcloud auth login
EOF
        exit 1
    fi
    if ! "$GCLOUD_BIN" auth print-access-token >/dev/null 2>&1; then
        cat >&2 <<EOF
gcloud cannot refresh an access token for ${active_account}.
Run:
  gcloud auth login
EOF
        exit 1
    fi
}

ensure_repository_public() {
    local repository="$1"
    local format="$2"
    local description="$3"

    if [ "$APPLY" != "Y" ]; then
        run_or_echo "$GCLOUD_BIN" artifacts repositories describe "$repository" \
            --project="$PROJECT" \
            --location="$LOCATION"
        run_or_echo "$GCLOUD_BIN" artifacts repositories create "$repository" \
            --repository-format="$format" \
            --project="$PROJECT" \
            --location="$LOCATION" \
            --description="$description"
        run_or_echo "$GCLOUD_BIN" artifacts repositories add-iam-policy-binding "$repository" \
            --project="$PROJECT" \
            --location="$LOCATION" \
            --member=allUsers \
            --role=roles/artifactregistry.reader \
            --condition=None \
            --quiet
        return
    fi

    "$GCLOUD_BIN" services enable artifactregistry.googleapis.com --project="$PROJECT"

    if "$GCLOUD_BIN" artifacts repositories describe "$repository" \
        --project="$PROJECT" \
        --location="$LOCATION" >/dev/null 2>&1; then
        log "GAR repository ${repository} already exists in ${PROJECT}/${LOCATION}."
    else
        log "Creating ${format} GAR repository ${repository} in ${PROJECT}/${LOCATION}."
        "$GCLOUD_BIN" artifacts repositories create "$repository" \
            --repository-format="$format" \
            --project="$PROJECT" \
            --location="$LOCATION" \
            --description="$description"
    fi

    "$GCLOUD_BIN" artifacts repositories add-iam-policy-binding "$repository" \
        --project="$PROJECT" \
        --location="$LOCATION" \
        --member=allUsers \
        --role=roles/artifactregistry.reader \
        --condition=None \
        --quiet
}

prepare_binary_artifacts() {
    local version_tag="$1"
    if [ -n "$BINARY_ARTIFACTS_DIR" ]; then
        [ -d "$BINARY_ARTIFACTS_DIR" ] || die "Binary artifacts directory was not found: $BINARY_ARTIFACTS_DIR"
        if [ -z "$(find "$BINARY_ARTIFACTS_DIR" -type f -print -quit)" ]; then
            die "Binary artifacts directory has no files: $BINARY_ARTIFACTS_DIR"
        fi
        PREPARED_BINARY_ARTIFACT_DIR="$BINARY_ARTIFACTS_DIR"
        return
    fi

    [ -d "$MEMBRANE_DIR/mn-context-engine" ] || die "Membrane Rust crate was not found under: $MEMBRANE_DIR"

    local suffix package_name package_root package_dir artifact_dir binary_path checksum_file
    suffix="$(host_package_suffix)"
    package_name="membrane-${version_tag}-${suffix}"
    package_root="${DIST_DIR}/package"
    package_dir="${package_root}/${package_name}"
    artifact_dir="${DIST_DIR}/binary"
    binary_path="${MEMBRANE_DIR}/mn-context-engine/target/release/mn-context-engine"
    checksum_file="${artifact_dir}/membrane-${version_tag}-SHA256SUMS.txt"

    if [ "$APPLY" = "Y" ]; then
        "$CARGO_BIN" build --release --locked --manifest-path "${MEMBRANE_DIR}/mn-context-engine/Cargo.toml"
    else
        run_or_echo "$CARGO_BIN" build --release --locked --manifest-path "${MEMBRANE_DIR}/mn-context-engine/Cargo.toml"
    fi

    if [ "$APPLY" = "Y" ] && [ ! -x "$binary_path" ]; then
        die "Rust binary was not built: $binary_path"
    fi

    if [ "$APPLY" = "Y" ]; then
        mkdir -p "$artifact_dir"
        rm -rf "$package_root"
        mkdir -p "$package_dir/docs"
        cp "$binary_path" "$package_dir/"
        [ -f "${MEMBRANE_DIR}/README.md" ] && cp "${MEMBRANE_DIR}/README.md" "$package_dir/"
        [ -f "${MEMBRANE_DIR}/docs/docker.md" ] && cp "${MEMBRANE_DIR}/docs/docker.md" "$package_dir/docs/"
        [ -f "${MEMBRANE_DIR}/docs/integration.md" ] && cp "${MEMBRANE_DIR}/docs/integration.md" "$package_dir/docs/"
        tar -C "$package_root" -czf "${artifact_dir}/${package_name}.tar.gz" "$package_name"
        (cd "$package_root" && zip -qr "${artifact_dir}/${package_name}.zip" "$package_name")
        rm -f "$checksum_file"
        (
            cd "$artifact_dir"
            sha256_file "${package_name}.tar.gz" "${package_name}.zip" > "$checksum_file"
        )
        rm -rf "$package_root"
    else
        log "DRY RUN: would package local Membrane Rust binary into ${artifact_dir}/${package_name}.tar.gz"
        log "DRY RUN: would package local Membrane Rust binary into ${artifact_dir}/${package_name}.zip"
        log "DRY RUN: would write ${checksum_file}"
    fi

    PREPARED_BINARY_ARTIFACT_DIR="$artifact_dir"
}

publish_binary_artifacts() {
    local version_tag="$1"
    local artifact_dir="$2"

    ensure_repository_public "$BINARY_REPOSITORY" generic "MirrorNeuron public binary release archives"

    run_or_echo "$GCLOUD_BIN" artifacts generic upload \
        --project="$PROJECT" \
        --location="$LOCATION" \
        --repository="$BINARY_REPOSITORY" \
        --package="$BINARY_PACKAGE" \
        --version="$version_tag" \
        --source-directory="$artifact_dir" \
        --skip-existing
}

publish_docker_image() {
    local version_tag="$1"
    local version_number="$2"
    local image_repo="${LOCATION}-docker.pkg.dev/${PROJECT}/${DOCKER_REPOSITORY}/${DOCKER_IMAGE_NAME}"
    local registry="${LOCATION}-docker.pkg.dev"
    local -a build_cmd

    [ -f "${MEMBRANE_DIR}/Dockerfile" ] || die "Membrane Dockerfile was not found: ${MEMBRANE_DIR}/Dockerfile"

    ensure_repository_public "$DOCKER_REPOSITORY" docker "MirrorNeuron runtime Docker images"

    if [ "$APPLY" = "Y" ]; then
        "$GCLOUD_BIN" auth configure-docker "$registry" --quiet
        "$DOCKER_BIN" buildx version >/dev/null
    else
        run_or_echo "$GCLOUD_BIN" auth configure-docker "$registry" --quiet
    fi

    build_cmd=(
        "$DOCKER_BIN" buildx build
        --target runtime
        --platform "$DOCKER_PLATFORMS"
        --push
        --tag "${image_repo}:${version_tag}"
        --tag "${image_repo}:${version_number}"
    )
    if [ "$TAG_LATEST" = "Y" ]; then
        build_cmd+=(--tag "${image_repo}:latest")
    fi
    build_cmd+=("$MEMBRANE_DIR")

    run_or_echo "${build_cmd[@]}"
}

VERSION_TAG="$(infer_version)"
VERSION_NUMBER="${VERSION_TAG#v}"

if [ -z "$PROJECT" ]; then
    die "GAR project is required."
fi
if [ "$PUBLISH_BINARY" != "Y" ] && [ "$PUBLISH_DOCKER" != "Y" ]; then
    die "Nothing to publish: both --skip-binary and --skip-docker were provided."
fi

require_common_tools

log "Membrane public GAR publish"
log "  project: ${PROJECT}"
log "  location: ${LOCATION}"
log "  version: ${VERSION_TAG}"
log "  membrane dir: ${MEMBRANE_DIR}"
if [ "$PUBLISH_BINARY" = "Y" ]; then
    log "  binary GAR: ${LOCATION}-generic.pkg.dev/${PROJECT}/${BINARY_REPOSITORY}/${BINARY_PACKAGE}:${VERSION_TAG}"
fi
if [ "$PUBLISH_DOCKER" = "Y" ]; then
    log "  docker GAR: ${LOCATION}-docker.pkg.dev/${PROJECT}/${DOCKER_REPOSITORY}/${DOCKER_IMAGE_NAME}:${VERSION_TAG}"
    log "  docker platforms: ${DOCKER_PLATFORMS}"
fi

if [ "$APPLY" = "Y" ]; then
    check_gcloud_auth_for_apply
else
    log "Dry run only. Re-run with --apply to publish."
fi

if [ "$PUBLISH_BINARY" = "Y" ]; then
    prepare_binary_artifacts "$VERSION_TAG"
    publish_binary_artifacts "$VERSION_TAG" "$PREPARED_BINARY_ARTIFACT_DIR"
fi

if [ "$PUBLISH_DOCKER" = "Y" ]; then
    publish_docker_image "$VERSION_TAG" "$VERSION_NUMBER"
fi

log ""
if [ "$APPLY" = "Y" ]; then
    log "Membrane GAR publish complete."
else
    log "Dry run complete. Re-run with --apply to publish."
fi
