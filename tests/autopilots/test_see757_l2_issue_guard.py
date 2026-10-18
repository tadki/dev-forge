"""QA tests for SEE-757: L2 issue status guard for local_repo_check.py.

Scenarios covered:
1. Active issues (todo/in_progress/in_review/blocked/backlog) -> worktree skipped
2. Closed issues (done/cancelled) -> worktree eligible for deletion
3. No linked issue -> worktree eligible for deletion
4. API failure when issue_id exists -> worktree retained (fail-safe)
5. B3 orphan branch cleanup does NOT delete branches from L2-skipped worktrees
"""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

# Script path
SCRIPT_DIR = Path(__file__).resolve().parent.parent.parent / "autopilots"
LOCAL_REPO_CHECK = str(SCRIPT_DIR / "local_repo_check.py")


def _init_git_repo(repo_path: Path):
    """Initialize a minimal git repo with a commit."""
    subprocess.run(["git", "init", "--quiet"], cwd=str(repo_path), check=True)
    subprocess.run(["git", "config", "user.email", "test@test.com"], cwd=str(repo_path), check=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=str(repo_path), check=True)
    (repo_path / "file.txt").write_text("hello")
    subprocess.run(["git", "add", "."], cwd=str(repo_path), check=True)
    subprocess.run(["git", "commit", "-m", "init", "--quiet"], cwd=str(repo_path), check=True)


def _make_worktree(ws: Path, name: str, issue_id: str = "", branch: str = "") -> Path:
    """Create a worktree directory with git repo and optional .gc_meta.json.

    SEE-956 H6: deletion now requires origin/{branch} to exist (so unpushed
    commits are not trusted). A local remote-tracking ref is created for the
    checked-out branch so tests that need a "clean + pushed" worktree can
    reach the deletion path without standing up a full bare remote.
    """
    workdir = ws / name / "workdir" / "test-repo"
    workdir.mkdir(parents=True)
    _init_git_repo(workdir)

    # Establish the local origin/* tracking ref that H6 checks. Without this,
    # a clean branch with zero unpushed commits would look like never-pushed
    # work and be routed to need_push_decision instead of deleted.
    if branch:
        subprocess.run(["git", "checkout", "-b", branch, "--quiet"], cwd=str(workdir), check=True)
        subprocess.run(
            ["git", "update-ref", f"refs/remotes/origin/{branch}", "HEAD"],
            cwd=str(workdir), check=True,
        )
    else:
        subprocess.run(
            ["git", "update-ref", "refs/remotes/origin/master", "HEAD"],
            cwd=str(workdir), check=True,
        )

    if issue_id:
        meta_dir = ws / name
        meta_file = meta_dir / ".gc_meta.json"
        meta_file.write_text(json.dumps({"issue_id": issue_id}))

    return workdir


def _run_script(ws: Path, extra_env=None):
    """Run local_repo_check.py --dry-run against a workspace."""
    env = os.environ.copy()
    env["EXECUTION_ISSUE_ID"] = ""
    env["PYTHONPATH"] = str(SCRIPT_DIR) + os.pathsep + os.environ.get("PYTHONPATH", "")
    if extra_env:
        env.update(extra_env)

    result = subprocess.run(
        [sys.executable, LOCAL_REPO_CHECK, "--dry-run", "--workspace-root", str(ws)],
        capture_output=True,
        text=True,
        env=env,
        timeout=60,
    )
    assert result.returncode == 0, f"Script failed:\nstdout: {result.stdout}\nstderr: {result.stderr}"
    return json.loads(result.stdout)


def _make_mock_multica(tmp_path: Path, responses: dict) -> str:
    """Create a mock multica binary on PATH.

    responses: dict mapping issue_id -> status string (or None for API failure)
    """
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    multica_bin = bin_dir / "multica"

    # Build response mapping inside the script
    resp_lines = []
    for iid, status in responses.items():
        if status is None:
            resp_lines.append(f"    '{iid}': None,")
        else:
            resp_lines.append(f"    '{iid}': '{status}',")

    script = f'''#!/usr/bin/env python3
import sys
import json

RESPONSES = {{
{chr(10).join(resp_lines)}
}}

if len(sys.argv) >= 4 and sys.argv[1] == "issue" and sys.argv[2] == "get":
    issue_id = sys.argv[3]
    status = RESPONSES.get(issue_id)
    if status is None:
        # Simulate API failure or unknown issue: print nothing
        pass
    else:
        print(json.dumps({{"id": issue_id, "status": status, "assignee_id": ""}}))
'''
    multica_bin.write_text(script)
    multica_bin.chmod(0o755)
    return str(bin_dir)


class TestL2IssueStatusGuard:
    """Scenario 1: Active issue statuses skip the worktree.

    SEE-956 H5: ``backlog`` is now treated as active (a backlog issue may be
    picked up, so its worktree is retained) and moved here from the deletable set.
    """

    @pytest.mark.parametrize("status", ["todo", "in_progress", "in_review", "blocked", "backlog"])
    def test_active_issue_skips_worktree(self, tmp_path, status):
        ws = tmp_path / "workspace"
        ws.mkdir()
        _make_worktree(ws, "wt-active", issue_id="issue-active", branch="agent/test/active")

        mock_path = _make_mock_multica(tmp_path, {"issue-active": status})
        env = {"PATH": mock_path + os.pathsep + os.environ.get("PATH", "")}

        output = _run_script(ws, extra_env=env)

        # Should be in skipped_active_issues, NOT in deleted_worktrees
        skipped = output.get("skipped_active_issues", [])
        deleted = output.get("deleted_worktrees", [])

        assert len(skipped) == 1, f"Expected 1 skipped entry for status={status}"
        assert skipped[0]["hash"] == "wt-active"
        assert skipped[0].get("skip_reason") == "issue_active"
        assert skipped[0].get("issue_status") == status
        assert len(deleted) == 0, f"Active issue worktree should NOT be deleted for status={status}"


class TestL2DeletableIssueStatuses:
    """Scenario 2: Closed (done/cancelled) issues allow deletion.

    SEE-956 H5: ``backlog`` was removed from the deletable set and is now
    retained (see TestL2IssueStatusGuard).
    """

    @pytest.mark.parametrize("status", ["done", "cancelled"])
    def test_closed_issue_allows_deletion(self, tmp_path, status):
        ws = tmp_path / "workspace"
        ws.mkdir()
        _make_worktree(ws, "wt-closed", issue_id="issue-closed", branch="agent/test/closed")

        mock_path = _make_mock_multica(tmp_path, {"issue-closed": status})
        env = {"PATH": mock_path + os.pathsep + os.environ.get("PATH", "")}

        output = _run_script(ws, extra_env=env)

        skipped = output.get("skipped_active_issues", [])
        deleted = output.get("deleted_worktrees", [])

        assert len(skipped) == 0, f"Closed issue worktree should NOT be skipped for status={status}"
        assert len(deleted) == 1, f"Expected 1 deleted entry for status={status}"
        assert deleted[0]["hash"] == "wt-closed"
        assert deleted[0].get("delete_status") == "dry_run"


class TestL2NoLinkedIssue:
    """Scenario 3: No linked issue -> worktree eligible for deletion."""

    def test_no_issue_worktree_deleted(self, tmp_path):
        ws = tmp_path / "workspace"
        ws.mkdir()
        _make_worktree(ws, "wt-no-issue", issue_id="", branch="agent/test/noissue")

        output = _run_script(ws)

        skipped = output.get("skipped_active_issues", [])
        deleted = output.get("deleted_worktrees", [])

        assert len(skipped) == 0, "No-issue worktree should NOT be in skipped_active"
        assert len(deleted) == 1, "No-issue worktree should be eligible for deletion"
        assert deleted[0]["hash"] == "wt-no-issue"


class TestL2ApiFailure:
    """Scenario 4: API failure with issue_id present -> fail-safe retain."""

    def test_api_failure_retains_worktree(self, tmp_path):
        ws = tmp_path / "workspace"
        ws.mkdir()
        _make_worktree(ws, "wt-api-fail", issue_id="issue-fail", branch="agent/test/fail")

        # Mock returns None for this issue_id -> simulates API failure
        mock_path = _make_mock_multica(tmp_path, {"issue-fail": None})
        env = {"PATH": mock_path + os.pathsep + os.environ.get("PATH", "")}

        output = _run_script(ws, extra_env=env)

        skipped = output.get("skipped_active_issues", [])
        deleted = output.get("deleted_worktrees", [])

        assert len(skipped) == 1, "API-failure worktree should be retained (fail-safe)"
        assert skipped[0]["hash"] == "wt-api-fail"
        assert skipped[0].get("skip_reason") == "issue_status_unknown"
        assert "issue_status_fetch_failed" in skipped[0].get("note", "")
        assert len(deleted) == 0, "API-failure worktree should NOT be deleted"


class TestL2MultipleMixedStatuses:
    """Mixed scenario: multiple worktrees with different issue statuses."""

    def test_mixed_statuses_correctly_classified(self, tmp_path):
        ws = tmp_path / "workspace"
        ws.mkdir()

        _make_worktree(ws, "wt-todo", issue_id="issue-todo", branch="agent/test/todo")
        _make_worktree(ws, "wt-done", issue_id="issue-done", branch="agent/test/done")
        _make_worktree(ws, "wt-none", issue_id="", branch="agent/test/none")
        _make_worktree(ws, "wt-fail", issue_id="issue-fail", branch="agent/test/fail")

        mock_path = _make_mock_multica(tmp_path, {
            "issue-todo": "todo",
            "issue-done": "done",
            "issue-fail": None,
        })
        env = {"PATH": mock_path + os.pathsep + os.environ.get("PATH", "")}

        output = _run_script(ws, extra_env=env)

        skipped = output.get("skipped_active_issues", [])
        deleted = output.get("deleted_worktrees", [])

        # 2 skipped: todo + api-fail
        assert len(skipped) == 2
        skipped_hashes = {s["hash"] for s in skipped}
        assert skipped_hashes == {"wt-todo", "wt-fail"}

        # 2 deleted: done + no-issue
        assert len(deleted) == 2
        deleted_hashes = {d["hash"] for d in deleted}
        assert deleted_hashes == {"wt-done", "wt-none"}


class TestL2B3OrphanSafety:
    """Scenario 5: B3 orphan branch cleanup must NOT delete branches from L2-skipped worktrees.

    When L2 guard skips a worktree, the worktree directory is NOT deleted.
    Therefore the branch remains registered in the bare repo's worktree list.
    B3 checks git worktree list --porcelain; skipped branches are still active.
    """

    def test_skipped_branch_not_in_orphan_list(self, tmp_path):
        """Verify branch from L2-skipped worktree is NOT in orphan list.

        Uses git worktree add (not clone) so the worktree is registered
        in the bare repo's worktree list, making B3 orphan detection work.
        """
        ws = tmp_path / "workspace"
        ws.mkdir()

        # Create bare repo with an initial commit on master
        bare = tmp_path / "bare" / "test.git"
        bare.mkdir(parents=True)
        subprocess.run(["git", "init", "--bare", "--quiet"], cwd=str(bare), check=True)

        # Bootstrap: create an initial commit via a temp clone
        tmp_clone = tmp_path / "tmp_clone"
        subprocess.run(["git", "clone", "--quiet", str(bare), str(tmp_clone)], check=True)
        subprocess.run(["git", "config", "user.email", "t@test.com"], cwd=str(tmp_clone), check=True)
        subprocess.run(["git", "config", "user.name", "T"], cwd=str(tmp_clone), check=True)
        (tmp_clone / "f.txt").write_text("x")
        subprocess.run(["git", "add", "."], cwd=str(tmp_clone), check=True)
        subprocess.run(["git", "commit", "-m", "init", "--quiet"], cwd=str(tmp_clone), check=True)
        subprocess.run(["git", "push", "origin", "master", "--quiet"], cwd=str(tmp_clone), check=True)

        # Create branch agent/test/skip in bare repo
        subprocess.run(
            ["git", "push", "origin", "master:refs/heads/agent/test/skip", "--quiet"],
            cwd=str(tmp_clone), check=True,
        )
        # Create an orphan branch (no worktree will be added for this)
        subprocess.run(
            ["git", "push", "origin", "master:refs/heads/agent/test/orphan", "--quiet"],
            cwd=str(tmp_clone), check=True,
        )

        # Create a git worktree for agent/test/skip inside the workspace
        # Using `git worktree add` (not clone) so the worktree is registered
        # in the bare repo's worktree list, which is what B3 checks.
        # find_bare_repo_path walks workdir depth=0 looking for .git file;
        # placing the worktree directly at workdir level ensures .git is at depth 0.
        wt_workdir = ws / "wt-skip" / "workdir"
        wt_workdir.mkdir(parents=True)
        subprocess.run(
            ["git", "worktree", "add", str(wt_workdir), "agent/test/skip"],
            cwd=str(bare), check=True,
        )

        # Add .gc_meta.json with active issue (in parent of workdir)
        meta = ws / "wt-skip" / ".gc_meta.json"
        meta.write_text(json.dumps({"issue_id": "issue-skip"}))

        # Mock multica: issue is active (in_progress)
        mock_path = _make_mock_multica(tmp_path, {"issue-skip": "in_progress"})

        env = {
            "PATH": mock_path + os.pathsep + os.environ.get("PATH", ""),
            "EXECUTION_ISSUE_ID": "",
        }

        result = subprocess.run(
            [sys.executable, LOCAL_REPO_CHECK, "--dry-run", "--workspace-root", str(ws)],
            capture_output=True,
            text=True,
            env=env,
            timeout=60,
        )
        assert result.returncode == 0, f"Script failed: {result.stderr}"
        output = json.loads(result.stdout)

        # L2: worktree should be skipped (active issue)
        skipped = output.get("skipped_active_issues", [])
        assert len(skipped) == 1
        assert skipped[0]["hash"] == "wt-skip"

        # B3: orphan list should contain the orphan, NOT the skipped branch
        orphans = output.get("orphan_branches_list", [])
        assert "agent/test/orphan" in orphans, "True orphan should be in orphan list"
        assert "agent/test/skip" not in orphans, "L2-skipped branch must NOT be in orphan list"


class TestL2ReportOutput:
    """Verify report outputs include skipped_active information."""

    def test_report_functions_with_skipped_active(self, tmp_path):
        """Import and test the build_report_comment output when skipped_active exists."""
        sys.path.insert(0, str(SCRIPT_DIR))
        import local_repo_check as lrc

        # Simulate state as if main loop ran
        lrc.skipped_active = [
            {"hash": "abc123", "branch": "agent/test/x", "issue_status": "in_progress"}
        ]
        lrc.entries = [{"hash": "abc123", "skipped": True}]
        lrc.deleted = []
        lrc.need_push_decision = []
        lrc.need_changes_decision = []
        lrc.no_repo = []
        lrc.total = 1

        report = lrc.build_report_comment()
        assert "因 issue 活跃而跳过" in report
        assert "1" in report

        mention = lrc.build_mention_comment()
        assert "因 issue 活跃而跳过的仓库" in mention
        assert "abc123" in mention
        assert "in_progress" in mention

        summary = lrc.build_summary_description()
        assert "issue 状态保护" in summary

    def test_json_output_has_skipped_active_field(self, tmp_path):
        ws = tmp_path / "workspace"
        ws.mkdir()
        _make_worktree(ws, "wt-inprog", issue_id="issue-inprog", branch="agent/test/inprog")

        mock_path = _make_mock_multica(tmp_path, {"issue-inprog": "in_progress"})
        env = {"PATH": mock_path + os.pathsep + os.environ.get("PATH", "")}

        output = _run_script(ws, extra_env=env)

        assert "skipped_active_issues" in output
        assert isinstance(output["skipped_active_issues"], list)
        assert len(output["skipped_active_issues"]) == 1
