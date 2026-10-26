# Third-party notices

This repository's own documentation and scripts are licensed under the
**Apache License 2.0** (see `LICENSE` and `NOTICE`).

That licence does **not** extend to the software this repository helps you
run. The components below remain under their own terms. This repository
contains **configuration, documentation and scripts only** — it does not
vendor, link or redistribute any DAFoam software.

## DAFoam

The DAFoam solver, adjoint framework and its Python/OpenFOAM layers are open
source: <https://github.com/DAFoam/DAFoam> (see that repository for the license).

## MDO Agent Deck (`dafoam/agent` image, `mdo-agent-deck` on PyPI)

**Not open source.** DAFoam distributes the MDO Agent Deck framework on PyPI as a
compiled shared-library package for evaluation purposes, under its own LICENSE
terms. It is referenced here only as an external container image pulled at
install time (`dafoam/agent:latest`).

Do not redistribute the image, the wheel, or anything derived from their
contents as part of this repository.

## `dafoam_mcp_server`

The MCP server repository is open source:
<https://github.com/DAFoam/dafoam_mcp_server>.

## `mdo_agent_work`

The working directory contents under `work/results/` are copied from
<https://github.com/DAFoam/mdo_agent_work> (branch `docker`). Treat that
directory as upstream material: do not assume this repository's terms apply to
it, and re-fetch rather than fork where possible (`scripts/bootstrap.sh` is
idempotent).

## OpenFOAM, PETSc, CGNS, IPOPT, SNOPT, MACH, OpenMDAO

Bundled inside the `dafoam/agent` image, each under its own license. Nothing is
compiled or redistributed here.
