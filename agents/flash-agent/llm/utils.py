"""
LLM Utilities – Token Management and History Processing
=========================================================

Provides utilities for managing conversation history and token limits.
"""

from __future__ import annotations

import logging
from typing import Any, Dict, List, Optional

logger = logging.getLogger("flash-agent")

# Approximate token counts per character (conservative estimate)
CHARS_PER_TOKEN = 4


def estimate_tokens(text: str) -> int:
    """
    Estimate token count from text length.
    
    Uses a conservative 4 chars per token estimate.
    For precise counts, use tiktoken with the specific model.
    
    Args:
        text: Input text
        
    Returns:
        Estimated token count
    """
    return len(text) // CHARS_PER_TOKEN


def estimate_message_tokens(message: Dict[str, Any]) -> int:
    """
    Estimate tokens in a message dict.
    
    Accounts for role/content structure overhead (~4 tokens).
    
    Args:
        message: Dict with role and content keys
        
    Returns:
        Estimated token count
    """
    overhead = 4  # Role markers, formatting
    content = message.get("content", "")
    return overhead + estimate_tokens(content)


def trim_history_to_token_limit(
    history: List[Dict[str, Any]],
    max_tokens: int = 90000,
) -> List[Dict[str, Any]]:
    """
    Trim conversation history to fit within token limit.
    
    Preserves the most recent messages, trimming from the beginning.
    If even the last message exceeds the limit, truncates its content.
    
    Based on FLASH agent's token management approach.
    
    Args:
        history: List of message dicts with role/content
        max_tokens: Maximum token budget
        
    Returns:
        Trimmed history list that fits within token limit
    """
    if not history:
        return []
    
    # Work backwards from most recent
    trimmed: List[Dict[str, Any]] = []
    total_tokens = 0
    
    # Handle the last message specially - it must be included
    last_msg = history[-1]
    last_msg_tokens = estimate_message_tokens(last_msg)
    
    if last_msg_tokens > max_tokens:
        # Even last message is too long - truncate it
        content = last_msg.get("content", "")
        max_content_chars = (max_tokens - 4) * CHARS_PER_TOKEN
        truncated_content = content[:max_content_chars] + "... [truncated]"
        return [{"role": last_msg["role"], "content": truncated_content}]
    
    trimmed.insert(0, last_msg)
    total_tokens += last_msg_tokens
    
    # Add earlier messages in reverse order until limit
    for message in reversed(history[:-1]):
        message_tokens = estimate_message_tokens(message)
        
        if total_tokens + message_tokens > max_tokens:
            logger.debug(
                "History trimmed: %d messages removed to fit %d tokens",
                len(history) - len(trimmed),
                max_tokens,
            )
            break
        
        trimmed.insert(0, message)
        total_tokens += message_tokens
    
    return trimmed


def create_history_entry(
    role: str,
    content: str,
    metadata: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """
    Create a standardized history entry.
    
    Args:
        role: Message role (system, user, assistant, tool)
        content: Message content
        metadata: Optional metadata dict
        
    Returns:
        History entry dict
    """
    entry = {
        "role": role,
        "content": content,
    }
    if metadata:
        entry["metadata"] = metadata
    return entry


def format_mcp_result_for_history(
    mcp_data: Dict[str, Any],
    max_length: int = 2000,
) -> str:
    """
    Format MCP data for inclusion in history.
    
    Creates a condensed representation suitable for history tracking.
    
    Args:
        mcp_data: Raw MCP response data
        max_length: Max string length
        
    Returns:
        Formatted string summary
    """
    parts = []
    
    server_type = mcp_data.get("server_type", "unknown")
    namespace = mcp_data.get("namespace", "unknown")
    duration = mcp_data.get("_mcp_duration_sec", 0)
    
    parts.append(f"MCP {server_type} | namespace={namespace} | {duration:.1f}s")
    
    data = mcp_data.get("data", {})
    data_keys = list(data.keys())
    parts.append(f"Tools called: {', '.join(data_keys[:10])}")
    
    # Summarize key findings
    if "pods_list_in_namespace" in data:
        pods = data["pods_list_in_namespace"]
        if isinstance(pods, dict) and not pods.get("error"):
            parts.append(f"Pods: {len(pods)} found")
    
    if "events" in data:
        events = data["events"]
        if isinstance(events, list):
            parts.append(f"Events: {len(events)} found")
    
    # Check for errors
    errors = [k for k, v in data.items() if isinstance(v, dict) and v.get("error")]
    if errors:
        parts.append(f"Errors in: {', '.join(errors)}")
    
    result = "\n".join(parts)
    if len(result) > max_length:
        result = result[:max_length] + "..."
    
    return result


def format_analysis_for_history(
    analysis: Dict[str, Any],
    max_length: int = 1500,
) -> str:
    """
    Format analysis result for inclusion in history.
    
    Args:
        analysis: LLM analysis result dict
        max_length: Max string length
        
    Returns:
        Formatted string summary
    """
    parts = []
    
    health = analysis.get("health", {})
    score = health.get("overall_health_score", "?")
    pods = health.get("total_pods", 0)
    parts.append(f"Health Score: {score} | Pods: {pods}")
    
    issues = analysis.get("issues", [])
    if issues:
        parts.append(f"Issues ({len(issues)}):")
        for issue in issues[:5]:
            severity = issue.get("severity", "?")
            summary = issue.get("summary", "")[:100]
            pod = issue.get("affected_pod", "?")
            parts.append(f"  [{severity}] {pod}: {summary}")
    else:
        parts.append("No issues detected")
    
    exp_info = analysis.get("experiment_info", {})
    if exp_info.get("experiment_id"):
        parts.append(f"Experiment: {exp_info['experiment_id']}")
    
    result = "\n".join(parts)
    if len(result) > max_length:
        result = result[:max_length] + "..."
    
    return result
