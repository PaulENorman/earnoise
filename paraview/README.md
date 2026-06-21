# ParaView

- `localLaunchPvServer.sh` starts the viewer VM, syncs a case from Cloud Storage, opens the SSH tunnel, and launches the local ParaView client.
- `manageVm.sh` manages the viewer VM lifecycle and can recreate the configured viewer VM if it is missing.
- `runPvServerOnVm.sh` installs the matching ParaView server build on the VM and starts `pvserver`.
- `openPvTunnel.sh` recreates the SSH tunnel manually if needed.
- `gcp.env` is the ignored local file for viewer-VM defaults.
- `gcp.env.example` is the tracked template with scrubbed placeholder values.
