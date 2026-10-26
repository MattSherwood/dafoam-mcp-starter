#!/usr/bin/env python3
"""
Verify the DAFoam MDO Agent Deck MCP server speaks MCP over stdio.

Spawns the exact `docker run ... mdo-agent-deck-mcp` command DAFoam's own
.mcp.json uses, performs the MCP handshake (initialize -> initialized ->
tools/list), and prints the advertised tool names.

This is the ground-truth check that the agent deck is reachable before wiring
it into DSH / Codex / Claude. It does not run a CFD case.

Usage:
    ./scripts/verify_mcp.py                 # full handshake + tool list
    ./scripts/verify_mcp.py --json          # machine-readable summary
    ./scripts/verify_mcp.py --timeout 600   # slow (emulated) hosts
    ./scripts/verify_mcp.py --cwd DIR       # alternate results dir
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CWD = PROJECT_ROOT / "work" / "results"
IMAGE = "dafoam/agent:latest"
PROTOCOL_VERSION = "2025-06-18"

DOCKER_ARGS = [
    "run", "-i", "--rm",
    "--platform", "linux/amd64",
    "--network", "host",
    "--mount", "type=bind,src=.,target=/home/dafoamuser/mount",
    "-w", "/home/dafoamuser/mount",
    IMAGE,
    "bash", "-lc",
    "source /home/dafoamuser/dafoam/loadDAFoam.sh && mdo-agent-deck-mcp",
]


def log(msg: str) -> None:
    print(f"[verify-mcp] {msg}", file=sys.stderr, flush=True)


def preflight(cwd: Path) -> list[str]:
    problems: list[str] = []
    if shutil.which("docker") is None:
        problems.append("docker CLI not found on PATH")
    if not cwd.is_dir():
        problems.append(f"MCP working directory missing: {cwd}")
    elif not (cwd / ".mcp.json").exists():
        problems.append(f"{cwd} does not look like a DAFoam results dir (no .mcp.json)")
    return problems


def image_present() -> bool:
    try:
        out = subprocess.run(
            ["docker", "image", "inspect", IMAGE],
            capture_output=True, text=True, timeout=60,
        )
        return out.returncode == 0
    except (subprocess.SubprocessError, OSError):
        return False


def _send(proc: subprocess.Popen, payload: dict) -> None:
    assert proc.stdin is not None
    proc.stdin.write(json.dumps(payload) + "\n")
    proc.stdin.flush()


def _await_id(proc: subprocess.Popen, want_id: int, deadline: float) -> dict:
    """Read stdout lines until the JSON-RPC response with want_id arrives."""
    assert proc.stdout is not None
    while time.monotonic() < deadline:
        line = proc.stdout.readline()
        if line == "":
            raise RuntimeError(
                "MCP server closed stdout before responding "
                f"(exit={proc.poll()}). Check `docker logs` / stderr above."
            )
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            # Servers sometimes leak progress text onto stdout; not fatal.
            log(f"non-JSON stdout: {line[:160]}")
            continue
        if msg.get("id") == want_id:
            return msg
        if "method" in msg:
            log(f"notification: {msg.get('method')}")
    raise TimeoutError(f"timed out waiting for response id={want_id}")


def run_handshake(cwd: Path, timeout: float) -> dict:
    env = os.environ.copy()
    # Honour whichever daemon the caller configured; do not silently override.
    cmd = ["docker", *DOCKER_ARGS]
    log(f"cwd={cwd}")
    log(f"spawning: docker run --platform linux/amd64 {IMAGE} mdo-agent-deck-mcp")

    started = time.monotonic()
    proc = subprocess.Popen(
        cmd, cwd=str(cwd), env=env,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, bufsize=1,
    )
    try:
        deadline = time.monotonic() + timeout

        _send(proc, {
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "dafoam-verify-mcp", "version": "0.1.0"},
            },
        })
        init = _await_id(proc, 1, deadline)
        if "error" in init:
            raise RuntimeError(f"initialize failed: {init['error']}")
        server_info = init.get("result", {}).get("serverInfo", {})
        negotiated = init.get("result", {}).get("protocolVersion")
        log(f"connected: {server_info.get('name')} {server_info.get('version')} "
            f"(protocol {negotiated})")

        _send(proc, {"jsonrpc": "2.0", "method": "notifications/initialized"})
        _send(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        listing = _await_id(proc, 2, deadline)
        if "error" in listing:
            raise RuntimeError(f"tools/list failed: {listing['error']}")

        tools = listing.get("result", {}).get("tools", [])
        return {
            "ok": True,
            "server": server_info,
            "protocolVersion": negotiated,
            "elapsedSeconds": round(time.monotonic() - started, 1),
            "toolCount": len(tools),
            "tools": [t.get("name") for t in tools],
        }
    finally:
        try:
            if proc.stdin:
                proc.stdin.close()
        except OSError:
            pass
        try:
            proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)
        if proc.stderr:
            tail = proc.stderr.read()
            if tail and tail.strip():
                log("server stderr:")
                for line in tail.strip().splitlines()[-25:]:
                    print(f"  | {line}", file=sys.stderr)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cwd", type=Path, default=DEFAULT_CWD,
                    help="MCP working directory (default: work/results)")
    ap.add_argument("--timeout", type=float, default=300.0,
                    help="seconds to wait for handshake (default 300; emulation is slow)")
    ap.add_argument("--json", action="store_true", help="emit JSON only")
    args = ap.parse_args()

    problems = preflight(args.cwd)
    if problems:
        result = {"ok": False, "problems": problems}
        print(json.dumps(result, indent=2) if args.json else
              "\n".join(f"PREFLIGHT FAIL: {p}" for p in problems), file=sys.stderr)
        return 2

    if not image_present():
        msg = f"{IMAGE} not present locally - run ./scripts/bootstrap.sh (or docker pull {IMAGE})"
        print(json.dumps({"ok": False, "problems": [msg]}, indent=2) if args.json
              else f"PREFLIGHT FAIL: {msg}", file=sys.stderr)
        return 2

    try:
        result = run_handshake(args.cwd, args.timeout)
    except (RuntimeError, TimeoutError, OSError, subprocess.SubprocessError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, indent=2) if args.json
              else f"HANDSHAKE FAIL: {exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print()
        print(f"MCP handshake OK in {result['elapsedSeconds']}s "
              f"({result['server'].get('name')} {result['server'].get('version')})")
        print(f"{result['toolCount']} tool(s) advertised:")
        for name in result["tools"]:
            print(f"  - {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
