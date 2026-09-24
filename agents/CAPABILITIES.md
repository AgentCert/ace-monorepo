# Agent Capabilities

Summary of every agent implementation in this directory: what it does, which pipeline
it runs under, and which fault/scenario universe it can be benchmarked against. See
`agents/harness/<name>/bench.yaml` and `agent-harness.yaml` for the exact runnable
configuration behind each row.

Two scenario universes exist:
- **ITBench** — IBM's config-level Kubernetes fault benchmark
  (`chaos-charts/faults/itbench/`, 30 scenario types: e.g. scaled-to-zero workload,
  nonexistent container image, misconfigured readiness probe, HPA misconfig, DNS
  failure, ingress blocking, valkey password/OOM, anti-affinity, priority preemption).
- **Standard LitmusChaos faults** — classic infra chaos experiments
  (`chaos-charts/faults/kubernetes/`, ~27 types: pod-delete, CPU/memory hog,
  container-kill, network loss/latency/corruption/duplication/partition/rate-limit,
  IO-stress, DNS-error, HTTP-latency/status-code/modify-body/modify-header/reset-peer,
  disk-fill, node-drain/cpu-hog/memory-hog/poweroff/restart/taint).

| Agent | Framework | Pipeline | Scope |
|---|---|---|---|
| `flash-agent` | Custom ReAct + MCP (K8s + Prometheus) | `trace_based` | ITBench-flavored, but driven by hand-picked Argo workflow manifests, not the raw ITBench harness |
| `ciso-agent` | LangGraph + CrewAI + LiteLLM | `ciso` | ITBench-CISO compliance scenarios (not fault-remediation) |
| `sre-agent` ("Zero") | Codex-CLI wrapper + MCP | `sre` | ITBench-Lite offline snapshot dataset |
| `sre-agent-comprehensive` | Custom (`sre_comprehensive`) | `itbench_sre` | Both ITBench + standard LitmusChaos faults, live cluster — broadest coverage |
| `sre-agent-crewai` | CrewAI + MCP streamable-HTTP | orchestrated via Argo Workflow only (retired from `ace-bench.py`) | ITBench + standard faults, live cluster, N=30 certification runs |
| `sre-agent-qwen` | Codex-CLI wrapper + MCP, local Ollama | `itbench_sre` | ITBench faults only, plus a two-layer prompt-patch capability-probe harness |
| `a2a-mcp-agent` (harness-only) | Universal A2A/JSON-RPC bridge, not an LLM agent | any | Any A2A-compatible external agent, any scenario type |

---

## flash-agent

Implements Microsoft Research's FLASH methodology: DISCOVER → REASON+ACT → ANALYZE →
REFLECT, with hindsight self-reflection injected into subsequent scan cycles. Scope-
agnostic MCP discovery (works whether the K8s MCP server is namespace-scoped or
cluster-wide). Two pre-baked Argo Workflow manifests define what it is actually
benchmarked against in practice:

- **`flash-agent-5scenario-manifest.json`** — 5 ITBench scenarios: scaled-to-zero
  workload, nonexistent container image, misconfigured readiness probe, modified
  target-port service, feature-flag flood.
- **`flash-agent-comprehensive-30-manifest.json`** (newest; launchable from the
  AgentCert UI) — ~35 ITBench scenarios (feature-flag/CPU faults, env-var
  misconfig, pod-failure, unsupported-arch image, HTTP tamper/abort, ingress
  blocking, nonexistent node, valkey password/OOM, HPA misconfig, cordoned node,
  no-limits/memory-stress, priority preemption, DNS failure, anti-affinity,
  hanging/crashing init container, insufficient resources, API-server surge,
  resource quota, invalid selector, nonexistent PVC, deleted service) plus 16
  standard LitmusChaos faults (pod-delete, CPU/memory hog, container-kill, network
  loss/latency/corruption/duplication/partition/rate-limit, IO-stress, DNS-error,
  HTTP-latency/status-code/modify-body/modify-header/reset-peer).

## ciso-agent

LangGraph `CISOManager` routes tasks to 3 CrewAI sub-agents: `kubernetes_kyverno`,
`kubernetes_kubectl_opa`, `rhel_playbook_opa`. Generates Kyverno policies and OPA
Rego rules, evaluates via kubectl, executes Ansible playbooks on RHEL. Configured
(`bench.yaml`) for 3 ITBench-CISO compliance scenario types: Gen-CIS-b-K8s-Kyverno,
Gen-CIS-b-K8s-Kubectl-OPA, Upd-CIS-b-K8s-Kyverno. This is compliance/policy
generation and verification against CIS benchmarks — not fault-remediation.

## sre-agent ("Zero")

Codex CLI wrapper managing workspace setup, prompt templating (`AGENTS.md`), MCP
server lifecycle, and retry logic. Supports **offline** evaluation against the
ITBench-Lite snapshot dataset (Hugging Face `itbench-org/ITBench-Lite`, one
"Scenario-N" subdirectory per fault) — the canonical offline ITBench SRE track.
Does not touch a live cluster in this mode.

## sre-agent-comprehensive

Purpose-built to cover every fault defined under `chaos-charts/faults/` — both
`itbench/` (30 config-level faults) and `kubernetes/` (~27 standard LitmusChaos
faults) — in live online mode with real kubectl/Prometheus MCP tools, following a
9-phase investigation protocol. Evaluated via `agent_output.json`. Broadest
single-agent coverage of any agent in this directory.

## sre-agent-crewai

Same fault universe as `sre-agent-comprehensive` (ITBench + standard,
`itbench_sre` pipeline), but retired from the local `ace-bench.py` dev path — now
runs exclusively via the LitmusChaos Argo Workflow triggered from the AgentCert
UI, at full `runs_per_fault: 30` certification scale. Single CrewAI agent with an
eight-step investigation protocol: list namespaces → pod health → events →
NetworkPolicies → policy specs → Prometheus PromQL → delete faulty resource →
verify recovery.

## sre-agent-qwen

A capability-probed variant of the SRE agent using local Ollama
(`qwen2.5:7b-instruct`) instead of default LiteLLM routing. Same ITBench
`itbench_sre` fault set as `sre-agent-comprehensive`/`sre-agent-crewai`, plus a
two-layer prompt-patch evaluation harness (`capability_probes` in `bench.yaml`)
that measures raw open-weight model capability (Layer 1: unpatched prompts)
against patched-prompt performance (Layer 2) on two known failure modes: RBAC
namespace-scope awareness, and premature offline-tool calls before live data
collection.

## a2a-mcp-agent (harness-only, not an LLM agent)

A generic bridge (`a2a_bridge.py`) for any external agent that speaks A2A (Agent
Card + JSON-RPC `tasks/send`/`tasks/get`) and MCP. Scenario-agnostic: whatever
`scenario_data.json` (`goal`, `mcp_urls`, `openai_base_url`, `model_alias`) is fed
to it, it can point at any ITBench or non-ITBench scenario the target agent
supports, with no certifier- or harness-side changes required.
