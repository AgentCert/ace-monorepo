"""MCP tool wrappers for the comprehensive SRE agent.

Covers all fault categories in chaos-charts/faults/:
  - NetworkPolicy blocking (delete policy)
  - Rogue pods / load generators (delete pod/deployment)
  - Node cordoning (patch node)
  - Deployment config faults — image, command, initContainer, probe,
    env, resources, nodeSelector, affinity, dnsPolicy (rollout_undo)
  - Service faults — missing, wrong selector, wrong targetPort (patch/apply)
  - ResourceQuota, HPA, PVC, ConfigMap, Secret (patch/delete)
  - Standard LitmusChaos stress / network faults (delete pods for restart)

Both K8S_MCP_URL and PROM_MCP_URL are read from env at import time so the
harness can override them without code changes.
"""
from __future__ import annotations

import asyncio
import concurrent.futures
from datetime import datetime, timezone
import json
import os
import re
from typing import Optional, Type
import uuid

from crewai.tools import BaseTool
from mcp import ClientSession
try:
    # mcp>=2.0 renamed this function; pyproject.toml pins "mcp>=1.9.0" with no
    # upper bound, so whichever name the installed version exposes is used.
    from mcp.client.streamable_http import streamablehttp_client
except ImportError:
    from mcp.client.streamable_http import streamable_http_client as streamablehttp_client
from pydantic import BaseModel, Field, field_validator

def _parse_mcp_urls() -> tuple[str, str]:
    """Resolve K8S and Prometheus MCP URLs from env vars.

    Priority:
      1. K8S_MCP_URL / PROM_MCP_URL (explicit)
      2. MCP_URLS — comma-separated "k8s_url,prom_url" injected by the Helm chart
      3. Localhost defaults for local dev
    """
    mcp_urls = os.environ.get("MCP_URLS", "")
    parts = [u.strip() for u in mcp_urls.split(",") if u.strip()]
    default_k8s = parts[0] if len(parts) >= 1 else "http://127.0.0.1:18081/mcp"
    default_prom = parts[1] if len(parts) >= 2 else "http://127.0.0.1:31085/mcp"
    return (
        os.environ.get("K8S_MCP_URL", default_k8s),
        os.environ.get("PROM_MCP_URL", default_prom),
    )


K8S_URL, PROM_URL = _parse_mcp_urls()

_TOOL_CALL_HISTORY: list[dict] = []
_TOOL_OUTPUT_LIMIT = int(os.environ.get("SRE_AGENT_TOOL_TRACE_OUTPUT_CHARS", "4000"))


def reset_tool_call_history() -> None:
    _TOOL_CALL_HISTORY.clear()


def get_tool_call_history() -> list[dict]:
    return list(_TOOL_CALL_HISTORY)


def required_evidence_missing() -> list[str]:
    """Return minimum investigation calls that have not happened yet."""
    names = [event.get("tool_name") for event in _TOOL_CALL_HISTORY if event.get("status") == "success"]
    missing: list[str] = []
    if "namespaces_list" not in names:
        missing.append("list_namespaces")
    if "pods_list_in_namespace" not in names:
        missing.append("list_pods_in_namespace")
    if "events_list" not in names:
        missing.append("list_k8s_events")
    if "resources_list" not in names:
        missing.append("list_k8s_resources")
    return missing


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(value: datetime) -> str:
    return value.isoformat().replace("+00:00", "Z")


def _trace_id() -> str:
    return (
        os.environ.get("NOTIFY_ID")
        or os.environ.get("TRACE_ID")
        or os.environ.get("EXPERIMENT_RUN_ID")
        or ""
    ).strip()


def _redacted_output(tool_name: str, arguments: dict, text: str) -> str:
    kind = str(arguments.get("kind", "")).lower()
    if kind == "secret" or "secret" in tool_name.lower():
        return "[redacted secret resource output]"
    return text[:_TOOL_OUTPUT_LIMIT]


def _record_tool_call(
    *,
    url: str,
    tool_name: str,
    arguments: dict,
    start: datetime,
    end: datetime,
    status: str,
    output: str = "",
    error: str = "",
) -> None:
    event = {
        "tool_name": tool_name,
        "url": url,
        "arguments": arguments,
        "status": status,
        "duration_ms": int((end - start).total_seconds() * 1000),
        "output_preview": _redacted_output(tool_name, arguments, output),
        "error": error[:1000],
    }
    _TOOL_CALL_HISTORY.append(event)
    print(
        f"[sre-comprehensive] tool {tool_name} status={status} "
        f"duration_ms={event['duration_ms']} error={bool(error)}",
        flush=True,
    )
    _emit_langfuse_tool_observation(event, start, end)


def _emit_langfuse_tool_observation(event: dict, start: datetime, end: datetime) -> None:
    host = os.environ.get("LANGFUSE_HOST", "").rstrip("/")
    public_key = os.environ.get("LANGFUSE_PUBLIC_KEY", "")
    secret_key = os.environ.get("LANGFUSE_SECRET_KEY", "")
    trace_id = _trace_id()
    if not (host and public_key and secret_key and trace_id):
        return

    observation_id = str(uuid.uuid4())
    body = {
        "batch": [
            {
                "id": observation_id,
                "type": "span-create",
                "timestamp": _iso(end),
                "body": {
                    "id": observation_id,
                    "traceId": trace_id,
                    "type": "SPAN",
                    "name": f"tool: {event['tool_name']}",
                    "startTime": _iso(start),
                    "endTime": _iso(end),
                    "input": json.dumps(event["arguments"]),
                    "output": event["output_preview"],
                    "level": "ERROR" if event["status"] == "error" else "DEFAULT",
                    "statusMessage": event["error"] or None,
                    "metadata": {
                        "tool_name": event["tool_name"],
                        "tool_url": event["url"],
                        "duration_ms": str(event["duration_ms"]),
                        "agent_name": os.environ.get("AGENT_NAME", "sre-agent-comprehensive"),
                        "workflow_name": os.environ.get("WORKFLOW_NAME", ""),
                        "workflow_uid": os.environ.get("WORKFLOW_UID", ""),
                        "experiment_id": os.environ.get("EXPERIMENT_ID", ""),
                        "experiment_run_id": os.environ.get("EXPERIMENT_RUN_ID", ""),
                        "target_namespace": os.environ.get("TARGET_NAMESPACE", ""),
                    },
                },
            }
        ]
    }
    try:
        import httpx

        httpx.post(
            f"{host}/api/public/ingestion",
            auth=(public_key, secret_key),
            json=body,
            timeout=5,
        ).raise_for_status()
    except Exception as exc:
        print(f"[sre-comprehensive] Langfuse tool observation failed: {exc}", flush=True)


# ---------------------------------------------------------------------------
# Low-level async → sync MCP bridge (fresh session per call, no shared state)
# ---------------------------------------------------------------------------

# Per-call ceiling. The mcp streamable-http client has no built-in connect
# timeout, so a wrong MCP_URLS (wrong namespace, server not Ready yet) would
# otherwise stall the whole ReAct turn until CrewAI's much longer timeout.
_MCP_TIMEOUT_S = float(os.environ.get("MCP_TIMEOUT", "30") or "30")


def _unwrap_exc(exc: BaseException) -> str:
    """Flatten anyio/TaskGroup ExceptionGroups down to their real cause(s).

    The mcp streamable-http client drives its POST + SSE read loop inside an
    anyio task group, so every failure — connection refused, DNS failure,
    non-200 status, timeout — reaches the caller as
    ``ExceptionGroup: unhandled errors in a TaskGroup (N sub-exception(s))``
    whose ``str()`` discloses nothing. Without this the agent's Observation
    and the pod log both just say "unhandled errors in a TaskGroup", which is
    un-actionable. Recurse through ``.exceptions`` and surface the leaves.
    """
    leaves: list[str] = []

    def _walk(e: BaseException) -> None:
        subs = getattr(e, "exceptions", None)
        if subs:
            for sub in subs:
                _walk(sub)
            return
        label = f"{type(e).__name__}: {e}".strip()
        if label and label not in leaves:
            leaves.append(label)

    _walk(exc)
    return "; ".join(leaves) or f"{type(exc).__name__}: {exc}"


async def _async_call(url: str, tool_name: str, arguments: dict) -> str:
    async def _run() -> str:
        async with streamablehttp_client(url) as (read, write, *_rest):
            async with ClientSession(read, write) as session:
                await session.initialize()
                result = await session.call_tool(tool_name, arguments)
                texts = [c.text for c in result.content if hasattr(c, "text")]
                return "\n".join(texts) or "(no output)"

    try:
        return await asyncio.wait_for(_run(), timeout=_MCP_TIMEOUT_S)
    except asyncio.TimeoutError:
        raise RuntimeError(
            f"timed out after {_MCP_TIMEOUT_S:.0f}s (endpoint unreachable or not responding)"
        ) from None


def check_mcp_reachable() -> dict:
    """Best-effort MCP handshake probe. Returns ``{url: "" if OK else error}``."""

    async def _probe(url: str) -> None:
        async with streamablehttp_client(url) as (read, write, *_rest):
            async with ClientSession(read, write) as session:
                await session.initialize()

    results: dict = {}
    for url in (K8S_URL, PROM_URL):
        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                pool.submit(
                    asyncio.run,
                    asyncio.wait_for(_probe(url), timeout=min(_MCP_TIMEOUT_S, 10.0)),
                ).result()
            results[url] = ""
        except Exception as exc:
            results[url] = _unwrap_exc(exc)
    return results


def _call_mcp(url: str, tool_name: str, arguments: dict) -> str:
    start = _utc_now()
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        try:
            result = pool.submit(asyncio.run, _async_call(url, tool_name, arguments)).result()
        except Exception as exc:
            end = _utc_now()
            detail = _unwrap_exc(exc)
            _record_tool_call(
                url=url,
                tool_name=tool_name,
                arguments=arguments,
                start=start,
                end=end,
                status="error",
                error=detail,
            )
            # Re-raise with the unwrapped cause so CrewAI's Observation text
            # (and `kubectl logs`) name the real problem instead of the opaque
            # "unhandled errors in a TaskGroup".
            raise RuntimeError(f"MCP call '{tool_name}' to {url} failed: {detail}") from exc
        end = _utc_now()
        _record_tool_call(
            url=url,
            tool_name=tool_name,
            arguments=arguments,
            start=start,
            end=end,
            status="success",
            output=result,
        )
        return result


def collect_minimum_evidence(namespace: str, remediate: bool = True) -> list[dict]:
    """Deterministically inspect the target namespace and (optionally) remediate
    scale-to-zero. Set ``remediate=False`` — via ``SRE_AGENT_PREFLIGHT_REMEDIATE``
    in __main__.py — to measure the agent's own remediation capability without
    the deterministic assist (the LLM tool-loop then has to fix it itself)."""
    findings: list[dict] = []
    _call_mcp(K8S_URL, "namespaces_list", {})
    _call_mcp(K8S_URL, "pods_list_in_namespace", {"namespace": namespace})
    _call_mcp(K8S_URL, "events_list", {"namespace": namespace})
    deployments_text = _call_mcp(
        K8S_URL,
        "resources_list",
        {"apiVersion": "apps/v1", "kind": "Deployment", "namespace": namespace},
    )
    try:
        deployments = _parse_json(deployments_text)
        items = deployments.get("items", []) if isinstance(deployments, dict) else deployments
    except ValueError as exc:
        # Structured parse failed (e.g. the MCP server is still on the default
        # `--list-output table`). Don't abandon the whole preflight — fall back
        # to a kubectl-style table scan that can still catch scale-to-zero.
        print(f"[sre-comprehensive] preflight: {exc}; falling back to table scan", flush=True)
        return _collect_from_table(deployments_text, namespace, remediate)
    if not isinstance(items, list):
        return findings

    for deployment in items:
        if not isinstance(deployment, dict):
            continue
        name = deployment.get("metadata", {}).get("name", "")
        spec = deployment.get("spec", {})
        status = deployment.get("status", {})
        replicas = int(spec.get("replicas") or 0)
        available = int(status.get("availableReplicas") or 0)
        if replicas == 0:
            if not remediate:
                continue
            _scale_workload(name, namespace, 1)
            findings.append(
                {
                    "name": f"{namespace}/Deployment/{name}",
                    "contributing_factor": True,
                    "reasoning": (
                        "Deployment had spec.replicas=0 during deterministic preflight; "
                        "scaled it back to 1 replica and will verify in subsequent scans."
                    ),
                }
            )
        elif available == 0 and remediate:
            # Only surface this in the "deterministic remediator" mode. Under
            # remediate=False (certify pure agent capability) the preflight must
            # NOT emit findings — a transient availableReplicas==0 during app
            # install would otherwise short-circuit the LLM loop in __main__.
            findings.append(
                {
                    "name": f"{namespace}/Deployment/{name}",
                    "contributing_factor": False,
                    "reasoning": "Deployment currently has zero available replicas and needs investigation.",
                }
            )
    return findings


def _collect_from_table(text: str, namespace: str, remediate: bool = True) -> list[dict]:
    """Fallback scale-to-zero detector for kubectl-style table output.

    Header is whitespace-delimited with a ``NAME`` and a ``READY`` column
    (``desired/current`` style, e.g. ``0/0``). A ``READY`` of ``0/0`` means the
    Deployment was scaled to zero — patch it back to one replica.
    """
    findings: list[dict] = []
    lines = [ln for ln in text.splitlines() if ln.strip()]
    if len(lines) < 2:
        return findings
    header = lines[0].split()
    try:
        name_i = header.index("NAME")
        ready_i = header.index("READY")
    except ValueError:
        return findings
    for row in lines[1:]:
        cols = row.split()
        if len(cols) <= max(name_i, ready_i):
            continue
        name, ready = cols[name_i], cols[ready_i]
        desired = ready.split("/")[-1] if "/" in ready else ready
        if desired == "0":
            if not remediate:
                continue
            _scale_workload(name, namespace, 1)
            findings.append(
                {
                    "name": f"{namespace}/Deployment/{name}",
                    "contributing_factor": True,
                    "reasoning": (
                        "Deployment READY column was 0/0 (scaled to zero) during "
                        "deterministic preflight table scan; scaled it back to 1 replica."
                    ),
                }
            )
    return findings


def _deep_merge(base: dict, overlay: dict) -> dict:
    """RFC 7396-ish recursive merge of ``overlay`` into ``base`` (in place)."""
    for key, val in overlay.items():
        if isinstance(val, dict) and isinstance(base.get(key), dict):
            _deep_merge(base[key], val)
        elif val is None:
            base.pop(key, None)
        else:
            base[key] = val
    return base


def _merge_write(api_version: str, kind: str, name: str,
                 namespace: Optional[str], patch_obj: dict) -> str:
    """Emulate a strategic/merge patch on an MCP server that only exposes
    ``resources_get`` + ``resources_create_or_update``: read the live object,
    deep-merge the patch, write it back whole."""
    gargs: dict = {"apiVersion": api_version, "kind": kind, "name": name}
    if namespace:
        gargs["namespace"] = namespace
    current = _parse_json(_call_mcp(K8S_URL, "resources_get", gargs))
    if not isinstance(current, dict):
        raise RuntimeError(f"unexpected resources_get payload for {kind}/{name}")
    # A server-managed field that rejects create_or_update if stale.
    current.get("metadata", {}).pop("managedFields", None)
    _deep_merge(current, patch_obj)
    return _call_mcp(K8S_URL, "resources_create_or_update", {"resource": json.dumps(current)})


def _scale_workload(name: str, namespace: str, replicas: int) -> None:
    """Set a Deployment's replica count via the MCP server's ``resources_scale``
    tool. This server build exposes ``resources_scale`` (and
    ``resources_create_or_update``) but **no** generic ``resources_patch`` —
    calling the latter fails with ``unknown tool "resources_patch"``.
    """
    _call_mcp(
        K8S_URL,
        "resources_scale",
        {
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "name": name,
            "namespace": namespace,
            "scale": replicas,
        },
    )


def _parse_json(text: str) -> dict | list:
    """Parse structured data from an MCP ``resources_list`` / ``get`` response.

    The containers/kubernetes-mcp-server emits **table** text by default
    (``--list-output`` defaults to ``table``); the app charts now pass
    ``--list-output yaml`` so these responses are YAML. Older/renderer
    variants can still hand back JSON or JSON-with-prose, so try, in order:
    JSON → embedded JSON → YAML (single or multi-doc). A YAML ``kind: *List``
    document is normalised to ``{"items": [...]}`` so callers that expect the
    Kubernetes list shape keep working.
    """
    text = text.strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    # YAML — the primary format the MCP server emits for `resources_get` and,
    # with `--list-output yaml`, for `resources_list`. Tried BEFORE the regex
    # fallback below: a resource YAML often contains a literal `{}` (e.g.
    # `emptyDir: {}`, `securityContext: {}`, an inline JSON annotation), and a
    # greedy `\{.*\}` search would "successfully" json.loads that fragment into
    # an empty dict, silently discarding the whole object.
    try:
        import yaml  # PyYAML — pulled in transitively by crewai

        docs = [d for d in yaml.safe_load_all(text) if d is not None]
    except Exception:
        docs = []
    if len(docs) == 1:
        doc = docs[0]
        if isinstance(doc, dict):
            return doc
        if isinstance(doc, list):
            return {"items": doc}
    elif len(docs) > 1:
        # multi-doc stream (one YAML doc per resource)
        return {"items": [d for d in docs if isinstance(d, dict)]}
    # Last resort: pull the outermost JSON object/array out of surrounding prose.
    for pat in (r"\{.*\}", r"\[.*\]"):
        m = re.search(pat, text, re.DOTALL)
        if m:
            try:
                parsed = json.loads(m.group(0))
                if parsed:  # ignore an empty {} / [] fragment match
                    return parsed
            except json.JSONDecodeError:
                continue
    raise ValueError(f"Cannot parse structured data from MCP response: {text[:300]}")


# ---------------------------------------------------------------------------
# Shared arg schemas
# ---------------------------------------------------------------------------

def _clean(v: str) -> str:
    """Strip surrounding quotes that open-weight LLMs sometimes wrap string args in.

    qwen2.5 occasionally emits {"namespace": "\"otel-demo\""} which CrewAI
    passes through as the literal string '"otel-demo"'. Stripping one layer of
    surrounding single or double quotes recovers the intended value.
    """
    if isinstance(v, str):
        s = v.strip()
        if len(s) >= 2 and s[0] in ('"', "'") and s[-1] == s[0]:
            return s[1:-1]
    return v


class _Empty(BaseModel):
    pass


class _NSInput(BaseModel):
    namespace: str = Field(description="Kubernetes namespace")

    @field_validator("namespace", mode="before")
    @classmethod
    def clean_namespace(cls, v: str) -> str:
        return _clean(v)


class _ListPodsInput(BaseModel):
    namespace: str = Field(description="Kubernetes namespace, e.g. 'otel-demo'")
    label_selector: Optional[str] = Field(
        default=None,
        description="Optional label selector, e.g. 'chaos-injector' or 'app=cart'",
    )

    @field_validator("namespace", mode="before")
    @classmethod
    def clean_namespace(cls, v: str) -> str:
        return _clean(v)


class _ListResourcesInput(BaseModel):
    api_version: str = Field(
        description=(
            "API version, e.g. 'v1', 'apps/v1', 'networking.k8s.io/v1', "
            "'autoscaling/v2', 'scheduling.k8s.io/v1'"
        )
    )
    kind: str = Field(
        description=(
            "Resource kind, e.g. 'Deployment', 'Service', 'NetworkPolicy', "
            "'ResourceQuota', 'HorizontalPodAutoscaler', 'PersistentVolumeClaim', "
            "'ReplicaSet', 'PriorityClass', 'Node', 'ConfigMap', 'Secret'"
        )
    )
    namespace: Optional[str] = Field(
        default=None,
        description="Namespace (omit for cluster-scoped resources like Node, PriorityClass)",
    )
    label_selector: Optional[str] = Field(
        default=None,
        description="Optional label selector to filter results",
    )

    @field_validator("api_version", "kind", "namespace", "label_selector", mode="before")
    @classmethod
    def clean_strings(cls, v: str) -> str:
        return _clean(v) if v is not None else v


class _GetResourceInput(BaseModel):
    api_version: str = Field(description="API version")
    kind: str = Field(description="Resource kind")
    name: str = Field(description="Resource name")
    namespace: Optional[str] = Field(default=None, description="Namespace")

    @field_validator("api_version", "kind", "name", "namespace", mode="before")
    @classmethod
    def clean_strings(cls, v: str) -> str:
        return _clean(v) if v is not None else v


class _DeleteResourceInput(BaseModel):
    api_version: str = Field(description="API version")
    kind: str = Field(description="Resource kind")
    name: str = Field(description="Resource name to delete")
    namespace: Optional[str] = Field(default=None, description="Namespace")

    @field_validator("api_version", "kind", "name", "namespace", mode="before")
    @classmethod
    def clean_strings(cls, v: str) -> str:
        return _clean(v) if v is not None else v


class _PodLogsInput(BaseModel):
    name: str = Field(description="Pod name")
    namespace: Optional[str] = Field(default=None, description="Namespace")
    tail: Optional[int] = Field(default=50, description="Number of log lines to return")

    @field_validator("name", "namespace", mode="before")
    @classmethod
    def clean_strings(cls, v: str) -> str:
        return _clean(v) if v is not None else v


class _PatchInput(BaseModel):
    api_version: str = Field(description="API version, e.g. 'v1', 'apps/v1'")
    kind: str = Field(description="Resource kind")
    name: str = Field(description="Resource name")
    namespace: Optional[str] = Field(default=None, description="Namespace (omit for cluster-scoped)")
    patch: str = Field(
        description=(
            "JSON merge patch string (RFC 7396). Only the specified fields are changed. "
            'Example: \'{"spec":{"unschedulable":false}}\' to uncordon a node. '
            'Example: \'{"spec":{"replicas":1}}\' to scale a deployment. '
            'Example: \'{"spec":{"selector":{"app":"correct-name"}}}\' to fix a service selector. '
            'Example: \'{"spec":{"hard":{"requests.cpu":"2","requests.memory":"4Gi"}}}\' for quota.'
        )
    )


class _ApplyInput(BaseModel):
    spec: str = Field(
        description=(
            "Complete JSON spec of the resource to create or update. "
            "Must include apiVersion, kind, metadata (with name and namespace), and spec."
        )
    )


class _RolloutUndoInput(BaseModel):
    name: str = Field(description="Name of the Deployment to roll back")
    namespace: str = Field(description="Namespace of the Deployment")

    @field_validator("name", "namespace", mode="before")
    @classmethod
    def clean_strings(cls, v: str) -> str:
        return _clean(v)


class _PromQLInput(BaseModel):
    query: str = Field(
        description=(
            "PromQL expression to execute against Prometheus. "
            "Examples: "
            "rate(traces_span_metrics_calls_total{service_name='quote',status_code='STATUS_CODE_ERROR'}[5m]) "
            "kube_pod_status_ready{namespace='otel-demo'}"
        )
    )


# ---------------------------------------------------------------------------
# Kubernetes tools — read-only
# ---------------------------------------------------------------------------

class ListNamespacesTool(BaseTool):
    name: str = "list_namespaces"
    description: str = "List all Kubernetes namespaces in the cluster."
    args_schema: Type[BaseModel] = _Empty

    def _run(self) -> str:  # type: ignore[override]
        return _call_mcp(K8S_URL, "namespaces_list", {})


class ListNodesTool(BaseTool):
    name: str = "list_nodes"
    description: str = (
        "List all Kubernetes nodes with their status, conditions, and schedulability. "
        "Use to detect cordoned nodes (spec.unschedulable=true) or NotReady nodes."
    )
    args_schema: Type[BaseModel] = _Empty

    def _run(self) -> str:  # type: ignore[override]
        # This MCP server build has no `nodes_list`; Node is a normal resource.
        return _call_mcp(K8S_URL, "resources_list", {"apiVersion": "v1", "kind": "Node"})


class ListPodsTool(BaseTool):
    name: str = "list_pods_in_namespace"
    description: str = (
        "List all pods in a Kubernetes namespace with their status and readiness. "
        "Use label_selector to find rogue injector pods (e.g. 'chaos-injector')."
    )
    args_schema: Type[BaseModel] = _ListPodsInput

    def _run(self, namespace: str, label_selector: Optional[str] = None) -> str:  # type: ignore[override]
        args: dict = {"namespace": namespace}
        if label_selector:
            args["labelSelector"] = label_selector
        return _call_mcp(K8S_URL, "pods_list_in_namespace", args)


class ListEventsTool(BaseTool):
    name: str = "list_k8s_events"
    description: str = (
        "List Kubernetes events in a namespace. "
        "Shows warnings (FailedScheduling, BackOff, FailedMount, OOMKilling, etc.) "
        "that reveal the root cause of pod failures."
    )
    args_schema: Type[BaseModel] = _NSInput

    def _run(self, namespace: str) -> str:  # type: ignore[override]
        return _call_mcp(K8S_URL, "events_list", {"namespace": namespace})


class ListResourcesTool(BaseTool):
    name: str = "list_k8s_resources"
    description: str = (
        "List Kubernetes resources by apiVersion and kind. "
        "Supports any resource type: Deployment, Service, NetworkPolicy, "
        "ResourceQuota, HorizontalPodAutoscaler, PersistentVolumeClaim, "
        "ReplicaSet, PriorityClass, ConfigMap, Secret, Node, etc."
    )
    args_schema: Type[BaseModel] = _ListResourcesInput

    def _run(  # type: ignore[override]
        self,
        api_version: str,
        kind: str,
        namespace: Optional[str] = None,
        label_selector: Optional[str] = None,
    ) -> str:
        args: dict = {"apiVersion": api_version, "kind": kind}
        if namespace:
            args["namespace"] = namespace
        if label_selector:
            args["labelSelector"] = label_selector
        return _call_mcp(K8S_URL, "resources_list", args)


class GetResourceTool(BaseTool):
    name: str = "get_k8s_resource"
    description: str = (
        "Get the full spec of a specific Kubernetes resource. "
        "Use to inspect: Deployment initContainers, container image/command/probe/env/resources, "
        "nodeSelector, affinity, dnsPolicy; Service selector and ports; "
        "NetworkPolicy ingress rules; ConfigMap data; Secret data."
    )
    args_schema: Type[BaseModel] = _GetResourceInput

    def _run(  # type: ignore[override]
        self,
        api_version: str,
        kind: str,
        name: str,
        namespace: Optional[str] = None,
    ) -> str:
        args: dict = {"apiVersion": api_version, "kind": kind, "name": name}
        if namespace:
            args["namespace"] = namespace
        return _call_mcp(K8S_URL, "resources_get", args)


class GetPodLogsTool(BaseTool):
    name: str = "get_pod_logs"
    description: str = "Fetch recent log lines from a pod. Use to diagnose CrashLoopBackOff."
    args_schema: Type[BaseModel] = _PodLogsInput

    def _run(self, name: str, namespace: Optional[str] = None, tail: Optional[int] = 50) -> str:  # type: ignore[override]
        args: dict = {"name": name}
        if namespace:
            args["namespace"] = namespace
        if tail:
            args["tail"] = tail
        return _call_mcp(K8S_URL, "pods_log", args)


# ---------------------------------------------------------------------------
# Kubernetes tools — write (remediation)
# ---------------------------------------------------------------------------

class DeleteResourceTool(BaseTool):
    name: str = "delete_k8s_resource"
    description: str = (
        "Delete a Kubernetes resource. Use for: "
        "NetworkPolicy (ingress blocking), "
        "rogue injector Pods (label chaos-injector), "
        "workload-scanner Deployment (API server surge), "
        "chaos-priority-preemption-decoy Deployment, "
        "chaos-priority-preemption PriorityClass, "
        "stuck PersistentVolumeClaims, "
        "stressed/stuck Pods (they auto-restart from their controller)."
    )
    args_schema: Type[BaseModel] = _DeleteResourceInput

    def _run(  # type: ignore[override]
        self,
        api_version: str,
        kind: str,
        name: str,
        namespace: Optional[str] = None,
    ) -> str:
        args: dict = {"apiVersion": api_version, "kind": kind, "name": name}
        if namespace:
            args["namespace"] = namespace
        return _call_mcp(K8S_URL, "resources_delete", args)


class PatchResourceTool(BaseTool):
    name: str = "patch_resource"
    description: str = (
        "Apply a JSON merge patch to any Kubernetes resource. "
        "Only the specified fields change; all others remain. "
        "Use for: "
        "uncordon a node — patch={'spec':{'unschedulable':false}}; "
        "fix Service selector — patch={'spec':{'selector':{'app':'correct-name'}}}; "
        "fix Service targetPort — patch={'spec':{'ports':[{'port':80,'targetPort':8080,'name':'http'}]}}; "
        "delete ResourceQuota — delete_k8s_resource instead; "
        "fix HPA metrics — patch={'spec':{'metrics':[{'type':'Resource','resource':{'name':'cpu','target':{'type':'Utilization','averageUtilization':80}}}]}}; "
        "scale Deployment — patch={'spec':{'replicas':1}}; "
        "fix ConfigMap data — patch={'data':{'key':'corrected-value'}}."
    )
    args_schema: Type[BaseModel] = _PatchInput

    def _run(  # type: ignore[override]
        self,
        api_version: str,
        kind: str,
        name: str,
        patch: str,
        namespace: Optional[str] = None,
    ) -> str:
        try:
            patch_obj = json.loads(patch) if isinstance(patch, str) else dict(patch)
        except (json.JSONDecodeError, TypeError, ValueError) as exc:
            return f"patch_resource: patch is not valid JSON — {exc}"

        # This MCP server build has no generic `resources_patch`. A replicas-only
        # patch maps cleanly onto `resources_scale`; anything else is done as a
        # read-merge-write through `resources_get` + `resources_create_or_update`.
        if set(patch_obj) == {"spec"} and set(patch_obj["spec"]) == {"replicas"}:
            try:
                sargs = {"apiVersion": api_version, "kind": kind, "name": name,
                         "scale": int(patch_obj["spec"]["replicas"])}
                if namespace:
                    sargs["namespace"] = namespace
                return _call_mcp(K8S_URL, "resources_scale", sargs)
            except Exception as e:  # noqa: BLE001 - fall through to merge path
                pass

        try:
            return _merge_write(api_version, kind, name, namespace, patch_obj)
        except Exception as e:  # noqa: BLE001
            return (
                f"patch_resource: merge-write of {kind}/{name} failed — {e}. "
                "For a Deployment pod-template change, use rollout_undo instead."
            )


class ApplyResourceTool(BaseTool):
    name: str = "apply_resource"
    description: str = (
        "Create or replace a Kubernetes resource from a complete JSON spec. "
        "Use when a resource has been DELETED and needs to be recreated "
        "(e.g. a deleted Service or ResourceQuota). "
        "The spec must include apiVersion, kind, metadata.name, "
        "metadata.namespace (if namespaced), and spec."
    )
    args_schema: Type[BaseModel] = _ApplyInput

    def _run(self, spec: str) -> str:  # type: ignore[override]
        try:
            parsed = json.loads(spec)
        except json.JSONDecodeError as exc:
            return f"apply_resource: spec is not valid JSON — {exc}"
        try:
            return _call_mcp(K8S_URL, "resources_create_or_update", {"resource": json.dumps(parsed)})
        except Exception as e:  # noqa: BLE001
            return (
                f"apply_resource: resources_create_or_update failed — {e}. "
                "Try patch_resource with the existing resource instead."
            )


class RolloutUndoTool(BaseTool):
    name: str = "rollout_undo"
    description: str = (
        "Undo the last rollout of a Deployment, reverting to its previous working revision. "
        "Equivalent to 'kubectl rollout undo deployment/<name> -n <namespace>'. "
        "Use for ANY Deployment whose pod template was modified by a fault: "
        "bad initContainer (CrashLoopBackOff or Init:* state), "
        "wrong container image (ImagePullBackOff), "
        "wrong container command (/nonexistent-binary), "
        "broken readinessProbe (pods NotReady), "
        "wrong environment variable, "
        "wrong nodeSelector (pods Pending on nonexistent node), "
        "impossible podAntiAffinity (pods Pending), "
        "wrong dnsPolicy (DNS resolution failures), "
        "insufficient container resources (OOMKilled / CrashLoopBackOff), "
        "bad PVC volume mount (pods Pending with FailedMount)."
    )
    args_schema: Type[BaseModel] = _RolloutUndoInput

    def _run(self, name: str, namespace: str) -> str:  # type: ignore[override]
        try:
            return self._do_rollout_undo(name, namespace)
        except Exception as exc:
            return (
                f"rollout_undo failed for {namespace}/{name}: {exc}. "
                "As a fallback, use get_k8s_resource to read the Deployment, "
                "identify the injected field, and call patch_resource to correct it."
            )

    # ------------------------------------------------------------------
    # Implementation: find previous ReplicaSet revision, patch Deployment
    # ------------------------------------------------------------------

    def _do_rollout_undo(self, name: str, namespace: str) -> str:
        # 1. Get current Deployment
        deploy_text = _call_mcp(K8S_URL, "resources_get", {
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "name": name,
            "namespace": namespace,
        })
        deploy = _parse_json(deploy_text)

        # 2. Determine current revision
        annotations: dict = deploy.get("metadata", {}).get("annotations", {})
        current_rev = int(annotations.get("deployment.kubernetes.io/revision", "1"))
        target_rev = current_rev - 1

        if target_rev < 1:
            return (
                f"Deployment {name} is at revision 1 — no previous revision exists. "
                "Use patch_resource to manually correct the broken field instead."
            )

        # 3. Build label selector from Deployment's matchLabels
        match_labels: dict = (
            deploy.get("spec", {}).get("selector", {}).get("matchLabels", {})
        )
        label_selector = ",".join(f"{k}={v}" for k, v in match_labels.items())

        # 4. List ReplicaSets for this Deployment
        rs_args: dict = {
            "apiVersion": "apps/v1",
            "kind": "ReplicaSet",
            "namespace": namespace,
        }
        if label_selector:
            rs_args["labelSelector"] = label_selector

        rs_text = _call_mcp(K8S_URL, "resources_list", rs_args)
        rs_data = _parse_json(rs_text)
        items: list = rs_data.get("items", []) if isinstance(rs_data, dict) else []

        # 5. Find the ReplicaSet for target_rev
        target_rs: dict | None = None
        for rs in items:
            rs_rev = int(
                rs.get("metadata", {})
                  .get("annotations", {})
                  .get("deployment.kubernetes.io/revision", "0")
            )
            if rs_rev == target_rev:
                target_rs = rs
                break

        if not target_rs:
            found = [
                rs.get("metadata", {})
                  .get("annotations", {})
                  .get("deployment.kubernetes.io/revision", "?")
                for rs in items
            ]
            return (
                f"Cannot find ReplicaSet with revision {target_rev} for Deployment {name}. "
                f"Found revisions: {found}. "
                "Use patch_resource to manually correct the broken field in the Deployment spec."
            )

        # 6. Extract pod template from target RS
        prev_template: dict = target_rs.get("spec", {}).get("template", {})
        if not prev_template:
            return f"Previous ReplicaSet (rev {target_rev}) has no pod template."

        # Strip tracking annotation that would conflict with rolling update hash
        tmpl_meta: dict = prev_template.get("metadata", {})
        annots: dict = tmpl_meta.get("annotations", {})
        annots.pop("kubectl.kubernetes.io/last-applied-configuration", None)
        annots.pop("deployment.kubernetes.io/revision", None)

        # 7. Patch the Deployment's pod template (read-merge-write; this MCP
        #    server build has no generic resources_patch)
        result = _merge_write(
            "apps/v1", "Deployment", name, namespace,
            {"spec": {"template": prev_template}},
        )
        return (
            f"Rolled back Deployment {name} to revision {target_rev}. "
            f"Pods will restart with the previous configuration. "
            f"MCP response: {result[:300]}"
        )


# ---------------------------------------------------------------------------
# Prometheus tool
# ---------------------------------------------------------------------------

class ExecutePromQLTool(BaseTool):
    name: str = "execute_promql_query"
    description: str = (
        "Execute a PromQL instant query against Prometheus. "
        "Use to confirm service impact (error rate spikes) and verify recovery "
        "(error rate returning to zero)."
    )
    args_schema: Type[BaseModel] = _PromQLInput

    def _run(self, query: str) -> str:  # type: ignore[override]
        return _call_mcp(PROM_URL, "execute_query", {"query": query})


# ---------------------------------------------------------------------------
# Public interface
# ---------------------------------------------------------------------------

_COMPACT_CAP = int(os.environ.get("SRE_AGENT_OBS_CHAR_CAP", "2600"))


def _pod_rows(items: list) -> str:
    """One line per pod: only the unhealthy ones in full, the rest summarised."""
    unhealthy, healthy = [], 0
    for p in items:
        if not isinstance(p, dict):
            continue
        meta, status = p.get("metadata", {}), p.get("status", {})
        name = meta.get("name", "?")
        phase = status.get("phase", "?")
        cs = status.get("containerStatuses") or []
        ready = sum(1 for c in cs if c.get("ready"))
        total = len(cs) or 1
        restarts = sum(int(c.get("restartCount", 0)) for c in cs)
        waiting = next(
            (c["state"]["waiting"].get("reason")
             for c in cs
             if isinstance(c.get("state", {}).get("waiting"), dict)),
            "",
        )
        is_healthy = phase == "Running" and ready == total and not waiting
        if is_healthy:
            healthy += 1
        else:
            unhealthy.append(
                f"  {name}  phase={phase} ready={ready}/{total} restarts={restarts}"
                + (f" {waiting}" if waiting else "")
            )
    out = ["UNHEALTHY PODS:" if unhealthy else "All pods healthy."]
    out += unhealthy
    if healthy:
        out.append(f"(+{healthy} other pods Running/Ready)")
    return "\n".join(out)


def _workload_rows(items: list, kind: str) -> str:
    rows = [f"{kind}S (name  spec.replicas  status.available):"]
    for d in items:
        if not isinstance(d, dict):
            continue
        n = d.get("metadata", {}).get("name", "?")
        spec_r = d.get("spec", {}).get("replicas", "?")
        avail = d.get("status", {}).get("availableReplicas", 0)
        rows.append(f"  {n}  {spec_r}  {avail}")
    return "\n".join(rows)


def compact_tool_output(tool_name: str, arguments: dict, text: str) -> str:
    """Shrink a verbose MCP observation so a multi-step investigation fits in
    context. Structured summaries for pod / workload lists; a head+tail char
    cap for everything else. Never raises — worst case returns the raw text
    truncated."""
    try:
        if tool_name == "list_pods_in_namespace":
            data = _parse_json(text)
            items = data.get("items", data) if isinstance(data, dict) else data
            if isinstance(items, list):
                return _pod_rows(items)
        if tool_name == "list_k8s_resources" and str(arguments.get("kind", "")).lower() in (
            "deployment", "statefulset", "daemonset", "replicaset"
        ):
            data = _parse_json(text)
            items = data.get("items", data) if isinstance(data, dict) else data
            if isinstance(items, list):
                return _workload_rows(items, str(arguments.get("kind")))
    except Exception:
        pass
    if len(text) <= _COMPACT_CAP:
        return text
    head = text[: _COMPACT_CAP * 2 // 3]
    tail = text[-_COMPACT_CAP // 3 :]
    return f"{head}\n… [{len(text) - _COMPACT_CAP} chars elided] …\n{tail}"


def get_all_tools() -> list:
    return [
        # Discovery
        ListNamespacesTool(),
        ListNodesTool(),
        ListPodsTool(),
        ListEventsTool(),
        ListResourcesTool(),
        GetResourceTool(),
        GetPodLogsTool(),
        # Remediation
        DeleteResourceTool(),
        PatchResourceTool(),
        ApplyResourceTool(),
        RolloutUndoTool(),
        # Observability
        ExecutePromQLTool(),
    ]
