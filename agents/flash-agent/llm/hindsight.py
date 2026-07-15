"""
Hindsight Builder – FLASH Reflection System
=============================================

Implements hindsight integration based on FLASH agent architecture.
Generates learnings from past failures to improve future decisions.

Reference: https://www.microsoft.com/en-us/research/project/flash-a-reliable-workflow-automation-agent/
"""

from __future__ import annotations

import logging
from typing import Any, Dict, List, Optional

from openai import AzureOpenAI, OpenAI

from config import AgentConfig

logger = logging.getLogger("flash-agent")


def _create_openai_client(cfg: AgentConfig) -> OpenAI:
    """Create an OpenAI-compatible client."""
    if cfg.openai_base_url and ".openai.azure.com" in cfg.openai_base_url:
        return AzureOpenAI(
            api_key=cfg.openai_api_key,
            azure_endpoint=cfg.openai_base_url,
            api_version=cfg.azure_api_version,
            timeout=120.0,
        )
    return OpenAI(
        api_key=cfg.openai_api_key or "not-needed",
        base_url=cfg.openai_base_url,
        timeout=120.0,
    )


# ------------------------------------------------------------------------------
# Hindsight Prompt
# ------------------------------------------------------------------------------

HINDSIGHT_PROMPT = """You are a hindsight reflection agent for ITOps workflow automation.

Your role is to analyze past execution history and current state to provide actionable insights that prevent repeated failures and improve decision-making.

## Recent Execution History
{history}

## Current Environment State
{current_input}

## Detected Failure Context
{failure_context}

---

Based on this execution trace, provide hindsight reflection addressing:

1. **Status Assessment**
   - Current workflow/system state
   - Progress toward resolution

2. **Issues Identified**
   - Specific problems or anomalies observed
   - Patterns that may indicate root cause

3. **Root Cause Hypothesis**
   - Most likely cause based on evidence
   - Supporting observations

4. **Recommended Next Actions**
   - Specific diagnostic or remediation steps
   - Priority order if multiple actions

5. **Lessons for Future**
   - Patterns to watch for in similar cases
   - What worked or didn't work

Provide concise, actionable guidance. Focus on what the agent should do next to resolve the situation effectively.
"""


class HindsightBuilder:
    """
    Agent hindsight generator.
    
    Analyzes execution history and current state to generate
    reflection insights that help prevent repeated failures.
    """

    def __init__(self, cfg: AgentConfig) -> None:
        self.cfg = cfg
        self._hindsight_cache: Dict[str, str] = {}  # Cache recent hindsights

    def summarize_history(
        self,
        history: List[Dict[str, Any]],
        max_messages: int = 5,
        max_content_len: int = 500,
    ) -> str:
        """
        Summarize recent execution history for hindsight generation.
        
        Args:
            history: List of history entries with role/content
            max_messages: Number of recent messages to include
            max_content_len: Max chars per message content
            
        Returns:
            Condensed history summary string
        """
        if not history:
            return "No previous actions recorded."
        
        summary_parts = []
        recent = history[-max_messages:]
        
        for entry in recent:
            role = entry.get("role", "unknown")
            content = entry.get("content", "")
            
            # Truncate long content
            if len(content) > max_content_len:
                content = content[:max_content_len] + "..."
            
            summary_parts.append(f"[{role.upper()}]: {content}")
        
        return "\n".join(summary_parts)

    def generate_hindsight_prompt(
        self,
        current_input: str,
        history: List[Dict[str, Any]],
        failure_context: Optional[Dict[str, Any]] = None,
    ) -> str:
        """
        Build the hindsight generation prompt.
        
        Args:
            current_input: Current environment state/output
            history: Execution history
            failure_context: Optional details about detected failures
            
        Returns:
            Formatted prompt for hindsight LLM call
        """
        summarized_history = self.summarize_history(history)
        
        # Format the embedded hindsight prompt
        prompt = HINDSIGHT_PROMPT.format(
            history=summarized_history,
            current_input=current_input[:2000],
            failure_context=failure_context or "None detected",
        )

        return prompt

    def develop_hindsight(
        self,
        current_input: str,
        history: List[Dict[str, Any]],
        failure_context: Optional[Dict[str, Any]] = None,
        scan_id: str = "",
    ) -> Optional[str]:
        """
        Develop hindsight based on current state and execution history.
        
        This is the main entry point for hindsight generation. It:
        1. Builds a reflection prompt from history and current state
        2. Calls the LLM to generate hindsight
        3. Returns actionable guidance for the next step
        
        Args:
            current_input: Current environment output/state
            history: Execution history (list of role/content dicts)
            failure_context: Optional failure details
            scan_id: Scan identifier for tracing
            
        Returns:
            Hindsight guidance string, or None if generation failed
        """
        if not history:
            logger.debug("No history available for hindsight generation")
            return None
        
        prompt = self.generate_hindsight_prompt(
            current_input=current_input,
            history=history,
            failure_context=failure_context,
        )
        
        logger.info("Generating hindsight reflection...")
        
        try:
            client = _create_openai_client(self.cfg)
            response = client.chat.completions.create(
                model=self.cfg.model_alias,
                messages=[{"role": "user", "content": prompt}],
                temperature=0.3,
                max_completion_tokens=800,
            )
            
            hindsight = response.choices[0].message.content
            if hindsight:
                logger.info("Hindsight generated: %d chars", len(hindsight))
                return hindsight.strip()
            
            return None
            
        except Exception as exc:
            logger.warning("Hindsight generation failed: %s", exc)
            return None

    def should_generate_hindsight(
        self,
        analysis_result: Dict[str, Any],
        history: List[Dict[str, Any]],
    ) -> bool:
        """
        Determine if hindsight generation should be triggered.
        
        Hindsight is valuable when:
        - Health score is low (issues detected)
        - There are unresolved issues from previous scans
        - Multiple consecutive failures/warnings
        - Complex multi-step analysis is needed
        
        Args:
            analysis_result: Current analysis result
            history: Execution history
            
        Returns:
            True if hindsight should be generated
        """
        # Check health score threshold
        health = analysis_result.get("health", {})
        health_score = health.get("overall_health_score", 100)
        
        if health_score < 80:
            logger.debug("Hindsight triggered: low health score (%s)", health_score)
            return True
        
        # Check for issues
        issues = analysis_result.get("issues", [])
        critical_issues = [i for i in issues if i.get("severity") == "critical"]
        
        if critical_issues:
            logger.debug("Hindsight triggered: %d critical issues", len(critical_issues))
            return True
        
        # Check history for repeated failures
        if len(history) >= 3:
            recent_failures = sum(
                1 for h in history[-3:]
                if "error" in str(h.get("content", "")).lower()
                or "failed" in str(h.get("content", "")).lower()
            )
            if recent_failures >= 2:
                logger.debug("Hindsight triggered: repeated failures in history")
                return True
        
        return False

    def extract_failure_context(
        self,
        mcp_data: Dict[str, Any],
        analysis_result: Dict[str, Any],
    ) -> Dict[str, Any]:
        """
        Extract failure context from MCP data and analysis results.
        
        Args:
            mcp_data: Raw MCP data collection
            analysis_result: LLM analysis result
            
        Returns:
            Structured failure context dict
        """
        context: Dict[str, Any] = {
            "mcp_errors": [],
            "pod_issues": [],
            "analysis_issues": [],
            "health_score": None,
        }
        
        # Extract MCP errors
        data = mcp_data.get("data", {})
        for key, value in data.items():
            if isinstance(value, dict) and value.get("error"):
                context["mcp_errors"].append({
                    "tool": key,
                    "error": value["error"],
                })
        
        # Extract pod issues
        pods_data = data.get("pods_list_in_namespace", {})
        if isinstance(pods_data, dict):
            for pod_name, pod_info in pods_data.items():
                if isinstance(pod_info, dict):
                    status = pod_info.get("status", "")
                    restarts = pod_info.get("restarts", 0)
                    if status not in ("Running", "Succeeded") or restarts > 0:
                        context["pod_issues"].append({
                            "pod": pod_name,
                            "status": status,
                            "restarts": restarts,
                        })
        
        # Extract analysis issues
        issues = analysis_result.get("issues", [])
        context["analysis_issues"] = [
            {
                "severity": i.get("severity"),
                "summary": i.get("summary"),
                "pod": i.get("affected_pod"),
            }
            for i in issues[:5]  # Limit to top 5
        ]
        
        # Health score
        health = analysis_result.get("health", {})
        context["health_score"] = health.get("overall_health_score")
        
        return context
