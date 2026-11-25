#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mn-format-pending.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
cd "$TEST_ROOT"
git init -q
git config user.name "mn-deploy test"
git config user.email "mn-deploy-test@example.invalid"
cp "$REPO_DIR/.pre-commit-config.yaml" .
echo 'ignored.py' >.gitignore
echo 'private.md' >.prettierignore
echo 'untouched=0' >untouched.py
git add .
git commit -qm base
base="$(git rev-parse HEAD)"

# One unpublished commit, a staged type stub and untracked files of mixed types.
echo 'value=1' >published-later.py
git add published-later.py
git commit -qm pending
echo 'value:int' >stub.pyi
git add stub.pyi
echo '#    Title' >"notes with spaces.md"
echo '#    Keep' >private.md
echo 'ignored=2' >ignored.py
mkdir install_support
echo 'snapshot=3' >install_support/snapshot.py
echo '{"a":1}' >data.json
echo 'const a=1' >app.js
echo 'input: [1,2]' >ci.yaml

format_pending() {
  uvx --from pre-commit==4.5.1 python "$REPO_DIR/scripts/format-pending.py" "$base" "$@"
}

format_pending ruff-format
test "$(cat published-later.py)" = 'value = 1'
test "$(cat stub.pyi)" = 'value: int'
test "$(git show :stub.pyi)" = 'value:int'
test "$(cat untouched.py)" = 'untouched=0'
test "$(cat ignored.py)" = 'ignored=2'
test "$(cat install_support/snapshot.py)" = 'snapshot=3'
test "$(cat "notes with spaces.md")" = '#    Title'

echo 'value=4' >published-later.py
format_pending prettier
test "$(cat "notes with spaces.md")" = '# Title'
test "$(cat published-later.py)" = 'value=4'
test "$(cat private.md)" = '#    Keep'
test "$(cat data.json)" = '{"a":1}'
test "$(cat app.js)" = 'const a=1'
test "$(cat ci.yaml)" = 'input: [1,2]'

echo "Pending file formatting tests passed"
