#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${MN_GAR_PROJECT:-mirrorneuron-public-packages}"
LOCATION="${MN_GAR_LOCATION:-us-central1}"
REPOSITORY="${MN_GAR_NPM_REPOSITORY:-mirrorneuron-npm}"
WEB_UI_DIR="${MN_WEB_UI_DIR:-${WORKSPACE_ROOT}/mn-web-ui}"
DIST_DIR="${MN_WEB_UI_DIST_DIR:-${SCRIPT_DIR}/dist/web-ui}"
NPM_BIN="${MN_NPM_BIN:-npm}"
GCLOUD_BIN="${MN_GCLOUD_BIN:-gcloud}"
NODE_BIN="${MN_NODE_BIN:-node}"
VERSION=""
APPLY="N"
SKIP_BUILD="N"

usage() {
  cat <<'EOF'
Usage: publish_web_ui_to_google_artifact_registry.sh --version VERSION [options]

Build a self-contained mirrorneuron-web-ui npm package from the local checkout
and publish it to Google Artifact Registry. GitHub workflow artifacts are not inputs. The public npm registry is used only
for third-party build dependencies.

Options:
  --version VERSION       Package version, with or without a leading v.
  --apply                 Publish after building; otherwise perform a dry run.
  --skip-build            Package an existing WEB_UI_DIR/dist directory.
  --project PROJECT       GAR project. Default: mirrorneuron-public-packages.
  --location LOCATION     GAR location. Default: us-central1.
  --repository NAME       GAR npm repository. Default: mirrorneuron-npm.
  --web-ui-dir PATH       Local mn-web-ui checkout.
  --dist-dir PATH         Output directory for the npm tarball.
  -h, --help              Show this help.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --version) shift; [[ "$#" -gt 0 ]] || die "--version requires a value."; VERSION="$1" ;;
    --version=*) VERSION="${1#*=}" ;;
    --apply) APPLY="Y" ;;
    --skip-build) SKIP_BUILD="Y" ;;
    --project) shift; [[ "$#" -gt 0 ]] || die "--project requires a value."; PROJECT="$1" ;;
    --project=*) PROJECT="${1#*=}" ;;
    --location) shift; [[ "$#" -gt 0 ]] || die "--location requires a value."; LOCATION="$1" ;;
    --location=*) LOCATION="${1#*=}" ;;
    --repository) shift; [[ "$#" -gt 0 ]] || die "--repository requires a value."; REPOSITORY="$1" ;;
    --repository=*) REPOSITORY="${1#*=}" ;;
    --web-ui-dir) shift; [[ "$#" -gt 0 ]] || die "--web-ui-dir requires a value."; WEB_UI_DIR="$1" ;;
    --web-ui-dir=*) WEB_UI_DIR="${1#*=}" ;;
    --dist-dir) shift; [[ "$#" -gt 0 ]] || die "--dist-dir requires a value."; DIST_DIR="$1" ;;
    --dist-dir=*) DIST_DIR="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  die "--version must be MAJOR.MINOR.PATCH."
[[ -f "${WEB_UI_DIR}/package.json" ]] || die "Web UI checkout is invalid: ${WEB_UI_DIR}"
command -v "$NPM_BIN" >/dev/null 2>&1 || die "npm was not found: ${NPM_BIN}"
command -v "$NODE_BIN" >/dev/null 2>&1 || die "Node.js was not found: ${NODE_BIN}"

if [[ "$SKIP_BUILD" != "Y" ]]; then
  (cd "$WEB_UI_DIR" && "$NPM_BIN" ci && "$NPM_BIN" run build)
fi
[[ -f "${WEB_UI_DIR}/dist/index.html" ]] || die "Web UI build output is missing: ${WEB_UI_DIR}/dist"

stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/mn-web-ui-package.XXXXXX")"
npmrc="$(mktemp "${TMPDIR:-/tmp}/mn-web-ui-npmrc.XXXXXX")"
cleanup() {
  rm -rf "$stage_dir"
  rm -f "$npmrc"
}
trap cleanup EXIT

cp -R "${WEB_UI_DIR}/dist" "${stage_dir}/dist"
for file in README.md LICENSE; do
  [[ -f "${WEB_UI_DIR}/${file}" ]] && cp "${WEB_UI_DIR}/${file}" "${stage_dir}/${file}"
done

"$NODE_BIN" - "${WEB_UI_DIR}/package.json" "${stage_dir}/package.json" "$VERSION" <<'JS'
const fs = require("node:fs");
const source = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const packageJson = {
  name: source.name,
  version: process.argv[4],
  description: source.description || "MirrorNeuron web UI dashboard.",
  license: source.license || "MIT",
  type: "module",
  files: ["dist", "README.md", "LICENSE"],
};
fs.writeFileSync(process.argv[3], JSON.stringify(packageJson, null, 2) + "\n");
JS

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
DIST_DIR="$(cd "$DIST_DIR" && pwd)"
tarball_name="$(cd "$stage_dir" && "$NPM_BIN" pack --silent --pack-destination "$DIST_DIR")"
tarball="${DIST_DIR}/${tarball_name}"
[[ -f "$tarball" ]] || die "npm pack did not produce ${tarball}"
integrity="$("$NODE_BIN" - "$tarball" <<'JS'
const crypto = require("node:crypto");
const fs = require("node:fs");
const digest = crypto.createHash("sha512").update(fs.readFileSync(process.argv[2])).digest("base64");
process.stdout.write("sha512-" + digest);
JS
)"

registry="https://${LOCATION}-npm.pkg.dev/${PROJECT}/${REPOSITORY}/"
printf 'Built %s with integrity %s.\n' "$tarball" "$integrity"

if [[ "$APPLY" != "Y" ]]; then
  printf 'DRY RUN: would publish mirrorneuron-web-ui@%s to %s\n' "$VERSION" "$registry"
  exit 0
fi

command -v "$GCLOUD_BIN" >/dev/null 2>&1 || die "gcloud was not found: ${GCLOUD_BIN}"
format="$($GCLOUD_BIN artifacts repositories describe "$REPOSITORY" \
  --project="$PROJECT" --location="$LOCATION" --format='value(format)' 2>/dev/null || true)"
[[ "$format" == "NPM" ]] ||
  die "GAR npm repository ${REPOSITORY} was not found. Run setup_google_artifact_registry.sh first."
token="$($GCLOUD_BIN auth print-access-token)"
[[ -n "$token" ]] || die "Could not obtain a Google Cloud access token."
chmod 600 "$npmrc"
cat > "$npmrc" <<EOF
registry=${registry}
//${LOCATION}-npm.pkg.dev/${PROJECT}/${REPOSITORY}/:_authToken=${token}
always-auth=true
EOF
unset token

remote_integrity="$($NPM_BIN view "mirrorneuron-web-ui@${VERSION}" dist.integrity \
  --registry="$registry" --userconfig="$npmrc" 2>/dev/null || true)"
if [[ -n "$remote_integrity" && "$remote_integrity" != "$integrity" ]]; then
  die "GAR already contains mirrorneuron-web-ui@${VERSION} with different content."
fi
if [[ -z "$remote_integrity" ]]; then
  "$NPM_BIN" publish "$tarball" --tag latest --registry="$registry" --userconfig="$npmrc"
fi
remote_integrity="$($NPM_BIN view "mirrorneuron-web-ui@${VERSION}" dist.integrity \
  --registry="$registry" --userconfig="$npmrc")"
[[ "$remote_integrity" == "$integrity" ]] || die "GAR Web UI integrity verification failed."
printf 'Published and verified mirrorneuron-web-ui@%s in GAR.\n' "$VERSION"
