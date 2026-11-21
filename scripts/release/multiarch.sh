#!/usr/bin/env bash

validate_qemu_mode() {
  case "$1" in
  auto | always | never) ;;
  *) die "QEMU mode must be auto, always, or never; got '$1'." ;;
  esac
}

needs_amd64_emulation() {
  local platforms="$1" mode="$2" host_arch="$3"
  platforms="${platforms//[[:space:]]/}"
  case ",$platforms," in
  *,linux/amd64,*) ;;
  *) return 1 ;;
  esac

  case "$mode" in
  always) return 0 ;;
  auto) [[ "$host_arch" == arm64 || "$host_arch" == aarch64 ]] ;;
  *) return 1 ;;
  esac
}

configure_amd64_emulation() {
  local component="$1" host_arch="$2" docker="$3" image="$4"
  log "Configuring amd64 QEMU emulation for ${component} release build on ${host_arch}."
  run_or_echo "$docker" run --privileged --rm "$image" --install amd64
}
