---
title: "4 · Pipeline"
parent: "Methodology"
nav_order: 4
nav_fold: true
---

# Pipeline Architecture

The certifier is a four-phase analytical pipeline. It takes a raw Langfuse trace from one agent run and produces per-fault metric files. Repeat across N runs and you have the input for aggregation and certification.

---

## The Four Phases

```
Raw Langfuse Trace (JSON)
         │
         ▼
┌─────────────────────┐
│  Phase 0            │  LLM classifies interleaved events into
│  Fault Bucketing    │  per-fault lifecycle buckets (3-pass algorithm)
└──────────┬──────────┘
           │  one bucket file per active fault
           ▼
┌─────────────────────┐
│  Phase 1            │  LLM extracts quantitative (TTD, TTM, tokens)
│  Metrics Extraction │  and qualitative metrics per fault bucket
└──────────┬──────────┘
           │  repeated for each of N runs
           ▼
┌─────────────────────┐
│  Phase 2            │  Pure-Python stats per fault category
│  Aggregation        │  + LLM Council narrative synthesis
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  Phase 3            │  5 concurrent LLM builders produce
│  Certification      │  a validated 12-section report → JSON + PDF
└─────────────────────┘
```

---

## Phase Design Decisions

Each phase is designed around a specific principle.

**Phase 0 uses a 3-pass algorithm** because a single agent run typically contains events from multiple simultaneous faults, all interleaved in the trace. Pass 1 finds fault injection timestamps (deterministic, no LLM). Pass 2 assigns events deterministically where only one fault was active. Pass 3 sends ambiguous events to an LLM classifier. This keeps LLM calls to the minimum necessary.

**Phase 1 makes two extraction passes** (quantitative + qualitative) because LLMs are reliable at identifying patterns and making judgements, but unreliable at arithmetic. All numeric computation happens in Phase 2, in pure Python, so results are fully reproducible.

**Phase 2 runs no LLMs for arithmetic** because reproducibility is non-negotiable for a certification claim. The LLM Council in Phase 2 handles narrative synthesis only — k independent judges assess qualitative data, a meta-judge produces a consensus, and the numeric aggregation is separate and deterministic.

**Phase 3 runs 5 narrative builders concurrently** because the 12 report sections have no inter-dependencies except one: the Recommendations section depends on the Limitations section, so it runs sequentially after. Everything else runs in parallel to minimise wall-clock time.

---

## What This Chapter Covers

| Section | Contents |
|---|---|
| [4.0 Architecture Overview](04-Pipeline/4.0-Architecture-Overview) | Full end-to-end flow with phase internals, output files, and design rationale |
| [4.1 Fault Bucketing](04-Pipeline/4.1-Fault-Bucketing) | Phase 0 deep-dive: the 3-pass classification algorithm |
| [4.2 Metrics Extraction](04-Pipeline/4.2-Metrics-Extraction) | Phase 1: quantitative and qualitative extraction passes |
| [4.3 Aggregation and LLM Council](04-Pipeline/4.3-Aggregation-and-LLM-Council) | Phase 2: deterministic stats and narrative synthesis |
| [4.4 Hypothesis Framework](04-Pipeline/4.4-Hypothesis-Framework) | Statistical hypothesis testing that activates at N ≥ 30 runs |

Start with [4.0 Architecture Overview](04-Pipeline/4.0-Architecture-Overview) for the complete flow diagram and output file layout.
