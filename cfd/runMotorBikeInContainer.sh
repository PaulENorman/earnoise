#!/usr/bin/env bash
# Runs inside the OpenFOAM.com container and executes a fresh motorBike tutorial case.

set -eo pipefail

log() {
  printf '[runMotorBikeInContainer] %s\n' "$*" >&2
}

RUN_ID="${1:?run id is required}"
CASE_NAME="${2:-motorBike}"
CASE_CPUS="${3:?case cpu count is required}"
TUTORIAL_RELATIVE_PATH="${4:-incompressible/simpleFoam/motorBike}"
RUNS_ROOT="/runs"
CASE_RUN_DIR="$RUNS_ROOT/$RUN_ID/$CASE_NAME"
DECOMP_DICT="system/decomposeParDict.localLaunch"

[[ -n "${WM_PROJECT_DIR:-}" ]] || {
  printf '[runMotorBikeInContainer] ERROR: OpenFOAM environment is not loaded.\n' >&2
  exit 1
}

. "${WM_PROJECT_DIR:?}/bin/tools/RunFunctions"

log "Preparing fresh case from \$FOAM_TUTORIALS/$TUTORIAL_RELATIVE_PATH."
rm -rf "$CASE_RUN_DIR"
mkdir -p "$RUNS_ROOT/$RUN_ID"
mkdir -p "$CASE_RUN_DIR"
cp -a "$FOAM_TUTORIALS/$TUTORIAL_RELATIVE_PATH/." "$CASE_RUN_DIR/"
cd "$CASE_RUN_DIR"

cat > "$DECOMP_DICT" <<EOF
/*--------------------------------*- C++ -*----------------------------------*\\
| =========                 |                                                 |
| \\\\      /  F ield         | OpenFOAM: The Open Source CFD Toolbox           |
|  \\\\    /   O peration     | Version:  v2506                                 |
|   \\\\  /    A nd           | Website:  www.openfoam.com                      |
|    \\\\/     M anipulation  |                                                 |
\\*---------------------------------------------------------------------------*/
FoamFile
{
    version     2.0;
    format      ascii;
    class       dictionary;
    object      decomposeParDict;
}

numberOfSubdomains ${CASE_CPUS};

method          scotch;

// ************************************************************************* //
EOF

mkdir -p constant/triSurface
cp -f "$FOAM_TUTORIALS/resources/geometry/motorBike.obj.gz" constant/triSurface/

rm -f log.*
rm -rf processor*

MPI="mpirun --oversubscribe --use-hwthread-cpus -np ${CASE_CPUS}"
APP="$(getApplication)"

log "Running preprocessing."
runApplication surfaceFeatureExtract
runApplication blockMesh
runApplication decomposePar -decomposeParDict "$DECOMP_DICT"

log "Running snappyHexMesh."
$MPI snappyHexMesh -parallel -overwrite -decomposeParDict "$DECOMP_DICT" > log.snappyHexMesh 2>&1

log "Running topoSet."
$MPI topoSet -parallel -decomposeParDict "$DECOMP_DICT" > log.topoSet 2>&1

log "Restoring initial fields."
restore0Dir -processor

log "Running patchSummary."
$MPI patchSummary -parallel -decomposeParDict "$DECOMP_DICT" > log.patchSummary 2>&1

log "Running potentialFoam."
$MPI potentialFoam -parallel -writephi -decomposeParDict "$DECOMP_DICT" > log.potentialFoam 2>&1

log "Running checkMesh."
$MPI checkMesh -parallel -writeFields '(nonOrthoAngle)' -constant -decomposeParDict "$DECOMP_DICT" > log.checkMesh 2>&1

log "Running ${APP}."
$MPI "$APP" -parallel -decomposeParDict "$DECOMP_DICT" > "log.${APP}" 2>&1

log "Reconstructing results."
runApplication reconstructParMesh -constant
runApplication reconstructPar -latestTime

log "motorBike tutorial run completed."
