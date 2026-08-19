# Handoff: sidecar fault-attribution fix

Scoped handoff for continuing **one specific piece of work** — do not confuse this with
`OPEN_WEIGHT_CERTIFICATION_HANDOFF.md` (the full project change log; this work is also
recorded there as §42, in more narrative form). This file is meant to be read cold by a
Claude Code session with no other context on this conversation.

---

## 1. The problem this fixes

When one Argo Workflow injects several chaos faults back to back (e.g. `flash-agent-comprehensive-30`,
or the new single-pass `flash-agent-5scenario` experiment), the certifier's Phase 0 fault-bucketing
step (`certifier/fault_analyzer/scripts/fault_bucketing.py`) is supposed to split the trace into
one bucket per fault. It could only do this by scanning the trace for `fault: <name>` Langfuse spans
that the ChaosCenter observability tracer emits at injection time. When those spans are sparse or
missing — confirmed empirically: a real trace pulled from this cluster's Langfuse had only 1 `fault:`
span for its 1 completed injection, nothing to anchor a split once more faults start — the whole
trace collapses into one `Unclassified` bucket instead of a real per-fault breakdown. This was first
hit and partially patched (stopped it from hard-failing, didn't fix the collapse) in
`OPEN_WEIGHT_CERTIFICATION_HANDOFF.md` §39.

## 2. The fix

`agent-sidecar/proxy.py` (the HTTP proxy that sits between the agent and LiteLLM) already re-reads
its context fresh from a ConfigMap volume mount **on every single LLM request** — that's the existing
mechanism that lets a long-running agent pod pick up a new `NOTIFY_ID` without restarting. It just
had no field for "which fault is active right now." The fix adds one:

1. The Argo Workflow's fault-injection step brackets each fault with a `kubectl patch configmap`
   write — sets `CURRENT_FAULT_NAME=<fault-name>` right before injecting, clears it to `""` right
   after revert.
2. The sidecar picks this up on its next context read (same poll loop it already runs) and stamps
   `metadata.current_fault_name` onto every outgoing LLM call — real, live ground truth, not an
   inference.
3. The certifier's fault-bucketing pipeline gained a new **Pass 0** that splits the trace
   deterministically on `current_fault_name` transitions when present, running *before* the existing
   `fault: *`-span heuristic (Pass 1). On a trace that carries the tag nowhere at all (older data, or
   a workflow that doesn't bracket faults this way), Pass 0 is a true no-op — everything falls back to
   working exactly as it did before.

### The one subtle design point worth understanding before touching this code

A call carrying **no** `current_fault_name` key can mean two different things, and getting them
confused breaks the fix:
- **Never tagged at all** (legacy trace, or a non-LLM scaffolding span like `workflow-step: *`) →
  leave it alone, don't touch bucket state.
- **Explicitly cleared** (the sidecar *did* see the ConfigMap, and it currently reads `""`) → this
  is a real transition signal and must close whichever fault bucket was open.

`fault_bucketing.py` distinguishes these with a sentinel (`FaultBucketingPipeline._NO_FAULT_TAG`) —
see `_extract_current_fault_name()`. Without this distinction, 5 sequential occurrences of the
*same* fault type in one trace silently merge back into 1 bucket instead of staying 5 distinct ones
— this was an actual bug caught mid-session by a standalone test before it shipped (see §6).

## 3. Files changed (all still uncommitted)

| File | Status | What |
|---|---|---|
| `agent-sidecar/proxy.py` | modified | New `CURRENT_FAULT_NAME` context key; `_load_context()` special-cases "file exists but empty" vs "file never existed"; `_inject_metadata()` stamps `current_fault_name` onto every call when the key is present at all. |
| `agent-charts/charts/flash-agent/templates/configmap.yaml` | modified | New `CURRENT_FAULT_NAME: ""` key in the Helm-templated ConfigMap. |
| `certifier/fault_analyzer/scripts/fault_bucketing.py` | modified | New `_bucket_by_current_fault_name()` (Pass 0) + `_enrich_buckets_from_span()` helper; wired into `run()` before the existing Pass 1. |
| `agents/harness/flash-agent/flash-agent-5scenario-manifest.json` | **new file** | Argo Workflow manifest: one pass through 5 ITBench fault scenarios on `otel-demo` (scaled-to-zero, nonexistent-image, readiness-probe, target-port, feature-flag-flood), each bracketed by new `mark-fault-start`/`mark-fault-clear` steps that patch the ConfigMap. `interFaultPause=90s` (see §7 for why). **Deliberately does not loop for "N runs"** — see §5. |

## 4. Live infra state on this cluster right now

- Cluster: KinD `agentcert-alfred` (`ACE_INSTANCE_NAME=alfred02-trn`), Docker container
  `agentcert-alfred-control-plane`. This is the user's own checkout/cluster, not shared.
- Relevant ports (host): Web UI `2002`, GraphQL REST `8084`, Auth REST `3006`, Certifier API `18001`,
  MongoDB `27020`.
- Namespaces: `ace` (platform services), `otel-demo` (target app + `flash-agent` Deployment +
  `flash-agent-metadata` ConfigMap), `itbench` (chaos infra: `workflow-controller`, `subscriber`,
  `chaos-exporter`, admin-mode namespace for ChaosEngines).
- **certifier**: LIVE and verified running the fix. Image `agentcert/certifier:latest` was rebuilt
  from `certifier/Dockerfile`, `kind load docker-image agentcert/certifier:latest --name
  agentcert-alfred` (note: `certifier/Makefile`'s `kind-load` target hardcodes the *wrong* cluster
  name `agentcert`, not `agentcert-alfred` — don't use `make kind-load` on this host, pass `--name
  agentcert-alfred` directly). Then `kubectl rollout restart deployment/certifier -n ace`. Verified
  with `kubectl exec -n ace deploy/certifier -- grep _NO_FAULT_TAG /app/fault_analyzer/scripts/fault_bucketing.py`.
- **agent-sidecar** and **agentcert-install-agent**: both rebuilt (`agentcert/agent-sidecar:latest`
  from `agent-sidecar/Dockerfile`; `agentcert/agentcert-install-agent:latest` from
  `agent-charts/install-agent/Dockerfile`, build context = `agent-charts/` root — this image bakes
  in `agent-charts/charts/` at *build* time via `COPY charts/ /charts/`, so the Helm chart source
  edit does nothing live until this image is rebuilt) and `kind load`ed into `agentcert-alfred`.
  **NOT yet exercised** — nothing has redeployed the flash-agent Helm release since, so the
  currently-running `flash-agent` pod in `otel-demo` still has the OLD ConfigMap (no
  `CURRENT_FAULT_NAME` key) and the OLD sidecar image. Takes effect automatically the next time any
  flash-agent experiment actually runs (the Argo `install-agent` step does a fresh Helm
  install/upgrade using whatever's in the just-rebuilt `agentcert-install-agent` image).
- `argo-chaos` (the ServiceAccount fault-injection steps run as) already has a `cluster-admin`
  ClusterRoleBinding (`argo-chaos-admin-itbench`) — confirmed via `kubectl get clusterrolebindings`.
  The new `mark-fault-start`/`mark-fault-clear` steps' `kubectl patch configmap` calls need no new
  RBAC.

## 5. Explicitly rejected design (don't reintroduce it)

An earlier draft baked "5 runs" directly into the workflow — 5 scenarios × 5 repeated runs each,
25 total fault injections chained into one Argo Workflow via a Python generator script, so one UI
click would produce 5 statistical runs. **The user explicitly rejected this**: "I do not want you to
code a python behind the scene supplier. I want the multiple runs mechanism to be handled by the ui."
The shipped manifest does exactly **one pass** through the 5 scenarios. Repeated runs (for
statistical significance) are the user's/UI's job — click Run again on the registered experiment for
another independent workflow execution/trace. Do not add a run-count loop back into this manifest
without the user asking for it again.

## 6. Verification already done (not committed as test files — see note)

No pytest/deps available on this host outside the certifier pod. Verified by importing the real
`fault_bucketing.py` with `pydantic`/`openai`/etc. stubbed via `sys.modules` (so the actual shipped
logic runs, not a copy), and constructing a bare `FaultBucketingPipeline` instance directly
(`FaultBucketingPipeline.__new__(...)` + manually setting `active_faults`/`closed_faults`/agent
fields) to call `_bucket_by_current_fault_name()` against hand-built event lists. Scenarios checked,
all passing:

1. Legacy trace, no `current_fault_name` anywhere → true no-op, buckets stay empty.
2. Single fault window, ends on an explicit `""` clear → bucket closes correctly.
3. Untagged scaffolding event (e.g. `workflow-step: *`) mid-fault → does *not* split the open bucket.
4. **5 sequential occurrences of the same fault name → 5 distinct buckets**, not 1 (this is the case
   the whole fix exists for — the first implementation attempt failed this exact test, which is what
   led to the sentinel/tri-state design in §2).
5. Multiple *different* fault types sequentially → distinct buckets, correctly closed/reopened.
6. A matching `fault: *` span (when one does exist) enriches the Pass-0-created bucket's
   `ground_truth`/`sla`/target fields instead of spawning a duplicate bucket.

The sidecar side (`proxy.py`) was separately verified with a temp-dir-backed fake ConfigMap mount:
real fault name stamped correctly; explicit-empty-file case stamps `""` (not omitted); file-absent
case omits the key entirely (preserving old-workflow behavior); unrelated context keys' existing
env-var-fallback behavior is unchanged.

**Note**: these were throwaway scripts in a session-scoped scratchpad directory, not saved into the
repo. If you need to re-verify after further changes, recreate similar standalone tests using the
stub-and-import approach above (see `certifier/fault_analyzer/tests/test_fault_bucketing.py` for the
existing real test suite's conventions — its own execution is also blocked by missing deps outside
the pod, same constraint).

## 7. Known open items / what to check next

- **Sidecar image pull policy risk (unverified, real, not caused by this fix).** The sidecar
  container is installed with `--set sidecar.image.pullPolicy=Always` (inherited unchanged from the
  `flash-agent-comprehensive-30` manifest pattern into the new one). `.env`'s
  `INSTALL_AGENT_IMAGE_SOURCE=local` only controls the install-agent *workflow-step* image, not the
  sidecar's own pull policy. If this KinD node has outbound internet access, `Always` could silently
  pull the real published `agentcert/agent-sidecar:latest` from Docker Hub instead of using the
  locally-built fix. **Check this the first time the experiment actually runs**: `kubectl exec` into
  the running sidecar container and compare its image digest/behavior against the local build (does
  `proxy.py` inside it have the `CURRENT_FAULT_NAME` context key?).
- **`interFaultPause=90` in the manifest**: the kubelet's ConfigMap-volume sync lag is documented
  (Kubernetes docs) as up to ~60s worst case. 90s gives ~50% margin so the sidecar reliably sees the
  cleared `""` state before the *next* fault's `mark-fault-start` overwrites it — otherwise calls
  made right after a revert can get misattributed to the fault that just ended. Don't shrink this
  without re-checking that assumption.
- **Experiment not yet registered in ChaosCenter.** Attempted the same `saveChaosExperiment` GraphQL
  flow `setup.sh`'s `seed_flash_agent_comprehensive()` uses (see
  `OPEN_WEIGHT_CERTIFICATION_HANDOFF.md` §38) — blocked because `.env`'s `ADMIN_PASSWORD=litmus` is
  stale (the real admin password was changed via the UI at some point; this exact issue was already
  hit and fixed once before by resetting the bcrypt hash directly in `auth.users` — see that same
  doc's "Change 7" entry). Resetting it again was blocked by this session's own permission
  classifier (a direct credential-mutating Mongo write needs explicit user sign-off). **The user
  chose to upload `flash-agent-5scenario-manifest.json` themselves via ChaosCenter's own "Upload
  Experiment" UI feature** — do not attempt to fix the admin password or auto-register this
  experiment unless the user asks again; that decision was already made.
- **Nothing end-to-end has actually run yet.** The fix is verified in isolation (unit-style, per §6)
  and certifier is live, but no real fault-injection workflow has exercised the sidecar's new
  stamping or Pass 0's live behavior against a real Langfuse trace. First real run is the actual
  functional test.
- **Nothing committed to git.** All 4 changes are working-tree modifications across 3
  submodules (`agent-sidecar`, `agent-charts`, `certifier`) plus one new untracked file in the root
  repo. Don't assume any of this survives a `git checkout`/`git clean` without checking `git status`
  first in each of those directories.

## 8. Quick pointers

- ConfigMap: `flash-agent-metadata` in namespace `otel-demo`, mounted read-only at
  `/etc/agent/metadata` in both the `agent` and `agent-sidecar` containers of the flash-agent pod.
- Sidecar context keys live in `agent-sidecar/proxy.py`'s `_CONTEXT_KEYS` tuple.
- Certifier's Pass 0/1/2 orchestration is in `FaultBucketingPipeline.run()`,
  `certifier/fault_analyzer/scripts/fault_bucketing.py`.
- Fault names used in the new manifest's `mark-fault-start` calls must match the real
  `ChaosExperiment` CR names (e.g. `scaled-to-zero-kubernetes-workload`), not the Argo template's own
  short label (e.g. `itb-scenario-58-scaled-to-zero`) — these already match; if scenarios are ever
  added/changed, keep that distinction in mind.
