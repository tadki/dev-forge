"""§SPEC-009 (SEE-1516 substep C2, fingerprint 69823a273535): 催促 24h 冷却。

push_comment_sender need_push/need_push_decision 原每轮 cron 重复 @ (仅
no_assignee 有 rate-limit)。本套件钉扎: 24h 窗内同 entry 同型催促跳过、
冷却到期后恢复发送；dry_run/非该型不受影响 (零回归)。
"""

import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

import push_comment_sender as pcs


def _entry(**kw):
    base = dict(
        id="issue-1", identifier="SEE-001", status="in_progress",
        assignee_id="a5c250e8-7257-466e-b45a-03f995c7206c",
        push_count=1, latest_run_status="completed",
        decision_reason="assigned_but_no_push",
        latest_push_reminder_at="",
    )
    base.update(kw)
    return base


def _cat(need_push=(), decision=(), no_assignee=()):
    return {"need_push": list(need_push), "need_push_decision": list(decision),
            "no_assignee": list(no_assignee), "running": [], "errors": []}


class TestPushCooldown(unittest.TestCase):
    def _run(self, categories, log=None):
        log = [] if log is None else log
        with patch("push_comment_sender.is_issue_in_terminal_status", return_value=False), \
             patch("push_comment_sender.multica_stdin_cmd", return_value=(True, "ok")) as m:
            result = pcs.send_push_comments(
                categories, log, {"kill_switch": False}, dry_run=False)
        return result, m, log

    @patch("push_comment_sender._is_within_hours", lambda ts, h: True)  # 24h 窗内 → 冷却命中
    def test_within_window_skips(self):
        result, mock_send, log = self._run(_cat([_entry(latest_push_reminder_at="recent")]))
        actions = result["push_actions"]
        assert len(actions) == 1
        assert actions[0]["sent"] is False
        assert result["push_actions_summary"]["skipped"] == 1
        mock_send.assert_not_called()
        # hardener 补强: 冷却跳过必须留 processing_log (日志删除变异在此杀伤)
        assert any("phase5_push_cooldown" in line for line in log), log

    @patch("push_comment_sender._is_within_hours", lambda ts, h: False)  # 窗已过 → 恢复发送
    def test_past_window_sends(self):
        result, mock_send, _log = self._run(_cat([_entry(latest_push_reminder_at="old")]))
        assert result["push_actions"][0]["sent"] is True
        assert mock_send.call_count == 1

    @patch("push_comment_sender._is_within_hours", lambda ts, h: True)
    def test_decision_within_window_skips(self):
        result, mock_send, _log = self._run(
            _cat(decision=[_entry(latest_push_reminder_at="recent")]))
        assert result["push_actions"][0]["sent"] is False
        mock_send.assert_not_called()

    @patch("push_comment_sender._is_within_hours", lambda ts, h: True)
    def test_second_push_within_window_skips(self):
        """push_count>=1 的 SECOND 催促同受 24h 冷却。"""
        result, _, _log = self._run(
            _cat([_entry(push_count=3, latest_push_reminder_at="recent")]))
        assert result["push_actions"][0]["sent"] is False

    def test_no_reminder_at_sends(self):
        """无 latest_push_reminder_at (从未催促) → 正常发送, 不进冷却。"""
        result, mock_send, _log = self._run(_cat([_entry(latest_push_reminder_at="")]))
        assert result["push_actions"][0]["sent"] is True
        assert mock_send.call_count == 1

    def test_terminal_status_race_guard_blocks_send(self):
        """Phase1→Phase5 间隙转 terminal → 不发送 (race guard 删除变异在此存活)。"""
        log = []
        with patch("push_comment_sender.is_issue_in_terminal_status", return_value=True), \
             patch("push_comment_sender.multica_stdin_cmd") as m:
            result = pcs.send_push_comments(
                _cat([_entry(latest_push_reminder_at="")]), log,
                {"kill_switch": False}, dry_run=False)
        assert result["push_actions"][0]["sent"] is False, result["push_actions"]
        m.assert_not_called()


def test_is_within_hours_boundary_exact(monkeypatch):
    """dt == cutoff 边界 → 不在窗内（`>` 不得放宽为 `>=`）。时钟钉扎确定性判定。

    _is_within_hours 函数内 `from datetime import datetime` 每次调用重新解析,
    钉扎须替换 stdlib datetime 模块的 datetime 属性（FrozenDatetime 子类）。
    """
    import datetime as datetime_module
    from datetime import datetime as real_dt, timedelta, timezone

    fixed_cutoff = real_dt(2026, 1, 1, 0, 0, 0, tzinfo=timezone.utc)

    class FrozenDatetime(real_dt):
        @classmethod
        def now(cls, tz=None):
            return fixed_cutoff + timedelta(hours=24)

        @classmethod
        def fromisoformat(cls, s):
            return fixed_cutoff

    monkeypatch.setattr(datetime_module, "datetime", FrozenDatetime)
    assert pcs._is_within_hours("2026-01-01T00:00:00+00:00", 24) is False


def test_push_cooldown_defined_24h():
    assert pcs.PUSH_COOLDOWN_HOURS == 24
    assert pcs.NO_ASSIGNEE_PING_COOLDOWN_HOURS == 24


def test_is_within_hours_honors_window():
    now = datetime.now(timezone.utc).isoformat()
    assert pcs._is_within_hours(now, 24) is True
    past = (datetime.now(timezone.utc) - timedelta(hours=25)).isoformat()
    assert pcs._is_within_hours(past, 24) is False
    assert pcs._is_within_hours("", 24) is False
