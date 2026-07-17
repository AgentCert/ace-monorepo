"""CrewAI crew for the comprehensive SRE fault-remediation agent.

Designed to handle every fault scenario in chaos-charts/faults/:
  itbench/   — 29 configuration-level K8s faults
  kubernetes/ — standard LitmusChaos stress/network experiments

Investigation order is structured so that each fault category is covered
by at least one explicit phase of the protocol.
"""
from __future__ import annotations

import os

from crewai import Agent, Crew, LLM, Task

from .mcp_tools import get_all_tools

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


def build_crew(
    goal: str,
    workspace_dir: str,
    model: str,
    output_path: str,
    namespace: str = "otel-demo",
) -> Crew:
    base_url = os.environ.get("LITELLM_BASE_URL", "http://127.0.0.1:14000")
    api_key = os.environ.get("SRE_AGENT_LITELLM_API_KEY", "ollama")
    prefixed_model = model if "/" in model else f"openai/{model}"

    llm = LLM(
        model=prefixed_model,
        base_url=base_url,
        api_key=api_key,
        temperature=0.0,
        max_tokens=4096,
    )

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
