#!/usr/bin/env python3
"""SEE-894 A/B test: repo-sync REMOTE_AHEAD pull visibility.

Verifies Refacty's Phase B root-cause claim independently, using fully
isolated temp clones (never the real /mnt/d/GodotProjects/king-of-likes/ repo):

  A (before fix, commit 583741f): REMOTE_AHEAD pull executes and advances the
    local SHA, BUT repo_sync.py emits zero `pull success` lines to stdout, so
    the daemon (which captures stdout via subprocess) shows `grep -c pull == 0`.
  B (after fix, commit df4db67): the same scenario logs `pull success` to stdout,
    so the daemon log reflects the operation.

Key invariant proven by the A leg: pull was *already* running correctly; the bug
was purely log visibility, exactly as Refacty reported. Proven by the B leg: the
two added `logger.info` calls surface the result on stdout.

Both legs drive real `git` over throwaway (local + bare remote) temp repos under
pytest tmp_path. No main-repo access, no origin/master push, no shared /tmp state.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# Source-tree root: this file is <root>/.dev/tests/abtest/test_see894_*.py
SOURCE_ROOT = Path(__file__).resolve().parents[3]
FIX_HEAD_AFTER = SOURCE_ROOT / "repo-sync" / "repo_sync.py"
FIX_COMMIT_BEFORE = "583741f"  # parent of f7e718b (the logging fix)

# CI/checkout must expose git history so we can extract the pre-fix script.
REQUIRES_GIT_HISTORY = True


def _run_git(cwd: str, args: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", cwd] + args,
        capture_output=True, text=True, check=check,
        encoding="utf-8", errors="replace",
    )


def _make_temp_sync_repo(root: Path) -> dict[str, str]:
    """Independent (local clone + bare remote) pair, discarded with tmp_path."""
    root.mkdir(parents=True, exist_ok=True)
    remote = root / "remote.git"
    local = root / "local"
    remote.mkdir(parents=True, exist_ok=True)
    local.mkdir(parents=True, exist_ok=True)
    _run_git(str(remote), ["init", "--bare", "-b", "master"])
    _run_git(str(local), ["init", "-b", "master"])
    _run_git(str(local), ["config", "user.email", "qa@test.com"])
    _run_git(str(local), ["config", "user.name", "QA"])
    (local / "README.md").write_text("init\n")
    _run_git(str(local), ["add", "README.md"])
    _run_git(str(local), ["commit", "-m", "init"])
    _run_git(str(local), ["remote", "add", "origin", str(remote)])
    _run_git(str(local), ["push", "-u", "origin", "master"])
    return {"local": str(local), "remote": str(remote), "root": str(root)}


def _make_remote_ahead(repo: dict[str, str], tag: str) -> str:
    """Push a commit to the bare remote via a second clone, then fetch in local
    so local is behind origin/master (REMOTE_AHEAD). Returns the remote SHA."""
    clone = os.path.join(repo["root"], "clone_remote")
    os.makedirs(clone)
    _run_git(clone, ["clone", repo["remote"], "."])
    _run_git(clone, ["config", "user.email", "qa@test.com"])
    _run_git(clone, ["config", "user.name", "QA"])
    Path(clone, f"remote_{tag}.txt").write_text(f"remote change {tag}\n")
    _run_git(clone, ["add", f"remote_{tag}.txt"])
    _run_git(clone, ["commit", "-m", f"remote: {tag}"])
    _run_git(clone, ["push"])
    remote_sha = _run_git(clone, ["rev-parse", "origin/master"]).stdout.strip()
    _run_git(repo["local"], ["fetch", "origin"])
    return remote_sha


def _write_config(repo: dict[str, str], root: Path) -> str:
    cfg = {
        "repo_path": repo["local"],
        "remote": "origin",
        "branch": "master",
        "log_dir": str(root / "logs"),
        "state_file": str(root / "state.json"),
        "lock_file": str(root / "sync.lock"),
        "pid_file": str(root / "daemon.pid"),
        "stash_on_dirty": True,
        "conflict_resolution_strategy": "rebase_first",
        "daemon_poll_interval_seconds": 1,
        "daemon_max_consecutive_failures": 3,
        "daemon_backoff_max_seconds": 10,
        "subprocess_timeout_seconds": 30,
    }
    p = root / "repo_sync_config.json"
    p.write_text(json.dumps(cfg))
    return str(p)


def _run_sync(script_path: str, config_path: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, script_path, "--config", config_path, "--lock-timeout", "10"],
        capture_output=True, text=True,
        encoding="utf-8", errors="replace", timeout=30,
    )


def _extract_prefix_script(dest: Path) -> str | None:
    """Extract repo_sync.py at FIX_COMMIT_BEFORE into dest. Returns path or None
    if the git object is unavailable (shallow checkout)."""
    r = subprocess.run(
        ["git", "-C", str(SOURCE_ROOT), "show", f"{FIX_COMMIT_BEFORE}:.dev/repo_sync.py"],
        capture_output=True,
    )
    if r.returncode != 0:
        return None
    dest.write_bytes(r.stdout)
    return str(dest)


# ---------------------------------------------------------------------------
# A/B scenarios
# ---------------------------------------------------------------------------


class TestSee894PullLoggingAB:
    """Independent A/B verification of the SEE-894 pull-logging fix."""

    def test_a_before_fix_pull_runs_but_is_invisible(self, tmp_path: Path) -> None:
        """A leg: before the fix, pull STILL executes (SHA advances) but stdout
        carries zero `pull success` lines — the daemon visibility bug."""
        pre_script = _extract_prefix_script(tmp_path / "repo_sync_before.py")
        if pre_script is None:
            pytest.skip(f"pre-fix script at {FIX_COMMIT_BEFORE} unavailable (shallow checkout)")

        repo = _make_temp_sync_repo(tmp_path / "A")
        repo_root = tmp_path / "A"
        remote_sha = _make_remote_ahead(repo, "a")
        local_before = _run_git(repo["local"], ["rev-parse", "master"]).stdout.strip()
        assert local_before != remote_sha, "fixture broken: local should be behind"

        cfg_path = _write_config(repo, repo_root)
        r = _run_sync(pre_script, cfg_path)

        assert r.returncode == 0, f"pre-fix sync failed: {r.stdout}\n{r.stderr}"
        # Pull really executed even before the fix (proves root cause = visibility)
        local_after = _run_git(repo["local"], ["rev-parse", "master"]).stdout.strip()
        assert local_after == remote_sha, (
            "A leg expected pull to advance local SHA to remote — pull must run pre-fix"
        )

        pull_lines = [ln for ln in r.stdout.splitlines() if "pull success" in ln.lower()]
        assert pull_lines == [], (
            "A leg (pre-fix) must emit ZERO `pull success` stdout lines — that is the bug.\n"
            f"got: {pull_lines}"
        )

    def test_b_after_fix_pull_is_visible(self, tmp_path: Path) -> None:
        """B leg: after the fix, pull executes AND `pull success` lands on stdout."""
        repo = _make_temp_sync_repo(tmp_path / "B")
        repo_root = tmp_path / "B"
        remote_sha = _make_remote_ahead(repo, "b")
        local_before = _run_git(repo["local"], ["rev-parse", "master"]).stdout.strip()
        assert local_before != remote_sha, "fixture broken: local should be behind"

        cfg_path = _write_config(repo, repo_root)
        r = _run_sync(str(FIX_HEAD_AFTER), cfg_path)

        assert r.returncode == 0, f"post-fix sync failed: {r.stdout}\n{r.stderr}"
        local_after = _run_git(repo["local"], ["rev-parse", "master"]).stdout.strip()
        assert local_after == remote_sha, "B leg: pull must advance local SHA to remote"

        pull_lines = [ln for ln in r.stdout.splitlines() if "pull success" in ln.lower()]
        assert len(pull_lines) >= 1, (
            "B leg (post-fix) must emit at least one `pull success` stdout line.\n"
            f"stdout was: {r.stdout!r}"
        )

    def test_grep_pull_count_ab_delta(self, tmp_path: Path) -> None:
        """Directly demonstrates the `grep -c pull == 0` -> `>= 1` transition
        that the daemon log relies on, in one place."""
        pre_script = _extract_prefix_script(tmp_path / "repo_sync_before.py")
        if pre_script is None:
            pytest.skip(f"pre-fix script at {FIX_COMMIT_BEFORE} unavailable")

        # A
        repo_a = _make_temp_sync_repo(tmp_path / "GA")
        _make_remote_ahead(repo_a, "ga")
        r_a = _run_sync(pre_script, _write_config(repo_a, tmp_path / "GA"))
        count_a = sum(1 for ln in r_a.stdout.splitlines() if "pull success" in ln.lower())

        # B
        repo_b = _make_temp_sync_repo(tmp_path / "GB")
        _make_remote_ahead(repo_b, "gb")
        r_b = _run_sync(str(FIX_HEAD_AFTER), _write_config(repo_b, tmp_path / "GB"))
        count_b = sum(1 for ln in r_b.stdout.splitlines() if "pull success" in ln.lower())

        assert count_a == 0, f"pre-fix must grep 0 pull-success lines, got {count_a}"
        assert count_b >= 1, f"post-fix must grep >=1 pull-success lines, got {count_b}"


# ---------------------------------------------------------------------------
# Daemon log visibility: confirm the daemon actually relays stdout -> its log
# ---------------------------------------------------------------------------


class TestSee894DaemonRelaysPullSuccess:
    """Run one real daemon cycle in a temp clone and confirm
    `pull success` lands in repo-sync-daemon.log."""

    def test_daemon_log_contains_pull_success(self, tmp_path: Path) -> None:
        import shutil
        import time

        repo = _make_temp_sync_repo(tmp_path / "DAEMON")
        repo_root = tmp_path / "DAEMON"
        remote_sha = _make_remote_ahead(repo, "d")

        # Daemon resolves the sync script relative to its own location, so copy
        # the post-fix repo_sync.py + daemon into the temp clone's
        # .dev/repo-sync/ layout (SEE-1195 moved the trio out of .dev root).
        local_dev = Path(repo["local"]) / ".dev" / "repo-sync"
        local_dev.mkdir(parents=True, exist_ok=True)
        shutil.copy(FIX_HEAD_AFTER, local_dev / "repo_sync.py")
        shutil.copy(SOURCE_ROOT / "repo-sync" / "repo_sync_daemon.py", local_dev / "repo_sync_daemon.py")

        cfg = {
            "repo_path": repo["local"],
            "remote": "origin",
            "branch": "master",
            "log_dir": str(repo_root / "logs"),
            "state_file": str(repo_root / "state.json"),
            "lock_file": str(repo_root / "sync.lock"),
            "pid_file": str(repo_root / "daemon.pid"),
            "stash_on_dirty": True,
            "conflict_resolution_strategy": "rebase_first",
            "daemon_poll_interval_seconds": 1,
            "daemon_max_consecutive_failures": 3,
            "daemon_backoff_max_seconds": 10,
            "subprocess_timeout_seconds": 30,
        }
        cfg_path = local_dev / "repo_sync_config.json"
        cfg_path.write_text(json.dumps(cfg))

        daemon_log = Path(cfg["log_dir"]) / "repo-sync-daemon.log"
        daemon_log.parent.mkdir(parents=True, exist_ok=True)

        proc = subprocess.Popen(
            [sys.executable, str(local_dev / "repo_sync_daemon.py"), "--config", str(cfg_path)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            # One daemon poll is 1s; give it two cycles to run the sync.
            deadline = time.time() + 8
            while time.time() < deadline:
                if daemon_log.exists() and "pull success" in daemon_log.read_text(errors="replace").lower():
                    break
                time.sleep(0.3)
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()

        assert daemon_log.exists(), "daemon never wrote its log"
        log_text = daemon_log.read_text(errors="replace")
        assert "pull success" in log_text.lower(), (
            "daemon log must contain `pull success` after a REMOTE_AHEAD cycle.\n"
            f"log:\n{log_text}"
        )
        # And the local clone really advanced.
        local_after = _run_git(repo["local"], ["rev-parse", "master"]).stdout.strip()
        assert local_after == remote_sha, "daemon cycle must advance local SHA"
