"""CrewAI SRE incident investigation crew."""
from __future__ import annotations

import os

from crewai import Agent, Crew, LLM, Task

from .mcp_tools import get_all_tools

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


def build_crew(goal: str, workspace_dir: str, model: str, output_path: str) -> Crew:
    base_url = os.environ.get("LITELLM_BASE_URL", "http://127.0.0.1:14000")
    api_key = os.environ.get("SRE_AGENT_LITELLM_API_KEY", "ollama")
    # litellm requires an explicit provider prefix when using a custom base_url
    prefixed_model = model if "/" in model else f"openai/{model}"

    llm = LLM(
        model=prefixed_model,
        base_url=base_url,
        api_key=api_key,
        temperature=0.0,
        max_tokens=2048,
    )

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

    task_desc = f"""{goal}

## Required investigation steps (do ALL of them in order):

1. Call list_namespaces — find the affected application namespace
2. Call list_pods_in_namespace with namespace="otel-demo" — confirm pod health
3. Call list_k8s_events with namespace="otel-demo" — look for warnings/errors
4. Call list_k8s_resources with api_version="networking.k8s.io/v1", kind="NetworkPolicy", namespace="otel-demo" — spot unexpected policies
5. If you found a suspicious NetworkPolicy, call get_k8s_resource to read its full spec
6. Call execute_promql_query with a relevant PromQL to confirm error rate
   (e.g. rate(traces_span_metrics_calls_total{{service_name="quote",status_code="STATUS_CODE_ERROR"}}[5m]))
7. Call delete_k8s_resource to remove the faulty NetworkPolicy if one was found
8. Call execute_promql_query again to verify traffic recovered

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
