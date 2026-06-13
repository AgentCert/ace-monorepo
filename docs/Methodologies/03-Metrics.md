---
title: "Metrics"
parent: "Certification Methodology"
grand_parent: "Deep Dive"
nav_order: 3
---

# Metrics

Certification is only as good as the measurements behind it. This chapter defines every metric AgentCert captures, how each is extracted, and what it actually tells you about the agent's behaviour.

---

## Two Types of Extraction

Metrics in AgentCert are extracted in two ways, and it matters which is which:

**LLM-extracted.** An LLM reads the raw trace events for a fault bucket and identifies times, sequences, and qualitative judgements it can't be computed mechanically. Time-to-detect, for example, requires the LLM to identify the moment the agent's reasoning shows awareness of the fault — a subtlety that cannot be derived from timestamps alone.

**Code-computed.** Token counts, tool call counts, and derived rates (detection rate = detected_runs / total_runs) are calculated deterministically from structured data. These are fully reproducible: same inputs, same numbers, every time.

The distinction matters for auditability. Numeric aggregation is pure Python — no LLM, no variance. Qualitative summaries use LLMs but go through the LLM Council (k independent judges + a meta-judge) to reduce model-level variance.

---

## Metric Categories

| Category | Key Metrics | What It Tells You |
|---|---|---|
| **Timing & SLA** | TTD (time-to-detect), TTM (time-to-mitigate), SLA score | How fast the agent responds — average, median, and worst-case |
| **Detection & Resolution** | detection_success, action_correctness, tool_accuracy | Did the agent find the fault and take the right steps? |
| **Reasoning Quality** | 4-dimension composite score | Clarity, accuracy, evidence-grounding, and decision quality |
| **Hallucination** | 6-type taxonomy, hallucination_score | How often the agent asserts things that aren't in the trace |
| **Behavioural Assessment** | plan_adherence, collateral_damage, unsafe_action | Did remediation stay within safe bounds? |
| **Safety & RAI** | PII exposure, security compliance, guardrail adherence, RAI score | Responsible AI checks across every run |
| **Resource Efficiency** | input_tokens, output_tokens | LLM cost per run and trajectory overhead |
| **Derived Rates** | detection_rate, mitigation_rate, rai_rate, security_rate | Aggregated pass rates across all N runs |

---

## From Per-Run to Aggregated

Per-run metrics are extracted for every individual agent run. They are then aggregated across all N runs for a fault category to produce:

- **Mean / median / p95** for timing metrics
- **Success rates** for binary outcomes (detected or not, mitigated or not)
- **Composite scores** for qualitative dimensions
- **Confidence intervals** when N ≥ 30

This multi-run aggregation is what transforms a collection of observations into a defensible certification claim.

---

## What This Section Covers

<details class="section-details" markdown="1">
<summary class="section-summary"><span class="section-tag">3.0</span> Metrics Reference</summary>
<div class="section-details-body" markdown="1">
{% capture _s %}{% include_relative 03-Metrics/3.0-Metrics-Reference.md %}{% endcapture %}{% assign _p = _s | split: "---" %}{% assign _b = _p | slice: 2, 100 | join: "---" %}{{ _b | lstrip }}
</div>
</details>
