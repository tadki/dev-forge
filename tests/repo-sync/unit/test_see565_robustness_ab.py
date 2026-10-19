#!/usr/bin/env python3
"""
A/B Test for SEE-565 repo sync robustness improvements.

Compares pre-fix vs post-fix behavior for key scenarios:
  A (pre-fix): orphan gitlink → stash fails → sync halts
  B (post-fix): orphan gitlink → stash fails → auto-cleanup → retry → sync succeeds

Uses mocks to simulate the gitlink-related stash failure that occurs in production
but is difficult to reproduce in test environments.
"""

import os
import subprocess
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "repo-sync"))

from repo_sync import (
    detect_orphan_gitlinks,
    remove_orphan_gitlink,
    do_stash_if_dirty,
    _try_stash_with_recovery,
    git_run,
)


def _run_git(cwd, args, check=True):
    return subprocess.run(
        ["git"] + args,
        cwd=cwd,
        capture_output=True,
        text=True,
        check=check,
    )


def _make_repo(tmp_path, name="repo"):
    """Create a minimal git repo with initial commit."""
    repo = str(tmp_path / name)
    os.makedirs(repo)
    _run_git(repo, ["init", "-b", "master"])
    _run_git(repo, ["config", "user.email", "test@test.com"])
    _run_git(repo, ["config", "user.name", "Test"])
    Path(os.path.join(repo, "a.txt")).write_text("a")
    _run_git(repo, ["add", "a.txt"])
    _run_git(repo, ["commit", "-m", "init"])
    return repo


def _add_orphan_gitlink(repo, name="FakeSubmodule"):
    """Add an orphan gitlink to the repo index."""
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


# ---------------------------------------------------------------------------
# A/B Test 1: Orphan gitlink stash failure (mocked)
# ---------------------------------------------------------------------------


class TestABOrphanGitlinkStash:
    """A/B test: stash behavior with gitlink error, using mocks."""

    def test_a_pre_fix_no_recovery(self, tmp_path):
        """A (pre-fix simulation): Without recovery, stash fails on gitlink error.

        Simulates pre-fix behavior: when stash encounters "could not write index"
        and recovery=False, it returns failure without attempting cleanup.
        """
        repo = _make_repo(tmp_path)
        Path(os.path.join(repo, "dirty.txt")).write_text("dirty")

        original_git_run = git_run
        call_count = {"n": 0}

        def mock_git_run(repo_path, args, check=True, timeout=None):
            if "stash" in args and "push" in args:
                call_count["n"] += 1
                r = MagicMock()
                r.returncode = 1
                r.stderr = "error: could not write index"
                return r
            return original_git_run(repo_path, args, check=check, timeout=timeout)

        with patch("repo_sync.git_run", side_effect=mock_git_run):
            ok, msg, had_stash = do_stash_if_dirty(
                repo, stash_on_dirty=True, recovery=False
            )
        assert ok is False
        assert "stash failed" in msg

    def test_b_post_fix_with_recovery(self, tmp_path):
        """B (post-fix): With recovery, gitlink cleanup allows stash to succeed."""
        repo = _make_repo(tmp_path)
        _add_orphan_gitlink(repo)
        Path(os.path.join(repo, "dirty.txt")).write_text("dirty")

        original_git_run = git_run
        call_count = {"n": 0}

        def mock_git_run(repo_path, args, check=True, timeout=None):
            if "stash" in args and "push" in args:
                call_count["n"] += 1
                if call_count["n"] == 1:
                    r = MagicMock()
                    r.returncode = 1
                    r.stderr = "error: could not write index"
                    return r
            return original_git_run(repo_path, args, check=check, timeout=timeout)

        with patch("repo_sync.git_run", side_effect=mock_git_run):
            ok, msg, had_stash = do_stash_if_dirty(
                repo, stash_on_dirty=True, recovery=True
            )
        assert ok is True
        assert "gitlink cleanup" in msg

    def test_behavior_diff(self, tmp_path):
        """Direct comparison: recovery=True produces success where recovery=False fails."""
        # Scenario A: no recovery → fails
        repo_a = _make_repo(tmp_path, "repo_a")
        Path(os.path.join(repo_a, "dirty.txt")).write_text("dirty")

        def mock_fail_stash(repo_path, args, check=True, timeout=None):
            if "stash" in args and "push" in args:
                r = MagicMock()
                r.returncode = 1
                r.stderr = "error: could not write index"
                return r
            return git_run(repo_path, args, check=check, timeout=timeout)

        with patch("repo_sync.git_run", side_effect=mock_fail_stash):
            ok_a, msg_a, _ = do_stash_if_dirty(
                repo_a, stash_on_dirty=True, recovery=False
            )

        # Scenario B: with recovery → succeeds (detects orphans, cleans, retries)
        repo_b = _make_repo(tmp_path, "repo_b")
        _add_orphan_gitlink(repo_b)
        Path(os.path.join(repo_b, "dirty.txt")).write_text("dirty")

        original_git_run = git_run
        call_count = {"n": 0}

        def mock_fail_then_succeed(repo_path, args, check=True, timeout=None):
            if "stash" in args and "push" in args:
                call_count["n"] += 1
                if call_count["n"] == 1:
                    r = MagicMock()
                    r.returncode = 1
                    r.stderr = "error: could not write index"
                    return r
            return original_git_run(repo_path, args, check=check, timeout=timeout)

        with patch("repo_sync.git_run", side_effect=mock_fail_then_succeed):
            ok_b, msg_b, _ = do_stash_if_dirty(
                repo_b, stash_on_dirty=True, recovery=True
            )

        assert ok_a is False, "Pre-fix: stash should fail without recovery"
        assert ok_b is True, "Post-fix: stash should succeed with recovery"


# ---------------------------------------------------------------------------
# A/B Test 2: _try_stash_with_recovery vs raw do_stash_if_dirty
# ---------------------------------------------------------------------------


class TestABStashRecoveryHelper:
    """A/B test: _try_stash_with_recovery vs calling do_stash_if_dirty directly."""

    def test_a_direct_stash_fails_on_gitlink_error(self, tmp_path):
        """A: Direct stash with recovery=False fails on gitlink error."""
        repo = _make_repo(tmp_path)
        Path(os.path.join(repo, "dirty.txt")).write_text("dirty")

        def mock_fail_stash(repo_path, args, check=True, timeout=None):
            if "stash" in args and "push" in args:
                r = MagicMock()
                r.returncode = 1
                r.stderr = "error: could not write index"
                return r
            return git_run(repo_path, args, check=check, timeout=timeout)

        with patch("repo_sync.git_run", side_effect=mock_fail_stash):
            ok, msg, had_stash = do_stash_if_dirty(
                repo, stash_on_dirty=True, recovery=False
            )
        assert ok is False

    def test_b_stash_with_recovery_helper_succeeds(self, tmp_path):
        """B: _try_stash_with_recovery auto-detects and cleans gitlinks."""
        repo = _make_repo(tmp_path)
        _add_orphan_gitlink(repo)
        Path(os.path.join(repo, "dirty.txt")).write_text("dirty")

        original_git_run = git_run
        call_count = {"n": 0}

        def mock_git_run(repo_path, args, check=True, timeout=None):
            if "stash" in args and "push" in args:
                call_count["n"] += 1
                if call_count["n"] == 1:
                    r = MagicMock()
                    r.returncode = 1
                    r.stderr = "error: could not write index"
                    return r
            return original_git_run(repo_path, args, check=check, timeout=timeout)

        with patch("repo_sync.git_run", side_effect=mock_git_run):
            ok, msg, had_stash = _try_stash_with_recovery(repo, stash_on_dirty=True)
        assert ok is True


# ---------------------------------------------------------------------------
# A/B Test 3: Gitlink detection exists where it didn't before
# ---------------------------------------------------------------------------


class TestABGitlinkDetection:
    """A/B test: verify detect_orphan_gitlinks identifies problems pre-sync."""

    def test_clean_repo_no_orphans(self, tmp_path):
        """Clean repo should report zero orphans."""
        repo = _make_repo(tmp_path)
        assert detect_orphan_gitlinks(repo) == []

    def test_repo_with_orphan_detected(self, tmp_path):
        """Repo with orphan gitlink should be detectable."""
        repo = _make_repo(tmp_path)
        _add_orphan_gitlink(repo)
        orphans = detect_orphan_gitlinks(repo)
        assert len(orphans) == 1
        assert orphans[0] == "FakeSubmodule"

    def test_orphan_removed_clean(self, tmp_path):
        """After removal, detect_orphan_gitlinks returns empty."""
        repo = _make_repo(tmp_path)
        _add_orphan_gitlink(repo)
        orphans = detect_orphan_gitlinks(repo)
        assert len(orphans) > 0

        ok, msg = remove_orphan_gitlink(repo, orphans[0])
        assert ok is True

        assert detect_orphan_gitlinks(repo) == []
