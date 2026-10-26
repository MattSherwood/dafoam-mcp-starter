#!/usr/bin/env bash
# Reproduce the DAFoam + DSH environment from scratch.
#
# Works on macOS (Homebrew) and Linux/WSL2 (apt or dnf). Idempotent: re-running
# skips whatever is already correct. NON-DESTRUCTIVE: it will not overwrite a
# cordis.patch.yml that already holds other settings.
#
#   ./scripts/install.sh --yes          # unattended
#   ./scripts/install.sh                # confirm each phase
#   ./scripts/install.sh --skip-image   # everything except the 2.2 GiB pull
#   ./scripts/install.sh --help
#
# What it does, in order:
#   1. detect platform
#   2. install CLI packages (git, gh, node, python, docker/colima, jq)
#   3. install the pinned DSH (npm install -g @deepseek-ai/dsh@<pin>)
#   4. start a container runtime (Colima on macOS; verify Docker on Linux)
#   5. pull dafoam/agent:latest
#   6. fetch the mdo_agent_work working directory into work/
#   7. register the DAFoam MCP server in the DSH profile patch
#   8. verify: doctor + MCP handshake
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSH_VERSION="${DSH_VERSION:-0.1.5-rc.3}"
IMAGE="${DAFOAM_AGENT_IMAGE:-dafoam/agent:latest}"
COLIMA_CPUS="${COLIMA_CPUS:-4}"
COLIMA_MEM="${COLIMA_MEM:-8}"
COLIMA_DISK="${COLIMA_DISK:-40}"

ASSUME_YES=0
SKIP_IMAGE=0
SKIP_DOCKER=0
ROSETTA=0

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1; shift ;;
    --skip-image) SKIP_IMAGE=1; shift ;;
    --skip-docker) SKIP_DOCKER=1; shift ;;
    --rosetta) ROSETTA=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mok\033[0m   %s\n' "$*"; }
warn() { printf '    \033[33mwarn\033[0m %s\n' "$*"; }
die()  { printf '    \033[31mfail\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  read -r -p "    $1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# --------------------------------------------------------------- 1. platform
step "1/8 platform"
OS="$(uname -s)"
ARCH="$(uname -m)"
IS_WSL=0
grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=1
case "$OS" in
  Darwin) ok "macOS $(sw_vers -productVersion) on $ARCH" ;;
  Linux)  ok "Linux on $ARCH$([ $IS_WSL -eq 1 ] && echo ' (WSL2)')" ;;
  *) die "unsupported platform: $OS. On Windows use WSL2 (Ubuntu) and re-run inside it." ;;
esac
if [ "$OS" = "Darwin" ] && [ "$ARCH" = "arm64" ]; then
  warn "Apple silicon: the DAFoam image is amd64. Expect emulation (see --rosetta)."
fi

# --------------------------------------------------------------- 2. packages
step "2/8 CLI packages"
need_git=0; need_gh=0; need_node=0; need_py=0; need_jq=0
command -v git >/dev/null || need_git=1
command -v gh  >/dev/null || need_gh=1
command -v node >/dev/null || need_node=1
command -v python3 >/dev/null || need_py=1
command -v jq >/dev/null || need_jq=1

if [ "$OS" = "Darwin" ]; then
  if ! command -v brew >/dev/null; then
    warn "Homebrew missing"
    confirm "Install Homebrew now?" || die "install Homebrew from https://brew.sh then re-run"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  ok "Homebrew $(brew --version | head -1 | awk '{print $2}')"
  pkgs=()
  [ $need_git -eq 1 ] && pkgs+=(git)
  [ $need_gh -eq 1 ] && pkgs+=(gh)
  [ $need_node -eq 1 ] && pkgs+=(node)
  [ $need_py -eq 1 ] && pkgs+=(python@3.13)
  [ $need_jq -eq 1 ] && pkgs+=(jq)
  if [ $SKIP_DOCKER -eq 0 ]; then
    command -v docker >/dev/null || pkgs+=(docker)
    command -v colima >/dev/null || pkgs+=(colima)
  fi
  if [ ${#pkgs[@]} -gt 0 ]; then
    echo "    installing: ${pkgs[*]}"
    brew install "${pkgs[@]}"
  else
    ok "nothing to install"
  fi
elif [ "$OS" = "Linux" ]; then
  missing=()
  [ $need_git -eq 1 ] && missing+=(git)
  [ $need_gh  -eq 1 ] && missing+=(gh)
  [ $need_jq  -eq 1 ] && missing+=(jq)
  [ $need_py  -eq 1 ] && missing+=(python3)
  if [ $SKIP_DOCKER -eq 0 ] && ! command -v docker >/dev/null; then
    missing+=(docker.io)
  fi
  if [ ${#missing[@]} -gt 0 ]; then
    warn "missing: ${missing[*]}"
    if command -v apt-get >/dev/null; then
      confirm "Run apt-get install for these?" || die "install them manually and re-run"
      sudo apt-get update && sudo apt-get install -y "${missing[@]}"
    elif command -v dnf >/dev/null; then
      confirm "Run dnf install for these?" || die "install them manually and re-run"
      sudo dnf install -y "${missing[@]}"
    else
      die "no supported package manager; install: ${missing[*]}"
    fi
  else
    ok "nothing to install"
  fi
  if [ $SKIP_DOCKER -eq 0 ]; then
    sudo systemctl enable --now docker 2>/dev/null || warn "could not start docker service"
    sudo usermod -aG docker "$USER" 2>/dev/null || true
  fi
fi

if ! command -v node >/dev/null; then
  die "Node.js still missing. Install v20+ (https://nodejs.org) and re-run."
fi
ok "node $(node --version) / npm $(npm --version)"

# ------------------------------------------------------------------ 3. dsh
step "3/8 DSH ($DSH_VERSION)"
if command -v dsh >/dev/null; then
  have="$(dsh --version 2>/dev/null | tr -d '[:space:]')"
  if [ "$have" = "$DSH_VERSION" ]; then
    ok "dsh $have already installed"
  else
    warn "dsh $have present, pinning to $DSH_VERSION"
    npm install -g "@deepseek-ai/dsh@$DSH_VERSION"
  fi
else
  npm install -g "@deepseek-ai/dsh@$DSH_VERSION"
fi
command -v dsh >/dev/null || die "dsh not on PATH after install"
ok "dsh $(dsh --version)"

# --------------------------------------------------------- 4. docker runtime
if [ $SKIP_DOCKER -eq 0 ]; then
  step "4/8 container runtime"
  if [ "$OS" = "Darwin" ]; then
    if colima status >/dev/null 2>&1; then
      ok "Colima already running"
    else
      args=(--cpu "$COLIMA_CPUS" --memory "$COLIMA_MEM" --disk "$COLIMA_DISK")
      [ "$ROSETTA" -eq 1 ] && args+=(--vm-type vz --vz-rosetta)
      echo "    starting Colima (${COLIMA_CPUS} CPU / ${COLIMA_MEM} GiB / ${COLIMA_DISK} GiB)"
      colima start "${args[@]}"
    fi
  fi
  docker info >/dev/null 2>&1 || die "docker daemon unreachable"
  ok "docker $(docker info --format '{{.OperatingSystem}} / {{.Architecture}}')"
else
  step "4/8 container runtime (skipped)"
fi

# ------------------------------------------------------------------ 5. image
if [ $SKIP_IMAGE -eq 0 ] && [ $SKIP_DOCKER -eq 0 ]; then
  step "5/8 DAFoam image ($IMAGE)"
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    ok "already present ($(docker image inspect "$IMAGE" --format '{{.Size}}' | awk '{printf "%.2f GiB", $1/1073741824}'))"
  else
    echo "    pulling (~2.2 GiB, this is the long step)"
    docker pull "$IMAGE"
  fi
else
  step "5/8 DAFoam image (skipped)"
fi

# ------------------------------------------------------- 6. working directory
step "6/8 working directory"
if [ -f "$ROOT/work/results/.mcp.json" ]; then
  ok "work/results already present"
else
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --retry 3 --max-time 180 \
    "https://github.com/DAFoam/mdo_agent_work/archive/refs/heads/docker.zip" \
    -o "$tmp/maw.zip"
  unzip -q "$tmp/maw.zip" -d "$tmp"
  mkdir -p "$ROOT/work"
  cp -R "$tmp/mdo_agent_work-docker/." "$ROOT/work/"
  ok "installed into work/results"
fi

# ------------------------------------------------------ 7. register MCP server
step "7/8 register the DAFoam MCP server with DSH"
PROFILE_DIR="$HOME/.dsh/profiles/web"
PATCH="$PROFILE_DIR/cordis.patch.yml"
mkdir -p "$PROFILE_DIR"

# Let DSH initialise the profile from its template first, so we do not fight it.
dsh --profile web --dump-config >/dev/null 2>&1 || true

render_patch() {
  cat <<'YAML'
# DSH patch layer. IMPORTANT: a new entry must be wrapped in `insert:`.
# A bare `- id: x` means "update an existing entry" and is silently skipped.
# Docs: docs/REPRODUCE.md (this repo)
- insert:
    - id: mcp-dafoam
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: dafoam
        transport: stdio
        cwd: __WORKDIR__
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
          - __IMAGE__
          - bash
          - -lc
          - source /home/dafoamuser/dafoam/loadDAFoam.sh && mdo-agent-deck-mcp
        toolCallTimeoutMs: 900000
        failOnStartupError: false
YAML
}

write_patch() {
  render_patch \
    | sed -e "s|__WORKDIR__|$ROOT/work/results|g" -e "s|__IMAGE__|$IMAGE|g" \
    > "$1"
}

if [ -f "$PATCH" ] && grep -q 'mcp-dafoam' "$PATCH"; then
  ok "mcp-dafoam already registered"
else
  # Is the existing patch layer more than an empty list / comments?
  nontrivial=0
  if [ -f "$PATCH" ]; then
    while IFS= read -r line; do
      l="$(printf '%s' "$line" | sed 's/#.*//' | tr -d '[:space:]')"
      [ -z "$l" ] && continue
      [ "$l" = "[]" ] && continue
      nontrivial=1
    done < "$PATCH"
  fi
  if [ "$nontrivial" -eq 1 ]; then
    sidecar="$PROFILE_DIR/cordis.dafoam.patch.yml"
    write_patch "$sidecar"
    warn "existing $PATCH has other settings — left untouched"
    warn "merge this entry by hand: $sidecar"
    warn "then delete the sidecar"
  else
    [ -f "$PATCH" ] && cp "$PATCH" "$PATCH.bak.$(date +%Y%m%dT%H%M%S)"
    write_patch "$PATCH"
    ok "wrote $PATCH"
  fi
fi

# ---------------------------------------------------------------- 8. verify
step "8/8 verification"
[ -x "$ROOT/scripts/doctor.sh" ] && "$ROOT/scripts/doctor.sh" || warn "doctor.sh missing"
if [ $SKIP_IMAGE -eq 0 ] && [ $SKIP_DOCKER -eq 0 ]; then
  if command -v python3 >/dev/null; then
    python3 "$ROOT/scripts/verify_mcp.py" --timeout 600 || \
      warn "MCP handshake failed — see docs/RUNBOOK.md"
  fi
fi

cat <<EOF

$(printf '\033[1mDone.\033[0m')

Next:
  1. Provide a DeepSeek API key to the process that launches DSH:
         export DEEPSEEK_API_KEY=sk-...
     (or complete the first-run setup in the web UI)
  2. Start the harness:
         dsh web --host 127.0.0.1 --port 3080 --no-open
  3. Open http://127.0.0.1:3080 and ask:
         "Is mdo_agent_deck's must_call_first tool available?"

Docs: docs/REPRODUCE.md · docs/RUNBOOK.md · docs/ARCHITECTURE.md
EOF
