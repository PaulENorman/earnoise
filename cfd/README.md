# CFD

- `localLaunchMotorBike.sh` is the Mac-side launcher for the current motorBike workflow.
- `manageVm.sh` manages the CFD VM lifecycle and can recreate the configured compute VM if it is missing.
- `runMotorBikeOnVm.sh` builds the Docker image on the compute VM, runs the motorBike case, and uploads artifacts.
- `runMotorBikeInContainer.sh` is the in-container OpenFOAM.com executor.
- `gcp.env` is the ignored local file for compute-VM defaults.
- `gcp.env.example` is the tracked template with scrubbed placeholder values.
- `cases/motorBike.env` holds motorBike-specific case settings so a future head case can live beside it.
- `cases/humanHead.env.example` is a placeholder profile for the next case family.
