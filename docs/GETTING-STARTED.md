# Getting started

For a first-time user: what you need before you start, what to expect, and how to
get from a clean machine to a solved CFD case.

Expect **20–30 minutes**, most of it waiting for a 2.2 GiB container image to
download. You do not need to know Docker, OpenFOAM or MCP beforehand.

---

## Decide which path you want

**Path A — follow along (5 minutes).** Read `docs/ARCHITECTURE.md` and
`docs/GLOSSARY.md`. Enough to understand what the demo did and what the numbers
meant. No installation.

**Path B — run it yourself (20–30 minutes).** Continue below.

---

## Before you start — the checklist

Have all of these ready first. Each one is a blocker, and it is better to find
out now than halfway through.

- [ ] **A machine running macOS or Linux**, with at least **25 GB free disk** and
      **16 GB RAM**. On Windows you must use **WSL2** (Ubuntu) — the scripts do
      not run in PowerShell or CMD.
- [ ] **Homebrew** (macOS) or **apt/dnf** (Linux). The installer uses them.
- [ ] **Node.js 20 or newer.** The installer will install it via Homebrew if
      missing on macOS.
- [ ] **A DeepSeek account with credits** — <https://platform.deepseek.com> →
      Billing → top up. A typical case here costs **a few cents**; the account
      itself is free. Note this is a separate product from the ChatGPT/Claude
      subscription you may already have.
- [ ] **A DeepSeek API key** — same site, API Keys → create. Copy it immediately;
      it is shown once.
- [ ] **Git** and, ideally, the **GitHub CLI** (`gh`).

You do **not** need: a GPU, a cloud account, or a paid GitHub plan.

---

## Install

```bash
git clone https://github.com/MattSherwood/dafoam-mcp-starter
cd dafoam-mcp-starter
./scripts/install.sh --yes
```

The installer is idempotent — if it fails partway, fix the problem and run it
again. It will not overwrite an existing harness configuration.

It does roughly this: installs CLI packages → installs the pinned agent harness
(`dsh`) → starts a small Linux VM that provides Docker (Colima, on macOS) →
pulls the DAFoam image → fetches the working directory → registers the CFD tools
with the harness → runs the verification checks.

**Apple silicon note:** the DAFoam image is `amd64`-only, so it runs under
emulation. That is expected and supported; it is simply slower than an Intel or
AMD machine. `./scripts/install.sh --rosetta` enables faster translation at the
cost of a VM restart.

---

## Verify it works

```bash
./scripts/doctor.sh      # expect "0 failure(s)"
./scripts/verify_mcp.py  # expect 9 tools listed
```

`verify_mcp.py` talks to the CFD server directly, with no AI involved. If it
passes, the hard part is done.

Then start the assistant:

```bash
export DEEPSEEK_API_KEY=sk-...      # or complete the first-run setup in the UI
dsh web --host 127.0.0.1 --port 3080 --no-open
```

Open <http://127.0.0.1:3080> and ask:

> Is mdo_agent_deck's must_call_first tool available?

"Available" means the wiring is correct.

---

## Your first case

Type this exactly — the specific numbers matter, they are the tested set:

```
Run a steady-state CFD simulation for the NACA2412 airfoil at 2 degrees angle
of attack, on a 6000-cell mesh with yPlus 30, Ma=0.15, Re=1e6.
```

It will generate a mesh (~70 s), solve the flow (~2–3 min), and produce plots.
**If it says the run did not finish in its wait budget, ask it to "check again"** —
that is normal, and it will resume rather than restart.

### What you should see

```
C_L ≈ 0.4020    C_D ≈ 0.01508    C_M ≈ −0.0412    L/D ≈ 26.6
mesh: max non-orthogonality ≈ 51.6, max skewness ≈ 0.833, aspect ratio ≈ 435
```

### What the numbers mean — and which to distrust

- **Lift is believable.** NACA 2412 is cambered with zero-lift near −2°, and a 2D
  section gains roughly 0.11 per degree, so hand calculation gives ≈0.44. We get
  0.40 — within 9%.
- **Drag is too high.** L/D ≈ 27, whereas a clean section here should reach 50–70.
  The mesh is coarse, the wall treatment is y⁺≈30, and the turbulence model is
  fully turbulent with no transition — all three inflate drag. The same run
  produced both numbers, formatted identically.
- **This is a 2D section, steady flow, one angle of attack.** No wingtips, no
  stall, no validation data, no mesh-independence study.

That is the point of the exercise: *the tool is convincing, so you must supply the
judgement.*

---

## When something goes wrong

| Symptom | Fix |
|---|---|
| `EADDRINUSE 127.0.0.1:3080` | an old harness is running: `lsof -nP -iTCP:3080 -sTCP:LISTEN`, kill that PID |
| No `mcp__dafoam__*` tools | `dsh --profile web --dump-config \| grep mcp-dafoam`; a missing `insert:` wrapper is the usual cause |
| `MISSING_CREDENTIAL` | the API key is not visible to the process — export it, or use the UI setup |
| `no space left on device` | `docker system prune`, or delete old cases under `work/results/` |
| Plot links dead | those servers live inside the container; start the harness *first*, then run a case |
| Everything is slow | 2 CPU / 4 GiB container VM — raise it: `colima stop && colima start --cpu 6 --memory 10` |

More in `docs/RUNBOOK.md`.

---

## Asking for help

Open an issue on this repository with:

1. the output of `./scripts/doctor.sh`
2. which step failed
3. your OS and CPU architecture (`uname -sm`)

Please **do not paste your API key** — redact anything starting with `sk-`.
