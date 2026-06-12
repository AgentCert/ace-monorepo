---
title: "2 · Experiment Design"
parent: "Methodology"
nav_order: 2
nav_fold: true
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

## What This Chapter Covers

| Section | Contents |
|---|---|
| [2.0 Experiment Assumptions](02-Experiment-Design/2.0-Experiment-Assumptions) | Pre-conditions that must hold for results to be valid |
| [2.1 Experimentation Principles](02-Experiment-Design/2.1-Experimentation-Principles) | Why 30 runs, why clean baselines, why controlled injection timing |
| [2.2 Global Methods and Standards](02-Experiment-Design/2.2-Global-Methods-and-Standards) | Statistical methods, confidence levels, and reporting conventions |
| [2.3 Fault Taxonomy](02-Experiment-Design/2.3-Fault-Taxonomy) | Full reference of fault types, categories, and LitmusChaos mappings |
| [2.4 Fault Configuration Schema](02-Experiment-Design/2.4-Fault-Configuration-Schema) | JSON schema for writing a fault configuration file |
| [2.5 Trace Collection and Preprocessing](02-Experiment-Design/2.5-Trace-Collection-and-Preprocessing) | How Langfuse captures agent behaviour and what the pipeline expects |
| [2.6 Certification Scenarios](02-Experiment-Design/2.6-Certification-Scenarios) | The three certification scenarios based on data completeness |
