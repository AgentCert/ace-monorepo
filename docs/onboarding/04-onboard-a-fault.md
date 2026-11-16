---
title: "Onboarding a Fault"
parent: "Setup"
nav_order: 97
---

# Onboarding a Fault

> How to add a new custom fault to ACE: the controlled break that is injected into a
> target application while the agent under test tries to detect and repair it.

---

## 1. What a "fault" is in ACE

A fault is a **deliberate, repeatable, self-reverting break** of a running application.
ACE injects it, gives the agent a fixed window to notice and fix the problem, checks
whether the app recovered, then undoes the break. Every fault answers five questions:

| Question | Answered by |
|---|---|
| What do we break? | The **target**: namespace, label and kind, e.g. `sock-shop`, `name=catalogue`, `deployment` |
| How do we break it? | **Go code** compiled into a container image |
| For how long? | `TOTAL_CHAOS_DURATION`, in seconds |
| How do we undo it? | The same Go code restores the original state |
| Did it recover? | A **recovery check**, recorded as a LitmusChaos `ChaosResult` |

A fault is **YAML plus a Go program**. The YAML in `chaos-charts` says *what* to run;
the Go code in `litmus-go` *does* the damage. The two are linked only by the fault's
name.

### Two families of faults

| | **Upstream LitmusChaos faults** | **ITBench faults** |
|---|---|---|
| Folder | `chaos-charts/faults/kubernetes/` | `chaos-charts/faults/itbench/` |
| Examples | `pod-delete`, `pod-cpu-hog`, `node-drain` | `scaled-to-zero-kubernetes-workload`, `ingress-port-blocking-network-policy` |
| What they break | Runtime resources: CPU, memory, network, nodes | Configuration: replicas, images, probes, Services, NetworkPolicies |
| Image | `litmuschaos/go-runner`, built by LitmusChaos | `agentcert/itbench-experiment`, **built by ACE from `litmus-go/`** |

**Custom faults are ITBench faults.** ACE only copies the upstream `go-runner` image
(it is a `mirror` row in `deploy/images.txt`), so code changes for upstream faults
never reach the cluster. The ITBench image is rebuilt from your checkout on every
`setup.sh` run.

### Generic or application-specific

A fault is either **generic**, usable against any registered application, or
**application-specific**, tied to one application. The difference is a single entry in
`chaos-charts/faults/fault-capabilities.yaml` (Step 5). The Go code and runtime path are
the same.

---

## 2. Fault anatomy: what each file signifies

The YAML is the launch command; the Go code is the program. They are linked only by
strings: `-name`, env keys and `metadata.name`.

| File | Signifies | Read by, and when | What it controls |
|---|---|---|---|
| `litmus-go/experiments/itbench/<fault>/experiment/experiment.go` | **The program** | Compiled into `agentcert/itbench-experiment` at build time | Runs inside the fault pod: inject, hold, check, revert, then write the `ChaosResult` |
| `litmus-go/bin/itbench-experiment/main.go` | **The dispatcher** | Same image | Maps `-name <fault>` to your code |
| `chaos-charts/faults/itbench/<fault>/fault.yaml` | **The recipe** (ChaosExperiment) | chaos-runner, at run time | Which image to start, the `-name` that picks the Go code, default env values, required permissions |
| `chaos-charts/faults/itbench/<fault>/engine.yaml` | **One order** (ChaosEngine template) | Chaos Studio copies it; litmus-checker creates it; chaos-operator reads it | The target (`appinfo` becomes `TARGETS`), env overrides, probes, service account |
| `chaos-charts/faults/itbench/<fault>/<fault>.chartserviceversion.yaml` | **The UI card** | Chaos Studio and graphql, when you build and save | Name and settings form in Chaos Studio; values are validated on save. Never reaches the cluster |
| `chaos-charts/faults/itbench/<fault>/ground_truth.yaml` | **The answer key** | graphql, then Langfuse, then the certifier, after the run | How the agent is scored: ideal steps, ideal tool calls, time limits. The fault never reads it |
| `chaos-charts/faults/itbench/itbench.chartserviceversion.yaml` | **The fault list** | Chaos Studio | Which faults appear in the UI |
| `chaos-charts/faults/fault-capabilities.yaml` | **The catalog** | Chaos Studio and graphql | Generic or app-specific, and how the fault injects |

> Use the same name everywhere: the folder name, `metadata.name` in `fault.yaml`, the
> `-name` argument, the experiment name in `engine.yaml`, the `case` in `main.go`, and the
> catalog key. Lowercase with hyphens. The examples below use `my-fault`.

---

## 3. Step-by-step procedure

The quickest start is to copy an existing ITBench fault and change what differs.
`scaled-to-zero-kubernetes-workload` is the smallest one.

### Step 1 — Write the fault code (`litmus-go`)

Create `litmus-go/experiments/itbench/my-fault/experiment/experiment.go`:

```go
package experiment

import (
	"context"

	"github.com/litmuschaos/litmus-go/pkg/clients"
	itbench "github.com/litmuschaos/litmus-go/pkg/itbench/common"
	"github.com/litmuschaos/litmus-go/pkg/types"
)

// Run hands the fault to the shared ITBench runner, which handles the
// ChaosResult, probes, the hold window, abort handling and grading.
func Run(ctx context.Context, cs clients.ClientSets) {
	itbench.Run(ctx, cs, inject)
}

// inject is the only fault-specific part: what to break.
func inject(ctx context.Context, cs clients.ClientSets, chaosDetails *types.ChaosDetails) error {
	// Set the target workload's replicas to 0, hold, then restore the original value.
	return itbench.PatchWorkloadField(ctx, cs, chaosDetails, []string{"spec", "replicas"}, "/spec/replicas", int64(0))
}
```

The helpers in `litmus-go/pkg/itbench/common/` already find the target, remember the
original value, wait `TOTAL_CHAOS_DURATION`, run the recovery check and restore the
value. Most faults are one helper call:

| Helper | Breaks |
|---|---|
| `PatchWorkloadField` | A field on the target Deployment/StatefulSet (replicas, nodeSelector, dnsPolicy…) |
| `PatchContainerField` | A field on the target container (image, command, probe, resources…) |
| `PatchField` | A field on any other kind (Service, ConfigMap, HPA…) |
| `JSONPatch` + `HoldChaos` + `RevertContext` | Anything else, with your own inject and revert |

If you write your own logic, follow three rules:
- Read the target from `chaosDetails.AppDetail`, which comes from the `TARGETS` setting.
- Call `itbench.HoldChaos` between the inject and the revert.
- Revert with `itbench.RevertContext()`, so the revert still runs if someone stops the workflow.

### Step 2 — Register it in the dispatcher (`litmus-go`)

In `litmus-go/bin/itbench-experiment/main.go`, add one import and one `case`:

```go
myFault "github.com/litmuschaos/litmus-go/experiments/itbench/my-fault/experiment"
...
case "my-fault":
	myFault.Run(ctx, cs)
```

### Step 3 — Create the fault folder (`chaos-charts`)

Copy `chaos-charts/faults/itbench/scaled-to-zero-kubernetes-workload/` to
`chaos-charts/faults/itbench/my-fault/`, rename the CSV to
`my-fault.chartserviceversion.yaml`, and update the names.

**`fault.yaml`**: which image and fault to run, and its defaults.

```yaml
kind: ChaosExperiment
metadata:
  name: my-fault
spec:
  definition:
    image: "agentcert/itbench-experiment:dev"
    command: [/itbench-experiment]
    args: [-name, my-fault]          # must match the case in main.go
    env:
      - name: TOTAL_CHAOS_DURATION
        value: "300"
```

**`engine.yaml`**: the target and setting overrides used when the fault runs.

```yaml
kind: ChaosEngine
spec:
  appinfo:
    appns: ''                        # filled in from Chaos Studio
    applabel: ''
    appkind: 'deployment'
  chaosServiceAccount: litmus-admin
  experiments:
    - name: my-fault                 # must match metadata.name in fault.yaml
      spec:
        components:
          env:
            - name: TOTAL_CHAOS_DURATION
              value: '300'
```

**`my-fault.chartserviceversion.yaml`**: the UI card and settings form.

```yaml
kind: ChartServiceVersion
metadata:
  name: my-fault
spec:
  displayName: My Fault
  configurations:                    # each key must exist in fault.yaml env
    - key: TOTAL_CHAOS_DURATION
      label: Duration (seconds)
      type: integer
      min: 1
      required: true
```

Settings left out of `configurations` stay locked to their `fault.yaml` defaults. See
[Fault configuration](../platform/fault-configuration.md) for the field types.

**`ground_truth.yaml`**: copy it from the fault you started from, and rewrite the
symptoms, remediation, ideal steps and SLA for your fault.

**Icon**: add any PNG as `chaos-charts/faults/itbench/icons/my-fault.png`.

### Step 4 — Add it to the fault list (`chaos-charts`)

`chaos-charts/faults/itbench/itbench.chartserviceversion.yaml`, under `spec.faults`.
This makes the fault visible in Chaos Studio:

```yaml
  - name: my-fault
    description: Scale workload to zero.
    displayName: My Fault
```

`chaos-charts/faults/itbench/itbench.package.yaml`, under `faults`:

```yaml
- name: my-fault
  CSV: my-fault.chartserviceversion.yaml
  desc: my-fault
```

### Step 5 — Add it to the catalog (`chaos-charts`)

`chaos-charts/faults/fault-capabilities.yaml`, under `spec.faults`. Also increase
`metadata.faultCount` by one.

**Generic fault**, offered for every registered application:

```yaml
    my-fault:
      category: itbench
      classification: generic
      mechanism: k8s-api
      scope: pod
      concurrency: parallel-safe
      targetRequirements: {}
      verified: code
```

**Application-specific fault**, offered and accepted only for one application:

```yaml
    my-fault:
      category: itbench
      classification: application-specific
      mechanism: k8s-api
      scope: pod
      concurrency: parallel-safe
      targetRequirements:
        workloadKinds: [deployment]
        requiredApp: sock-shop          # an application name from app-charts/charts/applications.chartserviceversion.yaml
        requiredServices: [catalogue]   # optional: limits the target picker to these services
      verified: code
```

For an app-specific fault, also put the app's defaults in `engine.yaml` (for example
`appns: 'sock-shop'`, `applabel: 'name=catalogue'`) and any app-specific settings in
`fault.yaml`.

### Step 6 — Validate

From the monorepo root:

```bash
# Go code compiles and the shared ITBench tests pass
(cd litmus-go && go build ./bin/itbench-experiment && go test ./pkg/itbench/...)

# Fault list, catalog, folders and dispatcher agree (no cluster needed)
python3 scripts/validate-fault-capabilities.py
# expect: OK — N fault(s) checked, 0 errors
```

### Step 7 — Deploy and run it

```bash
./scripts/setup.sh --restart
```

This rebuilds the hub-bundle image (the fault catalog the UI reads), rebuilds
`agentcert/itbench-experiment` from your `litmus-go/`, and restarts graphql. Open
**Chaos Studio**: the fault appears under **ITBench**. Add it to an experiment, save,
run, and follow it:

```bash
kubectl -n litmus get pods -w                  # the <fault>-xxxxx pod appears
kubectl -n litmus logs -f <fault-pod>          # "Injecting: …" and "Reverting: …" lines
kubectl -n litmus get chaosresult -o wide      # the verdict
```

When it works, commit in `litmus-go` and `chaos-charts`, push both to their AgentCert
branches, and bump both submodule pointers in the monorepo.

---

## 4. Checklist

- [ ] `litmus-go/experiments/itbench/my-fault/experiment/experiment.go` with `Run` and `inject`
- [ ] Import and `case "my-fault"` in `litmus-go/bin/itbench-experiment/main.go`
- [ ] `chaos-charts/faults/itbench/my-fault/` with `fault.yaml`, `engine.yaml`, `my-fault.chartserviceversion.yaml`, `ground_truth.yaml`
- [ ] Icon `chaos-charts/faults/itbench/icons/my-fault.png`
- [ ] Entries in `itbench.chartserviceversion.yaml` and `itbench.package.yaml`
- [ ] Catalog entry in `fault-capabilities.yaml` and `faultCount` updated
- [ ] `validate-fault-capabilities.py` reports 0 errors
- [ ] `setup.sh --restart`, and the fault shows in Chaos Studio and runs

---

## 5. Common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| Fault missing from Chaos Studio | Not listed in `itbench.chartserviceversion.yaml`, or setup not re-run | Add it (Step 4), then `setup.sh --restart` |
| Fault pod logs `Unsupported itbench chaos experiment` | `-name` has no matching `case`, or the image wasn't rebuilt | Add the `case` (Step 2), then `setup.sh --restart` |
| Save rejected with an experiment-name error | `engine.yaml` experiment name differs from `metadata.name` in `fault.yaml` | Use one name everywhere |
| `no target resolved: TARGETS env var was empty` | The experiment has no target label | Pick a target service in Chaos Studio, or set `applabel` in `engine.yaml` |
| Run always passes | The fault leaves pods healthy (e.g. a NetworkPolicy), so the built-in check (`readyReplicas ≥ 1`) never fails | Add an EOT probe to the experiment's ChaosEngine that checks your specific damage is gone |
| Target left broken after a stopped run | The revert used `ctx` instead of `itbench.RevertContext()` | Revert with `RevertContext()` |
