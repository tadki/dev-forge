"""E2E test for SEE-750: Agent Watchdog Phase 5 with assignee sync.

Tests the end-to-end Phase 5 execution flow using the actual `execute_reruns`
function with fully mocked CLI calls, simulating the real SEE-747 scenario:

  - Archi created SEE-747, assignee is Archi
  - Owner delegated to Bachi via @mention (assignee NOT updated)
  - Bachi's task failed (idle watchdog killed)
  - Watchdog must rerun to Bachi, not Archi
  - After rerun, assignee must be restored to Archi

This validates the full Phase 5 pipeline in a realistic scenario.
"""

import json
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots"))

from agent_watchdog import execute_reruns
from watchdog_state import WatchdogState


# --- Real agent IDs from the platform ---

ARCHI_AGENT_ID = "809951ab-c70c-48c3-b0d6-7b16b49e1ce3"
BACHI_AGENT_ID = "a5c250e8-7257-466e-b45a-03f995c7206c"
SEE747_ISSUE_ID = "420c414c-986f-40d2-a53b-76b937544a4a"


# --- Platform simulator ---


class PlatformSimulator:
    """Simulates the Multica platform CLI responses for Phase 5 testing."""

    def __init__(self):
        self.issue_assignees = {}
        self.dispatch_log = []
        self.cli_calls = []

    def setup(self, issue_id, assignee):
        """Set an issue's current assignee."""
        self.issue_assignees[issue_id] = assignee

    def multica_cli(self, cmd, **kwargs):
        """Mock multica_cli that simulates platform behavior."""
        self.cli_calls.append(cmd)
        cmd_str = cmd if isinstance(cmd, str) else str(cmd)

        if "issue get" in cmd_str:
            issue_id = cmd_str.split()[3]  # ["multica", "issue", "get", "<id>", ...]
            return (True, json.dumps({
                "id": issue_id,
                "assignee_id": self.issue_assignees.get(issue_id, ""),
                "status": "in_progress",
            }))

        if "issue update" in cmd_str and "--assignee-id" in cmd_str:
            parts = cmd_str.split()
            issue_id = parts[3]
            new_assignee = parts[parts.index("--assignee-id") + 1]
            self.issue_assignees[issue_id] = new_assignee
            return (True, "ok")

        if "issue rerun" in cmd_str:
            parts = cmd_str.split()
            issue_id = parts[3]
            dispatched_to = self.issue_assignees.get(issue_id, "unknown")
            self.dispatch_log.append({
                "issue_id": issue_id,
                "dispatched_to": dispatched_to,
            })
            return (True, f"rerun dispatched to {dispatched_to}")

        return (False, f"unhandled cmd: {cmd_str}")

    def reset(self):
        self.issue_assignees.clear()
        self.dispatch_log.clear()
        self.cli_calls.clear()


# ============================================================
# E2E: SEE-747 scenario
# ============================================================


class TestSEE750E2E:
    @pytest.fixture(autouse=True)
    def reset(self):
        yield

    def test_rerun_dispatches_to_failed_agent_not_stale_assignee(self, tmp_path, monkeypatch):
        """SEE-747 scenario: rerun must go to Bachi, not Archi."""
        import agent_watchdog

        platform = PlatformSimulator()
        platform.setup(SEE747_ISSUE_ID, ARCHI_AGENT_ID)  # Stale assignee

        monkeypatch.setattr(agent_watchdog, "multica_cli", platform.multica_cli)

        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        processing_log = []

        task = {
            "task_id": "task-bachi-failed",
            "issue_id": SEE747_ISSUE_ID,
            "agent_id": BACHI_AGENT_ID,
            "agent_name": "Bachi",
        }

        results = execute_reruns([task], state, dry_run=False, processing_log=processing_log)

        assert len(results) == 1
        assert results[0]["success"] is True
        assert results[0]["dry_run"] is False

        # 1. Rerun dispatched to Bachi (failed agent), not Archi
        assert len(platform.dispatch_log) == 1
        assert platform.dispatch_log[0]["dispatched_to"] == BACHI_AGENT_ID, \
            f"Expected dispatch to Bachi, got {platform.dispatch_log[0]['dispatched_to']}"

        # 2. Issue assignee restored to Archi
        assert platform.issue_assignees[SEE747_ISSUE_ID] == ARCHI_AGENT_ID, \
            "Original assignee must be restored after rerun"

        # 3. Audit trail
        assert any("phase5_assignee_sync" in log for log in processing_log)
        assert any("phase5_assignee_restore" in log for log in processing_log)
        assert any("phase5_rerun_ok" in log for log in processing_log)

        # 4. State recorded
        assert state.get_restart_count(SEE747_ISSUE_ID) == 1

    def test_multiple_issues_synced_independently(self, tmp_path, monkeypatch):
        """Two different issues with different stale assignees → each synced independently."""
        import agent_watchdog

        platform = PlatformSimulator()
        platform.setup("issue-1", ARCHI_AGENT_ID)
        platform.setup("issue-2", BACHI_AGENT_ID)

        monkeypatch.setattr(agent_watchdog, "multica_cli", platform.multica_cli)

        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        processing_log = []

        tasks = [
            {"task_id": "t1", "issue_id": "issue-1", "agent_id": BACHI_AGENT_ID, "agent_name": "Bachi"},
            {"task_id": "t2", "issue_id": "issue-2", "agent_id": ARCHI_AGENT_ID, "agent_name": "Archi"},
        ]

        results = execute_reruns(tasks, state, dry_run=False, processing_log=processing_log)

        assert all(r["success"] for r in results)

        # Issue-1: sync Archi → Bachi → rerun → restore to Archi
        dispatches_1 = [d for d in platform.dispatch_log if d["issue_id"] == "issue-1"]
        assert dispatches_1[0]["dispatched_to"] == BACHI_AGENT_ID

        # Issue-2: sync Bachi → Archi → rerun → restore to Bachi
        dispatches_2 = [d for d in platform.dispatch_log if d["issue_id"] == "issue-2"]
        assert dispatches_2[0]["dispatched_to"] == ARCHI_AGENT_ID

        # Both assignees restored
        assert platform.issue_assignees["issue-1"] == ARCHI_AGENT_ID
        assert platform.issue_assignees["issue-2"] == BACHI_AGENT_ID

        # Two restarts recorded
        assert state.get_restart_count("issue-1") == 1
        assert state.get_restart_count("issue-2") == 1

    def test_dry_run_no_platform_state_changes(self, tmp_path, monkeypatch):
        """Dry-run mode must not change any platform state."""
        import agent_watchdog

        platform = PlatformSimulator()
        platform.setup(SEE747_ISSUE_ID, ARCHI_AGENT_ID)

        monkeypatch.setattr(agent_watchdog, "multica_cli", platform.multica_cli)
        # Even if fetch_issue_info is called somehow
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_info",
                            lambda issue_id, log: {"assignee_id": ARCHI_AGENT_ID})

        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        processing_log = []

        task = {
            "task_id": "task-bachi-failed",
            "issue_id": SEE747_ISSUE_ID,
            "agent_id": BACHI_AGENT_ID,
            "agent_name": "Bachi",
        }

        results = execute_reruns([task], state, dry_run=True, processing_log=processing_log)

        assert results[0]["success"] is True
        assert results[0]["dry_run"] is True

        # No dispatches, no assignee changes, no state recorded
        assert platform.dispatch_log == []
        assert platform.issue_assignees[SEE747_ISSUE_ID] == ARCHI_AGENT_ID
        assert state.get_restart_count(SEE747_ISSUE_ID) == 0

        # Only dry-run log entry
        assert any("phase5_dry_run" in log for log in processing_log)
        assert not any("phase5_assignee_sync" in log for log in processing_log)

    def test_rerun_failure_still_restores_assignee(self, tmp_path, monkeypatch):
        """If rerun itself fails, assignee must still be restored."""
        import agent_watchdog

        platform = PlatformSimulator()
        platform.setup(SEE747_ISSUE_ID, ARCHI_AGENT_ID)

        # Override rerun to always fail
        original_rerun = platform.multica_cli
        def failing_rerun(cmd, **kwargs):
            if "issue rerun" in str(cmd):
                platform.dispatch_log.append({"issue_id": SEE747_ISSUE_ID, "dispatched_to": BACHI_AGENT_ID})
                return (False, "rerun failed: platform error")
            return original_rerun(cmd, **kwargs)

        monkeypatch.setattr(agent_watchdog, "multica_cli", failing_rerun)

        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        processing_log = []

        task = {
            "task_id": "task-bachi-failed",
            "issue_id": SEE747_ISSUE_ID,
            "agent_id": BACHI_AGENT_ID,
            "agent_name": "Bachi",
        }

        results = execute_reruns([task], state, dry_run=False, processing_log=processing_log)

        assert results[0]["success"] is False
        assert results[0]["error"] == "rerun failed: platform error"

        # Assignee restored despite rerun failure
        assert platform.issue_assignees[SEE747_ISSUE_ID] == ARCHI_AGENT_ID

        # Audit trail still complete
        assert any("phase5_assignee_sync" in log for log in processing_log)
        assert any("phase5_assignee_restore" in log for log in processing_log)
        assert any("phase5_rerun_fail" in log for log in processing_log)

        # No state recorded (rerun failed)
        assert state.get_restart_count(SEE747_ISSUE_ID) == 0
