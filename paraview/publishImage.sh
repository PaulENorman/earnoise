#!/usr/bin/env bash
# Publishes the ParaView pvserver image to Artifact Registry.

set -euo pipefail

log() {
  printf '[paraview/publishImage] %s\n' "$*" >&2
}

die() {
  printf '[paraview/publishImage] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

publish_with_cloud_build() {
  log "Submitting Cloud Build for ${PARAVIEW_IMAGE_TAG}."
  gcloud builds submit \
    --tag "$PARAVIEW_IMAGE_TAG" \
    "$REPO_ROOT/paraview"
}

publish_with_local_docker() {
  local registry_host

  require_cmd docker

  registry_host="${PARAVIEW_IMAGE_TAG%%/*}"

  log "Authenticating Docker to ${registry_host}."
  gcloud auth print-access-token | docker login \
    -u oauth2accesstoken \
    --password-stdin "https://${registry_host}"

  log "Building and pushing ${PARAVIEW_IMAGE_TAG} for ${PARAVIEW_BUILD_PLATFORM}."
  docker buildx build \
    --platform "$PARAVIEW_BUILD_PLATFORM" \
    --provenance=false \
    --sbom=false \
    --tag "$PARAVIEW_IMAGE_TAG" \
    --push \
    "$REPO_ROOT/paraview"
}

main() {
  local config_file

  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  config_file="${EARNOISE_PARAVIEW_ENV_FILE:-$REPO_ROOT/paraview/gcp.env}"

  if [[ -f "$config_file" ]]; then
    # shellcheck disable=SC1090
    source "$config_file"
  fi

  require_cmd gcloud

  GCP_PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
  ARTIFACT_REGISTRY_LOCATION="${ARTIFACT_REGISTRY_LOCATION:-us-central1}"
  ARTIFACT_REGISTRY_REPOSITORY="${ARTIFACT_REGISTRY_REPOSITORY:-your-docker-repo}"
  PARAVIEW_IMAGE_NAME="${PARAVIEW_IMAGE_NAME:-paraview-pvserver}"
  PARAVIEW_VERSION="${PARAVIEW_VERSION:-6.1.1}"
  PARAVIEW_IMAGE_TAG="${PARAVIEW_IMAGE_TAG:-${ARTIFACT_REGISTRY_LOCATION}-docker.pkg.dev/${GCP_PROJECT}/${ARTIFACT_REGISTRY_REPOSITORY}/${PARAVIEW_IMAGE_NAME}:v${PARAVIEW_VERSION}}"
  PARAVIEW_IMAGE_PUBLISH_BACKEND="${PARAVIEW_IMAGE_PUBLISH_BACKEND:-cloud-build}"
  PARAVIEW_BUILD_PLATFORM="${PARAVIEW_BUILD_PLATFORM:-linux/amd64}"

  [[ -n "$GCP_PROJECT" ]] || die "GCP_PROJECT is not set and no default gcloud project was found."
  [[ "$ARTIFACT_REGISTRY_REPOSITORY" != "your-docker-repo" ]] || die "Set ARTIFACT_REGISTRY_REPOSITORY in paraview/gcp.env before publishing."

  case "$PARAVIEW_IMAGE_PUBLISH_BACKEND" in
    cloud-build)
      publish_with_cloud_build
      ;;
    docker-local)
      publish_with_local_docker
      ;;
    *)
      die "Unsupported PARAVIEW_IMAGE_PUBLISH_BACKEND: ${PARAVIEW_IMAGE_PUBLISH_BACKEND} (expected cloud-build or docker-local)."
      ;;
  esac
}

main "$@"
