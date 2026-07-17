"""CrewAI tools backed by the Kubernetes and Prometheus MCP servers.

Both servers expose the MCP streamable-HTTP transport (POST /mcp).
Each tool opens a fresh session per call so there are no shared-state issues
between CrewAI's sequential tool invocations.
"""
from __future__ import annotations

import asyncio
import concurrent.futures
from typing import Optional, Type

from crewai.tools import BaseTool
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client
from pydantic import BaseModel, Field

K8S_URL = "http://127.0.0.1:18081/mcp"
PROM_URL = "http://127.0.0.1:31085/mcp"


# ---------------------------------------------------------------------------
# Low-level async MCP call, bridged to sync via a dedicated thread so it
# never conflicts with CrewAI's own asyncio usage.
# ---------------------------------------------------------------------------

async def _async_call(url: str, tool_name: str, arguments: dict) -> str:
    async with streamablehttp_client(url) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(tool_name, arguments)
            texts = [
                c.text for c in result.content if hasattr(c, "text")
            ]
            return "\n".join(texts) or "(no output)"


def _call_mcp(url: str, tool_name: str, arguments: dict) -> str:
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        return pool.submit(asyncio.run, _async_call(url, tool_name, arguments)).result()


# ---------------------------------------------------------------------------
# Kubernetes tools
# ---------------------------------------------------------------------------

class _Empty(BaseModel):
    pass


class ListNamespacesTool(BaseTool):
    name: str = "list_namespaces"
    description: str = "List all Kubernetes namespaces in the cluster."
    args_schema: Type[BaseModel] = _Empty

    def _run(self) -> str:  # type: ignore[override]
        return _call_mcp(K8S_URL, "namespaces_list", {})


class _ListPodsInput(BaseModel):
    namespace: str = Field(description="Kubernetes namespace, e.g. 'otel-demo'")
    label_selector: Optional[str] = Field(
        default=None, description="Optional label selector, e.g. 'app=quote'"
    )


class ListPodsTool(BaseTool):
    name: str = "list_pods_in_namespace"
    description: str = (
        "List all pods in a Kubernetes namespace. "
        "Shows pod name, status, and readiness."
    )
    args_schema: Type[BaseModel] = _ListPodsInput

    def _run(self, namespace: str, label_selector: Optional[str] = None) -> str:  # type: ignore[override]
        args: dict = {"namespace": namespace}
        if label_selector:
            args["labelSelector"] = label_selector
        return _call_mcp(K8S_URL, "pods_list_in_namespace", args)


class _NSInput(BaseModel):
    namespace: str = Field(description="Kubernetes namespace")


class ListEventsTool(BaseTool):
    name: str = "list_k8s_events"
    description: str = (
        "List Kubernetes events in a namespace. "
        "Shows warnings, errors, and recent activity."
    )
    args_schema: Type[BaseModel] = _NSInput

    def _run(self, namespace: str) -> str:  # type: ignore[override]
        return _call_mcp(K8S_URL, "events_list", {"namespace": namespace})


class _ListResourcesInput(BaseModel):
    api_version: str = Field(
        description="API version, e.g. 'networking.k8s.io/v1' or 'apps/v1' or 'v1'"
    )
    kind: str = Field(
        description="Resource kind, e.g. 'NetworkPolicy', 'Deployment', 'Service'"
    )
    namespace: Optional[str] = Field(
        default=None,
        description="Namespace to search (omit for cluster-scoped resources)",
    )


class ListResourcesTool(BaseTool):
    name: str = "list_k8s_resources"
    description: str = (
        "List Kubernetes resources by kind. "
        "Use api_version='networking.k8s.io/v1', kind='NetworkPolicy' "
        "to find network policies."
    )
    args_schema: Type[BaseModel] = _ListResourcesInput

    def _run(  # type: ignore[override]
        self, api_version: str, kind: str, namespace: Optional[str] = None
    ) -> str:
        args: dict = {"apiVersion": api_version, "kind": kind}
        if namespace:
            args["namespace"] = namespace
        return _call_mcp(K8S_URL, "resources_list", args)


class _GetResourceInput(BaseModel):
    api_version: str = Field(description="API version, e.g. 'networking.k8s.io/v1'")
    kind: str = Field(description="Resource kind, e.g. 'NetworkPolicy'")
    name: str = Field(description="Resource name")
    namespace: Optional[str] = Field(default=None, description="Namespace")


class GetResourceTool(BaseTool):
    name: str = "get_k8s_resource"
    description: str = (
        "Get the full spec of a specific Kubernetes resource by name. "
        "Use to inspect a suspicious NetworkPolicy's podSelector and ingress rules."
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


class _DeleteResourceInput(BaseModel):
    api_version: str = Field(description="API version, e.g. 'networking.k8s.io/v1'")
    kind: str = Field(description="Resource kind, e.g. 'NetworkPolicy'")
    name: str = Field(description="Resource name to delete")
    namespace: Optional[str] = Field(default=None, description="Namespace")


class DeleteResourceTool(BaseTool):
    name: str = "delete_k8s_resource"
    description: str = (
        "Delete a Kubernetes resource. "
        "Use to remove a faulty NetworkPolicy that is blocking traffic."
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


class _PodLogsInput(BaseModel):
    name: str = Field(description="Pod name")
    namespace: Optional[str] = Field(default=None, description="Namespace")
    tail: Optional[int] = Field(default=50, description="Number of log lines")


class GetPodLogsTool(BaseTool):
    name: str = "get_pod_logs"
    description: str = "Fetch recent log lines from a specific pod."
    args_schema: Type[BaseModel] = _PodLogsInput

    def _run(  # type: ignore[override]
        self, name: str, namespace: Optional[str] = None, tail: Optional[int] = 50
    ) -> str:
        args: dict = {"name": name}
        if namespace:
            args["namespace"] = namespace
        if tail:
            args["tail"] = tail
        return _call_mcp(K8S_URL, "pods_log", args)


# ---------------------------------------------------------------------------
# Prometheus tools
# ---------------------------------------------------------------------------

class _PromQLInput(BaseModel):
    query: str = Field(
        description=(
            "PromQL expression. "
            "Example: rate(traces_span_metrics_calls_total"
            "{service_name='quote',status_code='STATUS_CODE_ERROR'}[5m])"
        )
    )


class ExecutePromQLTool(BaseTool):
    name: str = "execute_promql_query"
    description: str = (
        "Execute a PromQL instant query against Prometheus. "
        "Use to check error rates, latency, and service health metrics."
    )
    args_schema: Type[BaseModel] = _PromQLInput

    def _run(self, query: str) -> str:  # type: ignore[override]
        return _call_mcp(PROM_URL, "execute_query", {"query": query})


# ---------------------------------------------------------------------------

def get_all_tools() -> list:
    return [
        ListNamespacesTool(),
        ListPodsTool(),
        ListEventsTool(),
        ListResourcesTool(),
        GetResourceTool(),
        DeleteResourceTool(),
        GetPodLogsTool(),
        ExecutePromQLTool(),
    ]
