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
    parser.add_argument("--goal", required=True, help="Investigation goal")
    parser.add_argument(
        "--model",
        default=os.environ.get("MODEL", "qwen2.5-7b-instruct"),
        help="LiteLLM model alias",
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
