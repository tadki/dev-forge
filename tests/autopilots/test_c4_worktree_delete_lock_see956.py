"""SEE-956 C4 regression: per-worktree advisory delete lock + porcelain cross-check.

Tests the helpers in local_repo_check.py that guard worktree deletion:
- ``acquire_worktree_delete_lock`` takes a per-worktree advisory flock and
  cross-checks ``git worktree list --porcelain`` for a ``locked`` reason.
- ``_worktree_is_locked`` parses porcelain output correctly.
"""

import fcntl
import os
import subprocess
import sys
import tempfile

import pytest

# Add autopilots/ (repo-relative) to path for module imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots"))

from local_repo_check import acquire_worktree_delete_lock, _worktree_is_locked


class TestWorktreeIsLockedPorcelain:
    def test_detects_locked_worktree(self, tmp_path):
        wt = str(tmp_path / "worktree-a")
        os.makedirs(wt, exist_ok=True)
        porcelain = (
            f"worktree {tmp_path / 'other'}\n"
            "bare\n"
            f"worktree {wt}\n"
            "locked because: agent push in progress\n"
        )
        assert _worktree_is_locked(porcelain, wt) is True

    def test_ignores_unlocked_worktree(self, tmp_path):
        wt = str(tmp_path / "worktree-b")
        os.makedirs(wt, exist_ok=True)
        porcelain = (
            f"worktree {wt}\n"
            "bare\n"
        )
        assert _worktree_is_locked(porcelain, wt) is False

    def test_ignores_locked_other_worktree(self, tmp_path):
        wt = str(tmp_path / "worktree-c")
        other = str(tmp_path / "other-locked")
        os.makedirs(wt, exist_ok=True)
        os.makedirs(other, exist_ok=True)
        porcelain = (
            f"worktree {other}\n"
            "locked\n"
            f"worktree {wt}\n"
            "bare\n"
        )
        assert _worktree_is_locked(porcelain, wt) is False

    def test_handles_empty_porcelain(self, tmp_path):
        assert _worktree_is_locked("", str(tmp_path / "wt")) is False


class TestAcquireWorktreeDeleteLock:
    def test_acquires_ok_when_free(self, tmp_path):
        wt_dir = str(tmp_path / "wt-free")
        os.makedirs(wt_dir, exist_ok=True)
        status, fd = acquire_worktree_delete_lock(wt_dir, bare_repo="")
        assert status == "ok"
        assert fd is not None
        assert os.path.exists(str(tmp_path / ".wt-free.dellock"))
        os.close(fd)

    def test_skips_when_advisory_lock_held(self, tmp_path):
        wt_dir = str(tmp_path / "wt-held")
        os.makedirs(wt_dir, exist_ok=True)
        lockfile = str(tmp_path / ".wt-held.dellock")
        holder_fd = os.open(lockfile, os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(holder_fd, fcntl.LOCK_EX)
        try:
            status, fd = acquire_worktree_delete_lock(wt_dir, bare_repo="")
            assert status == "skipped_concurrent"
            assert fd is None
        finally:
            fcntl.flock(holder_fd, fcntl.LOCK_UN)
            os.close(holder_fd)

    def test_skips_when_git_porcelain_reports_locked(self, tmp_path):
        """The advisory lock succeeds, but the porcelain cross-check sees 'locked'."""
        import local_repo_check as lrc

        wt_dir = str(tmp_path / "wt-git-locked")
        os.makedirs(wt_dir, exist_ok=True)
        fake_porcelain = f"worktree {wt_dir}\nlocked\n"
        original_run = lrc.run

        def fake_run(cmd, timeout=30):
            return fake_porcelain

        lrc.run = fake_run
        try:
            status, fd = acquire_worktree_delete_lock(wt_dir, bare_repo="/fake/bare")
            assert status == "skipped_git_locked"
            assert fd is None
        finally:
            lrc.run = original_run

    def test_releases_fd_ok_on_skip(self, tmp_path):
        """Skipped_git_locked must not leak the advisory lock fd."""
        import local_repo_check as lrc

        wt_dir = str(tmp_path / "wt-release")
        os.makedirs(wt_dir, exist_ok=True)
        fake_porcelain = f"worktree {wt_dir}\nlocked\n"
        # SEE-1473: restore the REAL lrc.run afterwards — the previous finally
        # installed a permanent fallback-stub, silently breaking every later
        # in-process caller of run() (exposed by the SEE-1473 branch tests).
        original_run = lrc.run
        lrc.run = lambda cmd, timeout=30: fake_porcelain
        try:
            status, fd = acquire_worktree_delete_lock(wt_dir, bare_repo="/fake/bare")
            # If fd were not closed, the next acquire would see skipped_concurrent
            status2, fd2 = acquire_worktree_delete_lock(wt_dir, bare_repo="/fake/bare")
            assert status == "skipped_git_locked"
            # second call should be able to take the advisory lock, then fail on porcelain again
            assert status2 == "skipped_git_locked"
            assert fd2 is None
        finally:
            lrc.run = original_run


class TestC4IntegrationInDeletePath:
    """Smoke test that the delete helper functions exist and behave safely."""

    def test_lockfile_tied_to_worktree_name(self, tmp_path):
        wt_dir = str(tmp_path / "some-agent-worktree")
        os.makedirs(wt_dir, exist_ok=True)
        expected_lock = str(tmp_path / ".some-agent-worktree.dellock")
        status, fd = acquire_worktree_delete_lock(wt_dir, bare_repo="")
        try:
            assert status == "ok"
            assert os.path.exists(expected_lock)
        finally:
            if fd is not None:
                os.close(fd)
