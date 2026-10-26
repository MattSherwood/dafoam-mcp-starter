#!/usr/bin/env bash
# Preflight doctor for the DAFoam / MDO Agent Deck stack on this host.
# Read-only: it inspects, never changes, the machine.
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="dafoam/agent:latest"
fail=0
warn=0

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
note() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; warn=$((warn+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail+1)); }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

hdr "Host"
printf '  macOS %s on %s\n' "$(sw_vers -productVersion)" "$(uname -m)"
MEM_GB=$(sysctl -n hw.memsize | awk '{printf "%.0f", $1/1073741824}')
printf '  %s CPUs, %s GiB RAM\n' "$(sysctl -n hw.ncpu)" "$MEM_GB"
[ "$MEM_GB" -ge 16 ] && ok "host RAM adequate for small cases" \
                     || note "host RAM ${MEM_GB}GiB is low for CFD"

FREE_GB=$(df -g /System/Volumes/Data | awk 'NR==2{print $4}')
printf '  %s GiB free on /System/Volumes/Data\n' "$FREE_GB"
if [ "$FREE_GB" -ge 25 ]; then ok "disk headroom for image + cases"
elif [ "$FREE_GB" -ge 8 ]; then note "operating headroom only (image ~2.3GiB packed / ~6GiB unpacked); no room to archive cases"
else bad "insufficient free disk (<8GiB) — prune images or cases"; fi

hdr "Docker runtime"
if ! command -v docker >/dev/null; then bad "docker CLI not found"; else
  ok "docker CLI $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,)"
  if docker info >/dev/null 2>&1; then
    ok "daemon reachable ($(docker context show 2>/dev/null))"
    printf '  server: %s / %s / %s CPU / %s\n' \
      "$(docker info --format '{{.OperatingSystem}}' 2>/dev/null)" \
      "$(docker info --format '{{.Architecture}}' 2>/dev/null)" \
      "$(docker info --format '{{.NCPU}}' 2>/dev/null)" \
      "$(docker info --format '{{.MemTotal}}' 2>/dev/null | awk '{printf "%.1fGiB", $1/1073741824}')"
    NCPU=$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)
    [ "${NCPU:-0}" -ge 4 ] && ok "VM has ${NCPU} CPUs" \
      || note "VM has only ${NCPU} CPU(s); CFD will be slow (raise with colima start --cpus)"
  else
    bad "daemon NOT reachable — start Colima: colima start"
  fi
fi

hdr "amd64 emulation (required: ${IMAGE} is amd64-only)"
if command -v colima >/dev/null; then
  ROSETTA=$(colima list 2>/dev/null | awk '$1=="default"{for(i=1;i<=NF;i++) if($i ~ /rosetta/) print $i}')
  CFG="$HOME/.colima/default/colima.yaml"
  if [ -f "$CFG" ] && grep -qE '^rosetta: true' "$CFG"; then
    ok "Colima Rosetta enabled (fast x86_64 translation)"
  else
    note "Colima Rosetta DISABLED — amd64 runs under slow QEMU binfmt"
    printf '        only matters for a LOCAL compute path; skip if DAFoam moves to a remote host\n'
    printf '        fix: colima stop && colima start --vm-type vz --vz-rosetta   (brief restart)\n'
  fi
else
  note "colima not found; assuming Docker Desktop (enable Rosetta in settings)"
fi

hdr "DAFoam image"
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  ok "$IMAGE present ($(docker image inspect "$IMAGE" --format '{{.Size}}' | awk '{printf "%.2fGiB", $1/1073741824}'))"
else
  note "$IMAGE not pulled — run ./scripts/bootstrap.sh"
fi

hdr "MCP working directory"
if [ -d "$PROJECT_ROOT/work/results" ]; then
  ok "work/results exists"
  [ -f "$PROJECT_ROOT/work/results/.mcp.json" ] && ok ".mcp.json present" \
    || note ".mcp.json missing — re-fetch with ./scripts/bootstrap.sh"
else
  bad "work/results missing — run ./scripts/bootstrap.sh"
fi

hdr "DSH integration"
PATCH="$HOME/.dsh/profiles/web/cordis.patch.yml"
if [ -f "$PATCH" ] && grep -q 'mcp-dafoam' "$PATCH"; then
  ok "mcp-dafoam registered in $PATCH"
else
  note "not registered in DSH yet — see config/dsh/cordis.patch.yml"
fi

printf '\n\033[1mSummary:\033[0m %d failure(s), %d warning(s)\n' "$fail" "$warn"
[ "$fail" -eq 0 ] || exit 1
