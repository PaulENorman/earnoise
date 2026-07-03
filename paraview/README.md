# ParaView

- `localLaunchPvServer.sh` starts the viewer VM, syncs a case from Cloud Storage, opens the SSH tunnel, and launches the local ParaView client.
- `manageVm.sh` manages the viewer VM lifecycle and can recreate the configured viewer VM if it is missing.
- `publishImage.sh` publishes the ParaView pvserver image to Artifact Registry, defaulting to Cloud Build so it is built on x86_64 infrastructure instead of the local Mac.
- `runPvServerOnVm.sh` pulls the configured ParaView pvserver image onto the VM, syncs the case locally on the VM, and starts `pvserver` from the container.
- `openPvTunnel.sh` recreates the SSH tunnel manually if needed.
- `Dockerfile` defines the reusable ParaView server image.
- `gcp.env` is the ignored local file for viewer-VM defaults.
- `gcp.env.example` is the tracked template with scrubbed placeholder values.
