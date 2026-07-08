# Kubernetes Resources Per Run

**Source:** Spec §20  
**Date:** 2026-07-07

This document describes every Kubernetes resource created for each experiment run, the namespace
it lives in, its lifecycle, and how cleanup is triggered.

---

## Resource Table

| Resource | Kind | Namespace | Label | Lifecycle |
|----------|------|-----------|-------|-----------|
| `app-<runID>` | Helm Release | `<appName>-<runID>` | `ace.io/run-id: <runID>` | Created at `install-app-tmpl` step; deleted by `teardown-tmpl` |
| `agent-<runID>` | Helm Release | `<appName>-<runID>` | `ace.io/run-id: <runID>` | Created at `install-agent-tmpl` step; deleted by `teardown-tmpl` |
| `ace-agent-secret-<runID>` | Secret | `litmus` | `ace.io/run-id: <runID>` | Created by `submitRun` resolver before Argo submission; deleted by `teardown-tmpl` |
| `<expName>-<runID>` | Argo Workflow | `litmus` | `ace.io/run-id: <runID>` | Created by `submitRun` resolver; retained for 7 days, then garbage-collected by Argo TTL |
| `<stepName>-<runID>` | ChaosEngine | `litmus` | `ace.io/run-id: <runID>` | Created per fault step by `litmus-fault-tmpl`; deleted after the step's chaos duration completes |
| `load-test-<runID>` | Job | `<appName>-<runID>` | `ace.io/run-id: <runID>` | Created at load-test start (if `app.yaml` defines `loadTest`); deleted by `teardown-tmpl` |
| `<appName>-<runID>` | Namespace | cluster | `ace.io/run-id: <runID>` | Created during `install-app-tmpl`; deleted by `teardown-tmpl` via `kubectl delete namespace` |

---

## Naming Convention

All resource names follow the pattern `<resource-type>-<runID>` where `runID` is a short UUID
(e.g., `run-ab12cd34`). The full resource name is:

- Argo Workflow: `<truncated-experiment-name>-<runID>` (max 63 characters total)
- ChaosEngine per step: `<step-name>-<runID>` (max 63 characters total)
- Secrets: `ace-agent-secret-<runID>`
- App namespace: `<appName>-<runID>` (e.g., `sock-shop-run-ab12cd34`)

The `<truncated-experiment-name>` is truncated to 40 characters if needed to keep the total
Argo Workflow name within the 63-character Kubernetes resource name limit.

---

## Labels Applied to All Resources

All resources created for a run carry the following labels for bulk operations:

```yaml
labels:
  ace.io/run-id: "<runID>"
  ace.io/experiment-name: "<experimentName>"
  ace.io/experiment-version: "<definitionVersion>"
  ace.io/agent-name: "<agentName>"
```

**Bulk cleanup by label selector:**
```bash
kubectl delete all,secrets,workflows,chaosengines -l ace.io/run-id=<runID> -n litmus
kubectl delete namespace <appName>-<runID>
```

---

## Lifecycle Detail

### Argo Workflow

**Created by:** `submitRun` resolver, immediately after K8s Secret creation.

**Created in:** `litmus` namespace.

**Cleaned up by:** Argo TTL controller. The workflow YAML includes:
```yaml
spec:
  ttlStrategy:
    secondsAfterCompletion: 604800  # 7 days
    secondsAfterFailure: 604800
    secondsAfterSuccess: 604800
```

**Manual cleanup:**
```bash
kubectl delete workflow <expName>-<runID> -n litmus
```

---

### ChaosEngine

**Created by:** `litmus-fault-tmpl` Argo template — one ChaosEngine per `type: fault` step, one
per fault in `type: parallel-fault` steps.

**Created in:** `litmus` namespace.

**Cleaned up by:** `litmus-fault-tmpl` container deletes the ChaosEngine after
`CHAOS_DURATION` seconds. LitmusChaos also runs automatic cleanup when a ChaosEngine transitions
to the `Completed` phase.

**If teardown fails (partial failure):** ChaosEngine remains. The background cleanup job retries
deletion of all resources with label `ace.io/run-id: <runID>` every 10 minutes.

---

### Agent Secret

**Created by:** `submitRun` resolver — before Argo Workflow submission.

**Created in:** `litmus` namespace.

**Contents:** Agent secrets from `secretOverrides` in the `submitRun` call. These are injected
into the agent pod via `envFrom.secretRef`.

**Cleaned up by:** `teardown-tmpl` runs `kubectl delete secret ace-agent-secret-<runID> -n litmus`.

**Security:** The secret is scoped to the `litmus` namespace. Network policies prevent the
agent pod in `<appName>-<runID>` from directly reading K8s secrets from `litmus`. The secret
is mounted as environment variables into the agent pod only.

---

### App Namespace

**Created by:** `helm upgrade --install` in `install-app-tmpl` using `--create-namespace`.

**Contents:** All app Helm release resources (Deployments, Services, ConfigMaps, PVCs if needed).

**Cleaned up by:** `teardown-tmpl` runs `kubectl delete namespace <appName>-<runID>` which
cascade-deletes all resources in the namespace.

**Network policy:** A default network policy is applied to the namespace that:
- Allows ingress from `litmus` namespace (ChaosEngine needs to reach the app)
- Denies egress to `kube-system` namespace
- Denies egress to other `<appName>-<runID>` namespaces (run isolation)

---

## Teardown Failure Handling

When `teardown-tmpl` fails (e.g., Helm uninstall times out), the resources remain orphaned.
The namespace is tagged:

```bash
kubectl annotate namespace <appName>-<runID> ace.io/cleanup-needed=true
```

A background cleanup CronJob (`ace-cleanup-job`) running every 10 minutes checks for namespaces
with `ace.io/cleanup-needed: true` and retries cleanup:

```bash
kubectl delete namespace -l ace.io/cleanup-needed=true
```

The CronJob is defined at `agent-charts/templates/cleanup-cronjob.yaml` (to be created as part
of the Charts implementation of this plan).

---

## RBAC for ChaosEngine

The `litmus-admin` ServiceAccount is used by all ChaosEngine CRs. It has the following
cluster-scoped permissions:
- `get`, `list`, `watch`, `delete` on `pods` in any namespace
- `get`, `list`, `watch` on `deployments`, `replicasets` in any namespace
- `create`, `delete` on `chaosengines.litmuschaos.io`

**Blast radius protection:** The ChaosEngine's `appinfo.appns` field restricts the chaos to
the app's namespace. The `litmus-admin` ServiceAccount's pod-targeting RBAC is intentionally
permissive (cluster-wide) so LitmusChaos can target any namespace. The protection is at the
ChaosEngine spec level, not the RBAC level.

**Future hardening:** Per-run RBAC (Phase 2) will create a scoped ServiceAccount per run with
only the permissions needed for the declared faults.

---

## Quick Reference: What to Clean Up After a Failed Run

```bash
export RUN_ID="run-ab12cd34"
export APP_NS="sock-shop-${RUN_ID}"

# Delete Argo Workflow
kubectl delete workflow -n litmus -l ace.io/run-id=$RUN_ID

# Delete ChaosEngines
kubectl delete chaosengines -n litmus -l ace.io/run-id=$RUN_ID

# Delete agent secret
kubectl delete secret ace-agent-secret-$RUN_ID -n litmus 2>/dev/null

# Delete app namespace (cascade-deletes all app resources)
kubectl delete namespace $APP_NS 2>/dev/null

# Verify clean
kubectl get all,secrets,workflows,chaosengines -n litmus -l ace.io/run-id=$RUN_ID
kubectl get namespace $APP_NS 2>/dev/null
```
