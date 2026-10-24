#!/usr/bin/env python3
"""SEE-476: submodule module-config self-heal (runtime) + boot precheck (daemon).

Three same-root-cause circuit-breaker incidents (2026-09-22 / 10-23 / 10-24):
an abnormal power cut left a size-correct but all-0x00 module config on the
NTFS/9p checkout; every sync cycle then died on
`fatal: bad config line 1 in file .git/modules/addons/godot_mcp/config`
until the breaker tripped at 10/10. The thrice-validated manual fix — backup
the corrupt file, rebuild core section + relative worktree + remote.origin
(url from the parent .git/config), retry — is automated here.

Two directions pinned by the DoD:
  A. corrupt config → self-heal → retry succeeds (cycle success, no breaker)
  B. non-parse failure → NO self-heal (normal persistent accounting intact)
"""

import inspect
import json
import logging
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "repo-sync"))

# Local-path submodule remotes need the CVE-2022-39253 opt-out (git >= 2.38.1),
# both as env config layer and persisted repo config (fixtures are trusted).
os.environ.setdefault("GIT_CONFIG_COUNT", "1")
os.environ.setdefault("GIT_CONFIG_KEY_0", "protocol.file.allow")
os.environ.setdefault("GIT_CONFIG_VALUE_0", "always")

from repo_sync import (  # noqa: E402
    classify_error,
    do_submodule_update,
    is_module_config_parse_failure,
    precheck_module_configs,
    repair_module_config,
    run_sync,
)
from repo_sync_daemon import run_one_cycle  # noqa: E402

# Reuse the fixture builders from the SEE-1268 suite to avoid drift.
sys.path.insert(0, os.path.dirname(__file__))
from test_repo_sync_submodule_see1268 import (  # noqa: E402
    _init_repo_with_submodule,
    _run_git,
)

LOGGER = logging.getLogger("repo_sync")
MODULE_CONFIG_REL = Path(".git") / "modules" / "vendor" / "subtool" / "config"


@pytest.fixture
def repo_with_submodule():
    with tempfile.TemporaryDirectory() as d:
        repo = _init_repo_with_submodule(d)
        _run_git(repo["local"], ["config", "protocol.file.allow", "always"])
        _run_git(repo["local"], ["submodule", "update", "--init", "--recursive"])
        yield repo


def _module_config(repo: dict) -> Path:
    return Path(repo["local"]) / MODULE_CONFIG_REL


def _corrupt_like_power_cut(cfg: Path) -> None:
    """Reproduce the incident: size-correct, all-0x00 content."""
    cfg.write_bytes(b"\x00" * cfg.stat().st_size)


def _corrupt_backups(cfg: Path) -> list[Path]:
    return sorted(cfg.parent.glob("config.corrupt-*"))


def _sync_config(repo: dict, tmp_path: Path) -> dict:
    return {
        "repo_path": repo["local"],
        "remote": "origin",
        "branch": "master",
        "log_dir": str(tmp_path / "logs"),
        "state_file": str(tmp_path / "state.json"),
        "lock_file": str(tmp_path / "sync.lock"),
        "stash_on_dirty": True,
    }


class TestRuntimeSelfHeal:
    def test_corrupt_config_selfheals_and_retry_succeeds(self, repo_with_submodule):
        cfg = _module_config(repo_with_submodule)
        _corrupt_like_power_cut(cfg)

        ok, msg = do_submodule_update(repo_with_submodule["local"], logger=LOGGER)

        assert ok, msg
        assert "self-heal" in msg
        # git accepts the rebuilt config again
        _run_git(repo_with_submodule["local"], ["submodule", "status"])
        # corrupt original preserved as backup (forensic copy, never deleted)
        backups = _corrupt_backups(cfg)
        assert len(backups) == 1
        assert backups[0].read_bytes() == b"\x00" * len(backups[0].read_bytes())
        # rebuilt structure carries the verified essentials
        content = cfg.read_text()
        assert "[core]" in content
        assert "worktree = " in content
        assert '[remote "origin"]' in content
        assert "url = " in content
        # rebuilt url points at the registered submodule remote
        assert repo_with_submodule["sub_remote"] in content

    def test_selfheal_paths_logged_for_grep(self, repo_with_submodule, caplog):
        cfg = _module_config(repo_with_submodule)
        _corrupt_like_power_cut(cfg)

        with caplog.at_level(logging.DEBUG, logger="repo_sync"):
            ok, _ = do_submodule_update(repo_with_submodule["local"], logger=LOGGER)

        assert ok
        text = caplog.text
        # DoD: grep-able log lines naming BOTH the corrupt file and the backup
        assert str(cfg) in text
        assert "config.corrupt-" in text
        assert "backed up" in text
        assert "rebuilt" in text

    def test_full_sync_cycle_success_after_selfheal_no_error_category(
        self, repo_with_submodule, tmp_path
    ):
        """DoD: corrupt → self-heal → the cycle itself succeeds (success=true,
        no error_category → daemon does not increment the breaker)."""
        cfg = _module_config(repo_with_submodule)
        _corrupt_like_power_cut(cfg)
        config = _sync_config(repo_with_submodule, tmp_path)

        result = run_sync(config, LOGGER)

        assert result["success"] is True, result["message"]
        assert "error_category" not in result
        state = json.loads(Path(config["state_file"]).read_text())
        assert state["success"] is True

    def test_non_parse_failure_does_not_trigger_selfheal(
        self, repo_with_submodule
    ):
        """DoD direction B: a non-parse persistent failure (unreachable remote)
        must NOT be healed away — no backup, no rewrite, failure propagates."""
        cfg = _module_config(repo_with_submodule)
        # Record a NEW submodule sha via a throwaway clone: the child worktree
        # never receives the objects, so `submodule update` MUST fetch (an
        # unchanged sha is a local no-op and would never touch the network).
        local = repo_with_submodule["local"]
        throwaway = str(Path(local).parent / "see476-bump-clone")
        # cwd must pre-exist for subprocess; the clone target is created by git
        _run_git(str(Path(local).parent), ["clone", "--quiet", repo_with_submodule["sub_remote"], throwaway])
        _run_git(throwaway, ["config", "user.email", "test@test.com"])
        _run_git(throwaway, ["config", "user.name", "Test"])
        Path(throwaway, "tool.py").write_text("TOOL_V2 = 2\n")
        _run_git(throwaway, ["add", "tool.py"])
        _run_git(throwaway, ["commit", "-m", "sub v2"])
        _run_git(throwaway, ["push", "origin", "master"])
        new_sha = _run_git(throwaway, ["rev-parse", "HEAD"]).stdout.strip()
        _run_git(local, ["update-index", "--cacheinfo", f"160000,{new_sha},vendor/subtool"])
        _run_git(local, ["commit", "-m", "bump submodule pointer"])
        rerouted = "/nonexistent/see476-sub.git"
        _run_git(local, ["config", "--file", str(cfg), "remote.origin.url", rerouted])
        before = cfg.read_bytes()

        ok, msg = do_submodule_update(repo_with_submodule["local"], logger=LOGGER)

        assert not ok
        assert "self-heal" not in msg
        assert _corrupt_backups(cfg) == []
        assert cfg.read_bytes() == before

    def test_repair_without_url_fails_explicitly_and_keeps_file(
        self, repo_with_submodule
    ):
        """No source of truth for the url → explicit failure, corrupt file
        untouched (never silently rewrite without a verified url)."""
        cfg = _module_config(repo_with_submodule)
        _corrupt_like_power_cut(cfg)
        gm = Path(repo_with_submodule["local"]) / ".gitmodules"
        gm.write_text('[submodule "vendor/subtool"]\n\tpath = vendor/subtool\n')
        _run_git(
            repo_with_submodule["local"],
            ["config", "--unset", "submodule.vendor/subtool.url"],
        )

        ok, msg = repair_module_config(repo_with_submodule["local"], cfg, LOGGER)

        assert not ok
        assert "no submodule url found" in msg
        assert set(cfg.read_bytes()) == {0}
        assert _corrupt_backups(cfg) == []

    def test_parse_failure_classification_stays_persistent(self):
        """If self-heal fails, the leftover message must still classify as
        persistent (the failure class is never masked as transient)."""
        msg = (
            "submodule update --init --recursive failed: fatal: bad config line 1 "
            "in file /repo/.git/modules/addons/godot_mcp/config; "
            "module-config self-heal failed: no submodule url found"
        )
        assert classify_error(msg) == "persistent"


class TestParseFailureDetection:
    def test_detects_incident_signature_with_absolute_path(self):
        err = (
            "fatal: bad config line 1 in file "
            "/mnt/d/repo/.git/modules/addons/godot_mcp/config"
        )
        assert is_module_config_parse_failure(err) == (
            "/mnt/d/repo/.git/modules/addons/godot_mcp/config"
        )

    def test_detects_relative_path_form(self):
        err = "fatal: bad config line 1 in file .git/modules/addons/godot_mcp/config"
        assert is_module_config_parse_failure(err) == (
            ".git/modules/addons/godot_mcp/config"
        )

    def test_ignores_non_parse_failures(self):
        assert is_module_config_parse_failure(
            "fatal: could not read from remote repository."
        ) is None
        assert is_module_config_parse_failure(
            "error: pathspec 'x' did not match any file(s) known to git"
        ) is None
        assert is_module_config_parse_failure("") is None
        assert is_module_config_parse_failure(
            "fatal: bad config line 1 in file /repo/.git/config"  # NOT a module config
        ) == "/repo/.git/config"  # detection is textual; scope guard lives in repair


class TestBootPrecheck:
    def test_precheck_repairs_corrupt_config(self, repo_with_submodule):
        cfg = _module_config(repo_with_submodule)
        _corrupt_like_power_cut(cfg)

        repaired = precheck_module_configs(repo_with_submodule["local"], LOGGER)

        assert repaired == [str(cfg)]
        _run_git(repo_with_submodule["local"], ["submodule", "status"])
        assert len(_corrupt_backups(cfg)) == 1

    def test_precheck_leaves_healthy_config_alone(self, repo_with_submodule):
        cfg = _module_config(repo_with_submodule)
        before = cfg.read_bytes()

        repaired = precheck_module_configs(repo_with_submodule["local"], LOGGER)

        assert repaired == []
        assert cfg.read_bytes() == before
        assert _corrupt_backups(cfg) == []

    def test_precheck_tolerates_missing_module_dir(self, repo_with_submodule):
        """Uninitialized submodule (no .git/modules entry yet) is materializa-
        tion's job, not corruption — precheck must skip it, not crash."""
        import shutil

        shutil.rmtree(
            Path(repo_with_submodule["local"]) / ".git" / "modules" / "vendor",
            ignore_errors=True,
        )

        repaired = precheck_module_configs(repo_with_submodule["local"], LOGGER)

        assert repaired == []


class TestDaemonWiring:
    def test_boot_precheck_runs_before_first_cycle(self):
        """Pin: daemon main() calls the precheck after startup, before the
        sync loop (DoD: 损坏配置在首周期前已修复)."""
        sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "repo-sync"))
        import repo_sync_daemon as daemon

        src = inspect.getsource(daemon.main)
        assert "precheck_module_configs" in src
        assert src.index("precheck_module_configs") < src.index("while _running")

    def test_corrupted_repo_full_daemon_cycle_succeeds(
        self, repo_with_submodule, tmp_path
    ):
        """DoD end-to-end: corrupt config → run_one_cycle (the daemon's actual
        per-cycle primitive, subprocess included) → ok=True, category=''."""
        cfg = _module_config(repo_with_submodule)
        _corrupt_like_power_cut(cfg)
        config = _sync_config(repo_with_submodule, tmp_path)
        config_path = tmp_path / "sync-config.json"
        config_path.write_text(json.dumps(config))
        sync_script = str(
            Path(__file__).resolve().parents[3] / "repo-sync" / "repo_sync.py"
        )

        ok, category = run_one_cycle(
            sync_script, config, str(config_path), LOGGER, timeout=120
        )

        assert ok is True
        assert category == ""
        assert len(_corrupt_backups(cfg)) == 1
        assert cfg.read_text().startswith("[core]")
