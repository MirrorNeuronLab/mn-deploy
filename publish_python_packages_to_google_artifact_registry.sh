#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INDEX_FILE="${MN_PACKAGE_INDEX_FILE:-${SCRIPT_DIR}/package-index/python-packages.toml}"
PROJECT="${MN_GAR_PROJECT:-}"
LOCATION="${MN_GAR_LOCATION:-us-central1}"
REPOSITORY="${MN_GAR_REPOSITORY:-mirrorneuron-python}"
PUBLISH_VENV="${MN_GAR_PUBLISH_VENV:-${SCRIPT_DIR}/.venv-gar-publish}"
if [ -x "${PUBLISH_VENV}/bin/python" ]; then
    PYTHON_BIN="${MN_PUBLISH_PYTHON:-${PUBLISH_VENV}/bin/python}"
else
    PYTHON_BIN="${MN_PUBLISH_PYTHON:-python3}"
fi
GCLOUD_BIN="${MN_GCLOUD_BIN:-gcloud}"
DIST_DIR="${MN_PYTHON_DIST_DIR:-${SCRIPT_DIR}/dist/python-packages}"
LOCAL_INDEX_DIR="${MN_LOCAL_PYTHON_INDEX_DIR:-${SCRIPT_DIR}/local-python-index}"
APPLY="N"

usage() {
    cat <<EOF
Usage: ./publish_python_packages_to_google_artifact_registry.sh [options]

Build indexed MirrorNeuron Python packages, generate a local simple index, and
sync package names to Google Artifact Registry.

Defaults to dry-run. Pass --apply to upload and delete stale GAR package names.

Options:
  --apply                Upload packages and delete stale GAR package names.
  --project PROJECT      Google Cloud project ID. Env: MN_GAR_PROJECT.
  --location LOCATION    GAR location. Env: MN_GAR_LOCATION. Default: us-central1.
  --repository NAME      GAR Python repository. Env: MN_GAR_REPOSITORY. Default: mirrorneuron-python.
  --index-file PATH      Local package index. Env: MN_PACKAGE_INDEX_FILE.
  --dist-dir PATH        Distribution output dir. Env: MN_PYTHON_DIST_DIR.
  --local-index-dir PATH Local PEP 503 simple index dir. Env: MN_LOCAL_PYTHON_INDEX_DIR.
  --python PATH          Python with build/twine installed. Env: MN_PUBLISH_PYTHON.
  -h, --help             Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply) APPLY="Y" ;;
        --project)
            shift
            [ "$#" -gt 0 ] || { echo "--project requires a value." >&2; exit 1; }
            PROJECT="$1"
            ;;
        --project=*) PROJECT="${1#*=}" ;;
        --location)
            shift
            [ "$#" -gt 0 ] || { echo "--location requires a value." >&2; exit 1; }
            LOCATION="$1"
            ;;
        --location=*) LOCATION="${1#*=}" ;;
        --repository)
            shift
            [ "$#" -gt 0 ] || { echo "--repository requires a value." >&2; exit 1; }
            REPOSITORY="$1"
            ;;
        --repository=*) REPOSITORY="${1#*=}" ;;
        --index-file)
            shift
            [ "$#" -gt 0 ] || { echo "--index-file requires a value." >&2; exit 1; }
            INDEX_FILE="$1"
            ;;
        --index-file=*) INDEX_FILE="${1#*=}" ;;
        --dist-dir)
            shift
            [ "$#" -gt 0 ] || { echo "--dist-dir requires a value." >&2; exit 1; }
            DIST_DIR="$1"
            ;;
        --dist-dir=*) DIST_DIR="${1#*=}" ;;
        --local-index-dir)
            shift
            [ "$#" -gt 0 ] || { echo "--local-index-dir requires a value." >&2; exit 1; }
            LOCAL_INDEX_DIR="$1"
            ;;
        --local-index-dir=*) LOCAL_INDEX_DIR="${1#*=}" ;;
        --python)
            shift
            [ "$#" -gt 0 ] || { echo "--python requires a value." >&2; exit 1; }
            PYTHON_BIN="$1"
            ;;
        --python=*) PYTHON_BIN="${1#*=}" ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

if [ -z "$PROJECT" ]; then
    echo "A Google Cloud project is required. Pass --project or set MN_GAR_PROJECT." >&2
    exit 1
fi
if [ ! -f "$INDEX_FILE" ]; then
    echo "Package index was not found: $INDEX_FILE" >&2
    exit 1
fi
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    echo "Python command '$PYTHON_BIN' was not found." >&2
    exit 1
fi
if ! command -v "$GCLOUD_BIN" >/dev/null 2>&1; then
    echo "'$GCLOUD_BIN' is required to compare and prune GAR packages." >&2
    exit 1
fi

REPOSITORY_URL="https://${LOCATION}-python.pkg.dev/${PROJECT}/${REPOSITORY}/"
SIMPLE_URL="${REPOSITORY_URL}simple/"
PACKAGE_ROWS="$(mktemp "${TMPDIR:-/tmp}/mn-package-index.XXXXXX")"
INDEXED_NAMES="$(mktemp "${TMPDIR:-/tmp}/mn-package-names.XXXXXX")"
REMOTE_NAMES="$(mktemp "${TMPDIR:-/tmp}/mn-remote-package-names.XXXXXX")"
cleanup() {
    rm -f "$PACKAGE_ROWS" "$INDEXED_NAMES" "$REMOTE_NAMES"
}
trap cleanup EXIT

"$PYTHON_BIN" - "$INDEX_FILE" "$WORKSPACE_ROOT" > "$PACKAGE_ROWS" <<'PY'
from __future__ import annotations

import sys
import tomllib
from pathlib import Path

index_file = Path(sys.argv[1])
workspace_root = Path(sys.argv[2])
data = tomllib.loads(index_file.read_text())
packages = data.get("packages", [])
if not packages:
    raise SystemExit(f"No packages found in {index_file}")
seen = set()
for package in packages:
    name = package["name"]
    path = workspace_root / package["path"]
    if name in seen:
        raise SystemExit(f"Duplicate package in index: {name}")
    seen.add(name)
    if not (path / "pyproject.toml").exists():
        raise SystemExit(f"Indexed package is missing pyproject.toml: {name} at {path}")
    print(f"{name}\t{path}")
PY

cut -f1 "$PACKAGE_ROWS" | sort -u > "$INDEXED_NAMES"

echo "Building indexed Python packages from $INDEX_FILE."
rm -rf "$DIST_DIR" "$LOCAL_INDEX_DIR"
mkdir -p "$DIST_DIR" "$LOCAL_INDEX_DIR"

while IFS="$(printf '\t')" read -r package_name package_path; do
    [ -n "$package_name" ] || continue
    echo "Building ${package_name} from ${package_path}."
    "$PYTHON_BIN" -m build "$package_path" --outdir "$DIST_DIR"
done < "$PACKAGE_ROWS"

echo "Checking distributions."
"$PYTHON_BIN" -m twine check "$DIST_DIR"/*

echo "Generating local simple index at ${LOCAL_INDEX_DIR}."
"$PYTHON_BIN" - "$INDEX_FILE" "$DIST_DIR" "$LOCAL_INDEX_DIR" > /dev/null <<'PY'
from __future__ import annotations

import html
import re
import sys
import tomllib
from pathlib import Path

index_file = Path(sys.argv[1])
dist_dir = Path(sys.argv[2])
local_index_dir = Path(sys.argv[3])
simple_dir = local_index_dir / "simple"
data = tomllib.loads(index_file.read_text())
packages = data.get("packages", [])

def canonical(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()

def distribution_name(path: Path) -> str:
    name = path.name
    if name.endswith(".tar.gz"):
        name = name[:-7]
    else:
        name = path.stem
    return name.split("-", 1)[0]

files_by_package: dict[str, list[Path]] = {canonical(pkg["name"]): [] for pkg in packages}
for artifact in sorted(dist_dir.iterdir()):
    if artifact.suffix not in {".whl", ".gz", ".zip"}:
        continue
    key = canonical(distribution_name(artifact))
    files_by_package.setdefault(key, []).append(artifact)

simple_dir.mkdir(parents=True, exist_ok=True)
root_links = []
for package in packages:
    canonical_name = canonical(package["name"])
    package_dir = simple_dir / canonical_name
    package_dir.mkdir(parents=True, exist_ok=True)
    root_links.append(f'<a href="{canonical_name}/">{html.escape(package["name"])}</a>')
    links = []
    for artifact in files_by_package.get(canonical_name, []):
        target = package_dir / artifact.name
        target.write_bytes(artifact.read_bytes())
        escaped = html.escape(artifact.name)
        links.append(f'<a href="{escaped}">{escaped}</a>')
    (package_dir / "index.html").write_text(
        "<!doctype html>\n<html><body>\n" + "\n".join(links) + "\n</body></html>\n",
        encoding="utf-8",
    )

(simple_dir / "index.html").write_text(
    "<!doctype html>\n<html><body>\n" + "\n".join(root_links) + "\n</body></html>\n",
    encoding="utf-8",
)
(local_index_dir / "packages.txt").write_text(
    "\n".join(package["name"] for package in packages) + "\n",
    encoding="utf-8",
)
PY

if [ "$APPLY" = "Y" ]; then
    echo "Uploading distributions to ${REPOSITORY_URL}."
    "$PYTHON_BIN" -m twine upload --repository-url "$REPOSITORY_URL" --skip-existing "$DIST_DIR"/*
else
    echo "DRY RUN: would upload distributions to ${REPOSITORY_URL}."
fi

echo "Listing packages currently in GAR."
"$GCLOUD_BIN" artifacts packages list \
    --project="$PROJECT" \
    --repository="$REPOSITORY" \
    --location="$LOCATION" \
    --format='value(name)' \
    | awk -F/ 'NF {print $NF}' \
    | sort -u > "$REMOTE_NAMES"

stale_count=0
while IFS= read -r remote_package; do
    [ -n "$remote_package" ] || continue
    if grep -Fxq "$remote_package" "$INDEXED_NAMES"; then
        continue
    fi
    stale_count=$((stale_count + 1))
    if [ "$APPLY" = "Y" ]; then
        echo "Deleting stale GAR package ${remote_package}."
        "$GCLOUD_BIN" artifacts packages delete "$remote_package" \
            --project="$PROJECT" \
            --repository="$REPOSITORY" \
            --location="$LOCATION" \
            --quiet
    else
        echo "DRY RUN: would delete stale GAR package ${remote_package}."
    fi
done < "$REMOTE_NAMES"

echo ""
echo "Indexed packages: $(wc -l < "$INDEXED_NAMES" | tr -d ' ')"
echo "Stale remote packages: ${stale_count}"
echo "Local simple index: ${LOCAL_INDEX_DIR}/simple/"
echo "GAR simple index: ${SIMPLE_URL}"
if [ "$APPLY" != "Y" ]; then
    echo "Dry run complete. Re-run with --apply to upload and prune."
fi
