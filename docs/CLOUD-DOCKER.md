# Running DAFoam on a cloud / remote Docker host

You asked whether Colima is cloud-based: **it is not.** Colima is a local Lima VM
on this Mac (Apple Virtualization.framework), so it competes with macOS for the
same 16 GiB RAM and the same 24 GiB of free disk. This document covers moving
the compute elsewhere.

## The trap: `DOCKER_HOST` alone does not move the workload

DAFoam's MCP command is:

```
docker run -i --rm --platform linux/amd64 --network host \
  --mount type=bind,src=.,target=/home/dafoamuser/mount \
  -w /home/dafoamuser/mount dafoam/agent:latest \
  bash -lc 'source …/loadDAFoam.sh && mdo-agent-deck-mcp'
```

Two flags behave differently once the daemon is remote:

| Flag | Local meaning | With `DOCKER_HOST=ssh://cloud` |
|---|---|---|
| `--mount src=.` | the CLI resolves `.` against its own cwd → `/Users/<you>/…/work/results`, then the daemon mounts it (verified) | the CLI still resolves it locally, so the **cloud daemon is asked to mount a macOS path it does not have**. Fails loudly (`no such file or directory`) — or, worse, silently mounts an unrelated same-named path if one exists |
| `--network host` | binds the local VM's interfaces | binds the **cloud** host's interfaces |

Consequences:

1. You cannot keep the client-side `src=.`; it must be replaced with an absolute
   path that exists on the cloud box.
2. Cases would be written on the cloud box, not in this project. Results do not
   come back by themselves.
3. Visualization links point at cloud-internal addresses.
4. The MCP server, its state and the case directory all live remotely, while the
   MCP *client* (DSH) runs locally — every tool result round-trips over SSH.

This is survivable (SSH tunnel + rsync), but it is a distributed-systems problem,
not a config flag. Do not expect `DOCKER_HOST=ssh://…` to "just work".

## Three viable options, in increasing order of correctness

### Option 1 — Remote daemon + mirrored workspace (quick, fragile)

Mount by **absolute** path and keep the two trees in sync:

```bash
# on the cloud box: the workspace that will be mounted
ssh cloud 'mkdir -p ~/dafoam/work/results'

# locally, override the mount source and tunnel the visualizer port
docker --context cloud run -i --rm --platform linux/amd64 \
  --mount type=bind,src=/home/ubuntu/dafoam/work/results,target=/home/dafoamuser/mount \
  -w /home/dafoamuser/mount -p 5006:5006 \
  dafoam/agent:latest bash -lc 'source /home/dafoamuser/dafoam/loadDAFoam.sh && mdo-agent-deck-mcp'
```

Then `rsync -az cloud:~/dafoam/work/results/ ./work/results/` after each case,
and `ssh -L 5006:localhost:5006 cloud` for the Trame server.

Keep the *client* cwd on `work/results` (so DSH's file tools see local files) but
accept that the container writes remotely until you sync.

- Pros: no new host, one image, works today.
- Cons: two sources of truth, manual sync, `--network host` must become `-p`.

### Option 2 — Put the whole agent (client + container) on the cloud VM (best value)

Run Docker **and** the MCP client (DSH, Codex, or Claude) on one cloud VM. Then
`--mount src=.` and `--network host` are both true again, because client and
daemon share a filesystem and a loopback. Nothing about the architecture changes.

```bash
# cloud VM: Ubuntu 24.04, x86_64 (amd64 native — no emulation), 8-16 vCPU, 32-64 GiB RAM, 200 GiB SSD
sudo apt-get update && sudo apt-get install -y docker.io
sudo usermod -aG docker "$USER"
docker pull dafoam/agent:latest                     # amd64 native, fast
git clone <this project> ~/DAFoam && cd ~/DAFoam
./scripts/bootstrap.sh                              # same scripts, no Colima
```

Access DSH over `ssh -L 3080:127.0.0.1:3080 cloud`, or drive it with Codex/Claude
running on that VM.

- Pros: native amd64 (no Rosetta tax), real RAM, one filesystem, visualization
  links work, and the same MCP registration applies unchanged.
- Cons: a VM to maintain; you edit files through SSH or a synced folder.

**This is the recommended path once past tutorial-sized cases.**

### Option 3 — DAFoam HPC / Native mode (the supported heavy path)

For wing, aircraft and aero-structural optimization DAFoam itself tells you to
leave Docker mode behind and compile DAFoam on an HPC system, then run in
**HPC mode** (client on the head node, jobs via SLURM) or **Native mode**
(client on a compute node). This is the officially supported route for anything
serious, gives real MPI scaling, and uses `myHPCJob.sh` for scheduling instead of
a container.

Choose this over Option 2 if you need (a) many-core MPI runs, (b) batch queues,
or (c) reproducibility on cluster modules.

## Sizing guide (order of magnitude)

| Workload | vCPU | RAM | Notes |
|---|---|---|---|
| Tutorial mesh + 2D NACA0012 | 2–4 | 8 GiB | Colima on this Mac can do it |
| 2D airfoil optimization (ADflow adjoint) | 4–8 | 16 GiB | Rosetta penalty hurts |
| 3D wing | 8–16 | 32 GiB+ | remote or Native |
| Aircraft / aero-structural | 16–64 | 64 GiB+ | HPC mode |

Add ~10 GiB disk for the image, plus ~0.1–5 GiB per case depending on grid size.

## Decision checklist

- Just validating the workflow? → stay on local Colima, small cases only.
- Repeated 3D work? → Option 2 (agent + client on one amd64 VM), or Option 3.
- External collaborators / batch queue? → Option 3.
- Need a single `DOCKER_HOST` for *many* projects, DAFoam included? → accept
  Option 1's sync burden only if the explicit mounts and port publishing are
  scripted, never hand-typed.
