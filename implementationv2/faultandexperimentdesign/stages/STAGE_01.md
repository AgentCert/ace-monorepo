# Stage 01: Fault Catalog Directory Structure & Seed Faults

**Phase:** 0 — Fault Catalog  
**Status:** Not Started  
**Estimated Effort:** 0.5 day  
**Date Added:** 2026-07-07  

---

## Objectives

1. Create the `catalog/faults/` directory tree with subdirectories for `general/` and `domains/`.
2. Write five seed `fault.yaml` files covering all three scopes (general, domain, app-specific).
3. Update `catalog/validate.sh` with a `fault validate` subcommand that schema-checks a `fault.yaml`.
4. Confirm that running `ace fault validate` against each seed fault produces no errors.

---

## Current State Analysis

### What Exists
- `catalog/` directory exists at `/srv/projects/ace-monorepo/catalog/` with app-related content.
- No `catalog/faults/` directory exists yet.
- `catalog/validate.sh` may or may not have a `fault` subcommand — check with:
  ```bash
  ls /srv/projects/ace-monorepo/catalog/
  grep -n "fault" /srv/projects/ace-monorepo/catalog/validate.sh 2>/dev/null || echo "not found"
  ```

### What Is Needed
- `catalog/faults/general/` — infrastructure-level faults usable by any app
- `catalog/faults/domains/<domain>/` — domain-specific fault directories
- `catalog/apps/official/sock-shop/faults/` — app-specific fault example
- Five complete `fault.yaml` files (see §Implementation Tasks)
- `catalog/validate.sh` updated with `fault validate` subcommand

---

## Pre-Stage Verification

Run these checks before starting. All must pass:

```bash
# 1. Confirm catalog/ root exists
ls /srv/projects/ace-monorepo/catalog/

# 2. Confirm sock-shop app.yaml exists (needed for the app-specific fault to be meaningful)
ls /srv/projects/ace-monorepo/catalog/apps/official/sock-shop/app.yaml

# 3. Confirm no fault.yaml already exists that would conflict
find /srv/projects/ace-monorepo/catalog -name "fault.yaml" 2>/dev/null | head -5
```

If the sock-shop `app.yaml` does not exist, create a minimal stub for it referencing the
`carts-db-corrupt` fault (App Onboarding will flesh it out later).

---

## Implementation Tasks

### Task 1: Create Directory Structure

```bash
mkdir -p /srv/projects/ace-monorepo/catalog/faults/general/pod-delete
mkdir -p /srv/projects/ace-monorepo/catalog/faults/general/cpu-hog
mkdir -p /srv/projects/ace-monorepo/catalog/faults/domains/cloud-native/pod-oom-kill
mkdir -p /srv/projects/ace-monorepo/catalog/faults/domains/telecom/snmp-trap-flood
mkdir -p /srv/projects/ace-monorepo/catalog/apps/official/sock-shop/faults/carts-db-corrupt
```

### Task 2: Write `catalog/faults/general/pod-delete/fault.yaml`

```yaml
apiVersion: ace.io/v1
kind: FaultCatalogEntry

metadata:
  name: pod-delete
  displayName: "Pod Delete"
  version: "1.0.0"
  tier: official
  scope: general
  domain: null
  targetApp: null
  tags: [resilience, availability, pod-lifecycle]
  maintainers:
    - name: "ACE Team"
      email: "ace@example.io"

spec:
  description:
    short: "Forcefully deletes one or more target pods"
    long: |
      Injects pod failure by deleting the target pod(s). Kubernetes reschedules them.
      Used to test auto-recovery, readiness probe behavior, and the agent's ability to
      detect pod churn and verify recovery. The chaos lasts for CHAOS_DURATION seconds
      during which pods are periodically deleted.
    suitableFor:
      - "Stateless services backed by Kubernetes Deployments"
      - "Testing agent detection of pod unavailability events"
      - "Verifying readiness probe and liveness probe behavior"
    notSuitableFor:
      - "StatefulSets where pod identity matters without PVC snapshot support"
      - "Services with very long startup times (>CHAOS_DURATION)"

  implementation:
    type: litmus
    chaosKind: ChaosEngine
    experimentRef: pod-delete
    namespace: litmus

  targetSpec:
    required: true
    resolutionMode: microservice-label

  parameters:
    - key: CHAOS_DURATION
      displayName: "Chaos Duration"
      type: integer
      unit: seconds
      default: "30"
      min: 10
      max: 600
      required: true
      description: "How long the chaos lasts. Pods are deleted repeatedly within this window."
      litmusEnv: TOTAL_CHAOS_DURATION

    - key: PODS_AFFECTED_PERC
      displayName: "% Pods Affected"
      type: integer
      unit: percent
      default: "50"
      min: 1
      max: 100
      required: false
      description: "What percentage of matching pods to delete in each iteration."
      litmusEnv: PODS_AFFECTED_PERC

    - key: FORCE_DELETE
      displayName: "Force Delete"
      type: boolean
      default: "false"
      required: false
      description: "Skip graceful termination (SIGTERM) and force-kill immediately via SIGKILL."
      litmusEnv: FORCE

  compatibility:
    targetDomains: ["*"]
    incompatibleApps: []
    requiredCapabilities: []

  observability:
    expectedSymptoms:
      - "Target pod transitions to Terminating state"
      - "Deployment ReplicaSet creates a replacement pod"
      - "HTTP 503 or connection refused on target service endpoints during transition"
      - "kube_pod_status_ready metric drops to 0 for affected pods"
    expectedAlerts:
      - KubePodNotReady
      - KubeDeploymentReplicasMismatch
    detectionWindowSecs: 60

  groundTruth:
    category: availability
    impact: high
    detectWithinSecs: 60
    mitigateWithinSecs: 120
    detectionHints:
      - "kubectl get pods -n <app-ns>: count drops then recovers"
      - "Prometheus: kube_pod_status_ready drops to 0 for target label"
      - "Langfuse: agent tool call to list_pods or get_deployment_status"
    remediationHints:
      - "Verify Deployment replicas are restored to desired count"
      - "Check that HPA is not preventing scale-up"
      - "Confirm readiness probe passes on replacement pod before marking healthy"
```

### Task 3: Write `catalog/faults/general/cpu-hog/fault.yaml`

```yaml
apiVersion: ace.io/v1
kind: FaultCatalogEntry

metadata:
  name: cpu-hog
  displayName: "CPU Hog"
  version: "1.0.0"
  tier: official
  scope: general
  domain: null
  targetApp: null
  tags: [performance, resource-saturation, cpu]
  maintainers:
    - name: "ACE Team"
      email: "ace@example.io"

spec:
  description:
    short: "Saturates CPU on target pod(s) to simulate high load"
    long: |
      Consumes a configurable number of CPU cores on the target pod by running a
      stress workload as a sidecar. Used to test agent detection of CPU saturation
      events and remediation through scaling or alerting.
    suitableFor:
      - "Services that export CPU utilization metrics to Prometheus"
      - "Testing HPA scale-out behavior under CPU load"
      - "Agent detection of resource saturation events"
    notSuitableFor:
      - "Single-core pods where any CPU stress immediately causes OOM"

  implementation:
    type: litmus
    chaosKind: ChaosEngine
    experimentRef: pod-cpu-hog
    namespace: litmus

  targetSpec:
    required: true
    resolutionMode: microservice-label

  parameters:
    - key: CPU_CORES
      displayName: "CPU Cores"
      type: integer
      unit: cores
      default: "1"
      min: 1
      max: 8
      required: true
      description: "Number of CPU cores to consume on the target pod."
      litmusEnv: CPU_CORES

    - key: CHAOS_DURATION
      displayName: "Chaos Duration"
      type: integer
      unit: seconds
      default: "60"
      min: 10
      max: 600
      required: true
      description: "Duration for which CPU stress is applied."
      litmusEnv: TOTAL_CHAOS_DURATION

    - key: PODS_AFFECTED_PERC
      displayName: "% Pods Affected"
      type: integer
      unit: percent
      default: "100"
      min: 1
      max: 100
      required: false
      description: "Percentage of matching pods to target."
      litmusEnv: PODS_AFFECTED_PERC

  compatibility:
    targetDomains: ["*"]
    incompatibleApps: []
    requiredCapabilities: []

  observability:
    expectedSymptoms:
      - "container_cpu_usage_seconds_total rises sharply on target pod"
      - "Pod CPU throttling metric (container_cpu_cfs_throttled_seconds_total) increases"
      - "Response latency on target service increases proportionally"
    expectedAlerts:
      - KubePodCPUThrottlingHigh
      - NodeCPUSaturation
    detectionWindowSecs: 30

  groundTruth:
    category: performance
    impact: medium
    detectWithinSecs: 30
    mitigateWithinSecs: 120
    detectionHints:
      - "Prometheus: container_cpu_usage_seconds_total spike on target pod label"
      - "kubectl top pods -n <app-ns>: shows CPU near limit"
      - "Agent tool call: query_prometheus with cpu_usage metric"
    remediationHints:
      - "Scale Deployment replicas to distribute load"
      - "Trigger HPA if configured with CPU utilization target"
      - "Confirm CPU normalizes after chaos window ends"
```

### Task 4: Write `catalog/faults/domains/cloud-native/pod-oom-kill/fault.yaml`

```yaml
apiVersion: ace.io/v1
kind: FaultCatalogEntry

metadata:
  name: pod-oom-kill
  displayName: "Pod OOM Kill"
  version: "1.0.0"
  tier: official
  scope: domain
  domain: cloud-native
  targetApp: null
  tags: [memory, oom, availability, cloud-native]
  maintainers:
    - name: "ACE Team"
      email: "ace@example.io"

spec:
  description:
    short: "Triggers an OOM kill on the target pod by exhausting memory"
    long: |
      Injects memory consumption on the target pod until the kernel OOM killer
      terminates it. Tests the agent's ability to distinguish an OOM event from
      a voluntary restart, detect the OOMKilled exit reason, and verify that
      the pod restarts with appropriate memory limits or triggers an alert.
    suitableFor:
      - "Apps with memory-limit-constrained pods (resources.limits.memory set)"
      - "Testing agent detection of OOMKilled container exit reason"
    notSuitableFor:
      - "Pods without memory limits set — will consume node memory unboundedly"
      - "DaemonSets (OOM kill may disrupt node-level logging/monitoring)"

  implementation:
    type: litmus
    chaosKind: ChaosEngine
    experimentRef: pod-memory-hog
    namespace: litmus

  targetSpec:
    required: true
    resolutionMode: microservice-label

  parameters:
    - key: MEMORY_CONSUMPTION
      displayName: "Memory Consumption (MB)"
      type: integer
      unit: megabytes
      default: "500"
      min: 100
      max: 4096
      required: true
      description: "Memory in MB to consume on the target pod until OOM kill is triggered."
      litmusEnv: MEMORY_CONSUMPTION

    - key: CHAOS_DURATION
      displayName: "Chaos Duration"
      type: integer
      unit: seconds
      default: "30"
      min: 10
      max: 300
      required: true
      description: "Maximum duration before fault is cleaned up if OOM kill does not occur."
      litmusEnv: TOTAL_CHAOS_DURATION

  compatibility:
    targetDomains: [cloud-native]
    incompatibleApps: []
    requiredCapabilities: []

  observability:
    expectedSymptoms:
      - "Pod restarts with exit reason OOMKilled (exit code 137)"
      - "kube_pod_container_status_last_terminated_reason == OOMKilled"
      - "container_memory_usage_bytes spikes then pod disappears"
    expectedAlerts:
      - KubePodCrashLooping
      - KubeContainerOOMKilled
    detectionWindowSecs: 45

  groundTruth:
    category: availability
    impact: high
    detectWithinSecs: 45
    mitigateWithinSecs: 90
    detectionHints:
      - "kubectl describe pod <target-pod>: Last State reason: OOMKilled"
      - "Prometheus: kube_pod_container_status_last_terminated_reason{reason='OOMKilled'}"
      - "Agent tool call: get_pod_events or describe_pod"
    remediationHints:
      - "Increase memory limits in Deployment spec"
      - "Add or tune VPA (Vertical Pod Autoscaler) for the target service"
      - "Confirm pod returns to Running state after restart"
```

### Task 5: Write `catalog/faults/domains/telecom/snmp-trap-flood/fault.yaml`

```yaml
apiVersion: ace.io/v1
kind: FaultCatalogEntry

metadata:
  name: snmp-trap-flood
  displayName: "SNMP Trap Flood"
  version: "1.0.0"
  tier: official
  scope: domain
  domain: telecom
  targetApp: null
  tags: [telecom, snmp, alert-storm, observability]
  maintainers:
    - name: "ACE Team"
      email: "ace@example.io"

spec:
  description:
    short: "Floods the SNMP trap receiver with high-volume synthetic traps"
    long: |
      Generates a high-volume synthetic SNMP trap flood targeting the app's
      SNMP trap receiver endpoint. Used to test the agent's ability to
      distinguish a genuine NF alarm from noise, triage alert storms without
      false-positive remediation, and correctly identify the trap flood as
      an injected condition rather than a real network failure.
    suitableFor:
      - "Telecom apps with an SNMP trap receiver (port 162/UDP)"
      - "Testing agent storm-suppression or trap-deduplication behavior"
    notSuitableFor:
      - "Apps without an SNMP trap receiver"
      - "Environments where UDP port 162 is firewalled from the fault injector pod"

  implementation:
    type: script
    image: "aceio/snmp-fault-injector:1.0.0"
    command: ["/inject.sh"]
    args: []
    envFrom: []

  targetSpec:
    required: true
    resolutionMode: microservice-label

  parameters:
    - key: TRAP_RATE
      displayName: "Trap Rate (traps/sec)"
      type: integer
      unit: "traps/second"
      default: "100"
      min: 10
      max: 10000
      required: true
      description: "Number of SNMP traps per second to send to the target receiver."
      litmusEnv: TRAP_RATE

    - key: CHAOS_DURATION
      displayName: "Chaos Duration"
      type: integer
      unit: seconds
      default: "60"
      min: 15
      max: 300
      required: true
      description: "Duration for which the trap flood is sustained."
      litmusEnv: CHAOS_DURATION

    - key: TARGET_OID
      displayName: "Target OID"
      type: string
      default: "1.3.6.1.4.1.99999.1.1"
      required: false
      description: "OID to include in the synthetic traps. Defaults to ACE test OID."
      litmusEnv: TARGET_OID

  compatibility:
    targetDomains: [telecom]
    incompatibleApps: []
    requiredCapabilities: [snmp-trap-receiver]

  observability:
    expectedSymptoms:
      - "SNMP trap receiver queue depth increases sharply"
      - "Alert manager ingestion rate spikes"
      - "Log volume on trap receiver pod increases"
    expectedAlerts:
      - SNMPTrapFloodDetected
    detectionWindowSecs: 30

  groundTruth:
    category: availability
    impact: medium
    detectWithinSecs: 30
    mitigateWithinSecs: 120
    detectionHints:
      - "Trap receiver pod logs: high ingestion rate"
      - "Agent tool call: query_snmp_receiver_stats or check_alertmanager_queue"
    remediationHints:
      - "Apply trap rate-limiting at the SNMP receiver"
      - "Filter synthetic OID from alert pipeline"
      - "Confirm trap flood stops after CHAOS_DURATION elapses"
```

### Task 6: Write `catalog/apps/official/sock-shop/faults/carts-db-corrupt/fault.yaml`

```yaml
apiVersion: ace.io/v1
kind: FaultCatalogEntry

metadata:
  name: carts-db-corrupt
  displayName: "Carts DB Corruption"
  version: "1.0.0"
  tier: official
  scope: app-specific
  domain: null
  targetApp: sock-shop
  tags: [data-integrity, mongodb, sock-shop, cart-service]
  maintainers:
    - name: "ACE Team"
      email: "ace@example.io"

spec:
  description:
    short: "Corrupts documents in the carts MongoDB to simulate data-integrity failure"
    long: |
      Runs a one-shot MongoDB job that writes malformed BSON documents to the
      carts collection in the Sock Shop carts-db instance. Simulates a data
      corruption event where the carts service returns errors on cart retrieval,
      causing the frontend to show error states for affected users.
    suitableFor:
      - "Sock Shop only — targets the MongoDB instance named 'carts-db'"
      - "Testing agent detection of data-integrity errors in cart operations"
    notSuitableFor:
      - "Any other app — the carts-db service name is Sock Shop specific"

  implementation:
    type: script
    image: "aceio/mongo-fault-injector:1.0.0"
    command: ["/corrupt-carts.sh"]
    args: []
    envFrom: []

  targetSpec:
    required: true
    resolutionMode: microservice-label

  parameters:
    - key: CORRUPT_PERCENTAGE
      displayName: "% Documents to Corrupt"
      type: integer
      unit: percent
      default: "10"
      min: 1
      max: 50
      required: true
      description: "Percentage of documents in the carts collection to corrupt."
      litmusEnv: CORRUPT_PERCENTAGE

    - key: CHAOS_DURATION
      displayName: "Chaos Duration"
      type: integer
      unit: seconds
      default: "60"
      min: 15
      max: 300
      required: true
      description: "Duration before corrupted documents are restored to valid state."
      litmusEnv: CHAOS_DURATION

  compatibility:
    targetDomains: [cloud-native]
    incompatibleApps: []
    requiredCapabilities: []

  observability:
    expectedSymptoms:
      - "HTTP 500 errors on GET /carts/<id> endpoint"
      - "carts-service error log: 'Failed to decode cart document'"
      - "Frontend shows 'Unable to load cart' for affected user sessions"
    expectedAlerts:
      - CartsServiceErrorRateHigh
      - MongoDBDocumentCorruptionDetected
    detectionWindowSecs: 30

  groundTruth:
    category: data-integrity
    impact: medium
    detectWithinSecs: 30
    mitigateWithinSecs: 90
    detectionHints:
      - "HTTP 500 rate on /carts/* endpoints rises above 5%"
      - "Agent tool call: check_service_error_rate or query_logs for 'Failed to decode'"
      - "MongoDB: db.carts.find({'$where': 'this.items == null'}) returns results"
    remediationHints:
      - "Run db.carts.deleteMany({'items': null}) to remove corrupted documents"
      - "Verify HTTP 500 rate returns to baseline"
      - "Confirm no corrupted documents remain in collection"
```

### Task 7: Update `catalog/validate.sh`

Add a `fault validate` subcommand that checks a `fault.yaml` against required fields:

```bash
#!/usr/bin/env bash
# catalog/validate.sh
# Usage:
#   ./validate.sh app <path-to-app.yaml>
#   ./validate.sh fault <path-to-fault.yaml>

set -euo pipefail

CMD="${1:-help}"
TARGET="${2:-}"

validate_fault() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "ERROR: File not found: $file" >&2
    exit 1
  fi

  echo "Validating fault: $file"

  # Check required top-level keys
  for key in apiVersion kind metadata spec; do
    if ! grep -q "^${key}:" "$file"; then
      echo "ERROR: Missing required top-level key: $key" >&2
      exit 1
    fi
  done

  # Check apiVersion
  if ! grep -q "^apiVersion: ace.io/v1" "$file"; then
    echo "ERROR: apiVersion must be 'ace.io/v1'" >&2
    exit 1
  fi

  # Check kind
  if ! grep -q "^kind: FaultCatalogEntry" "$file"; then
    echo "ERROR: kind must be 'FaultCatalogEntry'" >&2
    exit 1
  fi

  # Check metadata fields
  for field in name displayName version tier scope; do
    if ! grep -q "  ${field}:" "$file"; then
      echo "ERROR: Missing metadata field: $field" >&2
      exit 1
    fi
  done

  # Check valid scope
  scope=$(grep "  scope:" "$file" | awk '{print $2}')
  if [[ "$scope" != "general" && "$scope" != "domain" && "$scope" != "app-specific" ]]; then
    echo "ERROR: Invalid scope '$scope'. Must be: general, domain, app-specific" >&2
    exit 1
  fi

  # For domain scope, domain must be non-null
  if [[ "$scope" == "domain" ]]; then
    domain=$(grep "  domain:" "$file" | awk '{print $2}')
    if [[ "$domain" == "null" ]]; then
      echo "ERROR: scope=domain requires a non-null domain value" >&2
      exit 1
    fi
  fi

  # For app-specific scope, targetApp must be non-null
  if [[ "$scope" == "app-specific" ]]; then
    target=$(grep "  targetApp:" "$file" | awk '{print $2}')
    if [[ "$target" == "null" ]]; then
      echo "ERROR: scope=app-specific requires a non-null targetApp value" >&2
      exit 1
    fi
  fi

  # Check spec sections
  for section in description implementation parameters compatibility groundTruth; do
    if ! grep -q "  ${section}:" "$file"; then
      echo "ERROR: Missing spec section: $section" >&2
      exit 1
    fi
  done

  echo "OK: $file is valid"
}

case "$CMD" in
  fault)
    validate_fault "$TARGET"
    ;;
  help|--help|-h)
    echo "Usage:"
    echo "  $0 app <path-to-app.yaml>     Validate an app.yaml"
    echo "  $0 fault <path-to-fault.yaml> Validate a fault.yaml"
    ;;
  *)
    echo "Unknown command: $CMD" >&2
    exit 1
    ;;
esac
```

---

## Verification Criteria

### Must Pass

1. `catalog/faults/` directory tree exists with all five fault.yaml files:
   ```bash
   find /srv/projects/ace-monorepo/catalog/faults -name "fault.yaml" | wc -l
   # Expected: 4 (pod-delete, cpu-hog, pod-oom-kill, snmp-trap-flood)
   find /srv/projects/ace-monorepo/catalog/apps/official/sock-shop/faults -name "fault.yaml" | wc -l
   # Expected: 1 (carts-db-corrupt)
   ```

2. Each fault.yaml passes the `fault validate` script:
   ```bash
   bash /srv/projects/ace-monorepo/catalog/validate.sh fault \
     /srv/projects/ace-monorepo/catalog/faults/general/pod-delete/fault.yaml
   # Expected: "OK: ... is valid"
   ```

3. All fault.yamls are valid YAML (no parse errors):
   ```bash
   for f in $(find /srv/projects/ace-monorepo/catalog -name "fault.yaml"); do
     python3 -c "import yaml; yaml.safe_load(open('$f'))" && echo "OK: $f"
   done
   ```

### Should Pass

4. Each fault.yaml has all five `spec` sections: `description`, `implementation`, `parameters`,
   `compatibility`, `groundTruth`.

5. Scope correctness: `general` faults have `domain: null`, `domain` faults have a non-null
   `domain`, `app-specific` faults have a non-null `targetApp`.

---

## Testing Commands

```bash
# Validate all fault.yamls in one pass
for f in $(find /srv/projects/ace-monorepo/catalog -name "fault.yaml"); do
  bash /srv/projects/ace-monorepo/catalog/validate.sh fault "$f"
done

# Check YAML syntax
pip install pyyaml 2>/dev/null
for f in $(find /srv/projects/ace-monorepo/catalog -name "fault.yaml"); do
  python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" "$f" && echo "YAML OK: $f"
done

# Count faults by scope
grep -rh "  scope:" /srv/projects/ace-monorepo/catalog | sort | uniq -c
```

---

## Common Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| `validate.sh` exits with "Missing required top-level key" | YAML indentation is wrong (tabs vs spaces) | Use 2-space indentation throughout; replace tabs with `sed -i 's/\t/  /g'` |
| `validate.sh` exits with "Invalid scope" | Scope value has trailing whitespace | Check with `cat -A fault.yaml \| grep scope` |
| Python YAML parse error on `fault.yaml` | Unquoted `*` in `targetDomains: ["*"]` | Wrap in quotes: `["*"]` is valid YAML; if using bare `*` in block style wrap in quotes |
| `carts-db-corrupt` fault not loading | `catalog/apps/official/sock-shop/` path does not match loader's path assumption | Confirm Stage 02 loader also walks `catalog/apps/<tier>/<appName>/faults/`; adjust if the `official/` tier subdirectory is not expected |

---

## Rollback Procedure

Stage 01 only creates files — it does not modify any Go code or MongoDB. To roll back:

```bash
rm -rf /srv/projects/ace-monorepo/catalog/faults/
rm -rf /srv/projects/ace-monorepo/catalog/apps/official/sock-shop/faults/
git checkout /srv/projects/ace-monorepo/catalog/validate.sh
```

---

## Success Criteria

Stage 01 is complete when:
- All five fault.yaml files exist at their declared paths
- Running `bash catalog/validate.sh fault <path>` on each returns "OK"
- Running `python3 -c "import yaml; yaml.safe_load(open('<path>'))"` on each returns no error
- The directory structure matches the layout in spec §4

**Next Stage:** Stage 02 — FaultCatalogEntry Go Types + YAML Loader
