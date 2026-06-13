---
title: "Pipeline"
parent: "Certification Methodology"
grand_parent: "Deep Dive"
nav_order: 4
---

# Pipeline Architecture

The certifier is a four-phase analytical pipeline. It takes a raw Langfuse trace from one agent run and produces per-fault metric files. Repeat across N runs and you have the input for aggregation and certification.

---

## The Four Phases

<div class="flow-pipeline">
  <div class="flow-input-node">Raw Langfuse Trace (JSON)</div>
  <div class="flow-arrow"><div class="flow-arrow-line"></div><div class="flow-arrow-head"></div></div>
  <div class="flow-phase-box">
    <span class="flow-phase-badge">Phase 0</span>
    <div>
      <div class="flow-phase-title">Fault Bucketing</div>
      <div class="flow-phase-desc">LLM classifies interleaved events into per-fault lifecycle buckets (3-pass algorithm)</div>
    </div>
  </div>
  <div class="flow-arrow"><div class="flow-arrow-line"></div><div class="flow-arrow-note">one bucket file per active fault</div><div class="flow-arrow-line"></div><div class="flow-arrow-head"></div></div>
  <div class="flow-phase-box">
    <span class="flow-phase-badge">Phase 1</span>
    <div>
      <div class="flow-phase-title">Metrics Extraction</div>
      <div class="flow-phase-desc">LLM extracts quantitative (TTD, TTM, tokens) and qualitative metrics per fault bucket</div>
    </div>
  </div>
  <div class="flow-arrow"><div class="flow-arrow-line"></div><div class="flow-arrow-note">repeated for each of N runs</div><div class="flow-arrow-line"></div><div class="flow-arrow-head"></div></div>
  <div class="flow-phase-box">
    <span class="flow-phase-badge">Phase 2</span>
    <div>
      <div class="flow-phase-title">Aggregation</div>
      <div class="flow-phase-desc">Pure-Python stats per fault category + LLM Council narrative synthesis</div>
    </div>
  </div>
  <div class="flow-arrow"><div class="flow-arrow-line"></div><div class="flow-arrow-head"></div></div>
  <div class="flow-phase-box">
    <span class="flow-phase-badge">Phase 3</span>
    <div>
      <div class="flow-phase-title">Certification</div>
      <div class="flow-phase-desc">5 concurrent LLM builders produce a validated 12-section report → JSON + PDF</div>
    </div>
  </div>
</div>

---

## Phase Design Decisions

Each phase is designed around a specific principle.

**Phase 0 uses a 3-pass algorithm** because a single agent run typically contains events from multiple simultaneous faults, all interleaved in the trace. Pass 1 finds fault injection timestamps (deterministic, no LLM). Pass 2 assigns events deterministically where only one fault was active. Pass 3 sends ambiguous events to an LLM classifier. This keeps LLM calls to the minimum necessary.

**Phase 1 makes two extraction passes** (quantitative + qualitative) because LLMs are reliable at identifying patterns and making judgements, but unreliable at arithmetic. All numeric computation happens in Phase 2, in pure Python, so results are fully reproducible.

**Phase 2 runs no LLMs for arithmetic** because reproducibility is non-negotiable for a certification claim. The LLM Council in Phase 2 handles narrative synthesis only — k independent judges assess qualitative data, a meta-judge produces a consensus, and the numeric aggregation is separate and deterministic.

**Phase 3 runs 5 narrative builders concurrently** because the 12 report sections have no inter-dependencies except one: the Recommendations section depends on the Limitations section, so it runs sequentially after. Everything else runs in parallel to minimise wall-clock time.

---

## What This Section Covers

<details class="section-details" markdown="1">
<summary class="section-summary"><span class="section-tag">4.0</span> Architecture Overview</summary>
<div class="section-details-body" markdown="1">
{% capture _s %}{% include_relative 04-Pipeline/4.0-Architecture-Overview.md %}{% endcapture %}{% assign _p = _s | split: "---" %}{% assign _b = _p | slice: 2, 100 | join: "---" %}{{ _b | lstrip }}
</div>
</details>
<details class="section-details" markdown="1">
<summary class="section-summary"><span class="section-tag">4.1</span> Fault Bucketing</summary>
<div class="section-details-body" markdown="1">
{% capture _s %}{% include_relative 04-Pipeline/4.1-Fault-Bucketing.md %}{% endcapture %}{% assign _p = _s | split: "---" %}{% assign _b = _p | slice: 2, 100 | join: "---" %}{{ _b | lstrip }}
</div>
</details>
<details class="section-details" markdown="1">
<summary class="section-summary"><span class="section-tag">4.2</span> Metrics Extraction</summary>
<div class="section-details-body" markdown="1">
{% capture _s %}{% include_relative 04-Pipeline/4.2-Metrics-Extraction.md %}{% endcapture %}{% assign _p = _s | split: "---" %}{% assign _b = _p | slice: 2, 100 | join: "---" %}{{ _b | lstrip }}
</div>
</details>
<details class="section-details" markdown="1">
<summary class="section-summary"><span class="section-tag">4.3</span> Aggregation and LLM Council</summary>
<div class="section-details-body" markdown="1">
{% capture _s %}{% include_relative 04-Pipeline/4.3-Aggregation-and-LLM-Council.md %}{% endcapture %}{% assign _p = _s | split: "---" %}{% assign _b = _p | slice: 2, 100 | join: "---" %}{{ _b | lstrip }}
</div>
</details>
<details class="section-details" markdown="1">
<summary class="section-summary"><span class="section-tag">4.4</span> Hypothesis Framework</summary>
<div class="section-details-body" markdown="1">
{% capture _s %}{% include_relative 04-Pipeline/4.4-Hypothesis-Framework.md %}{% endcapture %}{% assign _p = _s | split: "---" %}{% assign _b = _p | slice: 2, 100 | join: "---" %}{{ _b | lstrip }}
</div>
</details>
