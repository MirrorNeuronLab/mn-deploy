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
PLAN="N"

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
Usage: release_all.sh [-v MAJOR.MINOR.PATCH] [--resume-from PHASE]

Omit -v (or use --auto) to choose the next unused patch when source changed.
Python distributions advance independently when their tracked inputs change.
Use --plan for a read-only version preview.

Create a complete multi-repository release:
  1. verify all release worktrees are clean and synchronized with main;
  2. update package versions and installer defaults, then snapshot support;
  3. create local annotated release tags, then build, publish, and verify all
     Python, Web UI, Core, and Membrane artifacts in Google Artifact Registry;
  4. push the prepared tags only after GAR verification succeeds, without
     consuming or waiting for GitHub release workflow artifacts;
  5. update named blueprint pins and record the completed release.

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
  if [[ -d "${WORKSPACE_ROOT}/otterdesk-blueprints/.git" ]]; then
    [[ -z "$(git -C "${WORKSPACE_ROOT}/otterdesk-blueprints" status --porcelain)" ]] ||
      die "Uncommitted changes in otterdesk-blueprints."
  fi

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
    if [[ "$repo" == "mn-deploy" ]]; then
      git -C "$path" diff --quiet "$TAG" HEAD -- . ':!released.md' ||
        die "Release tooling or metadata changed since ${TAG}; resume using the tagged checkout."
    elif [[ "$RESUME_FROM" == "python" ]]; then
      [[ "$(git -C "$path" rev-list -n 1 "$TAG")" == "$(git -C "$path" rev-parse HEAD)" ]] ||
        die "${repo} advanced after ${TAG}; Python publishing cannot safely resume from changed source. Resume from the first incomplete later phase instead."
    fi
  done
}

prepare_release_metadata() {
  local index_file="${SCRIPT_DIR}/package-index/python-packages.toml"
  local pyproject

  set_compose_web_ui_version "${SCRIPT_DIR}/docker-compose.yml" "$VERSION"

  # The aggregate tag identifies a release set, not every distribution version.
  python3 \
    "${SCRIPT_DIR}/scripts/prepare-python-package-index.py" \
    "$index_file" "$WORKSPACE_ROOT" "$VERSION" --independent \
    --baseline "$MN_RELEASE_BASELINE" >/dev/null

  update_installer_pins
  prepare_install_support_snapshot

  commit_and_push_if_changed \
    mn-deploy \
    "Prepare ${TAG} package index and installer support" \
    install.sh package-index/python-packages.toml docker-compose.yml "install_support/${TAG}"
  local repo
  for repo in "${REPOSITORIES[@]}"; do
    local metadata_paths=()
    while IFS= read -r pyproject; do
      [[ -n "$pyproject" ]] && metadata_paths+=("$pyproject")
    done < <(python3 - "${SCRIPT_DIR}/package-index/python-packages.toml" "$repo" <<'PYTHON'
import sys, tomllib
from pathlib import PurePosixPath
for package in tomllib.loads(open(sys.argv[1]).read())["packages"]:
    parts = PurePosixPath(package["path"]).parts
    if parts[0] == sys.argv[2]:
        print(str(PurePosixPath(*parts[1:]) / "pyproject.toml"))
PYTHON
    )
    if [[ "${#metadata_paths[@]}" -gt 0 ]]; then
      commit_and_push_if_changed "$repo" "Prepare ${TAG} package metadata" "${metadata_paths[@]}"
    fi
  done
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

update_installer_pins() {
  local setting
  for setting in MN_DEFAULT_CORE_VERSION MN_DEFAULT_WEB_UI_VERSION \
    MN_DEFAULT_AGENT_PACKAGE_INDEX_VERSION MN_DEFAULT_MEMBRANE_CONTEXT_ENGINE_VERSION \
    MN_DEFAULT_INSTALL_VERSION; do
    set_installer_default_version "$setting" "$TAG"
  done
  while read -r setting version; do
    set_installer_default_version "$setting" "v${version}"
  done < <(python3 - "${SCRIPT_DIR}/package-index/python-packages.toml" <<'PYTHON'
import sys, tomllib
settings = {"mirrorneuron-python-sdk": "MN_DEFAULT_PYTHON_SDK_VERSION",
            "mirrorneuron-cli": "MN_DEFAULT_CLI_VERSION", "mirrorneuron-api": "MN_DEFAULT_API_VERSION"}
for package in tomllib.loads(open(sys.argv[1]).read())["packages"]:
    if package["name"] in settings:
        print(settings[package["name"]], package["version"])
PYTHON
  )
}

update_post_release_pins() {
  if ! grep -Fq "## ${TAG} " "${SCRIPT_DIR}/released.md"; then
    cat >> "${SCRIPT_DIR}/released.md" <<EOF

## ${TAG} -- $(date +%F)

- GAR npm: mirrorneuron-web-ui@${VERSION} in ${NPM_REPOSITORY}.
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

  if [[ -d "${WORKSPACE_ROOT}/otterdesk-blueprints/.git" ]]; then
    [[ -z "$(git -C "${WORKSPACE_ROOT}/otterdesk-blueprints" status --porcelain)" ]] ||
      die "Blueprint checkout changed during release; commit or stash before finalizing."
    [[ "$(git -C "${WORKSPACE_ROOT}/otterdesk-blueprints" branch --show-current)" == "main" ]] ||
      die "otterdesk-blueprints is not on main."
    git -C "${WORKSPACE_ROOT}/otterdesk-blueprints" fetch --quiet origin main
    [[ "$(git -C "${WORKSPACE_ROOT}/otterdesk-blueprints" rev-parse HEAD)" == \
       "$(git -C "${WORKSPACE_ROOT}/otterdesk-blueprints" rev-parse origin/main)" ]] ||
      die "otterdesk-blueprints is not synchronized with origin/main."
    python3 "${SCRIPT_DIR}/scripts/release-contract.py" blueprints \
      "${SCRIPT_DIR}/package-index/python-packages.toml" "${WORKSPACE_ROOT}/otterdesk-blueprints"
    commit_and_push_if_changed otterdesk-blueprints "Pin blueprint dependencies for ${TAG}" .
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
    --auto) VERSION="" ;;
    --plan) PLAN="Y" ;;
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

if [[ -z "$VERSION" ]]; then
  [[ -z "$RESUME_FROM" ]] || die "Resuming requires the original explicit --version."
  if [[ "$PLAN" != "Y" ]]; then
    for repo in "${REPOSITORIES[@]}"; do
      [[ -z "$(git -C "${WORKSPACE_ROOT}/${repo}" status --porcelain)" ]] || die "Uncommitted changes in ${repo}."
      git -C "${WORKSPACE_ROOT}/${repo}" fetch --quiet origin main --tags
    done
  fi
  VERSION="$(python3 "${SCRIPT_DIR}/scripts/release-contract.py" next-version \
    "$WORKSPACE_ROOT" "${REPOSITORIES[@]}")"
  [[ -n "$VERSION" ]] || { printf 'No source changes since the last release.\n'; exit 0; }
fi
MN_RELEASE_BASELINE="$(sed -n 's/^MN_DEFAULT_INSTALL_VERSION=.*:-\(v[0-9.]*\)}"/\1/p' "${SCRIPT_DIR}/install.sh")"
validate_version "$VERSION"
if [[ "$PLAN" == "Y" ]]; then
  printf 'Next release: v%s (local tags and committed source; publish refreshes remote tags).\n' "$VERSION"
  python3 "${SCRIPT_DIR}/scripts/prepare-python-package-index.py" \
    "${SCRIPT_DIR}/package-index/python-packages.toml" "$WORKSPACE_ROOT" "$VERSION" \
    --independent --baseline "$MN_RELEASE_BASELINE" --dry-run >/dev/null
  exit 0
fi
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
  update_post_release_pins
fi

CURRENT_PHASE=""
printf 'Release %s completed successfully.\n' "$TAG"
