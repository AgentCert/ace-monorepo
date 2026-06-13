---
title: "5 · Certification"
parent: "Deep Dive"
nav_order: 5
nav_fold: true
---

# Certification

Certification is the output that makes everything else meaningful. Phase 3 takes the aggregated scorecards from Phase 2 and builds a 12-section report — validated against a Pydantic schema, rendered to HTML and PDF — that you can hand to a stakeholder and defend.

---

## What a Certification Report Contains

The report is divided into four logical parts:

| Part | Sections | Focus |
|---|---|---|
| **Agent Capability** | 1–5 | What the agent can do — performance, reasoning, safety, RAI compliance |
| **Fault Injection Analysis** | 6–8 | How it behaved across each fault category |
| **Limitations & Improvements** | 9–10 | Where it struggled and what to fix |
| **Appendix** | 11–12 | Token accounting and statistical hypothesis results |

Every section is backed by the raw metrics from Phase 1 and the aggregated scores from Phase 2. There are no black boxes: every narrative claim traces back to a specific trace event.

---

## How It Is Built

Phase 3 runs **six concurrent LLM narrative builders** — executive summary, fault resilience, RAI compliance, security compliance, performance, and limitations — plus a seventh builder (recommendations) that runs sequentially after limitations because it depends on that section's content.

The final document is validated against the `CertificationReport` Pydantic schema. If validation fails, the pipeline errors rather than silently emitting a malformed report. You always get a valid report or a clear error — never a partial or corrupted output.

---

## The Evidence Chain

```
Raw Langfuse Trace
      │
      ▼  Phase 0+1 (per run)
Per-fault metrics JSON
      │
      ▼  Phase 2 (across all N runs)
Aggregated scorecard
      │
      ▼  Phase 3
12-section CertificationReport (JSON)
      │
      ▼  Cert reporter
certification.html  →  certification.pdf
```

The chain is fully traceable. The PDF you hand to a stakeholder is a rendering of the JSON, which is derived from the aggregated scorecard, which is derived from per-fault metrics, which are extracted from the raw traces. Every number has a source.

---

## Certification Scenarios

The report adapts to the data available:

- **Full certification** — N ≥ 30 runs per fault category, all metrics extracted. All 12 sections populated, statistical hypothesis results included.
- **Provisional certification** — 10 ≤ N < 30. Metrics are reported but confidence intervals are noted as insufficient for hypothesis testing.
- **Preliminary assessment** — N < 10. Report is generated as an early indicator, clearly marked as non-certifying.

---

## What This Chapter Covers

| Section | Contents |
|---|---|
| [5.0 Certification Overview](05-Certification/5.0-Certification-Overview) | How the cert builder works and what each part of the report contains |
| [5.1 Report Builder Architecture](05-Certification/5.1-Report-Builder-Architecture) | Internal architecture of Phase 3: builders, concurrency, and schema validation |
| [5.2 Report Sections Reference](05-Certification/5.2-Report-Sections-Reference) | What goes into each of the 12 sections |
| [5.3 Certification Scenarios](05-Certification/5.3-Certification-Scenarios) | Full / provisional / preliminary — which scenario applies and why |
