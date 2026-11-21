#!/usr/bin/env bash
# Release commands run only when the publisher sets APPLY=Y.

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

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

sha256_file() {
  if command_exists sha256sum; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}
