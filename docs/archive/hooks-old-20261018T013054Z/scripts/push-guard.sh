#!/bin/bash
set -e

# PreToolUse hook: guards git push commands
# Trigger: Bash(git push*)
#
# SEE-1411 终版架构（Owner 指令「一劳永逸」，替代四轮手写词法拉锯）：
# 不再手写 tokenizer/heredoc 正则/bash -c 解包/tilde 展开——那些正是 F-1~F-2‴
# 每轮都漏的根源。改为「stub 沙箱语义解析」：
#   1. 用户命令放进一个 PATH=仅有无害桩(每个外部命令只回显自己的 argv) 的沙箱里
#      真实跑一遍（5s timeout 兜底未闭合 heredoc 的挂起；文件写入落在沙箱）。
#   2. 真实 bash 消化全部引号/tilde/heredoc/here-string/bash -c——每个桩回显的
#      argv 就是语义级命令词元，且带**执行时刻的真实 cwd**。
#   3. guard 对每条「推送行」独立判定（含 cwd 精确认仓），任一行违规即拦。
# 词法层从 ~180 行启发式缩为零假设；沙箱外未知命令一律 command-not-found
# （fail-closed：未覆盖的调用形态只会"不执行"，不会绕过检查去真推）。
# 已知限制（Revy r5 登记，OWNER 追认）：
#   ARCH-5  env 前缀（GIT_DIR=… git push）不进 argv——判定按 cwd 语义走；显式 cd/-C 可准确定位
#   ARCH-1  多仓复合命令的 SAFE 行聚合只对首行做共享分支/ancestry 精查（第 2 条
#           起的 SAFE 行不做 host 目标检查；单仓单 push 为主要使用形态，登记）
#   ARCH-6  沙箱不是 jail：绝对路径/未 stub 化的命令会真实执行（故意的只读对照用法可达），
#           但其 argv 不进捕获 → 不触发 guard 分类（"故意绕过"威胁模型边界，登记不堵）

INPUT=$(cat)

# --- Phase 1: 语义解析（stub 沙箱真实执行，零词法假设）---
SANDBOX=$(mktemp -d 2>/dev/null) || SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/bin"
# 覆盖 agent 会话常见外部命令；不在此列的命令在沙箱内 command-not-found——
# 方向是 fail-closed（不会偷偷真执行，也就不可能"逃过检查真推送"）。
STUBS="git cat rm mv cp sed awk grep egrep fgrep tee touch mkdir rmdir tr head tail bash sh diff sort uniq wc find xargs env sudo curl wget scp rsync ln chmod chown dd sleep printf echo false true test ping ssh scp nohup setsid script strace busybox dirname basename realpath readlink stat file less more vi vim nano python3 python node npm go"
for c in $STUBS; do
  printf '#!/bin/bash\nprintf "ARGV:%%s|CWD:%%s\\n" "%s $*" "$PWD" >> "$PG_CAPTURE"\n' "$c" > "$SANDBOX/bin/$c" 2>/dev/null
  chmod +x "$SANDBOX/bin/$c" 2>/dev/null || true
done
printf '%s\n' "${PUSHGUARD_CMD:-}" > "$SANDBOX/cmd" 2>/dev/null || true
printf '%s' "$INPUT" > "$SANDBOX/input.json"
# 用户命令经 node 从 JSON 提出（不经过 shell 二次解释），写入文件供沙箱 bash 读
node -e "
  let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{
    try { process.stdout.write(JSON.parse(d).tool_input?.command || ''); } catch(e) {}
  });
" < "$SANDBOX/input.json" > "$SANDBOX/cmd" 2>/dev/null || true

PG_CAPTURE="$SANDBOX/capture.txt"; : > "$PG_CAPTURE"
(
  export PATH="$SANDBOX/bin" PG_CAPTURE
  # SEE-1411 ARCH-0 (Revy r5): start in the CALLER's cwd — commands without an
  # explicit cd (the most common real form) must capture the true repo cwd.
  /usr/bin/timeout 5 /bin/bash "$SANDBOX/cmd" >/dev/null 2>&1
) || true
# 沙箱结尾 cwd（用户 push 实际会发生的目录；cd 失败时=沙箱本身）
if [ -s "$SANDBOX/capture.txt.pwd" ]; then :; fi
FINAL_CWD=$(tail -1 "$PG_CAPTURE.pwd" 2>/dev/null || echo "")

# --- Phase 1.5: 逐行分类（bash 消化后的 argv 是语义级：无引号/无 heredoc/tilde 已展开）---
# 输出 PUSHLINE 协议：class|cwd|target   （每条 push 命令一行；target 为空表示无显式 refspec）
PHASE1_OUTPUT=$(python3 - "$PG_CAPTURE" <<'PYEOF'
import sys, re, shlex, os

capture = sys.argv[1]
HOME = os.environ.get('HOME', '')
try:
    lines = open(capture).read().splitlines()
except Exception:
    lines = []

def strip_refs(t):
    return t[len('refs/heads/'):] if t.startswith('refs/heads/') else t

def classify(args):
    """返回 (class, target, cwd, uncertain)。cwd=None 且 uncertain=True → shell 端 fail-closed。
    bash 桩已消化引号/heredoc/bash-c 包装——本函数只做 token 级判定，零词法假设。"""
    try:
        tokens = shlex.split(args)
    except ValueError:
        tokens = args.split()
    # 定位 git push：git 后可隔全局旗标；-C <path> 是权威 cwd
    cwd_hint = None
    post = None
    for i, t in enumerate(tokens):
        if t != 'git':
            continue
        j = i + 1
        while j < len(tokens) and tokens[j].startswith('-') and tokens[j] != '--':
            if tokens[j] == '-C' and j + 1 < len(tokens):
                cwd_hint = tokens[j + 1]
                j += 1
            j += 1
        if j < len(tokens) and tokens[j] == 'push':
            post = tokens[j + 1:]
            break
    if post is None:
        return None
    # cd 估计（无 -C 时）：行内 cd <path>；tilde 以 HOME 锚定
    if cwd_hint is None:
        m = re.search(r'(?:^|&&|;|\||\s)\s*cd\s+(\S+)', args)
        if m:
            h = m.group(1)
            cwd_hint = (HOME + h[1:]) if h.startswith('~') else h
    uncertain = cwd_hint is None
    cls = 'SAFE'
    target = ''
    is_delete = False
    is_force = False
    has_master = False
    bare = []
    after = []
    for t in post:
        if t == '--':
            continue
        if t.startswith('-'):
            if t in ('-d', '--delete'):
                is_delete = True
            if t == '--force' or t.startswith('--force=') or (t.startswith('--force') and 'lease' not in t) or t == '--force-with-lease' or t.startswith('--force-with-lease=') or re.match(r'^-[a-z]*f', t):
                is_force = True
            continue
        after.append(t)
        bare.append(strip_refs(t))
    if any(t.startswith(':') for t in post):
        is_delete = True
        for t in post:
            if t.startswith(':') and strip_refs(t[1:]) in ('master', 'main'):
                has_master = True
    if is_delete and any(b in ('master', 'main') for b in bare):
        has_master = True
    if not is_delete and any(b in ('master', 'main') for b in bare):
        has_master = True
    if is_force:
        cls = 'FORCE'
    elif has_master:
        cls = 'MASTER'
    elif is_delete:
        cls = 'DELETE'
    else:
        for t in reversed(after):
            if t in ('origin', 'upstream'):
                continue
            target = strip_refs(t.split(':')[-1])
            break
    return (cls, target, cwd_hint, uncertain)

out = []
for line in lines:
    if not line.startswith('ARGV:'):
        continue
    body, _, cwd = line.rpartition('|CWD:')
    if not body.startswith('ARGV:'):
        continue
    args = body[len('ARGV:'):]
    r = classify(args)
    if r is None:
        continue
    cls, target, hint, uncertain = r
    out.append(f'PUSHLINE:{cls}|{hint or cwd}|{target}|{1 if uncertain else 0}')

if not out:
    print('NOT_PUSH')
else:
    for l in out:
        print(l)
PYEOF
) 2>/dev/null || true

# 沙箱异常（timeout 后无捕获等）：真实 shell 语义下未闭合 heredoc 会挂起、命令不执行 → 放行
if [ ! -s "$PG_CAPTURE" ]; then
  echo "$INPUT"; exit 0
fi

rm -rf "$SANDBOX" 2>/dev/null || true

# --- Head-tree guards (restored, SEE-1411 ARCH-2b/2c): draft blacklist +
# sidecar lease. Run once per push against the resolved GIT_ROOT.
run_head_guards() {
  [ -n "$GIT_ROOT" ] || return 0
  # Check A (HARD): HEAD tree must NOT contain .godot/mcp-lease.json
  local leaked
  leaked=$(git -C "$GIT_ROOT" ls-tree -r --name-only HEAD 2>/dev/null \
    | grep -E '^\.godot/mcp-lease\.json$|/\.godot/mcp-lease\.json$' || true)
  if [ -n "$leaked" ]; then
    echo "[push-guard] 错误：HEAD tree 包含 sidecar lease 文件，禁止推送到 ${TARGET_BRANCH:-<未指定>}（被校验的仓库：${GIT_ROOT}）" >&2
    echo "[push-guard] 恢复：git rm --cached .godot/mcp-lease.json && git commit，然后重推。" >&2
    exit 2
  fi
  # Check 7 (HARD): agent draft files must not ride into a push (SEE-1062)
  local drafts
  drafts=$(git -C "$GIT_ROOT" ls-tree -r --name-only HEAD 2>/dev/null \
    | grep -E '^\.reply.*\.md$|^\.assign.*\.md$|^\.review.*\.md$|^\.mcp_.*\.md$|^\.flow\.md$' \
    || true)
  if [ -n "$drafts" ]; then
    echo "[push-guard] 错误：HEAD 含 agent 草稿文件，禁止推送到 ${TARGET_BRANCH:-<未指定>}（被校验的仓库：${GIT_ROOT}）" >&2
    echo "[push-guard] 命中：$(printf '%s' "$drafts" | tr '\n' ' ')" >&2
    echo "[push-guard] 恢复：git rm <file> && git commit，然后重推。" >&2
    exit 2
  fi
  # Check B (SOFT): worktree sidecar still active — warn only
  local sidecar="$GIT_ROOT/.godot/mcp-lease.json"
  if [ -f "$sidecar" ]; then
    local state
    state=$(python3 -c "
import json,sys
try: print(str(json.load(open(sys.argv[1])).get('state','')))
except Exception: print('')" "$sidecar" 2>/dev/null || true)
    if [ "$state" = "active" ]; then
      echo "[push-guard] 提示：worktree sidecar state=active（lease 未释放），sidecar 不会进 git。" >&2
      echo "[push-guard] 建议：运行 addons/godot_mcp/launch/restore-godot-original.sh 释放 lease（不阻塞 push）。" >&2
    fi
  fi
}

# --- Phase 2: 聚合判定（最严行胜出；任一行违规即拦）---
if [ "$PHASE1_OUTPUT" = "NOT_PUSH" ] || [ -z "$PHASE1_OUTPUT" ]; then
  echo "$INPUT"; exit 0
fi

WORST="SAFE"; WORST_CWD=""; WORST_TARGET=""; WORST_UNC=0
while IFS= read -r pl; do
  case "$pl" in PUSHLINE:*) ;; *) continue ;; esac
  body="${pl#PUSHLINE:}"
  cls="${body%%|*}"; rest="${body#*|}"; cwd="${rest%%|*}"; rest="${rest#*|}"
  target="${rest%%|*}"; unc="${rest#*|}"
  case "$cls" in
    FORCE)   PRI=5 ;;
    MASTER)  PRI=4 ;;
    DELETE)  PRI=2 ;;
    SAFE)    PRI=1 ;;
    *)       PRI=1 ;;
  esac
  case "$WORST" in
    FORCE) PRI_W=5 ;;
    MASTER) PRI_W=4 ;;
    DELETE) PRI_W=2 ;;
    *) PRI_W=1 ;;
  esac
  if [ "$PRI" -gt "$PRI_W" ]; then
    WORST="$cls"; WORST_CWD="$cwd"; WORST_TARGET="$target"; WORST_UNC="$unc"
  elif [ "$PRI" -eq "$PRI_W" ] && [ -z "$WORST_CWD" ]; then
    WORST_CWD="$cwd"; WORST_TARGET="$target"; WORST_UNC="$unc"
  fi
done <<PUSHLIST
$PHASE1_OUTPUT
PUSHLIST

GIT_ROOT="$WORST_CWD"
PUSH_RESULT="$WORST"
TARGET_BRANCH="$WORST_TARGET"

# If not a git push command, pass stdin through and exit
[ "$PUSH_RESULT" = "SAFE" ] || true   # push classes below; SAFE falls into Phase 3

# Force push: blocked for agents by default. SEE-1069: Atlas whitelisted by agent_id
# (audit-logged); non-Atlas blocked.
if [ "$PUSH_RESULT" = "FORCE" ]; then
  ATLAS_AGENT_ID="fac3e3a1-dcda-498d-8613-e8c2811f3ef5"
  if [ "${MULTICA_AGENT_ID:-}" = "$ATLAS_AGENT_ID" ]; then
    FORCED_CMD=$(printf '%s' "$INPUT" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{process.stdout.write((JSON.parse(d).tool_input?.command||'').trim())}catch(e){}})" 2>/dev/null || true)
    AUDIT_LOG="${PROJECT_ROOT:-.}/.claude/push-guard-force-audit.log"
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

# Check 4/5: master 白名单 + 共享分支目标（host 判定沿用；MASTER 行已在上面进入本段）
if [ "$PUSH_RESULT" = "MASTER" ]; then
  # SEE-1411 fail-closed first: an unlocatable push repo must never ride the
  # companion-autonomy branch out (Revy r5 E1a).
  if [ -z "$GIT_ROOT" ] || ! git -C "$GIT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "[push-guard] 错误：无法在沙箱中定位该推送的目标仓库（cwd=${GIT_ROOT:-无}）" >&2
    echo "[push-guard] 请用 cd <仓库路径> && git push … 或 git -C <仓库路径> push … 显式定位后重试" >&2
    exit 2
  fi
  HOST_REPO=""
  if [ -n "$PROJECT_ROOT" ] && git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    HOST_REPO="$PROJECT_ROOT"
  elif [ -d "$GIT_ROOT/.claude/hooks" ]; then
    HOST_REPO="$GIT_ROOT"
  else
    GQT_CAND="${GQT_REPO_ROOT:-$HOME/tools/godot-qa-toolkit}"
    if git -C "$GQT_CAND" rev-parse --show-toplevel >/dev/null 2>&1 \
       && [ "$(git -C "$GQT_CAND" rev-parse --show-toplevel 2>/dev/null)" = "$GIT_ROOT" ]; then
      HOST_REPO="$GIT_ROOT"
    fi
  fi
  if [ -n "$HOST_REPO" ] && [ "$HOST_REPO" = "$GIT_ROOT" ]; then
    case "${MULTICA_AGENT_NAME:-}" in
      Atlas|Archi)
        run_head_guards
        echo "$INPUT"; exit 0 ;;
      *)
        echo "[push-guard] 错误：禁止直接推送到 master 分支（被校验的仓库：${GIT_ROOT}）" >&2
        echo "[push-guard] 请在feature分支上开发，通过PR合并" >&2
        exit 2
        ;;
    esac
  fi
  # 非 host 仓：companion 自治，不做 KOL-master 门
  echo "$INPUT"; exit 0
fi


# --- Phase 3: 需要 GIT_ROOT 的检查（working_branch 元数据一次解析）---
# SEE-1411 fail-closed：推送 cwd 无法确认为 git 仓（bash -c 内层 cd 落空等）时
# 一律拦下并要求显式 -C/cd——不确定就不能放行（DELETE 行为无代码，例外放行）。
if [ "$PUSH_RESULT" != "DELETE" ]; then
  if [ -z "$GIT_ROOT" ] || ! git -C "$GIT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "[push-guard] 错误：无法在沙箱中定位该推送的目标仓库（cwd=${GIT_ROOT:-无}）" >&2
    echo "[push-guard] 请用 cd <仓库路径> && git push … 或 git -C <仓库路径> push … 显式定位后重试" >&2
    exit 2
  fi
else
  echo "$INPUT"; exit 0
fi

git -C "$GIT_ROOT" fetch origin >/dev/null 2>&1 || true

CURRENT_UPSTREAM=$(git -C "$GIT_ROOT" rev-parse --abbrev-ref "@{upstream}" 2>/dev/null || true)
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

# Check 3: ancestry（沿用既有语义；未跟踪 working_branch 时校验 origin/master|HEAD）
if [ "$CURRENT_UPSTREAM" != "origin/${WORKING_BRANCH}" ]; then
  DEFAULT_REMOTE_REF="origin/master"
  if ! git -C "$GIT_ROOT" rev-parse --verify --quiet "$DEFAULT_REMOTE_REF" >/dev/null 2>&1; then
    DEFAULT_REMOTE_REF=$(git -C "$GIT_ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo "")
  fi
  if [ -n "$DEFAULT_REMOTE_REF" ] \
     && ! git -C "$GIT_ROOT" merge-base --is-ancestor "$DEFAULT_REMOTE_REF" HEAD 2>/dev/null; then
    echo "[push-guard] 错误：当前分支未包含最新的 ${DEFAULT_REMOTE_REF}（被校验的仓库：${GIT_ROOT}）" >&2
    echo "[push-guard] 请先执行 git fetch && git rebase ${DEFAULT_REMOTE_REF}" >&2
    exit 2
  fi
fi

# SAFE 行：共享分支目标检查（host 限定）
if [ "$PUSH_RESULT" = "SAFE" ] && [ -n "$WORKING_BRANCH" ]; then
  IS_HOST_REPO=false
  if [ -n "$PROJECT_ROOT" ] && [ "$GIT_ROOT" = "$PROJECT_ROOT" ]; then
    IS_HOST_REPO=true
  elif [ -d "$GIT_ROOT/.claude/hooks" ]; then
    IS_HOST_REPO=true
  else
    GQT_CAND="${GQT_REPO_ROOT:-$HOME/tools/godot-qa-toolkit}"
    if git -C "$GQT_CAND" rev-parse --show-toplevel >/dev/null 2>&1 \
       && [ "$(git -C "$GQT_CAND" rev-parse --show-toplevel 2>/dev/null)" = "$GIT_ROOT" ]; then
      IS_HOST_REPO=true
    fi
  fi
  if [ "$IS_HOST_REPO" = "true" ]; then
    if [ "$CURRENT_UPSTREAM" != "origin/${WORKING_BRANCH}" ] && [ "$TARGET_BRANCH" != "$WORKING_BRANCH" ]; then
      echo "[push-guard] 当前任务要求推送到共享分支 ${WORKING_BRANCH}（本次目标：${TARGET_BRANCH:-<未指定>}，被校验的仓库：${GIT_ROOT}）" >&2
      echo "[push-guard] 请使用显式 refspec：git push origin HEAD:refs/heads/${WORKING_BRANCH}" >&2
      exit 2
    fi
    # SC4: non-FF 预检
    if [ "$TARGET_BRANCH" = "$WORKING_BRANCH" ] && [ -n "$(git -C "$GIT_ROOT" rev-list "HEAD..origin/${WORKING_BRANCH}" 2>/dev/null)" ]; then
      echo "[push-guard] 远端共享分支 ${WORKING_BRANCH} 已推进（其他 agent 抢先），本次推送会被 non-FF 拒绝。" >&2
      echo "[push-guard] 恢复方法：git fetch origin && git rebase origin/${WORKING_BRANCH}，然后重新推送。" >&2
      exit 2
    fi
  fi
fi

# Head-tree guards apply to every real push reaching here (SAFE/MASTER passes)
run_head_guards

# --- Check 8 (restored, SEE-1411 ARCH-2c; origin SEE-1268 GAP-1): dangling
# gitlink guard. A parent repo whose gitlink points at a commit missing from
# the child's remote makes every fresh clone broken — irrecoverable class, so
# the check is HARD. The probe lib only exists in host repos; companions skip
# (v2 behavior, no crash — the r5 F-3 fix stays).
if [ -f "$GIT_ROOT/.gitmodules" ]; then
  if [ ! -f "$GIT_ROOT/.claude/hooks/scripts/lib/gitlink-probe.sh" ]; then
    echo "[push-guard] 提示：$GIT_ROOT 无 gitlink-probe 库（非宿主仓），跳过 dangling-gitlink 检查" >&2
  else
    . "$GIT_ROOT/.claude/hooks/scripts/lib/gitlink-probe.sh"
    DANGLING=""
    while IFS=$'\t' read -r sha path_rel; do
      [ -n "$sha" ] || continue
      VERDICT=$(qa_gitlink_classify "$GIT_ROOT" "$path_rel" "$sha" 20)
      case "$VERDICT" in
        dangling) DANGLING="$DANGLING$path_rel @ $sha
" ;;
        *) : ;;
      esac
    done < <(git -C "$GIT_ROOT" ls-files --stage 2>/dev/null | awk '/^160000/{print $2"\t"$4}')
    if [ -n "$DANGLING" ]; then
      echo "[push-guard] 错误：dangling gitlink——父仓指针指向子库 remote 上不存在的 commit，推出去会让所有人 clone 死亡。（被校验的仓库：${GIT_ROOT}）" >&2
      echo "[push-guard] 命中：
$DANGLING" >&2
      echo "[push-guard] 恢复：先在对应子库 push 该 commit（先补推子库），再重推父仓。" >&2
      exit 2
    fi
  fi
fi

# All checks passed — pass stdin through

echo "$INPUT"
