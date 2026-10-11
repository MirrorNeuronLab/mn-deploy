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
git -C "$TARGET" config user.name "mn-deploy test"
git -C "$TARGET" config user.email "mn-deploy-test@example.invalid"
git clone "$REMOTE" "$PUBLISHER" >/dev/null
git -C "$PUBLISHER" config user.name "mn-deploy test"
git -C "$PUBLISHER" config user.email "mn-deploy-test@example.invalid"

# Tags added after a clone can point to commits the clone already has. An
# ordinary branch fetch does not guarantee that those tags are downloaded.
git -C "$PUBLISHER" tag sync-test-tag
git -C "$PUBLISHER" push origin refs/tags/sync-test-tag >/dev/null
test -z "$(git -C "$TARGET" tag --list sync-test-tag)"

"$HELPER_DIR/git_commit_push_all.sh" >"$OUTPUT" 2>&1

test "$(git -C "$TARGET" rev-parse refs/tags/sync-test-tag)" = \
    "$(git -C "$PUBLISHER" rev-parse refs/tags/sync-test-tag)"
grep -q "Fetching latest changes and tags" "$OUTPUT"

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

# A clean working tree can still contain unpublished commits. Publish them
# without creating another commit or rewriting either side's history.
printf '%s\n' "committed locally" >"$TARGET/value.txt"
git -C "$TARGET" add value.txt
git -C "$TARGET" commit -m "committed locally" >/dev/null
LOCAL_COMMIT="$(git -C "$TARGET" rev-parse HEAD)"
test "$LOCAL_COMMIT" != "$(git --git-dir="$REMOTE" rev-parse main)"

"$HELPER_DIR/git_commit_push_all.sh" >"$OUTPUT" 2>&1

test "$(git --git-dir="$REMOTE" rev-parse main)" = "$LOCAL_COMMIT"
test "$(git -C "$TARGET" rev-parse HEAD)" = "$LOCAL_COMMIT"
test -z "$(git -C "$TARGET" status --porcelain)"
grep -q "Pushing to origin/main" "$OUTPUT"

# Repeating a completed sync is a no-op, and new dirty work still gets saved.
"$HELPER_DIR/git_commit_push_all.sh" >"$OUTPUT" 2>&1
test "$(git --git-dir="$REMOTE" rev-parse main)" = "$LOCAL_COMMIT"
grep -q "Already synchronized with origin/main" "$OUTPUT"
printf '%s\n' "new local work" >"$TARGET/value.txt"
"$HELPER_DIR/git_commit_push_all.sh" -m "new local work" >"$OUTPUT" 2>&1
test "$(git --git-dir="$REMOTE" rev-parse main)" = "$(git -C "$TARGET" rev-parse HEAD)"
test "$(git -C "$TARGET" log -1 --format=%s)" = "new local work"
test -z "$(git -C "$TARGET" status --porcelain)"

git -C "$PUBLISHER" fetch origin >/dev/null
git -C "$PUBLISHER" merge --ff-only origin/main >/dev/null
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

# Committing that unmatched work leaves a clean but divergent branch. Neither
# local nor remote commits may be discarded or force-pushed by the helper.
git -C "$TARGET" add value.txt
git -C "$TARGET" commit -m "unique local work" >/dev/null
LOCAL_COMMIT="$(git -C "$TARGET" rev-parse HEAD)"
REMOTE_COMMIT="$(git --git-dir="$REMOTE" rev-parse main)"
if "$HELPER_DIR/git_commit_push_all.sh" >"$OUTPUT" 2>&1; then
    echo "expected clean divergent branch reconciliation to fail" >&2
    exit 1
fi
test "$(git -C "$TARGET" rev-parse HEAD)" = "$LOCAL_COMMIT"
test "$(git --git-dir="$REMOTE" rev-parse main)" = "$REMOTE_COMMIT"
test -z "$(git -C "$TARGET" status --porcelain)"

echo "git_commit_push_all synchronization tests passed"
