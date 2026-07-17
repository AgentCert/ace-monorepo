"""
A2A/MCP bridge — the interactive adapter layer between the ITBench harness
protocol and any agent that speaks A2A (Google Agent-to-Agent protocol).

Input  : /tmp/agent/scenario_data.json  (universal schema, see harness/README.md)
Output : /tmp/agent/agent_data.tar      (standard ITBench result tarball)

The bridge:
  1. Reads the universal scenario_data.json.
  2. Verifies the target agent via its Agent Card (/.well-known/agent.json).
  3. Sends the benchmark task via JSON-RPC 2.0  tasks/send.
     MCP server URLs, LLM proxy endpoint, and model alias are embedded in the
     task message so the agent can self-configure without any harness-side
     knowledge of its internals.
  4. Polls tasks/get until the task reaches a terminal state.
  5. Packages the A2A task result + original scenario into agent_data.tar.

The agent is fully responsible for connecting to the MCP servers and routing
its LLM calls through the provided proxy URL — the harness only passes the
coordinates.
"""

from __future__ import annotations

import json
import logging
import os
import sys
import tarfile
import time
import uuid
from pathlib import Path
from typing import Any

import httpx
from tenacity import retry, stop_after_attempt, wait_exponential

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s  %(levelname)s  %(message)s",
)
log = logging.getLogger("a2a_bridge")

SCENARIO_PATH = Path("/tmp/agent/scenario_data.json")
OUTPUT_TAR = Path("/tmp/agent/agent_data.tar")

TERMINAL_STATES = {"completed", "failed", "canceled"}

# ── helpers ──────────────────────────────────────────────────────────────────


def _rpc(client: httpx.Client, url: str, method: str, params: dict) -> dict:
    payload = {"jsonrpc": "2.0", "id": str(uuid.uuid4()), "method": method, "params": params}
    resp = client.post(url, json=payload, timeout=30.0)
    resp.raise_for_status()
    body = resp.json()
    if "error" in body:
        raise RuntimeError(f"A2A JSON-RPC error [{method}]: {body['error']}")
    return body.get("result", {})


@retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1, min=2, max=8))
def _fetch_agent_card(base_url: str) -> dict:
    # A2A v1.0 spec: Agent Card is at /.well-known/agent-card.json
    # Some older implementations use /.well-known/agent.json — try both.
    base = base_url.rstrip("/")
    with httpx.Client(timeout=10.0) as c:
        for path in ("/.well-known/agent-card.json", "/.well-known/agent.json"):
            try:
                resp = c.get(f"{base}{path}")
                if resp.status_code == 200:
                    return resp.json()
            except Exception:
                continue
    raise RuntimeError(f"Agent Card not found at {base} (tried agent-card.json and agent.json)")


# ── main ─────────────────────────────────────────────────────────────────────


def main() -> None:
    # ── 1. Read scenario ──────────────────────────────────────────────────────
    if not SCENARIO_PATH.exists():
        log.error("scenario_data.json not found at %s", SCENARIO_PATH)
        sys.exit(1)

    scenario: dict[str, Any] = json.loads(SCENARIO_PATH.read_text())

    a2a_endpoint = scenario.get("a2a_endpoint", "").rstrip("/")
    if not a2a_endpoint:
        log.error("scenario_data.json must contain 'a2a_endpoint'")
        sys.exit(1)

    goal: str = scenario.get("goal", "")
    if not goal:
        log.error("scenario_data.json must contain 'goal'")
        sys.exit(1)

    mcp_urls: str = scenario.get("mcp_urls", "")
    openai_base_url: str = scenario.get("openai_base_url", "")
    model_alias: str = scenario.get("model_alias", "")
    timeout_seconds: int = int(scenario.get("timeout_seconds", 300))

    # ── 2. Verify agent via Agent Card ────────────────────────────────────────
    log.info("Fetching Agent Card from %s/.well-known/agent.json", a2a_endpoint)
    try:
        card = _fetch_agent_card(a2a_endpoint)
        log.info("Agent Card: name=%s  version=%s", card.get("name"), card.get("version"))
    except Exception as exc:
        log.warning("Could not fetch Agent Card (%s) — continuing anyway", exc)
        card = {}

    # ── 3. Build and send A2A task ────────────────────────────────────────────
    # Pass MCP/LLM coordinates as structured metadata in the task message so
    # the agent can self-configure on its side without any harness-side coupling.
    task_id = str(uuid.uuid4())

    # Embed context lines before the goal so legacy agents that only read the
    # text part still receive the coordinates.
    context_lines: list[str] = []
    if mcp_urls:
        context_lines.append(f"MCP_URLS: {mcp_urls}")
    if openai_base_url:
        context_lines.append(f"OPENAI_BASE_URL: {openai_base_url}")
    if model_alias:
        context_lines.append(f"MODEL_ALIAS: {model_alias}")

    task_text = ("\n".join(context_lines) + "\n\n" + goal).strip() if context_lines else goal

    send_params: dict[str, Any] = {
        "id": task_id,
        "message": {
            "role": "user",
            "parts": [{"type": "text", "text": task_text}],
        },
        # Structured metadata for A2A-native agents that parse params
        "metadata": {
            "mcp_urls": mcp_urls,
            "openai_base_url": openai_base_url,
            "model_alias": model_alias,
        },
    }

    # Derive the JSON-RPC endpoint.  Agents may expose it at "/" or "/".
    rpc_url = a2a_endpoint + "/"
    agent_card_url = card.get("url", rpc_url)
    if agent_card_url and agent_card_url != rpc_url:
        rpc_url = agent_card_url.rstrip("/") + "/"

    log.info("Sending A2A task %s to %s", task_id, rpc_url)
    with httpx.Client(timeout=60.0) as client:
        try:
            _rpc(client, rpc_url, "tasks/send", send_params)
            log.info("Task submitted, polling for completion (timeout=%ds)", timeout_seconds)
        except Exception as exc:
            log.error("Failed to submit A2A task: %s", exc)
            sys.exit(1)

        # ── 4. Poll until terminal state ──────────────────────────────────────
        deadline = time.monotonic() + timeout_seconds
        task_result: dict[str, Any] = {}
        state = "submitted"

        while time.monotonic() < deadline:
            try:
                task_result = _rpc(client, rpc_url, "tasks/get", {"id": task_id})
            except Exception as exc:
                log.warning("Poll error: %s — retrying in 10s", exc)
                time.sleep(10)
                continue

            state = task_result.get("status", {}).get("state", "")
            log.info("Task %s state: %s", task_id, state)

            if state in TERMINAL_STATES:
                break
            time.sleep(5)
        else:
            log.warning("Timeout reached — task %s last state: %s", task_id, state)

    # ── 5. Package results ────────────────────────────────────────────────────
    ts = int(time.time())
    outdir = Path(f"/tmp/agent/a2a-{ts}")
    outdir.mkdir(parents=True, exist_ok=True)

    (outdir / "scenario_data.json").write_text(SCENARIO_PATH.read_text())
    (outdir / "agent_card.json").write_text(json.dumps(card, indent=2))
    (outdir / "a2a_result.json").write_text(json.dumps(task_result, indent=2))

    # Extract text artifacts from completed task messages
    artifacts: list[dict] = task_result.get("artifacts", [])
    for idx, artifact in enumerate(artifacts):
        for pidx, part in enumerate(artifact.get("parts", [])):
            if part.get("type") == "text":
                fname = artifact.get("name") or f"artifact_{idx}_part_{pidx}.txt"
                (outdir / fname).write_text(part.get("text", ""))

    with tarfile.open(OUTPUT_TAR, "w") as tar:
        tar.add(outdir, arcname=".")

    log.info("Result packaged to %s (state=%s)", OUTPUT_TAR, state)
    sys.exit(0 if state == "completed" else 1)


if __name__ == "__main__":
    main()
