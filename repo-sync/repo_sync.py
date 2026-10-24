#!/usr/bin/env python3
"""Repo sync logic for local sync (pull-only; SEE-1430b 语义改向).
Former bidirectional auto-sync: all upward (push/forward) semantics retired.

Four-state model:
  SYNCED       : local == remote
  LOCAL_AHEAD  : local ahead of remote (push)
  REMOTE_AHEAD : remote ahead of local (pull)
  DIVERGED     : both ahead of merge-base (block + alert)

Usage:
  python3 repo_sync.py [--config path] [--direction pull-only] [--dry-run] [--quiet]
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import time
from enum import Enum
from pathlib import Path
from typing import Any

if sys.platform != "win32":
    import fcntl


# ---------------------------------------------------------------------------
# Constants / Enums
# ---------------------------------------------------------------------------


class SyncState(str, Enum):
    SYNCED = "SYNCED"
    LOCAL_AHEAD = "LOCAL_AHEAD"
    REMOTE_AHEAD = "REMOTE_AHEAD"
    DIVERGED = "DIVERGED"


class Direction(str, Enum):
    # SEE-1430b 语义改向（Owner 2026-10-19 指令）：向上同步整体退役，仅保留
    # sync-to-local（pull-only）。bidirectional/push-only 传入即报错。
    PULL_ONLY = "pull-only"


class ConflictResolution(str, Enum):
    REBASE_FIRST = "rebase_first"
    MERGE_FIRST = "merge_first"
    BLOCK_ONLY = "block_only"


DEFAULT_CONFIG_PATH = Path(__file__).with_name("repos.d") / "kol.json"
LOG_FORMAT = "%(asctime)s [%(levelname)s] %(message)s"


def _resolve_repo_path(raw: str) -> str:
    """SEE-1430b 注册制：repo_path 直写实值，仅做 ~ 展开（__KOL_REPO_ROOT__ 哨兵废除）。"""
    return os.path.expanduser(raw)


# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------


def load_config(config_path: Path | str | None = None) -> dict[str, Any]:
    path = Path(config_path) if config_path else DEFAULT_CONFIG_PATH
    with open(path, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    # Resolve repo_path (expanduser only; registration system writes real values) before deriving
    # relative paths against it.
    repo_root = Path(_resolve_repo_path(cfg["repo_path"]))
    cfg["repo_path"] = str(repo_root)
    for key in ("log_dir", "state_file"):
        val = cfg.get(key, "")
        if val and not Path(val).is_absolute():
            cfg[key] = str(repo_root / val)
    return cfg


# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------


def setup_logging(
    config: dict[str, Any], quiet: bool = False, dry_run: bool = False,
    file_log: bool = True,
) -> logging.Logger:
    logger = logging.getLogger("repo_sync")
    logger.setLevel(logging.DEBUG)

    # Clear existing handlers in case of repeated calls
    logger.handlers = []

    if not quiet:
        handler = logging.StreamHandler(sys.stdout)
        handler.setLevel(logging.DEBUG)
        handler.setFormatter(logging.Formatter(LOG_FORMAT))
        logger.addHandler(handler)

    # File log writes into the checkout (log_dir defaults relative to
    # repo_path); dry-run (SPEC-012) skips it unless the caller explicitly
    # placed log_dir outside repo_path (test harnesses).
    if file_log and (
        not dry_run
        or not _path_inside_repo(config, config.get("log_dir", ""))
    ):
        log_dir = Path(config["log_dir"])
        log_dir.mkdir(parents=True, exist_ok=True)
        file_handler = logging.FileHandler(
            log_dir / "repo-sync.log", encoding="utf-8"
        )
        file_handler.setLevel(logging.DEBUG)
        file_handler.setFormatter(logging.Formatter(LOG_FORMAT))
        logger.addHandler(file_handler)

    return logger


def _path_inside_repo(config: dict[str, Any], raw_path: str) -> bool:
    """True when raw_path resolves inside repo_path (dry-run write boundary:
    SPEC-012 requires zero writes into the target checkout, while state/log
    paths explicitly placed outside (test harnesses) stay writable)."""
    if not raw_path:
        return False
    repo_root = Path(os.path.expanduser(config["repo_path"])).resolve()
    try:
        candidate = Path(raw_path).resolve()
    except OSError:
        return True
    try:
        candidate.relative_to(repo_root)
    except ValueError:
        return False
    return True


def write_state(config: dict[str, Any], state: dict[str, Any]) -> None:
    # dry-run 是纯观测语义（SPEC-012）：state 决断不得落盘进 repo_path，
    # 否则对规范检出的验收会留下 .dev/logs/ 未跟踪残留；显式指到外部的
    # state 路径（测试夹具）不在边界内，照写。
    if state.get("dry_run", False) and _path_inside_repo(
        config, config.get("state_file", "")
    ):
        return
    state_path = Path(config["state_file"])
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state["timestamp"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with open(state_path, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)


# ---------------------------------------------------------------------------
# File lock (flock)
# ---------------------------------------------------------------------------


def _posix_reclaim_stale(fd) -> bool | None:
    """尝试回收死持有者的 flock 锁。

    返回 True=已抢到并清零；False=非 stale（活持有者或读取失败）；
    None=判定为 stale 但抢锁失败（调用方按模式决定重试或放弃）。
    """
    try:
        os.lseek(fd, 0, os.SEEK_SET)
        existing = os.read(fd, 32).decode("utf-8").strip()
        if not existing.isdigit():
            return False
        try:
            os.kill(int(existing), 0)
        except OSError:
            # PID is dead — stale lock, overwrite (non-blocking)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except (OSError, BlockingIOError):
                return None
            os.lseek(fd, 0, os.SEEK_SET)
            os.truncate(fd, 0)
            return True
        return False
    except (OSError, ValueError):
        return False


def acquire_lock(lock_path: str, timeout: float = 0.0) -> int | None:
    """Acquire exclusive file lock. Returns fd or None on failure.

    When LOCK_NB fails, checks if the lock holder PID is still alive.
    If the PID is dead, treats the lock as stale and re-acquires it.
    """
    if sys.platform == "win32":
        # Windows: use msvcrt for file locking
        import msvcrt

        try:
            fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
            if timeout > 0:
                end = time.time() + timeout
                while time.time() < end:
                    try:
                        msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
                        return fd
                    except OSError:
                        time.sleep(0.2)
                os.close(fd)
                return None
            msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
            return fd
        except OSError:
            return None

    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        if timeout > 0:
            end = time.time() + timeout
            while time.time() < end:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    return fd
                except (OSError, BlockingIOError):
                    # Check for stale lock
                    if _posix_reclaim_stale(fd) is True:
                        return fd
                    time.sleep(0.2)
            os.close(fd)
            return None
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except (OSError, BlockingIOError):
        # Immediate (non-blocking) acquisition failed — check stale
        if _posix_reclaim_stale(fd) is True:
            return fd
        os.close(fd)
        return None


def release_lock(fd: int | None, lock_path: str) -> None:
    if fd is None:
        return
    try:
        if sys.platform == "win32":
            import msvcrt

            msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
        else:
            fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
    except OSError:
        pass
    try:
        os.remove(lock_path)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Git helpers
# ---------------------------------------------------------------------------


def git_run(
    repo_path: str, args: list[str], check: bool = True, timeout: int | None = None
) -> subprocess.CompletedProcess[str]:
    cmd = ["git", "-C", repo_path] + args
    kwargs: dict[str, Any] = {
        "capture_output": True,
        "text": True,
        "check": check,
        "encoding": "utf-8",
        "errors": "replace",
    }
    if timeout is not None:
        kwargs["timeout"] = timeout
    return subprocess.run(cmd, **kwargs)


# ---------------------------------------------------------------------------
# Orphan gitlink helpers
# ---------------------------------------------------------------------------


def detect_orphan_gitlinks(repo_path: str, timeout: int | None = None) -> list[str]:
    """Return list of orphan gitlink paths (mode 160000 but no .gitmodules entry)."""
    orphan_paths: list[str] = []
    r = git_run(repo_path, ["ls-files", "--stage"], check=False, timeout=timeout)
    if r.returncode != 0:
        return orphan_paths

    # Parse registered submodule paths from .gitmodules if present
    registered: set[str] = set()
    gitmodules_path = Path(repo_path) / ".gitmodules"
    if gitmodules_path.is_file():
        try:
            content = gitmodules_path.read_text(encoding="utf-8")
            for line in content.splitlines():
                line = line.strip()
                if line.startswith("path"):
                    parts = line.split("=", 1)
                    if len(parts) == 2:
                        registered.add(parts[1].strip())
        except OSError:
            pass

    for line in r.stdout.strip().splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[0] == "160000":
            path = parts[3] if len(parts) > 3 else parts[-1]
            if path not in registered:
                orphan_paths.append(path)

    return orphan_paths


def remove_orphan_gitlink(
    repo_path: str, path: str, timeout: int | None = None
) -> tuple[bool, str]:
    """Remove an orphan gitlink from the index."""
    r = git_run(repo_path, ["rm", "--cached", path], check=False, timeout=timeout)
    if r.returncode == 0:
        return True, f"removed orphan gitlink: {path}"
    return False, f"failed to remove orphan gitlink {path}: {r.stderr.strip()}"


def _is_gitlink_related_error(stderr: str) -> bool:
    """Check if stderr indicates a submodule/gitlink related failure."""
    indicators = ["could not write index", "submodule", "gitlink"]
    err_lower = stderr.lower()
    return any(ind in err_lower for ind in indicators)


def _cleanup_gitlinks_and_retry_stash(
    repo_path: str, stash_cmd: list[str], error_output: str, timeout: int | None = None
) -> subprocess.CompletedProcess[str] | None:
    """If error_output indicates a gitlink issue, clean orphans and retry stash.

    Returns the retry CompletedProcess if cleanup was performed,
    or None if the error was not gitlink-related or no orphans found.
    """
    if not _is_gitlink_related_error(error_output):
        return None
    orphans = detect_orphan_gitlinks(repo_path, timeout=timeout)
    if not orphans:
        return None
    for orphan_path in orphans:
        remove_orphan_gitlink(repo_path, orphan_path, timeout=timeout)
    return git_run(repo_path, stash_cmd, check=False, timeout=timeout)


def _try_stash_with_recovery(
    repo_path: str, stash_on_dirty: bool, timeout: int | None = None
) -> tuple[bool, str, bool]:
    """Attempt stash; on gitlink-related failure, clean orphan gitlinks and retry once."""
    ok, msg, had_stash = do_stash_if_dirty(
        repo_path, stash_on_dirty, recovery=False, timeout=timeout
    )
    if ok or had_stash:
        return ok, msg, had_stash

    # Stash failed — try gitlink cleanup and retry
    stash_cmd = ["stash", "push", "--include-untracked", "-m", "auto-sync-stash"]
    retry = _cleanup_gitlinks_and_retry_stash(
        repo_path, stash_cmd, msg, timeout=timeout
    )
    if retry is not None:
        if retry.returncode == 0:
            return True, "stashed (after gitlink cleanup)", True
        return (
            False,
            f"stash failed after gitlink cleanup: {retry.stderr.strip()}",
            False,
        )

    return ok, msg, had_stash


def _is_transient_network_error(stderr: str) -> bool:
    """Check if stderr indicates a transient network/TLS error worth retrying."""
    indicators = [
        "gnutls",
        "handshake failed",
        "tls connection",
        "could not resolve host",
        "connection timed out",
        "operation timed out",
        "network is unreachable",
        "failed to connect",
        "connection reset",
        "ssl",
    ]
    err_lower = stderr.lower()
    return any(ind in err_lower for ind in indicators)


def classify_error(message: str) -> str:
    """Classify an error as 'transient' or 'persistent' for circuit-breaker logic.

    Transient errors are expected to self-heal on retry (network hiccups,
    temporary file locks, concurrent worktree occupation). Persistent errors
    require manual intervention or code changes (merge conflicts, corrupted
    state, disabled features, in-progress git operations).
    """
    msg = message.lower()

    # Transient indicators (will self-heal on retry)
    transient_indicators = [
        "gnutls",
        "handshake failed",
        "tls connection",
        "could not resolve host",
        "connection timed out",
        "operation timed out",
        "network is unreachable",
        "failed to connect",
        "connection reset",
        "ssl",
        "index.lock",
        "file exists",
        "resource temporarily unavailable",
        "cannot lock ref",
        "could not lock",
        "another worktree",  # concurrent worktree occupation
        "checked out in another worktree",
        "is being checked out",
    ]
    if any(ind in msg for ind in transient_indicators):
        return "transient"

    # Persistent indicators (require human action)
    persistent_indicators = [
        "stash pop conflicted",
        "needs manual resolution",
        "unmerged",
        "diverged",
        "manual intervention",
        "stash_on_dirty disabled",
        "block_only",
        "merge/rebase/cherry-pick in progress",
        "submodule in intermediate",
        "config branch is",
        "switch to master failed",
        "would be overwritten by checkout",
        "untracked working tree files would be overwritten",
        "working tree dirty",
        "stash failed",
    ]
    if any(ind in msg for ind in persistent_indicators):
        return "persistent"

    # Default: treat unknown errors as persistent so they don't loop forever
    return "persistent"


# ---------------------------------------------------------------------------
# Branch guard helpers (SEE-869: ensure the main repo sits on its registered branch before sync)
# ---------------------------------------------------------------------------


def get_current_branch(repo_path: str, timeout: int | None = None) -> str:
    """Return current branch name; 'HEAD' for detached HEAD; '' on error."""
    r = git_run(
        repo_path, ["rev-parse", "--abbrev-ref", "HEAD"], check=False, timeout=timeout
    )
    return r.stdout.strip() if r.returncode == 0 else ""


def _resolve_git_dir(repo_path: str) -> Path | None:
    """Resolve the actual .git directory, following worktree gitdir pointers."""
    git_path = Path(repo_path) / ".git"
    if not git_path.exists():
        return None
    if git_path.is_dir():
        return git_path
    # Worktree: .git is a file like 'gitdir: /path/to/main/.git/worktrees/xxx'
    try:
        content = git_path.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    if not content.startswith("gitdir:"):
        return None
    raw = content[len("gitdir:") :].strip()
    resolved = Path(raw)
    if not resolved.is_absolute():
        resolved = (Path(repo_path) / resolved).resolve()
    return resolved if resolved.is_dir() else None


def has_git_operation_in_progress(repo_path: str) -> bool:
    """Check for in-progress merge/rebase/cherry-pick/revert operations."""
    git_dir = _resolve_git_dir(repo_path)
    if git_dir is None:
        return False
    for marker in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD"):
        if (git_dir / marker).exists():
            return True
    if (git_dir / "rebase-merge").is_dir() or (git_dir / "rebase-apply").is_dir():
        return True
    return False


def has_submodule_changes(repo_path: str, timeout: int | None = None) -> bool:
    """Detect submodule intermediate state (modified/conflict/uninitialized).

    Only runs if .gitmodules exists. Returns True on '+' (modified), 'U'
    (conflict), or '-' (uninitialized) status from `git submodule status`.
    """
    if not (Path(repo_path) / ".gitmodules").is_file():
        return False
    r = git_run(
        repo_path, ["submodule", "status"], check=False, timeout=timeout
    )
    if r.returncode != 0:
        return False
    for line in r.stdout.splitlines():
        if not line:
            continue
        if line[0] in ("+", "U", "-"):
            return True
    return False


def is_branch_worktree_occupied(
    repo_path: str, branch: str, timeout: int | None = None
) -> tuple[bool, str | None]:
    """Check if the registered branch is checked out in another worktree.

    Returns (occupied, other_worktree_path). Only triggers if a worktree OTHER
    than repo_path has refs/heads/<branch> as its checked-out branch.
    """
    r = git_run(
        repo_path, ["worktree", "list", "--porcelain"], check=False, timeout=timeout
    )
    if r.returncode != 0:
        return False, None
    try:
        current = Path(repo_path).resolve()
    except OSError:
        current = Path(repo_path)

    lines = r.stdout.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.startswith("worktree "):
            i += 1
            continue
        wt_path_str = line[len("worktree ") :].strip()
        wt_branch: str | None = None
        i += 1
        while i < len(lines) and lines[i].strip():
            sub = lines[i]
            if sub.startswith("branch "):
                wt_branch = sub[len("branch ") :].strip()
            i += 1
        if wt_branch == "refs/heads/%s" % branch:
            try:
                wt_path = Path(wt_path_str).resolve()
            except OSError:
                wt_path = Path(wt_path_str)
            if wt_path != current:
                return True, wt_path_str
    return False, None


def switch_to_branch(
    repo_path: str, branch: str, timeout: int | None = None
) -> tuple[bool, str]:
    """Switch to the registered branch; create it from origin/<branch> if absent."""
    r = git_run(repo_path, ["switch", branch], check=False, timeout=timeout)
    if r.returncode == 0:
        return True, "switched to %s" % branch
    err = r.stderr.strip() if r.stderr else ""
    lowered = err.lower()
    if (
        "invalid reference" in lowered
        or "did not match" in lowered
        or "unknown revision" in lowered
    ):
        r2 = git_run(
            repo_path,
            ["switch", "-c", branch, "origin/%s" % branch],
            check=False,
            timeout=timeout,
        )
        if r2.returncode == 0:
            return True, "created %s from origin/%s" % (branch, branch)
        return (
            False,
            r2.stderr.strip() if r2.stderr else "failed to create %s from origin/%s" % (branch, branch),
        )
    return False, err


def ensure_on_registered_branch(
    repo_path: str,
    branch: str,
    stash_on_dirty: bool,
    dry_run: bool,
    logger: logging.Logger,
    timeout: int | None = None,
) -> tuple[bool, str, bool]:
    """Ensure repo is on the registered branch before sync.

    Implements Archi's boundary-case matrix (SEE-869 Phase 2b):
      1. Config branch must be a protected default ('master' or 'main')
      2. Already on the registered branch → no-op
      3. In-progress merge/rebase/cherry-pick/revert → persistent failure
      4. Submodule intermediate state → persistent failure
      5. Registered branch checked out in another worktree → transient skip
      6. Dirty tree → stash once (or fail if stash_on_dirty disabled)
      7. Switch to the registered branch (handles detached HEAD/other branches)

    SEE-1440: branch is a parameter everywhere — a repo registered on main
    must never be switched to a non-existent origin/master.

    Returns (ok, message, had_stash). had_stash=True means the caller must
    `do_stash_pop()` after the sync body completes.

    dry_run=True: only detection and reporting — no stash/switch/pop.
    """
    # 1. Config validation (#10)
    # SEE-1430b: dev-forge itself registered on 'main' — accept both defaults.
    if branch not in ("master", "main"):
        return (
            False,
            f"config branch is '{branch}'; only 'master' or 'main' is supported for main-repo protection",
            False,
        )

    # 2. Current branch detection
    current = get_current_branch(repo_path, timeout=timeout)
    if not current:
        return False, "could not detect current branch", False
    if current == branch:
        return True, "already on %s" % branch, False

    blocked, reason = _branch_guard_blockers(repo_path, timeout=timeout)
    if blocked:
        return False, reason, False

    # 5. Worktree occupation (#7) — transient skip
    occupied, wt_path = is_branch_worktree_occupied(repo_path, branch, timeout=timeout)
    if occupied:
        return (
            False,
            f"{branch} is checked out in another worktree ({wt_path}); skipping",
            False,
        )

    # 6. Dirty tree stash (#1, pre-switch)
    is_dirty = is_working_tree_dirty(repo_path, timeout=timeout)
    if is_dirty and not stash_on_dirty:
        return False, "working tree dirty (stash_on_dirty disabled)", False

    # dry_run: report intent, do not mutate repo state
    if dry_run:
        action = "stash dirty tree and switch" if is_dirty else "switch"
        return (
            True,
            f"dry-run: would {action} from {current} to {branch}",
            False,
        )

    stash_ok, stash_msg, had_stash = _stash_dirty_before_switch(
        repo_path, stash_on_dirty, is_dirty, timeout=timeout
    )
    if not stash_ok:
        return False, stash_msg, False

    # 7. Switch to the registered branch (detached HEAD #2 / switch failure #9)
    switch_ok, switch_msg = switch_to_branch(repo_path, branch, timeout=timeout)
    if not switch_ok:
        if had_stash:
            do_stash_pop(repo_path, timeout=timeout)
        return False, f"switch to {branch} failed: {switch_msg}", False

    logger.info("branch guard: switched from %s to %s", current, branch)
    return True, f"switched from {current} to {branch}", had_stash


def _stash_dirty_before_switch(
    repo_path: str,
    stash_on_dirty: bool,
    is_dirty: bool,
    timeout: int | None = None,
) -> tuple[bool, str, bool]:
    """Guard 前置 stash：#1 单次 stash + 子模块中间态回滚。返回 (ok, message, had_stash)。"""
    if not is_dirty:
        return True, "", False
    stash_ok, stash_msg, had_stash = do_stash_if_dirty(
        repo_path, stash_on_dirty, timeout=timeout
    )
    if not stash_ok:
        return False, f"stash failed: {stash_msg}", False
    if had_stash and has_submodule_changes(repo_path, timeout=timeout):
        do_stash_pop(repo_path, timeout=timeout)
        return False, "submodule in intermediate state; manual cleanup required", False
    return True, "", had_stash


def _count_unpushed_commits(
    repo_path: str, remote: str, branch: str, timeout: int | None = None
) -> int:
    """LOCAL_AHEAD 告警幅度：origin/<branch>..HEAD 未推送提交数（探测失败记 -1）。"""
    r = git_run(
        repo_path,
        ["rev-list", "--count", f"{remote}/{branch}..{branch}"],
        check=False,
        timeout=timeout,
    )
    if r.returncode != 0:
        return -1
    try:
        return int(r.stdout.strip() or "0")
    except ValueError:
        return -1


def _handle_remote_ahead(
    config: dict[str, Any],
    logger: logging.Logger,
    direction: Direction,
    dry_run: bool,
    subprocess_timeout: int | None,
) -> dict[str, Any]:
    """REMOTE_AHEAD path: pull ff-only — the core of sync-to-local.

    SEE-1406 前移移植（自 gqt 2315 行硬化版）：run_sync 的 REMOTE_AHEAD 内联块
    原样抽取为独立函数，供结构断言测试检查。SEE-1430b 后本函数即新语义核心
    （向下 sync）；guard 判式改写为显式 PULL_ONLY 放行（Direction 已单值化，
    行为等价：非 pull-only 一律不 pull）。
    """
    repo_path = config["repo_path"]
    remote = config["remote"]
    branch = config["branch"]
    stash_on_dirty = config.get("stash_on_dirty", True)
    result: dict[str, Any] = {
        "action": "pull",
        "state": SyncState.REMOTE_AHEAD.value,
        "success": True,
        "message": "",
        "dry_run": dry_run,
    }
    if direction != Direction.PULL_ONLY:
        result["action"] = "none"
        result["message"] = "remote ahead, but direction restricts to push-only"
        logger.info("remote ahead, skipped per direction")
        return result
    if dry_run:
        result["message"] = "dry-run: would pull"
        logger.info("dry-run: would pull")
        return result
    ok, msg = do_pull_ff_only(
        repo_path,
        remote,
        branch,
        stash_on_dirty,
        timeout=subprocess_timeout,
    )
    result["success"] = ok
    result["message"] = msg
    if ok:
        logger.info("pull success: %s", msg)
    else:
        result["error_category"] = classify_error(msg)
        logger.error("pull failed: %s (category=%s)", msg, result["error_category"])
    return result


def _branch_guard_blockers(
    repo_path: str, timeout: int | None = None
) -> tuple[bool, str]:
    """Blocking preconditions for the branch guard (boundary matrix #3/#4).

    Returns (blocked, reason). Worktree occupation and dirty-tree cases are
    handled by the caller (they are skip/stash cases, not hard blockers).

    SEE-1406 前移移植（自 gqt 2315 行硬化版，c7649f1/791fa4f 同源）：guard
    阻断项抽取为独立函数，便于单测与 dry-run 判定复用；行为与内联版一致。
    """
    # 3. In-progress operation (#3)
    if has_git_operation_in_progress(repo_path):
        return (
            True,
            "merge/rebase/cherry-pick in progress; abort required before switching",
        )
    # 4. Submodule intermediate state (#4)
    if has_submodule_changes(repo_path, timeout=timeout):
        return (
            True,
            "submodule in intermediate state; manual cleanup required",
        )
    return False, ""


def git_fetch(
    repo_path: str, remote: str, timeout: int | None = None
) -> tuple[bool, str]:
    # --prune removes stale remote-tracking refs (e.g. remotes/origin/agent/*)
    # when they are deleted on the remote. SEE-1033
    r = git_run(repo_path, ["fetch", "--prune", remote], check=False, timeout=timeout)
    return r.returncode == 0, r.stderr.strip() if r.stderr else r.stdout.strip()


def git_fetch_with_retry(
    repo_path: str,
    remote: str,
    timeout: int | None = None,
    retries: int = 3,
    retry_delay: float = 2.0,
) -> tuple[bool, str]:
    """Fetch with retry on transient network errors."""
    for attempt in range(1, retries + 1):
        ok, err = git_fetch(repo_path, remote, timeout=timeout)
        if ok:
            return True, err
        if _is_transient_network_error(err) and attempt < retries:
            time.sleep(retry_delay)
            continue
        return ok, err
    return False, err


def get_sha(repo_path: str, ref: str, timeout: int | None = None) -> str | None:
    r = git_run(repo_path, ["rev-parse", ref], check=False, timeout=timeout)
    return r.stdout.strip() if r.returncode == 0 else None


def detect_sync_state(
    repo_path: str, remote: str, branch: str, timeout: int | None = None
) -> SyncState:
    local_sha = get_sha(repo_path, branch, timeout=timeout)
    remote_sha = get_sha(repo_path, f"{remote}/{branch}", timeout=timeout)

    if not local_sha or not remote_sha:
        return SyncState.DIVERGED

    if local_sha == remote_sha:
        return SyncState.SYNCED

    r = git_run(
        repo_path,
        ["merge-base", branch, f"{remote}/{branch}"],
        check=False,
        timeout=timeout,
    )
    base_sha = r.stdout.strip() if r.returncode == 0 else None
    if not base_sha:
        return SyncState.DIVERGED

    if local_sha == base_sha:
        return SyncState.REMOTE_AHEAD
    if remote_sha == base_sha:
        return SyncState.LOCAL_AHEAD
    return SyncState.DIVERGED


def is_working_tree_dirty(repo_path: str, timeout: int | None = None) -> bool:
    r = git_run(repo_path, ["status", "--porcelain"], check=False, timeout=timeout)
    return bool(r.stdout.strip())


def do_pull_ff_only(
    repo_path: str,
    remote: str,
    branch: str,
    stash_on_dirty: bool,
    timeout: int | None = None,
) -> tuple[bool, str]:
    had_stash = False
    stash_cmd = ["stash", "push", "--include-untracked", "-m", "auto-sync-stash"]
    if is_working_tree_dirty(repo_path, timeout=timeout):
        if not stash_on_dirty:
            return False, "working tree dirty (stash_on_dirty disabled)"
        r = git_run(repo_path, stash_cmd, check=False, timeout=timeout)
        if r.returncode != 0:
            stderr = r.stderr.strip() if r.stderr else ""
            retry = _cleanup_gitlinks_and_retry_stash(
                repo_path, stash_cmd, stderr, timeout=timeout
            )
            if retry is not None:
                if retry.returncode != 0:
                    return (
                        False,
                        f"stash failed after gitlink cleanup: {retry.stderr.strip()}",
                    )
                had_stash = True
            else:
                return False, f"stash failed: {stderr}"
        else:
            had_stash = True

    try:
        r = git_run(
            repo_path,
            ["pull", "--ff-only", remote, branch],
            check=False,
            timeout=timeout,
        )
        pull_ok = r.returncode == 0
        pull_msg = (
            "pull success" if pull_ok else f"pull --ff-only failed: {r.stderr.strip()}"
        )
    except Exception as e:
        pull_ok = False
        pull_msg = f"pull exception: {e}"

    # Submodule content must follow the new pointers (SEE-1268) — a pointer-only
    # pull leaves the child working trees stale, which downstream consumers read
    # as a failed sync. Best-effort: record failure without discarding the pull.
    if pull_ok:
        sub_ok, sub_msg = do_submodule_update(repo_path, timeout=timeout)
        pull_msg = f"{pull_msg}; {sub_msg}"
        if not sub_ok:
            pull_ok = False

    if had_stash:
        r = git_run(repo_path, ["stash", "pop"], check=False, timeout=timeout)
        if r.returncode != 0:
            if pull_ok:
                return (
                    False,
                    "pull success but stash pop conflicted, needs manual resolution",
                )
            else:
                return False, f"{pull_msg}; additionally stash pop failed"

    return pull_ok, pull_msg


def do_submodule_update(
    repo_path: str,
    timeout: int | None = None,
    logger: logging.Logger | None = None,
) -> tuple[bool, str]:
    """Materialize submodule content to match recorded pointers (SEE-1268).

    Pointer-level ops (pull/push/rebase) move gitlinks but never populate the
    child working trees, so a synced master would still miss the godot-mcp
    addon content (the only remaining submodule — gqt split as a standalone
    repo, SEE-1396). Runs only when .gitmodules exists; `--init` also clears
    the '-'
    uninitialized status that has_submodule_changes() treats as a sync-blocking
    intermediate state.

    Self-healing (two failure classes, each retried once, never silent):
    - vendored→submodule migration residue (SEE-1268): `git submodule update
      --init` refuses to clone into a non-empty directory — the residue is
      MOVED ASIDE (never deleted) and the init retried.
    - module-config corruption (SEE-476): a parse-class failure naming a
      .git/modules/**/config file (the thrice-repeated power-cut all-0x00
      incident) triggers backup → rebuild → retry, so the cycle succeeds
      without burning a circuit-breaker count.
    """
    log = logger or logging.getLogger("repo_sync")
    if not (Path(repo_path) / ".gitmodules").is_file():
        return True, "no submodules (.gitmodules absent)"

    ok, err = _run_submodule_init(repo_path, timeout)
    if ok:
        return True, "submodule update --init --recursive success"

    corrupt_cfg = is_module_config_parse_failure(err)
    if corrupt_cfg is not None:
        # SEE-476: only parse-class module-config failures self-heal; every
        # other failure keeps its normal persistent accounting.
        cfg_path = Path(corrupt_cfg)
        if not cfg_path.is_absolute():
            cfg_path = Path(repo_path) / cfg_path
        log.warning(
            "%s parse-class module config failure: %s", SELFHEAL_LOG_PREFIX, err.strip()
        )
        repaired, repair_msg = repair_module_config(repo_path, cfg_path, log)
        if not repaired:
            return False, (
                f"submodule update --init --recursive failed: {err}; "
                f"module-config self-heal failed: {repair_msg}"
            )
        ok2, err2 = _run_submodule_init(repo_path, timeout)
        if not ok2:
            return False, (
                f"submodule update --init --recursive still failing after "
                f"module-config self-heal ({repair_msg}): {err2}"
            )
        log.info(
            "%s submodule update succeeded after module config rebuild",
            SELFHEAL_LOG_PREFIX,
        )
        return True, (
            f"submodule update success after module-config self-heal ({repair_msg})"
        )

    if not _is_residue_blocked(err):
        # Not the migration class — a real fetch/URL failure. Surface it.
        return False, f"submodule update --init --recursive failed: {err}"

    moved_ok, moved_msg = _recover_submodule_residue(repo_path, timeout)
    if not moved_ok:
        return False, (
            f"submodule update --init --recursive failed ({err}); "
            f"residue recovery failed: {moved_msg}"
        )

    ok2, err2 = _run_submodule_init(repo_path, timeout)
    if not ok2:
        return False, (
            f"submodule update --init --recursive still failing after moving "
            f"residue aside ({moved_msg}): {err2}"
        )
    return True, f"submodule update success after residue recovery ({moved_msg})"


def _run_submodule_init(repo_path: str, timeout: int | None) -> tuple[bool, str]:
    r = git_run(
        repo_path,
        ["submodule", "update", "--init", "--recursive"],
        check=False,
        timeout=timeout,
    )
    return r.returncode == 0, (r.stderr.strip() if r.stderr else r.stdout.strip())


# Git's clone-into-populated-directory signatures. `--force` does NOT help here
# (verified: it re-fails), so the only recovery is clearing the path.
_RESIDUE_MARKERS = ("not an empty directory", "failed to clone")


def _is_residue_blocked(stderr: str) -> bool:
    low = stderr.lower()
    return any(marker in low for marker in _RESIDUE_MARKERS)


def _uninitialized_submodule_paths(repo_path: str, timeout: int | None) -> list[str]:
    """Paths git reports as '-' (registered but not checked out)."""
    r = git_run(repo_path, ["submodule", "status"], check=False, timeout=timeout)
    if r.returncode != 0:
        return []
    paths: list[str] = []
    for line in r.stdout.splitlines():
        if not line.startswith("-"):
            continue
        # Format: "-<sha> <path>[ (describe)]"
        parts = line[1:].split()
        if len(parts) >= 2:
            paths.append(parts[1])
    return paths


def _recover_submodule_residue(repo_path: str, timeout: int | None) -> tuple[bool, str]:
    """Move non-empty uninitialized submodule paths aside so --init can clone.

    Reversible by construction: the residue is relocated to
    .dev/logs/submodule-residue/<path>-<epoch>/ inside the repo (gitignored),
    never removed. Best-effort `deinit` first drops any stale registration.
    """
    paths = _uninitialized_submodule_paths(repo_path, timeout)
    if not paths:
        return False, "no uninitialized submodule path to recover"

    backup_root = Path(repo_path) / ".dev" / "logs" / "submodule-residue"
    moved: list[str] = []
    for rel in paths:
        target = Path(repo_path) / rel
        if not target.exists():
            continue
        if not any(target.iterdir()):
            # Empty dir: git would have cloned fine, so this is not the blocker.
            continue
        dest = backup_root / f"{rel.replace('/', '_')}-{int(time.time())}"
        try:
            # Move the working-tree residue FIRST: `git submodule deinit -f`
            # empties the submodule directory, so running it before the move
            # would destroy the very files this recovery promises to preserve.
            dest.parent.mkdir(parents=True, exist_ok=True)
            if dest.exists():
                dest = dest.with_name(dest.name + f"-{os.getpid()}")
            shutil.move(str(target), str(dest))
            git_run(repo_path, ["submodule", "deinit", "-f", "--", rel], check=False, timeout=timeout)
            # A stale .git/modules/<path> registration makes the re-clone fail
            # even with the worktree dir gone (verified against git ≥2.38), so
            # relocate it too — same reversible treatment as the worktree dir.
            stale_modules = _git_path(repo_path, f"modules/{rel}", timeout)
            if stale_modules and stale_modules.exists():
                shutil.move(str(stale_modules), str(dest) + ".gitmodules")
        except OSError as e:
            return False, f"could not move residue for {rel} to {dest}: {e}"
        moved.append(f"{rel} -> {dest}")

    if not moved:
        return False, "residue recovery found nothing to move (init failure not path-related)"
    return True, "; ".join(moved)


# ---------------------------------------------------------------------------
# Module-config self-heal & boot precheck (SEE-476)
#
# Three same-root-cause circuit-breaker incidents (2026-09-22 / 10-23 /
# 10-24): an abnormal power cut left a size-correct but all-0x00 module
# config (.git/modules/addons/godot_mcp/config on the NTFS/9p D-drive
# checkout); every sync cycle then died on `fatal: bad config line 1 ...`
# (classified persistent by default) until the breaker tripped at 10/10.
# The thrice-validated manual fix — back up the corrupt file, rebuild the
# standard structure (core section + relative worktree + remote.origin, url
# from the parent repo's stored submodule url), retry — is automated here.
# Repair only ever triggers on parse-class failures naming a config under
# .git/modules/, so network/conflict/gitlink failures keep their accounting.
# ---------------------------------------------------------------------------

# Parse-class git config errors name the offending file as "in file <path>".
# git prints the offending file as "in file <path>" at line end; the path may
# contain spaces (anywhere in the checkout path), so capture to end-of-line
# rather than \S+ (which truncated and silently degraded to no-repair).
_MODULE_CONFIG_PARSE_RE = re.compile(
    r"(?:bad config line|missing '='|bad config section)[^\n]*?in file (.+?)\s*$",
    re.MULTILINE,
)

SELFHEAL_LOG_PREFIX = "[repo-sync-self-heal]"
PRECHECK_LOG_PREFIX = "[repo-sync-precheck]"


def is_module_config_parse_failure(stderr: str) -> str | None:
    """Return the config-file path named by a parse-class git error, else None.

    Textual detection only — the caller (repair_module_config) re-checks that
    the path actually resolves under .git/modules/ before touching anything.
    """
    m = _MODULE_CONFIG_PARSE_RE.search(stderr or "")
    return m.group(1) if m else None


def _parse_gitmodules_with_names(repo_path: str) -> list[dict[str, str]]:
    """Parse .gitmodules into [{name, path, url}] entries.

    Keeps the section NAME because the parent repo's .git/config keys
    `submodule.<name>.url` by that name, which may differ from the checkout
    path (`path = ...`).
    """
    gm_path = Path(repo_path) / ".gitmodules"
    if not gm_path.is_file():
        return []
    entries: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for raw in gm_path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line.startswith("[submodule"):
            if current:
                entries.append(current)
            name = line[line.find('"') + 1 : line.rfind('"')] if '"' in line else ""
            current = {"name": name}
        elif current is not None and "=" in line:
            key, _, val = line.partition("=")
            current[key.strip()] = val.strip()
    if current:
        entries.append(current)
    return entries


def _registered_submodule_urls(repo_path: str) -> dict[str, str]:
    """path → url for registered submodules.

    Precedence mirrors `git submodule init`: the parent .git/config stored
    value first, .gitmodules fallback second. Empty url means no source of
    truth — callers must refuse to rebuild from it.
    """
    urls: dict[str, str] = {}
    for entry in _parse_gitmodules_with_names(repo_path):
        path, name = entry.get("path", ""), entry.get("name", "")
        if not path:
            continue
        r = git_run(
            repo_path, ["config", "--get", f"submodule.{name}.url"], check=False
        )
        url = r.stdout.strip() if r.returncode == 0 else ""
        urls[path] = url or entry.get("url", "")
    return urls


def _module_rel_from_config_path(repo_path: str, config_file: Path) -> str | None:
    """Map a .git/modules/<rel>/config path back to the submodule path <rel>.

    Returns None when the file does not resolve under .git/modules/ — the
    scope guard that keeps this repair away from every other config file.
    """
    if not config_file.is_absolute():
        config_file = Path(repo_path) / config_file
    try:
        modules_root = (Path(repo_path) / ".git" / "modules").resolve()
        rel = config_file.resolve().parent.relative_to(modules_root)
    except (OSError, ValueError):
        return None
    if not rel.parts:
        return None
    return "/".join(rel.parts)


def _git_config_parses(config_file: Path, repo_path: str) -> bool:
    r = git_run(
        repo_path, ["config", "--file", str(config_file), "--list"], check=False
    )
    return r.returncode == 0


def _module_config_check_reason(config_file: Path, repo_path: str) -> str:
    """First failing integrity gate as human-readable text; 'healthy' if none.

    The three gates mirror the incident: power cuts leave size-correct
    all-zero content (the fast byte-level check), other corruption only shows
    as a git parse failure.
    """
    try:
        data = config_file.read_bytes()
    except OSError as e:
        return f"unreadable: {e}"
    if not data:
        return "empty file"
    if set(data) == {0}:
        return f"all-zero content ({len(data)} bytes)"
    if not _git_config_parses(config_file, repo_path):
        r = git_run(
            repo_path, ["config", "--file", str(config_file), "--list"], check=False
        )
        return f"git parse failed: {r.stderr.strip()}"
    return "healthy"


def _backup_stamp() -> str:
    """Timestamp for backup names; a seam so tests can pin same-second collisions."""
    return time.strftime("%Y%m%d-%H%M%S")


def repair_module_config(
    repo_path: str, config_file: Path, logger: logging.Logger
) -> tuple[bool, str]:
    """Back up a corrupt module config and rebuild the verified structure.

    Mirrors the thrice-validated manual fix (SEE-476): same-directory
    `config.corrupt-<ts>` backup, then core section + relative worktree +
    [remote "origin"], url taken from the parent repo's stored submodule url.
    Reversible by construction (the corrupt original is preserved); refuses to
    rewrite when no source of truth for the url exists.
    """
    if not config_file.is_absolute():
        config_file = Path(repo_path) / config_file
    rel = _module_rel_from_config_path(repo_path, config_file)
    if rel is None:
        return False, f"not a module config under .git/modules/: {config_file}"

    url = _registered_submodule_urls(repo_path).get(rel, "")
    if not url:
        return False, (
            f"no submodule url found for '{rel}' in parent .git/config or "
            f".gitmodules; refusing to rebuild {config_file} without a source of truth"
        )

    # Backup first — the corrupt original is the only forensic copy. Same-second
    # repairs append -N so a later fix never overwrites an earlier forensic copy.
    stamp = _backup_stamp()
    backup = config_file.parent / f"config.corrupt-{stamp}"
    n = 1
    while backup.exists():
        backup = config_file.parent / f"config.corrupt-{stamp}-{n}"
        n += 1
    try:
        shutil.copy2(config_file, backup)
    except OSError as e:
        return False, f"could not back up {config_file} to {backup}: {e}"
    logger.warning(
        "%s corrupt module config backed up: %s -> %s (module=%s)",
        SELFHEAL_LOG_PREFIX,
        config_file,
        backup,
        rel,
    )

    worktree_rel = os.path.relpath(
        os.path.join(repo_path, rel), start=str(config_file.parent)
    ).replace(os.sep, "/")
    # Mirror the parent repo's core.filemode; when unset, "false" matches the
    # NTFS/9p reality of the incident checkout (mode bits are not trackable).
    fm = git_run(repo_path, ["config", "--get", "core.filemode"], check=False)
    filemode = fm.stdout.strip() or "false"

    content = "\n".join(
        [
            "[core]",
            "\trepositoryformatversion = 0",
            f"\tfilemode = {filemode}",
            "\tbare = false",
            "\tlogallrefupdates = true",
            f"\tworktree = {worktree_rel}",
            '[remote "origin"]',
            f"\turl = {url}",
            "\tfetch = +refs/heads/*:refs/remotes/origin/*",
        ]
    )
    tmp = config_file.parent / "config.rebuild-tmp"
    try:
        tmp.write_text(content + "\n", encoding="utf-8")
        os.replace(tmp, config_file)
    except OSError as e:
        return False, f"could not write rebuilt config {config_file}: {e}"

    if not _git_config_parses(config_file, repo_path):
        logger.error(
            "%s rebuilt module config still fails git parse: %s; corrupt "
            "original preserved at %s",
            SELFHEAL_LOG_PREFIX,
            config_file,
            backup,
        )
        return False, f"rebuilt config failed git parse: {config_file}"

    logger.info(
        "%s module config rebuilt: %s (module=%s url=%s)",
        SELFHEAL_LOG_PREFIX,
        config_file,
        rel,
        url,
    )
    return True, f"rebuilt {config_file} (backup: {backup})"


def precheck_module_configs(repo_path: str, logger: logging.Logger) -> list[str]:
    """Boot precheck (SEE-476 goal 2): validate every registered submodule's
    module config (exists / not all-zero / git-parseable) BEFORE the first
    sync cycle, repairing anything corrupt. Returns repaired config paths.

    A missing module config (uninitialized submodule) is materialization's
    job, not corruption — skipped here. Repair failures are logged loudly and
    left for the runtime self-heal backstop; startup never aborts on them.
    """
    repaired: list[str] = []
    for rel in sorted(_registered_submodule_urls(repo_path)):
        cfg = Path(repo_path) / ".git" / "modules" / rel / "config"
        if not cfg.is_file():
            continue
        reason = _module_config_check_reason(cfg, repo_path)
        if reason == "healthy":
            continue
        logger.warning(
            "%s module config failed integrity check (path=%s): %s",
            PRECHECK_LOG_PREFIX,
            cfg,
            reason,
        )
        ok, msg = repair_module_config(repo_path, cfg, logger)
        if ok:
            repaired.append(str(cfg))
        else:
            logger.error(
                "%s precheck repair FAILED for %s: %s (runtime self-heal will retry)",
                PRECHECK_LOG_PREFIX,
                cfg,
                msg,
            )
    return repaired


def _git_path(repo_path: str, rel: str, timeout: int | None) -> Path | None:
    """Resolve a path inside the repo's git dir (worktree-safe)."""
    r = git_run(repo_path, ["rev-parse", "--git-path", rel], check=False, timeout=timeout)
    if r.returncode != 0 or not r.stdout.strip():
        return None
    p = Path(r.stdout.strip())
    return p if p.is_absolute() else Path(repo_path) / p


# do_push（向上推送）已随向上同步语义退役（SEE-1430b）；实现保留在 KOL master
# 与 gqt 历史树内可查，需要回退时自历史恢复。


def _looks_like_not_our_ref(output: str) -> bool:
    low = output.lower()
    return "not our ref" in low or "no such ref" in low


def _sha_reachable_via_tips(
    child_wt: str, url: str, sha: str, probe_timeout_s: int
) -> bool:
    """True when `sha` is an ancestor of some tip on the remote (or the tip
    itself). Uses ls-remote tips + local ancestry checks against the child's
    own object store — transport-independent, no remote history download."""
    r = git_run(child_wt, ["ls-remote", url], check=False, timeout=probe_timeout_s)
    if r.returncode != 0:
        # Can't see the remote at all — not a dangling verdict; let the push
        # proceed (the push itself will fail loudly if the remote is broken).
        return True
    for line in r.stdout.splitlines():
        tip_sha = line.split("\t", 1)[0].strip()
        if tip_sha == sha:
            return True
        # merge-base needs both objects locally; a tip that is newer than our
        # last child fetch is NOT yet in the object store, making every
        # merge-base fail → a false "dangling" verdict that fail-closes gate2
        # (SEE-1292 production case: squash-merged 0221ae0 absent locally for
        # the entire circuit-breaker window). Remedy: fetch the tip once (shallow
        # unbounded fetch of a remote tip is bounded by the repo's real history)
        # before the ancestry probe; genuine fetch failure keeps fail-close.
        m = git_run(child_wt, ["merge-base", "--is-ancestor", sha, tip_sha],
                    check=False)
        if m.returncode != 0:
            f = git_run(child_wt, ["fetch", "--quiet", url, tip_sha],
                        check=False, timeout=probe_timeout_s)
            if f.returncode != 0:
                continue
            m = git_run(child_wt, ["merge-base", "--is-ancestor", sha, tip_sha],
                        check=False)
        if m.returncode == 0:
            return True
    return False


def _iter_gitlinks(repo_path: str, timeout: int | None) -> list[tuple[str, str]]:
    """Yield (path, sha) for every gitlink recorded in the index."""
    r = git_run(repo_path, ["ls-files", "--stage"], check=False, timeout=timeout)
    links: list[tuple[str, str]] = []
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[0] == "160000":
            links.append((parts[3], parts[1]))
    return links


def ensure_gitlinks_reachable(
    repo_path: str,
    timeout: int | None = None,
    probe_timeout_s: int = 30,
    recursive: bool = False,
    _path_prefix: str = "",
) -> tuple[bool, str]:
    """Verify every gitlink's SHA is fetchable from its submodule remote (GAP-1).

    Technique (probed against git 2.x, file & https transports):
      `git fetch --dry-run <remote> <sha>` inside the child worktree —
      rc=0 → the remote can serve that commit; rc!=0 with "not our ref"
      → the commit is missing upstream (dangling).

    Skips gracefully when: no .gitmodules, child worktree not initialized
    ('-' status — repo-sync's materialize owns that state), or the child's
    remote cannot be resolved. probe_timeout_s bounds each network round-trip
    so a hung remote cannot stall the sync loop.

    (c) 递归骨架（SEE-1268 §7.4(c)）：recursive=True 且某子库工作区有自己的
    .gitmodules 时对其递归一次（深度限 1 层——递归调用强制 recursive=False，
    避免无限下钻）；dangling 文案经 _path_prefix 带父路径前缀。默认 False，
    与既有行为零变化（两子库均无嵌套，走不到递归分支）。
    """
    if not (Path(repo_path) / ".gitmodules").is_file():
        return True, "no submodules (.gitmodules absent)"

    links = _iter_gitlinks(repo_path, timeout)
    if not links:
        return True, "no gitlinks in index"

    for path_rel, sha in links:
        child = Path(repo_path) / path_rel
        # '-' uninitialized: no local child repo; the materialize step owns it.
        if not (child / ".git").exists():
            continue
        # Resolve the child's configured origin URL (not the .gitmodules URL —
        # worktree-local `remote.origin.url` is what a push from here would use).
        r = git_run(str(child), ["remote", "get-url", "origin"],
                    check=False, timeout=timeout)
        if r.returncode != 0 or not r.stdout.strip():
            continue
        url = r.stdout.strip()
        display = f"{_path_prefix}{path_rel}"

        r = git_run(str(child), ["fetch", "--dry-run", "--quiet", url, sha],
                    check=False, timeout=probe_timeout_s)
        if r.returncode != 0 and _looks_like_not_our_ref(r.stderr + r.stdout):
            # Authoritative on http remotes: the server refused to serve the sha.
            err = (r.stderr.strip() or r.stdout.strip())[:200]
            return False, (
                f"submodule '{display}' commit {sha} is NOT on its remote "
                f"({url}) — 先补推子库再推父仓 / push the submodule first. "
                f"detail: {err}"
            )
        # fetch succeeded — but on file-protocol remotes that success is not
        # proof (local transport resolves objects the remote lacks, probed
        # against git 2.x). Cross-check ancestry: the gitlink must be an
        # ancestor of some remote tip, else treat as dangling.
        if not _sha_reachable_via_tips(str(child), url, sha, probe_timeout_s):
            return False, (
                f"submodule '{display}' commit {sha} is NOT an ancestor of any "
                f"tip on its remote ({url}) — 先补推子库再推父仓 / push the "
                f"submodule first."
            )

        # (c) 递归：本子库通过后，若启用递归且它有嵌套 .gitmodules，下钻一次。
        if recursive and (child / ".gitmodules").is_file():
            nested_ok, nested_msg = ensure_gitlinks_reachable(
                str(child),
                timeout=timeout,
                probe_timeout_s=probe_timeout_s,
                recursive=False,  # 深度限 1 层
                _path_prefix=f"{display}/",
            )
            if not nested_ok:
                return False, nested_msg
    return True, "all gitlink SHAs reachable from their submodule remotes"



def do_stash_if_dirty(
    repo_path: str,
    stash_on_dirty: bool,
    recovery: bool = True,
    timeout: int | None = None,
) -> tuple[bool, str, bool]:
    """Stash dirty working tree. Returns (ok, msg, had_stash).

    When recovery=True and stash fails with a gitlink-related error,
    automatically cleans orphan gitlinks and retries once.
    """
    if not is_working_tree_dirty(repo_path, timeout=timeout):
        return True, "", False
    if not stash_on_dirty:
        return False, "working tree dirty (stash_on_dirty disabled)", False
    stash_cmd = ["stash", "push", "--include-untracked", "-m", "auto-sync-stash"]
    r = git_run(repo_path, stash_cmd, check=False, timeout=timeout)
    if r.returncode != 0:
        stderr = r.stderr.strip() if r.stderr else ""
        if recovery:
            retry = _cleanup_gitlinks_and_retry_stash(
                repo_path, stash_cmd, stderr, timeout=timeout
            )
            if retry is not None and retry.returncode == 0:
                return True, "stashed (after gitlink cleanup)", True
        return False, f"stash failed: {stderr}", False
    return True, "stashed", True


def do_stash_pop(repo_path: str, timeout: int | None = None) -> tuple[bool, str]:
    r = git_run(repo_path, ["stash", "pop"], check=False, timeout=timeout)
    if r.returncode != 0:
        return False, f"stash pop failed: {r.stderr.strip()}"
    return True, "stash pop success"


def do_rebase(
    repo_path: str, remote: str, branch: str, timeout: int | None = None
) -> tuple[bool, str]:
    """Rebase local branch onto remote. Returns (ok, msg)."""
    r = git_run(
        repo_path, ["rebase", f"{remote}/{branch}"], check=False, timeout=timeout
    )
    if r.returncode == 0:
        return True, "rebase success"
    return False, f"rebase failed: {r.stderr.strip()}"


def do_rebase_abort(repo_path: str, timeout: int | None = None) -> tuple[bool, str]:
    r = git_run(repo_path, ["rebase", "--abort"], check=False, timeout=timeout)
    if r.returncode == 0:
        return True, "rebase aborted"
    return False, f"rebase abort failed: {r.stderr.strip()}"


def do_pull_merge(
    repo_path: str, remote: str, branch: str, timeout: int | None = None
) -> tuple[bool, str]:
    """Pull with merge strategy (--no-rebase --no-edit). Returns (ok, msg)."""
    r = git_run(
        repo_path,
        ["pull", "--no-rebase", "--no-edit", remote, branch],
        check=False,
        timeout=timeout,
    )
    if r.returncode == 0:
        return True, "merge pull success"
    return False, f"merge pull failed: {r.stderr.strip()}"


def resolve_diverged(
    repo_path: str,
    remote: str,
    branch: str,
    stash_on_dirty: bool,
    strategy: ConflictResolution,
    logger: logging.Logger,
    dry_run: bool = False,
    timeout: int | None = None,
) -> dict[str, Any]:
    """Attempt automatic conflict resolution for DIVERGED state.

    Strategies:
      rebase_first: rebase → submodule materialization; on conflict → abort → merge (no push — push retired, SEE-1430b)
      merge_first:  merge; on conflict → block
      block_only:   immediate block + alert
    """
    result: dict[str, Any] = {
        "action": "resolve_diverged",
        "state": "DIVERGED",
        "success": False,
        "message": "",
        "resolution_steps": [],
        "dry_run": dry_run,
    }

    if dry_run:
        result["message"] = (
            f"dry-run: would attempt {strategy.value} conflict resolution"
        )
        return result

    if strategy == ConflictResolution.BLOCK_ONLY:
        result["message"] = (
            "DIVERGED: block_only strategy, manual intervention required"
        )
        return result

    # Stash dirty working tree before rebase/merge operations
    stash_ok, stash_msg, had_stash = do_stash_if_dirty(
        repo_path, stash_on_dirty, timeout=timeout
    )
    if not stash_ok:
        result["message"] = f"DIVERGED: cannot proceed — {stash_msg}"
        return result
    if had_stash:
        result["resolution_steps"].append("stash")

    try:
        if strategy == ConflictResolution.REBASE_FIRST:
            result = _resolve_rebase_first(
                repo_path, remote, branch, result, logger, timeout=timeout
            )
        elif strategy == ConflictResolution.MERGE_FIRST:
            result = _resolve_merge_first(
                repo_path, remote, branch, result, logger, timeout=timeout
            )
    finally:
        if had_stash:
            pop_ok, pop_msg = do_stash_pop(repo_path, timeout=timeout)
            result["resolution_steps"].append(
                f"stash_pop({'ok' if pop_ok else 'fail'})"
            )
            if not pop_ok and result["success"]:
                result["success"] = False
                result["message"] += f"; {pop_msg}"

    return result


def _resolve_rebase_first(
    repo_path: str,
    remote: str,
    branch: str,
    result: dict[str, Any],
    logger: logging.Logger,
    timeout: int | None = None,
) -> dict[str, Any]:
    ok, msg = do_rebase(repo_path, remote, branch, timeout=timeout)
    result["resolution_steps"].append(f"rebase({'ok' if ok else 'fail'})")

    if ok:
        logger.info("rebase succeeded for DIVERGED resolution")
        # SEE-1430b 语义改向：化解后不再 push（向上同步退役）。
        # 保留子库物化——materialize 是向下 sync 的一部分。
        sub_ok, sub_msg = do_submodule_update(repo_path, timeout=timeout, logger=logger)
        result["resolution_steps"].append(f"submodule_update({'ok' if sub_ok else 'fail'})")
        result["success"] = sub_ok
        if not sub_ok:
            result["message"] = f"resolved DIVERGED via rebase: {msg}; submodule content not materialized: {sub_msg}"
        else:
            result["message"] = f"resolved DIVERGED via rebase: {msg}; submodule content materialized"
        return result

    logger.warning("rebase failed, attempting abort then merge fallback: %s", msg)
    abort_ok, abort_msg = do_rebase_abort(repo_path, timeout=timeout)
    result["resolution_steps"].append(f"rebase_abort({'ok' if abort_ok else 'fail'})")

    merge_ok, merge_msg = do_pull_merge(repo_path, remote, branch, timeout=timeout)
    result["resolution_steps"].append(f"merge({'ok' if merge_ok else 'fail'})")

    if merge_ok:
        logger.info("merge fallback succeeded for DIVERGED resolution")
        # SEE-1430b 语义改向：化解后不再 push；保留子库物化。
        sub_ok, sub_msg = do_submodule_update(repo_path, timeout=timeout, logger=logger)
        result["resolution_steps"].append(f"submodule_update({'ok' if sub_ok else 'fail'})")
        result["success"] = sub_ok
        if not sub_ok:
            result["message"] = f"resolved DIVERGED via merge fallback: {merge_msg}; submodule content not materialized: {sub_msg}"
        else:
            result["message"] = f"resolved DIVERGED via merge fallback: {merge_msg}; submodule content materialized"
        return result

    result["message"] = (
        "DIVERGED: rebase and merge both failed, manual intervention required"
    )
    return result


def _resolve_merge_first(
    repo_path: str,
    remote: str,
    branch: str,
    result: dict[str, Any],
    logger: logging.Logger,
    timeout: int | None = None,
) -> dict[str, Any]:
    merge_ok, merge_msg = do_pull_merge(repo_path, remote, branch, timeout=timeout)
    result["resolution_steps"].append(f"merge({'ok' if merge_ok else 'fail'})")

    if merge_ok:
        logger.info("merge succeeded for DIVERGED resolution")
        # SEE-1430b 语义改向：化解后不再 push；保留子库物化。
        sub_ok, sub_msg = do_submodule_update(repo_path, timeout=timeout, logger=logger)
        result["resolution_steps"].append(f"submodule_update({'ok' if sub_ok else 'fail'})")
        result["success"] = sub_ok
        if not sub_ok:
            result["message"] = f"resolved DIVERGED via merge: {merge_msg}; submodule content not materialized: {sub_msg}"
        else:
            result["message"] = f"resolved DIVERGED via merge: {merge_msg}; submodule content materialized"
        return result

    result["message"] = "DIVERGED: merge failed, manual intervention required"
    return result


# ---------------------------------------------------------------------------
# SEE-1285: gitlink auto-forward (three-gate, fail-close)
# ---------------------------------------------------------------------------

# Gate 1 maps a GitHub Actions check-run conclusion set to a three-state
# verdict. Anything not provably green/fail lands on "unknown" and is treated
# as not satisfied (fail-close) with backoff retry on the next cycle.
_CI_SUCCESS = "success"


def classify_ci_conclusion(job_conclusions: list[dict[str, Any]] | None) -> str:
    """Classify child CI verdict as 'success' | 'fail' | 'unknown'.

    `job_conclusions` is the list of check-run dicts for the child's
    build-and-test workflow on the pushed branch. success requires ALL
    conclusions to be success; any explicit non-success conclusion is 'fail';
    running/missing/error → 'unknown' (retry with backoff next cycle).
    """
    if not job_conclusions:
        return "unknown"
    verdicts = [
        (j.get("conclusion") or "").lower() for j in job_conclusions
    ]
    if any(v in ("failure", "timed_out", "cancelled", "startup_failure") for v in verdicts):
        return "fail"
    if all(v == _CI_SUCCESS for v in verdicts):
        return "success"
    return "unknown"


def _select_gating_runs(runs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Pick the gating workflow check-runs for Gate 1.

    A fork push produces publish/release check-runs (`skipped`) beside the
    `build-and-test` one (ci.yml). Pool-wide classification would turn any
    `skipped` neighbour into 'unknown' even when CI is green (D2, HIGH).
    Filter to the gating check-run when present; fall back to the full pool
    when absent — fail-close either way.
    """
    if not runs:
        return runs
    gated = [
        r for r in runs
        if isinstance(r, dict) and r.get("name") == "build-and-test"
    ]
    return gated if gated else runs


def default_ci_query(child_remote_url: str, branch: str, sha: str) -> str:
    """Query the child repo's CI conclusion via GitHub API (Gate 1 producer).

    Uses `gh api` (authenticated CLI, the same tool the platform runs). The
    repo is derived from the child remote URL. Any failure (no gh, network,
    repo not on GitHub) yields 'unknown' — never raises.
    """
    if "github.com" not in child_remote_url:
        return "unknown"
    slug = child_remote_url.rstrip("/")
    for prefix in ("https://github.com/", "git@github.com:"):
        if slug.startswith(prefix):
            slug = slug[len(prefix):]
            break
    if slug.endswith(".git"):
        slug = slug[:-4]
    try:
        r = subprocess.run(
            ["gh", "api",
             f"repos/{slug}/commits/{sha}/check-runs?per_page=100",
             "--jq", "[.check_runs[] | {name, conclusion, status}]"],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            timeout=30,
        )
        if r.returncode != 0:
            return "unknown"
        runs = json.loads(r.stdout or "[]")
    except (subprocess.SubprocessError, json.JSONDecodeError, ValueError, OSError):
        return "unknown"
    # build-and-test is the child repo's gating workflow (ci.yml); when it is
    # absent fall back to the full set — fail-close either way.
    return classify_ci_conclusion(_select_gating_runs(runs))


def verify_lag_interval_integrity(
    child_worktree: str, old_sha: str, new_sha: str, timeout: int | None = None
) -> tuple[bool, str]:
    """Gate 3 — the lag interval must have decidable history: new_sha must
    contain old_sha as an ancestor (single merge-base --is-ancestor check).
    A squash/rebase/force-push rewrites the interval, breaking ancestry:
    old_sha unreachable from new_sha makes the whole interval suspect —
    fail-close, never forward.

    Returns (ok, first_bad_sha). ok=False → fail-close, never forward.
    """
    if old_sha == new_sha:
        return True, ""
    m = git_run(
        child_worktree, ["merge-base", "--is-ancestor", old_sha, new_sha],
        check=False, timeout=timeout,
    )
    if m.returncode == 0:
        return True, ""
    return False, old_sha


def evaluate_forward_gates(
    parent_repo: str,
    sub_path: str,
    child_remote_url: str,
    child_branch: str,
    new_sha: str,
    ci_conclusion: str,
    timeout: int | None = None,
) -> tuple[bool, str | None, str]:
    """Run the three SEE-1285 gates in order; first failure wins.

    Gate 1 (CI): ci_conclusion must be exactly 'success' — unknown/fail/empty
      all block (fail-close, backoff retry on next cycle for unknown).
    Gate 2 (pointer health): delegates to the GAP-1 check
      `ensure_gitlinks_reachable` — reused, never reimplemented or bypassed.
    Gate 3 (interval integrity): parent gitlink → new_sha must be a
      contiguous history segment in the child.

    Returns (allowed, failing_gate_or_None, message).
    """
    # Gate 1 — child CI green (three-state: success / fail / unknown)
    if ci_conclusion != _CI_SUCCESS:
        return False, "gate1", (
            f"gate1 not satisfied: child CI conclusion={ci_conclusion or 'unknown'!r} "
            f"(success required; unknown → backoff retry)"
        )
    # Gate 2 — pointer health via GAP-1 (reuse, never bypass)
    guard_ok, guard_msg = ensure_gitlinks_reachable(
        parent_repo, timeout=timeout
    )
    if not guard_ok:
        return False, "gate2", f"gate2 not satisfied (GAP-1): {guard_msg}"

    # Gate 3 — interval integrity
    child_wt = str(Path(parent_repo) / sub_path)
    if (Path(child_wt) / ".git").exists():
        old_sha = _iter_gitlinks(parent_repo, timeout)
        old = next((sha for p, sha in old_sha if p == sub_path), None)
        if old:
            # G-1（生产观察）：materialize 滞后时子对象库缺新 head 对象，
            # merge-base 对不可判定提交返回非 0，被误判为区间抹除 fail-close。
            # 判定前先 fetch 目标 sha 到本地对象库；fetch 失败维持 fail-close
            # （对象不可得 = 不可判定 → 安全侧）。不动工作树 checkout 状态
            # （仅 fetch，不动 materialize；checkout 对齐由 forward 段处理）。
            f = git_run(child_wt, ["fetch", "--quiet", child_remote_url, new_sha],
                        check=False, timeout=timeout)
            if f.returncode != 0:
                return False, "gate3", (
                    f"gate3 not satisfied: cannot fetch {new_sha[:12]} from "
                    f"{child_remote_url} (object unavailable); fail-close"
                )
            ok, bad = verify_lag_interval_integrity(child_wt, old, new_sha, timeout=timeout)
            if not ok:
                return False, "gate3", (
                    f"gate3 not satisfied: interval history broken — commit {bad[:12]} "
                    f"unreachable from {new_sha[:12]} (squash/rebase/force-push suspected); "
                    f"manual review required"
                )
    return True, None, "all gates passed"


def _query_child_remote_head(repo_path: str, url: str, branch: str, timeout: int | None) -> str | None:
    r = git_run(repo_path, ["ls-remote", url, branch], check=False, timeout=30)
    if r.returncode != 0 or not r.stdout.strip():
        return None
    return r.stdout.split("\t", 1)[0].strip()


# do_forward_gitlinks（SEE-1285 三道 gate 向上 forward）已随向上同步语义退役
# （SEE-1430b）；完整实现保留在 KOL master 与 gqt 历史树内可查。


def send_alert(config: dict[str, Any], message: str) -> tuple[bool, str]:
    issue_id = config.get("alert_issue_id")
    if not issue_id:
        return False, "alert_issue_id not configured"

    cmd = [
        "multica",
        "issue",
        "comment",
        "add",
        issue_id,
        "--content",
        message,
    ]
    r = subprocess.run(
        cmd, capture_output=True, text=True, encoding="utf-8", errors="replace"
    )
    return r.returncode == 0, r.stderr.strip() if r.stderr else r.stdout.strip()


# ---------------------------------------------------------------------------
# Core sync logic
# ---------------------------------------------------------------------------


def _parse_gitmodules_submodules(repo_path: str) -> list[dict[str, str]]:
    """Parse .gitmodules into [{path, url, branch}] entries."""
    gm_path = Path(repo_path) / ".gitmodules"
    if not gm_path.is_file():
        return []
    entries: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for raw in gm_path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line.startswith("[submodule"):
            if current:
                entries.append(current)
            current = {}
        elif current is not None and "=" in line:
            key, _, val = line.partition("=")
            current[key.strip()] = val.strip()
    if current:
        entries.append(current)
    return entries


def _warn_submodule_lags(
    repo_path: str, config: dict[str, Any], logger: logging.Logger, timeout: int | None
) -> None:
    """(a) SYNCED 滞后告警（SEE-1268 §7.4(a)）：materialize 成功后逐子库比对
    remote branch head 与父库 index gitlink——落后仅 logger.warning 暴露，
    不拦截、不置 success=False；网络失败/分支不存在静默跳过；同一 remote
    head 只在变化时告警一次（state.json 去重，避免 5s 循环噪音）。

    返回告警后的 warned_heads 映射（并入 result 由 write_state 落盘）。
    """
    if not (Path(repo_path) / ".gitmodules").is_file():
        return

    links = _iter_gitlinks(repo_path, timeout)
    if not links:
        return
    link_map = {path: sha for path, sha in links}

    submodules = _parse_gitmodules_submodules(repo_path)
    if not submodules:
        return

    # 去重状态：上次告警的 remote head（同 head 不重复告警）。
    state_file = config.get("state_file")
    prior: dict[str, str] = {}
    if state_file and Path(state_file).is_file():
        try:
            prior = json.loads(Path(state_file).read_text(encoding="utf-8")).get(
                "lag_warned_heads", {}
            )
        except (json.JSONDecodeError, OSError):
            prior = {}
    warned_heads: dict[str, str] = dict(prior)

    for sub in submodules:
        _warn_single_submodule_lag(repo_path, logger, sub, link_map, prior, warned_heads)

    return warned_heads


def _warn_single_submodule_lag(
    repo_path: str,
    logger: logging.Logger,
    sub: dict[str, str],
    link_map: dict,
    prior: dict[str, str],
    warned_heads: dict[str, str],
) -> None:
    path_rel = sub.get("path", "")
    url = sub.get("url", "")
    branch = sub.get("branch", "master")
    if not path_rel or not url:
        return
    gitlink_sha = link_map.get(path_rel)
    if not gitlink_sha:
        return

    # 单次网络往返取 remote branch head；超时沿用既有 probe 上限。
    r = git_run(repo_path, ["ls-remote", url, branch], check=False, timeout=30)
    if r.returncode != 0 or not r.stdout.strip():
        return  # 网络失败/分支不存在——静默跳过（§7.4(a) 边界）
    remote_head = r.stdout.split("\t", 1)[0].strip()

    if remote_head == gitlink_sha:
        # 已追上——清除该子库的去重记录，下次再次落后时重新告警。
        warned_heads.pop(path_rel, None)
        return

    # 落后（gitlink ≠ remote head）。仅状态变化告警。
    if prior.get(path_rel) == remote_head:
        return
    short_link = gitlink_sha[:12]
    short_head = remote_head[:12]
    # LOW-1（code-review）：判定用「不等」，涵盖 behind / ahead / diverged
    # 三种关系；祖先校验需要远端 head 对象在本地（通常未 fetch），为判定
    # 多拉一次网络不值当。故采用评审给出的中性措辞选项——不谎称 "behind"，
    # 「需人工跟进」的语义不变（消费决策在主库 PR）。
    logger.warning(
        "submodule '%s' differs from its remote: gitlink %s vs %s#%s %s — "
        "父库 pin 旧版可能为设计意图；如需跟进，先推子库已就绪的指针变更"
        "（消费决策在主库 PR）",
        path_rel, short_link, url, branch, short_head,
    )
    warned_heads[path_rel] = remote_head


def _synced_path_result(
    repo_path: str, config: dict[str, Any], logger: logging.Logger,
    result: dict[str, Any], dry_run: bool, timeout: int | None,
) -> dict[str, Any]:
    """SYNCED 稳态路径：子库 materialize + 滞后告警；返回最终 result。"""
    # SEE-1268 follow-up: pointer equality does NOT imply content
    # equality — a working copy can sit exactly at the remote head yet
    # have uninitialized submodules (arrived via an older daemon build
    # or a manual pull). Materialize on the steady-state path too, or
    # that gap never self-heals (the D-drive missing-plugin.cfg bug).
    if dry_run:
        result["message"] = "already synced (dry-run: would verify submodules)"
        logger.info("already synced")
    else:
        sub_ok, sub_msg = do_submodule_update(repo_path, timeout=timeout, logger=logger)
        if sub_ok:
            result["message"] = "already synced"
            logger.info("already synced")
            # (a) SYNCED 滞后告警（SEE-1268 §7.4(a)）：materialize 成功后
            # 检测子库 remote 超前——只暴露不动作（不拦截、不置失败）。
            lag_heads = _warn_submodule_lags(repo_path, config, logger, timeout)
            if lag_heads is not None:
                result["lag_warned_heads"] = lag_heads
            # SEE-1430b 语义改向：向上 forward（SEE-1285 三道 gate）整体退役，
            # gitlink_forward_enabled 配置键作废——注册文件若仍携带，告警一次。
            if config.get("gitlink_forward_enabled") is not None:
                logger.warning(
                    "gitlink_forward_enabled is retired by sync-to-local "
                    "semantics (SEE-1430b); ignoring it (warn-once per cycle)"
                )
        else:
            result["success"] = False
            result["message"] = f"already synced but submodule materialization failed: {sub_msg}"
            result["error_category"] = classify_error(sub_msg)
            logger.error(
                "submodule materialization failed on SYNCED path: %s (category=%s)",
                sub_msg,
                result["error_category"],
            )
    return result


def _diverged_path_result(
    config: dict[str, Any], logger: logging.Logger, repo_path: str,
    remote: str, branch: str, stash_on_dirty: bool, conflict_strategy,
    result: dict[str, Any], dry_run: bool, timeout: int | None,
) -> dict[str, Any]:
    # DIVERGED — attempt automatic conflict resolution
    result["state"] = SyncState.DIVERGED.value
    logger.warning(
        "DIVERGED detected: local=%s remote=%s",
        get_sha(repo_path, branch, timeout=timeout),
        get_sha(repo_path, f"{remote}/{branch}", timeout=timeout),
    )

    resolved = resolve_diverged(
        repo_path,
        remote,
        branch,
        stash_on_dirty,
        conflict_strategy,
        logger,
        dry_run,
        timeout=timeout,
    )
    result.update(
        {
            "action": resolved["action"],
            "success": resolved["success"],
            "message": resolved["message"],
            "resolution_steps": resolved.get("resolution_steps", []),
        }
    )

    if resolved["success"]:
        logger.info("DIVERGED resolved: %s", resolved["message"])
    else:
        logger.error("DIVERGED resolution failed: %s", resolved["message"])
        if not dry_run:
            alert_msg = (
                "🚨 **Repo Sync Alert — DIVERGED resolution failed**\n\n"
                f"- Local `{branch}`: `{get_sha(repo_path, branch, timeout=timeout) or 'unknown'}`\n"
                f"- Remote `{remote}/{branch}`: `{get_sha(repo_path, f'{remote}/{branch}', timeout=timeout) or 'unknown'}`\n"
                f"- Strategy: `{conflict_strategy.value}`\n"
                f"- Steps: `{resolved.get('resolution_steps', [])}`\n"
                f"- Repo: `{repo_path}`\n\n"
                f"Resolution message: {resolved['message']}\n\n"
                "Manual intervention required."
            )
            ok, err = send_alert(config, alert_msg)
            if ok:
                logger.info("alert sent")
            else:
                logger.error("alert failed: %s", err)
    return result


def run_sync(
    config: dict[str, Any],
    logger: logging.Logger,
    direction: Direction = Direction.PULL_ONLY,
    dry_run: bool = False,
) -> dict[str, Any]:
    repo_path = os.path.expanduser(config["repo_path"])
    remote = config["remote"]
    branch = config["branch"]
    stash_on_dirty = config.get("stash_on_dirty", True)
    conflict_strategy = ConflictResolution(
        config.get(
            "conflict_resolution_strategy", ConflictResolution.REBASE_FIRST.value
        )
    )
    subprocess_timeout = config.get("subprocess_timeout_seconds")

    result = {
        "action": "none",
        "state": None,
        "success": True,
        "message": "",
        "dry_run": dry_run,
    }

    # Branch guard (SEE-869): ensure the main repo sits on its registered branch before sync.
    # If a stash was taken here, it is restored once after the sync body
    # completes (single stash + single pop per cycle — never nested).
    guard_ok, guard_msg, had_stash = ensure_on_registered_branch(
        repo_path,
        branch,
        stash_on_dirty,
        dry_run,
        logger,
        timeout=subprocess_timeout,
    )
    if not guard_ok:
        result["success"] = False
        result["action"] = "branch_guard"
        result["message"] = guard_msg
        result["error_category"] = classify_error(guard_msg)
        logger.error(
            "branch guard failed: %s (category=%s)",
            guard_msg,
            result["error_category"],
        )
        write_state(config, result)
        return result

    try:
        # Fetch origin (with retry for transient network errors)
        fetch_retries = config.get("fetch_retry_count", 3)
        fetch_retry_delay = config.get("fetch_retry_delay_seconds", 2.0)
        ok, err = git_fetch_with_retry(
            repo_path, remote, timeout=subprocess_timeout,
            retries=fetch_retries, retry_delay=fetch_retry_delay,
        )
        if not ok:
            result["success"] = False
            result["message"] = f"fetch failed: {err}"
            result["error_category"] = classify_error(err)
            logger.warning("fetch failed: %s (category=%s)", err, result["error_category"])
            write_state(config, result)
            return result

        state = detect_sync_state(repo_path, remote, branch, timeout=subprocess_timeout)
        result["state"] = state.value
        logger.info("sync state: %s", state.value)

        if state == SyncState.SYNCED:
            result = _synced_path_result(
                repo_path, config, logger, result, dry_run, subprocess_timeout
            )
            write_state(config, result)
            return result

        if state == SyncState.LOCAL_AHEAD:
            # SEE-1430b 语义改向：向上同步（push）退役。local ahead 不自动推送，
            # 仅记录落后幅度并告警，等人工处理。
            ahead = _count_unpushed_commits(
                repo_path, remote, branch, timeout=subprocess_timeout
            )
            result["action"] = "none"
            result["message"] = (
                f"local ahead {ahead} commit(s); push is retired by sync-to-local "
                "semantics (SEE-1430b) — manual handling required"
            )
            logger.warning(
                "LOCAL_AHEAD: %s", result["message"]
            )
            write_state(config, result)
            return result

        if state == SyncState.REMOTE_AHEAD:
            result = _handle_remote_ahead(
                config, logger, direction, dry_run, subprocess_timeout
            )
            write_state(config, result)
            return result

        result = _diverged_path_result(
            config, logger, repo_path, remote, branch, stash_on_dirty,
            conflict_strategy, result, dry_run, subprocess_timeout,
        )
        write_state(config, result)
        return result
    finally:
        # Restore the stash taken by ensure_on_registered_branch — one pop max
        # per sync cycle. Failure here overrides the previously written
        # result so the state file reflects the latest failure.
        if had_stash and not dry_run:
            pop_ok, pop_msg = do_stash_pop(repo_path, timeout=subprocess_timeout)
            if not pop_ok:
                logger.error("stash pop failed after sync: %s", pop_msg)
                result["success"] = False
                prior = result.get("message", "").strip()
                result["message"] = (
                    f"{prior}; stash pop failed: {pop_msg}".lstrip("; ").strip()
                )
                result["error_category"] = classify_error(pop_msg)
                write_state(config, result)


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description="Repo sync script")
    parser.add_argument("--config", default=None, help="Path to config JSON")
    parser.add_argument(
        "--direction",
        choices=[Direction.PULL_ONLY.value],
        default=Direction.PULL_ONLY.value,
        help="Sync direction (sync-to-local only; bidirectional/push-only retired "
             "by SEE-1430b — passing the legacy values errors out here)",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="Detect state only, no write ops"
    )
    parser.add_argument("--quiet", action="store_true", help="Suppress console output")
    parser.add_argument(
        "--lock-timeout",
        type=float,
        default=0.0,
        help="Lock acquisition timeout (seconds)",
    )
    args = parser.parse_args()

    config = load_config(args.config)
    logger = setup_logging(config, quiet=args.quiet, dry_run=args.dry_run)

    lock_path = config.get("lock_file", "/tmp/repo-sync.lock")
    lock_fd = acquire_lock(lock_path, timeout=args.lock_timeout)
    if lock_fd is None:
        logger.warning(
            "Could not acquire lock (%s) — another sync is running", lock_path
        )
        return 1

    # Write PID to lock file for stale lock detection
    try:
        os.lseek(lock_fd, 0, os.SEEK_SET)
        os.truncate(lock_fd, 0)
        os.write(lock_fd, str(os.getpid()).encode("utf-8"))
    except OSError:
        pass

    try:
        result = run_sync(
            config,
            logger,
            direction=Direction(args.direction),
            dry_run=args.dry_run,
        )
        return 0 if result["success"] else 1
    finally:
        release_lock(lock_fd, lock_path)


if __name__ == "__main__":
    sys.exit(main())
