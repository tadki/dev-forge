#!/usr/bin/env python3
"""SEE-1268: repo-sync must carry submodule content alongside pointer sync.

do_pull_ff_only (REMOTE_AHEAD) and run_sync's push/DIVERGED bodies must run
`git submodule update --init --recursive` after the pointer-level git op
succeeds. A `-` (uninitialized) submodule must be auto-initialized so the
daemon's has_submodule_changes() guard never wedges the sync loop.
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

from repo_sync import do_pull_ff_only, do_submodule_update, has_submodule_changes, run_sync


def _run_git(cwd, args, check=True):
    # protocol.file.allow=always: git ≥2.38.1 blocks file:// submodule clones
    # (CVE-2022-39253 fix); local-path test fixtures are trusted, so re-allow.
    return subprocess.run(
        ["git", "-c", "protocol.file.allow=always"] + args,
        cwd=cwd,
        capture_output=True,
        text=True,
        check=check,
    )


def _make_child_repo(tmp: str) -> str:
    """Create the submodule's canonical BARE repo (mirrors a real origin)."""
    sub_remote = os.path.join(tmp, "sub.git")
    os.makedirs(sub_remote)
    _run_git(sub_remote, ["init", "--bare", "-b", "master"])

    # Seed it from a scratch worktree (non-bare repos refuse pushes to their
    # checked-out branch, so all pushes go to the bare repo).
    seed = os.path.join(tmp, "sub-seed")
    os.makedirs(seed)
    _run_git(seed, ["init", "-b", "master"])
    _run_git(seed, ["config", "user.email", "test@test.com"])
    _run_git(seed, ["config", "user.name", "Test"])
    Path(os.path.join(seed, "tool.py")).write_text("TOOL_V1 = 1\n")
    _run_git(seed, ["add", "tool.py"])
    _run_git(seed, ["commit", "-m", "sub v1"])
    _run_git(seed, ["remote", "add", "origin", sub_remote])
    _run_git(seed, ["push", "origin", "master"])
    return sub_remote


def _init_repo_with_submodule(tmp: str) -> dict:
    """Build remote-bare + local-with-one-submodule and push to remote."""
    remote = os.path.join(tmp, "remote.git")
    sub_remote = _make_child_repo(tmp)
    local = os.path.join(tmp, "local")

    os.makedirs(remote)
    _run_git(remote, ["init", "--bare", "-b", "master"])

    os.makedirs(local)
    _run_git(local, ["init", "-b", "master"])
    _run_git(local, ["config", "user.email", "test@test.com"])
    _run_git(local, ["config", "user.name", "Test"])
    Path(os.path.join(local, "a.txt")).write_text("a")
    _run_git(local, ["add", "a.txt"])
    _run_git(local, ["commit", "-m", "init"])

    _run_git(local, ["submodule", "add", sub_remote, "vendor/subtool"])
    _run_git(local, ["commit", "-m", "add submodule"])
    _run_git(local, ["remote", "add", "origin", remote])
    _run_git(local, ["push", "-u", "origin", "master"])

    return {"remote": remote, "sub_remote": sub_remote, "local": local}


def _bump_submodule_via(clone: str, sub_path: str, text: str, message: str) -> None:
    """Commit text to the submodule inside `clone`, bump the parent pointer.

    `submodule update --init` leaves the child detached — reattach to master
    before committing, or the commit lands off-branch and pushes nothing.
    """
    _run_git(sub_path, ["checkout", "master"])
    # SEE-1381 §SPEC-016: the submodule checkout is a fresh clone — clones do
    # NOT inherit user identity, and CI runners have none globally.
    _run_git(sub_path, ["config", "user.email", "test@test.com"])
    _run_git(sub_path, ["config", "user.name", "Test"])
    Path(os.path.join(sub_path, "tool.py")).write_text(text)
    _run_git(sub_path, ["add", "tool.py"])
    _run_git(sub_path, ["commit", "-m", message])
    _run_git(sub_path, ["push", "origin", "master"])
    _run_git(clone, ["add", "vendor/subtool"])
    _run_git(clone, ["commit", "-m", message])
    _run_git(clone, ["push", "origin", "master"])


@pytest.fixture
def repo_with_submodule():
    with tempfile.TemporaryDirectory() as d:
        repo = _init_repo_with_submodule(d)
        # `submodule add` leaves the child checked out, but hand tests a
        # canonical fully-materialized state anyway (update is idempotent).
        _run_git(repo["local"], ["submodule", "update", "--init", "--recursive"])
        yield repo


class TestDoSubmoduleUpdate:
    def test_noop_without_gitmodules(self, tmp_path):
        plain = tmp_path / "plain"
        plain.mkdir()
        _run_git(str(plain), ["init", "-b", "master"])
        ok, msg = do_submodule_update(str(plain))
        assert ok is True
        assert "no submodules" in msg

    def test_initializes_uninitialized_submodule(self, repo_with_submodule):
        local = repo_with_submodule["local"]
        sub_path = os.path.join(local, "vendor", "subtool")
        # Simulate a fresh checkout: deinit (drops the worktree + .git pointer
        # file, keeps the index gitlink + .gitmodules) then remove leftovers.
        _run_git(local, ["submodule", "deinit", "-f", "vendor/subtool"])
        shutil.rmtree(sub_path, ignore_errors=True)

        assert has_submodule_changes(local), "deinit must read as '-' intermediate"

        ok, msg = do_submodule_update(local)
        assert ok, f"do_submodule_update failed: {msg}"
        assert Path(sub_path, "tool.py").is_file(), "submodule content must be materialized"
        assert not has_submodule_changes(local)

    def test_updates_content_when_pointer_moves(self, repo_with_submodule):
        local = repo_with_submodule["local"]
        sub_path = os.path.join(local, "vendor", "subtool")
        tool_file = Path(sub_path, "tool.py")
        sub_remote = repo_with_submodule["sub_remote"]

        # Advance the submodule origin, then record the new pointer locally.
        seed = os.path.join(os.path.dirname(local), "sub-seed")
        _run_git(seed, ["checkout", "master"])
        Path(os.path.join(seed, "tool.py")).write_text("TOOL_V2 = 2\n")
        _run_git(seed, ["add", "tool.py"])
        _run_git(seed, ["commit", "-m", "sub v2"])
        _run_git(seed, ["push", "origin", "master"])
        # Point the local child at origin's tip, bump the parent pointer, then
        # roll the child's checkout back so pointer is AHEAD of content.
        _run_git(sub_path, ["fetch", "origin"])
        _run_git(sub_path, ["checkout", "origin/master"])
        _run_git(local, ["add", "vendor/subtool"])
        _run_git(local, ["commit", "-m", "bump pointer"])
        _run_git(sub_path, ["checkout", "HEAD~1"])

        assert tool_file.read_text() == "TOOL_V1 = 1\n"
        ok, msg = do_submodule_update(local)
        assert ok, f"do_submodule_update failed: {msg}"
        assert tool_file.read_text() == "TOOL_V2 = 2\n"


class TestPullCarriesSubmodule:
    def test_pull_ff_only_updates_submodule_content(self, repo_with_submodule):
        remote, local = repo_with_submodule["remote"], repo_with_submodule["local"]

        # Clone2 (simulating the D-drive master role): remote gains a commit
        # that ALSO bumps the submodule pointer. The old tool.py content must
        # land locally after do_pull_ff_only — pointer alone is not enough.
        clone = os.path.join(os.path.dirname(remote), "clone2")
        os.makedirs(clone)
        _run_git(clone, ["clone", remote, "."])
        _run_git(clone, ["submodule", "update", "--init"])
        _run_git(clone, ["config", "user.email", "test@test.com"])
        _run_git(clone, ["config", "user.name", "Test"])
        Path(os.path.join(clone, "new.txt")).write_text("new")

        _bump_submodule_via(
            clone, os.path.join(clone, "vendor", "subtool"), "TOOL_V2 = 2\n", "bump to v2"
        )

        ok, msg = do_pull_ff_only(local, "origin", "master", stash_on_dirty=False)
        assert ok, f"pull failed: {msg}"
        tool_file = Path(local, "vendor", "subtool", "tool.py")
        assert tool_file.is_file()
        assert tool_file.read_text() == "TOOL_V2 = 2\n", (
            "submodule content must follow the new pointer after pull"
        )
        assert not has_submodule_changes(local)


class TestRunSyncCarriesSubmodule:
    def test_remote_ahead_sync_brings_submodule_content(self, repo_with_submodule, tmp_path):
        remote, local = repo_with_submodule["remote"], repo_with_submodule["local"]

        clone = os.path.join(os.path.dirname(remote), "clone3")
        os.makedirs(clone)
        _run_git(clone, ["clone", remote, "."])
        _run_git(clone, ["submodule", "update", "--init"])
        _run_git(clone, ["config", "user.email", "test@test.com"])
        _run_git(clone, ["config", "user.name", "Test"])
        _bump_submodule_via(
            clone, os.path.join(clone, "vendor", "subtool"), "TOOL_V3 = 3\n", "bump to v3"
        )

        config = {
            "repo_path": local,
            "remote": "origin",
            "branch": "master",
            "log_dir": str(tmp_path / "logs"),
            "state_file": str(tmp_path / "state.json"),
            "lock_file": str(tmp_path / "sync.lock"),
            "stash_on_dirty": True,
        }
        result = run_sync(config, logging.getLogger("test"), dry_run=False)
        assert result["success"], result["message"]

        tool_file = Path(local, "vendor", "subtool", "tool.py")
        assert tool_file.read_text() == "TOOL_V3 = 3\n"
        assert not has_submodule_changes(local)
