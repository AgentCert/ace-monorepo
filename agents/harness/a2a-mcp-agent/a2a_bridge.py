"""
A2A/MCP bridge — the interactive adapter layer between the ITBench harness
protocol and any agent that speaks A2A (Google Agent-to-Agent protocol).

Input  : /tmp/agent/scenario_data.json  (universal schema, see harness/README.md)
Output : /tmp/agent/agent_data.tar      (standard ITBench result tarball)

The bridge:
  1. Reads the universal scenario_data.json.
  2. Verifies the target agent via its Agent Card
     (/.well-known/agent-card.json, falling back to /.well-known/agent.json).
  3. Submits the benchmark task over JSON-RPC 2.0. It tries the current A2A
     method `message/send` first and falls back to the legacy `tasks/send`
     for agents built against the pre-v0.2 draft. MCP server URLs, the LLM
     proxy endpoint, and the model alias are passed in both the message text
     and the structured metadata so the agent can self-configure.
  4. Polls `tasks/get` until the task reaches a terminal state (unless the
     agent answered immediately with a Message rather than creating a Task).
  5. Packages the A2A result + original scenario into agent_data.tar.

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

# A2A TaskState values that end the poll loop.
TERMINAL_STATES = {"completed", "failed", "canceled", "cancelled", "rejected"}
# States where the agent is blocked waiting on the caller. The bridge has no
# channel to answer, so it stops instead of burning the whole timeout window.
WAITING_STATES = {"input-required", "auth-required"}

# JSON-RPC error substrings that mean "this server does not implement that method".
_MISSING_METHOD_HINTS = (
    "method not found",
    "not supported",
    "unknown method",
    "unsupported method",
    "no such method",
)

# ── JSON-RPC plumbing ────────────────────────────────────────────────────────


class _RpcError(RuntimeError):
    """A JSON-RPC error object returned in the response body."""

    def __init__(self, method: str, code: Any, message: str) -> None:
        self.code = code
        self.rpc_message = message or ""
        super().__init__(f"A2A JSON-RPC error [{method}]: code={code} {self.rpc_message}".rstrip())


def _rpc(client: httpx.Client, url: str, method: str, params: dict, timeout: float = 60.0) -> dict:
    payload = {"jsonrpc": "2.0", "id": str(uuid.uuid4()), "method": method, "params": params}
    resp = client.post(url, json=payload, timeout=timeout)
    resp.raise_for_status()
    body = resp.json()
    if body.get("error"):
        err = body["error"] or {}
        raise _RpcError(method, err.get("code"), err.get("message", ""))
    return body.get("result") or {}


def _looks_like_missing_method(exc: Exception) -> bool:
    """True if `exc` indicates the server simply doesn't implement the method."""
    if isinstance(exc, _RpcError):
        if exc.code == -32601:  # JSON-RPC "Method not found"
            return True
        return any(h in exc.rpc_message.lower() for h in _MISSING_METHOD_HINTS)
    if isinstance(exc, httpx.HTTPStatusError):
        return exc.response.status_code in (404, 405, 501)
    return False


@retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1, min=2, max=8))
def _fetch_agent_card(base_url: str) -> dict:
    # Current A2A spec serves the card at /.well-known/agent-card.json;
    # pre-v0.2 implementations use /.well-known/agent.json — try both.
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


# ── task submission (dual-protocol) ─────────────────────────────────────────


def _submit_task(
    client: httpx.Client,
    url: str,
    task_text: str,
    metadata: dict,
    legacy_task_id: str,
) -> tuple[str, dict]:
    """Submit the task, preferring `message/send`, falling back to `tasks/send`.

    Returns (protocol, result) where protocol is the method that worked and
    result is the JSON-RPC `result` object (an A2A Task or Message).
    """
    v03_params: dict[str, Any] = {
        "message": {
            "role": "user",
            "parts": [{"kind": "text", "text": task_text}],
            "messageId": str(uuid.uuid4()),
            "kind": "message",
        },
        "configuration": {"acceptedOutputModes": ["text/plain", "application/json"]},
        "metadata": metadata,
    }
    try:
        return "message/send", _rpc(client, url, "message/send", v03_params)
    except (_RpcError, httpx.HTTPStatusError) as exc:
        if not _looks_like_missing_method(exc):
            raise
        log.info("agent does not implement message/send (%s) — using legacy tasks/send", exc)

    legacy_params: dict[str, Any] = {
        "id": legacy_task_id,
        "message": {
            "role": "user",
            "parts": [{"type": "text", "text": task_text}],
        },
        "metadata": metadata,
    }
    return "tasks/send", _rpc(client, url, "tasks/send", legacy_params)


def _is_message_result(obj: dict) -> bool:
    """A2A `message/send` may answer with a Message instead of creating a Task."""
    if obj.get("kind") == "message":
        return True
    return "parts" in obj and "status" not in obj and "artifacts" not in obj


def _text_parts(parts: Any) -> list[str]:
    out: list[str] = []
    for part in parts or []:
        if isinstance(part, dict) and (part.get("kind") == "text" or part.get("type") == "text"):
            out.append(part.get("text", ""))
    return out


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
    log.info("Fetching Agent Card from %s/.well-known/agent-card.json", a2a_endpoint)
    try:
        card = _fetch_agent_card(a2a_endpoint)
        log.info("Agent Card: name=%s  version=%s", card.get("name"), card.get("version"))
    except Exception as exc:
        log.warning("Could not fetch Agent Card (%s) — continuing anyway", exc)
        card = {}

    # ── 3. Build the task message ────────────────────────────────────────────
    # Pass MCP/LLM coordinates as structured metadata *and* as a text preamble
    # so the agent can self-configure however it parses the message.
    legacy_task_id = str(uuid.uuid4())

    context_lines: list[str] = []
    if mcp_urls:
        context_lines.append(f"MCP_URLS: {mcp_urls}")
    if openai_base_url:
        context_lines.append(f"OPENAI_BASE_URL: {openai_base_url}")
    if model_alias:
        context_lines.append(f"MODEL_ALIAS: {model_alias}")

    task_text = ("\n".join(context_lines) + "\n\n" + goal).strip() if context_lines else goal

    metadata = {
        "mcp_urls": mcp_urls,
        "openai_base_url": openai_base_url,
        "model_alias": model_alias,
    }

    # Derive the JSON-RPC endpoint. Prefer the Agent Card's advertised URL.
    rpc_url = a2a_endpoint + "/"
    agent_card_url = card.get("url", rpc_url)
    if agent_card_url and agent_card_url.rstrip("/") + "/" != rpc_url:
        rpc_url = agent_card_url.rstrip("/") + "/"

    # ── 4. Submit + poll ────────────────────────────────────────────────────
    protocol = "unknown"
    task_result: dict[str, Any] = {}
    state = "submitted"

    with httpx.Client(timeout=60.0) as client:
        try:
            protocol, send_result = _submit_task(
                client, rpc_url, task_text, metadata, legacy_task_id
            )
            log.info("Task submitted via %s to %s", protocol, rpc_url)
        except Exception as exc:
            log.error("Failed to submit A2A task: %s", exc)
            sys.exit(1)

        if _is_message_result(send_result):
            # Agent answered inline without creating a Task — nothing to poll.
            log.info("Agent returned a Message directly; no task polling needed")
            task_result = send_result
            state = "completed"
        else:
            poll_id = send_result.get("id") or legacy_task_id
            task_result = send_result
            state = (send_result.get("status") or {}).get("state", "") or "submitted"
            log.info("Task %s state: %s (polling, timeout=%ds)", poll_id, state, timeout_seconds)

            deadline = time.monotonic() + timeout_seconds
            while state not in TERMINAL_STATES and time.monotonic() < deadline:
                if state in WAITING_STATES:
                    log.warning("Task %s is %s — bridge cannot answer; stopping", poll_id, state)
                    break
                time.sleep(5)
                try:
                    task_result = _rpc(client, rpc_url, "tasks/get", {"id": poll_id})
                except Exception as exc:
                    log.warning("Poll error: %s — retrying in 10s", exc)
                    time.sleep(10)
                    continue
                state = (task_result.get("status") or {}).get("state", "")
                log.info("Task %s state: %s", poll_id, state)

            if state not in TERMINAL_STATES and state not in WAITING_STATES:
                log.warning("Timeout reached — task %s last state: %s", poll_id, state)

    # ── 5. Package results ────────────────────────────────────────────────────
    ts = int(time.time())
    outdir = Path(f"/tmp/agent/a2a-{ts}")
    outdir.mkdir(parents=True, exist_ok=True)

    (outdir / "scenario_data.json").write_text(SCENARIO_PATH.read_text())
    (outdir / "agent_card.json").write_text(json.dumps(card, indent=2))
    (outdir / "a2a_result.json").write_text(json.dumps(task_result, indent=2))
    (outdir / "a2a_protocol.txt").write_text(f"{protocol}\nfinal_state={state}\n")

    # Collect text output from wherever the agent put it: a direct Message,
    # Task artifacts, or the final TaskStatus message.
    if _is_message_result(task_result):
        for i, text in enumerate(_text_parts(task_result.get("parts"))):
            (outdir / f"message_part_{i}.txt").write_text(text)
    else:
        for idx, artifact in enumerate(task_result.get("artifacts") or []):
            for pidx, part in enumerate(artifact.get("parts", [])):
                if part.get("kind") == "text" or part.get("type") == "text":
                    fname = artifact.get("name") or f"artifact_{idx}_part_{pidx}.txt"
                    (outdir / fname).write_text(part.get("text", ""))
        status_msg = (task_result.get("status") or {}).get("message") or {}
        for i, text in enumerate(_text_parts(status_msg.get("parts"))):
            (outdir / f"status_message_part_{i}.txt").write_text(text)

    with tarfile.open(OUTPUT_TAR, "w") as tar:
        tar.add(outdir, arcname=".")

    log.info("Result packaged to %s (protocol=%s state=%s)", OUTPUT_TAR, protocol, state)
    sys.exit(0 if state == "completed" else 1)


if __name__ == "__main__":
    main()
