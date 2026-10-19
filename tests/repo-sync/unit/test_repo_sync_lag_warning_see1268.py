#!/usr/bin/env python3
"""SEE-1268 (a): SYNCED steady-state submodule lag warning (repo-sync).

`run_sync`'s SYNCED branch, after `do_submodule_update` succeeds, compares
each `.gitmodules` submodule's remote branch head vs the parent index gitlink:
differing → single-line `logger.warning` (never blocks, never success=False);
network failure / missing branch → silently skipped; same remote head → dedup
(state-file recorded) so the same lag is not re-warned every 5s cycle.
"""

import json
import logging
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "repo-sync"))
os.environ.setdefault("GIT_CONFIG_COUNT", "1")
os.environ.setdefault("GIT_CONFIG_KEY_0", "protocol.file.allow")
os.environ.setdefault("GIT_CONFIG_VALUE_0", "always")

from repo_sync import run_sync  # noqa: E402


def _g(cwd, args, check=False):
    return subprocess.run(
        ["git", "-c", "protocol.file.allow=always"] + args,
        cwd=cwd, capture_output=True, text=True, check=check,
    )


def _make_lagging_project(behind: bool):
    """Parent-with-submodule where the child's remote is ahead of the gitlink
    (behind=True) or equal (behind=False)."""
    d = tempfile.mkdtemp()
    sub = os.path.join(d, "sub.git"); os.makedirs(sub)
    _g(sub, ["init", "--bare", "-b", "master"], check=True)
    seed = os.path.join(d, "seed"); os.makedirs(seed)
    _g(seed, ["init", "-b", "master"], check=True)
    # SEE-1381 §SPEC-016: local identity — CI runners have none globally.
    _g(seed, ["config", "user.email", "t@t.com"])
    _g(seed, ["config", "user.name", "T"])
    Path(seed, "f").write_text("v1\n")
    _g(seed, ["add", "f"]); _g(seed, ["commit", "-m", "v1"], check=True)
    _g(seed, ["remote", "add", "origin", sub])
    _g(seed, ["push", "origin", "master:refs/heads/master"], check=True)

    parent = os.path.join(d, "parent"); os.makedirs(parent)
    _g(parent, ["init", "-b", "master"], check=True)
    _g(parent, ["config", "user.email", "t@t.com"])
    _g(parent, ["config", "user.name", "T"])
    Path(parent, "p").write_text("p\n")
    _g(parent, ["add", "p"]); _g(parent, ["commit", "-m", "p"], check=True)
    _g(parent, ["submodule", "add", sub, "vendor/sub"], check=True)
    _g(parent, ["commit", "-m", "add sub"], check=True)
    remote = os.path.join(d, "parent.git"); os.makedirs(remote)
    _g(remote, ["init", "--bare", "-b", "master"], check=True)
    _g(parent, ["remote", "add", "origin", remote])
    _g(parent, ["push", "origin", "master:refs/heads/master"], check=True)

    if behind:
        # Advance the child's remote so the parent's recorded gitlink is behind.
        Path(seed, "f").write_text("v2\n")
        _g(seed, ["commit", "-am", "v2"], check=True)
        _g(seed, ["push", "origin", "master:refs/heads/master"], check=True)

    return {"dir": d, "parent": parent, "remote": remote}


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


class TestSyncLagWarning:
    def test_lagging_submodule_warns_but_does_not_block(self, tmp_path, caplog):
        fx = _make_lagging_project(behind=True)
        with caplog.at_level(logging.WARNING, logger="repo_sync"):
            result = run_sync(
                _sync_config(fx["parent"], tmp_path),
                logging.getLogger("repo_sync"),
                dry_run=False,
            )
        assert result["success"] is True, result["message"]
        assert "already synced" in result["message"]
        warns = [r.message for r in caplog.records if r.levelno >= logging.WARNING]
        assert any("vendor/sub" in w and "differs" in w for w in warns), warns

    def test_up_to_date_no_warning(self, tmp_path, caplog):
        fx = _make_lagging_project(behind=False)
        with caplog.at_level(logging.WARNING, logger="repo_sync"):
            result = run_sync(
                _sync_config(fx["parent"], tmp_path),
                logging.getLogger("repo_sync"),
                dry_run=False,
            )
        assert result["success"] is True
        warns = [r.message for r in caplog.records
                 if r.levelno >= logging.WARNING and "differs" in r.message]
        assert warns == [], warns

    def test_same_remote_head_dedupes_repeat_cycles(self, tmp_path, caplog):
        fx = _make_lagging_project(behind=True)
        cfg = _sync_config(fx["parent"], tmp_path)
        log = logging.getLogger("repo_sync")
        with caplog.at_level(logging.WARNING, logger="repo_sync"):
            run_sync(cfg, log, dry_run=False)
        first = [r.message for r in caplog.records
                 if "differs" in r.message and "vendor/sub" in r.message]
        assert first, "first cycle must warn once"
        caplog.clear()
        with caplog.at_level(logging.WARNING, logger="repo_sync"):
            run_sync(cfg, log, dry_run=False)
        second = [r.message for r in caplog.records
                  if "differs" in r.message and "vendor/sub" in r.message]
        assert second == [], f"same remote head must not re-warn: {second}"

    def test_network_failure_silent_skip(self, tmp_path, monkeypatch):
        # Unresolvable remote → skip warning entirely, never crash the cycle.
        fx = _make_lagging_project(behind=False)
        _g(fx["parent"], ["config", "-f", ".gitmodules",
                          "submodule.vendor/sub.url", "/nonexistent/x.git"])
        result = run_sync(
            _sync_config(fx["parent"], tmp_path),
            logging.getLogger("repo_sync"),
            dry_run=False,
        )
        assert result["success"] is True, result["message"]

    def test_no_gitmodules_zero_engagement(self, tmp_path, caplog):
        plain = tmp_path / "plain"; plain.mkdir()
        _g(str(plain), ["init", "-b", "master"], check=True)
        _g(str(plain), ["config", "user.email", "t@t.com"])
        _g(str(plain), ["config", "user.name", "T"])
        Path(str(plain), "x").write_text("x\n")
        _g(str(plain), ["add", "x"]); _g(str(plain), ["commit", "-m", "x"], check=True)
        remote = tmp_path / "plain.git"; remote.mkdir()
        _g(str(remote), ["init", "--bare", "-b", "master"], check=True)
        _g(str(plain), ["remote", "add", "origin", str(remote)])
        _g(str(plain), ["push", "origin", "master:refs/heads/master"], check=True)
        with caplog.at_level(logging.WARNING, logger="repo_sync"):
            result = run_sync(
                _sync_config(str(plain), tmp_path),
                logging.getLogger("repo_sync"),
                dry_run=False,
            )
        assert result["success"] is True
        warns = [r.message for r in caplog.records if "differs" in r.message]
        assert warns == []
