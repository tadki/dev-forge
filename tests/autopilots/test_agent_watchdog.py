"""Unit tests for agent_watchdog.py — idle_watchdog detection logic, helpers, phases."""

import argparse
import json
import os
import sys
import tempfile
from datetime import datetime, timezone, timedelta

import pytest

# Add autopilots/ (repo-relative) to path for module imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots"))

from agent_watchdog import (
    parse_args,
    get_failed_runs,
    detect_idle_watchdog_kills,
    enrich_issue_identifiers,
    _is_idle_watchdog_kill,
    _is_long_cancelled,
    _calculate_duration_minutes,
    _fetch_issue_info,
    _fetch_issue_runs,
    apply_restart_limits,
    execute_reruns,
    fetch_agents,
    main,
    _parse_ts,
    IDLE_WATCHDOG_ERROR_PATTERN,
    MIN_CANCELLED_DURATION_MIN,
)
from watchdog_state import WatchdogState


# --- Fixtures ---


@pytest.fixture
def processing_log():
    return []


def _make_task(
    task_id="t1",
    status="failed",
    error="agent produced no new messages for 30m0s and message queue was empty; force-stopped by idle watchdog",
    issue_id="issue-1",
    started_at=None,
    ended_at=None,
    agent_id="agent-1",
    agent_name="TestAgent",
    **overrides,
):
    """Create a minimal task dict."""
    if started_at is None:
        started_at = (datetime.now(timezone.utc) - timedelta(hours=1)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
    if ended_at is None and status in ("failed", "cancelled"):
        ended_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    task = {
        "task_id": task_id,
        "agent_id": agent_id,
        "agent_name": agent_name,
        "issue_id": issue_id,
        "status": status,
        "error": error,
        "started_at": started_at,
        "ended_at": ended_at or "",
    }
    task.update(overrides)
    return task


# ============================================================
# 1. _is_idle_watchdog_kill
# ============================================================


class TestIsIdleWatchdogKill:
    def test_failed_with_idle_watchdog_error(self):
        task = _make_task(status="failed", error="force-stopped by idle watchdog")
        assert _is_idle_watchdog_kill(task) is True

    def test_failed_with_other_error(self):
        task = _make_task(status="failed", error="daemon restarted unexpectedly")
        assert _is_idle_watchdog_kill(task) is False

    def test_cancelled_task(self):
        task = _make_task(status="cancelled", error=None)
        assert _is_idle_watchdog_kill(task) is False

    def test_completed_task(self):
        task = _make_task(status="completed", error=None)
        assert _is_idle_watchdog_kill(task) is False

    def test_none_error(self):
        task = _make_task(status="failed", error=None)
        assert _is_idle_watchdog_kill(task) is False

    def test_case_insensitive(self):
        task = _make_task(status="failed", error="Force-Stopped By IDLE WATCHDOG")
        assert _is_idle_watchdog_kill(task) is True


# ============================================================
# 2. _is_long_cancelled
# ============================================================


class TestIsLongCancelled:
    def test_cancelled_long_duration(self):
        started = (datetime.now(timezone.utc) - timedelta(minutes=30)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        ended = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        task = _make_task(status="cancelled", error=None, started_at=started, ended_at=ended)
        assert _is_long_cancelled(task) is True

    def test_cancelled_short_duration(self):
        started = (datetime.now(timezone.utc) - timedelta(minutes=10)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        ended = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        task = _make_task(status="cancelled", error=None, started_at=started, ended_at=ended)
        assert _is_long_cancelled(task) is False

    def test_cancelled_with_error(self):
        task = _make_task(status="cancelled", error="some error")
        assert _is_long_cancelled(task) is False

    def test_failed_task_not_long_cancelled(self):
        task = _make_task(status="failed", error=None)
        assert _is_long_cancelled(task) is False


# ============================================================
# 3. _calculate_duration_minutes
# ============================================================


class TestCalculateDurationMinutes:
    def test_normal_duration(self):
        started = (datetime.now(timezone.utc) - timedelta(minutes=45)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        ended = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        task = {"started_at": started, "ended_at": ended}
        duration = _calculate_duration_minutes(task)
        assert 44.0 <= duration <= 46.0

    def test_no_ended_at_uses_now(self):
        started = (datetime.now(timezone.utc) - timedelta(minutes=30)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        task = {"started_at": started, "ended_at": None}
        duration = _calculate_duration_minutes(task)
        assert 29.0 <= duration <= 31.0

    def test_no_started_at_returns_zero(self):
        task = {"started_at": "", "ended_at": "2026-05-14T12:00:00Z"}
        assert _calculate_duration_minutes(task) == 0.0

    def test_completed_at_fallback(self):
        started = (datetime.now(timezone.utc) - timedelta(minutes=60)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        ended = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        task = {"started_at": started, "completed_at": ended}
        duration = _calculate_duration_minutes(task)
        assert 59.0 <= duration <= 61.0


# ============================================================
# 4. get_failed_runs (mocked CLI)
# ============================================================


class TestGetFailedRuns:
    def test_filters_failed_and_cancelled(self, processing_log, monkeypatch):
        import agent_watchdog
        tasks_data = [
            {"id": "t1", "status": "failed", "issue_id": "i1", "error": "idle watchdog", "started_at": "2026-05-14T10:00:00Z", "ended_at": "2026-05-14T10:30:00Z"},
            {"id": "t2", "status": "completed", "issue_id": "i2", "started_at": "2026-05-14T10:00:00Z"},
            {"id": "t3", "status": "cancelled", "issue_id": "i3", "error": None, "started_at": "2026-05-14T10:00:00Z", "ended_at": "2026-05-14T10:45:00Z"},
            {"id": "t4", "status": "running", "issue_id": "i4", "started_at": "2026-05-14T10:00:00Z"},
        ]
        monkeypatch.setattr(
            agent_watchdog,
            "multica_cli",
            lambda *a, **kw: (True, json.dumps(tasks_data)),
        )
        agents = [{"id": "agent-1", "name": "TestAgent"}]
        result = get_failed_runs(agents, processing_log)
        assert len(result) == 2
        task_ids = [t["task_id"] for t in result]
        assert "t1" in task_ids
        assert "t3" in task_ids

    def test_cli_failure_continues(self, processing_log, monkeypatch):
        import agent_watchdog
        monkeypatch.setattr(
            agent_watchdog,
            "multica_cli",
            lambda *a, **kw: (False, "error"),
        )
        agents = [{"id": "agent-1", "name": "TestAgent"}]
        result = get_failed_runs(agents, processing_log)
        assert result == []

    def test_empty_agents_list(self, processing_log):
        result = get_failed_runs([], processing_log)
        assert result == []

    def test_captures_error_and_ended_fields(self, processing_log, monkeypatch):
        import agent_watchdog
        tasks_data = [
            {"id": "t1", "status": "failed", "issue_id": "i1", "error": "idle watchdog", "started_at": "2026-05-14T10:00:00Z", "ended_at": "2026-05-14T10:30:00Z"},
        ]
        monkeypatch.setattr(
            agent_watchdog,
            "multica_cli",
            lambda *a, **kw: (True, json.dumps(tasks_data)),
        )
        result = get_failed_runs([{"id": "agent-1", "name": "TestAgent"}], processing_log)
        assert len(result) == 1
        assert result[0]["error"] == "idle watchdog"
        assert result[0]["status"] == "failed"


# ============================================================
# 5. detect_idle_watchdog_kills (mocked CLI)
# ============================================================


class TestDetectIdleWatchdogKills:
    def test_primary_signal_hit(self, processing_log, monkeypatch):
        """failed + idle watchdog error → detected."""
        import agent_watchdog
        task = _make_task(
            task_id="t1", status="failed",
            error="agent produced no new messages for 30m0s; force-stopped by idle watchdog",
        )
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_info",
                            lambda *a, **kw: {"status": "in_progress"})
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_runs",
                            lambda *a, **kw: [{"id": "t1"}])

        kills = detect_idle_watchdog_kills([task], processing_log)
        assert len(kills) == 1
        assert kills[0]["detection_method"] == "idle_watchdog_error"

    def test_auxiliary_signal_hit(self, processing_log, monkeypatch):
        """cancelled + duration >= 25min → detected."""
        import agent_watchdog
        started = (datetime.now(timezone.utc) - timedelta(minutes=30)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        ended = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        task = _make_task(
            task_id="t2", status="cancelled", error=None,
            started_at=started, ended_at=ended,
        )
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_info",
                            lambda *a, **kw: {"status": "in_progress"})
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_runs",
                            lambda *a, **kw: [{"id": "t2"}])

        kills = detect_idle_watchdog_kills([task], processing_log)
        assert len(kills) == 1
        assert kills[0]["detection_method"] == "long_cancelled"

    def test_not_latest_run_filtered(self, processing_log, monkeypatch):
        """Task is not the latest run for its issue → filtered out."""
        import agent_watchdog
        task = _make_task(task_id="t-old", status="failed",
                          error="force-stopped by idle watchdog")
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_info",
                            lambda *a, **kw: {"status": "in_progress"})
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_runs",
                            lambda *a, **kw: [{"id": "t-new"}, {"id": "t-old"}])

        kills = detect_idle_watchdog_kills([task], processing_log)
        assert len(kills) == 0

    def test_issue_done_filtered(self, processing_log, monkeypatch):
        """Issue status=done → task filtered out."""
        import agent_watchdog
        task = _make_task(task_id="t1", status="failed",
                          error="force-stopped by idle watchdog")
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_info",
                            lambda *a, **kw: {"status": "done"})
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_runs",
                            lambda *a, **kw: [{"id": "t1"}])

        kills = detect_idle_watchdog_kills([task], processing_log)
        assert len(kills) == 0

    def test_mixed_scenario(self, processing_log, monkeypatch):
        """Multiple tasks: some hit, some filtered."""
        import agent_watchdog
        tasks = [
            _make_task(task_id="t1", status="failed",
                       error="force-stopped by idle watchdog"),
            _make_task(task_id="t2", status="cancelled", error=None),
            _make_task(task_id="t3", status="failed", error="other error"),
        ]
        # t3 should not match any pattern

        def fake_issue_info(issue_id, *a, **kw):
            return {"status": "in_progress"}

        def fake_issue_runs(issue_id, *a, **kw):
            return [{"id": "t1"}, {"id": "t2"}]

        monkeypatch.setattr(agent_watchdog, "_fetch_issue_info", fake_issue_info)
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_runs", fake_issue_runs)

        kills = detect_idle_watchdog_kills(tasks, processing_log)
        assert len(kills) == 1
        assert kills[0]["task_id"] == "t1"

    def test_empty_input_returns_empty(self, processing_log):
        kills = detect_idle_watchdog_kills([], processing_log)
        assert kills == []

    def test_no_issue_id_skipped(self, processing_log, monkeypatch):
        """Task with empty issue_id → skipped."""
        import agent_watchdog
        task = _make_task(task_id="t1", issue_id="", status="failed",
                          error="force-stopped by idle watchdog")
        kills = detect_idle_watchdog_kills([task], processing_log)
        assert len(kills) == 0

    def test_issue_cache_reused(self, processing_log, monkeypatch):
        """Same issue_id for multiple tasks → single CLI call per issue."""
        import agent_watchdog
        call_count = {"info": 0, "runs": 0}

        def counting_issue_info(issue_id, *a, **kw):
            call_count["info"] += 1
            return {"status": "in_progress"}

        def counting_issue_runs(issue_id, *a, **kw):
            call_count["runs"] += 1
            return [{"id": "t1"}, {"id": "t2"}]

        monkeypatch.setattr(agent_watchdog, "_fetch_issue_info", counting_issue_info)
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_runs", counting_issue_runs)

        tasks = [
            _make_task(task_id="t1", issue_id="same-issue", status="failed",
                       error="force-stopped by idle watchdog"),
            _make_task(task_id="t2", issue_id="same-issue", status="failed",
                       error="force-stopped by idle watchdog"),
        ]
        kills = detect_idle_watchdog_kills(tasks, processing_log)
        assert call_count["info"] == 1
        assert call_count["runs"] == 1


# ============================================================
# 6. _fetch_issue_info / _fetch_issue_runs (mocked CLI)
# ============================================================


class TestFetchIssueHelpers:
    def test_fetch_issue_info_success(self, processing_log, monkeypatch):
        import agent_watchdog
        issue_data = {"id": "i1", "status": "in_progress", "identifier": "SEE-100"}
        monkeypatch.setattr(
            agent_watchdog, "multica_cli",
            lambda *a, **kw: (True, json.dumps(issue_data)),
        )
        result = _fetch_issue_info("i1", processing_log)
        assert result["status"] == "in_progress"
        assert result["identifier"] == "SEE-100"

    def test_fetch_issue_info_failure(self, processing_log, monkeypatch):
        import agent_watchdog
        monkeypatch.setattr(
            agent_watchdog, "multica_cli",
            lambda *a, **kw: (False, "error"),
        )
        result = _fetch_issue_info("i1", processing_log)
        assert result == {}

    def test_fetch_issue_runs_success(self, processing_log, monkeypatch):
        import agent_watchdog
        runs_data = [
            {"id": "run-2", "status": "failed"},
            {"id": "run-1", "status": "completed"},
        ]
        monkeypatch.setattr(
            agent_watchdog, "multica_cli",
            lambda *a, **kw: (True, json.dumps(runs_data)),
        )
        result = _fetch_issue_runs("i1", processing_log)
        assert len(result) == 2
        assert result[0]["id"] == "run-2"

    def test_fetch_issue_runs_failure(self, processing_log, monkeypatch):
        import agent_watchdog
        monkeypatch.setattr(
            agent_watchdog, "multica_cli",
            lambda *a, **kw: (False, "error"),
        )
        result = _fetch_issue_runs("i1", processing_log)
        assert result == []


# ============================================================
# 7. Rate limiting — apply_restart_limits
# ============================================================


class TestApplyRestartLimits:
    def test_allows_under_limit(self, tmp_path, processing_log):
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        tasks = [_make_task()]
        approved, skipped = apply_restart_limits(tasks, state, 3, processing_log)
        assert len(approved) == 1
        assert len(skipped) == 0

    def test_blocks_at_limit(self, tmp_path, processing_log):
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        for i in range(3):
            state.record_restart("issue-1", f"task-{i}")
        tasks = [_make_task()]
        approved, skipped = apply_restart_limits(tasks, state, 3, processing_log)
        assert len(approved) == 0
        assert len(skipped) == 1
        assert "rate_limit" in skipped[0].get("skip_reason", "")

    def test_different_issues_independent(self, tmp_path, processing_log):
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        for i in range(3):
            state.record_restart("issue-other", f"task-{i}")
        task = _make_task()
        task["issue_id"] = "issue-new"
        approved, skipped = apply_restart_limits([task], state, 3, processing_log)
        assert len(approved) == 1


# ============================================================
# 8. Execute reruns — dry-run and real
# ============================================================


class TestExecuteReruns:
    def test_dry_run_does_not_execute(self, tmp_path, processing_log):
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        tasks = [_make_task()]
        results = execute_reruns(tasks, state, dry_run=True, processing_log=processing_log)
        assert len(results) == 1
        assert results[0]["success"] is True
        assert results[0]["dry_run"] is True
        assert state.get_restart_count("issue-1") == 0

    def test_real_run_records_state(self, tmp_path, processing_log, monkeypatch):
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        tasks = [_make_task()]

        import agent_watchdog
        monkeypatch.setattr(agent_watchdog, "multica_cli", lambda *a, **kw: (True, "ok"))

        results = execute_reruns(tasks, state, dry_run=False, processing_log=processing_log)
        assert len(results) == 1
        assert results[0]["success"] is True
        assert results[0]["dry_run"] is False
        assert state.get_restart_count("issue-1") == 1

    def test_real_run_failure_handled(self, tmp_path, processing_log, monkeypatch):
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        tasks = [_make_task()]

        import agent_watchdog
        monkeypatch.setattr(
            agent_watchdog, "multica_cli", lambda *a, **kw: (False, "rerun failed")
        )

        results = execute_reruns(tasks, state, dry_run=False, processing_log=processing_log)
        assert len(results) == 1
        assert results[0]["success"] is False
        assert results[0]["error"] == "rerun failed"
        assert state.get_restart_count("issue-1") == 0


# ============================================================
# 9. Agent filtering — fetch_agents (mocked CLI)
# ============================================================


class TestFetchAgents:
    def test_excludes_specified_agents(self, processing_log, monkeypatch):
        import agent_watchdog
        agents_data = [
            {"id": "fac3e3a1-dcda-498d-8613-e8c2811f3ef5", "name": "Atlas", "status": "active"},
            {"id": "b2384294-919a-4a91-9f35-2c45848577aa", "name": "Chekky", "status": "active"},
            {"id": "809951ab-c70c-48c3-b0d6-7b16b49e1ce3", "name": "Archi", "status": "active"},
            {"id": "some-other-id", "name": "Other", "status": "active"},
        ]
        monkeypatch.setattr(
            agent_watchdog,
            "multica_cli",
            lambda *a, **kw: (True, json.dumps(agents_data)),
        )
        result = fetch_agents(
            exclude_names=["Atlas", "Chekky"],
            self_agent_id="b2384294-919a-4a91-9f35-2c45848577aa",
            processing_log=processing_log,
        )
        names = [a["name"] for a in result]
        assert "Atlas" not in names
        assert "Chekky" not in names
        assert "Archi" in names
        assert "Other" in names

    def test_cli_failure_returns_empty(self, processing_log, monkeypatch):
        import agent_watchdog
        monkeypatch.setattr(
            agent_watchdog, "multica_cli", lambda *a, **kw: (False, "connection error")
        )
        result = fetch_agents(["Atlas"], "self-id", processing_log)
        assert result == []
        assert any("phase1_agent_list_failed" in log for log in processing_log)

    def test_invalid_json_returns_empty(self, processing_log, monkeypatch):
        import agent_watchdog
        monkeypatch.setattr(
            agent_watchdog, "multica_cli", lambda *a, **kw: (True, "not json")
        )
        result = fetch_agents(["Atlas"], "self-id", processing_log)
        assert result == []
        assert any("phase1_agent_list_json_error" in log for log in processing_log)


# ============================================================
# 10. _parse_ts helper
# ============================================================


class TestParseTs:
    def test_valid_rfc3339(self):
        result = _parse_ts("2026-05-14T12:00:00Z")
        assert result.year == 2026
        assert result.month == 5

    def test_valid_with_offset(self):
        result = _parse_ts("2026-05-14T12:00:00+08:00")
        assert result.year == 2026

    def test_empty_string(self):
        result = _parse_ts("")
        assert result == datetime.min.replace(tzinfo=timezone.utc)

    def test_none_returns_min_datetime(self):
        result = _parse_ts(None)
        assert result == datetime.min.replace(tzinfo=timezone.utc)

    def test_invalid_string(self):
        result = _parse_ts("not-a-date")
        assert result == datetime.min.replace(tzinfo=timezone.utc)


# ============================================================
# 11. parse_args
# ============================================================


class TestParseArgs:
    def test_defaults(self, monkeypatch):
        monkeypatch.setattr(sys, "argv", ["agent_watchdog.py"])
        args = parse_args()
        assert args.dry_run is True
        assert args.max_restarts_per_hour == 3
        assert args.exclude_agents == "Atlas"
        assert args.execution_issue_id == ""
        assert args.alert_issue_id == ""
        assert args.kill_switch == "false"
        assert args.verbose is False

    def test_no_dry_run(self, monkeypatch):
        monkeypatch.setattr(sys, "argv", ["agent_watchdog.py", "--no-dry-run"])
        args = parse_args()
        assert args.dry_run is False

    def test_custom_max_restarts(self, monkeypatch):
        monkeypatch.setattr(sys, "argv", ["agent_watchdog.py", "--max-restarts-per-hour", "5"])
        args = parse_args()
        assert args.max_restarts_per_hour == 5

    def test_custom_exclude_agents(self, monkeypatch):
        monkeypatch.setattr(sys, "argv", [
            "agent_watchdog.py", "--exclude-agents", "Atlas,Bachi"
        ])
        args = parse_args()
        assert args.exclude_agents == "Atlas,Bachi"

    def test_execution_issue_id(self, monkeypatch):
        monkeypatch.setattr(sys, "argv", [
            "agent_watchdog.py", "--execution-issue-id", "abc-123"
        ])
        args = parse_args()
        assert args.execution_issue_id == "abc-123"

    def test_alert_issue_id(self, monkeypatch):
        monkeypatch.setattr(sys, "argv", [
            "agent_watchdog.py", "--alert-issue-id", "alert-456"
        ])
        args = parse_args()
        assert args.alert_issue_id == "alert-456"

    def test_kill_switch_true(self, monkeypatch):
        monkeypatch.setattr(sys, "argv", [
            "agent_watchdog.py", "--kill-switch", "true"
        ])
        args = parse_args()
        assert args.kill_switch == "true"

    def test_verbose(self, monkeypatch):
        monkeypatch.setattr(sys, "argv", ["agent_watchdog.py", "--verbose"])
        args = parse_args()
        assert args.verbose is True

    def test_pid_file_default(self, monkeypatch):
        monkeypatch.setattr(sys, "argv", ["agent_watchdog.py"])
        args = parse_args()
        assert "agent_watchdog.pid" in args.pid_file

    def test_state_file_default(self, monkeypatch):
        monkeypatch.setattr(sys, "argv", ["agent_watchdog.py"])
        args = parse_args()
        # SEE-956 C6: state file migrated from /tmp to ~/.multica/watchdog_state.json.
        assert "watchdog_state.json" in args.state_file


# ============================================================
# 12. enrich_issue_identifiers
# ============================================================


class TestEnrichIssueIdentifiers:
    def test_skips_no_issue_id(self, processing_log, monkeypatch):
        import agent_watchdog
        cli_called = {"n": 0}
        def counting_cli(*a, **kw):
            cli_called["n"] += 1
            return (True, "{}")
        monkeypatch.setattr(agent_watchdog, "multica_cli", counting_cli)

        tasks = [{"task_id": "t1", "issue_id": ""}]
        enrich_issue_identifiers(tasks, processing_log)
        assert cli_called["n"] == 0

    def test_skips_already_enriched(self, processing_log, monkeypatch):
        import agent_watchdog
        cli_called = {"n": 0}
        def counting_cli(*a, **kw):
            cli_called["n"] += 1
            return (True, "{}")
        monkeypatch.setattr(agent_watchdog, "multica_cli", counting_cli)

        tasks = [{"task_id": "t1", "issue_id": "i1",
                  "issue_identifier": "SEE-100", "issue_status": "in_progress"}]
        enrich_issue_identifiers(tasks, processing_log)
        assert cli_called["n"] == 0

    def test_enriches_successfully(self, processing_log, monkeypatch):
        import agent_watchdog
        issue_data = {"identifier": "SEE-200", "title": "Test Title", "status": "todo"}
        monkeypatch.setattr(
            agent_watchdog, "multica_cli",
            lambda *a, **kw: (True, json.dumps(issue_data)),
        )

        tasks = [{"task_id": "t1", "issue_id": "i1"}]
        enrich_issue_identifiers(tasks, processing_log)
        assert tasks[0]["issue_identifier"] == "SEE-200"
        assert tasks[0]["issue_title"] == "Test Title"
        assert tasks[0]["issue_status"] == "todo"

    def test_cli_failure_ignored(self, processing_log, monkeypatch):
        import agent_watchdog
        monkeypatch.setattr(
            agent_watchdog, "multica_cli",
            lambda *a, **kw: (False, "error"),
        )

        tasks = [{"task_id": "t1", "issue_id": "i1"}]
        enrich_issue_identifiers(tasks, processing_log)
        assert "issue_identifier" not in tasks[0]

    def test_json_decode_error_ignored(self, processing_log, monkeypatch):
        import agent_watchdog
        monkeypatch.setattr(
            agent_watchdog, "multica_cli",
            lambda *a, **kw: (True, "not-json"),
        )

        tasks = [{"task_id": "t1", "issue_id": "i1"}]
        enrich_issue_identifiers(tasks, processing_log)
        assert "issue_identifier" not in tasks[0]

    def test_enriches_multiple_tasks(self, processing_log, monkeypatch):
        import agent_watchdog
        def fake_cli(*a, **kw):
            issue_id = a[0].split()[-3]
            data = {"identifier": issue_id[:3].upper(), "title": f"Title {issue_id}", "status": "in_progress"}
            return (True, json.dumps(data))
        monkeypatch.setattr(agent_watchdog, "multica_cli", fake_cli)

        tasks = [
            {"task_id": "t1", "issue_id": "aaa"},
            {"task_id": "t2", "issue_id": "bbb"},
        ]
        enrich_issue_identifiers(tasks, processing_log)
        assert tasks[0]["issue_identifier"] == "AAA"
        assert tasks[1]["issue_identifier"] == "BBB"


# ============================================================
# 13. get_failed_runs JSON error branch
# ============================================================


class TestGetFailedRunsErrors:
    def test_json_decode_error(self, processing_log, monkeypatch):
        import agent_watchdog
        monkeypatch.setattr(
            agent_watchdog, "multica_cli",
            lambda *a, **kw: (True, "not valid json"),
        )
        agents = [{"id": "agent-1", "name": "TestAgent"}]
        result = get_failed_runs(agents, processing_log)
        assert result == []
        assert any("phase2_tasks_json_error" in log for log in processing_log)


# ============================================================
# 14. _fetch_issue_info / _fetch_issue_runs JSON error branches
# ============================================================


class TestFetchHelpersJsonErrors:
    def test_fetch_issue_info_json_error(self, processing_log, monkeypatch):
        import agent_watchdog
        monkeypatch.setattr(
            agent_watchdog, "multica_cli",
            lambda *a, **kw: (True, "invalid json"),
        )
        result = _fetch_issue_info("i1", processing_log)
        assert result == {}
        assert any("fetch_issue_info_json_error" in log for log in processing_log)

    def test_fetch_issue_runs_json_error(self, processing_log, monkeypatch):
        import agent_watchdog
        monkeypatch.setattr(
            agent_watchdog, "multica_cli",
            lambda *a, **kw: (True, "invalid json"),
        )
        result = _fetch_issue_runs("i1", processing_log)
        assert result == []
        assert any("fetch_issue_runs_json_error" in log for log in processing_log)


# ============================================================
# 15. main entry function
# ============================================================


class TestMain:
    def test_main_no_kills(self, tmp_path, monkeypatch):
        """main() with no agents and no kills produces valid report."""
        import agent_watchdog
        monkeypatch.setattr(
            agent_watchdog, "fetch_agents",
            lambda *a, **kw: [],
        )
        monkeypatch.setattr(
            agent_watchdog, "get_failed_runs",
            lambda *a, **kw: [],
        )
        monkeypatch.setattr(
            agent_watchdog, "detect_idle_watchdog_kills",
            lambda *a, **kw: [],
        )
        monkeypatch.setattr(
            agent_watchdog, "enrich_issue_identifiers",
            lambda *a, **kw: None,
        )
        monkeypatch.setattr(
            agent_watchdog, "apply_restart_limits",
            lambda *a, **kw: ([], []),
        )
        monkeypatch.setattr(
            agent_watchdog, "execute_reruns",
            lambda *a, **kw: [],
        )
        monkeypatch.setattr(
            agent_watchdog, "generate_json_report",
            lambda **kw: {"summary": {"test": True}},
        )

        args = argparse.Namespace(
            dry_run=True,
            exclude_agents="Atlas",
            self_agent_id="self-id",
            max_restarts_per_hour=3,
            state_file=str(tmp_path / "state.json"),
            kill_switch="false",
            execution_issue_id="",
            alert_issue_id="",
            verbose=False,
        )
        main(args)

    def test_main_dry_run_with_kills(self, tmp_path, monkeypatch, capsys):
        """main() in dry_run mode with kills found."""
        import agent_watchdog
        monkeypatch.setattr(
            agent_watchdog, "fetch_agents",
            lambda *a, **kw: [{"id": "a1", "name": "Agent1"}],
        )
        monkeypatch.setattr(
            agent_watchdog, "get_failed_runs",
            lambda *a, **kw: [{"task_id": "t1", "issue_id": "i1"}],
        )
        monkeypatch.setattr(
            agent_watchdog, "detect_idle_watchdog_kills",
            lambda *a, **kw: [{"task_id": "t1", "issue_id": "i1", "agent_name": "Agent1"}],
        )
        monkeypatch.setattr(
            agent_watchdog, "enrich_issue_identifiers",
            lambda *a, **kw: None,
        )
        monkeypatch.setattr(
            agent_watchdog, "apply_restart_limits",
            lambda *a, **kw: ([{"task_id": "t1", "issue_id": "i1"}], []),
        )
        monkeypatch.setattr(
            agent_watchdog, "execute_reruns",
            lambda *a, **kw: [{"issue_id": "i1", "task_id": "t1", "success": True, "dry_run": True}],
        )

        def fake_generate(**kw):
            return {"summary": {"dry_run": kw.get("dry_run"), "kill_switch": kw.get("kill_switch")}}

        monkeypatch.setattr(agent_watchdog, "generate_json_report", fake_generate)

        args = argparse.Namespace(
            dry_run=True,
            exclude_agents="Atlas",
            self_agent_id="self-id",
            max_restarts_per_hour=3,
            state_file=str(tmp_path / "state.json"),
            kill_switch="false",
            execution_issue_id="",
            alert_issue_id="",
            verbose=False,
        )
        main(args)
        captured = capsys.readouterr()
        assert "dry_run" in captured.out

    def test_main_verbose_includes_log(self, tmp_path, monkeypatch, capsys):
        """main() with verbose=True includes processing_log in report."""
        import agent_watchdog
        log_captured = []
        monkeypatch.setattr(
            agent_watchdog, "fetch_agents",
            lambda *a, **kw: [],
        )
        monkeypatch.setattr(
            agent_watchdog, "get_failed_runs",
            lambda *a, **kw: [],
        )
        monkeypatch.setattr(
            agent_watchdog, "detect_idle_watchdog_kills",
            lambda *a, **kw: [],
        )
        monkeypatch.setattr(
            agent_watchdog, "apply_restart_limits",
            lambda *a, **kw: ([], []),
        )
        monkeypatch.setattr(
            agent_watchdog, "execute_reruns",
            lambda *a, **kw: [],
        )

        def fake_generate(**kw):
            log_captured.append(kw.get("processing_log"))
            return {"summary": {"verbose": True}}

        monkeypatch.setattr(agent_watchdog, "generate_json_report", fake_generate)

        args = argparse.Namespace(
            dry_run=True,
            exclude_agents="Atlas",
            self_agent_id="self-id",
            max_restarts_per_hour=3,
            state_file=str(tmp_path / "state.json"),
            kill_switch="false",
            execution_issue_id="",
            alert_issue_id="",
            verbose=True,
        )
        main(args)
        # When verbose=True, processing_log should be passed
        assert log_captured[0] is not None

    def test_main_kill_switch_prevents_reruns(self, tmp_path, monkeypatch, capsys):
        """main() with kill_switch=true skips reruns."""
        import agent_watchdog
        monkeypatch.setattr(
            agent_watchdog, "fetch_agents",
            lambda *a, **kw: [{"id": "a1", "name": "Agent1"}],
        )
        monkeypatch.setattr(
            agent_watchdog, "get_failed_runs",
            lambda *a, **kw: [{"task_id": "t1"}],
        )
        monkeypatch.setattr(
            agent_watchdog, "detect_idle_watchdog_kills",
            lambda *a, **kw: [{"task_id": "t1", "issue_id": "i1", "agent_name": "Agent1"}],
        )
        monkeypatch.setattr(
            agent_watchdog, "apply_restart_limits",
            lambda *a, **kw: ([{"task_id": "t1", "issue_id": "i1"}], []),
        )

        args = argparse.Namespace(
            dry_run=True,
            exclude_agents="Atlas",
            self_agent_id="self-id",
            max_restarts_per_hour=3,
            state_file=str(tmp_path / "state.json"),
            kill_switch="true",
            execution_issue_id="",
            alert_issue_id="",
            verbose=False,
        )
        main(args)
        captured = capsys.readouterr()
        assert "kill_switch" in captured.out

    def test_main_kill_switch_auto_trigger(self, tmp_path, monkeypatch, capsys):
        """main() triggers kill_switch when error ratio exceeds threshold."""
        import agent_watchdog
        monkeypatch.setattr(
            agent_watchdog, "fetch_agents",
            lambda *a, **kw: [{"id": "a1", "name": "Agent1"}],
        )
        monkeypatch.setattr(
            agent_watchdog, "get_failed_runs",
            lambda *a, **kw: [{"task_id": "t1"}],
        )
        monkeypatch.setattr(
            agent_watchdog, "detect_idle_watchdog_kills",
            lambda *a, **kw: [{"task_id": "t1", "issue_id": "i1", "agent_name": "Agent1"}],
        )
        monkeypatch.setattr(
            agent_watchdog, "apply_restart_limits",
            lambda *a, **kw: ([{"task_id": "t1", "issue_id": "i1"}], []),
        )
        # Simulate rerun failure (not dry_run, not kill_switch error)
        monkeypatch.setattr(
            agent_watchdog, "execute_reruns",
            lambda *a, **kw: [{"issue_id": "i1", "success": False, "dry_run": False, "error": "fail"}],
        )

        args = argparse.Namespace(
            dry_run=False,
            exclude_agents="Atlas",
            self_agent_id="self-id",
            max_restarts_per_hour=3,
            state_file=str(tmp_path / "state.json"),
            kill_switch="false",
            execution_issue_id="",
            alert_issue_id="",
            verbose=False,
        )
        main(args)
        captured = capsys.readouterr()
        assert "kill_switch_triggered" in captured.out or "kill_switch" in captured.out

    def test_main_posts_report_comment(self, tmp_path, monkeypatch):
        """main() posts report comment when execution_issue_id is set."""
        import agent_watchdog
        monkeypatch.setattr(
            agent_watchdog, "fetch_agents",
            lambda *a, **kw: [],
        )
        monkeypatch.setattr(
            agent_watchdog, "get_failed_runs",
            lambda *a, **kw: [],
        )
        monkeypatch.setattr(
            agent_watchdog, "detect_idle_watchdog_kills",
            lambda *a, **kw: [],
        )
        monkeypatch.setattr(
            agent_watchdog, "apply_restart_limits",
            lambda *a, **kw: ([], []),
        )
        monkeypatch.setattr(
            agent_watchdog, "execute_reruns",
            lambda *a, **kw: [],
        )

        calls = []
        def fake_post(issue_id, md, dry_run, log):
            calls.append((issue_id, dry_run))
        monkeypatch.setattr(agent_watchdog, "post_report_comment", fake_post)

        args = argparse.Namespace(
            dry_run=True,
            exclude_agents="Atlas",
            self_agent_id="self-id",
            max_restarts_per_hour=3,
            state_file=str(tmp_path / "state.json"),
            kill_switch="false",
            execution_issue_id="exec-issue-123",
            alert_issue_id="",
            verbose=False,
        )
        main(args)
        assert len(calls) == 1
        assert calls[0] == ("exec-issue-123", True)

    def test_main_kill_switch_alert(self, tmp_path, monkeypatch):
        """main() sends kill switch alert when conditions are met."""
        import agent_watchdog
        monkeypatch.setattr(
            agent_watchdog, "fetch_agents",
            lambda *a, **kw: [{"id": "a1", "name": "Agent1"}],
        )
        monkeypatch.setattr(
            agent_watchdog, "get_failed_runs",
            lambda *a, **kw: [{"task_id": "t1"}],
        )
        monkeypatch.setattr(
            agent_watchdog, "detect_idle_watchdog_kills",
            lambda *a, **kw: [{"task_id": "t1", "issue_id": "i1", "agent_name": "Agent1"}],
        )
        monkeypatch.setattr(
            agent_watchdog, "apply_restart_limits",
            lambda *a, **kw: ([{"task_id": "t1", "issue_id": "i1"}], []),
        )
        # Force kill switch trigger via error ratio
        monkeypatch.setattr(
            agent_watchdog, "execute_reruns",
            lambda *a, **kw: [{"issue_id": "i1", "success": False, "dry_run": False, "error": "fail"}],
        )

        alert_calls = []
        def fake_multica_stdin(cmd, content):
            alert_calls.append((cmd, content))
        monkeypatch.setattr(agent_watchdog, "multica_stdin_cmd", fake_multica_stdin)

        args = argparse.Namespace(
            dry_run=False,
            exclude_agents="Atlas",
            self_agent_id="self-id",
            max_restarts_per_hour=3,
            state_file=str(tmp_path / "state.json"),
            kill_switch="false",
            execution_issue_id="",
            alert_issue_id="alert-456",
            verbose=False,
        )
        main(args)
        assert len(alert_calls) == 1
        assert "alert-456" in alert_calls[0][0]
        assert "Kill Switch" in alert_calls[0][1]

    def test_main_dry_run_no_alert_sent(self, tmp_path, monkeypatch):
        """main() does NOT send alert in dry_run mode even if kill switch triggered."""
        import agent_watchdog
        monkeypatch.setattr(
            agent_watchdog, "fetch_agents",
            lambda *a, **kw: [{"id": "a1", "name": "Agent1"}],
        )
        monkeypatch.setattr(
            agent_watchdog, "get_failed_runs",
            lambda *a, **kw: [{"task_id": "t1"}],
        )
        monkeypatch.setattr(
            agent_watchdog, "detect_idle_watchdog_kills",
            lambda *a, **kw: [{"task_id": "t1", "issue_id": "i1", "agent_name": "Agent1"}],
        )
        monkeypatch.setattr(
            agent_watchdog, "apply_restart_limits",
            lambda *a, **kw: ([{"task_id": "t1", "issue_id": "i1"}], []),
        )
        monkeypatch.setattr(
            agent_watchdog, "execute_reruns",
            lambda *a, **kw: [{"issue_id": "i1", "success": False, "dry_run": False, "error": "fail"}],
        )

        alert_calls = []
        def fake_multica_stdin(cmd, content):
            alert_calls.append((cmd, content))
        monkeypatch.setattr(agent_watchdog, "multica_stdin_cmd", fake_multica_stdin)

        args = argparse.Namespace(
            dry_run=True,
            exclude_agents="Atlas",
            self_agent_id="self-id",
            max_restarts_per_hour=3,
            state_file=str(tmp_path / "state.json"),
            kill_switch="false",
            execution_issue_id="",
            alert_issue_id="alert-456",
            verbose=False,
        )
        main(args)
        assert len(alert_calls) == 0

    def test_main_no_reruns_no_kill_switch_check(self, tmp_path, monkeypatch, capsys):
        """main() skips kill switch check when there are no rerun results."""
        import agent_watchdog
        monkeypatch.setattr(
            agent_watchdog, "fetch_agents",
            lambda *a, **kw: [],
        )
        monkeypatch.setattr(
            agent_watchdog, "get_failed_runs",
            lambda *a, **kw: [],
        )
        monkeypatch.setattr(
            agent_watchdog, "detect_idle_watchdog_kills",
            lambda *a, **kw: [],
        )
        monkeypatch.setattr(
            agent_watchdog, "apply_restart_limits",
            lambda *a, **kw: ([], []),
        )
        monkeypatch.setattr(
            agent_watchdog, "execute_reruns",
            lambda *a, **kw: [],
        )

        args = argparse.Namespace(
            dry_run=True,
            exclude_agents="Atlas",
            self_agent_id="self-id",
            max_restarts_per_hour=3,
            state_file=str(tmp_path / "state.json"),
            kill_switch="false",
            execution_issue_id="",
            alert_issue_id="",
            verbose=False,
        )
        main(args)
        captured = capsys.readouterr()
        # kill_switch should remain False, not triggered
        assert "kill_switch_triggered" not in captured.out
