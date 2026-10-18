"""Regression tests for the active-run guard fix (SEE-1006).

The bug: `has_active_run` only checked `status in ("running", "queued")`, so a task
in the `dispatched` state (runtime has claimed it but not yet started) was treated as
inactive and the issue got nudged. Per `.dev/docs/multica/official/tasks.md` the task
lifecycle is `Queued → Dispatched → Running → Completed/Failed/Cancelled`; any
non-terminal run should block the nudge.
"""

import os
import sys
from datetime import datetime, timezone

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "autopilots"))


@pytest.mark.unit
class TestHasActiveRun:
    """Unit tests for the has_active_run predicate."""

    def test_running_is_active(self):
        from issue_status_check import has_active_run

        assert has_active_run([{"status": "running"}]) is True

    def test_queued_is_active(self):
        from issue_status_check import has_active_run

        assert has_active_run([{"status": "queued"}]) is True

    def test_dispatched_is_active(self):
        """BUG FIX (SEE-1006): dispatched was not recognised as active."""
        from issue_status_check import has_active_run

        assert has_active_run([{"status": "dispatched"}]) is True

    def test_completed_then_dispatched_is_active(self):
        """Even when the latest run is terminal, an earlier dispatched run blocks."""
        from datetime import timedelta

        from issue_status_check import has_active_run

        # Fixtures must be recent: SEE-1414 added a STALE_RUN_AGE_HOURS filter
        # that skips non-terminal runs older than the watchdog horizon.
        now = datetime.now(timezone.utc)
        runs = [
            {"status": "completed", "created_at": (now - timedelta(hours=2)).isoformat()},
            {"status": "dispatched", "created_at": (now - timedelta(hours=1)).isoformat()},
        ]
        assert has_active_run(runs) is True

    def test_stale_non_terminal_run_not_active(self):
        """SEE-1414: a non-terminal run older than STALE_RUN_AGE_HOURS no longer blocks."""
        from datetime import timedelta

        from issue_status_check import STALE_RUN_AGE_HOURS, has_active_run

        now = datetime.now(timezone.utc)
        runs = [
            {
                "status": "running",
                "created_at": (now - timedelta(hours=STALE_RUN_AGE_HOURS + 1)).isoformat(),
            }
        ]
        assert has_active_run(runs) is False

    def test_all_terminal_not_active(self):
        from issue_status_check import has_active_run

        runs = [
            {"status": "completed"},
            {"status": "failed"},
            {"status": "cancelled"},
        ]
        assert has_active_run(runs) is False

    def test_empty_runs_not_active(self):
        from issue_status_check import has_active_run

        assert has_active_run([]) is False

    def test_missing_status_field_not_active(self):
        from issue_status_check import has_active_run

        assert has_active_run([{"id": "task-1"}]) is False

    def test_empty_status_string_not_active(self):
        from issue_status_check import has_active_run

        assert has_active_run([{"status": ""}]) is False


@pytest.mark.unit
class TestClassifyIssueWithDispatchedRun:
    """End-to-end guard that a dispatched run routes the issue to 'running'."""

    def _classify(self, issue, runs, latest_run_status="none"):
        from issue_status_check import classify_issue

        processing_log = []
        return classify_issue(
            issue=issue,
            push_count=0,
            latest_commenter=None,
            latest_run_status=latest_run_status,
            reconfirmed_status=issue.get("status", "in_progress"),
            runs=runs,
            processing_log=processing_log,
        )

    def test_dispatched_run_classified_as_running(self):
        """Exact reproduction of the reported bug path."""
        issue = {
            "id": "issue-001",
            "identifier": "SEE-1006",
            "title": "Test issue",
            "status": "in_progress",
            "assignee_id": "agent-A",
            "assignee_type": "agent",
        }
        runs = [
            {
                "status": "dispatched",
                "created_at": datetime.now(timezone.utc).isoformat(),
            }
        ]
        decision, entry = self._classify(issue, runs)
        assert decision == "running"
        assert entry["decision_reason"] == "has_running_run"

    def test_running_run_classified_as_running(self):
        issue = {
            "id": "issue-002",
            "identifier": "SEE-1006",
            "title": "Test issue",
            "status": "in_progress",
            "assignee_id": "agent-A",
            "assignee_type": "agent",
        }
        runs = [
            {
                "status": "running",
                "created_at": datetime.now(timezone.utc).isoformat(),
            }
        ]
        decision, entry = self._classify(issue, runs)
        assert decision == "running"
        assert entry["decision_reason"] == "has_running_run"

    def test_terminal_run_does_not_force_running(self):
        """A completed run with no other activity still falls through to the stale paths."""
        issue = {
            "id": "issue-003",
            "identifier": "SEE-1006",
            "title": "Test issue",
            "status": "in_progress",
            "assignee_id": "agent-A",
            "assignee_type": "agent",
        }
        runs = [
            {
                "status": "completed",
                "created_at": datetime.now(timezone.utc).isoformat(),
            }
        ]
        decision, entry = self._classify(issue, runs, latest_run_status="completed")
        assert decision != "running"
        assert decision in {"need_push", "need_push_decision", "active", "placeholder", "no_assignee"}
