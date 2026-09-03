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
import concurrent.futures
import json
import os
import re
import sys
import time
from pathlib import Path

from .crew import build_crew

# Hard ceiling on a single ``crew.kickoff()``. CrewAI's text-ReAct loop can
# enter a non-terminating doom loop with qwen2.5 on the ollama_chat route
# (hallucinated Observations → unparseable step → CrewAI re-injects the whole
# tool list → scratchpad bloats → empty completion → retry, forever), which
# would otherwise consume the entire scan window on scan iteration 1 and never
# let the deterministic preflight (which runs at the top of each loop) re-check
# for a fault injected *after* the agent started. On timeout we abandon the
# kickoff thread (it dies with the process) and fall through to the next
# iteration, where ``collect_minimum_evidence`` gets another turn.
_KICKOFF_TIMEOUT_S = float(os.environ.get("SRE_AGENT_KICKOFF_TIMEOUT", "120") or "120")


def _kickoff_with_timeout(crew, timeout: float):
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(crew.kickoff)
        try:
            return future.result(timeout=timeout)
        finally:
            # Do not block process shutdown on a wedged kickoff thread.
            pool._threads.clear()
            concurrent.futures.thread._threads_queues.clear()
from .mcp_tools import check_mcp_reachable, collect_minimum_evidence, reset_tool_call_history
from .tool_loop import run_investigation

# Which investigation engine to use once the deterministic preflight has run:
#   "toolcalling" (default) — native OpenAI tool-calling loop (tool_loop.py),
#     the fix for CrewAI's text-ReAct doom loop with qwen on ollama_chat.
#   "crewai" — the legacy CrewAgentExecutor path (build_crew + kickoff).
_ENGINE = os.environ.get("SRE_AGENT_ENGINE", "toolcalling").strip().lower()

# Per-cycle wall-clock budget for the native tool-calling loop. Unlike the
# CrewAI doom loop (which _KICKOFF_TIMEOUT_S exists to *cut off*), the tool loop
# terminates cleanly on its own — it just needs enough time to walk the 9-phase
# protocol. Still capped by the global --max-runtime deadline.
_TOOLLOOP_BUDGET_S = float(os.environ.get("SRE_AGENT_TOOLLOOP_BUDGET", "600") or "600")

# When false, the deterministic preflight still gathers evidence but does NOT
# scale a zeroed workload back up — the agent's own loop has to do it. Use this
# to certify pure agent capability; leave true for a production remediator.
_PREFLIGHT_REMEDIATE = os.environ.get(
    "SRE_AGENT_PREFLIGHT_REMEDIATE", "true"
).strip().lower() in ("1", "true", "yes", "on")


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
    # When every MCP endpoint is unreachable the agent has no way to gather
    # evidence — re-running the crew just burns tokens and floods Langfuse with
    # byte-identical "all tools broken → empty JSON" traces (temperature is low
    # and the context is identical each cycle). Skip the kickoff on those cycles
    # and abandon the scan loop after this many consecutive all-down cycles.
    mcp_down_streak = 0
    max_mcp_down_streak = int(os.environ.get("SRE_AGENT_MAX_MCP_DOWN_STREAK", "3") or "3")

    while True:
        iteration += 1
        print(f"[sre-comprehensive] scan iteration {iteration} namespace={args.namespace}", flush=True)

        reach = check_mcp_reachable()
        for _url, _err in reach.items():
            print(
                f"[sre-comprehensive]   MCP {_url}: {'OK' if not _err else 'UNREACHABLE — ' + _err}",
                file=sys.stderr if _err else sys.stdout,
                flush=True,
            )
        mcp_all_down = bool(reach) and all(reach.values())

        if mcp_all_down:
            mcp_down_streak += 1
            print(
                f"[sre-comprehensive] all MCP endpoints unreachable "
                f"(streak {mcp_down_streak}/{max_mcp_down_streak}); skipping investigation this "
                f"cycle. Check agent.config.MCP_URLS and that the app's MCP servers are "
                f"Running/Ready in namespace '{args.namespace}'.",
                file=sys.stderr,
                flush=True,
            )
            if last_output is None:
                last_output = {
                    "entities": [],
                    "propagation_chain": [],
                    "_error": f"MCP endpoints unreachable: {reach}",
                }
                Path(output_path).write_text(json.dumps(last_output, indent=2))
        else:
            mcp_down_streak = 0
            reset_tool_call_history()
            deterministic_findings: list[dict] = []
            deterministic_error = ""
            try:
                deterministic_findings = collect_minimum_evidence(
                    args.namespace, remediate=_PREFLIGHT_REMEDIATE
                )
            except Exception as exc:
                deterministic_error = str(exc)
                print(f"[sre-comprehensive] deterministic preflight failed: {deterministic_error}", file=sys.stderr, flush=True)

            # The preflight is allowed to remediate obvious failures, but CrewAI must
            # still collect its own minimum evidence before a final empty answer is accepted.
            reset_tool_call_history()

            # If the deterministic preflight already found (and remediated) a
            # fault, don't hand this cycle to CrewAI's ReAct loop — it is prone
            # to a non-terminating doom loop with qwen on the ollama_chat route
            # (see _kickoff_with_timeout) and would only burn the rest of the
            # window re-deriving what the preflight already knows. Record the
            # findings and keep looping cheaply so later cycles can verify
            # recovery / catch anything new.
            if deterministic_findings:
                output_data = {"entities": deterministic_findings, "propagation_chain": []}
                if deterministic_error:
                    output_data["_preflight_error"] = deterministic_error[:2000]
                Path(output_path).write_text(json.dumps(output_data, indent=2))
                last_output = output_data
                print(
                    f"[sre-comprehensive] deterministic preflight remediated "
                    f"{len(deterministic_findings)} fault(s); skipping CrewAI this cycle",
                    flush=True,
                )
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
                continue

            if _ENGINE != "crewai":
                # Native tool-calling loop (default) — see tool_loop.py.
                base_url = (
                    os.environ.get("LITELLM_BASE_URL")
                    or os.environ.get("OPENAI_BASE_URL")
                    or "http://127.0.0.1:14000"
                )
                api_key = (
                    os.environ.get("SRE_AGENT_LITELLM_API_KEY")
                    or os.environ.get("OPENAI_API_KEY")
                    or "ollama"
                )
                loop_deadline = time.monotonic() + _TOOLLOOP_BUDGET_S
                if deadline is not None:
                    loop_deadline = min(loop_deadline, deadline)
                try:
                    output_data = run_investigation(
                        goal=args.goal,
                        namespace=args.namespace,
                        model=args.model,
                        base_url=base_url,
                        api_key=api_key,
                        output_path=output_path,
                        deadline=loop_deadline,
                    )
                except Exception as exc:  # noqa: BLE001
                    print(f"[sre-comprehensive] tool-loop failed: {exc}", file=sys.stderr, flush=True)
                    output_data = {
                        "entities": deterministic_findings,
                        "propagation_chain": [],
                        "_error": str(exc)[:2000],
                    }
            else:
                crew = build_crew(
                    goal=args.goal,
                    workspace_dir=str(workspace),
                    model=args.model,
                    output_path=output_path,
                    namespace=args.namespace,
                )

                try:
                    result = _kickoff_with_timeout(crew, _KICKOFF_TIMEOUT_S)
                    output_data = _load_output(output_path, result)
                except concurrent.futures.TimeoutError:
                    print(
                        f"[sre-comprehensive] crew.kickoff() exceeded {_KICKOFF_TIMEOUT_S:.0f}s "
                        f"— abandoning this cycle; deterministic preflight re-runs next scan",
                        file=sys.stderr,
                        flush=True,
                    )
                    output_data = {
                        "entities": deterministic_findings,
                        "propagation_chain": [],
                        "_error": f"crew.kickoff timed out after {_KICKOFF_TIMEOUT_S:.0f}s",
                    }
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
                    **({"_llm_unavailable": True} if output_data.get("_llm_unavailable") else {}),
                }
            if deterministic_error:
                output_data.setdefault("_preflight_error", deterministic_error[:2000])
            Path(output_path).write_text(json.dumps(output_data, indent=2))
            last_output = output_data
            print(f"[sre-comprehensive] diagnosis written to {output_path}", flush=True)

            # The tool loop already aborted this cycle because the LLM endpoint
            # is down / rate-limiting. Do NOT sleep SCAN_INTERVAL and try again —
            # every retry cycle just hammers a dead endpoint. End the scan loop.
            if output_data.get("_llm_unavailable"):
                print(
                    "[sre-comprehensive] abandoning scan loop: LLM endpoint "
                    "unavailable / rate-limited — not retrying",
                    file=sys.stderr,
                    flush=True,
                )
                break

        if mcp_down_streak >= max_mcp_down_streak:
            print(
                f"[sre-comprehensive] abandoning scan loop: MCP unreachable for "
                f"{mcp_down_streak} consecutive cycles",
                file=sys.stderr,
                flush=True,
            )
            break

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
