#!/usr/bin/env bash
# Build and verify local release assets.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/artifacts.sh COMMAND [OPTIONS]

  clients OUTPUT_DIRECTORY [--wasm-only]  Build the three Wasm clients and checksums.
                                          Include the native web UI proxy by default.
  tag [TAG]                               Validate a release tag and set GitHub outputs.
                                          Defaults to GITHUB_REF_NAME.
  zip [TAG [OUTPUT_DIRECTORY]]            Archive tracked files in the current Git checkout.
                                          Defaults to TAG_NAME and dist/release-assets.
  check FILE...                           Check each release artifact and ZIP contents.
EOF
}

validate_tag() {
  local tag version is_prerelease semver_tag_regex
  tag="${1:-}"

  if [[ -z "$tag" && -n "${GITHUB_REF_NAME:-}" ]]; then
    tag="$GITHUB_REF_NAME"
  fi

  if [[ -z "$tag" ]]; then
    echo "::error::Missing tag name. Expected a tag such as v1.0.1 or v1.0.1-rc.1." >&2
    exit 1
  fi

  semver_tag_regex='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(alpha|beta|rc)\.(0|[1-9][0-9]*))?$'

  if [[ ! "$tag" =~ $semver_tag_regex ]]; then
    echo "::error::Invalid release tag '$tag'." >&2
    echo "Expected vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-rc.N, -beta.N, or -alpha.N." >&2
    echo "Examples: v1.0.1, v1.1.0, v2.0.0, v1.0.1-rc.1" >&2
    exit 1
  fi

  version="${tag#v}"
  is_prerelease="false"

  if [[ "$version" == *-* ]]; then
    is_prerelease="true"
  fi

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "tag_name=$tag"
      echo "version=$version"
      echo "is_prerelease=$is_prerelease"
    } >>"$GITHUB_OUTPUT"
  fi

  if [[ -n "${GITHUB_ENV:-}" ]]; then
    {
      echo "TAG_NAME=$tag"
      echo "VERSION=$version"
      echo "IS_PRERELEASE=$is_prerelease"
    } >>"$GITHUB_ENV"
  fi

  echo "Validated release tag $tag (version $version, prerelease $is_prerelease)."
}

make_zip() (
  tag="${1:-${TAG_NAME:-}}"
  output_dir="${2:-dist/release-assets}"

  if [[ -z "$tag" ]]; then
    echo "Missing tag name. Pass a tag such as v1.0.1." >&2
    exit 1
  fi

  repo_root="$(git rev-parse --show-toplevel)"
  cd "$repo_root"

  project_name="${PROJECT_NAME:-$(basename "$repo_root")}"
  zip_name="${project_name}-${tag}.zip"

  mkdir -p "$output_dir"
  output_dir_abs="$(cd "$output_dir" && pwd)"
  zip_path="$output_dir_abs/$zip_name"

  if [[ -e "$zip_path" ]]; then
    echo "Refusing to overwrite existing release ZIP: $zip_path" >&2
    exit 1
  fi

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  archive_root="$tmpdir/${project_name}-${tag}"
  mkdir -p "$archive_root"

  while IFS= read -r -d '' file; do
    case "$file" in
    .git/* | .venv/* | venv/* | env/* | .tox/* | node_modules/* | */node_modules/*)
      continue
      ;;
    __pycache__/* | */__pycache__/* | .pytest_cache/* | */.pytest_cache/*)
      continue
      ;;
    .mypy_cache/* | */.mypy_cache/* | .ruff_cache/* | */.ruff_cache/*)
      continue
      ;;
    build/* | */build/* | dist/* | */dist/* | htmlcov/* | */htmlcov/*)
      continue
      ;;
    *.egg-info/* | *.pyc | *.pyo | *.tmp | *.swp | .DS_Store | */.DS_Store)
      continue
      ;;
    esac

    destination="$archive_root/$file"
    mkdir -p "$(dirname "$destination")"
    cp -p "$file" "$destination"
  done < <(git ls-files -z)

  if [[ -z "$(find "$archive_root" -type f -print -quit)" ]]; then
    echo "No tracked project files were found for the release ZIP." >&2
    exit 1
  fi

  if touch -h -t 198001010000 "$archive_root" 2>/dev/null; then
    find "$archive_root" -exec touch -h -t 198001010000 {} +
  else
    find "$archive_root" -exec touch -t 198001010000 {} +
  fi

  (
    cd "$tmpdir"
    find "${project_name}-${tag}" -type f | LC_ALL=C sort | zip -X -q "$zip_path" -@
  )

  echo "$zip_path"
)

write_client_asset() {
  local stage=$1 output=$2 asset=$3
  (cd "$stage" && sha256_file "$asset" >"$asset.sha256")
  mv "$stage/$asset" "$stage/$asset.sha256" "$output/"
}

build_clients() (
  if [[ $# -lt 1 || $# -gt 2 || ($# -eq 2 && $2 != --wasm-only) ]]; then
    usage >&2
    exit 2
  fi
  scripts=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  # shellcheck source=release/commands.sh
  source "$scripts/release/commands.sh"
  root=${MN_CLIENT_SOURCE_ROOT:-$(cd "$scripts/../.." && pwd)}
  mkdir -p "$1"
  out=$(cd "$1" && pwd)
  stage=$(mktemp -d "$out/.wasm.XXXXXXXX")
  trap 'rm -rf "$stage"' EXIT
  target=${CARGO_TARGET_DIR:-$root/mn-client-support/target}
  engine=${MN_WASMTIME_BIN:-wasmtime}
  for repo in mn-client-support mn-cli mn-api; do
    command=$repo
    [ "$repo" != mn-cli ] || command=mn
    "$root/mn-client-support/scripts/build-wasm.sh" "$root/$repo" "$command" "$target"
    asset="$command.wasm"
    cp "$target/wasm32-wasip2/release/$asset" "$stage/$asset"
    "$engine" run -C cache=n -S cli-exit-with-code "$stage/$asset" --version
    write_client_asset "$stage" "$out" "$asset"
  done

  # The optional web UI proxy retains its platform-specific release artifact.
  if [ "${2:-}" != --wasm-only ]; then
    triple=$(rustc -vV | awk '$1 == "host:" {print $2}')
    cargo build --locked --release --manifest-path "$root/mn-api/Cargo.toml" --bin mn-web-ui-server --target-dir "$target"
    asset="mn-web-ui-server-$triple"
    cp "$target/release/mn-web-ui-server" "$stage/$asset"
    "$stage/$asset" --version
    write_client_asset "$stage" "$out" "$asset"
  fi
)

check_artifacts() {
  local artifact contents
  if [[ $# -eq 0 ]]; then
    echo "No release artifacts were provided for validation." >&2
    return 1
  fi
  for artifact in "$@"; do
    if [[ ! -f "$artifact" ]]; then
      echo "Missing release artifact: $artifact" >&2
      return 1
    fi
    if [[ ! -s "$artifact" ]]; then
      echo "Release artifact is empty: $artifact" >&2
      return 1
    fi
    if [[ "$artifact" == *.zip ]]; then
      contents=$(unzip -Z1 "$artifact") || return 1
      if grep -E '(^|/)(\.git|node_modules|__pycache__|\.pytest_cache|build|dist)(/|$)' >/dev/null <<<"$contents"; then
        echo "Release ZIP contains an excluded path: $artifact" >&2
        return 1
      fi
    fi
  done
  echo "Release artifacts look valid."
}

command=${1:-}
if [[ $# -gt 0 ]]; then shift; fi
case "$command" in
"" | -h | --help) usage ;;
clients | tag | zip | check)
  case "${1:-}" in -h | --help)
    usage
    exit 0
    ;;
  esac
  case "$command" in
  clients) build_clients "$@" ;;
  tag) validate_tag "$@" ;;
  zip) make_zip "$@" ;;
  check) check_artifacts "$@" ;;
  esac
  ;;
*)
  printf 'error: unknown artifact command %s\n' "$command" >&2
  usage >&2
  exit 2
  ;;
esac
