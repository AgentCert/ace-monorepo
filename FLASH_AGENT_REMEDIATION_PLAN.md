# Remediation-capable flash-agent

## Context

`agents/flash-agent/` (the FLASH-methodology ITOps agent — DISCOVER → REASON+ACT → ANALYZE →
REFLECT) is diagnosis-only today, but not by an explicit hard rule — it's diagnosis-only because
three independent layers all currently stop short of action:

1. **Prompt**: `_SYSTEM_PROMPT_HEAD` and the chaos-awareness block
   (`agents/flash-agent/flash_agent.py:57`, `:249`) tell the LLM to produce `recommended_action`
   *text* for "an operator or automation system" and explicitly say *"Do NOT delete or scale the
   suspicious pods themselves."*
2. **RBAC**: every deployed copy of the kubernetes-mcp-server's RBAC (4 identical copies across
   `app-charts/charts/{sock-shop,otel-demo,bookinfo}/templates/mcptools/kubernetes-mcp-server.yaml`
   and `AgentCert/chaoscenter/graphql/server/manifests/{namespace,cluster}/4a_mcp_tools_rbac.yaml`)
   grants only `get/list/watch` on core+apps resources — the only full-CRUD grant is on
   `litmuschaos.io` CRDs (chaos control, unrelated to app remediation).
3. **Output schema**: `issues[].recommended_action` is a string; there's no `actions_taken` field
   and nothing downstream that would score an executed action.

Crucially, none of this is a load-bearing safety mechanism to preserve — it's just unfinished
work. The upstream `kubernetes-mcp-server` image (`quay.io/containers/kubernetes_mcp_server`)
**already exposes** the mutating tools needed (`pods_delete`, `pod_exec`,
`deployments_update/delete`, generic `resources_delete`, etc.) — confirmed working end-to-end by
`agents/sre-agent-crewai`'s `DeleteResourceTool` (`src/sre_crewai/mcp_tools.py:157-182`), the one
existing agent in this repo that already remediates (hardcoded to a single fault). The
`agent-charts/charts/flash-agent/values.yaml:10` chart even has a pre-existing, never-wired
`role: "observer"  # Agent role: observer, remediation, etc.` slot anticipating exactly this.

Every `chaos-charts/faults/{kubernetes,itbench}/*/ground_truth.yaml` file's `remediation:` field
names a genuinely active fix (delete pod, scale up, exec-kill, rollback, patch resource limits) —
none of the 39 sampled faults are "just wait for Kubernetes to self-heal." So closing this gap is
mostly about: widening RBAC safely, updating the prompt to authorize the fix, giving the agent a
place to record what it did, and closing the loop so it can verify the fix worked.

**Scope** (confirmed with user): target the fault categories flash-agent already owns —
`application_fault`, `network_fault`, `resource_fault`, `database_storage_fault`,
`scheduling_fault`, `security_fault`. Explicitly **out of scope**: `ciso_fault` (owned end-to-end
by `ITBench-CISO-CAA-Agent`, a different mechanism — Kyverno/OPA policy checks, not K8s object
mutation, and CLAUDE.md says don't modify its upstream logic) and `sre_agent_fault` (35 ITBench
`Scenario-N` IDs routed to `sre-agent`/`sre-agent-crewai`).

## Architecture decision

**Extend the existing `agents/flash-agent/` codebase behind an `AGENT_ROLE` switch, and give it a
new benchmarking/certification identity — do not fork a parallel 1200-line copy of the ReAct
engine.** This satisfies "a new flash agent" from the standpoint that matters (it gets its own
`agent_id`, its own cert reports, its own N=30 statistics, independently toggleable and
comparable against the existing diagnosis-only `flash-agent-v1`) while reusing
`FlashAgent`/`MCPClient`/`HindsightBuilder` as-is. Concretely:

- Same Docker image (`agentcert/agentcert-flash-agent`), same `flash_agent.py`/`main.py`/`config.py`.
- New `AGENT_ROLE` env var (`observer` default / `remediation`) threaded into `AgentConfig`,
  finally wiring up the chart's already-existing `agent.role` value.
- A **second, separately-deployed, elevated-RBAC instance** of `kubernetes-mcp-server` per target
  app chart, bound to a namespace-scoped `Role` (not `ClusterRole`) with only the extra verbs
  remediation needs. The existing read-only instance is untouched — `flash-agent-v1` and any
  other consumer keep exactly their current RBAC and behavior (durable, non-regressing per
  CLAUDE.md §0.1).
- A new harness identity, `agents/harness/flash-agent-remediation/`, whose `MCP_URLS` points at
  the new elevated instance and whose env sets `AGENT_ROLE=remediation`.

This keeps blast radius bounded: only a newly-created namespaced Role in the target app namespaces
(`sock-shop`, later `otel-demo`/`bookinfo`) gains write verbs, nothing cluster-wide, nothing
outside those namespaces, and the existing certified diagnosis-only agent is byte-for-byte
unaffected.

## Code changes — `agents/flash-agent/`

### 1. `config.py` — new env vars on `AgentConfig`
- `agent_role: str` ← `AGENT_ROLE` (default `"observer"`), validated to `{"observer", "remediation"}`.
- `max_tool_iterations: int` ← `MAX_TOOL_ITERATIONS` (default `10`) — currently a hardcoded
  module constant in `flash_agent.py:48`; remediation needs more turns per scan (diagnose *and*
  act), so this must become configurable rather than bumping the shared default. Pass through to
  `FlashAgent` instead of referencing the module global.
- `max_remediation_actions: int` ← `MAX_REMEDIATION_ACTIONS` (default `3`) — hard cap on mutating
  tool calls per scan, independent of the iteration budget, so a confused agent can't hammer the
  cluster with deletes/patches even within a long ReAct loop.

### 2. `flash_agent.py` — prompt changes (only active when `agent_role == "remediation"`)
- `_SYSTEM_PROMPT_HEAD` (line 51): add a 5th numbered point authorizing execution — *"When you
  have identified a real (non-chaos-injected) fault and a safe corrective action, call the
  appropriate tool yourself to apply the fix, then report what you did in `actions_taken`."* Keep
  point 4 (recommended_action text) for cases where no safe tool exists.
- Chaos-awareness block (`_render_chaos_awareness_block`, lines 205-250): **keep** the existing
  "if evidence of active chaos injection, do NOT mutate — monitor for recovery instead" rule
  as-is; it's the one guardrail that must survive unchanged (don't fight a fault that's still
  being actively injected / is the experiment itself, vs. a confirmed real fault needing a fix).
  Add a new paragraph directly beneath it, only in the remediation prompt variant: *"If NO step
  surfaced evidence of active chaos injection, and the issue matches a known-safe corrective
  pattern (pod stuck in a bad state → delete it and let the controller recreate it; deployment
  under-scaled → scale/patch replica count back to the declared spec; PVC broken/missing →
  rollback deployment revision or remove the invalid volumeMount; runaway process in a container →
  exec a kill signal), call the tool. Otherwise, fall back to `recommended_action` text only."*
- `_SYSTEM_PROMPT_OUTPUT_FORMAT` (lines 60-108): add an `actions_taken` array to the JSON schema,
  e.g. `{tool, arguments, issue_ref, result: "success"|"failed", detail, timestamp}` — one entry
  per mutating tool call actually executed. Feeds both the hindsight loop (below) and certifier
  scoring.

### 3. Execution path — reuse, don't rebuild
- `_execute_mcp_tool()` (line 761) and `MCPClient.call_tool()` are already fully generic
  pass-throughs with no read/write distinction — **no change needed here**. The only new logic is
  a small guard in the ReAct loop (around line 600, where tool calls are dispatched): if
  `agent_role != "remediation"`, refuse to call any tool whose name matches a mutating-verb
  pattern (`delete|patch|update|exec|scale|rollback` — allowlist by *shape*, matching the existing
  `_FALLBACK_DOCTRINE` convention of picking tools by name/schema pattern, not by hardcoding
  literal MCP method names) and return a "not authorized for this agent role" tool-result instead
  of calling it. This is the actual code-level safety boundary for the observer identity, on top
  of RBAC.
- Enforce `max_remediation_actions` here too — once the cap is hit, further matching tool calls
  are refused with a reason the LLM can see, so it explains itself in `insights` rather than
  silently looping.

### 4. Verification loop — reuse `run_scan_mode`, don't build a new one
`main.py`'s `run_scan_mode()` (line 110) already loops up to `MAX_ITERATIONS`, rescanning every
`RESCAN_DELAY` seconds until `_has_unresolved_issues()` is false. Once mutation is possible, this
existing loop **becomes** the act → wait → re-observe → confirm-fixed cycle for free — no new
control flow needed, just confirm it behaves correctly once issues can actually be cleared by the
agent's own actions instead of only external recovery.

### 5. Hindsight — teach it about action outcomes
`_detect_warning_patterns()` (line 882) and `format_analysis_for_history()`
(`llm/utils.py:186`) currently condense only health score + top issues into history — no
record of what was tried. Extend `format_analysis_for_history` to also fold in
`actions_taken` (tool + result) when present, so `HindsightBuilder.develop_hindsight()`
(`llm/hindsight.py:159`) can tell the next scan "you already tried deleting this pod and it came
back unhealthy — try X instead" rather than repeating a failed action blindly. This is the
concrete mechanism preventing thrash/retry loops across scans (within a scan, the
`max_remediation_actions` cap does the same job).

## Infra changes

### 1. New elevated-RBAC MCP instance (`app-charts/charts/sock-shop/templates/mcptools/`)
Add a second `kubernetes-mcp-server` Deployment+Service+ServiceAccount+**namespaced Role**+
RoleBinding (not ClusterRole), gated behind a values flag (e.g.
`mcpTools.remediation.enabled`, default `false`), named distinctly (e.g.
`kubernetes-mcp-server-rw`) so it coexists with the existing read-only one. Grant only:
```yaml
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get","list","watch","delete"]        # pod-delete, pod-network-loss remediation
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["create"]                              # kill runaway process (pod-cpu-hog)
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get","list"]
- apiGroups: ["apps"]
  resources: ["deployments","statefulsets","replicasets"]
  verbs: ["get","list","watch","patch","update"] # scale back up, restart, rollback
- apiGroups: ["apps"]
  resources: ["deployments/scale"]
  verbs: ["get","update","patch"]
- apiGroups: [""]
  resources: ["persistentvolumeclaims"]
  verbs: ["get","list","watch","delete"]         # database_storage_fault remediation
```
Scoped to the `sock-shop` namespace only (Role, not ClusterRole) — never touches `ace`, `litmus`,
or another checkout's namespaces, satisfying CLAUDE.md §0. Verify the existing read-only instance
and its RBAC are completely untouched by this change (durability check: a fresh
`helm install` with the flag off reproduces today's behavior exactly).

Repeat for `app-charts/charts/otel-demo/` and `app-charts/charts/bookinfo/` as a fast-follow once
sock-shop is validated (same template pattern, same flag name, for consistency).

### 2. Helm values overlay (`agent-charts/charts/flash-agent/`)
New `values-remediation.yaml` (sibling to the default `values.yaml`) setting:
```yaml
agent:
  role: remediation
  config:
    AGENT_ROLE: "remediation"
    MCP_URLS: "http://kubernetes-mcp-server-rw.sock-shop.svc.cluster.local:8081/mcp,http://prometheus-mcp-server.sock-shop.svc.cluster.local:8083/mcp"
    MAX_TOOL_ITERATIONS: "20"
    MAX_REMEDIATION_ACTIONS: "3"
```
Deployed via `helm install ... -f values.yaml -f values-remediation.yaml`, keeping the base chart
untouched for the existing observer identity. Also confirm (verification step, likely no change
needed): the flash-agent pod's own `ClusterRole` (`agent-charts/charts/flash-agent/values.yaml:79-90`,
read-only get/list/watch) is vestigial — the agent never calls the K8s API directly, only MCP
over HTTP — so it does not need widening for remediation; if investigation shows it's actually
used for something, revisit.

### 3. New harness identity (`agents/harness/flash-agent-remediation/`)
Mirror `agents/harness/flash-agent/`'s three files (`bench.yaml`, `agent-harness.yaml`,
`setup.sh`), changing: `agent_id: flash-agent-remediation-v1`, `mcp_urls` pointing at the
`kubernetes-mcp-server-rw` NodePort, env `AGENT_ROLE=remediation`, and
`scan_query`/`bench.yaml`'s description updated from *"...recommended remediation"* to
*"...remediate and resolve issues you can safely fix, and report any you cannot"* — since the
harness contract (`scenario_data.json` → `agent_data.tar`) itself needs no structural change
(confirmed: no ground truth is passed to the agent, correctly).

## Certifier verification pass (no plan to change code unless investigation finds a real gap)

1. Read `certifier/metrics_extractor/` to confirm nothing filters out or misclassifies
   mutating tool-call spans when computing `action_correctness`/`tool_selection_accuracy` against
   `ideal_tool_usage_trajectory` — it should already work generically since it parses whatever
   tool calls appear in the Langfuse trace, but this needs confirming before relying on it for
   real cert scoring of the new agent.
2. Audit the `tool_available: false` flags in `ground_truth.yaml` for the six in-scope
   categories (23 occurrences across all 39 files, inconsistently authored — e.g. `"Pods: Delete"`
   is `true` in `pod-delete/ground_truth.yaml` but `false` in
   `pod-network-corruption/ground_truth.yaml`) and flip ones that are now genuinely callable via
   the new elevated MCP instance to `true`, so certification scoring reflects real capability.

## Rollout / testing plan

1. **Single-fault smoke test in `sock-shop` only**: implement the code changes above, deploy the
   `kubernetes-mcp-server-rw` instance + `values-remediation.yaml` overlay, run one `pod-delete`
   experiment via `python scripts/ace-bench.py flash-agent --runs 1` (or a manual
   `scripts/run_certification.py --trace-id ... --debug` against a captured trace) with
   `AGENT_ROLE=remediation`, and manually confirm: the agent calls a delete tool, `actions_taken`
   is populated, the rescan loop confirms recovery, and the observer identity run alongside it is
   completely unaffected.
2. Expand fault-by-fault across the six in-scope categories in `sock-shop` (start with the
   faults whose `ground_truth.yaml` already marks the needed tool `tool_available: true`, since
   those need no RBAC-list additions beyond what's already scoped above).
3. Extend the `mcpTools.remediation.enabled` overlay to `otel-demo`/`bookinfo`.
4. Register `flash-agent-remediation-v1` in the agent registry, run a full `repeat_per_fault: 30`
   certification pass, and compare its 12-section report against the existing `flash-agent-v1`
   baseline (TTD/TTR, success_rate, safety flags) to confirm the new agent is actually solving
   faults, not just adding risk.

## Handoff docs

Per CLAUDE.md §0.2, append a dated entry to both `OPEN_WEIGHT_CERTIFICATION_HANDOFF.md` and
`OPEN_WEIGHT_CERTIFICATION_HANDOFF_READABLE.md` once code/infra changes land, covering: the new
`AGENT_ROLE` switch, the new elevated-RBAC MCP instance and exact verbs granted, the new harness
identity, and the ground-truth `tool_available` reconciliation — including the "why" (closing the
diagnosis-only gap while keeping the existing agent's RBAC/behavior untouched).