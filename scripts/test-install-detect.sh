#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mn-install-detect.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

assert_output() {
    local expected="$1"
    local actual
    actual="$(MN_HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/bin:/usr/bin:/bin" "$REPO_DIR/install.sh" --detect-only)"
    if [ "$actual" != "$expected" ]; then
        printf 'expected: %s\nactual:   %s\n' "$expected" "$actual" >&2
        exit 1
    fi
}

mkdir -p "$TEST_ROOT/bin"
cat > "$TEST_ROOT/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    info) exit "${FAKE_DOCKER_INFO_STATUS:-0}" ;;
    "container inspect mirror-neuron-core") exit "${FAKE_CONTAINER_STATUS:-1}" ;;
    "container inspect --format {{.State.Running}} mirror-neuron-core")
        printf '%s\n' "${FAKE_CONTAINER_RUNNING:-false}"
        ;;
    "container inspect --format {{.Config.Image}} mirror-neuron-core")
        printf '%s\n' 'mirror-neuron-core:latest'
        ;;
    "image inspect --format {{ index .Config.Labels \"org.opencontainers.image.version\" }} mirror-neuron-core:latest")
        printf '%s\n' "${FAKE_IMAGE_VERSION:-}"
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/docker"

assert_output '{"installed":false,"running":false,"runtime_ready":false,"status":"not_installed","version":null,"docker_installed":true,"docker_running":true}'

mkdir -p "$TEST_ROOT/home/bin"
cat > "$TEST_ROOT/home/bin/mn" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "runtime status") exit "${FAKE_RUNTIME_STATUS:-0}" ;;
    --version) printf '%s\n' 'mn v1.3.52' ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/home/bin/mn"
cat > "$TEST_ROOT/home/install_metadata.json" <<'EOF'
{
  "core_release_tag": "v1.3.54"
}
EOF
FAKE_CONTAINER_STATUS=0 FAKE_CONTAINER_RUNNING=true \
    assert_output '{"installed":true,"running":true,"runtime_ready":true,"status":"running","version":"v1.3.54","docker_installed":true,"docker_running":true}'

FAKE_CONTAINER_STATUS=1 FAKE_RUNTIME_STATUS=1 \
    assert_output '{"installed":true,"running":false,"runtime_ready":false,"status":"stopped","version":"v1.3.54","docker_installed":true,"docker_running":true}'

FAKE_DOCKER_INFO_STATUS=1 FAKE_RUNTIME_STATUS=1 \
    assert_output '{"installed":true,"running":null,"runtime_ready":false,"status":"docker_not_running","version":"v1.3.54","docker_installed":true,"docker_running":false}'

mv "$TEST_ROOT/bin/docker" "$TEST_ROOT/bin/docker.disabled"
FAKE_RUNTIME_STATUS=1 \
    assert_output '{"installed":true,"running":null,"runtime_ready":false,"status":"docker_not_running","version":"v1.3.54","docker_installed":false,"docker_running":false}'
mv "$TEST_ROOT/bin/docker.disabled" "$TEST_ROOT/bin/docker"

cat > "$TEST_ROOT/home/install_metadata.json" <<'EOF'
{
  "core_release_tag": "v1.3.54\\\",\"unexpected\":true"
}
EOF
FAKE_CONTAINER_STATUS=0 FAKE_CONTAINER_RUNNING=false FAKE_IMAGE_VERSION=v1.3.53 FAKE_RUNTIME_STATUS=1 \
    assert_output '{"installed":true,"running":false,"runtime_ready":false,"status":"stopped","version":"v1.3.53","docker_installed":true,"docker_running":true}'

printf 'install detection tests passed\n'
