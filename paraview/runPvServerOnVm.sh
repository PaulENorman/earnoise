#!/usr/bin/env bash
# Pulls a published ParaView pvserver image onto the viewer VM, exposes a GCS
# results tree as a filesystem, prepares `.foam` markers, and launches pvserver.

set -euo pipefail

log() {
  printf '[runPvServerOnVm] %s\n' "$*" >&2
}

die() {
  printf '[runPvServerOnVm] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  paraview/runPvServerOnVm.sh \
    --image-tag <docker-tag> \
    --port <port> \
    [--bucket-case-path <bucket/path/under/root>] \
    --bucket-root <gs://bucket>
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image-tag)
        PARAVIEW_IMAGE_TAG="$2"
        shift 2
        ;;
      --port)
        PARAVIEW_PORT="$2"
        shift 2
        ;;
      --bucket-case-path)
        BUCKET_CASE_PATH="$2"
        shift 2
        ;;
      --bucket-root)
        BUCKET_ROOT="$2"
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

ensure_gcsfuse_cmd() {
  local codename

  if command -v gcsfuse >/dev/null 2>&1; then
    return
  fi

  log "Installing Cloud Storage FUSE."
  codename="$(
    . /etc/os-release
    printf '%s\n' "${VERSION_CODENAME:-}"
  )"
  [[ -n "$codename" ]] || die "Could not determine Ubuntu/Debian codename for gcsfuse installation."

  sudo apt-get update
  sudo apt-get install -y --no-install-recommends ca-certificates curl gnupg
  sudo rm -f /usr/share/keyrings/gcsfuse.gpg
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/gcsfuse.gpg
  printf 'deb [signed-by=/usr/share/keyrings/gcsfuse.gpg] https://packages.cloud.google.com/apt gcsfuse-%s main\n' "$codename" \
    | sudo tee /etc/apt/sources.list.d/gcsfuse.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends gcsfuse

  command -v gcsfuse >/dev/null 2>&1 || die "gcsfuse is not available on the VM."
}

cleanup_previous_results_cache() {
  local results_dir="$HOME/paraview-cases/results"

  if mountpoint -q "$results_dir"; then
    fusermount3 -u "$results_dir" 2>/dev/null || fusermount -u "$results_dir" 2>/dev/null || true
  fi

  rm -rf "$results_dir"
}

pull_paraview_image() {
  local registry_host

  registry_host="${PARAVIEW_IMAGE_TAG%%/*}"
  log "Authenticating Docker to ${registry_host}."
  gcloud auth print-access-token | "${DOCKER_CMD[@]}" login \
    -u oauth2accesstoken \
    --password-stdin "https://${registry_host}" >/dev/null

  log "Pulling ParaView image ${PARAVIEW_IMAGE_TAG}."
  "${DOCKER_CMD[@]}" pull "${PARAVIEW_IMAGE_TAG}"
}

parse_gcs_uri() {
  local uri_without_scheme

  [[ "$BUCKET_ROOT" == gs://* ]] || die "--bucket-root must start with gs://"
  uri_without_scheme="${BUCKET_ROOT#gs://}"
  GCS_BUCKET="${uri_without_scheme%%/*}"
  GCS_PREFIX="${uri_without_scheme#"$GCS_BUCKET"}"
  GCS_PREFIX="${GCS_PREFIX#/}"
}

join_gcs_prefix() {
  local left="$1"
  local right="$2"

  if [[ -n "$left" && -n "$right" ]]; then
    printf '%s/%s\n' "${left%/}" "${right#/}"
  elif [[ -n "$left" ]]; then
    printf '%s\n' "${left%/}"
  else
    printf '%s\n' "${right#/}"
  fi
}

mount_case_bucket() {
  local only_dir

  CASE_ROOT="$HOME/paraview-cases"
  CASE_DIR="${CASE_ROOT}/results"
  parse_gcs_uri
  only_dir="$(join_gcs_prefix "$GCS_PREFIX" "$BUCKET_CASE_PATH")"

  log "Mounting gs://${GCS_BUCKET}${only_dir:+/$only_dir} at ${CASE_DIR}."
  if mountpoint -q "$CASE_DIR"; then
    fusermount3 -u "$CASE_DIR" 2>/dev/null || fusermount -u "$CASE_DIR" 2>/dev/null || true
  fi

  rm -rf "$CASE_DIR"
  mkdir -p "$CASE_DIR"

  if [[ -n "$only_dir" ]]; then
    gcsfuse --implicit-dirs --file-mode 0644 --dir-mode 0755 --only-dir "$only_dir" "$GCS_BUCKET" "$CASE_DIR"
  else
    gcsfuse --implicit-dirs --file-mode 0644 --dir-mode 0755 "$GCS_BUCKET" "$CASE_DIR"
  fi
}

prepare_foam_markers() {
  local control_dict
  local case_dir
  local marker_count

  marker_count=0
  while IFS= read -r control_dict; do
    case_dir="$(dirname "$(dirname "$control_dict")")"
    : > "${case_dir}/$(basename "$case_dir").foam"
    marker_count=$((marker_count + 1))
  done < <(find "$CASE_DIR" -path '*/system/controlDict' -type f 2>/dev/null)

  if (( marker_count == 0 )); then
    log "No OpenFOAM controlDict files found under ${CASE_DIR}; no .foam markers were created."
  else
    log "Prepared ${marker_count} ParaView .foam marker file(s) under ${CASE_DIR}."
  fi
}

start_pvserver() {
  local status_dir
  local log_file
  local pid_file
  local container_name

  status_dir="$HOME/paraview-run"
  log_file="${status_dir}/pvserver.log"
  pid_file="${status_dir}/pvserver.pid"
  container_name="earnoise-pvserver"

  mkdir -p "$status_dir"

  log "Removing any previous pvserver container."
  "${DOCKER_CMD[@]}" rm -f "${container_name}" >/dev/null 2>&1 || true

  log "Starting pvserver on port ${PARAVIEW_PORT}."
  nohup "${DOCKER_CMD[@]}" run --rm \
    --name "${container_name}" \
    --network host \
    -v "${CASE_ROOT}:/cases" \
    -w /tmp \
    "${PARAVIEW_IMAGE_TAG}" \
    pvserver --server-port="${PARAVIEW_PORT}" \
    > "$log_file" 2>&1 < /dev/null &

  echo $! > "$pid_file"
  sleep 3

  kill -0 "$(cat "$pid_file")" 2>/dev/null || {
    tail -n 50 "$log_file" >&2 || true
    die "pvserver failed to stay running."
  }

  log "pvserver is running."
  printf 'pvserver_pid=%s\n' "$(cat "$pid_file")"
  printf 'pvserver_log=%s\n' "$log_file"
  printf 'case_dir=%s\n' "$CASE_DIR"
}

main() {
  PARAVIEW_IMAGE_TAG=""
  PARAVIEW_PORT="11111"
  BUCKET_CASE_PATH=""
  BUCKET_ROOT=""

  parse_args "$@"

  [[ -n "$PARAVIEW_IMAGE_TAG" ]] || die "--image-tag is required."
  [[ -n "$BUCKET_ROOT" ]] || die "--bucket-root is required."

  cleanup_previous_results_cache
  ensure_docker_cmd
  ensure_gcsfuse_cmd
  pull_paraview_image
  mount_case_bucket
  prepare_foam_markers
  start_pvserver
}

main "$@"
