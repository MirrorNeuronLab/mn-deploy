#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INDEX_FILE="${MN_PACKAGE_INDEX_FILE:-${SCRIPT_DIR}/package-index/python-packages.toml}"
PROJECT="${MN_GAR_PROJECT:-}"
LOCATION="${MN_GAR_LOCATION:-us-central1}"
REPOSITORY="${MN_GAR_REPOSITORY:-agent-skills}"
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
PRUNE="Y"

usage() {
    cat <<EOF
Usage: ./publish_python_packages_to_google_artifact_registry.sh [options]

Build indexed MirrorNeuron Python packages, generate a local simple index, and
sync package names to Google Artifact Registry.

Defaults to dry-run. Pass --apply to upload and delete stale GAR package names.

Options:
  --apply                Upload packages and delete stale GAR package names.
  --no-prune             Upload packages without deleting unrelated GAR package names.
  --project PROJECT      Google Cloud project ID. Env: MN_GAR_PROJECT.
  --location LOCATION    GAR location. Env: MN_GAR_LOCATION. Default: us-central1.
  --repository NAME      GAR Python repository. Env: MN_GAR_REPOSITORY. Default: agent-skills.
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
        --no-prune) PRUNE="N" ;;
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
LOCAL_ARTIFACTS="$(mktemp "${TMPDIR:-/tmp}/mn-local-artifacts.XXXXXX")"
REMOTE_FILES="$(mktemp "${TMPDIR:-/tmp}/mn-remote-files.XXXXXX")"
UPLOAD_ARTIFACTS="$(mktemp "${TMPDIR:-/tmp}/mn-upload-artifacts.XXXXXX")"
REMOTE_NAMES="$(mktemp "${TMPDIR:-/tmp}/mn-remote-package-names.XXXXXX")"
cleanup() {
    rm -f "$PACKAGE_ROWS" "$INDEXED_NAMES" "$LOCAL_ARTIFACTS" "$REMOTE_FILES" "$UPLOAD_ARTIFACTS" "$REMOTE_NAMES"
}
trap cleanup EXIT

"$PYTHON_BIN" - "$INDEX_FILE" "$WORKSPACE_ROOT" > "$PACKAGE_ROWS" <<'PY'
from __future__ import annotations

import sys
import tomllib
import re
from pathlib import Path

def canonical(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()

def normalize_version(value: object) -> str:
    text = str(value or "").strip()
    if text.lower().startswith("v"):
        text = text[1:]
    return text

def load_project_name(package_path: Path) -> str:
    pyproject = package_path / "pyproject.toml"
    if not pyproject.exists():
        raise FileNotFoundError(pyproject)
    try:
        data = tomllib.loads(pyproject.read_text())
    except tomllib.TOMLDecodeError as exc:
        raise SystemExit(f"Invalid pyproject.toml at {pyproject}: {exc}") from exc
    project_name = data.get("project", {}).get("name")
    if not project_name:
        raise SystemExit(f"pyproject.toml is missing project.name: {pyproject}")
    return project_name

def find_package_path(workspace_root: Path, configured_path: Path, canonical_name: str) -> Path | None:
    search_root = configured_path.parent
    while not search_root.exists() and search_root != workspace_root:
        search_root = search_root.parent
    if not search_root.exists() or workspace_root not in (search_root, *search_root.parents):
        search_root = workspace_root

    matches = []
    for pyproject in search_root.rglob("pyproject.toml"):
        if any(part.startswith(".") for part in pyproject.relative_to(search_root).parts):
            continue
        package_path = pyproject.parent
        if canonical(load_project_name(package_path)) == canonical_name:
            matches.append(package_path)
    if len(matches) > 1:
        rendered = ", ".join(str(match) for match in sorted(matches))
        raise SystemExit(f"Indexed package path is ambiguous for {canonical_name}: {rendered}")
    return matches[0] if matches else None

index_file = Path(sys.argv[1])
workspace_root = Path(sys.argv[2])
data = tomllib.loads(index_file.read_text())
packages = data.get("packages", [])
if not packages:
    raise SystemExit(f"No packages found in {index_file}")
seen = set()
for package in packages:
    name = package["name"]
    canonical_name = canonical(name)
    path = workspace_root / package["path"]
    build_formats = package.get("build_formats") or ["sdist", "wheel"]
    version = normalize_version(package.get("version"))
    if canonical_name in seen:
        raise SystemExit(f"Duplicate package in index: {name}")
    seen.add(canonical_name)
    if not (path / "pyproject.toml").exists():
        resolved_path = find_package_path(workspace_root, path, canonical_name)
        if resolved_path is None:
            raise SystemExit(f"Indexed package is missing pyproject.toml: {name} at {path}")
        print(f"Resolved indexed package path for {name}: {path} -> {resolved_path}", file=sys.stderr)
        path = resolved_path
    project_name = load_project_name(path)
    if canonical(project_name) != canonical_name:
        raise SystemExit(f"Indexed package name/path mismatch: {name} at {path} declares {project_name}")
    unknown_formats = sorted(set(build_formats) - {"sdist", "wheel"})
    if unknown_formats:
        raise SystemExit(f"Unknown build_formats for {name}: {', '.join(unknown_formats)}")
    if not build_formats:
        raise SystemExit(f"build_formats must not be empty for {name}")
    print(f"{name}\t{path}\t{','.join(build_formats)}\t{version}")
PY

"$PYTHON_BIN" - "$PACKAGE_ROWS" > "$INDEXED_NAMES" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

package_rows = Path(sys.argv[1])

def canonical(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()

for line in package_rows.read_text().splitlines():
    if not line:
        continue
    package_name = line.split("\t", 1)[0]
    print(canonical(package_name))
PY
sort -u "$INDEXED_NAMES" -o "$INDEXED_NAMES"

echo "Building indexed Python packages from $INDEX_FILE."
rm -rf "$DIST_DIR" "$LOCAL_INDEX_DIR"
mkdir -p "$DIST_DIR" "$LOCAL_INDEX_DIR"

while IFS="$(printf '\t')" read -r package_name package_path build_formats package_version; do
    [ -n "$package_name" ] || continue
    build_args=()
    case ",${build_formats}," in
        *,sdist,*) build_args+=(--sdist) ;;
    esac
    case ",${build_formats}," in
        *,wheel,*) build_args+=(--wheel) ;;
    esac
    version_label=""
    if [ -n "$package_version" ]; then
        version_label=" version ${package_version}"
    fi
    echo "Building ${package_name}${version_label} from ${package_path} (${build_formats})."
    rm -rf "${package_path}/build"
    if [ -n "$package_version" ] && [ "$package_name" = "mirrorneuron-membrane-python-sdk" ]; then
        MEMBRANE_PYTHON_SDK_VERSION="$package_version" "$PYTHON_BIN" -m build "$package_path" --outdir "$DIST_DIR" "${build_args[@]}"
    elif [ -n "$package_version" ]; then
        SETUPTOOLS_SCM_PRETEND_VERSION="$package_version" "$PYTHON_BIN" -m build "$package_path" --outdir "$DIST_DIR" "${build_args[@]}"
    else
        "$PYTHON_BIN" -m build "$package_path" --outdir "$DIST_DIR" "${build_args[@]}"
    fi
done < "$PACKAGE_ROWS"

echo "Checking distributions."
"$PYTHON_BIN" -m twine check "$DIST_DIR"/*

echo "Indexing local distribution files."
"$PYTHON_BIN" - "$INDEX_FILE" "$DIST_DIR" > "$LOCAL_ARTIFACTS" <<'PY'
from __future__ import annotations

import sys
import tomllib
from pathlib import Path

from packaging.utils import canonicalize_name, parse_sdist_filename, parse_wheel_filename
from packaging.version import Version

index_file = Path(sys.argv[1])
dist_dir = Path(sys.argv[2])
data = tomllib.loads(index_file.read_text())
indexed_packages = {
    canonicalize_name(package["name"]): package["name"]
    for package in data.get("packages", [])
}
expected_versions = {
    canonicalize_name(package["name"]): str(package["version"]).lstrip("vV")
    for package in data.get("packages", [])
    if package.get("version")
}

for artifact in sorted(dist_dir.iterdir()):
    if artifact.suffix == ".whl":
        name, version, *_ = parse_wheel_filename(artifact.name)
    elif artifact.name.endswith((".tar.gz", ".zip")):
        name, version = parse_sdist_filename(artifact.name)
    else:
        continue
    canonical_name = canonicalize_name(name)
    package_name = indexed_packages.get(canonical_name)
    if package_name is None:
        raise SystemExit(f"Built artifact is not in the package index: {artifact.name}")
    expected_version = expected_versions.get(canonical_name)
    if expected_version and version != Version(expected_version):
        raise SystemExit(
            f"Built artifact has wrong version for {package_name}: "
            f"{artifact.name} declares {version}, expected {expected_version}"
        )
    print(f"{package_name}\t{artifact}\t{artifact.name}")
PY

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

echo "Listing distribution files currently in GAR."
: > "$REMOTE_FILES"
while IFS="$(printf '\t')" read -r package_name _package_path _build_formats _package_version; do
    [ -n "$package_name" ] || continue
    "$GCLOUD_BIN" artifacts files list \
        --project="$PROJECT" \
        --repository="$REPOSITORY" \
        --location="$LOCATION" \
        --package="$package_name" \
        --format='value(name)' \
        | awk -F/ -v package="$package_name" 'NF {print package "\t" $NF}' \
        >> "$REMOTE_FILES"
done < "$PACKAGE_ROWS"
sort -u "$REMOTE_FILES" -o "$REMOTE_FILES"

"$PYTHON_BIN" - "$LOCAL_ARTIFACTS" "$REMOTE_FILES" > "$UPLOAD_ARTIFACTS" <<'PY'
from __future__ import annotations

import sys
from pathlib import Path

local_artifacts = Path(sys.argv[1])
remote_files = Path(sys.argv[2])

remote = set()
for line in remote_files.read_text().splitlines():
    if not line:
        continue
    package_name, filename = line.split("\t", 1)
    remote.add((package_name, filename))

for line in local_artifacts.read_text().splitlines():
    if not line:
        continue
    package_name, artifact_path, filename = line.split("\t", 2)
    if (package_name, filename) not in remote:
        print(artifact_path)
PY

local_artifact_count="$(wc -l < "$LOCAL_ARTIFACTS" | tr -d ' ')"
upload_artifact_count="$(wc -l < "$UPLOAD_ARTIFACTS" | tr -d ' ')"
skipped_artifact_count=$((local_artifact_count - upload_artifact_count))

if [ "$APPLY" = "Y" ]; then
    if [ "$upload_artifact_count" -gt 0 ]; then
        echo "Uploading ${upload_artifact_count} missing distribution(s) to ${REPOSITORY_URL}."
        upload_artifacts=()
        while IFS= read -r artifact_path; do
            [ -n "$artifact_path" ] || continue
            upload_artifacts+=("$artifact_path")
        done < "$UPLOAD_ARTIFACTS"
        GOOGLE_CLOUD_PROJECT="$PROJECT" "$PYTHON_BIN" -m twine upload --repository-url "$REPOSITORY_URL" "${upload_artifacts[@]}"
    else
        echo "No missing distributions to upload to ${REPOSITORY_URL}."
    fi
else
    echo "DRY RUN: would upload ${upload_artifact_count} missing distribution(s) to ${REPOSITORY_URL}."
fi
echo "Already published distributions: ${skipped_artifact_count}"

echo "Listing packages currently in GAR."
"$GCLOUD_BIN" artifacts packages list \
    --project="$PROJECT" \
    --repository="$REPOSITORY" \
    --location="$LOCATION" \
    --format='value(name)' \
    | "$PYTHON_BIN" -c 'import re, sys
def canonical(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()
for line in sys.stdin:
    package_name = line.rsplit("/", 1)[-1].strip()
    if package_name:
        print(f"{canonical(package_name)}\t{package_name}")' \
    | sort -u > "$REMOTE_NAMES"

stale_count=0
while IFS="$(printf '\t')" read -r remote_canonical_name remote_package; do
    [ -n "$remote_package" ] || continue
    if grep -Fxq "$remote_canonical_name" "$INDEXED_NAMES"; then
        continue
    fi
    stale_count=$((stale_count + 1))
    if [ "$APPLY" = "Y" ] && [ "$PRUNE" = "Y" ]; then
        echo "Deleting stale GAR package ${remote_package}."
        "$GCLOUD_BIN" artifacts packages delete "$remote_package" \
            --project="$PROJECT" \
            --repository="$REPOSITORY" \
            --location="$LOCATION" \
            --quiet
    elif [ "$APPLY" = "Y" ]; then
        echo "Skipping stale GAR package \${remote_package} (--no-prune)."
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
