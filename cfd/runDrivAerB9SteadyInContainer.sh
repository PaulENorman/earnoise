#!/usr/bin/env bash
# Runs a reduced steady-state DrivAer B9 workflow inside the OpenFOAM container.

set -eo pipefail

log() {
  printf '[runDrivAerB9SteadyInContainer] %s\n' "$*" >&2
}

die() {
  printf '[runDrivAerB9SteadyInContainer] ERROR: %s\n' "$*" >&2
  exit 1
}

RUN_ID="${1:?run id is required}"
CASE_NAME="${2:-drivAerB9Steady}"
CASE_CPUS="${3:?case cpu count is required}"
RUNS_ROOT="/runs"
CASE_RUN_DIR="$RUNS_ROOT/$RUN_ID/$CASE_NAME"

DRIVAER_BLOCK_CELLS="${DRIVAER_BLOCK_CELLS:-24 20 12}"
DRIVAER_SURFACE_LEVEL="${DRIVAER_SURFACE_LEVEL:-5}"
DRIVAER_ADD_LAYERS="${DRIVAER_ADD_LAYERS:-false}"
DRIVAER_STEADY_END_TIME="${DRIVAER_STEADY_END_TIME:-1000}"
DRIVAER_WRITE_INTERVAL="${DRIVAER_WRITE_INTERVAL:-250}"
DRIVAER_GEOMETRY_DIR="${DRIVAER_GEOMETRY_DIR:-I9_aerodynamics_DrivAer}"
CASE_INPUT_FILE_IN_VM="${CASE_INPUT_FILE_IN_VM:-}"

[[ -n "${WM_PROJECT_DIR:-}" ]] || die "OpenFOAM environment is not loaded."
[[ -n "$CASE_INPUT_FILE_IN_VM" ]] || die "CASE_INPUT_FILE_IN_VM must point to the B9 dataset zip."
[[ -f "$CASE_INPUT_FILE_IN_VM" ]] || die "Missing B9 dataset zip: $CASE_INPUT_FILE_IN_VM"

. "${WM_PROJECT_DIR:?}/bin/tools/RunFunctions"

extract_dataset() {
  rm -rf "$CASE_RUN_DIR"
  mkdir -p "$CASE_RUN_DIR"

  log "Extracting B9 case setup and geometry from $(basename "$CASE_INPUT_FILE_IN_VM")."
  unzip -p "$CASE_INPUT_FILE_IN_VM" B9_case_setup.tgz | tar -xzf - -C "$CASE_RUN_DIR"
  unzip -p "$CASE_INPUT_FILE_IN_VM" B9_aerodynamics_DrivAer.tgz | tar -xzf - -C "$CASE_RUN_DIR"
}

prepare_case_tree() {
  local steady_case_dir="$CASE_RUN_DIR/aerodynamicsDrivAer/aerodynamicsDrivAer"
  local tri_surface_dir="$steady_case_dir/constant/triSurface"

  [[ -d "$steady_case_dir" ]] || die "Expected steady case directory was not created."

  mkdir -p "$tri_surface_dir"
  cp -f "$CASE_RUN_DIR/$DRIVAER_GEOMETRY_DIR/"*.obj.gz "$tri_surface_dir/"
  gunzip -f "$tri_surface_dir/"*.obj.gz
}

patch_case_for_small_vm() {
  local steady_case_dir="$CASE_RUN_DIR/aerodynamicsDrivAer/aerodynamicsDrivAer"
  cd "$steady_case_dir"

  log "Applying reduced settings for a smaller VM."

  perl -0pi -e "s/hex \\(0 1 2 3 4 5 6 7\\) \\([^\\)]*\\) simpleGrading/hex (0 1 2 3 4 5 6 7) (${DRIVAER_BLOCK_CELLS}) simpleGrading/" system/blockMeshDict
  perl -0pi -e "s/level \\(9 9\\);/level (${DRIVAER_SURFACE_LEVEL} ${DRIVAER_SURFACE_LEVEL});/g" system/snappyHexMeshDict
  perl -0pi -e "s/addLayers\\s+true;/addLayers ${DRIVAER_ADD_LAYERS};/" system/snappyHexMeshDict

  foamDictionary -entry numberOfSubdomains -set "$CASE_CPUS" system/decomposeParDictMesher
  foamDictionary -entry numberOfSubdomains -set "$CASE_CPUS" system/decomposeParDictSolver
  foamDictionary -entry endTime -set "$DRIVAER_STEADY_END_TIME" system/controlDict
  foamDictionary -entry writeInterval -set "$DRIVAER_WRITE_INTERVAL" system/controlDict
}

run_case() {
  local steady_case_dir="$CASE_RUN_DIR/aerodynamicsDrivAer/aerodynamicsDrivAer"
  local mpi="mpirun --oversubscribe --use-hwthread-cpus -np ${CASE_CPUS}"

  cd "$steady_case_dir"
  rm -f log.*
  rm -rf processor*

  log "Running reduced steady-state DrivAer case."
  runApplication blockMesh
  runApplication surfaceFeatureExtract
  runApplication -decomposeParDict system/decomposeParDictMesher decomposePar
  ${mpi} snappyHexMesh -parallel -overwrite -decomposeParDict system/decomposeParDictMesher > log.snappyHexMesh 2>&1
  ${mpi} renumberMesh -parallel -constant -overwrite -decomposeParDict system/decomposeParDictMesher > log.renumberMesh 2>&1
  ${mpi} checkMesh -parallel -constant -decomposeParDict system/decomposeParDictMesher > log.checkMesh 2>&1
  ${mpi} redistributePar -parallel -constant -overwrite -decomposeParDict system/decomposeParDictSolver > log.redistributePar 2>&1
  restore0Dir -processor
  ${mpi} changeDictionary -parallel -constant -enableFunctionEntries -decomposeParDict system/decomposeParDictSolver > log.changeDictionary 2>&1
  ${mpi} potentialFoam -parallel -initialiseUBCs -noFunctionObjects -decomposeParDict system/decomposeParDictSolver > log.potentialFoam 2>&1
  ${mpi} applyBoundaryLayer -parallel -ybl 0.1 -decomposeParDict system/decomposeParDictSolver > log.applyBoundaryLayer 2>&1
  ${mpi} simpleFoam -parallel -decomposeParDict system/decomposeParDictSolver > log.simpleFoam 2>&1

  runApplication reconstructParMesh -constant
  runApplication reconstructPar -latestTime
}

main() {
  extract_dataset
  prepare_case_tree
  patch_case_for_small_vm
  run_case
  log "Reduced steady-state DrivAer run completed."
}

main "$@"
