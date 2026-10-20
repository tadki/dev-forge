"""A/B test for SEE-869 branch guard daemon-level behavior.

Compares behaviour of run_sync across multiple daemon-like cycles when the
local repo drifts off master between cycles:

  A (pre-fix / guard disabled):  repo drifts to a feature branch -> subsequent
                                  syncs operate on the wrong branch and never
                                  recover; daemon effectively corrupts state.
  B (post-fix / guard enabled):   repo drifts to a feature branch -> next
                                  cycle's branch guard switches back to master
                                  before sync, and sync succeeds.

This test NEVER touches /mnt/d/GodotProjects/king-of-likes/. All git work runs
against temporary repositories created inside the test.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any
from unittest.mock import patch

import pytest

_REPO_SYNC_DIR = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "..", "repo-sync")
)
_REPO_SYNC_SCRIPT = os.path.join(_REPO_SYNC_DIR, "repo_sync.py")

sys.path.insert(0, _REPO_SYNC_DIR)

import repo_sync  # noqa: E402
from repo_sync import (  # noqa: E402
    Direction,
    get_current_branch,
    run_sync,
)


def _run_git(cwd: str, args: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", cwd] + args,
        capture_output=True,
        text=True,
        check=check,
        encoding="utf-8",
        errors="replace",
    )


@pytest.fixture
def drift_repo(tmp_path: Path):
    """Create a local repo with a feature branch off master."""
    remote = tmp_path / "remote.git"
    local = tmp_path / "local"
    remote.mkdir()
    local.mkdir()

    _run_git(str(remote), ["init", "--bare", "-b", "master"])
    _run_git(str(local), ["init", "-b", "master"])
    _run_git(str(local), ["config", "user.email", "test@test.com"])
    _run_git(str(local), ["config", "user.name", "Test"])
    _run_git(str(local), ["config", "protocol.file.allow", "always"])

    (local / "a.txt").write_text("a")
    _run_git(str(local), ["add", "a.txt"])
    _run_git(str(local), ["commit", "-m", "init"])
    _run_git(str(local), ["remote", "add", "origin", str(remote)])
    _run_git(str(local), ["push", "origin", "HEAD:refs/heads/master"])

    return {
        "local": str(local),
        "remote": str(remote),
        "root": str(tmp_path),
    }


def _config(repo: str, tmp_path: Path) -> dict[str, Any]:
    return {
        "repo_path": repo,
        "remote": "origin",
        "branch": "master",
        "log_dir": str(tmp_path / "logs"),
        "state_file": str(tmp_path / "state.json"),
        "lock_file": str(tmp_path / "sync.lock"),
        "pid_file": str(tmp_path / "daemon.pid"),
        "stash_on_dirty": True,
        "conflict_resolution_strategy": "rebase_first",
        "daemon_poll_interval_seconds": 1,
        "daemon_max_consecutive_failures": 5,
    }


class _QuietLogger:
    def debug(self, *a, **k): pass
    def info(self, *a, **k): pass
    def warning(self, *a, **k): pass
    def error(self, *a, **k): pass


def _disable_branch_guard(*args, **kwargs):
    """Stub for ensure_on_registered_branch — pretends the repo is aligned."""
    return True, "guard disabled (A baseline)", False


# ---------------------------------------------------------------------------
# A / B comparison: cycle 1 stays synced, drift happens before cycle 2.
# ---------------------------------------------------------------------------


class TestDaemonBranchGuardAB:
    def test_a_baseline_drift_does_not_recover_without_guard(self, drift_repo, tmp_path: Path) -> None:
        """Baseline: with the guard disabled, a drifted repo stays drifted
        across multiple cycles and sync operates on the wrong branch."""
        repo = drift_repo["local"]
        config = _config(repo, tmp_path)
        logger = _QuietLogger()

        # Cycle 1: synced -> no-op
        with patch.object(repo_sync, "ensure_on_registered_branch", _disable_branch_guard):
            result = run_sync(config, logger)
        assert result["success"] is True

        # External operation: drift the local repo to a feature branch
        _run_git(repo, ["checkout", "-b", "feature/drifted"])
        (Path(repo) / "feature.txt").write_text("feature work")
        _run_git(repo, ["add", "feature.txt"])
        _run_git(repo, ["commit", "-m", "feature work"])

        # Cycle 2: with the guard disabled, the repo stays on feature branch.
        # The sync reports success because there is nothing to do (LOCAL_AHEAD
        # of origin/master only if master moved; here master did not move so
        # detect_sync_state uses the current branch's HEAD against origin/master,
        # which compares correctly regardless of checked-out branch — but the
        # guard never ran, so the repo remains on feature/drifted.)
        with patch.object(repo_sync, "ensure_on_registered_branch", _disable_branch_guard):
            result = run_sync(config, logger)

        # The local repo should still be on feature/drifted (guard never ran)
        assert get_current_branch(repo) == "feature/drifted", (
            "A baseline: drift should persist when guard is disabled"
        )

    def test_b_with_guard_drift_auto_recovers_across_cycles(self, drift_repo, tmp_path: Path) -> None:
        """With guard enabled, a drifted repo is recovered back to master
        across multiple cycles."""
        repo = drift_repo["local"]
        config = _config(repo, tmp_path)
        logger = _QuietLogger()

        # Cycle 1: synced -> no-op
        result = run_sync(config, logger)
        assert result["success"] is True
        assert get_current_branch(repo) == "master"

        # External operation: drift the repo to feature branch + dirty tree
        _run_git(repo, ["checkout", "-b", "feature/recoverable"])
        (Path(repo) / "uncommitted.txt").write_text("dirty change")
        dirty_content = (Path(repo) / "uncommitted.txt").read_text()

        # Cycle 2: guard should switch back to master (preserving the dirty tree
        # via stash+pop) and complete the sync.
        result = run_sync(config, logger)
        assert result["success"] is True, f"cycle 2 failed: {result}"
        assert get_current_branch(repo) == "master", (
            "guard should have switched back to master"
        )
        # Dirty file should be restored after stash pop
        restored = (Path(repo) / "uncommitted.txt").read_text()
        assert restored == dirty_content, "dirty tree should be preserved"

        # Cycle 3: repo stays on master, sync is idempotent
        result = run_sync(config, logger)
        assert result["success"] is True
        assert get_current_branch(repo) == "master"


# ---------------------------------------------------------------------------
# Multi-cycle end-to-end via repo_sync.py CLI (simulates daemon subprocess).
# ---------------------------------------------------------------------------


class TestDaemonMultiCycleCLI:
    def _run_one_cycle(self, config_path: Path) -> subprocess.CompletedProcess[str]:
        repo_path = json.loads(config_path.read_text())["repo_path"]
        return subprocess.run(
            [sys.executable, _REPO_SYNC_SCRIPT,
             "--config", str(config_path), "--lock-timeout", "10"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=60,
        )

    def test_multi_cycle_recovers_after_external_drift(
        self, drift_repo, tmp_path: Path
    ) -> None:
        repo = drift_repo["local"]
        config = _config(repo, tmp_path)
        config_path = tmp_path / "repo_sync_config.json"
        config_path.write_text(json.dumps(config))

        # Cycle 1: synced
        r = self._run_one_cycle(config_path)
        assert r.returncode == 0, f"cycle 1 failed: {r.stdout}\n{r.stderr}"
        assert get_current_branch(repo) == "master"

        # External drift: switch to feature branch and add a tracked file
        _run_git(repo, ["checkout", "-b", "feature/multi"])
        (Path(repo) / "drift.txt").write_text("drifted")
        _run_git(repo, ["add", "drift.txt"])
        _run_git(repo, ["commit", "-m", "drift commit"])

        # Cycle 2: guard must switch back to master and proceed.
        r = self._run_one_cycle(config_path)
        assert r.returncode == 0, f"cycle 2 failed: {r.stdout}\n{r.stderr}"
        assert get_current_branch(repo) == "master", (
            "guard should have restored master in cycle 2"
        )

        # The drift.txt commit lives on feature/multi branch, not master.
        # master should remain clean and synced with origin/master.
        _run_git(repo, ["fetch", "origin"])
        assert _run_git(repo, ["rev-parse", "master"]).stdout.strip() == \
               _run_git(repo, ["rev-parse", "origin/master"]).stdout.strip()

        # Cycle 3: stays on master, idempotent
        r = self._run_one_cycle(config_path)
        assert r.returncode == 0
        assert get_current_branch(repo) == "master"

    def test_transient_drift_does_not_count_against_circuit_breaker(
        self, drift_repo, tmp_path: Path
    ) -> None:
        """Repeated transient branch-guard failures (e.g. worktree occupation)
        should NOT be counted toward the daemon circuit breaker."""
        repo = drift_repo["local"]
        config = _config(repo, tmp_path)
        config_path = tmp_path / "repo_sync_config.json"
        config_path.write_text(json.dumps(config))

        # Make master occupied by another worktree, then drift repo off master.
        other_wt = str(tmp_path / "other-wt")
        _run_git(repo, ["checkout", "-b", "feature/wt-occupied"])
        _run_git(repo, ["worktree", "add", other_wt, "master"])
        try:
            # Run 4 consecutive cycles — each should report a transient skip.
            # daemon_max_consecutive_failures is 5; transient failures must not
            # accumulate even though cycle count exceeds 0.
            categories: list[str] = []
            for _ in range(4):
                r = self._run_one_cycle(config_path)
                assert r.returncode == 1, (
                    f"cycle should report failure (transient skip): {r.stdout}"
                )
                state = json.loads(Path(config["state_file"]).read_text())
                categories.append(state.get("error_category", "persistent"))

            assert all(c == "transient" for c in categories), (
                f"all categories should be transient, got {categories}"
            )
            assert get_current_branch(repo) == "feature/wt-occupied", (
                "transient skip must not mutate the repo"
            )
        finally:
            _run_git(repo, ["worktree", "remove", "--force", other_wt], check=False)
