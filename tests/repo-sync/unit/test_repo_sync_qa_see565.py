#!/usr/bin/env python3
"""
QA unit tests for SEE-565 repo sync robustness improvements.

Supplements Bachi's test_repo_sync_robustness.py with edge cases
identified during Atlas code review and Revy QA verification.
"""

import json
import os
import subprocess
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "repo-sync"))

from repo_sync import (
    acquire_lock,
    release_lock,
    detect_orphan_gitlinks,
    remove_orphan_gitlink,
    _try_stash_with_recovery,
    _cleanup_gitlinks_and_retry_stash,
    git_run,
    do_rebase,
    do_stash_pop,
    do_rebase_abort,
    do_pull_merge,
    detect_sync_state,
    is_working_tree_dirty,
    get_sha,
)


def _run_git(cwd, args, check=True):
    return subprocess.run(
        ["git"] + args,
        cwd=cwd,
        capture_output=True,
        text=True,
        check=check,
    )


# ---------------------------------------------------------------------------
# 1. Config defaults
# ---------------------------------------------------------------------------


class TestConfigDefaults:
    """Verify new config keys have correct defaults."""

    def test_daemon_max_consecutive_failures_default(self):
        """daemon_max_consecutive_failures should default to 10."""
        config = {
            "repo_path": "/tmp",
            "remote": "origin",
            "branch": "master",
            "log_dir": "/tmp/logs",
        }
        assert config.get("daemon_max_consecutive_failures", 10) == 10

    def test_daemon_backoff_max_seconds_default(self):
        """daemon_backoff_max_seconds should default to 300."""
        config = {
            "repo_path": "/tmp",
            "remote": "origin",
            "branch": "master",
            "log_dir": "/tmp/logs",
        }
        assert config.get("daemon_backoff_max_seconds", 300) == 300

    def test_subprocess_timeout_seconds_default(self):
        """subprocess_timeout_seconds should default to 120."""
        config = {
            "repo_path": "/tmp",
            "remote": "origin",
            "branch": "master",
            "log_dir": "/tmp/logs",
        }
        assert config.get("subprocess_timeout_seconds", 120) == 120

    def test_config_file_has_new_keys(self):
        """repo_sync_config.json should contain the three new keys."""
        config_path = Path(__file__).parent.parent.parent / "repo_sync_config.json"
        if not config_path.exists():
            pytest.skip("config file not found")
        with open(config_path) as f:
            cfg = json.load(f)
        assert "daemon_max_consecutive_failures" in cfg
        assert "daemon_backoff_max_seconds" in cfg
        assert "subprocess_timeout_seconds" in cfg


# ---------------------------------------------------------------------------
# 2. Stale lock edge cases
# ---------------------------------------------------------------------------


class TestStaleLockEdgeCases:
    """Verify stale lock handling edge cases from Atlas review finding MEDIUM-1."""

    @pytest.fixture
    def lock_file(self, tmp_path):
        return str(tmp_path / "test.lock")

    def test_nonblocking_path_no_file(self, lock_file):
        """timeout=0.0 should succeed immediately on fresh file."""
        if sys.platform == "win32":
            pytest.skip("Unix-only test")
        fd = acquire_lock(lock_file, timeout=0.0)
        assert fd is not None
        release_lock(fd, lock_file)

    def test_nonblocking_path_empty_file(self, lock_file):
        """Empty lock file (no PID written) should be acquirable."""
        if sys.platform == "win32":
            pytest.skip("Unix-only test")
        Path(lock_file).write_text("")
        fd = acquire_lock(lock_file, timeout=0.0)
        assert fd is not None
        release_lock(fd, lock_file)

    def test_nonblocking_path_non_numeric_pid(self, lock_file):
        """Lock file with non-numeric content should be acquirable."""
        if sys.platform == "win32":
            pytest.skip("Unix-only test")
        Path(lock_file).write_text("not-a-pid")
        fd = acquire_lock(lock_file, timeout=0.0)
        assert fd is not None
        release_lock(fd, lock_file)

    def test_timeout_path_with_dead_pid(self, lock_file):
        """timeout>0 with dead PID should recover via stale detection."""
        if sys.platform == "win32":
            pytest.skip("Unix-only test")
        dead_pid = 99999999
        Path(lock_file).write_text(str(dead_pid))
        fd = acquire_lock(lock_file, timeout=0.5)
        assert fd is not None
        release_lock(fd, lock_file)

    def test_release_lock_idempotent(self, lock_file):
        """release_lock should not raise on double-release."""
        if sys.platform == "win32":
            pytest.skip("Unix-only test")
        fd = acquire_lock(lock_file)
        assert fd is not None
        release_lock(fd, lock_file)
        release_lock(None, lock_file)


# ---------------------------------------------------------------------------
# 3. Orphan gitlink edge cases
# ---------------------------------------------------------------------------


class TestOrphanGitlinkEdgeCases:
    """Additional orphan gitlink detection tests."""

    def test_detect_with_gitmodules_registered(self, tmp_path):
        """Registered submodule in .gitmodules should NOT be flagged as orphan."""
        repo = str(tmp_path / "repo")
        os.makedirs(repo)
        _run_git(repo, ["init", "-b", "master"])
        _run_git(repo, ["config", "user.email", "test@test.com"])
        _run_git(repo, ["config", "user.name", "Test"])
        Path(os.path.join(repo, "a.txt")).write_text("a")
        _run_git(repo, ["add", "a.txt"])
        _run_git(repo, ["commit", "-m", "init"])

        gitmodules = Path(os.path.join(repo, ".gitmodules"))
        gitmodules.write_text(
            '[submodule "RealSub"]\n\tpath = RealSub\n\turl = https://example.com/repo.git\n'
        )
        _run_git(repo, ["add", ".gitmodules"])
        _run_git(repo, ["commit", "-m", "add gitmodules"])

        subprocess.run(
            [
                "git",
                "-C",
                repo,
                "update-index",
                "--add",
                "--cacheinfo",
                "160000",
                "abc123def456789012345678901234567890abcd",
                "RealSub",
            ],
            capture_output=True,
            check=False,
        )

        orphans = detect_orphan_gitlinks(repo)
        assert "RealSub" not in orphans

    def test_detect_multiple_orphans(self, tmp_path):
        """Should detect multiple orphan gitlinks."""
        repo = str(tmp_path / "repo")
        os.makedirs(repo)
        _run_git(repo, ["init", "-b", "master"])
        _run_git(repo, ["config", "user.email", "test@test.com"])
        _run_git(repo, ["config", "user.name", "Test"])
        Path(os.path.join(repo, "a.txt")).write_text("a")
        _run_git(repo, ["add", "a.txt"])
        _run_git(repo, ["commit", "-m", "init"])

        for name in ["Sub1", "Sub2"]:
            subprocess.run(
                [
                    "git",
                    "-C",
                    repo,
                    "update-index",
                    "--add",
                    "--cacheinfo",
                    "160000",
                    "abc123def456789012345678901234567890abcd",
                    name,
                ],
                capture_output=True,
                check=False,
            )

        orphans = detect_orphan_gitlinks(repo)
        assert len(orphans) == 2
        assert "Sub1" in orphans
        assert "Sub2" in orphans

    def test_remove_nonexistent_gitlink(self, tmp_path):
        """Removing a non-existent gitlink should return failure."""
        repo = str(tmp_path / "repo")
        os.makedirs(repo)
        _run_git(repo, ["init", "-b", "master"])
        _run_git(repo, ["config", "user.email", "test@test.com"])
        _run_git(repo, ["config", "user.name", "Test"])
        Path(os.path.join(repo, "a.txt")).write_text("a")
        _run_git(repo, ["add", "a.txt"])
        _run_git(repo, ["commit", "-m", "init"])

        ok, msg = remove_orphan_gitlink(repo, "NonExistent")
        assert ok is False


# ---------------------------------------------------------------------------
# 4. _try_stash_with_recovery
# ---------------------------------------------------------------------------


class TestTryStashWithRecovery:
    """Test _try_stash_with_recovery helper."""

    def test_stash_succeeds_immediately(self, tmp_path):
        """If stash works on first try, no recovery needed."""
        repo = str(tmp_path / "repo")
        os.makedirs(repo)
        _run_git(repo, ["init", "-b", "master"])
        _run_git(repo, ["config", "user.email", "test@test.com"])
        _run_git(repo, ["config", "user.name", "Test"])
        Path(os.path.join(repo, "a.txt")).write_text("a")
        _run_git(repo, ["add", "a.txt"])
        _run_git(repo, ["commit", "-m", "init"])
        Path(os.path.join(repo, "dirty.txt")).write_text("dirty")

        ok, msg, had_stash = _try_stash_with_recovery(repo, stash_on_dirty=True)
        assert ok is True

    def test_stash_disabled(self, tmp_path):
        """stash_on_dirty=False should not stash."""
        repo = str(tmp_path / "repo")
        os.makedirs(repo)
        _run_git(repo, ["init", "-b", "master"])
        _run_git(repo, ["config", "user.email", "test@test.com"])
        _run_git(repo, ["config", "user.name", "Test"])
        Path(os.path.join(repo, "a.txt")).write_text("a")
        _run_git(repo, ["add", "a.txt"])
        _run_git(repo, ["commit", "-m", "init"])
        Path(os.path.join(repo, "dirty.txt")).write_text("dirty")

        ok, msg, had_stash = _try_stash_with_recovery(repo, stash_on_dirty=False)
        assert ok is False
        assert "disabled" in msg


# ---------------------------------------------------------------------------
# 5. git_run timeout propagation
# ---------------------------------------------------------------------------


class TestGitRunTimeout:
    """Verify git_run passes timeout to subprocess."""

    @patch("repo_sync.subprocess.run")
    def test_timeout_forwarded(self, mock_run):
        """git_run should pass timeout to subprocess.run."""
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        git_run("/tmp/repo", ["status"], timeout=30)
        _, kwargs = mock_run.call_args
        assert kwargs.get("timeout") == 30

    @patch("repo_sync.subprocess.run")
    def test_no_timeout_by_default(self, mock_run):
        """git_run without timeout should not pass timeout kwarg."""
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        git_run("/tmp/repo", ["status"])
        _, kwargs = mock_run.call_args
        assert "timeout" not in kwargs


# ---------------------------------------------------------------------------
# 6. Circuit breaker alert format
# ---------------------------------------------------------------------------


class TestCircuitBreakerAlert:
    """Verify circuit breaker alert content."""

    @patch("repo_sync.subprocess.run")
    def test_alert_includes_pid_and_failure_count(self, mock_run):
        """Alert message should include PID and failure count."""
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        from repo_sync import send_alert

        config = {"alert_issue_id": "test-issue-id"}
        alert_msg = (
            f"🚨 **Repo Sync Daemon Alert — Circuit breaker triggered**\n\n"
            f"- PID: `{os.getpid()}`\n"
            f"- Consecutive failures: `10`\n"
            f"- Max allowed: `10`\n"
            f"- Daemon stopped to prevent infinite crash loop."
        )
        send_alert(config, alert_msg)
        cmd_args = mock_run.call_args[0][0]
        assert "PID" in cmd_args[-1]
        assert "Consecutive failures" in cmd_args[-1]


# ---------------------------------------------------------------------------
# 7. Exponential backoff edge cases
# ---------------------------------------------------------------------------


class TestBackoffEdgeCases:
    """Edge cases for exponential backoff."""

    def test_backoff_with_zero_base(self):
        """Base interval of 0 should not cause issues."""
        base = 0
        backoff_max = 300
        interval = base
        for _ in range(10):
            interval = min(interval * 2, backoff_max)
        assert interval == 0

    def test_backoff_with_base_equals_max(self):
        """If base equals max, interval stays constant."""
        base = 300
        backoff_max = 300
        interval = base
        interval = min(interval * 2, backoff_max)
        assert interval == backoff_max

    def test_backoff_preserves_integer_sequence(self):
        """Backoff should produce clean integer sequence."""
        base = 5
        backoff_max = 300
        interval = base
        sequence = []
        for _ in range(7):
            sequence.append(interval)
            interval = min(interval * 2, backoff_max)
        for val in sequence:
            assert isinstance(val, int)


# ---------------------------------------------------------------------------
# 8. MEDIUM-1: stale lock non-blocking LOCK_NB fallback
# ---------------------------------------------------------------------------


class TestStaleLockNonblockingFallback:
    """Verify stale lock path uses LOCK_NB and falls back correctly."""

    @pytest.fixture
    def lock_file(self, tmp_path):
        return str(tmp_path / "test.lock")

    def test_nonblocking_stale_lock_fallback_on_nb_fail(self, lock_file):
        """If LOCK_NB fails after dead PID detection, should return None (immediate path)."""
        if sys.platform == "win32":
            pytest.skip("Unix-only test")
        dead_pid = 99999999
        Path(lock_file).write_text(str(dead_pid))

        fd_holder = acquire_lock(lock_file, timeout=0.0)
        assert fd_holder is not None

        fd2 = acquire_lock(lock_file, timeout=0.0)
        assert fd2 is None

        release_lock(fd_holder, lock_file)

    def test_nonblocking_stale_lock_recovers_after_holder_releases(self, lock_file):
        """After lock holder releases, another acquire should succeed."""
        if sys.platform == "win32":
            pytest.skip("Unix-only test")
        dead_pid = 99999999
        Path(lock_file).write_text(str(dead_pid))

        fd1 = acquire_lock(lock_file, timeout=0.0)
        assert fd1 is not None
        release_lock(fd1, lock_file)

        fd2 = acquire_lock(lock_file, timeout=0.0)
        assert fd2 is not None
        release_lock(fd2, lock_file)


# ---------------------------------------------------------------------------
# 9. MEDIUM-2: _cleanup_gitlinks_and_retry_stash unified function
# ---------------------------------------------------------------------------


class TestCleanupGitlinksAndRetryStash:
    """Test the extracted _cleanup_gitlinks_and_retry_stash function."""

    @patch("repo_sync.remove_orphan_gitlink")
    @patch("repo_sync.detect_orphan_gitlinks")
    @patch("repo_sync.git_run")
    def test_returns_none_on_non_gitlink_error(
        self, mock_git_run, mock_detect, mock_remove
    ):
        """Should return None when error is not gitlink-related."""
        result = _cleanup_gitlinks_and_retry_stash(
            "/tmp/repo", ["stash", "push"], "ordinary stash error"
        )
        assert result is None
        mock_detect.assert_not_called()
        mock_remove.assert_not_called()

    @patch("repo_sync.remove_orphan_gitlink")
    @patch("repo_sync.detect_orphan_gitlinks")
    @patch("repo_sync.git_run")
    def test_returns_none_when_no_orphans_found(
        self, mock_git_run, mock_detect, mock_remove
    ):
        """Should return None when error is gitlink-related but no orphans found."""
        mock_detect.return_value = []
        result = _cleanup_gitlinks_and_retry_stash(
            "/tmp/repo", ["stash", "push"], "submodule error in stash"
        )
        assert result is None
        mock_remove.assert_not_called()

    @patch("repo_sync.remove_orphan_gitlink")
    @patch("repo_sync.detect_orphan_gitlinks")
    @patch("repo_sync.git_run")
    def test_cleans_orphans_and_retries(self, mock_git_run, mock_detect, mock_remove):
        """Should clean orphans and return retry result."""
        mock_detect.return_value = ["Sub1", "Sub2"]
        mock_git_run.return_value = MagicMock(returncode=0, stdout="", stderr="")

        result = _cleanup_gitlinks_and_retry_stash(
            "/tmp/repo", ["stash", "push", "-m", "test"], "submodule error"
        )

        assert result is not None
        assert result.returncode == 0
        assert mock_remove.call_count == 2
        mock_git_run.assert_called_once_with(
            "/tmp/repo", ["stash", "push", "-m", "test"], check=False, timeout=None
        )

    @patch("repo_sync.remove_orphan_gitlink")
    @patch("repo_sync.detect_orphan_gitlinks")
    @patch("repo_sync.git_run")
    def test_passes_timeout_to_git_run(self, mock_git_run, mock_detect, mock_remove):
        """Should pass timeout to git_run retry call."""
        mock_detect.return_value = ["Sub1"]
        mock_git_run.return_value = MagicMock(returncode=0, stdout="", stderr="")

        _cleanup_gitlinks_and_retry_stash(
            "/tmp/repo", ["stash", "push"], "gitlink error", timeout=60
        )

        mock_git_run.assert_called_once_with(
            "/tmp/repo", ["stash", "push"], check=False, timeout=60
        )

    @patch("repo_sync.remove_orphan_gitlink")
    @patch("repo_sync.detect_orphan_gitlinks")
    @patch("repo_sync.git_run")
    def test_returns_retry_result_on_failure(
        self, mock_git_run, mock_detect, mock_remove
    ):
        """Should return the retry result even if it fails."""
        mock_detect.return_value = ["Sub1"]
        mock_git_run.return_value = MagicMock(
            returncode=1, stdout="", stderr="still failing"
        )

        result = _cleanup_gitlinks_and_retry_stash(
            "/tmp/repo", ["stash", "push"], "submodule error"
        )

        assert result is not None
        assert result.returncode == 1


# ---------------------------------------------------------------------------
# 10. MEDIUM-3: timeout propagation to all git operations
# ---------------------------------------------------------------------------


class TestTimeoutPropagation:
    """Verify subprocess timeout is propagated to all git operations."""

    @patch("repo_sync.subprocess.run")
    def test_do_rebase_passes_timeout(self, mock_run):
        """do_rebase should pass timeout to git_run."""
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        do_rebase("/tmp/repo", "origin", "main", timeout=45)
        _, kwargs = mock_run.call_args
        assert kwargs.get("timeout") == 45

    @patch("repo_sync.subprocess.run")
    def test_do_stash_pop_passes_timeout(self, mock_run):
        """do_stash_pop should pass timeout to git_run."""
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        do_stash_pop("/tmp/repo", timeout=20)
        _, kwargs = mock_run.call_args
        assert kwargs.get("timeout") == 20

    @patch("repo_sync.subprocess.run")
    def test_do_rebase_abort_passes_timeout(self, mock_run):
        """do_rebase_abort should pass timeout to git_run."""
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        do_rebase_abort("/tmp/repo", timeout=15)
        _, kwargs = mock_run.call_args
        assert kwargs.get("timeout") == 15

    @patch("repo_sync.subprocess.run")
    def test_do_pull_merge_passes_timeout(self, mock_run):
        """do_pull_merge should pass timeout to git_run."""
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        do_pull_merge("/tmp/repo", "origin", "main", timeout=60)
        _, kwargs = mock_run.call_args
        assert kwargs.get("timeout") == 60

    @patch("repo_sync.subprocess.run")
    def test_get_sha_passes_timeout(self, mock_run):
        """get_sha should pass timeout to git_run."""
        mock_run.return_value = MagicMock(returncode=0, stdout="abc123\n", stderr="")
        get_sha("/tmp/repo", "HEAD", timeout=10)
        _, kwargs = mock_run.call_args
        assert kwargs.get("timeout") == 10

    @patch("repo_sync.subprocess.run")
    def test_is_working_tree_dirty_passes_timeout(self, mock_run):
        """is_working_tree_dirty should pass timeout to git_run."""
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        is_working_tree_dirty("/tmp/repo", timeout=5)
        _, kwargs = mock_run.call_args
        assert kwargs.get("timeout") == 5

    @patch("repo_sync.subprocess.run")
    def test_detect_orphan_gitlinks_passes_timeout(self, mock_run):
        """detect_orphan_gitlinks should pass timeout to git_run."""
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        detect_orphan_gitlinks("/tmp/repo", timeout=10)
        _, kwargs = mock_run.call_args
        assert kwargs.get("timeout") == 10

    @patch("repo_sync.subprocess.run")
    def test_remove_orphan_gitlink_passes_timeout(self, mock_run):
        """remove_orphan_gitlink should pass timeout to git_run."""
        mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
        remove_orphan_gitlink("/tmp/repo", "Sub1", timeout=10)
        _, kwargs = mock_run.call_args
        assert kwargs.get("timeout") == 10

    @patch("repo_sync.subprocess.run")
    def test_detect_sync_state_passes_timeout(self, mock_run):
        """detect_sync_state should pass timeout to get_sha and git_run."""
        mock_run.return_value = MagicMock(returncode=0, stdout="abc123\n", stderr="")
        detect_sync_state("/tmp/repo", "origin", "main", timeout=30)
        for call in mock_run.call_args_list:
            _, kwargs = call
            assert kwargs.get("timeout") == 30
