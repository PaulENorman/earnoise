#!/usr/bin/env bash
# Manages the ParaView VM lifecycle from local config.

set -euo pipefail

log() {
  printf '[paraview/manageVm] %s\n' "$*" >&2
}

die() {
  printf '[paraview/manageVm] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  paraview/manageVm.sh <status|start|stop|ensure-running|create|delete>

Environment:
  EARNOISE_PARAVIEW_ENV_FILE   Optional config file to source before running.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

load_config() {
  local config_file
  local project_number

  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  config_file="${EARNOISE_PARAVIEW_ENV_FILE:-$REPO_ROOT/paraview/gcp.env}"

  if [[ -f "$config_file" ]]; then
    # shellcheck disable=SC1090
    source "$config_file"
  fi

  GCP_PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
  PARAVIEW_GCP_ZONE="${PARAVIEW_GCP_ZONE:-us-central1-a}"
  PARAVIEW_VM_NAME="${PARAVIEW_VM_NAME:-paraview-viewer}"
  PARAVIEW_VM_MACHINE_TYPE="${PARAVIEW_VM_MACHINE_TYPE:-n2-highmem-4}"
  PARAVIEW_VM_DISK_SIZE_GB="${PARAVIEW_VM_DISK_SIZE_GB:-10}"
  PARAVIEW_VM_DISK_TYPE="${PARAVIEW_VM_DISK_TYPE:-pd-balanced}"
  PARAVIEW_VM_IMAGE_PROJECT="${PARAVIEW_VM_IMAGE_PROJECT:-ubuntu-os-cloud}"
  PARAVIEW_VM_IMAGE_FAMILY="${PARAVIEW_VM_IMAGE_FAMILY:-ubuntu-minimal-2404-lts-amd64}"
  PARAVIEW_VM_SCOPES="${PARAVIEW_VM_SCOPES:-cloud-platform}"

  [[ -n "$GCP_PROJECT" ]] || die "GCP_PROJECT is not set and no default gcloud project was found."

  project_number="$(gcloud projects describe "$GCP_PROJECT" --format='value(projectNumber)')"
  PARAVIEW_VM_SERVICE_ACCOUNT="${PARAVIEW_VM_SERVICE_ACCOUNT:-${project_number}-compute@developer.gserviceaccount.com}"
}

instance_exists() {
  gcloud compute instances describe "$PARAVIEW_VM_NAME" \
    --project="$GCP_PROJECT" \
    --zone="$PARAVIEW_GCP_ZONE" \
    --format='value(name)' >/dev/null 2>&1
}

instance_status() {
  if ! instance_exists; then
    printf 'MISSING\n'
    return
  fi

  gcloud compute instances describe "$PARAVIEW_VM_NAME" \
    --project="$GCP_PROJECT" \
    --zone="$PARAVIEW_GCP_ZONE" \
    --format='value(status)'
}

create_instance() {
  if instance_exists; then
    log "VM $PARAVIEW_VM_NAME already exists."
    return 0
  fi

  log "Creating VM $PARAVIEW_VM_NAME in $PARAVIEW_GCP_ZONE."
  gcloud compute instances create "$PARAVIEW_VM_NAME" \
    --project="$GCP_PROJECT" \
    --zone="$PARAVIEW_GCP_ZONE" \
    --machine-type="$PARAVIEW_VM_MACHINE_TYPE" \
    --boot-disk-size="${PARAVIEW_VM_DISK_SIZE_GB}GB" \
    --boot-disk-type="$PARAVIEW_VM_DISK_TYPE" \
    --image-family="$PARAVIEW_VM_IMAGE_FAMILY" \
    --image-project="$PARAVIEW_VM_IMAGE_PROJECT" \
    --service-account="$PARAVIEW_VM_SERVICE_ACCOUNT" \
    --scopes="$PARAVIEW_VM_SCOPES"
}

start_instance() {
  local status

  status="$(instance_status)"
  case "$status" in
    MISSING)
      create_instance
      ;;
    RUNNING)
      log "VM $PARAVIEW_VM_NAME is already running."
      ;;
    TERMINATED|STOPPED)
      log "Starting VM $PARAVIEW_VM_NAME."
      gcloud compute instances start "$PARAVIEW_VM_NAME" \
        --project="$GCP_PROJECT" \
        --zone="$PARAVIEW_GCP_ZONE"
      ;;
    *)
      die "VM $PARAVIEW_VM_NAME is in unexpected state: $status"
      ;;
  esac
}

stop_instance() {
  local status

  status="$(instance_status)"
  case "$status" in
    MISSING)
      log "VM $PARAVIEW_VM_NAME does not exist."
      ;;
    TERMINATED|STOPPED)
      log "VM $PARAVIEW_VM_NAME is already stopped."
      ;;
    RUNNING|PROVISIONING|STAGING|REPAIRING)
      log "Stopping VM $PARAVIEW_VM_NAME."
      gcloud compute instances stop "$PARAVIEW_VM_NAME" \
        --project="$GCP_PROJECT" \
        --zone="$PARAVIEW_GCP_ZONE"
      ;;
    *)
      die "VM $PARAVIEW_VM_NAME is in unexpected state: $status"
      ;;
  esac
}

delete_instance() {
  if ! instance_exists; then
    log "VM $PARAVIEW_VM_NAME does not exist."
    return 0
  fi

  log "Deleting VM $PARAVIEW_VM_NAME."
  gcloud compute instances delete "$PARAVIEW_VM_NAME" \
    --project="$GCP_PROJECT" \
    --zone="$PARAVIEW_GCP_ZONE" \
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
