#!/usr/bin/env bash
# Publish only the portable clients. Verify downloaded bytes on every invocation, including retries.
set -euo pipefail
scripts=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../release/commands.sh
source "$scripts/release/commands.sh"
version=""
project=${MN_GAR_PROJECT:-mirrorneuron-public-packages}
location=${MN_GAR_LOCATION:-us-central1}
repository=${MN_CLIENT_GAR_REPOSITORY:-mirrorneuron-binaries}
artifacts=""
apply=false
from_tag=false
usage() {
  echo "Usage: scripts/publish.sh clients --version vX.Y.Z [--project P] [--location L] [--repository R] [--from-tag | --artifacts DIR] [--apply]"
}
while [ "$#" -gt 0 ]; do
  case "$1" in
  --version | --project | --location | --repository | --artifacts)
    if [[ $# -lt 2 || -z $2 ]]; then
      printf 'error: %s requires a value\n' "$1" >&2
      exit 2
    fi
    case "$1" in
    --version) version=$2 ;;
    --project) project=$2 ;;
    --location) location=$2 ;;
    --repository) repository=$2 ;;
    --artifacts) artifacts=$2 ;;
    esac
    shift 2
    ;;
  --from-tag)
    from_tag=true
    shift
    ;;
  --apply)
    apply=true
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
  esac
done
version="v${version#v}"
"$scripts/artifacts.sh" tag "$version" >/dev/null
if [ "$from_tag" = true ] && [ -n "$artifacts" ]; then
  echo "--from-tag and --artifacts are mutually exclusive" >&2
  exit 2
fi
packages=(mn-client-support mn-cli mn-api)
for package in "${packages[@]}"; do printf '%s\n' "$location/$project/$repository/$package@$version"; done
[ "$apply" = true ] || exit 0
stage=$(mktemp -d "${TMPDIR:-/tmp}/mn-client-publish.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
cache=${MN_WASM_ARTIFACT_CACHE:-}
if [ "$from_tag" = true ]; then
  workspace=${MN_CLIENT_SOURCE_ROOT:-$(cd "$scripts/../.." && pwd)}
  trees=()
  for package in "${packages[@]}"; do
    trees+=("$(git -C "$workspace/$package" rev-parse --verify "refs/tags/$version^{tree}")")
  done
  key=$(
    IFS=-
    printf '%s' "${trees[*]}"
  )
  cache=${cache:-${XDG_CACHE_HOME:-$HOME/.cache}/mirrorneuron/wasm-client-releases/$version/$key}
  if [ ! -d "$cache" ]; then
    for package in "${packages[@]}"; do
      mkdir -p "$stage/source/$package"
      git -C "$workspace/$package" archive "refs/tags/$version" | tar -x -C "$stage/source/$package"
    done
    export MN_CLIENT_SOURCE_ROOT="$stage/source"
  fi
fi
if [ -z "$artifacts" ] && [ -n "$cache" ]; then
  if [ ! -d "$cache" ]; then
    (
      umask 077
      mkdir -p "$(dirname "$cache")"
      build=$(mktemp -d "$(dirname "$cache")/.build.XXXXXXXX")
      trap 'rm -rf "$build"' EXIT
      MN_CLIENT_RELEASE_VERSION="${version#v}" "$scripts/artifacts.sh" clients "$build/artifacts" --wasm-only
      # Preserve the original bytes across partial uploads and concurrent retries.
      python3 - "$build/artifacts" "$cache" <<'PY_CACHE'
import errno, os, sys
try:
    os.rename(sys.argv[1], sys.argv[2])
except OSError as error:
    if error.errno not in (errno.ENOTEMPTY, errno.EEXIST):
        raise
PY_CACHE
    )
  fi
  artifacts=$cache
elif [ -z "$artifacts" ]; then
  artifacts="$stage/build"
  MN_CLIENT_RELEASE_VERSION="${version#v}" "$scripts/artifacts.sh" clients "$artifacts" --wasm-only
fi
engine=${MN_WASMTIME_BIN:-wasmtime}
gcloud=${MN_GCLOUD_BIN:-gcloud}
# Validate the entire release before its first upload.
for package in "${packages[@]}"; do
  name=$package
  [ "$package" != mn-cli ] || name=mn
  file="$name.wasm"
  mkdir "$stage/$package"
  cp "$artifacts/$file" "$artifacts/$file.sha256" "$stage/$package/"
  expected=$(awk 'NR==1 {print $1}' "$artifacts/$file.sha256")
  actual=$(sha256_file "$artifacts/$file")
  [[ "$expected" =~ ^[0-9a-f]{64}$ && "${actual%% *}" = "$expected" ]] || {
    echo "Invalid checksum for $file" >&2
    exit 1
  }
  identity=$("$engine" run -C cache=n -S cli-exit-with-code "$artifacts/$file" --version)
  [ "$identity" = "$name ${version#v}" ] || {
    echo "$file reports '$identity', expected $version" >&2
    exit 1
  }
done
for package in "${packages[@]}"; do
  "$gcloud" artifacts generic upload --project="$project" --location="$location" --repository="$repository" \
    --package="$package" --version="$version" --source-directory="$stage/$package" --skip-existing
  for path in "$stage/$package/"*; do
    url="https://artifactregistry.googleapis.com/download/v1/projects/$project/locations/$location/repositories/$repository/files/$package%3A$version%3A${path##*/}:download?alt=media"
    curl --proto '=https' --proto-redir '=https' --retry 3 --retry-all-errors -fsSL "$url" -o "$stage/download"
    cmp "$path" "$stage/download" || {
      echo "Published bytes differ for $package $version ${path##*/}" >&2
      exit 1
    }
  done
done
