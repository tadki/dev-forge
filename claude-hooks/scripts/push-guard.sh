#!/bin/bash
set -e

# PreToolUse hook: guards git push commands
# Trigger: Bash(git push*)
# - Checks current branch contains latest origin/master
# - Checks master/main push permission (MULTICA_AGENT_NAME)
# - Success: pass stdin through (echo INPUT)
# - Failure: exit 2 + stderr message

INPUT=$(cat)

# --- Phase 1: Parse command (no git repo required) ---
# Parse tool_input.command from stdin JSON and detect push target
# Uses node for robust command parsing (same pattern as doc-reminder.sh)
# Also extracts git repo path from -C <path> or cd <path> && patterns
PHASE1_OUTPUT=$(printf '%s' "$INPUT" | node -e "
  let d = '';
  process.stdin.on('data', c => d += c);
  process.stdin.on('end', () => {
    try {
      const i = JSON.parse(d);
      let cmd = (i.tool_input?.command || '').trim();

      // Strip heredoc content before tokenizing to prevent false positives
      // from content words like git+push inside the heredoc body
      cmd = cmd.replace(/(?:^|\s)<<-?\s*\S+[\s\S]*$/, '').trim();

      // Tokenize command (preserve quoted strings as single tokens)
      const tokens = cmd.match(/(?:[^\s\"']+|\"[^\"]*\"|'[^']*')+/g) || [];

      // Extract cd <path> && pattern (last cd before git wins)
      let cmdGitRoot = '';
      for (let ci = 0; ci < tokens.length - 2; ci++) {
        if (tokens[ci] === 'cd' && tokens[ci + 2] === '&&') {
          cmdGitRoot = tokens[ci + 1];
        }
      }

      // Find 'git' token, then find 'push' subcommand after skipping global flags
      let isPush = false;
      let pushTokenIndex = -1;
      for (let idx = 0; idx < tokens.length; idx++) {
        if (tokens[idx] === 'git') {
          let j = idx + 1;
          // Skip flag tokens (start with -) and their value tokens
          while (j < tokens.length) {
            const tok = tokens[j];
            if (tok.startsWith('-')) {
              // Single-dash flag with value (e.g., -C dir): skip flag + next token
              if (tok.length === 2 && tok !== '--') {
                if (tok === '-C' && j + 1 < tokens.length) {
                  cmdGitRoot = tokens[j + 1];
                }
                j += 2;
                continue;
              }
              // --flag=value or --flag: skip only the flag token
              j++;
              continue;
            }
            break;
          }
          if (j < tokens.length && tokens[j] === 'push') {
            isPush = true;
            pushTokenIndex = j;
            break;
          }
        }
      }

      if (!isPush) {
        if (cmdGitRoot) process.stdout.write('CMD_GIT_ROOT=' + cmdGitRoot + '\n');
        process.stdout.write('NOT_PUSH');
        return;
      }

      // Detect delete push (--delete / -d): no code involved, bypass all checks
      for (let i = pushTokenIndex + 1; i < tokens.length; i++) {
        if (tokens[i] === '--delete' || tokens[i] === '-d') {
          if (cmdGitRoot) process.stdout.write('CMD_GIT_ROOT=' + cmdGitRoot + '\n');
          process.stdout.write('DELETE_PUSH');
          return;
        }
      }

      // Extract tokens after 'push', skip push-local flags (starting with -) and '--'
      const afterPush = tokens.slice(pushTokenIndex + 1);

      // Detect force push (C3/SC5): scanned on RAW tokens so it wins over the
      // NO_REFSPEC early-return below. Agents must never force-push on a shared
      // branch; only the §B auto-rebase (repo-checkout, SessionStart) uses
      // --force-with-lease and it does not pass through push-guard.
      // SEE-954 LOW-1: also catch combined short clusters (-fn, -uf, -fo) and
      // --force=<v>. --no-force is an explicit opt-out and must NOT be blocked.
      let isForce = false;
      for (const t of afterPush) {
        if (t.startsWith('--')) {
          if (t === '--force' || t.startsWith('--force=') ||
              t === '--force-with-lease' || t.startsWith('--force-with-lease=')) {
            isForce = true; break;
          }
        } else if (t.startsWith('-') && t !== '-') {
          // Short option cluster: force if it contains 'f' (e.g. -f, -fn, -uf, -fo).
          if (t.indexOf('f') !== -1) { isForce = true; break; }
        }
      }
      if (isForce) {
        if (cmdGitRoot) process.stdout.write('CMD_GIT_ROOT=' + cmdGitRoot + '\n');
        process.stdout.write('FORCE_PUSH');
        return;
      }

      const pushArgs = [];
      for (const t of afterPush) {
        if (t === '--') continue;
        if (t.startsWith('-')) continue;
        pushArgs.push(t);
      }

      // If no tokens after filtering flags, no refspec was specified
      if (pushArgs.length === 0) {
        if (cmdGitRoot) process.stdout.write('CMD_GIT_ROOT=' + cmdGitRoot + '\n');
        process.stdout.write('NO_REFSPEC');
        return;
      }

      // Check if any token targets master/main
      let isMasterPush = false;
      for (const token of pushArgs) {
        if (token.includes(':')) {
          // Format: local:remote — check remote part
          const remote = token.split(':').pop();
          if (/\b(master|main)\b/.test(remote)) {
            isMasterPush = true;
            break;
          }
        } else if (/^(master|main)$/.test(token)) {
          isMasterPush = true;
          break;
        }
      }

      if (cmdGitRoot) process.stdout.write('CMD_GIT_ROOT=' + cmdGitRoot + '\n');
      process.stdout.write(isMasterPush ? 'MASTER_PUSH' : 'SAFE_PUSH');
    } catch(e) {
      process.stdout.write('NOT_PUSH');
    }
  });
" 2>/dev/null)

CMD_GIT_ROOT=""
PUSH_RESULT="$PHASE1_OUTPUT"

if [[ "$PHASE1_OUTPUT" == CMD_GIT_ROOT=* ]]; then
  CMD_GIT_ROOT="${PHASE1_OUTPUT#CMD_GIT_ROOT=}"
  CMD_GIT_ROOT="${CMD_GIT_ROOT%%$'\n'*}"
  PUSH_RESULT="${PHASE1_OUTPUT##*$'\n'}"
fi

# Safety net: if Phase 1 produced an unexpected/empty result, default to NOT_PUSH
# to avoid blocking non-push commands when node/parser has issues
case "$PUSH_RESULT" in
  NOT_PUSH|DELETE_PUSH|FORCE_PUSH|NO_REFSPEC|MASTER_PUSH|SAFE_PUSH) ;;
  *) PUSH_RESULT="NOT_PUSH" ;;
esac

# If not a git push command, pass stdin through and exit
[ "$PUSH_RESULT" = "NOT_PUSH" ] && { echo "$INPUT"; exit 0; }

# Delete push: no code involved, bypass Phase 2 & 3
[ "$PUSH_RESULT" = "DELETE_PUSH" ] && { echo "$INPUT"; exit 0; }

# Force push (C3/SC5): blocked for agents by default. The §B auto-rebase in
# repo-checkout (SessionStart) uses --force-with-lease but does not pass through
# push-guard, so any agent-typed --force / --force-with-lease / -f is a mistake
# that would overwrite another agent's commits on the shared branch.
# SEE-1069: Atlas (Leader agent) is whitelisted by agent_id so it can force-push
# to reconcile squash-merge divergence on a shared branch. Every whitelisted
# force-push is appended to an audit log for traceability. Non-force pushes are
# unaffected — this only short-circuits the force-push block below.
if [ "$PUSH_RESULT" = "FORCE_PUSH" ]; then
  ATLAS_AGENT_ID="fac3e3a1-dcda-498d-8613-e8c2811f3ef5"
  if [ "${MULTICA_AGENT_ID:-}" = "$ATLAS_AGENT_ID" ]; then
    AUDIT_LOG="${PROJECT_ROOT:-.}/.claude/push-guard-force-audit.log"
    FORCED_CMD=$(printf '%s' "$INPUT" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{process.stdout.write((JSON.parse(d).tool_input?.command||'').trim())}catch(e){}})" 2>/dev/null || true)
    # Best-effort audit: a logging failure (missing dir, read-only fs) must never
    # break the authorized push decision, hence mkdir -p + `|| true`.
    mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null || true
    { echo "$(date -Iseconds) agent=${MULTICA_AGENT_ID:-unknown} name=${MULTICA_AGENT_NAME:-unknown} cmd=${FORCED_CMD}"; } >> "$AUDIT_LOG" 2>/dev/null || true
    echo "[push-guard] Atlas whitelist: force-push allowed, audit logged to ${AUDIT_LOG}" >&2
    echo "$INPUT"; exit 0
  fi
  echo "[push-guard] 错误：禁止 force-push（--force / --force-with-lease / -f）" >&2
  echo "[push-guard] 多 agent 共享分支场景下 force-push 会覆盖他人 commit。" >&2
  echo "[push-guard] 请改用：git fetch origin && git rebase origin/<working_branch>，然后普通推送。" >&2
  exit 2
fi

# Git root resolution — shared by the Phase 2 master guard and Phase 3. Resolved
# once; later calls are no-ops. Returns 1 if no repo is reachable from the
# command path, PROJECT_ROOT, CWD, or direct subdirectories.
GIT_ROOT=""
# Resolve the git repo a push actually targets. SEE-1268 (2-library split): an
# agent now pushes standalone companion repos (godot-qa-toolkit, the godot-mcp
# fork, addons submodules) that live OUTSIDE the KingOfLikes worktree. Those
# repos carry their own development flow (fork PR, standalone master) and must
# NOT be guard-gated by KOL's master/shared policy. Resolution order: explicit
# -C/cd root (Phase 1) → the git repo the command runs IN (walk up from $PWD,
# where git's own --git-dir discovery wins over any PROJECT_ROOT default) → the
# host worktree. We deliberately probe the command's own git root BEFORE
# PROJECT_ROOT, so a push from a non-host repo is judged by that repo's actual
# state, not by the D-drive master that dispatcher's WSL fallback projects.
resolve_git_root() {
  [ -n "$GIT_ROOT" ] && return 0
  local cand
  # 1. Explicit -C/cd path from Phase 1 (git push -C <dir> or `cd <dir> && git push`).
  if [ -n "$CMD_GIT_ROOT" ] && git -C "$CMD_GIT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    GIT_ROOT="$CMD_GIT_ROOT"; return 0
  fi
  # 2. The repo the command physically runs in — `git rev-parse --show-toplevel`
  #    from $PWD is authoritative (handles nested submodules and sibling repos);
  #    project a bare/gitlink-style push via git worktree list when --show-toplevel
  #    fails but the command cwd is still a worktree (SEE-1268 submodule pushes).
  if cand=$(git rev-parse --show-toplevel 2>/dev/null); then
    GIT_ROOT="$cand"; return 0
  fi
  if git rev-parse --git-dir >/dev/null 2>&1; then
    GIT_ROOT="$PWD"; return 0
  fi
  # 3. Host worktree fallback — the historical case (agent on the KOL checkout).
  if [ -n "${PROJECT_ROOT:-}" ] && git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    GIT_ROOT="$PROJECT_ROOT"; return 0
  fi
  # 3b. SEE-1430b wrong-repo fix: prefer the task's target checkout when it is
  #     a repo — deterministic, ahead of any directory guessing.
  if [ -n "${TARGET_REPO_ROOT:-}" ] && git -C "$TARGET_REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    GIT_ROOT="$TARGET_REPO_ROOT"; return 0
  fi
  # 4. Last resort: one-level scan of PWD subdirectories. Deterministic order
  #    (sorted) — and if nothing matches, fail-open (return 1) instead of
  #    picking an arbitrary repo (previous behaviour grabbed the first entry
  #    in shell glob order, which mis-attributed pushes to the wrong repo).
  #    SEE-1440 / fingerprint b5a1003be842: only a candidate that carries the
  #    hook-host ownership marker (.claude/hooks) may be attributed — a stray
  #    sibling repo (e.g. /tmp fixture) must fall through to the no-repo path
  #    instead of being validated as the push target.
  local subdir
  while IFS= read -r subdir; do
    [ -n "$subdir" ] || continue
    [ -d "$subdir" ] || continue
    [ -d "${subdir%/}/.claude/hooks" ] || continue
    if git -C "$subdir" rev-parse --git-dir >/dev/null 2>&1; then
      GIT_ROOT="${subdir%/}"; return 0
    fi
  done < <(find "$PWD" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort)
  return 1
}

# SEE-1117 Direction 3 + SEE-1240 WS-8 retirement note: the per-worktree MCP
# lease lives in a sidecar at <worktree>/.godot/mcp-lease.json (gitignored —
# .gitignore covers .godot/). project.godot's static [godot_mcp] section
# carries ONLY machine-level bind constants (bind_mode=1 / custom_bind_ip="") —
# deployment-topology values, not per-agent runtime state; the WS-1
# override.cfg injection channel is retired (dead on WSL UNC paths). Per-agent
# runtime state (port / lease) lives ONLY in the sidecar. The historical
# port_override / [godot_mcp] pollution interception retired with SEE-1117
# Direction 3; this guard's remaining job is the ACTIVE sidecar invariants:
#   Check A (HARD BLOCK): the HEAD tree must NOT contain .godot/mcp-lease.json.
#     .gitignore should already make this impossible, so a hit means someone
#     force-added it — refuse the push and point at `git rm --cached`.
#   Check B (SOFT WARN): if the WORKTREE's sidecar is state=active, warn that
#     the lease was not released. Soft because the sidecar never enters git,
#     so an active lease cannot pollute the push payload — it only means the
#     editor's port is notionally still held. The agent should run
#     restore-godot-original.sh, but the push is not blocked.
run_sidecar_guard() {
  local target="$1"
  [ -n "$GIT_ROOT" ] || return 0
  [ -n "$target" ] || return 0

  # Check A: HEAD tree must NOT carry .godot/mcp-lease.json. Defensively scan
  # the whole tree path so a nested force-add is also caught.
  local leaked
  leaked=$(git -C "$GIT_ROOT" ls-tree -r --name-only HEAD 2>/dev/null \
    | grep -E '^\.godot/mcp-lease\.json$|/\.godot/mcp-lease\.json$' || true)
  if [ -n "$leaked" ]; then
    echo "[push-guard] 错误：HEAD tree 包含 sidecar lease 文件，禁止推送到 ${target}" >&2
    echo "[push-guard] 命中：$(printf '%s' "$leaked" | tr '\n' ' ')" >&2
    echo "[push-guard] .godot/mcp-lease.json 是 worktree 运行期 lease 状态，已被 .gitignore 挡，不应进 git。" >&2
    echo "[push-guard] 恢复：git rm --cached .godot/mcp-lease.json && git commit，然后重推。" >&2
    exit 2
  fi

  # Check B: worktree sidecar state=active → soft warn only. The sidecar is
  # gitignored, so an active lease does NOT pollute the push payload; this is
  # just a nudge to release the lease so the port is free for the next agent.
  local sidecar="$GIT_ROOT/.godot/mcp-lease.json"
  if [ -f "$sidecar" ]; then
    local state
    state=$(node -e "
      let raw = '';
      process.stdin.on('data', c => raw += c);
      process.stdin.on('end', () => {
        try { const o = JSON.parse(raw); process.stdout.write(String(o.state || '')); }
        catch (e) { process.stdout.write(''); }
      });
    " < "$sidecar" 2>/dev/null || true)
    if [ "$state" = "active" ]; then
      echo "[push-guard] 提示：worktree sidecar state=active（lease 未释放），sidecar 不会进 git，不会污染 push 内容。" >&2
      echo "[push-guard] 建议：运行 addons/godot_mcp/launch/restore-godot-original.sh 释放 lease（不阻塞本次 push）。" >&2
    fi
  fi
}

# SEE-1062 M1: reject pushes whose HEAD tree carries agent draft files
# (.reply*.md, .assign*.md, .review*.md, .mcp_*.md, .flow.md). These are
# Atlas-style Write+post+rm comment drafts; the stop-hook auto-commit
# repeatedly captures them between the rm and the next push, polluting the
# shared branch (3rd recurrence on PR #448). Scanning HEAD's tracked files
# (rather than a HEAD~1..HEAD diff) catches drafts no matter which commit
# added them, and naturally allows cleanup pushes — a git rm'd file is
# absent from HEAD.
run_draft_blacklist_guard() {
  local target="$1"
  [ -n "$GIT_ROOT" ] || return 0
  [ -n "$target" ] || return 0
  local matched
  matched=$(git -C "$GIT_ROOT" ls-tree -r --name-only HEAD 2>/dev/null \
    | grep -E '^\.reply.*\.md$|^\.assign.*\.md$|^\.review.*\.md$|^\.mcp_.*\.md$|^\.flow\.md$' \
    || true)
  if [ -n "$matched" ]; then
    echo "[push-guard] 错误：HEAD 含 agent 草稿文件，禁止推送到 ${target}" >&2
    echo "[push-guard] 命中：$(printf '%s' "$matched" | tr '\n' ' ')" >&2
    echo "[push-guard] Write+post+rm 草稿被 stop-hook auto-commit 带入（SEE-1062 第 3 次复发）。" >&2
    echo "[push-guard] 恢复：git rm <file> && git commit，然后重推。" >&2
    exit 2
  fi
}

# --- Phase 2: Guard checks that don't require git repo ---

# GQT host checkout resolution (SEE-1406 追加, Owner 白名单定调): the
# godot-qa-toolkit canonical checkout is a policy host like the KOL worktree —
# direct master/main pushes there follow the same Atlas/Archi-only whitelist.
# Sentinel/env pattern mirrors TARGET_REPO_ROOT: GQT_REPO_ROOT env overrides; the
# default probe path MUST stay in sync with GQT's .dev/launch/
# godot-qa-toolkit-start.sh + .dev/systemd unit hardcode
# (~/tools/godot-qa-toolkit). Neither env nor repo present → no GQT host
# (fail-open, companion zero-change preserved).
GQT_HOST_ROOT=""
resolve_gqt_host_root() {
  [ -n "$GQT_HOST_ROOT" ] && return 0
  local cand="${GQT_REPO_ROOT:-$HOME/tools/godot-qa-toolkit}"
  # -C 探测挂起失败即无 GQT host（fail-open）；toplevel 与 GIT_ROOT 同形可比。
  if git -C "$cand" rev-parse --show-toplevel >/dev/null 2>&1; then
    GQT_HOST_ROOT=$(git -C "$cand" rev-parse --show-toplevel 2>/dev/null)
    return 0
  fi
  return 1
}

# Check 2a: if pushing to master/main, only Atlas/Archi allowed (always blocks, regardless of CWD).
# SEE-1268 (2-library split): this master block is KOL's OWNAGENT-workflow policy,
# scoped to the KingOfLikes host worktree repo. Companion standalone libraries
# (godot-qa-toolkit, the godot-mcp fork, addons submodules) have their own
# development flow (fork PR / standalone master) and must NOT be master-gated by
# KOL. Only when the push's git root is the KOL worktree do we enforce the block.
# SEE-1406 追加: the GQT CANONICAL checkout joins the host set (same whitelist);
# GQT *task* checkouts elsewhere stay companion (path must equal toplevel probe).
if [ "$PUSH_RESULT" = "MASTER_PUSH" ]; then
  resolve_git_root || true
  HOST_REPO=""
  if [ -n "$PROJECT_ROOT" ] && git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    HOST_REPO="$PROJECT_ROOT"
  elif [ -n "$GIT_ROOT" ] && [ -d "$GIT_ROOT/.claude/hooks" ]; then
    HOST_REPO="$GIT_ROOT"
  fi
  IS_HOOK_HOST=false
  if [ -n "$HOST_REPO" ] && [ "$HOST_REPO" = "$GIT_ROOT" ]; then
    IS_HOOK_HOST=true
  elif [ -n "$GIT_ROOT" ] && resolve_gqt_host_root && [ "$GIT_ROOT" = "$GQT_HOST_ROOT" ]; then
    IS_HOOK_HOST=true
  fi
  if [ "$IS_HOOK_HOST" = "true" ]; then
    case "${MULTICA_AGENT_NAME:-}" in
      Atlas|Archi)
        # Even Atlas/Archi must not push a leaked .godot/mcp-lease.json onto master.
        [ -n "$GIT_ROOT" ] && run_sidecar_guard master
        echo "$INPUT"; exit 0 ;;
      *)
        echo "[push-guard] 错误：禁止直接推送到 master 分支" >&2
        echo "[push-guard] 请在feature分支上开发，通过PR合并" >&2
        exit 2
        ;;
    esac
  fi
  # Non-host repo (companion library): its own dev flow governs; not KOL-master-gated.
fi

# --- Phase 3: Guard checks that require being inside a git repo ---

resolve_git_root || {
  echo "[push-guard] 警告：未检测到 git 仓库，无法验证推送安全性" >&2
  echo "[push-guard] 请在仓库目录内执行 push 命令" >&2
  exit 2
}

# Fetch latest remote refs to ensure accurate ancestry check
git -C "$GIT_ROOT" fetch origin >/dev/null 2>&1 || true

# Resolve shared working branch + current upstream once for all checks (SEE-954),
# so Check 3 (master ancestry) and Check 5 (shared-branch target) share them.
WORKING_BRANCH=""
CURRENT_UPSTREAM=$(git -C "$GIT_ROOT" rev-parse --abbrev-ref "@{upstream}" 2>/dev/null || true)
if [ -n "${MULTICA_TASK_ID:-}" ]; then
  ISSUE_ID=$(multica issue run-messages "$MULTICA_TASK_ID" --output json 2>/dev/null | node -e "
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
  if [ -n "$ISSUE_ID" ]; then
    WORKING_BRANCH=$(multica issue metadata list "$ISSUE_ID" --output json 2>/dev/null | node -e "
      let d=''; process.stdin.on('data', c => d += c);
      process.stdin.on('end', () => {
        try {
          const meta = JSON.parse(d);
          if (meta.working_branch) {
            process.stdout.write(meta.working_branch);
          }
        } catch(e) {}
      });
    " 2>/dev/null || true)
  fi
fi

# Check 3: current branch must contain latest origin/<default> — UNLESS it tracks
# origin/<working_branch>, in which case master is picked up transitively via the
# §B auto-rebase (repo-checkout), so ancestry is satisfied through the shared
# branch and we must not block (SC1).
# SEE-1268: the default-branch ref is repo-specific. KOL uses master; companion
# libraries (godot-qa-toolkit, godot-mcp fork) default to master/main per their
# own HEAD. Use origin/HEAD when set, falling back to origin/master; a repo with
# neither ref gets no ancestry check (nothing to verify against) rather than a
# false "未包含最新的 master" block.
if [ "$CURRENT_UPSTREAM" != "origin/${WORKING_BRANCH}" ]; then
  # SEE-1430b: default-branch ref resolution order fixed — prefer origin/HEAD
  # (authoritative), then origin/main (dev-forge default), then origin/master
  # (KOL legacy). Old order tried origin/master first; repos whose default is
  # main (dev-forge) have no origin/master remote ref, so the ancestry check
  # always failed ("当前分支未包含最新的 origin/master") on every push.
  DEFAULT_REMOTE_REF=$(git -C "$GIT_ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo "")
  if [ -z "$DEFAULT_REMOTE_REF" ]; then
    if git -C "$GIT_ROOT" rev-parse --verify --quiet "origin/main" >/dev/null 2>&1; then
      DEFAULT_REMOTE_REF="origin/main"
    else
      DEFAULT_REMOTE_REF="origin/master"
    fi
  fi
  if [ -n "$DEFAULT_REMOTE_REF" ] \
     && ! git -C "$GIT_ROOT" merge-base --is-ancestor "$DEFAULT_REMOTE_REF" HEAD 2>/dev/null; then
    echo "[push-guard] 错误：当前分支未包含最新的 ${DEFAULT_REMOTE_REF}" >&2
    echo "[push-guard] 请先执行 git fetch && git rebase ${DEFAULT_REMOTE_REF}" >&2
    exit 2
  fi
fi

# Check 4: NO_REFSPEC + current branch is master/main — block non-Atlas/Archi
if [ "$PUSH_RESULT" = "NO_REFSPEC" ]; then
  CURRENT_BRANCH=$(git -C "$GIT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [ "$CURRENT_BRANCH" = "master" ] || [ "$CURRENT_BRANCH" = "main" ]; then
    case "${MULTICA_AGENT_NAME:-}" in
      Atlas|Archi) echo "$INPUT"; exit 0 ;;
      *)
        echo "[push-guard] 错误：禁止直接推送到 master 分支" >&2
        echo "[push-guard] 请在feature分支上开发，通过PR合并" >&2
        exit 2
        ;;
    esac
  fi
fi

# Check 5: shared-branch target enforcement (SEE-954). WORKING_BRANCH and
# CURRENT_UPSTREAM are resolved once above the checks.
#   - bare `git push` (NO_REFSPEC): ALLOW when the current branch tracks
#     origin/<working_branch> — the push lands on the shared branch via upstream
#     (SC2). Otherwise require an explicit refspec.
#   - explicit refspec: the remote target MUST equal <working_branch>.
#   - SC4: pre-detect non-FF (another agent pushed first) and surface recovery.
# SEE-1268 (2-library split): the shared-branch policy is KOL's multi-agent
# workflow on the HOST worktree. A push from a companion standalone repo is not
# part of that workflow and must not be target-gated. Check 5 therefore applies
# ONLY when GIT_ROOT is the KOL host worktree or the GQT canonical checkout
# (SEE-1406 追加 — same shared-branch discipline, Owner 定调功能与 KOL 一致).
IS_HOST_REPO=false
if [ -n "$PROJECT_ROOT" ] && [ "$GIT_ROOT" = "$PROJECT_ROOT" ]; then
  IS_HOST_REPO=true
elif [ -n "$PROJECT_ROOT" ] && git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
     && [ "$GIT_ROOT" = "$PROJECT_ROOT" ]; then
  IS_HOST_REPO=true
elif [ -n "$GIT_ROOT" ] && resolve_gqt_host_root && [ "$GIT_ROOT" = "$GQT_HOST_ROOT" ]; then
  IS_HOST_REPO=true
fi

# The §B auto-rebase in repo-checkout (SessionStart) pushes origin/<working_branch>
# with --force-with-lease but does not pass through push-guard; check A/5 only run
# for host pushes. Guard the whole Check-5 block behind IS_HOST_REPO.
if [ "$IS_HOST_REPO" = "true" ] && [ -n "$WORKING_BRANCH" ]; then
  if [ "$PUSH_RESULT" = "NO_REFSPEC" ]; then
    if [ "$CURRENT_UPSTREAM" != "origin/${WORKING_BRANCH}" ]; then
      echo "[push-guard] 当前任务要求推送到共享分支 ${WORKING_BRANCH}" >&2
      echo "[push-guard] 请使用显式 refspec：git push origin HEAD:refs/heads/${WORKING_BRANCH}" >&2
      exit 2
    fi
  else
    # Extract target branch from the push command refspec
    TARGET_BRANCH=$(printf '%s' "$INPUT" | node -e "
      let d=''; process.stdin.on('data', c => d += c);
      process.stdin.on('end', () => {
        try {
          const i = JSON.parse(d);
          let cmd = (i.tool_input?.command || '').trim();
          cmd = cmd.replace(/(?:^|\s)<<-?\s*\S+[\s\S]*$/, '').trim();
          const tokens = cmd.match(/(?:[^\s\"']+|\"[^\"]*\"|'[^']*')+/g) || [];
          let pushIdx = -1;
          for (let idx = 0; idx < tokens.length; idx++) {
            if (tokens[idx] === 'git') {
              let j = idx + 1;
              while (j < tokens.length && tokens[j].startsWith('-')) {
                if (tokens[j].length === 2 && tokens[j] !== '--') { j += 2; continue; }
                j++; continue;
              }
              if (j < tokens.length && tokens[j] === 'push') { pushIdx = j; break; }
            }
          }
          if (pushIdx < 0) return;
          const afterPush = tokens.slice(pushIdx + 1);
          for (const t of afterPush) {
            if (t === '--' || t.startsWith('-')) continue;
            if (t === 'origin') continue;
            if (t.includes(':')) {
              const branch = t.split(':').pop().replace(/^refs\/heads\//, '').replace(/^[\"'\x60]|[\"'\x60]$/g, '');
              process.stdout.write(branch);
            } else {
              process.stdout.write(t.replace(/^[\"'\x60]|[\"'\x60]$/g, ''));
            }
            return;
          }
        } catch(e) {}
      });
    " 2>/dev/null || true)

    if [ "$TARGET_BRANCH" != "$WORKING_BRANCH" ]; then
      echo "[push-guard] 错误：当前任务的共享分支是 ${WORKING_BRANCH}，不允许推送到 ${TARGET_BRANCH:-<未指定>}" >&2
      echo "[push-guard] 请使用：git push origin HEAD:refs/heads/${WORKING_BRANCH}" >&2
      exit 2
    fi
  fi

  # SC4: pre-detect non-FF. If origin/<working_branch> has commits not in HEAD,
  # a push would be rejected. Block with a recoverable hint (rebase preserves
  # local commits; reset --hard only when there are none to lose).
  if [ -n "$(git -C "$GIT_ROOT" rev-list "HEAD..origin/${WORKING_BRANCH}" 2>/dev/null)" ]; then
    echo "[push-guard] 远端共享分支 ${WORKING_BRANCH} 已推进（其他 agent 抢先），本次推送会被 non-FF 拒绝。" >&2
    echo "[push-guard] 恢复方法：git fetch origin && git rebase origin/${WORKING_BRANCH}，然后重新推送。" >&2
    echo "[push-guard]（若本地无未推送 commit，也可：git reset --hard origin/${WORKING_BRANCH}）" >&2
    exit 2
  fi
fi

# Check 6 (SEE-1117 Direction 3): sidecar lease guard. project.godot carries
# no lease state and (since SEE-1240 WS-8) only the static machine-level
# [godot_mcp] bind constants — per-agent runtime state lives solely in
# .godot/mcp-lease.json (gitignored). Hard-block if the HEAD tree leaked a
# sidecar; soft-warn if the worktree sidecar is still active. Mirrors the
# master check in Phase 2. Host-repo scoped (SEE-1268): companion repos have no
# project.godot lease sidecar, so the guard is a no-op for them anyway.
if [ "$IS_HOST_REPO" = "true" ] && [ -n "$WORKING_BRANCH" ]; then
  run_sidecar_guard "$WORKING_BRANCH"
  # Check 7 (SEE-1062 M1): reject pushes whose HEAD tree carries agent draft
  # files. Root-cause guard against the recurring stop-hook draft pollution.
  # Also host-repo scoped — the draft-file pollution class is the KOL stop-hook
  # auto-commit; companion repos are not governed by that auto-commit flow.
  run_draft_blacklist_guard "$WORKING_BRANCH"
fi

# Check 8 (SEE-1268 GAP-1, defense-in-depth): dangling-gitlink guard.
# The authoritative check lives in repo_sync.do_push (the automated channel);
# this copy intercepts agent-typed pushes. Engages only when .gitmodules
# exists; 探测走共享函数（.claude/hooks/scripts/lib/gitlink-probe.sh——与 auto-pr
# 共用同一份实现，守 §7.3 冗余红线），每 probe 限 20s 防远端拖慢。
if [ -f "$GIT_ROOT/.gitmodules" ]; then
  GITLINK_PROBE_TIMEOUT=20
  # shellcheck source=scripts/lib/gitlink-probe.sh
  # 优先本仓 lib（dev-forge 相对定位）；目标仓库自带副本时兜底（$GIT_ROOT 恒为正在 push 的仓库根）。
  _probe="$(cd "$(dirname "$0")" && pwd)/lib/gitlink-probe.sh"
  [ -f "$_probe" ] || _probe="$GIT_ROOT/.claude/hooks/scripts/lib/gitlink-probe.sh"
  [ -f "$_probe" ] && . "$_probe"
  DANGLING=""
  while IFS=$'\t' read -r sha path_rel; do
    [ -n "$sha" ] || continue
    VERDICT=$(qa_gitlink_classify "$GIT_ROOT" "$path_rel" "$sha" "$GITLINK_PROBE_TIMEOUT")
    case "$VERDICT" in
      dangling)
        DANGLING="$DANGLING$path_rel @ $sha
" ;;
      *) : ;;  # healthy / uninit / no-url / probe-fail：不误拦
    esac
  done < <(git -C "$GIT_ROOT" ls-files --stage 2>/dev/null | awk '/^160000/{print $2"\t"$4}')
  if [ -n "$DANGLING" ]; then
    echo "[push-guard] 错误：dangling gitlink——父仓指针指向子库 remote 上不存在的 commit，推出去会让所有人 clone 死亡。" >&2
    echo "[push-guard] 命中：
$DANGLING" >&2
    echo "[push-guard] 恢复：先在对应子库 push 该 commit（先补推子库），再重推父仓。" >&2
    exit 2
  fi
fi

# All checks passed — pass stdin through
echo "$INPUT"
