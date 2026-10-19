#!/usr/bin/env python3
"""SEE-1268 follow-up: submodule materialization must be self-healing on every
sync cycle, not just on the pull/push transition.

Two gaps found in production (D-drive master lost addons/godot_mcp/plugin.cfg):

  1. STEADY-STATE GAP — run_sync's `SYNCED` branch returns early, so a repo
     already at the remote head never (re)materializes submodules. If the
     working copy arrived at the submodule state through any path that skipped
     `git submodule update` (an older daemon build, a manual pull), it stays
     broken forever.
  2. MIGRATION RESIDUE — the vendored→submodule switch leaves the old files on
     disk; `git submodule update --init` then refuses to clone into a non-empty
     directory and fails every cycle. The recovery must move the residue aside
     (reversible) and retry, and must never fail silently.
"""

import logging
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "repo-sync"))

# Production `git_run` passes no -c flags and these fixtures use local-path
# remotes; expose the CVE-2022-39253 opt-out as an env config layer so every
# git child process (including submodule clones) accepts file:// transports.
os.environ.setdefault("GIT_CONFIG_COUNT", "1")
os.environ.setdefault("GIT_CONFIG_KEY_0", "protocol.file.allow")
os.environ.setdefault("GIT_CONFIG_VALUE_0", "always")

from repo_sync import do_submodule_update, has_submodule_changes, run_sync

# Reuse the fixture builders from the SEE-1268 suite to avoid drift.
sys.path.insert(0, os.path.dirname(__file__))
from test_repo_sync_submodule_see1268 import (  # noqa: E402
    _init_repo_with_submodule,
    _run_git,
)


@pytest.fixture
def repo_with_submodule():
    with tempfile.TemporaryDirectory() as d:
        repo = _init_repo_with_submodule(d)
        # Production `git_run` does not pass -c flags, and these fixtures use
        # local-path remotes; persist the CVE-2022-39253 opt-out as repo config
        # so submodule clones spawned by git_run succeed in the test env.
        _run_git(repo["local"], ["config", "protocol.file.allow", "always"])
        _run_git(repo["local"], ["submodule", "update", "--init", "--recursive"])
        yield repo


def _strip_submodule(repo: str, path: str = "vendor/subtool") -> str:
    """Leave the migration residue behind: unregister + clear the module dir,
    then put an untracked file where the submodule should be cloned."""
    _run_git(repo, ["submodule", "deinit", "-f", path])
    shutil.rmtree(os.path.join(repo, ".git", "modules", "vendor"), ignore_errors=True)
    shutil.rmtree(os.path.join(repo, path), ignore_errors=True)
    os.makedirs(os.path.join(repo, path), exist_ok=True)
    Path(repo, path, "old_vendored_file.gd").write_text("# residue\n")
    return os.path.join(repo, path)


def _sync_config(repo: str, tmp_path) -> dict:
    return {
        "repo_path": repo,
        "remote": "origin",
        "branch": "master",
        "log_dir": str(tmp_path / "logs"),
        "state_file": str(tmp_path / "state.json"),
        "lock_file": str(tmp_path / "sync.lock"),
        "stash_on_dirty": True,
    }


class TestSteadyStateMaterialization:
    """Gap 1: an already-SYNCED repo must still get its submodules materialized."""

    def test_synced_repo_with_missing_submodule_is_repaired(self, repo_with_submodule, tmp_path):
        local = repo_with_submodule["local"]
        _strip_submodule(local)
        assert has_submodule_changes(local), "pre-state must read as '-' uninitialized"

        result = run_sync(_sync_config(local, tmp_path), logging.getLogger("t"), dry_run=False)

        assert result["success"], result["message"]
        assert "already synced" in result["message"]
        tool = Path(local, "vendor", "subtool", "tool.py")
        assert tool.is_file(), "SYNCED cycle must materialize submodule content"
        assert not has_submodule_changes(local)

    def test_synced_repo_is_idempotent_when_already_materialized(self, repo_with_submodule, tmp_path):
        local = repo_with_submodule["local"]
        result = run_sync(_sync_config(local, tmp_path), logging.getLogger("t"), dry_run=False)
        assert result["success"], result["message"]
        assert Path(local, "vendor", "subtool", "tool.py").is_file()


class TestMigrationResidueRecovery:
    """Gap 2: non-empty submodule dir + cleared module registration must recover."""

    def test_residue_blocked_init_is_recovered_by_moving_aside(self, repo_with_submodule):
        local = repo_with_submodule["local"]
        sub_path = _strip_submodule(local)

        # First, prove the naive call fails (the production symptom).
        naive = do_submodule_update(local)
        assert naive[0] is True, "do_submodule_update must self-heal, not fail"
        assert Path(sub_path, "tool.py").is_file()

    def test_residue_is_moved_aside_not_deleted(self, repo_with_submodule):
        local = repo_with_submodule["local"]
        _strip_submodule(local)

        ok, msg = do_submodule_update(local)
        assert ok, msg
        # The residue must survive somewhere (reversible recovery — never destroy).
        survivors = list(Path(local).rglob("old_vendored_file.gd"))
        assert survivors, "residue file must be preserved in a backup, not deleted"

    def test_recovery_reports_what_it_moved(self, repo_with_submodule):
        local = repo_with_submodule["local"]
        _strip_submodule(local)

        ok, msg = do_submodule_update(local)
        assert ok
        assert "residue" in msg.lower(), f"message must name the recovery: {msg}"

    def test_unrelated_failure_is_still_reported_not_hidden(self, repo_with_submodule):
        """A failure that is NOT residue-related must surface, not be masked."""
        local = repo_with_submodule["local"]
        # Point the submodule at a non-existent origin: not a residue case.
        _run_git(local, ["config", "-f", ".gitmodules",
                         "submodule.vendor/subtool.url", "/nonexistent/repo.git"])
        _run_git(local, ["submodule", "deinit", "-f", "vendor/subtool"])
        shutil.rmtree(os.path.join(local, ".git", "modules", "vendor"), ignore_errors=True)

        ok, msg = do_submodule_update(local)
        assert ok is False, "a genuine fetch failure must NOT be reported as success"
        assert "nonexistent" in msg or "failed" in msg.lower()
