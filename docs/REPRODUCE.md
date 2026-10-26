# Reproducing this environment

Everything needed to rebuild this setup on another machine — a full component
inventory with versions, links, what each part does, and why it is needed.

Versions below were captured from the reference machine and are the ones
**verified working together**. Where a version is not pinned, that is called out.

---

## 0. What you are actually building

```
┌─────────────────────────────────────────────────────────────────────────┐
│ OS + terminal (macOS, or Linux / WSL2 on Windows)                       │
│                                                                         │
│  ┌───────────────────────────┐        ┌──────────────────────────────┐  │
│  │ Editor: VS Code Insiders  │        │ DSH — DeepSeek Harness       │  │
│  │  + Harness extension      │◄──────►│  web UI at 127.0.0.1:3080    │  │
│  │  + Python ext / Pylance   │        │  MCP client + tool registry  │  │
│  └───────────────────────────┘        └───────────────┬──────────────┘  │
│                                                       │ MCP over stdio  │
│                                       ┌───────────────▼──────────────┐  │
│                                       │ Container runtime            │  │
│                                       │  Colima (macOS) / Docker     │  │
│                                       │  ┌────────────────────────┐  │  │
│                                       │  │ dafoam/agent (amd64)   │  │  │
│                                       │  │  mdo-agent-deck-mcp    │  │  │
│                                       │  │  OpenFOAM + DAFoam     │  │  │
│                                       │  └────────────────────────┘  │  │
│                                       └──────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

The one non-obvious idea: **DSH is the MCP host**. It spawns the DAFoam
container as a stdio MCP server and exposes its tools to the model. There is no
long-running DAFoam service to deploy.

---

## 1. Requirements at a glance

| Component | Version here | Required? | Why |
|---|---|---|---|
| macOS / Linux / WSL2 | macOS 26.7.1 arm64 | **yes** | Container runtime and shell tooling; Windows must use WSL2 |
| Homebrew | 7.0.10 | **yes** (macOS) | Installs every other CLI below |
| Git | 2.54.0 | **yes** | Clone the workspace, version your cases |
| GitHub CLI (`gh`) | 2.88.1 | recommended | Private remotes, releases, publishing the deck |
| Node.js | v26.0.0 | **yes** | Runs `dsh` |
| npm | 11.12.1 | **yes** | Installs `dsh` |
| `@deepseek-ai/dsh` | 0.1.5-rc.3 | **yes** | The agent harness / MCP host |
| DeepSeek account + credits | — | **yes** | Model access for the agent |
| DeepSeek API key | — | **yes** | Authenticates `dsh` to the model endpoint |
| Container runtime | Docker 29.5.2 server | **yes** | DAFoam ships only as a container image |
| Colima | 0.10.3 | macOS only | Lightweight Linux VM providing Docker without Docker Desktop |
| `dafoam/agent` image | `latest`, amd64, 2.23 GiB | **yes** | The CFD stack and MCP server |
| `mdo_agent_work` | branch `docker` | **yes** | The working directory the agent requires |
| Python 3 | 3.15.0 | recommended | Helper scripts (stdlib only) |
| VS Code Insiders | current | recommended | Convenient editor; also hosts the Harness extension |
| Harness VS Code extension | 1.0.0 | optional | Editor integration; `dsh web` works without it |
| Rosetta (Apple silicon) | Apple's translation | optional | Speeds up the amd64 image; QEMU fallback works |

**Disk:** ~8 GiB for the image, plus ~10 MB per CFD case. Leave 20 GiB free.
**RAM:** 16 GiB host is workable; the container VM needs 8 GiB to be useful.

---

## 2. Component inventory

### 2.1 Terminal environment

**What it is.** A POSIX shell (`zsh` on macOS, `bash` elsewhere) with standard
coreutils.

**What it does.** Everything here is driven from a shell: installing packages,
starting the container runtime, launching `dsh`, running the scripts.

**Why it is needed.** The DAFoam MCP server is spawned as a subprocess. There is
no GUI-only path.

**Windows.** Install **WSL2** with Ubuntu, then follow the Linux instructions
inside it. Native PowerShell/CMD is not supported by these scripts.
Link: <https://learn.microsoft.com/windows/wsl/install>

---

### 2.2 Homebrew (macOS package manager)

**What it is.** The de-facto package manager for macOS.
**What it does.** Installs and upgrades git, gh, node, python, colima, docker.
**Why it is needed.** Version-consistent CLI tooling without manual downloads.
**Link:** <https://brew.sh> · **Install:**

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

**Packages to install:**

| Package | Purpose |
|---|---|
| `git` | version control (macOS Xcode git also works) |
| `gh` | GitHub CLI — private remotes, releases, Pages |
| `node` | JavaScript runtime for `dsh` |
| `python@3.13` | helper scripts (`scripts/*.py`) |
| `colima` | Linux VM that provides Docker on macOS |
| `docker` | Docker CLI (client only; Colima provides the daemon) |
| `docker-compose` | optional; only for other projects |
| `jq` | optional; inspecting JSON results by hand |

```bash
brew install git gh node python@3.13 colima docker jq
```

---

### 2.3 Git and GitHub CLI

**What they are.** `git` is distributed version control. `gh` is GitHub's
command-line client.
**What they do.** `git` tracks the workspace and the generated cases; `gh`
creates private repositories, cuts releases, and enables GitHub Pages.
**Why they are needed.** Reproducibility rests on being able to check out an
exact state; `gh` is what makes the release and publishing steps scriptable.

```bash
git --version        # 2.54.0
gh --version         # 2.88.1
gh auth login        # choose HTTPS, authenticate via browser
```

**Links:** <https://git-scm.com> · <https://cli.github.com>

---

### 2.4 Node.js and npm

**What they are.** A JavaScript runtime and its package manager.
**What they do.** `dsh` is a Node application; npm installs it globally.
**Why they are needed.** There is no non-Node distribution of `dsh`.

```bash
node --version   # v26.0.0 on the reference machine; v20+ expected to work
npm --version    # 11.12.1
```

**Link:** <https://nodejs.org> (or `brew install node`)

---

### 2.5 DSH — DeepSeek Harness

**What it is.** A plugin-composed agent harness: it runs a model, exposes a tool
registry, and hosts **MCP clients** that bridge external tools into that
registry.

**What it does here.** Provides the web UI at `127.0.0.1:3080`, spawns the
DAFoam container as a stdio MCP server, and surfaces its nine tools to the model
as `mcp__dafoam__<tool>`. It also records session history and enforces the
sandbox/file policy.

**Why it is needed.** It is the thing that turns the DAFoam container into
something an LLM can drive. Without it there is no conversation, only a Docker
command.

**Install (pin the version for reproducibility):**

```bash
npm install -g @deepseek-ai/dsh@0.1.5-rc.3
dsh --version     # 0.1.5-rc.3
```

**Link:** <https://www.npmjs.com/package/@deepseek-ai/dsh>

**Layout it creates:** everything lives under `$DSH_HOME` (default `~/.dsh`):

| Path | Purpose |
|---|---|
| `~/.dsh/settings.yaml` | UI preferences |
| `~/.dsh/profiles/web/cordis.patch.yml` | **your patch layer** — where the DAFoam MCP server is registered |
| `~/.dsh/profiles/web/package.json` | profile manifest and out-of-tree plugins |
| `~/.dsh/.credentials.yaml` | credential references (not the secret itself) |
| `~/.dsh/sessions/` | per-workspace session history |

---

### 2.6 DeepSeek account, credits and API key

**What it is.** A DeepSeek platform account with a purchased credit balance, and
an API key derived from it.

**What it does.** Pays for and authenticates model calls. `dsh` resolves the key
through a credential reference named **`DEEPSEEK_API_KEY`**: either from the
environment or from DSH's own credential store, populated during first-run setup
in the web UI.

**Why it is needed.** No key, no model calls — the harness starts, but every
request fails with `MISSING_CREDENTIAL` or `AUTH`.

**Steps:**

1. Create an account at <https://platform.deepseek.com>
2. Add credits (Billing → Top up). Free tiers are for evaluation only.
3. API Keys → Create. Copy it once; it is not shown again.
4. Provide it to DSH, either:
   - first-run setup in the web UI (`dsh web`, follow the prompt), or
   - export `DEEPSEEK_API_KEY=sk-…` in the shell that launches `dsh`.

```bash
# verify the key is visible to the process that will run dsh
[ -n "${DEEPSEEK_API_KEY:-}" ] && echo "key present" || echo "key missing"
```

> **Do not commit the key.** `.gitignore` already excludes common patterns, but
> never place it in `cordis.patch.yml`.

**Link:** <https://platform.deepseek.com>

---

### 2.7 Editor: VS Code Insiders

**What it is.** The nightly build of VS Code. Stable VS Code works equally well.
**What it does.** Edits the workspace, the deck, and the case files; the Harness
extension adds editor-level integration with `dsh`.
**Why it is needed.** Optional. Nothing in the pipeline requires it — but it is
the comfortable place to read `agent_workflow.json`, edit Markdown docs, and run
terminals.

**Link:** <https://code.visualstudio.com/insiders>

**Extensions actually used on the reference machine:**

| Extension ID | Role | Needed? |
|---|---|---|
| `vithrive.deepseek-harness-vscode` | Harness integration | **recommended** |
| `ms-python.python` | Python language support | recommended |
| `ms-python.vscode-pylance` | Python IntelliSense | recommended |
| `ms-python.debugpy` | Python debugging | optional |
| `vizards.deepseek-v4-for-copilot` | Copilot integration | **not part of this pipeline** |

Install by ID (`Cmd-Shift-X`, then search the exact ID) or:

```bash
code-insiders --install-extension vithrive.deepseek-harness-vscode
code-insiders --install-extension ms-python.python
code-insiders --install-extension ms-python.vscode-pylance
```

> The `deepseek-v4-for-copilot` extension belongs to a different workflow. Do not
> assume it is required just because it is installed.

---

### 2.8 Container runtime — Colima + Docker (macOS)

**What they are.** Docker runs Linux containers. On macOS there is no Linux
kernel, so a VM is required. **Colima** is a small CLI-driven VM (Lima + Apple
Virtualization.framework) that provides the Docker daemon without Docker Desktop.
On Linux, Docker runs natively and Colima is unnecessary.

**What they do.** Run `dafoam/agent`, an **amd64-only** Linux image, and bind-mount
the working directory into it.

**Why they are needed.** DAFoam is distributed as a container image; there is no
supported native macOS build.

```bash
# macOS
brew install colima docker
colima start --cpu 4 --memory 8 --disk 40

# Apple silicon: optionally enable Rosetta for the amd64 image (faster)
colima stop && colima start --cpu 4 --memory 8 --disk 40 --vm-type vz --vz-rosetta
```

**Verify:**

```bash
docker info --format '{{.OperatingSystem}} / {{.Architecture}} / {{.NCPU}} CPU'
```

**Links:** <https://github.com/abiosoft/colima> · <https://docs.docker.com>

> **Networking note (macOS).** Docker Desktop's "host networking" toggle does not
> exist in Colima. It is not needed: DAFoam's visualisation servers bind inside
> the VM and Colima forwards them to `127.0.0.1` on the host. Verified.

---

### 2.9 The DAFoam image

**What it is.** A pre-compiled container holding OpenFOAM, DAFoam's adjoint
solver, PETSc, CGNS, and the **MDO Agent Deck** — DAFoam's agentic layer, which
exposes an MCP server called `mdo-agent-deck-mcp`.

**What it does.** Generates meshes, runs steady/unsteady CFD, and runs
adjoint-based shape optimisation, orchestrated through MCP tools.

**Why it is needed.** It *is* the engineering capability. Everything else is
plumbing.

```bash
docker pull dafoam/agent:latest
docker image inspect dafoam/agent:latest --format '{{.Architecture}} {{.Size}}'
# amd64 2393026461
```

| Property | Value |
|---|---|
| Size | 2.23 GiB (amd64 only) |
| Digest | `sha256:07569d71628450c7869003c9fe48aa55ad66b2b191d09fcebb4d355040326a85` |
| MCP protocol | 2025-06-18 |
| Deck version | `mdo_agent_deck 1.29.0` |

> **Licence.** The DAFoam solver is open source, but the **MDO Agent Deck is
> closed source**, distributed for evaluation. You may pull the image; you may
> not redistribute it or its contents. See `NOTICE.md`.

**Links:** <https://dafoam.github.io/index.html> ·
<https://dafoam.github.io/ai-agent-overview.html> ·
<https://dafoam.github.io/ai-agent-installation.html> ·
<https://github.com/DAFoam/dafoam_mcp_server>

---

### 2.10 The DAFoam working directory

**What it is.** `mdo_agent_work`, branch `docker` — a small directory of hidden
per-client configuration that DAFoam's MCP server expects.

**What it does.** Provides `results/`, which is simultaneously the agent's working
directory, the case root, and the bind-mount target.

**Why it is needed.** DAFoam refuses to run without it, and the MCP command binds
`src=.` — so the client's working directory *is* the case root.

```bash
curl -fsSL https://github.com/DAFoam/mdo_agent_work/archive/refs/heads/docker.zip -o /tmp/maw.zip
unzip -q /tmp/maw.zip -d /tmp
mkdir -p work && cp -R /tmp/mdo_agent_work-docker/. work/
ls work/results/.mcp.json     # must exist
```

**Link:** <https://github.com/DAFoam/mdo_agent_work/tree/docker>

---

### 2.11 Python

**What it is.** A Python 3 interpreter.
**What it does.** Runs `scripts/verify_mcp.py` (MCP handshake probe),
`scripts/demo_case.py` (deterministic case driver), and the deck build helpers.
**Why it is needed.** Convenient, not load-bearing — the same work can be done
with `jq` and a raw pipe, but the scripts use **stdlib only**, so any Python ≥3.9
works.

```bash
python3 --version    # 3.15.0 on the reference machine
```

**Link:** <https://www.python.org>

---

### 2.12 Documentation set

| Document | What it covers |
|---|---|
| `README.md` | quickstart and project layout |
| `docs/REPRODUCE.md` | this file — full component inventory |
| `docs/INSTALL.md` | the official DAFoam procedure and every deviation, justified |
| `docs/ARCHITECTURE.md` | DAFoam layers, DSH wiring, integration patterns |
| `docs/RUNBOOK.md` | operate / verify / troubleshoot |
| `docs/GLOSSARY.md` | one line per term (y⁺, RANS, Spalart–Allmaras…) |
| `docs/CLOUD-DOCKER.md` | running the compute elsewhere, and the mount trap |
| `NOTICE.md` | third-party licensing |

External references:
- DAFoam — <https://dafoam.github.io/index.html>
- MCP specification — <https://modelcontextprotocol.io>
- OpenFOAM — <https://openfoam.org>
- Colima — <https://github.com/abiosoft/colima>

---

### 2.13 Demo artifacts

What a successful reproduction produces under `work/results/`:

| Artifact | What it is | Size |
|---|---|---|
| `airfoil_mesh_000N/` | one meshed case | ~3 MB |
| `airfoil_cfd_000N/` | one meshed + solved case | ~7 MB |
| `plots/mesh.html` | mesh quality figures | small |
| `plots/cfd.html` | pressure contours, Cp, convergence | small |
| `mesh_analysis_metrics.json` | non-orthogonality, skewness, aspect ratio | tiny |
| `bash_*_run_001.sh` | **replayable** command script per phase | tiny |
| `agent_workflow.json` | per-case phase history with timestamps | tiny |
| `agent_state.json` | resumable bindings | tiny |

Reference results to compare against (NACA 2412, 2°, 6 000 cells, y⁺30,
Ma 0.15, Re 1×10⁶):

```
C_L 0.4016   C_D 0.01508   C_M −0.0412   L/D 26.6   iterations 427
mesh: max non-orthogonality 51.6, max skewness 0.833, max aspect ratio 435
two independent runs agreed to 5 significant figures
```

---

## 3. The wiring that actually matters

DSH profile patch — `~/.dsh/profiles/web/cordis.patch.yml`:

```yaml
- insert:
    - id: mcp-dafoam
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: dafoam
        transport: stdio
        cwd: <ABSOLUTE-PATH-TO>/Projects/DAFoam/work/results   # must be absolute
        command: docker
        args:
          - run
          - -i
          - --rm
          - --platform
          - linux/amd64
          - --network
          - host
          - --mount
          - type=bind,src=.,target=/home/dafoamuser/mount
          - -w
          - /home/dafoamuser/mount
          - dafoam/agent:latest
          - bash
          - -lc
          - source /home/dafoamuser/dafoam/loadDAFoam.sh && mdo-agent-deck-mcp
        toolCallTimeoutMs: 900000
        failOnStartupError: false
```

Three things are easy to get wrong:

1. **`insert:` is mandatory.** A bare `- id: mcp-dafoam` at this layer means
   *update an existing entry* and is skipped with only a warning. The harness
   boots happily, with no MCP server.
2. **`cwd` must be `work/results`.** DAFoam binds `src=.`, so the client's working
   directory becomes the case root.
3. **`--platform linux/amd64` must stay.** The image publishes amd64 only; on
   Apple silicon it runs under Rosetta or QEMU.

**Verify without restarting anything** (the loader hot-applies this file):

```bash
dsh --profile web --dump-config | grep -A12 mcp-dafoam    # no "not found" warning
docker ps --format '{{.Image}}' | grep dafoam             # client connected
```

---

## 4. Manual installation, in order

```bash
# 1 — tooling
brew install git gh node python@3.13 colima docker jq

# 2 — harness
npm install -g @deepseek-ai/dsh@0.1.5-rc.3

# 3 — container runtime
colima start --cpu 4 --memory 8 --disk 40

# 4 — DAFoam image
docker pull dafoam/agent:latest

# 5 — workspace
git clone <this repo> ~/Projects/DAFoam
cd ~/Projects/DAFoam
curl -fsSL https://github.com/DAFoam/mdo_agent_work/archive/refs/heads/docker.zip -o /tmp/maw.zip
unzip -q /tmp/maw.zip -d /tmp && mkdir -p work && cp -R /tmp/mdo_agent_work-docker/. work/

# 6 — API key
export DEEPSEEK_API_KEY=sk-...

# 7 — register the MCP server (see §3), then:
./scripts/doctor.sh            # expect 0 failures
./scripts/verify_mcp.py        # expect 9 tools

# 8 — run
dsh web --host 127.0.0.1 --port 3080 --no-open
```

---

## 5. Automated installation

```bash
./scripts/install.sh --yes
```

The script is idempotent and **non-destructive**: it never overwrites an existing
`cordis.patch.yml` that contains other settings — it writes a sidecar file and
tells you to merge. It detects macOS vs Linux/WSL, skips what is already present,
and finishes by running the verification checks.

See `scripts/install.sh --help` for flags.

---

## 6. Verification checklist

| # | Check | Command | Expected |
|---|---|---|---|
| 1 | Harness runs | `dsh --version` | `0.1.5-rc.3` |
| 2 | Docker reachable | `docker info` | daemon reachable |
| 3 | Image present | `docker image inspect dafoam/agent:latest` | amd64, 2.23 GiB |
| 4 | Working directory | `ls work/results/.mcp.json` | file exists |
| 5 | Preflight | `./scripts/doctor.sh` | 0 failures |
| 6 | MCP handshake | `./scripts/verify_mcp.py` | 9 tools, `<60 s` |
| 7 | Registered | `dsh --profile web --dump-config \| grep mcp-dafoam` | entry, no warning |
| 8 | End-to-end | ask DSH for a 6 000-cell NACA 2412 mesh | ~70 s |

---

## 7. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `EADDRINUSE 127.0.0.1:3080` | an older `dsh web` is still running | `lsof -nP -iTCP:3080 -sTCP:LISTEN` then kill that PID |
| No `mcp__dafoam__*` tools | patch entry skipped | `dsh --profile web --dump-config \| grep mcp-dafoam`; check for `insert:` |
| `patch: entry "mcp-dafoam" not found` | bare `- id:` without `insert:` | wrap in `- insert:` |
| `exec format error` | amd64 image without emulation | keep `--platform linux/amd64`; enable Rosetta or binfmt |
| `no space left on device` | image + cases | `docker system prune`, delete old cases |
| `MISSING_CREDENTIAL` / `AUTH` | no API key | export `DEEPSEEK_API_KEY` or complete first-run setup |
| Plot links dead | servers live inside the MCP container | connect DSH first, then run a case |
| Case crawls | 2 CPU / 4 GiB VM | raise Colima resources; 3D cases need a real host |

---

## 8. Cost and footprint

| Item | Cost |
|---|---|
| Everything on this page | free software |
| DAFoam image | free to pull; **closed-source deck** under evaluation licence |
| DeepSeek API | pay per token; a mesh + solve case is a handful of cents |
| Local disk | ~8 GiB image + ~10 MB per case |
| Time | ~20 minutes automated, ~40 manual (mostly the 2.2 GiB pull) |
