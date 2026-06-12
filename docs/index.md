---
title: Home
nav_order: 1
description: >-
  ACE certifies AI agents for production. Inject real failures, measure what
  actually happens, and get a formal report your board can read.
---

# Your AI agent works in the demo.
{: .fs-9 }

# Does it work when production breaks?
{: .fs-9 }

AI agents are making real decisions in real infrastructure. The question every stakeholder is now asking — your board, your customers, your risk team — is the one most teams still can't answer with evidence: *is it actually safe to ship?*
{: .fs-5 .fw-300 }

[Get certified →](setup/README.md){: .btn .btn-primary .fs-5 .mb-4 .mb-md-0 .mr-2 }
[Read the research ↗](https://arxiv.org/abs/2512.04123){: .btn .fs-5 .mb-4 .mb-md-0 .mr-2 }
[GitHub ↗](https://github.com/AgentCert/ace-monorepo){: .btn .fs-5 .mb-4 .mb-md-0 }

---

## The industry has a measurement problem

A landmark study — *[Measuring Agents in Production](https://arxiv.org/abs/2512.04123)*, accepted as an **oral presentation at ICML 2026** — surveyed 86 organizations deploying AI agents across 26 industries. It found reliability to be the #1 unresolved challenge in production AI deployment — ahead of performance, cost, and latency.

And it found something more uncomfortable than that:

<div style="border-left:4px solid #6366f1;padding:1rem 1.5rem;background:#f5f3ff;border-radius:0 8px 8px 0;margin:1.5rem 0;">
<p style="font-size:1.15rem;font-weight:700;color:#3730a3;margin:0 0 .4rem;">74% of teams still rely on human evaluation to know if their agent is working.</p>
<p style="color:#4c1d95;margin:0;font-size:.9rem;">Human reviewers. Spot-checks. Gut feel. That is the current state of the art in AI agent safety validation across the industry.</p>
</div>

When a pod crashes at 3am, a network degrades, or a database times out — does your agent detect it? Does it respond correctly? Does it hallucinate a recovery path? Does it expose sensitive data while doing so? Most teams don't have systematic answers to any of these questions, because they've never run the experiments that would produce them.

**AgentCert exists to close that gap.**

---

## From "we believe it's ready" to "here is the proof"

AgentCert doesn't run tests. It runs **certification experiments** — controlled, repeated, and statistically rigorous — and produces a formal report that holds up to scrutiny from anyone in the room.

| Without AgentCert | With AgentCert |
|---|---|
| Human reviewers sampling logs | Automated measurement across every run |
| One-off scenarios, single pass | 30+ independent runs per failure type |
| "It worked in our testing" | Detection rate, response time, worst-case behaviour |
| No systematic safety check | RAI compliance score, PII exposure rate, hallucination score |
| Opinion | A PDF your board, your customers, and your compliance team can read |

The output is not a dashboard. It is a **certification report** — 12 sections, formally structured, with the evidence chain visible from raw observation to final verdict. "Our agent is certified" becomes a statement you can back up with a document.

---

## Three steps from uncertainty to certified

**1 · Break things on purpose.**
Real infrastructure failures — services going down, networks degrading, resources running out — are injected into a controlled environment. Your agent faces them without warning, the same way it would in production.

**2 · Measure what actually happens.**
Every decision, every tool call, every second of response time is captured and measured. Not once — dozens of times per failure scenario. Statistical results, not anecdotes.

**3 · Receive a report you can stand behind.**
Detection rate. Time-to-detect at the 95th percentile. Hallucination score. Safety compliance. A pass/fail verdict with the data that produced it — in a PDF you can hand to anyone who asks.

---

### See the full pipeline

<div style="width:100%;height:450px;overflow:hidden;border-radius:10px;border:1px solid #e2e8f0;margin:1rem 0;background:#e8ecf2;">
  <iframe src="animated_archiecture/agentcert_workflow_animation.html" width="1480" height="830" frameborder="0" style="transform:scale(0.54);transform-origin:top left;"></iframe>
</div>

[Open full-screen ↗](animated_archiecture/agentcert_workflow_animation.html){: .btn .btn-primary .mb-4 }

---

## The report changes the conversation

A certification report is not a testing artifact. It is a **trust artifact**.

In a sales conversation, it turns "our agent is production-ready" from a claim into a document with specifics. In a board meeting, it turns "we believe the risk is low" into a scored, evidence-backed assessment. In a procurement review, it answers the questions legal and compliance will ask before any contract is signed. In an engineering post-mortem, it tells you exactly which failure type the agent couldn't handle and why.

The same report. Different rooms. Every room gets what it needs.

---

## Built on real research, released as open source

AgentCert is grounded in *[Measuring Agents in Production](https://arxiv.org/abs/2512.04123)* (Pan, Arabzadeh, Cogo et al., ICML 2026 oral). The paper studied 86 deployed systems, identified reliability and systematic evaluation as the central unsolved problems, and provided an empirical foundation for what a proper measurement framework needs to capture.

The platform is fully open source under the MIT License. The certification methodology, the evaluation framework, the report format — available to use, audit, extend, and contribute to.

[Explore on GitHub ↗](https://github.com/AgentCert/ace-monorepo){: .btn .btn-primary .mb-4 .mr-2 }
[Join the Slack community ↗](https://join.slack.com/t/agentcertific-evj3152/shared_invite/zt-4066ekqer-uIT~K_URfwiC15KlwT5Pjw){: .btn .mb-4 }

---

## Get started

The entire platform starts with one command. No infrastructure expertise required — ACE provisions everything it needs.

```bash
./scripts/setup.sh      # 2-minute setup wizard, asks only for your AI API key
docker compose up -d    # the full platform comes up
```

Open **[http://localhost:2001](http://localhost:2001)**, connect your agent, run your first experiment. First certification report in under an hour.

[Full setup guide →](setup/README.md){: .btn .btn-primary .fs-5 .mb-4 .mb-md-0 .mr-2 }
[Run your first experiment →](setup/running-an-experiment.md){: .btn .fs-5 .mb-4 .mb-md-0 }

---

## Go deeper

- **[Architecture](architecture.md)** — how the control plane, chaos engine, and certifier connect.
- **[Methodology](Methodologies/01-Introduction.md)** — the science behind the certification: experiment design, statistical framework, the 12-section report standard.
- **[API reference](api.md)** — connect certification to your CI/CD pipeline.
- **[Testing & coverage](testing.md)** — run the test suites and generate coverage reports.

---

<sub>ACE — Agent Certification Engine · MIT Licensed · [GitHub](https://github.com/AgentCert/ace-monorepo) · [Slack](https://join.slack.com/t/agentcertific-evj3152/shared_invite/zt-4066ekqer-uIT~K_URfwiC15KlwT5Pjw) · Based on research from *Measuring Agents in Production*, ICML 2026</sub>
