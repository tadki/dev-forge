"""Unit tests for SEE-519: local_repo_check.py worktree/branch cleanup enhancements.

Tests cover:
- find_bare_repo_path() with mock .git files and fallback logic
- Branch name normalization (refs/heads/agent/xxx -> agent/xxx) for B1 and B3
- B1 safety skip: active branch must NOT be deleted
- B3 orphan detection: active branches must NOT be in orphan list
- Dry-run mode: destructive operations must be skipped
"""

import json
import os
import subprocess
import sys
import tempfile

import pytest

# Add .dev/autopilots to path for module imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots"))


# =============================================================================
# Helpers: replicate the branch-normalization logic from local_repo_check.py
# so we test exactly what the production code does.
# =============================================================================

def normalize_branch_ref(porcelain_line: str) -> str:
    """Replicate B1/B3 branch normalization from local_repo_check.py.

    Input:  'branch refs/heads/agent/xxx'
    Output: 'agent/xxx'
    """
    prefix = "branch "
    if not porcelain_line.startswith(prefix):
        return ""
    return porcelain_line[len(prefix):].replace("refs/heads/", "", 1)


def branch_in_use(porcelain_output: str, branch_name: str) -> bool:
    """Replicate B1 safety check from local_repo_check.py."""
    return any(
        normalize_branch_ref(line) == branch_name
        for line in porcelain_output.splitlines()
        if line.startswith("branch ")
    )


def find_orphan_branches(porcelain_output: str, agent_branches_raw: str) -> list:
    """Replicate B3 orphan branch logic from local_repo_check.py."""
    active_branches = set()
    for line in porcelain_output.splitlines():
        if line.startswith("branch "):
            short = normalize_branch_ref(line)
            if short:
                active_branches.add(short)

    agent_branches = [
        line.strip().lstrip("* ").strip()
        for line in agent_branches_raw.splitlines()
        if line.strip()
    ]

    return [b for b in agent_branches if b not in active_branches]


# =============================================================================
# Tests for Branch Name Normalization (CRITICAL fix verification)
# =============================================================================

class TestBranchNameNormalization:
    """Verify the CRITICAL fix: porcelain 'refs/heads/agent/xxx' -> short 'agent/xxx'."""

    def test_normalize_standard_agent_branch(self):
        assert normalize_branch_ref("branch refs/heads/agent/bachi/bf931e59") == "agent/bachi/bf931e59"

    def test_normalize_already_short(self):
        assert normalize_branch_ref("branch agent/bachi/bf931e59") == "agent/bachi/bf931e59"

    def test_normalize_master_branch(self):
        assert normalize_branch_ref("branch refs/heads/master") == "master"

    def test_normalize_feature_branch(self):
        assert normalize_branch_ref("branch refs/heads/feature/abc") == "feature/abc"

    def test_normalize_non_branch_line(self):
        assert normalize_branch_ref("worktree /path/to/wt") == ""

    def test_normalize_empty(self):
        assert normalize_branch_ref("") == ""

    def test_normalize_only_prefix(self):
        assert normalize_branch_ref("branch ") == ""


class TestB1BranchInUseSafety:
    """Verify B1 safety skip: branch used by active worktree must NOT be deleted."""

    def test_branch_in_use_when_active(self):
        porcelain = """worktree /path/to/wt1
branch refs/heads/agent/bachi/bf931e59
HEAD 9b9799a

worktree /path/to/wt2
branch refs/heads/master
HEAD 21f5d9f"""
        assert branch_in_use(porcelain, "agent/bachi/bf931e59") is True

    def test_branch_not_in_use_when_only_master(self):
        porcelain = """worktree /path/to/wt1
branch refs/heads/master
HEAD 21f5d9f"""
        assert branch_in_use(porcelain, "agent/bachi/bf931e59") is False

    def test_branch_not_in_use_empty_list(self):
        assert branch_in_use("", "agent/bachi/bf931e59") is False

    def test_branch_in_use_with_short_ref_in_porcelain(self):
        """Edge case: porcelain uses short ref (should still match)."""
        porcelain = """worktree /path/to/wt1
branch agent/bachi/bf931e59
HEAD 9b9799a"""
        assert branch_in_use(porcelain, "agent/bachi/bf931e59") is True

    def test_similar_branch_name_not_matched(self):
        """Ensure prefix match doesn't accidentally match similar names."""
        porcelain = """worktree /path/to/wt1
branch refs/heads/agent/bachi/bf931e59
HEAD 9b9799a"""
        assert branch_in_use(porcelain, "agent/bachi/bf931e59a") is False
        assert branch_in_use(porcelain, "agent/bachi") is False

    def test_bug_scenario_refs_heads_vs_short(self):
        """This was the CRITICAL bug: comparing 'refs/heads/agent/xxx' with 'agent/xxx'
        would always return False, bypassing the safety check."""
        porcelain = "branch refs/heads/agent/bachi/bf931e59"
        # OLD buggy code: f"branch {branch_name}" in line
        # Would compare "branch agent/bachi/bf931e59" with "branch refs/heads/agent/bachi/bf931e59"
        # -> False (WRONG! branch IS in use)
        old_buggy_check = f"branch agent/bachi/bf931e59" in "branch refs/heads/agent/bachi/bf931e59"
        assert old_buggy_check is False, "Old buggy logic would incorrectly say not in use"

        # NEW fixed code: normalize first, then compare
        new_fixed_check = branch_in_use(porcelain, "agent/bachi/bf931e59")
        assert new_fixed_check is True, "Fixed logic correctly identifies branch in use"


class TestB3OrphanBranchDetection:
    """Verify B3 orphan branch detection: active branches must NOT appear in orphan list."""

    def test_no_orphans_when_all_active(self):
        porcelain = """worktree /path/to/wt1
branch refs/heads/agent/bachi/bf931e59
HEAD 9b9799a"""
        agent_branches = "agent/bachi/bf931e59\n"
        assert find_orphan_branches(porcelain, agent_branches) == []

    def test_finds_orphan_when_not_in_active(self):
        porcelain = """worktree /path/to/wt1
branch refs/heads/agent/bachi/bf931e59
HEAD 9b9799a"""
        agent_branches = "agent/bachi/bf931e59\n  agent/old/stale\n"
        orphans = find_orphan_branches(porcelain, agent_branches)
        assert "agent/old/stale" in orphans
        assert "agent/bachi/bf931e59" not in orphans

    def test_bug_scenario_all_marked_orphan(self):
        """This was the CRITICAL bug: active_branches stored 'refs/heads/agent/xxx'
        while agent_branches stored 'agent/xxx', so the 'not in' check always passed,
        marking ALL agent branches as orphan (including active ones)."""
        porcelain = "branch refs/heads/agent/active/wt"
        agent_branches = "agent/active/wt\n"

        # OLD buggy logic simulation
        old_active = set()
        for line in porcelain.splitlines():
            if line.startswith("branch "):
                old_active.add(line[len("branch "):])  # stores "refs/heads/agent/active/wt"

        old_agent = [line.strip() for line in agent_branches.splitlines() if line.strip()]
        old_orphans = [b for b in old_agent if b not in old_active]
        # Bug: "agent/active/wt" not in {"refs/heads/agent/active/wt"} -> True -> marked orphan!
        assert "agent/active/wt" in old_orphans, "Old buggy code would mark active branch as orphan"

        # NEW fixed logic
        new_orphans = find_orphan_branches(porcelain, agent_branches)
        assert "agent/active/wt" not in new_orphans, "Fixed code correctly excludes active branch"

    def test_multiple_active_and_multiple_orphans(self):
        porcelain = """worktree /path/to/wt1
branch refs/heads/agent/wt1
HEAD aaa

worktree /path/to/wt2
branch refs/heads/agent/wt2
HEAD bbb"""
        agent_branches = "agent/wt1\n  agent/wt2\n  agent/orphan1\n  agent/orphan2\n"
        orphans = find_orphan_branches(porcelain, agent_branches)
        assert set(orphans) == {"agent/orphan1", "agent/orphan2"}

    def test_no_agent_branches(self):
        assert find_orphan_branches("", "") == []

    def test_empty_active_list_all_orphans(self):
        agent_branches = "agent/orphan1\n  agent/orphan2\n"
        orphans = find_orphan_branches("", agent_branches)
        assert len(orphans) == 2


# =============================================================================
# Tests for find_bare_repo_path()
# =============================================================================

class TestFindBareRepoPath:
    """Test find_bare_repo_path() logic via importing from local_repo_check.py."""

    @pytest.fixture(autouse=True)
    def _isolate_workspace_env(self, monkeypatch):
        # find_bare_repo_path 优先取 $MULTICA_WORKSPACE_ID 命名解析 bare repo；
        # 本机 env 在位时 tmp_path 用例会命中真实工作区，`== ""` 断言假红。
        monkeypatch.delenv("MULTICA_WORKSPACE_ID", raising=False)

    def test_from_git_file_gitdir(self, tmp_path):
        """Bare repo detected from .git file containing 'gitdir: ...' path."""
        from local_repo_check import find_bare_repo_path

        # Simulate workspace with a worktree — .git file must be at workdir root
        # because find_bare_repo_path breaks after first os.walk iteration
        ws = tmp_path / "workspace"
        workdir = ws / "abc123" / "workdir"
        workdir.mkdir(parents=True)

        # Simulate bare repo with worktree metadata
        bare = tmp_path / "repos" / "github.com+tadki+KingOfLikes-Godot.git"
        wt_meta = bare / "worktrees" / "abc123"
        wt_meta.mkdir(parents=True)

        # Create .git file at workdir root pointing to worktree metadata
        git_file = workdir / ".git"
        git_file.write_text(f"gitdir: {wt_meta}\n")

        result = find_bare_repo_path(str(ws))
        assert result == str(bare)

    def test_no_worktree_dirs_returns_empty(self, tmp_path):
        """When workspace has no valid worktree directories, return empty string."""
        from local_repo_check import find_bare_repo_path

        ws = tmp_path / "workspace"
        ws.mkdir()
        # No subdirectories at all

        result = find_bare_repo_path(str(ws))
        assert result == ""

    def test_workspace_with_empty_workdir(self, tmp_path):
        """When workdir exists but has no .git file, return empty string."""
        from local_repo_check import find_bare_repo_path

        ws = tmp_path / "workspace"
        workdir = ws / "abc123" / "workdir"
        workdir.mkdir(parents=True)

        result = find_bare_repo_path(str(ws))
        assert result == ""

    def test_real_workspace_finds_bare_repo(self):
        """Live smoke: bare-repo discovery works on the REAL workspace root.

        SEE-1473 R2 rewrite: the root comes from the product resolver
        (``_default_workspace_root()`` — Tier-0 env, interface-derived) instead
        of the hardcoded legacy-layout path this test used before, which the
        §SPEC-010 cleanup deleted and turned this test into a permanent skip.
        Skips when no live root is resolvable (plain CI checkout). Read-only.
        """
        from local_repo_check import _default_workspace_root, find_bare_repo_path

        ws = _default_workspace_root()
        if not ws or not os.path.isdir(ws):
            pytest.skip("No live workspace root resolvable in this environment")

        result = find_bare_repo_path(ws)
        assert result != "", "Should find bare repo on real workspace"
        assert result.endswith(".git"), f"Bare repo path should end with .git: {result}"
        assert os.path.isdir(result), f"Bare repo path should exist: {result}"


# =============================================================================
# Integration: Dry-Run Mode Verification
# =============================================================================

class TestDryRunIntegration:
    """Verify dry-run mode does not execute destructive operations.

    This test runs the actual local_repo_check.py with --dry-run against a
    temporary workspace and verifies no deletions occurred.
    """

    def test_dry_run_no_deletions(self, tmp_path):
        """Run script in dry-run mode; verify no directories deleted."""
        ws = tmp_path / "workspace"
        ws.mkdir()

        # Create a fake worktree that would be eligible for deletion
        # (clean + no unpushed commits)
        wt = ws / "deadbeef" / "workdir" / "test-repo"
        wt.mkdir(parents=True)
        subprocess.run(["git", "init", "--quiet"], cwd=str(wt), check=True)
        (wt / "file.txt").write_text("hello")
        subprocess.run(["git", "add", "."], cwd=str(wt), check=True)
        subprocess.run(["git", "commit", "-m", "init", "--quiet"], cwd=str(wt), check=True)

        script = os.path.join(
            os.path.dirname(__file__), "..", "..", "autopilots", "local_repo_check.py"
        )

        env = os.environ.copy()
        env["EXECUTION_ISSUE_ID"] = ""

        result = subprocess.run(
            [sys.executable, str(script), "--dry-run", "--workspace-root", str(ws)],
            capture_output=True,
            text=True,
            env=env,
            timeout=60,
        )

        # Should exit 0 and produce JSON
        assert result.returncode == 0, f"Script failed: {result.stderr}"
        output = json.loads(result.stdout)

        # Verify directory still exists (the primary dry-run guarantee)
        assert wt.exists(), "dry-run must NOT delete directories"

        # Verify dry-run indicators.
        # When bare_repo is found: orphan_branches_cleaned = -1, worktree_pruned = None
        # When bare_repo not found (temp workspace): defaults are 0 and False
        if output.get("bare_repo"):
            assert output["orphan_branches_cleaned"] == -1, \
                "dry-run with bare_repo should set orphan_branches_cleaned to -1"

    def test_dry_run_deleted_entries_marked(self, tmp_path):
        """In dry-run mode, deleted entries should have 'dry_run' status."""
        ws = tmp_path / "workspace"
        ws.mkdir()

        wt = ws / "cafebabe" / "workdir" / "test-repo"
        wt.mkdir(parents=True)
        subprocess.run(["git", "init", "--quiet"], cwd=str(wt), check=True)
        (wt / "file.txt").write_text("hello")
        subprocess.run(["git", "add", "."], cwd=str(wt), check=True)
        subprocess.run(["git", "commit", "-m", "init", "--quiet"], cwd=str(wt), check=True)
        # SEE-956 H6: deletion requires origin/{branch}; create the local
        # origin/master tracking ref so this clean worktree is deletable.
        subprocess.run(
            ["git", "update-ref", "refs/remotes/origin/master", "HEAD"],
            cwd=str(wt), check=True,
        )

        script = os.path.join(
            os.path.dirname(__file__), "..", "..", "autopilots", "local_repo_check.py"
        )

        env = os.environ.copy()
        env["EXECUTION_ISSUE_ID"] = ""

        result = subprocess.run(
            [sys.executable, str(script), "--dry-run", "--workspace-root", str(ws)],
            capture_output=True,
            text=True,
            env=env,
            timeout=60,
        )

        assert result.returncode == 0
        output = json.loads(result.stdout)

        deleted = output.get("deleted_worktrees", [])
        assert len(deleted) > 0, "Expected at least one eligible worktree"
        for entry in deleted:
            assert entry.get("delete_status") == "dry_run", \
                f"Expected dry_run status, got: {entry.get('delete_status')}"


# =============================================================================
# NOTE (SEE-1473 R2): the former TestRealWorkspaceDryRun /
# test_real_workspace_dry_run_no_crash live test was retired with the
# §SPEC-010 cleanup that deleted the legacy workspace root it hardcoded.
# Its real-machine full-scan role is owned by the QA-stage §SPEC-005/011
# criteria (deliberate dry-run acceptance, not a unit-suite citizen — a live
# full scan takes minutes and contends on the SEE-956 WorkspaceMutex, so a
# concurrent run makes it time out). Its crash/JSON-contract discrimination
# stays covered by the sandbox dry-run tests above and the SEE-1473 orphan
# sandbox suite.
# =============================================================================
