"""
Flash Agent – FLASH-style Workflow Automation Agent
====================================================

Implements Microsoft Research's FLASH methodology for reliable
multi-step task execution with status supervision and hindsight.

FLASH Reasoning Loop (per scan):
  1. DISCOVER          → Discover available MCP tools
  2. REASON + ACT      → LLM decides which tools to call (ReAct loop)
  3. ANALYZE           → LLM produces structured analysis
  4. REFLECT           → Generate hindsight from failures for future scans

Key FLASH enhancements:
  - Status Supervision: Breaks complex tasks into status-dependent steps
  - Hindsight Integration: Learns from past failures to improve reliability
  - Agentic Tool Use: LLM decides which tools to call with what arguments

Reference: https://www.microsoft.com/en-us/research/project/flash-a-reliable-workflow-automation-agent/
"""

from __future__ import annotations

import hashlib
import json
import logging
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Callable, Dict, List, Optional, Tuple

import requests
from openai import AzureOpenAI, OpenAI
from openai.types.chat import ChatCompletionMessageToolCall

from config import AgentConfig
from llm.hindsight import HindsightBuilder
from llm.utils import (
    create_history_entry,
    format_analysis_for_history,
    trim_history_to_token_limit,
)
from mcp.client import MCPClient, MCPScope

logger = logging.getLogger("flash-agent")

# Maximum tool-calling iterations to prevent infinite loops
MAX_TOOL_ITERATIONS = 10


_SYSTEM_PROMPT_HEAD = """You are an ITOps analysis agent with access to Kubernetes tools via MCP.

Your task is to analyze the health of your assigned Kubernetes scope by:
1. Using the available tools to gather information
2. Investigating any issues you discover
3. Producing a final structured analysis
4. For every actionable issue, giving concrete remediation guidance that tells the operator to remediate and fix the issue when it is safe and authorized to do so"""


_SYSTEM_PROMPT_OUTPUT_FORMAT = """## When You Have Enough Information
Once you have gathered sufficient data to assess cluster health, provide your final analysis.

## JSON Output Format
Your final response must be a valid JSON object with this structure:
{
  "status_reasoning": {
    "determined_status": "healthy|degraded|critical|unknown",
    "status_justification": ["reason1", "reason2"],
    "data_quality": {
      "completeness": "complete|partial|insufficient",
      "gaps": ["metrics_unavailable", "logs_unavailable", ...],
      "confidence_impact": "Health score capped due to missing observability"
    }
  },
  "thoughts": {
    "key_observations": [],
    "analysis_approach": [],
    "observability_gaps": ["List any tools that failed or data that was unavailable"]
  },
  "health": {
    "total_pods": 0,
    "healthy_pods": 0,
    "unhealthy_pods": 0,
    "error_count": 0,
    "warning_count": 0,
    "overall_health_score": 0
  },
  "issues": [
    {
      "severity": "critical|warning|info",
      "component": "component-name",
      "category": "category",
      "summary": "description",
      "recommended_action": "what to do to remediate and fix the issue"
    }
  ],
  "insights": {
    "summary": "overall summary",
    "concerns": [],
    "recommendations": [],
    "observability_recommendations": ["Deploy metrics-server", ...]
  }
}

## Remediation Guidance
For every issue in the `issues` array, `recommended_action` must be concrete, operational, and fix-oriented.
Do not stop at diagnosis. When the evidence supports an action, explicitly say to remediate and fix the issue.
Recommend the safest corrective action available from the observed evidence, and clearly call out when execution should be handled by an operator or automation system."""


_FALLBACK_DOCTRINE = """## Fallback Doctrine
The full inventory of tools you can call is supplied to you as `tools=[...]`.
Inspect each tool's `name`, `description`, and `inputSchema` before deciding
which one to call — argument names and tool naming vary across MCP servers,
so DO NOT assume any specific tool exists; pick by shape and description.

When a tool returns `forbidden`, do NOT retry it.
When a tool returns `not available` (or a similar "backend missing" error), do
NOT give up: scan your remaining tools and find one that can answer the same
question through a different route (e.g. if a snapshot tool is unavailable,
look for a tool that accepts a query string and ask a timeseries backend).
Only record an observability gap if you have tried every reasonable
alternative tool and all of them have failed."""


def _render_scope_block(scope: MCPScope) -> str:
    """
    Scope-aware preamble. Describes namespace constraints in terms of tool
    *shapes* (does the schema accept ``namespace``?) — never tool names.
    """
    if scope.kind == "namespace" and scope.namespaces:
        ns = scope.namespaces[0]
        return (
            f"## Your Scope\n"
            f"You operate inside a single Kubernetes namespace: **`{ns}`**.\n"
            f"The MCP server backing your tools is bound by RBAC to this namespace only.\n"
            f"You MUST stay within this scope:\n"
            f"- Always pass `namespace=\"{ns}\"` to any tool whose inputSchema declares a `namespace` argument.\n"
            f"- Prefer tools whose schema declares a `namespace` parameter.\n"
            f"- Do NOT call cluster-scoped tools — any tool whose schema does NOT accept `namespace`,\n"
            f"  including cluster-resource listers and node-level resource probes. They will fail\n"
            f"  with RBAC `forbidden`.\n"
            f"- For timeseries queries, pin `{{namespace=\"{ns}\"}}` selectors."
        )
    if scope.kind == "namespaces" and scope.namespaces:
        ns_list = ", ".join(f"`{n}`" for n in scope.namespaces)
        ns_re = "|".join(scope.namespaces)
        return (
            f"## Your Scope\n"
            f"You may operate across these Kubernetes namespaces: {ns_list}.\n"
            f"The MCP server's RBAC allows access to each of these — but NO others.\n"
            f"You MUST:\n"
            f"- Pass an explicit `namespace=...` argument on every tool call (one of the namespaces above).\n"
            f"- Prefer tools whose schema declares a `namespace` parameter; do NOT call any tool whose\n"
            f"  schema does NOT accept `namespace` (cluster-scoped reads will fail with `forbidden`).\n"
            f"- For timeseries queries, pin `{{namespace=~\"{ns_re}\"}}` selectors."
        )
    if scope.kind == "cluster":
        return (
            "## Your Scope\n"
            "The MCP server has cluster-wide RBAC. You may use cluster-scoped tools and\n"
            "namespace-scoped tools alike.\n"
            "Still, prefer narrow queries when investigating a specific component to keep results actionable."
        )
    return (
        "## Your Scope\n"
        "Target scope could not be auto-discovered from the MCP server.\n"
        "Prefer tools whose schema declares a `namespace` parameter.\n"
        "Avoid cluster-scoped calls unless you have evidence the MCP service account is authorized cluster-wide."
    )


def _render_resource_metrics_block(scope: MCPScope) -> str:
    """
    Describe *what* to gather and the fallback chain, never *which tool* to call.
    The LLM picks tools at runtime from `tools=[...]` based on description and
    inputSchema. The PromQL snippets are backend data (cAdvisor / kube-state-metrics
    series names) — not tool names — and stay valid across any Prometheus-compatible
    timeseries backend the agent might be wired to.
    """
    ns = scope.namespaces[0] if scope.namespaces else None
    ns_selector = f'namespace="{ns}",' if ns else "namespace=\"<your-namespace>\","
    ns_only = f'namespace="{ns}"' if ns else "namespace=\"<your-namespace>\""
    ns_arg = f'`namespace="{ns}"`' if ns else "an explicit `namespace=`"
    return (
        "## Resource Metrics\n"
        f"Primary path — find a tool that returns a per-pod resource snapshot\n"
        f"(CPU / memory) and accepts {ns_arg}. Call it, and if it returns rows, use them.\n\n"
        f"Fallback path — if the primary tool is unavailable, returns `not available`,\n"
        f"or no such tool exists, find a tool that accepts a query string and ask a\n"
        f"Prometheus-compatible timeseries backend. Pin every query to your namespace:\n"
        f"  - CPU per pod:    sum by (pod) (rate(container_cpu_usage_seconds_total{{{ns_selector}container!=\"\",container!=\"POD\"}}[2m]))\n"
        f"  - Memory per pod: sum by (pod) (container_memory_working_set_bytes{{{ns_selector}container!=\"\",container!=\"POD\"}})\n"
        f"  - Net RX drops:   sum by (pod) (rate(container_network_receive_packets_dropped_total{{{ns_only}}}[2m]))\n"
        f"  - Net TX drops:   sum by (pod) (rate(container_network_transmit_packets_dropped_total{{{ns_only}}}[2m]))\n"
        f"    Drop counters are not always emitted; if empty, retry with\n"
        f"    container_network_receive_errors_total / container_network_transmit_errors_total.\n"
        f"  - Pod state:      kube_pod_status_phase{{{ns_only}}} == 1\n"
        f"  - Restarts:       kube_pod_container_status_restarts_total{{{ns_only}}}\n\n"
        f"Only record `metrics_unavailable` if BOTH paths fail — no snapshot tool AND no\n"
        f"timeseries-query tool can answer, OR every query returns empty for ≥ 2 attempts."
    )


def _render_chaos_awareness_block(scope: MCPScope) -> str:
    """
    Describe chaos-detection signals the LLM should look for and the
    in-namespace tools shapes it needs (a pod-lister, an event-lister, a
    timeseries-query tool, a metric-introspection tool). The LLM resolves
    each shape from `tools=[...]`. If a shape isn't represented in the
    agent's tool inventory, the corresponding sub-step naturally degrades —
    the LLM will simply note "no such tool available" for that signal.
    """
    ns = scope.namespaces[0] if scope.namespaces else None
    if not ns:
        return ""
    return (
        "## Chaos Awareness (in-scope, data-driven detection)\n"
        f"You operate inside ONE namespace. You MUST NOT call any tool with a different\n"
        f"`namespace` argument. Before recommending remediation for any symptom, attempt\n"
        f"to determine whether the symptom is being driven by a deliberate disturbance\n"
        f"scheduled into your namespace. Use whatever tools are available to you:\n\n"
        f"1. Anomalous pod fleet — list pods in `{ns}` (use a tool whose schema accepts\n"
        f"   `namespace`). The agent has NO inter-scan memory of pod inventory, so checks\n"
        f"   must be evaluable from a single snapshot:\n"
        f"     • pods with ownerReferences whose `kind` is NOT one of\n"
        f"       Deployment, ReplicaSet, StatefulSet, DaemonSet, Job, CronJob — anything\n"
        f"       else (custom CRD kind) is suspicious\n"
        f"     • pods with NO ownerRef at all (raw pods are unusual in production namespaces)\n"
        f"     • pods whose containers terminate-and-restart in a tight loop\n"
        f"   Capture the pod name, the unfamiliar owner kind, and any annotation/label\n"
        f"   keys (NOT values — keys are enough to identify the framework at runtime).\n\n"
        f"2. In-namespace events — list events in `{ns}` (use a tool whose schema accepts\n"
        f"   `namespace`) and look for reasons containing `Inject`, `Kill`, `Chaos`, `Disrupt`,\n"
        f"   `Fault`, or events referencing pods that no longer exist. Capture reasons verbatim.\n\n"
        f"3. Metric-backed disturbance probe — only if you have a tool that lists / introspects\n"
        f"   the metrics catalogue AND a tool that runs a query string against it:\n"
        f"   a. Discover available metrics whose name matches `(?i)(chaos|fault|inject|disrupt)`.\n"
        f"      If none, this step is empty.\n"
        f"   b. For each candidate series, read its label set. Pick the label whose name contains\n"
        f"      \"namespace\" or \"ns\" — that is the namespace-scoping label. DO NOT assume a\n"
        f"      fixed label name.\n"
        f"   c. Query `<series>{{<discovered-label>=\"{ns}\"}}` grouped by every other label.\n"
        f"      A non-empty result means a disturbance is currently targeting your namespace.\n\n"
        f"If ANY step surfaces evidence, classify the symptom as\n"
        f"`category=\"external-disturbance\"` (or `\"chaos-injected\"` if a metric-backed step\n"
        f"surfaced matching series — the metric/label values are auditable evidence). Copy the\n"
        f"discovered marker into `summary`. Set `recommended_action` to monitor for recovery\n"
        f"rather than mutate the workload. Do NOT delete or scale the suspicious pods themselves.\n\n"
        f"If NO step surfaced evidence, treat the symptom as a real fault."
    )


def _render_dependency_log_block(scope: MCPScope) -> str:
    """
    Drill-down doctrine. Describes what to fetch and how to follow service edges
    inside the agent's namespace, in terms of tool *shapes* (a log-fetcher, a
    pod-detail fetcher, a service-detail fetcher, a pod-lister) — the LLM picks
    each from `tools=[...]`.
    """
    ns = scope.namespaces[0] if scope.namespaces else None
    if not ns:
        return ""
    return (
        "## Dependency Log Drill-Down\n"
        f"After identifying a problem pod, drill down using whatever tools are available:\n"
        f"  - fetch the pod's logs (use a tool that takes a pod `name` plus `namespace`;\n"
        f"    request ~300 lines of tail if a `tail` parameter is supported)\n"
        f"  - fetch the pod's full description (a tool that takes pod `name` + `namespace`).\n\n"
        f"If the pod's logs reference a connection-refused / no-reachable-servers / timeout\n"
        f"to a hostname `X`:\n"
        f"  - Match `X` against `<service>`, `<service>.{ns}`, or `<service>.{ns}.svc.cluster.local`.\n"
        f"    If matched, fetch the Service definition (use a tool that takes service `name`\n"
        f"    + `namespace`), read its `selector`, list pods in `{ns}` whose labels match the\n"
        f"    selector, then fetch logs for each. All calls stay pinned to `namespace=\"{ns}\"`.\n"
        f"  - If `X` does not match any of those patterns, treat it as out-of-namespace —\n"
        f"    do NOT attempt to resolve it, do NOT read pods elsewhere; record `X` as an\n"
        f"    external dependency in `summary` and move on."
    )


def _build_system_prompt(scope: MCPScope) -> str:
    """
    Build a scope-aware system prompt.

    The prompt describes intentions and tool *shapes* — never tool names.
    The LLM resolves shape → tool at runtime from the ``tools=[...]`` list it
    receives via the OpenAI function-calling API. This keeps the agent valid
    against any MCP server set, with any naming convention, with no client-side
    semantic mapping required.
    """
    blocks: List[str] = [
        _SYSTEM_PROMPT_HEAD,
        _render_scope_block(scope),
        _FALLBACK_DOCTRINE,
        _render_resource_metrics_block(scope),
        _render_chaos_awareness_block(scope),
        _render_dependency_log_block(scope),
        _SYSTEM_PROMPT_OUTPUT_FORMAT,
    ]
    return "\n\n".join(b for b in blocks if b)

BASELINE_PROMPT = """You are setting up continuous health monitoring for a Kubernetes namespace.

## Available MCP Tools
{tool_list}

## Task
Select the minimal set of tools to poll repeatedly for monitoring namespace "{namespace}".
These tools will run every few seconds WITHOUT an LLM - only when metrics change will analysis trigger.

## Selection Guidelines
- Prefer tools whose schema declares a `namespace` parameter over cluster-wide variants.
- Include pod status monitoring (required)
- Include events if available (recommended for detecting issues)
- Do NOT include tools requiring specific pod names (unknown at setup time)
- Do NOT include log tools (too noisy for polling)

## Response Format
Return ONLY valid JSON:
{{
  "watch_tools": [
    {{"name": "tool_name", "args": {{"namespace": "{namespace}"}}}}
  ],
  "healthy_thresholds": {{
    "min_pods": 1,
    "max_restart_delta": 0,
    "max_pending_pods": 0,
    "max_failed_pods": 0
  }}
}}
"""


@dataclass
class WatchBaseline:
    """Baseline configuration for watch mode."""
    namespace: str
    watch_tools: List[Dict[str, Any]]
    healthy_thresholds: Dict[str, int]
    baseline_metrics: Dict[str, Any] = field(default_factory=dict)
    established_at: str = ""


def _create_openai_client(cfg: AgentConfig) -> OpenAI:
    """Create an OpenAI-compatible client (supports Azure or standard endpoints)."""
    if cfg.openai_base_url and ".openai.azure.com" in cfg.openai_base_url:
        return AzureOpenAI(
            api_key=cfg.openai_api_key,
            azure_endpoint=cfg.openai_base_url,
            api_version=cfg.azure_api_version,
            timeout=cfg.llm_request_timeout,
            max_retries=cfg.llm_max_retries,
        )
    return OpenAI(
        api_key=cfg.openai_api_key or "not-needed",
        base_url=cfg.openai_base_url,
        timeout=cfg.llm_request_timeout,
        max_retries=cfg.llm_max_retries,
    )


def _convert_mcp_tool_to_openai(tool_def: Dict[str, Any]) -> Dict[str, Any]:
    """
    Convert an MCP tool definition to OpenAI function-calling format.

    MCP format:
        {"name": <tool>, "description": "...", "inputSchema": {...}}

    OpenAI format:
        {"type": "function", "function": {"name": "...", "description": "...", "parameters": {...}}}
    """
    input_schema = tool_def.get("inputSchema", {})
    
    # Clean up the schema for OpenAI compatibility
    parameters = {
        "type": input_schema.get("type", "object"),
        "properties": input_schema.get("properties", {}),
    }
    
    # Only include required if it has items
    required = input_schema.get("required", [])
    if required:
        parameters["required"] = required
    
    return {
        "type": "function",
        "function": {
            "name": tool_def.get("name", ""),
            "description": tool_def.get("description", "No description"),
            "parameters": parameters,
        }
    }


def _format_tool_result(tool_name: str, result: Dict[str, Any]) -> str:
    """Format a tool result for inclusion in conversation."""
    if isinstance(result, dict) and result.get("error"):
        return f"Error: {result['error']}"
    
    # Extract text content from MCP response
    if isinstance(result, dict) and "content" in result:
        content = result["content"]
        if isinstance(content, list):
            texts = [c.get("text", "") for c in content if c.get("type") == "text"]
            result_text = "\n".join(texts)
        else:
            result_text = str(content)
    else:
        result_text = json.dumps(result, indent=2, default=str)
    
    # Truncate very long results
    if len(result_text) > 8000:
        result_text = result_text[:8000] + "\n... (truncated)"
    
    return result_text


class FlashAgent:
    """
    Flash Agent – ITOps analysis agent with hindsight reflection.

    Uses FLASH-style hindsight integration for improved reliability
    on multi-step tasks. Dynamically discovers tools from configured
    MCP servers and applies LLM analysis with optional hindsight.
    """

    # Maximum history entries to retain across scans
    MAX_HISTORY_SIZE = 20

    def __init__(self, cfg: AgentConfig) -> None:
        self.cfg = cfg
        self._scan_counter = 0
        
        # FLASH hindsight components
        self.history: List[Dict[str, Any]] = []
        self.hindsight_builder = HindsightBuilder(cfg)
        self._last_hindsight: str | None = None

    def scan(self, query: str) -> Dict[str, Any]:
        """Execute one full analysis scan cycle."""
        self._scan_counter += 1
        scan_start = time.time()
        scan_id = (
            f"{self.cfg.agent_name}"
            f"-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S')}"
        )
        logger.info(
            "\u2550\u2550\u2550 Scan #%d started | scan_id=%s \u2550\u2550\u2550",
            self._scan_counter,
            scan_id,
        )

        analysis = self._execute_scan_steps(
            scan_query=query,
            scan_id=scan_id,
            scan_start=scan_start,
        )
        return analysis

    def health_check(self) -> bool:
        """Return True if the agent is ready to accept scan requests."""
        return bool(self.cfg.agent_name and self.cfg.mcp_urls)

    def get_capabilities(self) -> List[str]:
        """Return list of MCP server URLs this agent is configured to use."""
        return list(self.cfg.mcp_urls)

    def _execute_scan_steps(
        self,
        scan_query: str,
        scan_id: str,
        scan_start: float,
    ) -> Dict[str, Any]:
        """
        Execute FLASH reasoning loop with agentic tool calling.

        ReAct Loop:
          1. Discover tools from MCP servers
          2. Give LLM the task + available tools
          3. LLM decides which tools to call
          4. Execute tool calls, return results to LLM
          5. Repeat until LLM produces final analysis
          6. Generate hindsight if needed
        """
        # ── Record query in history ──────────────────────────────────────────
        self._add_to_history("user", f"Query: {scan_query}", {"scan_id": scan_id})

        # ── Step 1: Discover MCP tools + scope ───────────────────────────────
        mcp_tools, mcp_clients, mcp_scopes = self._discover_mcp_tools()

        if not mcp_tools:
            logger.error("No MCP tools discovered – cannot proceed")
            return {"health": {"overall_health_score": -1}, "issues": []}

        # Direct tool→client routing: each tool carries the URL of the server
        # that advertised it. Build a lookup so _execute_mcp_tool can route
        # without iterating all clients (which breaks when a server returns
        # HTTP 200 with a JSON-RPC error for unknown tools).
        tool_owner = {
            t["name"]: mcp_clients[t["_mcp_url"]]
            for t in mcp_tools
            if t.get("_mcp_url") in mcp_clients
        }

        # Convert to OpenAI function format
        openai_tools = [_convert_mcp_tool_to_openai(t) for t in mcp_tools]
        tool_names = [t["function"]["name"] for t in openai_tools]
        logger.info("Discovered %d tools: %s", len(openai_tools), tool_names)

        # Merge per-MCP scopes into the single scope shown to the LLM.
        merged_scope = self._merge_scopes(list(mcp_scopes.values()))
        logger.info("Discovered scope: %s", merged_scope.describe())

        # ── Step 2: Initialize LLM conversation ──────────────────────────────
        client = _create_openai_client(self.cfg)
        system_prompt = _build_system_prompt(merged_scope)

        # Build initial prompt with optional hindsight
        hindsight = self._get_hindsight_for_prompt(scan_id)
        if merged_scope.kind == "namespace" and merged_scope.namespaces:
            user_prompt = (
                f"Analyze the health of namespace `{merged_scope.namespaces[0]}` "
                f"using only namespace-scoped tools. Task: {scan_query}"
            )
        elif merged_scope.kind == "namespaces" and merged_scope.namespaces:
            ns_csv = ", ".join(merged_scope.namespaces)
            user_prompt = (
                f"Analyze the health of namespaces [{ns_csv}] "
                f"using namespace-scoped tools (always pass an explicit `namespace=`). "
                f"Task: {scan_query}"
            )
        elif merged_scope.kind == "cluster":
            user_prompt = f"Analyze the Kubernetes cluster health. Task: {scan_query}"
        else:
            user_prompt = f"Analyze the Kubernetes namespace health. Task: {scan_query}"
        if hindsight:
            user_prompt = f"{user_prompt}\n\nHINDSIGHT FROM PREVIOUS ANALYSIS:\n{hindsight}"
            logger.info("Injected hindsight into prompt (%d chars)", len(hindsight))

        messages: List[Dict[str, Any]] = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ]
        
        # ── Step 3: ReAct loop - LLM decides tools, we execute ───────────────
        analysis = None
        iteration = 0
        tool_calls_made: List[str] = []
        
        while iteration < MAX_TOOL_ITERATIONS:
            iteration += 1
            logger.info("ReAct iteration %d/%d", iteration, MAX_TOOL_ITERATIONS)
            
            try:
                response = client.chat.completions.create(
                    model=self.cfg.model_alias,
                    messages=messages,
                    tools=openai_tools,
                    tool_choice="auto",
                    temperature=0.1,
                )
            except Exception as exc:
                logger.error("LLM call failed: %s", exc)
                break
            
            assistant_message = response.choices[0].message
            
            # Check if LLM wants to call tools
            if assistant_message.tool_calls:
                # Add assistant message with tool calls to conversation
                messages.append({
                    "role": "assistant",
                    "content": assistant_message.content,
                    "tool_calls": [
                        {
                            "id": tc.id,
                            "type": "function",
                            "function": {
                                "name": tc.function.name,
                                "arguments": tc.function.arguments,
                            }
                        }
                        for tc in assistant_message.tool_calls
                    ]
                })
                
                # Execute each tool call
                for tool_call in assistant_message.tool_calls:
                    tool_name = tool_call.function.name
                    try:
                        tool_args = json.loads(tool_call.function.arguments)
                    except json.JSONDecodeError:
                        tool_args = {}
                    
                    logger.info("  Tool call: %s(%s)", tool_name, tool_args)
                    tool_calls_made.append(tool_name)
                    
                    # Execute via MCP
                    result = self._execute_mcp_tool(mcp_clients, tool_name, tool_args, tool_owner=tool_owner)
                    result_text = _format_tool_result(tool_name, result)
                    
                    logger.info("  Tool result: %d chars", len(result_text))
                    
                    # Add tool result to conversation
                    messages.append({
                        "role": "tool",
                        "tool_call_id": tool_call.id,
                        "content": result_text,
                    })
            else:
                # LLM produced final response - try to parse as JSON
                content = assistant_message.content or ""
                logger.info("LLM final response (%d chars)", len(content))
                
                try:
                    # Try to extract JSON from the response
                    analysis = self._parse_analysis_response(content)
                    break
                except Exception as exc:
                    logger.warning("Could not parse analysis: %s", exc)
                    # Ask LLM to format as JSON
                    messages.append({"role": "assistant", "content": content})
                    messages.append({
                        "role": "user", 
                        "content": "Please provide your analysis as a valid JSON object matching the required schema."
                    })
        
        if analysis is None:
            logger.error("ReAct loop ended without valid analysis")
            return {"health": {"overall_health_score": -1}, "issues": []}

        # ── Step 4: Log results ──────────────────────────────────────────────
        duration = time.time() - scan_start
        health = analysis.get("health", {})
        issues = analysis.get("issues", [])
        
        logger.info(
            "\u2550\u2550\u2550 Scan complete | scan_id=%s | %.1fs | tools_called=%d | "
            "health=%s | issues=%d \u2550\u2550\u2550",
            scan_id,
            duration,
            len(tool_calls_made),
            health.get("overall_health_score", "?"),
            len(issues),
        )
        for issue in issues:
            logger.info(
                "  [%s] %s — %s",
                issue.get("severity", "?").upper(),
                issue.get("component", "?"),
                issue.get("summary", ""),
            )

        # ── Record in history ────────────────────────────────────────────────
        analysis_summary = format_analysis_for_history(analysis)
        self._add_to_history("assistant", analysis_summary, {
            "scan_id": scan_id,
            "tools_called": tool_calls_made,
        })

        # ── Add metadata ─────────────────────────────────────────────────────
        analysis["_metadata"] = {
            "scan_id": scan_id,
            "duration_sec": round(duration, 2),
            "tool_calls": tool_calls_made,
            "iterations": iteration,
        }
        
        if hindsight:
            analysis["hindsight_reflection"] = {
                "generated": True,
                "content": hindsight,
            }
            self._last_hindsight = hindsight
        else:
            analysis["hindsight_reflection"] = {"generated": False}

        return analysis

    def _merge_scopes(self, scopes: List[MCPScope]) -> MCPScope:
        """
        Merge per-MCP scopes into the single scope shown to the LLM.

        Rules:
          - Drop ``agnostic`` scopes (e.g. Prometheus) — they don't constrain.
          - If everything left is ``unknown``, return ``unknown`` honestly.
          - If any concrete namespace scope exists, the union of namespaces
            wins (least-privilege wins over any cluster-wide peer).
          - Otherwise, ``cluster``.
        """
        if not scopes:
            return MCPScope(kind="unknown", source="fallback")

        non_agnostic = [s for s in scopes if s.kind != "agnostic"]
        if not non_agnostic:
            return MCPScope(kind="unknown", source="fallback (all-agnostic)")

        known = [s for s in non_agnostic if s.kind != "unknown"]
        if not known:
            return MCPScope(kind="unknown", source="fallback (all-unknown)")

        ns_scopes = [s for s in known if s.kind in ("namespace", "namespaces")]
        if ns_scopes:
            collected: List[str] = []
            for s in ns_scopes:
                collected.extend(s.namespaces)
            distinct = list(dict.fromkeys(collected))  # order-preserving dedupe
            kind: str = "namespace" if len(distinct) == 1 else "namespaces"
            return MCPScope(kind=kind, namespaces=distinct, source="merged")

        # Only cluster-scoped MCPs known
        return MCPScope(kind="cluster", source="merged")

    def _discover_mcp_tools(
        self,
    ) -> Tuple[List[Dict[str, Any]], Dict[str, MCPClient], Dict[str, MCPScope]]:
        """
        Discover tools and scope from each configured MCP server.

        Scope discovery uses the MCP server itself as the authority (via its
        introspection / probe tools), never the URL or any deployment-shape
        signal. ``cfg.scope_override`` short-circuits discovery when set.

        Returns:
            ``(all_tool_definitions, {url: client}, {url: scope})``.
        """
        all_tools: List[Dict[str, Any]] = []
        clients: Dict[str, MCPClient] = {}
        scopes: Dict[str, MCPScope] = {}
        override = self.cfg.scope_override or None

        for mcp_url in self.cfg.mcp_urls:
            logger.info("Discovering tools from %s", mcp_url)
            try:
                client = MCPClient(mcp_url, self.cfg.agent_name, self.cfg.mcp_timeout)
                session_id = client.initialize()
                logger.info("MCP session: %s", session_id)

                tools = client.list_tools()
                for tool in tools:
                    tool["_mcp_url"] = mcp_url  # Track which server has this tool
                all_tools.extend(tools)
                clients[mcp_url] = client

                # Discover this MCP's authorization scope from the server itself.
                try:
                    scope = client.discover_scope(tools, override=override)
                except Exception as exc:
                    logger.warning("Scope discovery failed for %s: %s", mcp_url, exc)
                    scope = MCPScope(kind="unknown", source="fallback (error)")
                scopes[mcp_url] = scope
                logger.info("MCP %s → %s", mcp_url, scope.describe())

                logger.info("Found %d tools from %s", len(tools), mcp_url)
            except Exception as exc:
                logger.error("Failed to discover tools from %s: %s", mcp_url, exc)

        return all_tools, clients, scopes

    def _execute_mcp_tool(
        self,
        clients: Dict[str, MCPClient],
        tool_name: str,
        arguments: Dict[str, Any],
        tool_owner: Optional[Dict[str, MCPClient]] = None,
    ) -> Dict[str, Any]:
        """
        Execute a tool call via the appropriate MCP client.

        ``tool_owner`` maps tool name → the client that advertised it (built from
        the ``_mcp_url`` metadata stamped onto each tool by ``_discover_mcp_tools``).
        When present, the owning client is tried directly instead of iterating all
        clients — necessary when multiple MCP servers are configured and a server
        returns HTTP 200 with a JSON-RPC error for unknown tools (which does not
        raise an exception and would otherwise short-circuit the fallback loop).
        """
        if tool_owner:
            client = tool_owner.get(tool_name)
            if client is not None:
                try:
                    return client.call_tool(tool_name, arguments)
                except Exception as exc:
                    logger.debug("Tool %s call failed: %s", tool_name, exc)
                    return {"error": f"Tool '{tool_name}' call failed: {exc}"}

        # Fallback for single-MCP setups or when tool_owner is unavailable.
        for mcp_url, client in clients.items():
            try:
                result = client.call_tool(tool_name, arguments)
                return result
            except Exception as exc:
                logger.debug("Tool %s failed on %s: %s", tool_name, mcp_url, exc)
                continue

        return {"error": f"Tool '{tool_name}' not found or failed on all MCP servers"}

    def _parse_analysis_response(self, content: str) -> Dict[str, Any]:
        """
        Parse LLM response into analysis dict.
        Handles JSON in markdown code blocks.
        """
        # Try direct JSON parse first
        content = content.strip()
        
        # Handle markdown code blocks
        if "```json" in content:
            start = content.find("```json") + 7
            end = content.find("```", start)
            if end > start:
                content = content[start:end].strip()
        elif "```" in content:
            start = content.find("```") + 3
            end = content.find("```", start)
            if end > start:
                content = content[start:end].strip()
        
        parsed = json.loads(content)
        if isinstance(parsed, list):
            # A small model will sometimes wrap the single expected object in a
            # list. json.loads() happily accepts that (it's valid JSON), so
            # this used to reach the caller as-is and crash later on
            # `analysis.get(...)` (AttributeError: 'list' object has no
            # attribute 'get') -- reproduced in ~15 real mass-execution runs.
            # Salvage the common one-element case; anything else is a genuine
            # shape mismatch, so raise and let the existing retry-as-JSON loop
            # ask the model to correct it instead of crashing the whole scan.
            if len(parsed) == 1 and isinstance(parsed[0], dict):
                return parsed[0]
            raise ValueError(f"expected a JSON object, got a list of {len(parsed)} item(s)")
        if not isinstance(parsed, dict):
            raise ValueError(f"expected a JSON object, got {type(parsed).__name__}")
        return parsed

    def _get_hindsight_for_prompt(self, scan_id: str) -> Optional[str]:
        """
        Check if hindsight should be included in the prompt.
        """
        if len(self.history) < 2:
            return None
        
        # Check for warning patterns
        if not self._detect_warning_patterns():
            return None
        
        logger.info("Generating hindsight for scan %s", scan_id)
        
        failure_context = {
            "scan_number": self._scan_counter,
            "history_length": len(self.history),
        }
        
        trimmed_history = trim_history_to_token_limit(self.history, max_tokens=50000)
        
        hindsight = self.hindsight_builder.develop_hindsight(
            current_input="Starting new scan",
            history=trimmed_history,
            failure_context=failure_context,
            scan_id=scan_id,
        )
        
        return hindsight

    def _add_to_history(
        self,
        role: str,
        content: str,
        metadata: Dict[str, Any] | None = None,
    ) -> None:
        """
        Add an entry to the execution history.
        
        Maintains a bounded history buffer for hindsight generation.
        """
        entry = create_history_entry(role, content, metadata)
        self.history.append(entry)
        
        # Trim to max size
        if len(self.history) > self.MAX_HISTORY_SIZE:
            self.history = self.history[-self.MAX_HISTORY_SIZE:]

    def _detect_warning_patterns(self) -> bool:
        """
        Detect warning patterns in recent history that warrant hindsight.
        
        Returns:
            True if warning patterns are detected
        """
        if len(self.history) < 2:
            return False
        
        # Check last few entries for error/warning keywords
        warning_keywords = ["error", "failed", "warning", "critical", "timeout"]
        recent = self.history[-3:]
        
        warning_count = 0
        for entry in recent:
            content = str(entry.get("content", "")).lower()
            if any(kw in content for kw in warning_keywords):
                warning_count += 1
        
        # Trigger if 2+ recent entries have warnings
        return warning_count >= 2

    def get_history_summary(self) -> Dict[str, Any]:
        """
        Get a summary of the current history state.
        
        Useful for debugging and observability.
        """
        return {
            "total_entries": len(self.history),
            "last_hindsight": self._last_hindsight[:200] if self._last_hindsight else None,
            "scan_count": self._scan_counter,
        }

    def establish_baseline(self, namespace: str) -> WatchBaseline:
        """
        Ask LLM to select watch tools and establish baseline metrics.
        
        Args:
            namespace: The Kubernetes namespace to monitor
            
        Returns:
            WatchBaseline with selected tools and initial metrics
        """
        logger.info("Establishing watch baseline for namespace: %s", namespace)

        # Discover available MCP tools (scope info ignored — namespace is given
        # explicitly by the caller in watch mode).
        mcp_tools, mcp_clients, _ = self._discover_mcp_tools()
        if not mcp_tools:
            raise RuntimeError("No MCP tools discovered - cannot establish baseline")
        
        # Format tool list for prompt
        tool_descriptions = []
        for tool in mcp_tools:
            name = tool.get("name", "")
            desc = tool.get("description", "No description")
            schema = tool.get("inputSchema", {})
            props = schema.get("properties", {})
            required = schema.get("required", [])
            
            args_desc = ""
            if props:
                args_list = [f"{k}{'*' if k in required else ''}" for k in props.keys()]
                args_desc = f" (args: {', '.join(args_list)})"
            
            tool_descriptions.append(f"- {name}: {desc}{args_desc}")
        
        tool_list = "\n".join(tool_descriptions)
        
        # Ask LLM to select watch tools
        client = _create_openai_client(self.cfg)
        prompt = BASELINE_PROMPT.format(tool_list=tool_list, namespace=namespace)
        
        try:
            response = client.chat.completions.create(
                model=self.cfg.model_alias,
                messages=[
                    {"role": "system", "content": "You are a Kubernetes monitoring configuration assistant."},
                    {"role": "user", "content": prompt},
                ],
                temperature=0.1,
            )
            content = response.choices[0].message.content or ""
            baseline_config = self._parse_analysis_response(content)
        except Exception as exc:
            logger.error("Failed to get baseline from LLM: %s", exc)
            # Honest degraded fallback: no watch tools, watch loop polls but
            # never deviates. Caller can re-run establish_baseline once the LLM
            # is reachable. We deliberately do NOT guess a tool name here —
            # tool selection is the LLM's job.
            baseline_config = {
                "watch_tools": [],
                "healthy_thresholds": {
                    "min_pods": 1,
                    "max_restart_delta": 0,
                    "max_pending_pods": 0,
                    "max_failed_pods": 0,
                },
            }
        
        baseline = WatchBaseline(
            namespace=namespace,
            watch_tools=baseline_config.get("watch_tools", []),
            healthy_thresholds=baseline_config.get("healthy_thresholds", {}),
            established_at=datetime.now(timezone.utc).isoformat(),
        )
        
        logger.info("Baseline tools selected: %s", [t["name"] for t in baseline.watch_tools])
        
        # Run initial tool calls to establish baseline metrics
        baseline.baseline_metrics = self._collect_watch_metrics(mcp_clients, baseline.watch_tools)
        logger.info("Baseline metrics: %s", baseline.baseline_metrics)
        
        return baseline

    def watch(
        self,
        baseline: WatchBaseline,
        poll_interval: float = 5.0,
        on_change: Optional[Callable[[Dict[str, Any], Dict[str, Any]], None]] = None,
        shutdown_check: Optional[Callable[[], bool]] = None,
    ) -> None:
        """
        Continuous watch loop - polls tools and triggers analysis on change.
        
        Args:
            baseline: The established baseline from establish_baseline()
            poll_interval: Seconds between polls (default 5)
            on_change: Optional callback(old_metrics, new_metrics) on deviation
            shutdown_check: Optional callable returning True to stop watching
        """
        logger.info(
            "Starting watch loop | namespace=%s | interval=%.1fs | tools=%d",
            baseline.namespace, poll_interval, len(baseline.watch_tools),
        )
        
        mcp_tools, mcp_clients, _ = self._discover_mcp_tools()
        if not mcp_clients:
            logger.error("No MCP clients available for watch")
            return
        tool_owner = {
            t["name"]: mcp_clients[t["_mcp_url"]]
            for t in mcp_tools
            if t.get("_mcp_url") in mcp_clients
        }

        last_metrics = baseline.baseline_metrics.copy()
        poll_count = 0
        
        while True:
            if shutdown_check and shutdown_check():
                logger.info("Watch loop shutdown requested")
                break
            
            poll_count += 1
            poll_start = time.time()
            
            # Collect current metrics
            current_metrics = self._collect_watch_metrics(mcp_clients, baseline.watch_tools)
            
            # Check for deviation
            deviation = self._detect_deviation(
                baseline.baseline_metrics,
                last_metrics,
                current_metrics,
                baseline.healthy_thresholds,
            )
            
            poll_duration = time.time() - poll_start
            
            if deviation:
                logger.info(
                    "Watch poll #%d | %.2fs | DEVIATION: %s",
                    poll_count, poll_duration, deviation,
                )
                
                if on_change:
                    on_change(last_metrics, current_metrics)
                else:
                    # Default: run full LLM analysis
                    logger.info("Triggering full scan due to deviation")
                    self.scan(f"Analyze {baseline.namespace} - deviation detected: {deviation}")
                
                # Update baseline with new "normal" after analysis
                last_metrics = current_metrics
            else:
                logger.debug(
                    "Watch poll #%d | %.2fs | OK | pods=%s restarts=%s",
                    poll_count, poll_duration,
                    current_metrics.get("pod_count", "?"),
                    current_metrics.get("total_restarts", "?"),
                )
            
            # Sleep until next poll (interruptible)
            sleep_start = time.time()
            while time.time() - sleep_start < poll_interval:
                if shutdown_check and shutdown_check():
                    break
                time.sleep(0.5)

    def _collect_watch_metrics(
        self,
        clients: Dict[str, MCPClient],
        watch_tools: List[Dict[str, Any]],
    ) -> Dict[str, Any]:
        """
        Execute watch tools and extract metrics.
        
        Returns dict with standardized metrics:
            pod_count, running_pods, pending_pods, failed_pods,
            total_restarts, error_events, raw_hash
        """
        raw_outputs: List[str] = []
        metrics: Dict[str, Any] = {
            "pod_count": 0,
            "running_pods": 0,
            "pending_pods": 0,
            "failed_pods": 0,
            "total_restarts": 0,
            "error_events": 0,
            "pods": [],
        }
        
        for tool_spec in watch_tools:
            tool_name = tool_spec.get("name", "")
            tool_args = tool_spec.get("args", {})
            
            result = self._execute_mcp_tool(clients, tool_name, tool_args, tool_owner=tool_owner)
            result_text = _format_tool_result(tool_name, result)
            raw_outputs.append(result_text)
            
            # Extract metrics based on tool type
            if "pods" in tool_name.lower():
                self._extract_pod_metrics(result_text, metrics)
            elif "events" in tool_name.lower():
                self._extract_event_metrics(result_text, metrics)
        
        # Hash raw output for simple change detection
        raw_combined = "\n".join(raw_outputs)
        metrics["raw_hash"] = hashlib.md5(raw_combined.encode()).hexdigest()[:12]
        
        return metrics

    def _extract_pod_metrics(self, output: str, metrics: Dict[str, Any]) -> None:
        """Extract pod metrics from tool output."""
        lines = output.strip().split("\n")
        
        for line in lines:
            # Skip headers and empty lines
            if not line.strip() or line.startswith("NAMESPACE") or line.startswith("NAME"):
                continue
            
            parts = line.split()
            if len(parts) < 5:
                continue
            
            # Parse kubectl-style output: NAMESPACE KIND NAME READY STATUS RESTARTS AGE
            # or: NAMESPACE APIVERSION KIND NAME READY STATUS RESTARTS AGE
            try:
                # Find STATUS and RESTARTS columns
                status_idx = -1
                for i, part in enumerate(parts):
                    if part in ("Running", "Pending", "Failed", "CrashLoopBackOff", 
                               "Error", "Completed", "Terminating", "ContainerCreating"):
                        status_idx = i
                        break
                
                if status_idx > 0:
                    status = parts[status_idx]
                    # Restarts is usually after status
                    restarts_str = parts[status_idx + 1] if status_idx + 1 < len(parts) else "0"
                    restarts = int(restarts_str) if restarts_str.isdigit() else 0
                    
                    metrics["pod_count"] += 1
                    metrics["total_restarts"] += restarts
                    
                    if status == "Running":
                        metrics["running_pods"] += 1
                    elif status == "Pending" or status == "ContainerCreating":
                        metrics["pending_pods"] += 1
                    elif status in ("Failed", "Error", "CrashLoopBackOff"):
                        metrics["failed_pods"] += 1
                    
                    # Track pod names
                    pod_name = parts[3] if len(parts) > 3 else parts[0]
                    metrics["pods"].append({"name": pod_name, "status": status, "restarts": restarts})
            except (ValueError, IndexError):
                continue

    def _extract_event_metrics(self, output: str, metrics: Dict[str, Any]) -> None:
        """Extract event metrics from tool output."""
        error_patterns = ["error", "failed", "backoff", "unhealthy", "killing"]
        
        for line in output.lower().split("\n"):
            if any(pattern in line for pattern in error_patterns):
                metrics["error_events"] += 1

    def _detect_deviation(
        self,
        baseline: Dict[str, Any],
        previous: Dict[str, Any],
        current: Dict[str, Any],
        thresholds: Dict[str, int],
    ) -> Optional[str]:
        """
        Detect if current metrics deviate from healthy baseline.
        
        Returns deviation description or None if healthy.
        """
        deviations = []
        
        # Check pod count
        min_pods = thresholds.get("min_pods", 1)
        if current.get("pod_count", 0) < min_pods:
            deviations.append(f"pod_count={current['pod_count']} < min={min_pods}")
        
        # Check restart delta (compared to previous, not baseline)
        max_restart_delta = thresholds.get("max_restart_delta", 0)
        restart_delta = current.get("total_restarts", 0) - previous.get("total_restarts", 0)
        if restart_delta > max_restart_delta:
            deviations.append(f"restart_delta={restart_delta} > max={max_restart_delta}")
        
        # Check pending pods
        max_pending = thresholds.get("max_pending_pods", 0)
        if current.get("pending_pods", 0) > max_pending:
            deviations.append(f"pending_pods={current['pending_pods']} > max={max_pending}")
        
        # Check failed pods
        max_failed = thresholds.get("max_failed_pods", 0)
        if current.get("failed_pods", 0) > max_failed:
            deviations.append(f"failed_pods={current['failed_pods']} > max={max_failed}")
        
        # Check for new error events
        if current.get("error_events", 0) > previous.get("error_events", 0):
            deviations.append(f"new_error_events detected")
        
        return "; ".join(deviations) if deviations else None

