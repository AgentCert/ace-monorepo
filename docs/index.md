---
title: Home
nav_order: 1
description: >-
  ACE certifies AI agents for production. Inject real failures, measure what
  actually happens, and get a formal report your board can read.
---

<!-- ═══════════════════════════════════════════════════════ HERO ═══ -->
<div style="background:linear-gradient(135deg,#4338ca 0%,#6d28d9 55%,#9333ea 100%);color:#fff;padding:3.5rem 3rem 3.2rem;border-radius:18px;margin:0 0 2.5rem;box-shadow:0 24px 60px rgba(79,70,229,.22);">
<p style="font-size:.75rem;font-weight:700;letter-spacing:.14em;text-transform:uppercase;opacity:.72;margin:0 0 1.1rem 0;">Agent Certification Engine · Open Source · MIT Licensed</p>
<h1 style="color:#fff;font-size:2.55rem;font-weight:800;line-height:1.18;margin:0 0 1.1rem 0;padding:0;border:none;">Your AI agent works in the demo.<br>Does it work when production breaks?</h1>
<p style="font-size:1.08rem;opacity:.88;line-height:1.68;margin:0 0 2rem 0;max-width:580px;">AI agents are making real decisions in real infrastructure. The question every stakeholder is now asking — your board, your customers, your risk team — is the one most teams still can't answer with evidence: <em>is it actually safe to ship?</em></p>
<div style="display:flex;gap:.75rem;flex-wrap:wrap;align-items:center;">
<a href="setup/README.md" style="background:#fff;color:#4338ca;padding:.68rem 1.45rem;border-radius:9px;font-weight:700;text-decoration:none;font-size:.95rem;display:inline-block;white-space:nowrap;">Get certified →</a>
<a href="https://arxiv.org/abs/2512.04123" style="background:rgba(255,255,255,.14);color:#fff;padding:.68rem 1.45rem;border-radius:9px;font-weight:600;text-decoration:none;font-size:.95rem;border:1.5px solid rgba(255,255,255,.35);display:inline-block;white-space:nowrap;">Read the research ↗</a>
<a href="https://github.com/AgentCert/ace-monorepo" style="background:rgba(255,255,255,.14);color:#fff;padding:.68rem 1.45rem;border-radius:9px;font-weight:600;text-decoration:none;font-size:.95rem;border:1.5px solid rgba(255,255,255,.35);display:inline-block;white-space:nowrap;">GitHub ↗</a>
</div>
</div>

<!-- ═══════════════════════════════════════════════ STAT CARDS ═══ -->
<div style="display:grid;grid-template-columns:repeat(3,1fr);gap:1rem;margin:0 0 2.8rem;">
<div style="background:#faf5ff;border:1.5px solid #ddd6fe;border-radius:13px;padding:1.4rem 1.2rem;text-align:center;">
<div style="font-size:2.4rem;font-weight:800;color:#6d28d9;line-height:1;">74%</div>
<div style="font-size:.82rem;color:#6b7280;margin-top:.45rem;line-height:1.45;">of teams rely on<br>human evaluation</div>
</div>
<div style="background:#eff6ff;border:1.5px solid #bfdbfe;border-radius:13px;padding:1.4rem 1.2rem;text-align:center;">
<div style="font-size:2.4rem;font-weight:800;color:#1d4ed8;line-height:1;">86</div>
<div style="font-size:.82rem;color:#6b7280;margin-top:.45rem;line-height:1.45;">organizations studied<br>across 26 industries</div>
</div>
<div style="background:#f0fdf4;border:1.5px solid #bbf7d0;border-radius:13px;padding:1.4rem 1.2rem;text-align:center;">
<div style="font-size:2.4rem;font-weight:800;color:#15803d;line-height:1;">#1</div>
<div style="font-size:.82rem;color:#6b7280;margin-top:.45rem;line-height:1.45;">reliability: unresolved<br>challenge in prod AI</div>
</div>
</div>

<!-- ═══════════════════════════════════════════ MEASUREMENT GAP ═══ -->
<div style="margin:0 0 2.8rem;">
<h2 style="font-size:1.55rem;font-weight:700;margin:0 0 .9rem;">The industry has a measurement problem</h2>
<p>A landmark study — <a href="https://arxiv.org/abs/2512.04123"><em>Measuring Agents in Production</em></a>, accepted as an <strong>oral presentation at ICML 2026</strong> — surveyed 86 organisations deploying AI agents across 26 industries. It found reliability to be the #1 unresolved challenge in production AI deployment — ahead of performance, cost, and latency.</p>
<div style="border-left:4px solid #6d28d9;padding:1rem 1.4rem;background:#faf5ff;border-radius:0 10px 10px 0;margin:1.2rem 0;">
<p style="font-size:1.08rem;font-weight:700;color:#3730a3;margin:0 0 .3rem 0;">74% of teams still rely on human evaluation to know if their agent is working.</p>
<p style="color:#5b21b6;margin:0;font-size:.9rem;">Human reviewers. Spot-checks. Gut feel. That is the current state of the art in AI agent safety validation across the industry.</p>
</div>
<p>When a pod crashes at 3 am, a network degrades, or a database times out — does your agent detect it? Does it respond correctly? Does it hallucinate a recovery path? Does it expose sensitive data while doing so? Most teams don't have systematic answers to any of these questions, because they've never run the experiments that would produce them.</p>
<p><strong>AgentCert exists to close that gap.</strong></p>
</div>

<!-- ═══════════════════════════════════════════════ BEFORE/AFTER ═══ -->
<h2 style="font-size:1.55rem;font-weight:700;margin:0 0 1rem;">From "we believe it's ready" to "here is the proof"</h2>
<p style="margin:0 0 1.2rem;">AgentCert doesn't run tests. It runs <strong>certification experiments</strong> — controlled, repeated, and statistically rigorous — and produces a formal report that holds up to scrutiny from anyone in the room.</p>

<div style="display:grid;grid-template-columns:1fr 1fr;gap:1rem;margin:0 0 2.8rem;">
<div style="background:#fff5f5;border:1.5px solid #fecaca;border-radius:13px;padding:1.4rem 1.5rem;">
<p style="font-size:.72rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#dc2626;margin:0 0 .9rem 0;">Without AgentCert</p>
<ul style="margin:0;padding-left:1.2rem;color:#374151;font-size:.92rem;line-height:2;">
<li>Human reviewers sampling logs</li>
<li>One-off scenarios, single pass</li>
<li>"It worked in our testing"</li>
<li>No systematic safety check</li>
<li>Opinion</li>
</ul>
</div>
<div style="background:#f0fdf4;border:1.5px solid #86efac;border-radius:13px;padding:1.4rem 1.5rem;">
<p style="font-size:.72rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#15803d;margin:0 0 .9rem 0;">With AgentCert</p>
<ul style="margin:0;padding-left:1.2rem;color:#374151;font-size:.92rem;line-height:2;">
<li>Automated measurement across every run</li>
<li>30+ independent runs per failure type</li>
<li>Detection rate, P95 response time, worst-case</li>
<li>RAI compliance score, PII rate, hallucination score</li>
<li>A PDF your board, legal, and customers can read</li>
</ul>
</div>
</div>

<!-- ════════════════════════════════════════════════ THREE STEPS ═══ -->
<h2 style="font-size:1.55rem;font-weight:700;margin:0 0 1.2rem;">Three steps from uncertainty to certified</h2>

<div style="display:grid;grid-template-columns:repeat(3,1fr);gap:1rem;margin:0 0 2.8rem;">
<div style="background:#fff;border:1.5px solid #e5e7eb;border-radius:13px;padding:1.5rem 1.3rem;position:relative;">
<div style="width:2.2rem;height:2.2rem;background:linear-gradient(135deg,#4338ca,#6d28d9);border-radius:50%;display:flex;align-items:center;justify-content:center;margin:0 0 .9rem 0;font-size:1rem;font-weight:800;color:#fff;line-height:1;">1</div>
<h3 style="font-size:1rem;font-weight:700;margin:0 0 .5rem 0;color:#111827;">Break things on purpose</h3>
<p style="font-size:.88rem;color:#6b7280;margin:0;line-height:1.55;">Real infrastructure failures — services down, networks degrading, resources exhausted — injected into a controlled environment. Your agent faces them without warning.</p>
</div>
<div style="background:#fff;border:1.5px solid #e5e7eb;border-radius:13px;padding:1.5rem 1.3rem;">
<div style="width:2.2rem;height:2.2rem;background:linear-gradient(135deg,#4338ca,#6d28d9);border-radius:50%;display:flex;align-items:center;justify-content:center;margin:0 0 .9rem 0;font-size:1rem;font-weight:800;color:#fff;line-height:1;">2</div>
<h3 style="font-size:1rem;font-weight:700;margin:0 0 .5rem 0;color:#111827;">Measure what actually happens</h3>
<p style="font-size:.88rem;color:#6b7280;margin:0;line-height:1.55;">Every decision, every tool call, every second of response time captured and measured. Not once — dozens of times per failure scenario. Statistical results, not anecdotes.</p>
</div>
<div style="background:#fff;border:1.5px solid #e5e7eb;border-radius:13px;padding:1.5rem 1.3rem;">
<div style="width:2.2rem;height:2.2rem;background:linear-gradient(135deg,#4338ca,#6d28d9);border-radius:50%;display:flex;align-items:center;justify-content:center;margin:0 0 .9rem 0;font-size:1rem;font-weight:800;color:#fff;line-height:1;">3</div>
<h3 style="font-size:1rem;font-weight:700;margin:0 0 .5rem 0;color:#111827;">Receive a report you can stand behind</h3>
<p style="font-size:.88rem;color:#6b7280;margin:0;line-height:1.55;">Detection rate. P95 time-to-detect. Hallucination score. Safety compliance. A pass/fail verdict with the data that produced it — in a PDF you can hand to anyone who asks.</p>
</div>
</div>

<!-- ════════════════════════════════════════════════ ANIMATION ═══ -->
<h2 style="font-size:1.55rem;font-weight:700;margin:0 0 .8rem;">See the full pipeline</h2>

<div style="width:100%;height:450px;overflow:hidden;border-radius:14px;border:1.5px solid #e5e7eb;margin:0 0 .8rem 0;background:#e8ecf2;box-shadow:0 4px 24px rgba(0,0,0,.07);">
  <iframe src="animated_archiecture/agentcert_workflow_animation.html" width="1480" height="830" frameborder="0" style="transform:scale(0.54);transform-origin:top left;"></iframe>
</div>

<p style="margin:0 0 2.8rem .1rem;"><a href="animated_archiecture/agentcert_workflow_animation.html">Open full-screen ↗</a></p>

<!-- ════════════════════════════════════════════ REPORT CHANGES ═══ -->
<div style="background:linear-gradient(135deg,#1e1b4b 0%,#312e81 100%);color:#fff;padding:2.5rem 2.8rem;border-radius:16px;margin:0 0 2.8rem;box-shadow:0 16px 48px rgba(30,27,75,.25);">
<h2 style="color:#fff;font-size:1.45rem;font-weight:700;margin:0 0 .9rem 0;padding:0;border:none;">The report changes the conversation</h2>
<p style="opacity:.88;line-height:1.7;margin:0 0 .9rem 0;font-size:.97rem;">A certification report is not a testing artifact. It is a <strong style="color:#c4b5fd;">trust artifact</strong>.</p>
<div style="display:grid;grid-template-columns:1fr 1fr;gap:1.1rem;margin-top:1.2rem;">
<div style="background:rgba(255,255,255,.08);border-radius:10px;padding:1.1rem 1.2rem;">
<p style="font-size:.75rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#a5b4fc;margin:0 0 .4rem 0;">In a sales conversation</p>
<p style="font-size:.9rem;opacity:.85;margin:0;line-height:1.5;">Turns "our agent is production-ready" from a claim into a document with specifics.</p>
</div>
<div style="background:rgba(255,255,255,.08);border-radius:10px;padding:1.1rem 1.2rem;">
<p style="font-size:.75rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#a5b4fc;margin:0 0 .4rem 0;">In a board meeting</p>
<p style="font-size:.9rem;opacity:.85;margin:0;line-height:1.5;">Turns "we believe the risk is low" into a scored, evidence-backed assessment.</p>
</div>
<div style="background:rgba(255,255,255,.08);border-radius:10px;padding:1.1rem 1.2rem;">
<p style="font-size:.75rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#a5b4fc;margin:0 0 .4rem 0;">In a procurement review</p>
<p style="font-size:.9rem;opacity:.85;margin:0;line-height:1.5;">Answers the questions legal and compliance will ask before any contract is signed.</p>
</div>
<div style="background:rgba(255,255,255,.08);border-radius:10px;padding:1.1rem 1.2rem;">
<p style="font-size:.75rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#a5b4fc;margin:0 0 .4rem 0;">In an engineering post-mortem</p>
<p style="font-size:.9rem;opacity:.85;margin:0;line-height:1.5;">Tells you exactly which failure type the agent couldn't handle, and why.</p>
</div>
</div>
<p style="opacity:.7;font-size:.88rem;margin:1.2rem 0 0 0;">The same report. Different rooms. Every room gets what it needs.</p>
</div>

<!-- ══════════════════════════════════════════════════ RESEARCH ═══ -->
<div style="background:#fafafa;border:1.5px solid #e5e7eb;border-radius:13px;padding:1.6rem 1.8rem;margin:0 0 2.8rem;display:flex;gap:1.5rem;align-items:flex-start;">
<div style="font-size:2rem;line-height:1;flex-shrink:0;margin-top:.1rem;">📄</div>
<div>
<h3 style="font-size:1rem;font-weight:700;margin:0 0 .4rem 0;color:#111827;">Built on peer-reviewed research</h3>
<p style="font-size:.9rem;color:#4b5563;margin:0;line-height:1.6;">AgentCert is grounded in <a href="https://arxiv.org/abs/2512.04123"><em>Measuring Agents in Production</em></a> (Pan, Arabzadeh, Cogo et al.) — accepted as an <strong>oral presentation at ICML 2026</strong>. The paper studied 86 deployed systems, identified reliability and systematic evaluation as the central unsolved problems, and provided an empirical foundation for what a proper measurement framework needs to capture. The platform is fully open source under the MIT License.</p>
</div>
</div>

<!-- ══════════════════════════════════════════════ GET STARTED ═══ -->
<div style="background:#f8fafc;border:1.5px solid #e2e8f0;border-radius:13px;padding:2rem 2rem 1.6rem;margin:0 0 2.8rem;">
<h2 style="font-size:1.45rem;font-weight:700;margin:0 0 .6rem 0;">Get started in minutes</h2>
<p style="color:#6b7280;margin:0 0 1.2rem 0;font-size:.95rem;">The entire platform starts with one command. No infrastructure expertise required.</p>

```bash
./scripts/setup.sh      # 2-minute setup wizard, asks only for your AI API key
docker compose up -d    # the full platform comes up
```

<p style="color:#6b7280;font-size:.9rem;margin:.9rem 0 1.4rem 0;">Open <strong>http://localhost:2001</strong>, connect your agent, run your first experiment. First certification report in under an hour.</p>
<div style="display:flex;gap:.75rem;flex-wrap:wrap;">
<a href="setup/README.md" style="background:#4338ca;color:#fff;padding:.65rem 1.3rem;border-radius:9px;font-weight:700;text-decoration:none;font-size:.92rem;display:inline-block;">Full setup guide →</a>
<a href="setup/running-an-experiment.md" style="background:#fff;color:#374151;padding:.65rem 1.3rem;border-radius:9px;font-weight:600;text-decoration:none;font-size:.92rem;border:1.5px solid #d1d5db;display:inline-block;">Run your first experiment →</a>
</div>
</div>

<!-- ══════════════════════════════════════════════════ GO DEEPER ═══ -->
<div style="display:grid;grid-template-columns:repeat(2,1fr);gap:1rem;margin:0 0 2rem;">
<a href="architecture.md" style="background:#fff;border:1.5px solid #e5e7eb;border-radius:12px;padding:1.3rem 1.4rem;text-decoration:none;display:block;transition:border-color .2s;" onmouseover="this.style.borderColor='#6d28d9'" onmouseout="this.style.borderColor='#e5e7eb'">
<p style="font-size:.72rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#6d28d9;margin:0 0 .3rem 0;">Architecture</p>
<p style="font-weight:600;color:#111827;margin:0 0 .3rem 0;font-size:.97rem;">How the platform fits together</p>
<p style="font-size:.85rem;color:#6b7280;margin:0;">Control plane, chaos engine, certifier — and how they connect.</p>
</a>
<a href="Methodologies/01-Introduction.md" style="background:#fff;border:1.5px solid #e5e7eb;border-radius:12px;padding:1.3rem 1.4rem;text-decoration:none;display:block;" onmouseover="this.style.borderColor='#6d28d9'" onmouseout="this.style.borderColor='#e5e7eb'">
<p style="font-size:.72rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#6d28d9;margin:0 0 .3rem 0;">Methodology</p>
<p style="font-weight:600;color:#111827;margin:0 0 .3rem 0;font-size:.97rem;">The science behind certification</p>
<p style="font-size:.85rem;color:#6b7280;margin:0;">Experiment design, statistical framework, the 12-section report standard.</p>
</a>
<a href="api.md" style="background:#fff;border:1.5px solid #e5e7eb;border-radius:12px;padding:1.3rem 1.4rem;text-decoration:none;display:block;" onmouseover="this.style.borderColor='#6d28d9'" onmouseout="this.style.borderColor='#e5e7eb'">
<p style="font-size:.72rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#6d28d9;margin:0 0 .3rem 0;">API Reference</p>
<p style="font-weight:600;color:#111827;margin:0 0 .3rem 0;font-size:.97rem;">Integrate with your CI/CD pipeline</p>
<p style="font-size:.85rem;color:#6b7280;margin:0;">Connect certification runs to your deployment workflow.</p>
</a>
<a href="testing.md" style="background:#fff;border:1.5px solid #e5e7eb;border-radius:12px;padding:1.3rem 1.4rem;text-decoration:none;display:block;" onmouseover="this.style.borderColor='#6d28d9'" onmouseout="this.style.borderColor='#e5e7eb'">
<p style="font-size:.72rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#6d28d9;margin:0 0 .3rem 0;">Testing & Coverage</p>
<p style="font-weight:600;color:#111827;margin:0 0 .3rem 0;font-size:.97rem;">Run the test suites</p>
<p style="font-size:.85rem;color:#6b7280;margin:0;">Unit, integration, and coverage reports for all platform components.</p>
</a>
</div>

---

<sub>ACE — Agent Certification Engine · MIT Licensed · [GitHub](https://github.com/AgentCert/ace-monorepo) · [Slack](https://join.slack.com/t/agentcertific-evj3152/shared_invite/zt-4066ekqer-uIT~K_URfwiC15KlwT5Pjw) · Based on research from <em>Measuring Agents in Production</em>, ICML 2026</sub>
