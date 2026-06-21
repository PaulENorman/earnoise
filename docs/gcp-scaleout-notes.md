# GCP Scale-Out Notes

This note captures the design behind the current scale-out workflow and the next likely refinements.

## 1. VM-Native Bucket Uploads

The first launcher iteration defaulted to `UPLOAD_MODE=local` because the existing VM originally had read-only Cloud Storage scope. That path was useful as a safe bootstrap, but it does not scale for larger cases because the launcher copies artifacts back through the local machine.

### Current Direction

- keep case execution on the compute VM
- write archives and selected reconstructed outputs to local disk on the VM
- upload directly from the VM to a results bucket
- only pull small metadata or logs back locally when needed

### Safer GCP Model

- attach a dedicated service account to the VM
- grant only the bucket permissions needed for uploads
- ensure the VM has a broad enough access scope to use those IAM permissions

Practical implication for this repo:

- `UPLOAD_MODE=vm` is now the right default when the VM has the correct service account and storage scope
- the remaining optimization is reducing or removing the local artifact fetch path when it is not needed

### Suggested Artifact Split

For larger runs, keep three artifact classes:

1. `manifest.txt` and small logs for quick inspection
2. a full compressed archive for cold storage and reproducibility
3. a lighter reconstructed case tree for direct ParaView use

That is already close to the current script layout, so the main blocker is VM-side bucket auth rather than repo structure.

## 2. Remote ParaView / `pvserver`

For interactive viewing, the clean model is:

- run the solver on one VM
- stage output either on that VM disk or in a bucket
- start `pvserver` on a viewer-friendly VM
- connect from local ParaView to the remote `pvserver`

### Why Separate Viewer and Solver Nodes May Help

- large solves can saturate CPU and memory, which makes interactive rendering unpleasant
- viewer sessions often want a GPU or at least a more graphics-friendly machine shape
- keeping the viewer node separate lets us stop it independently when not inspecting results

For small tests, solver and `pvserver` can share one VM. For larger cases, splitting them is cleaner.

### Practical Connection Options

1. simplest: run `pvserver` on the same VM and forward the port over SSH from the laptop
2. more scalable: use a dedicated viewer VM with `pvserver`
3. highest-performance path later: GPU-backed viewer VM if remote rendering becomes the bottleneck

### Likely Workflow

1. run case on compute VM
2. upload archive and reconstructed case to bucket
3. start viewer VM when needed
4. download selected case data from the bucket onto the viewer VM, or mount/fuse bucket access if acceptable
5. run `pvserver`
6. connect to it from local ParaView over SSH tunneling
7. stop the viewer VM after inspection

### Repo-Level Follow-Ups

The next useful implementation steps are:

1. add a VM-preflight check that detects whether `UPLOAD_MODE=vm` is actually usable
2. document the exact service account, IAM role, and scope change needed on the compute VM
3. decide whether the viewer VM should be deleted and recreated between sessions
4. add the first non-motorBike case path beside `cfd/cases/motorBike.env`
