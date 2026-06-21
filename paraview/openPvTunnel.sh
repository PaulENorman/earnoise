#!/usr/bin/env bash
# Opens an SSH tunnel from the local machine to the remote pvserver port.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${EARNOISE_PARAVIEW_ENV_FILE:-$REPO_ROOT/paraview/gcp.env}"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

GCP_PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
PARAVIEW_GCP_ZONE="${PARAVIEW_GCP_ZONE:-us-central1-a}"
PARAVIEW_VM_NAME="${PARAVIEW_VM_NAME:-paraview-viewer}"
PARAVIEW_PORT="${PARAVIEW_PORT:-11111}"

exec gcloud compute ssh "$PARAVIEW_VM_NAME" \
  --project="$GCP_PROJECT" \
  --zone="$PARAVIEW_GCP_ZONE" \
  -- -N -L "${PARAVIEW_PORT}:localhost:${PARAVIEW_PORT}"
