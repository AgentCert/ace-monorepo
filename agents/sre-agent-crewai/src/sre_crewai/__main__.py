"""CLI entrypoint for the CrewAI SRE agent.

Usage:
  python -m sre_crewai \
    --goal "Diagnose the current K8s incident..." \
    --model qwen2.5-7b-instruct \
    --workspace-dir /tmp/agent/workspace \
    --output /tmp/agent/workspace/agent_output.json
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

from .crew import build_crew


def _extract_json(text: str) -> dict | None:
    """Try to extract a JSON object from free-form text."""
    # Strip markdown fences
    text = re.sub(r"```(?:json)?\s*", "", text).strip()
    # Try the whole string
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    # Find the largest {...} block
    match = re.search(r"\{.*\}", text, re.DOTALL)
    if match:
        try:
            return json.loads(match.group(0))
        except json.JSONDecodeError:
            pass
    return None


def main() -> None:
    parser = argparse.ArgumentParser(description="CrewAI SRE incident investigator")
    # The agent-charts Helm chart (the only live deployment path — see
    # agents/harness/sre-agent-crewai/bench.yaml) runs this entrypoint with no
    # CLI args at all, relying entirely on env vars from its ConfigMap. --goal
    # must therefore have an env-backed default, not `required=True`, or every
    # pod deployed that way fails at argument parsing before build_crew() ever
    # runs. GOAL/MODEL_ALIAS are the chart's ConfigMap key names; the old
    # standalone agent-harness.yaml script still passes --goal/--model
    # explicitly and continues to take precedence when given.
    parser.add_argument(
        "--goal",
        default=os.environ.get("GOAL", "Diagnose and remediate all faults in the Kubernetes cluster."),
        help="Investigation goal",
    )
    parser.add_argument(
        "--model",
        default=os.environ.get("MODEL_ALIAS") or os.environ.get("MODEL", "qwen2.5-7b-instruct"),
        help="LiteLLM model alias",
    )
    parser.add_argument("--workspace-dir", default="/tmp/agent/workspace")
    parser.add_argument("--output", default=None, help="Path for agent_output.json")
    args = parser.parse_args()

    workspace = Path(args.workspace_dir)
    workspace.mkdir(parents=True, exist_ok=True)
    output_path = args.output or str(workspace / "agent_output.json")

    # The Helm chart runs this as a Deployment, so returning makes Kubernetes
    # restart the pod and back off (CrashLoopBackOff), and a single pass runs
    # before any fault is injected. Under the chart, scan every SCAN_INTERVAL
    # seconds like the other agents, bounded by AGENT_MAX_RUNTIME_SECONDS, then
    # idle until the workflow uninstalls the agent. With neither set (the
    # standalone harness) it still makes exactly one pass.
    scan_interval = int(os.environ.get("SCAN_INTERVAL", "0") or "0")
    max_runtime = int(os.environ.get("AGENT_MAX_RUNTIME_SECONDS", "0") or "0")
    deadline = time.monotonic() + max_runtime if max_runtime > 0 else None

    iteration = 0
    while True:
        iteration += 1
        print(f"[sre-crewai] scan iteration {iteration}", flush=True)
        try:
            _investigate(args, workspace, output_path)
        except Exception as exc:  # a failed pass must not take the pod down
            print(f"[sre-crewai] scan iteration {iteration} failed: {exc}", file=sys.stderr, flush=True)
        if scan_interval <= 0:
            break
        sleep_for = scan_interval
        if deadline is not None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            sleep_for = min(scan_interval, int(remaining))
        if sleep_for <= 0:
            break
        print(f"[sre-crewai] sleeping {sleep_for}s before next scan", flush=True)
        time.sleep(sleep_for)

    if scan_interval > 0 and os.environ.get("AGENT_IDLE_AFTER_MAX_RUNTIME", "false").strip().lower() in ("1", "true", "yes"):
        print("[sre-crewai] bounded scan loop complete; idling until workflow cleanup", flush=True)
        while True:
            time.sleep(3600)


def _investigate(args: argparse.Namespace, workspace: Path, output_path: str) -> None:
    """Run one crew investigation and write its diagnosis to output_path."""
    crew = build_crew(
        goal=args.goal,
        workspace_dir=str(workspace),
        model=args.model,
        output_path=output_path,
    )

    result = crew.kickoff()

    # CrewAI writes task output_file automatically when output_file is set.
    # If that file already has valid JSON we're done; otherwise parse result.raw.
    output_file = Path(output_path)
    output_data: dict | None = None

    if output_file.exists():
        try:
            output_data = json.loads(output_file.read_text())
            print(f"[sre-crewai] agent_output.json written by CrewAI task ({output_path})")
        except json.JSONDecodeError:
            raw_text = output_file.read_text()
            output_data = _extract_json(raw_text)
            if output_data:
                print("[sre-crewai] extracted JSON from task output file")

    if output_data is None:
        raw = getattr(result, "raw", None) or str(result)
        output_data = _extract_json(raw)
        if output_data:
            print("[sre-crewai] extracted JSON from crew result.raw")

    if output_data is None:
        print("[sre-crewai] WARNING: could not extract structured JSON; saving raw output", file=sys.stderr)
        raw = getattr(result, "raw", None) or str(result)
        output_data = {
            "entities": [],
            "propagation_chain": [],
            "_raw_output": raw[:8000],
        }

    output_file.write_text(json.dumps(output_data, indent=2))
    print(f"[sre-crewai] diagnosis written to {output_path}")


if __name__ == "__main__":
    main()
