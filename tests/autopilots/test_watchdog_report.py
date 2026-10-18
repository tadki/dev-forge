"""Unit tests for watchdog_report.py — JSON output structure and Markdown format."""

import os
import re
import sys

import pytest

# Add .dev/autopilots to path for module imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots"))

from watchdog_report import (
    generate_json_report,
    generate_comment_markdown,
    _issue_link,
    REPORT_MARKER,
)


def _sample_report(idle_watchdog_kills=None, skipped_tasks=None, processing_log=None, **overrides):
    """Build a minimal valid report dict for testing."""
    defaults = {
        "agents_scanned": [{"id": "a1", "name": "Agent1"}],
        "scanned_tasks": [{"task_id": "t1", "agent_name": "Agent1", "status": "failed"}],
        "idle_watchdog_kills": idle_watchdog_kills or [],
        "rerun_results": [],
        "skipped_tasks": skipped_tasks or [],
        "processing_log": processing_log or [],
        "dry_run": True,
        "kill_switch": False,
        "total_errors": 0,
    }
    defaults.update(overrides)
    return generate_json_report(**defaults)


class TestGenerateJsonReport:
    def test_summary_fields_present(self):
        report = _sample_report()
        s = report["summary"]
        assert "timestamp" in s
        assert "dry_run" in s
        assert "kill_switch" in s
        assert "total_agents_scanned" in s
        assert "total_scanned_tasks" in s
        assert "idle_watchdog_kills" in s
        assert "reruns_executed" in s
        assert "reruns_skipped_limit" in s
        assert "errors" in s

    def test_top_level_keys(self):
        report = _sample_report()
        expected_keys = {
            "summary", "agents_scanned", "scanned_tasks",
            "idle_watchdog_kills", "rerun_results", "skipped_tasks",
            "processing_log",
        }
        assert set(report.keys()) == expected_keys

    def test_kills_count_matches(self):
        kills = [
            {"agent_name": "A", "issue_id": "i1", "task_id": "t1", "detection_method": "idle_watchdog_error"},
            {"agent_name": "B", "issue_id": "i2", "task_id": "t2", "detection_method": "long_cancelled"},
        ]
        report = _sample_report(idle_watchdog_kills=kills)
        assert report["summary"]["idle_watchdog_kills"] == 2

    def test_rerun_count_from_results(self):
        results = [
            {"issue_id": "i1", "success": True, "dry_run": True},
            {"issue_id": "i2", "success": False, "dry_run": True},
        ]
        report = _sample_report(rerun_results=results)
        assert report["summary"]["reruns_executed"] == 1

    def test_verbose_log_included(self):
        report = _sample_report(processing_log=["log1", "log2"])
        assert report["processing_log"] == ["log1", "log2"]

    def test_timestamp_format(self):
        report = _sample_report()
        ts = report["summary"]["timestamp"]
        assert re.match(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", ts)


class TestGenerateCommentMarkdown:
    def test_basic_structure(self):
        report = _sample_report()
        md = generate_comment_markdown(report)
        assert "## Agent Watchdog" in md
        assert "巡检报告" in md
        assert "| 指标 | 值 |" in md
        assert "| Agent | Issue | 检测方式 | Rerun |" in md
        assert "| Issue | 原因 |" in md
        assert REPORT_MARKER in md

    def test_no_kills_tasks_row(self):
        report = _sample_report(idle_watchdog_kills=[])
        md = generate_comment_markdown(report)
        assert "无命中任务" in md

    def test_no_skipped_tasks_row(self):
        report = _sample_report(skipped_tasks=[])
        md = generate_comment_markdown(report)
        assert "| — | 无 |" in md

    def test_kill_task_in_table(self):
        kills = [
            {
                "agent_name": "TestAgent",
                "issue_id": "12345678-1234-1234-1234-123456789012",
                "issue_identifier": "SEE-100",
                "task_id": "t1",
                "detection_method": "idle_watchdog_error",
                "duration_minutes": 30.0,
            }
        ]
        report = _sample_report(idle_watchdog_kills=kills)
        md = generate_comment_markdown(report)
        assert "TestAgent" in md
        assert "SEE-100" in md
        assert "idle_watchdog_error" in md

    def test_verbose_includes_log(self):
        report = _sample_report(processing_log=["test_log_entry"])
        md = generate_comment_markdown(report, verbose=True)
        assert "test_log_entry" in md
        assert "### 处理日志" in md

    def test_non_verbose_excludes_log(self):
        report = _sample_report(processing_log=["test_log_entry"])
        md = generate_comment_markdown(report, verbose=False)
        assert "test_log_entry" not in md

    def test_dry_run_label(self):
        report = _sample_report(dry_run=True)
        md = generate_comment_markdown(report)
        assert "Dry-Run" in md

    def test_execution_mode_label(self):
        report = _sample_report(dry_run=False)
        md = generate_comment_markdown(report)
        assert "执行模式" in md

    def test_kill_switch_status(self):
        report = _sample_report(kill_switch=True)
        md = generate_comment_markdown(report)
        assert "已触发" in md

    def test_table_alignment(self):
        """Verify markdown table pipe alignment."""
        report = _sample_report()
        md = generate_comment_markdown(report)
        lines = md.split("\n")
        for line in lines:
            if line.startswith("|") and "---" not in line:
                assert line.endswith("|"), f"Table row not closed: {line}"

    def test_scanned_tasks_label(self):
        report = _sample_report()
        md = generate_comment_markdown(report)
        assert "扫描 Task 数" in md
        assert "Idle Watchdog 检测数" in md

    def test_no_cancel_results_in_report(self):
        """Verify cancel_results is no longer in report output."""
        report = _sample_report()
        assert "cancel_results" not in report
        assert "cancels_executed" not in report["summary"]


class TestSkippedTasksInMarkdown:
    def test_skipped_task_with_identifier(self):
        skipped = [
            {"issue_id": "i1", "issue_identifier": "SEE-500", "skip_reason": "rate_limit"},
        ]
        report = _sample_report(skipped_tasks=skipped)
        md = generate_comment_markdown(report)
        assert "SEE-500" in md
        assert "rate_limit" in md

    def test_skipped_task_without_identifier(self):
        skipped = [
            {"issue_id": "abc-123", "skip_reason": "issue_done"},
        ]
        report = _sample_report(skipped_tasks=skipped)
        md = generate_comment_markdown(report)
        assert "abc-123" in md
        assert "issue_done" in md


class TestPostReportComment:
    def test_dry_run_returns_early(self):
        from watchdog_report import post_report_comment
        log = []
        result = post_report_comment("issue-1", "md content", dry_run=True, processing_log=log)
        assert result["sent"] is False
        assert result["dry_run"] is True

    def test_empty_issue_id_returns_early(self):
        from watchdog_report import post_report_comment
        log = []
        result = post_report_comment("", "md content", dry_run=False, processing_log=log)
        assert result["sent"] is False

    def test_non_dry_run_success(self, monkeypatch):
        from watchdog_report import post_report_comment
        log = []
        monkeypatch.setattr(
            "watchdog_report.multica_stdin_cmd",
            lambda cmd, content, timeout=15: (True, "ok"),
        )
        result = post_report_comment("issue-1", "md content", dry_run=False, processing_log=log)
        assert result["sent"] is True
        assert result.get("error") is None
        assert any("report_comment_sent" in entry for entry in log)

    def test_non_dry_run_failure(self, monkeypatch):
        from watchdog_report import post_report_comment
        log = []
        monkeypatch.setattr(
            "watchdog_report.multica_stdin_cmd",
            lambda cmd, content, timeout=15: (False, "connection error"),
        )
        result = post_report_comment("issue-1", "md content", dry_run=False, processing_log=log)
        assert result["sent"] is False
        assert result["error"] == "connection error"
        assert any("report_comment_failed" in entry for entry in log)


class TestIssueLink:
    def test_with_identifier(self):
        link = _issue_link("12345678-1234", "SEE-100")
        assert "SEE-100" in link
        assert "mention://issue/12345678-1234" in link

    def test_without_identifier_uses_short_id(self):
        link = _issue_link("12345678-1234-5678", "")
        assert "12345678" in link
        assert "mention://issue/12345678-1234-5678" in link

    def test_empty_issue_id(self):
        link = _issue_link("", "SEE-100")
        assert link == "—"
