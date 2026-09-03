"""CrewAI SRE incident investigation crew."""
from __future__ import annotations

import os
from typing import Any, Dict, List, Optional

import litellm
from crewai import Agent, Crew, LLM, Task

from .mcp_tools import CAN_MUTATE, get_all_tools

_OUTPUT_SCHEMA = """{
  "entities": [
    {
      "name": "namespace/Kind/name",
      "contributing_factor": true,
      "reasoning": "Explanation with evidence"
    }
  ],
  "propagation_chain": [
    {
      "from": "namespace/Kind/source",
      "to": "namespace/Kind/destination",
      "reasoning": "How the failure propagated"
    }
  ]
}"""

# Some model aliases behind the shared LiteLLM proxy silently route to a
# different real model than their name implies — verified for "gpt-4o" via
# the `x-ms-served-model` Azure response header (it's actually GPT-5.1, a
# reasoning-class model). Reasoning-class models reject the legacy
# `max_tokens`/`stop` Chat Completions params outright (400 Bad Request),
# and CrewAI's own capability auto-detection (LLM.supports_stop_words())
# can't catch this — it pattern-matches the model *name* string via
# litellm's static registry, which has no visibility into what a given
# deployment was actually repointed to.
#
# CrewAgentExecutor also unconditionally sets `self.llm.stop = stop_words`
# on construction (crew_agent_executor.py ~L84-87) regardless of what
# supports_stop_words() returns, and base LLM.call() sends whatever's in
# `self.stop` on every request — so overriding supports_stop_words() alone
# does NOT stop `stop` from being sent; call() itself must be overridden
# too. Two strategies, selected via SRE_AGENT_STOP_STRATEGY:
#   "truncate" (default) — never send `stop`; let the model generate its
#     full response and cut it client-side at the first stop marker, same
#     effect as CrewAI's own dormant fallback path (the
#     `if not self.use_stop_words:` branch in crew_agent_executor.py) but
#     reachable without depending on supports_stop_words()'s wrong answer.
#     Bounded by SRE_AGENT_MAX_COMPLETION_TOKENS so a runaway/hallucinated
#     continuation has a hard ceiling rather than an unbounded worst case.
#   "stream" — abort the connection the instant the stop marker appears in
#     the streamed text, closer to what native `stop` would have actually
#     cost in billed tokens. More precise, more code, not yet
#     production-hardened — prototype only, see innovation.md §4.7.
_STOP_STRATEGY = os.environ.get("SRE_AGENT_STOP_STRATEGY", "truncate").strip().lower()
# Matches the original hardcoded `max_tokens=2048` this file used before we
# learned it has to be sent as `max_completion_tokens` instead (see
# _build_llm_params below) — same budget, correct wire key, adjustable
# per-deployment without a code change.
_MAX_COMPLETION_TOKENS = int(os.environ.get("SRE_AGENT_MAX_COMPLETION_TOKENS", "2048"))
# Off by default — token_counter() re-tokenizes every truncated completion,
# pure overhead unless someone's actually trying to quantify the workaround's
# cost right now. Opt in with SRE_AGENT_LOG_TOKEN_WASTE=1/true/yes.
_LOG_TOKEN_WASTE = os.environ.get("SRE_AGENT_LOG_TOKEN_WASTE", "").strip().lower() in ("1", "true", "yes")

# CrewAI's ReAct prompt format cuts each turn here (agent.py:
# `stop_words = [self.i18n.slice("observation")]`, same literal in this
# crewai version) — duplicated here since it's not derivable without a
# constructed Agent instance at the point _TruncatingLLM needs it.
_STOP_MARKER = "\nObservation:"

# Sampling temperature for the investigator LLM. Was hardcoded to 0.0, which
# made every certification run of the same fault produce a byte-identical trace
# — defeating the N>1 premise the certifier is built on. Default to a small
# non-zero value so runs differ; override per-deployment via env. Set "0.0" for
# a strictly reproducible single run.
_TEMPERATURE = float(os.environ.get("SRE_AGENT_TEMPERATURE", "0.2") or "0.2")


def _build_llm_params(llm: "LLM", messages: List[Dict[str, str]]) -> Dict[str, Any]:
    """Same param set as crewai.LLM.call(), except:
    - `stop` is always omitted — the marker is stripped client-side instead
      (either after the fact or mid-stream, depending on strategy).
    - the length cap is sent as `max_completion_tokens`, never the legacy
      `max_tokens` key: base LLM.call() builds
      `"max_tokens": self.max_tokens or self.max_completion_tokens` — i.e.
      it collapses max_completion_tokens onto the wire key "max_tokens"
      regardless of which attribute is actually set, which is exactly the
      param this model rejects. Sending it under its real name is the
      entire fix.
    """
    params = {
        "model": llm.model,
        "messages": messages,
        "timeout": llm.timeout,
        "temperature": llm.temperature,
        "top_p": llm.top_p,
        "n": llm.n,
        "max_completion_tokens": llm.max_completion_tokens or _MAX_COMPLETION_TOKENS,
        "presence_penalty": llm.presence_penalty,
        "frequency_penalty": llm.frequency_penalty,
        "logit_bias": llm.logit_bias,
        "response_format": llm.response_format,
        "seed": llm.seed,
        "logprobs": llm.logprobs,
        "top_logprobs": llm.top_logprobs,
        "api_base": llm.base_url,
        "api_version": llm.api_version,
        "api_key": llm.api_key,
        **llm.kwargs,
    }
    return {k: v for k, v in params.items() if v is not None}


def _log_waste(model: str, kept_text: str, completion_tokens: Optional[int]) -> None:
    """Best-effort measurement of how much of the billed completion was
    discarded by client-side truncation — see innovation.md §4.7 for why
    this only applies to the "truncate" strategy (a "stream" call that
    aborted early was never billed for the discarded tail in the first
    place, so there's nothing to measure after the fact). Opt-in only —
    see _LOG_TOKEN_WASTE above."""
    if not _LOG_TOKEN_WASTE or not completion_tokens:
        return
    try:
        kept_tokens = litellm.token_counter(model=model, text=kept_text)
        wasted = max(completion_tokens - kept_tokens, 0)
        if wasted:
            # print(), not logging: matches __main__.py's [sre-crewai] convention
            # and guarantees visibility in `kubectl logs` without depending on
            # whatever logging config (if any) the host process has set up.
            print(
                f"[sre-crewai] stop-word workaround: {wasted}/{completion_tokens} "
                f"completion tokens discarded after truncation "
                f"({100 * wasted / completion_tokens:.0f}% waste)"
            )
    except Exception:
        pass  # measurement is best-effort; never let it break a real call


class _TruncatingLLM(LLM):
    """Default ("truncate") strategy — see module-level comment above."""

    def supports_stop_words(self) -> bool:
        return False

    def call(self, messages: List[Dict[str, str]], callbacks: Optional[List[Any]] = None) -> str:
        if callbacks:
            self.set_callbacks(callbacks)
        params = _build_llm_params(self, messages)
        response = litellm.completion(**params)
        full_text = response["choices"][0]["message"]["content"]
        kept_text = full_text.split(_STOP_MARKER)[0].rstrip()
        _log_waste(self.model, kept_text, response["usage"].get("completion_tokens"))
        return kept_text


class _StreamingTruncatingLLM(LLM):
    """"stream" strategy (opt-in, SRE_AGENT_STOP_STRATEGY=stream) — prototype
    for further research, see innovation.md §4.7 and module-level comment
    above."""

    def supports_stop_words(self) -> bool:
        return False

    def call(self, messages: List[Dict[str, str]], callbacks: Optional[List[Any]] = None) -> str:
        if callbacks:
            self.set_callbacks(callbacks)
        params = _build_llm_params(self, messages)
        params["stream"] = True
        stream = litellm.completion(**params)
        chunks: List[str] = []
        try:
            for chunk in stream:
                delta = chunk.choices[0].delta.content
                if delta:
                    chunks.append(delta)
                    if _STOP_MARKER in "".join(chunks):
                        break
        finally:
            close = getattr(stream, "close", None)
            if callable(close):
                close()
        full_text = "".join(chunks)
        return full_text.split(_STOP_MARKER)[0].rstrip()


def _build_llm(model: str, base_url: str, api_key: str) -> LLM:
    llm_cls = _StreamingTruncatingLLM if _STOP_STRATEGY == "stream" else _TruncatingLLM
    return llm_cls(
        model=model,
        base_url=base_url,
        api_key=api_key,
        temperature=_TEMPERATURE,
    )


def build_crew(goal: str, workspace_dir: str, model: str, output_path: str) -> Crew:
    # OPENAI_BASE_URL/OPENAI_API_KEY are what the agent-charts Helm chart sets
    # (the only live deployment path — see agents/harness/sre-agent-crewai/bench.yaml).
    # LITELLM_BASE_URL/SRE_AGENT_LITELLM_API_KEY are the legacy standalone
    # agent-harness.yaml script's names, kept as a fallback for that path.
    base_url = os.environ.get("OPENAI_BASE_URL") or os.environ.get("LITELLM_BASE_URL", "http://127.0.0.1:14000")
    api_key = os.environ.get("OPENAI_API_KEY") or os.environ.get("SRE_AGENT_LITELLM_API_KEY", "ollama")
    # litellm requires an explicit provider prefix when using a custom base_url
    prefixed_model = model if "/" in model else f"openai/{model}"

    llm = _build_llm(prefixed_model, base_url, api_key)

    investigator = Agent(
        role="SRE Incident Investigator",
        goal=(
            "Diagnose a Kubernetes incident by querying the live cluster and "
            "Prometheus, then produce a structured JSON diagnosis."
        ),
        backstory=(
            "You are an expert Site Reliability Engineer. You systematically "
            "investigate Kubernetes incidents: enumerate namespaces, check pod "
            "health, inspect NetworkPolicies, and query Prometheus error rates. "
            "You always complete every step and never stop early."
        ),
        tools=get_all_tools(),
        llm=llm,
        verbose=True,
        max_iter=25,
        max_retry_limit=3,
    )

    investigation_steps = [
        'Call list_namespaces — find the affected application namespace',
        'Call list_pods_in_namespace with namespace="otel-demo" — confirm pod health',
        'Call list_k8s_events with namespace="otel-demo" — look for warnings/errors',
        'Call list_k8s_resources with api_version="networking.k8s.io/v1", '
        'kind="NetworkPolicy", namespace="otel-demo" — spot unexpected policies',
        'If you found a suspicious NetworkPolicy, call get_k8s_resource to read its full spec',
        'Call execute_promql_query with a relevant PromQL to confirm error rate\n'
        '   (e.g. rate(traces_span_metrics_calls_total'
        '{service_name="quote",status_code="STATUS_CODE_ERROR"}[5m]))',
    ]
    if CAN_MUTATE:
        # delete_k8s_resource only exists as a tool (get_all_tools() above)
        # when AGENT_MODE=active — these two steps must stay in lockstep with
        # that, or the model gets instructed to call a tool it doesn't have.
        investigation_steps += [
            'Call delete_k8s_resource to remove the faulty NetworkPolicy if one was found',
            'Call execute_promql_query again to verify traffic recovered',
        ]
    steps_text = "\n".join(f"{i}. {s}" for i, s in enumerate(investigation_steps, start=1))
    mode_note = (
        ""
        if CAN_MUTATE
        else "\n\nYou are running in READ-ONLY (observe) mode: do not attempt to "
        "delete or modify any resources — only investigate and report your diagnosis."
    )

    task_desc = f"""{goal}{mode_note}

## Required investigation steps (do ALL of them in order):

{steps_text}

## Final output

After completing all steps above, output ONLY a valid JSON object matching this schema:
{_OUTPUT_SCHEMA}

Rules for the JSON:
- Entity names MUST use "namespace/Kind/name" format (e.g. "otel-demo/NetworkPolicy/quote-http-abort-fault")
- Every entity that CAUSED the incident has contributing_factor=true
- Every entity IMPACTED but not causal has contributing_factor=false
- propagation_chain shows how the fault spread

Do NOT wrap the JSON in markdown code fences. Output raw JSON only."""

    task = Task(
        description=task_desc,
        expected_output=(
            "A raw JSON object with 'entities' and 'propagation_chain' fields "
            "describing the incident root cause and impact."
        ),
        agent=investigator,
        output_file=output_path,
    )

    return Crew(
        agents=[investigator],
        tasks=[task],
        verbose=True,
    )
