# earnoise

Reproducible CFD workflow for running OpenFOAM cases on GCP with Docker and pushing results to Google Cloud Storage.

The current CFD baseline is the OpenFOAM.com / OpenCFD / Keysight line, now targeting `v2306` on Ubuntu 24.04 so it matches the exaFOAM DrivAer B9 benchmark.

## Repo Layout

- `Dockerfile` builds the base OpenFOAM.com container image.
- `cases/` is for tracked case inputs and lightweight case scripts.
- `cfd/` holds the compute launchers and case-specific CFD configuration.
- `docs/` holds workflow notes, current status, and security guidance.
- `paraview/` holds the viewer VM launchers and ParaView-specific configuration.

## Current Direction

Target flow:

```text
GitHub
  -> GCP VM
  -> Docker
  -> OpenFOAM
  -> Cloud Storage
```

Immediate focus:

1. Keep the motorBike tutorial path stable on OpenFOAM.com `v2306`.
2. Add a second case family beside motorBike, starting with a reduced steady-state DrivAer B9 workflow.
3. Keep the GCP launch path reproducible without committing account-linked config or credentials.
4. Decide how disposable the ParaView viewer VM should be between sessions.

## Quick Start

Build the image:

```bash
docker build -t earnoise-openfoam:v2306 .
```

Start an interactive shell with the repo's case directory mounted into the container:

```bash
docker run --rm -it -v "$PWD/cases:/cases" earnoise-openfoam:v2306
```

Inside the container, OpenFOAM should already be sourced for interactive shells. Useful checks:

```bash
echo $WM_PROJECT_VERSION
foamInstallationTest
mpirun --version
```

Submit a case to GCP with the local machine acting only as the orchestrator:

```bash
EARNOISE_CFD_CASE_ENV_FILE=cfd/cases/motorBike.env bash cfd/localLaunchCase.sh
```

The generic CFD launcher reads platform defaults from a local ignored `cfd/gcp.env`, case defaults from a case profile in `cfd/cases/`, runs the selected in-container case script on the VM, then uploads a manifest, a full archive, and a lighter reconstructed case directory directly from the VM to Cloud Storage.

To launch the reduced DrivAer B9 starter, copy the case template and point `CASE_INPUT_GCS_URI` at the DaRUS zip staged in your case-inputs bucket. `CASE_INPUT_FILE` remains available as a one-off local upload fallback.

```bash
cp cfd/cases/drivAerB9.env.example cfd/cases/drivAerB9.env
EARNOISE_CFD_CASE_ENV_FILE=cfd/cases/drivAerB9.env bash cfd/localLaunchCase.sh
```

Publish the CFD image to Artifact Registry with Cloud Build:

```bash
bash cfd/setupArtifactRegistry.sh
bash cfd/publishImage.sh
```

Publish the ParaView server image to Artifact Registry with Cloud Build:

```bash
bash paraview/publishImage.sh
```

To set up local machine-specific config, copy:

```bash
cp cfd/gcp.env.example cfd/gcp.env
cp paraview/gcp.env.example paraview/gcp.env
```

Useful VM lifecycle commands:

```bash
bash cfd/manageVm.sh status
bash cfd/manageVm.sh ensure-running
bash paraview/manageVm.sh status
bash paraview/manageVm.sh stop
```

## Credential Safety

- Do not store service-account JSON files, SSH keys, local `gcp.env` files, or `.env` files in this repo.
- The long-term plan is to use a VM-attached GCP service account instead of committed keys.
- `.gitignore`, `.gcpignore`, `.gcloudignore`, and `.dockerignore` are set up to reduce accidental leakage of local secrets, account-linked config, and bulky CFD outputs.

## Next Step

The next layer is tuning the reduced DrivAer starter so it fits the current VM envelope, then using that as the base for future head and aeroacoustic workflows.
