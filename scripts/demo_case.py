#!/usr/bin/env python3
"""
Drive one DAFoam Agent Deck case end-to-end over MCP, without an LLM.

Why this exists:
  * pre-warm: produce a finished case before a demo, so the meeting shows
    results instead of a progress bar
  * fallback: if the conversational agent misbehaves during a demo, run the
    exact same deterministic workflow from the shell
  * evidence: writes demo_transcript.json with every request/response

This follows DAFoam's mandatory order:
    must_call_first -> (get_pre_context) -> verify_workflow -> run_workflow

Usage:
    ./scripts/demo_case.py --cells 6000 --yplus 30
    ./scripts/demo_case.py --verify-only
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CWD = PROJECT_ROOT / "work" / "results"

CMD = [
    "docker", "run", "-i", "--rm",
    "--platform", "linux/amd64", "--network", "host",
    "--mount", "type=bind,src=.,target=/home/dafoamuser/mount",
    "-w", "/home/dafoamuser/mount",
    "dafoam/agent:latest", "bash", "-lc",
    "source /home/dafoamuser/dafoam/loadDAFoam.sh && mdo-agent-deck-mcp",
]


class Client:
    def __init__(self, cwd: Path, call_timeout: float):
        self.call_timeout = call_timeout
        self.transcript: list[dict] = []
        self._id = 0
        self.proc = subprocess.Popen(
            CMD, cwd=str(cwd), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1,
        )
        self._rpc("initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "dafoam-demo-case", "version": "0.1.0"},
        })
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _send(self, obj: dict) -> None:
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()

    def _rpc(self, method: str, params: dict) -> dict:
        self._id += 1
        rid = self._id
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        deadline = time.monotonic() + self.call_timeout
        while time.monotonic() < deadline:
            line = self.proc.stdout.readline()
            if line == "":
                raise RuntimeError(f"server closed stdout during {method}")
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("id") == rid:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {json.dumps(msg['error'])[:1500]}")
                return msg.get("result", {})
        raise TimeoutError(f"{method} exceeded {self.call_timeout}s")

    def call(self, tool: str, args: dict) -> str:
        started = time.monotonic()
        print(f"\n>>> {tool} {json.dumps(args)[:200]}", flush=True)
        result = self._rpc("tools/call", {"name": tool, "arguments": args})
        text = "\n".join(b.get("text", "") for b in result.get("content", [])
                         if b.get("type") == "text")
        elapsed = round(time.monotonic() - started, 1)
        self.transcript.append({
            "tool": tool, "arguments": args, "elapsedSeconds": elapsed,
            "isError": result.get("isError", False), "text": text,
        })
        print(f"<<< {tool} ({elapsed}s, {len(text)} chars, "
              f"isError={result.get('isError', False)})", flush=True)
        if result.get("isError"):
            print(text[:2500], flush=True)
        return text

    def close(self) -> None:
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=30)
        except Exception:
            self.proc.kill()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--skill", default="generate-cfd-mesh",
                    choices=["generate-cfd-mesh", "run-cfd-simulation"],
                    help="mesh only (~70s) or mesh + steady CFD (~4m16s)")
    ap.add_argument("--airfoil", default="naca2412")
    ap.add_argument("--cells", type=int, default=6000)
    ap.add_argument("--yplus", type=float, default=30.0)
    ap.add_argument("--mach", type=float, default=0.15)
    ap.add_argument("--re", type=float, default=1_000_000.0)
    ap.add_argument("--aoa", type=float, default=2.0,
                    help="angle of attack (degrees); simulation only")
    ap.add_argument("--cwd", type=Path, default=DEFAULT_CWD)
    ap.add_argument("--call-timeout", type=float, default=3600.0)
    ap.add_argument("--verify-only", action="store_true")
    ap.add_argument("--out", type=Path, default=None,
                    help="transcript path (default: demo_transcript_<skill>.json; "
                         "never the committed demo_transcript.json)")
    args = ap.parse_args()
    if args.out is None:
        # Per-skill name so a rehearsal cannot clobber the evidence transcript
        # that ships with the repo.
        args.out = PROJECT_ROOT / f"demo_transcript_{args.skill.replace('-', '_')}.json"

    prereq_inputs = {
        "airfoil_profile": args.airfoil,
        "mesh_cells": args.cells,
        "y_plus": args.yplus,
        "mach_number": args.mach,
        "reynolds_number": args.re,
    }
    if args.skill == "run-cfd-simulation":
        # Prerequisite chain: the scenario runs the mesh first, then the solver.
        scenario = "single-skill-with-prereq-single-run"
        payload = {
            "prereq_cases": [{"inputs": prereq_inputs}],
            "cases": [{"inputs": {"angle_of_attack": args.aoa}}],
        }
        user_prompt = (
            f"Run a steady-state CFD simulation for the {args.airfoil.upper()} airfoil "
            f"at {args.aoa:g} degrees angle of attack, on a {args.cells}-cell mesh "
            f"with yPlus {args.yplus:g}, Ma={args.mach:g}, Re={args.re:g}"
        )
    else:
        scenario = "single-skill-single-run"
        payload = {"cases": [{"inputs": prereq_inputs}]}
        user_prompt = (
            f"Generate a CFD mesh for the {args.airfoil.upper()} airfoil with "
            f"{args.cells} cells, yPlus {args.yplus:g}, Ma={args.mach:g}, Re={args.re:g}"
        )

    print(f"project: {PROJECT_ROOT}\nskill:   {args.skill}\ncwd:     {args.cwd}\n"
          f"payload: {json.dumps(payload)}")
    client = Client(args.cwd, args.call_timeout)
    started = time.monotonic()
    rc = 0
    try:
        raw = client.call("must_call_first", {})
        info = json.loads(raw)
        print(f"work_dir: {info.get('work_dir')}  run_mode: {info.get('run_mode')}")

        # Mandatory ordering: verify_workflow is rejected unless
        # get_skill_input_info has already supplied the schema this session.
        client.call("get_skill_input_info",
                    {"agent": "airfoil", "skill": args.skill})

        verified = client.call("verify_workflow", {
            "scenario": scenario, "agent": "airfoil",
            "skill": args.skill, "payload": payload,
            "user_prompt": user_prompt,
        })
        print("\n--- verification result ---")
        print(verified[:3000])

        if args.verify_only:
            print("\n--verify-only: stopping before run_workflow")
        else:
            run_args = json.loads(verified)
            # run_arguments is the only accepted shape; anything else is rejected.
            ra = run_args.get("run_arguments", run_args)
            if not isinstance(ra, dict) or not ra.get("scenario"):
                raise RuntimeError(
                    f"could not find run_arguments in verification output: {list(run_args)[:10]}")
            out = client.call("run_workflow", ra)
            print("\n--- run result ---")
            print(out[:4000])
    except Exception as exc:
        rc = 1
        print(f"\nFAILED: {exc}", file=sys.stderr)
    finally:
        client.close()
        args.out.write_text(json.dumps({
            "userPrompt": user_prompt, "payload": payload,
            "totalSeconds": round(time.monotonic() - started, 1),
            "ok": rc == 0, "phases": client.transcript,
        }, indent=2))
        print(f"\ntotal {round(time.monotonic() - started, 1)}s "
              f"-> transcript: {args.out}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
