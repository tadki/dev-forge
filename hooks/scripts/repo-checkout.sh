#!/bin/bash
# SessionStart hook — auto-checkout repos on agent startup
# SEE-505: Added integrity check, retry, and non-blocking hints via hookSpecificOutput

FALLBACK_URL="https://github.com/tadki/KingOfLikes-Godot.git"
REPO_NAME="KingOfLikes-Godot"

# SEE-1005: SessionStart fires in every CC session, including independent
# subprocesses spawned for controlled experiments. Two protections bound it:
#   1. Re-entrancy early-exit — skip the whole align flow when this repo was
#      aligned very recently (marker fresh + upstream still set).
#   2. Bounded timeouts — every blocking network op is wrapped so a slow/hung
#      network or a racing subprocess can never block CC indefinitely. On
#      timeout the op fails soft and the existing fallback paths take over.
GIT_FETCH_TIMEOUT=30      # git fetch / ls-remote against origin
GIT_PUSH_TIMEOUT=45       # git push (force-with-lease, shared-branch create)
GIT_REBASE_TIMEOUT=60     # §B auto-rebase (worktree add + rebase origin/master)
MULTICA_CLI_TIMEOUT=20    # multica issue / agent / metadata CLI calls
REPO_CHECKOUT_TIMEOUT=120 # multica repo checkout (full clone can be large)
MARKER_FRESH_SECS=600     # treat .cc-aligned-* marker as valid for 10 min

# --- Helper: output non-blocking hint via hookSpecificOutput ---
output_hint() {
    local msg="$1"
    jq -n --arg msg "$msg" --arg event "SessionStart" \
        '{hookSpecificOutput: {hookEventName: $event, additionalContext: $msg}}'
}

# --- Helper: output fallback hint, checking if working_branch exists in metadata ---
output_fallback_hint() {
    local repo_dir="$1"
    local checkout_note="$2"
    local issue_id fallback_wb=""
    issue_id=$(resolve_issue_id)
    if [ -n "$issue_id" ]; then
        fallback_wb=$(resolve_working_branch_from_metadata "$issue_id")
    fi
    if [ -n "$fallback_wb" ]; then
        output_hint "本 issue 已设置 working branch ${fallback_wb}，但本地 reset 失败。请尝试手动执行：git fetch origin && git branch -u origin/${fallback_wb} && git reset --hard origin/${fallback_wb}。推送到共享分支请使用显式 refspec：git push origin HEAD:refs/heads/${fallback_wb}（裸 git push 会被 push-guard 拦截）。Repo 已自动检出，无需重复 checkout${checkout_note}。如需进行代码工作或探索，请 cd 到 '$repo_dir'。严禁直接修改本地 main repo，除非有 owner 命令。"
    else
        output_hint "本 issue 尚未设置 working branch，故已自动创建默认 worktree。Repo 已自动检出，无需重复 checkout${checkout_note}。如需进行代码工作或探索，请 cd 到 '$repo_dir'。严禁直接修改本地 main repo，除非有 owner 命令。"
    fi
}

# --- Helper: read github_repo URLs from resources.json ---
get_repo_urls() {
    local res_file="$1"
    local python_cmd
    python_cmd="$(command -v python3 2>/dev/null || command -v python 2>/dev/null)"
    [ -n "$python_cmd" ] || return
    "$python_cmd" -c "
import json, sys
try:
    with open('$res_file', 'r', encoding='utf-8') as f:
        data = json.load(f)
    for r in data.get('resources', []):
        if r.get('resource_type') == 'github_repo':
            url = r.get('resource_ref', {}).get('url', '')
            if url:
                print(url)
except Exception:
    pass
" 2>/dev/null
}

# --- Helper: resolve issue_id via MULTICA_TASK_ID -> MULTICA_AGENT_ID fallback chain ---
resolve_issue_id() {
    # Path 0 (most reliable): direct lookup by task id via agent tasks. From the
    # moment a task is dispatched, `multica agent tasks` lists it with id + issue_id,
    # so this path does not depend on run-messages being populated or the task
    # having transitioned to running / having work_dir filled (Bug A).
    if [ -n "${MULTICA_TASK_ID:-}" ] && [ -n "${MULTICA_AGENT_ID:-}" ]; then
        local issue_id
        issue_id=$(multica agent tasks "$MULTICA_AGENT_ID" --output json 2>/dev/null | jq -r --arg tid "$MULTICA_TASK_ID" '
            .[] | select(.id == $tid) | .issue_id // empty
        ' 2>/dev/null | head -n1)
        [ -n "$issue_id" ] && { echo "$issue_id"; return 0; }
    fi

    # Path 1: MULTICA_TASK_ID + multica issue run-messages
    if [ -n "${MULTICA_TASK_ID:-}" ]; then
        local issue_id
        issue_id=$(timeout "$MULTICA_CLI_TIMEOUT" multica issue run-messages "$MULTICA_TASK_ID" --output json 2>/dev/null | node -e "
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
        [ -n "$issue_id" ] && { echo "$issue_id"; return 0; }
    fi

    # Path 2: MULTICA_AGENT_ID + multica agent tasks + work_dir match
    if [ -n "${MULTICA_AGENT_ID:-}" ]; then
        local issue_id
        issue_id=$(timeout "$MULTICA_CLI_TIMEOUT" multica agent tasks "$MULTICA_AGENT_ID" --output json 2>/dev/null | jq -r --arg pwd "$PWD" '
            .[] | select(.status == "running" and .work_dir == $pwd) | .issue_id
        ' 2>/dev/null | head -n1)
        [ -n "$issue_id" ] && { echo "$issue_id"; return 0; }
    fi

    return 1
}

# --- Helper: read working_branch from issue metadata (SEE-954 dedup) ---
# Shared by output_fallback_hint, try_auto_create_shared_branch, and
# try_shared_branch_reset. Echoes the working_branch value (empty when absent).
resolve_working_branch_from_metadata() {
    local issue_id="$1"
    [ -n "$issue_id" ] || return 0
    timeout "$MULTICA_CLI_TIMEOUT" multica issue metadata list "$issue_id" --output json 2>/dev/null | node -e "
        let d=''; process.stdin.on('data', c => d += c);
        process.stdin.on('end', () => {
            try {
                const meta = JSON.parse(d);
                if (meta.working_branch) {
                    process.stdout.write(meta.working_branch);
                }
            } catch(e) {}
        });
    " 2>/dev/null || true
}

# --- Helper: check repo integrity ---
check_integrity() {
    local repo_dir="$1"
    [ -d "$repo_dir" ] || return 1
    [ -e "$repo_dir/.git" ] || return 1
    (cd "$repo_dir" && git rev-parse --git-dir > /dev/null 2>&1) || return 1
    local file_count
    file_count=$(find "$repo_dir" -mindepth 1 -maxdepth 1 ! -name '.git' 2>/dev/null | wc -l)
    [ "$file_count" -gt 0 ] || return 1
    return 0
}

# --- Helper: refuse checkout if cwd is already inside a git repo (SEE-913) ---
# Prevents nested worktree creation. The multica task workdir is never a git
# repo, so this never blocks the legitimate checkout path. Fail-open when git
# is unavailable; the platform-side /repo/checkout guard is the fail-closed
# authority.
refuse_if_inside_git_repo() {
    local toplevel
    if toplevel=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$toplevel" ]; then
        output_hint "拒绝执行 multica repo checkout：当前目录已位于 git 仓库内部（${toplevel}），在此创建 worktree 会产生嵌套仓库（SEE-913）。当前目录: $PWD。请在非 git 仓库目录（如 multica 任务 workdir）内重试，或直接在当前仓库内工作。本次 SessionStart 跳过自动 checkout。"
        exit 0
    fi
}

# --- Helpers: agent branch upstream alignment (SEE-948) ---
# Current branch name; empty when HEAD is detached (symbolic-ref fails on detached).
get_current_branch() {
    git symbolic-ref --short HEAD 2>/dev/null
}

# True if tracked files have unstaged/uncommitted changes.
# Untracked files are intentionally excluded — `git stash push` (no -u) and
# `git reset --hard` both leave untracked files alone, so they must not trip
# the dirty signal either.
is_worktree_dirty() {
    ! git diff-index --quiet HEAD -- 2>/dev/null
}

# List agent-produced commits that would be lost on reset: between upstream_ref
# and HEAD, excluding anything already on master. In the SEE-954 model origin/
# <working_branch> already contains master (via the §B auto-rebase below), so
# `--not origin/master` never hides real agent commits and keeps a freshly
# aligned checkout — whose HEAD is an ancestor of master — from falsely
# tripping the protection.
list_unpushed_commits() {
    local upstream_ref="$1"
    git log "${upstream_ref}..HEAD" --not origin/master --oneline 2>/dev/null
}

# Idempotently point the current branch's upstream at origin/<working_branch>.
# Early-returns when already correct so the common rerun path does no network I/O.
set_agent_upstream() {
    local working_branch="$1"
    local current_branch desired_upstream current_upstream
    current_branch=$(get_current_branch)
    [ -n "$current_branch" ] || return 1
    desired_upstream="origin/${working_branch}"
    current_upstream=$(git rev-parse --abbrev-ref "@{upstream}" 2>/dev/null || true)
    [ "$current_upstream" = "$desired_upstream" ] && return 0
    timeout "$GIT_FETCH_TIMEOUT" git ls-remote --exit-code --heads origin "$working_branch" >/dev/null 2>&1 || return 1
    git branch --set-upstream-to="$desired_upstream" "$current_branch" >/dev/null 2>&1
}

# Align the agent branch HEAD to origin/<working_branch>, set upstream. Single
# source of truth for the A/B/C entry points (Refacty §3, Revy R8), so the
# race/early-exit path inherits the same protection as the main path (Revy E8).
#
# SEE-954: the per-SessionStart `git rebase origin/master` is gone. A §B
# auto-rebase advances origin/<working_branch> to contain master (first-agent
# -wins via --force-with-lease) before the reset below, so the agent branch
# picks up master transitively and the per-tool-call rebase hook is no longer
# needed. On conflict it aborts, pins blocked_reason/waiting_on metadata for
# Leader, emits conflict_msg, and falls through — the agent keeps working on
# the (unchanged) origin/<working_branch> until Leader reconciles.
#
# Internal order:
#   fetch → remote-exists → detached guard → unpushed guard
#   → §B auto-rebase master (first-agent-wins) → dirty stash → reset
#   → set upstream → stash pop → touch .cc-aligned marker → success → exit 0
#
# success_msg / conflict_msg are supplied by the caller so each entry point
# keeps its existing user-facing wording (Revy R6). conflict_msg is emitted when
# the §B auto-rebase hits a merge conflict (Leader reconcile required).
#
# Return contract:
#   - exit 0 on success or any recoverable stop-with-hint state (detached HEAD,
#     unpushed protection, stash failure, pop conflict, upstream failure). These
#     are terminal — a fallback strategy cannot help.
#   - return 1 (silent) only when the remote branch is missing or reset failed,
#     so callers can fall back. A stays silent to preserve its original
#     fall-through; B/C wrap the call with their own diagnostic hint.
align_agent_branch_to_working_branch() {
    local repo_dir="$1"
    local working_branch="$2"
    local success_msg="$3"
    local conflict_msg="$4"
    local desired_upstream="origin/${working_branch}"
    local abs_repo_dir

    # Resolve repo_dir to an absolute path so the cd below is idempotent for
    # all three call sites. If a caller already cd'd into the repo and passed a
    # relative basename (e.g. KingOfLikes-Godot), the bare path is no longer
    # reachable as a subdirectory, so a naive re-cd would fail (Bug B). In that
    # case we fall back to the current PWD when its basename matches.
    abs_repo_dir=$(cd "$repo_dir" 2>/dev/null && pwd) || true
    if [ -z "$abs_repo_dir" ] && [ "$(basename "$PWD")" = "$repo_dir" ]; then
        abs_repo_dir="$PWD"
    fi
    if [ -n "$abs_repo_dir" ]; then
        repo_dir="$abs_repo_dir"
    fi

    cd "$repo_dir" || { output_hint "无法进入仓库目录 ${repo_dir}，请检查路径。"; return 1; }
    timeout "$GIT_FETCH_TIMEOUT" git fetch origin >/dev/null 2>&1 || true

    # Verify the remote branch is fetchable; stay silent on failure so callers
    # can fall back (R9 network-vs-missing distinction is the caller's job).
    timeout "$GIT_FETCH_TIMEOUT" git fetch origin "refs/heads/${working_branch}" >/dev/null 2>&1 || return 1

    # Detached HEAD guard (§1.3): symbolic-ref returns empty on detached HEAD.
    local current_branch
    current_branch=$(get_current_branch)
    if [ -z "$current_branch" ]; then
        output_hint "[repo-checkout] 当前为 detached HEAD，无法设置 upstream。请先 checkout 分支（git checkout <branch>）后再运行 SessionStart hook。当前仓库： $repo_dir"
        exit 0
    fi

    # Unpushed-commit protection (§1.1). Decoupled from dirty: any agent-produced
    # commit not yet on origin/<working_branch> blocks the reset, regardless of
    # working-tree state. Hook aborts BEFORE stashing so the agent's working tree
    # stays visible (§2.1 order fix — Revy T21).
    local unpushed
    unpushed=$(list_unpushed_commits "$desired_upstream")
    if [ -n "$unpushed" ]; then
        output_hint "[repo-checkout] 本地未推送 commit 保护：当前分支有未推送到 ${desired_upstream} 的 commit，自动 reset 会丢失它们，已中止。失败命令： git reset --hard ${desired_upstream}。受影响 commit：
${unpushed}
下一步：
  1) 先推送： git push origin HEAD:refs/heads/${working_branch}
  2) 或备份： git branch backup/${current_branch}/manual
  3) 确认可丢弃后再运行 SessionStart hook
当前仓库： $repo_dir"
        exit 0
    fi

    # Snapshot pre-existing stashes for diagnostics only. We never pop a stash we
    # did not create — auto_stashed tracks only our own.
    git stash list >/dev/null 2>&1 || true

    # §B auto-rebase master onto the shared working branch (SEE-954). Advances
    # origin/<working_branch> to contain master BEFORE the reset, so the agent
    # branch picks up master transitively and the per-tool-call rebase hook is
    # no longer needed. Runs in an isolated worktree so the agent's worktree
    # (possibly dirty, not yet stashed) is never touched. Idempotent: skipped
    # when origin/master is already an ancestor of origin/<working_branch>.
    # On conflict: abort, pin blocked_reason/waiting_on metadata for Leader,
    # emit conflict_msg, and fall through — the reset below aligns the agent to
    # the (unchanged) origin/<working_branch> until Leader reconciles.
    if ! git merge-base --is-ancestor origin/master "$desired_upstream" 2>/dev/null; then
        local _issue_id wb_old_sha rebase_tmp_branch rebase_wt
        wb_old_sha=$(git rev-parse "$desired_upstream" 2>/dev/null || true)
        rebase_tmp_branch="cc-rebase-${working_branch//\//-}"
        rebase_wt="${TEMP:-/tmp}/cc-rebase-wt.$$"
        [ -e "$rebase_wt" ] && rm -rf "$rebase_wt" 2>/dev/null || true
        if [ -n "$wb_old_sha" ] && timeout "$GIT_REBASE_TIMEOUT" git worktree add -b "$rebase_tmp_branch" "$rebase_wt" "$desired_upstream" >/dev/null 2>&1; then
            if timeout "$GIT_REBASE_TIMEOUT" git -C "$rebase_wt" rebase origin/master >/dev/null 2>&1; then
                # first-agent-wins: the explicit lease is the lock. A losing
                # agent's push is rejected silently and origin/<wb> still ends
                # up containing master — safe either way.
                timeout "$GIT_PUSH_TIMEOUT" git -C "$rebase_wt" push --force-with-lease="${working_branch}:${wb_old_sha}" \
                    origin "${rebase_tmp_branch}:refs/heads/${working_branch}" >/dev/null 2>&1 || true
            else
                git -C "$rebase_wt" rebase --abort >/dev/null 2>&1 || true
                _issue_id=$(resolve_issue_id)
                if [ -n "$_issue_id" ]; then
                    timeout "$MULTICA_CLI_TIMEOUT" multica issue metadata set "$_issue_id" --key blocked_reason \
                        --value "auto-rebase-conflict-${working_branch}" >/dev/null 2>&1 || true
                    timeout "$MULTICA_CLI_TIMEOUT" multica issue metadata set "$_issue_id" --key waiting_on \
                        --value "leader-reconcile" >/dev/null 2>&1 || true
                fi
                output_hint "${conflict_msg}"
            fi
            git worktree remove --force "$rebase_wt" >/dev/null 2>&1 || true
            git branch -D "$rebase_tmp_branch" >/dev/null 2>&1 || true
            # Refresh origin/<working_branch> so the reset below uses the new tip
            # (no-op when the push lost the lease or the rebase conflicted).
            timeout "$GIT_FETCH_TIMEOUT" git fetch origin "refs/heads/${working_branch}" >/dev/null 2>&1 || true
        fi
    fi

    local needs_reset=false auto_stashed=false
    if [ "$(git rev-parse HEAD 2>/dev/null)" != "$(git rev-parse "${desired_upstream}" 2>/dev/null)" ]; then
        needs_reset=true
    fi

    # Dirty stash only when we are about to move HEAD.
    if [ "$needs_reset" = true ] && is_worktree_dirty; then
        if ! git stash push -m "repo-checkout auto-stash before reset" >/dev/null 2>&1; then
            output_hint "[repo-checkout] stash 失败：无法保存本地改动，请手动 commit 或 stash 后重新运行 hook。当前仓库： $repo_dir"
            exit 0
        fi
        auto_stashed=true
    fi

    if [ "$needs_reset" = true ]; then
        if ! git reset --hard "$desired_upstream" >/dev/null 2>&1; then
            # Restore the working tree we just stashed, then let the caller hint.
            [ "$auto_stashed" = true ] && git stash pop >/dev/null 2>&1 || true
            return 1
        fi
    fi

    if ! set_agent_upstream "$working_branch"; then
        [ "$auto_stashed" = true ] && git stash pop >/dev/null 2>&1 || true
        output_hint "[repo-checkout] upstream 设置失败：无法将当前分支 upstream 设置为 ${desired_upstream}。失败命令： git branch --set-upstream-to=${desired_upstream} ${current_branch}。下一步：
  1) 检查远程分支： git ls-remote --heads origin ${working_branch}
  2) 若不存在请联系 Owner 确认 metadata 的 working_branch
  3) 若存在请手动执行： git branch --set-upstream-to=${desired_upstream} ${current_branch}
当前仓库： $repo_dir"
        exit 0
    fi

    # Restore the agent's working-tree changes on top of the aligned HEAD.
    # (SEE-954: master is already merged into origin/<working_branch> via the
    # §B auto-rebase above, so no per-SessionStart rebase runs here.)
    if [ "$auto_stashed" = true ]; then
        if ! git stash pop >/dev/null 2>&1; then
            local conflict_files
            conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null)
            output_hint "[repo-checkout] stash pop 冲突：恢复本地改动时发生冲突（upstream 已设置，rebase 已完成）。失败命令： git stash pop。冲突文件：
${conflict_files}
下一步：
  1) 查看状态： git status
  2) 标记解决： git add <file>
  3) 冲突 stash 仍保留在 git stash list，解决后用 git stash drop 清理
当前仓库： $repo_dir"
            exit 0
        fi
    fi

    # --- SEE-1111 目标1/目标2: generate the private worktree's clean
    # project.godot (copy from D-drive master HEAD when the untracked file is
    # absent after the reset) and pin the agent's godot-mcp port into it.
    # The whole file is untracked + gitignored (SEE-1111 目标1), so the reset
    # leaves no project.godot on a fresh worktree; prepare-worktree.sh copies
    # it from D-drive HEAD / origin/master and then applies the
    # "port_override 改成该 agent 专属端口" half, guarded by the same
    # write-target guard as configure (never the shared D-drive checkout).
    # Best-effort only: when no agent name/port is resolvable (manual session,
    # Chekky, etc.) or the file has legit uncommitted edits, skip silently —
    # the launcher/proxy re-pins at spawn time via configure. Never break the
    # session over this.
    # This function has already `cd`'d into $repo_dir (see above).
    # 缺陷3 fix (SEE-1111): the previous call passed no --worktree and had no
    # KOL_AGENT_NAME exported, so prepare-worktree.sh could neither resolve its
    # repo root nor the agent port on a fresh checkout, and `|| true` swallowed
    # the failure silently — leaving the project.godot ungenerated. Pass the
    # current checkout explicitly and export the agent name; keep the
    # non-blocking best-effort (no failure hint on the common non-agent /
    # no-toolchain cases) but LOG a hint when the script is present and fails.
    # SEE-1273 T5-F: launch 工具链单落点解析（submodule addons/godot_mcp/launch）
    PREPARE_WT="$(mcp_launch_script prepare-worktree.sh "$(pwd)")" || PREPARE_WT=""
    if [[ -x "$PREPARE_WT" ]]; then
        # KOL_AGENT_NAME: MULTICA_AGENT_NAME when set; otherwise resolve the
        # agent's own name via the CLI so Chekky etc. still pin their port
        # (prepare-worktree falls back to a random free port when no name).
        local _prepare_agent="${MULTICA_AGENT_NAME:-}"
        if [ -z "$_prepare_agent" ] && [ -n "${MULTICA_AGENT_ID:-}" ]; then
            _prepare_agent=$(timeout "$MULTICA_CLI_TIMEOUT" multica agent get "$MULTICA_AGENT_ID" --output json 2>/dev/null | jq -r '.name // empty' 2>/dev/null)
        fi
        PREP_RC=0
        # SEE-1396 P1: prepare-worktree.sh 是本 hook 内最后一个无 timeout 包裹的
        # 外部调用——/mnt/d D-state 挂起时它会把 SessionStart 无限阻塞；按本文件
        # 既有模式补包裹（时长对齐 REPO_CHECKOUT_TIMEOUT=120，属全 clone 量级操作）。
        if [ -n "$_prepare_agent" ]; then
            KOL_AGENT_NAME="$_prepare_agent" timeout "$REPO_CHECKOUT_TIMEOUT" \
                "$PREPARE_WT" --worktree "$(pwd)" >/dev/null 2>&1 || PREP_RC=$?
        elif [ -n "${KOL_MCP_PORT:-}" ]; then
            timeout "$REPO_CHECKOUT_TIMEOUT" \
                "$PREPARE_WT" --worktree "$(pwd)" --port "$KOL_MCP_PORT" >/dev/null 2>&1 || PREP_RC=$?
        fi
        # Manual sessions (no agent name/port resolvable) skip silently — the
        # launcher/proxy re-pins at spawn time. Only agent/toolchain sessions
        # that FAIL get a hint, so a broken checkout is never silent (缺陷3).
        if [ "$PREP_RC" -ne 0 ]; then
            output_hint "[repo-checkout] prepare-worktree.sh 未生成 project.godot（rc=${PREP_RC}）——launcher/proxy 会在编辑启动时再尝试。若这是 Bachi/Atlas 等 godot-mcp agent 的检出，请检查 addons/godot_mcp/launch/prepare-worktree.sh。"
        fi
    fi

    local _DIR
    _DIR="$(pwd)"
    _DIR="${_DIR////_}"
    _DIR="${_DIR// /_}"
    touch "${TEMP:-/tmp}/.cc-aligned-${_DIR}"
    # SEE-1388 §SPEC-009（fingerprint d9657f804c2a）：setup.sh 幂等接入 checkout 链。
    # 新 clone core.hooksPath 未设 + hook 文件无执行位时 post-checkout 链不生效
    # （激活率 0% 事故）；session 启动的 checkout 链在此补齐激活。setup.sh 自身
    # 幂等，重复执行安全且静默；更新失败不影响主流程（fail-open 精神）。
    if [ -n "$repo_dir" ] && [ -f "$repo_dir/.githooks/setup.sh" ]; then
        ( cd "$repo_dir" && sh .githooks/setup.sh >/dev/null 2>&1 ) || true
    fi
    # SEE-1268: the aligned HEAD may carry submodule pointers — materialize the
    # content (best-effort) before handing the worktree to the agent.
    ensure_submodules_materialized "$repo_dir" || true
    # SEE-1285: SessionStart [gitlink-sync] hint — 一行零 token 状态提示。
    # state.json 缺失/损坏时 lib 自身静默跳过（rc 0 无输出）。
    # SEE-1381 §SPEC-021：hint 路径锚定本脚本自身目录（$0 在 run_script
    # ${HOOKS_DIR}/... 与直接 bash 调用下均指向本脚本），不再依赖 cwd=仓库根——
    # 非仓库根 cwd 下 hint 由静默缺失转为正常产出（语义增强）；仓库根 cwd 口径零变化。
    local _gitlink_hint
    _gitlink_hint="$(bash "$(cd "$(dirname "$0")" && pwd)/lib/gitlink-sync-hint.sh" 2>/dev/null || true)"
    [ -n "$_gitlink_hint" ] && output_hint "$_gitlink_hint"
    output_hint "${success_msg}"
    exit 0
}

# --- SEE-1268: materialize submodule content after alignment ---
# multica repo checkout / git reset --hard move gitlinks but never populate the
# child working trees, so a worktree aligned to a branch carrying a submodule
# (e.g. addons/godot_mcp) would point at a submodule it cannot use.
# `submodule update --init --recursive` is the fallback the platform checkout
# lacks. Best-effort: bounded by GIT_SUBMODULE_TIMEOUT, failure emits a hint
# (never a silent skip) but never blocks the session. No-op when .gitmodules
# is absent (the historical case).
GIT_SUBMODULE_TIMEOUT=60 # submodule update --init --recursive

# --- SEE-1396 D1: prune stale materializations of REMOVED submodules ---
# 过渡期形态：platform checkout 可能在 pre-split 提交（.gitmodules 历史里还有
# gitlink）上执行过 submodule update，留下已拆除 submodule 的完整工作树残锤
# （SEE-1396 §SPEC-001c 实机 FAIL 根因）。磁盘驱动枚举：找出树内所有携带 .git
# 指针的目录（含 .dev/qa-toolkit 这类「HEAD 不跟踪、.gitmodules 已不注册」的
# 残锤），仅清理同时满足 ①不被 HEAD 跟踪为 gitlink/文件、②未注册于现行
# .gitmodules 的路径——绝不动仍注册的 submodule。
# 语义边界（SEE-1396 三轮如实声明）：
# - 枚举覆盖 .git 指针位于 find 深度 2~4 的目录（即仓库内 depth 1~3 的目录），
#   根级残锤（depth 1 目录，其 .git 在深度 2）实际会被清理；
# - 嵌套含 .git 目录的未跟踪克隆不可与残锤区分，一并删除；
# - 纯未跟踪工作文件（无 .git 指针）一律不碰；
# - index 对账域（D4/D6 收敛）：仅 ①被清路径自身 staged 条目（ls-files -- path）
#   ②祖先目录条目中 mode 160000（gitlink）且为被清路径前缀者（嵌套形态所需）
#   ——普通 tracked 文件条目永不入列，同父 tracked 内容绝不受波及。
cleanup_removed_submodules() {
    local repo_dir="$1"
    ( [ -d "$repo_dir/.git" ] || [ -f "$repo_dir/.git" ] ) || return 0
    local path
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        # HEAD 里仍跟踪（gitlink 或普通文件）→ 不清；现行 .gitmodules 仍注册 → 不清。
        if git -C "$repo_dir" ls-tree -r --name-only HEAD -- "$path" 2>/dev/null | grep -q .; then
            continue
        fi
        if git -C "$repo_dir" config --file "$repo_dir/.gitmodules" --get-regexp \
                '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}' | grep -Fxq "$path"; then
            continue
        fi
        # D4：index 对账治本——被清路径若已 staged，必须连同 index 条目一起取消，
        # 否则残 `AD` 一次 commit 即复活已拆除 submodule（磁盘清理成为假象）。
        # D6（CRITICAL 收敛）：对账域严禁扩到父目录全量列表（真实 KOL 形态下会把
        # 残锤父目录 .dev 下全部 tracked 条目 staged 删除）；只清 ①自身条目与
        # ②祖先链上的 gitlink（160000）条目。ls-files 先于磁盘 rm 执行。
        # 用 update-index --force-remove 纯 index 手术而非 git rm --cached：残锤
        # 常带损坏/悬空的 submodule .git 指针（gitdir 指向已不存在的位置），git rm
        # --cached 会对 160000 条目探测该 gitdir 并 fatal（本机实证 rc=128），
        # 纯 index 手术不触磁盘/子模块 probe，天然免疫这类残锤。
        local _idx_entries
        _idx_entries=$(git -C "$repo_dir" ls-files -- "$path" 2>/dev/null; \
            git -C "$repo_dir" ls-files -s 2>/dev/null \
                | awk -F'\t' -v p="$path" '$1 ~ /^160000 / && index(p, $2 "/") == 1 { print $2 }')
        local _idx_failed=0
        while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            if ! git -C "$repo_dir" update-index --force-remove -- "$entry" 2>/dev/null; then
                _idx_failed=1
            fi
        done <<<"$_idx_entries"
        if [ "$_idx_failed" -ne 0 ]; then
            output_hint "[repo-checkout] 已拆除 submodule 残留 $path 的 git index 对账失败——请手动执行：git rm --cached -r '$path'（SEE-1396 D4）"
        fi
        if rm -rf "${repo_dir:?}/$path" 2>/dev/null; then
            output_hint "[repo-checkout] 已清理已拆除 submodule 的物化残留： $path（SEE-1396）"
        else
            # D5：rm 失败必须如实报残留，不再假成功。
            output_hint "[repo-checkout] 已拆除 submodule 残留 $path 清理失败（磁盘删除未成功），目录仍在——请手动执行： rm -rf '${repo_dir:?}/$path'（SEE-1396 D5）"
        fi
    done < <(
        find "$repo_dir" -mindepth 2 -maxdepth 4 -name '.git' \
            -not -path "$repo_dir/.git/*" -not -path "$repo_dir/.git" \
            -printf '%h\n' 2>/dev/null | sed "s|^$repo_dir/||" | sort -u
    )
}

ensure_submodules_materialized() {
    local repo_dir="$1"
    # SEE-1396 D1: 物化前先清已拆除 submodule 的残锤——否则残锤里的 gitdir
    # 会与现行 submodule 的 gitdir 同源漂移（SEE-1381 core.worktree 同款机制）。
    cleanup_removed_submodules "$repo_dir"
    [ -f "$repo_dir/.gitmodules" ] || return 0
    local out
    out=$(cd "$repo_dir" && timeout "$GIT_SUBMODULE_TIMEOUT" \
        git submodule update --init --recursive 2>&1)
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        output_hint "[repo-checkout] submodule 兜底失败（rc=${rc}，超时 ${GIT_SUBMODULE_TIMEOUT}s）：本 worktree 的 submodule 内容可能缺失。失败命令： git submodule update --init --recursive。输出：
${out}
下一步：手动执行同一命令重试；若反复失败请联系 Leader。当前仓库： $repo_dir"
        return 1
    fi
    return 0
}

# --- Helper: auto-create shared branch if working_branch metadata doesn't exist ---
# When no working_branch is set, creates a deterministic branch (shared/SEE-XXX),
# writes metadata, resets to it, and exits the script.
# On failure: returns silently. When working_branch already exists: outputs hint and exits.
try_auto_create_shared_branch() {
    local repo_dir="$1"

    local issue_id issue_identifier working_branch
    issue_id=$(resolve_issue_id)
    [ -n "$issue_id" ] || return 1

    # Get issue identifier for deterministic branch naming
    issue_identifier=$(timeout "$MULTICA_CLI_TIMEOUT" multica issue get "$issue_id" --output json 2>/dev/null | node -e "
        let d=''; process.stdin.on('data', c => d += c);
        process.stdin.on('end', () => {
            try {
                const issue = JSON.parse(d);
                if (issue.identifier) {
                    process.stdout.write(issue.identifier);
                }
            } catch(e) {}
        });
    " 2>/dev/null || true)
    [ -n "$issue_identifier" ] || return 1

    # If working_branch already set by another agent, try to reset to it
    working_branch=$(resolve_working_branch_from_metadata "$issue_id")
    if [ -n "$working_branch" ]; then
        align_agent_branch_to_working_branch "$repo_dir" "$working_branch" \
            "已成功将本 issue 的 working branch checkout 到 ${working_branch}。如需进行代码工作或探索，请 cd 到 '$repo_dir'。严禁直接修改本地 main repo，除非有 owner 命令。推送到共享分支：git push origin HEAD:refs/heads/${working_branch}。push-guard 钩子会自动验证 push 目标分支正确性。" \
            "本 issue 的 working branch ${working_branch} auto-rebase master 冲突，已通知 Leader reconcile（脚本：bash .dev/scripts/reconcile-working-branch.sh ${working_branch}）。agent 暂时继续基于旧 origin/${working_branch} 工作。如需进行代码工作或探索，请 cd 到 '$repo_dir'。严禁直接修改本地 main repo，除非有 owner 命令。" \
            || {
                # helper returned 1: remote branch missing (R10) or reset failed (R9).
                if ! timeout "$GIT_FETCH_TIMEOUT" git ls-remote --exit-code --heads origin "$working_branch" >/dev/null 2>&1; then
                    output_hint "[repo-checkout] metadata 与远程不一致：issue metadata 的 working_branch 为 ${working_branch}，但远程不存在该分支。请 Owner 确认 metadata，或手动创建：git push origin HEAD:refs/heads/${working_branch}。不要直接 push 到 origin/master。当前仓库： $repo_dir"
                else
                    output_hint "本 issue 已设置 working branch ${working_branch}，但本地 reset 失败。请尝试手动执行：git fetch origin && git reset --hard origin/${working_branch} && git rebase origin/master"
                fi
                exit 0
            }
        exit 0
    fi

    local branch_name="shared/${issue_identifier}"

    cd "$repo_dir" || { output_hint "无法进入仓库目录 ${repo_dir}，请检查路径。"; return 1; }
    timeout "$GIT_FETCH_TIMEOUT" git fetch origin >/dev/null 2>&1 || true

    # Race: another agent may have pushed the branch between metadata read and now
    if timeout "$GIT_FETCH_TIMEOUT" git ls-remote --exit-code --heads origin "$branch_name" >/dev/null 2>&1; then
        working_branch="$branch_name"
    else
        # Create new shared branch from current HEAD (master)
        if ! timeout "$GIT_PUSH_TIMEOUT" git push origin "HEAD:refs/heads/${branch_name}" >/dev/null 2>&1; then
            output_hint "自动创建共享分支失败：无法推送到远程。请检查网络或权限。"
            return 1
        fi
        working_branch="$branch_name"
    fi

    # Write metadata (best effort — if another agent wrote first, that's fine)
    timeout "$MULTICA_CLI_TIMEOUT" multica issue metadata set "$issue_id" --key working_branch --value "$working_branch" >/dev/null 2>&1 || true

    # Reset to shared branch and set upstream. A freshly-created branch == master,
    # so the §B auto-rebase idempotency guard skips it; master is picked up on a
    # later align only after master itself advances.
    align_agent_branch_to_working_branch "$repo_dir" "$working_branch" \
        "已自动创建共享分支 ${working_branch}（基于 master）。本 issue 的所有 Agent 共享此分支。如需进行代码工作或探索，请 cd 到 '$repo_dir'。严禁直接修改本地 main repo，除非有 owner 命令。" \
        "已自动创建共享分支 ${working_branch}（基于 master）。本 issue 的所有 Agent 共享此分支。如需进行代码工作或探索，请 cd 到 '$repo_dir'。严禁直接修改本地 main repo，除非有 owner 命令。" \
        || {
            output_hint "共享分支 ${working_branch} 已在远程创建，但本地 fetch/reset 失败。请尝试手动执行：git fetch origin && git reset --hard origin/${working_branch}"
            exit 0
        }
    exit 0
}

# --- Helper: reset to shared branch if working_branch metadata exists ---
# On success: outputs hint and exits the script
# On failure or no working_branch: returns silently
try_shared_branch_reset() {
    local repo_dir="$1"

    local issue_id working_branch
    issue_id=$(resolve_issue_id)
    [ -n "$issue_id" ] || return 1

    working_branch=$(resolve_working_branch_from_metadata "$issue_id")
    [ -n "$working_branch" ] || return 1

    align_agent_branch_to_working_branch "$repo_dir" "$working_branch" \
        "已成功将本 issue 的 working branch checkout 到 ${working_branch}。如需进行代码工作或探索，请 cd 到 '$repo_dir'。严禁直接修改本地 main repo，除非有 owner 命令。推送到共享分支：git push origin HEAD:refs/heads/${working_branch}。push-guard 钩子会自动验证 push 目标分支正确性。" \
        "本 issue 的 working branch ${working_branch} auto-rebase master 冲突，已通知 Leader reconcile（脚本：bash .dev/scripts/reconcile-working-branch.sh ${working_branch}）。agent 暂时继续基于旧 origin/${working_branch} 工作。如需进行代码工作或探索，请 cd 到 '$repo_dir'。严禁直接修改本地 main repo，除非有 owner 命令。" \
        || return 1
}

# SessionStart entry: sweep legacy idempotency markers from the removed
# rebase-before-work hook (SEE-954). No reader remains, so every .cc-rebase-*
# file is garbage; .cc-aligned-* is the new marker written on successful align.
rm -f "${TEMP:-/tmp}"/.cc-rebase-* 2>/dev/null || true

# --- SEE-1005: re-entrancy / subprocess early-exit ---
# SessionStart re-fires in every CC session, including independent subprocesses
# spawned for controlled experiments. Once this repo dir was aligned recently
# (marker fresh + HEAD still on a branch tracking the working branch upstream),
# skip the whole network-heavy align flow and exit fast — no fetch, no multica
# CLI, no rebase. Falls through silently when the marker is stale/absent, the
# upstream drifted, or HEAD is detached, so the legitimate first-align path and
# drift-correction path still run unchanged.
maybe_early_exit_if_aligned() {
    local repo_dir="$1"
    [ -n "$repo_dir" ] && [ -e "$repo_dir/.git" ] || return 1

    # Match the marker name written at the end of align_agent_branch_to_working_branch.
    local _DIR marker
    _DIR="$(cd "$repo_dir" && pwd)"
    _DIR="${_DIR////_}"
    _DIR="${_DIR// /_}"
    marker="${TEMP:-/tmp}/.cc-aligned-${_DIR}"
    [ -e "$marker" ] || return 1

    # Freshness gate (mtime within MARKER_FRESH_SECS).
    local now mtime age
    now=$(date +%s)
    mtime=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null || echo 0)
    age=$((now - mtime))
    [ "$age" -ge 0 ] && [ "$age" -le "$MARKER_FRESH_SECS" ] || return 1

    # Cheap local checks (no network): on a branch and upstream still configured.
    # If upstream is unset or HEAD detached, the align flow must run again.
    local current_branch upstream
    current_branch=$(cd "$repo_dir" && git symbolic-ref --short HEAD 2>/dev/null || true)
    [ -n "$current_branch" ] || return 1
    upstream=$(cd "$repo_dir" && git rev-parse --abbrev-ref "@{upstream}" 2>/dev/null || true)
    [ -n "$upstream" ] || return 1

    local wb="${upstream#origin/}"
    # SEE-1268: the re-entrancy fast path skips the align flow, which is where
    # submodule materialization lives — so a worktree whose submodule content is
    # missing but whose align marker is still fresh would hand the agent a
    # broken addon (no plugin.cfg). Cheap local check, bounded, best-effort.
    ensure_submodules_materialized "$repo_dir" || true
    output_hint "SessionStart 已跳过自动检出（重入/子进程保护，SEE-1005）：仓库 '${repo_dir##*/}' 近期已对齐，本地分支 ${current_branch} 跟踪 ${upstream}。如需代码工作请 cd 到 '${repo_dir##*/}'。推送到共享分支：git push origin HEAD:refs/heads/${wb}（裸 git push 会被 push-guard 拦截）。严禁直接修改本地 main repo，除非有 owner 命令。"
    exit 0
}

# --- Determine expected repo directory ---
RESOURCES_FILE="$PWD/.multica/project/resources.json"
DETECTED_REPO_DIR=""

if [ -f "$RESOURCES_FILE" ]; then
    PYTHON_CMD="$(command -v python3 2>/dev/null || command -v python 2>/dev/null)"
    if [ -n "$PYTHON_CMD" ]; then
        while read -r repo_url; do
            if [ -n "$repo_url" ]; then
                DETECTED_REPO_DIR=$(basename "$repo_url" .git)
            fi
        done < <(get_repo_urls "$RESOURCES_FILE")
    else
        output_hint "无法解析 resources.json，将使用默认仓库配置。"
    fi
fi

REPO_DIR="${DETECTED_REPO_DIR:-$REPO_NAME}"

# SEE-1005: re-entrancy fast path. If already aligned in the last few minutes,
# exit immediately without any network I/O. Covers independent subprocesses
# spawned inside an already-aligned task.
maybe_early_exit_if_aligned "$REPO_DIR" || true

# --- SEE-913 helpers above ---

# --- SEE-1170 Channel 1: stale-registration prune + single retry on checkout failure ---
# Defect 2 mitigation: when `multica repo checkout` fails because the bare repo
# still holds a stale worktree registration ("missing but already registered"),
# run `git worktree prune` on the bare repo (idempotent, no-op for live/in-flight
# worktrees) and retry checkout exactly once. Best-effort only — never loops.

resolve_bare_repo() {
    local repo_url="$1" ws_id slug bare_root match cursor
    ws_id="${MULTICA_WORKSPACE_ID:-}"
    if [ -z "$ws_id" ]; then
        ws_id=$(basename "$(cd "$PWD/../.." 2>/dev/null && pwd)" 2>/dev/null)
    fi
    [ -n "$ws_id" ] || return 1
    # Tier 1: env override (explicit non-default layout).
    if [ -n "${MULTICA_BARE_REPOS_ROOT:-}" ] && [ -d "${MULTICA_BARE_REPOS_ROOT}/${ws_id}" ]; then
        bare_root="${MULTICA_BARE_REPOS_ROOT%/}/${ws_id}"
    else
        # Tier 2: walk up from $PWD looking for a "<ancestor>/.repos/<ws_id>" dir.
        bare_root=""
        cursor="$PWD"
        while [ "$cursor" != "/" ] && [ -n "$cursor" ]; do
            if [ -d "${cursor}/.repos/${ws_id}" ]; then
                bare_root="${cursor}/.repos/${ws_id}"
                break
            fi
            cursor="$(dirname "$cursor")"
        done
        # Tier 3: legacy default (historical layout; kept as last-resort fallback).
        if [ -z "$bare_root" ]; then
            bare_root="/home/jerry/multica_workspaces/.repos/${ws_id}"
        fi
    fi
    slug="${repo_url#*://}"
    slug="${slug%/}"
    slug="${slug//\//+}"
    if [ -d "${bare_root}/${slug}" ]; then
        echo "${bare_root}/${slug}"
        return 0
    fi
    # slug drift fallback: match by repo name suffix
    match=$(ls -d "${bare_root}"/*"+$(basename "$repo_url" .git).git" 2>/dev/null | head -n1)
    [ -n "$match" ] && { echo "$match"; return 0; }
    return 1
}

bare_registration_exists() {
    local bare_repo="$1" wt_path="$2"
    git -C "$bare_repo" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $wt_path"
}

# Runs `multica repo checkout`; on a stale-registration failure prunes the bare
# repo and retries once. Sets CHECKOUT_FAILED=true on final failure and appends
# a diagnostic line to CHECKOUT_DIAG (surfaced via the hint notes in Step 2/4).
checkout_repo() {
    local repo_url="$1" repo_dir="$2" err_file rc stderr_hit wt_path bare_repo
    err_file=$(mktemp)
    if timeout "$REPO_CHECKOUT_TIMEOUT" multica repo checkout "$repo_url" >/dev/null 2>"$err_file"; then
        rm -f "$err_file"
        # SEE-1268: fresh worktrees from the bare cache carry gitlinks without
        # child content; materialize immediately (best-effort, hint on fail).
        ensure_submodules_materialized "$PWD/$repo_dir" || true
        return 0
    fi
    rc=$?
    stderr_hit=false
    grep -q "missing but already registered" "$err_file" 2>/dev/null && stderr_hit=true
    wt_path="$PWD/$repo_dir"
    bare_repo=$(resolve_bare_repo "$repo_url")
    # Fallback detection against git version stderr drift: target dir exists as
    # a shell (no .git) while the bare repo still holds its registration.
    if [ "$stderr_hit" = false ] && [ -d "$wt_path" ] && [ ! -e "$wt_path/.git" ] \
        && [ -n "$bare_repo" ] && bare_registration_exists "$bare_repo" "$wt_path"; then
        stderr_hit=true
    fi
    if [ "$stderr_hit" = false ]; then
        rm -f "$err_file"
        CHECKOUT_FAILED=true
        return 1
    fi
    if [ -z "$bare_repo" ]; then
        CHECKOUT_DIAG="${CHECKOUT_DIAG}检测到 stale worktree 注册信号（stderr 命中）但 bare repo 路径无法推导，跳过 prune+retry（SEE-1170）。"
        rm -f "$err_file"
        CHECKOUT_FAILED=true
        return 1
    fi
    timeout 15 git -C "$bare_repo" worktree prune >/dev/null 2>&1 || true
    if timeout "$REPO_CHECKOUT_TIMEOUT" multica repo checkout "$repo_url" >/dev/null 2>"$err_file"; then
        CHECKOUT_DIAG="${CHECKOUT_DIAG}检测到 stale worktree 注册，已对 bare repo 执行 git worktree prune，retry checkout 成功（SEE-1170 通道 1）。"
        rm -f "$err_file"
        ensure_submodules_materialized "$PWD/$repo_dir" || true
        return 0
    fi
    CHECKOUT_DIAG="${CHECKOUT_DIAG}检测到 stale worktree 注册并已 prune，但 retry checkout 仍失败（daemon 侧 ownership 标记可能未清除；缓解为 best-effort，SEE-1170 通道 1）。"
    rm -f "$err_file"
    CHECKOUT_FAILED=true
    return 1
}

# --- SEE-1273 T3: godot-mcp launch 双落点解析库（优先 submodule、兜底旧路径）---
# shellcheck source=scripts/godot-mcp-launch-path.lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/godot-mcp-launch-path.lib.sh" 2>/dev/null || true

# --- SEE-1273 T3 / K5 / SEE-1292 ②c: source KOL 专属值（唯一落点 .dev/env/kol-mcp.env）---
# 该文件 export GODOT_MCP_SHARED_MASTER / GODOT_MCP_REPO_DIRNAME（规范名，
# ②c 起 KOL_* 旧名不再由本 hook 注入）与 GODOT_MCP_HOME="$HOME/.multica"
# （现网状态目录连续注入，AC-DECPL-009 前置）。文件缺失不阻塞（非 agent
# 会话无需这些值）；下方兜底保证文件缺失时 daemon 链仍指旧状态路径。
_KOL_ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../env/kol-mcp.env"
[ -f "$_KOL_ENV_FILE" ] && . "$_KOL_ENV_FILE"
unset _KOL_ENV_FILE
# 现网连续兜底：无论 env 文件是否在，daemon 链的状态目录一律指 $HOME/.multica。
# env.sh 只在变量为空时才取默认，此显式注入优先级不受别名链影响。
export GODOT_MCP_HOME="${GODOT_MCP_HOME:-$HOME/.multica}"

# --- Entry point: check integrity first ---
if check_integrity "$REPO_DIR"; then
    try_shared_branch_reset "$REPO_DIR" || try_auto_create_shared_branch "$REPO_DIR" || true
    # SEE-1242 B-2 P3: doctor 注册层断言 + 工具清单被动记录（观测，软失败）。
    # 限时包裹：SessionStart 永不被观测工具阻塞（与 GIT_FETCH_TIMEOUT 同纪律）。
    # SEE-1273 T3: 双落点解析（优先 submodule、兜底旧路径）
    ASSERT_REG="$(mcp_launch_script mcp-assert-registration.sh "$REPO_DIR" || true)"
    if [ -n "$ASSERT_REG" ] && [ -x "$ASSERT_REG" ]; then
        PROJECT_ROOT="$(cd .. && pwd)" timeout 10 \
            bash "$ASSERT_REG" >/dev/null 2>&1 || true
    fi
    _mtp="$(cd "$(dirname "$0")" && pwd)/mcp-tool-presence.sh"
    [ -f "$_mtp" ] || _mtp="$REPO_DIR/.claude/hooks/scripts/mcp-tool-presence.sh"
    if [ -f "$_mtp" ]; then
        PROJECT_ROOT="$(cd .. && pwd)" timeout 10 \
            bash "$_mtp" >/dev/null 2>&1 || true
    fi
    output_fallback_hint "$REPO_DIR" ""
    exit 0
fi

# SEE-913: block nested worktree creation when cwd is already inside a git repo.
refuse_if_inside_git_repo

# --- Step 1: Attempt checkout ---
CHECKOUT_HAPPENED=false
CHECKOUT_FAILED=false
CHECKOUT_DIAG=""

if [ -f "$RESOURCES_FILE" ]; then
    PYTHON_CMD="$(command -v python3 2>/dev/null || command -v python 2>/dev/null)"
    if [ -n "$PYTHON_CMD" ]; then
        while read -r repo_url; do
            if [ -n "$repo_url" ]; then
                REPO_DIR=$(basename "$repo_url" .git)
                checkout_repo "$repo_url" "$REPO_DIR"
                CHECKOUT_HAPPENED=true
            fi
        done < <(get_repo_urls "$RESOURCES_FILE")
    else
        output_hint "无法解析 resources.json，将使用默认仓库配置。"
    fi
fi

# Fallback: hardcoded repo URL when resources.json is not available
if [ "$CHECKOUT_HAPPENED" = false ]; then
    REPO_DIR="$REPO_NAME"
    if [ ! -d "$REPO_NAME" ]; then
        checkout_repo "$FALLBACK_URL" "$REPO_NAME"
    fi
    CHECKOUT_HAPPENED=true
fi

# --- Step 2: Integrity check after checkout ---
if check_integrity "$REPO_DIR"; then
    try_shared_branch_reset "$REPO_DIR" || try_auto_create_shared_branch "$REPO_DIR" || true
    checkout_note2=""
    [ "$CHECKOUT_FAILED" = true ] && checkout_note2="（checkout 过程中曾出现错误，建议检查网络或权限）"
    [ -n "$CHECKOUT_DIAG" ] && checkout_note2="${checkout_note2}${CHECKOUT_DIAG}"
    output_fallback_hint "$REPO_DIR" "$checkout_note2"
    exit 0
fi

# --- Step 3: Retry once — clean and re-checkout ---
rm -rf "$REPO_DIR"

if [ -f "$RESOURCES_FILE" ]; then
    PYTHON_CMD="$(command -v python3 2>/dev/null || command -v python 2>/dev/null)"
    if [ -n "$PYTHON_CMD" ]; then
        while read -r repo_url; do
            if [ -n "$repo_url" ]; then
                REPO_DIR=$(basename "$repo_url" .git)
                checkout_repo "$repo_url" "$REPO_DIR"
            fi
        done < <(get_repo_urls "$RESOURCES_FILE")
    else
        output_hint "无法解析 resources.json，将使用默认仓库配置。"
    fi
else
    REPO_DIR="$REPO_NAME"
    checkout_repo "$FALLBACK_URL" "$REPO_NAME"
fi

# --- Step 4: Final check after retry ---
if check_integrity "$REPO_DIR"; then
    try_shared_branch_reset "$REPO_DIR" || try_auto_create_shared_branch "$REPO_DIR" || true
    checkout_note4=""
    [ "$CHECKOUT_FAILED" = true ] && checkout_note4="（checkout 过程中曾出现错误，建议检查网络或权限）"
    [ -n "$CHECKOUT_DIAG" ] && checkout_note4="${checkout_note4}${CHECKOUT_DIAG}"
    output_fallback_hint "$REPO_DIR" "$checkout_note4"
else
    rm -rf "$REPO_DIR"
    final_msg="Repo 自动检出失败，请手动 checkout 并在其中工作。严禁直接修改本地 main repo，除非有 owner 命令。"
    [ -n "$CHECKOUT_DIAG" ] && final_msg="${final_msg}${CHECKOUT_DIAG}"
    output_hint "$final_msg"
fi

exit 0
