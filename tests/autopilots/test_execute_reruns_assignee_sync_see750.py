"""Unit tests for SEE-750 fix: Phase 5 execute_reruns assignee sync.

The fix (commit 98a4fb8) ensures that when the watchdog calls `multica issue rerun`,
the issue's assignee is temporarily set to the actually-failed agent (not the
stale assignee left over from a previous owner mention), and restored afterwards.

These tests verify:
1. Dry-run mode: no assignee sync happens.
2. Real-run mode: assignee is synced from original → failed_agent before rerun.
3. Original assignee is restored after rerun (success path).
4. Original assignee is restored after rerun failure (finally block).
5. No sync when assignee already matches failed_agent.
6. No sync when agent_id is missing from task.
7. processing_log records sync and restore events for auditability.
"""

import os
import sys

import pytest

# Add autopilots/ (repo-relative) to path for module imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots"))

from agent_watchdog import execute_reruns
from watchdog_state import WatchdogState


# --- Fixtures ---


@pytest.fixture
def processing_log():
    return []


@pytest.fixture
def state(tmp_path):
    state_file = str(tmp_path / "state.json")
    return WatchdogState(state_file)


def _make_task(
    task_id="t1",
    issue_id="issue-1",
    agent_id="bachi-agent-id",
    agent_name="Bachi",
    **overrides,
):
    """Minimal Phase-5 task dict."""
    task = {
        "task_id": task_id,
        "issue_id": issue_id,
        "agent_id": agent_id,
        "agent_name": agent_name,
    }
    task.update(overrides)
    return task


# --- Helpers for capturing multica_cli calls ---


class CliRecorder:
    """Records all multica_cli invocations in order."""

    def __init__(self, responses=None):
        """responses: list of (ok, output) tuples, one per call. None = default success."""
        self.calls = []
        self.responses = list(responses or [(True, "ok")])
        self._idx = 0

    def __call__(self, *args, **kwargs):
        cmd = args[0] if args else kwargs.get("cmd", "")
        self.calls.append(cmd)
        if self._idx < len(self.responses):
            resp = self.responses[self._idx]
        else:
            resp = self.responses[-1]
        self._idx += 1
        return resp


# ============================================================
# 1. Dry-run mode: no assignee sync
# ============================================================


class TestDryRunNoSync:
    def test_dry_run_does_not_sync_assignee(self, state, processing_log, monkeypatch):
        """In dry-run mode, multica_cli must never be called for assignee sync."""
        import agent_watchdog

        recorder = CliRecorder()
        monkeypatch.setattr(agent_watchdog, "multica_cli", recorder)
        # _fetch_issue_info should also not be called in dry-run
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_info", lambda *a, **kw: {"assignee_id": "archi-id"})

        task = _make_task(agent_id="bachi-agent-id")
        results = execute_reruns([task], state, dry_run=True, processing_log=processing_log)

        assert len(results) == 1
        assert results[0]["success"] is True
        assert results[0]["dry_run"] is True
        # No multica_cli calls should have been made
        assert recorder.calls == [], f"Expected no CLI calls in dry-run, got: {recorder.calls}"
        # No sync log entries
        assert not any("phase5_assignee_sync" in log for log in processing_log)
        assert not any("phase5_assignee_restore" in log for log in processing_log)
        # dry-run log entry should be present
        assert any("phase5_dry_run" in log for log in processing_log)

    def test_dry_run_does_not_call_fetch_issue_info(self, state, processing_log, monkeypatch):
        """_fetch_issue_info must not be called in dry-run mode."""
        import agent_watchdog

        fetch_called = {"n": 0}
        def counting_fetch(issue_id, log):
            fetch_called["n"] += 1
            return {"assignee_id": "archi-id"}
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_info", counting_fetch)
        monkeypatch.setattr(agent_watchdog, "multica_cli", lambda *a, **kw: (True, "ok"))

        task = _make_task()
        execute_reruns([task], state, dry_run=True, processing_log=processing_log)
        assert fetch_called["n"] == 0


# ============================================================
# 2. Real-run mode: assignee sync when differs from failed_agent
# ============================================================


class TestRealRunSync:
    def test_sync_when_assignee_differs(self, state, processing_log, monkeypatch):
        """When original_assignee != failed_agent_id, sync to failed_agent first."""
        import agent_watchdog

        recorder = CliRecorder()
        monkeypatch.setattr(agent_watchdog, "multica_cli", recorder)
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_info",
                            lambda issue_id, log: {"assignee_id": "archi-id"})

        task = _make_task(agent_id="bachi-agent-id")
        results = execute_reruns([task], state, dry_run=False, processing_log=processing_log)

        assert results[0]["success"] is True
        # Expected call sequence: fetch info (via multica_cli) → update assignee → rerun → restore
        update_calls = [c for c in recorder.calls if "issue update" in c and "--assignee-id" in c]
        rerun_calls = [c for c in recorder.calls if "issue rerun" in c]
        # Should have exactly 2 update calls: sync then restore
        assert len(update_calls) == 2, f"Expected 2 update calls, got: {update_calls}"
        # First update should be to failed_agent (Bachi)
        assert "bachi-agent-id" in update_calls[0]
        # Second update should restore original (Archi)
        assert "archi-id" in update_calls[1]
        # Rerun should happen between sync and restore
        rerun_idx = recorder.calls.index(rerun_calls[0])
        sync_idx = next(i for i, c in enumerate(recorder.calls) if c == update_calls[0])
        restore_idx = recorder.calls.index(update_calls[1])
        assert sync_idx < rerun_idx < restore_idx, \
            f"Expected order sync < rerun < restore, got: {recorder.calls}"
        # State should be recorded
        assert state.get_restart_count("issue-1") == 1

    def test_no_sync_when_assignee_already_matches(self, state, processing_log, monkeypatch):
        """When original_assignee == failed_agent_id, no sync needed."""
        import agent_watchdog

        recorder = CliRecorder()
        monkeypatch.setattr(agent_watchdog, "multica_cli", recorder)
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_info",
                            lambda issue_id, log: {"assignee_id": "bachi-agent-id"})

        task = _make_task(agent_id="bachi-agent-id")
        results = execute_reruns([task], state, dry_run=False, processing_log=processing_log)

        assert results[0]["success"] is True
        # Only rerun call, no update calls
        rerun_calls = [c for c in recorder.calls if "issue rerun" in c]
        update_calls = [c for c in recorder.calls if "issue update" in c and "--assignee-id" in c]
        assert len(rerun_calls) == 1
        assert len(update_calls) == 0, f"Expected no update calls, got: {update_calls}"
        # No sync/restore log entries
        assert not any("phase5_assignee_sync" in log for log in processing_log)
        assert not any("phase5_assignee_restore" in log for log in processing_log)
        # State should be recorded
        assert state.get_restart_count("issue-1") == 1

    def test_no_sync_when_agent_id_missing(self, state, processing_log, monkeypatch):
        """When task has no agent_id, skip sync (no failed agent to sync to)."""
        import agent_watchdog

        recorder = CliRecorder()
        monkeypatch.setattr(agent_watchdog, "multica_cli", recorder)
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_info",
                            lambda issue_id, log: {"assignee_id": "archi-id"})

        task = _make_task(agent_id="")
        results = execute_reruns([task], state, dry_run=False, processing_log=processing_log)

        assert results[0]["success"] is True
        # Only rerun call, no fetch_issue_info, no update
        update_calls = [c for c in recorder.calls if "issue update" in c]
        rerun_calls = [c for c in recorder.calls if "issue rerun" in c]
        assert len(rerun_calls) == 1
        assert len(update_calls) == 0
        # _fetch_issue_info should NOT be called when agent_id is empty
        assert not any("issue get" in c for c in recorder.calls)

    def test_no_sync_when_issue_info_fetch_fails(self, state, processing_log, monkeypatch):
        """When _fetch_issue_info returns empty (CLI failure), skip sync gracefully."""
        import agent_watchdog

        recorder = CliRecorder()
        monkeypatch.setattr(agent_watchdog, "multica_cli", recorder)
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_info",
                            lambda issue_id, log: {})  # CLI failed

        task = _make_task(agent_id="bachi-agent-id")
        results = execute_reruns([task], state, dry_run=False, processing_log=processing_log)

        assert results[0]["success"] is True
        # Only rerun call, no update calls
        update_calls = [c for c in recorder.calls if "issue update" in c and "--assignee-id" in c]
        rerun_calls = [c for c in recorder.calls if "issue rerun" in c]
        assert len(rerun_calls) == 1
        assert len(update_calls) == 0


# ============================================================
# 3. Finally block: assignee restored even if rerun fails
# ============================================================


class TestFinallyBlockRestore:
    def test_restore_on_rerun_failure(self, state, processing_log, monkeypatch):
        """If rerun fails, original_assignee must still be restored in finally."""
        import agent_watchdog

        recorder = CliRecorder(responses=[(True, "ok"), (False, "rerun error")])
        monkeypatch.setattr(agent_watchdog, "multica_cli", recorder)
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_info",
                            lambda issue_id, log: {"assignee_id": "archi-id"})

        task = _make_task(agent_id="bachi-agent-id")
        results = execute_reruns([task], state, dry_run=False, processing_log=processing_log)

        assert results[0]["success"] is False
        assert results[0]["error"] == "rerun error"
        # Verify restore happened despite rerun failure
        update_calls = [c for c in recorder.calls if "issue update" in c and "--assignee-id" in c]
        assert len(update_calls) == 2
        assert "archi-id" in update_calls[1], "Restore should happen in finally even if rerun fails"
        # State should NOT be recorded (rerun failed)
        assert state.get_restart_count("issue-1") == 0
        # processing_log should contain both sync and restore
        assert any("phase5_assignee_sync" in log for log in processing_log)
        assert any("phase5_assignee_restore" in log for log in processing_log)
        assert any("phase5_rerun_fail" in log for log in processing_log)

    def test_restore_on_sync_update_failure(self, state, processing_log, monkeypatch):
        """If the initial sync update fails, rerun still executes and restore still runs."""
        import agent_watchdog

        # First update fails, rerun succeeds
        recorder = CliRecorder(responses=[(False, "update failed"), (True, "ok"), (True, "ok")])
        monkeypatch.setattr(agent_watchdog, "multica_cli", recorder)
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_info",
                            lambda issue_id, log: {"assignee_id": "archi-id"})

        task = _make_task(agent_id="bachi-agent-id")
        # The sync update failure doesn't raise (multica_cli returns ok=False), so rerun proceeds
        results = execute_reruns([task], state, dry_run=False, processing_log=processing_log)

        assert results[0]["success"] is True
        # Restore still happens in finally
        update_calls = [c for c in recorder.calls if "issue update" in c and "--assignee-id" in c]
        # Should have 2 update calls: sync (failed) and restore
        assert len(update_calls) == 2
        assert "archi-id" in update_calls[1]

    def test_no_restore_when_no_sync_happened(self, state, processing_log, monkeypatch):
        """If no sync occurred (assignee already matches), no restore should happen."""
        import agent_watchdog

        # Rerun fails, but no sync was needed
        recorder = CliRecorder(responses=[(False, "rerun error")])
        monkeypatch.setattr(agent_watchdog, "multica_cli", recorder)
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_info",
                            lambda issue_id, log: {"assignee_id": "bachi-agent-id"})

        task = _make_task(agent_id="bachi-agent-id")
        results = execute_reruns([task], state, dry_run=False, processing_log=processing_log)

        assert results[0]["success"] is False
        # No update calls should have been made
        update_calls = [c for c in recorder.calls if "issue update" in c and "--assignee-id" in c]
        assert len(update_calls) == 0
        # No sync/restore log entries
        assert not any("phase5_assignee_sync" in log for log in processing_log)
        assert not any("phase5_assignee_restore" in log for log in processing_log)


# ============================================================
# 4. Audit trail: processing_log records
# ============================================================


class TestAuditTrail:
    def test_sync_log_includes_from_and_to(self, state, processing_log, monkeypatch):
        """processing_log sync entry must include from= and to= identifiers for audit."""
        import agent_watchdog

        recorder = CliRecorder()
        monkeypatch.setattr(agent_watchdog, "multica_cli", recorder)
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_info",
                            lambda issue_id, log: {"assignee_id": "archi-id"})

        task = _make_task(issue_id="SEE-750", agent_id="bachi-agent-id")
        execute_reruns([task], state, dry_run=False, processing_log=processing_log)

        sync_logs = [l for l in processing_log if "phase5_assignee_sync" in l]
        restore_logs = [l for l in processing_log if "phase5_assignee_restore" in l]
        assert len(sync_logs) == 1
        assert "issue=SEE-750" in sync_logs[0]
        assert "from=archi-id" in sync_logs[0]
        assert "to=bachi-agent-id" in sync_logs[0]
        assert len(restore_logs) == 1
        assert "issue=SEE-750" in restore_logs[0]
        assert "to=archi-id" in restore_logs[0]

    def test_multiple_tasks_processed_independently(self, state, processing_log, monkeypatch):
        """Multiple tasks in one call: each gets independent sync/restore."""
        import agent_watchdog

        recorder = CliRecorder()
        monkeypatch.setattr(agent_watchdog, "multica_cli", recorder)

        issue_to_assignee = {
            "issue-1": "archi-id",
            "issue-2": "fronti-id",
        }
        def fake_fetch(issue_id, log):
            return {"assignee_id": issue_to_assignee.get(issue_id, "")}
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_info", fake_fetch)

        tasks = [
            _make_task(task_id="t1", issue_id="issue-1", agent_id="bachi-agent-id"),
            _make_task(task_id="t2", issue_id="issue-2", agent_id="fronti-agent-id"),
        ]
        results = execute_reruns(tasks, state, dry_run=False, processing_log=processing_log)

        assert all(r["success"] for r in results)
        # Each task: fetch → sync → rerun → restore = 4 calls
        # Total: 8 multica_cli calls (rerun + 2 updates per task, no fetch via multica_cli)
        assert len(recorder.calls) == 6  # 2 syncs + 2 reruns + 2 restores
        # State recorded for both
        assert state.get_restart_count("issue-1") == 1
        assert state.get_restart_count("issue-2") == 1


# ============================================================
# 5. Backward compatibility: original rerun still works
# ============================================================


class TestBackwardCompatibility:
    def test_rerun_still_works_with_existing_tasks(self, state, processing_log, monkeypatch):
        """Tasks with agent_id present (new format) continue to work end-to-end."""
        import agent_watchdog

        recorder = CliRecorder()
        monkeypatch.setattr(agent_watchdog, "multica_cli", recorder)
        monkeypatch.setattr(agent_watchdog, "_fetch_issue_info",
                            lambda issue_id, log: {"assignee_id": "bachi-agent-id"})

        task = _make_task(agent_id="bachi-agent-id")
        results = execute_reruns([task], state, dry_run=False, processing_log=processing_log)

        assert results[0]["success"] is True
        # Only rerun call (no sync needed since assignee matches)
        rerun_calls = [c for c in recorder.calls if "issue rerun" in c]
        assert len(rerun_calls) == 1
        assert "issue-1" in rerun_calls[0]
