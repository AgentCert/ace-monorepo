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
import json
import os
import re
from typing import Optional, Type

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


# ---------------------------------------------------------------------------
# Low-level async → sync MCP bridge (fresh session per call, no shared state)
# ---------------------------------------------------------------------------

async def _async_call(url: str, tool_name: str, arguments: dict) -> str:
    async with streamablehttp_client(url) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(tool_name, arguments)
            texts = [c.text for c in result.content if hasattr(c, "text")]
            return "\n".join(texts) or "(no output)"


def _call_mcp(url: str, tool_name: str, arguments: dict) -> str:
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        return pool.submit(asyncio.run, _async_call(url, tool_name, arguments)).result()


def _parse_json(text: str) -> dict | list:
    """Parse JSON from MCP response text which may contain surrounding prose."""
    text = text.strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    # Find the outermost JSON object or array
    for pat in (r"\{.*\}", r"\[.*\]"):
        m = re.search(pat, text, re.DOTALL)
        if m:
            try:
                return json.loads(m.group(0))
            except json.JSONDecodeError:
                continue
    raise ValueError(f"Cannot parse JSON from MCP response: {text[:300]}")


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
        # Try dedicated nodes_list endpoint first; fall back to resources_list
        try:
            return _call_mcp(K8S_URL, "nodes_list", {})
        except Exception:
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
        args: dict = {"apiVersion": api_version, "kind": kind, "name": name, "patch": patch}
        if namespace:
            args["namespace"] = namespace
        try:
            return _call_mcp(K8S_URL, "resources_patch", args)
        except Exception as e:
            return (
                f"patch_resource call failed: {e}. "
                "If the MCP server does not support resources_patch, "
                "try delete_k8s_resource followed by apply_resource, "
                "or use rollout_undo for Deployment modifications."
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
        for method in ("resources_apply", "resources_create"):
            try:
                return _call_mcp(K8S_URL, method, {"spec": json.dumps(parsed)})
            except Exception:
                continue
        return (
            "apply_resource: neither resources_apply nor resources_create is available "
            "on this MCP server. Try patch_resource with the existing resource instead."
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

        # 7. Patch the Deployment's pod template
        patch = {"spec": {"template": prev_template}}
        result = _call_mcp(K8S_URL, "resources_patch", {
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "name": name,
            "namespace": namespace,
            "patch": json.dumps(patch),
        })
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
