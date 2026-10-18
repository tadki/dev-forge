#!/usr/bin/env python3
"""Local worktree inspection script for Multica workspace.

Scans worktree directories, collects metadata, checks git status,
auto-deletes clean+pushed worktrees, and outputs structured JSON.

Can be run directly on Windows without bash:
    python autopilots/local_repo_check.py --workspace-root <path> [--dry-run]
"""

import argparse
import json
import subprocess
import sys
import os
import re
import shutil
import tempfile
from datetime import datetime, timezone

from multica_helpers import (
    AGENT_MAP, ATLAS_ID, CHORE_LABEL, INFRA_LABEL, PROJECT_ID,
    PidFileLock, WorkspaceMutex,
    log_error as _log_error_orig, multica_cli, multica_stdin_cmd,
)

# SEE-1109: wrap log_error so any Phase 2 write failure bumps a counter the
# top-level exit checks. Without this a failed summary-issue create wrote a
# stderr line but still exited 0, masking the failure from the autopilot
# scheduler.
_phase2_error_count = 0


def log_error(msg):
    global _phase2_error_count
    _phase2_error_count += 1
    _log_error_orig(msg)

# SEE-956 C4: fcntl is used for the per-worktree advisory lock. On Windows it is
# unavailable and the lock degrades to a no-op (we still run the git worktree-list
# cross-check, which does not depend on fcntl).
try:
    import fcntl
except ImportError:
    fcntl = None


# --- Argument parsing ---

def _default_workspace_root() -> str:
    """Derive the Multica workspace root without hardcoding.

    Resolution order:
      1. $MULTICA_WORKSPACE_ID under $MULTICA_WORKSPACES_ROOT
         (or its default ~/multica_workspaces).
      2. Walk up from this script looking for an ancestor whose children are
         worktree slots (each contains a ``.gc_meta.json`` or a ``workdir/``).
      3. Empty string — caller must fail fast and ask for --workspace-root.
    """
    ws_id = os.environ.get("MULTICA_WORKSPACE_ID", "")
    if ws_id:
        root_base = os.environ.get(
            "MULTICA_WORKSPACES_ROOT",
            os.path.expanduser("~/multica_workspaces"),
        )
        candidate = os.path.join(root_base, ws_id)
        if os.path.isdir(candidate):
            return candidate

    cursor = os.path.abspath(os.path.dirname(__file__))
    for _ in range(6):
        if os.path.isfile(os.path.join(cursor, ".gc_meta.json")):
            parent = os.path.dirname(cursor)
            if parent and parent != cursor:
                return parent
        parent = os.path.dirname(cursor)
        if parent == cursor:
            break
        cursor = parent
    return ""


def parse_args():
    parser = argparse.ArgumentParser(
        description="Local worktree inspection script for Multica workspace"
    )
    parser.add_argument(
        "--workspace-root",
        default=_default_workspace_root(),
        help="Workspace root directory (default: derived from MULTICA_WORKSPACE_ID "
             "or by walking up from this script)"
    )
    parser.add_argument(
        "--current-hash", default="",
        help="Current worktree hash to skip (auto-detected if omitted)"
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Dry run mode (do not execute destructive operations)"
    )
    parser.add_argument(
        "--execution-issue-id", default="",
        help="Execution issue ID for reporting"
    )
    parser.add_argument(
        "--kill-switch",
        default=os.environ.get("KILL_SWITCH", "false"),
        help="Kill switch: true/false. When true, skip the worktree-deletion "
             "phase and only emit the need_decision list (default: %(default)s)",
    )
    return parser.parse_args()


# --- Constants ---

# Issue statuses whose worktrees may be auto-deleted (whitelist, fail-safe).
# Any status NOT in this set (e.g. todo, in_progress, in_review, blocked, backlog)
# is treated as "issue still active" — the worktree is preserved.
#
# SEE-956 H5: "backlog" was removed. A backlog issue is queued for future work,
# not abandoned — its worktree/branch may still be needed, so auto-deleting it
# risks discarding staged work. Only terminal statuses (done/cancelled) qualify.
DELETABLE_ISSUE_STATUSES = {"done", "cancelled"}


# --- Module-level variables (defaults; updated at runtime) ---

workspace_root = ""
current_hash = ""
dry_run = False
execution_issue_id = ""


# --- Helper functions ---

def run(cmd, fallback="", timeout=30):
    """Thin wrapper over multica_helpers.multica_cli (SEE-1224 #3).

    Preserves the legacy stdout/fallback signature so callers are untouched;
    transient CLI failures now get unified exponential backoff instead of
    silently returning fallback.
    """
    ok, out = multica_cli(cmd, timeout=timeout)
    return out if ok else fallback


def run_ok(cmd, timeout=30):
    """Thin wrapper over multica_helpers.multica_cli returning (ok, stdout)."""
    return multica_cli(cmd, timeout=timeout)


def _worktree_is_locked(porcelain_output: str, wt_dir: str) -> bool:
    """True if `git worktree list --porcelain` marks wt_dir with a `locked` reason.

    Used by the SEE-956 C4 cross-check: a worktree git-locked by another holder
    (e.g. an in-flight checkout or repair) must not be torn down.
    """
    wt_dir_abs = os.path.abspath(wt_dir)
    current: str | None = None
    for line in (porcelain_output or "").splitlines():
        if line.startswith("worktree "):
            current = os.path.abspath(line[len("worktree "):].strip())
        elif line == "locked" or line.startswith("locked "):
            if current == wt_dir_abs:
                return True
    return False


def acquire_worktree_delete_lock(wt_dir: str, bare_repo: str) -> tuple[str, int | None]:
    """SEE-956 C4: per-worktree advisory lock + git worktree-list cross-check.

    Returns ``(status, fd)``:
    - ``("ok", fd)`` — lock acquired; caller must close ``fd`` (releases the flock)
      in a ``finally``.
    - ``("skipped_concurrent", None)`` — another process holds the advisory lock.
    - ``("skipped_git_locked", None)`` — git reports the worktree as locked.
    """
    lockfile = os.path.join(
        os.path.dirname(wt_dir), "." + os.path.basename(wt_dir) + ".dellock"
    )

    if fcntl is not None:
        try:
            fd = os.open(lockfile, os.O_RDWR | os.O_CREAT, 0o644)
        except OSError:
            return "skipped_concurrent", None
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            try:
                os.close(fd)
            except OSError:
                pass
            return "skipped_concurrent", None
    else:
        fd = None

    if bare_repo:
        wt_list = run(f'git -C "{bare_repo}" worktree list --porcelain', timeout=15)
        if _worktree_is_locked(wt_list, wt_dir):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
            return "skipped_git_locked", None

    return "ok", fd


def clean(e):
    out = {}
    for k, v in e.items():
        if k in ("completed_at",):
            continue
        out[k] = v
    return out


def find_bare_repo_path(ws_root: str) -> str:
    """Detect bare repo path from any worktree's .git file, or fall back to the
    Multica bare-repo root.

    SEE-1181: the fallback is now derived instead of hardcoded. Resolution order
    mirrors `repo-checkout.sh`'s `resolve_bare_repo`:
      1. $MULTICA_BARE_REPOS_ROOT/<ws_id>   (env override for non-default layouts)
      2. <ancestor-of-ws_root>/.repos/<ws_id>  (walk-up from workspace root)
      3. /home/jerry/multica_workspaces/.repos/<ws_id>  (legacy default)
    ``ws_id`` prefers $MULTICA_WORKSPACE_ID and falls back to basename(ws_root).
    """
    for name in sorted(os.listdir(ws_root)):
        wt_dir = os.path.join(ws_root, name)
        workdir = os.path.join(wt_dir, "workdir")
        if not os.path.isdir(workdir):
            continue
        # Walk depth<=2 to find <workdir>/<repo>/.git (a "gitdir:" pointer file in
        # linked-worktree layouts). Do NOT `break` after the first iteration —
        # that exited at depth=0 (workdir itself) and never descended into
        # <workdir>/<repo>, making this whole path dead code behind the
        # hardcoded fallback. Prune deeper subtrees by clearing `dirs` instead.
        for root, dirs, files in os.walk(workdir):
            depth = root[len(workdir):].count(os.sep)
            if depth > 2:
                dirs.clear()
                continue
            git_file = os.path.join(root, ".git")
            if os.path.isfile(git_file):
                try:
                    with open(git_file, "r", encoding="utf-8") as f:
                        line = f.readline().strip()
                    if line.startswith("gitdir: "):
                        gitdir = line[len("gitdir: "):]
                        # e.g. gitdir: /home/.../github.com+tadki+KingOfLikes-Godot.git/worktrees/xxx
                        bare = os.path.dirname(os.path.dirname(gitdir))
                        if os.path.isdir(bare):
                            return bare
                except (IOError, OSError):
                    pass

    # Fallback: standard Multica bare repo path (derived, not hardcoded).
    ws_id = os.environ.get("MULTICA_WORKSPACE_ID") or os.path.basename(ws_root)
    candidates = []
    env_root = os.environ.get("MULTICA_BARE_REPOS_ROOT")
    if env_root:
        candidates.append(os.path.join(env_root, ws_id))
    cursor = os.path.abspath(ws_root)
    while True:
        candidates.append(os.path.join(cursor, ".repos", ws_id))
        parent = os.path.dirname(cursor)
        if parent == cursor:
            break
        cursor = parent
    candidates.append(f"/home/jerry/multica_workspaces/.repos/{ws_id}")
    for fallback_dir in candidates:
        if os.path.isdir(fallback_dir):
            for entry in sorted(os.listdir(fallback_dir)):
                if entry.endswith(".git") and os.path.isdir(os.path.join(fallback_dir, entry)):
                    return os.path.join(fallback_dir, entry)
    return ""


# --- Phase 2 state ---

# Populated during main execution
assignee_map = {}  # issue_id -> assignee_id


def get_mention_link(entry):
    iid = entry.get("issue_id", "")
    aid = assignee_map.get(iid, "")
    return AGENT_MAP.get(aid, AGENT_MAP.get(ATLAS_ID, "[@Atlas]"))


def build_summary_description():
    lines = []
    lines.append("## 背景")
    lines.append("")
    lines.append("本轮本地仓库巡检发现以下 worktree 中的仓库需要决策。")
    lines.append("")
    lines.append("已 push + git 干净 的仓库已自动删除（详见本 Issue 评论）。")
    lines.append("")

    # Type A
    lines.append(
        f"## 类型 A：git 干净 + 未 push（共 {len(need_push_decision)} 个）"
    )
    lines.append("")
    lines.append("> 需要各 Agent 决策：push / 放弃。")
    lines.append("")
    lines.append(
        "| 目录 | 当前分支 | 未推送 commits 数 | 上游分支 | 关联 Issue | 推荐操作 |"
    )
    lines.append(
        "|------|----------|------------------|----------|-----------|---------|"
    )
    for e in need_push_decision:
        hash_val = e.get("hash", "")
        branch = e.get("branch", "")
        unpushed = e.get("unpushed_commits", 0)
        upstream = e.get("upstream_ref", "")
        issue_id = e.get("issue_id", "")
        issue_status = e.get("issue_status", "N/A")
        link = (
            f"[{issue_id}](mention://issue/{issue_id})"
            if issue_id
            else "无"
        )
        lines.append(
            f"| {hash_val} | {branch} | {unpushed} | {upstream} | {link} ({issue_status}) | push / 放弃 |"
        )
    lines.append("")

    # Type B
    lines.append(
        f"## 类型 B：git 有未提交变更（共 {len(need_changes_decision)} 个）"
    )
    lines.append("")
    lines.append("> 需要各 Agent 决策：继续修改 / 提交并 push / 放弃。")
    lines.append("")
    lines.append(
        "| 目录 | 当前分支 | git 状态摘要 | 未推送 commits 数 | 关联 Issue | 推荐操作 |"
    )
    lines.append(
        "|------|----------|-------------|------------------|-----------|---------|"
    )
    for e in need_changes_decision:
        hash_val = e.get("hash", "")
        branch = e.get("branch", "")
        status = e.get("git_status_summary", "").replace("; ", "<br>")
        unpushed = e.get("unpushed_commits", 0)
        issue_id = e.get("issue_id", "")
        issue_status = e.get("issue_status", "N/A")
        link = (
            f"[{issue_id}](mention://issue/{issue_id})"
            if issue_id
            else "无"
        )
        lines.append(
            f"| {hash_val} | {branch} | {status} | {unpushed} | {link} ({issue_status}) | 继续修改 / 提交并push / 放弃 |"
        )
    lines.append("")

    # Decision options
    lines.append("## 决策选项")
    lines.append("")
    lines.append("### 对于类型 A（干净 + 未 push）")
    lines.append(
        "- **push** → 执行 `git push origin <分支名>` → 仓库变为\"已push+干净\"状态，下轮巡检自动删除"
    )
    lines.append(
        "- **放弃** → 手动删除 worktree 目录 `rm -rf .../<hash>`"
    )
    lines.append("")
    lines.append("### 对于类型 B（有未提交变更）")
    lines.append(
        "- **继续修改** → 不删除，继续在此分支上工作"
    )
    lines.append(
        "- **提交并 push** → `git add . && git commit -m \"...\" && git push origin <分支>` → 下轮巡检自动删除"
    )
    lines.append(
        "- **放弃** → 手动删除 worktree 目录（注意：未提交的更改会丢失）"
    )
    lines.append("")

    # Operations
    lines.append("## 操作方法")
    lines.append("")
    lines.append("### 继续修改")
    lines.append("```")
    lines.append("# 1. 继续在对应 workdir 中工作")
    lines.append(f"cd {workspace_root}/<hash>/workdir")
    lines.append("# ...继续修改...")
    lines.append("```")
    lines.append("")
    lines.append("### 提交并 push")
    lines.append("```")
    lines.append(f"cd {workspace_root}/<hash>/workdir")
    lines.append("git add .")
    lines.append('git commit -m "提交变更"')
    lines.append("git push origin <当前分支>")
    lines.append("```")
    lines.append("")
    lines.append("### 放弃（删除仓库）")
    lines.append("```")
    lines.append(f"rm -rf {workspace_root}/<hash>")
    lines.append("```")
    lines.append("")

    # Notes
    lines.append("## 注意事项")
    lines.append("")
    lines.append("- **issue 状态保护**：关联 issue 处于活跃状态（todo/in_progress/in_review/blocked）的 worktree 不会被自动删除，仅 done/backlog/cancelled 状态可删除")
    lines.append("- API 故障时默认保留 worktree（skip_reason=issue_status_unknown）")
    lines.append("- 未推送的 commits 或本地变更在删除后无法恢复")
    lines.append("- 完成后请在本 Issue 评论确认已处理的工作目录")

    return "\n".join(lines)


def build_mention_comment():
    lines = []
    lines.append("本地仓库巡检结果：")
    lines.append("")
    lines.append("**已 push + git 干净（自动删除）：**")
    for e in deleted:
        status = e.get("delete_status", "")
        suffix = f" （{status}）" if status != "success" else ""
        lines.append(f"- {e.get('hash', '')}{suffix}")
    lines.append("")

    if need_push_decision:
        lines.append("**需要决策的仓库：**")
        lines.append("")
        lines.append("git 干净 + 未 push：")
        for e in need_push_decision:
            mention = get_mention_link(e)
            lines.append(
                f"- {e.get('hash', '')}（{e.get('branch', '')}，{e.get('unpushed_commits', 0)} 个未推送 commits）→ {mention}"
            )
        lines.append("")

    if need_changes_decision:
        lines.append("git 有未提交变更：")
        for e in need_changes_decision:
            mention = get_mention_link(e)
            lines.append(
                f"- {e.get('hash', '')}（{e.get('branch', '')}，git 状态：{e.get('git_status_summary', '')}）→ {mention}"
            )
        lines.append("")

    if skipped_active:
        lines.append("**因 issue 活跃而跳过的仓库：**")
        for e in skipped_active:
            mention = get_mention_link(e)
            lines.append(
                f"- {e.get('hash', '')}（{e.get('branch', '')}，issue 状态：{e.get('issue_status', 'N/A')}）→ {mention}"
            )
        lines.append("")

    lines.append("请相关 Agent 评估并做出决策。")
    return "\n".join(lines)


def build_report_comment(summary_issue_id=None):
    lines = []
    lines.append("本轮本地仓库巡检结果：")
    lines.append("")
    lines.append(f"- 检查了 **{total}** 个本地仓库")
    lines.append(
        f"- 已 push + git 干净（自动删除）：**{len(deleted)}** 个"
    )

    if need_push_decision or need_changes_decision:
        lines.append(
            f"- git 干净 + 未 push（需 agent 决策）：**{len(need_push_decision)}** 个"
        )
        lines.append(
            f"- git 有未提交变更（需 agent 决策）：**{len(need_changes_decision)}** 个"
        )
        if summary_issue_id:
            lines.append(
                f"- 汇总 Issue：[汇总](mention://issue/{summary_issue_id})"
            )
    else:
        lines.append("- 需 agent 决策：**0** 个")

    lines.append(f"- 无仓库：**{len(no_repo)}** 个（仅记录）")

    skipped_count = sum(1 for e in entries if e.get("skipped"))
    lines.append(f"- 跳过（当前工作目录）：**{skipped_count}** 个")
    if skipped_active:
        lines.append(f"- 因 issue 活跃而跳过：**{len(skipped_active)}** 个")
    lines.append("")

    if deleted:
        lines.append("已删除仓库明细：")
        for e in deleted:
            status = e.get("delete_status", "")
            lines.append(f"- {e.get('hash', '')}: {status}")

    return "\n".join(lines)


# --- Main execution ---

if __name__ == "__main__":
    args = parse_args()

    # SEE-956 H10+L3: per-script PID lock (a second cron of THIS script no-ops) +
    # workspace-wide mutex (coordinates with other autopilots that touch the same
    # worktrees / bare repo). Acquired explicitly rather than via `with` so the
    # existing scan body keeps its indentation; both are OS-level file locks that
    # auto-release on process exit, so exception paths are still safe. The normal
    # path releases them at the end of the file.
    _pid_lock = PidFileLock(os.path.join(tempfile.gettempdir(), "local_repo_check.pid"))
    if not _pid_lock.acquire():
        sys.exit(1)
    _ws_mutex = WorkspaceMutex(label="local_repo_check")
    _ws_mutex.acquire()

    workspace_root = args.workspace_root
    current_hash = args.current_hash
    dry_run = args.dry_run
    execution_issue_id = args.execution_issue_id or os.environ.get("EXECUTION_ISSUE_ID", "")
    # SEE-1224 #4: --kill-switch forces a read-only pass. Under kill-switch the
    # deletion phase is skipped entirely — worktrees that would have been
    # auto-deleted are surfaced in need_push_decision so a human still sees the
    # same decision list without any git worktree remove / branch -D executing.
    kill_switch = str(args.kill_switch).lower() == "true"

    # Auto-detect current_hash if not provided
    if not current_hash:
        current_hash = os.environ.get("MULTICA_WORKTREE_HASH", "")
        if not current_hash and workspace_root:
            cwd = os.getcwd()
            # Normalize path separators for comparison
            ws_root_norm = workspace_root.replace("/", os.sep).replace("\\", os.sep)
            prefix = ws_root_norm + os.sep
            if cwd.startswith(prefix):
                rel = cwd[len(prefix):]
                current_hash = rel.split(os.sep)[0]

    if not os.path.isdir(workspace_root):
        print(json.dumps({"error": f"Workspace root not found: {workspace_root}"}), file=sys.stderr)
        sys.exit(1)

    # ============================================================
    # Phase 1: Scan worktrees
    # ============================================================

    entries = []
    for name in sorted(os.listdir(workspace_root)):
        wt_dir = os.path.join(workspace_root, name)
        if not os.path.isdir(wt_dir):
            continue
        workdir = os.path.join(wt_dir, "workdir")
        if not os.path.isdir(workdir):
            continue

        entry = {"hash": name}
        meta_path = os.path.join(wt_dir, ".gc_meta.json")
        if os.path.isfile(meta_path):
            try:
                with open(meta_path, "r", encoding="utf-8") as f:
                    meta = json.load(f)
                entry["issue_id"] = meta.get("issue_id", "")
            except (json.JSONDecodeError, IOError):
                entry["issue_id"] = ""
        else:
            entry["issue_id"] = ""
            entry["note"] = "no .gc_meta.json"

        entries.append(entry)

    total = len(entries)
    deleted = []
    need_push_decision = []
    need_changes_decision = []
    no_repo = []
    skipped_active = []

    bare_repo = find_bare_repo_path(workspace_root)

    for entry in entries:
        h = entry["hash"]
        wt_dir = os.path.join(workspace_root, h)
        workdir = os.path.join(wt_dir, "workdir")

        # Skip current worktree
        if h == current_hash:
            entry["skipped"] = True
            entry["skip_reason"] = "current_worktree"
            no_repo.append(entry)
            continue

        # Find git repo inside workdir (could be nested)
        git_repo_path = None
        for root, dirs, files in os.walk(workdir):
            depth = root[len(workdir):].count(os.sep)
            if depth > 2:
                dirs.clear()
                continue
            if ".git" in dirs or ".git" in files:
                git_repo_path = root
                break

        if git_repo_path is None:
            no_repo.append(entry)
            continue

        # Check git repo validity
        ok, _ = run_ok(f'git -C "{git_repo_path}" rev-parse --git-dir')
        if not ok:
            entry["note"] = "invalid git repo"
            no_repo.append(entry)
            continue

        # Branch (SEE-956 H7: detached HEAD has no resolvable branch, so it
        # cannot be safely mapped to a remote ref — retain it for manual review
        # instead of auto-deleting).
        _, branch = run_ok(f'git -C "{git_repo_path}" rev-parse --abbrev-ref HEAD')
        entry["branch"] = branch
        if not branch or branch == "HEAD":
            entry["skipped"] = True
            entry["skip_reason"] = "detached_head"
            skipped_active.append(entry)
            continue

        # Upstream ref
        remote_ref = f"origin/{branch}"
        entry["upstream_ref"] = remote_ref

        # SEE-956 H6: verify origin/{branch} actually exists before trusting the
        # unpushed count. A branch that was never pushed has no origin/{branch};
        # `git log origin/{branch}..HEAD` then fails silently and reports 0
        # unpushed commits, which previously green-lit auto-deletion of work that
        # had never reached the remote.
        rr_ok, _ = run_ok(
            f'git -C "{git_repo_path}" rev-parse --verify --quiet "{remote_ref}"'
        )
        remote_ref_exists = rr_ok
        entry["remote_ref_exists"] = remote_ref_exists

        # Git status (SEE-956 H4: untracked files — the `??` entries — do not
        # count as "dirty". Build artifacts and scratch files routinely appear as
        # untracked and must not block cleanup of an otherwise-clean, pushed
        # worktree. The full status is still recorded for visibility.)
        status_short = run(f'git -C "{git_repo_path}" status --short')
        if status_short:
            entry["git_status_summary"] = status_short.replace("\n", "; ")
        tracked_changes = [
            line for line in status_short.splitlines()
            if line.strip() and not line.startswith("??")
        ]
        is_clean = (len(tracked_changes) == 0)

        # Unpushed commits
        if remote_ref_exists:
            unpushed_raw = run(f'git -C "{git_repo_path}" log {remote_ref}..HEAD --oneline')
        else:
            # Branch not on the remote — count commits ahead of origin/master so
            # the decision bucket still surfaces a meaningful number.
            unpushed_raw = run(f'git -C "{git_repo_path}" log origin/master..HEAD --oneline')
        unpushed_lines = [l for l in unpushed_raw.splitlines() if l.strip()] if unpushed_raw else []
        entry["unpushed_commits"] = len(unpushed_lines)

        # Issue status and assignee lookup
        issue_id = entry.get("issue_id", "")
        issue_status = ""
        assignee_id = ""
        if issue_id:
            issue_raw = run(f'multica issue get {issue_id} --output json', timeout=15)
            if issue_raw:
                try:
                    issue_data = json.loads(issue_raw)
                    issue_status = issue_data.get("status", "")
                    assignee_id = issue_data.get("assignee_id", "")
                except (json.JSONDecodeError, KeyError):
                    pass

        # API failure conservative handling
        api_failed = bool(issue_id and not issue_status)
        if api_failed:
            entry["issue_status"] = "N/A"
            entry["note"] = entry.get("note", "") + " | issue_status_fetch_failed"
        else:
            entry["issue_status"] = issue_status if issue_status else "N/A"

        entry["assignee_id"] = assignee_id

        # L2: Issue status guard — retain worktree if the linked issue is still
        # active or its status could not be confirmed. This has ABSOLUTE
        # priority over the git-deletable decision (SEE-956): an active issue
        # means someone may still be working here, so we never auto-delete it
        # regardless of push/clean state. Previously this only ran when the
        # worktree was already git-deletable, which let an active issue's
        # never-pushed worktree slip past the guard into need_push_decision.
        if api_failed:
            entry["skipped"] = True
            entry["skip_reason"] = "issue_status_unknown"
            skipped_active.append(entry)
            continue
        if issue_id and entry["issue_status"] not in DELETABLE_ISSUE_STATUSES and entry["issue_status"] != "N/A":
            entry["skipped"] = True
            entry["skip_reason"] = "issue_active"
            skipped_active.append(entry)
            continue

        # A worktree is only auto-deletable when clean AND pushed (H6: the remote
        # ref must exist) AND no unpushed commits remain.
        deletable = is_clean and remote_ref_exists and entry["unpushed_commits"] == 0

        # Categorize
        if deletable and kill_switch:
            # Kill-switch: suppress deletion and surface as need_push_decision so
            # the operator still sees which worktrees would have been removed.
            entry["delete_status"] = "skipped_kill_switch"
            need_push_decision.append(entry)
        elif deletable:
            if dry_run:
                entry["delete_status"] = "dry_run"
            else:
                wt_lockfd: int | None = None
                try:
                    # SEE-956 C4: per-worktree advisory lock + git worktree-list
                    # cross-check so a concurrently-used worktree is never torn down.
                    lock_status, wt_lockfd = acquire_worktree_delete_lock(wt_dir, bare_repo)
                    if lock_status == "ok":
                        shutil.rmtree(wt_dir)
                        entry["delete_status"] = "success"
                        # B1: Sync cleanup branch in bare repo (agent/* only)
                        branch_name = entry.get("branch", "")
                        if bare_repo and branch_name.startswith("agent/"):
                            # Check the branch is not used by any active worktree
                            wt_list = run(
                                f'git -C "{bare_repo}" worktree list --porcelain',
                                timeout=15,
                            )
                            branch_in_use = any(
                                line[len("branch "):].replace("refs/heads/", "", 1) == branch_name
                                for line in wt_list.splitlines()
                                if line.startswith("branch ")
                            )
                            if not branch_in_use:
                                ok, _ = run_ok(
                                    f'git -C "{bare_repo}" branch -D "{branch_name}"',
                                    timeout=15,
                                )
                                entry["branch_cleanup"] = "deleted" if ok else "failed"
                            else:
                                entry["branch_cleanup"] = "skipped_active"
                    else:
                        entry["delete_status"] = lock_status
                except Exception as e:
                    entry["delete_status"] = f"failed: {e}"
                finally:
                    if wt_lockfd is not None:
                        try:
                            os.close(wt_lockfd)
                        except OSError:
                            pass
            deleted.append(entry)
        elif is_clean and (entry["unpushed_commits"] > 0 or not remote_ref_exists):
            # SEE-956 H6: a clean worktree whose branch was never pushed
            # (remote_ref_exists is False) also needs a push decision — we
            # must not auto-delete work that has never reached the remote.
            need_push_decision.append(entry)
        else:
            need_changes_decision.append(entry)

    # --- B2: Worktree prune after cleanup loop ---
    bare_repo_pruned = False
    if bare_repo and not dry_run and not kill_switch:
        ok, _ = run_ok(f'git -C "{bare_repo}" worktree prune', timeout=30)
        bare_repo_pruned = ok
    elif bare_repo and (dry_run or kill_switch):
        bare_repo_pruned = None  # suppressed indicator

    # --- B3: Batch cleanup orphan agent/* branches ---
    orphan_branches_cleaned = 0
    orphan_branches_list = []
    if bare_repo:
        # Get active worktree branches (normalized to short names)
        wt_list = run(
            f'git -C "{bare_repo}" worktree list --porcelain', timeout=15
        )
        active_branches = set()
        for line in wt_list.splitlines():
            if line.startswith("branch "):
                short = line[len("branch "):].replace("refs/heads/", "", 1)
                active_branches.add(short)

        # Get all agent/* branches (already short names)
        agent_branches_raw = run(
            f'git -C "{bare_repo}" branch --list "agent/*"', timeout=30
        )
        agent_branches = [
            line.strip().lstrip("* ").strip()
            for line in agent_branches_raw.splitlines()
            if line.strip()
        ]

        # Orphan = agent branches not in active worktrees
        orphans = [b for b in agent_branches if b not in active_branches]
        orphan_branches_list = orphans

        if not dry_run and not kill_switch:
            for branch_name in orphans:
                ok, _ = run_ok(
                    f'git -C "{bare_repo}" branch -D "{branch_name}"', timeout=15
                )
                if ok:
                    orphan_branches_cleaned += 1
        else:
            orphan_branches_cleaned = -1  # suppressed (dry-run or kill-switch) indicator

    result = {
        "total_worktrees": total,
        "current_worktree": current_hash or "unknown",
        "deleted_worktrees": [clean(e) for e in deleted],
        "need_push_decision": [clean(e) for e in need_push_decision],
        "need_changes_decision": [clean(e) for e in need_changes_decision],
        "skipped_active_issues": [clean(e) for e in skipped_active],
        "no_repo": [clean(e) for e in no_repo],
        "bare_repo": bare_repo,
        "worktree_pruned": bare_repo_pruned,
        "orphan_branches_list": orphan_branches_list,
        "orphan_branches_cleaned": orphan_branches_cleaned,
        "kill_switch": kill_switch,
    }

    # ============================================================
    # Phase 2: Create summary issue, notify, report, mark done
    # ============================================================

    # Collect assignee info for entries that need decision
    all_decision_entries = need_push_decision + need_changes_decision
    assignee_map = {}  # issue_id -> assignee_id
    for entry in all_decision_entries:
        iid = entry.get("issue_id", "")
        if iid and iid not in assignee_map:
            ok, raw = multica_cli(f'multica issue get {iid} --output json', timeout=15)
            if ok and raw:
                try:
                    data = json.loads(raw)
                    assignee_map[iid] = data.get("assignee_id", "")
                except (json.JSONDecodeError, KeyError):
                    pass

    # --------------------------------------------------
    # Execute Phase 2
    # --------------------------------------------------

    if not dry_run and not kill_switch:
        if not need_push_decision and not need_changes_decision:
            # Phase 3: Silent completion
            if execution_issue_id:
                ok, _ = multica_stdin_cmd(
                    f"multica issue comment add {execution_issue_id} --content-stdin",
                    build_report_comment(),
                    timeout=30,
                )
                if not ok:
                    log_error("Failed to post silent-completion report comment")
                ok, _ = multica_cli(
                    f"multica issue status {execution_issue_id} done", timeout=15
                )
                if not ok:
                    log_error("Failed to mark execution issue as done")
        else:
            # Phase 2: Create summary issue
            summary_desc = build_summary_description()

            # SEE-1109: date-suffixed title keeps each daily summary unique so the
            # server title-dedup never matches historical issues (SEE-1108 proved the
            # dated title creates cleanly); --allow-duplicate is a same-day safety net.
            # SEE-1181: drop the hard `--assignee Atlas` — the mention comment below
            # already routes each decision item to its issue's actual assignee, so a
            # blanket Atlas assignment only added noise on days with no real decisions.
            date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
            ok, out = multica_stdin_cmd(
                f'multica issue create --title "本地仓库巡检：以下仓库需要决策 {date_str}" '
                f'--allow-duplicate --project {PROJECT_ID} --description-stdin',
                summary_desc,
                timeout=30,
            )

            summary_issue_id = ""
            if ok and out:
                # Try to parse issue ID from JSON output
                try:
                    data = json.loads(out)
                    summary_issue_id = data.get("id", "")
                except (json.JSONDecodeError, KeyError):
                    # Fallback: try to extract UUID from output
                    m = re.search(
                        r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
                        out,
                    )
                    if m:
                        summary_issue_id = m.group(0)

            if summary_issue_id:
                # Add labels
                for label_id in (INFRA_LABEL, CHORE_LABEL):
                    ok, _ = multica_cli(
                        f"multica issue label add {summary_issue_id} {label_id}",
                        timeout=15,
                    )
                    if not ok:
                        log_error(f"Failed to add label {label_id} to summary issue")

                # Add mention comment
                mention_comment = build_mention_comment()
                ok, _ = multica_stdin_cmd(
                    f"multica issue comment add {summary_issue_id} --content-stdin",
                    mention_comment,
                    timeout=30,
                )
                if not ok:
                    log_error("Failed to post mention comment to summary issue")
            else:
                log_error("Failed to create summary issue")

            # Report on execution issue
            if execution_issue_id:
                ok, _ = multica_stdin_cmd(
                    f"multica issue comment add {execution_issue_id} --content-stdin",
                    build_report_comment(summary_issue_id),
                    timeout=30,
                )
                if not ok:
                    log_error("Failed to post report comment to execution issue")

                # Mark done
                ok, _ = multica_cli(
                    f"multica issue status {execution_issue_id} done", timeout=15
                )
                if not ok:
                    log_error("Failed to mark execution issue as done")
    else:
        mode = "KILL_SWITCH" if kill_switch else "DRY_RUN"
        print(f"[{mode}] Phase 2 skipped -- no CLI write operations executed.", file=sys.stderr)

    print(json.dumps(result, indent=2, ensure_ascii=False))

    # SEE-956 H10+L3: release the per-script and workspace locks on normal exit.
    _ws_mutex.release()
    _pid_lock.release()

    # SEE-1109: a non-zero exit surfaces Phase 2 write failures to the autopilot
    # scheduler instead of the silent exit-0 that previously masked them.
    if _phase2_error_count:
        sys.exit(2)