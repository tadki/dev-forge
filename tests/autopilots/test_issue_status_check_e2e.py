"""E2E test suite for issue_status_check.py full pipeline (SEE-226).

Tests the complete classification -> push decision -> JSON output flow
by mocking multica CLI responses and verifying end-to-end behavior.

Uses /revy-testing skill: e2e tests placed in tests/e2e/.
"""

import contextlib
import json
import os
import sys
from datetime import datetime, timezone, timedelta
from io import StringIO
from unittest.mock import patch, MagicMock

import pytest

# Add autopilots directory to path (from tests/e2e/ -> .dev/autopilots/)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "autopilots"))


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

SELF_AGENT_ID = "b2384294-919a-4a91-9f35-2c45848577aa"
ASSIGNEE_ID = "agent-assignee-001"
OTHER_AGENT_ID = "agent-other-002"
ISSUE_ID = "issue-test-001"

# Full team agent/member IDs from multica_helpers.AGENT_MAP
ALL_AGENTS = [
    {"id": "fac3e3a1-dcda-498d-8613-e8c2811f3ef5", "name": "Atlas"},
    {"id": "809951ab-c70c-48c3-b0d6-7b16b49e1ce3", "name": "Archi"},
    {"id": "a5c250e8-7257-466e-b45a-03f995c7206c", "name": "Bachi"},
    {"id": "23354e78-8322-418b-b44d-375287a0650c", "name": "Fronti"},
    {"id": "2660961d-6add-4d15-8d1b-dea446142a94", "name": "Revy"},
    {"id": "3c6b6d88-ce6c-4e02-a78e-24ee08e70c85", "name": "Refacty"},
    {"id": "b2384294-919a-4a91-9f35-2c45848577aa", "name": "Chekky"},
]
ALL_MEMBERS = [
    {"user_id": "6462d805-1d32-4a7f-97db-8c01e78a56ae", "name": "jerry"},
]

NOW = datetime.now(timezone.utc)
COMMENT_36MIN = (NOW - timedelta(minutes=36)).isoformat()
COMMENT_5MIN = (NOW - timedelta(minutes=5)).isoformat()
ISSUE_CREATED_1HR = (NOW - timedelta(hours=1)).isoformat()


def _make_mock_subprocess(mock_data: dict):
    """Create a mock subprocess.run that returns predefined multica CLI responses."""
    def mock_run(cmd, shell=True, capture_output=True, text=True,
                 encoding=None, errors=None, timeout=None):
        cmd_str = " ".join(cmd) if isinstance(cmd, list) else (cmd or "")
        if "multica agent list" in cmd_str:
            return MagicMock(stdout=json.dumps(mock_data.get("agents", ALL_AGENTS)), stderr="")
        elif "multica workspace members" in cmd_str:
            return MagicMock(stdout=json.dumps(mock_data.get("members", ALL_MEMBERS)), stderr="")
        elif "multica issue list" in cmd_str:
            status = _extract_status(cmd_str)
            return MagicMock(stdout=json.dumps(mock_data.get("issues_by_status", {}).get(status, [])), stderr="")
        elif "multica issue comment list" in cmd_str:
            return MagicMock(stdout=json.dumps(mock_data.get("comments", [])), stderr="")
        elif "multica issue runs" in cmd_str:
            return MagicMock(stdout=json.dumps(mock_data.get("runs", [])), stderr="")
        elif "multica issue get" in cmd_str:
            return MagicMock(stdout=json.dumps(mock_data.get("issue_detail", {})), stderr="")
        else:
            return MagicMock(stdout="", stderr="")
    return mock_run


def _extract_status(cmd_str: str) -> str:
    import re
    match = re.search(r"--status (\w+)", cmd_str)
    return match.group(1) if match else ""


def _run_main(mock_data: dict) -> dict:
    """Run issue_status_check.main() with mocked CLI and return parsed JSON output."""
    mock_data.setdefault("agents", ALL_AGENTS)
    mock_data.setdefault("members", ALL_MEMBERS)
    mock_run_fn = _make_mock_subprocess(mock_data)
    buf = StringIO()

    with patch("issue_status_check.subprocess.run", mock_run_fn), \
         patch("issue_status_check.acquire_lock", return_value=True), \
         patch("issue_status_check.cleanup_pid"), \
         contextlib.redirect_stdout(buf):

        import issue_status_check
        issue_status_check.dry_run = True
        issue_status_check.verbose = False
        issue_status_check.self_agent_id = SELF_AGENT_ID
        issue_status_check.GRACE_PERIOD_MINUTES = 10
        issue_status_check.main()

    return json.loads(buf.getvalue())


# ---------------------------------------------------------------------------
# E2E Test 1: Stale assignee self-comment -> need_push full pipeline
# ---------------------------------------------------------------------------

class TestE2EStaleIssuePipeline:

    def _mock_data(self):
        return {
            "issues_by_status": {
                "todo": [], "in_progress": [{
                    "id": ISSUE_ID, "identifier": "TEST-001",
                    "title": "Stale assigned issue", "status": "in_progress",
                    "assignee_id": ASSIGNEE_ID, "assignee_type": "agent",
                    "created_at": ISSUE_CREATED_1HR,
                }], "blocked": [],
            },
            "issue_detail": {
                "id": ISSUE_ID, "identifier": "TEST-001",
                "title": "Stale assigned issue", "status": "in_progress",
                "assignee_id": ASSIGNEE_ID, "assignee_type": "agent",
                "created_at": ISSUE_CREATED_1HR,
            },
            "comments": [
                {"author_id": ASSIGNEE_ID, "author_type": "agent", "created_at": COMMENT_36MIN, "content": "Working"},
            ],
            "runs": [],
        }

    def test_stale_assignee_self_comment_classified_as_need_push(self):
        result = _run_main(self._mock_data())
        entries = result["need_push"]
        assert len(entries) == 1
        assert entries[0]["decision"] == "need_push"
        assert entries[0]["decision_reason"] == "assigned_but_stale"
        assert entries[0]["assignee_id"] == ASSIGNEE_ID

    def test_stale_issue_not_in_active_category(self):
        result = _run_main(self._mock_data())
        assert len(result["active"]) == 0

    def test_stale_issue_generates_push_action(self):
        result = _run_main(self._mock_data())
        actions = result["push_actions"]
        assert len(actions) == 1
        assert actions[0]["action"] == "need_push_first"


# ---------------------------------------------------------------------------
# E2E Test 2: Active other contributor -> active full pipeline
# ---------------------------------------------------------------------------

class TestE2EActiveIssuePipeline:

    def _mock_data(self):
        return {
            "issues_by_status": {
                "todo": [], "in_progress": [{
                    "id": ISSUE_ID, "identifier": "TEST-002",
                    "title": "Active issue", "status": "in_progress",
                    "assignee_id": ASSIGNEE_ID, "assignee_type": "agent",
                    "created_at": ISSUE_CREATED_1HR,
                }], "blocked": [],
            },
            "issue_detail": {
                "id": ISSUE_ID, "identifier": "TEST-002",
                "title": "Active issue", "status": "in_progress",
                "assignee_id": ASSIGNEE_ID, "assignee_type": "agent",
                "created_at": ISSUE_CREATED_1HR,
            },
            "comments": [
                {"author_id": OTHER_AGENT_ID, "author_type": "agent", "created_at": COMMENT_5MIN, "content": "On it"},
            ],
            "runs": [],
        }

    def test_active_other_agent_comment_classified_as_active(self):
        result = _run_main(self._mock_data())
        entries = result["active"]
        assert len(entries) == 1
        assert entries[0]["decision"] == "active"
        assert entries[0]["decision_reason"] == "other_contributor_active"

    def test_active_issue_no_push_action(self):
        result = _run_main(self._mock_data())
        assert len(result["push_actions"]) == 0


# ---------------------------------------------------------------------------
# E2E Test 3: JSON output format completeness
# ---------------------------------------------------------------------------

class TestE2EOutputFormat:

    def _mock_data(self):
        return {
            "issues_by_status": {"todo": [], "in_progress": [], "blocked": []},
            "issue_detail": {}, "comments": [], "runs": [],
        }

    def test_output_has_all_category_keys(self):
        result = _run_main(self._mock_data())
        for cat in ["grace_period", "need_push", "need_push_decision",
                    "running", "active", "no_assignee", "errors"]:
            assert cat in result, f"Missing category '{cat}'"

    def test_summary_has_required_fields(self):
        result = _run_main(self._mock_data())
        summary = result["summary"]
        assert "total_issues" in summary
        assert "status_counts" in summary
        assert "category_counts" in summary
        assert "active" in summary["category_counts"]
        assert summary["dry_run"] is True


# ---------------------------------------------------------------------------
# E2E Test 4: SEE-224 exact reproduction full pipeline
# ---------------------------------------------------------------------------

class TestE2ESEE224Reproduction:

    def _mock_data(self):
        return {
            "issues_by_status": {
                "todo": [], "in_progress": [{
                    "id": "9964bef3-2c81-446d-bb30-e9680508c12d",
                    "identifier": "SEE-224", "title": "Test issue",
                    "status": "in_progress",
                    "assignee_id": ASSIGNEE_ID, "assignee_type": "agent",
                    "created_at": (NOW - timedelta(hours=2)).isoformat(),
                }], "blocked": [],
            },
            "issue_detail": {
                "id": "9964bef3-2c81-446d-bb30-e9680508c12d",
                "identifier": "SEE-224", "title": "Test issue",
                "status": "in_progress",
                "assignee_id": ASSIGNEE_ID, "assignee_type": "agent",
                "created_at": (NOW - timedelta(hours=2)).isoformat(),
            },
            "comments": [
                {"author_id": ASSIGNEE_ID, "author_type": "agent", "created_at": COMMENT_36MIN, "content": "Working on it"},
            ],
            "runs": [],
        }

    def test_see224_issue_not_disappeared(self):
        result = _run_main(self._mock_data())
        total = sum(len(result.get(k, [])) for k in
                    ["need_push", "need_push_decision", "running",
                     "active", "no_assignee", "grace_period"])
        assert total >= 1, "SEE-224 bug: issue disappeared from all categories"
        found = any(e["identifier"] == "SEE-224" and e["decision_reason"] == "assigned_but_stale"
                    for e in result.get("need_push", []))
        assert found, "SEE-224 should be in need_push with reason assigned_but_stale"


# ---------------------------------------------------------------------------
# E2E Test 5: SEE-572 assignee self-activity detection
# ---------------------------------------------------------------------------

class TestE2EAssigneeSelfActivity:
    """Test that assignee recent self-comments classify issue as active (SEE-572)."""

    def _mock_data(self, comment_author_id=None, comment_created_at=None):
        base = {
            "issues_by_status": {
                "todo": [], "in_progress": [{
                    "id": ISSUE_ID, "identifier": "TEST-572",
                    "title": "Assignee activity test", "status": "in_progress",
                    "assignee_id": ASSIGNEE_ID, "assignee_type": "agent",
                    "created_at": ISSUE_CREATED_1HR,
                }], "blocked": [],
            },
            "issue_detail": {
                "id": ISSUE_ID, "identifier": "TEST-572",
                "title": "Assignee activity test", "status": "in_progress",
                "assignee_id": ASSIGNEE_ID, "assignee_type": "agent",
                "created_at": ISSUE_CREATED_1HR,
            },
            "comments": [],
            "runs": [],
        }
        if comment_author_id and comment_created_at:
            base["comments"].append({
                "author_id": comment_author_id,
                "author_type": "agent",
                "created_at": comment_created_at,
                "content": "Assignee comment",
            })
        return base

    def test_assignee_recent_comment_is_active(self):
        """Assignee self-comment 5min ago -> active (not need_push)."""
        result = _run_main(self._mock_data(
            comment_author_id=ASSIGNEE_ID,
            comment_created_at=COMMENT_5MIN,
        ))
        entries = result["active"]
        assert len(entries) == 1
        assert entries[0]["decision"] == "active"
        assert entries[0]["decision_reason"] == "assignee_recently_active"
        assert len(result["need_push"]) == 0
        assert len(result["push_actions"]) == 0

    def test_assignee_stale_comment_is_need_push(self):
        """Assignee self-comment 36min ago -> need_push (past threshold)."""
        result = _run_main(self._mock_data(
            comment_author_id=ASSIGNEE_ID,
            comment_created_at=COMMENT_36MIN,
        ))
        entries = result["need_push"]
        assert len(entries) == 1
        assert entries[0]["decision"] == "need_push"
        assert entries[0]["decision_reason"] == "assigned_but_stale"
        assert len(result["active"]) == 0

    def test_assignee_no_comment_is_need_push(self):
        """Assignee with no comments -> need_push (existing behavior)."""
        result = _run_main(self._mock_data())
        entries = result["need_push"]
        assert len(entries) == 1
        assert entries[0]["decision"] == "need_push"
        assert entries[0]["decision_reason"] == "assigned_but_stale"
        assert len(result["active"]) == 0