# cases

This directory is for tracked case definitions, setup scripts, and small supporting assets.

When mounted into the container with:

```bash
docker run --rm -it -v "$PWD/cases:/cases" earnoise-openfoam:v2506
```

it appears inside the container at:

```text
/cases
```

## Good To Commit

- `0/`
- `constant/` source inputs and case properties
- `system/`
- `Allrun*` and `Allclean*`
- small geometry and case notes

## Usually Do Not Commit

- `processor*/`
- `postProcessing/`
- generated meshes under `constant/polyMesh/`
- generated edge-mesh outputs under `constant/extendedFeatureEdgeMesh/`
- `log.*`
- large reconstructed results

## Suggested Layout

```text
cases/
  motorBike/
    0/
    constant/
    system/
    Allrun
    README.md
```

The goal is to keep reproducible inputs in git while treating heavy solver output as disposable artifacts.
