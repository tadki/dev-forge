"""A/B test for SEE-751: compare backlog scanning behavior before vs after fix.

Pre-fix (before commit 57cd4f0):
  STATUSES = ["todo", "in_progress", "blocked", "backlog"]
  → Script queries for backlog issues, processes them, may send push reminders.

Post-fix (commit 57cd4f0):
  STATUSES = ["todo", "in_progress", "blocked"]
  → Script never queries for backlog issues, they are completely excluded.

This test simulates both behaviors and verifies the behavioral difference.
"""

import contextlib
import json
import os
import sys
from datetime import datetime, timezone, timedelta
from io import StringIO
from unittest.mock import patch, MagicMock

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "autopilots"))


# ---------------------------------------------------------------------------
# Shared helpers & mock data
# ---------------------------------------------------------------------------

NOW = datetime.now(timezone.utc)
ISSUE_CREATED_1HR = (NOW - timedelta(hours=1)).isoformat()

ALL_AGENTS = [{"id": "agent-001", "name": "Atlas"}]
ALL_MEMBERS = [{"user_id": "user-001", "name": "jerry"}]

BACKLOG_ISSUE = {
    "id": "issue-backlog-ab",
    "identifier": "SEE-BACKLOG-AB",
    "title": "Backlog issue for A/B comparison",
    "status": "backlog",
    "assignee_id": None,
    "created_at": ISSUE_CREATED_1HR,
}


def _make_mock_subprocess():
    """Mock subprocess that tracks queried statuses."""
    queried_statuses = []

    # multica_cli（SEE-956 H8 重构后）以 subprocess.run(cmd, shell=False,
    # input=...) 调用并检查 returncode；mock 透传任意签名并返回 returncode=0
    # 的 CompletedProcess 形状，否则 TypeError 触发退避重试、fetch 全失败。
    def mock_run(cmd, *args, **kwargs):
        cmd_str = " ".join(cmd) if isinstance(cmd, list) else (cmd or "")

        if "multica agent list" in cmd_str:
            return MagicMock(returncode=0, stdout=json.dumps(ALL_AGENTS), stderr="")
        elif "multica workspace members" in cmd_str:
            return MagicMock(returncode=0, stdout=json.dumps(ALL_MEMBERS), stderr="")
        elif "multica issue list" in cmd_str:
            import re
            match = re.search(r"--status (\w+)", cmd_str)
            status = match.group(1) if match else ""
            queried_statuses.append(status)
            if status == "backlog":
                return MagicMock(returncode=0, stdout=json.dumps([BACKLOG_ISSUE]), stderr="")
            return MagicMock(returncode=0, stdout=json.dumps([]), stderr="")
        elif "multica issue comment list" in cmd_str:
            return MagicMock(returncode=0, stdout=json.dumps([]), stderr="")
        elif "multica issue runs" in cmd_str:
            return MagicMock(returncode=0, stdout=json.dumps([]), stderr="")
        elif "multica issue get" in cmd_str:
            return MagicMock(returncode=0, stdout=json.dumps(BACKLOG_ISSUE), stderr="")
        else:
            return MagicMock(returncode=0, stdout="", stderr="")

    mock_run._queried_statuses = queried_statuses
    return mock_run


def _run_with_statuses(statuses_list):
    """Run main() with a specific STATUSES list and return (result, queried_statuses)."""
    mock_fn = _make_mock_subprocess()
    buf = StringIO()

    with patch("issue_status_check.subprocess.run", mock_fn), \
         patch("issue_status_check.PidFileLock"), \
         contextlib.redirect_stdout(buf):

        import issue_status_check
        issue_status_check.dry_run = True
        issue_status_check.verbose = False
        issue_status_check.self_agent_id = "self-agent-001"
        issue_status_check.GRACE_PERIOD_MINUTES = 10
        # Override STATUSES for the test
        original = issue_status_check.STATUSES
        issue_status_check.STATUSES = statuses_list
        try:
            issue_status_check.main()
        finally:
            issue_status_check.STATUSES = original

    return json.loads(buf.getvalue()), mock_fn._queried_statuses


# ---------------------------------------------------------------------------
# A/B comparison
# ---------------------------------------------------------------------------

class TestABBacklogExclusion:
    """Compare pre-fix vs post-fix backlog scanning behavior."""

    def test_prefix_queries_backlog(self):
        """Pre-fix behavior: STATUSES includes backlog, so it IS queried."""
        _, queried = _run_with_statuses(["todo", "in_progress", "blocked", "backlog"])
        assert "backlog" in queried, "Pre-fix: backlog should be queried"

    def test_postfix_does_not_query_backlog(self):
        """Post-fix behavior: STATUSES excludes backlog, so it is NOT queried."""
        _, queried = _run_with_statuses(["todo", "in_progress", "blocked"])
        assert "backlog" not in queried, "Post-fix: backlog should NOT be queried"

    def test_prefix_backlog_issue_appears_in_output(self):
        """Pre-fix: backlog issue appears in output categories (e.g., no_assignee)."""
        result, _ = _run_with_statuses(["todo", "in_progress", "blocked", "backlog"])
        all_entries = (
            result.get("need_push", [])
            + result.get("need_push_decision", [])
            + result.get("running", [])
            + result.get("active", [])
            + result.get("no_assignee", [])
            + result.get("grace_period", [])
            # SEE-956 H1: fixture 无 description，得分低于阈值进 placeholder 桶
            + result.get("placeholder", [])
        )
        identifiers = {e.get("identifier") for e in all_entries}
        assert "SEE-BACKLOG-AB" in identifiers, (
            "Pre-fix: backlog issue should appear in output categories"
        )

    def test_postfix_backlog_issue_absent_from_output(self):
        """Post-fix: backlog issue is completely absent from output."""
        result, _ = _run_with_statuses(["todo", "in_progress", "blocked"])
        all_entries = (
            result.get("need_push", [])
            + result.get("need_push_decision", [])
            + result.get("running", [])
            + result.get("active", [])
            + result.get("no_assignee", [])
            + result.get("grace_period", [])
        )
        identifiers = {e.get("identifier") for e in all_entries}
        assert "SEE-BACKLOG-AB" not in identifiers, (
            "Post-fix: backlog issue must NOT appear in output"
        )

    def test_both_query_expected_active_statuses(self):
        """Both pre and post-fix query the 3 active statuses."""
        for statuses in [
            ["todo", "in_progress", "blocked", "backlog"],
            ["todo", "in_progress", "blocked"],
        ]:
            _, queried = _run_with_statuses(statuses)
            for s in ["todo", "in_progress", "blocked"]:
                assert s in queried, f"Status '{s}' should always be queried"
