#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${MN_GAR_PROJECT:-}"
LOCATION="${MN_GAR_LOCATION:-us-central1}"
REPOSITORY="${MN_GAR_REPOSITORY:-mirrorneuron-python}"
VENV_DIR="${MN_GAR_PUBLISH_VENV:-${SCRIPT_DIR}/.venv-gar-publish}"
PYTHON_BIN="${MN_GAR_SETUP_PYTHON:-python3}"

usage() {
    cat <<EOF
Usage: ./setup_google_artifact_registry.sh --project PROJECT [options]

Prepare Google Artifact Registry for MirrorNeuron Python packages.

Options:
  --project PROJECT       Google Cloud project ID. Env: MN_GAR_PROJECT.
  --location LOCATION     GAR location. Env: MN_GAR_LOCATION. Default: us-central1.
  --repository NAME       GAR Python repository. Env: MN_GAR_REPOSITORY. Default: mirrorneuron-python.
  --venv PATH             Local publishing venv. Env: MN_GAR_PUBLISH_VENV.
  --python PATH           Python used to create the publishing venv.
  -h, --help              Show this help.

Manual auth commands, if needed:
  gcloud auth login
  gcloud auth application-default login
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
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
        --venv)
            shift
            [ "$#" -gt 0 ] || { echo "--venv requires a value." >&2; exit 1; }
            VENV_DIR="$1"
            ;;
        --venv=*) VENV_DIR="${1#*=}" ;;
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

if ! command -v gcloud >/dev/null 2>&1; then
    echo "'gcloud' is required. Install and initialize Google Cloud CLI first." >&2
    exit 1
fi

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    echo "Python command '$PYTHON_BIN' was not found." >&2
    exit 1
fi

active_account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1 || true)"
if [ -z "$active_account" ]; then
    cat >&2 <<EOF
No active gcloud user account was found.
Run:
  gcloud auth login
  gcloud auth application-default login
EOF
    exit 1
fi

if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
    cat >&2 <<EOF
Application Default Credentials are not available.
Run:
  gcloud auth application-default login
EOF
    exit 1
fi

echo "Enabling Artifact Registry API for project ${PROJECT}."
gcloud services enable artifactregistry.googleapis.com --project="$PROJECT"

if gcloud artifacts repositories describe "$REPOSITORY" \
    --project="$PROJECT" \
    --location="$LOCATION" >/dev/null 2>&1; then
    echo "Artifact Registry repository ${REPOSITORY} already exists in ${LOCATION}."
else
    echo "Creating Python Artifact Registry repository ${REPOSITORY} in ${LOCATION}."
    gcloud artifacts repositories create "$REPOSITORY" \
        --repository-format=python \
        --project="$PROJECT" \
        --location="$LOCATION" \
        --description="MirrorNeuron Python packages"
fi

echo "Preparing local publishing virtualenv at ${VENV_DIR}."
"$PYTHON_BIN" -m venv "$VENV_DIR"
"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/python" -m pip install --upgrade \
    build \
    twine \
    keyring \
    keyrings.google-artifactregistry-auth

echo ""
echo "Google Artifact Registry Python repository is ready."
echo "Repository URL: https://${LOCATION}-python.pkg.dev/${PROJECT}/${REPOSITORY}/"
echo "Pip index URL: https://${LOCATION}-python.pkg.dev/${PROJECT}/${REPOSITORY}/simple/"
echo ""
echo "Publish dry run:"
echo "  MN_GAR_PROJECT=${PROJECT} MN_GAR_LOCATION=${LOCATION} MN_GAR_REPOSITORY=${REPOSITORY} ./publish_python_packages_to_google_artifact_registry.sh"
echo ""
echo "Publish and prune:"
echo "  MN_GAR_PROJECT=${PROJECT} MN_GAR_LOCATION=${LOCATION} MN_GAR_REPOSITORY=${REPOSITORY} ./publish_python_packages_to_google_artifact_registry.sh --apply"
