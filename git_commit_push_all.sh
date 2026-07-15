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

# Loop through all subdirectories in parent folder
for dir in "$TARGET_DIR"/*/; do
    if [ -d "$dir/.git" ]; then
        echo "-------------------------------------"
        echo "Processing repo: $dir"
        cd "$dir"

        validate_repo_before_commit

        # Get current branch and pull latest changes
        BRANCH=$(git rev-parse --abbrev-ref HEAD)
        echo "Pulling latest changes for $BRANCH..."
        git pull origin "$BRANCH"

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
