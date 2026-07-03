#!/usr/bin/env bash
# Starts the ParaView VM, launches pvserver remotely, and opens an SSH tunnel.

set -euo pipefail

log() {
  printf '[localLaunchPvServer] %s\n' "$*" >&2
}

die() {
  printf '[localLaunchPvServer] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  paraview/localLaunchPvServer.sh [bucket-case-path]

Examples:
  paraview/localLaunchPvServer.sh
  paraview/localLaunchPvServer.sh drivAer/b9-steady/4PM_21_Jun_28_2026/case/aerodynamicsDrivAer/aerodynamicsDrivAer

Environment:
  EARNOISE_PARAVIEW_ENV_FILE  Optional config file to source before launch.
  PARAVIEW_PORT           Local and remote pvserver port. Default: 11111
  BUCKET_CASE_PATH        Optional bucket path under PARAVIEW_CASE_ROOT to sync.
                          Empty means sync the full bucket root.
  LOCAL_PARAVIEW_APP      Local macOS ParaView app bundle. Default: /Applications/ParaView-<version>.app
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

quote_arg() {
  printf '%q' "$1"
}

gcloud_scp() {
  gcloud compute scp \
    --project="$GCP_PROJECT" \
    --zone="$PARAVIEW_GCP_ZONE" \
    "$@"
}

gcloud_ssh() {
  local remote_command="$1"

  gcloud compute ssh "$PARAVIEW_VM_NAME" \
    --project="$GCP_PROJECT" \
    --zone="$PARAVIEW_GCP_ZONE" \
    --command="$remote_command"
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
  log "Ensuring ParaView VM $PARAVIEW_VM_NAME exists and is running."
  bash "$REPO_ROOT/paraview/manageVm.sh" ensure-running
}

cleanup_remote_results_cache() {
  local remote_cmd

remote_cmd='
case_root="$HOME/paraview-cases"
results_dir="$HOME/paraview-cases/results"
if mountpoint -q "$results_dir"; then
  fusermount3 -u "$results_dir" 2>/dev/null || fusermount -u "$results_dir" 2>/dev/null || true
fi
rm -rf "$case_root"
'

  log "Cleaning any partial ParaView bucket cache on $PARAVIEW_VM_NAME."
  ssh_with_retries "$remote_cmd"
}

copy_bundle_to_vm() {
  log "Uploading source bundle to $PARAVIEW_VM_NAME."
  scp_with_retries \
    "$SOURCE_BUNDLE" \
    "$PARAVIEW_VM_NAME:~/$REMOTE_BUNDLE_NAME"
}

prepare_remote_repo() {
  log "Preparing remote workspace on the VM."
  ssh_with_retries \
    "rm -rf ~/earnoise-runner && mkdir -p ~/earnoise-runner && tar -xzf ~/$REMOTE_BUNDLE_NAME -C ~/earnoise-runner && rm -f ~/$REMOTE_BUNDLE_NAME"
}

start_remote_pvserver() {
  local remote_cmd

  remote_cmd="$(
    cat <<EOF
bash ~/earnoise-runner/paraview/runPvServerOnVm.sh \
  --image-tag $(quote_arg "$PARAVIEW_IMAGE_TAG") \
  --port $(quote_arg "$PARAVIEW_PORT") \
  --bucket-case-path $(quote_arg "$BUCKET_CASE_PATH") \
  --bucket-root $(quote_arg "$PARAVIEW_CASE_ROOT")
EOF
  )"

  log "Preparing pvserver on $PARAVIEW_VM_NAME."
  ssh_with_retries "$remote_cmd"
}

verify_remote_pvserver() {
  local output
  local remote_cmd

  remote_cmd='
pid_file="$HOME/paraview-run/pvserver.pid"
log_file="$HOME/paraview-run/pvserver.log"

if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
  printf "__EARNOISE_PVSERVER_OK__ %s\n" "$(cat "$pid_file")"
else
  printf "__EARNOISE_PVSERVER_FAIL__\n"
  tail -n 50 "$log_file" 2>/dev/null || true
  exit 1
fi
'

  log "Verifying pvserver is still running."
  output="$(ssh_with_retries "$remote_cmd" 2>&1)" || true
  printf '%s\n' "$output"

  if [[ "$output" != *"__EARNOISE_PVSERVER_OK__"* ]]; then
    die "pvserver did not stay up on $PARAVIEW_VM_NAME."
  fi
}

launch_local_tunnel() {
  local local_port_pid
  local tunnel_log

  if lsof -nP -iTCP:"$PARAVIEW_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    log "A local listener is already using port $PARAVIEW_PORT. Reusing the existing tunnel or service."
    return 0
  fi

  tunnel_log="${TMPDIR:-/tmp}/earnoise-pvtunnel-${PARAVIEW_PORT}.log"

  log "Opening SSH tunnel on localhost:$PARAVIEW_PORT."
  gcloud compute ssh "$PARAVIEW_VM_NAME" \
    --project="$GCP_PROJECT" \
    --zone="$PARAVIEW_GCP_ZONE" \
    -- -N -L "${PARAVIEW_PORT}:localhost:${PARAVIEW_PORT}" \
    >"$tunnel_log" 2>&1 &

  local_port_pid=$!
  sleep 2

  if ! kill -0 "$local_port_pid" 2>/dev/null; then
    cat "$tunnel_log" >&2 || true
    die "Failed to start SSH tunnel to $PARAVIEW_VM_NAME."
  fi

  log "SSH tunnel started with PID $local_port_pid."
}

launch_local_paraview() {
  local app_bundle
  local server_url

  app_bundle="${LOCAL_PARAVIEW_APP:-/Applications/ParaView-${PARAVIEW_VERSION}.app}"
  [[ -d "$app_bundle" ]] || die "Local ParaView app bundle not found: $app_bundle"

  server_url="cs://localhost:${PARAVIEW_PORT}"

  log "Launching local ParaView and connecting to $server_url."
  open "$app_bundle" --args --server-url "$server_url"
}

print_next_steps() {
  local remote_case_dir

  if [[ -n "$BUCKET_CASE_PATH" ]]; then
    remote_case_dir="~/paraview-cases/${BUCKET_CASE_PATH}"
  else
    remote_case_dir="~/paraview-cases/results"
  fi

  cat <<EOF

ParaView server is ready.

1. Local ParaView should now be opening against:
   cs://localhost:${PARAVIEW_PORT}

2. Case files on the VM are under:
   ${remote_case_dir}

3. If you need to recreate the tunnel manually, run:
   gcloud compute ssh $PARAVIEW_VM_NAME --project=$GCP_PROJECT --zone=$PARAVIEW_GCP_ZONE -- -N -L ${PARAVIEW_PORT}:localhost:${PARAVIEW_PORT}
EOF
}

main() {
  local config_file

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  config_file="${EARNOISE_PARAVIEW_ENV_FILE:-$REPO_ROOT/paraview/gcp.env}"

  if [[ -f "$config_file" ]]; then
    # shellcheck disable=SC1090
    source "$config_file"
  fi

  require_cmd gcloud

  GCP_PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
  PARAVIEW_GCP_ZONE="${PARAVIEW_GCP_ZONE:-us-central1-a}"
  PARAVIEW_VM_NAME="${PARAVIEW_VM_NAME:-paraview-viewer}"
  PARAVIEW_VERSION="${PARAVIEW_VERSION:-6.1.1}"
  ARTIFACT_REGISTRY_LOCATION="${ARTIFACT_REGISTRY_LOCATION:-us-central1}"
  ARTIFACT_REGISTRY_REPOSITORY="${ARTIFACT_REGISTRY_REPOSITORY:-your-docker-repo}"
  PARAVIEW_IMAGE_NAME="${PARAVIEW_IMAGE_NAME:-paraview-pvserver}"
  PARAVIEW_IMAGE_TAG="${PARAVIEW_IMAGE_TAG:-${ARTIFACT_REGISTRY_LOCATION}-docker.pkg.dev/${GCP_PROJECT}/${ARTIFACT_REGISTRY_REPOSITORY}/${PARAVIEW_IMAGE_NAME}:v${PARAVIEW_VERSION}}"
  PARAVIEW_PORT="${PARAVIEW_PORT:-11111}"
  PARAVIEW_CASE_ROOT="${PARAVIEW_CASE_ROOT:-gs://your-results-bucket}"
  LOCAL_PARAVIEW_APP="${LOCAL_PARAVIEW_APP:-/Applications/ParaView-${PARAVIEW_VERSION}.app}"
  BUCKET_CASE_PATH="${1:-${BUCKET_CASE_PATH:-}}"

  [[ -n "$GCP_PROJECT" ]] || die "GCP_PROJECT is not set and no default gcloud project was found."
  [[ "$PARAVIEW_CASE_ROOT" != "gs://your-results-bucket" ]] || die "Set PARAVIEW_CASE_ROOT in paraview/gcp.env before launching."
  [[ "$ARTIFACT_REGISTRY_REPOSITORY" != "your-docker-repo" ]] || die "Set ARTIFACT_REGISTRY_REPOSITORY in paraview/gcp.env before launching."

  REMOTE_BUNDLE_NAME="earnoise-paraview-source.tgz"
  SOURCE_BUNDLE="$(mktemp "${TMPDIR:-/tmp}/earnoise-paraview-source-XXXXXX.tgz")"
  trap 'rm -f "$SOURCE_BUNDLE"' EXIT

  log "Creating source bundle from $REPO_ROOT."
  COPYFILE_DISABLE=1 tar -czf "$SOURCE_BUNDLE" \
    --no-xattrs \
    --exclude-from="$REPO_ROOT/.gcpignore" \
    -C "$REPO_ROOT" \
    .

  ensure_vm_running
  cleanup_remote_results_cache
  copy_bundle_to_vm
  prepare_remote_repo
  start_remote_pvserver
  verify_remote_pvserver
  launch_local_tunnel
  launch_local_paraview
  print_next_steps
}

main "$@"
