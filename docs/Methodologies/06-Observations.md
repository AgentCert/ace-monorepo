---
title: "Observations"
parent: "Certification Methodology"
grand_parent: "Deep Dive"
nav_order: 6
---

# Observations

This chapter is a living record of findings from real AgentCert certification runs. It is not a static methodology document — it grows as we run more experiments and encounter new patterns in agent behaviour.

Read this if you want to understand what ACE actually finds in practice, not just what it is designed to find.

---

## What We Have Observed

### Detection performance varies sharply by fault type

Real runs on the flash-agent revealed a pattern that appears across multiple datasets: the agent performs well on compute and application faults but fails almost completely on network faults.

| Fault Type | Detection Rate |
|---|---|
| pod-cpu-hog | ~90% |
| pod-memory-hog | ~80% |
| pod-network-loss | ~0% |

This is not a misconfiguration. It reflects a genuine capability gap: the agent's toolset for diagnosing network-layer faults is insufficient. Pod CPU and memory issues produce signals that appear in standard Kubernetes metrics; network loss requires probing at the network layer, which the agent's available tools do not support.

**The takeaway:** certification does not just validate your agent — it identifies the fault categories where it is blind.

---

### PII exposure patterns are non-obvious

PII exposure does not happen because the agent is asked to expose PII. It happens because the agent, under fault conditions, over-explains its reasoning and includes diagnostic context that incidentally contains sensitive values (pod IP addresses, internal service names with environment-encoded metadata, log fragments with user IDs).

The RAI metrics in Phase 1 specifically track this pattern. Agents that score well in normal operation can still fail RAI checks under fault conditions when verbosity increases.

---

### Hallucination increases under uncertainty

When an agent cannot find a clear signal for a fault, hallucination rates go up. The agent fills the reasoning gap with plausible-sounding but unsupported claims. Phase 1 extracts a 6-type hallucination taxonomy per run. Aggregated across 30 runs, the pattern is consistent: fault types the agent cannot diagnose clearly correlate with higher hallucination scores.

This is one of the strongest arguments for statistical certification: a single run where the agent happens to be confident will look clean. Thirty runs reveal the distribution.

---

## What This Section Covers

<details class="section-details" markdown="1">
<summary class="section-summary"><span class="section-tag">6.1</span> TTD &amp; TTM Observations</summary>
<div class="section-details-body" markdown="1">
{% capture _s %}{% include_relative 06-Observations/6.1-TTD-Observation.md %}{% endcapture %}{% assign _p = _s | split: "---" %}{% assign _b = _p | slice: 2, 100 | join: "---" %}{{ _b | lstrip }}
</div>
</details>
<details class="section-details" markdown="1">
<summary class="section-summary"><span class="section-tag">6.2</span> PII Observations</summary>
<div class="section-details-body" markdown="1">
{% capture _s %}{% include_relative 06-Observations/6.2-PII-Observation.md %}{% endcapture %}{% assign _p = _s | split: "---" %}{% assign _b = _p | slice: 2, 100 | join: "---" %}{{ _b | lstrip }}
</div>
</details>
<details class="section-details" markdown="1">
<summary class="section-summary"><span class="section-tag">6.3</span> Hallucination Observations</summary>
<div class="section-details-body" markdown="1">
{% capture _s %}{% include_relative 06-Observations/6.3-Hallucination-Observation.md %}{% endcapture %}{% assign _p = _s | split: "---" %}{% assign _b = _p | slice: 2, 100 | join: "---" %}{{ _b | lstrip }}
</div>
</details>
<details class="section-details" markdown="1">
<summary class="section-summary"><span class="section-tag">6.4</span> Fault Bucketing &amp; Detection Findings</summary>
<div class="section-details-body" markdown="1">
{% capture _s %}{% include_relative 06-Observations/6.4-Fault-Bucketing-And-Detection-Findings.md %}{% endcapture %}{% assign _p = _s | split: "---" %}{% assign _b = _p | slice: 2, 100 | join: "---" %}{{ _b | lstrip }}
</div>
</details>
<details class="section-details" markdown="1">
<summary class="section-summary"><span class="section-tag">6.5</span> Hypothesis Validation Report</summary>
<div class="section-details-body" markdown="1">
{% capture _s %}{% include_relative 06-Observations/6.5-Hypothesis-Validation-Report.md %}{% endcapture %}{% assign _p = _s | split: "---" %}{% assign _b = _p | slice: 2, 100 | join: "---" %}{{ _b | lstrip }}
</div>
</details>
