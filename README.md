# DAFoam + DSH starter

A reproducible environment for driving **[DAFoam](https://dafoam.github.io/index.html)**'s
MDO Agent Deck — adjoint-enabled CFD and shape optimisation on OpenFOAM — through
an MCP-capable agent harness.

The interesting part is not the CFD. It is that DAFoam exposes its engineering
workflows over **MCP** (Model Context Protocol), so an AI client can drive mesh
generation, solver runs and optimisation — while the framework keeps the model on
a short leash: a fixed catalogue of skills, a verified payload, and a refusal to
claim a run finished before it has evidence.

This repo is the *how to run it* half: wiring, scripts, and the constraints that
cost real time to discover.

---

## What you get

| | |
|---|---|
| `scripts/install.sh` | idempotent installer for macOS / Linux / WSL2 |
| `scripts/doctor.sh` | read-only preflight (host, Docker VM, disk, image, registration) |
| `scripts/verify_mcp.py` | raw MCP handshake — proves the server works, no LLM involved |
| `scripts/demo_case.py` | deterministic single case over MCP (pre-warm or fallback) |
| `config/mcp/dafoam.json` | MCP server descriptor template |
| `docs/REPRODUCE.md` | **start here** — full component inventory with versions and links |
| `docs/INSTALL.md` | the official DAFoam procedure and every deviation, justified |
| `docs/ARCHITECTURE.md` | layers, harness wiring, integration patterns |
| `docs/RUNBOOK.md` | operate / verify / troubleshoot |
| `docs/GLOSSARY.md` | one line per term — y⁺, RANS, Spalart–Allmaras, adjoints |
| `docs/CLOUD-DOCKER.md` | running the compute elsewhere, and the mount trap |

## Quickstart

```bash
# 0. prerequisites: Homebrew (macOS) or apt/dnf (Linux), Node 20+, a DeepSeek API key
./scripts/install.sh --yes

# 1. harness
export DEEPSEEK_API_KEY=sk-...
dsh web --host 127.0.0.1 --port 3080 --no-open

# 2. open http://127.0.0.1:3080 and ask:
#    "Is mdo_agent_deck's must_call_first tool available?"
```

The installer pulls a 2.2 GiB image, so give it ~20 minutes on a fresh machine.
It is idempotent and will not overwrite an existing DSH patch layer that holds
other settings.

Verified timings on an Apple-silicon laptop (2 CPU / 4 GiB container VM, amd64
emulation):

| Step | Time |
|---|---|
| MCP handshake | ~9 s |
| 6 000-cell airfoil mesh | ~70 s |
| mesh + steady CFD solve | ~4 min (427 iterations) |

## The three things that bite

1. **`insert:` is mandatory** in the DSH patch layer. A bare `- id: …` means
   *update an existing entry* and is silently skipped — the harness boots with no
   MCP server and no error.
2. **`cwd` must be the working directory DAFoam expects** (`work/results`).
   DAFoam binds `src=.`, so the client's working directory *becomes* the case root.
3. **`--platform linux/amd64` must stay.** The image publishes amd64 only; on
   Apple silicon it runs under Rosetta or QEMU.

## What is deliberately absent

- `work/results/` — fetched by the installer from
  [`DAFoam/mdo_agent_work`](https://github.com/DAFoam/mdo_agent_work); upstream
  material should be fetched, not forked.
- Case directories, transcripts and generated bake-off scripts — output of the
  MDO Agent Deck, which is **closed source** (see `NOTICE.md`).
- Anything containing a personal path or credential.

## Licensing

DAFoam and `dafoam_mcp_server` are open source. The **MDO Agent Deck** shipped
inside `dafoam/agent` is closed source and distributed for evaluation only —
this repo tells you how to pull and run it, and redistributes none of it. Read
`NOTICE.md` before deploying anything commercially.

## Requirements at a glance

macOS or Linux (Windows via WSL2), 16 GiB RAM, ~25 GiB free disk, Docker (Colima
on macOS), Node 20+, Python 3.9+, and a DeepSeek account with credits. Full
detail, with links: [`docs/REPRODUCE.md`](docs/REPRODUCE.md).
