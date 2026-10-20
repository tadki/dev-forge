"""E2E integration coverage for local_repo_check.py (SEE-889).

Sets up a temporary Multica-style workspace with four worktree directories
inside it, each backed by a real git repo wired to a local bare origin:

- A: clean + fully pushed   → should be auto-deleted (dry-run only)
- B: clean + unpushed       → needs a push/abort decision
- C: dirty                  → needs a changes/abort decision
- D: current worktree       → skipped as "current_worktree"

The script is executed via subprocess with `--dry-run` so no real deletion
ever occurs. Tests assert:
1. Correct categorization in the JSON output.
2. Dry-run never actually removes any worktree directory.
3. The [DRY_RUN] Phase 2 skipped message is emitted.
4. No multica CLI call is required (issue_id is left empty in all metadata).
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots"))

import pytest

SCRIPT = os.path.abspath(os.path.join(
    os.path.dirname(__file__), "..", "..", "autopilots", "local_repo_check.py"
))


def _git(*args, cwd=None, check=True):
    cmd = ["git", *args]
    result = subprocess.run(
        cmd, cwd=cwd, check=check,
        capture_output=True, text=True,
        encoding="utf-8", errors="replace",
        timeout=30,
    )
    return result


def _write_commit(workdir, filename, message):
    path = os.path.join(workdir, filename)
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"{filename}\n")
    _git("add", filename, cwd=workdir)
    _git("commit", "-m", message, cwd=workdir)


def _build_workspace(tmpdir):
    """Return (workspace_root, hashes dict)."""
    workspace = os.path.join(tmpdir, "workspace")
    os.makedirs(workspace)

    origin = os.path.join(tmpdir, "origin.git")
    _git("init", "--bare", origin)

    hashes = {
        "clean_pushed": "aaaa1111aaaa1111aaaa1111aaaa1111",
        "unpushed": "bbbb2222bbbb2222bbbb2222bbbb2222",
        "dirty": "cccc3333cccc3333cccc3333cccc3333",
        "current": "dddd4444dddd4444dddd4444dddd4444",
    }

    def _make_repo(name, branch, unpushed=False, dirty=False):
        repo_dir = os.path.join(workspace, name, "workdir")
        os.makedirs(repo_dir)
        _git("init", cwd=repo_dir)
        _git("remote", "add", "origin", origin, cwd=repo_dir)
        _git("checkout", "-b", branch, cwd=repo_dir)
        _write_commit(repo_dir, "initial.txt", "Initial commit")
        _git("push", "-u", "origin", branch, cwd=repo_dir)
        if unpushed:
            _write_commit(repo_dir, "unpushed.txt", "Unpushed commit")
        if dirty:
            # SEE-956 H4：实现已排除 untracked（`??`），dirty 判定只看 tracked
            # 变更；用例改用 tracked 修改构造（先提交基线再修改）。
            dirty_file = os.path.join(repo_dir, "dirty.txt")
            with open(dirty_file, "w", encoding="utf-8") as f:
                f.write("committed baseline\n")
            _git("add", "dirty.txt", cwd=repo_dir)
            _git("commit", "-m", "add dirty.txt", cwd=repo_dir)
            with open(dirty_file, "w", encoding="utf-8") as f:
                f.write("local changes\n")
        return repo_dir

    _make_repo(hashes["clean_pushed"], "feat/see889-clean-pushed")
    _make_repo(hashes["unpushed"], "feat/see889-unpushed", unpushed=True)
    _make_repo(hashes["dirty"], "feat/see889-dirty", dirty=True)

    # Current worktree: has a workdir directory but no repo; script skips it
    # before doing any git work.
    os.makedirs(os.path.join(workspace, hashes["current"], "workdir"))

    return workspace, hashes


@pytest.fixture
def workspace(tmp_path_factory):
    tmpdir = tmp_path_factory.mktemp("local_repo_check_see889")
    workspace_root, hashes = _build_workspace(str(tmpdir))
    yield workspace_root, hashes
    shutil.rmtree(str(tmpdir), ignore_errors=True)


def _run_script(workspace_root, current_hash):
    env = os.environ.copy()
    env["PYTHONPATH"] = os.path.dirname(SCRIPT)
    result = subprocess.run(
        [sys.executable, SCRIPT,
         "--workspace-root", workspace_root,
         "--current-hash", current_hash,
         "--dry-run"],
        env=env,
        capture_output=True, text=True,
        encoding="utf-8", errors="replace",
        timeout=60,
    )
    return result


class TestLocalRepoCheckDryRun:
    def test_exit_code_zero_and_valid_json(self, workspace):
        ws_root, hashes = workspace
        result = _run_script(ws_root, hashes["current"])
        assert result.returncode == 0, result.stderr
        data = json.loads(result.stdout)
        assert data["total_worktrees"] == 4

    def test_clean_pushed_categorized_as_dry_run_deleted(self, workspace):
        ws_root, hashes = workspace
        result = _run_script(ws_root, hashes["current"])
        data = json.loads(result.stdout)
        deleted = data["deleted_worktrees"]
        target = [e for e in deleted if e.get("hash") == hashes["clean_pushed"]]
        assert len(target) == 1, (
            f"Expected clean+pushed worktree in deleted_worktrees, got: {deleted}"
        )
        assert target[0]["delete_status"] == "dry_run"
        assert target[0]["branch"] == "feat/see889-clean-pushed"
        assert target[0]["unpushed_commits"] == 0

    def test_dry_run_never_removes_directories(self, workspace):
        ws_root, hashes = workspace
        result = _run_script(ws_root, hashes["current"])
        assert result.returncode == 0
        for name in hashes.values():
            assert os.path.isdir(os.path.join(ws_root, name, "workdir")), (
                f"Dry-run removed directory for {name}"
            )

    def test_unpushed_categorized_as_need_push_decision(self, workspace):
        ws_root, hashes = workspace
        data = json.loads(_run_script(ws_root, hashes["current"]).stdout)
        entries = [e for e in data["need_push_decision"] if e.get("hash") == hashes["unpushed"]]
        assert len(entries) == 1, data["need_push_decision"]
        assert entries[0]["unpushed_commits"] == 1
        assert entries[0]["branch"] == "feat/see889-unpushed"

    def test_dirty_categorized_as_need_changes_decision(self, workspace):
        ws_root, hashes = workspace
        data = json.loads(_run_script(ws_root, hashes["current"]).stdout)
        entries = [e for e in data["need_changes_decision"] if e.get("hash") == hashes["dirty"]]
        assert len(entries) == 1, data["need_changes_decision"]
        assert "dirty.txt" in entries[0]["git_status_summary"]
        assert entries[0]["branch"] == "feat/see889-dirty"

    def test_current_worktree_is_skipped(self, workspace):
        ws_root, hashes = workspace
        data = json.loads(_run_script(ws_root, hashes["current"]).stdout)
        no_repo = [e for e in data["no_repo"] if e.get("hash") == hashes["current"]]
        assert len(no_repo) == 1, data["no_repo"]
        assert no_repo[0].get("skipped") is True
        assert no_repo[0].get("skip_reason") == "current_worktree"

    def test_phase_two_skipped_in_dry_run(self, workspace):
        ws_root, hashes = workspace
        result = _run_script(ws_root, hashes["current"])
        assert "[DRY_RUN] Phase 2 skipped" in result.stderr

    def test_no_multica_invoked_when_issue_id_empty(self, workspace):
        # With empty issue_id the script should not call `multica issue get`,
        # so the test passes even when no multica CLI is installed.
        ws_root, hashes = workspace
        env = os.environ.copy()
        env["PATH"] = "/tmp/no_multica_bin_exists:" + env.get("PATH", "")
        env["PYTHONPATH"] = os.path.dirname(SCRIPT)
        result = subprocess.run(
            [sys.executable, SCRIPT,
             "--workspace-root", ws_root,
             "--current-hash", hashes["current"],
             "--dry-run"],
            env=env,
            capture_output=True, text=True,
            encoding="utf-8", errors="replace",
            timeout=60,
        )
        assert result.returncode == 0, result.stderr
        assert "[DRY_RUN] Phase 2 skipped" in result.stderr
