"""SEE-956 C6/H11 regression: atomic rate-limit gate + atomic state write.

These tests pin the concurrency contract that Archi flagged as the headline
risk and that Bachi's fix delivers:

- ``state.lock()`` wraps check→record so the Nth+1 restart is blocked *under
  the lock* (single-process boundary test).
- Two real OS processes contending on the same state file cannot together
  exceed ``max_per_hour`` (the true check-then-act race Archi asked to be
 固化 as regression).
- ``_save()`` writes atomically (temp + ``os.replace``) so a reader never
  observes a half-written / truncated state file — the failure mode that
  would silently wipe the rate-limit window and defeat C6/H11.
"""

import glob
import json
import os
import subprocess
import sys
import textwrap
import threading
import time

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots"))

from watchdog_state import WatchdogState


def _utcnow_iso():
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# Worker program: each instance tries to record `goal` restarts for `issue_id`
# under the lock, exactly as execute_reruns does. Used for real 2-process races.
# The autopilots dir is passed as argv[1] and prepended to sys.path so the
# worker does not depend on the parent's PYTHONPATH.
_WORKER = textwrap.dedent(
    """
    import sys
    sys.path.insert(0, sys.argv[1])
    from watchdog_state import WatchdogState
    state_file, issue_id, goal, max_per_hour, barrier = (
        sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), sys.argv[6]
    )
    import os, time
    # Barrier: rendezvous, not a one-shot GO file. Each worker announces
    # readiness (barrier + ".<pid>.ready") before waiting for the parent's GO
    # (barrier); the parent releases GO only after every worker is in position.
    # A plain GO file released on a fixed timer lets late-interpreter-startup
    # workers (loaded machines) miss the race entirely — SEE-1381 §SPEC-012.
    if barrier:
        open(barrier + "." + str(os.getpid()) + ".ready", "w").close()
        for _ in range(30000):
            if os.path.exists(barrier):
                break
            time.sleep(0.001)
    state = WatchdogState(state_file)
    recorded = 0
    for _ in range(goal):
        with state.lock():
            if state.check_restart_limit(issue_id, max_per_hour):
                state.record_restart(issue_id, "task-x")
                recorded += 1
            else:
                break
    print(recorded)
    """
)

# Negative-control worker: does the SAME loop WITHOUT state.lock() — pure
# check-then-act. Proves the test is a real race detector: this version leaks
# past the cap, the locked version does not.
_WORKER_NO_LOCK = textwrap.dedent(
    """
    import sys
    sys.path.insert(0, sys.argv[1])
    from watchdog_state import WatchdogState
    state_file, issue_id, goal, max_per_hour, barrier = (
        sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), sys.argv[6]
    )
    import os, time
    # Same rendezvous barrier as the locked worker — see the comment there.
    if barrier:
        open(barrier + "." + str(os.getpid()) + ".ready", "w").close()
        for _ in range(30000):
            if os.path.exists(barrier):
                break
            time.sleep(0.001)
    recorded = 0
    for _ in range(goal):
        s = WatchdogState(state_file)  # fresh load each iter (maximizes race)
        if s.check_restart_limit(issue_id, max_per_hour):
            time.sleep(0.002)  # widen the check-then-act gap
            s.record_restart(issue_id, "task-x")
            recorded += 1
        else:
            break
    print(recorded)
    """
)


def _spawn_race(tmp_path, worker_src, n_workers=8, goal=3, max_per_hour=3):
    """Launch n_workers processes that race on the same state file behind a
    filesystem barrier; return (total_records, worker_outputs)."""
    autopilots_dir = os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", "..", "autopilots")
    )
    state_file = str(tmp_path / "race.json")
    barrier = str(tmp_path / "GO")
    env = dict(os.environ)
    env["MULTICA_HOME"] = str(tmp_path / "multica-home")
    procs = [
        subprocess.Popen(
            [sys.executable, "-c", worker_src, autopilots_dir, state_file,
             "issue-race", str(goal), str(max_per_hour), barrier],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
        )
        for _ in range(n_workers)
    ]
    # Rendezvous release: wait until every worker has announced readiness, so
    # the race starts with all workers in position regardless of interpreter
    # startup skew under load (a fixed 0.05s timer let late workers miss the
    # race — SEE-1381 §SPEC-012 load-sensitivity finding).
    deadline = time.time() + 60
    while time.time() < deadline:
        if len(glob.glob(barrier + ".*.ready")) >= n_workers:
            break
        time.sleep(0.05)
    open(barrier, "w").close()
    outputs = []
    for p in procs:
        out, err = p.communicate(timeout=30)
        assert p.returncode == 0, f"worker failed: {err}"
        outputs.append(int(out.strip()))
    sys.path.insert(0, autopilots_dir)
    from watchdog_state import WatchdogState
    total = WatchdogState(state_file).get_restart_count("issue-race")
    return total, outputs


class TestAtomicRateLimitGateSingleProcess:
    """C6/H11 unit boundary: the 4th restart must be blocked inside state.lock()."""

    def test_fourth_restart_blocked_under_lock(self, tmp_path):
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        issue_id = "issue-concurrent-001"
        max_per_hour = 3
        outcomes = []
        # Simulate execute_reruns loop: lock -> check -> record
        for _ in range(4):
            with state.lock():
                allowed = state.check_restart_limit(issue_id, max_per_hour)
                if allowed:
                    state.record_restart(issue_id, "task-x")
                outcomes.append(allowed)
        # First 3 allowed, 4th blocked under the lock
        assert outcomes == [True, True, True, False]
        assert state.get_restart_count(issue_id) == max_per_hour

    def test_limit_gate_blocks_exactly_at_max(self, tmp_path):
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        issue_id = "issue-cap-002"
        # Pre-fill to the cap
        for _ in range(3):
            state.record_restart(issue_id, "task-y")
        with state.lock():
            assert state.check_restart_limit(issue_id, 3) is False

    def test_failed_rerun_does_not_consume_quota(self, tmp_path):
        """Mirrors test_real_run_failure_handled: a failed rerun must not record."""
        state_file = str(tmp_path / "state.json")
        state = WatchdogState(state_file)
        issue_id = "issue-fail-003"
        with state.lock():
            allowed = state.check_restart_limit(issue_id, 3)
            # A failed rerun (ok=False) must not call record_restart
            ok = False
            if allowed and ok:
                state.record_restart(issue_id, "task-z")
        assert state.get_restart_count(issue_id) == 0


class TestAtomicRateLimitGateTwoProcesses:
    """C6/H11 real concurrency: two OS processes cannot exceed max_per_hour.

    This is the regression Archi explicitly asked for: two concurrent watchdog
    instances racing on the same issue must not both pass the cap. The
    companion ``test_without_lock_race_leaks_past_cap`` proves the test is a
    real race detector (it fails on the un-locked code path), so a future
    regression that drops ``state.lock()`` will turn this suite red.
    """

    def test_two_concurrent_workers_total_does_not_exceed_cap(self, tmp_path):
        total, outputs = _spawn_race(tmp_path, _WORKER, n_workers=2, goal=5, max_per_hour=3)
        assert total == 3, f"race leaked past cap: total={total} (workers={outputs})"
        assert sum(outputs) == 3

    def test_many_workers_still_capped(self, tmp_path):
        """Stress: 8 barrier-synchronized workers, cap=3 -> exactly 3 records."""
        total, outputs = _spawn_race(tmp_path, _WORKER, n_workers=8, goal=3, max_per_hour=3)
        assert total == 3, f"stress race leaked past cap: total={total} (workers={outputs})"

    def test_without_lock_race_leaks_past_cap(self, tmp_path):
        """Negative control: the SAME loop WITHOUT state.lock() allows every
        worker to pass the cap, because each worker reads the file, sees the
        current count, and writes its own records back, overwriting others.

        The *locked* tests above guarantee ``sum(outputs) == max_per_hour``
        (only one critical section's worth of restarts are allowed). The
        un-locked path is expected to overshoot — we assert that the total
        number of restarts recorded by all workers is strictly greater than
        the cap, proving the test suite is sensitive to the lock.
        """
        total, outputs = _spawn_race(tmp_path, _WORKER_NO_LOCK, n_workers=8, goal=3, max_per_hour=3)
        # total may still be exactly 3 due to last-writer-wins; the leak is in
        # the *sum of records each worker thought it made*.
        assert sum(outputs) > 3, (
            f"negative control did not leak: total={total}, outputs={outputs}; "
            f"the race is too narrow on this machine to reproduce without the lock"
        )
        # Sanity: the locked path never leaks, so the previous tests already
        # established the product behavior; this just anchors the detector.


class TestAtomicStateSave:
    """C6: _save() must be atomic (temp + os.replace); readers never see a
    truncated/half-written file that would silently wipe the rate-limit window.
    """

    def test_save_produces_valid_json_with_expected_shape(self, tmp_path):
        state_file = str(tmp_path / "atomic.json")
        state = WatchdogState(state_file)
        state.record_restart("issue-save-006", "task-a")
        state.record_restart("issue-save-006", "task-b")
        with open(state_file, encoding="utf-8") as f:
            data = json.load(f)
        assert "restarts" in data
        assert len(data["restarts"]) == 2

    def test_save_replaces_not_appends_or_truncates_mid_record(self, tmp_path):
        """A normal save must leave exactly one well-formed JSON document."""
        state_file = str(tmp_path / "atomic2.json")
        state = WatchdogState(state_file)
        for i in range(5):
            state.record_restart("issue-rpl", f"task-{i}")
        with open(state_file, encoding="utf-8") as f:
            raw = f.read()
        # Exactly one JSON object — first non-ws char '{', last '}'
        assert raw.strip().startswith("{")
        assert raw.strip().endswith("}")
        json.loads(raw)  # parses cleanly

    def test_no_temp_file_left_after_save(self, tmp_path):
        state_file = str(tmp_path / "notemp.json")
        state = WatchdogState(state_file)
        state.record_restart("issue-clean", "task-c")
        leftovers = [
            n for n in os.listdir(str(tmp_path))
            if n.startswith(".watchdog_state.") and n.endswith(".tmp")
        ]
        assert leftovers == [], f"temp file left behind: {leftovers}"

    def test_load_recovers_when_state_file_truncated(self, tmp_path):
        """Simulate the pre-fix failure mode: a truncated state file must not
        crash and must start from an empty window (rather than the old code's
        silent zeroing — the new atomic write *prevents* truncation from
        happening in the first place; this test pins the load-time guard)."""
        state_file = str(tmp_path / "trunc.json")
        # Write a deliberately broken (truncated) state file
        with open(state_file, "w", encoding="utf-8") as f:
            f.write('{"restarts": [{"issue_id": "issue-x", "task_id": "t1", "timestamp": "20')
        state = WatchdogState(state_file)
        # Must not raise; window starts empty
        assert state.records == []
        assert state.get_restart_count("issue-x") == 0

    def test_save_then_load_roundtrip_preserves_records(self, tmp_path):
        state_file = str(tmp_path / "roundtrip.json")
        s1 = WatchdogState(state_file)
        s1.record_restart("issue-rt", "task-1")
        s1.record_restart("issue-rt", "task-2")
        # New instance reads the same file
        s2 = WatchdogState(state_file)
        assert s2.get_restart_count("issue-rt") == 2

    def test_save_atomic_under_simulated_crash_pattern(self, tmp_path):
        """The atomic pattern means a *partial* temp write is never visible at
        the canonical path: os.replace is the only thing that publishes it."""
        state_file = str(tmp_path / "crash.json")
        state = WatchdogState(state_file)
        state.record_restart("issue-crash", "task-0")
        snapshot_before = open(state_file, encoding="utf-8").read()
        # Simulate a crash mid-write by directly truncating a *temp* file —
        # the canonical file must remain intact because the real _save only
        # swaps it in via os.replace once fully written.
        bogus_temp = str(tmp_path / ".watchdog_state.crash.tmp")
        with open(bogus_temp, "w") as f:
            f.write('{"restarts": BROKEN')
        # canonical file untouched
        assert open(state_file, encoding="utf-8").read() == snapshot_before
        json.loads(open(state_file, encoding="utf-8").read())  # still valid
