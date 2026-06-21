#!/usr/bin/env bash
# Runs on the local machine and submits the motorBike case to the GCP VM.

set -euo pipefail

log() {
  printf '[localLaunchMotorBike] %s\n' "$*" >&2
}

die() {
  printf '[localLaunchMotorBike] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  cfd/localLaunchMotorBike.sh

Environment:
  EARNOISE_CFD_ENV_FILE        Optional platform config file to source before launch.
  EARNOISE_CFD_CASE_ENV_FILE   Optional case config file to source before launch.
  RUN_ID                  Optional override for the run id.

Expected config values:
  GCP_PROJECT
  GCP_ZONE
  GCP_VM_NAME
  GCS_BUCKET_URI
  DOCKER_IMAGE_TAG
  CASE_CPUS
  CASE_NAME
  TUTORIAL_RELATIVE_PATH
  UPLOAD_MODE
  STOP_VM_AFTER_RUN
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

quote_arg() {
  printf '%q' "$1"
}

gcloud_ssh() {
  local remote_command="$1"

  gcloud compute ssh "$GCP_VM_NAME" \
    --project="$GCP_PROJECT" \
    --zone="$GCP_ZONE" \
    --command="$remote_command"
}

gcloud_scp() {
  gcloud compute scp \
    --project="$GCP_PROJECT" \
    --zone="$GCP_ZONE" \
    "$@"
}

ssh_with_retries() {
  local remote_command="$1"
  local attempt
  local status

  for attempt in 1 2 3; do
    if gcloud_ssh "$remote_command"; then
      return 0
    fi
    status=$?

    if (( attempt == 3 )); then
      return "$status"
    fi

    log "SSH command failed (attempt $attempt/3). Retrying in 5 seconds."
    sleep 5
  done
}

scp_with_retries() {
  local attempt
  local status

  for attempt in 1 2 3; do
    if gcloud_scp "$@"; then
      return 0
    fi
    status=$?

    if (( attempt == 3 )); then
      return "$status"
    fi

    log "SCP command failed (attempt $attempt/3). Retrying in 5 seconds."
    sleep 5
  done
}

ensure_vm_running() {
  log "Ensuring CFD VM $GCP_VM_NAME exists and is running."
  bash "$REPO_ROOT/cfd/manageVm.sh" ensure-running
}

copy_bundle_to_vm() {
  log "Uploading source bundle to $GCP_VM_NAME."
  scp_with_retries \
    "$SOURCE_BUNDLE" \
    "$GCP_VM_NAME:~/$REMOTE_BUNDLE_NAME"
}

prepare_remote_repo() {
  log "Preparing remote workspace on the VM."
  ssh_with_retries \
    "rm -rf ~/earnoise-runner && mkdir -p ~/earnoise-runner && tar -xzf ~/$REMOTE_BUNDLE_NAME -C ~/earnoise-runner && rm -f ~/$REMOTE_BUNDLE_NAME"
}

start_remote_case_runner() {
  local job_cmd
  local remote_cmd

  job_cmd="$(
    cat <<EOF
set +e
bash ~/earnoise-runner/cfd/runMotorBikeOnVm.sh \
  --run-id $(quote_arg "$RUN_ID") \
  --image-tag $(quote_arg "$DOCKER_IMAGE_TAG") \
  --case-cpus $(quote_arg "$CASE_CPUS") \
  --case-name $(quote_arg "$CASE_NAME") \
  --tutorial-relative-path $(quote_arg "$TUTORIAL_RELATIVE_PATH") \
  --bucket-uri $(quote_arg "$GCS_BUCKET_URI") \
  --upload-mode $(quote_arg "$UPLOAD_MODE")
status=\$?
printf '%s\n' "\$status" > "\$HOME/earnoise-runner/status/$(quote_arg "$RUN_ID")/exit_code"
exit "\$status"
EOF
  )"

  remote_cmd="$(
    cat <<EOF
status_dir="\$HOME/earnoise-runner/status/$(quote_arg "$RUN_ID")"
log_file="\$status_dir/runner.log"
pid_file="\$status_dir/pid"

rm -rf "\$status_dir"
mkdir -p "\$status_dir"

nohup bash -lc $(quote_arg "$job_cmd") > "\$log_file" 2>&1 < /dev/null &
echo \$! > "\$pid_file"
printf '__EARNOISE_STARTED__ %s\n' "\$(cat "\$pid_file")"
EOF
  )"

  log "Submitting case $CASE_NAME to the VM."
  ssh_with_retries "$remote_cmd"
}

monitor_remote_case_runner() {
  local next_line
  local missing_polls
  local output
  local remote_cmd
  local line
  local line_count
  local state
  local exit_code

  next_line=1
  missing_polls=0

  while true; do
    remote_cmd="$(
      cat <<EOF
status_dir="\$HOME/earnoise-runner/status/$(quote_arg "$RUN_ID")"
log_file="\$status_dir/runner.log"
exit_file="\$status_dir/exit_code"
pid_file="\$status_dir/pid"

if [[ -f "\$log_file" ]]; then
  sed -n '${next_line},\$p' "\$log_file"
  line_count=\$(wc -l < "\$log_file" | tr -d '[:space:]')
else
  line_count=0
fi

if [[ -f "\$exit_file" ]]; then
  state=exited
  exit_code=\$(cat "\$exit_file")
elif [[ -f "\$pid_file" ]] && kill -0 "\$(cat "\$pid_file")" 2>/dev/null; then
  state=running
  exit_code=
else
  state=missing
  exit_code=
fi

printf '__EARNOISE_LINE_COUNT__ %s\n' "\$line_count"
printf '__EARNOISE_STATE__ %s\n' "\$state"
if [[ -n "\$exit_code" ]]; then
  printf '__EARNOISE_EXIT__ %s\n' "\$exit_code"
fi
EOF
    )"

    output="$(ssh_with_retries "$remote_cmd")" || die "Could not poll remote run state for $RUN_ID."
    line_count=""
    state=""
    exit_code=""

    while IFS= read -r line; do
      case "$line" in
        __EARNOISE_LINE_COUNT__\ *)
          line_count="${line#__EARNOISE_LINE_COUNT__ }"
          ;;
        __EARNOISE_STATE__\ *)
          state="${line#__EARNOISE_STATE__ }"
          ;;
        __EARNOISE_EXIT__\ *)
          exit_code="${line#__EARNOISE_EXIT__ }"
          ;;
        *)
          printf '%s\n' "$line" >&2
          ;;
      esac
    done <<< "$output"

    if [[ -n "$line_count" && "$line_count" =~ ^[0-9]+$ ]]; then
      next_line=$((line_count + 1))
    fi

    case "$state" in
      running)
        missing_polls=0
        sleep 10
        ;;
      exited)
        if [[ "$exit_code" == "0" ]]; then
          return 0
        fi
        die "Remote runner exited with code ${exit_code:-unknown}. See the remote log under ~/earnoise-runner/status/$RUN_ID/runner.log."
        ;;
      missing)
        missing_polls=$((missing_polls + 1))
        if (( missing_polls >= 3 )); then
          die "Remote runner for $RUN_ID disappeared before writing an exit code."
        fi
        sleep 5
        ;;
      *)
        sleep 5
        ;;
    esac
  done
}

fetch_and_upload_artifacts() {
  local local_case_dir
  local local_manifest
  local local_archive
  local local_case_tree

  local_case_dir="$REPO_ROOT/artifacts/$RUN_ID"
  mkdir -p "$local_case_dir"

  log "Fetching artifacts back to the local machine."
  scp_with_retries \
    --recurse \
    "$GCP_VM_NAME:~/earnoise-runner/artifacts/$RUN_ID/$CASE_NAME" \
    "$local_case_dir/"

  local_manifest="$local_case_dir/$CASE_NAME/manifest.txt"
  local_archive="$local_case_dir/$CASE_NAME/${CASE_NAME}-${RUN_ID}.tgz"
  local_case_tree="$local_case_dir/$CASE_NAME/case"
  [[ -f "$local_manifest" ]] || die "Missing downloaded manifest: $local_manifest"
  [[ -f "$local_archive" ]] || die "Missing downloaded archive: $local_archive"
  [[ -d "$local_case_tree" ]] || die "Missing downloaded case directory: $local_case_tree"

  log "Uploading artifacts to $GCS_BUCKET_URI."
  gcloud storage cp \
    "$local_manifest" \
    "$local_archive" \
    "${GCS_BUCKET_URI%/}/$CASE_NAME/$RUN_ID/"
  gcloud storage cp \
    --recursive \
    "$local_case_tree" \
    "${GCS_BUCKET_URI%/}/$CASE_NAME/$RUN_ID/"
}

stop_vm_if_requested() {
  if [[ "${STOP_VM_AFTER_RUN:-0}" == "1" && "${VM_SESSION_ACTIVE:-0}" == "1" && "${VM_STOPPED_ALREADY:-0}" == "0" ]]; then
    log "Stopping VM $GCP_VM_NAME."
    bash "$REPO_ROOT/cfd/manageVm.sh" stop
    VM_STOPPED_ALREADY=1
  fi
}

cleanup_local_bundle() {
  if [[ -n "${SOURCE_BUNDLE:-}" && -f "${SOURCE_BUNDLE:-}" ]]; then
    rm -f "$SOURCE_BUNDLE"
  fi

  stop_vm_if_requested
}

generate_run_id() {
  local raw_run_id

  raw_run_id="$(date '+%I%p_%M_%b_%d_%Y')"
  printf '%s\n' "${raw_run_id#0}"
}

main() {
  local case_config_file
  local config_file

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  config_file="${EARNOISE_CFD_ENV_FILE:-$REPO_ROOT/cfd/gcp.env}"
  case_config_file="${EARNOISE_CFD_CASE_ENV_FILE:-$REPO_ROOT/cfd/cases/motorBike.env}"

  if [[ -f "$config_file" ]]; then
    # shellcheck disable=SC1090
    source "$config_file"
  fi

  if [[ -f "$case_config_file" ]]; then
    # shellcheck disable=SC1090
    source "$case_config_file"
  fi

  require_cmd gcloud
  require_cmd tar

  GCP_PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
  GCP_ZONE="${GCP_ZONE:-us-central1-f}"
  GCP_VM_NAME="${GCP_VM_NAME:-cfd-compute}"
  GCS_BUCKET_URI="${GCS_BUCKET_URI:-gs://your-results-bucket}"
  DOCKER_IMAGE_TAG="${DOCKER_IMAGE_TAG:-earnoise-openfoam:v2506}"
  CASE_CPUS="${CASE_CPUS:-2}"
  CASE_NAME="${CASE_NAME:-motorBike}"
  TUTORIAL_RELATIVE_PATH="${TUTORIAL_RELATIVE_PATH:-incompressible/simpleFoam/motorBike}"
  UPLOAD_MODE="${UPLOAD_MODE:-local}"
  STOP_VM_AFTER_RUN="${STOP_VM_AFTER_RUN:-0}"
  RUN_ID="${RUN_ID:-$(generate_run_id)}"
  VM_SESSION_ACTIVE=0
  VM_STOPPED_ALREADY=0

  [[ -n "$GCP_PROJECT" ]] || die "GCP_PROJECT is not set and no default gcloud project was found."
  [[ "$CASE_NAME" == "motorBike" ]] || die "This launcher is pinned to CASE_NAME=motorBike."
  [[ "$GCS_BUCKET_URI" != "gs://your-results-bucket" ]] || die "Set GCS_BUCKET_URI in cfd/gcp.env before launching."
  [[ "$UPLOAD_MODE" == "local" || "$UPLOAD_MODE" == "vm" ]] || die "UPLOAD_MODE must be either local or vm."
  [[ -f "$REPO_ROOT/.gcpignore" ]] || die "Missing bundle ignore file: $REPO_ROOT/.gcpignore"
  log "Using OpenFOAM.com tutorial path $TUTORIAL_RELATIVE_PATH for $CASE_NAME."

  if [[ "$UPLOAD_MODE" == "local" ]]; then
    log "Using local upload mode. Successful runs will be copied to $GCS_BUCKET_URI from this machine."
  fi

  REMOTE_BUNDLE_NAME="earnoise-source-$RUN_ID.tgz"
  SOURCE_BUNDLE="$(mktemp "${TMPDIR:-/tmp}/earnoise-source-XXXXXX.tgz")"
  trap cleanup_local_bundle EXIT

  log "Creating source bundle from $REPO_ROOT."
  COPYFILE_DISABLE=1 tar -czf "$SOURCE_BUNDLE" \
    --no-xattrs \
    --exclude-from="$REPO_ROOT/.gcpignore" \
    -C "$REPO_ROOT" \
    .

  ensure_vm_running
  VM_SESSION_ACTIVE=1
  copy_bundle_to_vm
  prepare_remote_repo
  start_remote_case_runner
  monitor_remote_case_runner

  if [[ "$UPLOAD_MODE" == "local" ]]; then
    fetch_and_upload_artifacts
  fi

  log "Run completed. Run id: $RUN_ID"
  if [[ "$UPLOAD_MODE" == "local" ]]; then
    log "Artifacts are under $REPO_ROOT/artifacts/$RUN_ID and in ${GCS_BUCKET_URI%/}/$CASE_NAME/$RUN_ID/."
  else
    log "Artifacts were uploaded from the VM to ${GCS_BUCKET_URI%/}/$CASE_NAME/$RUN_ID/."
  fi
}

main "$@"
