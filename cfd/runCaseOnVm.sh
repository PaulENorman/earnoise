#!/usr/bin/env bash
# Runs on the GCP VM and executes a configured CFD workflow there.

set -euo pipefail

log() {
  printf '[runCaseOnVm] %s\n' "$*" >&2
}

die() {
  printf '[runCaseOnVm] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  cfd/runCaseOnVm.sh --run-id <utc-run-id> [options]
EOF
}

check_free_disk_space() {
  local avail_kb
  local avail_gb
  local min_free_gb=6

  avail_kb="$(df -Pk /var/lib/docker 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ -z "$avail_kb" ]]; then
    avail_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
  fi

  avail_gb=$((avail_kb / 1024 / 1024))
  log "Approx free disk before Docker build: ${avail_gb}GB."

  if (( avail_gb < min_free_gb )); then
    die "Only ${avail_gb}GB free on the VM. Need at least ${min_free_gb}GB free before building the OpenFOAM image."
  fi
}

ensure_docker_cmd() {
  if docker info >/dev/null 2>&1; then
    DOCKER_CMD=(docker)
    return
  fi

  if command -v sudo >/dev/null 2>&1; then
    if command -v systemctl >/dev/null 2>&1; then
      sudo systemctl start docker >/dev/null 2>&1 || true
    fi

    if sudo docker info >/dev/null 2>&1; then
      DOCKER_CMD=(sudo docker)
      return
    fi
  fi

  log "Installing Docker runtime."
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends docker.io

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now docker >/dev/null 2>&1 || true
  fi

  if sudo docker info >/dev/null 2>&1; then
    DOCKER_CMD=(sudo docker)
    return
  fi

  die "Docker is not available on the VM."
}

ensure_gcloud_cmd() {
  if command -v gcloud >/dev/null 2>&1; then
    return
  fi

  log "Installing Google Cloud CLI."
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends ca-certificates curl gnupg
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  printf 'deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main\n' \
    | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends google-cloud-cli

  command -v gcloud >/dev/null 2>&1 || die "gcloud is not available on the VM."
}

write_manifest() {
  cat > "$ARTIFACT_DIR/manifest.txt" <<EOF
run_id=$RUN_ID
case_name=$CASE_NAME
results_prefix=$RESULTS_PREFIX
image_tag=$IMAGE_TAG
openfoam_version=$OPENFOAM_VERSION
case_cpus=$CASE_CPUS
container_run_script=$CONTAINER_RUN_SCRIPT
upload_mode=$UPLOAD_MODE
archive_name=$ARCHIVE_NAME
staged_case_dir=case
case_input_file=${CASE_INPUT_FILE:-}
case_input_gcs_uri=${CASE_INPUT_GCS_URI:-}
created_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

build_image_on_vm() {
  log "Building Docker image $IMAGE_TAG."
  "${DOCKER_CMD[@]}" build -t "$IMAGE_TAG" "$REPO_ROOT"
}

pull_image_from_registry() {
  local registry_host

  registry_host="${IMAGE_TAG%%/*}"
  log "Authenticating Docker to ${registry_host}."
  gcloud auth print-access-token | "${DOCKER_CMD[@]}" login \
    -u oauth2accesstoken \
    --password-stdin "https://${registry_host}" >/dev/null

  log "Pulling Docker image $IMAGE_TAG."
  "${DOCKER_CMD[@]}" pull "$IMAGE_TAG"
}

ensure_image_available() {
  if [[ "$IMAGE_TAG" == *".pkg.dev/"* ]]; then
    pull_image_from_registry
  else
    build_image_on_vm
  fi
}

prepare_case_input_from_gcs() {
  local cache_dir
  local cache_file

  [[ -n "$CASE_INPUT_GCS_URI" ]] || return 0

  cache_dir="$HOME/earnoise-runner-inputs-cache"
  cache_file="$cache_dir/$(basename "$CASE_INPUT_GCS_URI")"

  mkdir -p "$cache_dir"

  if [[ ! -f "$cache_file" ]]; then
    log "Caching case input from $CASE_INPUT_GCS_URI."
    gcloud storage cp "$CASE_INPUT_GCS_URI" "$cache_file"
  else
    log "Using cached case input $cache_file."
  fi

  CASE_INPUT_FILE="$cache_file"
}

run_case_in_container() {
  local docker_args
  local container_env

  log "Running $CASE_NAME with container script $CONTAINER_RUN_SCRIPT."
  mkdir -p "$RUNS_ROOT" "$ARTIFACT_ROOT"

  docker_args=(
    --rm
    --cpus="$CASE_CPUS"
    --user "$(id -u):$(id -g)"
    --shm-size=2g
    -e "HOME=/tmp"
    -e "OPENFOAM_VERSION=$OPENFOAM_VERSION"
    -e "OMPI_MCA_btl_vader_single_copy_mechanism=none"
    -v "$REPO_ROOT/cfd:/workspace/cfd:ro"
    -v "$RUNS_ROOT:/runs"
    -v "$ARTIFACT_ROOT:/artifacts"
  )

  for container_env in "${CONTAINER_ENVS[@]}"; do
    docker_args+=(-e "$container_env")
  done

  if [[ -n "$CASE_INPUT_FILE" ]]; then
    docker_args+=(
      -e "CASE_INPUT_FILE_IN_VM=/inputs/$(basename "$CASE_INPUT_FILE")"
      -v "$CASE_INPUT_FILE:/inputs/$(basename "$CASE_INPUT_FILE"):ro"
    )
  fi

  "${DOCKER_CMD[@]}" run "${docker_args[@]}" \
    "$IMAGE_TAG" \
    bash -lc "
      set +u
      source /usr/lib/openfoam/openfoam${OPENFOAM_VERSION}/etc/bashrc
      set -u
      bash /workspace/cfd/${CONTAINER_RUN_SCRIPT} \
        $(printf '%q' "$RUN_ID") \
        $(printf '%q' "$CASE_NAME") \
        $(printf '%q' "$CASE_CPUS")
    "
}

package_case_results() {
  [[ -d "$CASE_RUN_DIR" ]] || die "Expected run directory was not created: $CASE_RUN_DIR"
  mkdir -p "$ARTIFACT_DIR"

  log "Packaging run directory from $CASE_RUN_DIR."
  tar -czf "$ARTIFACT_DIR/$ARCHIVE_NAME" \
    --exclude='processor*' \
    -C "$RUNS_ROOT/$RUN_ID" \
    "$CASE_NAME"
}

stage_case_results() {
  local staged_case_dir="$ARTIFACT_DIR/case"

  rm -rf "$staged_case_dir"
  mkdir -p "$staged_case_dir"

  log "Staging reconstructed case files into $staged_case_dir."
  tar -cf - \
    --exclude='processor*' \
    --exclude='postProcessing' \
    -C "$CASE_RUN_DIR" \
    . | tar -xf - -C "$staged_case_dir"
}

upload_artifacts_from_vm() {
  [[ -n "$GCS_BUCKET_URI" ]] || die "--bucket-uri is required when --upload-mode=vm."

  log "Uploading artifacts from the VM to $GCS_BUCKET_URI."
  gcloud storage cp \
    "$ARTIFACT_DIR/manifest.txt" \
    "$ARTIFACT_DIR/$ARCHIVE_NAME" \
    "${GCS_BUCKET_URI%/}/$RESULTS_PREFIX/$RUN_ID/"
  gcloud storage cp \
    --recursive \
    "$ARTIFACT_DIR/case" \
    "${GCS_BUCKET_URI%/}/$RESULTS_PREFIX/$RUN_ID/"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run-id) RUN_ID="$2"; shift 2 ;;
      --case-name) CASE_NAME="$2"; shift 2 ;;
      --image-tag) IMAGE_TAG="$2"; shift 2 ;;
      --openfoam-version) OPENFOAM_VERSION="$2"; shift 2 ;;
      --case-cpus) CASE_CPUS="$2"; shift 2 ;;
      --results-prefix) RESULTS_PREFIX="$2"; shift 2 ;;
      --container-run-script) CONTAINER_RUN_SCRIPT="$2"; shift 2 ;;
      --bucket-uri) GCS_BUCKET_URI="$2"; shift 2 ;;
      --case-input-file) CASE_INPUT_FILE="$2"; shift 2 ;;
      --case-input-gcs-uri) CASE_INPUT_GCS_URI="$2"; shift 2 ;;
      --container-env) CONTAINER_ENVS+=("$2"); shift 2 ;;
      --upload-mode) UPLOAD_MODE="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
}

main() {
  CASE_NAME="motorBike"
  RUN_ID=""
  OPENFOAM_VERSION="2306"
  IMAGE_TAG="earnoise-openfoam:v2306"
  CASE_CPUS="2"
  RESULTS_PREFIX="$CASE_NAME"
  CONTAINER_RUN_SCRIPT="runMotorBikeInContainer.sh"
  GCS_BUCKET_URI=""
  CASE_INPUT_FILE=""
  CASE_INPUT_GCS_URI=""
  CONTAINER_ENVS=()
  UPLOAD_MODE="local"

  parse_args "$@"

  [[ -n "$RUN_ID" ]] || die "--run-id is required."
  [[ "$UPLOAD_MODE" == "local" || "$UPLOAD_MODE" == "vm" ]] || die "--upload-mode must be local or vm."

  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  RUNS_ROOT="$REPO_ROOT/runs"
  CASE_RUN_DIR="$RUNS_ROOT/$RUN_ID/$CASE_NAME"
  ARTIFACT_ROOT="$REPO_ROOT/artifacts"
  ARTIFACT_DIR="$ARTIFACT_ROOT/$RUN_ID/$CASE_NAME"
  ARCHIVE_NAME="${CASE_NAME}-${RUN_ID}.tgz"

  ensure_docker_cmd
  ensure_gcloud_cmd
  check_free_disk_space
  ensure_image_available
  prepare_case_input_from_gcs
  run_case_in_container
  package_case_results
  stage_case_results
  write_manifest

  if [[ "$UPLOAD_MODE" == "vm" ]]; then
    upload_artifacts_from_vm
  fi

  log "Remote run finished. Artifacts are in $ARTIFACT_DIR."
}

main "$@"
