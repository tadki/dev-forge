"""A/B test for SEE-750 fix: verify Phase 5 rerun dispatches to the correct agent.

This test compares the behavior of `execute_reruns`:
- Pre-fix: always calls `multica issue rerun {issue_id}` without syncing assignee.
  Platform dispatches to issue's stale assignee (Archi) instead of the failed agent (Bachi).
- Post-fix: temporarily syncs assignee to failed_agent, runs rerun, restores original.

We simulate the platform behavior by tracking which `assignee_id` is set at the
time `multica issue rerun` is called. The pre-fix behavior always re-enqueues
to the issue's current assignee (Archi), while the post-fix behavior re-enqueues
to the failed agent (Bachi).
"""

import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots"))


# --- Pre-fix behavior simulation ---


def execute_reruns_prefix(
    approved_tasks, state, dry_run, processing_log,
):
    """Simulate the pre-fix execute_reruns (before commit 98a4fb8).

    Pre-fix code (lines 321-334 in the original file):
        if dry_run:
            ...
        else:
            ok, out = multica_cli(f"multica issue rerun {issue_id}")
            entry["success"] = ok
            ...

    No assignee sync occurs; the platform uses the issue's current assignee.
    """
    results = []
    for task in approved_tasks:
        issue_id = task.get("issue_id", "")
        task_id = task.get("task_id", "")
        entry = {
            "issue_id": issue_id,
            "task_id": task_id,
            "agent_name": task.get("agent_name", ""),
            "success": False,
            "dry_run": dry_run,
            "error": None,
        }
        if dry_run:
            entry["success"] = True
            processing_log.append(f"phase5_dry_run: issue={issue_id}")
        else:
            # Simulate: rerun dispatched to whatever the issue's assignee is at call time
            # (In pre-fix, the platform uses issue's current assignee, which is stale)
            ok, out = _fake_multica_cli(f"multica issue rerun {issue_id}")
            entry["success"] = ok
            entry["error"] = None if ok else out
            if ok:
                state.record_restart(issue_id, task_id)
                processing_log.append(f"phase5_rerun_ok: issue={issue_id}")
            else:
                processing_log.append(f"phase5_rerun_fail: issue={issue_id} error={out}")
        results.append(entry)
    return results


# --- Shared fake CLI infrastructure ---


_current_issue_assignee = {}


def _fake_multica_cli(cmd):
    """Fake CLI that tracks issue assignee state and dispatches rerun accordingly.

    In the pre-fix world, `multica issue rerun` dispatches to the issue's current assignee.
    In the post-fix world, the sync step changes the assignee before rerun, so the
    rerun dispatches to the failed agent.
    """
    cmd_str = cmd
    if "issue update" in cmd_str and "--assignee-id" in cmd_str:
        # Parse: multica issue update {issue_id} --assignee-id {new_assignee}
        parts = cmd_str.split()
        issue_id = parts[3]  # ["multica", "issue", "update", "<id>", ...]
        new_assignee = parts[parts.index("--assignee-id") + 1]
        _current_issue_assignee[issue_id] = new_assignee
        return (True, "ok")
    if "issue rerun" in cmd_str:
        parts = cmd_str.split()
        issue_id = parts[3]  # ["multica", "issue", "rerun", "<id>"]
        # Dispatch to whoever is currently the assignee
        dispatched_to = _current_issue_assignee.get(issue_id, "unknown")
        # Record which agent the platform dispatched to
        _rerun_dispatch_log.append({
            "issue_id": issue_id,
            "dispatched_to": dispatched_to,
        })
        return (True, f"rerun dispatched to {dispatched_to}")
    if "issue get" in cmd_str:
        parts = cmd_str.split()
        issue_id = parts[2]
        return (True, json.dumps({
            "id": issue_id,
            "assignee_id": _current_issue_assignee.get(issue_id, "archi-stale-id"),
        }))
    return (False, f"unhandled cmd: {cmd_str}")


_rerun_dispatch_log = []


def _reset_fake_cli_state():
    _current_issue_assignee.clear()
    _rerun_dispatch_log.clear()


import json  # noqa: E402


def _setup_issue(issue_id, assignee):
    _current_issue_assignee[issue_id] = assignee


# ============================================================
# A/B test fixtures
# ============================================================


@pytest.fixture
def processing_log():
    return []


@pytest.fixture(autouse=True)
def reset_state():
    _reset_fake_cli_state()
    yield
    _reset_fake_cli_state()


@pytest.fixture
def task():
    """Task representing Bachi's failed run on SEE-750.

    The issue was created by Archi (assignee=archi-stale-id), but the owner
    delegated to Bachi via @mention without updating the assignee.
    """
    return {
        "task_id": "t-bachi-1",
        "issue_id": "issue-see750",
        "agent_id": "bachi-agent-id",  # The actually-failed agent
        "agent_name": "Bachi",
    }


# ============================================================
# A/B test: verify fix changes dispatch target
# ============================================================


class TestSEE750AssigneeSyncAB:
    """A/B comparison: pre-fix dispatches to stale assignee, post-fix to failed agent."""

    def test_AB_prefix_dispatches_to_stale_assignee(self, tmp_path, task, processing_log, monkeypatch):
        """PRE-FIX: rerun dispatches to the issue's stale assignee (Archi), not Bachi."""
        from watchdog_state import WatchdogState
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        _setup_issue("issue-see750", "archi-stale-id")

        monkeypatch.setattr("agent_watchdog.multica_cli", _fake_multica_cli)
        monkeypatch.setattr("agent_watchdog._fetch_issue_info",
                            lambda issue_id, log: {"assignee_id": _current_issue_assignee.get(issue_id)})

        execute_reruns_prefix([task], state, dry_run=False, processing_log=processing_log)

        # Pre-fix: rerun dispatched to Archi (stale assignee), not Bachi (failed agent)
        assert len(_rerun_dispatch_log) == 1
        assert _rerun_dispatch_log[0]["dispatched_to"] == "archi-stale-id", \
            "Pre-fix behavior: rerun uses stale assignee (BUG)"

    def test_AB_postfix_dispatches_to_failed_agent(self, tmp_path, task, processing_log, monkeypatch):
        """POST-FIX: rerun dispatches to the failed agent (Bachi)."""
        from agent_watchdog import execute_reruns
        from watchdog_state import WatchdogState
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        _setup_issue("issue-see750", "archi-stale-id")

        monkeypatch.setattr("agent_watchdog.multica_cli", _fake_multica_cli)
        monkeypatch.setattr("agent_watchdog._fetch_issue_info",
                            lambda issue_id, log: {"assignee_id": _current_issue_assignee.get(issue_id)})

        execute_reruns([task], state, dry_run=False, processing_log=processing_log)

        # Post-fix: rerun dispatched to Bachi (failed agent)
        assert len(_rerun_dispatch_log) == 1
        assert _rerun_dispatch_log[0]["dispatched_to"] == "bachi-agent-id", \
            "Post-fix behavior: rerun uses failed agent (FIXED)"

    def test_AB_postfix_restores_original_assignee(self, tmp_path, task, processing_log, monkeypatch):
        """POST-FIX: after rerun, the issue's assignee is restored to Archi."""
        from agent_watchdog import execute_reruns
        from watchdog_state import WatchdogState
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        _setup_issue("issue-see750", "archi-stale-id")

        monkeypatch.setattr("agent_watchdog.multica_cli", _fake_multica_cli)
        monkeypatch.setattr("agent_watchdog._fetch_issue_info",
                            lambda issue_id, log: {"assignee_id": _current_issue_assignee.get(issue_id)})

        execute_reruns([task], state, dry_run=False, processing_log=processing_log)

        # After rerun, assignee should be back to Archi (restored in finally)
        assert _current_issue_assignee["issue-see750"] == "archi-stale-id", \
            "Post-fix: original assignee must be restored after rerun"

    def test_AB_postfix_audit_trail_complete(self, tmp_path, task, processing_log, monkeypatch):
        """POST-FIX: processing_log contains both sync and restore entries."""
        from agent_watchdog import execute_reruns
        from watchdog_state import WatchdogState
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        _setup_issue("issue-see750", "archi-stale-id")

        monkeypatch.setattr("agent_watchdog.multica_cli", _fake_multica_cli)
        monkeypatch.setattr("agent_watchdog._fetch_issue_info",
                            lambda issue_id, log: {"assignee_id": _current_issue_assignee.get(issue_id)})

        execute_reruns([task], state, dry_run=False, processing_log=processing_log)

        # Audit trail: sync entry with from/to, and restore entry
        sync_logs = [l for l in processing_log if "phase5_assignee_sync" in l]
        restore_logs = [l for l in processing_log if "phase5_assignee_restore" in l]
        assert len(sync_logs) == 1
        assert "from=archi-stale-id" in sync_logs[0]
        assert "to=bachi-agent-id" in sync_logs[0]
        assert len(restore_logs) == 1
        assert "to=archi-stale-id" in restore_logs[0]
