#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT="${MN_GAR_PROJECT:-mirrorneuron-public-packages}"
LOCATION="${MN_GAR_LOCATION:-us-central1}"
REPOSITORY="${MN_OTTERDESK_GAR_REPOSITORY:-otterdesk-desktop}"
PACKAGE="${MN_OTTERDESK_GAR_PACKAGE:-otterdesk}"
OTTERDESK_DIR="${MN_OTTERDESK_DIR:-${WORKSPACE_ROOT}/otterdesk-desktop-app}"
DIST_DIR="${MN_OTTERDESK_DIST_DIR:-${OTTERDESK_DIR}/dist}"
STAGING_DIR="${MN_OTTERDESK_STAGING_DIR:-${SCRIPT_DIR}/dist/otterdesk-gar}"
VERSION="${MN_OTTERDESK_VERSION:-${MN_PACKAGE_VERSION:-}}"
GCLOUD_BIN="${MN_GCLOUD_BIN:-gcloud}"
NPM_BIN="${MN_NPM_BIN:-npm}"
BUILD_COMMAND="${MN_OTTERDESK_BUILD_COMMAND:-dist:mac}"
APPLY="N"
BUILD_ARTIFACTS="N"

usage() {
    cat <<EOF
Usage: ./publish_public_otterdesk_to_google_artifact_registry.sh [options]

Publish public Otterdesk desktop application packages to Google Artifact
Registry using the public MirrorNeuron package project.

Defaults to dry-run and uploads existing files from the Otterdesk dist/
directory. Pass --build to run an Electron package build first, and --apply to
create the GAR repository, grant public read, and upload artifacts.

Options:
  --apply                    Publish artifacts. Default is dry-run.
  --build                    Run npm build/package command before staging.
  --build-command SCRIPT     npm script to run with --build.
                             Env: MN_OTTERDESK_BUILD_COMMAND.
                             Default: dist:mac.
  --version VERSION          Release version/tag, for example v1.2.8.
                             Env: MN_OTTERDESK_VERSION or MN_PACKAGE_VERSION.
  --project PROJECT          GAR project. Env: MN_GAR_PROJECT.
                             Default: mirrorneuron-public-packages.
  --location LOCATION        GAR location. Env: MN_GAR_LOCATION.
                             Default: us-central1.
  --repository NAME          GAR generic repository.
                             Env: MN_OTTERDESK_GAR_REPOSITORY.
                             Default: otterdesk-desktop.
  --package NAME             GAR generic package name.
                             Env: MN_OTTERDESK_GAR_PACKAGE.
                             Default: otterdesk.
  --otterdesk-dir PATH       Otterdesk checkout. Env: MN_OTTERDESK_DIR.
  --dist-dir PATH            Directory containing desktop release files.
                             Env: MN_OTTERDESK_DIST_DIR.
  --staging-dir PATH         Local staging directory used before upload.
                             Env: MN_OTTERDESK_STAGING_DIR.
  --gcloud PATH              gcloud executable. Env: MN_GCLOUD_BIN.
  --npm PATH                 npm executable. Env: MN_NPM_BIN.
  -h, --help                 Show this help.

Examples:
  ./publish_public_otterdesk_to_google_artifact_registry.sh --version v1.2.8

  ./publish_public_otterdesk_to_google_artifact_registry.sh \\
    --apply \\
    --build \\
    --version v1.2.8
EOF
}

log() {
    printf '%s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

quote_args() {
    local arg
    for arg in "$@"; do
        printf ' %q' "$arg"
    done
    printf '\n'
}

run_or_echo() {
    if [ "$APPLY" = "Y" ]; then
        "$@"
    else
        printf 'DRY RUN:'
        quote_args "$@"
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply) APPLY="Y" ;;
        --build) BUILD_ARTIFACTS="Y" ;;
        --build-command)
            shift
            [ "$#" -gt 0 ] || die "--build-command requires a value."
            BUILD_COMMAND="$1"
            ;;
        --build-command=*) BUILD_COMMAND="${1#*=}" ;;
        --version)
            shift
            [ "$#" -gt 0 ] || die "--version requires a value."
            VERSION="$1"
            ;;
        --version=*) VERSION="${1#*=}" ;;
        --project)
            shift
            [ "$#" -gt 0 ] || die "--project requires a value."
            PROJECT="$1"
            ;;
        --project=*) PROJECT="${1#*=}" ;;
        --location)
            shift
            [ "$#" -gt 0 ] || die "--location requires a value."
            LOCATION="$1"
            ;;
        --location=*) LOCATION="${1#*=}" ;;
        --repository)
            shift
            [ "$#" -gt 0 ] || die "--repository requires a value."
            REPOSITORY="$1"
            ;;
        --repository=*) REPOSITORY="${1#*=}" ;;
        --package)
            shift
            [ "$#" -gt 0 ] || die "--package requires a value."
            PACKAGE="$1"
            ;;
        --package=*) PACKAGE="${1#*=}" ;;
        --otterdesk-dir)
            shift
            [ "$#" -gt 0 ] || die "--otterdesk-dir requires a value."
            OTTERDESK_DIR="$1"
            ;;
        --otterdesk-dir=*) OTTERDESK_DIR="${1#*=}" ;;
        --dist-dir)
            shift
            [ "$#" -gt 0 ] || die "--dist-dir requires a value."
            DIST_DIR="$1"
            ;;
        --dist-dir=*) DIST_DIR="${1#*=}" ;;
        --staging-dir)
            shift
            [ "$#" -gt 0 ] || die "--staging-dir requires a value."
            STAGING_DIR="$1"
            ;;
        --staging-dir=*) STAGING_DIR="${1#*=}" ;;
        --gcloud)
            shift
            [ "$#" -gt 0 ] || die "--gcloud requires a value."
            GCLOUD_BIN="$1"
            ;;
        --gcloud=*) GCLOUD_BIN="${1#*=}" ;;
        --npm)
            shift
            [ "$#" -gt 0 ] || die "--npm requires a value."
            NPM_BIN="$1"
            ;;
        --npm=*) NPM_BIN="${1#*=}" ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
    shift
done

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

normalize_version_tag() {
    local value="$1"
    value="${value#refs/tags/}"
    value="${value#release/}"
    case "$value" in
        v*) printf '%s' "$value" ;;
        *) printf 'v%s' "$value" ;;
    esac
}

infer_version() {
    if [ -n "$VERSION" ]; then
        normalize_version_tag "$VERSION"
        return
    fi

    if [ -f "${OTTERDESK_DIR}/package.json" ] && command_exists node; then
        local package_version
        package_version="$(node -p "require('${OTTERDESK_DIR}/package.json').version" 2>/dev/null || true)"
        if [ -n "$package_version" ]; then
            normalize_version_tag "$package_version"
            return
        fi
    fi

    die "Release version is required. Pass --version v1.2.8 or set MN_OTTERDESK_VERSION."
}

sha256_file() {
    if command_exists sha256sum; then
        sha256sum "$@"
    else
        shasum -a 256 "$@"
    fi
}

require_tools() {
    command_exists "$GCLOUD_BIN" || die "'$GCLOUD_BIN' was not found."
    command_exists find || die "'find' was not found."
    command_exists sort || die "'sort' was not found."
    command_exists sha256sum || command_exists shasum || die "'sha256sum' or 'shasum' is required."
    if [ "$BUILD_ARTIFACTS" = "Y" ]; then
        command_exists "$NPM_BIN" || die "'$NPM_BIN' was not found."
    fi
}

check_gcloud_auth_for_apply() {
    local active_account
    active_account="$("$GCLOUD_BIN" auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1 || true)"
    if [ -z "$active_account" ]; then
        cat >&2 <<EOF
No active gcloud account was found.
Run:
  gcloud auth login
EOF
        exit 1
    fi
    if ! "$GCLOUD_BIN" auth print-access-token >/dev/null 2>&1; then
        cat >&2 <<EOF
gcloud cannot refresh an access token for ${active_account}.
Run:
  gcloud auth login
EOF
        exit 1
    fi
}

ensure_repository_public() {
    if [ "$APPLY" != "Y" ]; then
        run_or_echo "$GCLOUD_BIN" artifacts repositories describe "$REPOSITORY" \
            --project="$PROJECT" \
            --location="$LOCATION"
        run_or_echo "$GCLOUD_BIN" artifacts repositories create "$REPOSITORY" \
            --repository-format=generic \
            --project="$PROJECT" \
            --location="$LOCATION" \
            --description="Otterdesk public desktop application packages"
        run_or_echo "$GCLOUD_BIN" artifacts repositories add-iam-policy-binding "$REPOSITORY" \
            --project="$PROJECT" \
            --location="$LOCATION" \
            --member=allUsers \
            --role=roles/artifactregistry.reader \
            --condition=None \
            --quiet
        return
    fi

    "$GCLOUD_BIN" services enable artifactregistry.googleapis.com --project="$PROJECT"

    if "$GCLOUD_BIN" artifacts repositories describe "$REPOSITORY" \
        --project="$PROJECT" \
        --location="$LOCATION" >/dev/null 2>&1; then
        log "GAR repository ${REPOSITORY} already exists in ${PROJECT}/${LOCATION}."
    else
        log "Creating generic GAR repository ${REPOSITORY} in ${PROJECT}/${LOCATION}."
        "$GCLOUD_BIN" artifacts repositories create "$REPOSITORY" \
            --repository-format=generic \
            --project="$PROJECT" \
            --location="$LOCATION" \
            --description="Otterdesk public desktop application packages"
    fi

    "$GCLOUD_BIN" artifacts repositories add-iam-policy-binding "$REPOSITORY" \
        --project="$PROJECT" \
        --location="$LOCATION" \
        --member=allUsers \
        --role=roles/artifactregistry.reader \
        --condition=None \
        --quiet
}

build_artifacts() {
    if [ "$BUILD_ARTIFACTS" != "Y" ]; then
        return
    fi

    [ -d "$OTTERDESK_DIR" ] || die "Otterdesk directory was not found: $OTTERDESK_DIR"
    run_or_echo "$NPM_BIN" --prefix "$OTTERDESK_DIR" run "$BUILD_COMMAND"
}

stage_artifacts() {
    local version_tag="$1"
    local checksum_file

    [ -d "$DIST_DIR" ] || die "Otterdesk dist directory was not found: $DIST_DIR"

    if [ "$APPLY" = "Y" ]; then
        rm -rf "$STAGING_DIR"
        mkdir -p "$STAGING_DIR"
        while IFS= read -r -d '' artifact; do
            cp "$artifact" "$STAGING_DIR/"
        done < <(
            find "$DIST_DIR" -maxdepth 1 -type f \( \
                -name "*.dmg" -o \
                -name "*.pkg" -o \
                -name "*-mac.zip" -o \
                -name "*.exe" -o \
                -name "*-win.zip" -o \
                -name "*.blockmap" -o \
                -name "latest*.yml" \
            \) ! -name "*.__uninstaller.exe" -print0
        )

        if [ -z "$(find "$STAGING_DIR" -type f -print -quit)" ]; then
            die "No Otterdesk desktop artifacts were found in $DIST_DIR."
        fi

        checksum_file="${STAGING_DIR}/otterdesk-${version_tag}-SHA256SUMS.txt"
        (
            cd "$STAGING_DIR"
            rm -f "$(basename "$checksum_file")"
            while IFS= read -r -d '' file; do
                sha256_file "$file"
            done < <(find . -maxdepth 1 -type f ! -name "*SHA256SUMS.txt" -print0 | sort -z) > "$checksum_file"
        )
    else
        log "DRY RUN: would stage desktop artifacts from ${DIST_DIR} into ${STAGING_DIR}"
        find "$DIST_DIR" -maxdepth 1 -type f \( \
            -name "*.dmg" -o \
            -name "*.pkg" -o \
            -name "*-mac.zip" -o \
            -name "*.exe" -o \
            -name "*-win.zip" -o \
            -name "*.blockmap" -o \
            -name "latest*.yml" \
        \) ! -name "*.__uninstaller.exe" -print | sort || true
        log "DRY RUN: would write otterdesk-${version_tag}-SHA256SUMS.txt"
    fi
}

publish_artifacts() {
    ensure_repository_public

    run_or_echo "$GCLOUD_BIN" artifacts generic upload \
        --project="$PROJECT" \
        --location="$LOCATION" \
        --repository="$REPOSITORY" \
        --package="$PACKAGE" \
        --version="$VERSION_TAG" \
        --source-directory="$STAGING_DIR" \
        --skip-existing
}

VERSION_TAG="$(infer_version)"

if [ -z "$PROJECT" ]; then
    die "GAR project is required."
fi

require_tools

log "Otterdesk public GAR publish"
log "  project: ${PROJECT}"
log "  location: ${LOCATION}"
log "  generic GAR: ${LOCATION}-generic.pkg.dev/${PROJECT}/${REPOSITORY}/${PACKAGE}:${VERSION_TAG}"
log "  otterdesk dir: ${OTTERDESK_DIR}"
log "  dist dir: ${DIST_DIR}"
log "  staging dir: ${STAGING_DIR}"

if [ "$APPLY" = "Y" ]; then
    check_gcloud_auth_for_apply
else
    log "Dry run only. Re-run with --apply to publish."
fi

build_artifacts
stage_artifacts "$VERSION_TAG"
publish_artifacts

log ""
if [ "$APPLY" = "Y" ]; then
    log "Otterdesk GAR publish complete."
else
    log "Dry run complete. Re-run with --apply to publish."
fi
