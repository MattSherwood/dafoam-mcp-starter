# DAFoam on this host — installation record and deviations

Source of truth: <https://dafoam.github.io/ai-agent-installation.html> (docs v5.1.1).
This file records the official procedure, what we did differently, and why.

## Official procedure (Docker mode)

DAFoam documents three mutually exclusive ways to run the MDO Agent Deck:
**(A) Docker**, **(B) HPC**, **(C) Native**. Docker is the only one that works
without compiling DAFoam/OpenFOAM/PETSc, so it is the right starting point here.

1. Install **one** LLM client (Codex / Claude Desktop / VS Code extension / CLI).
   DAFoam explicitly says to sign in with a subscription, **not** API keys.
2. Install **Docker Desktop**; enable
   `Settings → Resources → Network → Enable host networking`
   (needed to serve the interactive visualization pages).
3. `docker pull dafoam/agent:latest`
4. Download `mdo_agent_work` (branch `docker`), rename the extracted
   `mdo_agent_work-docker/` to `mdo_agent_work/`.
   **Do not hand-make this folder** — `mdo_agent_work/results/` contains hidden
   per-client config DAFoam relies on.
5. Open `mdo_agent_work/results/` in the LLM client and ask:
   *"Is mdo_agent_deck's must_call_first tool available?"*

## What we actually did (and why)

| Step | Official | Here | Reason |
|---|---|---|---|
| Docker engine | Docker Desktop | **Colima 0.10.3** (already installed) | Docker Desktop not present; Colima was already serving other projects |
| amd64 support | Rosetta setting in Desktop | `colima start --vz-rosetta` | `dafoam/agent:latest` publishes **amd64 only** (verified on Docker Hub); Apple silicon needs translation |
| Host networking | Desktop toggle | `--network host` inside the VM; Colima has no equivalent toggle | See "Visualization" below |
| LLM client | Codex / Claude | **DSH** via `dsh-mcp-client` (primary) + Codex/Claude configs kept | Keeps the MCP surface inside the existing harness instead of adding a second LLM |

Working directory: `work/results/` (renamed from `mdo_agent_work`), i.e. this
project *is* the DAFoam working directory, with the client-facing folder kept at
DAFoam's expected relative path.

## Verified install result

```
$ ./scripts/verify_mcp.py
MCP handshake OK in 9.4s (mdo_agent_deck 1.29.0)
9 tool(s) advertised:
  must_call_first, verify_workflow, run_workflow, resume_workflow,
  get_skill_input_info, generate_lhs_samples, get_pre_context,
  set_custom_vsp_design_vars, get_skill_advanced_parameters
```

Image digest `sha256:07569d71628450c7869003c9fe48aa55ad66b2b191d09fcebb4d355040326a85`.
Also confirmed: `--mount src=.` is resolved **client-side** to the CLI's cwd, so
the registration's `cwd` field is what places the case root, and a remote daemon
would receive an absolute macOS path (see `CLOUD-DOCKER.md`).

Not yet verified: a *simulation* or optimization (only mesh generation has been
run), and behaviour on a remote host. Mesh generation itself **is** verified:
`airfoil`/`generate-cfd-mesh`, 6K cells, NACA2412, 70.8 s end-to-end.

**Note on `scripts/colima-upgrade.sh`:** it is *not* part of this install. It
remains available for a local-only path, but if DAFoam is going to a remote host
the resize buys nothing — the VM stays emulated and still smaller than a real
workload, and the restart interrupts whatever containers you run there.


## Version pinning

| Component | Value | Note |
|---|---|---|
| `dafoam/agent` | `latest` (2.39 GB, amd64) | Pin a tag (e.g. `v0.4.6`) for reproducibility; `latest` was the only multi-arch-capable line but publishes amd64 |
| `mdo_agent_work` | branch `docker`, HEAD | Re-fetch with `scripts/bootstrap.sh` if DAFoam bumps it |
| DAFoam docs | v5.1.1 | v5 released 05/05/2026 |

> `dafoam/agent:v0.4.1` is the one tag published with an **arm64** variant. If
> native-speed execution on Apple silicon matters more than version currency,
> that tag is the only first-party escape from emulation. Everything newer is
> amd64-only, so `--platform linux/amd64` + Rosetta is the supported path.

## Data and resources

Image unpacked: ~6 GiB. Each CFD case adds a mesh + fields (tens of MB to
several GB). This host had **24 GiB free** at install time — fine for the small
tutorial cases, **not** fine for wing/aircraft aero-structural work. See
`CLOUD-DOCKER.md`.

## Visualization (verified working)

Docker Desktop's "host networking" makes the Trame/HTML servers bind to the Mac's
loopback. Colima has no such toggle — `--network host` binds **inside the VM** —
but Colima forwards VM-bound ports to the host loopback, so DAFoam's returned
links work unchanged:

```
html_url:  http://localhost:8001/plots/mesh.html
trame_url: http://localhost:8002
```

Verified with an HTTP server bound inside the VM: it answered at
`127.0.0.1:8001` from macOS. No `--network-address` or `-p` publishing needed.

**Caveat:** those servers run inside the ephemeral MCP container. They are up
only while the MCP session is alive, so links go dead once the client
disconnects. For a live demo, connect the client first, then run the case.
Concurrent sessions would also collide on ports 8001/8002.

## Licensing

The MDO Agent Deck framework is **not open source**. DAFoam distributes it on
PyPI as a compiled shared-library package for evaluation, with a separate
LICENSE. The MCP server repo (`DAFoam/dafoam_mcp_server`) and DAFoam itself are
open source. Treat the agent deck as a licensed dependency, not a vendored one —
none of it is compiled into this project.
