---
title: "Experiment Design"
parent: "Certification Methodology"
grand_parent: "Deep Dive"
nav_order: 2
---

# Experiment Design

A certification experiment has a precise structure. Randomness is acceptable in the agent's responses — it is not acceptable in the experimental setup. This chapter defines what makes a valid AgentCert experiment: what you inject, how many times you run it, and what you need to define before the agent ever sees a fault.

---

## Anatomy of an Experiment

Every AgentCert experiment consists of three elements defined before injection:

**Fault configuration file.** A JSON document that specifies the fault type, the target service, the injection parameters, and — critically — the **ground truth**: what the agent should ideally do, which tools it should call in what order, and what a correct detection and mitigation looks like. The agent never sees this file. It is the answer key used for evaluation after the fact.

**Fault injection.** LitmusChaos injects the fault into the Kubernetes cluster at a defined time. The agent is given no advance notice. It must infer the fault from the observable signals available to it (pod status, logs, metrics, network health checks).

**Repeated runs.** The same fault is injected N times, with the cluster returned to a clean baseline between runs. The certification methodology requires a minimum of **30 runs per fault category** for statistical significance. Below 30, confidence intervals are too wide and the hypothesis framework does not activate.

---

## Fault Taxonomy

AgentCert organises faults into five categories based on what layer of the stack they target:

| Category | What It Targets | Example Faults |
|---|---|---|
| **Network** | Pod-to-pod and pod-to-service communication | Pod network loss, bandwidth throttle, DNS error |
| **Compute / Resource** | CPU, memory, disk within a pod or node | Pod CPU hog, memory hog, disk fill |
| **Application** | Pod lifecycle and container process | Pod deletion, container kill, replica scaling |
| **Database / Storage** | Stateful workloads and I/O | DB connection failure, write bottleneck |
| **Security / Adversarial** | Access control and certificate validity | Auth failure, cert expiry, unexpected traffic |

Each fault in the taxonomy has a corresponding LitmusChaos experiment definition in the [chaos-charts repository](https://github.com/AgentCert/chaos-charts).

---

## Why Fault Category Matters

The agent may perform differently across fault categories even when the symptoms look similar. A pod deletion and a network partition can both cause HTTP 5xx errors upstream — but they require different diagnostic approaches and different remediation steps. Certification is reported **per fault category**, not as a single aggregate score.

---

## What This Section Covers

<details class="section-details" markdown="1">
<summary class="section-summary"><span class="section-tag">2.0</span> Experiment Assumptions</summary>
<div class="section-details-body" markdown="1">
{% capture _s %}{% include_relative 02-Experiment-Design/2.0-Experiment-Assumptions.md %}{% endcapture %}{% assign _p = _s | split: "---" %}{% assign _b = _p | slice: 2, 100 | join: "---" %}{{ _b | lstrip }}
</div>
</details>
<details class="section-details" markdown="1">
<summary class="section-summary"><span class="section-tag">2.1</span> Experimentation Principles</summary>
<div class="section-details-body" markdown="1">
{% capture _s %}{% include_relative 02-Experiment-Design/2.1-Experimentation-Principles.md %}{% endcapture %}{% assign _p = _s | split: "---" %}{% assign _b = _p | slice: 2, 100 | join: "---" %}{{ _b | lstrip }}
</div>
</details>
<details class="section-details" markdown="1">
<summary class="section-summary"><span class="section-tag">2.2</span> Global Methods and Standards</summary>
<div class="section-details-body" markdown="1">
{% capture _s %}{% include_relative 02-Experiment-Design/2.2-Global-Methods-and-Standards.md %}{% endcapture %}{% assign _p = _s | split: "---" %}{% assign _b = _p | slice: 2, 100 | join: "---" %}{{ _b | lstrip }}
</div>
</details>
<details class="section-details" markdown="1">
<summary class="section-summary"><span class="section-tag">2.3</span> Fault Taxonomy</summary>
<div class="section-details-body" markdown="1">
{% capture _s %}{% include_relative 02-Experiment-Design/2.3-Fault-Taxonomy.md %}{% endcapture %}{% assign _p = _s | split: "---" %}{% assign _b = _p | slice: 2, 100 | join: "---" %}{{ _b | lstrip }}
</div>
</details>
<details class="section-details" markdown="1">
<summary class="section-summary"><span class="section-tag">2.4</span> Fault Configuration Schema</summary>
<div class="section-details-body" markdown="1">
{% capture _s %}{% include_relative 02-Experiment-Design/2.4-Fault-Configuration-Schema.md %}{% endcapture %}{% assign _p = _s | split: "---" %}{% assign _b = _p | slice: 2, 100 | join: "---" %}{{ _b | lstrip }}
</div>
</details>
<details class="section-details" markdown="1">
<summary class="section-summary"><span class="section-tag">2.5</span> Trace Collection and Preprocessing</summary>
<div class="section-details-body" markdown="1">
{% capture _s %}{% include_relative 02-Experiment-Design/2.5-Trace-Collection-and-Preprocessing.md %}{% endcapture %}{% assign _p = _s | split: "---" %}{% assign _b = _p | slice: 2, 100 | join: "---" %}{{ _b | lstrip }}
</div>
</details>
<details class="section-details" markdown="1">
<summary class="section-summary"><span class="section-tag">2.6</span> Certification Scenarios</summary>
<div class="section-details-body" markdown="1">
{% capture _s %}{% include_relative 02-Experiment-Design/2.6-Certification-Scenarios.md %}{% endcapture %}{% assign _p = _s | split: "---" %}{% assign _b = _p | slice: 2, 100 | join: "---" %}{{ _b | lstrip }}
</div>
</details>
