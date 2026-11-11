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
export PYTHONPATH="$WORKSPACE_ROOT/mn-python-sdk/packages/runtime/src:$WORKSPACE_ROOT/mn-python-sdk/packages/runtime${PYTHONPATH:+:$PYTHONPATH}"

(cd "$WORKSPACE_ROOT/mn-system-tests" && "$VALIDATION_PYTHON" -m pytest tests/integration/installer -q)
(cd "$WORKSPACE_ROOT/mn-system-tests" && "$VALIDATION_PYTHON" -m pytest \
  tests/integration/contracts/test_api_contracts.py \
  tests/integration/contracts/test_cli_contracts.py \
  tests/integration/contracts/test_model_replica_contracts.py \
  tests/integration/contracts/test_provider_default_overrides.py \
  tests/integration/contracts/test_run_admission_contracts.py \
  tests/integration/contracts/test_federated_model_status_contract.py \
  tests/integration/contracts/test_blueprint_runtime_model_preflight_contract.py -q)
(cd "$WORKSPACE_ROOT/mn-python-sdk" && "$VALIDATION_PYTHON" -m pytest tests packages/runtime/tests_runtime -q)
(cd "$WORKSPACE_ROOT/mn-cli" && "$VALIDATION_PYTHON" -m pytest -q)
(cd "$WORKSPACE_ROOT/mn-api" && "$VALIDATION_PYTHON" -m pytest -q)
(cd "$WORKSPACE_ROOT/MirrorNeuron" && mix test --no-start tests/unit/grpc/runtime_control_auth_test.exs tests/unit/grpc/runtime_membership_test.exs tests/unit/grpc/runtime_control_route_test.exs)
"$VALIDATION_PYTHON" "$DEPLOY_DIR/scripts/validate-runtime-wheels.py"
"$VALIDATION_PYTHON" "$DEPLOY_DIR/scripts/prepare-python-package-index.py" \
  "$DEPLOY_DIR/package-index/python-packages.toml" "$WORKSPACE_ROOT" 1.4.8 --verify-worktree --verify-dependencies
if [ "$live" = Y ]; then
  (cd "$WORKSPACE_ROOT/mn-system-tests" && MN_SPLIT_RUNTIME_ACCEPTANCE=1 "$VALIDATION_PYTHON" -m pytest tests/integration/live/test_split_runtime_acceptance.py -q)
else
  printf 'Offline gate passed. Release also requires --two-runtimes (Docker, cached Redis image, Elixir).\n'
fi
