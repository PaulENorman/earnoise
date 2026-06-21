# docs

This directory tracks the working plan for the cloud CFD pipeline and the guardrails around it.

## Current Status

- The repo is split into `cfd/` for compute and `paraview/` for remote visualization.
- The baseline container is the OpenFOAM.com / OpenCFD / Keysight line on Ubuntu 24.04.
- The compute launcher now defaults to VM-side uploads to Cloud Storage.
- The ParaView launcher now starts a separate viewer VM, syncs a case from Cloud Storage, launches `pvserver`, opens the SSH tunnel, and starts the local ParaView client.
- VM lifecycle is automated from shell scripts, so the normal workflow no longer depends on the GCP GUI.
- Local machine-specific cloud settings live in ignored `cfd/gcp.env` and `paraview/gcp.env` files.

## OpenFOAM.com Baseline

The repository Dockerfile now targets:

- Ubuntu `24.04` (`noble`)
- official OpenFOAM apt repository from `dl.openfoam.com`
- package `openfoam2506-default`
- pinned package version `2506.260127-1`

That package layout installs OpenFOAM under:

```text
/usr/lib/openfoam/openfoam2506
```

and the shell setup file lives at:

```text
/usr/lib/openfoam/openfoam2506/etc/bashrc
```

## Operational Notes Worth Keeping

These came out of the first VM pass and should carry forward into the new image validation:

- Mounted case data should be accessed in-container as `/cases`, not `~/cases`.
- Host write permissions were initially rough enough to require `chmod 777` as a temporary workaround.
- A cleaner UID/GID strategy is still needed for mounted case directories.
- The 2-vCPU VM hit an OpenMPI slot-detection problem during parallel runs.
- The working workaround was to call MPI explicitly with:

```bash
mpirun --oversubscribe --use-hwthread-cpus -np 2
```

- That workaround carries into the current motorBike execution path in `cfd/runMotorBikeInContainer.sh`.

## Credential Policy

The repo should stay free of long-lived credentials.

Rules for the next GCP step:

1. Prefer a VM-attached service account for bucket access.
2. Do not commit service-account JSON files, SSH private keys, local `gcp.env` files, or local `.env` files.
3. Keep any local-only credentials outside the repo and mount or inject them at runtime only if absolutely necessary.
4. Avoid embedding secrets directly in shell scripts, Dockerfiles, or GitHub workflow files.

Current VM note:

- The working launchers assume VM-attached service accounts with `cloud-platform` scope.
- Access should be restricted with bucket-level IAM rather than committed credentials.

## Expected Pipeline

Planned one-command flow:

1. Create or reuse a GCP VM from the local launcher.
2. Copy a filtered source bundle to the VM.
3. Build the Docker image on the VM.
4. Run a selected case workflow.
5. Upload selected outputs to Cloud Storage.
6. Shut the VM down or delete it when appropriate.

## Open Questions For The Next Pass

- Whether the viewer VM should be deleted between sessions instead of merely stopped.
- Whether the compute VM should stay as a long-lived small instance or also become fully disposable.
- How to handle cleaner UID/GID mapping for mounted case directories instead of permissive `chmod 777`.
- How the future human-head case should diverge from the current motorBike-specific launch path.

## Next Notes

- [gcp-scaleout-notes.md](/Users/paulnorman/Desktop/earnoise/earnoise/docs/gcp-scaleout-notes.md) covers the next storage and remote-ParaView steps:
  VM-native bucket uploads and a `pvserver`-based viewing path.
