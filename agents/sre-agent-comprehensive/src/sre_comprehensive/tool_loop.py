"""Direct OpenAI tool-calling investigation loop for the comprehensive SRE agent.

Replaces CrewAI's text-ReAct executor for the LiteLLM->ollama_chat route.
CrewAI 0.95's `CrewAgentExecutor` is hard-wired to text ReAct: it prompts for a
`Thought/Action/Action Input` block, stops generation at `\\nObservation:`, and
regex-parses the result. qwen2.5:32b on this route ignores the stop, free-runs
the whole trajectory (hallucinating Observations), CrewAI can't parse it, it
re-injects the entire tool list as a "use the format" reminder, the scratchpad
bloats, the completion goes empty, and the loop restarts from scratch — forever,
0 real remediations (see OPEN_WEIGHT_CERTIFICATION_HANDOFF.md sec 123 / REACTFIX_HANDOFF sec 2d).

This module drives the model with native tool-calling instead: it advertises the
MCP tools as `tools=[...]` JSON schemas, the model returns structured
`tool_calls`, we execute them and feed results back as `role:"tool"` messages.
No text parsing, no stop-token hack, no format re-injection. Selected via
`SRE_AGENT_ENGINE=toolcalling` (the default in __main__.py).
"""
from __future__ import annotations

import json
import os
import time
from typing import Any, Optional

import litellm

from .crew import _OUTPUT_SCHEMA, _TASK_TEMPLATE
from .mcp_tools import (
    K8S_URL,
    _call_mcp,
    _parse_json,
    compact_tool_output,
    get_all_tools,
    get_tool_call_history,
    required_evidence_missing,
)

_MAX_STEPS = int(os.environ.get("SRE_AGENT_MAX_STEPS", "40") or "40")
_LLM_TIMEOUT = float(os.environ.get("SRE_AGENT_LLM_STEP_TIMEOUT", "240") or "240")
_TEMPERATURE = float(os.environ.get("SRE_AGENT_TEMPERATURE", "0.2") or "0.2")
# qwen needs a generous completion budget for the final JSON, but nothing like
# the 4096 the ReAct path burned re-hallucinating trajectories every step.
# GPT-5-class models write verbose reasoning; a low cap truncates the final
# JSON mid-object so it never parses. 6000 leaves room for a full diagnosis.
_MAX_TOKENS = int(os.environ.get("SRE_AGENT_MAX_COMPLETION_TOKENS", "6000") or "6000")
# After this many steps, stop offering tools and demand the final JSON. qwen
# tends to keep "remediating" an already-healthy workload instead of concluding.
_FORCE_ANSWER_AFTER = int(os.environ.get("SRE_AGENT_FORCE_ANSWER_AFTER", "16") or "16")
# Consecutive no-progress steps (every tool call a repeat or a no-op) before we
# force the answer early.
_STALL_LIMIT = int(os.environ.get("SRE_AGENT_STALL_LIMIT", "3") or "3")


def _log(msg: str) -> None:
    print(f"[sre-comprehensive] {msg}", flush=True)


def _sig(name: str, args: dict) -> str:
    try:
        return name + ":" + json.dumps(args, sort_keys=True, default=str)
    except Exception:
        return name + ":" + repr(args)


def _strip_titles(node: Any) -> Any:
    """pydantic's model_json_schema() sprays `title` everywhere; some providers
    choke on unknown keys. Drop them."""
    if isinstance(node, dict):
        return {k: _strip_titles(v) for k, v in node.items() if k != "title"}
    if isinstance(node, list):
        return [_strip_titles(v) for v in node]
    return node


def _raw_description(t: Any) -> str:
    """crewai's BaseTool rewrites `.description` into a bulky
    "Tool Name: … Tool Arguments: {…} Tool Description: …" blob (arg detail is
    already in the JSON schema we send). Recover the class-level default."""
    try:
        default = type(t).model_fields["description"].default
        if isinstance(default, str) and default:
            return default
    except Exception:
        pass
    return getattr(t, "description", "") or ""


def _tool_schemas(tools: list) -> list[dict]:
    schemas = []
    for t in tools:
        params = _strip_titles(t.args_schema.model_json_schema())
        params.setdefault("type", "object")
        params.setdefault("properties", {})
        params.pop("description", None)
        schemas.append(
            {
                "type": "function",
                "function": {
                    "name": t.name,
                    "description": _raw_description(t).strip()[:1024],
                    "parameters": params,
                },
            }
        )
    return schemas


def _exec_tool(tool: Any, raw_args: str) -> str:
    try:
        args = json.loads(raw_args) if raw_args and raw_args.strip() else {}
    except json.JSONDecodeError as exc:
        return f"ERROR: could not parse tool arguments as JSON ({exc}). Send valid JSON."
    if not isinstance(args, dict):
        return "ERROR: tool arguments must be a JSON object."
    # Route through the pydantic arg schema so the shared _clean() validators
    # (they unwrap the doubled quotes qwen emits) and defaults apply.
    try:
        cleaned = tool.args_schema(**args).model_dump()
    except Exception:
        cleaned = args
    try:
        return str(tool._run(**cleaned))
    except TypeError:
        # schema/_run kwarg mismatch — last resort, pass through raw
        try:
            return str(tool._run(**args))
        except Exception as exc:  # noqa: BLE001
            return f"ERROR executing {tool.name}: {exc}"
    except Exception as exc:  # noqa: BLE001
        return f"ERROR executing {tool.name}: {exc}"


def _valid_diagnosis(obj: Any) -> bool:
    return (
        isinstance(obj, dict)
        and isinstance(obj.get("entities"), list)
        and isinstance(obj.get("propagation_chain"), list)
    )


def _items(text: str) -> list:
    try:
        d = _parse_json(text)
    except Exception as exc:  # noqa: BLE001
        _log(f"_open_issues: could not parse a list response ({exc}); first 120: {text[:120]!r}")
        return []
    if isinstance(d, dict):
        d = d.get("items", d)
    return d if isinstance(d, list) else []


def _open_issues(namespace: str) -> list[str]:
    """Concrete, still-unremediated problems in the namespace, phrased so the
    model can act on them. Empty => the namespace looks healthy and a
    conclusion is credible. Used to reject a premature "entities: []" answer.
    Best-effort; never raises."""
    issues: list[str] = []
    # ---- pod health: RAW-TEXT scan (robust to _parse_json fragility) ----
    # Unambiguous, terminal-ish pod failure reasons only. Deliberately NOT
    # "Error"/"FailedScheduling"/"FailedMount" — those appear transiently in a
    # healthy namespace during app startup and in benign lastState fields, and
    # firing on them makes the gate reject every conclusion forever.
    _BAD = ("CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "RunContainerError",
            "CreateContainerConfigError", "CreateContainerError", "InvalidImageName",
            "ImageInspectError", "RegistryUnavailable")
    try:
        pods_text = _call_mcp(K8S_URL, "pods_list_in_namespace", {"namespace": namespace})
        seen_bad = sorted({b for b in _BAD if b in pods_text})
        if seen_bad:
            issues.append(
                f"pod(s) in the namespace are failing ({', '.join(seen_bad)}) — "
                f"list_pods_in_namespace + get_k8s_resource the owning Deployment, "
                f"inspect its pod template (image / command / args / readinessProbe / "
                f"resources / initContainers / env), and rollout_undo (or patch_resource) "
                f"to fix it"
            )
        # Structured pass — extra detail when the parse works.
        for p in _items(pods_text):
            if not isinstance(p, dict):
                continue
            md, st = p.get("metadata", {}), p.get("status", {})
            phase = st.get("phase", "")
            cs = st.get("containerStatuses") or []
            not_ready = [c for c in cs if not c.get("ready")]
            owner = (md.get("ownerReferences") or [{}])[0].get("name", "")
            if (phase not in ("Running", "Succeeded") or (cs and not_ready)) and not seen_bad:
                issues.append(
                    f"pod {md.get('name')} (owner {owner}) phase={phase} "
                    f"ready={len(cs) - len(not_ready)}/{len(cs)} — investigate + fix"
                )
    except Exception:
        pass
    try:
        dep_text = _call_mcp(K8S_URL, "resources_list",
                             {"apiVersion": "apps/v1", "kind": "Deployment",
                              "namespace": namespace})
        deps = _items(dep_text)
        if not deps:
            _log(f"_open_issues: Deployment list parsed to 0 items. raw[:400]={dep_text[:400]!r}")
        for d in deps:
            if not isinstance(d, dict):
                continue
            n = d.get("metadata", {}).get("name", "")
            spec_r = int(d.get("spec", {}).get("replicas") or 0)
            avail = int(d.get("status", {}).get("availableReplicas") or 0)
            updated = int(d.get("status", {}).get("updatedReplicas") or 0)
            if spec_r == 0:
                issues.append(f"Deployment {n} spec.replicas=0 — scale it up with patch_resource")
            elif avail < spec_r:
                issues.append(f"Deployment {n} available {avail}/{spec_r} — investigate + fix")
            elif updated < spec_r:
                issues.append(
                    f"Deployment {n} rollout stuck ({updated}/{spec_r} updated) — "
                    f"get_k8s_resource it, check the pod template (image/command/probe/"
                    f"env/resources), rollout_undo if the template is bad"
                )
        # Fallback: if the structured parse yielded nothing but the raw text
        # plainly shows a zeroed workload, still raise it (parser fragility must
        # not silently disable the gate).
        if not any("replicas=0" in i or "spec.replicas=0" in i for i in issues) and \
                ("replicas: 0" in dep_text or "\nreplicas: 0" in dep_text):
            issues.append(
                "a Deployment in this namespace has replicas: 0 — locate it via "
                "list_k8s_resources(apps/v1, Deployment) and scale it up with patch_resource"
            )
    except Exception:
        pass
    try:
        hpa_text = _call_mcp(K8S_URL, "resources_list",
                             {"apiVersion": "autoscaling/v2",
                              "kind": "HorizontalPodAutoscaler", "namespace": namespace})
        import re as _re
        for m in _re.finditer(r"averageUtilization:\s*(\d+)", hpa_text):
            if int(m.group(1)) < 40:
                issues.append(
                    f"an HPA has averageUtilization={m.group(1)} (absurdly low → constant "
                    f"scale-up) — get_k8s_resource the HPA and patch_resource it to ~80"
                )
                break
    except Exception:
        pass
    try:
        ev_text = _call_mcp(K8S_URL, "events_list", {"namespace": namespace})
        # Fault-specific event phrasings only — not generic probe/mount/schedule
        # warnings, which flood a healthy namespace during startup.
        for kw in ("exceeded quota", "forbidden: failed quota",
                   "must specify one of: `request` or `limit`",
                   "is forbidden: exceeded quota"):
            if kw in ev_text:
                issues.append(
                    "a ResourceQuota is blocking pod creation (\"exceeded quota\" in "
                    "events) — list_k8s_resources(v1, ResourceQuota) and "
                    "delete_k8s_resource the over-restrictive quota"
                )
                break
    except Exception:
        pass
    _log(f"_open_issues({namespace}) -> {len(issues)}: {issues[:5]}")
    return issues


def _extract_json(text: str) -> Optional[dict]:
    import re

    if not text:
        return None
    text = re.sub(r"```(?:json)?", "", text).strip()
    for candidate in (text, (re.search(r"\{.*\}", text, re.DOTALL) or [None])[0] if re.search(r"\{.*\}", text, re.DOTALL) else None):
        if not candidate:
            continue
        try:
            return json.loads(candidate)
        except (json.JSONDecodeError, TypeError):
            continue
    return None


def run_investigation(
    *,
    goal: str,
    namespace: str,
    model: str,
    base_url: str,
    api_key: str,
    output_path: str,
    deadline: Optional[float] = None,
) -> dict:
    """Run one full tool-calling investigation. Returns the diagnosis dict
    (also written to output_path). Never raises."""
    prefixed_model = model if "/" in model else f"openai/{model}"
    tools = get_all_tools()
    by_name = {t.name: t for t in tools}
    schemas = _tool_schemas(tools)

    system = _TASK_TEMPLATE.format(goal=goal, namespace=namespace, schema=_OUTPUT_SCHEMA)
    system += (
        "\n\n## HOW TO ACT\n"
        "Call the tools directly — one or more per turn — to gather evidence and "
        "apply fixes. Do NOT narrate a plan in prose; issue tool calls.\n"
        "- `list_*` tools only tell you WHAT exists. They do NOT tell you a "
        "resource is correct. For EVERY Deployment, Service, HPA, NetworkPolicy, "
        "ResourceQuota and ConfigMap in the namespace you MUST call "
        "get_k8s_resource and read the actual spec — a fault is usually a wrong "
        "field inside an object that otherwise looks fine in a list.\n"
        "- A Deployment with availableReplicas == spec.replicas can STILL be "
        "faulted: a bad new image leaves the old ReplicaSet serving while the "
        "new pods sit in ImagePullBackOff. Check updatedReplicas and the pod "
        "list, not just availableReplicas.\n"
        "\nSymptom → fix:\n"
        "  spec.replicas == 0                     -> patch_resource {\"spec\":{\"replicas\":1}}\n"
        "  pod ImagePullBackOff / ErrImagePull    -> get_k8s_resource the Deployment, "
        "confirm a bogus image tag, then rollout_undo\n"
        "  pod CrashLoopBackOff from bad command/args/env/probe/resources -> rollout_undo\n"
        "  pod Pending (nodeSelector / affinity / unschedulable node) -> uncordon the "
        "node with patch_resource {\"spec\":{\"unschedulable\":false}}, or rollout_undo a "
        "bad nodeSelector/affinity\n"
        "  NetworkPolicy with empty or port-blocking ingress -> delete_k8s_resource it\n"
        "  Service selector contains 'invalid' / wrong targetPort -> patch_resource\n"
        "  HPA averageUtilization < 40 -> patch_resource to ~80\n"
        "  ResourceQuota with absurdly low limits -> delete_k8s_resource it\n"
        "  ConfigMap feature flag defaultVariant 'on' for a failure flag -> patch_resource off\n"
        "  rogue Pod/Deployment (label chaos-injector, name workload-scanner/decoy) -> delete_k8s_resource\n"
        "\n- Apply each remediation exactly ONCE (the write tools are idempotent). "
        "After a fix, verify with a read tool and MOVE ON.\n"
        "- `rollout_undo` is ONLY for a poisoned pod template. Never for a replica "
        "count.\n"
        "- Every resource you remediate MUST appear in the final `entities` with "
        "contributing_factor:true.\n"
        "- Conclude ONLY when you have inspected every workload's spec AND every "
        "pod is Running/Ready. Then reply with ONLY the JSON object.\n"
        "- The final JSON must be COMPACT: one sentence per `reasoning` / per "
        "propagation_chain entry, no markdown, no commentary before or after.\n"
        "- `entities` RULES (strict):\n"
        "  * Include a resource ONLY if you remediated it, OR a Warning event / a "
        "non-Ready pod directly implicates it. Typically 1, at most 2-3.\n"
        "  * A resource that simply does not exist is NOT a fault — do not invent "
        "one (e.g. an absent `valkey-credentials` Secret in a namespace where "
        "valkey-cart is Running is normal, not a finding).\n"
        "  * NEVER list the `sre-agent-comprehensive` Deployment, the Namespace "
        "itself, or a resource that was healthy the whole time.\n"
        "  * If, after full investigation, nothing was actually wrong, return "
        "`entities: []` — that is a valid and correct answer."
    )
    messages: list[dict] = [
        {"role": "system", "content": system},
        {"role": "user", "content": f"Begin the investigation of namespace '{namespace}' now."},
    ]

    best: dict = {"entities": [], "propagation_chain": []}
    nudged_empty = 0
    seen_sigs: set[str] = set()
    stall_streak = 0
    remediation_ok = False
    inspected = False          # get_k8s_resource ever called
    remediated: set[tuple[str, str]] = set()   # (namespace/Kind/name, tool) actually written
    deepdive_nudges = 0        # times we've rejected a premature "nothing wrong"
    max_deepdive = int(os.environ.get("SRE_AGENT_MAX_DEEPDIVE_NUDGES", "3") or "3")

    for step in range(1, _MAX_STEPS + 1):
        if deadline is not None and time.monotonic() >= deadline:
            _log(f"tool-loop: deadline reached at step {step}")
            break

        # Past a step budget, or after a run of no-progress turns, stop offering
        # tools and force the model to produce the JSON. qwen otherwise keeps
        # "re-remediating" an already-healthy workload forever. Each deep-dive
        # rejection (see below) buys another ~8 steps of tool access.
        force_answer = (
            step > _FORCE_ANSWER_AFTER + deepdive_nudges * 8
            or stall_streak >= _STALL_LIMIT
        )
        try:
            # `max_completion_tokens`, not the legacy `max_tokens`: the Azure
            # reasoning-class deployment behind the `gpt-4o` alias rejects
            # `max_tokens` outright (400), and litellm collapses
            # max_completion_tokens onto the right wire key for ollama_chat too.
            resp = litellm.completion(
                model=prefixed_model,
                messages=messages,
                tools=schemas,
                tool_choice="none" if force_answer else "auto",
                temperature=_TEMPERATURE,
                max_completion_tokens=_MAX_TOKENS,
                api_base=base_url,
                api_key=api_key,
                timeout=_LLM_TIMEOUT,
            )
        except Exception as exc:  # noqa: BLE001
            _log(f"tool-loop: LLM call failed at step {step}: {exc}")
            time.sleep(2)
            continue

        msg = resp.choices[0].message
        tool_calls = [] if force_answer else (getattr(msg, "tool_calls", None) or [])
        messages.append(msg.model_dump() if hasattr(msg, "model_dump") else dict(msg))

        if tool_calls:
            names = ", ".join(tc.function.name for tc in tool_calls)
            _log(f"tool-loop: step {step} -> {names}")
            progressed = False
            for tc in tool_calls:
                args_obj: dict = {}
                try:
                    args_obj = json.loads(tc.function.arguments or "{}")
                except json.JSONDecodeError:
                    pass
                sig = _sig(tc.function.name, args_obj)
                tool = by_name.get(tc.function.name)
                if tool is None:
                    result = f"ERROR: unknown tool '{tc.function.name}'."
                elif sig in seen_sigs:
                    result = (
                        "SKIPPED — you already made this exact call and it succeeded. "
                        "It is idempotent; repeating it achieves nothing. Move to the "
                        "next investigation phase, or emit the final JSON if every "
                        "phase is done and the workload is healthy."
                    )
                else:
                    seen_sigs.add(sig)
                    progressed = True
                    raw = _exec_tool(tool, tc.function.arguments or "{}")
                    if tc.function.name == "get_k8s_resource" and not raw.startswith("ERROR"):
                        inspected = True
                    if tc.function.name in ("patch_resource", "rollout_undo",
                                            "resources_scale", "apply_resource",
                                            "delete_k8s_resource") and not raw.startswith("ERROR"):
                        remediation_ok = True
                        rk = args_obj.get("kind") or (
                            "Deployment" if tc.function.name == "rollout_undo" else "")
                        rn = args_obj.get("name", "")
                        rns = args_obj.get("namespace") or namespace
                        if rn and rk:
                            scope = "" if rk in ("Node", "PriorityClass", "Namespace") else f"{rns}/"
                            remediated.add((f"{scope}{rk}/{rn}", tc.function.name))
                    result = compact_tool_output(tc.function.name, args_obj, raw)
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": tc.id,
                        "name": tc.function.name,
                        "content": result[:8000],
                    }
                )
            stall_streak = 0 if progressed else stall_streak + 1
            continue

        # No tool calls — treat content as a (possibly final) answer.
        content = (msg.content or "").strip()
        parsed = _extract_json(content)

        if _valid_diagnosis(parsed):
            # Before accepting ANY conclusion, sanity-check the live cluster.
            # The model must not conclude — right diagnosis, wrong diagnosis, or
            # "all clear" — while a concrete problem is still unremediated. A
            # non-empty (but wrong) `entities` does NOT earn an exemption.
            issues = _open_issues(namespace) if deepdive_nudges < max_deepdive else []
            if issues:
                deepdive_nudges += 1
                stall_streak = 0
                _log(f"tool-loop: rejecting conclusion at step {step}; "
                     f"{len(issues)} unremediated issue(s), deepdive {deepdive_nudges}/{max_deepdive}")
                messages.append({"role": "user", "content": (
                    "Do NOT conclude yet — these problems are still live in the cluster "
                    "and you have not fixed them:\n- " + "\n- ".join(issues[:8]) +
                    "\n\nFor each: get_k8s_resource the named workload, inspect its full "
                    "spec (spec.replicas; every container image/command/args/env/"
                    "readinessProbe/resources; initContainers; nodeSelector; affinity; "
                    "dnsPolicy), then apply the fix (patch_resource / rollout_undo / "
                    "delete_k8s_resource / apply_resource). A Deployment whose "
                    "updatedReplicas < replicas has a broken pod template — rollout_undo "
                    "it. Re-check with a read tool, then conclude."
                )})
                continue
            if remediation_ok and not parsed["entities"]:
                deepdive_nudges += 1
                messages.append({"role": "user", "content": (
                    "You applied at least one remediation but `entities` is empty. "
                    "Every resource you changed IS a contributing factor — list each "
                    "one in `entities` with contributing_factor:true and a reasoning "
                    "citing the tool output, then re-emit the JSON."
                )})
                continue

            # Strip obviously-bogus entities the model sometimes pads with.
            _bogus = ("/Namespace/", "/Deployment/sre-agent-comprehensive")
            clean_ents = [
                e for e in parsed["entities"]
                if isinstance(e, dict) and not any(b in str(e.get("name", "")) for b in _bogus)
            ]
            if len(clean_ents) != len(parsed["entities"]):
                _log(f"tool-loop: dropped {len(parsed['entities']) - len(clean_ents)} bogus entit(y/ies)")
            parsed["entities"] = clean_ents
            if len(clean_ents) > 6 and deepdive_nudges < max_deepdive:
                deepdive_nudges += 1
                messages.append({"role": "user", "content": (
                    f"{len(clean_ents)} entities is too many — a single injected fault has "
                    "1, rarely 2-3 root causes. Re-emit the JSON with ONLY the resources "
                    "you actually remediated or that a Warning event / non-Ready pod "
                    "directly implicated. Drop everything that was healthy."
                )})
                continue

            # Ground truth: a resource the agent actually WROTE to is by
            # definition a contributing factor. qwen/GPT-5 sometimes remediate
            # the right thing but narrate a different (wrong) root cause — force
            # the remediated resources into `entities`, and drop entries that
            # are neither remediated nor plausibly implicated.
            ent_names = {str(e.get("name", "")) for e in clean_ents}
            for rname, rtool in sorted(remediated):
                if rname not in ent_names:
                    clean_ents.append({
                        "name": rname,
                        "contributing_factor": True,
                        "reasoning": f"Agent applied {rtool} to this resource to remediate the fault.",
                    })
                    _log(f"tool-loop: injected remediated entity {rname} ({rtool})")
            if remediated:
                rset = {r for r, _ in remediated}
                clean_ents = [
                    e for e in clean_ents
                    if str(e.get("name", "")) in rset or e.get("contributing_factor") is False
                ] or clean_ents
            parsed["entities"] = clean_ents
            best = parsed
            _log(f"tool-loop: final diagnosis at step {step} "
                 f"({len(parsed['entities'])} entities, remediation_applied={remediation_ok}, "
                 f"inspected={inspected})")
            break

        missing = required_evidence_missing()
        if missing and not force_answer:
            nudge = (
                "You have not gathered the minimum evidence yet. Call these tools "
                f"before concluding: {', '.join(missing)}."
            )
        else:
            nudged_empty += 1
            nudge = (
                "Output ONLY the final JSON object now — keys `entities` and "
                "`propagation_chain`, matching the schema. No prose, no code fences, "
                "no further tool calls."
            )
        if nudged_empty >= 3:
            _log("tool-loop: model will not emit valid JSON; stopping with best-effort")
            break
        messages.append({"role": "user", "content": nudge})

    try:
        from pathlib import Path

        Path(output_path).write_text(json.dumps(best, indent=2))
    except Exception as exc:  # noqa: BLE001
        _log(f"tool-loop: could not write {output_path}: {exc}")
    return best
