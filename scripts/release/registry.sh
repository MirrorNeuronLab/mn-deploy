#!/usr/bin/env bash
# Publishers supply the gcloud executable, project and location.

check_gcloud_auth() {
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
  local repository="$1"
  local format="$2"
  local description="$3"

  if [ "$APPLY" != "Y" ]; then
    run_or_echo "$GCLOUD_BIN" artifacts repositories describe "$repository" \
      --project="$PROJECT" \
      --location="$LOCATION"
    run_or_echo "$GCLOUD_BIN" artifacts repositories create "$repository" \
      --repository-format="$format" \
      --project="$PROJECT" \
      --location="$LOCATION" \
      --description="$description"
    run_or_echo "$GCLOUD_BIN" artifacts repositories add-iam-policy-binding "$repository" \
      --project="$PROJECT" \
      --location="$LOCATION" \
      --member=allUsers \
      --role=roles/artifactregistry.reader \
      --condition=None \
      --quiet
    return
  fi

  "$GCLOUD_BIN" services enable artifactregistry.googleapis.com --project="$PROJECT"

  if "$GCLOUD_BIN" artifacts repositories describe "$repository" \
    --project="$PROJECT" \
    --location="$LOCATION" >/dev/null 2>&1; then
    log "GAR repository ${repository} already exists in ${PROJECT}/${LOCATION}."
  else
    log "Creating ${format} GAR repository ${repository} in ${PROJECT}/${LOCATION}."
    "$GCLOUD_BIN" artifacts repositories create "$repository" \
      --repository-format="$format" \
      --project="$PROJECT" \
      --location="$LOCATION" \
      --description="$description"
  fi

  "$GCLOUD_BIN" artifacts repositories add-iam-policy-binding "$repository" \
    --project="$PROJECT" \
    --location="$LOCATION" \
    --member=allUsers \
    --role=roles/artifactregistry.reader \
    --condition=None \
    --quiet
}

prepare_docker_repository() {
  ensure_repository_public "$DOCKER_REPOSITORY" docker "MirrorNeuron runtime Docker images"
  run_or_echo "$GCLOUD_BIN" auth configure-docker "$1" --quiet
  if [ "$APPLY" = "Y" ]; then
    "$DOCKER_BIN" buildx version >/dev/null
  fi
}
