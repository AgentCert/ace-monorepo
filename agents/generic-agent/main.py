"""
Generic Agent – entry point
============================

Thin orchestrator harness. Loads configuration, sets up logging, registers
signal handlers, and drives the analysis loop.

Modes:
  - SCAN_INTERVAL=0  : run the hindsight loop once, then exit (job-like)
  - SCAN_INTERVAL>0  : keep re-scanning until issues clear or MAX_ITERATIONS
  - WATCH_MODE=true  : establish a baseline once, then poll without the LLM
                       until a deviation is detected
"""

from __future__ import annotations

import logging
import os
import signal
import time
from typing import Any, Dict, List

from agent_core import GenericAgent
from config import AgentConfig

LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s",
)
logger = logging.getLogger("generic-agent")

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
    issues: List[Dict[str, Any]] = analysis.get("issues", [])
    return any(issue.get("severity", "").lower() in ("critical", "warning") for issue in issues)


def _count_issues_by_severity(analysis: Dict[str, Any]) -> Dict[str, int]:
    issues: List[Dict[str, Any]] = analysis.get("issues", [])
    counts = {"critical": 0, "warning": 0, "info": 0}
    for issue in issues:
        severity = issue.get("severity", "info").lower()
        if severity in counts:
            counts[severity] += 1
    return counts


def _scan_failed(analysis: Dict[str, Any]) -> bool:
    """True when the scan could not produce a real analysis (LLM/MCP failure)."""
    return analysis.get("status") == "failed"


def run_watch_mode(cfg: AgentConfig, agent: GenericAgent) -> None:
    namespace = WATCH_NAMESPACE or cfg.scope_override
    if not namespace:
        logger.error("WATCH_MODE needs WATCH_NAMESPACE or AGENT_SCOPE_NAMESPACE")
        raise SystemExit(1)

    logger.info("Watch mode | namespace=%s | interval=%.1fs", namespace, WATCH_INTERVAL)

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

    agent.watch(
        baseline=baseline,
        poll_interval=WATCH_INTERVAL,
        shutdown_check=lambda: _shutdown,
    )
    logger.info("Watch mode terminated")


def run_scan_mode(cfg: AgentConfig, agent: GenericAgent) -> bool:
    """Returns False when a scan cycle could not produce a real analysis."""
    iteration = 0

    while not _shutdown and iteration < MAX_ITERATIONS:
        iteration += 1
        logger.info("=== Hindsight iteration %d/%d ===", iteration, MAX_ITERATIONS)

        try:
            analysis = agent.scan(cfg.scan_query)
        except Exception as exc:
            logger.exception("Scan cycle failed: %s", exc)
            return False

        if _scan_failed(analysis):
            logger.error(
                "Scan could not complete (%s) — treating as unhealthy, NOT resolved",
                analysis.get("status_reason", "unknown"),
            )
            return False

        counts = _count_issues_by_severity(analysis)

        if not _has_unresolved_issues(analysis):
            logger.info(
                "All issues resolved | critical=%d warning=%d info=%d",
                counts["critical"], counts["warning"], counts["info"],
            )
            break

        logger.info(
            "Issues remaining | critical=%d warning=%d info=%d – re-scan in %ds",
            counts["critical"], counts["warning"], counts["info"], RESCAN_DELAY,
        )

        for _ in range(RESCAN_DELAY):
            if _shutdown:
                break
            time.sleep(1)

    if iteration >= MAX_ITERATIONS and not _shutdown:
        logger.warning("Max iterations (%d) reached", MAX_ITERATIONS)

    logger.info("Scan mode terminated | iterations=%d", iteration)
    return True


def main() -> None:
    cfg = AgentConfig.from_env()
    errors = cfg.validate()
    if errors:
        for err in errors:
            logger.error("Config error: %s", err)
        raise SystemExit(1)

    logger.info(
        "Generic Agent | agent=%s | model=%s | MCP=%d | scope=%s | mode=%s",
        cfg.agent_name, cfg.model_alias, len(cfg.mcp_urls),
        cfg.scope_override or "auto-discover",
        "watch" if WATCH_MODE else "scan",
    )

    agent = GenericAgent(cfg)

    if WATCH_MODE:
        run_watch_mode(cfg, agent)
    elif not run_scan_mode(cfg, agent):
        logger.error("Generic Agent scan mode failed — exiting non-zero")
        raise SystemExit(1)

    logger.info("Generic Agent shut down cleanly")


if __name__ == "__main__":
    main()
