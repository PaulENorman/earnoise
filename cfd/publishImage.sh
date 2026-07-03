#!/usr/bin/env bash
# Publishes the CFD image to Artifact Registry, either with Cloud Build or local Docker.

set -euo pipefail

log() {
  printf '[cfd/publishImage] %s\n' "$*" >&2
}

die() {
  printf '[cfd/publishImage] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

publish_with_cloud_build() {
  log "Submitting Cloud Build for ${DOCKER_IMAGE_TAG}."
  gcloud builds submit \
    --tag "$DOCKER_IMAGE_TAG" \
    "$REPO_ROOT"
}

publish_with_local_docker() {
  local registry_host

  require_cmd docker

  registry_host="${DOCKER_IMAGE_TAG%%/*}"

  log "Authenticating Docker to ${registry_host}."
  gcloud auth print-access-token | docker login \
    -u oauth2accesstoken \
    --password-stdin "https://${registry_host}"

  log "Building and pushing ${DOCKER_IMAGE_TAG} for ${DOCKER_BUILD_PLATFORM}."
  docker buildx build \
    --platform "$DOCKER_BUILD_PLATFORM" \
    --provenance=false \
    --sbom=false \
    --tag "$DOCKER_IMAGE_TAG" \
    --push \
    "$REPO_ROOT"
}

main() {
  local config_file

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
  DOCKER_IMAGE_NAME="${DOCKER_IMAGE_NAME:-cfd-openfoam}"
  OPENFOAM_VERSION="${OPENFOAM_VERSION:-2306}"
  DOCKER_IMAGE_TAG="${DOCKER_IMAGE_TAG:-${ARTIFACT_REGISTRY_LOCATION}-docker.pkg.dev/${GCP_PROJECT}/${ARTIFACT_REGISTRY_REPOSITORY}/${DOCKER_IMAGE_NAME}:v${OPENFOAM_VERSION}}"
  DOCKER_BUILD_PLATFORM="${DOCKER_BUILD_PLATFORM:-linux/amd64}"
  IMAGE_PUBLISH_BACKEND="${IMAGE_PUBLISH_BACKEND:-cloud-build}"

  [[ -n "$GCP_PROJECT" ]] || die "GCP_PROJECT is not set and no default gcloud project was found."
  [[ "$ARTIFACT_REGISTRY_REPOSITORY" != "your-docker-repo" ]] || die "Set ARTIFACT_REGISTRY_REPOSITORY in cfd/gcp.env before publishing."

  case "$IMAGE_PUBLISH_BACKEND" in
    cloud-build)
      publish_with_cloud_build
      ;;
    docker-local)
      publish_with_local_docker
      ;;
    *)
      die "Unsupported IMAGE_PUBLISH_BACKEND: ${IMAGE_PUBLISH_BACKEND} (expected cloud-build or docker-local)."
      ;;
  esac
}

main "$@"
