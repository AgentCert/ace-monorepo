"""
Unit tests for the outer scan-loop lifetime in main.py.

The agent runs as a Deployment beside the app for the whole Argo workflow and
must keep scanning until the workflow's onExit cleanup uninstalls it (SIGTERM).
A clean scan, or an MCP/LLM outage, must not end the process in continuous
mode; legacy one-shot behaviour (SCAN_INTERVAL unset/0) must be unchanged.

No network: FlashAgent is replaced by a fake whose scan() returns canned
analyses, and main._wait is patched so no test actually sleeps. Run with:

    python -m unittest tests.test_continuous_loop -v     # or: pytest tests/

(from agents/flash-agent/).
"""

from __future__ import annotations

import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import main  # noqa: E402
from main import LoopSettings  # noqa: E402

CLEAN = {"health": {"overall_health_score": 100}, "issues": [], "status": "completed"}
ISSUES = {"issues": [{"severity": "critical", "summary": "pod crash-looping"}], "status": "completed"}
FAILED = {"health": {"overall_health_score": -1}, "issues": [], "status": "failed",
          "status_reason": "no_mcp_tools_discovered"}


class _FakeAgent:
    """Replays ``results`` (dicts are returned, exceptions are raised)."""

    def __init__(self, results):
        self._results = list(results)
        self.calls = 0

    def scan(self, _query):
        self.calls += 1
        item = self._results[min(self.calls - 1, len(self._results) - 1)]
        if isinstance(item, BaseException):
            raise item
        return dict(item)


class _Cfg:
    scan_query = "Analyse namespace sock-shop"


class _WaitRecorder:
    """Stand-in for main._wait: records delays, requests shutdown after N waits."""

    def __init__(self, stop_after: int):
        self.delays: list[float] = []
        self.stop_after = stop_after

    def __call__(self, seconds):
        self.delays.append(seconds)
        if len(self.delays) >= self.stop_after:
            main._SHUTDOWN.set()
        return main._SHUTDOWN.is_set()


class _Base(unittest.TestCase):
    def setUp(self):
        main._SHUTDOWN.clear()

    def tearDown(self):
        main._SHUTDOWN.clear()

    def _run(self, settings, results, stop_after=50):
        agent = _FakeAgent(results)
        waiter = _WaitRecorder(stop_after)
        with mock.patch.object(main, "_wait", waiter):
            ok = main.run_scan_mode(_Cfg(), agent, settings)
        return ok, agent, waiter


class TestLoopSettings(unittest.TestCase):
    def test_unset_is_legacy_oneshot(self):
        s = LoopSettings.from_env({})
        self.assertFalse(s.continuous)
        self.assertEqual(s.max_iterations, 10)

    def test_scan_interval_zero_is_legacy(self):
        s = LoopSettings.from_env({"SCAN_INTERVAL": "0"})
        self.assertFalse(s.continuous)

    def test_scan_interval_enables_continuous_unlimited(self):
        s = LoopSettings.from_env({"SCAN_INTERVAL": "60"})
        self.assertTrue(s.continuous)
        self.assertEqual(s.interval, 60)
        self.assertEqual(s.max_iterations, 0)

    def test_continuous_flag_uses_rescan_delay(self):
        s = LoopSettings.from_env({"CONTINUOUS": "true", "RESCAN_DELAY": "15"})
        self.assertTrue(s.continuous)
        self.assertEqual(s.interval, 15)

    def test_explicit_max_iterations_respected(self):
        s = LoopSettings.from_env({"SCAN_INTERVAL": "60", "MAX_ITERATIONS": "3"})
        self.assertEqual(s.max_iterations, 3)

    def test_garbage_values_do_not_crash(self):
        s = LoopSettings.from_env({"SCAN_INTERVAL": "abc", "MAX_ITERATIONS": ""})
        self.assertFalse(s.continuous)
        self.assertEqual(s.max_iterations, 10)

    def test_failure_backoff_is_exponential_and_bounded(self):
        s = LoopSettings(continuous=True, scan_interval=5, max_iterations=0,
                         rescan_delay=30, backoff_max=120)
        self.assertEqual([s.failure_backoff(n) for n in range(1, 9)],
                         [5, 10, 20, 40, 80, 120, 120, 120])
        # Never below the scan interval, even if the cap is smaller.
        s2 = LoopSettings(continuous=True, scan_interval=300, max_iterations=0,
                          rescan_delay=30, backoff_max=120)
        self.assertEqual(s2.failure_backoff(1), 300)
        self.assertEqual(s2.failure_backoff(50), 300)


class TestContinuousMode(_Base):
    settings = LoopSettings(continuous=True, scan_interval=60, max_iterations=0,
                            rescan_delay=30, backoff_max=120)

    def test_clean_scan_does_not_end_process(self):
        ok, agent, waiter = self._run(self.settings, [CLEAN], stop_after=5)
        self.assertTrue(ok)
        # Kept scanning after every clean scan until SIGTERM (simulated).
        self.assertEqual(agent.calls, 5)
        self.assertEqual(waiter.delays, [60] * 5)

    def test_failures_back_off_and_never_exit(self):
        results = [FAILED, RuntimeError("LLM 503"), FAILED, CLEAN, FAILED]
        ok, agent, waiter = self._run(self.settings, results, stop_after=5)
        self.assertTrue(ok)  # continuous mode never reports failure / exits non-zero
        self.assertEqual(agent.calls, 5)
        # 1st/2nd/3rd consecutive failure -> 60,120,120 (capped); success resets.
        self.assertEqual(waiter.delays, [60, 120, 120, 60, 60])

    def test_shutdown_before_start_runs_nothing(self):
        main._SHUTDOWN.set()
        ok, agent, _ = self._run(self.settings, [CLEAN])
        self.assertTrue(ok)
        self.assertEqual(agent.calls, 0)

    def test_explicit_max_iterations_caps(self):
        capped = LoopSettings(continuous=True, scan_interval=60, max_iterations=3,
                              rescan_delay=30, backoff_max=120)
        ok, agent, waiter = self._run(capped, [ISSUES])
        self.assertTrue(ok)
        self.assertEqual(agent.calls, 3)
        self.assertEqual(len(waiter.delays), 2)  # no sleep after the final cycle

    def test_heartbeat_logged_each_cycle(self):
        with self.assertLogs("flash-agent", level="INFO") as logs:
            self._run(self.settings, [CLEAN], stop_after=3)
        beats = [line for line in logs.output if "heartbeat cycle=" in line]
        self.assertEqual(len(beats), 3)
        self.assertIn("heartbeat cycle=3 ts=", beats[-1])


class TestLegacyOneShotMode(_Base):
    settings = LoopSettings(continuous=False, scan_interval=0, max_iterations=10,
                            rescan_delay=30, backoff_max=120)

    def test_clean_scan_stops(self):
        ok, agent, waiter = self._run(self.settings, [CLEAN])
        self.assertTrue(ok)
        self.assertEqual(agent.calls, 1)
        self.assertEqual(waiter.delays, [])

    def test_failed_scan_returns_false(self):
        ok, agent, _ = self._run(self.settings, [FAILED])
        self.assertFalse(ok)
        self.assertEqual(agent.calls, 1)

    def test_exception_returns_false(self):
        ok, _, _ = self._run(self.settings, [RuntimeError("boom")])
        self.assertFalse(ok)

    def test_issues_rescan_until_max_iterations(self):
        ok, agent, waiter = self._run(self.settings, [ISSUES])
        self.assertTrue(ok)
        self.assertEqual(agent.calls, 10)
        self.assertEqual(waiter.delays, [30] * 10)


if __name__ == "__main__":
    unittest.main()
