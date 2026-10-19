"""Unit test: repo_sync should prune stale remote refs when fetching.

SEE-1033: after remote agent/* branches are bulk-deleted, a local repo still
shows stale remotes/origin/agent/* tracking refs unless fetch uses --prune.
The repo_sync daemon currently uses `git fetch remote` without --prune, so
this test documents the gap and drives a fix.
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

import pytest


def _run(cmd: list[str], cwd: Path, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd, cwd=str(cwd), check=check, capture_output=True, text=True, timeout=30
    )


@pytest.mark.unit
def test_repo_sync_fetch_without_prune_leaves_stale_agent_refs():
    """Current repo_sync.git_fetch uses 'git fetch remote' (no --prune).

    After origin deletes an agent/* branch, the local remote-tracking ref
    remotes/origin/agent/<X> remains. This is the VS Code symptom reported
    in SEE-1033.
    """
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        remote = tmp_path / "remote.git"
        local = tmp_path / "local"
        remote.mkdir()
        local.mkdir()

        _run(["git", "init", "--bare", str(remote)], cwd=tmp_path)
        _run(["git", "clone", str(remote), str(local)], cwd=tmp_path)
        _run(["git", "config", "user.email", "t@example.com"], cwd=local)
        _run(["git", "config", "user.name", "Test"], cwd=local)

        (local / "README.md").write_text("x\n")
        _run(["git", "add", "README.md"], cwd=local)
        _run(["git", "commit", "-m", "init"], cwd=local)
        _run(["git", "push", "origin", "master"], cwd=local)

        # Create agent branch on remote
        _run(["git", "checkout", "-b", "agent/chekky/abc123"], cwd=local)
        (local / "agent.txt").write_text("y\n")
        _run(["git", "add", "agent.txt"], cwd=local)
        _run(["git", "commit", "-m", "agent work"], cwd=local)
        _run(["git", "push", "origin", "agent/chekky/abc123"], cwd=local)
        _run(["git", "checkout", "master"], cwd=local)

        # Simulate bulk deletion on remote (from another clone)
        other = tmp_path / "other"
        _run(["git", "clone", str(remote), str(other)], cwd=tmp_path)
        _run(["git", "push", "origin", "--delete", "agent/chekky/abc123"], cwd=other)

        # Existing local repo still has stale tracking ref after fetch without --prune
        _run(["git", "fetch", "origin"], cwd=local)
        stale = _run(["git", "branch", "-a"], cwd=local, check=False).stdout
        assert "remotes/origin/agent/chekky/abc123" in stale, (
            "stale remote-tracking ref should remain after fetch without --prune"
        )


@pytest.mark.unit
def test_fetch_with_prune_removes_stale_agent_refs():
    """Baseline verification that git fetch --prune cleans stale refs."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        remote = tmp_path / "remote.git"
        local = tmp_path / "local"
        remote.mkdir()
        local.mkdir()

        _run(["git", "init", "--bare", str(remote)], cwd=tmp_path)
        _run(["git", "clone", str(remote), str(local)], cwd=tmp_path)
        _run(["git", "config", "user.email", "t@example.com"], cwd=local)
        _run(["git", "config", "user.name", "Test"], cwd=local)

        (local / "README.md").write_text("x\n")
        _run(["git", "add", "README.md"], cwd=local)
        _run(["git", "commit", "-m", "init"], cwd=local)
        _run(["git", "push", "origin", "master"], cwd=local)

        _run(["git", "checkout", "-b", "agent/chekky/abc123"], cwd=local)
        (local / "agent.txt").write_text("y\n")
        _run(["git", "add", "agent.txt"], cwd=local)
        _run(["git", "commit", "-m", "agent work"], cwd=local)
        _run(["git", "push", "origin", "agent/chekky/abc123"], cwd=local)
        _run(["git", "checkout", "master"], cwd=local)
        _run(["git", "push", "origin", "--delete", "agent/chekky/abc123"], cwd=local)

        fresh = tmp_path / "fresh"
        _run(["git", "clone", str(remote), str(fresh)], cwd=tmp_path)
        _run(["git", "fetch", "origin", "--prune"], cwd=fresh)

        stale = _run(["git", "branch", "-a"], cwd=fresh, check=False).stdout
        assert "remotes/origin/agent/chekky/abc123" not in stale


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
