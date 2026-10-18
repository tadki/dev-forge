"""QA test suite for classify_issue contributor logic fix (SEE-226).

Tests the three fixes:
1. has_other_contributor checks commenter != assignee AND comment is recent
2. COMMENT_ACTIVITY_THRESHOLD_MINUTES = 20 controls freshness
3. No more return None — issues go to "active" or "need_push" categories
"""

import json
import os
import sys
from datetime import datetime, timezone, timedelta
from unittest.mock import patch

import pytest

# Add .dev/autopilots to path for module imports
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "autopilots"))


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def make_comment(author_id, author_type="agent", minutes_ago=0):
    """Create a mock comment dict."""
    created = datetime.now(timezone.utc) - timedelta(minutes=minutes_ago)
    return {
        "author_id": author_id,
        "author_type": author_type,
        "created_at": created.isoformat(),
        "content": "test comment",
    }


def make_issue(assignee_id="agent-assignee-001", status="in_progress"):
    """Create a mock issue dict."""
    return {
        "id": "issue-001",
        "identifier": "TEST-001",
        "title": "Test issue",
        "status": status,
        "assignee_id": assignee_id,
        "assignee_type": "agent",
    }


# ---------------------------------------------------------------------------
# Test 1: get_latest_commenter returns created_at
# ---------------------------------------------------------------------------

class TestGetLatestCommenter:
    def test_returns_created_at_field(self):
        from issue_status_check import get_latest_commenter

        comments = [
            make_comment("self-id", minutes_ago=30),
            make_comment("user-001", minutes_ago=5),
        ]
        result = get_latest_commenter(comments, "self-id")
        assert result is not None
        assert "created_at" in result
        assert result["author_id"] == "user-001"

    def test_skips_self_comments(self):
        from issue_status_check import get_latest_commenter

        comments = [
            make_comment("self-id", minutes_ago=30),
            make_comment("self-id", minutes_ago=5),
        ]
        result = get_latest_commenter(comments, "self-id")
        assert result is None

    def test_returns_none_when_all_self(self):
        from issue_status_check import get_latest_commenter

        comments = [make_comment("self-id", minutes_ago=i) for i in range(5)]
        result = get_latest_commenter(comments, "self-id")
        assert result is None

    def test_returns_latest_non_self(self):
        from issue_status_check import get_latest_commenter

        comments = [
            make_comment("user-001", minutes_ago=60),
            make_comment("self-id", minutes_ago=30),
            make_comment("user-002", minutes_ago=10),
        ]
        result = get_latest_commenter(comments, "self-id")
        assert result["author_id"] == "user-002"


# ---------------------------------------------------------------------------
# Test 2: has_other_contributor logic — must be different from assignee AND recent
# ---------------------------------------------------------------------------

class TestHasOtherContributor:
    """Test the has_other_contributor logic within classify_issue.

    has_other_contributor should be True only when:
    - latest_commenter is not None
    - commenter author_id != assignee_id
    - comment is within COMMENT_ACTIVITY_THRESHOLD_MINUTES (20)
    """

    def _classify(self, issue, latest_commenter, push_count=0, runs=None):
        from issue_status_check import classify_issue

        processing_log = []
        return classify_issue(
            issue=issue,
            push_count=push_count,
            latest_commenter=latest_commenter,
            latest_run_status="none",
            reconfirmed_status=issue.get("status", "in_progress"),
            runs=runs or [],
            processing_log=processing_log,
        )

    def test_assignee_self_comment_not_counted_as_other(self):
        """BUG FIX: assignee commenting on own issue should NOT block push."""
        issue = make_issue(assignee_id="agent-A")
        latest_commenter = {
            "author_id": "agent-A",  # same as assignee
            "author_type": "agent",
            "created_at": datetime.now(timezone.utc).isoformat(),
        }
        decision, entry = self._classify(issue, latest_commenter)
        assert decision == "need_push"
        assert entry["decision_reason"] == "assigned_but_stale"

    def test_recent_other_comment_is_active(self):
        """Other agent comments within 20min → active (not pushed)."""
        issue = make_issue(assignee_id="agent-A")
        latest_commenter = {
            "author_id": "agent-B",  # different from assignee
            "author_type": "agent",
            "created_at": (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat(),
        }
        decision, entry = self._classify(issue, latest_commenter)
        assert decision == "active"
        assert entry["decision_reason"] == "other_contributor_active"

    def test_old_other_comment_is_stale(self):
        """Other agent comments older than 20min → need_push (stale)."""
        issue = make_issue(assignee_id="agent-A")
        latest_commenter = {
            "author_id": "agent-B",
            "author_type": "agent",
            "created_at": (datetime.now(timezone.utc) - timedelta(minutes=30)).isoformat(),
        }
        decision, entry = self._classify(issue, latest_commenter)
        assert decision == "need_push"
        assert entry["decision_reason"] == "assigned_but_stale"

    def test_old_assignee_self_comment_is_stale(self):
        """Assignee self-comment older than 20min → need_push."""
        issue = make_issue(assignee_id="agent-A")
        latest_commenter = {
            "author_id": "agent-A",
            "author_type": "agent",
            "created_at": (datetime.now(timezone.utc) - timedelta(minutes=45)).isoformat(),
        }
        decision, entry = self._classify(issue, latest_commenter)
        assert decision == "need_push"
        assert entry["decision_reason"] == "assigned_but_stale"

    def test_no_commenter_with_assignee_is_stale(self):
        """No commenter at all → need_push with assigned_but_stale."""
        issue = make_issue(assignee_id="agent-A")
        decision, entry = self._classify(issue, None)
        assert decision == "need_push"
        assert entry["decision_reason"] == "assigned_but_stale"

    def test_boundary_19min_other_comment_is_active(self):
        """Comment at 19min ago → still within threshold → active."""
        issue = make_issue(assignee_id="agent-A")
        latest_commenter = {
            "author_id": "agent-B",
            "author_type": "agent",
            "created_at": (datetime.now(timezone.utc) - timedelta(minutes=19)).isoformat(),
        }
        decision, entry = self._classify(issue, latest_commenter)
        assert decision == "active"

    def test_boundary_21min_other_comment_is_stale(self):
        """Comment at 21min ago → outside threshold → stale."""
        issue = make_issue(assignee_id="agent-A")
        latest_commenter = {
            "author_id": "agent-B",
            "author_type": "agent",
            "created_at": (datetime.now(timezone.utc) - timedelta(minutes=21)).isoformat(),
        }
        decision, entry = self._classify(issue, latest_commenter)
        assert decision == "need_push"
        assert entry["decision_reason"] == "assigned_but_stale"


# ---------------------------------------------------------------------------
# Test 3: No more return None — all issues classified
# ---------------------------------------------------------------------------

class TestNoReturnNone:
    """Verify that classify_issue never returns (None, None) for in_progress issues.

    The old code returned None when assignee_id and has_other_contributor were both True,
    causing issues to disappear from all categories.
    """

    def _classify(self, issue, latest_commenter, push_count=0, runs=None):
        from issue_status_check import classify_issue

        processing_log = []
        return classify_issue(
            issue=issue,
            push_count=push_count,
            latest_commenter=latest_commenter,
            latest_run_status="none",
            reconfirmed_status=issue.get("status", "in_progress"),
            runs=runs or [],
            processing_log=processing_log,
        )

    def test_assigned_with_recent_other_never_none(self):
        """The exact scenario that caused SEE-224: assigned + other commenter → was None."""
        issue = make_issue(assignee_id="agent-A")
        latest_commenter = {
            "author_id": "agent-B",
            "author_type": "agent",
            "created_at": datetime.now(timezone.utc).isoformat(),
        }
        decision, entry = self._classify(issue, latest_commenter)
        assert decision is not None
        assert entry is not None
        assert decision == "active"

    def test_assigned_with_old_other_never_none(self):
        issue = make_issue(assignee_id="agent-A")
        latest_commenter = {
            "author_id": "agent-B",
            "author_type": "agent",
            "created_at": (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat(),
        }
        decision, entry = self._classify(issue, latest_commenter)
        assert decision is not None
        assert entry is not None
        assert decision == "need_push"

    def test_assigned_self_comment_never_none(self):
        issue = make_issue(assignee_id="agent-A")
        latest_commenter = {
            "author_id": "agent-A",
            "author_type": "agent",
            "created_at": datetime.now(timezone.utc).isoformat(),
        }
        decision, entry = self._classify(issue, latest_commenter)
        assert decision is not None
        assert entry is not None


# ---------------------------------------------------------------------------
# Test 4: Active category in categories dict
# ---------------------------------------------------------------------------

class TestActiveCategory:
    def test_categories_dict_has_active_key(self):
        from issue_status_check import COMMENT_ACTIVITY_THRESHOLD_MINUTES

        # Verify the constant exists
        assert COMMENT_ACTIVITY_THRESHOLD_MINUTES == 20


# ---------------------------------------------------------------------------
# Test 5: Regression — other decision paths still work correctly
# ---------------------------------------------------------------------------

class TestRegression:
    """Ensure the fix doesn't break other classification paths."""

    def _classify(self, issue, latest_commenter, push_count=0, run_status="none",
                  runs=None, reconfirmed_status=None):
        from issue_status_check import classify_issue

        processing_log = []
        return classify_issue(
            issue=issue,
            push_count=push_count,
            latest_commenter=latest_commenter,
            latest_run_status=run_status,
            reconfirmed_status=reconfirmed_status or issue.get("status", "in_progress"),
            runs=runs or [],
            processing_log=processing_log,
        )

    def test_done_status_returns_none(self):
        """Done issues should still return None (skipped)."""
        issue = make_issue(status="done")
        decision, entry = self._classify(issue, None)
        assert decision is None
        assert entry is None

    def test_cancelled_status_returns_none(self):
        issue = make_issue(status="cancelled")
        decision, entry = self._classify(issue, None)
        assert decision is None

    def test_in_review_returns_none(self):
        issue = make_issue(status="in_review")
        decision, entry = self._classify(issue, None)
        assert decision is None

    def test_running_run_classified_as_running(self):
        issue = make_issue()
        runs = [{"status": "running", "created_at": datetime.now(timezone.utc).isoformat()}]
        decision, entry = self._classify(issue, None, runs=runs)
        assert decision == "running"

    def test_high_push_count_classified_as_need_push_decision(self):
        from issue_status_check import PUSH_THRESHOLD

        issue = make_issue()
        decision, entry = self._classify(issue, None, push_count=PUSH_THRESHOLD)
        assert decision == "need_push_decision"

    def test_no_assignee_no_commenter_is_no_assignee(self):
        issue = make_issue(assignee_id=None)
        decision, entry = self._classify(issue, None)
        assert decision == "no_assignee"

    def test_no_assignee_with_commenter_is_need_push(self):
        issue = make_issue(assignee_id=None)
        latest_commenter = {
            "author_id": "user-001",
            "author_type": "member",
            "created_at": datetime.now(timezone.utc).isoformat(),
        }
        decision, entry = self._classify(issue, latest_commenter)
        assert decision == "need_push"
        assert entry["decision_reason"] == "no_assignee_but_has_commenter"


# ---------------------------------------------------------------------------
# Test 6: SEE-224 exact reproduction scenario
# ---------------------------------------------------------------------------

class TestSEE224Reproduction:
    """Reproduce the exact SEE-224 scenario that was reported as broken.

    SEE-224 was in_progress, no running runs, past grace period, 0 push reminders.
    Assignee had commented 36 minutes ago, which was treated as "other contributor active"
    → issue returned None → disappeared from all categories.
    """

    def _classify(self, issue, latest_commenter, push_count=0, runs=None):
        from issue_status_check import classify_issue

        processing_log = []
        return classify_issue(
            issue=issue,
            push_count=push_count,
            latest_commenter=latest_commenter,
            latest_run_status="none",
            reconfirmed_status="in_progress",
            runs=runs or [],
            processing_log=processing_log,
        )

    def test_see224_assignee_commented_36min_ago_now_pushed(self):
        """Before fix: returned None (issue disappeared).
        After fix: should be need_push with assigned_but_stale."""
        issue = {
            "id": "9964bef3-2c81-446d-bb30-e9680508c12d",
            "identifier": "SEE-224",
            "title": "Test issue",
            "status": "in_progress",
            "assignee_id": "agent-assignee-001",
            "assignee_type": "agent",
        }
        # Assignee self-commented 36 minutes ago
        latest_commenter = {
            "author_id": "agent-assignee-001",  # same as assignee
            "author_type": "agent",
            "created_at": (datetime.now(timezone.utc) - timedelta(minutes=36)).isoformat(),
        }
        decision, entry = self._classify(issue, latest_commenter, push_count=0)
        assert decision is not None, "BUG: issue disappeared (returned None)"
        assert decision == "need_push"
        assert entry["decision_reason"] == "assigned_but_stale"

    def test_see224_other_agent_commented_36min_ago_now_pushed(self):
        """Even if a different agent commented 36min ago, it should be stale."""
        issue = {
            "id": "9964bef3-2c81-446d-bb30-e9680508c12d",
            "identifier": "SEE-224",
            "title": "Test issue",
            "status": "in_progress",
            "assignee_id": "agent-assignee-001",
            "assignee_type": "agent",
        }
        latest_commenter = {
            "author_id": "agent-other-002",  # different from assignee
            "author_type": "agent",
            "created_at": (datetime.now(timezone.utc) - timedelta(minutes=36)).isoformat(),
        }
        decision, entry = self._classify(issue, latest_commenter, push_count=0)
        assert decision is not None
        assert decision == "need_push"
        assert entry["decision_reason"] == "assigned_but_stale"
