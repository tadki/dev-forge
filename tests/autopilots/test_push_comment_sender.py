"""Unit tests for push_comment_sender.py and count_push_reminders fix.

Covers: template rendering, mention resolution, push action determination,
kill switch behavior, dry-run mode, and the CRITICAL count_push_reminders fix.
"""

import os
import sys
import unittest
from unittest.mock import patch, MagicMock

# Add .dev/autopilots to path for module imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots"))

from push_comment_sender import (
    PUSH_MARKER,
    PUSH_CONTENT_MARKERS,
    PUSH_TEMPLATE_NEED_PUSH_FIRST,
    PUSH_TEMPLATE_NEED_PUSH_SECOND,
    PUSH_TEMPLATE_DECISION,
    PUSH_TEMPLATE_NO_ASSIGNEE,
    NO_ASSIGNEE_PING_COOLDOWN_HOURS,
    resolve_mention_target,
    extract_mention_name,
    suggest_next_status,
    build_identifier_link,
    determine_push_action,
    render_push_template,
    send_push_comments,
)
from multica_helpers import AGENT_MAP, ATLAS_ID


class TestResolveMentionTarget(unittest.TestCase):
    """Test @mention resolution priority chain."""

    def test_assignee_priority(self):
        """有 assignee -> @assignee"""
        entry = {
            "assignee_id": "a5c250e8-7257-466e-b45a-03f995c7206c",  # Bachi
            "latest_commenter_id": "809951ab-c70c-48c3-b0d6-7b16b49e1ce3",  # Archi
        }
        link, target_id = resolve_mention_target(entry)
        self.assertEqual(target_id, "a5c250e8-7257-466e-b45a-03f995c7206c")
        self.assertIn("Bachi", link)

    def test_latest_commenter_fallback(self):
        """无 assignee 但有非 self 评论者 -> @latest_commenter"""
        entry = {
            "assignee_id": "",
            "latest_commenter_id": "809951ab-c70c-48c3-b0d6-7b16b49e1ce3",  # Archi
        }
        link, target_id = resolve_mention_target(entry)
        self.assertEqual(target_id, "809951ab-c70c-48c3-b0d6-7b16b49e1ce3")
        self.assertIn("Archi", link)

    def test_atlas_fallback_no_assignee_no_commenter(self):
        """无 assignee 且无评论者 -> @Atlas"""
        entry = {
            "assignee_id": "",
            "latest_commenter_id": "",
        }
        link, target_id = resolve_mention_target(entry)
        self.assertEqual(target_id, ATLAS_ID)
        self.assertIn("Atlas", link)

    def test_unknown_assignee_fallback_to_atlas(self):
        """assignee 不在 AGENT_MAP -> fallback @Atlas"""
        entry = {
            "assignee_id": "unknown-id-123",
            "latest_commenter_id": "",
        }
        link, target_id = resolve_mention_target(entry)
        self.assertEqual(target_id, "unknown-id-123")
        # Link should fallback to Atlas mention since unknown ID not in AGENT_MAP
        self.assertIn("Atlas", link)


class TestExtractMentionName(unittest.TestCase):
    """Test mention name extraction from mention links."""

    def test_standard_mention(self):
        self.assertEqual(extract_mention_name("[@Atlas](mention://agent/xxx)"), "Atlas")

    def test_member_mention(self):
        self.assertEqual(extract_mention_name("[@jerry](mention://member/xxx)"), "jerry")

    def test_invalid_format(self):
        self.assertEqual(extract_mention_name("invalid"), "Atlas")


class TestSuggestNextStatus(unittest.TestCase):
    """Test status suggestion mapping."""

    def test_todo_to_in_progress(self):
        self.assertEqual(suggest_next_status("todo"), "in_progress")

    def test_in_progress_to_in_review(self):
        self.assertEqual(suggest_next_status("in_progress"), "in_review")

    def test_blocked_to_in_progress(self):
        self.assertEqual(suggest_next_status("blocked"), "in_progress")

    def test_in_review_to_done(self):
        self.assertEqual(suggest_next_status("in_review"), "done")

    def test_unknown_defaults_in_review(self):
        self.assertEqual(suggest_next_status("unknown_status"), "in_review")


class TestBuildIdentifierLink(unittest.TestCase):
    """Test issue identifier link building."""

    def test_standard_link(self):
        result = build_identifier_link("SEE-175", "abc-123")
        self.assertEqual(result, "[SEE-175](mention://issue/abc-123)")


class TestDeterminePushAction(unittest.TestCase):
    """Test push action determination based on category and push_count."""

    def test_need_push_first_time(self):
        """push_count=0 -> need_push_first template"""
        entry = {"push_count": 0}
        action, template = determine_push_action("need_push", entry)
        self.assertEqual(action, "need_push_first")
        self.assertEqual(template, PUSH_TEMPLATE_NEED_PUSH_FIRST)

    def test_need_push_second_time(self):
        """push_count=1 -> need_push_second template"""
        entry = {"push_count": 1}
        action, template = determine_push_action("need_push", entry)
        self.assertEqual(action, "need_push_second")
        self.assertEqual(template, PUSH_TEMPLATE_NEED_PUSH_SECOND)

    def test_need_push_decision(self):
        """need_push_decision -> decision template"""
        entry = {"push_count": 2}
        action, template = determine_push_action("need_push_decision", entry)
        self.assertEqual(action, "need_push_decision")
        self.assertEqual(template, PUSH_TEMPLATE_DECISION)

    def test_no_assignee(self):
        """no_assignee -> no_assignee template"""
        entry = {"push_count": 0}
        action, template = determine_push_action("no_assignee", entry)
        self.assertEqual(action, "no_assignee")
        self.assertEqual(template, PUSH_TEMPLATE_NO_ASSIGNEE)


class TestRenderPushTemplate(unittest.TestCase):
    """Test template rendering with context data."""

    def test_need_push_first_rendering(self):
        """首次催促模板渲染"""
        entry = {
            "id": "test-id-123",
            "status": "in_progress",
            "identifier": "SEE-175",
            "push_count": 0,
            "latest_run_status": "completed",
            "decision_reason": "assigned_but_no_push",
        }
        mention_target = "[@Bachi](mention://agent/xxx)"
        result = render_push_template(PUSH_TEMPLATE_NEED_PUSH_FIRST, entry, mention_target)

        self.assertIn(mention_target, result)
        self.assertIn("in_progress", result)
        self.assertIn("test-id-123", result)
        self.assertIn(PUSH_MARKER, result)
        self.assertIn("in_review", result)  # suggested next status

    def test_need_push_second_rendering(self):
        """二次催促模板渲染"""
        entry = {
            "id": "test-id-123",
            "status": "in_progress",
            "identifier": "SEE-175",
            "push_count": 1,
            "latest_run_status": "completed",
            "decision_reason": "push_count=1 < threshold=2",
        }
        mention_target = "[@Bachi](mention://agent/xxx)"
        result = render_push_template(PUSH_TEMPLATE_NEED_PUSH_SECOND, entry, mention_target)

        self.assertIn(mention_target, result)
        self.assertIn("第 2 次催促", result)  # push_count_display = push_count + 1
        self.assertIn(PUSH_MARKER, result)

    def test_decision_rendering(self):
        """强制推进模板渲染"""
        entry = {
            "id": "test-id-123",
            "status": "in_progress",
            "identifier": "SEE-175",
            "push_count": 2,
            "latest_run_status": "completed",
            "decision_reason": "push_count=2 >= threshold=2",
        }
        mention_target = "[@Bachi](mention://agent/xxx)"
        result = render_push_template(PUSH_TEMPLATE_DECISION, entry, mention_target)

        self.assertIn(mention_target, result)
        self.assertIn("已发出 2 次催促", result)
        self.assertIn("completed", result)
        self.assertIn("push_count=2 >= threshold=2", result)
        self.assertIn(PUSH_MARKER, result)

    def test_no_assignee_rendering(self):
        """无 assignee 模板渲染"""
        entry = {
            "id": "test-id-123",
            "status": "todo",
            "identifier": "SEE-175",
        }
        mention_target = "[@Atlas](mention://agent/xxx)"
        result = render_push_template(PUSH_TEMPLATE_NO_ASSIGNEE, entry, mention_target)

        self.assertIn("[@Atlas]", result)
        self.assertIn("[SEE-175](mention://issue/test-id-123)", result)
        self.assertIn("todo", result)
        self.assertIn(PUSH_MARKER, result)


class TestCountPushRemindersFix(unittest.TestCase):
    """CRITICAL FIX: count_push_reminders must only count push marker comments."""

    def _call_count_push_reminders(self, comments, self_id="chekky-id"):
        """Helper to call the fixed count_push_reminders from issue_status_check."""
        # Import here to get the fixed version
        from issue_status_check import count_push_reminders
        return count_push_reminders(comments, self_id)

    def test_only_counts_push_marker_comments(self):
        """只统计含 push marker 的评论"""
        comments = [
            {"author_id": "chekky-id", "content": "Step 5 report\nblah blah"},
            {"author_id": "chekky-id", "content": f"Please check status\n{PUSH_MARKER}"},
            {"author_id": "chekky-id", "content": f"Another push\n{PUSH_MARKER}"},
            {"author_id": "other-id", "content": "Some comment"},
        ]
        count = self._call_count_push_reminders(comments, "chekky-id")
        self.assertEqual(count, 2, "Should only count comments with push markers")

    def test_legacy_keyword_fallback(self):
        """无 push marker 但含催促关键词的旧评论仍被识别"""
        comments = [
            {"author_id": "chekky-id", "content": "请确认本 Issue 当前处理状态"},
        ]
        count = self._call_count_push_reminders(comments, "chekky-id")
        self.assertEqual(count, 1, "Should count legacy keyword comments")

    def test_excludes_non_push_self_comments(self):
        """非 push 的 self 评论不计入"""
        comments = [
            {"author_id": "chekky-id", "content": "## Taskflow report\n\nResults..."},
            {"author_id": "chekky-id", "content": "All checks passed"},
            {"author_id": "other-id", "content": "Some comment"},
        ]
        count = self._call_count_push_reminders(comments, "chekky-id")
        self.assertEqual(count, 0, "Non-push self comments should not be counted")

    def test_empty_comments(self):
        """空评论列表返回 0"""
        count = self._call_count_push_reminders([], "chekky-id")
        self.assertEqual(count, 0)

    def test_no_self_comments(self):
        """无 self 评论返回 0"""
        comments = [
            {"author_id": "other-id", "content": f"push {PUSH_MARKER}"},
        ]
        count = self._call_count_push_reminders(comments, "chekky-id")
        self.assertEqual(count, 0)


class TestSendPushCommentsDryRun(unittest.TestCase):
    """Test dry-run mode behavior."""

    def test_dry_run_does_not_send(self):
        """dry-run 模式下不实际发送，但记录 push_actions"""
        categories = {
            "need_push": [
                {
                    "id": "issue-1",
                    "identifier": "SEE-001",
                    "status": "in_progress",
                    "assignee_id": "a5c250e8-7257-466e-b45a-03f995c7206c",
                    "push_count": 0,
                    "latest_run_status": "completed",
                    "decision_reason": "assigned_but_no_push",
                }
            ],
            "need_push_decision": [],
            "no_assignee": [],
            "running": [],
            "errors": [],
        }
        processing_log = []
        state = {"kill_switch": False}

        result = send_push_comments(categories, processing_log, state, dry_run=True)

        actions = result["push_actions"]
        summary = result["push_actions_summary"]

        self.assertEqual(len(actions), 1)
        self.assertEqual(actions[0]["sent"], False)
        self.assertEqual(actions[0]["dry_run"], True)
        self.assertEqual(actions[0]["action"], "need_push_first")
        self.assertEqual(summary["skipped"], 1)
        self.assertEqual(summary["sent"], 0)
        self.assertEqual(summary["failed"], 0)


class TestSendPushCommentsKillSwitch(unittest.TestCase):
    """Test Kill Switch behavior."""

    @patch("push_comment_sender.multica_stdin_cmd")
    def test_kill_switch_prevents_sending(self, mock_stdin_cmd):
        """kill_switch=true 时不发送任何评论"""
        mock_stdin_cmd.return_value = (True, "ok")

        categories = {
            "need_push": [
                {
                    "id": "issue-1",
                    "identifier": "SEE-001",
                    "status": "in_progress",
                    "assignee_id": "a5c250e8-7257-466e-b45a-03f995c7206c",
                    "push_count": 0,
                    "latest_run_status": "completed",
                    "decision_reason": "assigned_but_no_push",
                }
            ],
            "need_push_decision": [],
            "no_assignee": [],
            "running": [],
            "errors": [],
        }
        processing_log = []
        state = {"kill_switch": True}

        result = send_push_comments(categories, processing_log, state, dry_run=False)

        mock_stdin_cmd.assert_not_called()
        actions = result["push_actions"]
        self.assertEqual(len(actions), 1)
        self.assertEqual(actions[0]["sent"], False)
        self.assertEqual(actions[0]["kill_switch"], True)

    @patch("push_comment_sender.multica_stdin_cmd")
    def test_kill_switch_triggered_by_errors(self, mock_stdin_cmd):
        """发送错误率超阈值触发 Kill Switch"""
        mock_stdin_cmd.return_value = (False, "CLI error")

        categories = {
            "need_push": [
                {
                    "id": f"issue-{i}",
                    "identifier": f"SEE-00{i}",
                    "status": "in_progress",
                    "assignee_id": "a5c250e8-7257-466e-b45a-03f995c7206c",
                    "push_count": 0,
                    "latest_run_status": "completed",
                    "decision_reason": "assigned_but_no_push",
                }
                for i in range(5)
            ],
            "need_push_decision": [],
            "no_assignee": [],
            "running": [],
            "errors": [],
        }
        processing_log = []
        state = {"kill_switch": False}

        # With max_errors_ratio=0.3, after 2 failures out of 5, ratio=0.4 > 0.3
        # But kill switch is checked after each send attempt
        # After 1 failure: 1/1 = 1.0 > 0.3 -> kill switch triggered
        result = send_push_comments(
            categories, processing_log, state,
            dry_run=False, max_errors_ratio=0.3
        )

        # Kill switch should be triggered after first failure
        self.assertTrue(state["kill_switch"])
        summary = result["push_actions_summary"]
        # First one attempted, failed, then kill switch stops rest
        self.assertEqual(summary["failed"], 1)

    @patch("push_comment_sender.is_issue_in_terminal_status", return_value=False)
    @patch("push_comment_sender.multica_stdin_cmd")
    def test_successful_sending(self, mock_stdin_cmd, mock_terminal):
        """正常发送成功场景"""
        mock_stdin_cmd.return_value = (True, "ok")

        categories = {
            "need_push": [
                {
                    "id": "fake-issue-id-for-test-only-00000000",
                    "identifier": "SEE-TEST",
                    "status": "in_progress",
                    "assignee_id": "a5c250e8-7257-466e-b45a-03f995c7206c",
                    "push_count": 0,
                    "latest_run_status": "completed",
                    "decision_reason": "assigned_but_no_push",
                }
            ],
            "need_push_decision": [],
            "no_assignee": [],
            "running": [],
            "errors": [],
        }
        processing_log = []
        state = {"kill_switch": False}

        result = send_push_comments(categories, processing_log, state, dry_run=False)

        mock_stdin_cmd.assert_called_once()
        actions = result["push_actions"]
        self.assertEqual(len(actions), 1)
        self.assertEqual(actions[0]["sent"], True)
        self.assertIsNone(actions[0]["error"])
        self.assertEqual(actions[0]["mention_target"], "Bachi")
        summary = result["push_actions_summary"]
        self.assertEqual(summary["sent"], 1)
        self.assertEqual(summary["failed"], 0)


class TestPushActionsRecordCompleteness(unittest.TestCase):
    """Verify push_actions records contain all required fields."""

    def test_all_fields_present(self):
        categories = {
            "need_push": [
                {
                    "id": "issue-1",
                    "identifier": "SEE-001",
                    "status": "in_progress",
                    "assignee_id": "a5c250e8-7257-466e-b45a-03f995c7206c",
                    "push_count": 0,
                    "latest_run_status": "completed",
                    "decision_reason": "assigned_but_no_push",
                }
            ],
            "need_push_decision": [],
            "no_assignee": [],
        }
        processing_log = []
        state = {"kill_switch": False}

        result = send_push_comments(categories, processing_log, state, dry_run=True)
        action = result["push_actions"][0]

        required_fields = [
            "issue_id", "identifier", "action",
            "mention_target", "mention_target_id",
            "sent", "error",
        ]
        for field in required_fields:
            self.assertIn(field, action, f"Missing required field: {field}")


class TestNoAssigneePingCooldown(unittest.TestCase):
    """SEE-956 H3: no_assignee pings must observe a 24h cooldown window."""

    def _no_assignee_entry(self, latest_push_reminder_at=""):
        return {
            "id": "issue-no-assignee-00000000",
            "identifier": "SEE-NOASSIGNEE",
            "status": "todo",
            "assignee_id": "",
            "push_count": 0,
            "latest_run_status": "completed",
            "decision_reason": "",
            "latest_push_reminder_at": latest_push_reminder_at,
        }

    def test_no_assignee_ping_sent_when_no_previous_reminder(self):
        """First no_assignee ping (no latest_push_reminder_at) is sent."""
        categories = {
            "need_push": [],
            "need_push_decision": [],
            "no_assignee": [self._no_assignee_entry(latest_push_reminder_at="")],
            "running": [],
            "errors": [],
        }
        processing_log = []
        state = {"kill_switch": False}

        with patch("push_comment_sender.multica_stdin_cmd", return_value=(True, "ok")):
            result = send_push_comments(categories, processing_log, state, dry_run=False)

        self.assertEqual(result["push_actions_summary"]["sent"], 1)
        self.assertEqual(result["push_actions"][0]["action"], "no_assignee")
        self.assertTrue(result["push_actions"][0]["sent"])

    def test_no_assignee_ping_suppressed_within_cooldown(self):
        """A reminder sent 1h ago should trigger cooldown, not ping again."""
        from datetime import datetime, timezone, timedelta
        recent = (datetime.now(timezone.utc) - timedelta(hours=1)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        categories = {
            "need_push": [],
            "need_push_decision": [],
            "no_assignee": [self._no_assignee_entry(latest_push_reminder_at=recent)],
            "running": [],
            "errors": [],
        }
        processing_log = []
        state = {"kill_switch": False}

        with patch("push_comment_sender.multica_stdin_cmd", return_value=(True, "ok")) as mock:
            result = send_push_comments(categories, processing_log, state, dry_run=False)

        mock.assert_not_called()
        self.assertEqual(result["push_actions_summary"]["sent"], 0)
        self.assertEqual(result["push_actions_summary"]["skipped"], 1)
        self.assertTrue(
            any("phase5_no_assignee_rate_limited" in log for log in processing_log),
            "expected rate-limit log entry",
        )

    def test_no_assignee_ping_sent_after_cooldown(self):
        """A reminder sent 25h ago is outside the cooldown window; ping again."""
        from datetime import datetime, timezone, timedelta
        old = (datetime.now(timezone.utc) - timedelta(hours=25)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        categories = {
            "need_push": [],
            "need_push_decision": [],
            "no_assignee": [self._no_assignee_entry(latest_push_reminder_at=old)],
            "running": [],
            "errors": [],
        }
        processing_log = []
        state = {"kill_switch": False}

        with patch("push_comment_sender.multica_stdin_cmd", return_value=(True, "ok")):
            result = send_push_comments(categories, processing_log, state, dry_run=False)

        self.assertEqual(result["push_actions_summary"]["sent"], 1)
        self.assertTrue(result["push_actions"][0]["sent"])
        self.assertFalse(
            any("phase5_no_assignee_rate_limited" in log for log in processing_log),
        )

    def test_cooldown_uses_exact_config_hours(self):
        """The boundary is exactly NO_ASSIGNEE_PING_COOLDOWN_HOURS (24)."""
        from datetime import datetime, timezone, timedelta
        boundary = (
            datetime.now(timezone.utc)
            - timedelta(hours=NO_ASSIGNEE_PING_COOLDOWN_HOURS, minutes=-1)
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
        categories = {
            "need_push": [],
            "need_push_decision": [],
            "no_assignee": [self._no_assignee_entry(latest_push_reminder_at=boundary)],
            "running": [],
            "errors": [],
        }
        processing_log = []
        state = {"kill_switch": False}

        with patch("push_comment_sender.multica_stdin_cmd", return_value=(True, "ok")) as mock:
            result = send_push_comments(categories, processing_log, state, dry_run=False)

        mock.assert_not_called()
        self.assertEqual(result["push_actions_summary"]["skipped"], 1)


class TestFileSizeLimits(unittest.TestCase):
    """Verify files stay under 800 line limit."""

    def test_push_comment_sender_under_800(self):
        """push_comment_sender.py 不超过 800 行"""
        scripts_dir = os.path.join(os.path.dirname(__file__), "..", "..", "autopilots")
        filepath = os.path.join(scripts_dir, "push_comment_sender.py")
        with open(filepath, "r", encoding="utf-8") as f:
            lines = f.readlines()
        self.assertLessEqual(len(lines), 800, f"File has {len(lines)} lines, exceeds 800 limit")

    def test_issue_status_check_under_800(self):
        """issue_status_check.py 不超过 800 行"""
        scripts_dir = os.path.join(os.path.dirname(__file__), "..", "..", "autopilots")
        filepath = os.path.join(scripts_dir, "issue_status_check.py")
        with open(filepath, "r", encoding="utf-8") as f:
            lines = f.readlines()
        self.assertLessEqual(len(lines), 800, f"File has {len(lines)} lines, exceeds 800 limit")


if __name__ == "__main__":
    unittest.main(verbosity=2)
