---
title: Home
nav_order: 1
description: >-
  ACE certifies AI agents for production. Inject real failures, measure what
  actually happens, and get a formal report your board can read.
---

<!-- ═══════════════════════════════════════════════════════ HERO ═══ -->
<div style="background:linear-gradient(135deg,#4338ca 0%,#6d28d9 55%,#9333ea 100%);color:#fff;padding:3.5rem 3rem 3.2rem;border-radius:18px;margin:0 0 2.5rem;box-shadow:0 24px 60px rgba(79,70,229,.22);">
<div style="display:flex;gap:.6rem;flex-wrap:wrap;margin:0 0 1.1rem 0;align-items:center;">
<span style="background:rgba(255,255,255,.18);border:1px solid rgba(255,255,255,.35);border-radius:6px;padding:.25rem .7rem;font-size:.72rem;font-weight:700;letter-spacing:.08em;text-transform:uppercase;">Infosys × Microsoft</span>
<span style="background:rgba(255,255,255,.18);border:1px solid rgba(255,255,255,.35);border-radius:6px;padding:.25rem .7rem;font-size:.72rem;font-weight:700;letter-spacing:.08em;text-transform:uppercase;">Open Source · MIT</span>
<span style="background:rgba(255,255,255,.18);border:1px solid rgba(255,255,255,.35);border-radius:6px;padding:.25rem .7rem;font-size:.72rem;font-weight:700;letter-spacing:.08em;text-transform:uppercase;">Inspired by AIOpsLab</span>
<span style="background:rgba(255,255,255,.18);border:1px solid rgba(255,255,255,.35);border-radius:6px;padding:.25rem .7rem;font-size:.72rem;font-weight:700;letter-spacing:.08em;text-transform:uppercase;">Built on LitmusChaos · LFN</span>
</div>
<h1 style="color:#fff;font-size:2.55rem;font-weight:800;line-height:1.18;margin:0 0 1.1rem 0;padding:0;border:none;">Your AI agent works in the demo.<br>Does it work when production breaks?</h1>
<p style="font-size:1.08rem;opacity:.88;line-height:1.68;margin:0 0 2rem 0;max-width:580px;">AI agents are making real decisions in real infrastructure. The question every stakeholder is now asking — your board, your customers, your risk team — is the one most teams still can't answer with evidence: <em>is it actually safe to ship?</em></p>
<div style="display:flex;gap:.75rem;flex-wrap:wrap;align-items:center;">
<a href="{{ "/setup/README.html" | relative_url }}" style="background:#fff;color:#4338ca;padding:.68rem 1.45rem;border-radius:9px;font-weight:700;text-decoration:none;font-size:.95rem;display:inline-block;white-space:nowrap;">Get certified →</a>
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

<div id="ace-anim-wrap" style="width:100%;overflow:hidden;border-radius:14px;border:1.5px solid #e5e7eb;margin:0 0 .8rem 0;background:#e8ecf2;box-shadow:0 4px 24px rgba(0,0,0,.07);">
  <iframe id="ace-anim" src="animated_archiecture/agentcert_workflow_animation.html" width="1480" height="830" frameborder="0" style="transform-origin:top left;display:block;"></iframe>
</div>
<script>
(function(){
  var wrap = document.getElementById('ace-anim-wrap');
  var frame = document.getElementById('ace-anim');
  function resize(){
    var s = wrap.offsetWidth / 1480;
    frame.style.transform = 'scale('+s+')';
    wrap.style.height = Math.round(830 * s) + 'px';
  }
  resize();
  window.addEventListener('resize', resize);
})();
</script>

<p style="margin:0 0 2.8rem .1rem;"><a href="animated_archiecture/agentcert_workflow_animation.html">Open full-screen ↗</a></p>

<!-- ══════════════════════════════════════════════════ SRE STORY ═══ -->
<div style="margin:0 0 2.8rem;">

<div style="background:#eff6ff;border:1.5px solid #bfdbfe;border-radius:12px;padding:1.1rem 1.4rem;margin:0 0 1.6rem;display:flex;gap:1rem;align-items:flex-start;">
<div style="font-size:1.4rem;flex-shrink:0;">🔬</div>
<div>
<p style="font-size:.8rem;font-weight:700;color:#1d4ed8;letter-spacing:.08em;text-transform:uppercase;margin:0 0 .3rem;">Origin</p>
<p style="font-size:.9rem;color:#1e3a5f;margin:0;line-height:1.6;"><strong>ACE is a joint Infosys × Microsoft open source project.</strong> It is inspired by <a href="https://github.com/microsoft/AIOpsLab" style="color:#1d4ed8;"><strong>AIOpsLab</strong></a> — Microsoft Research's open benchmark framework for AI-powered IT operations. AIOpsLab defined the problem space: how do you evaluate AI agents against realistic production failures? ACE answers it with chaos engineering, statistical rigour, and a formal certification report.</p>
<p style="font-size:.9rem;color:#1e3a5f;margin:.6rem 0 0;line-height:1.6;">The chaos engineering layer is built on <a href="https://litmuschaos.io" style="color:#1d4ed8;"><strong>LitmusChaos</strong></a> — a <strong>Linux Foundation Networking (LFN)</strong> project — extended with agentic scenario support: trace-correlated fault injection, agent health scheduling, and the statistical certification pipeline that turns raw Langfuse traces into a formal report.</p>
</div>
</div>

<h2 style="font-size:1.55rem;font-weight:700;margin:0 0 .8rem;">We put the SRE agent through 30 failure scenarios. Here is what we found.</h2>
<p style="color:#374151;line-height:1.75;margin:0 0 .8rem;">The agent under test is an SRE agent built on top of <strong>Microsoft's Flash ITOps agent</strong> — an LLM-powered system capable of investigating alerts, pulling Kubernetes traces, running diagnostics, and executing runbooks autonomously via MCP. The target environment is SockShop, the same microservices benchmark used by AIOpsLab and Microsoft Research.</p>
<p style="color:#374151;line-height:1.75;margin:0 0 .8rem;">The question we needed to answer was not "does it work?" — it had already passed internal testing. The question was <strong>what happens when production is genuinely broken at the infrastructure level</strong>: when the monitoring service the agent depends on is itself degraded, when pod-status tool calls return stale data, when the runbook vector store times out mid-investigation, when disk-fill and container-kill arrive simultaneously at 3 am.</p>

<div style="display:grid;grid-template-columns:repeat(4,1fr);gap:.9rem;margin:1.4rem 0;">
<div style="background:#faf5ff;border:1.5px solid #ddd6fe;border-radius:11px;padding:1.1rem;text-align:center;">
<div style="font-size:1.8rem;font-weight:800;color:#6d28d9;">30+</div>
<div style="font-size:.78rem;color:#7c3aed;margin-top:.3rem;line-height:1.4;font-weight:600;">chaos scenarios<br>injected</div>
</div>
<div style="background:#eff6ff;border:1.5px solid #bfdbfe;border-radius:11px;padding:1.1rem;text-align:center;">
<div style="font-size:1.8rem;font-weight:800;color:#1d4ed8;">30×</div>
<div style="font-size:.78rem;color:#1d4ed8;margin-top:.3rem;line-height:1.4;font-weight:600;">independent runs<br>per scenario</div>
</div>
<div style="background:#f0fdf4;border:1.5px solid #bbf7d0;border-radius:11px;padding:1.1rem;text-align:center;">
<div style="font-size:1.8rem;font-weight:800;color:#15803d;">12</div>
<div style="font-size:.78rem;color:#15803d;margin-top:.3rem;line-height:1.4;font-weight:600;">report sections<br>generated</div>
</div>
<div style="background:#fff7ed;border:1.5px solid #fed7aa;border-radius:11px;padding:1.1rem;text-align:center;">
<div style="font-size:1.8rem;font-weight:800;color:#c2410c;">P95</div>
<div style="font-size:.78rem;color:#c2410c;margin-top:.3rem;line-height:1.4;font-weight:600;">time-to-detect<br>measured</div>
</div>
</div>

<p style="color:#374151;line-height:1.75;margin:0;">The result was a 12-section certification report with real numbers across detection rate, P95 time-to-detect, tool-call failure handling, hallucination rate, and PII exposure under stress. Some results were reassuring. Some told us exactly what to fix before shipping. All of it was documented, reproducible, and shareable with anyone who needed to understand whether this agent was ready. <strong>That is the report AgentCert generates. The SRE agent is the first thing it certified.</strong></p>
</div>

<!-- ══════════════════════════════════════════ DOMAIN EXPANSION ═══ -->
<h2 style="font-size:1.55rem;font-weight:700;margin:0 0 .5rem;">Same architecture. Every domain.</h2>
<p style="color:#6b7280;margin:0 0 1.5rem;line-height:1.7;">The three phases that worked for the SRE agent — fault injection, systematic measurement, formal report — apply to any agent in any domain. What changes between domains is the <strong>fault library</strong>: the catalogue of failure scenarios that matter for your stack and your risk profile. ACE ships with the SRE library and a framework for extending it. The community builds the rest.</p>

<div style="display:grid;grid-template-columns:repeat(3,1fr);gap:1rem;margin:0 0 2.8rem;">
<div style="background:#fff;border:1.5px solid #e5e7eb;border-radius:13px;padding:1.4rem;border-top:3px solid #dc2626;">
<div style="font-size:1.3rem;margin:0 0 .5rem;">🏥</div>
<p style="font-size:.72rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#dc2626;margin:0 0 .25rem;">Healthcare & Life Sciences</p>
<p style="font-size:.78rem;color:#9ca3af;margin:0 0 .7rem;">Diagnostic triage · clinical decision support · adverse-event detection</p>
<p style="font-size:.88rem;color:#374151;margin:0;line-height:1.6;">When a records service degrades, does the agent fail safely or continue on incomplete data? In healthcare, a silent degradation is not a bug. It is a missed diagnosis. Certification documents exactly what the agent does when the data it trusts goes wrong.</p>
</div>
<div style="background:#fff;border:1.5px solid #e5e7eb;border-radius:13px;padding:1.4rem;border-top:3px solid #0284c7;">
<div style="font-size:1.3rem;margin:0 0 .5rem;">💹</div>
<p style="font-size:.72rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#0284c7;margin:0 0 .25rem;">Financial Services</p>
<p style="font-size:.78rem;color:#9ca3af;margin:0 0 .7rem;">Trading execution · fraud scoring · risk assessment · compliance monitoring</p>
<p style="font-size:.88rem;color:#374151;margin:0;line-height:1.6;">Feed outages and latency spikes are not edge cases in finance — they are Tuesday. An agent silently falling back to stale pricing data does not just lose money. It creates regulatory exposure. Certification proves the recovery behaviour is documented and intentional.</p>
</div>
<div style="background:#fff;border:1.5px solid #e5e7eb;border-radius:13px;padding:1.4rem;border-top:3px solid #7c3aed;">
<div style="font-size:1.3rem;margin:0 0 .5rem;">⚙️</div>
<p style="font-size:.72rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#7c3aed;margin:0 0 .25rem;">DevOps & SRE</p>
<p style="font-size:.78rem;color:#9ca3af;margin:0 0 .7rem;">Incident response · runbook automation · on-call triage · root cause analysis</p>
<p style="font-size:.88rem;color:#374151;margin:0;line-height:1.6;">When the observability stack itself is degraded and the tools the agent uses to diagnose the situation return corrupted data — what does it decide? This is where ACE started. Certify before it handles your on-call.</p>
</div>
<div style="background:#fff;border:1.5px solid #e5e7eb;border-radius:13px;padding:1.4rem;border-top:3px solid #b45309;">
<div style="font-size:1.3rem;margin:0 0 .5rem;">⚖️</div>
<p style="font-size:.72rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#b45309;margin:0 0 .25rem;">Legal & Compliance</p>
<p style="font-size:.78rem;color:#9ca3af;margin:0 0 .7rem;">Contract review · regulatory monitoring · policy enforcement · audit trail generation</p>
<p style="font-size:.88rem;color:#374151;margin:0;line-height:1.6;">Professional liability begins where documentation ends. A RAI compliance failure in this domain is not a UX issue — it is an audit finding. Certification provides the evidence trail that demonstrates due diligence before questions are asked.</p>
</div>
<div style="background:#fff;border:1.5px solid #e5e7eb;border-radius:13px;padding:1.4rem;border-top:3px solid #059669;">
<div style="font-size:1.3rem;margin:0 0 .5rem;">🛒</div>
<p style="font-size:.72rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#059669;margin:0 0 .25rem;">E-commerce & Retail</p>
<p style="font-size:.78rem;color:#9ca3af;margin:0 0 .7rem;">Recommendations · dynamic pricing · inventory management · supply chain</p>
<p style="font-size:.88rem;color:#374151;margin:0;line-height:1.6;">An agent recommending out-of-stock products or applying an expired promotion after a cache failure costs more than the order value. At the scale retail agents operate, reliability is a brand and margin problem simultaneously.</p>
</div>
<div style="background:#fff;border:1.5px solid #e5e7eb;border-radius:13px;padding:1.4rem;border-top:3px solid #4338ca;">
<div style="font-size:1.3rem;margin:0 0 .5rem;">🔧</div>
<p style="font-size:.72rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#4338ca;margin:0 0 .25rem;">Software Engineering</p>
<p style="font-size:.78rem;color:#9ca3af;margin:0 0 .7rem;">Code review · test generation · deployment automation · security scanning</p>
<p style="font-size:.88rem;color:#374151;margin:0;line-height:1.6;">The delivery pipeline is being handed to agents. When tool-calling infrastructure rate-limits or returns partial results, does your agent produce garbage silently — or degrade gracefully and tell you? The answer belongs in a report, not a post-mortem.</p>
</div>
</div>

<!-- ═══════════════════════════════════════════════ COLLABORATE ═══ -->
<div style="background:linear-gradient(135deg,#1e1b4b 0%,#312e81 100%);color:#fff;padding:2.5rem 2.8rem;border-radius:16px;margin:0 0 2.8rem;box-shadow:0 16px 48px rgba(30,27,75,.22);">
<div style="display:flex;gap:.7rem;margin:0 0 1rem;flex-wrap:wrap;">
<span style="background:rgba(255,255,255,.15);border:1px solid rgba(255,255,255,.3);border-radius:6px;padding:.2rem .7rem;font-size:.72rem;font-weight:700;letter-spacing:.08em;text-transform:uppercase;">Infosys</span>
<span style="opacity:.5;font-size:1rem;line-height:1.6;">×</span>
<span style="background:rgba(255,255,255,.15);border:1px solid rgba(255,255,255,.3);border-radius:6px;padding:.2rem .7rem;font-size:.72rem;font-weight:700;letter-spacing:.08em;text-transform:uppercase;">Microsoft</span>
<span style="opacity:.5;font-size:1rem;line-height:1.6;">·</span>
<span style="background:rgba(255,255,255,.15);border:1px solid rgba(255,255,255,.3);border-radius:6px;padding:.2rem .7rem;font-size:.72rem;font-weight:700;letter-spacing:.08em;text-transform:uppercase;">Extends AIOpsLab</span>
</div>
<h2 style="color:#fff;font-size:1.45rem;font-weight:700;margin:0 0 .7rem 0;padding:0;border:none;">Open to build on. Designed for collaboration.</h2>
<p style="opacity:.85;line-height:1.7;margin:0 0 1.5rem 0;font-size:.97rem;max-width:680px;">ACE is an open source project jointly developed by <strong style="color:#c4b5fd;">Infosys</strong> and <strong style="color:#c4b5fd;">Microsoft</strong>, extending Microsoft Research's <a href="https://github.com/microsoft/AIOpsLab" style="color:#a5b4fc;font-weight:600;">AIOpsLab</a> with chaos engineering, statistical certification, and a formal report standard. The most important thing it can become is the open benchmark for AI agent reliability across every domain — and that requires contributors from every domain.</p>
<div style="display:grid;grid-template-columns:repeat(2,1fr);gap:1rem;">
<div style="background:rgba(255,255,255,.08);border-radius:10px;padding:1.2rem 1.3rem;">
<p style="font-size:.75rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#a5b4fc;margin:0 0 .4rem 0;">Extend AIOpsLab fault scenarios</p>
<p style="font-size:.88rem;opacity:.82;margin:0;line-height:1.55;">AIOpsLab defines the benchmark. ACE makes it certifiable. Add fault scenarios for your cloud provider, agent framework, or domain — growing the shared library that every certification draws from.</p>
</div>
<div style="background:rgba(255,255,255,.08);border-radius:10px;padding:1.2rem 1.3rem;">
<p style="font-size:.75rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#a5b4fc;margin:0 0 .4rem 0;">Certify your own agent</p>
<p style="font-size:.88rem;opacity:.82;margin:0;line-height:1.55;">Have an ITOps, SRE, or domain agent built on AutoGen, LangChain, Semantic Kernel, or your own stack? Run ACE against it. The certification framework is agent-agnostic by design.</p>
</div>
<div style="background:rgba(255,255,255,.08);border-radius:10px;padding:1.2rem 1.3rem;">
<p style="font-size:.75rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#a5b4fc;margin:0 0 .4rem 0;">Gate deployments on certification</p>
<p style="font-size:.88rem;opacity:.82;margin:0;line-height:1.55;">The ACE API integrates with CI/CD. Run a certification experiment as a deployment gate — if detection rate drops below threshold, the deploy doesn't go. Reliability as a hard requirement, not a soft hope.</p>
</div>
<div style="background:rgba(255,255,255,.08);border-radius:10px;padding:1.2rem 1.3rem;">
<p style="font-size:.75rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#a5b4fc;margin:0 0 .4rem 0;">Build domain certifiers</p>
<p style="font-size:.88rem;opacity:.82;margin:0;line-height:1.55;">The SRE certifier is the first. Healthcare, finance, legal, and DevSec each have different failure modes and different evidence requirements. Build the certifier for your domain and contribute it as a plugin.</p>
</div>
</div>
<div style="margin-top:1.5rem;display:flex;gap:.75rem;flex-wrap:wrap;">
<a href="https://github.com/AgentCert/ace-monorepo" style="background:#fff;color:#312e81;padding:.6rem 1.3rem;border-radius:8px;font-weight:700;text-decoration:none;font-size:.9rem;display:inline-block;">Contribute on GitHub ↗</a>
<a href="https://github.com/microsoft/AIOpsLab" style="background:rgba(255,255,255,.14);color:#fff;padding:.6rem 1.3rem;border-radius:8px;font-weight:600;text-decoration:none;font-size:.9rem;border:1.5px solid rgba(255,255,255,.3);display:inline-block;">AIOpsLab on GitHub ↗</a>
<a href="https://join.slack.com/t/agentcertific-evj3152/shared_invite/zt-4066ekqer-uIT~K_URfwiC15KlwT5Pjw" style="background:rgba(255,255,255,.14);color:#fff;padding:.6rem 1.3rem;border-radius:8px;font-weight:600;text-decoration:none;font-size:.9rem;border:1.5px solid rgba(255,255,255,.3);display:inline-block;">Join the Slack ↗</a>
</div>
</div>

<!-- ══════════════════════════════════════════════ GET STARTED ═══ -->
<div style="background:#f8fafc;border:1.5px solid #e2e8f0;border-radius:13px;padding:2rem 2rem 1.6rem;margin:0 0 2.8rem;">
<h2 style="font-size:1.45rem;font-weight:700;margin:0 0 .4rem 0;">Get started in 5 minutes</h2>
<p style="color:#6b7280;margin:0 0 1.1rem 0;font-size:.95rem;">Clone the repo, run the wizard, bring up the stack. Everything — Kubernetes, Langfuse, LiteLLM, certifier — starts with one command.</p>
<pre style="background:#1e1b4b;color:#e2e8f0;border-radius:10px;padding:1.2rem 1.4rem;font-size:.85rem;line-height:1.7;overflow-x:auto;margin:0 0 1rem;"><code>git clone --recurse-submodules https://github.com/AgentCert/ace-monorepo
cd ace-monorepo
./scripts/setup.sh          # asks only for your Azure OpenAI key
docker compose up -d        # entire platform comes up</code></pre>
<p style="color:#6b7280;font-size:.9rem;margin:0 0 1.4rem 0;">Open <strong style="color:#374151;">http://localhost:2001</strong> — log in with <code style="background:#f1f5f9;padding:.1rem .4rem;border-radius:4px;">admin / litmus</code>, connect your agent, run your first experiment. First certification report in under an hour.</p>
<div style="display:flex;gap:.75rem;flex-wrap:wrap;">
<a href="{{ "/setup/README.html" | relative_url }}" style="background:#4338ca;color:#fff;padding:.65rem 1.3rem;border-radius:9px;font-weight:700;text-decoration:none;font-size:.92rem;display:inline-block;">Full onboarding guide →</a>
<a href="{{ "/setup/running-an-experiment.html" | relative_url }}" style="background:#fff;color:#374151;padding:.65rem 1.3rem;border-radius:9px;font-weight:600;text-decoration:none;font-size:.92rem;border:1.5px solid #d1d5db;display:inline-block;">Run your first experiment →</a>
</div>
</div>

<!-- ══════════════════════════════════════════════════ GO DEEPER ═══ -->
<div style="display:grid;grid-template-columns:repeat(2,1fr);gap:1rem;margin:0 0 2rem;">
<a href="{{ "/architecture.html" | relative_url }}" style="background:#fff;border:1.5px solid #e5e7eb;border-radius:12px;padding:1.3rem 1.4rem;text-decoration:none;display:block;transition:border-color .2s;" onmouseover="this.style.borderColor='#6d28d9'" onmouseout="this.style.borderColor='#e5e7eb'">
<p style="font-size:.72rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#6d28d9;margin:0 0 .3rem 0;">Architecture</p>
<p style="font-weight:600;color:#111827;margin:0 0 .3rem 0;font-size:.97rem;">How the platform fits together</p>
<p style="font-size:.85rem;color:#6b7280;margin:0;">Control plane, chaos engine, certifier — and how they connect.</p>
</a>
<a href="{{ "/Methodologies/01-Introduction.html" | relative_url }}" style="background:#fff;border:1.5px solid #e5e7eb;border-radius:12px;padding:1.3rem 1.4rem;text-decoration:none;display:block;" onmouseover="this.style.borderColor='#6d28d9'" onmouseout="this.style.borderColor='#e5e7eb'">
<p style="font-size:.72rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#6d28d9;margin:0 0 .3rem 0;">Deep Dive</p>
<p style="font-weight:600;color:#111827;margin:0 0 .3rem 0;font-size:.97rem;">The science behind certification</p>
<p style="font-size:.85rem;color:#6b7280;margin:0;">Experiment design, statistical framework, the 12-section report standard.</p>
</a>
<a href="{{ "/api.html" | relative_url }}" style="background:#fff;border:1.5px solid #e5e7eb;border-radius:12px;padding:1.3rem 1.4rem;text-decoration:none;display:block;" onmouseover="this.style.borderColor='#6d28d9'" onmouseout="this.style.borderColor='#e5e7eb'">
<p style="font-size:.72rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#6d28d9;margin:0 0 .3rem 0;">API Reference</p>
<p style="font-weight:600;color:#111827;margin:0 0 .3rem 0;font-size:.97rem;">Integrate with your CI/CD pipeline</p>
<p style="font-size:.85rem;color:#6b7280;margin:0;">Connect certification runs to your deployment workflow.</p>
</a>
<a href="{{ "/testing.html" | relative_url }}" style="background:#fff;border:1.5px solid #e5e7eb;border-radius:12px;padding:1.3rem 1.4rem;text-decoration:none;display:block;" onmouseover="this.style.borderColor='#6d28d9'" onmouseout="this.style.borderColor='#e5e7eb'">
<p style="font-size:.72rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#6d28d9;margin:0 0 .3rem 0;">Testing & Coverage</p>
<p style="font-weight:600;color:#111827;margin:0 0 .3rem 0;font-size:.97rem;">Run the test suites</p>
<p style="font-size:.85rem;color:#6b7280;margin:0;">Unit, integration, and coverage reports for all platform components.</p>
</a>
</div>

