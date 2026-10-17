#!/bin/bash
set -eo pipefail

# SEE-1268 (2-library split): capture the session's ACTUAL working repo BEFORE
# the `cd "$PROJECT_ROOT"` below. The stop hook may fire in a companion library
# (godot-qa-toolkit / godot-mcp fork / an addons submodule); once we cd into the
# KOL worktree, `git rev-parse --show-toplevel` re-resolves to KOL and the
# companion skip never triggers. Recording it now preserves the hook's original
# cwd so the skip is based on where the session actually was.
ORIG_CWD="$PWD"

if [ -n "${PROJECT_ROOT:-}" ] && [ -e "$PROJECT_ROOT/.git" ]; then
  cd "$PROJECT_ROOT"
fi

# Stop hook: auto-create draft PR when Claude Code session ends
# Handles 3 scenarios:
#   1. Uncommitted changes → auto commit + push + PR
#   2. Committed but unpushed → auto push + PR
#   3. Pushed but no PR → auto PR
# See: SEE-465

# 1. Anti-loop: read stdin JSON, check stop_hook_active
INPUT=$(cat)

IS_ACTIVE=$(printf '%s' "$INPUT" | node -e "
  let d = '';
  process.stdin.on('data', c => d += c);
  process.stdin.on('end', () => {
    try {
      const i = JSON.parse(d);
      process.stdout.write(i.stop_hook_active === true ? 'true' : 'false');
    } catch(e) { process.stdout.write('false'); }
  });
" 2>/dev/null || echo "false")

[ "$IS_ACTIVE" = "true" ] && exit 0

# 2. Git repo detection
git rev-parse --git-dir > /dev/null 2>&1 || exit 0

# --- SEE-1268 (2-library split): only auto-PR the KOL host worktree. ---
# The stop hook's auto-commit/push/draft-PR flow is KOL's multi-agent workflow.
# Companion standalone repos (godot-qa-toolkit, the godot-mcp fork, addons
# submodules) carry their own dev flows (fork PR / standalone master) and must
# NOT be auto-committed/pushed/PR'd here — silently skip. The session's repo is
# ORIG_CWD (captured before the `cd "$PROJECT_ROOT"` above); a launch in a
# companion repo makes ORIG_CWD /= PROJECT_ROOT, so the auto-commit PR flow is
# a no-op.
GIT_COMMAND_ROOT="$(cd "$ORIG_CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [ -n "$PROJECT_ROOT" ] && [ -n "$GIT_COMMAND_ROOT" ] && [ "$GIT_COMMAND_ROOT" != "$PROJECT_ROOT" ]; then
  exit 0
fi

# --- SEE-1273 T5-F: godot-mcp launch 单落点解析库（submodule addons/godot_mcp/launch）---
# shellcheck source=scripts/godot-mcp-launch-path.lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/godot-mcp-launch-path.lib.sh" 2>/dev/null || true

# --- SEE-1117 Direction 3: stop-hook lease-end backstop ---
# Release the per-worktree MCP lease sidecar (.godot/mcp-lease.json →
# state=released) on EVERY stop, INCLUDING the master checkout — a crashed
# agent would otherwise leave the lease active. Delegates to
# restore-godot-original.sh so the stop hook and the launch toolchain share
# one source of truth on what "released" means. Idempotent no-op when the
# sidecar is already released or absent. No `git add` — the sidecar is
# gitignored, so it can never be committed. Runs BEFORE the master/main branch
# filter below; the auto-commit/push/PR flow still skips master.
sanitize_lease_sidecar() {
    # SEE-1273 T5-F: launch 工具单落点解析（submodule addons/godot_mcp/launch）
    local restore_sh
    restore_sh="$(mcp_launch_script restore-godot-original.sh "${PROJECT_ROOT:-$(pwd)}")" || return 0
    [ -f project.godot ] || return 0   # restore anchors the worktree via project.godot
    KOL_PROJECT_GODOT="$PWD/project.godot" "$restore_sh" --project-godot "$PWD/project.godot" >/dev/null 2>&1 || true
}
sanitize_lease_sidecar

# --- SEE-1240 WS-8 / QA D2: stop-hook project.godot [godot_mcp] sanitize ---
# A manual MCP status-panel save persists per-agent runtime noise
# (port_override_enabled / port_override) into project.godot's [godot_mcp]
# section; the auto-commit below would otherwise capture it into the shared
# branch (the SEE-976/SEE-1062 pollution class). The runtime keys are DELETED
# outright (QA D2: zeroing them to false/6550 still wrote two noise lines into
# git via 2fa37e9b — the clean tracked state carries only the static machine
# bind lines). The static machine-level bind lines (bind_mode /
# custom_bind_ip) are LEGITIMATE tracked content (WS-8) and pass through
# untouched; the sed is anchored to the [godot_mcp] section only, so legit
# [autoload]/[input] edits survive byte-for-byte (SEE-1070 A.T4 contract).
# Idempotent + non-fatal.
sanitize_project_godot_mcp() {
    [ -f project.godot ] || return 0
    if grep -qE '^[[:space:]]*\[godot_mcp\][[:space:]]*$' project.godot 2>/dev/null; then
        sed -i '/^\[godot_mcp\]/,/^\[/ { /^\(port_override_enabled\|port_override\)=/d; }' project.godot 2>/dev/null || true
        git add project.godot 2>/dev/null || true
    fi
}
sanitize_project_godot_mcp

# SEE-1129 Owner principle #3 — "没有人使用的 editor 主动退出": on task/session
# exit, also STOP the Godot editor process this agent started (not just release
# the lease sidecar). Without this the orphaned editor + its proxy linger
# indefinitely (observed: 5+ orphan godot-mcp-proxy.mjs processes piling up).
# Delegates to stop-godot-editor.sh which resolves the editor PID + kills it +
# releases the lease + cleans the pid/worktree sidecars. Idempotent + non-fatal:
# a no-op when nothing is running. Runs on every branch (the master filter
# below governs only the auto-commit/push/PR flow).
stop_editor_on_exit() {
    # SEE-1273 T5-F: 单落点解析（submodule addons/godot_mcp/launch）
    local stop_sh
    stop_sh="$(mcp_launch_script stop-godot-editor.sh "${PROJECT_ROOT:-$(pwd)}")" || return 0
    # KOL_AGENT_NAME / KOL_MCP_PORT may be inherited from the session env; the
    # script also falls back to label resolution. Failures never block the stop
    # hook (the editor lease self-exit is the addon's own backstop).
    "$stop_sh" >/dev/null 2>&1 || true
}
stop_editor_on_exit

# SEE-1185 F3: surface swallowed git add/commit failures so "silent no-op"
# downstream (empty NEW_COMMITS → no push/PR) is distinguishable from real success
auto_pr_fail() {
  echo "[auto-pr] commit failed: $1" >&2
  # firelog 落点走单源 lib（SEE-1388 §SPEC-018，QA O1 残余收敛）；lib 缺失时降级
  # $HOME 全局兜底（fail-open：firelog 写失败绝不影响主流程）。
  local _log
  if declare -F resolve_hook_fire_log_path >/dev/null 2>&1; then
    _log=$(resolve_hook_fire_log_path 2>/dev/null) || _log=""
  else
    _lib_dir="$(cd "$(dirname "$0")" && pwd)"
    for _cand in "$_lib_dir/lib/hook-fire-path.lib.sh"; do
      [ -f "$_cand" ] && . "$_cand" && break
    done
    if declare -F resolve_hook_fire_log_path >/dev/null 2>&1; then
      _log=$(resolve_hook_fire_log_path 2>/dev/null) || _log=""
    else
      _log=""
    fi
  fi
  [ -n "$_log" ] || _log="$HOME/.claude/hook-fire.log"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [auto-pr] commit failed: $1" >> "$_log" 2>/dev/null || true
}

# 3. Branch filter - skip master/main (auto-commit/push/PR flow only; the
# sanitize above already ran unconditionally on every branch, master included)
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
[ "$CURRENT_BRANCH" = "master" ] || [ "$CURRENT_BRANCH" = "main" ] && exit 0
[ -z "$CURRENT_BRANCH" ] && exit 0

if [[ "$CURRENT_BRANCH" == revy/test-* ]]; then
  echo "[Hook] Skipping Revy test branch: ${CURRENT_BRANCH}"
  exit 0
fi

# 4. gh auth - ensure GH_TOKEN is set from GITHUB_PERSONAL_ACCESS_TOKEN
export GH_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:-}"

# 5. Detect default branch
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "master")
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="master"

# 6. Fetch latest remote state (throttled: once per 5 minutes)
FETCH_MARKER="${TEMP:-/tmp}/.cc-auto-pr-fetch-$(pwd | tr '/\\ ' '_')"
FETCH_INTERVAL=300
if [ ! -f "$FETCH_MARKER" ] || [ "$(($(date +%s) - $(cat "$FETCH_MARKER" 2>/dev/null || echo 0)))" -ge "$FETCH_INTERVAL" ]; then
  git fetch origin >/dev/null 2>&1 || true
  date +%s > "$FETCH_MARKER"
fi

# --- Resolve shared branch from issue metadata ---
ISSUE_ID=""
WORKING_BRANCH=""
if [ -n "${MULTICA_TASK_ID:-}" ]; then
  ISSUE_ID=$(multica issue run-messages "$MULTICA_TASK_ID" --output json 2>/dev/null | node -e "
    let d=''; process.stdin.on('data', c => d += c);
    process.stdin.on('end', () => {
      try {
        const msgs = JSON.parse(d);
        if (msgs.length > 0 && msgs[0].issue_id) {
          process.stdout.write(msgs[0].issue_id);
        }
      } catch(e) { process.stderr.write('[auto-pr] WARN issue-id parse failed (run-messages JSON): ' + e.message + ' -> issue_id 留空\n'); }
    });
  " || true)
  # SEE-1388 §SPEC-007 补丁棒次：node 侧 2>/dev/null 摘除——catch 内 stderr WARN 须真实可达；
  # multica CLI 侧 stderr 仍由管道左段的 2>/dev/null 独立吞掉，行为面其余不变（Harti 提案/Atlas 裁决）

  if [ -n "$ISSUE_ID" ]; then
    WORKING_BRANCH=$(multica issue metadata list "$ISSUE_ID" --output json 2>/dev/null | node -e "
      let d=''; process.stdin.on('data', c => d += c);
      process.stdin.on('end', () => {
        try {
          const meta = JSON.parse(d);
          if (meta.working_branch) {
            process.stdout.write(meta.working_branch);
          }
        } catch(e) { process.stderr.write('[auto-pr] WARN working-branch parse failed (metadata JSON): ' + e.message + ' -> working_branch 留空\n'); }
      });
    " || true)
  fi
fi

# --- Scenario 1: Uncommitted changes → auto commit ---
DIRTY=$(git status --porcelain 2>/dev/null || true)
if [ -n "$DIRTY" ]; then
  # Extract issue reference from branch name (e.g. feature/SEE-123-desc)
  ISSUE_REF=$(echo "$CURRENT_BRANCH" | grep -oE '[A-Z]+-[0-9]+' | head -1 || true)
  if [ -n "$ISSUE_REF" ]; then
    COMMIT_MSG="chore: auto-commit for ${ISSUE_REF}"
  else
    COMMIT_MSG="chore: auto-commit on stop hook (${CURRENT_BRANCH})"
  fi

  # SEE-1268 §7.4(d) gitlink 条件保留：不再无差别剥离——逐 gitlink 判定
  # （共享探测函数，与 push-guard Check 8 同实现）。
  #
  # 两阶段（code-review CRITICAL-1）：判定必须在 `git add -A` **之前**（uninit
  # 的 gitlink 在 add -A 后会被 index 抹掉，届时已无法观测），但 unstage 必须
  # 在 add -A **之后**——add -A 会把工作区的 gitlink 变更重新暂存，之前的
  # reset 是 no-op（剥离从未生效）。故：判定阶段只收集待剥离列表，add -A 之后
  # 统一 reset。
  #
  # 判定对象是「add -A 将要暂存的工作区 gitlink」（子库 HEAD），而非 index 里
  # 可能已过期（尚未 add）的旧值——否则待提交的 dangling 指针会被读成旧的健康
  # 值而漏判（同批 code-review 发现的第二处偏差）。
  #
  # 5 级判定（按序短路）：
  #   工作区与 index 一致（无变更）→ 跳过（零探测）
  #   uninit（'-' 工作区无 .git）→ 剥离 + 告警「子库未初始化」
  #   no-url（无法解析 origin URL）→ 剥离 + 告警「无法判定，保守剥离」
  #   dangling → 剥离 + 告警点名子库+SHA
  #   healthy → 保留（随 auto-commit 提交）
  # 无 .gitmodules 或 index 无 gitlink → 整段零开销跳过（现状性能特征）。
  GITLINK_STRIP=()
  if [ -f .gitmodules ] && git ls-files --stage 2>/dev/null | grep -q '^160000'; then
    GITLINK_PROBE_TIMEOUT=20
    # shellcheck source=scripts/lib/gitlink-probe.sh
    _probe="$(cd "$(dirname "$0")" && pwd)/lib/gitlink-probe.sh"
    [ -f "$_probe" ] || _probe="$PWD/.claude/hooks/scripts/lib/gitlink-probe.sh"
    [ -f "$_probe" ] && . "$_probe"
    set +eo pipefail
    while IFS=$'\t' read -r idx_sha path_rel; do
      [ -n "$path_rel" ] || continue
      if [ -e "$PWD/$path_rel/.git" ]; then
        wt_sha=$(git -C "$PWD/$path_rel" rev-parse HEAD 2>/dev/null) || wt_sha="$idx_sha"
        # 无变更：工作区 gitlink 与 index 记录一致 → 无需处理，零探测。
        [ "$wt_sha" = "$idx_sha" ] && continue
      else
        wt_sha="$idx_sha"
      fi
      VERDICT=$(qa_gitlink_classify "$PWD" "$path_rel" "$wt_sha" "$GITLINK_PROBE_TIMEOUT")
      case "$VERDICT" in
        healthy)
          : ;;  # 合法指针推进——保留（随 auto-commit 提交）
        uninit)
          GITLINK_STRIP+=("$path_rel")
          echo "[auto-pr] gitlink 剥离：子库未初始化（materialize 流程管辖），指针变更不落 commit：${path_rel}" >&2
          ;;
        dangling)
          GITLINK_STRIP+=("$path_rel")
          echo "[auto-pr] gitlink 剥离：dangling gitlink——子库 commit ${wt_sha} 未推 remote，已剥离；先补推子库再重新挪指针：${path_rel}" >&2
          ;;
        no-url|probe-fail)
          GITLINK_STRIP+=("$path_rel")
          echo "[auto-pr] gitlink 剥离：无法判定指针健康度（${VERDICT}），保守剥离不阻塞 stop hook：${path_rel}" >&2
          ;;
      esac
    done < <(git ls-files --stage 2>/dev/null | awk '/^160000/{print $2"\t"$4}')
    set -eo pipefail
  fi

  git add -A 2>/dev/null || auto_pr_fail "git add -A: $?"
  # 后置剥离（必须在 add -A 之后——见上）：把待剥离 gitlink 从暂存区移除。
  if [ "${#GITLINK_STRIP[@]}" -gt 0 ]; then
    for _gl_path in "${GITLINK_STRIP[@]}"; do
      git reset HEAD -- "$_gl_path" 2>/dev/null || true
    done
  fi
  # Unstage godot-mcp E2E screenshots at any nesting depth (SEE-905).
  # The test harness writes to a relative screenshots/see903/ path; when invoked
  # from a nested cwd the directory triple-nests. The e2e .gitignore twin this
  # used to pair with lived under .dev/godot-mcp/tests/ (removed in T5-F); the
  # e2e harness itself migrated to the fork (launch/tests/e2e/godot-mcp/).
  git diff --cached --name-only 2>/dev/null | grep -E 'screenshots/see903/' | while read -r path; do
    git reset HEAD -- "$path" 2>/dev/null || true
  done
  # SEE-1242 A-1/A-5: unstage known runtime-noise files. The pollution class is
  # "old-worktree leftovers × auto-commit git add -A" (override.cfg relapsed
  # twice: 94dd2651/e8b86632; ledger 2036f5bc ruled a staging-side exclusion
  # list + .gitignore line). A-5（扫描域收敛）: the unstage list is kept in
  # 1:1 symmetry with the repo-root .gitignore noise rules (.corrupt-* added
  # in A-5) so the exclusion domain and the ignore domain can no longer drift
  # apart — files already tracked before a rule existed are unstaged here,
  # files newly created are never dirty in the first place. The list matches
  # repo-root paths only (leading slash), so same-named tracked files
  # elsewhere cannot be suppressed.
  git diff --cached --name-only 2>/dev/null | grep -E '^(override\.cfg|\.corrupt-)' | while read -r path; do
    git reset HEAD -- "$path" 2>/dev/null || true
  done
  set -eo pipefail
  # Verify staging area has changes before committing
  STAGED=$(git diff --cached --name-status 2>/dev/null || true)
  if [ -n "$STAGED" ]; then
    git commit -m "$COMMIT_MSG" >/dev/null 2>&1 || auto_pr_fail "git commit: $?"
  fi
fi

# Check if there are any commits ahead of the default branch. SEE-954 D1 fix: the
# range base here MUST be DEFAULT_BRANCH (master), not WORKING_BRANCH. The PR base
# is master (see `gh pr create --base` below), so the PR commit range is master..HEAD.
# Using WORKING_BRANCH made this range empty after every push (origin/<wb> advances
# to HEAD), so the hook exited here and never created a PR.
NEW_COMMITS=$(git log "origin/${DEFAULT_BRANCH}..HEAD" --oneline 2>/dev/null || true)
[ -z "$NEW_COMMITS" ] && exit 0

# --- Scenario 2: Unpushed commits → auto push ---
NEEDS_PUSH=false
if ! git rev-parse --verify "origin/${CURRENT_BRANCH}" >/dev/null 2>&1; then
  # Remote branch doesn't exist yet
  NEEDS_PUSH=true
else
  TRACKING_BRANCH="${WORKING_BRANCH:-$CURRENT_BRANCH}"
  UNPUSHED=$(git log "origin/${TRACKING_BRANCH}..HEAD" --oneline 2>/dev/null || true)
  [ -n "$UNPUSHED" ] && NEEDS_PUSH=true
fi

if [ "$NEEDS_PUSH" = "true" ]; then
  # NO_REFSPEC guard: when running in a Multica worktree on an agent/<X>/<Y> branch
  # with no working_branch metadata, do NOT push the agent branch to origin.
  # This is the documented failure mode in .dev/docs/multica/shared-branch-coordination-plan.md.
  if [ -z "$WORKING_BRANCH" ] && [[ "$CURRENT_BRANCH" == agent/*/* ]]; then
    echo "[auto-pr-on-stop] 跳过 push：当前 worktree 分支 ${CURRENT_BRANCH} 没有对应的 working_branch 目标。" >&2
    echo "[auto-pr-on-stop] 这是 Multica 平台 issue 触发的普通 session，不应推送 agent/<X>/<Y> 到 origin。" >&2
    exit 0
  fi

  PUSH_TARGET="$CURRENT_BRANCH"
  if [ -n "$WORKING_BRANCH" ]; then
    PUSH_TARGET="HEAD:refs/heads/${WORKING_BRANCH}"
  fi

  # SEE-1117 Direction 3: the lease sidecar is gitignored (.godot/ line 1) so
  # it can never ride along on this push, and project.godot no longer carries
  # lease state. The worktree's sidecar was already released at the top of this
  # hook (sanitize_lease_sidecar); push-guard.sh Check A will hard-block on the
  # vanishingly-rare case where a sidecar somehow leaked into the HEAD tree. No
  # pre-push tip verification is needed here.

  set +e
  git push origin "$PUSH_TARGET" >/dev/null 2>&1
  PUSH_EXIT=$?
  set -e

  if [ $PUSH_EXIT -ne 0 ] && [ -n "$WORKING_BRANCH" ]; then
    # Retry with rebase for shared branch
    set +e
    git fetch origin >/dev/null 2>&1
    if git rebase "origin/${WORKING_BRANCH}" >/dev/null 2>&1; then
      git push origin "$PUSH_TARGET" >/dev/null 2>&1
      PUSH_EXIT=$?
    else
      git rebase --abort >/dev/null 2>&1 || true
      PUSH_EXIT=1
    fi
    set -e
  fi

  if [ $PUSH_EXIT -ne 0 ]; then
    echo "[Hook] Failed to push branch ${PUSH_TARGET}" >&2
    exit 0
  fi
fi

# --- Cherry-pick detection: skip PR if all commits exist in open PRs ---
set +e

OPEN_PR_BRANCHES=$(gh pr list --state open --json headRefName -q '.[].headRefName' 2>/dev/null | grep -vFx "$CURRENT_BRANCH" || true)
if [ -n "$WORKING_BRANCH" ]; then
  OPEN_PR_BRANCHES=$(echo "$OPEN_PR_BRANCHES" | grep -vFx "$WORKING_BRANCH" || true)
fi
SKIP_PR=false

if [ -n "$OPEN_PR_BRANCHES" ]; then
  CURRENT_COMMITS=$(git log "origin/${DEFAULT_BRANCH}..HEAD" --format="%H" 2>/dev/null || true)

  if [ -n "$CURRENT_COMMITS" ]; then
    ALL_FOUND=true
    TOTAL_COMMITS=0

    while IFS= read -r COMMIT; do
      [ -z "$COMMIT" ] && continue
      TOTAL_COMMITS=$((TOTAL_COMMITS + 1))
      COMMIT_FOUND=false

      while IFS= read -r PR_BRANCH; do
        [ -z "$PR_BRANCH" ] && continue

        # Method 1: same hash check (is-ancestor)
        if git merge-base --is-ancestor "$COMMIT" "origin/${PR_BRANCH}" >/dev/null 2>&1; then
          COMMIT_FOUND=true
          break
        fi

        # Method 2: patch-id fallback for true cherry-picks
        CURRENT_PATCH_ID=$(git show "$COMMIT" | git patch-id --stable 2>/dev/null | awk '{print $1}')
        if [ -n "$CURRENT_PATCH_ID" ]; then
          PR_COMMITS=$(git log "origin/${DEFAULT_BRANCH}..origin/${PR_BRANCH}" --format="%H" 2>/dev/null || true)
          while IFS= read -r PR_COMMIT; do
            [ -z "$PR_COMMIT" ] && continue
            PR_PATCH_ID=$(git show "$PR_COMMIT" | git patch-id --stable 2>/dev/null | awk '{print $1}')
            if [ "$CURRENT_PATCH_ID" = "$PR_PATCH_ID" ] && [ -n "$PR_PATCH_ID" ]; then
              COMMIT_FOUND=true
              break 2
            fi
          done <<< "$PR_COMMITS"
        fi
      done <<< "$OPEN_PR_BRANCHES"

      if [ "$COMMIT_FOUND" != "true" ]; then
        ALL_FOUND=false
        break
      fi
    done <<< "$CURRENT_COMMITS"

    if [ "$ALL_FOUND" = "true" ] && [ "$TOTAL_COMMITS" -gt 0 ]; then
      FIRST_PR_BRANCH=$(echo "$OPEN_PR_BRANCHES" | head -1)
      echo "[Hook] Skipping PR creation: all commits already present in existing PR(s) (branch: ${FIRST_PR_BRANCH})" >&2
      SKIP_PR=true
    fi
  fi
fi

set -e

[ "$SKIP_PR" = "true" ] && exit 0

# --- Scenario 3: Pushed but no PR → create PR ---
PR_HEAD="$CURRENT_BRANCH"
if [ -n "$WORKING_BRANCH" ]; then
  PR_HEAD="$WORKING_BRANCH"
fi

# Check for existing open PR on the head branch
EXISTING_PR=$(gh pr list --head "$PR_HEAD" --state open --json number -q '.[0].number' 2>/dev/null || echo "")
if [ -n "$EXISTING_PR" ]; then
  echo "[Hook] Pushed to existing PR #${EXISTING_PR} on branch ${PR_HEAD}" >&2
  exit 0
fi

# Also check closed/merged PRs to avoid recreating
EXISTING_PR_ALL=$(gh pr list --head "$PR_HEAD" --state all --json number -q '.[0].number' 2>/dev/null || echo "")
[ -n "$EXISTING_PR_ALL" ] && exit 0

# PR title - first commit message (range base = DEFAULT_BRANCH, matches PR base; SEE-954 D1)
TITLE=$(git log "origin/${DEFAULT_BRANCH}..HEAD" --reverse --format="%s" | head -1)

# PR description - compute commit list BEFORE heredoc (fix: heredoc bug)
COMMIT_LIST=$(git log "origin/${DEFAULT_BRANCH}..HEAD" --reverse --format="- %s")

BODY=$(cat <<EOF
## Summary

Auto-created draft PR from agent session on branch \`${PR_HEAD}\`.

### Commits
${COMMIT_LIST}
EOF
)

# Create Draft PR (stderr discarded; error handled by exit code)
set +e
PR_URL=$(gh pr create --head "$PR_HEAD" --base "$DEFAULT_BRANCH" --title "$TITLE" --body "$BODY" --draft 2>/dev/null)
PR_EXIT=$?
set -e

if [ $PR_EXIT -ne 0 ]; then
  echo "[Hook] Failed to create draft PR on branch ${PR_HEAD}" >&2
  exit 0
fi

echo "[Hook] Draft PR created: $PR_URL" >&2

# Write PR metadata to issue
if [ -n "$ISSUE_ID" ] && [ -n "$PR_URL" ]; then
  PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$' || true)
  multica issue metadata set "$ISSUE_ID" --key pr_url --value "$PR_URL" 2>/dev/null || true
  if [ -n "$PR_NUMBER" ]; then
    multica issue metadata set "$ISSUE_ID" --key pr_number --value "$PR_NUMBER" 2>/dev/null || true
  fi
fi

# Multica notification (resolve issue_id via run-messages, not temp file)
ISSUE_ID=""
if [ -n "${MULTICA_TASK_ID:-}" ]; then
  ISSUE_ID=$(multica issue run-messages "$MULTICA_TASK_ID" --output json 2>/dev/null | node -e "
    let d = '';
    process.stdin.on('data', c => d += c);
    process.stdin.on('end', () => {
      try {
        const msgs = JSON.parse(d);
        if (msgs.length > 0 && msgs[0].issue_id) {
          process.stdout.write(msgs[0].issue_id);
        }
      } catch(e) { process.stderr.write('[auto-pr] WARN notify issue-id parse failed (run-messages JSON): ' + e.message + ' -> issue_id 留空\n'); }
    });
  " 2>/dev/null || true)
fi

if [ -n "$ISSUE_ID" ]; then
  # Resolve --parent for agent-triggered runs
  PARENT_ARG=""
  if [ -n "${MULTICA_TASK_ID:-}" ]; then
    PARENT_ARG=$(multica issue runs "$ISSUE_ID" --output json 2>/dev/null | node -e "
      let d = '';
      process.stdin.on('data', c => d += c);
      process.stdin.on('end', () => {
        try {
          const runs = JSON.parse(d);
          const run = runs.find(r => r.id === process.env.MULTICA_TASK_ID);
          if (run && run.trigger_comment_id && run.trigger_comment_id !== 'undefined') {
            process.stdout.write('--parent ' + run.trigger_comment_id);
          }
        } catch(e) { process.stderr.write('[auto-pr] WARN trigger-comment parse failed (runs JSON): ' + e.message + ' -> --parent 留空\n'); }
      });
    " || true)
  fi

  # Extract PR metadata
  PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$' || true)
  COMMIT_COUNT=$(git log "origin/${DEFAULT_BRANCH}..HEAD" --oneline 2>/dev/null | wc -l | tr -d ' ')

  # Build PR notification text
  PR_INFO="Draft PR created: ${PR_URL}

**PR Metadata:**
- **PR:** #${PR_NUMBER}
- **Title:** ${TITLE}
- **Branch:** \`${PR_HEAD}\` → \`${DEFAULT_BRANCH}\`
- **Commits:** ${COMMIT_COUNT}

### Commits
${COMMIT_LIST}"

  # Try to edit existing comment (append PR info) instead of creating new one
  EDITED=false
  if [ -n "${MULTICA_AGENT_ID:-}" ] && [ -n "${MULTICA_TOKEN:-}" ] && [ -n "${MULTICA_SERVER_URL:-}" ]; then
    COMMENT_JSON=$(multica issue comment list "$ISSUE_ID" --output json 2>/dev/null | node -e "
      let d = '';
      process.stdin.on('data', c => d += c);
      process.stdin.on('end', () => {
        try {
          const comments = JSON.parse(d);
          const myComments = comments
            .filter(c => c.author_id === process.env.MULTICA_AGENT_ID)
            .sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
          if (myComments.length > 0) {
            const latest = myComments[0];
            process.stdout.write(JSON.stringify({id: latest.id, content: latest.content || ''}));
          }
        } catch(e) { process.stderr.write('[auto-pr] WARN latest-comment parse failed (comments JSON): ' + e.message + ' -> COMMENT_JSON 留空\n'); }
      });
    " 2>/dev/null || true)

    if [ -n "$COMMENT_JSON" ]; then
      # Merge existing content + PR info, then PUT via API
      PUT_BODY=$(PR_INFO="$PR_INFO" node -e "
        let d = '';
        process.stdin.on('data', c => d += c);
        process.stdin.on('end', () => {
          try {
            const obj = JSON.parse(d);
            const merged = obj.content + '\n\n---\n\n' + process.env.PR_INFO;
            process.stdout.write(JSON.stringify({content: merged}));
          } catch(e) { process.stderr.write('[auto-pr] WARN comment-merge parse failed (COMMENT_JSON): ' + e.message + ' -> PUT_BODY 留空\n'); }
        });
      " <<< "$COMMENT_JSON" 2>/dev/null || true)

      if [ -n "$PUT_BODY" ]; then
        COMMENT_ID=$(printf '%s' "$COMMENT_JSON" | node -e "
          let d = '';
          process.stdin.on('data', c => d += c);
          process.stdin.on('end', () => { try { process.stdout.write(JSON.parse(d).id); } catch(e) { process.stderr.write('[auto-pr] WARN comment-id parse failed (COMMENT_JSON): ' + e.message + ' -> COMMENT_ID 留空\n'); } });
        " 2>/dev/null || true)

        if [ -n "$COMMENT_ID" ]; then
          HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
            "${MULTICA_SERVER_URL}/api/comments/${COMMENT_ID}?workspace_id=${MULTICA_WORKSPACE_ID}" \
            -H "Authorization: Bearer ${MULTICA_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$PUT_BODY" 2>/dev/null || echo "000")

          if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ] 2>/dev/null; then
            echo "[Hook] Appended PR info to existing comment ${COMMENT_ID}" >&2
            EDITED=true
          else
            echo "[Hook] Comment edit failed (HTTP ${HTTP_CODE}), falling back to new comment" >&2
          fi
        fi
      fi
    fi
  fi

  # Fallback: create new comment if edit was not possible or failed
  if [ "$EDITED" = "false" ]; then
    # shellcheck disable=SC2086  # PARENT_ARG is either empty or "--parent <id>"; word-splitting is intended
    cat <<COMMENT | multica issue comment add "$ISSUE_ID" $PARENT_ARG --content-stdin 2>/dev/null || echo "[Hook] Failed to send notification" >&2
${PR_INFO}

<!-- Auto-mention disabled
[@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5) please review.
-->
COMMENT
  fi
fi
