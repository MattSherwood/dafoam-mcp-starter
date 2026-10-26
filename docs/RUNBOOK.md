# Runbook

## Daily flow

```bash
./scripts/doctor.sh          # preflight, read-only
./scripts/bootstrap.sh       # idempotent: workdir + image + handshake
./scripts/verify_mcp.py      # handshake + tool list only
```

In DSH, ask the server's entry point first — DAFoam's own smoke test:

> Is mdo_agent_deck's `must_call_first` tool available?

Then a small case:

> Generate a CFD mesh for the NACA2412 airfoil with 20K cells and yPlus 3.

Tools appear as `mcp__dafoam__must_call_first` … `mcp__dafoam__get_skill_advanced_parameters`.

## Verified baseline (this host)

| Check | Result |
|---|---|
| Image | `dafoam/agent:latest`, amd64, 2.23 GiB, `sha256:07569d71…326a85` |
| MCP server | `mdo_agent_deck 1.29.0`, protocol `2025-06-18` |
| Handshake time | 9.4 s under QEMU binfmt (no Rosetta) |
| Tools advertised | 9 (see below) |
| Relative bind mount | `--mount src=.` resolves to the client's cwd — confirmed |
| `must_call_first` tool call | **verified** — returns the live agent/skill catalogue (airfoil, wing, aero-structural chains) |
| End-to-end mesh case | **verified** — `airfoil`/`generate-cfd-mesh`, NACA2412, 6K cells, **70.8 s** total |
| Mesh quality | 6000 cells · max non-ortho 51.6 · max skewness 0.833 · max aspect ratio 435 |
| Visualization links | **verified reachable** — `localhost:8001` (HTML) and `localhost:8002` (Trame) work from macOS |
| Free disk after pull | **11 GiB** (was 24); a 6K mesh case costs ~7 MB |

Case output layout: `work/results/airfoil_mesh_0000/` with `plots/mesh.html`,
`mesh_analysis_metrics.json`, `bash_generate-cfd-mesh_run_001.sh` (replayable),
plus `agent_workflow.json` / `agent_state.json` at the results root.

> Viz caveat: the HTML/Trame servers live inside the ephemeral MCP container, so
> they are up only while the MCP session is. Connect the client, then run.

Advertised tools:

```
must_call_first            get_skill_input_info       get_pre_context
verify_workflow            generate_lhs_samples       set_custom_vsp_design_vars
run_workflow               resume_workflow            get_skill_advanced_parameters
```

## Contract: never skip the guardrail

1. `must_call_first` → returns the agent/skill/scenario catalogue for the session.
2. `get_skill_input_info` → exact parameter schema for the chosen skill.
3. `verify_workflow` → validates agent+skill+scenario+inputs against intent.
4. `run_workflow` → deterministic execution.
5. `resume_workflow` → continue after an interruption (`agent_state.json`).

`verify_workflow` is the point of the framework. Calling `run_workflow` directly
bypasses the consistency check and is the main way to get a silently wrong case.

## Where state lives

| File | Meaning |
|---|---|
| `work/results/agent_workflow.json` | per-case phase history with timestamps |
| `work/results/agent_state.json` | resumable bindings |
| `work/results/bash_*_run_001.sh` | exact replay of each phase |
| `work/results/<case>/` | mesh, fields, postProcessing |

DAFoam requires the LLM's cwd to be the results folder. To run two cases in
parallel, copy the folder (`results1/`, `results2/`) — each needs its own MCP
server instance, which means its own `cwd` in the DSH registration.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No `mcp__dafoam__*` tools in DSH | patch entry not applied | `dsh --profile web --dump-config \| grep mcp-dafoam`. If it warns `patch: entry "mcp-dafoam" not found`, the entry is missing its `insert:` wrapper — see `config/dsh/cordis.patch.yml` |
| `patch: entry … not found` on boot | bare `- id:` in the patch layer updates rather than adds | wrap in `- insert:` with no patch-level `id` |
| Tools listed but no `dafoam` container | MCP client failed to spawn | run `./scripts/verify_mcp.py` to isolate docker from DSH |
| Handshake times out | QEMU translation + cold image | `./scripts/verify_mcp.py --timeout 900` |
| `docker: no such file or directory` on mount | cwd wrong | registration must set `cwd` to `work/results` |
| `no space left on device` | 11 GiB headroom | `docker system prune`, delete `work/results/<case>` |
| Case crawls / OOM-killed | 2 CPU / 3.8 GiB VM | see `CLOUD-DOCKER.md`; do not expect 3D cases locally |
| Visualization link unreachable | servers died with the MCP container | connect the client first, then run; links live only while the session does |
| `exec format error` | amd64 image, no binfmt/Rosetta | keep `--platform linux/amd64`; Rosetta optional |

## Reverting the DSH registration

Delete the `- id: mcp-dafoam` block from
`~/.dsh/profiles/web/cordis.patch.yml`, leaving `[]`, and refresh.

## Why Colima is *not* the target architecture

Colima is a macOS-only Docker shim. It is here because Docker was already
available on this Mac, not because DAFoam wants it. For a remote host you need
Docker on that host and the MCP client next to it — Colima plays no part. See
the decision table in `CLOUD-DOCKER.md`.

Do **not** run `scripts/colima-upgrade.sh` if the plan is remote: it restarts
Colima (interrupting any containers you run there) and spends local RAM/disk on a VM that is
still too small and still emulated.
