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

# Use the selected publishing environment, then the operation's system Python.
release_python() {
  local interpreter="${MN_PUBLISH_PYTHON:-${MN_GAR_PUBLISH_VENV:-$1/.venv-gar-publish}/bin/python}"
  if ! command_exists "$interpreter"; then
    interpreter="${MN_PUBLISH_PYTHON:-$2}"
  fi
  if ! command_exists "$interpreter"; then
    printf 'error: set MN_PUBLISH_PYTHON to a publishing interpreter (%s was not found).\n' "$interpreter" >&2
    return 1
  fi
  printf '%s\n' "$interpreter"
}

sha256_file() {
  if command_exists sha256sum; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}

package_version_tag() {
  local value="$1"
  value="${value#refs/tags/}"
  value="${value#release/}"
  case "$value" in
  v*) printf '%s' "$value" ;;
  *) printf 'v%s' "$value" ;;
  esac
}
