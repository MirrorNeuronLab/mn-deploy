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

REPOSITORIES=(
  mn-api
  mn-cli
  mn-web-ui
  mn-deploy
  mn-python-sdk
  mn-docs
  mn-agents
  otterdesk-blueprints
  mn-skills
  MirrorNeuron
  Membrane
)

# These repositories publish artifacts or release assets from tag-triggered
# workflows. The other tagged repositories are source-only at release time.
WORKFLOW_REPOSITORIES=(
  mn-api
  mn-cli
  mn-web-ui
  mn-deploy
  mn-python-sdk
  MirrorNeuron
  Membrane
)

usage() {
  cat <<'EOF'
Usage: release_all.sh -v MAJOR.MINOR.PATCH

Create a complete multi-repository release:
  1. verify all release worktrees are clean and synchronized with main;
  2. update indexed/static package versions and snapshot installer support;
  3. commit, push, and annotate one tag in every release repository;
  4. wait for tag-triggered GitHub release workflows;
  5. publish and verify Python packages in GAR, PyPI, npm, and the Core and
     Membrane runtime images;
  6. update installer/blueprint pins and record the completed release.

Prerequisites: authenticated git, gh, gcloud, npm, curl, Python build/Twine
environment, and publishing authority for the configured npm/PyPI/GAR targets.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command was not found: $1"
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
    if git -C "$path" rev-parse --verify --quiet "refs/tags/${TAG}" >/dev/null; then
      die "${repo} already contains ${TAG}; tags are immutable release inputs."
    fi
  done

  return 0
}

prepare_release_metadata() {
  local index_file="${SCRIPT_DIR}/package-index/python-packages.toml"
  local pyproject

  PREVIOUS_VERSION="$(awk -F'"' '/^version =/ {print $2; exit}' "$index_file")"
  [[ -n "${PREVIOUS_VERSION}" ]] || die "Could not determine the current package-index version."

  restore_version_text "$index_file" "$PREVIOUS_VERSION" "$VERSION"

  for pyproject in \
    "${WORKSPACE_ROOT}/Membrane/mn-context-engine-python-sdk/pyproject.toml" \
    "${WORKSPACE_ROOT}/Membrane/mn-context-auto-optimizer/pyproject.toml" \
    "${WORKSPACE_ROOT}/Membrane/mn-context-auto-optimizer-benchmark/pyproject.toml"; do
    restore_version_text "$pyproject" "$PREVIOUS_VERSION" "$VERSION"
  done

  "${SCRIPT_DIR}/save_install_support.sh" --version "$TAG"

  commit_and_push_if_changed \
    mn-deploy \
    "Prepare ${TAG} package index and installer support" \
    package-index/python-packages.toml "install_support/${TAG}"
  commit_and_push_if_changed \
    Membrane \
    "Prepare ${TAG} Membrane package metadata" \
    mn-context-engine-python-sdk/pyproject.toml \
    mn-context-auto-optimizer/pyproject.toml \
    mn-context-auto-optimizer-benchmark/pyproject.toml
}

tag_all_repositories() {
  local repo path

  for repo in "${REPOSITORIES[@]}"; do
    path="${WORKSPACE_ROOT}/${repo}"
    git -C "$path" tag -a "$TAG" -m "Release ${TAG}"
    git -C "$path" push origin "refs/tags/${TAG}"
  done
}

wait_for_tag_workflows() {
  local repo run_ids attempt

  for repo in "${WORKFLOW_REPOSITORIES[@]}"; do
    run_ids=""

    for attempt in $(seq 1 30); do
      run_ids="$(gh run list --repo "MirrorNeuronLab/${repo}" --limit 100 \
        --json databaseId,headBranch,event \
        --jq ".[] | select(.headBranch == \"${TAG}\" and .event == \"push\") | .databaseId")"
      [[ -n "$run_ids" ]] && break
      sleep 10
    done

    [[ -n "$run_ids" ]] || die "No tag-triggered workflow appeared for ${repo}."
    while IFS= read -r run_id; do
      [[ -n "$run_id" ]] || continue
      gh run watch "$run_id" --repo "MirrorNeuronLab/${repo}" --exit-status
    done <<< "$run_ids"
  done
}

publish_core_gar_image_from_github() {
  local workflow='publish-core-gar-image.yml'
  local previous_run_id run_id attempt

  previous_run_id="$(gh run list \
    --repo MirrorNeuronLab/MirrorNeuron \
    --workflow "$workflow" \
    --branch main \
    --event workflow_dispatch \
    --limit 1 \
    --json databaseId \
    --jq '.[0].databaseId // empty')"

  gh workflow run "$workflow" \
    --repo MirrorNeuronLab/MirrorNeuron \
    --ref main \
    -f "release_tag=${TAG}"

  run_id=""
  for attempt in $(seq 1 30); do
    run_id="$(gh run list \
      --repo MirrorNeuronLab/MirrorNeuron \
      --workflow "$workflow" \
      --branch main \
      --event workflow_dispatch \
      --limit 1 \
      --json databaseId \
      --jq '.[0].databaseId // empty')"
    if [[ -n "$run_id" && "$run_id" != "$previous_run_id" ]]; then
      break
    fi
    sleep 10
  done

  [[ -n "$run_id" && "$run_id" != "$previous_run_id" ]] ||
    die "No GitHub Core GAR backfill workflow appeared for ${TAG}."
  gh run watch "$run_id" --repo MirrorNeuronLab/MirrorNeuron --exit-status
}

publish_and_verify_gar() {
  local local_count remote_count image tags_file core_image core_tags_file

  "${SCRIPT_DIR}/publish_python_packages_to_google_artifact_registry.sh" \
    --python "${SCRIPT_DIR}/.venv-gar-publish/bin/python" \
    --project "$PROJECT" \
    --location "$LOCATION" \
    --repository "$PYTHON_REPOSITORY" \
    --apply \
    --no-prune

  image="${LOCATION}-docker.pkg.dev/${PROJECT}/mirrorneuron-runtime/membrane-context-engine"
  tags_file="$(mktemp "${TMPDIR:-/tmp}/mn-membrane-tags.XXXXXX")"
  trap 'rm -f "$tags_file"' RETURN
  gcloud artifacts docker tags list "$image" --format='value(tag)' > "$tags_file"

  if ! grep -qx "$VERSION" "$tags_file" || ! grep -qx "$TAG" "$tags_file" || ! grep -qx latest "$tags_file"; then
    "${SCRIPT_DIR}/publish_public_membrane_to_google_artifact_registry.sh" \
      --apply \
      --version "$TAG" \
      --skip-binary
    gcloud artifacts docker tags list "$image" --format='value(tag)' > "$tags_file"
  fi

  grep -qx "$VERSION" "$tags_file" || die "Membrane Docker tag ${VERSION} was not published."
  grep -qx "${TAG}" "$tags_file" || die "Membrane Docker tag ${TAG} was not published."
  grep -qx latest "$tags_file" || die "Membrane Docker latest tag was not published."

  core_image="${LOCATION}-docker.pkg.dev/${PROJECT}/mirrorneuron-runtime/mirror-neuron-core"
  core_tags_file="$(mktemp "${TMPDIR:-/tmp}/mn-core-tags.XXXXXX")"
  trap 'rm -f "$tags_file" "$core_tags_file"' RETURN
  gcloud artifacts docker tags list "$core_image" --format='value(tag)' > "$core_tags_file"

  if ! grep -qx "$VERSION" "$core_tags_file" || ! grep -qx "$TAG" "$core_tags_file" || ! grep -qx latest "$core_tags_file"; then
    publish_core_gar_image_from_github
    gcloud artifacts docker tags list "$core_image" --format='value(tag)' > "$core_tags_file"
  fi

  grep -qx "$VERSION" "$core_tags_file" || die "Core Docker tag ${VERSION} was not published."
  grep -qx "${TAG}" "$core_tags_file" || die "Core Docker tag ${TAG} was not published."
  grep -qx latest "$core_tags_file" || die "Core Docker latest tag was not published."

  local_count="$(find "${SCRIPT_DIR}/dist/python-packages" -maxdepth 1 -type f | wc -l | tr -d ' ')"
  remote_count="$(gcloud artifacts files list \
    --project "$PROJECT" \
    --location "$LOCATION" \
    --repository "$PYTHON_REPOSITORY" \
    --format='value(name)' | awk -v version="$VERSION" 'index($0, version) {count++} END {print count+0}')"
  [[ "$local_count" == "$remote_count" ]] ||
    die "GAR artifact count mismatch: local=${local_count}, remote=${remote_count}."
}

verify_public_registries() {
  local package

  npm view "mirrorneuron-web-ui@${VERSION}" version | grep -qx "$VERSION" ||
    die "npm does not contain mirrorneuron-web-ui@${VERSION}."

  for package in \
    mirrorneuron-api \
    mirrorneuron-cli \
    mirrorneuron-python-sdk \
    mirrorneuron-membrane-python-sdk; do
    curl --fail --silent --show-error \
      "https://pypi.org/pypi/${package}/${VERSION}/json" \
      --output /dev/null || die "PyPI does not contain ${package}==${VERSION}."
  done
}

update_post_release_pins() {
  local file

  restore_version_text "${SCRIPT_DIR}/install.sh" "$PREVIOUS_VERSION" "$VERSION"
  restore_version_text "${SCRIPT_DIR}/docker-compose.yml" "$PREVIOUS_VERSION" "$VERSION"

  while IFS= read -r -d '' file; do
    restore_version_text "$file" "$PREVIOUS_VERSION" "$VERSION"
  done < <(find "${WORKSPACE_ROOT}/otterdesk-blueprints" -type f \( \
    -name manifest.json -o -name requirements.txt -o -name '*.json' \) -print0)

  cat >> "${SCRIPT_DIR}/released.md" <<EOF

## ${TAG} — $(date +%F)

- npm: `mirrorneuron-web-ui@${VERSION}`.
- PyPI: mirrorneuron-api, mirrorneuron-cli, mirrorneuron-python-sdk,
  and mirrorneuron-membrane-python-sdk ${VERSION}.
- GAR Python: all packages in package-index/python-packages.toml at ${VERSION}.
- GAR Docker: mirror-neuron-core and membrane-context-engine each published
  ${TAG}, ${VERSION}, and latest (pointing to this release at confirmation).
- GitHub tag: ${TAG} across the release repositories.
EOF

  commit_and_push_if_changed \
    mn-deploy \
    "Document ${TAG} release" \
    install.sh docker-compose.yml released.md

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

for command in git gh gcloud npm curl perl; do
  require_command "$command"
done

check_workspace
prepare_release_metadata
tag_all_repositories
wait_for_tag_workflows
publish_and_verify_gar
verify_public_registries
update_post_release_pins

printf 'Release %s completed successfully.\n' "$TAG"
