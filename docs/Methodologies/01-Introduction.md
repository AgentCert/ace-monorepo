---
title: "1 · Introduction"
parent: "Deep Dive"
nav_order: 1
nav_fold: true
---

# Introduction to AgentCert

AI agents fail silently. A pod restarts, network packets drop, a downstream API slows to a crawl — and the agent either handles it cleanly, hallucinates a recovery path, or misses it entirely. You usually find out in production.

AgentCert was built to change that. Instead of discovering failure modes at runtime, you inject controlled faults into a test environment, observe the agent's responses across dozens of independent runs, and produce a formal certification report before the agent ever sees production traffic.

---

## The Core Problem

Traditional testing breaks down on AI agents for two fundamental reasons.

**Non-determinism.** The same fault, the same prompt, the same cluster state — the agent may take a different path every time. A single test run tells you almost nothing. You need to run the experiment 20 or 30 times and reason statistically about what you observe across those runs. Pass/fail testing, the default mode of all CI frameworks, simply doesn't apply.

**Operational failures.** Unit tests and integration tests cannot surface the behaviours that actually matter in production: the agent that detects a pod deletion in 4 seconds on average but occasionally takes 45, the agent that performs well on network faults but quietly falls apart on DNS errors, the agent that handles tool failures safely in 29 out of 30 runs but not the 30th. These failure modes only emerge when you inject real chaos into a real environment and watch what happens.

AgentCert treats agent certification as an **empirical problem**, not a correctness problem.

---

## How AgentCert Solves It

The platform has three components working together:

**1 · Chaos injection.** LitmusChaos injects defined infrastructure faults (pod deletions, network packet loss, CPU hogs, DNS errors) into a Kubernetes cluster. The agent under test is given no hints — it must detect, diagnose, and respond on its own.

**2 · Trace capture.** Every LLM call, tool invocation, and reasoning step the agent makes is captured via Langfuse's OpenTelemetry integration. One trace file per run, containing the full agent behaviour.

**3 · Statistical certification.** The certifier pipeline consumes the traces from N runs and produces a 12-section certification report with statistical metrics (detection rate, p95 TTD, mitigation rate, RAI compliance score, hallucination score) backed by the raw evidence.

---

## What This Chapter Covers

| Section | Contents |
|---|---|
| [1.1 Why AgentCert](01-Introduction/1.1-Why-AgentCert) | The problem in detail and why traditional testing falls short |
| [1.2 High-Level Workflow](01-Introduction/1.2-High-Level-Workflow) | End-to-end flow from fault definition to certification report |
| [1.3 Certifier Assumptions](01-Introduction/1.3-Certifier-Assumptions) | What the pipeline assumes about your agent, environment, and traces |

Start with [1.1](01-Introduction/1.1-Why-AgentCert) if you are new to the platform. If you want the workflow picture first, jump to [1.2](01-Introduction/1.2-High-Level-Workflow).
