# ACE Handoff Briefing

**Certifying agents under real Kubernetes chaos**
Updated 2026-08-25 — orientation page for a developer picking up the project.

> ACE (Agent Certification Engine) injects real infrastructure faults into a live
> Kubernetes cluster, lets an AI agent attempt autonomous remediation, and runs its
> full LLM trace through a 4-phase pipeline to produce a statistical certification
> report. This page orients a new developer: what exists, how it fits together, what
> was just fixed, and what's still open. It is a condensed companion to
> `OPEN_WEIGHT_CERTIFICATION_HANDOFF.md` (81 entries) and `innovation.md`, not a
> replacement for either.

## Quick facts

| | |
|---|---|
| Agents onboarded | 6 charts — `flash-agent`, `ciso-agent`, `sre-agent`, `sre-agent-comprehensive`, `sre-agent-crewai`, `k8s-agent` |
| Actively tested recently | `sre-agent-comprehensive` only — 29/29 ITBench faults via the live UI trigger |
| Model routing | Ollama qwen2.5 (local GPU) + Azure `gpt-4o` alias |
| GPU | NVIDIA RTX A6000, 49GB — ~40–100× vs CPU |
| Legacy dataset | 137/137 SRE runs — flash-agent + local Ollama, 2026-08-12 |
| Branch | `feature/itbench-scenarios` |

## By the way

**The `gpt-4o` alias does not actually serve GPT-4o.** Azure's own
   `x-ms-served-model` response header confirms this environment's `gpt-4o`
   deployment is silently GPT-5.1, a reasoning-class model with different param
   requirements (`max_completion_tokens`, no `stop`). Any past result labeled
   "gpt-4o" was produced against this same backend without anyone knowing it — see
   [Today's fixes](#4-what-got-fixed-today-2026-08-25) and the
   [model-identity gap](#8-ideas-for-later).

---

## 1. Architecture — how a fault becomes a certificate

One end-to-end run: an onboarded agent (there are 6 charts on the platform — this is
**not** flash-agent-specific, though flash-agent uses MCP over SSE while the
CrewAI-based agents use MCP streamable-HTTP with a fresh session per call) operates
against a live cluster while a fault is injected, every LLM call it makes is traced,
and once the run ends the trace is fed through certifier's four phases to produce a
scored report.

```
 Agent under test (1 of 6 onboarded charts, e.g. sre-agent-comprehensive)
   │
   │ LLM calls                                agent-sidecar stamps
   ▼                                           EXPERIMENT_ID / RUN_ID
 LiteLLM proxy (:14000, unified gateway) ──┬──────────► Ollama (GPU)
   │                                       │             qwen2.5-instruct, A6000
   │ OTEL spans                            └──────────► Azure OpenAI
   ▼                                                     alias: gpt-4o
 Langfuse (:4000, trace store) ────────────┐             ⚠ actually serves GPT-5.1
                                            │ raw trace JSON
   Agent under test                        ▼
   │  MCP / JSON-RPC                  Certifier — Phase 0→4 (:8000)
   ▼                                  bucket → metrics → aggregate
 ┌─────────────────────────┐          → build → render
 │ k3s / KinD cluster       │               │
 │  K8s MCP server          │               │ HTML + A4 PDF
 │  Prometheus MCP          │               ▼
 │  (chaos faults land on   │          Certification report
 │   the target app here)   │
 └─────────────────────────┘
```

LiteLLM currently load-balances between local Ollama and the Azure `gpt-4o` alias;
every certificate is traceable back through this same trace path.

## 2. The certifier pipeline — four phases, one hard gate

LLMs classify and observe; **Python does all the arithmetic** (TTD/TTR, hallucination
score, success rate). Phase 3's Pydantic validation is a hard gate: a malformed report
raises instead of shipping. (Note: the report's `Meta` section does not currently
record which model actually served a run — see the model-identity gap below.)

```
┌──────────────┐   ┌──────────────────┐   ┌──────────────┐   ┌──────────────────┐   ┌────────────┐
│ Phase 0      │   │ Phase 1          │   │ Phase 2      │   │ Phase 3          │   │ Phase 4    │
│ Fault        │──►│ Metrics          │──►│ Aggregation  │──►│ Report assembly  │──►│ Render     │
│ bucketing    │   │ extraction       │   │              │   │                  │   │            │
│ reasoning LLM│   │ LLM observe +    │   │ stats + LLM  │   │ 7 narrative      │   │ LangGraph  │
│ spans→fault  │   │ Python math      │   │ Council      │   │ builders         │   │ → Jinja2 → │
│ lifecycle    │   │ TTD/TTR/halluc.  │   │ mean/p95/    │   │ Pydantic hard    │   │ Playwright │
│ (LLM)        │   │ (LLM)            │   │ narrative    │   │ gate (LLM)       │   │ → PDF      │
└──────────────┘   └──────────────────┘   └──────────────┘   └──────────────────┘   └────────────┘
```

---

## 3. What's been done, in order

The full log is `OPEN_WEIGHT_CERTIFICATION_HANDOFF.md` — 81 numbered entries with
commit SHAs, exact commands, and verification steps. This is the shape of it.

1. **30 ITBench SRE fault bundles completed** — all 30 ITBench scenarios landed as
   LitmusChaos ChaosHub fault bundles under `chaos-charts/faults/itbench/`, before this
   certification effort began.
2. **CISO scorecard pipeline stood up** — metrics adapter + CISO-specific aggregation
   functions added to certifier, behind an opt-in `--include-ciso-finops` flag.
3. **GPU discovered mid-session** — an idle RTX A6000 (49GB) was found on the host with
   drivers already installed. Ollama picked it up with zero config changes: ~40–100×
   speedup, turning a multi-day mass-execution plan into a same-session one.
4. **Mass execution: 137/137 SRE runs — historical baseline.** 29 fault bundles × 5
   runs (2 high-blast-radius faults capped at 1) — **flash-agent, local Ollama,
   2026-08-12.** A cleanup-timing bug in the run driver (deleting the fault before it
   finished reverting) caused real cluster damage that was found and fully repaired.
   This predates the Azure gpt-4o routing and the platform's real UI-trigger path —
   treat it as a proof-of-concept dataset, not the current state of certification
   coverage.
5. **First real SRE certification report** — full Phase 0→4 run producing a 20-page
   PDF with real narrative content; surfaced 7 latent report-rendering bugs that had
   never been hit because Phase 3/4 had never run end-to-end before.
6. **CISO agent LLM routing fixed, first trial PASS** — two separate bugs in
   `ciso-agent/src/ciso_agent/llm.py` (LangChain path and CrewAI/litellm path each
   hardcoded a `"gpt" in model` assumption) blocked any open-weight model from running
   the CISO agent at all.
7. **CISO mass execution + first CISO certification report** — 5 runs across 3 scenario
   types; two genuine small-model reliability failures recorded honestly as data, not
   hidden. First-ever CISO PDF produced through Phase 2→4.
8. **Submodule fork drift corrected** — `chaos-charts`, `app-charts`, and `certifier`
   had silently drifted to point at a contributor's personal fork instead of the
   `AgentCert` org, meaning content could exist locally yet be invisible to the
   deployed ChaosHub. Repointed and made this a standing rule in `CLAUDE.md` §1.
9. **Post-certification portability hardening** (2026-08-05 → 08-11) — swept every
   submodule for hardcoded Docker-bridge IPs and service names that were never real.
10. **Rootless-Docker rework + MongoDB replica-set fix** (2026-08-12 →) — bridge
    networking for `auth`/`graphql`/`web`, a KinD internal-kubeconfig bridge, personal
    CDI GPU passthrough, and a Kubernetes replica-set bug fixed via headless per-pod
    DNS.
11. **Live ChaosCenter UI batch launches** (2026-08-13 → 08-19) — 36+ experiments
    launched through the actual web UI surfaced platform-level bugs: namespace stuck
    "Terminating," orphaned infra namespaces, a broken "copy this kubectl command"
    link, and a UI stuck on "Loading…" traced to Kubernetes' internal traffic routing
    being silently broken since cluster creation.
12. **SRE agent (Zero) and SRE-CrewAI onboarded** (2026-08-14 → 08-19) — both agents
    wired into `setup.sh` and the UI; the 29 custom ITBench faults were rewritten from
    plain shell scripts into real chaos-testing-framework programs.
13. **The most recent real experiment: 29/29 faults ran, but the agent never actually
    looked** (~2026-08-19/20, **root cause found**) — the current benchmark of record.
    All 29 ITBench faults were triggered against `sre-agent-comprehensive` exactly the
    way clicking "Run" in the web UI triggers them, not a driver shortcut. That
    surfaced 4 real platform bugs (cluster-internal DNS routing silently broken; a
    required readiness precheck rejecting valid faults; unreliable in-cluster file
    copying; one stuck run silently delaying every run behind it), all fixed. Every
    fault injected cleanly and every run showed real LLM activity. **But every one of
    the 29 diagnoses came back "found nothing."** The agent's very first tool-call
    attempt, every single run, didn't match the format its framework (CrewAI) expects
    — and CrewAI's fallback on a malformed first attempt is to demand a final answer
    immediately rather than retry. Root cause: the same issue behind the
    `gpt-4o`→GPT-5.1 caveat above — a reasoning-class model doesn't honor the `stop`
    sequence CrewAI's ReAct parser depends on. The platform and fault-injection
    machinery are now proven end-to-end; the agent riding on top of it was not
    producing usable diagnoses.
14. **`setup.sh` hardening marathon + agent-correctness fixes** (2026-08-20 → today,
    **commit status disputed**) — a long tail of wizard reliability fixes, an infra
    manifest-ordering race fix, and — today — the candidate fix for the "found
    nothing" bug above, plus a related flash-agent honesty fix. See below.

---

## 4. What got fixed today (2026-08-25)

Two batches: fixes to agent/LLM-routing correctness (landed in commit `39ad013`), and
a further run of `setup.sh` wizard-reliability fixes plus one infra bug (§75–§81 of the
handoff log, disputed commit status — see the callout above).

### LLM routing & agent correctness

**Azure gpt-4o stopped silently dropping calls** (`litellm.yaml`) — LiteLLM v1.82's
shared aiohttp connection pool can hand out a stale pooled connection to a backend that
already closed it idle, surfacing as a bare `APIConnectionError` — and a
single-deployment model group gets fully blackballed after 3 such failures in 10s,
aborting retries regardless of `num_retries`. **Fix:** added a second, deliberately
distinct Azure gpt-4o deployment entry so failures spread across two deployment ids
instead of blackballing one; set `AIOHTTP_KEEPALIVE_TIMEOUT=45` below the backend's own
idle-close window; raised `num_retries` 3→5.

**flash-agent stopped reporting fake health** (`flash_agent.py`) — when MCP tool
discovery failed or the ReAct loop dead-ended, the agent silently returned the same
shape as a genuinely healthy scan (`issues: []`) — indistinguishable from "checked,
found nothing wrong." **Fix:** both failure paths now return an explicit
`status: "failed"` with a reason, and `main.py` exits non-zero instead of reporting
success.

**sre-agent-comprehensive: candidate fix for "found nothing"** (`crew.py`) — ported the
same stop-word / `max_completion_tokens` workaround already proven in
`sre-agent-crewai` — the model behind `gpt-4o` rejects the legacy `stop`/`max_tokens`
params CrewAI's ReAct executor sends by default, which is the most direct explanation
for every diagnosis in the run above coming back empty. **Status: not yet re-verified
live.** Shipped in the same commit as the finding, but no fresh 29-fault run has
confirmed it actually produces real diagnoses.

### Wizard reliability & infra — §75–§81

- **§75 — Venv sync flooded the terminal.** Pip output now redirects to a log file;
  terminal shows a compact progress bar; `.venv`/`.venv-*` excluded from manifest
  discovery.
- **§76 — pip `resolution-too-deep`.** The aggregated `pyproject.toml` install now uses
  `--no-deps`; requirements manifests remain the source of truth for transitive deps.
- **§77 — Noisy `SyntaxWarning` spam.** A real regex bug in `chaos-charts` fixed at
  source; third-party warning noise suppressed for setup-managed Python subprocesses.
- **§78 — Build prompt defaulted to skip.** Enter now maps to "build ALL locally" in
  both express and guided setup paths.
- **§79 — Prereq audit looked hung.** It was silently crawling 32,409 site-package
  files because the skip-list only matched a directory literally named `.venv`, not
  `.venv-setup-auto`. Fixed to skip any `site-packages` path or `.venv*` directory.
- **§80 — Build phase looked hung on Ollama.** A bare `wait` was blocking on every
  background job, including the multi-GB Ollama pull. Scoped to only the build jobs.
- **§81 — ITBench infra registration raced RBAC vs. its own Deployments.** The Go
  manifest generator glues 8 template files using filesystem order, not filename order
  — live evidence caught a Deployment created before its own ServiceAccount existed.
  **Fix:** sort the template list before concatenating. **Not yet in the running
  image** — needs `setup.sh --restart --local-build` to rebuild the graphql Go binary
  before it takes effect on a live cluster.

---

## 5. Bug catalog, by layer

A sample from the ~70 earlier entries, grouped by where the bug actually lived. Full
detail and commit SHAs are in the handoff log.

| Layer | Bug | Root cause |
|---|---|---|
| Cluster / infra | Litmus `subscriber` pod, 876 restarts | NetworkPolicy blocked its own ingress selectors |
| Cluster / infra | Auth service, 159 restarts over 17h | Mongo replica member registered by ClusterIP name, which `isSelf()` can never match |
| LLM gateway | Ollama unreachable from LiteLLM container | Ollama bound to `127.0.0.1` only |
| LLM gateway | Prompt silently truncated | Ollama's default 2048-token context window vs. flash-agent's ~2100-token system prompt |
| Agent code | CISO agent crashed for any non-GPT model | Two separate LLM call paths each hardcoded a `"gpt" in model` check |
| Agent code | flash-agent crashed on some model outputs | `[{...}]` list-wrapped JSON broke every downstream `.get()` call |
| Certifier | Phase 4 PDF silently dropped half its content | Renderer's dispatch table only handled 7 of 14 block types |
| Certifier | `total_runs: 0` in every report | Key-path typo: `experiment.run_id` vs. real field `experiment_run_id` |
| Mass-execution driver | Cluster left in broken state after full sweep | ChaosEngine deleted before the fault's own revert commands had run |

---

## 6. What's actually unresolved right now {#current-problems}

### 🔴 Every install-agent step still gets flash-agent-shaped values
`injectExperimentContextArgs` (GraphQL server) matches any install-agent workflow step
by template name alone and unconditionally injects a fixed Helm `--set` arg list shaped
for flash-agent's specific schema. `sre-agent-comprehensive` already uses a
structurally different schema with no branching to handle it.
**Recommendation:** this is the central blocker for treating any agent besides
flash-agent as reliably configured through the standard UI/Argo experiment path — see
step A1 of the onboarding plan below.

### 🟡 Today's "found nothing" fix hasn't been re-verified live
The stop-word/`max_completion_tokens` fix ported into `sre-agent-comprehensive` is a
strong candidate for why every one of the 29 real UI-triggered runs came back with an
empty diagnosis, but no fresh run has confirmed it.
**Recommendation:** re-run the same 29-fault sweep through the real UI-trigger path —
step A3 of the onboarding plan below.

### 🟡 Cross-component Python dependency conflict — mitigated, not solved
The setup venv-sync flattens every ACE Python component into one `.venv`. Today's
fixes made the symptom quieter and stopped one resolver failure mode — they didn't
change the underlying one-venv-for-everything architecture.

### 🟡 Rootless-Docker Compose rework: parse-verified, not run end-to-end
Verified via `docker compose config` (rendered YAML looks correct) but a real
`docker compose up` bring-up under a rootless daemon has not actually been run.

### 🔴 `CLUSTER_MODE=cloud` + rootless Docker: known, unfixed gap
The privatelink-DNS `pin_api_server_host()` mechanism only patches `/etc/hosts` for
the host-networked `cluster-init` service; `graphql` no longer shares that file.
Doesn't block local-KinD work. Tracked in `innovation.md` §3.19.

### 🟡 Three CISO narrative builders still stub out on CISO-only runs
`key_findings`, `qualitative`, and `limitations` builders read an SRE-only field for
every category; caught gracefully but the CISO-specific narrative content is generic.

---

## 7. What's left before ITBench faults are fully onboarded onto standard benchmarking

All 29+ ITBench SRE fault bundles exist and inject cleanly. What's not yet true: that
any onboarded agent besides flash-agent is reliably *configured* by the standard
UI/Argo path, that the one agent under active test is actually *diagnosing* anything,
or that a result can be trusted to say which model produced it. Ordered by what blocks
the next thing.

### Phase A — Correctness blockers (fix before trusting any multi-agent result)
1. **Stop hardcoding flash-agent's value schema.** Fix `injectExperimentContextArgs`
   to branch on the selected agent's declared schema instead of injecting one fixed
   arg list onto every install-agent step.
2. **Rebuild + redeploy the §81 fix.** `setup.sh --restart --local-build`, then
   register a fresh infra and confirm RBAC lands before its Deployments.
3. **Re-verify the "found nothing" fix.** Re-run the full 29-fault sweep against
   `sre-agent-comprehensive` through the real UI-trigger path.
4. **Pin and report actual model identity.** Add a validated model/provider field at
   agent registration; extract the real `model` from Langfuse spans into the cert
   report's `Meta` section. Non-optional given the confirmed gpt-4o→GPT-5.1
   mislabeling.

### Phase B — Coverage (today, only one of six agents has current data)
5. **Repeat the real-UI-trigger validation for the rest** — `sre-agent`,
   `sre-agent-crewai`, `ciso-agent`, `k8s-agent` have no recent live-UI-triggered data.
6. **Decide the fate of the 137/137 dataset** — re-run under current config, or
   explicitly retire it as a historical baseline in any report that cites it.

### Phase C — Scale & safety (needed once running the full fault set is routine)
7. **Fix the disk-fill blast-radius gap** — sizing falls through to the node's real
   shared disk when no `ephemeral-storage` limit is set on the target.
8. **Concurrent experiment support** — only one experiment can safely run per
   agent/app pairing today.
9. **Guided onboarding UX** — no "Create Experiment" path exists for a new agent/app
   pairing; chart-folder names must match exactly by hand.

### Phase D — Housekeeping
10. **Resolve the commit-status discrepancy** — confirm which checkout is
    authoritative, commit and push there.
11. **Update the stale status banners** — both handoff docs still open with "as of
    2026-08-12."

---

## 8. Ideas for later

`innovation.md` is the consolidated log of every feature considered across ACE's
development — roughly 51 entries already implemented, ~20 still proposed, and a few
partially tested or waiting on an upstream PR. What follows is only the open ones,
grouped by area. Reference numbers match `innovation.md` section numbers directly.

| Idea | Area | Ref |
|---|---|---|
| Per-experiment model selection from the ChaosCenter UI, not a global `.env` setting | Certifier | 1.11 |
| Fault-injection timestamp sourced from Argo workflow state, not a trace-native event — biases TTD/TTR under node contention | Certifier | 1.13 |
| No model/provider identity control, validation, or reporting for agents under test | Certifier | 1.14 |
| LiteLLM rate-limit controls (`rpm`/`tpm`/`max_parallel_requests`) unconfigured for cloud providers | LLM Config | 1.15 |
| Switch `sre-agent-qwen` to the composite prompt entry-point — deliberately deferred | Agents | 2.7 |
| Streaming early-abort for stop-incompatible model aliases — working prototype, not the default | LLM Config | 4.7 |
| Multi-stage self-contained web Dockerfile | Infrastructure | 3.14 |
| `make dev` target for always-fresh Compose images | Dev Experience | 3.15 |
| Prompt for JWT/MongoDB credentials at setup instead of shipping defaults | Security | 3.16 |
| Prompt for Azure Content Safety / Blob Storage config at setup | Security | 3.17 |
| HTTPS for the ChaosCenter web UI — currently plaintext end to end | Infrastructure | 3.18 |
| Concurrent experiment execution for the same agent/app pairing | Infrastructure | 3.20 |
| `disk-fill` fault blast-radius audit | Infrastructure | 3.21 |
| MongoDB backup/restore/lineage flow needs a real end-to-end checkup against a live pod | Infrastructure | 3.22 |
| `--local` flag for `build-and-push.sh` (kind-load instead of Hub push) | Images | 5.3 |
| `make setup-env` target for gitignored per-agent trial env files | Dev Experience | 6.7 |
| "Answer all questions upfront" option in `setup.sh` | Dev Experience | 6.8 |
| Origin header on the GraphQL subscriber's WebSocket dial, instead of a broadened `ALLOWED_ORIGINS` regex | Security | 7.4 |
| PR for the CISO agent OpenAI-compatible LLM fix — sitting on a personal fork, not yet raised upstream | Upstream | 8.1 |
| Push the SRE agent live-mode MCP fix — committed locally, not yet pushed anywhere | Upstream | 8.2 |
| Remaining CISO scenario types untested: Kubectl-OPA, RHEL9-Ansible-OPA, Upd-Kyverno | Evaluation | 8.3 |

---

## 9. Quick reference

### Start here

| Doc | What's in it |
|---|---|
| `CLAUDE.md` | Authoritative repo map — architecture, subsystems, env vars, entry points. Read first. |
| `OPEN_WEIGHT_CERTIFICATION_HANDOFF.md` | The full 81-entry technical change log — commit SHAs, exact commands, verification steps. |
| `OPEN_WEIGHT_CERTIFICATION_HANDOFF_READABLE.md` | Prose rewrite of the same log, easier to skim. |
| `innovation.md` | Every feature considered or implemented across ACE, with status — source for §8 above. |
| `chaos-charts/ITBENCH_HANDOFF.md` | Design notes for the 30 ITBench fault bundles themselves (submodule). |

### Commands you'll actually use

| Command | Does what |
|---|---|
| `./scripts/setup.sh` | Interactive first-time wizard |
| `./scripts/setup.sh --restart` | Redeploy with existing `.env`, no prompts (does *not* rebuild Go binaries — add `--local-build`, needed right now for §81) |
| `./scripts/start-local-services.sh` | Bring up MongoDB + Langfuse + Ollama + LiteLLM + Certifier via Compose |
| `python scripts/ace-bench.py flash-agent --runs 30` | Dev-tool: run the flash-agent trace_based pipeline locally |
| `python scripts/run_certification.py --trace-id <UUID>` | Run the certifier pipeline for one trace, no FastAPI server needed |

### Default local credentials

| Service | URL | Login |
|---|---|---|
| AgentCert UI | `localhost:2001` | admin / litmus |
| Langfuse | `localhost:$LANGFUSE_PORT` (4000) | admin@agentcert.local / agentcert-admin |
| MongoDB | `localhost:$MONGO_PORT` (27017, rs0) | admin / 1234 |
| LiteLLM proxy | `localhost:$LITELLM_PORT` (14000) | key: `sk-agentcert-2026` |
| Certifier Swagger | `localhost:8000/docs` | — |

### The one rule that matters most on this host

This dev host is shared. Never stop, remove, or recreate a Docker/Kubernetes resource
you didn't create this session without explicit confirmation — see `CLAUDE.md` §0.
Always use `ACE_INSTANCE_NAME`-scoped naming and `scripts/compose-up-guard.sh`.

---

*Built from `OPEN_WEIGHT_CERTIFICATION_HANDOFF.md` / `_READABLE.md` (81 entries),
`innovation.md`, `CLAUDE.md`, and a direct look at git status, the live litellm/agent
config, and running processes on 2026-08-25. Treat the handoff docs and `innovation.md`
as the source of truth for anything condensed here — this page corrects forward from
what earlier sessions believed (see the callout at the top) rather than silently
restating it.*
