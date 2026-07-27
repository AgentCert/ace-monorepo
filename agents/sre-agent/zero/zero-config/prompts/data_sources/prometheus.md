# Prometheus Data Source Reference

## Prometheus (via Prometheus MCP)

This is the cluster's real, live Prometheus instance -- it scrapes Kubernetes
infrastructure metrics (cAdvisor container stats, kube-state-metrics, node
metrics) and LitmusChaos's chaos-exporter, cluster-wide (not scoped to a
single namespace -- always filter by `namespace="otel-demo"` or the relevant
target namespace). It does **not** have otel-demo's own application-level
request/latency/trace metrics (there is no OTel-Collector-to-Prometheus
pipeline wired up for that) -- for that, correlate with what the
`offline_incident_analysis`/`kubernetes` tools already tell you about traces
and logs.

### Available Tools

- `execute_query` — instant PromQL query (single point in time)
- `execute_range_query` — PromQL range query (time series over a window: start, end, step)
- `list_metrics` — list metric names (supports pagination; the `filter_pattern` argument is
  unreliable for substring matching -- prefer `execute_query` directly if a metric doesn't show up)
- `get_metric_metadata` — type/help/unit for a metric
- `get_targets` — scrape target health (which exporters are up/down)

### Confirmed Real Metrics (queried directly against this cluster)

**Container resource usage (cAdvisor, `job="kubernetes-cadvisor"`):**
- `container_cpu_usage_seconds_total{namespace="otel-demo"}` — cumulative CPU seconds per container
  (rate it: `rate(container_cpu_usage_seconds_total{namespace="otel-demo"}[5m])`)
- `container_memory_working_set_bytes{namespace="otel-demo"}` — current memory usage
- Labels include `container`, `pod`, `image` (e.g. `ghcr.io/open-telemetry/demo:2.2.0-<service>`)

**Pod/cluster state (kube-state-metrics):**
- `kube_pod_status_phase{namespace="otel-demo"}` — Pending/Running/Failed/etc, value 1 for the active phase
- `kube_pod_container_status_restarts_total{namespace="otel-demo"}` — restart counts (CrashLoopBackOff indicator)
- `kube_pod_container_status_waiting_reason{namespace="otel-demo"}` — e.g. ImagePullBackOff, CrashLoopBackOff

**Chaos experiment status (chaos-exporter, `job="chaos-exporter"`):**
- `litmuschaos_experiment_verdict` — verdict of LitmusChaos experiments (empty result = no active/recent experiment)
- Query this FIRST when investigating a suspected fault injection -- a non-empty result directly
  confirms which experiment is/was active, when generic app-level symptoms alone wouldn't tell you.

**Node-level:**
- `node_cpu_seconds_total`, `node_memory_MemAvailable_bytes` — standard node-exporter-style metrics
  (present via `kubernetes-nodes` scrape job)

### Investigation Starting Point

```
1. litmuschaos_experiment_verdict                                    -- is a fault currently/recently active?
2. kube_pod_status_phase{namespace="otel-demo", phase!="Running"}     -- what's not healthy right now?
3. kube_pod_container_status_restarts_total{namespace="otel-demo"}    -- what's crash-looping?
4. rate(container_cpu_usage_seconds_total{namespace="otel-demo"}[5m]) -- resource pressure?
```

### Data Collection Tasks

**Query Prometheus** for:
- Chaos experiment verdicts → Write to `$WORKSPACE_DIR/chaos_status.json`
- Pod phase / restart counts → Write to `$WORKSPACE_DIR/k8s_pod_metrics.json`
- Container CPU/memory → Write to `$WORKSPACE_DIR/container_metrics.json`
