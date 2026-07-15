"""
MCP Client – JSON-RPC 2.0 Streamable HTTP
============================================

Generic MCP protocol client with SSE response parsing.
No domain-specific logic — reusable by any agent implementation.
"""

from __future__ import annotations

import json
import logging
import re
from collections import Counter
from dataclasses import dataclass, field
from typing import Any, Dict, List, Literal, Optional, Union
from urllib.parse import urlparse

import requests

logger = logging.getLogger("flash-agent")


# ─────────────────────────────────────────────────────────────────────────────
# Scope model
# ─────────────────────────────────────────────────────────────────────────────

ScopeKind = Literal["namespace", "namespaces", "cluster", "agnostic", "unknown"]


@dataclass
class MCPScope:
    """
    What an MCP server is authorized to read.

    The agent uses this to constrain LLM tool calls. ``namespace`` is the
    common case; ``agnostic`` covers MCPs without a namespace concept (e.g.
    Prometheus); ``unknown`` is an honest "discovery failed" state.
    """

    kind: ScopeKind = "unknown"
    namespaces: List[str] = field(default_factory=list)
    source: str = ""  # "explicit" | "introspection" | "probe" | "fallback" | "merged"

    def describe(self) -> str:
        if self.kind == "namespace" and self.namespaces:
            return f"namespace='{self.namespaces[0]}' (source={self.source})"
        if self.kind == "namespaces":
            return f"namespaces={self.namespaces} (source={self.source})"
        return f"{self.kind} (source={self.source})"


# Heuristic patterns for picking the introspection / probe tools used by
# scope discovery. These are NOT semantic capability classifiers — they
# select probe tools whose response can be mined for namespace evidence.
_INTROSPECTION_NAME_PATTERN = re.compile(
    r"(configuration|context|whoami|server[_-]?info|config[_-]?view|identity)",
    re.IGNORECASE,
)
_PROBE_NAME_PATTERN = re.compile(
    r"(pods|events|deployments|services|configmaps).*(list|get)",
    re.IGNORECASE,
)
_NS_REGEX = re.compile(
    r"namespace[\"'\s]*[:=]\s*[\"']?([a-z0-9][a-z0-9-]{0,62})[\"']?",
    re.IGNORECASE,
)
_IN_NS_REGEX = re.compile(
    r"in\s+(?:the\s+)?namespace\s+[\"']?([a-z0-9][a-z0-9-]{0,62})[\"']?",
    re.IGNORECASE,
)
_NS_KEY_NAMES = {"namespace", "currentnamespace", "default_namespace", "default-namespace"}

# Captures the SA's home namespace from "system:serviceaccount:<ns>:<name>".
# This is the SA's *home* — almost always equal to its RBAC scope when the
# Role/RoleBinding are co-located with the SA (the standard MCP deployment
# shape). Distinct from the *attempted* namespace named in the same error
# (e.g. `... in the namespace "default"`), which we do not trust.
_SA_NS_REGEX = re.compile(r"system:serviceaccount:([a-z0-9][a-z0-9-]{0,62}):")


def _tool_props(tool: Dict[str, Any]) -> Dict[str, Any]:
    return tool.get("inputSchema", {}).get("properties", {}) or {}


def _tool_required(tool: Dict[str, Any]) -> List[str]:
    return tool.get("inputSchema", {}).get("required", []) or []


def _any_tool_has_namespace_param(tools: List[Dict[str, Any]]) -> bool:
    return any("namespace" in _tool_props(t) for t in tools)


def _pick_introspection_tool(tools: List[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    for t in tools:
        name = t.get("name", "")
        if _INTROSPECTION_NAME_PATTERN.search(name) and not _tool_required(t):
            return t
    return None


def _pick_validation_tool(tools: List[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    """
    Pick a read-shaped tool that *requires* a ``namespace`` arg.

    Used to validate a candidate namespace via a real read against it. The tool
    must take ``namespace`` so we can target a specific candidate; required
    must be a subset of ``{namespace}`` so we can call it with just the candidate.
    """
    for t in tools:
        name = t.get("name", "")
        props = _tool_props(t)
        if "namespace" not in props:
            continue
        if not _PROBE_NAME_PATTERN.search(name):
            continue
        required = set(_tool_required(t))
        if "namespace" not in required:
            continue
        if not required.issubset({"namespace"}):
            continue
        return t
    return None


def _pick_candidate_probe_tool(tools: List[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    """
    Pick a read-shaped tool with no required args.

    Used to provoke a response we can mine for a candidate namespace:
      - SUCCESS  → SA has cluster-wide read (we'll classify as ``cluster``)
      - FORBIDDEN → error names ``system:serviceaccount:<ns>:`` (the SA's home ns)
    """
    for t in tools:
        name = t.get("name", "")
        if not _PROBE_NAME_PATTERN.search(name):
            continue
        if _tool_required(t):
            continue
        return t
    return None


def _is_error(result: Dict[str, Any]) -> bool:
    """
    Return True if an MCP tool result represents an error.

    Handles both shapes:
      - JSON-RPC level: top-level ``error`` key (set by ``_jsonrpc_call`` on protocol errors)
      - MCP tool level: ``isError: true`` flag inside a successful JSON-RPC result
    """
    if not isinstance(result, dict):
        return True
    if "error" in result:
        return True
    if result.get("isError") is True:
        return True
    return False


def _extract_sa_namespace_from_error(text: str) -> Optional[str]:
    """Extract <ns> from `system:serviceaccount:<ns>:<name>` if present."""
    if not text:
        return None
    m = _SA_NS_REGEX.search(text)
    return m.group(1) if m else None


def _extract_text(result: Dict[str, Any]) -> str:
    """Pull text content out of a standard MCP tool response."""
    if not isinstance(result, dict):
        return str(result or "")
    content = result.get("content")
    if isinstance(content, list):
        parts = [
            c.get("text", "")
            for c in content
            if isinstance(c, dict) and c.get("type") == "text"
        ]
        if parts:
            return "\n".join(parts)
    return json.dumps(result, default=str)


def _walk_json_for_namespace(data: Any) -> List[str]:
    """Walk a JSON-shaped value and collect all string values under namespace-like keys."""
    found: List[str] = []

    def visit(obj: Any) -> None:
        if isinstance(obj, dict):
            for k, v in obj.items():
                if isinstance(k, str) and k.lower() in _NS_KEY_NAMES and isinstance(v, str):
                    found.append(v)
                visit(v)
        elif isinstance(obj, list):
            for item in obj:
                visit(item)

    visit(data)
    return found


def _regex_extract_namespace(text: str) -> Optional[str]:
    """Permissive regex fallback. Prefers non-'default' matches when both exist."""
    candidates: List[str] = []
    for pat in (_NS_REGEX, _IN_NS_REGEX):
        candidates.extend(pat.findall(text or ""))
    candidates = [c for c in candidates if c]
    if not candidates:
        return None
    non_default = [c for c in candidates if c != "default"]
    pool = non_default if non_default else candidates
    return Counter(pool).most_common(1)[0][0]


def _parse_namespace_from_result(result: Dict[str, Any]) -> Optional[Union[str, List[str]]]:
    """
    Read a namespace (or list of namespaces) out of an MCP tool result.

    Returns ``None`` for error responses or when nothing namespace-shaped is
    present. We deliberately don't trust namespaces extracted from error
    messages here — those often reflect the *attempted* namespace (e.g.
    ``default``), not the SA's authorized scope.
    """
    if not result or _is_error(result):
        return None

    text = _extract_text(result)
    if not text:
        return None

    # Try JSON parse first (introspection tools commonly return JSON or kubeconfig)
    try:
        data = json.loads(text)
        found = _walk_json_for_namespace(data)
        if found:
            distinct = list(dict.fromkeys(found))
            return distinct if len(distinct) > 1 else distinct[0]
    except (json.JSONDecodeError, TypeError):
        pass

    # Fall back to regex (handles YAML / free-form text)
    ns = _regex_extract_namespace(text)
    return ns


class MCPClient:
    """
    MCP JSON-RPC 2.0 client with SSE response parsing and session management.

    Usage::

        client = MCPClient("http://localhost:8086/mcp", "my-agent", timeout=30)
        client.initialize()
        result = client.call_tool(<tool-name>, {"namespace": "default"})
    """

    def __init__(self, url: str, agent_name: str, timeout: int = 30) -> None:
        self.url = url
        self.agent_name = agent_name
        self.timeout = timeout
        self._session_id: Optional[str] = None
        self._call_counter = 1

    @property
    def session_id(self) -> Optional[str]:
        return self._session_id

    def initialize(self) -> Optional[str]:
        """Initialize MCP session and return session ID."""
        try:
            _, self._session_id = self._jsonrpc_call(
                method="initialize",
                params={
                    "protocolVersion": "2025-03-26",
                    "capabilities": {},
                    "clientInfo": {"name": self.agent_name, "version": "3.0"},
                },
            )
            return self._session_id
        except Exception as exc:
            logger.warning("MCP session init failed for %s: %s", self.url, exc)
            return None

    def call_tool(self, tool_name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Call an MCP tool and return the result dict."""
        self._call_counter += 1
        result, self._session_id = self._jsonrpc_call(
            method="tools/call",
            params={"name": tool_name, "arguments": arguments},
        )
        return result

    def list_tools(self) -> list[Dict[str, Any]]:
        """
        Discover available tools from the MCP server.

        Returns a list of tool definitions with name, description, and inputSchema.
        """
        self._call_counter += 1
        result, self._session_id = self._jsonrpc_call(
            method="tools/list",
            params={},
        )
        return result.get("tools", [])

    def discover_scope(
        self,
        tool_defs: List[Dict[str, Any]],
        override: Optional[str] = None,
    ) -> MCPScope:
        """
        Discover what this MCP server is authorized to read.

        Resolution:
          0. ``override`` wins — operator awareness lever.
          1. No tool exposes a ``namespace`` parameter → ``agnostic``
             (e.g. Prometheus, inherits scope from peers at merge time).
          2. Collect candidate namespaces:
             - From an introspection tool (``configuration_view``, etc.) —
               useful when an MCP exposes its config.
             - From a candidate-probe call (a read tool with no required args).
               If it SUCCEEDS, the SA has cluster-wide read → return ``cluster``.
               If it FAILS with a forbidden RBAC error, mine the SA's home
               namespace from ``system:serviceaccount:<ns>:`` — that name
               (almost always equal to the SA's RBAC scope in standard
               co-located Role/RoleBinding deployments) becomes a candidate.
          3. Validate each candidate via a namespace-required read tool
             picked by ``_pick_validation_tool``. Adopt only the namespaces
             that return non-error responses.
          4. No validated candidate → ``unknown``.

        Notes:
          - Error responses are recognised in BOTH MCP shapes: top-level
            ``error`` (JSON-RPC) and ``isError: true`` (MCP tool-level).
          - We never adopt a namespace from string-matching alone; adoption
            requires either an explicit override or a successful probe.
        """
        if override:
            return MCPScope(kind="namespace", namespaces=[override], source="explicit")

        if not _any_tool_has_namespace_param(tool_defs):
            return MCPScope(kind="agnostic", source="introspection")

        candidates: List[str] = []

        # Tier 1: introspection — collect candidates only.
        introspection = _pick_introspection_tool(tool_defs)
        if introspection:
            tool_name = introspection.get("name", "")
            try:
                result = self.call_tool(tool_name, {})
                ns = _parse_namespace_from_result(result)
                if isinstance(ns, list):
                    candidates.extend(ns)
                elif ns:
                    candidates.append(ns)
            except Exception as exc:
                logger.debug("Introspection tool %s failed: %s", tool_name, exc)

        # Tier 2: candidate-probe (no required args).
        cand_probe = _pick_candidate_probe_tool(tool_defs)
        if cand_probe:
            tool_name = cand_probe.get("name", "")
            try:
                result = self.call_tool(tool_name, {})
                if not _is_error(result):
                    # SA has cluster-wide read on this resource — treat as cluster scope.
                    return MCPScope(kind="cluster", source="probe")
                # Forbidden response — mine the SA's home ns from the error.
                sa_ns = _extract_sa_namespace_from_error(_extract_text(result))
                if sa_ns and sa_ns not in candidates:
                    candidates.append(sa_ns)
            except Exception as exc:
                logger.debug("Candidate probe %s failed: %s", tool_name, exc)

        # Tier 3: validate each candidate via a namespace-required read.
        validator = _pick_validation_tool(tool_defs)
        if validator and candidates:
            tool_name = validator.get("name", "")
            validated: List[str] = []
            for ns in dict.fromkeys(candidates):  # ordered dedupe
                try:
                    result = self.call_tool(tool_name, {"namespace": ns})
                    if not _is_error(result):
                        validated.append(ns)
                    else:
                        # A failure here may also reveal the SA's home ns —
                        # capture it for the next iteration.
                        sa_ns = _extract_sa_namespace_from_error(_extract_text(result))
                        if sa_ns and sa_ns not in candidates and sa_ns != ns:
                            candidates.append(sa_ns)
                except Exception as exc:
                    logger.debug("Validation %s(ns=%s) failed: %s", tool_name, ns, exc)
            if validated:
                kind: ScopeKind = "namespaces" if len(validated) > 1 else "namespace"
                return MCPScope(kind=kind, namespaces=validated, source="probe")

        return MCPScope(kind="unknown", source="fallback")

    def _jsonrpc_call(
        self,
        method: str,
        params: Dict[str, Any],
    ) -> tuple[Dict[str, Any], Optional[str]]:
        """
        Send a JSON-RPC 2.0 request to the MCP server and parse SSE response.
        Returns (result_dict, session_id).
        """
        parsed_url = urlparse(self.url)
        origin_host = (
            "localhost"
            if "host.docker.internal" in (parsed_url.hostname or "")
            else parsed_url.hostname
        )
        origin_port = f":{parsed_url.port}" if parsed_url.port else ""
        origin = f"{parsed_url.scheme}://{origin_host}{origin_port}"

        headers: Dict[str, str] = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "User-Agent": f"{self.agent_name}/3.0",
            "Origin": origin,
            "Host": f"{origin_host}{origin_port}",
        }
        if self._session_id:
            headers["Mcp-Session-Id"] = self._session_id

        body = {
            "jsonrpc": "2.0",
            "id": self._call_counter,
            "method": method,
            "params": params,
        }

        resp = requests.post(
            self.url, json=body, headers=headers, timeout=self.timeout
        )
        resp.raise_for_status()

        new_session_id = resp.headers.get("Mcp-Session-Id", self._session_id)

        # Parse SSE response: look for "data:" lines containing JSON-RPC result
        result: Dict[str, Any] = {}
        for line in resp.text.splitlines():
            if line.startswith("data: ") or line.startswith("data:"):
                data_str = line.split("data:", 1)[1].strip()
                if data_str:
                    try:
                        parsed = json.loads(data_str)
                        if "result" in parsed:
                            result = parsed["result"]
                        elif "error" in parsed:
                            result = {"error": parsed["error"]}
                    except json.JSONDecodeError:
                        pass

        return result, new_session_id


def generate_fallback_data(
    server_type: str, query: str, namespace: str
) -> Dict[str, Any]:
    """
    Generate synthetic data when MCP server is unreachable.

    Allows the agent to continue gracefully and provide LLM analysis
    even when underlying MCP infrastructure fails.
    """
    import datetime as _dt

    timestamp = _dt.datetime.utcnow().isoformat() + "Z"

    if server_type.lower() == "kubernetes":
        return {
            "status": "fallback",
            "reason": "MCP pod cannot reach Kubernetes API (DNS connectivity issue)",
            "data": {
                "cluster": namespace,
                "namespace": namespace,
                "timestamp": timestamp,
                "pods": [
                    {
                        "name": f"pod-{i}",
                        "namespace": namespace,
                        "status": "Unknown",
                        "phase": "Unknown",
                        "ready": "Unknown/Unknown",
                        "restarts": 0,
                        "reason": "MCP pod DNS connectivity issue",
                    }
                    for i in range(1, 4)
                ],
                "query_type": "operational_health",
                "query_original": query,
                "warnings": [
                    "MCP pod DNS failures - cannot resolve kubernetes.default.svc",
                    "Using synthetic data for LLM analysis",
                    "Actual cluster metrics unavailable",
                ],
                "recommendation": "Check MCP pod DNS configuration and Kubernetes cluster DNS service health",
            },
        }
    else:
        return {
            "status": "fallback",
            "reason": "MCP pod cannot reach Kubernetes API (DNS connectivity issue)",
            "data": {
                "cluster": namespace,
                "timestamp": timestamp,
                "metrics": {
                    "up": 0,
                    "node_memory_MemAvailable_bytes": 8589934592,  # 8GB placeholder
                    "node_cpu_seconds_total": 0,
                    "rate(container_cpu_usage_seconds_total[1m])": 0.05,
                    "container_memory_usage_bytes": 268435456,  # 256MB placeholder
                },
                "query_type": "system_metrics",
                "query_original": query,
                "warnings": [
                    "MCP pod DNS failures - Prometheus unavailable",
                    "Using synthetic metrics for LLM analysis",
                    "Actual system metrics unavailable",
                ],
            },
        }
