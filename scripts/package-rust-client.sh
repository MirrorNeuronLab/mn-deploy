#!/usr/bin/env bash
# Build the host's native client release assets from sibling Rust repositories.
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo 'Usage: package-rust-client.sh OUTPUT_DIRECTORY' >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/../.." && pwd)"
target="$(rustc -vV | awk '$1 == "host:" {print $2}')"
case "$target" in
aarch64-apple-darwin | x86_64-apple-darwin | aarch64-unknown-linux-gnu | x86_64-unknown-linux-gnu) ;;
*)
  echo "Unsupported release target $target" >&2
  exit 1
  ;;
esac
mkdir -p "$1"
out="$(cd "$1" && pwd)"
stage="$(mktemp -d "$out/.native.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
build_dir="${CARGO_TARGET_DIR:-$stage/target}"
mkdir -p "$build_dir"
build_dir="$(cd "$build_dir" && pwd)"
for repo in mn-client-support mn-cli mn-api; do
  cargo build --locked --release --bins --manifest-path "$root/$repo/Cargo.toml" --target-dir "$build_dir"
done
for command in mn-client-support mn mn-api mn-web-ui-server; do
  "$build_dir/release/$command" --version
  asset="$command-$target"
  cp "$build_dir/release/$command" "$stage/$asset"
  if command -v shasum >/dev/null; then
    (cd "$stage" && shasum -a 256 "$asset" >"$asset.sha256")
  else
    (cd "$stage" && sha256sum "$asset" >"$asset.sha256")
  fi
  mv "$stage/$asset" "$stage/$asset.sha256" "$out/"
done
