#!/usr/bin/env bash
# Installs a matching ParaView release on the viewer VM, syncs a case from GCS,
# prepares a `.foam` marker, and launches pvserver headlessly.

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
    --paraview-version <version> \
    --port <port> \
    --bucket-case-path <bucket/path/under/root> \
    --bucket-root <gs://bucket>
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --paraview-version)
        PARAVIEW_VERSION="$2"
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

install_system_packages() {
  log "Installing runtime packages."
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    libgl1 \
    libglib2.0-0 \
    libglu1-mesa \
    libgomp1 \
    libsm6 \
    libxcursor1 \
    libxext6 \
    libxi6 \
    libxinerama1 \
    libxkbcommon-x11-0 \
    libxrandr2 \
    libxrender1 \
    tar
}

ensure_paraview_install() {
  local install_root
  local archive_name
  local archive_url
  local install_dir
  local extracted_dir

  install_root="$HOME/paraview"
  archive_name="ParaView-${PARAVIEW_VERSION}-MPI-Linux-Python3.12-x86_64.tar.gz"
  archive_url="https://www.paraview.org/files/v6.1/${archive_name}"
  install_dir="${install_root}/ParaView-${PARAVIEW_VERSION}"
  extracted_dir="${install_root}/ParaView-${PARAVIEW_VERSION}-MPI-Linux-Python3.12-x86_64"
  PARAVIEW_BIN_DIR="${install_dir}/bin"

  if [[ -x "${PARAVIEW_BIN_DIR}/pvserver" ]]; then
    log "Using existing ParaView install at ${install_dir}."
    return
  fi

  log "Downloading ParaView ${PARAVIEW_VERSION}."
  mkdir -p "$install_root"
  curl -fL "$archive_url" -o "${install_root}/${archive_name}"

  log "Extracting ParaView ${PARAVIEW_VERSION}."
  rm -rf "$install_dir" "$extracted_dir"
  tar -xzf "${install_root}/${archive_name}" -C "$install_root"
  mv "$extracted_dir" "$install_dir"
}

sync_case_from_bucket() {
  local case_name
  local foam_marker

  CASE_ROOT="$HOME/paraview-cases"
  CASE_DIR="${CASE_ROOT}/${BUCKET_CASE_PATH}"

  log "Syncing case data from ${BUCKET_ROOT%/}/${BUCKET_CASE_PATH}."
  mkdir -p "$CASE_DIR"
  gcloud storage rsync --recursive "${BUCKET_ROOT%/}/${BUCKET_CASE_PATH}" "$CASE_DIR"

  case_name="$(basename "$CASE_DIR")"
  foam_marker="${CASE_DIR}/${case_name}.foam"
  : > "$foam_marker"
  log "Prepared ParaView marker file at ${foam_marker}."
}

start_pvserver() {
  local status_dir
  local log_file
  local pid_file
  local existing_pids

  status_dir="$HOME/paraview-run"
  log_file="${status_dir}/pvserver.log"
  pid_file="${status_dir}/pvserver.pid"

  mkdir -p "$status_dir"

  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    log "Stopping existing pvserver process."
    kill "$(cat "$pid_file")"
    sleep 2
  fi

  existing_pids="$(ss -ltnp 2>/dev/null | awk -v port=":${PARAVIEW_PORT}" '$4 ~ port {print $NF}' | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -u)"
  if [[ -n "$existing_pids" ]]; then
    log "Stopping stale listeners on port ${PARAVIEW_PORT}: ${existing_pids//$'\n'/ }"
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      kill "$pid" 2>/dev/null || true
    done <<< "$existing_pids"
    sleep 2
  fi

  log "Starting pvserver on port ${PARAVIEW_PORT}."
  nohup "${PARAVIEW_BIN_DIR}/pvserver" \
    --server-port="${PARAVIEW_PORT}" \
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
  printf 'foam_marker=%s\n' "${CASE_DIR}/$(basename "$CASE_DIR").foam"
}

main() {
  PARAVIEW_VERSION=""
  PARAVIEW_PORT="11111"
  BUCKET_CASE_PATH=""
  BUCKET_ROOT=""

  parse_args "$@"

  [[ -n "$PARAVIEW_VERSION" ]] || die "--paraview-version is required."
  [[ -n "$BUCKET_CASE_PATH" ]] || die "--bucket-case-path is required."
  [[ -n "$BUCKET_ROOT" ]] || die "--bucket-root is required."

  install_system_packages
  ensure_paraview_install
  sync_case_from_bucket
  start_pvserver
}

main "$@"
