"""
Flash Agent – Entry Point
==========================

Thin orchestrator harness. Loads configuration, sets up logging,
registers signal handlers, and drives the analysis loop.

Modes:
  - WATCH_MODE=true: Continuous monitoring with LLM-selected tools,
                     triggers full analysis only on deviation
  - WATCH_MODE=false: Original scan-based mode with hindsight loop

Scan-mode lifetime:
  - Legacy / one-shot (SCAN_INTERVAL unset or 0, CONTINUOUS unset): up to
    MAX_ITERATIONS (default 10) scans, stops at the first clean scan, exits
    non-zero if a scan could not produce a real analysis.
  - Continuous (SCAN_INTERVAL > 0 or CONTINUOUS=true): the in-cluster
    Deployment shape. Scans every SCAN_INTERVAL seconds until SIGTERM/SIGINT
    (the Argo workflow's onExit cleanup uninstalls the agent). A clean scan
    does NOT end the process, and a failed scan (MCP/LLM unavailable) backs
    off and retries instead of exiting — exiting here would only make the
    Deployment restart the pod with CrashLoop backoff and leave faults
    unobserved. MAX_ITERATIONS defaults to 0 (= unlimited) in this mode.
"""

from __future__ import annotations

import logging
import os
import signal
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import TYPE_CHECKING, Any, Dict, List, Mapping, Optional

if TYPE_CHECKING:
    from config import AgentConfig
    from flash_agent import FlashAgent


LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s",
)
logger = logging.getLogger("flash-agent")

# Watch-mode configuration
WATCH_MODE = os.getenv("WATCH_MODE", "false").lower() in ("true", "1", "yes")
WATCH_NAMESPACE = os.getenv("WATCH_NAMESPACE", "")
WATCH_INTERVAL = float(os.getenv("WATCH_INTERVAL", "5.0"))

# Set by SIGTERM/SIGINT. An Event (not a bare bool) so every sleep in the loop
# wakes up immediately on shutdown instead of finishing its full interval.
_SHUTDOWN = threading.Event()

_TRUTHY = ("1", "true", "yes", "on")


def _env_int(env: Mapping[str, str], name: str, default: int) -> int:
    raw = (env.get(name) or "").strip()
    if not raw:
        return default
    try:
        return int(float(raw))
    except ValueError:
        logger.warning("Ignoring non-numeric %s=%r (using %d)", name, raw, default)
        return default


@dataclass(frozen=True)
class LoopSettings:
    """Outer scan-loop knobs, read from the process environment."""

    continuous: bool
    scan_interval: int      # seconds between scans in continuous mode
    max_iterations: int     # 0 = unlimited
    rescan_delay: int       # legacy mode: seconds between scans while issues remain
    backoff_max: int        # cap on the failure backoff (continuous mode)

    @classmethod
    def from_env(cls, env: Optional[Mapping[str, str]] = None) -> "LoopSettings":
        env = os.environ if env is None else env
        scan_interval = max(_env_int(env, "SCAN_INTERVAL", 0), 0)
        continuous = scan_interval > 0 or (env.get("CONTINUOUS") or "").strip().lower() in _TRUTHY
        rescan_delay = max(_env_int(env, "RESCAN_DELAY", 30), 0)
        # Unset MAX_ITERATIONS keeps the historical cap of 10 for one-shot runs,
        # but means "unlimited" for a continuous Deployment — a cap there just
        # turns into an exit + pod restart mid-workflow.
        max_iterations = max(_env_int(env, "MAX_ITERATIONS", 0 if continuous else 10), 0)
        backoff_max = max(_env_int(env, "AGENT_RETRY_BACKOFF_MAX_SECONDS", 120), 1)
        return cls(
            continuous=continuous,
            scan_interval=scan_interval,
            max_iterations=max_iterations,
            rescan_delay=rescan_delay,
            backoff_max=backoff_max,
        )

    @property
    def interval(self) -> int:
        """Seconds between continuous-mode scans (never 0 — avoids a hot loop)."""
        return max(self.scan_interval or self.rescan_delay, 1)

    def failure_backoff(self, consecutive_failures: int) -> int:
        """Exponential backoff after N consecutive failed scans, bounded.

        Starts at the scan interval and doubles, capped at
        max(interval, AGENT_RETRY_BACKOFF_MAX_SECONDS) so an MCP/LLM outage
        neither hammers the dependency nor leaves the agent blind for long
        once it recovers.
        """
        n = max(consecutive_failures, 1)
        cap = max(self.interval, self.backoff_max)
        return int(min(self.interval * (2 ** min(n - 1, 16)), cap))


def _handle_signal(signum, _frame) -> None:
    logger.info("Received signal %s – shutting down gracefully", signum)
    _SHUTDOWN.set()


def _install_signal_handlers() -> None:
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)


def _shutdown_requested() -> bool:
    return _SHUTDOWN.is_set()


def _wait(seconds: float) -> bool:
    """Sleep up to ``seconds``; returns True as soon as shutdown is requested."""
    if seconds <= 0:
        return _SHUTDOWN.is_set()
    return _SHUTDOWN.wait(seconds)


def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


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


def _scan_failed(analysis: Dict[str, Any]) -> bool:
    """Check if the scan could not produce a real analysis (LLM/tooling failure)."""
    return analysis.get("status") == "failed"


def run_watch_mode(cfg: AgentConfig, agent: FlashAgent, settings: Optional[LoopSettings] = None) -> None:
    """
    Watch mode: LLM selects tools once, then polls without LLM until deviation.

    Env vars:
        WATCH_NAMESPACE: Required - namespace to monitor
        WATCH_INTERVAL: Poll interval in seconds (default 5)

    In continuous mode a failed baseline (LLM/MCP not ready yet) or a watch
    loop that returns early (no MCP clients) is retried with bounded backoff
    until SIGTERM, instead of exiting the process.
    """
    settings = settings or LoopSettings.from_env()
    namespace = WATCH_NAMESPACE or cfg.scan_query.split()[-1]  # Fallback: last word of query
    if not namespace or namespace == "namespace":
        logger.error("WATCH_NAMESPACE not set and couldn't infer from scan_query")
        raise SystemExit(1)

    logger.info(
        "Watch Mode | namespace=%s | interval=%.1fs | continuous=%s",
        namespace, WATCH_INTERVAL, settings.continuous,
    )

    failures = 0
    while not _shutdown_requested():
        # Phase 1: Establish baseline (LLM selects tools)
        try:
            baseline = agent.establish_baseline(namespace)
        except Exception as exc:
            if not settings.continuous:
                logger.exception("Failed to establish baseline: %s", exc)
                raise SystemExit(1)
            failures += 1
            delay = settings.failure_backoff(failures)
            logger.error(
                "Failed to establish baseline (attempt %d): %s — retrying in %ds",
                failures, exc, delay,
            )
            _wait(delay)
            continue

        logger.info(
            "Baseline established | tools=%s | thresholds=%s",
            [t["name"] for t in baseline.watch_tools],
            baseline.healthy_thresholds,
        )

        # Phase 2: Watch loop (no LLM until deviation)
        try:
            agent.watch(
                baseline=baseline,
                poll_interval=WATCH_INTERVAL,
                shutdown_check=_shutdown_requested,
            )
        except Exception as exc:  # noqa: BLE001
            if not settings.continuous:
                raise
            logger.exception("Watch loop raised: %s", exc)
        if not settings.continuous or _shutdown_requested():
            break
        failures += 1
        delay = settings.failure_backoff(failures)
        logger.error("Watch loop ended unexpectedly — re-establishing baseline in %ds", delay)
        _wait(delay)

    logger.info("Watch mode terminated")


def run_scan_mode(cfg: AgentConfig, agent: FlashAgent, settings: Optional[LoopSettings] = None) -> bool:
    """
    Scan mode: hindsight loop - scan, analyze, rescan.

    Returns:
        True if the mode terminated normally (clean scan / max iterations in
        one-shot mode, or graceful shutdown). False if a one-shot scan cycle
        could not produce a real analysis (LLM/MCP failure) — caller should
        exit non-zero. Continuous mode never returns False: failures are
        retried with bounded backoff until SIGTERM.
    """
    settings = settings or LoopSettings.from_env()
    if settings.continuous:
        return _run_continuous_scan(cfg, agent, settings)
    return _run_oneshot_scan(cfg, agent, settings)


def _run_oneshot_scan(cfg: AgentConfig, agent: FlashAgent, settings: LoopSettings) -> bool:
    """Legacy behaviour: stop at the first clean scan or after MAX_ITERATIONS."""
    iteration = 0
    max_iterations = settings.max_iterations

    while not _shutdown_requested() and (max_iterations <= 0 or iteration < max_iterations):
        iteration += 1
        logger.info("═══ Hindsight iteration %d/%s ═══", iteration, max_iterations or "∞")

        try:
            analysis = agent.scan(cfg.scan_query)
        except Exception as exc:
            logger.exception("Scan cycle failed: %s", exc)
            return False

        if _scan_failed(analysis):
            logger.error(
                "✗ Scan could not complete (%s) — treating as unhealthy, NOT resolved",
                analysis.get("status_reason", "unknown"),
            )
            return False

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
            counts["critical"], counts["warning"], counts["info"], settings.rescan_delay,
        )

        if _wait(settings.rescan_delay):
            break

    if max_iterations > 0 and iteration >= max_iterations and not _shutdown_requested():
        logger.warning("Max iterations (%d) reached", max_iterations)

    logger.info("Scan mode terminated | iterations=%d", iteration)
    return True


def _run_continuous_scan(cfg: AgentConfig, agent: FlashAgent, settings: LoopSettings) -> bool:
    """Scan every ``settings.interval`` seconds until shutdown (or MAX_ITERATIONS>0)."""
    iteration = 0
    consecutive_failures = 0
    max_iterations = settings.max_iterations
    logger.info(
        "Continuous scan mode | interval=%ds | max_iterations=%s | backoff_max=%ds",
        settings.interval, max_iterations or "unlimited", settings.backoff_max,
    )

    while not _shutdown_requested() and (max_iterations <= 0 or iteration < max_iterations):
        iteration += 1
        logger.info(
            "heartbeat cycle=%d ts=%s mode=continuous consecutive_failures=%d",
            iteration, _utc_now(), consecutive_failures,
        )

        failed_reason = ""
        try:
            analysis = agent.scan(cfg.scan_query)
        except Exception as exc:  # noqa: BLE001 — never let one cycle kill the pod
            logger.exception("Scan cycle %d raised: %s", iteration, exc)
            analysis = None
            failed_reason = f"exception: {exc}"
        else:
            if _scan_failed(analysis):
                failed_reason = str(analysis.get("status_reason", "unknown"))

        if failed_reason:
            consecutive_failures += 1
            delay = settings.failure_backoff(consecutive_failures)
            logger.error(
                "✗ Scan %d could not complete (%s) — MCP/LLM likely unavailable; "
                "consecutive failures=%d, retrying in %ds (process stays up)",
                iteration, failed_reason, consecutive_failures, delay,
            )
        else:
            consecutive_failures = 0
            delay = settings.interval
            counts = _count_issues_by_severity(analysis or {})
            if _has_unresolved_issues(analysis or {}):
                logger.info(
                    "Issues remaining: critical=%d warning=%d info=%d – next scan in %ds",
                    counts["critical"], counts["warning"], counts["info"], delay,
                )
            else:
                logger.info(
                    "✓ No unresolved issues (critical=%d warning=%d info=%d) – "
                    "continuing to watch, next scan in %ds",
                    counts["critical"], counts["warning"], counts["info"], delay,
                )

        if max_iterations > 0 and iteration >= max_iterations:
            logger.warning("Max iterations (%d) reached", max_iterations)
            break
        if _wait(delay):
            break

    logger.info("Scan mode terminated | iterations=%d | shutdown=%s", iteration, _shutdown_requested())
    return True


def main() -> None:
    # Keep the outer-loop module importable without the full runtime dependency
    """Entry point for Flash Agent."""
    # graph. This lets lifecycle/backoff behavior be tested in a clean offline
    # environment while production still imports the real implementations here.
    from config import AgentConfig
    from flash_agent import FlashAgent

    _install_signal_handlers()
    # Read before AgentConfig.from_env() loads .env, matching the historical
    # behaviour of these outer-loop knobs (process env only).
    settings = LoopSettings.from_env()
    cfg = AgentConfig.from_env()
    errors = cfg.validate()
    if errors:
        for err in errors:
            logger.error("Config error: %s", err)
        raise SystemExit(1)

    logger.info(
        "Flash Agent | agent=%s | model=%s | MCP=%d | mode=%s | continuous=%s",
        cfg.agent_name, cfg.model_alias, len(cfg.mcp_urls),
        "watch" if WATCH_MODE else "scan", settings.continuous,
    )

    agent = FlashAgent(cfg)

    if WATCH_MODE:
        run_watch_mode(cfg, agent, settings)
    else:
        if not run_scan_mode(cfg, agent, settings):
            logger.error("Flash Agent scan mode failed — exiting non-zero")
            raise SystemExit(1)

    logger.info("Flash Agent shut down cleanly")


if __name__ == "__main__":
    main()
