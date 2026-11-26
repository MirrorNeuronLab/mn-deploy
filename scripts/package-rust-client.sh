#!/usr/bin/env bash
# Produce architecture-independent release assets for the three Rust clients.
set -euo pipefail
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || { [ "$#" -eq 2 ] && [ "$2" != --wasm-only ]; }; then
  echo 'Usage: package-rust-client.sh OUTPUT_DIRECTORY [--wasm-only]' >&2; exit 2
fi
root=${MN_CLIENT_SOURCE_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}
mkdir -p "$1"
out=$(cd "$1" && pwd)
stage=$(mktemp -d "$out/.wasm.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
target=${CARGO_TARGET_DIR:-$root/mn-client-support/target}
engine=${MN_WASMTIME_BIN:-wasmtime}
for repo in mn-client-support mn-cli mn-api; do
  command=$repo; [ "$repo" != mn-cli ] || command=mn
  "$root/mn-client-support/scripts/build-wasm.sh" "$root/$repo" "$command" "$target"
  asset="$command.wasm"
  cp "$target/wasm32-wasip2/release/$asset" "$stage/$asset"
  "$engine" run -C cache=n -S cli-exit-with-code "$stage/$asset" --version
  if command -v shasum >/dev/null; then (cd "$stage" && shasum -a 256 "$asset" >"$asset.sha256")
  else (cd "$stage" && sha256sum "$asset" >"$asset.sha256"); fi
  mv "$stage/$asset" "$stage/$asset.sha256" "$out/"
done

# The optional web UI proxy retains its platform-specific release artifact.
if [ "${2:-}" != --wasm-only ]; then
  triple=$(rustc -vV | awk '$1 == "host:" {print $2}')
  cargo build --locked --release --manifest-path "$root/mn-api/Cargo.toml" --bin mn-web-ui-server --target-dir "$target"
  asset="mn-web-ui-server-$triple"
  cp "$target/release/mn-web-ui-server" "$stage/$asset"
  "$stage/$asset" --version
  if command -v shasum >/dev/null; then (cd "$stage" && shasum -a 256 "$asset" >"$asset.sha256")
  else (cd "$stage" && sha256sum "$asset" >"$asset.sha256"); fi
  mv "$stage/$asset" "$stage/$asset.sha256" "$out/"
fi
