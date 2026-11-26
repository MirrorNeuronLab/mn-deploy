#!/usr/bin/env bash
# Prepare the Rust target and C toolchain used to build mn-api.wasm.
set -euo pipefail

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  echo 'Usage: ./scripts/preapare_dev.sh'
  echo 'Prepare the WASI development tools and print the SDK directory for WASI_SDK_PATH.'
  exit 0
fi
if [[ $# -ne 0 ]]; then
  echo 'Usage: ./scripts/preapare_dev.sh' >&2
  exit 2
fi

export PATH="$PATH:${CARGO_HOME:-$HOME/.cargo}/bin"
if ! command -v rustc >/dev/null; then
  echo 'error: Install Rust with rustup and rerun developer setup.' >&2
  exit 1
fi
if [[ ! -d "$(rustc --print target-libdir --target wasm32-wasip2)" ]]; then
  rustup target add wasm32-wasip2 >&2
fi

check_sdk() {
  [[ -x "$1/bin/clang" && -x "$1/bin/llvm-ar" ]] &&
    "$1/bin/clang" --target=wasm32-wasip2 -x c -fsyntax-only - <<<'#include <stdio.h>'
}

sdk=${WASI_SDK_PATH:-}
if [[ -z $sdk && -x /opt/wasi-sdk/bin/clang ]]; then sdk=/opt/wasi-sdk; fi
if [[ -z $sdk ]]; then
  host="$(uname -s)/$(uname -m)"
  # SHA-256 digests from the upstream wasi-sdk-34 release assets.
  case "$host" in
    Linux/aarch64|Linux/arm64)
      platform=arm64-linux
      digest=f7e243dff54d60bcc576e94d6166b69f410f2500ae4a9ceef34315be10e77971 ;;
    Linux/x86_64)
      platform=x86_64-linux
      digest=b761e3a0721dbae9c09a0059e5fdb2bf917d1b4a8a7b430fb3b5aafb0984b2c4 ;;
    Darwin/arm64)
      platform=arm64-macos
      digest=9c59398106b417f8f14913380fdf0097a8cc0ff4af9eb3ce0065a859e88d49e9 ;;
    Darwin/x86_64)
      platform=x86_64-macos
      digest=87d27fa8adc68dee59bfbf2e22a6d34ef717c34d6bf1d8af2a56fc929d9ce0eb ;;
    *)
      echo "error: No pinned WASI SDK for $host. Set WASI_SDK_PATH to an extracted SDK." >&2
      exit 1 ;;
  esac
  name=wasi-sdk-34.0-$platform
  root=${XDG_DATA_HOME:-$HOME/.local/share}/mirrorneuron/dev
  mkdir -p "$root"
  root=$(cd "$root" && pwd -P)
  sdk=$root/$name
  if [[ ! -d $sdk ]]; then
    stage=$(mktemp -d "$root/.wasi-sdk.XXXXXXXX")
    trap 'rm -rf "$stage"' EXIT
    echo "==> Downloading $name" >&2
    curl --proto '=https' --proto-redir '=https' -fsSL --retry 2 -o "$stage/sdk.tar.gz" \
      "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-34/$name.tar.gz"
    if command -v sha256sum >/dev/null; then actual=$(sha256sum <"$stage/sdk.tar.gz")
    else actual=$(shasum -a 256 <"$stage/sdk.tar.gz"); fi
    if [[ ${actual%% *} != "$digest" ]]; then
      echo "error: SHA-256 checksum failed for $name. Rerun developer setup to retry." >&2
      exit 1
    fi
    tar -xzf "$stage/sdk.tar.gz" -C "$stage"
    check_sdk "$stage/$name" || { echo "error: Cannot run the downloaded $name toolchain." >&2; exit 1; }
    # Publish the complete directory. A concurrent run can publish it first.
    mv -n "$stage/$name" "$root/" || [[ -d $sdk ]]
  fi
fi
if ! check_sdk "$sdk"; then
  echo "error: Cannot use the WASI SDK in $sdk. Set WASI_SDK_PATH to a working SDK." >&2
  exit 1
fi
cd "$sdk" && pwd -P
