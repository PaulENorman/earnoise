#!/usr/bin/env bash
# Manages the CFD compute VM lifecycle from local config.

set -euo pipefail

log() {
  printf '[cfd/manageVm] %s\n' "$*" >&2
}

die() {
  printf '[cfd/manageVm] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  cfd/manageVm.sh <status|start|stop|ensure-running|create|delete>

Environment:
  EARNOISE_CFD_ENV_FILE   Optional config file to source before running.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

load_config() {
  local config_file
  local project_number

  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  config_file="${EARNOISE_CFD_ENV_FILE:-$REPO_ROOT/cfd/gcp.env}"

  if [[ -f "$config_file" ]]; then
    # shellcheck disable=SC1090
    source "$config_file"
  fi

  GCP_PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
  GCP_ZONE="${GCP_ZONE:-us-central1-f}"
  GCP_VM_NAME="${GCP_VM_NAME:-cfd-compute}"
  GCP_VM_MACHINE_TYPE="${GCP_VM_MACHINE_TYPE:-e2-medium}"
  GCP_VM_DISK_SIZE_GB="${GCP_VM_DISK_SIZE_GB:-30}"
  GCP_VM_DISK_TYPE="${GCP_VM_DISK_TYPE:-pd-balanced}"
  GCP_VM_IMAGE_PROJECT="${GCP_VM_IMAGE_PROJECT:-debian-cloud}"
  GCP_VM_IMAGE_FAMILY="${GCP_VM_IMAGE_FAMILY:-debian-12}"
  GCP_VM_SCOPES="${GCP_VM_SCOPES:-cloud-platform}"

  [[ -n "$GCP_PROJECT" ]] || die "GCP_PROJECT is not set and no default gcloud project was found."

  project_number="$(gcloud projects describe "$GCP_PROJECT" --format='value(projectNumber)')"
  GCP_VM_SERVICE_ACCOUNT="${GCP_VM_SERVICE_ACCOUNT:-${project_number}-compute@developer.gserviceaccount.com}"
}

instance_exists() {
  gcloud compute instances describe "$GCP_VM_NAME" \
    --project="$GCP_PROJECT" \
    --zone="$GCP_ZONE" \
    --format='value(name)' >/dev/null 2>&1
}

instance_status() {
  if ! instance_exists; then
    printf 'MISSING\n'
    return
  fi

  gcloud compute instances describe "$GCP_VM_NAME" \
    --project="$GCP_PROJECT" \
    --zone="$GCP_ZONE" \
    --format='value(status)'
}

create_instance() {
  if instance_exists; then
    log "VM $GCP_VM_NAME already exists."
    return 0
  fi

  log "Creating VM $GCP_VM_NAME in $GCP_ZONE."
  gcloud compute instances create "$GCP_VM_NAME" \
    --project="$GCP_PROJECT" \
    --zone="$GCP_ZONE" \
    --machine-type="$GCP_VM_MACHINE_TYPE" \
    --boot-disk-size="${GCP_VM_DISK_SIZE_GB}GB" \
    --boot-disk-type="$GCP_VM_DISK_TYPE" \
    --image-family="$GCP_VM_IMAGE_FAMILY" \
    --image-project="$GCP_VM_IMAGE_PROJECT" \
    --service-account="$GCP_VM_SERVICE_ACCOUNT" \
    --scopes="$GCP_VM_SCOPES"
}

start_instance() {
  local status

  status="$(instance_status)"
  case "$status" in
    MISSING)
      create_instance
      ;;
    RUNNING)
      log "VM $GCP_VM_NAME is already running."
      ;;
    TERMINATED|STOPPED)
      log "Starting VM $GCP_VM_NAME."
      gcloud compute instances start "$GCP_VM_NAME" \
        --project="$GCP_PROJECT" \
        --zone="$GCP_ZONE"
      ;;
    *)
      die "VM $GCP_VM_NAME is in unexpected state: $status"
      ;;
  esac
}

stop_instance() {
  local status

  status="$(instance_status)"
  case "$status" in
    MISSING)
      log "VM $GCP_VM_NAME does not exist."
      ;;
    TERMINATED|STOPPED)
      log "VM $GCP_VM_NAME is already stopped."
      ;;
    RUNNING|PROVISIONING|STAGING|REPAIRING)
      log "Stopping VM $GCP_VM_NAME."
      gcloud compute instances stop "$GCP_VM_NAME" \
        --project="$GCP_PROJECT" \
        --zone="$GCP_ZONE"
      ;;
    *)
      die "VM $GCP_VM_NAME is in unexpected state: $status"
      ;;
  esac
}

delete_instance() {
  if ! instance_exists; then
    log "VM $GCP_VM_NAME does not exist."
    return 0
  fi

  log "Deleting VM $GCP_VM_NAME."
  gcloud compute instances delete "$GCP_VM_NAME" \
    --project="$GCP_PROJECT" \
    --zone="$GCP_ZONE" \
    --quiet
}

main() {
  local action

  action="${1:-}"
  case "$action" in
    status|start|stop|ensure-running|create|delete)
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac

  require_cmd gcloud
  load_config

  case "$action" in
    status)
      instance_status
      ;;
    start|ensure-running)
      start_instance
      ;;
    stop)
      stop_instance
      ;;
    create)
      create_instance
      ;;
    delete)
      delete_instance
      ;;
  esac
}

main "$@"
