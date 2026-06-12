---
title: "6 · Observations"
parent: "Methodology"
nav_order: 6
nav_fold: true
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

## What This Chapter Covers

| Section | Contents |
|---|---|
| [6.1 TTD Observation](06-Observations/6.1-TTD-Observation) | Time-to-detect and time-to-mitigate findings across real datasets |
| [6.2 PII Observation](06-Observations/6.2-PII-Observation) | PII exposure patterns under fault conditions |
| [6.3 Hallucination Observation](06-Observations/6.3-Hallucination-Observation) | Hallucination behaviour under uncertainty |
| [6.4 Fault Bucketing and Detection Findings](06-Observations/6.4-Fault-Bucketing-And-Detection-Findings) | What the bucketing algorithm surfaces that manual review misses |
