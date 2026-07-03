# CFD

- `localLaunchCase.sh` is the Mac-side generic launcher for CFD cases.
- `manageVm.sh` manages the CFD VM lifecycle and can recreate the configured compute VM if it is missing.
- `publishImage.sh` publishes the CFD container to Artifact Registry, defaulting to Cloud Build so the image is produced on x86_64 infrastructure instead of the local Mac.
- `setupArtifactRegistry.sh` creates the Artifact Registry Docker repository and grants the compute VM read access.
- `runCaseOnVm.sh` pulls the configured image from Artifact Registry when `DOCKER_IMAGE_TAG` points there, otherwise it falls back to building on the compute VM before running the selected case and uploading artifacts.
- `runMotorBikeInContainer.sh` is the in-container motorBike executor.
- `runDrivAerB9SteadyInContainer.sh` is the in-container reduced steady-state DrivAer executor.
- `gcp.env` is the ignored local file for compute-VM defaults.
- `gcp.env.example` is the tracked template with scrubbed placeholder values.
- `cases/motorBike.env` holds motorBike-specific case settings.
- `cases/drivAerB9.env.example` is the tracked template for the reduced steady-state DrivAer starter.
- `cases/humanHead.env.example` is a placeholder profile for the next case family.
- `publishImage.sh` can still use local Docker with `IMAGE_PUBLISH_BACKEND=docker-local`, and that path defaults to `linux/amd64` so the pushed image matches the current x86_64 GCP VMs.

The new CFD image defaults to OpenFOAM.com `v2306` so it lines up with the public exaFOAM DrivAer B9 benchmark release.

The default launch mode is now detached submit with `UPLOAD_MODE=vm`, so the launcher can hand the run off to the VM, exit locally, and let the VM shut itself down after the remote runner exits.

For larger public benchmark inputs, prefer `CASE_INPUT_GCS_URI` in the case profile so the VM pulls from a dedicated Cloud Storage inputs bucket instead of re-uploading the same archive from your laptop on every run.

Use `RESULTS_PREFIX` in the case profile to control the Cloud Storage results path independently from the local case folder name. The DrivAer starter now uploads under `drivAer/b9-steady/<run-id>/`.

Launch a specific CFD case by selecting its env file:

```bash
EARNOISE_CFD_CASE_ENV_FILE=cfd/cases/motorBike.env bash cfd/localLaunchCase.sh
EARNOISE_CFD_CASE_ENV_FILE=cfd/cases/drivAerB9.env bash cfd/localLaunchCase.sh
```
