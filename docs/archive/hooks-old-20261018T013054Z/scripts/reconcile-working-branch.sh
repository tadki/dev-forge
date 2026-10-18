#!/bin/bash
set -euo pipefail

# Leader-only: reconcile a shared working branch after an auto-rebase conflict.
#
# Usage:
#   .claude/hooks/reconcile-working-branch.sh [--issue-id <id>] <working_branch>
#   .claude/hooks/reconcile-working-branch.sh --continue <working_branch>
#
# Normal flow: fetch → branch reconcile/<wb> off origin/<wb> → rebase
#   origin/master → (on conflict: human resolves on reconcile/<wb>, then run
#   --continue) → --force-with-lease push (first-reconciler-wins).
# --continue:  resume after a rebase conflict — finish `git rebase --continue`
#   on the existing reconcile/<wb> branch and push with the lease baseline
#   recorded when the normal run started, so a commit that landed on <wb>
#   during conflict resolution still trips the lease instead of being lost.
#
# Exit codes (runtime; pre-flight arg errors stay exit 1 per SEE-954):
#   0  success — <wb> now contains origin/master
#   1  rebase conflict — reconcile/<wb> retained; resolve there then --continue
#   2  push lease lost — a commit landed on <wb>; rerun this script (normal mode)
#   3  other error — not a repo, fetch/parse/checkout failure, etc.

CONTINUE_MODE=0
ISSUE_ID_ARG=""
WORKING_BRANCH=""

print_usage() {
    echo "Usage: $0 [--issue-id <id>] <working_branch>"
    echo "       $0 --continue <working_branch>"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --continue)
            CONTINUE_MODE=1; shift ;;
        --issue-id)
            [ $# -ge 2 ] || { print_usage >&2; exit 1; }
            ISSUE_ID_ARG="$2"; shift 2 ;;
        --issue-id=*)
            ISSUE_ID_ARG="${1#--issue-id=}"; shift ;;
        --help|-h)
            print_usage; exit 0 ;;
        *)
            if [ -z "$WORKING_BRANCH" ]; then
                WORKING_BRANCH="$1"
            else
                print_usage >&2; exit 1
            fi
            shift ;;
    esac
done

if [ -z "$WORKING_BRANCH" ]; then
    print_usage >&2
    exit 1
fi

# Locate the repo: honor PROJECT_ROOT, but detect via git itself so worktrees
# (where .git is a file pointing at the main repo) are handled correctly.
if [ -n "${PROJECT_ROOT:-}" ]; then
    if git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        cd "$PROJECT_ROOT"
    fi
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "[reconcile] 当前目录不是 git 仓库" >&2
    exit 3
fi

RECONCILE_BRANCH="reconcile/${WORKING_BRANCH//\//-}"
# Lease baseline file: persists the origin/<wb> tip captured at the start of a
# normal run so a later --continue can still detect commits that landed on <wb>
# during conflict resolution (first-reconciler-wins via --force-with-lease).
# `git rev-parse --git-dir` resolves to the worktree-private git dir (for linked
# worktrees this is .git/worktrees/<name>/), so each worktree owns its own file.
# Keyed on <wb> rather than pid so the normal-run process and the later
# --continue process read the same file across two separate invocations.
LEASE_FILE="$(git rev-parse --git-dir)/reconcile_lease_${WORKING_BRANCH//\//-}"

# Clear the blocked metadata that the §B auto-rebase pinned on conflict.
# Resolve ISSUE_ID three ways so a manual Leader run (no task env) also clears it:
#   1. explicit --issue-id arg; 2. MULTICA_ISSUE_ID env; 3. derive from MULTICA_TASK_ID.
clear_blocked_metadata() {
    local resolved="${ISSUE_ID_ARG:-${MULTICA_ISSUE_ID:-}}"
    if [ -z "$resolved" ] && [ -n "${MULTICA_TASK_ID:-}" ]; then
        resolved=$(multica issue run-messages "$MULTICA_TASK_ID" --output json 2>/dev/null | node -e "
            let d=''; process.stdin.on('data', c => d += c);
            process.stdin.on('end', () => {
                try {
                    const msgs = JSON.parse(d);
                    if (msgs.length > 0 && msgs[0].issue_id) {
                        process.stdout.write(msgs[0].issue_id);
                    }
                } catch(e) {}
            });
        " 2>/dev/null || true)
    fi
    if [ -n "$resolved" ]; then
        multica issue metadata delete "$resolved" --key blocked_reason >/dev/null 2>&1 || true
        multica issue metadata delete "$resolved" --key waiting_on >/dev/null 2>&1 || true
    fi
}

# Drop the local reconcile branch + lease file (after a failed push so a rerun
# starts clean). Best-effort: never masks the real exit code.
#
# Safe in both lease-failure (exit 2) paths:
# - Normal mode: the reconcile branch holds only the auto-rebased result; no
#   manual work has happened yet, so discarding it cannot lose human work. The
#   next normal run rebuilds it from the latest origin/<wb>.
# - --continue mode: the rebase is already finished and the conflict resolution
#   has been applied. If the lease has tripped, origin/<wb> moved underneath us
#   during conflict resolution; retaining the reconcile branch would re-trip the
#   stale lease forever. We discard it and require a normal rerun, which re-apply
#   the resolution against the new origin/<wb> tip. The cost is re-resolving the
#   same conflict; the benefit is that the incoming commit is never silently
#   dropped (first-reconciler-wins).
cleanup_reconcile_artifacts() {
    git checkout - >/dev/null 2>&1 || true
    git branch -D "$RECONCILE_BRANCH" >/dev/null 2>&1 || true
    rm -f "$LEASE_FILE" 2>/dev/null || true
}

# ------------------------------------------------------------------------
# --continue: finish an in-progress rebase on reconcile/<wb> and push.
# ------------------------------------------------------------------------
if [ "$CONTINUE_MODE" -eq 1 ]; then
    if ! git rev-parse --verify "$RECONCILE_BRANCH" >/dev/null 2>&1; then
        echo "[reconcile] --continue 需要 ${RECONCILE_BRANCH} 已存在，但未找到。请先正常运行本脚本。" >&2
        exit 3
    fi

    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ "$CURRENT_BRANCH" != "$RECONCILE_BRANCH" ]; then
        git checkout "$RECONCILE_BRANCH" || {
            echo "[reconcile] --continue: 无法切到 ${RECONCILE_BRANCH}（可能有未提交改动）。请手动 checkout 后重试。" >&2
            exit 3
        }
    fi

    GIT_DIR="$(git rev-parse --git-dir)"
    if [ -d "${GIT_DIR}/rebase-merge" ] || [ -d "${GIT_DIR}/rebase-apply" ]; then
        echo "[reconcile] --continue: 继续未完成的 rebase..." >&2
        if ! git rebase --continue; then
            echo "[reconcile] 仍有冲突。请在 ${RECONCILE_BRANCH} 上解决后再次运行：" >&2
            echo "  bash $0 --continue ${WORKING_BRANCH}" >&2
            exit 1
        fi
    fi

    # Lease baseline = the origin/<wb> tip captured when the normal run started.
    # If a commit landed on <wb> during conflict resolution, this baseline no
    # longer matches the remote and the push is rejected (first-reconciler-wins),
    # instead of silently dropping that commit. Fall back to the current tip with
    # a warning only if the baseline file is missing (e.g. manually created branch).
    # From this point until a successful push, keep the lease file on any failure
    # so the next --continue re-reads the original baseline. Only a successful
    # push or a lease-failure (exit 2) cleanup discards it.
    echo "[reconcile] --continue: fetching origin..." >&2
    git fetch origin >/dev/null 2>&1 || { echo "[reconcile] fetch 失败" >&2; exit 3; }
    if ! git ls-remote --exit-code --heads origin "$WORKING_BRANCH" >/dev/null 2>&1; then
        echo "[reconcile] 远程不存在 origin/${WORKING_BRANCH}" >&2
        exit 3
    fi
    WB_OLD_SHA=""
    if [ -f "$LEASE_FILE" ]; then
        WB_OLD_SHA=$(cat "$LEASE_FILE" 2>/dev/null || true)
    fi
    if [ -z "$WB_OLD_SHA" ]; then
        echo "[reconcile] --continue: 未找到 lease 基线文件，回退为当前 origin/${WORKING_BRANCH} tip。" >&2
        WB_OLD_SHA=$(git rev-parse "origin/${WORKING_BRANCH}" 2>/dev/null) || {
            echo "[reconcile] 无法解析 origin/${WORKING_BRANCH}" >&2
            exit 3
        }
    fi

    echo "[reconcile] --continue: 使用显式 lease 推送（first-reconciler-wins）..." >&2
    if ! git push --force-with-lease="${WORKING_BRANCH}:${WB_OLD_SHA}" origin "${RECONCILE_BRANCH}:refs/heads/${WORKING_BRANCH}"; then
        echo "[reconcile] push 被拒（lease 已丢失：另一 agent 在冲突解决期间向 ${WORKING_BRANCH} 推送了提交）。" >&2
        echo "[reconcile] 请重新执行本脚本（不带 --continue），以最新 origin/${WORKING_BRANCH} 重新 rebase。" >&2
        cleanup_reconcile_artifacts
        exit 2
    fi

    echo "[reconcile] 切回之前分支并清理 ${RECONCILE_BRANCH}..." >&2
    git checkout - >/dev/null 2>&1 || true
    git branch -D "$RECONCILE_BRANCH" >/dev/null 2>&1 || true
    rm -f "$LEASE_FILE" 2>/dev/null || true

    clear_blocked_metadata
    echo "[reconcile] 完成 — ${WORKING_BRANCH} 现在已包含 origin/master。" >&2
    exit 0
fi

# ------------------------------------------------------------------------
# Normal mode: fresh reconcile from origin/<wb>.
# ------------------------------------------------------------------------

echo "[reconcile] fetching origin..." >&2
git fetch origin >/dev/null 2>&1 || { echo "[reconcile] fetch 失败" >&2; exit 3; }

if ! git ls-remote --exit-code --heads origin "$WORKING_BRANCH" >/dev/null 2>&1; then
    echo "[reconcile] 远程不存在 origin/${WORKING_BRANCH}" >&2
    exit 3
fi

WB_OLD_SHA=$(git rev-parse "origin/${WORKING_BRANCH}" 2>/dev/null) || {
    echo "[reconcile] 无法解析 origin/${WORKING_BRANCH}" >&2
    exit 3
}

# Record the lease baseline so a later --continue can still detect commits that
# landed on <wb> during conflict resolution.
echo "$WB_OLD_SHA" > "$LEASE_FILE" 2>/dev/null || true

# Reentry safety: a reconcile/<wb> from a previous run may already exist. Never
# blindly `branch -D` it — it may hold human-resolved conflicts.
if git rev-parse --verify "$RECONCILE_BRANCH" >/dev/null 2>&1; then
    GIT_DIR="$(git rev-parse --git-dir)"
    if [ -d "${GIT_DIR}/rebase-merge" ] || [ -d "${GIT_DIR}/rebase-apply" ]; then
        echo "[reconcile] 检测到 ${RECONCILE_BRANCH} 仍处于 rebase 进行中——未删除，以保留已解决的冲突。" >&2
        echo "[reconcile] 请在该分支上解决冲突后运行：" >&2
        echo "  bash $0 --continue ${WORKING_BRANCH}" >&2
        exit 1
    fi
    echo "[reconcile] ${RECONCILE_BRANCH} 已存在但未处于 rebase。" >&2
    echo "[reconcile] 若其中含未推送的人工解决，请改用 --continue；若为旧残留，删除后重试：" >&2
    echo "  git branch -D ${RECONCILE_BRANCH} && bash $0 ${WORKING_BRANCH}" >&2
    rm -f "$LEASE_FILE" 2>/dev/null || true
    exit 1
fi

echo "[reconcile] 从 origin/${WORKING_BRANCH}（${WB_OLD_SHA}）创建分支 ${RECONCILE_BRANCH}..." >&2
git checkout -b "$RECONCILE_BRANCH" "origin/${WORKING_BRANCH}" || {
    echo "[reconcile] checkout 失败（可能本地有未提交改动）" >&2
    rm -f "$LEASE_FILE" 2>/dev/null || true
    exit 3
}

echo "[reconcile] rebase 到 origin/master..." >&2
if ! git rebase origin/master; then
    echo "[reconcile] 发生冲突。请在 ${RECONCILE_BRANCH} 上解决冲突，然后运行：" >&2
    echo "  bash $0 --continue ${WORKING_BRANCH}" >&2
    echo "[reconcile]（不要重跑不带 --continue 的脚本，否则会丢弃已解决的冲突）" >&2
    exit 1
fi

echo "[reconcile] rebase 干净，使用显式 lease 推送（first-reconciler-wins）..." >&2
if ! git push --force-with-lease="${WORKING_BRANCH}:${WB_OLD_SHA}" origin "${RECONCILE_BRANCH}:refs/heads/${WORKING_BRANCH}"; then
    echo "[reconcile] push 被拒（lease 已丢失：另一 agent 抢先向 ${WORKING_BRANCH} 推送）。请重新执行本脚本。" >&2
    cleanup_reconcile_artifacts
    exit 2
fi

echo "[reconcile] 切回之前分支并清理 ${RECONCILE_BRANCH}..." >&2
git checkout - >/dev/null 2>&1 || true
git branch -D "$RECONCILE_BRANCH" >/dev/null 2>&1 || true
rm -f "$LEASE_FILE" 2>/dev/null || true

clear_blocked_metadata
echo "[reconcile] 完成 — ${WORKING_BRANCH} 现在已包含 origin/master。" >&2
