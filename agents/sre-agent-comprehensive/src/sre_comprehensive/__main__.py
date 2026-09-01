"""CLI entrypoint for the comprehensive SRE fault-remediation agent.

Usage:
  python -m sre_comprehensive \\
    --goal "Diagnose and remediate the current Kubernetes incident." \\
    --model qwen2.5-7b-instruct \\
    --namespace otel-demo \\
    --workspace-dir /tmp/agent/workspace \\
    --output /tmp/agent/workspace/agent_output.json

The following environment variables are also read:
  LITELLM_BASE_URL          — LiteLLM proxy (default: http://127.0.0.1:14000)
  SRE_AGENT_LITELLM_API_KEY — API key for LiteLLM (default: ollama)
  K8S_MCP_URL               — Kubernetes MCP server (default: http://127.0.0.1:18081/mcp)
  PROM_MCP_URL              — Prometheus MCP server (default: http://127.0.0.1:31085/mcp)
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
from .mcp_tools import collect_minimum_evidence, reset_tool_call_history


def _extract_json(text: str) -> dict | None:
    """Try to extract a JSON object from free-form text."""
    text = re.sub(r"```(?:json)?\s*", "", text).strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    match = re.search(r"\{.*\}", text, re.DOTALL)
    if match:
        try:
            return json.loads(match.group(0))
        except json.JSONDecodeError:
            pass
    return None


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Comprehensive SRE agent: investigates and remediates all K8s fault categories"
    )
    parser.add_argument(
        "--goal",
        default=os.environ.get("AGENT_GOAL"),
        help="Investigation and remediation goal (or set AGENT_GOAL env var)",
    )
    parser.add_argument(
        "--model",
        default=os.environ.get("MODEL_ALIAS") or os.environ.get("MODEL", "qwen2.5-7b-instruct"),
        help="LiteLLM model alias",
    )
    parser.add_argument(
        "--namespace",
        default=os.environ.get("TARGET_NAMESPACE", "otel-demo"),
        help="Primary Kubernetes namespace to investigate (default: otel-demo)",
    )
    parser.add_argument("--workspace-dir", default="/tmp/agent/workspace")
    parser.add_argument("--output", default=None, help="Path for agent_output.json")
    parser.add_argument(
        "--max-runtime-seconds",
        type=int,
        default=int(os.environ.get("AGENT_MAX_RUNTIME_SECONDS", "0") or "0"),
        help="Bounded scan-loop runtime. 0 keeps legacy one-shot behavior unless SCAN_INTERVAL is set.",
    )
    args = parser.parse_args()
    if not args.goal:
        parser.error("--goal is required (or set AGENT_GOAL env var)")

    workspace = Path(args.workspace_dir)
    workspace.mkdir(parents=True, exist_ok=True)
    output_path = args.output or str(workspace / "agent_output.json")

    scan_interval = int(os.environ.get("SCAN_INTERVAL", "0") or "0")
    max_runtime = args.max_runtime_seconds
    if max_runtime <= 0 and scan_interval > 0:
        max_runtime = 780

    deadline = time.monotonic() + max_runtime if max_runtime > 0 else None
    last_output: dict | None = None
    iteration = 0

    while True:
        iteration += 1
        print(f"[sre-comprehensive] scan iteration {iteration} namespace={args.namespace}", flush=True)
        reset_tool_call_history()
        deterministic_findings: list[dict] = []
        deterministic_error = ""
        try:
            deterministic_findings = collect_minimum_evidence(args.namespace)
        except Exception as exc:
            deterministic_error = str(exc)
            print(f"[sre-comprehensive] deterministic preflight failed: {deterministic_error}", file=sys.stderr, flush=True)

        # The preflight is allowed to remediate obvious failures, but CrewAI must
        # still collect its own minimum evidence before a final empty answer is accepted.
        reset_tool_call_history()

        crew = build_crew(
            goal=args.goal,
            workspace_dir=str(workspace),
            model=args.model,
            output_path=output_path,
            namespace=args.namespace,
        )

        try:
            result = crew.kickoff()
            output_data = _load_output(output_path, result)
        except Exception as exc:
            print(f"[sre-comprehensive] crew execution failed: {exc}", file=sys.stderr, flush=True)
            output_data = {
                "entities": deterministic_findings,
                "propagation_chain": [],
                "_error": str(exc)[:2000],
            }
        if deterministic_findings and not output_data.get("entities"):
            output_data = {
                "entities": deterministic_findings,
                "propagation_chain": [],
            }
        if deterministic_error:
            output_data.setdefault("_preflight_error", deterministic_error[:2000])
        Path(output_path).write_text(json.dumps(output_data, indent=2))
        last_output = output_data
        print(f"[sre-comprehensive] diagnosis written to {output_path}", flush=True)

        if deadline is None:
            break
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        sleep_for = min(scan_interval if scan_interval > 0 else 30, max(int(remaining), 0))
        if sleep_for <= 0:
            break
        print(f"[sre-comprehensive] sleeping {sleep_for}s before next scan", flush=True)
        time.sleep(sleep_for)

    if last_output is None:
        last_output = {"entities": [], "propagation_chain": []}

    if os.environ.get("AGENT_IDLE_AFTER_MAX_RUNTIME", "true").strip().lower() in ("1", "true", "yes") and deadline is not None:
        print("[sre-comprehensive] bounded scan loop complete; idling until workflow cleanup", flush=True)
        while True:
            time.sleep(3600)


def _load_output(output_path: str, result: object) -> dict:

    output_file = Path(output_path)
    output_data: dict | None = None

    if output_file.exists():
        try:
            output_data = json.loads(output_file.read_text())
            print(f"[sre-comprehensive] agent_output.json written by CrewAI ({output_path})")
        except json.JSONDecodeError:
            output_data = _extract_json(output_file.read_text())
            if output_data:
                print("[sre-comprehensive] extracted JSON from CrewAI output file")

    if output_data is None:
        raw = getattr(result, "raw", None) or str(result)
        output_data = _extract_json(raw)
        if output_data:
            print("[sre-comprehensive] extracted JSON from crew result.raw")

    if output_data is None:
        print(
            "[sre-comprehensive] WARNING: could not extract structured JSON; saving raw",
            file=sys.stderr,
        )
        raw = getattr(result, "raw", None) or str(result)
        output_data = {
            "entities": [],
            "propagation_chain": [],
            "_raw_output": raw[:8000],
        }

    return output_data


if __name__ == "__main__":
    main()
