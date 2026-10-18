"""Unit tests for multica_helpers.py — PidFileLock mechanism."""

import os
import sys
import tempfile

import pytest

# Add autopilots/ (repo-relative) to path for module imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots"))

from multica_helpers import PidFileLock, WorkspaceMutex, _pid_exists


class TestPidFileLock:
    def test_acquire_and_release(self, tmp_path):
        pid_file = str(tmp_path / "test.pid")
        lock = PidFileLock(pid_file)
        assert lock.acquire() is True
        assert os.path.exists(pid_file)
        # PID file should contain current PID
        with open(pid_file) as f:
            assert f.read().strip() == str(os.getpid())
        lock.release()
        # After release, file should be removed
        assert not os.path.exists(pid_file)

    def test_double_acquire_fails(self, tmp_path):
        """BUG: PidFileLock.acquire() uses json.dumps on line 175 but never imports json.
        When lock contention occurs, it crashes with NameError instead of returning False.
        This test documents the bug — after fix, assert lock2.acquire() is False should pass.
        """
        pid_file = str(tmp_path / "test.pid")
        lock1 = PidFileLock(pid_file)
        assert lock1.acquire() is True

        lock2 = PidFileLock(pid_file)
        # Second acquire should gracefully return False (already running)
        assert lock2.acquire() is False
        lock1.release()

    def test_context_manager(self, tmp_path):
        pid_file = str(tmp_path / "ctx.pid")
        with PidFileLock(pid_file) as lock:
            assert os.path.exists(pid_file)
        assert not os.path.exists(pid_file)

    def test_release_without_acquire(self, tmp_path):
        pid_file = str(tmp_path / "noop.pid")
        lock = PidFileLock(pid_file)
        # Should not raise
        lock.release()

    def test_sequential_acquire_after_release(self, tmp_path):
        pid_file = str(tmp_path / "seq.pid")
        lock1 = PidFileLock(pid_file)
        assert lock1.acquire() is True
        lock1.release()

        lock2 = PidFileLock(pid_file)
        assert lock2.acquire() is True
        lock2.release()


class TestPidExists:
    def test_current_pid_exists(self):
        assert _pid_exists(os.getpid()) is True

    def test_nonexistent_pid(self):
        # Use a very high PID that's unlikely to exist
        assert _pid_exists(999999999) is False


class TestWorkspaceMutex:
    """SEE-956 H10/L3: advisory workspace-level mutex smoke tests.

    WorkspaceMutex differs from PidFileLock: it coordinates *different*
    autopilots with a bounded wait, then proceeds advisory-style rather than
    hard-failing. These tests pin its core contract (acquire/release,
    contention observed, advisory pass-through on timeout, stale-lock
    recovery via flock auto-release).
    """

    def test_acquire_and_release(self, tmp_path):
        mutex_file = str(tmp_path / "workspace.lock")
        m = WorkspaceMutex(mutex_file=mutex_file, timeout=1, label="test")
        assert m.acquire() is True
        assert os.path.exists(mutex_file)
        with open(mutex_file) as f:
            assert f.read().strip() == str(os.getpid())
        m.release()
        assert m._fd is None

    def test_context_manager_acquires_and_releases(self, tmp_path):
        mutex_file = str(tmp_path / "ctx_workspace.lock")
        with WorkspaceMutex(mutex_file=mutex_file, timeout=1, label="ctx") as m:
            assert m._acquired is True
        assert m._fd is None

    def test_second_holder_waits_then_advisory_proceeds(self, tmp_path):
        """A holder that never releases forces the second into advisory mode."""
        import fcntl
        mutex_file = str(tmp_path / "contended.lock")
        # Hold the lock with an independent fd that we keep open (not via
        # WorkspaceMutex.release) so the second acquirer cannot get it.
        os.makedirs(str(tmp_path), exist_ok=True)
        holder_fd = os.open(mutex_file, os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(holder_fd, fcntl.LOCK_EX)
        try:
            m = WorkspaceMutex(mutex_file=mutex_file, timeout=0, label="second")
            # timeout=0 -> cannot get the lock -> advisory proceed (returns False)
            assert m.acquire() is False
            assert m._acquired is False
        finally:
            fcntl.flock(holder_fd, fcntl.LOCK_UN)
            os.close(holder_fd)

    def test_stale_lock_recovered_after_release(self, tmp_path):
        """Once the prior holder releases (fd close), the mutex is acquirable."""
        import fcntl
        mutex_file = str(tmp_path / "stale.lock")
        holder_fd = os.open(mutex_file, os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(holder_fd, fcntl.LOCK_EX)
        fcntl.flock(holder_fd, fcntl.LOCK_UN)
        os.close(holder_fd)
        m = WorkspaceMutex(mutex_file=mutex_file, timeout=1, label="after")
        assert m.acquire() is True
        m.release()

    def test_release_without_acquire_is_noop(self, tmp_path):
        m = WorkspaceMutex(mutex_file=str(tmp_path / "noop.lock"), timeout=1)
        m.release()  # must not raise
