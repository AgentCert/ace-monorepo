"""
Flash Agent – Entry Point
==========================

Thin orchestrator harness. Loads configuration, sets up logging,
registers signal handlers, and drives the analysis loop.

Modes:
  - WATCH_MODE=true: Continuous monitoring with LLM-selected tools, 
                     triggers full analysis only on deviation
  - WATCH_MODE=false: Original scan-based mode with hindsight loop
"""

from __future__ import annotations

import logging
import os
import signal
import time
from typing import Dict, Any, List

from config import AgentConfig
from flash_agent import FlashAgent

LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s",
)
logger = logging.getLogger("flash-agent")

# Configuration
MAX_ITERATIONS = int(os.getenv("MAX_ITERATIONS", "10"))
RESCAN_DELAY = int(os.getenv("RESCAN_DELAY", "30"))
WATCH_MODE = os.getenv("WATCH_MODE", "false").lower() in ("true", "1", "yes")
WATCH_NAMESPACE = os.getenv("WATCH_NAMESPACE", "")
WATCH_INTERVAL = float(os.getenv("WATCH_INTERVAL", "5.0"))

_shutdown = False


def _handle_signal(signum, _frame) -> None:
    global _shutdown
    logger.info("Received signal %s – shutting down gracefully", signum)
    _shutdown = True


signal.signal(signal.SIGTERM, _handle_signal)
signal.signal(signal.SIGINT, _handle_signal)


def _has_unresolved_issues(analysis: Dict[str, Any]) -> bool:
    """Check if analysis contains critical or warning issues."""
    issues: List[Dict[str, Any]] = analysis.get("issues", [])
    return any(issue.get("severity", "").lower() in ("critical", "warning") for issue in issues)


def _count_issues_by_severity(analysis: Dict[str, Any]) -> Dict[str, int]:
    """Count issues by severity level."""
    issues: List[Dict[str, Any]] = analysis.get("issues", [])
    counts = {"critical": 0, "warning": 0, "info": 0}
    for issue in issues:
        severity = issue.get("severity", "info").lower()
        if severity in counts:
            counts[severity] += 1
    return counts


def run_watch_mode(cfg: AgentConfig, agent: FlashAgent) -> None:
    """
    Watch mode: LLM selects tools once, then polls without LLM until deviation.
    
    Env vars:
        WATCH_NAMESPACE: Required - namespace to monitor
        WATCH_INTERVAL: Poll interval in seconds (default 5)
    """
    namespace = WATCH_NAMESPACE or cfg.scan_query.split()[-1]  # Fallback: last word of query
    if not namespace or namespace == "namespace":
        logger.error("WATCH_NAMESPACE not set and couldn't infer from scan_query")
        raise SystemExit(1)
    
    logger.info(
        "Watch Mode | namespace=%s | interval=%.1fs",
        namespace, WATCH_INTERVAL,
    )
    
    # Phase 1: Establish baseline (LLM selects tools)
    try:
        baseline = agent.establish_baseline(namespace)
    except Exception as exc:
        logger.exception("Failed to establish baseline: %s", exc)
        raise SystemExit(1)
    
    logger.info(
        "Baseline established | tools=%s | thresholds=%s",
        [t["name"] for t in baseline.watch_tools],
        baseline.healthy_thresholds,
    )
    
    # Phase 2: Watch loop (no LLM until deviation)
    agent.watch(
        baseline=baseline,
        poll_interval=WATCH_INTERVAL,
        shutdown_check=lambda: _shutdown,
    )
    
    logger.info("Watch mode terminated")


def run_scan_mode(cfg: AgentConfig, agent: FlashAgent) -> None:
    """
    Scan mode: Original hindsight loop - scan, analyze, rescan if issues.
    """
    iteration = 0
    
    while not _shutdown and iteration < MAX_ITERATIONS:
        iteration += 1
        logger.info("═══ Hindsight iteration %d/%d ═══", iteration, MAX_ITERATIONS)
        
        try:
            analysis = agent.scan(cfg.scan_query)
        except Exception as exc:
            logger.exception("Scan cycle failed: %s", exc)
            break
        
        if not _has_unresolved_issues(analysis):
            counts = _count_issues_by_severity(analysis)
            logger.info(
                "✓ All issues resolved! critical=%d warning=%d info=%d",
                counts["critical"], counts["warning"], counts["info"],
            )
            break
        
        counts = _count_issues_by_severity(analysis)
        logger.info(
            "Issues remaining: critical=%d warning=%d info=%d – re-scan in %ds",
            counts["critical"], counts["warning"], counts["info"], RESCAN_DELAY,
        )
        
        for _ in range(RESCAN_DELAY):
            if _shutdown:
                break
            time.sleep(1)
    
    if iteration >= MAX_ITERATIONS and not _shutdown:
        logger.warning("Max iterations (%d) reached", MAX_ITERATIONS)
    
    logger.info("Scan mode terminated | iterations=%d", iteration)


def main() -> None:
    """Entry point for Flash Agent."""
    cfg = AgentConfig.from_env()
    errors = cfg.validate()
    if errors:
        for err in errors:
            logger.error("Config error: %s", err)
        raise SystemExit(1)
    
    logger.info(
        "Flash Agent | agent=%s | model=%s | MCP=%d | mode=%s",
        cfg.agent_name, cfg.model_alias, len(cfg.mcp_urls),
        "watch" if WATCH_MODE else "scan",
    )
    
    agent = FlashAgent(cfg)
    
    if WATCH_MODE:
        run_watch_mode(cfg, agent)
    else:
        run_scan_mode(cfg, agent)
    
    logger.info("Flash Agent shut down cleanly")


if __name__ == "__main__":
    main()
