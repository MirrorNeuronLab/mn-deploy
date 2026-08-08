#!/bin/bash

# Exit on error
set -e

# Commit message (default if not provided)
COMMIT_MSG="auto: update all repos"

usage() {
    echo "Usage: $0 [-m \"commit message\"]"
}

while getopts ":m:h" opt; do
    case "$opt" in
        m)
            COMMIT_MSG="$OPTARG"
            ;;
        h)
            usage
            exit 0
            ;;
        :)
            echo "Error: option -$OPTARG requires a commit message." >&2
            usage >&2
            exit 2
            ;;
        \?)
            echo "Error: invalid option -$OPTARG." >&2
            usage >&2
            exit 2
            ;;
    esac
done

shift $((OPTIND - 1))

if [ "$#" -gt 0 ]; then
    echo "Error: unexpected argument: $1" >&2
    usage >&2
    exit 2
fi

echo "Starting bulk git commit & push..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
echo "Operating on repositories in: $TARGET_DIR"

validate_repo_before_commit() {
    if git ls-files --error-unmatch mix.exs >/dev/null 2>&1; then
        if [ ! -s mix.exs ]; then
            echo "Tracked mix.exs is empty; restoring it from HEAD before committing."
            git restore --source=HEAD -- mix.exs
        fi

        if [ ! -s mix.exs ] || ! grep -q "use Mix.Project" mix.exs; then
            echo "Refusing to commit: tracked mix.exs is empty or not a Mix project."
            echo "Fix mix.exs first, then rerun the bulk commit."
            return 1
        fi
    fi
}

sync_branch_before_commit() {
    local branch="$1"
    local remote_ref="refs/remotes/origin/$branch"
    local recovery_stash

    echo "Fetching latest changes and tags for $branch..."
    git fetch --tags origin "$branch"

    if ! git show-ref --verify --quiet "$remote_ref"; then
        echo "error: origin/$branch was not found after fetch." >&2
        return 1
    fi

    if [[ -z $(git status --porcelain) ]]; then
        git merge --ff-only "$remote_ref"
        return
    fi

    # A local branch at or ahead of its fetched remote can be committed safely.
    if git merge-base --is-ancestor "$remote_ref" HEAD; then
        return
    fi

    if ! git merge-base --is-ancestor HEAD "$remote_ref"; then
        echo "error: local $branch has diverged from origin/$branch." >&2
        echo "Commit or stash local work, reconcile the branch, and rerun." >&2
        return 1
    fi

    # Reconcile only the narrow case where copied tracked files already equal
    # the fetched fast-forward result. Untracked files are never discarded.
    if [[ -z $(git ls-files --others --exclude-standard) ]] \
        && git diff --quiet "$remote_ref" --; then
        echo "Local tracked changes already match origin/$branch."
        echo "Creating a recovery stash and fast-forwarding..."
        git stash push -m "mn-deploy duplicate before fast-forward"
        recovery_stash="stash@{0}"
        git merge --ff-only "$remote_ref"

        if ! git diff --quiet HEAD "$recovery_stash" --; then
            echo "error: recovery stash differs from the fast-forwarded tree." >&2
            echo "The recovery stash was kept as $recovery_stash; inspect it before continuing." >&2
            return 1
        fi

        git stash drop "$recovery_stash"
        echo "Duplicate local changes reconciled with origin/$branch."
        return
    fi

    echo "error: local changes differ from origin/$branch while the branch is behind." >&2
    echo "Commit or stash local work, pull with an explicit conflict strategy, and rerun." >&2
    return 1
}

# Loop through all subdirectories in parent folder
for dir in "$TARGET_DIR"/*/; do
    if [ -d "$dir/.git" ]; then
        echo "-------------------------------------"
        echo "Processing repo: $dir"
        cd "$dir"

        validate_repo_before_commit

        # Get current branch and pull latest changes
        BRANCH=$(git rev-parse --abbrev-ref HEAD)
        sync_branch_before_commit "$BRANCH"

        # Check if there are changes
        if [[ -n $(git status --porcelain) ]]; then
            validate_repo_before_commit

            if [[ -z $(git status --porcelain) ]]; then
                echo "No changes after validation cleanup, skipping."
                cd "$TARGET_DIR"
                continue
            fi

            echo "Changes detected. Committing..."

            git add .
            git commit -m "$COMMIT_MSG"

            echo "Pushing to origin/$BRANCH..."
            git push origin "$BRANCH"
        else
            echo "No changes, skipping."
        fi

        cd "$TARGET_DIR"
    fi
done

echo "Done."
