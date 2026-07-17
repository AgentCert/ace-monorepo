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
from pathlib import Path

from .crew import build_crew


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
    parser.add_argument("--goal", required=True, help="Investigation and remediation goal")
    parser.add_argument(
        "--model",
        default=os.environ.get("MODEL", "qwen2.5-7b-instruct"),
        help="LiteLLM model alias",
    )
    parser.add_argument(
        "--namespace",
        default=os.environ.get("TARGET_NAMESPACE", "otel-demo"),
        help="Primary Kubernetes namespace to investigate (default: otel-demo)",
    )
    parser.add_argument("--workspace-dir", default="/tmp/agent/workspace")
    parser.add_argument("--output", default=None, help="Path for agent_output.json")
    args = parser.parse_args()

    workspace = Path(args.workspace_dir)
    workspace.mkdir(parents=True, exist_ok=True)
    output_path = args.output or str(workspace / "agent_output.json")

    crew = build_crew(
        goal=args.goal,
        workspace_dir=str(workspace),
        model=args.model,
        output_path=output_path,
        namespace=args.namespace,
    )

    result = crew.kickoff()

    # Prefer the output_file written by CrewAI; fall back to parsing result.raw
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

    output_file.write_text(json.dumps(output_data, indent=2))
    print(f"[sre-comprehensive] diagnosis written to {output_path}")


if __name__ == "__main__":
    main()
