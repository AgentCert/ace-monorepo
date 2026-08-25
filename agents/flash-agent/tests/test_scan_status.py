"""
Unit tests for the scan-result status helpers in main.py.

Covers the fix for a false "All issues resolved" report when the ReAct loop
could not produce a real analysis (e.g. every LLM call failed). Run with:

    python -m unittest tests.test_scan_status -v

(from agents/flash-agent/). Stdlib unittest only — no pytest dependency in
this component.
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from main import _has_unresolved_issues, _scan_failed  # noqa: E402


class TestScanFailed(unittest.TestCase):
    def test_failed_status_is_failed(self):
        analysis = {
            "health": {"overall_health_score": -1},
            "issues": [],
            "status": "failed",
            "status_reason": "react_loop_no_analysis",
        }
        self.assertTrue(_scan_failed(analysis))

    def test_completed_status_is_not_failed(self):
        analysis = {"health": {"overall_health_score": 100}, "issues": [], "status": "completed"}
        self.assertFalse(_scan_failed(analysis))

    def test_missing_status_key_defaults_to_not_failed(self):
        """Old-shape dict (no 'status' key) must not crash or be treated as failed."""
        analysis = {"health": {"overall_health_score": 100}, "issues": []}
        self.assertFalse(_scan_failed(analysis))


class TestHasUnresolvedIssues(unittest.TestCase):
    def test_no_issues(self):
        self.assertFalse(_has_unresolved_issues({"issues": []}))

    def test_critical_issue(self):
        analysis = {"issues": [{"severity": "critical", "summary": "pod crash-looping"}]}
        self.assertTrue(_has_unresolved_issues(analysis))

    def test_info_only_issue_not_unresolved(self):
        analysis = {"issues": [{"severity": "info", "summary": "fyi"}]}
        self.assertFalse(_has_unresolved_issues(analysis))


if __name__ == "__main__":
    unittest.main()
