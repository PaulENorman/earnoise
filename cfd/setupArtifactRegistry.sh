#!/usr/bin/env bash
# Enables Artifact Registry, creates the Docker repo, and grants the compute VM pull access.

set -euo pipefail

log() {
  printf '[cfd/setupArtifactRegistry] %s\n' "$*" >&2
}

die() {
  printf '[cfd/setupArtifactRegistry] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

repository_exists() {
  gcloud artifacts repositories describe "$ARTIFACT_REGISTRY_REPOSITORY" \
    --project="$GCP_PROJECT" \
    --location="$ARTIFACT_REGISTRY_LOCATION" >/dev/null 2>&1
}

main() {
  local config_file
  local project_number
  local service_account

  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  config_file="${EARNOISE_CFD_ENV_FILE:-$REPO_ROOT/cfd/gcp.env}"

  if [[ -f "$config_file" ]]; then
    # shellcheck disable=SC1090
    source "$config_file"
  fi

  require_cmd gcloud

  GCP_PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
  ARTIFACT_REGISTRY_LOCATION="${ARTIFACT_REGISTRY_LOCATION:-us-central1}"
  ARTIFACT_REGISTRY_REPOSITORY="${ARTIFACT_REGISTRY_REPOSITORY:-your-docker-repo}"

  [[ -n "$GCP_PROJECT" ]] || die "GCP_PROJECT is not set and no default gcloud project was found."
  [[ "$ARTIFACT_REGISTRY_REPOSITORY" != "your-docker-repo" ]] || die "Set ARTIFACT_REGISTRY_REPOSITORY in cfd/gcp.env before running setup."

  project_number="$(gcloud projects describe "$GCP_PROJECT" --format='value(projectNumber)')"
  service_account="${GCP_VM_SERVICE_ACCOUNT:-${project_number}-compute@developer.gserviceaccount.com}"

  log "Enabling Artifact Registry API."
  gcloud services enable artifactregistry.googleapis.com --project="$GCP_PROJECT"

  if repository_exists; then
    log "Repository $ARTIFACT_REGISTRY_REPOSITORY already exists."
  else
    log "Creating repository $ARTIFACT_REGISTRY_REPOSITORY in $ARTIFACT_REGISTRY_LOCATION."
    gcloud artifacts repositories create "$ARTIFACT_REGISTRY_REPOSITORY" \
      --project="$GCP_PROJECT" \
      --repository-format=docker \
      --location="$ARTIFACT_REGISTRY_LOCATION" \
      --description="CFD container images for earnoise"
  fi

  log "Granting Artifact Registry reader access to ${service_account}."
  gcloud artifacts repositories add-iam-policy-binding "$ARTIFACT_REGISTRY_REPOSITORY" \
    --project="$GCP_PROJECT" \
    --location="$ARTIFACT_REGISTRY_LOCATION" \
    --member="serviceAccount:${service_account}" \
    --role="roles/artifactregistry.reader"
}

main "$@"
