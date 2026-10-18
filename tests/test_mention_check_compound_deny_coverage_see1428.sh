#!/bin/bash
# test_mention_check_compound_deny_coverage_see1428.sh
# SEE-1428: pre comment 钩子对复合命令（comment add && rm 清理段）的拦截覆盖判定。
# 落点：dev-forge（SEE-1430 hooks 迁移后主库；本套件自 KOL branch shared/SEE-1428
# commit 682081d9 的 17 判据硬化版迁移，被测对象路径改为 claude-hooks/ 布局）。
#
# 用户反馈假设：复合命令 `multica issue comment add ... && rm <file>` 被拦截时
# 「只拦截 comment add 段，尾随 rm 段仍被执行」，导致拦截后重发报 No such file。
#
# 排查结论（§SPEC-001）：问题不存在于钩子拦截语义层。
#   1) 代码路径依据：
#      - claude-hooks/scripts/mention-check.sh:361-378 —— 命中 NO_MENTION /
#        CONTENT_FILE_UNREADABLE 时输出 permissionDecision=deny JSON 并 exit 0；
#        脚本自身不执行任何 shell 片段，无「拆段放行」逻辑。
#      - .claude/hooks/unified/engine.js:249-252 —— config deny action 命中即
#        result.denied 终态；engine.js:423-434 —— denied 时整条输出 deny 协议。
#        引擎对 payload.tool_input.command 求值（when-ops command op 全段扫描），
#        拦截判定以整条命令为对象，不存在按段放行路径。
#      - dispatcher.sh 尾段 —— hookSpecificOutput JSON 原样透传给 CC。
#   2) 平台语义依据：Claude Code 2.1.204 实测（沙箱 hook 工程与本仓库生产钩子
#      链两轮 claude -p 受控复现），PreToolUse deny 粒度 = 整条 Bash 工具调用，
#      `rm` 段与 comment 段一同不执行；permission 层拦截同样整条拒绝。
#   3) 用户可见「No such file」的真实机制：拦截后 agent 重发时，正文文件已被
#      此前一次**成功发出**的同构命令中的 `rm` 清理段删除（命令成功时 rm 本就
#      会执行，属设计内行为），或重发路径触发 CONTENT_FILE_UNREADABLE 硬错误
#      （mention-check.sh:337-358，文案含 No such file or directory）。二者均
#      非「钩子拦一半」。
#
# 本套件将该结论固化为机器判据（§SPEC-002/003 防回归）：
#   A. mention-check.sh 对 `comment add && rm` 复合命令输出整条 deny，且尾随
#      rm 目标文件不被钩子链触碰（钩子无命令执行能力，防「拦后删文件」回归）；
#   B. deny 覆盖各复合分隔符（&& / ; / 换行）——含行首 comment add；
#   B2. fallback 分段扫描边界：comment add 不在行首（cd 前缀 / bash -c 嵌套 /
#       管道后）仍整条 deny——仅被快速路径覆盖的行首样本对此无判别力；
#   C. engine mention-confirm-check（config deny）对 cd 前缀含 mention 复合
#      命令整条 deny，rm 目标不被触碰；
#   D. 阴性对照：无 comment add 的复合命令、以及引号字符串字面量中出现
#      comment add 短语（echo "..."）均不过度拦截（防 catch-all 误蔽合法命令）；
#   E. 用户所见「No such file」真实机制固化：复合命令中 --content-file 指向
#      不存在文件 → CONTENT_FILE_UNREADABLE 硬错误整条 deny（mention-check
#      诚实报错语义，SEE-1054），且 rm 目标不被触碰；
#   M. 变异杀灭用例：对 mention-check.sh 副本施加 3 类定向变异（fails-open
#      deny→allow / 复合检测失察 return false / catch-all 过拦 return true），
#      各被一台判据杀灭；变异锚点未命中或不唯一（源漂移）时显式 FAIL。
#
# Related Issues: SEE-1428
# Author: Bachi (Backend Agent) / Harti (Hardener)

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); }
separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# 被测链路：dev-forge claude-hooks/ 布局——脚本与引擎/规则均取本分支树
MENTION_CHECK="$REPO_ROOT/claude-hooks/scripts/mention-check.sh"
ENGINE="$REPO_ROOT/claude-hooks/unified/engine.js"
RULES="$REPO_ROOT/claude-hooks/unified/rules-v2.json"

[ -f "$MENTION_CHECK" ] || { echo "ERROR: $MENTION_CHECK not found"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "ERROR: node not found"; exit 1; }

TMP="$(mktemp -d /tmp/see1428-compound-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# 构造 PreToolUse/Bash hook payload（$1=command $2=session_id）
make_payload() {
    node -e "console.log(JSON.stringify({hook_event_name:'PreToolUse',tool_name:'Bash',tool_input:{command:process.argv[1]},session_id:process.argv[2]}))" "$1" "$2"
}

# 构造 payload 并跑 mention-check.sh，输出其 stdout
run_mention_check() { # $1=command $2=task_id [$3=script 覆盖（M 组变异副本用）]
    local SCRIPT="${3:-$MENTION_CHECK}"
    printf '%s' "$(make_payload "$1" "$2")" | PROJECT_ROOT="$REPO_ROOT" MULTICA_AGENT_NAME=Bachi MULTICA_TASK_ID="$2" "$SCRIPT"
}

is_deny() { # $1=hook stdout — 输出 permissionDecision=deny 协议时 exit 0
    printf '%s' "$1" | node -e "
      let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{
        try{const r=JSON.parse(d);process.exit(r.hookSpecificOutput?.permissionDecision==='deny'?0:1)}
        catch(e){process.exit(1)}
      });"
}

# M 组定向变异：$1=needle $2=replacement $3=dst — 锚点不存在或不唯一 exit 3（源漂移护栏）
apply_mutation() {
    node -e "
      const fs = require('fs');
      const [src, dst, needle, replacement] = process.argv.slice(1);
      const t = fs.readFileSync(src, 'utf8');
      const i = t.indexOf(needle);
      if (i < 0 || t.indexOf(needle, i + 1) >= 0) { process.exit(3); }
      fs.writeFileSync(dst, t.slice(0, i) + replacement + t.slice(i + needle.length));
      fs.chmodSync(dst, 0o755);
    " "$MENTION_CHECK" "$3" "$1" "$2"
}

separator "A. mention-check.sh: compound comment add && rm => whole-command deny"

BODY="$TMP/body-no-mention.md"
printf 'plain body without mention\n' > "$BODY"
MARKER="$TMP/marker-a"
touch "$MARKER"
RAW="multica issue comment add X --content-file $BODY --output table && rm $MARKER"
OUT=$(run_mention_check "$RAW" "see1428a$$")
if is_deny "$OUT"; then
    pass "A1 compound comment add && rm denied as a whole"
else
    fail "A1 expected whole-command deny; got: $(echo "$OUT" | head -c 200)"
fi
if [ -f "$MARKER" ]; then
    pass "A2 trailing rm target untouched by hook chain"
else
    fail "A2 marker deleted — hook chain must never execute command fragments"
fi

separator "B. deny coverage across compound separators (&& / ; / newline)"

for SEP_LABEL in "amp:&&" "semi:;" ; do
    SEP="${SEP_LABEL#*:}"
    RAW="multica issue comment add X --content-file $BODY --output table ${SEP} rm $MARKER"
    OUT=$(run_mention_check "$RAW" "see1428b$$-${SEP_LABEL%%:*}")
    if is_deny "$OUT"; then
        pass "B(${SEP_LABEL%%:*}) deny fires for '${SEP}'-joined compound"
    else
        fail "B(${SEP_LABEL%%:*}) expected deny for '${SEP}'-joined compound"
    fi
done

RAW="$(printf 'multica issue comment add X --content-file %s --output table\nrm %s' "$BODY" "$MARKER")"
OUT=$(run_mention_check "$RAW" "see1428b-nl")
if is_deny "$OUT"; then
    pass "B(nl) deny fires for newline-joined compound"
else
    fail "B(nl) expected deny for newline-joined compound"
fi

separator "B2. fallback segment-scan boundaries (cd-prefix / bash -c / pipe)"

# 行首样本由快速路径命中（见 B 组）；cd 前缀 / bash -c / 管道后只能由
# SEE-1092 fallback（splitShellCommands + extractCommands）命中——否则漏放。
RAW="cd '$REPO_ROOT' && multica issue comment add X --content-file $BODY --output table && rm $MARKER"
OUT=$(run_mention_check "$RAW" "see1428b2-cd$$")
if is_deny "$OUT"; then
    pass "B2(cd) deny fires for cd-prefixed compound (fallback path)"
else
    fail "B2(cd) expected deny for cd-prefixed compound; got: $(echo "$OUT" | head -c 200)"
fi

RAW="bash -c \"cd '$REPO_ROOT' && multica issue comment add X --content-file $BODY --output table && rm $MARKER\""
OUT=$(run_mention_check "$RAW" "see1428b2-bashc$$")
if is_deny "$OUT"; then
    pass "B2(bashc) deny fires for nested bash -c compound"
else
    fail "B2(bashc) expected deny for nested bash -c compound; got: $(echo "$OUT" | head -c 200)"
fi

RAW="echo prep | multica issue comment add X --content-file $BODY --output table && rm $MARKER"
OUT=$(run_mention_check "$RAW" "see1428b2-pipe$$")
if is_deny "$OUT"; then
    pass "B2(pipe) deny fires for comment add after pipe"
else
    fail "B2(pipe) expected deny for comment add after pipe; got: $(echo "$OUT" | head -c 200)"
fi

separator "C. engine mention-confirm-check: config deny covers compound with mention"

if [ -f "$ENGINE" ] && [ -f "$RULES" ]; then
    BODY_M="$TMP/body-mention.md"
    printf 'body [@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5) done\n' > "$BODY_M"
    MARKER2="$TMP/marker-c"
    touch "$MARKER2"
    RAW="cd '$REPO_ROOT' && multica issue comment add X --content-file $BODY_M --output table && rm $MARKER2"
    PAYLOAD=$(make_payload "$RAW" "see1428c")
    OUT=$(printf '%s' "$PAYLOAD" | PROJECT_ROOT="$REPO_ROOT" MULTICA_AGENT_NAME=Bachi \
        MULTICA_TASK_ID="see1428c$$" HOOK_RUN_SCOPE_ID="see1428c$$" HOOK_ISSUE_ID="" \
        HOOK_STATE_DIR="$TMP/state" UNIFIED_RULES_FILE="$RULES" HOOK_FIRE_LOG="$TMP/fire.log" node "$ENGINE")
    if is_deny "$OUT"; then
        pass "C1 engine deny covers cd-prefixed compound with mention"
    else
        fail "C1 expected engine deny; got: $(echo "$OUT" | head -c 200)"
    fi
    if [ -f "$MARKER2" ]; then
        pass "C2 engine deny path leaves rm target untouched"
    else
        fail "C2 marker deleted — engine must never execute command fragments"
    fi
else
    fail "C engine/rule artifacts missing at $ENGINE / $RULES (dev-forge claude-hooks layout expected)"
fi

separator "D. allow-case guard: plain compound WITHOUT comment add is not denied"

MARKER3="$TMP/marker-d"
touch "$MARKER3"
RAW="echo prep && rm $MARKER3"
OUT=$(run_mention_check "$RAW" "see1428d$$")
if is_deny "$OUT"; then
    fail "D1 unexpected deny for compound without comment add"
else
    pass "D1 non-comment compound passes mention-check (no over-blocking)"
fi

# D2 引号字面量阴性控制：短语只出现在字符串字面量中不是真实调用（quote-aware
# 分段语义，SEE-1092）——catch-all 式匹配变异（M 组 M3）不由 D1 中的短语无关
# 命令唯一杀灭，此样本把「过度拦截」判别器钉在引号边界上。
RAW="echo \"multica issue comment add X mentioned in docs\" && rm $MARKER3"
OUT=$(run_mention_check "$RAW" "see1428d2$$")
if is_deny "$OUT"; then
    fail "D2 unexpected deny: phrase inside quoted string literal is not a real invocation"
else
    pass "D2 quoted-string phrase passes mention-check (quote-aware, no over-blocking)"
fi

separator "E. CONTENT_FILE_UNREADABLE: user-visible 'No such file' mechanism pinned"

# §SPEC-001 结论固化的另一半：拦截后重发时正文文件已不存在 → 硬错误整条 deny
# （mention-check.sh:337-358 语义）——重发不来「半放行」，rm 照样不执行。
RAW="multica issue comment add X --content-file $TMP/no-such-file-e.md --output table && rm $MARKER"
OUT=$(run_mention_check "$RAW" "see1428e$$")
if is_deny "$OUT"; then
    pass "E1 unreadable --content-file in compound denied as a whole (hard error)"
else
    fail "E1 expected hard-error deny for unreadable content file in compound; got: $(echo "$OUT" | head -c 200)"
fi
if [ -f "$MARKER" ]; then
    pass "E2 rm target untouched even on hard-error deny path"
else
    fail "E2 marker deleted on CONTENT_FILE_UNREADABLE deny path — must never execute fragments"
fi

separator "M. mutation kill: targeted mutants of mention-check.sh copy (drift-guarded)"

# 每个变异体由一台判据杀灭（killed => 该变异使套件变红 = 判据真实有效）。
# 锚点当前经 uniq 校验；若上游改写导致锚点缺失/不唯一，apply_mutation exit 3
# → 显式 FAIL（源漂移需归因，不静默跳过）。

MUT="$TMP/mention-check-m1.sh"
if apply_mutation "permissionDecision: 'deny'," "permissionDecision: 'allow'," "$MUT"; then
    OUT=$(run_mention_check "cd '$REPO_ROOT' && multica issue comment add X --content-file $BODY --output table && rm $MARKER" "see1428m1$$" "$MUT")
    if [ -z "$OUT" ]; then
        fail "M1 mutant produced no output — execution failure must not count as killed"
    elif is_deny "$OUT"; then
        fail "M1 mutant(deny→allow) SURVIVED: deny assertion lost discriminating power"
    else
        pass "M1 mutant(deny→allow) killed: whole-command deny assertion goes red"
    fi
else
    fail "M1 mutation not applicable — mention-check.sh anchor drifted, re-verify"
fi

MUT="$TMP/mention-check-m2.sh"
if apply_mutation "function isRealCommentAdd(rawCmd) {" "function isRealCommentAdd(rawCmd) { return false;" "$MUT"; then
    OUT=$(run_mention_check "cd '$REPO_ROOT' && multica issue comment add X --content-file $BODY --output table && rm $MARKER" "see1428m2$$" "$MUT")
    if [ -z "$OUT" ]; then
        fail "M2 mutant produced no output — execution failure must not count as killed"
    elif is_deny "$OUT"; then
        fail "M2 mutant(detection-neutered) SURVIVED: cd-prefixed case lacks discriminating power"
    else
        pass "M2 mutant(detection-neutered) killed: fallback-path assertion goes red"
    fi
else
    fail "M2 mutation not applicable — mention-check.sh anchor drifted, re-verify"
fi

MUT="$TMP/mention-check-m3.sh"
if apply_mutation "function isRealCommentAdd(rawCmd) {" "function isRealCommentAdd(rawCmd) { return true;" "$MUT"; then
    OUT=$(run_mention_check "echo \"multica issue comment add X mentioned in docs\" && rm $MARKER3" "see1428m3$$" "$MUT")
    if [ -z "$OUT" ]; then
        fail "M3 mutant produced no output — execution failure must not count as killed"
    elif is_deny "$OUT"; then
        pass "M3 mutant(catch-all over-block) killed: D2 quoted-literal negative control goes red on over-block"
    else
        fail "M3 mutant(catch-all over-block) SURVIVED: negative controls lack discriminating power"
    fi
else
    fail "M3 mutation not applicable — mention-check.sh anchor drifted, re-verify"
fi

separator "Summary"
echo "Total: $((PASS + FAIL)) | PASS: $PASS | FAIL: $FAIL"
if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
    exit 0
else
    echo -e "${RED}$FAIL TEST(S) FAILED${NC}"
    exit 1
fi
