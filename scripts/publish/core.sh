#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_ROOT="$(cd "${DEPLOY_DIR}/.." && pwd)"

# shellcheck source=../release/commands.sh
source "$SCRIPT_DIR/release/commands.sh"
# shellcheck source=../release/registry.sh
source "$SCRIPT_DIR/release/registry.sh"
# shellcheck source=../release/multiarch.sh
source "$SCRIPT_DIR/release/multiarch.sh"

PROJECT="${MN_GAR_PROJECT:-mirrorneuron-public-packages}"
LOCATION="${MN_GAR_LOCATION:-us-central1}"
CORE_DIR="${MN_CORE_DIR:-${WORKSPACE_ROOT}/MirrorNeuron}"
CORE_DOCKERFILE="${MN_CORE_DOCKERFILE:-}"
VERSION="${MN_CORE_VERSION:-${MN_PACKAGE_VERSION:-}}"
DOCKER_REPOSITORY="${MN_CORE_GAR_DOCKER_REPOSITORY:-mirrorneuron-runtime}"
DOCKER_IMAGE_NAME="${MN_CORE_GAR_DOCKER_IMAGE_NAME:-mirror-neuron-core}"
DOCKER_PLATFORMS="${MN_CORE_DOCKER_PLATFORMS:-linux/amd64,linux/arm64}"
DOCKER_PROGRESS="${MN_CORE_DOCKER_PROGRESS:-auto}"
QEMU_MODE="${MN_CORE_QEMU_MODE:-auto}"
QEMU_IMAGE="${MN_CORE_QEMU_IMAGE:-tonistiigi/binfmt@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0}"
QEMU_ERL_AFLAGS="${MN_CORE_QEMU_ERL_AFLAGS:-+JMsingle true}"
HOST_ARCH="${MN_CORE_HOST_ARCH:-$(uname -m)}"
GCLOUD_BIN="${MN_GCLOUD_BIN:-gcloud}"
DOCKER_BIN="${MN_DOCKER_BIN:-docker}"
APPLY="N"
TAG_LATEST="Y"
WORKTREE_DIR=""

usage() {
  cat <<'EOF'
Usage: ./scripts/publish.sh core [options]

Build and publish the Core Docker image from the exact requested Core Git tag.
The script defaults to a dry run. Pass --apply to create/configure the GAR
repository if needed and push the multi-architecture runtime image.

Options:
  --apply                         Publish the image. Default is dry-run.
  --version VERSION               Release version/tag, for example v1.2.30.
                                   Env: MN_CORE_VERSION or MN_PACKAGE_VERSION.
  --core-dir PATH                 Core checkout. Env: MN_CORE_DIR.
  --dockerfile PATH               Release Dockerfile. Defaults to the Dockerfile
                                  in the Core checkout. Env: MN_CORE_DOCKERFILE.
  --project PROJECT               GAR project. Env: MN_GAR_PROJECT.
  --location LOCATION             GAR location. Env: MN_GAR_LOCATION.
  --docker-repository NAME        GAR Docker repository. Default: mirrorneuron-runtime.
  --docker-image-name NAME        GAR image name. Default: mirror-neuron-core.
  --docker-platforms LIST         Buildx platforms. Default: linux/amd64,linux/arm64.
  --docker-progress MODE          Buildx progress mode. Default: auto.
                                  Env: MN_CORE_DOCKER_PROGRESS.
  --qemu MODE                    amd64 emulator setup: auto, always, or never.
                                  Default: auto (enable on an ARM64 host).
                                  Env: MN_CORE_QEMU_MODE.
  --no-latest                     Do not update the latest tag.
  --gcloud PATH                   gcloud executable. Env: MN_GCLOUD_BIN.
  --docker PATH                   docker executable. Env: MN_DOCKER_BIN.
  -h, --help                      Show this help.

Examples:
  ./scripts/publish.sh core --version v1.2.30

  ./scripts/publish.sh core \
    --apply \
    --version v1.2.30
EOF
}

normalize_version_tag() {
  local value="$1"
  value="${value#refs/tags/}"
  case "$value" in
  v*) printf '%s' "$value" ;;
  *) printf 'v%s' "$value" ;;
  esac
}

validate_version_tag() {
  [[ "$1" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(alpha|beta|rc)\.(0|[1-9][0-9]*))?$ ]] ||
    die "Version must be vMAJOR.MINOR.PATCH (optionally -alpha.N, -beta.N, or -rc.N), got '$1'."
}

infer_version() {
  if [ -n "$VERSION" ]; then
    normalize_version_tag "$VERSION"
    return
  fi

  if [ -d "${CORE_DIR}/.git" ] && command_exists git; then
    local tag
    tag="$(git -C "$CORE_DIR" describe --tags --exact-match 2>/dev/null || true)"
    if [ -n "$tag" ]; then
      normalize_version_tag "$tag"
      return
    fi
  fi

  die "Release version is required. Pass --version v1.2.30 or set MN_CORE_VERSION."
}

cleanup() {
  if [ -n "$WORKTREE_DIR" ]; then
    git -C "$CORE_DIR" worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1 || true
  fi
}

prepare_tag_worktree() {
  local version_tag="$1"
  [ -d "$CORE_DIR/.git" ] || die "Core checkout was not found: $CORE_DIR"
  git -C "$CORE_DIR" rev-parse --verify --quiet "refs/tags/${version_tag}^{commit}" >/dev/null ||
    die "Core tag ${version_tag} is not available in ${CORE_DIR}. Fetch tags first."

  WORKTREE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mn-core-gar.${version_tag}.XXXXXX")"
  rmdir "$WORKTREE_DIR"
  git -C "$CORE_DIR" worktree add --detach "$WORKTREE_DIR" "refs/tags/${version_tag}" >/dev/null
  [ -f "$CORE_DOCKERFILE" ] || die "Core Dockerfile was not found: $CORE_DOCKERFILE"
}

publish_docker_image() {
  local version_tag="$1"
  local version_number="${version_tag#v}"
  local revision image_repo registry
  local -a build_cmd

  revision="$(git -C "$WORKTREE_DIR" rev-parse HEAD)"
  image_repo="${LOCATION}-docker.pkg.dev/${PROJECT}/${DOCKER_REPOSITORY}/${DOCKER_IMAGE_NAME}"
  registry="${LOCATION}-docker.pkg.dev"

  prepare_docker_repository "$registry"

  build_cmd=(
    "$DOCKER_BIN" buildx build
    --platform "$DOCKER_PLATFORMS"
    --progress "$DOCKER_PROGRESS"
    --push
    --file "$CORE_DOCKERFILE"
    --build-arg "CORE_RELEASE_TAG=${version_tag}"
    --build-arg "CORE_REVISION=${revision}"
    --label "org.opencontainers.image.version=${version_tag}"
    --label "org.opencontainers.image.revision=${revision}"
    --tag "${image_repo}:${version_tag}"
    --tag "${image_repo}:${version_number}"
  )
  if needs_amd64_emulation "$DOCKER_PLATFORMS" "$QEMU_MODE" "$HOST_ARCH"; then
    configure_amd64_emulation "Core" "$HOST_ARCH" "$DOCKER_BIN" "$QEMU_IMAGE"
    # Erlang's dual-mapped JIT memory is not supported by QEMU user mode.
    # This build-only argument is consumed by the Dockerfile's Mix steps.
    build_cmd+=(--build-arg "ERL_AFLAGS=${QEMU_ERL_AFLAGS}")
  fi
  if [ "$TAG_LATEST" = "Y" ]; then
    build_cmd+=(--tag "${image_repo}:latest")
  fi
  build_cmd+=("$WORKTREE_DIR")
  run_or_echo "${build_cmd[@]}"
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
  --core-dir)
    shift
    [ "$#" -gt 0 ] || die "--core-dir requires a value."
    CORE_DIR="$1"
    ;;
  --core-dir=*) CORE_DIR="${1#*=}" ;;
  --dockerfile)
    shift
    [ "$#" -gt 0 ] || die "--dockerfile requires a value."
    CORE_DOCKERFILE="$1"
    ;;
  --dockerfile=*) CORE_DOCKERFILE="${1#*=}" ;;
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
  --docker-progress)
    shift
    [ "$#" -gt 0 ] || die "--docker-progress requires a value."
    DOCKER_PROGRESS="$1"
    ;;
  --docker-progress=*) DOCKER_PROGRESS="${1#*=}" ;;
  --qemu)
    shift
    [ "$#" -gt 0 ] || die "--qemu requires a value."
    QEMU_MODE="$1"
    ;;
  --qemu=*) QEMU_MODE="${1#*=}" ;;
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
  -h | --help)
    usage
    exit 0
    ;;
  *) die "Unknown option: $1" ;;
  esac
  shift
done

command_exists git || die "git was not found."
command_exists "$GCLOUD_BIN" || die "'$GCLOUD_BIN' was not found."
command_exists "$DOCKER_BIN" || die "'$DOCKER_BIN' was not found."

CORE_DOCKERFILE="${CORE_DOCKERFILE:-${CORE_DIR}/Dockerfile}"

VERSION_TAG="$(infer_version)"
validate_version_tag "$VERSION_TAG"
validate_qemu_mode "$QEMU_MODE"
trap cleanup EXIT
prepare_tag_worktree "$VERSION_TAG"

if [ "$APPLY" = "Y" ]; then
  check_gcloud_auth
fi
publish_docker_image "$VERSION_TAG"

if [ "$APPLY" = "Y" ]; then
  log "Core GAR publish complete."
else
  log "Dry run complete. Re-run with --apply to publish."
fi
