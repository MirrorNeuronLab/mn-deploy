#!/usr/bin/env bash

# Release every tagged MirrorNeuron component from a clean workspace.
# Run from mn-deploy or the workspace root, for example:
#   mn-deploy/release_all.sh -v 1.2.30

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION=""
TAG=""
PROJECT="mirrorneuron-public-packages"
LOCATION="us-central1"
PYTHON_REPOSITORY="agent-skills"
NPM_REPOSITORY="mirrorneuron-npm"
PUBLISH_PYTHON=""
RESUME_FROM=""
CURRENT_PHASE=""

REPOSITORIES=(
  mn-api
  mn-cli
  mn-web-ui
  mn-deploy
  mn-python-sdk
  mn-docs
  mn-agents
  mn-skills
  MirrorNeuron
  Membrane
)

usage() {
  cat <<'EOF'
Usage: release_all.sh -v MAJOR.MINOR.PATCH [--resume-from PHASE]

Create a complete multi-repository release:
  1. verify all release worktrees are clean and synchronized with main;
  2. update indexed/static package versions and snapshot installer support;
  3. create local annotated release tags, then build, publish, and verify all
     Python, Web UI, Core, and Membrane artifacts in Google Artifact Registry;
  4. push the prepared tags only after GAR verification succeeds, without
     consuming or waiting for GitHub release workflow artifacts;
  5. update installer/blueprint pins and record the completed release.

Resume phases: prepare, python, web-ui, membrane, core, tags, or finalize.
After a failure, run the exact --resume-from command printed by this script.

Prerequisites: authenticated git and gcloud, npm, Docker with Buildx, uv (or a
prepared MN_PUBLISH_PYTHON), and publishing authority for the configured GAR
Python, npm, and Docker repositories.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command was not found: $1"
}

prepare_python_publish_environment() {
  local publish_venv="${MN_GAR_PUBLISH_VENV:-${SCRIPT_DIR}/.venv-gar-publish}"

  if [[ -n "${MN_PUBLISH_PYTHON:-}" ]]; then
    PUBLISH_PYTHON="$MN_PUBLISH_PYTHON"
  else
    require_command uv
    PUBLISH_PYTHON="${publish_venv}/bin/python"
    if [[ ! -x "$PUBLISH_PYTHON" ]]; then
      printf 'Preparing Python publishing environment with uv: %s\n' "$publish_venv"
      uv venv "$publish_venv"
    fi
    if ! "$PUBLISH_PYTHON" -c 'import build, packaging, twine' >/dev/null 2>&1; then
      printf 'Installing Python publishing dependencies with uv.\n'
      uv pip install --python "$PUBLISH_PYTHON" --upgrade \
        build \
        twine \
        keyring \
        keyrings.google-artifactregistry-auth
    fi
  fi

  command -v "$PUBLISH_PYTHON" >/dev/null 2>&1 ||
    die "Python publishing command was not found: ${PUBLISH_PYTHON}."
  if ! "$PUBLISH_PYTHON" -c 'import build, packaging, twine' >/dev/null 2>&1; then
    die "Python publishing environment is missing build, packaging, or twine: ${PUBLISH_PYTHON}."
  fi
}

validate_version() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    die "Version must be MAJOR.MINOR.PATCH, got '$1'."
}

restore_version_text() {
  local file="$1"
  local old_version="$2"
  local new_version="$3"

  perl -0pi -e "s/\\Q${old_version}\\E/${new_version}/g" "$file"
}

set_static_project_version() {
  local file="$1"
  local version="$2"

  MN_RELEASE_VERSION="$version" perl -0pi -e \
    's~(\[project\](?:(?!\n\[).)*?\nversion\s*=\s*")[^"]+(")~$1$ENV{MN_RELEASE_VERSION}$2~s' \
    "$file"
  grep -Fq "version = \"${version}\"" "$file" ||
    die "Could not set the Python project version in ${file}."
}

set_installer_default_version() {
  local setting="$1"
  local tag="$2"
  local expected

  env MN_RELEASE_SETTING="$setting" MN_RELEASE_TAG="$tag" perl -0pi -e \
    's~^(\Q$ENV{MN_RELEASE_SETTING}\E="\$\{\Q$ENV{MN_RELEASE_SETTING}\E:-)[^}]+(\}")~$1$ENV{MN_RELEASE_TAG}$2~m' \
    "${SCRIPT_DIR}/install.sh"
  printf -v expected '%s="${%s:-%s}"' "$setting" "$setting" "$tag"
  grep -Fq "$expected" "${SCRIPT_DIR}/install.sh" ||
    die "Could not set ${setting} to ${tag} in install.sh."
}

set_compose_web_ui_version() {
  local file="$1"
  local version="$2"

  MN_RELEASE_WEB_UI_VERSION="$version" perl -0pi -e \
    's~(MN_WEB_UI_PACKAGE_VERSION:\s*\$\{MN_WEB_UI_PACKAGE_VERSION:-)[^}]+(\})~$1$ENV{MN_RELEASE_WEB_UI_VERSION}$2~g' \
    "$file"
  grep -Fq \
    "MN_WEB_UI_PACKAGE_VERSION: \${MN_WEB_UI_PACKAGE_VERSION:-${version}}" \
    "$file" || die "Could not pin the Web UI Compose package version to ${version}."
}

prepare_install_support_snapshot() {
  local support_dir="${SCRIPT_DIR}/install_support/${TAG}"

  if [[ ! -d "$support_dir" ]]; then
    "${SCRIPT_DIR}/save_install_support.sh" --version "$TAG"
    return
  fi

  [[ -f "${support_dir}/docker-compose.yml" ]] &&
    [[ -f "${support_dir}/package-index/python-packages.toml" ]] &&
    cmp -s "${SCRIPT_DIR}/docker-compose.yml" "${support_dir}/docker-compose.yml" &&
    cmp -s \
      "${SCRIPT_DIR}/package-index/python-packages.toml" \
      "${support_dir}/package-index/python-packages.toml" ||
    die "Existing install support snapshot ${support_dir} does not match the prepared release metadata; refusing to overwrite an immutable snapshot."

  printf 'Reusing matching install support snapshot: %s\n' "$support_dir"
}

commit_and_push_if_changed() {
  local repo="$1"
  local message="$2"
  shift 2

  if [[ -n "$(git -C "${WORKSPACE_ROOT}/${repo}" status --porcelain -- "$@")" ]]; then
    git -C "${WORKSPACE_ROOT}/${repo}" add -- "$@"
    git -C "${WORKSPACE_ROOT}/${repo}" commit -m "$message"
    git -C "${WORKSPACE_ROOT}/${repo}" push origin main
  fi
}

phase_rank() {
  case "$1" in
    prepare) printf '0' ;;
    python) printf '1' ;;
    web-ui) printf '2' ;;
    membrane) printf '3' ;;
    core) printf '4' ;;
    tags) printf '5' ;;
    finalize) printf '6' ;;
    *) die "Unknown release phase: $1" ;;
  esac
}

should_run_phase() {
  [[ "$(phase_rank "$1")" -ge "$(phase_rank "$RESUME_FROM")" ]]
}

report_resume_command() {
  local status=$?
  if [[ "$status" -ne 0 && -n "$CURRENT_PHASE" ]]; then
    printf 'Next: fix the error, then run: %s -v %s --resume-from %s\n' \
      "$0" "$VERSION" "$CURRENT_PHASE" >&2
  fi
}
trap report_resume_command EXIT

check_workspace() {
  local repo path

  for repo in "${REPOSITORIES[@]}"; do
    path="${WORKSPACE_ROOT}/${repo}"
    [[ -d "${path}/.git" ]] || die "Release checkout is missing: ${path}"
    [[ -z "$(git -C "$path" status --porcelain)" ]] ||
      die "Uncommitted changes in ${repo}."
    [[ "$(git -C "$path" branch --show-current)" == "main" ]] ||
      die "${repo} is not on main."
    git -C "$path" fetch --quiet origin main --tags
    [[ "$(git -C "$path" rev-parse main)" == "$(git -C "$path" rev-parse origin/main)" ]] ||
      die "${repo}/main is not synchronized with origin/main."
    if git -C "$path" ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1; then
      die "${repo} already contains remote tag ${TAG}; tags are immutable release inputs."
    fi
    if git -C "$path" rev-parse --verify --quiet "refs/tags/${TAG}" >/dev/null; then
      [[ "$(git -C "$path" rev-list -n 1 "$TAG")" == "$(git -C "$path" rev-parse HEAD)" ]] ||
        die "${repo} has local ${TAG} on a different commit."
    fi
  done

  return 0
}

check_resume_workspace() {
  local repo path

  for repo in "${REPOSITORIES[@]}"; do
    path="${WORKSPACE_ROOT}/${repo}"
    [[ -d "${path}/.git" ]] || die "Release checkout is missing: ${path}"
    [[ -z "$(git -C "$path" status --porcelain)" ]] ||
      die "Uncommitted changes in ${repo}."
    [[ "$(git -C "$path" branch --show-current)" == "main" ]] ||
      die "${repo} is not on main."
    git -C "$path" fetch --quiet origin main --tags
    [[ "$(git -C "$path" rev-parse main)" == "$(git -C "$path" rev-parse origin/main)" ]] ||
      die "${repo}/main is not synchronized with origin/main."
    git -C "$path" rev-parse --verify --quiet "refs/tags/${TAG}^{commit}" >/dev/null ||
      die "${repo} is missing release tag ${TAG}; resume from prepare."
    if [[ "$RESUME_FROM" == "python" ]]; then
      [[ "$(git -C "$path" rev-list -n 1 "$TAG")" == "$(git -C "$path" rev-parse HEAD)" ]] ||
        die "${repo} advanced after ${TAG}; Python publishing cannot safely resume from changed source. Resume from the first incomplete later phase instead."
    fi
  done
}

resolve_previous_version() {
  local detected_version="$1"
  local preparation_commit historical_index

  if [[ "$detected_version" != "$VERSION" ]]; then
    printf '%s\n' "$detected_version"
    return
  fi

  preparation_commit="$(git -C "$SCRIPT_DIR" log -1 \
    -S "version = \"${VERSION}\"" \
    --format=%H -- package-index/python-packages.toml)"
  [[ -n "$preparation_commit" ]] ||
    die "Could not locate the package-index preparation commit for ${TAG}."

  historical_index="$(mktemp "${TMPDIR:-/tmp}/mn-previous-package-index.XXXXXX")"
  if ! git -C "$SCRIPT_DIR" show \
    "${preparation_commit}^:package-index/python-packages.toml" > "$historical_index"; then
    rm -f "$historical_index"
    die "Could not read the package index preceding ${TAG}."
  fi

  detected_version="$(python3 \
    "${SCRIPT_DIR}/scripts/prepare-python-package-index.py" \
    "$historical_index" "$WORKSPACE_ROOT" "$VERSION")"
  rm -f "$historical_index"
  [[ "$detected_version" != "$VERSION" ]] ||
    die "Could not recover the release version preceding ${TAG}."
  printf '%s\n' "$detected_version"
}

prepare_release_metadata() {
  local index_file="${SCRIPT_DIR}/package-index/python-packages.toml"
  local pyproject

  set_compose_web_ui_version "${SCRIPT_DIR}/docker-compose.yml" "$VERSION"

  for pyproject in \
    "${WORKSPACE_ROOT}/Membrane/mn-context-engine-python-sdk/pyproject.toml" \
    "${WORKSPACE_ROOT}/Membrane/mn-context-auto-optimizer/pyproject.toml" \
    "${WORKSPACE_ROOT}/Membrane/mn-context-auto-optimizer-benchmark/pyproject.toml"; do
    set_static_project_version "$pyproject" "$VERSION"
  done

  # Static projects (including mn-python-sdk/packages/*) retain the version in
  # their pyproject.toml. Projects versioned by Git tags use this release's
  # version. Keeping those two cases distinct prevents the package index from
  # claiming a 1.x SDK component while the build actually produces 0.1.x.
  PREVIOUS_VERSION="$(python3 \
    "${SCRIPT_DIR}/scripts/prepare-python-package-index.py" \
    "$index_file" "$WORKSPACE_ROOT" "$VERSION")"
  PREVIOUS_VERSION="$(resolve_previous_version "$PREVIOUS_VERSION")"

  prepare_install_support_snapshot

  commit_and_push_if_changed \
    mn-deploy \
    "Prepare ${TAG} package index and installer support" \
    package-index/python-packages.toml docker-compose.yml "install_support/${TAG}"
  commit_and_push_if_changed \
    Membrane \
    "Prepare ${TAG} Membrane package metadata" \
    mn-context-engine-python-sdk/pyproject.toml \
    mn-context-auto-optimizer/pyproject.toml \
    mn-context-auto-optimizer-benchmark/pyproject.toml
}

create_release_tags() {
  local repo path

  for repo in "${REPOSITORIES[@]}"; do
    path="${WORKSPACE_ROOT}/${repo}"
    if ! git -C "$path" rev-parse --verify --quiet "refs/tags/${TAG}" >/dev/null; then
      git -C "$path" tag -a "$TAG" -m "Release ${TAG}"
    fi
  done
}

push_release_tags() {
  local repo

  for repo in "${REPOSITORIES[@]}"; do
    git -C "${WORKSPACE_ROOT}/${repo}" push origin "refs/tags/${TAG}"
  done
}

publish_and_verify_gar() {
  local image tags_file core_image core_tags_file
  local membrane_worktree_root membrane_dir

  if should_run_phase python; then
    CURRENT_PHASE="python"
    "${SCRIPT_DIR}/publish_python_packages_to_google_artifact_registry.sh" \
      --python "$PUBLISH_PYTHON" \
      --project "$PROJECT" \
      --location "$LOCATION" \
      --repository "$PYTHON_REPOSITORY" \
      --apply \
      --no-prune
  fi

  if should_run_phase web-ui; then
    CURRENT_PHASE="web-ui"
    "${SCRIPT_DIR}/publish_web_ui_to_google_artifact_registry.sh" \
      --version "$VERSION" \
      --project "$PROJECT" \
      --location "$LOCATION" \
      --repository "$NPM_REPOSITORY" \
      --apply
  fi

  if should_run_phase membrane; then
    CURRENT_PHASE="membrane"
    image="${LOCATION}-docker.pkg.dev/${PROJECT}/mirrorneuron-runtime/membrane-context-engine"
    tags_file="$(mktemp "${TMPDIR:-/tmp}/mn-membrane-tags.XXXXXX")"
    gcloud artifacts docker tags list "$image" --format='value(tag)' > "$tags_file"

    if ! grep -qx "$VERSION" "$tags_file" ||
       ! grep -qx "$TAG" "$tags_file" ||
       ! grep -qx latest "$tags_file"; then
      membrane_worktree_root="$(mktemp -d "${TMPDIR:-/tmp}/mn-membrane-release.XXXXXX")"
      membrane_dir="${membrane_worktree_root}/source"
      (
        trap 'git -C "${WORKSPACE_ROOT}/Membrane" worktree remove --force "$membrane_dir" >/dev/null 2>&1 || true; rm -rf "$membrane_worktree_root"' EXIT
        git -C "${WORKSPACE_ROOT}/Membrane" worktree add \
          --detach "$membrane_dir" "refs/tags/${TAG}" >/dev/null
        "${SCRIPT_DIR}/publish_public_membrane_to_google_artifact_registry.sh" \
          --apply \
          --version "$TAG" \
          --membrane-dir "$membrane_dir" \
          --skip-binary
      )
      gcloud artifacts docker tags list "$image" --format='value(tag)' > "$tags_file"
    fi

    grep -qx "$VERSION" "$tags_file" || die "Membrane Docker tag ${VERSION} was not published."
    grep -qx "$TAG" "$tags_file" || die "Membrane Docker tag ${TAG} was not published."
    grep -qx latest "$tags_file" || die "Membrane Docker latest tag was not published."
    rm -f "$tags_file"
  fi

  if should_run_phase core; then
    CURRENT_PHASE="core"
    core_image="${LOCATION}-docker.pkg.dev/${PROJECT}/mirrorneuron-runtime/mirror-neuron-core"
    core_tags_file="$(mktemp "${TMPDIR:-/tmp}/mn-core-tags.XXXXXX")"
    gcloud artifacts docker tags list "$core_image" --format='value(tag)' > "$core_tags_file"

    if ! grep -qx "$VERSION" "$core_tags_file" ||
       ! grep -qx "$TAG" "$core_tags_file" ||
       ! grep -qx latest "$core_tags_file"; then
      "${SCRIPT_DIR}/publish_public_core_to_google_artifact_registry.sh" \
        --apply \
        --version "$TAG" \
        --project "$PROJECT" \
        --location "$LOCATION"
      gcloud artifacts docker tags list "$core_image" --format='value(tag)' > "$core_tags_file"
    fi

    grep -qx "$VERSION" "$core_tags_file" || die "Core Docker tag ${VERSION} was not published."
    grep -qx "$TAG" "$core_tags_file" || die "Core Docker tag ${TAG} was not published."
    grep -qx latest "$core_tags_file" || die "Core Docker latest tag was not published."
    rm -f "$core_tags_file"
  fi
}

update_post_release_pins() {
  local file setting
  local settings=(
    MN_DEFAULT_CORE_VERSION
    MN_DEFAULT_PYTHON_SDK_VERSION
    MN_DEFAULT_CLI_VERSION
    MN_DEFAULT_API_VERSION
    MN_DEFAULT_WEB_UI_VERSION
    MN_DEFAULT_AGENT_PACKAGE_INDEX_VERSION
    MN_DEFAULT_MEMBRANE_CONTEXT_ENGINE_VERSION
    MN_DEFAULT_INSTALL_VERSION
  )

  for setting in "${settings[@]}"; do
    set_installer_default_version "$setting" "$TAG"
  done

  while IFS= read -r -d '' file; do
    restore_version_text "$file" "$PREVIOUS_VERSION" "$VERSION"
  done < <(find "${WORKSPACE_ROOT}/otterdesk-blueprints" -type f \( \
    -name manifest.json -o -name requirements.txt -o -name '*.json' \) -print0)

  if ! grep -Fq "## ${TAG} " "${SCRIPT_DIR}/released.md"; then
    cat >> "${SCRIPT_DIR}/released.md" <<EOF

## ${TAG} -- $(date +%F)

- GAR npm: `mirrorneuron-web-ui@${VERSION}` in ${NPM_REPOSITORY}.
- GAR Python: all packages in package-index/python-packages.toml, including
  mirrorneuron-api, mirrorneuron-cli, and mirrorneuron-python-sdk.
- GAR Docker: mirror-neuron-core and membrane-context-engine each published
  ${TAG}, ${VERSION}, and latest (pointing to this release at confirmation).
- GitHub tag: ${TAG} across the release repositories.
EOF
  fi

  commit_and_push_if_changed \
    mn-deploy \
    "Document ${TAG} release" \
    install.sh released.md

  if ! git -C "${WORKSPACE_ROOT}/otterdesk-blueprints" diff --quiet ||
     ! git -C "${WORKSPACE_ROOT}/otterdesk-blueprints" diff --cached --quiet; then
    git -C "${WORKSPACE_ROOT}/otterdesk-blueprints" add -- .
    git -C "${WORKSPACE_ROOT}/otterdesk-blueprints" commit -m "Pin blueprint dependencies to ${VERSION}"
    git -C "${WORKSPACE_ROOT}/otterdesk-blueprints" push origin main
  fi
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -v|--version)
      shift
      [[ "$#" -gt 0 ]] || die "--version requires a value."
      VERSION="$1"
      ;;
    --resume-from)
      shift
      [[ "$#" -gt 0 ]] || die "--resume-from requires a phase."
      RESUME_FROM="$1"
      ;;
    --resume-from=*) RESUME_FROM="${1#*=}" ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
  shift
done

[[ -n "$VERSION" ]] || { usage >&2; exit 1; }
validate_version "$VERSION"
TAG="v${VERSION}"
RESUME_FROM="${RESUME_FROM:-prepare}"
phase_rank "$RESUME_FROM" >/dev/null

CURRENT_PHASE="$RESUME_FROM"
for command in git perl python3 cmp; do
  require_command "$command"
done
if should_run_phase python; then
  require_command gcloud
  prepare_python_publish_environment
fi
if should_run_phase web-ui; then
  require_command gcloud
  require_command npm
fi
if should_run_phase membrane || should_run_phase core; then
  require_command gcloud
  require_command docker
  docker info >/dev/null 2>&1 ||
    die "Docker is not running or the current user cannot access the Docker daemon."
  docker buildx version >/dev/null 2>&1 ||
    die "Docker Buildx is required to publish multi-platform runtime images."
fi

if [[ "$RESUME_FROM" == "prepare" ]]; then
  check_workspace
  CURRENT_PHASE="prepare"
  prepare_release_metadata
  create_release_tags
else
  check_resume_workspace
  PREVIOUS_VERSION="$(resolve_previous_version "$VERSION")"
fi

if should_run_phase python || should_run_phase web-ui ||
   should_run_phase membrane || should_run_phase core; then
  publish_and_verify_gar
fi
if should_run_phase tags; then
  CURRENT_PHASE="tags"
  push_release_tags
fi
if should_run_phase finalize; then
  CURRENT_PHASE="finalize"
  [[ -n "${PREVIOUS_VERSION:-}" ]] ||
    PREVIOUS_VERSION="$(resolve_previous_version "$VERSION")"
  update_post_release_pins
fi

CURRENT_PHASE=""
printf 'Release %s completed successfully.\n' "$TAG"
