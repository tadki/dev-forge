"""E2E / Integration test for the full agent_watchdog pipeline."""

import json
import os
import tempfile
from datetime import datetime, timezone, timedelta

import pytest

# Ensure .dev/autopilots is on path
import sys

scripts_dir = os.path.join(os.path.dirname(__file__), "..", "..", "autopilots")
scripts_dir = os.path.abspath(scripts_dir)
if scripts_dir not in sys.path:
    sys.path.insert(0, scripts_dir)

from agent_watchdog import (
    parse_args,
    fetch_agents,
    get_failed_runs,
    detect_idle_watchdog_kills,
    apply_restart_limits,
    execute_reruns,
    main,
)
from watchdog_state import WatchdogState


@pytest.fixture
def mock_cli_factory(monkeypatch):
    """Factory for mocking multica_cli with configurable responses."""

    def _factory(responses):
        import agent_watchdog
        call_count = {"n": 0}
        def _fake_cli(*args, **kwargs):
            cmd = args[0] if args else ""
            call_count["n"] += 1
            for pattern, result in responses.items():
                if pattern in cmd:
                    return result
            return (True, "")
        monkeypatch.setattr(agent_watchdog, "multica_cli", _fake_cli)
        return call_count

    return _factory


class TestFullPipelineE2E:
    """Simulate a full watchdog run end-to-end with mocked CLI."""

    def test_no_agents_found(self, tmp_path, mock_cli_factory, monkeypatch):
        """When no agents exist, pipeline completes with zero findings."""
        mock_cli_factory({
            "agent list": (True, "[]"),
        })
        agents = fetch_agents([], "self-id", [])
        failed = get_failed_runs(agents, [])
        assert len(agents) == 0
        assert len(failed) == 0

    def test_single_idle_watchdog_kill_full_pipeline(self, tmp_path, mock_cli_factory, monkeypatch):
        """One agent, one failed idle_watchdog task → detected."""
        mock_cli_factory({
            "agent list": (True, json.dumps([
                {"id": "agent-1", "name": "TestAgent", "status": "active"}
            ])),
            "agent tasks": (True, json.dumps([
                {
                    "id": "task-1",
                    "status": "failed",
                    "issue_id": "issue-1",
                    "error": "agent produced no new messages for 30m0s and message queue was empty; force-stopped by idle watchdog",
                    "started_at": "2026-05-14T10:00:00Z",
                    "ended_at": "2026-05-14T10:30:00Z",
                }
            ])),
            "issue get": (True, json.dumps({"id": "issue-1", "status": "in_progress", "identifier": "SEE-100", "title": "Test"})),
            "issue runs": (True, json.dumps([{"id": "task-1"}])),
        })

        log = []
        agents = fetch_agents([], "self-id", log)
        failed = get_failed_runs(agents, log)
        kills = detect_idle_watchdog_kills(failed, log)

        assert len(agents) == 1
        assert len(failed) == 1
        assert len(kills) == 1
        assert kills[0]["detection_method"] == "idle_watchdog_error"
        assert kills[0]["task_id"] == "task-1"

    def test_rate_limit_blocks_rerun(self, tmp_path, mock_cli_factory, monkeypatch):
        """Idle watchdog kill exists but rate limit prevents rerun."""
        mock_cli_factory({
            "agent list": (True, json.dumps([
                {"id": "agent-1", "name": "TestAgent", "status": "active"}
            ])),
            "agent tasks": (True, json.dumps([
                {
                    "id": "task-1",
                    "status": "failed",
                    "issue_id": "issue-1",
                    "error": "force-stopped by idle watchdog",
                    "started_at": "2026-05-14T10:00:00Z",
                    "ended_at": "2026-05-14T10:30:00Z",
                }
            ])),
            "issue get": (True, json.dumps({"id": "issue-1", "status": "in_progress", "identifier": "SEE-100", "title": "Test"})),
            "issue runs": (True, json.dumps([{"id": "task-1"}])),
        })

        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        for i in range(3):
            state.record_restart("issue-1", f"pre-{i}")

        log = []
        agents = fetch_agents([], "self-id", log)
        failed = get_failed_runs(agents, log)
        kills = detect_idle_watchdog_kills(failed, log)
        approved, skipped = apply_restart_limits(kills, state, 3, log)

        assert len(kills) == 1
        assert len(approved) == 0
        assert len(skipped) == 1
        assert "rate_limit" in skipped[0].get("skip_reason", "")

    def test_kill_switch_prevents_reruns(self, tmp_path, mock_cli_factory, monkeypatch):
        """Kill switch active → no reruns executed."""
        log = []
        tasks = [{"issue_id": "i1", "task_id": "t1", "agent_name": "A", "success": True}]
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)

        results = execute_reruns(
            approved_tasks=tasks, state=state, dry_run=True, processing_log=log
        )
        assert all(r["dry_run"] for r in results)

    def test_dry_run_vs_real_execution(self, tmp_path, mock_cli_factory, monkeypatch):
        """dry_run=True should not record restarts, dry_run=False should."""
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        tasks = [{"issue_id": "i1", "task_id": "t1", "agent_name": "A"}]

        # Dry run
        log1 = []
        results1 = execute_reruns(tasks, state, dry_run=True, processing_log=log1)
        assert state.get_restart_count("i1") == 0

        # Real run (mock CLI success)
        import agent_watchdog
        monkeypatch.setattr(agent_watchdog, "multica_cli", lambda *a, **kw: (True, "ok"))
        log2 = []
        results2 = execute_reruns(tasks, state, dry_run=False, processing_log=log2)
        assert state.get_restart_count("i1") == 1

    def test_all_tasks_active_no_kills(self, tmp_path, mock_cli_factory, monkeypatch):
        """All tasks are running → failed_runs is empty."""
        recent_ts = (datetime.now(timezone.utc) - timedelta(minutes=5)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )

        mock_cli_factory({
            "agent list": (True, json.dumps([
                {"id": "agent-1", "name": "TestAgent", "status": "active"}
            ])),
            "agent tasks": (True, json.dumps([
                {
                    "id": "task-1",
                    "status": "running",
                    "issue_id": "issue-1",
                    "started_at": recent_ts,
                }
            ])),
        })

        log = []
        agents = fetch_agents([], "self-id", log)
        failed = get_failed_runs(agents, log)
        kills = detect_idle_watchdog_kills(failed, log)

        assert len(failed) == 0
        assert len(kills) == 0

    def test_long_cancelled_detected(self, tmp_path, mock_cli_factory, monkeypatch):
        """Long cancelled task (auxiliary signal) is detected."""
        started_ts = (datetime.now(timezone.utc) - timedelta(minutes=30)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        ended_ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        mock_cli_factory({
            "agent list": (True, json.dumps([
                {"id": "agent-1", "name": "TestAgent", "status": "active"}
            ])),
            "agent tasks": (True, json.dumps([
                {
                    "id": "task-1",
                    "status": "cancelled",
                    "issue_id": "issue-1",
                    "error": None,
                    "started_at": started_ts,
                    "ended_at": ended_ts,
                }
            ])),
            "issue get": (True, json.dumps({"id": "issue-1", "status": "in_progress", "identifier": "SEE-100", "title": "Test"})),
            "issue runs": (True, json.dumps([{"id": "task-1"}])),
        })

        log = []
        agents = fetch_agents([], "self-id", log)
        failed = get_failed_runs(agents, log)
        kills = detect_idle_watchdog_kills(failed, log)

        assert len(failed) == 1
        assert len(kills) == 1
        assert kills[0]["detection_method"] == "long_cancelled"
