---
title: "Certification Methodology"
parent: "Deep Dive"
nav_order: 1
has_children: true
nav_fold: true
---

# Certification Methodology

How fault-injection runs become a defensible certification report. Six chapters — designed to be read in order, but each stands alone.

<div class="chapter-grid">
  <a class="chapter-card" href="{{ "/Methodologies/01-Introduction.html" | relative_url }}">
    <div class="chapter-num">1</div>
    <div class="chapter-body">
      <div class="chapter-title">Introduction</div>
      <div class="chapter-desc">Why ACE exists, the high-level workflow, and the core assumptions the pipeline rests on.</div>
    </div>
  </a>
  <a class="chapter-card" href="{{ "/Methodologies/02-Experiment-Design.html" | relative_url }}">
    <div class="chapter-num">2</div>
    <div class="chapter-body">
      <div class="chapter-title">Experiment Design</div>
      <div class="chapter-desc">Fault taxonomy, injection config schema, trace collection, and the ground-truth answer key.</div>
    </div>
  </a>
  <a class="chapter-card" href="{{ "/Methodologies/03-Metrics.html" | relative_url }}">
    <div class="chapter-num">3</div>
    <div class="chapter-body">
      <div class="chapter-title">Metrics</div>
      <div class="chapter-desc">Every metric AgentCert captures — how each is extracted (LLM vs code-computed) and what it tells you.</div>
    </div>
  </a>
  <a class="chapter-card" href="{{ "/Methodologies/04-Pipeline.html" | relative_url }}">
    <div class="chapter-num">4</div>
    <div class="chapter-body">
      <div class="chapter-title">Pipeline</div>
      <div class="chapter-desc">Fault bucketing → metrics extraction → statistical aggregation → LLM Council → hypothesis framework.</div>
    </div>
  </a>
  <a class="chapter-card" href="{{ "/Methodologies/05-Certification.html" | relative_url }}">
    <div class="chapter-num">5</div>
    <div class="chapter-body">
      <div class="chapter-title">Certification</div>
      <div class="chapter-desc">Report-builder architecture, the 12-section report reference, and full/provisional certification scenarios.</div>
    </div>
  </a>
  <a class="chapter-card" href="{{ "/Methodologies/06-Observations.html" | relative_url }}">
    <div class="chapter-num">6</div>
    <div class="chapter-body">
      <div class="chapter-title">Observations</div>
      <div class="chapter-desc">TTD, PII, and hallucination findings from real certification runs. A living record of what ACE finds in practice.</div>
    </div>
  </a>
</div>

---

## Why these six chapters?

The methodology answers three questions in sequence:

1. **What do you measure?** (Chapters 1–3) — the problem, the experimental structure, and the full metrics catalogue.
2. **How is it computed?** (Chapter 4) — the 4-phase pipeline from raw trace to scorecard.
3. **What do you report?** (Chapters 5–6) — the 12-section certification report and real findings from production runs.
