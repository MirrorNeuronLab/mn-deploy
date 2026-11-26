#!/bin/bash

# Exit on error
set -e

# Commit message (default if not provided)
COMMIT_MSG="auto: update all repos"
FORMAT_HOOKS=()

usage() {
  echo "Usage: $0 [--markdown-prettier] [--ruff-format] [-m \"commit message\"]"
  echo "  --markdown-prettier  Format pending Markdown with Prettier."
  echo "  --ruff-format        Format pending Python with Ruff."
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --markdown-prettier)
    FORMAT_HOOKS+=(prettier)
    ;;
  --ruff-format)
    FORMAT_HOOKS+=(ruff-format)
    ;;
  -m)
    if [ "$#" -lt 2 ]; then
      echo "Error: option -m requires a commit message." >&2
      usage >&2
      exit 2
    fi
    COMMIT_MSG="$2"
    shift
    ;;
  -m?*)
    COMMIT_MSG="${1#-m}"
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  --)
    shift
    break
    ;;
  -*)
    echo "Error: invalid option $1." >&2
    usage >&2
    exit 2
    ;;
  *) break ;;
  esac
  shift
done

if [ "$#" -gt 0 ]; then
  echo "Error: unexpected argument: $1" >&2
  usage >&2
  exit 2
fi

if ((${#FORMAT_HOOKS[@]})) && ! command -v uvx >/dev/null 2>&1; then
  echo "error: formatting requires uvx. Install uv and rerun." >&2
  exit 1
fi

echo "Starting bulk git commit & push..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
echo "Operating on repositories in: $TARGET_DIR"

prepare_checkout() {
  local name="$1" branch="$2" paired="" archive fetch_url push_url
  local legacy_ref="refs/remotes/origin/python-legacy"
  case "$name" in
  mn-api | mn-cli) paired="$name" ;;
  mn-client-support) paired="mn-surface" ;;
  esac

  if ! git remote get-url origin >/dev/null 2>&1; then
    if [ -n "$paired" ] && [ -f Cargo.toml ]; then
      for archive in "$TARGET_DIR/$paired-old" "$TARGET_DIR/${paired}_old"; do
        [ -e "$archive/.git" ] || continue
        fetch_url=$(git -C "$archive" remote get-url origin) || return 1
        push_url=$(git -C "$archive" remote get-url --push origin) || return 1
        git remote add origin "$fetch_url"
        if [ "$push_url" != "$fetch_url" ]; then
          git remote set-url --push origin "$push_url"
        fi
        echo "Configured origin from the paired ${archive##*/} checkout."
        break
      done
    fi
    if ! git remote get-url origin >/dev/null 2>&1; then
      echo "error: $name has no origin. Configure its Git remote and rerun." >&2
      return 1
    fi
  fi

  case "$name" in
  mn-api-old | mn-api_old | mn-cli-old | mn-cli_old | mn-surface-old | mn-surface_old)
    if [ "$branch" = python-legacy ]; then
      return
    fi
    # A pre-migration archive can still have main checked out at the Python tip.
    # Changing only its branch name preserves any pending edits to that tree.
    if [ "$branch" = main ] &&
      git fetch --no-tags origin "refs/heads/python-legacy:$legacy_ref" &&
      [ "$(git rev-parse HEAD)" = "$(git rev-parse "$legacy_ref")" ]; then
      if ! git show-ref --verify --quiet refs/heads/python-legacy; then
        git switch --track -c python-legacy origin/python-legacy
        return
      elif [ "$(git rev-parse python-legacy)" = "$(git rev-parse HEAD)" ]; then
        git switch python-legacy
        return
      fi
    fi
    echo "error: $name is on $branch. Reconcile the archived checkout with origin/python-legacy and switch to python-legacy." >&2
    return 1
    ;;
  esac
  if [ -n "$paired" ] && [ "$branch" = python-legacy ]; then
    echo "error: $name is the Rust checkout. Switch to its Rust development branch before publishing." >&2
    return 1
  fi
}

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
  if [[ -z $(git ls-files --others --exclude-standard) ]] &&
    git diff --quiet "$remote_ref" --; then
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

    prepare_checkout "$(basename "$dir")" "$(git branch --show-current)"
    validate_repo_before_commit

    # Get current branch and pull latest changes
    BRANCH=$(git symbolic-ref --quiet --short HEAD) || {
      echo "error: detached HEAD in $dir. Switch to the branch you intend to publish." >&2
      exit 1
    }
    sync_branch_before_commit "$BRANCH"

    if ((${#FORMAT_HOOKS[@]})); then
      uvx --from pre-commit==4.5.1 python "$SCRIPT_DIR/scripts/format-pending.py" "refs/remotes/origin/$BRANCH" "${FORMAT_HOOKS[@]}"
    fi

    # Check if there are changes
    if [[ -n $(git status --porcelain) ]]; then
      validate_repo_before_commit

      if [[ -z $(git status --porcelain) ]]; then
        echo "No changes after validation cleanup."
      else
        echo "Changes detected. Committing..."
        git add .
        git commit -m "$COMMIT_MSG"
      fi
    else
      echo "No uncommitted changes."
    fi

    # A clean worktree may already contain local commits. The preceding
    # sync guarantees a fast-forward relationship; a normal push also
    # rejects concurrent remote changes rather than rewriting history.
    if [[ $(git rev-parse HEAD) != $(git rev-parse "refs/remotes/origin/$BRANCH") ]]; then
      echo "Pushing to origin/$BRANCH..."
      git push origin "$BRANCH"
    else
      echo "Already synchronized with origin/$BRANCH."
    fi

    cd "$TARGET_DIR"
  fi
done

echo "Done."
