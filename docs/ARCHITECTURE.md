# Architecture: DAFoam, MCP and the harness

## 1. What DAFoam actually exposes

DAFoam v5 is not a single program. Four layers matter for integration:

```
┌──────────────────────────────────────────────────────────────────────┐
│  MDO Agent Deck  ("dafoam/agent" container, amd64)                   │
│  ├─ domain agents:  airfoil · wing · aircraft                        │
│  ├─ skills:         generate-cfd-mesh · run-cfd-simulation · optimize│
│  ├─ scenarios:      one skill / N runs / prereq→downstream chains    │
│  └─ MCP server:     `mdo-agent-deck-mcp` on stdio                    │
│        tools: must_call_first, workflow-verification, run-workflow,  │
│               analyze / post-process, visualization servers          │
├──────────────────────────────────────────────────────────────────────┤
│  DAFoam (adjoint-enabled OpenFOAM solver + Python layer)             │
│  OpenFOAM · PETSc/petsc4py · CGNS · IPOPT/SNOPT · MACH/OpenMDAO      │
├──────────────────────────────────────────────────────────────────────┤
│  Case assets & templates, results/, agent_workflow.json              │
└──────────────────────────────────────────────────────────────────────┘
```

Key properties:

- **Transport is stdio**, one process per client session, `--rm` ephemeral.
  There is no long-running DAFoam HTTP service to deploy.
- **Deterministic core, narrow model agency.** The model only chooses
  agent/skill/scenario, maps user parameters, and reacts to review feedback.
  Everything downstream is a fixed script. The verification tool refuses
  mismatched inputs before anything runs.
- **Auditable by construction.** Each case writes `agent_workflow.json`
  (phase history), `agent_state.json` (resumable bindings) and replayable
  `bash_*.sh` scripts.
- **Working directory is load-bearing.** `results/` ships hidden per-client MCP
  config; `--mount src=.` means the client's cwd *is* the container's case root.

## 2. Where DSH sits

DSH is already an MCP **host**. `@deepseek-ai/dsh-mcp-client` bridges a stdio
server's tools into the native tool namespace as `mcp__<server>__<tool>`.
So DAFoam needs no adaptation — only registration:

```
  DSH session
    ├── native tools (bash, read, edit, …)
    ├── mcp__dafoam__must_call_first        ← dafoam/agent container (stdio)
    ├── mcp__dafoam__…                      ← spawned once, reused per session
    └── (optional) mcp__<your-hub>__…       ← your own MCP server
```

`config/dsh/cordis.patch.yml` is the registration. Three details carry the weight:

| Field | Why |
|---|---|
| `insert:` wrapper | the patch layer only *adds* entries inside `insert:`. A bare `- id: mcp-dafoam` means "update an existing entry" and is silently skipped |
| `cwd: …/work/results` | makes DAFoam's `--mount src=.` resolve to the case root |
| `toolCallTimeoutMs: 900000` | default 60 s would abort mesh/optimization phases |

The loader **hot-applies** this file — no restart. Verify composition without
touching the running server:

```bash
dsh --profile web --dump-config | grep -A12 mcp-dafoam   # no "not found" warning
docker ps --format '{{.Image}}' | grep dafoam            # client connected
```

## 3. Integrating with an existing MCP host

If you already operate an MCP server of your own — an internal "hub" exposing
house tooling — there are two ways to combine it with DAFoam.

### Pattern A — peers (recommended)

```
        ┌─────────────┐
        │  MCP host   │   (DSH, or any MCP client)
        └──┬───────┬──┘
           │       │
   mcp__house__    mcp__dafoam__
           │       │
      your hub   dafoam/agent
```

The host mounts both servers as siblings. No proxy, no re-serialisation; each
server keeps its own tool semantics and timeouts, and the model chooses which
namespace to call. Cost: both tool sets occupy every request.

### Pattern B — your hub becomes the single front door

Requires your hub to be an MCP **client** as well as a server: a module that
spawns the same `docker run … mdo-agent-deck-mcp` command through an MCP stdio
client and re-exports selected tools. This adds a hop, doubles startup cost, and
forces one timeout policy onto two very different workloads. Worth it only if
external callers must see exactly one endpoint.

**Recommendation:** adopt Pattern A first. If the hub later becomes a gateway,
add Pattern B behind a feature flag rather than folding the container spawn into
an existing shell-command dispatcher — the two execution models (short-lived
shell subprocess vs. long-lived stdio protocol) should not share a module.

### Preserve the audit trail

Whatever you choose, `agent_workflow.json` plus the generated `bash_*.sh` are the
most valuable integration surface: a per-case, replayable record of what was
requested and what ran. Feed those into whatever telemetry store your hub uses.

## 4. Host topology

The Docker host is the only environmental variable that changes between
"laptop smoke test" and "real case":

| Topology | Image runs on | Bind mount resolves on | Good for |
|---|---|---|---|
| Colima (this host) | local VM, Rosetta | this Mac (`virtiofs`, `$HOME`) | tutorials, small airfoils |
| Remote daemon (`DOCKER_HOST=ssh://…`) | cloud VM | **remote** filesystem | — see caveat |
| Agent container + client both on cloud VM | cloud VM | cloud VM | heavy wing/aircraft |
| Native/HPC mode (no Docker) | bare metal / SLURM | local disk | production optimization |

The caveat on remote daemons is architectural, not cosmetic: `--mount src=.` and
`--network host` are resolved **by the daemon**, so pointing `DOCKER_HOST` at a
remote box silently mounts a *remote* `.` — usually an empty directory — and the
visualization servers bind to the remote host. See `CLOUD-DOCKER.md`.

## 5. Constraints to design around

| Constraint | Value | Consequence |
|---|---|---|
| Image arch | amd64 only | Rosetta required on Apple silicon; expect 2–4× slowdown vs. native |
| VM RAM | 3.8 GiB default | enough for 2D meshes/tutorials; not for 3D grids |
| Host disk | 24 GiB free | image + a few cases; not a case archive |
| Agent Deck license | closed, evaluation | don't vendor or redistribute |
| MCP transport | stdio, `--rm` | state lives in `results/`, not in the process |
