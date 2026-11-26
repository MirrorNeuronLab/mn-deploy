#!/usr/bin/env bash
# Local release gate. The live option provisions and removes its own two runtimes.
set -euo pipefail
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
VALIDATION_PYTHON="${MN_VALIDATION_PYTHON:-$WORKSPACE_ROOT/mn-system-tests/.venv/bin/python}"
case "${1:---offline}" in
--offline) live=N ;;
--two-runtimes) live=Y ;;
*)
  printf 'Usage: %s [--offline|--two-runtimes]\n' "$0" >&2
  exit 2
  ;;
esac
test -x "$VALIDATION_PYTHON" || {
  printf 'Set MN_VALIDATION_PYTHON to the provisioned system-test Python environment.\n' >&2
  exit 1
}
VALIDATION_HOME="$(mktemp -d "${TMPDIR:-/tmp}/mn-split-validation.XXXXXX")"
trap 'rm -rf "$VALIDATION_HOME"' EXIT
export MN_HOME="$VALIDATION_HOME" MN_ENV=test RUN_MN_SYSTEM_TESTS=1
export PYTHONPATH="$WORKSPACE_ROOT/mn-python-sdk/packages/contracts/src:$WORKSPACE_ROOT/mn-python-sdk/packages/runtime/src:$WORKSPACE_ROOT/mn-python-sdk/packages/runtime${PYTHONPATH:+:$PYTHONPATH}"

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$VALIDATION_HOME/target}"
for component in mn-client-support mn-cli mn-api; do
  cargo test --locked --manifest-path "$WORKSPACE_ROOT/$component/Cargo.toml"
  cargo build --locked --manifest-path "$WORKSPACE_ROOT/$component/Cargo.toml" --bins
done
export MN_RUST_CLIENT_BIN="$VALIDATION_HOME/wasm-bin"
mkdir -p "$MN_RUST_CLIENT_BIN"
"$DEPLOY_DIR/scripts/package-rust-client.sh" "$MN_RUST_CLIENT_BIN" --wasm-only
engine="${MN_WASMTIME_BIN:-$(command -v wasmtime)}"
ln -s "$engine" "$MN_RUST_CLIENT_BIN/wasmtime"
for command in mn mn-api mn-client-support; do
  "$engine" run -C cache=n "$MN_RUST_CLIENT_BIN/mn-client-support.wasm" --print-launcher >"$MN_RUST_CLIENT_BIN/$command"
  chmod 755 "$MN_RUST_CLIENT_BIN/$command"
done
cp "$CARGO_TARGET_DIR/debug/mn-web-ui-server" "$MN_RUST_CLIENT_BIN/"
(cd "$WORKSPACE_ROOT/mn-system-tests" && "$VALIDATION_PYTHON" -m pytest tests/integration/installer -q)
(cd "$WORKSPACE_ROOT/mn-system-tests" && "$VALIDATION_PYTHON" -m pytest \
  tests/integration/contracts/test_api_contracts.py \
  tests/integration/contracts/test_worker_supervision_transport.py \
  tests/integration/contracts/test_surface_proxy_publication.py \
  tests/integration/contracts/test_runtime_retirement_transport.py \
  tests/integration/contracts/test_cli_contracts.py \
  tests/integration/contracts/test_model_replica_contracts.py \
  tests/integration/contracts/test_provider_default_overrides.py \
  tests/integration/contracts/test_run_admission_contracts.py \
  tests/integration/contracts/test_federated_model_status_contract.py \
  tests/integration/contracts/test_blueprint_runtime_model_preflight_contract.py -q)
(cd "$DEPLOY_DIR" && "$VALIDATION_PYTHON" -m pytest tests/test_job_ui_proxy.py -q)
(cd "$WORKSPACE_ROOT/mn-python-sdk" && "$VALIDATION_PYTHON" -m pytest tests packages/runtime/tests_runtime -q)
(cd "$WORKSPACE_ROOT/mn-system-tests" && "$VALIDATION_PYTHON" -m pytest -q \
  tests/integration/contracts/test_native_rust_client.py \
  tests/integration/contracts/test_cli_python_parity.py \
  tests/integration/contracts/test_api_python_parity.py \
  tests/integration/contracts/test_wasm_release.py)
(cd "$WORKSPACE_ROOT/MirrorNeuron" && mix test --no-start tests/unit/grpc/runtime_control_auth_test.exs tests/unit/grpc/runtime_membership_test.exs tests/unit/grpc/runtime_control_route_test.exs tests/unit/core_environment_test.exs tests/e2e/runner/core_connection_test.exs)
"$VALIDATION_PYTHON" "$DEPLOY_DIR/scripts/validate-runtime-wheels.py"
"$VALIDATION_PYTHON" "$DEPLOY_DIR/scripts/prepare-python-package-index.py" \
  "$DEPLOY_DIR/package-index/python-packages.toml" "$WORKSPACE_ROOT" 1.4.8 --verify-worktree --verify-dependencies
if [ "$live" = Y ]; then
  (cd "$WORKSPACE_ROOT/mn-system-tests" && MN_SPLIT_RUNTIME_ACCEPTANCE=1 "$VALIDATION_PYTHON" -m pytest -q \
    tests/integration/live/test_split_runtime_acceptance.py \
    tests/integration/live/test_node_lifecycle.py)
else
  printf 'Offline gate passed. Release also requires --two-runtimes (Docker, cached Redis image, Elixir).\n'
fi
