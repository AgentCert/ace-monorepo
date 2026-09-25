# ACE Handoff Briefing

**Certifying agents under real Kubernetes chaos**
Revised 2026-09-02 — orientation page for a developer picking up the project.
Covers `OPEN_WEIGHT_CERTIFICATION_HANDOFF.md` through entry §125.

> ACE (Agent Certification Engine) injects real infrastructure faults into a live
> Kubernetes cluster, lets an AI agent attempt autonomous remediation, and runs its
> full LLM trace through a 4-phase pipeline to produce a statistical certification
> report. This page orients a new developer: what exists, how it fits together, what
> was just fixed, and what's still open. It is a condensed companion to
> `OPEN_WEIGHT_CERTIFICATION_HANDOFF.md` (125 entries) and `innovation.md`, not a
> replacement for either.
>
> **This revision** folds in handoff entries §112–§125 — the arc that took
> `sre-agent-comprehensive` from "never once started" to **autonomously investigating
> and remediating a live fault through its own LLM tool-calling loop** (§119, §123,
> §124, §125); a real agent-remediation verdict to replace the always-100% resiliency
> score (§120–§122); cluster-scoped infra RBAC covering the whole fault catalogue
> (§112); and a Chaos Studio agent-model picker that survives an N=30 batch
> (§114–§118). §93–§116 are committed and pushed (§117); §118–§125 are source-only
> and uncommitted.

## Quick facts

| | |
|---|---|
| Agents onboarded | 6 charts — `flash-agent`, `ciso-agent`, `sre-agent`, `sre-agent-comprehensive`, `sre-agent-crewai`, `k8s-agent` |
| Under active test | `sre-agent-comprehensive` — the `reactfix` multi-fault sweep on otel-demo (§124/§125) and the `q` experiment on Bookinfo (§96–§113) |
| Model routing | Ollama qwen2.5-32b (local GPU, the silent default) + Azure `gpt-4o` alias → GPT-5, now selectable per-run (§114/§125) |
| GPU | NVIDIA RTX A6000, 49 GB — ~40–100× vs CPU |
| Legacy dataset | 137/137 SRE runs — flash-agent + local Ollama, 2026-08-12 (historical baseline) |
| Branch | `feature/itbench-scenarios` — §93–§116 pushed (§117); §118–§125 uncommitted locally |

## Read this first — corrections to how this project has been reported

1. **The `gpt-4o` alias does not actually serve GPT-4o.** Azure's own
   `x-ms-served-model` header confirms this environment's `gpt-4o` deployment is
   silently GPT-5.1, a reasoning-class model with different param requirements
   (`max_completion_tokens`, no `stop`). Any past result labeled "gpt-4o" was
   produced against this backend without anyone knowing. See §9's model-identity gap.
2. **The 137/137 SRE figure is a historical baseline, not current data** —
   flash-agent, local Ollama, 2026-08-12, before the Azure routing and the real
   UI-trigger path. The agent under active test now is `sre-agent-comprehensive`.
3. **Recent traces were real but invisible.** For roughly the last two weeks, every
   Langfuse trace and observation was timestamped `9999-12-31` because an untagged
   ClickHouse image rolled forward to a version that breaks Langfuse v3's timestamp
   ingestion (§108/§110). The UI and the certifier both filter by time window, so a
   trace 8000 years in the future looks exactly like "no trace." Fixed in source;
   the running cluster picks it up on the next `setup.sh --restart --local-build`.
4. **`sre-agent-comprehensive` now runs, investigates, and remediates — but only
   just.** Through §111 two import bugs crash-looped it so no `q` run ever made an LLM
   call. §113/§119 bounded its scan loop and surfaced the opaque `unhandled errors in
   a TaskGroup` MCP failures; §123 made its deterministic preflight reliably fix a
   scaled-to-zero workload end-to-end (verified live, Run 5); §124 replaced CrewAI's
   text-ReAct executor — which doom-loops with qwen — with a native OpenAI
   tool-calling loop (`tool_loop.py`, `SRE_AGENT_ENGINE=toolcalling`, the new
   default), and the agent now autonomously investigates and remediates through the
   LLM path (verified live, Run 6). A multi-fault sweep is in progress (§124/§125).
   All of this is uncommitted and local to the `agentcert-alfred` cluster.
5. **The agent's model was silently always qwen, never the `gpt-4o` alias, until
   §125.** ChaosCenter's GraphQL server rewrites the install-agent `MODEL_ALIAS` on
   every run from its own `FLASH_AGENT_MODEL` env (`qwen2.5-32b-instruct`); the
   manifest's model param was ignored. §114 added a per-run model picker to Chaos
   Studio, §118 made the pick stick across an N=30 batch, but the sweep harness only
   started passing `modelAlias` in §125. GPT-5 (behind `gpt-4o`) is now working —
   ~1.5 s/call, native tool-calling, no 429s. Model identity still needs to be
   pinned and reported (§8 Phase A).
6. **The ITBench resiliency score read 100%/Pass on every run regardless of what the
   agent did** — the ChaosEngines carry no probes and each fault self-reverts inside
   the injector before any post-chaos probe could run (§120). §120 adds a mid-chaos
   (post-hold, pre-revert) probe checkpoint and was verified live two ways (agent
   fixes it → Pass; agent does nothing → Fail/0%); §122 makes the litmus-go framework
   assert recovery for every fault with no probe YAML at all. Both are source-only,
   not yet on the running cluster, and the dynamic ChaosCenter certification path
   still needs §122's `:recovery-check` image promoted.
7. **The rootless-Docker migration produced six distinct incidents**, one still
   unfixed (per-user kernel keyring exhaustion) — see §4.

---

## 1. Architecture — how a fault becomes a certificate

Redrawn to match `docs/platform/architecture.md` + `docs/platform/experiment-flow.md`.
The GraphQL API builds an Argo workflow from an *agent + app + fault selection* and
dispatches it to the target cluster's subscriber pod. The workflow runs in order —
**install-app → install-agent (+ sidecar) → load-test → chaos faults → teardown** —
and during the faults the agent (1 of 6 charts, never told what was injected) works
the cluster over MCP while its LLM calls flow through the sidecar and LiteLLM into
Langfuse. When the run reaches a terminal state the subscriber closes the trace and a
server-side poller drives the certifier.

```
 ┌────────────────────── AgentCert control plane ───────────────────────┐
 │  Web · React :2001    GraphQL API · Go :8080      Auth :3000 / :3030  │
 │                       builds the Argo workflow    MongoDB rs0 :27017  │
 │                       + Langfuse tracer           (sole persistence)  │
 └───────────────────────────────┬─────────────────────────────────────┘
                                 │  Argo workflow + installer images,
                                 │  dispatched to the subscriber over gRPC
                                 ▼
 ┌──────────── Kubernetes target cluster · one per registered infra ─────────────┐
 │  Subscriber pod ── runs Argo, reports run status home                         │
 │                                                                              │
 │  Argo workflow (litmus ns), steps in order:     System under test (app ns):   │
 │    1  install-app     helm upgrade --install       app + Prometheus + Grafana │
 │    2  install-agent   + agent-sidecar              K8s MCP :8081              │
 │    3  load-test       (optional)                   Prometheus MCP :8083       │
 │    4  chaos faults    LitmusChaos ────────────────► faults land on the app    │
 │    5  teardown        uninstall-agent / -application  (real SDK experiments)   │
 │                                                                              │
 │  Agent under test ──MCP / JSON-RPC──► SUT       agent-sidecar :4001           │
 │  (1 of 6 charts, never told                     stamps trace_id = NOTIFY_ID   │
 │   which fault)      ──LLM call──►               on every outbound LLM call    │
 └───────────────────────────────────────────────┬──────────────────────────────┘
        fault spans + run events                 │  stamped LLM calls
                    │                             ▼
                    │              LiteLLM proxy :4000 ──► Azure gpt-4o (⚠ serves GPT-5.1)
                    │              unified gateway     ├─► Ollama qwen2.5 · RTX A6000
                    │                    │             └─► Google Gemini
                    │                    │ trace spans
                    ▼                    ▼
 ┌───────────────────────────────────────────┐
 │ Langfuse · trace store :4000               │   backing store: ClickHouse (pin ≥ 26.8
 │  root span / run · child span / fault     │   + users.d datetime-parse drop-in, §110)
 │  LLM-call spans (LiteLLM) · OTEL events    │   + Postgres (needs a wait-for-db gate, §111)
 └───────────────────┬───────────────────────┘
                     │ raw trace JSON   (GraphQL poller triggers on run completion)
                     ▼
 ┌───────────────────────────────────────────┐      ┌───────────────────────────┐
 │ Certifier · Phase 0 → 4  :8000             │────► │ Certification report      │
 │ bucket → metrics → aggregate → build →     │      │ 12-section · HTML + A4 PDF │
 │ render                                     │      └───────────────────────────┘
 └───────────────────────────────────────────┘
```

**The trace-correlation contract.** One stable `trace_id` per run — generated by the
GraphQL tracer, carried through the subscriber, mounted into the agent pod as
`NOTIFY_ID`, stamped on every LLM call by the sidecar, forwarded by LiteLLM — is what
lets the certifier collect every span for a run.

### How the monorepo's pieces fit together

The monorepo is a superproject of submodules with a clean ownership split
(`docs/platform/architecture.md`). **AgentCert never embeds the agents or apps it
runs** — it references them by chart-source URL and installs them at experiment time
via the two installer images.

| Repo | Owns |
|---|---|
| `AgentCert` | Control plane — GraphQL API, web UI, auth, the in-cluster subscriber, the agent/app/fault-studio registries, the Langfuse tracer |
| `certifier` | The Phase 0→4 pipeline: raw trace → 12-section HTML + PDF report |
| `agent-charts` | Agent Helm charts + the `install-agent` workflow image |
| `app-charts` | Target-app Helm charts + the `install-app` workflow image |
| `chaos-charts` | The fault catalogue (ChaosHub source) — the 30 ITBench bundles + the two teardown faults |
| `litmus-go` | The `itbench-experiment` binary — one image behind all 29 ITBench faults and both teardown steps |
| `agent-sidecar` | The proxy that stamps run identity (`trace_id`) onto every LLM call |
| `agentcert-stack` | LiteLLM gateway config / bootstrap |
| `flash-agent` | The reference agent under test |

**Before any experiment can run** (`docs/platform/experiment-flow.md`): register a
Kubernetes environment (the subscriber lands via the stage 1–4 per-namespace
manifests) → add a ChaosHub, AgentHub and AppHub pointing at the chart repos →
register an Agent and an App → create a Fault Studio. An *experiment* then just binds
*agent + app + fault studio + schedule*.

**Certification is orchestrated server-side, not by the UI**
(`docs/platform/certification-flow.md`). When a run finishes, a GraphQL poller calls
the certifier in sequence — `bucketing-extraction` → poll → (gate: all runs complete)
→ `aggregation-certification` → poll → certificate ready — tracking state in three
Mongo collections (one per experiment, one per run, one per aggregation version). The
UI only reads GraphQL; it never calls the certifier directly, and the PDF is fetched
on demand, never stored in Mongo.

---

## 2. The certifier pipeline — LLMs observe, Python computes

Redrawn from `docs/Methodologies/04-Pipeline/`. LLMs classify and observe;
**Python does all the arithmetic** (TTD/TTR, hallucination score, success rate).
Phase 3's Pydantic v2 validation is a hard gate: a malformed report raises instead of
shipping.

```
Raw Langfuse trace  (one run, interleaved multi-fault spans)
      │
      ▼   ╔══ per run — repeat ≈ 30 runs × N faults × M fault categories ══╗
   Phase 0 · Fault bucketing        fault_analyzer/      [LLM]
      │    3 passes: deterministic fault-span detection + run metadata,
      │    then an LLM classifier only where 2+ faults overlap in a window
      ▼
   Phase 1 · Metrics extraction     metrics_extractor/   [LLM + Python]
      │    LLM extracts text observations; Python computes every number —
      │    TTD, TTR, hallucination_score, token / PII / tool-call sums
      ▼   ╚═══════════════════════════════════════════════════════════════╝
   Phase 2 · Aggregation            aggregator/          [Python + LLM]
      │    deterministic: IQM, mean, p95, BCa bootstrap CI, Wilson CI
      │    LLM Council: k judges + meta-judge → narrative fields
      │    RAI hard gate: any run with PII / adversarial input → that run's RAI = 0
      ▼
   Phase 3 · Certification          cert_builder/        [Python + LLM]
      │    6 deterministic builders (incl. the 8-axis scorecard radar)
      │    + 7 LLM narrative builders (6 concurrent, 1 sequential)
      │    → 12-section report · Pydantic v2 hard gate (raise, never emit bad)
      ▼
   Phase 4 · Render                 cert_reporter/       [Python]
           LangGraph → Jinja2 HTML → Playwright headless Chromium → A4 PDF

   Phase E · Hypothesis framework   hypothesis_framework/   (optional, n ≥ 30)
           H-01…H-09 statistical tests → injected as report Appendix A1–A5
```

**Resiliency score gotcha (§101/§102):** ChaosCenter's resiliency score is
passed-nodes / total-chaos-nodes. The two teardown steps used to be counted as chaos
experiments that structurally could never report a pass, so the `q` workflow scored
`10 ÷ 30 = 33.3%` regardless of how the agent did. Fixed in the GraphQL server: an
`IsTeardownExperiment` helper now excludes teardown from both the weight set and the
pass/fail tally, and §104 rebuilt the teardown steps as real SDK experiments so they
actually pass.

**The bigger scoring gotcha (§120–§122):** even with teardown excluded, the ITBench
ChaosEngines carry **no probes**, and every itbench `InjectFunc` does
patch → hold → revert *inside* `inject()` — so by the time any post-chaos probe would
run, the fault is already gone and the verdict is a vacuous `Pass` / `100%`, fully
decoupled from whether the agent did anything. §120 moves the evaluation point to a
**mid-chaos hook** (`HoldChaos` in `litmus-go/pkg/itbench/common/`, fires post-hold /
pre-revert — the last instant the fault is live) and wires a real recovery `cmdProbe`
onto one reference fault; §121 authored 42 fault-appropriate probes (inert until the
workflow files stop `kubectl apply`ing shell-script ChaosExperiments over the SDK
ones); §122 adds an **SDK-native default recovery assertion** so the framework scores
`readyReplicas`/endpoint recovery for every fault with zero probe YAML. §120 is live-
verified on a throwaway target; §122's image is built (`:recovery-check`) but not
promoted. This is what has to land before an N=30 batch produces a meaningful score.

---

## 3. What's been done, in order

The full log is `OPEN_WEIGHT_CERTIFICATION_HANDOFF.md` — 125 numbered entries with
commit SHAs, exact commands, and verification steps. This is the shape of it.

1. **30 ITBench SRE fault bundles completed** — all 30 ITBench scenarios landed as
   LitmusChaos ChaosHub fault bundles under `chaos-charts/faults/itbench/`.
2. **CISO scorecard pipeline stood up** — metrics adapter + CISO aggregation
   functions in certifier, behind an opt-in `--include-ciso-finops` flag.
3. **GPU discovered mid-session** — an idle RTX A6000 (49 GB), drivers already
   installed. Ollama picked it up with zero config: ~40–100× speedup.
4. **Mass execution: 137/137 SRE runs — historical baseline** (flash-agent, local
   Ollama, 2026-08-12). Predates the Azure routing and the real UI-trigger path.
5. **First real SRE + CISO certification reports** — full Phase 0→4 runs; surfaced 7
   latent report-rendering bugs never hit before Phase 3/4 ran end-to-end.
6. **CISO agent LLM routing fixed** — two hardcoded `"gpt" in model` assumptions
   blocked any open-weight model from running the CISO agent.
7. **Submodule fork drift corrected** — `chaos-charts`, `app-charts`, `certifier` had
   drifted to a personal fork; content could exist locally yet be invisible to the
   deployed ChaosHub. Repointed; standing rule in `CLAUDE.md` §1.
8. **Portability + rootless-Docker rework + MongoDB replica-set fix**
   (2026-08-05 → 08-19). See §4 for the rootless-Docker accounting.
9. **Live ChaosCenter UI batch launches** (36+ experiments) surfaced platform bugs:
   namespaces stuck "Terminating," orphaned infra namespaces, a broken kubectl-copy
   link, and cluster-internal DNS routing silently broken since cluster creation.
10. **SRE agent (Zero) + SRE-CrewAI onboarded**; the 29 custom ITBench faults
    rewritten from shell scripts to real chaos-testing-framework programs.
11. **29/29 ITBench faults ran through the real UI, but every diagnosis was empty**
    (~2026-08-19/20) — a reasoning-class model behind `gpt-4o` doesn't honor the
    `stop` sequence CrewAI's ReAct parser depends on. Candidate fix shipped, not yet
    re-verified.
12. **`setup.sh` hardening marathon** (§75–§81) — dependency audits, a silent-death
    job-control bug, adaptive build parallelism, an infra manifest-ordering race.
13. **"Making local builds tell the truth" (§82–§95)** — a whole class of bugs where
    a correct source fix never reached the running cluster: silent stale-layer reuse,
    a `web` build failing on nonexistent `@visx/*` versions, `kind load` lying about
    multi-arch images, phantom container images behind the uninstall faults and all
    29 ITBench faults. Committed `d5241d0` / `bbc7e10` / `fca469a`.
14. **The `q` experiment debugging arc (§96–§111)** — one ITBench experiment
    (`sre-agent-comprehensive` on Bookinfo) driven repeatedly through the real UI;
    each re-run failed differently and each failure was a real bug: an RBAC file
    that had existed since §31 but was applied by nothing during setup; the uninstall
    steps re-pulling a stale image over the good local one every run; a run-view
    double-render display bug; a `bookinfo` vs chart-internal `book-info` namespace
    split; the agent crash-looping on two import bugs in its own source; the
    resiliency score counting un-passable teardown steps; and finally ClickHouse
    silently breaking every Langfuse timestamp. See §5.
15. **Making `sre-agent-comprehensive` actually work + a real verdict (§112–§125)** —
    committed §107–§116 (§117), then the uncommitted §118–§125 run: cluster-scoped
    infra RBAC widened to the full fault-catalog union (§112); a Chaos Studio
    agent-model picker (§114) that no longer blanks the page (§115) and now persists
    across an N=30 batch (§118); the infra list refreshing after "Done" (§116); the
    `setup.sh` `helm_deploy` `set -e` abort that was the real cause of the §115 "web
    pod never cycled" mystery, plus `ollama.ace.svc` unreachability, both fixed
    (§118); MCP errors made legible and the blind scan loop bounded (§119); a
    mid-chaos recovery-probe checkpoint + 42 probes + an SDK-native default recovery
    assertion (§120–§122); the deterministic preflight proven to remediate
    scaled-to-zero live (§123); CrewAI's text-ReAct executor replaced with a native
    tool-calling loop so the LLM path investigates and remediates on its own (§124);
    and GPT-5 wired through as a real per-run model choice (§125). Multi-fault sweep
    in progress.

---

## 4. Rootless Docker: the full accounting

This checkout runs on a **personal rootless Docker daemon**
(`./scripts/setup.sh --rootless-docker`, CLAUDE.md §6) instead of the shared host's
root daemon — deliberately, to avoid the cross-checkout collision risk in CLAUDE.md
§0. That trade bought real isolation but also a tail of incidents. Six distinct so far
— five fixed or self-healing, one still open.

| Incident | What happened | Status |
|---|---|---|
| Bridge networking + KinD internal-kubeconfig (§20–22) | RootlessKit's "host" network is its own private netns — `auth`/`graphql`/`web` on `network_mode: host` came up with no error but were unreachable. Moved to bridge networking + explicit `ports:`; `graphql` got an internal container-DNS kubeconfig to keep reaching the KinD API server. | parse-verified, **not run e2e** |
| `containerd ≥ 2.3.0` shim regression, `"unsupported protocol: Yunix"` (§23) | This host's system containerd (2.3.3) has a confirmed upstream bug breaking every container start under the affected daemon. A checksum-verified static containerd 2.2.6 is pinned under `$HOME`, scoped only to the personal rootless `docker.service` user unit. | **self-healing** via `setup.sh --rootless-docker` |
| KinD kubeconfig merge gap | Healthy cluster, but `kubectl` hit connection-reset-to-`localhost:8080`. | **fixed** via `kind export kubeconfig` in `setup.sh` + `cluster-init/entrypoint.sh` |
| KinD node DNS unreachable via gateway IP (§47/48) | KinD rewrites each node's `resolv.conf` to the Docker-network gateway IP; the rootful daemon DNATs that to real DNS, RootlessKit/slirp4netns does not — every external image pull inside every node timed out, UI just showed infra "Pending". | not verified |
| `kind load` / `docker cp` deposit stale image content (§65) | Under the `containerd-snapshotter` storage driver, a freshly-rebuilt image landed on the KinD node as stale content 3× in a row; `docker cp` reported exit 0 while the file provably didn't exist. Root cause never isolated. | workaround |
| Ollama Service left pointing at a dead endpoint (§59) | An earlier migration removed the Ollama container (not just stopped it); the Service/Endpoints object and model volume survived, so flash-agent pods got `Connection refused`, silently reported as a clean scan. | **needs a restart / check** |
| **Per-UID kernel session-keyring exhaustion — the "disk quota exceeded" that isn't about disk (§62)** | An Argo experiment failed 5 of ~20 pods with `OCI runtime create failed: unable to create session key: disk quota exceeded`. `/proc/key-users` showed this UID at `200/200` on `kernel.keys.maxkeys` — the host's default per-user kernel session-keyring quota, one key per container. Pressure came from an unrelated `flash-agent` release crash-looping for 28 h / 339 restarts. Recovered only by deleting a throwaway namespace; nothing monitors this quota. | **NOT FIXED** |

**Why the keyring quota matters:** `kernel.keys.maxkeys` (default 200) is a *per-Linux-user*
kernel limit shared across every rootless daemon, every KinD cluster, and every pod
that user ever creates. A crash-looping pod left running (as CLAUDE.md §0 correctly
favours over unilaterally killing someone's work) burns through it quietly, then an
unrelated experiment fails with an error that reads like a disk problem.
**Two independent fixes:** raise the sysctl for this user (host-admin coordinated);
and/or add a `/proc/key-users` preflight to `setup.sh` / `check-prerequisites.sh`.

---

## 5. What got fixed — 2026-08-25 onward

### Batch 1 — LLM routing & agent correctness (commit `39ad013`)

- **Azure gpt-4o stopped silently dropping calls** (`litellm.yaml`) — a second
  distinct Azure deployment entry so failures spread across two ids instead of
  blackballing one; `AIOHTTP_KEEPALIVE_TIMEOUT=45`; `num_retries` 3→5.
- **flash-agent stopped reporting fake health** — MCP-discovery or ReAct dead-ends
  now return `status: "failed"` with a reason; `main.py` exits non-zero.
- **sre-agent-comprehensive: candidate fix for "found nothing"** — ported the
  stop-word / `max_completion_tokens` workaround from `sre-agent-crewai`.

### Batch 2 — build & deploy honesty (§82–§95, commits `d5241d0` / `bbc7e10`)

One user-triggered experiment failed step after step. The through-line: **a fix can be
correct in source, correct in a freshly-built image, and still not be what the cluster
is running.**

```
 Source fixed ──►  Local image  ──►  KinD node  ──►  Deployment  ──►  Running pod
 (commit)          (docker build)     (kind load)     (rollout)
        │                 │                │               │
   build silently    stale cached     multi-arch load   never restarted
   no-ops / fails    layer reused     fails, reported
                                      as success
```

- **§82** `--no-cache` extended to every locally-built image (was only `web`); the
  four bogus `@visx/*` version pins in `web` corrected to match `yarn.lock`; a new
  opt-in `--allow-build-cache` for a fast dev loop. A full 12-image `--no-cache`
  rebuild is 3 m 32 s at 6-way parallelism.
- **§91–§93** The uninstall faults and all 29 ITBench faults referenced container
  images that were never built. Pointed at the real `install-agent`/`install-app`
  images (given a `-delete` / `-delete-namespace` mode); wired the shared
  `itbench-experiment` image into `prepare-images.sh`, which was also crashing on any
  unset optional `.env` key, and whose local-build path pointed one folder too deep.
- **§95** `kind load` reported success for multi-arch images it failed to load —
  `kind_load()` now returns a real exit status with a per-node `crictl pull` fallback.
- **§89** Blank-canvas agent experiments referenced an unset Argo variable (the
  agent's Helm release name); Argo rejected the whole workflow, so the run showed
  "completed" with zero traces. Now derived from the install step at save- and
  run-time, so old experiments self-heal.
- **§84 / §87 / §88** Blank-canvas builder: the "Target Application" tab could be
  skipped; the App Label dropdown couldn't resolve a queued-for-install app; the App
  Kind dropdown wiped Namespace/Label on every click. All fixed.

### Batch 3 — the `q` experiment debugging arc, committed & pushed (§96–§105)

- **§96** Cross-namespace chaos was "forbidden" because the `itbench:litmus-admin`
  permission grant — correct in `chaos-charts` since §31 — was **applied by nothing
  during setup** and wiped on every cluster rebuild. `setup.sh` now applies it every
  run in both deploy modes. Separately, the *uninstall* steps had
  `imagePullPolicy: Always`, so every run ended by pulling a stale June image over
  the good local one and poisoning the next run's install step. Fixed across 16 files.
- **§97** The run-view drew the whole 9-step workflow twice (18 boxes). The status
  stitching layer (an ACE addition) let a per-run tracking id overwrite each step's
  name-based identity, so the "which live steps are extra?" check matched nothing and
  re-appended the entire run. Fixed; pulled into a tested helper.
- **§98** The install-helper image pull policy is now a setup/runtime choice
  (`Always` = production default; `setup.sh` writes `Never` for `*_IMAGE_SOURCE=local`
  so a missing local image fails loudly). Also closed a missing `install-agent`
  run-time override.
- **§99** Replaced the broad cluster-wide `litmus-admin` binding in source with a
  per-run service account (`ace-chaos-<notify_id>`) + namespace-scoped RoleBindings,
  cleaned up on terminal run events. *(Superseded by §106 — see below.)*
- **§100** `install-app -folder=bookinfo -namespace=bookinfo` installed into
  `bookinfo`, but the chart's own default rendered workloads into `book-info`, so the
  fault targeted an empty namespace. `install-app` now sets
  `namespaces.bookInfo/sockShop/otelDemo` to match the requested `-namespace`.
- **§101** `q` produced no LLM calls because **`sre-agent-comprehensive` crash-loops
  on import** — `crew.py` did `import mcp_tools` instead of `from .mcp_tools import`,
  and had a stray top-level `build_crew()` call. Both fixed; image rebuilt and loaded.
- **§102** The resiliency score no longer counts teardown steps
  (`IsTeardownExperiment` helper, 3 call sites in the GraphQL server).
- **§103** `ACE_BUILD_LOG_DIR` env var to redirect the local build-log directory
  (with a guard against dangerous values); `ACE_BUILD_PARALLELISM` documented.
- **§104** `uninstall-agent` / `uninstall-application` rebuilt as **real litmus-go
  SDK experiments** compiled into the `itbench-experiment` binary — they now emit a
  `Passed` ChaosResult, and `uninstall-application` does a complete namespace
  teardown (release-scoped delete first, then `delete namespace`).
- **§105** §93–§104 committed and pushed across five repos (litmus-go, AgentCert,
  app-charts, chaos-charts, ace-monorepo). Along the way, a `~/.gitconfig` GitHub
  username typo (`aruscher_dev` vs `aruscher-dev`) was blocking auth and was
  corrected directly.

### Batch 4 — the ClickHouse arc + UI fixes, now committed & pushed via §117 (§106–§116)

- **§106** The §99 per-experiment RBAC sandbox is **switched off** for now
  (`perExperimentChaosRBACEnabled = false`) — its permission list only covered
  pod-level faults; ITBench, node, and teardown faults need cluster-wide grants a
  namespace-scoped account can't give. The sandbox code stays as a disabled scaffold;
  `litmus-admin` gained `configmaps`/`ingresses`/PDB/HPA delete, and `setup.sh`
  applies it on every bring-up. Trade-offs written up in `innovation.md` §7.5.
- **§107** **Chaos Studio uninstall-step picker (Phase A)** — "Uninstall Application"
  / "Uninstall Agent" sidebar buttons + a drawer that scans the draft experiment for
  what it installs and drops the right teardown fault in. Multiple install/uninstall
  pairs (Phase B) is designed in `innovation.md` §1.16, not built. (AgentCert
  `047e8a7`.)
- **§108 → §110** **ClickHouse silently broke every Langfuse timestamp.** The
  untagged `clickhouse/clickhouse-server` image rolled to `:latest` = 26.8, which
  reads Langfuse's millisecond timestamps as seconds, overflows, and clamps to
  `9999-12-31` — so every trace became invisible to the UI and the certifier. **Final
  fix (§110):** keep ClickHouse on 26.8, drop a `users.d` file setting
  `input_format_read_datetime_number_as_raw_value = 1` (restores the old parse, no
  volume wipe), in all three deploy paths. Plus a new `setup.sh` **image-drift check**
  that resolves the registry digest of every third-party image and warns when a
  floating tag has moved, seeded from a checked-in `deploy/image-baseline.tsv`.
- **§109** The **A2A bridge** (`agents/harness/a2a-mcp-agent/`) now speaks current A2A
  (`message/send`, spec 0.3.0) with a fallback to the legacy `tasks/send` draft — it
  was hard-wired to the pre-0.2 name, so any current-spec agent (e.g. an AgentBeats
  competitor) got "method not found." Full interop analysis in `innovation.md` §2.9.
- **§111** `langfuse-web` crash-looped on a from-scratch deploy because Postgres took
  ~2.5 min to initialise and `langfuse-web` runs migrations immediately. Added a
  `wait-for-db` init container that derives its target from `DATABASE_URL` (no second
  copy of the address); the shared Postgres env block was pulled into one Helm helper.
- **§116** A newly registered chaos infrastructure didn't appear in the environment's
  infra list until you left the environment and came back. Three independent causes:
  the wizard's "Done" restarted the 5 s poll on the line right after `refetch()`, which
  supersedes the in-flight refetch in Apollo 3.x; the poll itself never rendered results
  because a `cache-and-network` query needs `notifyOnNetworkStatusChange` in Apollo 3.x;
  and `ListInfras` had no `$sort`, so a new infra landed on a later page. Fixed all
  three (server sorts newest-first by `created_at`; the list query sets the flag and
  stops flashing the spinner over the table on background polls; "Done" awaits the
  refetch before restarting the poll). Needs `graphql` + `web` rebuilt to go live.
- **§112** Cluster-scoped chaos-infrastructure RBAC (`litmus-admin-cluster-role` in
  the generated `manifests/cluster/` bundle) still carried the narrow upstream Litmus
  permission set, so `uninstall-agent` / `uninstall-application` 403'd on `book-info`
  every run. Replaced with the **union of every permission the `chaos-charts` fault
  catalogue declares**, plus a catalog-driven Go regression test; namespace-scoped
  infra validated against the namespaced subset.
- **§113** `sre-agent-comprehensive` runs a **bounded scan loop** (stays alive through
  the fault window instead of one-shot-exit-then-CrashLoop), rejects a premature empty
  CrewAI answer until minimum tool evidence exists, and emits **tool-call spans to
  Langfuse** so a trace shows what the agent actually did, not just paid completions.
- **§114 / §115** A Chaos Studio **agent-model picker** (`listAgentModelOptions` +
  `runChaosExperiment(modelAlias:)`) so a single manual run can pick Ollama vs an
  API model without redeploying. §115: it was added to an `import type` block, so
  `ts-loader`'s transpile-only build elided it and Chaos Studio rendered a blank
  page — fixed, plus a note to add `npm run typecheck` to the web build.
- **§117** All of §107–§116 committed and pushed across `chaos-charts`, `agent-charts`,
  `AgentCert`, and the superproject; pointers bumped.

### Batch 5 — `sre-agent-comprehensive` made to work + a real verdict, uncommitted (§118–§125)

- **§118** The §114 model pick was lost on runs 2..N of a multi-run batch — every
  re-run called `RunChaosWorkFlow(..., "")` and re-resolved the env default, so an
  N=30 batch was not model-consistent. Now persisted as a
  `litmuschaos.io/modelAlias` manifest annotation, resolved once and reused. **Also
  in §118:** two `setup.sh` bugs — (1) `helm_deploy` `wait`s on a just-killed
  background watch loop, which returns 143 and, under `set -e`, **aborts the entire
  script right after "Happy Helming!"**, skipping `restart_locally_built_deployments`
  and steps 5c–5f. *This is the root cause of the §115 "web image rebuilt but pod
  never cycled" mystery.* (2) step 5c's Ollama-network resolution took SIGPIPE under
  `pipefail`. Both fixed; plus `ollama.ace.svc.cluster.local` made reachable by
  `docker network connect`ing the Ollama container to the `kind` net (this host drops
  Docker inter-bridge forwarding to a published port).
- **§119** Every MCP tool call failed with the opaque `unhandled errors in a
  TaskGroup`; the blind scan loop then re-emitted a byte-identical empty diagnosis
  ~13×/run; and `temperature=0.0` made all N certification runs identical. Fixed:
  `_unwrap_exc` flattens the anyio `ExceptionGroup` to its real cause, an
  `asyncio.wait_for` timeout is enforced, `check_mcp_reachable()` gates each cycle and
  abandons the loop after 3 all-down cycles, and `SRE_AGENT_TEMPERATURE` defaults to
  0.2.
- **§120 → §122** A **real agent-remediation verdict.** §120: a mid-chaos hook
  (`HoldChaos`, post-hold / pre-revert) in `litmus-go/pkg/itbench/common/` runs a
  recovery probe at the last instant the fault is live, then the injector's own revert
  still runs — live-verified both ways on a throwaway target. §121: 42
  fault-appropriate `cmdProbe`s authored across the workflow files (inert until those
  files stop `kubectl apply`ing shell-script ChaosExperiments over the SDK ones).
  §122: an **SDK-native default recovery assertion** (`readyReplicas` / endpoint
  presence) so the framework scores every fault with zero probe YAML — this is the one
  the dynamic ChaosCenter path needs. `:recovery-check` image built, not promoted.
- **§123** `sre-agent-comprehensive` **actually remediates** a scaled-to-zero workload
  end-to-end — four separate breakages fixed: the K8s MCP server now returns YAML not
  tables; the MCP tool names in `mcp_tools.py` corrected to what this server build
  exposes (`resources_scale`, `resources_create_or_update` — there is no
  `resources_patch`); the MCP ServiceAccount given namespace-scoped **write** verbs;
  and `crew.kickoff()` bounded by `_kickoff_with_timeout` (120 s) so the deterministic
  preflight gets a second scan turn. Verified live (Run 5): `quote` back to `1/1`
  ~7 min before self-revert.
- **§124** Replaced CrewAI 0.95's hard-wired **text-ReAct executor** (which doom-loops
  with qwen — free-runs past the `\nObservation:` stop, scratchpad bloats, completion
  goes empty, restarts) with a **native OpenAI tool-calling loop** — new
  `tool_loop.py`, `SRE_AGENT_ENGINE=toolcalling` (default). Duplicate-call
  suppression, force-answer after 16 steps, `compact_tool_output` to fit a 20-step
  investigation in context. Verified live (Run 6): the LLM path walked
  list→get→`patch_resource` and remediated on its own, ~7 min before self-revert.
- **§125** Deep-dive enforcement (`_open_issues` rejects a "nothing wrong" conclusion
  while the cluster still has unremediated problems), entity-naming nudge, sharper
  symptom→tool prompt, and **GPT-5 (the `gpt-4o` alias) wired through as a real
  per-run model** — ChaosCenter was silently rewriting `MODEL_ALIAS` to
  `qwen2.5-32b-instruct` on every run; `register_experiment.py` / `sweep.py` now pass
  `modelAlias`. GPT-5 works: ~1.5 s/call, parallel tool calls, no 429s (needs
  `max_completion_tokens`, not `max_tokens`). Multi-fault sweep running.
- **§125 (CRD)** `unknown field 'spec.experiments[0].spec.rank'` warning spam in every
  inject-fault log is **not an error** — pure version skew between the trimmed
  ChaosEngine CRD bundle and `chaos-runner:3.0.0`. `rank` declared in all three CRD
  copies; needs the CRD re-applied.

---

## 6. Bug catalog, by layer

A sample, grouped by where the bug lived. Full detail and SHAs in the handoff log.

| Layer | Bug | Root cause |
|---|---|---|
| Cluster / infra | Litmus `subscriber` pod, 876 restarts | NetworkPolicy blocked its own ingress selectors |
| Cluster / infra | Auth service, 159 restarts over 17 h | Mongo replica member registered by ClusterIP name, which `isSelf()` can never match — fixed via headless per-pod DNS |
| Cluster / infra | Cross-namespace chaos "forbidden" every run (§96) | The `litmus-admin` grant existed in `chaos-charts` since §31 but was applied by nothing during setup, and wiped on every cluster rebuild |
| Trace store | Every Langfuse trace timestamped `9999-12-31`, invisible everywhere (§108/§110) | Untagged ClickHouse image → `:latest` = 26.8, which reads ms timestamps as seconds and clamps the overflow |
| Trace store | `langfuse-web` CrashLoopBackOff on fresh deploy (§111) | Runs DB migrations immediately; Postgres takes ~2.5 min to init the data dir — no readiness gate |
| LLM gateway | Prompt silently truncated | Ollama's default 2048-token context window vs. a ~2100-token system prompt; fixed with `num_ctx: 16384` |
| Agent code | CISO agent crashed for any non-GPT model | Two LLM call paths each hardcoded a `"gpt" in model` check |
| Agent code | `sre-agent-comprehensive` never once started (§101) | `crew.py`: bare `import mcp_tools` instead of a relative import, plus a stray top-level `build_crew()` call — both fire on import |
| Agent code | `sre-agent-comprehensive` made paid LLM calls but never remediated (§113/§119/§123/§124) | scan loop exited one-shot then CrashLooped; every MCP call died as opaque `unhandled errors in a TaskGroup`; MCP tool names had drifted (`resources_patch` doesn't exist); MCP SA was read-only; CrewAI text-ReAct doom-loops with qwen — fixed by a bounded scan loop, error unwrapping, correct tool names + write RBAC, and a native tool-calling loop replacing the CrewAI executor |
| Agent code | Agent always ran on qwen even when a run picked `gpt-4o` (§125) | ChaosCenter's `ops.InjectExperimentContextArgs` rewrites install-agent `MODEL_ALIAS` from the server's own `FLASH_AGENT_MODEL` env on every run; the harness never passed the `runChaosExperiment(modelAlias:)` arg |
| Scoring | ITBench resiliency 100%/Pass regardless of agent behavior (§120–§122) | ChaosEngines carry no probes, and each fault self-reverts inside `inject()` before any post-chaos probe runs — verdict fully decoupled from the agent |
| Deploy tooling | `setup.sh --restart --local-build` rebuilt images but never cycled the pods (§115/§118) | `helm_deploy` `wait`s on a just-SIGKILLed background watch loop → exit 143 → `set -e` aborts the whole script right after the Helm deploy, before `restart_locally_built_deployments` and steps 5c–5f |
| Infra | `litellm.ace.svc` → `ollama.ace.svc.cluster.local` times out even with the Service present (§118) | this host drops Docker inter-bridge forwarding to a published port; fixed by `docker network connect`ing the Ollama container onto the `kind` network and pointing Endpoints at its IP:11434 |
| Cluster / infra | Cluster-scoped infra RBAC 403s `uninstall-*` on the app namespace (§112) | generated `litmus-admin-cluster-role` still had the narrow upstream permission set, not the union of what the `chaos-charts` fault catalogue declares |
| Certifier | Phase 4 PDF silently dropped half its content | Renderer dispatch table handled only 7 of 14 block types |
| Certifier | `total_runs: 0` in every report | Key-path typo: `experiment.run_id` vs. `experiment_run_id` |
| Scoring | `q` always scored 33.3% resiliency (§101/§102) | The score counted the two teardown steps as chaos experiments that structurally cannot report a pass |
| Build pipeline | Source fix never reaches the running pod (§82–§95) | `--no-cache` guarded only `web`; `web` build failed on nonexistent `@visx/*` versions; KinD kept its own stale image copy; `kind load` reported success for multi-arch images it failed to load |
| Chaos faults | Fault hangs ~5 min then "succeeds" having done nothing | Fault definitions referenced container images (`uninstall-agent`, the dispatcher behind all 29 ITBench faults) never built or wired into `prepare-images.sh` |
| Web frontend | Run-view drew the whole workflow twice (§97) | A per-run tracking id overwrote each step's name identity, so the "extra steps" check re-appended the entire run |
| Web frontend | New chaos infra invisible until you left the environment and came back (§116) | `refetch()` on "Done" was superseded by a synchronous `startPolling()`; `cache-and-network` polling never rendered without `notifyOnNetworkStatusChange` (Apollo 3.x); and `ListInfras` had no `$sort` so a new infra fell past the page-1 limit |
| Web frontend | Fault silently saved with no target application | "Target Application" tab skippable; App Label couldn't resolve a queued-for-install app; App Kind reset Namespace/Label on every click |
| Harness | A2A bridge couldn't drive a current-spec agent (§109) | Hard-wired to the pre-0.2 `tasks/send` method name; the spec renamed it to `message/send` at 0.2 |
| App charts | Fault targeted an empty namespace (§100) | `install-app` installed into `-namespace` but the chart's own default rendered workloads into a different internal namespace |

---

## 7. What's actually unresolved right now

> **State of `sre-agent-comprehensive` (the headline).** It now works: it stays alive
> through the fault window, makes real MCP tool calls, and remediates — the
> deterministic preflight does scaled-to-zero reliably (§123, Run 5), and the native
> tool-calling loop that replaced CrewAI's text-ReAct executor investigates and
> remediates through the LLM path on its own (§124, Run 6), on GPT-5 via the `gpt-4o`
> alias (§125). What's left is **breadth and durability**, not "does it run": the
> multi-fault sweep (§124/§125) is still triaging which fault classes the model
> reliably fixes, and none of §118–§125 is committed or on any cluster but
> `agentcert-alfred`.

### 🔴 §118–§125 are entirely uncommitted; the whole agent-works story is local
`tool_loop.py`, the MCP-tool-name + write-RBAC fixes, the recovery-verdict work
(§120–§122), the two `setup.sh` bugs, and the model-alias plumbing are all
working-tree only, across the `agents/sre-agent-comprehensive`, `app-charts`,
`chaos-charts`, `litmus-go`, and `AgentCert` trees. The agent image, the
`install-app` RBAC image, and `itbench-experiment` are all local to `agentcert-alfred`
(loaded via `docker save`→`ctr import` because plain `kind load` no-ops on this host).
**Recommendation:** commit per-repo, bump submodule pointers, push; then rebuild
images wherever else this runs.

### 🔴 The ClickHouse fix (§110) is committed but may still need a cluster restart
§117 committed it, but it only takes effect after `setup.sh --restart --local-build`
re-applies the ClickHouse manifests. If the live cluster predates that, fresh traces
still clamp to `9999-12-31`. Confirm ClickHouse is on the pinned `:26.8` with the
`input_format_read_datetime_number_as_raw_value` drop-in before trusting any new trace.

### 🔴 A real N=30 verdict is not wired end-to-end yet
§120 (mid-chaos probe checkpoint) is live-verified but only on a hand-built
ChaosEngine; §122 (SDK-native default recovery assertion — the one the dynamic
ChaosCenter certification path actually needs) is built as
`agentcert/itbench-experiment:recovery-check` but **not promoted to `:dev` and not
live-run**. The 42 §121 probes are inert until the workflow files stop
`kubectl apply`ing shell-script ChaosExperiments over the SDK ones. Until one of these
lands, every ITBench run still scores a vacuous `Pass`/`100%`. The sweep harness
currently judges recovery by watching `quote` readiness vs the self-revert deadline,
not by a ChaosResult.

### 🔴 The model was silently always qwen — verify per-run identity end-to-end
§125 fixed the harness to pass `modelAlias`, and traces now show `model=azure/gpt4o`.
But ChaosCenter still resolves `MODEL_ALIAS` from `FLASH_AGENT_MODEL` whenever no
explicit alias is passed (the §118 annotation only persists a pick that was made). Any
path that doesn't go through the §125 harness or the §114 Chaos Studio picker still
gets the env default. Combined with the `gpt-4o`→GPT-5.1 mislabeling (§Read-this-first
#1), a validated model/provider field at registration + real `model` extracted from
Langfuse spans into the report is still Phase A work.

### 🔴 The `spec.rank` CRD warning needs the CRD re-applied
Cosmetic (§125), but the fix is code-only — `kubectl apply` the updated
`2a_litmus_crds.yaml`, or `setup.sh --restart --local-build`, to silence it.

### 🔴 Every install-agent step still gets flash-agent-shaped values
`injectExperimentContextArgs` (GraphQL) matches any install-agent step by template
name alone and injects a fixed `--set` list shaped for flash-agent's schema. §113
added a batch of `sre-agent-comprehensive`-specific keys (`TARGET_NAMESPACE`,
`WORKFLOW_UID`, Langfuse, bounded-runtime) to that same fixed list, so it works for
these two agents by union — but there is still no branching on the agent's declared
schema. **Recommendation:** branch on `agenthub` metadata — step A1 of §8.

### 🔴 The teardown fault definitions need pushing to the AgentCert-org repo
§104 rebuilt `uninstall-agent` / `uninstall-application` as real SDK experiments, but
a deployed ChaosCenter's hub only syncs from the AgentCert org. Until the chaos-charts
change is on that remote, a live run still installs the old helm-wrapper versions.
The existing `q` experiment also needs its two teardown steps **re-added in Studio**
to pick up the new versions.

### 🔴 Per-UID kernel keyring exhaustion can silently block all new pods
`kernel.keys.maxkeys` (default 200, per Linux user) is shared across every
rootless-Docker container; a long-running crash-looping pod burns through it, then an
unrelated experiment fails with a misleading "disk quota exceeded." Full writeup §4.

### 🟡 `sre-agent-comprehensive` LLM reasoning quality on the harder faults
Even when the agent remediates, the diagnosis narrative can hallucinate the cause
(Run 6 invented a "missing nodeSelector / Pending" story for what was just a replica
count). qwen2.5:32b investigates shallowly (§125); GPT-5 does `get`-level inspection
and parallel tool calls but is verbose enough that its final JSON truncated at 2000
tokens (fixed to 6000). Treat as a certification finding or move to a bigger open
model.

### 🟡 Ollama's Service may still point at a dead endpoint
Found dangling after a rootless-Docker migration removed the container while the
Service/Endpoints object and model volume survived. §118's step-5c fix
`docker network connect`s the container onto the `kind` net and repoints Endpoints,
but the `kind`-net IP is DHCP and changes on any container recreate — 5c must re-run
after one. **Check:** `docker ps -a | grep ollama`; if absent,
`./scripts/start-local-services.sh --only-ollama`, then `setup.sh --restart`.

### 🟡 Rootless-Docker Compose rework: parse-verified, not run end-to-end
Verified via `docker compose config`; a real `docker compose up` under a rootless
daemon has not been run.

### 🔴 `CLUSTER_MODE=cloud` + rootless Docker: known, unfixed gap
`pin_api_server_host()` only patches `/etc/hosts` for the host-networked
`cluster-init`; `graphql` no longer shares that file. Doesn't block local-KinD work.
Tracked in `innovation.md` §3.19.

### 🟡 Three CISO narrative builders still stub out on CISO-only runs
`key_findings`, `qualitative`, `limitations` read an SRE-only field for every
category; caught gracefully, but the content is generic.

---

## 8. What's left before ITBench faults are fully onboarded onto standard benchmarking

### Phase A — Correctness blockers
1. **Commit §118–§125 per-repo, bump submodule pointers, push, rebuild images.** The
   entire "agent now works" story — `tool_loop.py`, MCP tool names + write RBAC,
   `setup.sh` bugs #1/#2, model-alias plumbing, the recovery-verdict work — is
   working-tree only and local to `agentcert-alfred`. Nothing else picks it up until
   this happens.
2. **Land a real remediation verdict.** Promote `agentcert/itbench-experiment:recovery-check`
   (§122) to `:dev`, `kind load`, and do the two-case live run (agent fixes it → Pass;
   agent does nothing → Fail/0%) on the *no-probe* dynamic path. Then the ITBench
   score stops being vacuous.
3. **Finish the multi-fault sweep (§124/§125)** — run `sweep.py --all`, triage which
   fault classes the model reliably misses, and add a hybrid deterministic preflight
   floor (§124 "Step 4") for the ~6 blunt structural faults.
4. **Confirm ClickHouse + the `spec.rank` CRD are actually applied on the target
   cluster** — both are committed/code-done but need `setup.sh --restart --local-build`
   (or a manual `kubectl apply`) to be live.
5. **Push the §104 teardown fault definitions to the AgentCert-org `chaos-charts`**
   so a deployed hub serves them; re-add the two teardown steps to `q` in Studio.
6. **Stop hardcoding flash-agent's value schema** — branch
   `injectExperimentContextArgs` on the selected agent's declared `agenthub` schema
   instead of the current works-by-union fixed `--set` list.
7. **Pin and report actual model identity** — a validated model/provider field at
   agent registration; extract the real `model` from Langfuse spans into the report
   `Meta` section. Non-optional given the gpt-4o→GPT-5.1 mislabeling *and* the silent
   `FLASH_AGENT_MODEL` override (§125).
8. **Run an N=30 batch on `sre-agent-comprehensive`** once 1–4 land — a green run
   graph, dated traces, per-run variance (`SRE_AGENT_TEMPERATURE=0.2`), and a
   resiliency score that tracks actual remediation.

### Phase B — Coverage
6. **Repeat the real-UI-trigger validation for the other agents** — `sre-agent`,
   `sre-agent-crewai`, `ciso-agent`, `k8s-agent` have no recent live data.
7. **Decide the fate of the 137/137 dataset** — re-run under current config, or
   retire it as a historical baseline in any report that cites it.

### Phase C — Scale & safety
8. **Fix the disk-fill blast-radius gap** — sizing falls through to the node's real
   shared disk when no `ephemeral-storage` limit is set on the target.
9. **Concurrent experiment support** — only one experiment can safely run per
   agent/app pairing today.
10. **Finish or formally retire the per-experiment RBAC sandbox** (§99/§106,
    `innovation.md` §7.5).

### Phase D — Housekeeping
11. **Raise `kernel.keys.maxkeys`** for this user (host-admin coordinated) and add a
    `/proc/key-users` preflight to `setup.sh`.
12. **Caveat the 137/137 figure** wherever it leads a doc's top-of-file status line.
13. **Revisit the `itbench-experiment` publish switch** (§94) — wired for a future
    Docker Hub publish but deliberately still local-only; a loud warning fires when
    it's pointed at a registry and needs revisiting once a real publish happens.

---

## 9. Ideas for later

`innovation.md` is the consolidated log. Open items only; reference numbers match its
section numbers.

| Idea | Area | Ref |
|---|---|---|
| Chaos Studio: multiple install/uninstall pairs per experiment (uninstall picker Phase B) | Frontend | 1.16 |
| Per-experiment model selection from the ChaosCenter UI, not a global `.env` setting | Certifier | 1.11 |
| Fault-injection timestamp from Argo workflow state, not a trace-native event — biases TTD/TTR under node contention | Certifier | 1.13 |
| No model/provider identity control, validation, or reporting for agents under test | Certifier | 1.14 |
| LiteLLM rate-limit controls (`rpm`/`tpm`/`max_parallel_requests`) unconfigured for cloud providers | LLM Config | 1.15 |
| AgentBeats interoperability — full onboarding-path mapping + 4 adaptation gaps | Agents | 2.9 |
| Finish the per-experiment chaos-RBAC sandbox (drop NodePort for the in-cluster path, per-run namespace DNS) | Infrastructure | 7.5 |
| Streaming early-abort for stop-incompatible model aliases — working prototype, not the default | LLM Config | 4.7 |
| Multi-stage self-contained web Dockerfile | Infrastructure | 3.14 |
| `make dev` target for always-fresh Compose images | Dev Experience | 3.15 |
| Prompt for JWT/MongoDB credentials at setup instead of shipping defaults | Security | 3.16 |
| HTTPS for the ChaosCenter web UI — currently plaintext end to end | Infrastructure | 3.18 |
| Concurrent experiment execution for the same agent/app pairing | Infrastructure | 3.20 |
| `disk-fill` fault blast-radius audit | Infrastructure | 3.21 |
| MongoDB backup/restore/lineage flow needs a real end-to-end checkup against a live pod | Infrastructure | 3.22 |
| `--local` flag for `build-and-push.sh` (kind-load instead of Hub push) | Images | 5.3 |
| Origin header on the GraphQL subscriber's WebSocket dial, instead of a broadened `ALLOWED_ORIGINS` regex | Security | 7.4 |
| PR for the CISO agent OpenAI-compatible LLM fix — sitting on a personal fork, not raised upstream | Upstream | 8.1 |
| Remaining CISO scenario types untested: Kubectl-OPA, RHEL9-Ansible-OPA, Upd-Kyverno | Evaluation | 8.3 |

---

## 10. Quick reference

### Start here

| Doc | What's in it |
|---|---|
| `CLAUDE.md` | Authoritative repo map — architecture, subsystems, env vars, entry points. Read first. |
| `OPEN_WEIGHT_CERTIFICATION_HANDOFF.md` | The full 125-entry technical change log — commit SHAs, exact commands, verification steps. |
| `.tmp/sre-agent-experiments/REACTFIX_HANDOFF.md` · `reactfix/sweep.py` · `sweep_results*.tsv` | The `sre-agent-comprehensive` fault-sweep working notes, harness, and per-model result archives (§123–§125). Not repo code. |
| `OPEN_WEIGHT_CERTIFICATION_HANDOFF_READABLE.md` | Prose rewrite of the same log, easier to skim. |
| `innovation.md` | Every feature considered or implemented across ACE, with status — source for §9. |
| `chaos-charts/ITBENCH_HANDOFF.md` | Design notes for the 30 ITBench fault bundles (submodule). |
| `docs/platform/` · `docs/Methodologies/` | The rendered doc site — `architecture.md`, `experiment-flow.md`, `certification-flow.md`, and the per-phase pipeline pages. Source for the two diagrams above and the repo map. |

### Commands you'll actually use

| Command | Does what |
|---|---|
| `./scripts/setup.sh` | Interactive first-time wizard |
| `./scripts/setup.sh --restart --local-build` | Redeploy **and rebuild** Go/web images — needed for every §97–§125 fix to land on the cluster (and, since §118, it actually reaches the post-Helm steps now) |
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

*Built from `OPEN_WEIGHT_CERTIFICATION_HANDOFF.md` / `_READABLE.md` (125 entries),
`innovation.md`, `CLAUDE.md`, the `docs/` site (architecture, experiment-flow,
certification-flow, the pipeline pages — source for the two system diagrams and the
repo map), the `.tmp/sre-agent-experiments/` sweep notes, and a direct look at git
log / status and the live GraphQL server source. First built 2026-08-25, revised
2026-09-02. Treat the handoff docs and `innovation.md` as the source of truth for
anything condensed here.*
