"""CrewAI crew for the comprehensive SRE fault-remediation agent.

Designed to handle every fault scenario in chaos-charts/faults/:
  itbench/   — 29 configuration-level K8s faults
  kubernetes/ — standard LitmusChaos stress/network experiments

Investigation order is structured so that each fault category is covered
by at least one explicit phase of the protocol.
"""
from __future__ import annotations

import json
import os
from typing import Any, Dict, List, Optional

import litellm
from crewai import Agent, Crew, LLM, Task

from .mcp_tools import get_all_tools, required_evidence_missing

# ---------------------------------------------------------------------------
# Output schema shared by ITBench evaluators
# ---------------------------------------------------------------------------
_OUTPUT_SCHEMA = """{
  "entities": [
    {
      "name": "namespace/Kind/name",
      "contributing_factor": true,
      "reasoning": "Explanation with evidence from tool outputs"
    }
  ],
  "propagation_chain": [
    {
      "from": "namespace/Kind/source",
      "to": "namespace/Kind/destination",
      "reasoning": "How the fault propagated from source to destination"
    }
  ]
}"""

# ---------------------------------------------------------------------------
# Comprehensive investigation + remediation task description
# ---------------------------------------------------------------------------
_TASK_TEMPLATE = """{goal}

## COMPREHENSIVE FAULT INVESTIGATION AND REMEDIATION PROTOCOL

You are an expert SRE. Work through ALL phases below IN ORDER.
Do NOT skip any phase. Apply remediation as soon as you identify a fault —
do not wait until the end. After each remediation, continue investigating.
Only output the final JSON after completing all phases.

---

### PHASE 1 — INITIAL TRIAGE
1. call list_namespaces → identify the affected application namespace
   (expected: {namespace}, but verify)
2. call list_nodes → check for SchedulingDisabled (spec.unschedulable=true) or NotReady nodes
   → REMEDIATE: If a node is cordoned, call patch_resource(api_version="v1", kind="Node",
     name=<node-name>, patch='{{"spec":{{"unschedulable":false}}}}')
3. call list_pods_in_namespace(namespace="{namespace}") → note every pod NOT in Running state:
   CrashLoopBackOff, ImagePullBackOff, Init:*, Pending, OOMKilled, Evicted, Unknown, Terminating
4. call list_k8s_events(namespace="{namespace}") → record all Warning events

---

### PHASE 2 — NETWORK POLICIES
5. call list_k8s_resources(api_version="networking.k8s.io/v1", kind="NetworkPolicy", namespace="{namespace}")
   → For EACH policy found: call get_k8s_resource to inspect its ingress rules
   → REMEDIATE: If ingress is empty ([]) or blocks expected ports (80, 8080, 443, etc.):
     call delete_k8s_resource(api_version="networking.k8s.io/v1", kind="NetworkPolicy",
       name=<policy-name>, namespace="{namespace}")

---

### PHASE 3 — SERVICES
6. call list_k8s_resources(api_version="v1", kind="Service", namespace="{namespace}")
   → For each Service: call get_k8s_resource and check:
     a. spec.selector — if it contains "invalid-workload": fix with patch_resource
        patch='{{"spec":{{"selector":{{"<label-key>":"<correct-value>"}}}}}}'
     b. spec.ports[0].targetPort — if it is 9999: fix with patch_resource to the correct port
   → REMEDIATE missing Service (from events showing "service not found"):
     Infer the correct spec from the matching Deployment's selector and container port,
     then call apply_resource with a complete Service JSON spec.

---

### PHASE 4 — DEPLOYMENT WORKLOAD HEALTH
7. call list_k8s_resources(api_version="apps/v1", kind="Deployment", namespace="{namespace}")
   → Note any with 0 available replicas
8. For each Deployment with unhealthy pods (from Phase 1):
   call get_k8s_resource(api_version="apps/v1", kind="Deployment", name=<name>, namespace="{namespace}")
   Inspect ALL of these fields and REMEDIATE if ANY looks wrong:

   a. spec.replicas — if 0: call patch_resource with patch='{{"spec":{{"replicas":1}}}}'

   b. spec.template.spec.initContainers — if there is an EXTRA initContainer whose
      image is busybox, ubi10-minimal, or name contains "chaos" or "worker":
      call rollout_undo(name=<deployment-name>, namespace="{namespace}")

   c. spec.template.spec.containers[*].image — if "invalid", "nonexistent", "arm64v8",
      or any obviously wrong/test image:
      call rollout_undo(name=<deployment-name>, namespace="{namespace}")

   d. spec.template.spec.containers[*].command — if ["/nonexistent-binary"] or any
      obviously broken command:
      call rollout_undo(name=<deployment-name>, namespace="{namespace}")

   e. spec.template.spec.containers[*].readinessProbe — if httpGet.port is 40 or
      an obviously wrong port that the container does not listen on:
      call rollout_undo(name=<deployment-name>, namespace="{namespace}")

   f. spec.template.spec.containers[*].env — if any env var has a clearly wrong value
      (e.g. QUOTE_ADDR="quote:0000"):
      call rollout_undo(name=<deployment-name>, namespace="{namespace}")

   g. spec.template.spec.containers[*].resources.requests — if cpu="1m" and memory="8Mi"
      (unrealistically low):
      call rollout_undo(name=<deployment-name>, namespace="{namespace}")

   h. spec.template.spec.nodeSelector — if it contains "nonexistent-node-fault":
      call rollout_undo(name=<deployment-name>, namespace="{namespace}")

   i. spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution
      — if present with topologyKey=kubernetes.io/hostname for a single-node cluster:
      call rollout_undo(name=<deployment-name>, namespace="{namespace}")

   j. spec.template.spec.dnsPolicy — if "None" with dnsConfig.nameservers containing
      an unreachable address (not a real cluster DNS like 10.96.0.10):
      call rollout_undo(name=<deployment-name>, namespace="{namespace}")

   k. spec.template.spec.volumes — if there is a volume referencing a PVC that is in
      Pending/Bound-failed state (will check in Phase 6):
      call rollout_undo(name=<deployment-name>, namespace="{namespace}")

---

### PHASE 5 — ROGUE RESOURCES AND LOAD GENERATORS
9. call list_pods_in_namespace(namespace="{namespace}", label_selector="chaos-injector")
   → REMEDIATE: Delete each rogue injector pod found:
     call delete_k8s_resource(api_version="v1", kind="Pod", name=<pod-name>, namespace="{namespace}")

10. call list_k8s_resources(api_version="apps/v1", kind="Deployment", namespace="{namespace}")
    → If a Deployment named "workload-scanner" exists (API server request surge fault):
      call delete_k8s_resource(api_version="apps/v1", kind="Deployment",
        name="workload-scanner", namespace="{namespace}")
      Also delete its ServiceAccount, Role, and RoleBinding if present.

11. call list_k8s_resources(api_version="scheduling.k8s.io/v1", kind="PriorityClass")
    → If "chaos-priority-preemption" PriorityClass exists (priority preemption fault):
      a. call list_k8s_resources(api_version="apps/v1", kind="Deployment", namespace="{namespace}")
         → find "chaos-priority-preemption-decoy" and delete it
      b. call delete_k8s_resource(api_version="scheduling.k8s.io/v1",
           kind="PriorityClass", name="chaos-priority-preemption")

---

### PHASE 6 — RESOURCE GOVERNANCE
12. call list_k8s_resources(api_version="v1", kind="ResourceQuota", namespace="{namespace}")
    → call get_k8s_resource for each quota found
    → REMEDIATE: If hard limits are absurdly low (e.g. requests.cpu="10m",
      requests.memory="16Mi"): call delete_k8s_resource to remove the restrictive quota

13. call list_k8s_resources(api_version="autoscaling/v2", kind="HorizontalPodAutoscaler",
      namespace="{namespace}")
    → call get_k8s_resource for each HPA found
    → REMEDIATE: If spec.metrics contains averageUtilization values below 50 (e.g. cpu=20,
      memory=30) — unrealistically low causing constant scale-up:
      call patch_resource with corrected metrics (set averageUtilization to 80 for CPU, 80 for memory)

14. call list_k8s_resources(api_version="v1", kind="PersistentVolumeClaim",
      namespace="{namespace}")
    → REMEDIATE: If any PVC is Pending with invalid storageClassName ("invalid-class-name"):
      a. Identify which Deployment mounts it (from volumes in Phase 4k)
      b. call rollout_undo for that Deployment
      c. call delete_k8s_resource(api_version="v1", kind="PersistentVolumeClaim",
           name=<pvc-name>, namespace="{namespace}")

---

### PHASE 7 — CONFIGURATION RESOURCES
15. call get_k8s_resource(api_version="v1", kind="ConfigMap", name="flagd-config",
      namespace="{namespace}")
    → Parse the demo.flagd.json data value
    → REMEDIATE: If any feature flag has defaultVariant="on" (e.g. loadGeneratorFloodHomepage,
      adServiceFailure, productCatalogFailure, recommendationServiceCacheFailure):
      call patch_resource to update that flag to defaultVariant="off"
      patch='{{"data":{{"demo.flagd.json":"<corrected-json-string>"}}}}'

16. call get_k8s_resource(api_version="v1", kind="Secret", name="valkey-credentials",
      namespace="{namespace}")
    → Decode the valkey-password value from base64
    → REMEDIATE: If the password appears invalid (e.g. "invalid_password" base64-encoded):
      call rollout_undo(name="valkey-cart", namespace="{namespace}") to remove the
      --requirepass override injected into the container command

---

### PHASE 8 — STUCK PODS (node restart / stress faults)
17. call list_pods_in_namespace(namespace="{namespace}")
    → For pods in Unknown or Terminating state for > 30 s (visible via events timestamps):
      call delete_k8s_resource(api_version="v1", kind="Pod", name=<pod-name>,
        namespace="{namespace}") so the controller reschedules them

18. For pods affected by standard LitmusChaos experiments (pod-cpu-hog, pod-memory-hog,
    pod-network-loss, pod-network-corruption, pod-network-rate-limit, disk-fill,
    pod-dns-error, container-kill):
    → These faults self-revert after their duration, but pods may be stuck OOMKilled/Evicted
    → REMEDIATE: Delete the stuck pod; the parent Deployment/ReplicaSet recreates it:
      call delete_k8s_resource(api_version="v1", kind="Pod", name=<pod-name>,
        namespace="{namespace}")

---

### PHASE 9 — VERIFICATION
19. call list_pods_in_namespace(namespace="{namespace}") — verify all pods are Running/Ready
20. call execute_promql_query with a relevant error-rate query to confirm service recovery:
    rate(traces_span_metrics_calls_total{{status_code="STATUS_CODE_ERROR"}}[2m])
21. If any pods are still unhealthy after all remediations, get their logs via get_pod_logs
    and apply any additional remediation you can identify.

---

## OUTPUT FORMAT

After completing ALL phases, output ONLY a single valid JSON object with no markdown fences:
{schema}

Rules:
- Entity names MUST use "namespace/Kind/name" format (e.g. "otel-demo/NetworkPolicy/quote-policy")
- Every resource that directly CAUSED the incident has contributing_factor=true
- Resources that were IMPACTED but not causal have contributing_factor=false
- The propagation_chain shows how the fault spread through the system
- If no fault was found, return entities=[] and propagation_chain=[]
"""

# Some model aliases behind the shared LiteLLM proxy silently route to a
# different real model than their name implies — same environment/proxy as
# sre-agent-crewai (see agents/sre-agent-crewai/src/sre_crewai/crew.py),
# verified there for "gpt-4o" via the `x-ms-served-model` Azure response
# header (it's actually GPT-5.1, a reasoning-class model). Reasoning-class
# models reject the legacy `max_tokens`/`stop` Chat Completions params
# outright (400 Bad Request), and CrewAI's own capability auto-detection
# (LLM.supports_stop_words()) can't catch this — it pattern-matches the
# model *name* string via litellm's static registry, which has no
# visibility into what a given deployment was actually repointed to.
#
# CrewAgentExecutor also unconditionally sets `self.llm.stop = stop_words`
# on construction (crew_agent_executor.py ~L84-87) regardless of what
# supports_stop_words() returns, and base LLM.call() sends whatever's in
# `self.stop` on every request — so overriding supports_stop_words() alone
# does NOT stop `stop` from being sent; call() itself must be overridden
# too. Two strategies, selected via SRE_AGENT_STOP_STRATEGY:
#   "truncate" (default) — never send `stop`; let the model generate its
#     full response and cut it client-side at the first stop marker, same
#     effect as CrewAI's own dormant fallback path (the
#     `if not self.use_stop_words:` branch in crew_agent_executor.py) but
#     reachable without depending on supports_stop_words()'s wrong answer.
#     Bounded by SRE_AGENT_MAX_COMPLETION_TOKENS so a runaway/hallucinated
#     continuation has a hard ceiling rather than an unbounded worst case.
#   "stream" — abort the connection the instant the stop marker appears in
#     the streamed text, closer to what native `stop` would have actually
#     cost in billed tokens. More precise, more code, not yet
#     production-hardened — prototype only, ported from sre-agent-crewai
#     (see innovation.md §4.7 there).
_STOP_STRATEGY = os.environ.get("SRE_AGENT_STOP_STRATEGY", "truncate").strip().lower()
# Matches the original hardcoded `max_tokens=4096` this file used before we
# learned it has to be sent as `max_completion_tokens` instead (see
# _build_llm_params below) — same budget, correct wire key, adjustable
# per-deployment without a code change.
_MAX_COMPLETION_TOKENS = int(os.environ.get("SRE_AGENT_MAX_COMPLETION_TOKENS", "4096"))
# Off by default — token_counter() re-tokenizes every truncated completion,
# pure overhead unless someone's actually trying to quantify the workaround's
# cost right now. Opt in with SRE_AGENT_LOG_TOKEN_WASTE=1/true/yes.
_LOG_TOKEN_WASTE = os.environ.get("SRE_AGENT_LOG_TOKEN_WASTE", "").strip().lower() in ("1", "true", "yes")

# CrewAI's ReAct prompt format cuts each turn here (agent.py:
# `stop_words = [self.i18n.slice("observation")]`, same literal in this
# crewai version) — duplicated here since it's not derivable without a
# constructed Agent instance at the point _TruncatingLLM needs it.
_STOP_MARKER = "\nObservation:"


def _empty_final_answer(text: str) -> bool:
    compact = text.replace(" ", "").replace("\n", "")
    return "\"entities\":[]" in compact and "\"propagation_chain\":[]" in compact and "Action:" not in text


def _forced_evidence_action() -> str | None:
    namespace = os.environ.get("TARGET_NAMESPACE", "otel-demo")
    missing = required_evidence_missing()
    if not missing:
        return None
    tool_name = missing[0]
    if tool_name == "list_namespaces":
        action_input = "{}"
    elif tool_name == "list_pods_in_namespace":
        action_input = json.dumps({"namespace": namespace}, separators=(",", ":"))
    elif tool_name == "list_k8s_events":
        action_input = json.dumps({"namespace": namespace}, separators=(",", ":"))
    else:
        action_input = json.dumps(
            {"api_version": "apps/v1", "kind": "Deployment", "namespace": namespace},
            separators=(",", ":"),
        )
    return (
        "Thought: I must collect required Kubernetes evidence before I can provide a final answer.\n"
        f"Action: {tool_name}\n"
        f"Action Input: {action_input}"
    )


def _build_llm_params(llm: "LLM", messages: List[Dict[str, str]]) -> Dict[str, Any]:
    """Same param set as crewai.LLM.call(), except:
    - `stop` is always omitted — the marker is stripped client-side instead
      (either after the fact or mid-stream, depending on strategy).
    - the length cap is sent as `max_completion_tokens`, never the legacy
      `max_tokens` key: base LLM.call() builds
      `"max_tokens": self.max_tokens or self.max_completion_tokens` — i.e.
      it collapses max_completion_tokens onto the wire key "max_tokens"
      regardless of which attribute is actually set, which is exactly the
      param this model rejects. Sending it under its real name is the
      entire fix.
    """
    params = {
        "model": llm.model,
        "messages": messages,
        "timeout": llm.timeout,
        "temperature": llm.temperature,
        "top_p": llm.top_p,
        "n": llm.n,
        "max_completion_tokens": llm.max_completion_tokens or _MAX_COMPLETION_TOKENS,
        "presence_penalty": llm.presence_penalty,
        "frequency_penalty": llm.frequency_penalty,
        "logit_bias": llm.logit_bias,
        "response_format": llm.response_format,
        "seed": llm.seed,
        "logprobs": llm.logprobs,
        "top_logprobs": llm.top_logprobs,
        "api_base": llm.base_url,
        "api_version": llm.api_version,
        "api_key": llm.api_key,
        **llm.kwargs,
    }
    return {k: v for k, v in params.items() if v is not None}


def _log_waste(model: str, kept_text: str, completion_tokens: Optional[int]) -> None:
    """Best-effort measurement of how much of the billed completion was
    discarded by client-side truncation. Opt-in only — see
    _LOG_TOKEN_WASTE above."""
    if not _LOG_TOKEN_WASTE or not completion_tokens:
        return
    try:
        kept_tokens = litellm.token_counter(model=model, text=kept_text)
        wasted = max(completion_tokens - kept_tokens, 0)
        if wasted:
            # print(), not logging: matches __main__.py's [sre-comprehensive]
            # convention and guarantees visibility in `kubectl logs` without
            # depending on whatever logging config (if any) the host process
            # has set up.
            print(
                f"[sre-comprehensive] stop-word workaround: {wasted}/{completion_tokens} "
                f"completion tokens discarded after truncation "
                f"({100 * wasted / completion_tokens:.0f}% waste)"
            )
    except Exception:
        pass  # measurement is best-effort; never let it break a real call


class _TruncatingLLM(LLM):
    """Default ("truncate") strategy — see module-level comment above."""

    def supports_stop_words(self) -> bool:
        return False

    def call(self, messages: List[Dict[str, str]], callbacks: Optional[List[Any]] = None) -> str:
        if callbacks:
            self.set_callbacks(callbacks)
        params = _build_llm_params(self, messages)
        response = litellm.completion(**params)
        full_text = response["choices"][0]["message"]["content"]
        kept_text = full_text.split(_STOP_MARKER)[0].rstrip()
        forced_action = _forced_evidence_action() if _empty_final_answer(kept_text) else None
        if forced_action:
            print("[sre-comprehensive] rejected premature empty final answer; forcing evidence tool call", flush=True)
            kept_text = forced_action
        _log_waste(self.model, kept_text, response["usage"].get("completion_tokens"))
        return kept_text


class _StreamingTruncatingLLM(LLM):
    """"stream" strategy (opt-in, SRE_AGENT_STOP_STRATEGY=stream) — prototype,
    ported from sre-agent-crewai, see module-level comment above."""

    def supports_stop_words(self) -> bool:
        return False

    def call(self, messages: List[Dict[str, str]], callbacks: Optional[List[Any]] = None) -> str:
        if callbacks:
            self.set_callbacks(callbacks)
        params = _build_llm_params(self, messages)
        params["stream"] = True
        stream = litellm.completion(**params)
        chunks: List[str] = []
        try:
            for chunk in stream:
                delta = chunk.choices[0].delta.content
                if delta:
                    chunks.append(delta)
                    if _STOP_MARKER in "".join(chunks):
                        break
        finally:
            close = getattr(stream, "close", None)
            if callable(close):
                close()
        full_text = "".join(chunks)
        kept_text = full_text.split(_STOP_MARKER)[0].rstrip()
        forced_action = _forced_evidence_action() if _empty_final_answer(kept_text) else None
        if forced_action:
            print("[sre-comprehensive] rejected premature empty final answer; forcing evidence tool call", flush=True)
            return forced_action
        return kept_text


def _build_llm(model: str, base_url: str, api_key: str) -> LLM:
    llm_cls = _StreamingTruncatingLLM if _STOP_STRATEGY == "stream" else _TruncatingLLM
    return llm_cls(
        model=model,
        base_url=base_url,
        api_key=api_key,
        temperature=0.0,
    )


def build_crew(
    goal: str,
    workspace_dir: str,
    model: str,
    output_path: str,
    namespace: str = "otel-demo",
) -> Crew:
    import sys

    # Prints the directory path of the active Python environment
    print("Current Environment Path:", sys.prefix)
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
    prefixed_model = model if "/" in model else f"openai/{model}"

    llm = _build_llm(prefixed_model, base_url, api_key)

    investigator = Agent(
        role="SRE Comprehensive Fault Investigator and Remediator",
        goal=(
            "Investigate every possible Kubernetes fault category and remediate all "
            "detected issues using the available tools, then produce a structured JSON report."
        ),
        backstory=(
            "You are a senior Site Reliability Engineer with deep expertise in Kubernetes "
            "chaos engineering. You have handled every type of infrastructure fault: "
            "network policies, node scheduling, Deployment misconfigurations, Service issues, "
            "resource quotas, HPA misconfiguration, storage faults, secret corruption, "
            "feature flag regressions, and standard LitmusChaos experiments. "
            "You are methodical: you investigate every category systematically, "
            "apply targeted remediations immediately when you find a fault, "
            "and verify recovery before concluding."
        ),
        tools=get_all_tools(),
        llm=llm,
        verbose=True,
        max_iter=40,
        max_retry_limit=3,
    )

    task_desc = _TASK_TEMPLATE.format(
        goal=goal,
        namespace=namespace,
        schema=_OUTPUT_SCHEMA,
    )

    task = Task(
        description=task_desc,
        expected_output=(
            "A raw JSON object with 'entities' and 'propagation_chain' fields "
            "identifying every root-cause resource and how the fault propagated."
        ),
        agent=investigator,
        output_file=output_path,
    )

    return Crew(
        agents=[investigator],
        tasks=[task],
        verbose=True,
    )