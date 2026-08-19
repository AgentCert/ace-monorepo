# Fault ↔ Application Compatibility

Which faults in `chaos-charts/faults/` can be injected against which application in
`app-charts/charts/`, what each fault actually does to the target, and how it's meant
to be diagnosed/fixed. Compiled by reading each fault's `engine.yaml` (does it
hardcode a target service/namespace, or leave `appns`/target workload blank for the
caller to fill in?), its `fault.yaml`/`ChaosExperiment` `description.message` field
(the "what it does" text below is taken directly from, or lightly condensed from,
that field), its `ground_truth.yaml` (`goal`/`remediation` — the certifier's own
ideal-outcome reference, which is where the "how to fix" text below comes from), and
the pre-baked Argo Workflow `experiment.yaml` templates under
`chaos-charts/experiments/` (which combinations are actually wired up and runnable
today). See [`CAPABILITIES.md`](CAPABILITIES.md) for which *agent* is benchmarked
against which fault set — this file is app-compatibility, not agent-compatibility.

Three applications exist:

| App | Chart | Namespace | Notable services |
|---|---|---|---|
| **Sock Shop** | `app-charts/charts/sock-shop` | `sock-shop` | `carts`, `catalogue`, `orders`, `payment`, `shipping`, `user`, `queue-master`, `rabbitmq`, `*-db` (carts-db, catalogue-db, orders-db, user-db) |
| **Bookinfo** | `app-charts/charts/bookinfo` | `book-info` | `details`, `reviews` (v1/v2/v3), `ratings`, `productpage` |
| **OpenTelemetry Demo (Astronomy Shop)** | `app-charts/charts/otel-demo` | `otel-demo` | `checkout`, `email`, `quote`, `valkey-cart` (cache), `flagd` (feature flags), `frontend`, `cart`, `payment`, `shipping`, `currency`, `recommendation`, `product-catalog`, `ad`, `accounting`, plus load generator |

All three apps run on plain Kubernetes Deployments/Services/PVCs, so any fault that
targets by generic `appns`/`appkind`/label-selector (rather than hardcoding a specific
service name) is mechanically injectable against all three — the difference is only
whether an existing Argo Workflow template already wires that combination up, or
whether it needs `appNamespace`/target-workload parameters supplied manually.

---

## 1. Standard LitmusChaos faults (`chaos-charts/faults/kubernetes/`) — app-agnostic

All fault types below take a generic `appns`/`applabel`/target-workload (or, for
node-level faults, a `nodeLabel`) and have no hardcoded service reference — every one
is injectable against **Sock Shop, Bookinfo, and OpenTelemetry Demo alike**, and the
node-level ones against whatever app happens to be scheduled on the affected node.
`install-application`/`install-agent`/`uninstall-application`/`uninstall-agent` are
lifecycle steps, not faults, and are omitted.

### Pod-level

- **`pod-delete`** — Force-deletes a pod belonging to a Deployment/StatefulSet/DaemonSet, simulating a crash. *Fix:* confirm the controller replaces it and replica count is restored; if a replacement pod fails to come up healthy, roll back or scale the deployment.
- **`container-kill`** — Sends SIGKILL to a specific container inside an application pod (not the whole pod). *Fix:* check for CrashLoopBackOff/high restart counts, inspect logs, confirm the container auto-restarts and the pod returns to Running; if stuck, delete the pod to force a reschedule.
- **`pod-cpu-hog` / `pod-cpu-hog-exec`** — Pins one or more CPU cores to 100% inside the target container (via a stress process, either as a sidecar or `exec`'d into the container). *Fix:* identify pods with abnormal CPU usage, kill the stress process, restart degraded pods, and adjust CPU limits/HPA thresholds if the app couldn't absorb the load.
- **`pod-memory-hog` / `pod-memory-hog-exec`** — Allocates memory inside the target container until it is throttled or OOM-killed. *Fix:* identify pods with abnormal memory usage, kill the stress process, restart any OOMKilled pods, and adjust memory limits/VPA policy if needed.
- **`pod-io-stress`** — Generates sustained disk I/O load inside the target pod's containers. *Fix:* identify pods under I/O pressure and confirm they recover once the stress workload ends; adjust storage/IOPS limits if the app degraded.
- **`disk-fill`** — Fills the ephemeral storage of the target pod's containers to test eviction behavior under disk pressure. *Fix:* identify pods with high ephemeral-storage usage, clean up unnecessary files, delete evicted pods, and raise ephemeral-storage requests/limits if they were too tight.
- **`pod-autoscaler`** — Scales a Deployment's replica count up to a high value to stress cluster/node capacity and autoscaling. *Fix:* verify the new replicas reach Running, confirm nodes autoscale if needed, then scale the deployment back down (and remove any extra nodes the cluster autoscaler doesn't reclaim automatically).

### Network-level

- **`pod-network-loss`** — Drops a percentage of network packets to/from the target pod. *Fix:* confirm affected pods recover once the loss window ends; if not, delete the pod to reset its network state and verify connectivity/retry logic held up.
- **`pod-network-latency`** — Adds artificial latency to the target pod's network traffic. *Fix:* verify latency returns to baseline after the chaos window; check whether timeouts/retries in the app handled the slowdown gracefully.
- **`pod-network-corruption`** — Corrupts a percentage of network packets to/from the target pod. *Fix:* confirm the pod's network state is clean after the window ends (delete the pod if not) and that data integrity/error handling recovered.
- **`pod-network-duplication`** — Duplicates a percentage of outgoing network packets from the target pod. *Fix:* confirm normal network behavior resumes after the chaos window; check the app didn't double-process duplicated requests.
- **`pod-network-partition`** — Blocks 100% of network traffic to/from the target pod (a full network partition). *Fix:* confirm connectivity is restored once the partition lifts; check whether the app correctly reported/alerted on the outage rather than hanging silently.
- **`pod-network-rate-limit`** — Throttles the target pod's network bandwidth. *Fix:* confirm bandwidth and normal transfer speeds return after the window ends; check whether timeout handling degraded gracefully under the constrained throughput.
- **`pod-dns-error`** — Injects DNS resolution failures inside the target pod's containers. *Fix:* verify CoreDNS itself is healthy, check the pod's DNS policy/`resolv.conf`, delete the affected pod to restore a clean DNS state, and confirm service-to-service calls resume after the window ends.
- **`pod-dns-spoof`** — Redirects specific DNS lookups from the target pod to attacker-chosen hostnames/IPs. *Fix:* confirm DNS resolution returns to the correct targets after the window ends; check whether the app validated the identity of what it connected to.

### L7 / HTTP-level (via a MITM proxy inside the pod)

- **`pod-http-latency`** — Adds artificial latency to HTTP requests/responses passing through the target pod. *Fix:* confirm latency returns to baseline after the window; check the caller's timeout/retry behavior held up.
- **`pod-http-status-code`** — Rewrites the HTTP status code of responses from the target pod to a status code you choose. *Fix:* confirm real status codes resume after the window; check whether callers correctly handled/alerted on the injected error codes.
- **`pod-http-modify-body`** — Rewrites the HTTP response body from the target pod to a string you provide. *Fix:* confirm the real response body resumes after the window; check whether downstream consumers correctly rejected/handled the malformed payload rather than silently trusting it.
- **`pod-http-modify-header`** — Rewrites HTTP request/response headers on traffic through the target pod to values you provide. *Fix:* confirm original headers resume after the window; check whether the app depended on a header that was altered.
- **`pod-http-reset-peer`** — Resets the TCP connection on outgoing HTTP requests from the target pod, so calls fail immediately. *Fix:* confirm connections succeed again after the window; check whether the caller retried or failed hard.

### Config-level

*(These 4 also exist as ITBench variants in §2a below with the same mechanism — the
versions here are the raw LitmusChaos ChaosExperiment; the ITBench versions add a
scoped `ground_truth.yaml` used for the certifier's action-correctness grading.)*

- **`misconfigured-kubernetes-workload-container-readiness-probe`** — Patches a container's readiness probe to point at an unreachable port, so the pod is marked NotReady and removed from Service endpoints even though it's actually running fine. *Fix:* restore the correct readiness probe (`kubectl rollout undo` or edit the Deployment) so the pod becomes Ready and receives traffic again.
- **`modified-target-port-kubernetes-service`** — Changes a Service's `targetPort` to a port nothing is listening on, so all traffic to it fails. *Fix:* patch the Service's `targetPort` back to the port the pod actually listens on.
- **`invalid-kubernetes-service-selector`** — Replaces a Service's label selector with a value that matches no pods, so it has zero Endpoints and drops all inbound traffic. *Fix:* restore the Service's original selector so it re-matches pods and Endpoints repopulate.
- **`nonexistent-kubernetes-workload-persistent-volume-claim`** — Creates a PVC referencing a StorageClass that doesn't exist and mounts it into the workload, leaving pods stuck Pending/Init on a `FailedMount`. *Fix:* roll back the Deployment to remove the bad volume reference and delete the broken PVC.

### Node-level (affects whatever app is scheduled on the node)

- **`node-cpu-hog`** — Pins a node's CPU to high utilization, stressing every pod scheduled there. *Fix:* confirm the node's CPU usage returns to normal and no pods were evicted; if evicted, confirm they reschedule and recover.
- **`node-memory-hog`** — Pins a node's memory to high utilization, risking pod evictions/OOM on that node. *Fix:* confirm memory pressure clears and evicted pods reschedule and recover elsewhere.
- **`node-io-stress`** — Generates sustained disk I/O load on a node, affecting every pod's storage performance there. *Fix:* confirm I/O load clears and any degraded pods recover.
- **`node-drain`** — Cordons and evicts all pods from a node (`kubectl drain`), forcing them to reschedule elsewhere. *Fix:* confirm evicted pods rescheduled and reached Running/Ready; uncordon the node once the test window ends.
- **`node-taint`** — Applies a taint to a node that repels pods without a matching toleration. *Fix:* confirm affected pods without the toleration were rescheduled elsewhere and are healthy; remove the taint to restore normal scheduling.
- **`node-restart`** — Restarts a target node via SSH. *Fix:* identify the `NotReady` node and affected pods, delete any stuck `Terminating` pods, confirm workloads reschedule and run, and uncordon the node if it was left cordoned.
- **`node-poweroff`** — Powers off a node in the cluster outright. *Fix:* confirm the node's workloads were rescheduled onto healthy nodes and recovered; power the node back on and confirm it rejoins the cluster.
- **`kubelet-service-kill`** — Kills the kubelet service on the node hosting the application, simulating node agent failure. *Fix:* confirm the kubelet service restarts (systemd should auto-restart it) and the node returns to `Ready`; confirm pods on it weren't evicted unnecessarily.
- **`docker-service-kill`** — Kills the container runtime (Docker) service on the application node. *Fix:* confirm the runtime service restarts and the node's pods return to Running; investigate if any pods failed to recover automatically.

---

## 2. ITBench SRE faults (`chaos-charts/faults/itbench/`) — mostly app-agnostic, 7 exceptions

29 fault types (plus 4 more that exist only as empty duplicate directories under
`kubernetes/` — see the duplicate note above; those 4 real definitions live here).
Each carries a `ground_truth.yaml` with the certifier's ideal diagnostic/remediation
trajectory (used for Phase 1 `action_correctness` scoring), which is where the "how to
fix" text below is drawn from — these are deliberately more specific/kubectl-flavored
than the standard faults above, since they were written for exact-match grading.

### 2a. Generic — injectable against any of the three apps

These leave `appns`/target workload blank in `engine.yaml` for the caller to fill in
(same mechanism as the standard faults above), or operate on cluster/node-level
resources with no app tie-in at all. **Not yet pre-wired** to Sock Shop or Bookinfo in
any Argo Workflow template (only scenarios 36/53 → Bookinfo and 58/20/49 → OpenTelemetry
Demo are pre-baked today, per the table below) — but mechanically compatible with any
app by supplying `appNamespace` + a target Deployment/Service/label-selector.

| # | Fault | What it does | How to fix |
|---|---|---|---|
| 16 | `modified-kubernetes-workload-container-environment-variable` | Overwrites one named environment variable on a container with a bad value (default targets an otel-demo `quote`-service `QUOTE_ADDR` var, but the var name/value/target are all parameters). | Restore the env var to its original/correct value (`kubectl rollout undo` or edit the Deployment), then confirm the pod restarts, becomes Ready, and the downstream call succeeds. |
| 20 | `nonexistent-kubernetes-workload-container-image` | Points a container at a nonexistent image tag, causing `ImagePullBackOff`. | Revert the image to a known-good tag (`kubectl rollout undo` or `kubectl set image`), then confirm the pod reaches Running/Ready. |
| 30 | `modified-target-port-kubernetes-service` | Replaces a Service's `targetPort` with a broken value (default 9999), routing traffic to a closed port. | Patch the Service's `targetPort` back to the correct value. |
| 36 | `invalid-kubernetes-service-selector` | Replaces a Service's selector with an invalid label so it has zero matching Endpoints. | Restore the Service's original selector so Endpoints repopulate. |
| 39 | `cordoned-kubernetes-worker-node` | Cordons the node hosting a workload's pods (`kubectl cordon`), blocking new pods from landing there. ⚠️ shared blast radius: a node is usually shared by other workloads too. | `kubectl uncordon <node>` to restore schedulability, then confirm affected pods return to Running/Ready. |
| 43 | `failing-name-resolution-kubernetes-workload-dns-policy` | Patches a Deployment's `dnsPolicy` to `None` and points `dnsConfig.nameservers` at an unreachable DNS server, so all outgoing name lookups fail. | Restore `dnsPolicy` to `ClusterFirst` and remove the bad `dnsConfig.nameservers` entry (or `kubectl rollout undo`), then confirm the workload can resolve its dependencies again. |
| 46 | `insufficient-kubernetes-workload-container-resources` | Patches a container's `resources.requests/limits` down to unrealistically low values (default 8Mi memory), causing repeated OOMKill/CrashLoopBackOff. | Revert the resources block to adequate values (`kubectl rollout undo` or edit the Deployment), then confirm the pod stabilizes. |
| 49 | `misconfigured-kubernetes-workload-container-readiness-probe` | Patches a container's readiness probe to an unreachable port (default 40), leaving the pod permanently NotReady. | Correct or remove the faulty readiness probe so the pod becomes Ready and receives traffic again. |
| 58 | `scaled-to-zero-kubernetes-workload` | Scales a Deployment/StatefulSet to zero replicas, causing a full traffic outage. | Scale it back to a healthy replica count (`kubectl scale` or `kubectl rollout undo`), then confirm pods become Ready and traffic resumes. |
| 105 | `invalid-kubernetes-workload-container-command` | Overwrites a container's `command` with a nonexistent binary (and clears `args`), so it crash-loops immediately. | Revert the command/args (`kubectl rollout undo` or edit the Deployment), then confirm the pod reaches Running/Ready. |
| 114 | `deleted-kubernetes-service` | Deletes the Service fronting a workload, so other workloads can no longer resolve/route to it by name. | Recreate the Service (`kubectl apply` a manifest with the correct selector/ports, or re-sync via Helm) so Endpoints repopulate. |
| — | `crashing-kubernetes-workload-init-container` | Injects an extra initContainer running a deliberately bad script, so the pod is stuck in `Init:CrashLoopBackOff` and the main container never starts. | Roll back the Deployment or edit it to remove the injected initContainer, then confirm the pod leaves `Init:CrashLoopBackOff`. |
| — | `hanging-kubernetes-workload-init-container` | Appends an initContainer that sleeps forever, leaving every pod stuck in `Init:0/1`/Pending permanently. | Roll back the Deployment or remove the hanging initContainer entry, then confirm pods exit the `Init:` state. |
| — | `ingress-port-blocking-network-policy` | Creates a NetworkPolicy that denies all ingress traffic to a workload's pods. | Find and delete the offending NetworkPolicy (or edit it to allow the required ingress) so traffic resumes. |
| — | `insufficient-kubernetes-resource-quota` | Creates/patches a namespace ResourceQuota with hard CPU/memory limits far too low for the workload to (re)schedule. | Raise the ResourceQuota's limits (or delete it if unneeded), then confirm the stuck pods get created and reach Running/Ready. |
| — | `kubernetes-api-server-request-surge` | Deploys a short-lived load-generator Deployment (`workload-scanner`) in the namespace that hammers the kube-apiserver with a sustained request burst. ⚠️ cluster-wide blast radius: apiserver latency degradation isn't confined to the target namespace. | Find and delete the `workload-scanner` Deployment (or lower its request rate), then confirm apiserver latency returns to baseline cluster-wide. |
| — | `misconfigured-kubernetes-horizontal-pod-autoscaler` | Patches an HPA's CPU/memory utilization targets to unrealistically low values, so it scales toward `maxReplicas` without ever relieving load. | Patch the HPA's `spec.metrics` back to realistic utilization targets, then confirm replica count settles back down. |
| — | `nonexistent-kubernetes-workload-node` | Adds a `nodeSelector` referencing a node name that doesn't exist, leaving the pod permanently unschedulable (stuck Pending). | Remove or correct the invalid `nodeSelector` (`kubectl rollout undo` or edit), then confirm the pod is scheduled and reaches Running/Ready. |
| — | `nonexistent-kubernetes-workload-persistent-volume-claim` | Creates a PVC with an invalid StorageClass and mounts it into the workload, leaving pods stuck on a `FailedMount` event. | Roll back the Deployment (removing the bad volume reference) and delete the broken PVC. |
| — | `priority-kubernetes-workload-priority-preemption` | Creates a higher-priority PriorityClass and a resource-heavy decoy Deployment sized to consume most of the target pod's node, forcing the scheduler to preempt (evict) the lower-priority target pod. | Remove the decoy high-priority Deployment/PriorityClass starving the node, then confirm the target pod reschedules and reaches Running/Ready. |
| — | `unassigned-kubernetes-workload-container-resource-limits` | Removes a container's `resources.limits`, leaving it with no ceiling on resource consumption. | Patch `resources.limits` back to appropriate values (or `kubectl rollout undo`), then confirm limits are enforced again. |
| — | `unschedulable-kubernetes-workload-pod-anti-affinity-rule` | Patches a workload's pod template with a required inter-pod anti-affinity rule the cluster's node topology can't satisfy, so replacement pods stay Pending forever. | Remove or correct the anti-affinity rule so the scheduler can place the pod, then confirm it reaches Running/Ready. |
| — | `unsupported-architecture-kubernetes-workload-container-image` | Points a container at an image built only for an unsupported CPU architecture (e.g. arm64-only on an amd64 node), causing `ImagePullBackOff`/Pending. | Revert to a compatible image tag (`kubectl rollout undo` or `kubectl set image`), then confirm the pod reaches Running/Ready. |

**Wired up today** (pre-baked `experiment.yaml` templates, no manual parameters
needed): scenario 36 (`invalid-kubernetes-service-selector`) and scenario 53
(`nonexistent-kubernetes-workload-persistent-volume-claim`) → **Bookinfo**, via
`chaos-charts/experiments/bookinfo-itbench`. Scenarios 58/20/49 → **OpenTelemetry
Demo**, via `otel-demo-itbench`/`otel-demo-itbench-starter`.

### 2b. OpenTelemetry Demo — exclusive (hardcoded to app-specific services)

These reference a specific otel-demo microservice or feature by name in their
`engine.yaml` defaults and/or `ground_truth.yaml` remediation narrative — they only
make sense against **OpenTelemetry Demo** and cannot be pointed at Sock Shop or
Bookinfo without rewriting the fault itself:

| # | Fault | What it does | How to fix |
|---|---|---|---|
| 18 | `chaos-mesh-pod-failure-replacement` | Freezes the `checkout` service's main process via `SIGSTOP` (using an ephemeral debug container, since the container image is distroless with no shell) — the pod looks Running/Ready the whole time but is functionally dead. A LitmusChaos-native stand-in for Chaos Mesh's `pod-failure` action (no Chaos Mesh in this cluster). | Self-reverts automatically via `SIGCONT` once the chaos duration elapses; for faster recovery, delete the `checkout` pod (or roll out/restart its Deployment) so it's replaced with a fresh, responsive instance. |
| 26 | `chaos-mesh-http-body-tamper-replacement` | Fires synthetic HTTP requests carrying a malformed order body (`{'email': '12345', 'order': 'error body'}`) directly at the `email` Service on an interval, from a short-lived traffic-generator pod — an approximation of Chaos Mesh's in-flight body-tampering (no service mesh/proxy layer exists in this cluster to intercept real traffic). | Find and delete the rogue traffic-generator pod (label `chaos-injector=chaos-mesh-http-body-tamper-replacement`) in `otel-demo`, then confirm the `email` service's HTTP error rate returns to baseline — no config on `email` itself was ever changed. |
| 27 | `chaos-mesh-http-abort-replacement` | Creates a NetworkPolicy that denies all L3/L4 ingress to the `quote` service on port 8080, blocking every request there (a coarser LitmusChaos-native approximation of Chaos Mesh's L7 "abort POST requests only" action). | Find the offending NetworkPolicy in `otel-demo` (confirm it targets `quote` pods and denies port 8080), then delete it so traffic to `quote` resumes. |
| 34 | `valkey-workload-changed-password` | Overwrites the `valkey-cart` cache's auth credential (via a new/patched `valkey-credentials` Secret plus a forced `--requirepass` flag on the container), so dependent services (cart, checkout) can no longer authenticate to it. | Restore the `valkey-credentials` Secret's `valkey-password` key to its expected value, or roll back the Deployment to remove the `--requirepass` override, then confirm `cart`/`checkout` reconnect without auth errors. |
| 40 | `valkey-workload-out-of-memory` | Clamps the `valkey-cart` container's memory limit/request to an unrealistically low value, forcing it into repeated OOMKilled/CrashLoopBackOff. | Restore the container's memory limit/request to a sane value (`kubectl rollout undo` or patch `resources.limits/requests.memory`), then confirm it stops crash-looping. |
| — | `opentelemetry-demo-feature-flag` | Patches the `flagd-config` ConfigMap to flip a named feature flag (e.g. `loadGeneratorFloodHomepage`, `adHighCpu`, `cartFailure`, `paymentFailure`) to an abnormal value, triggering the corresponding in-app failure mode. | Edit `flagd-config` to set the flag's `defaultVariant` back to normal/off, then `kubectl rollout restart deployment` in `otel-demo` so `flagd` and the affected service pick up the correction. |

Pre-baked: scenarios 18/26/27 → `chaos-charts/experiments/itbench-adapted-scenarios`
(one run each) and `itbench-2scenario-5run` (scenarios 26/27, ×5 runs each).

---

## 3. Sock Shop-specific experiment bundles

Two pre-baked Sock Shop workflows exist that are not part of the ITBench fault set at
all — plain LitmusChaos, Sock Shop only, defined directly in
`chaos-charts/experiments/sock-shop*`. All use `pod-delete` (see §1 above for what it
does and how it's remediated):

| Experiment | Fault(s) | App |
|---|---|---|
| `sock-shop` | full resiliency suite (`chaos-config` driven) | Sock Shop |
| `sock-shop-single` | `pod-delete` (900s) | Sock Shop |
| `sock-shop-sequential` / `sock-shop-parallel` | same suite, sequential/parallel scheduling | Sock Shop |

---

## Summary

- **Sock Shop**: all 27 standard LitmusChaos faults + the 3 dedicated `sock-shop*`
  experiment bundles. ITBench faults are mechanically compatible (generic
  targeting) but none are pre-wired yet.
- **Bookinfo**: all 27 standard LitmusChaos faults + 2 pre-wired ITBench faults
  (scenario 36 invalid-selector, scenario 53 nonexistent-PVC). Other generic ITBench
  faults are compatible but not pre-wired.
- **OpenTelemetry Demo**: all 27 standard LitmusChaos faults + the full ITBench set,
  including all 6 otel-demo-exclusive faults — broadest coverage of the three apps,
  and the only app the exclusive faults can target at all.
