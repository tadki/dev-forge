"""E2E test for SEE-751: backlog issues are excluded from scanning.

Verifies the full pipeline behavior: even when backlog issues exist in the
system, they are not fetched, not processed, and do not appear in any output
category.
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
# Helpers
# ---------------------------------------------------------------------------

NOW = datetime.now(timezone.utc)
ISSUE_CREATED_1HR = (NOW - timedelta(hours=1)).isoformat()

ALL_AGENTS = [{"id": "agent-001", "name": "Atlas"}]
ALL_MEMBERS = [{"user_id": "user-001", "name": "jerry"}]


def _make_mock_subprocess(mock_data: dict):
    """Mock subprocess.run that also tracks which statuses were queried."""
    queried_statuses = set()

    # multica_cli（SEE-956 H8 重构后）以 subprocess.run(cmd, shell=False,
    # input=...) 调用并检查 returncode；mock 透传任意签名并返回 returncode=0
    # 的 CompletedProcess 形状，否则 TypeError 触发退避重试、fetch 全失败。
    def mock_run(cmd, *args, **kwargs):
        cmd_str = " ".join(cmd) if isinstance(cmd, list) else (cmd or "")

        if "multica agent list" in cmd_str:
            return MagicMock(returncode=0, stdout=json.dumps(mock_data.get("agents", ALL_AGENTS)), stderr="")
        elif "multica workspace members" in cmd_str:
            return MagicMock(returncode=0, stdout=json.dumps(mock_data.get("members", ALL_MEMBERS)), stderr="")
        elif "multica issue list" in cmd_str:
            import re
            match = re.search(r"--status (\w+)", cmd_str)
            status = match.group(1) if match else ""
            queried_statuses.add(status)
            return MagicMock(
                returncode=0,
                stdout=json.dumps(mock_data.get("issues_by_status", {}).get(status, [])),
                stderr=""
            )
        elif "multica issue comment list" in cmd_str:
            return MagicMock(returncode=0, stdout=json.dumps(mock_data.get("comments", [])), stderr="")
        elif "multica issue runs" in cmd_str:
            return MagicMock(returncode=0, stdout=json.dumps(mock_data.get("runs", [])), stderr="")
        elif "multica issue get" in cmd_str:
            return MagicMock(returncode=0, stdout=json.dumps(mock_data.get("issue_detail", {})), stderr="")
        else:
            return MagicMock(returncode=0, stdout="", stderr="")

    mock_run._queried_statuses = queried_statuses
    return mock_run


def _run_main(mock_data: dict):
    """Run issue_status_check.main() and return (result_dict, queried_statuses)."""
    mock_data.setdefault("agents", ALL_AGENTS)
    mock_data.setdefault("members", ALL_MEMBERS)
    mock_run_fn = _make_mock_subprocess(mock_data)
    buf = StringIO()

    with patch("issue_status_check.subprocess.run", mock_run_fn), \
         patch("issue_status_check.PidFileLock"), \
         contextlib.redirect_stdout(buf):

        import issue_status_check
        issue_status_check.dry_run = True
        issue_status_check.verbose = False
        issue_status_check.self_agent_id = "self-agent-001"
        issue_status_check.GRACE_PERIOD_MINUTES = 10
        issue_status_check.main()

    return json.loads(buf.getvalue()), mock_run_fn._queried_statuses


# ---------------------------------------------------------------------------
# E2E Test: Backlog issue is NOT scanned
# ---------------------------------------------------------------------------

class TestBacklogExclusion:
    """Verify backlog issues are completely excluded from the pipeline."""

    def _mock_data(self):
        return {
            "issues_by_status": {
                "todo": [],
                "in_progress": [],
                "blocked": [],
                "backlog": [{
                    "id": "issue-backlog-001",
                    "identifier": "SEE-BACKLOG",
                    "title": "A backlog issue that should NOT be scanned",
                    "status": "backlog",
                    "assignee_id": None,
                    "created_at": ISSUE_CREATED_1HR,
                }],
            },
            "comments": [],
            "runs": [],
        }

    def test_backlog_status_not_queried(self):
        """The script must never run 'multica issue list --status backlog'."""
        _, queried_statuses = _run_main(self._mock_data())
        assert "backlog" not in queried_statuses, (
            "Script incorrectly queried backlog status"
        )
        assert queried_statuses == {"todo", "in_progress", "blocked"}

    def test_backlog_issue_not_in_any_category(self):
        """Backlog issue must not appear in any output category."""
        result, _ = _run_main(self._mock_data())
        all_categorized = (
            result.get("need_push", [])
            + result.get("need_push_decision", [])
            + result.get("running", [])
            + result.get("active", [])
            + result.get("no_assignee", [])
            + result.get("grace_period", [])
        )
        for entry in all_categorized:
            assert entry.get("identifier") != "SEE-BACKLOG", (
                "Backlog issue was incorrectly categorized"
            )

    def test_total_issues_count_excludes_backlog(self):
        """Summary total_issues must not count backlog issues."""
        result, _ = _run_main(self._mock_data())
        summary = result.get("summary", {})
        assert summary.get("total_issues", 0) == 0, (
            "Backlog issue should not contribute to total count"
        )

    def test_status_counts_do_not_include_backlog(self):
        """Summary status_counts must not include a backlog key."""
        result, _ = _run_main(self._mock_data())
        summary = result.get("summary", {})
        status_counts = summary.get("status_counts", {})
        assert "backlog" not in status_counts, (
            "status_counts should not include backlog key"
        )


# ---------------------------------------------------------------------------
# E2E Test: Active + backlog mixed — only active are scanned
# ---------------------------------------------------------------------------

class TestMixedStatuses:
    """Verify active statuses are scanned while backlog is ignored."""

    def _mock_data(self):
        return {
            "issues_by_status": {
                "todo": [],
                "in_progress": [{
                    "id": "issue-inprogress-001",
                    "identifier": "SEE-ACTIVE",
                    "title": "An active issue",
                    "status": "in_progress",
                    "assignee_id": "agent-001",
                    "assignee_type": "agent",
                    "created_at": ISSUE_CREATED_1HR,
                }],
                "blocked": [],
                "backlog": [{
                    "id": "issue-backlog-001",
                    "identifier": "SEE-BACKLOG",
                    "title": "A backlog issue",
                    "status": "backlog",
                    "assignee_id": None,
                    "created_at": ISSUE_CREATED_1HR,
                }],
            },
            "issue_detail": {
                "id": "issue-inprogress-001",
                "identifier": "SEE-ACTIVE",
                "title": "An active issue",
                "status": "in_progress",
                "assignee_id": "agent-001",
                "assignee_type": "agent",
                "created_at": ISSUE_CREATED_1HR,
            },
            "comments": [],
            "runs": [],
        }

    def test_backlog_not_queried_with_active_present(self):
        """Backlog is still not queried when active issues exist."""
        result, queried_statuses = _run_main(self._mock_data())
        assert "backlog" not in queried_statuses
        assert queried_statuses == {"todo", "in_progress", "blocked"}

    def test_active_issue_processed_backlog_ignored(self):
        """Only the in_progress issue is processed; backlog is absent."""
        result, _ = _run_main(self._mock_data())
        all_categorized = (
            result.get("need_push", [])
            + result.get("need_push_decision", [])
            + result.get("running", [])
            + result.get("active", [])
            + result.get("no_assignee", [])
            + result.get("grace_period", [])
        )
        identifiers = {e.get("identifier") for e in all_categorized}
        assert "SEE-ACTIVE" in identifiers, "Active issue should be processed"
        assert "SEE-BACKLOG" not in identifiers, "Backlog issue must not be processed"
