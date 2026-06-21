#!/usr/bin/env bash
# Runs on the GCP VM and executes a fresh motorBike tutorial workflow there.

set -euo pipefail

log() {
  printf '[runMotorBikeOnVm] %s\n' "$*" >&2
}

die() {
  printf '[runMotorBikeOnVm] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  cfd/runMotorBikeOnVm.sh \
    --run-id <utc-run-id> \
    [--case-name <name>] \
    [--image-tag <docker-tag>] \
    [--case-cpus <count>] \
    [--tutorial-relative-path <path>] \
    [--bucket-uri <gs://bucket>] \
    [--upload-mode <local|vm>]
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

  die "Docker is not available on the VM."
}

write_manifest() {
  cat > "$ARTIFACT_DIR/manifest.txt" <<EOF
run_id=$RUN_ID
case_name=$CASE_NAME
image_tag=$IMAGE_TAG
case_cpus=$CASE_CPUS
tutorial_relative_path=$TUTORIAL_RELATIVE_PATH
upload_mode=$UPLOAD_MODE
archive_name=$ARCHIVE_NAME
staged_case_dir=case
created_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

build_image_on_vm() {
  log "Building Docker image $IMAGE_TAG."
  "${DOCKER_CMD[@]}" build -t "$IMAGE_TAG" "$REPO_ROOT"
}

run_case_in_container() {
  log "Running $CASE_NAME from tutorial path $TUTORIAL_RELATIVE_PATH."
  mkdir -p "$RUNS_ROOT" "$ARTIFACT_ROOT"
  "${DOCKER_CMD[@]}" run --rm \
    --cpus="$CASE_CPUS" \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -v "$REPO_ROOT/cfd:/workspace/cfd:ro" \
    -v "$RUNS_ROOT:/runs" \
    -v "$ARTIFACT_ROOT:/artifacts" \
    "$IMAGE_TAG" \
    bash -lc "
      set +u
      source /usr/lib/openfoam/openfoam2506/etc/bashrc
      set -u
      bash /workspace/cfd/runMotorBikeInContainer.sh \
        $(printf '%q' "$RUN_ID") \
        $(printf '%q' "$CASE_NAME") \
        $(printf '%q' "$CASE_CPUS") \
        $(printf '%q' "$TUTORIAL_RELATIVE_PATH")
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
  local staged_case_dir

  staged_case_dir="$ARTIFACT_DIR/case"
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
  command -v gcloud >/dev/null 2>&1 || die "UPLOAD_MODE=vm requires gcloud on the VM."
  [[ -n "$GCS_BUCKET_URI" ]] || die "--bucket-uri is required when --upload-mode=vm."

  log "Uploading artifacts from the VM to $GCS_BUCKET_URI."
  gcloud storage cp \
    "$ARTIFACT_DIR/manifest.txt" \
    "$ARTIFACT_DIR/$ARCHIVE_NAME" \
    "${GCS_BUCKET_URI%/}/$CASE_NAME/$RUN_ID/"
  gcloud storage cp \
    --recursive \
    "$ARTIFACT_DIR/case" \
    "${GCS_BUCKET_URI%/}/$CASE_NAME/$RUN_ID/"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run-id)
        RUN_ID="$2"
        shift 2
        ;;
      --case-name)
        CASE_NAME="$2"
        shift 2
        ;;
      --image-tag)
        IMAGE_TAG="$2"
        shift 2
        ;;
      --case-cpus)
        CASE_CPUS="$2"
        shift 2
        ;;
      --tutorial-relative-path)
        TUTORIAL_RELATIVE_PATH="$2"
        shift 2
        ;;
      --bucket-uri)
        GCS_BUCKET_URI="$2"
        shift 2
        ;;
      --upload-mode)
        UPLOAD_MODE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

main() {
  CASE_NAME="motorBike"
  RUN_ID=""
  IMAGE_TAG="earnoise-openfoam:v2506"
  CASE_CPUS="2"
  TUTORIAL_RELATIVE_PATH="incompressible/simpleFoam/motorBike"
  GCS_BUCKET_URI=""
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
  check_free_disk_space

  build_image_on_vm
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
