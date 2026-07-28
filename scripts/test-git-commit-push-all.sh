#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_HELPER="$(cd "$SCRIPT_DIR/.." && pwd)/git_commit_push_all.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mn-deploy-git-sync.XXXXXX")"
WORKSPACE="$TEST_ROOT/workspace"
REMOTE="$TEST_ROOT/origin.git"
SEED="$TEST_ROOT/seed"
PUBLISHER="$TEST_ROOT/publisher"
TARGET="$WORKSPACE/project"
HELPER_DIR="$WORKSPACE/mn-deploy"
OUTPUT="$TEST_ROOT/helper-output.log"

cleanup() {
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

git init --bare "$REMOTE" >/dev/null
git init "$SEED" >/dev/null
git -C "$SEED" config user.name "mn-deploy test"
git -C "$SEED" config user.email "mn-deploy-test@example.invalid"
git -C "$SEED" branch -M main
printf '%s\n' "base" >"$SEED/value.txt"
git -C "$SEED" add value.txt
git -C "$SEED" commit -m "base" >/dev/null
git -C "$SEED" remote add origin "$REMOTE"
git -C "$SEED" push -u origin main >/dev/null
git --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main

mkdir -p "$WORKSPACE" "$HELPER_DIR"
cp "$SOURCE_HELPER" "$HELPER_DIR/git_commit_push_all.sh"
git clone "$REMOTE" "$TARGET" >/dev/null
git clone "$REMOTE" "$PUBLISHER" >/dev/null
git -C "$PUBLISHER" config user.name "mn-deploy test"
git -C "$PUBLISHER" config user.email "mn-deploy-test@example.invalid"

printf '%s\n' "published duplicate" >"$PUBLISHER/value.txt"
git -C "$PUBLISHER" add value.txt
git -C "$PUBLISHER" commit -m "published duplicate" >/dev/null
git -C "$PUBLISHER" push origin main >/dev/null
printf '%s\n' "published duplicate" >"$TARGET/value.txt"

"$HELPER_DIR/git_commit_push_all.sh" >"$OUTPUT" 2>&1

test "$(git -C "$TARGET" rev-parse HEAD)" = \
    "$(git -C "$TARGET" rev-parse origin/main)"
test -z "$(git -C "$TARGET" status --porcelain)"
test -z "$(git -C "$TARGET" stash list)"
grep -q "Duplicate local changes reconciled" "$OUTPUT"

printf '%s\n' "new remote value" >"$PUBLISHER/value.txt"
git -C "$PUBLISHER" add value.txt
git -C "$PUBLISHER" commit -m "new remote value" >/dev/null
git -C "$PUBLISHER" push origin main >/dev/null
printf '%s\n' "unique local value" >"$TARGET/value.txt"

if "$HELPER_DIR/git_commit_push_all.sh" >"$OUTPUT" 2>&1; then
    echo "expected unique dirty worktree reconciliation to fail" >&2
    exit 1
fi

grep -q "local changes differ from origin/main" "$OUTPUT"
test "$(sed -n '1p' "$TARGET/value.txt")" = "unique local value"
test -n "$(git -C "$TARGET" status --porcelain)"

echo "git_commit_push_all duplicate reconciliation tests passed"
