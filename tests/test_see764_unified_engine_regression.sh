#!/bin/bash
# SEE-764 Regression Test Suite: Unified Rule Engine (v2)
# testee: .claude/hooks/unified/unified-hook.sh (v2 unified engine, SEE-1330 S5 re-target)
#
# S5 再定向说明 (SEE-1330 S5 目标 4, 取代 v1 pre-comment-skill-check.sh targetee):
#  - testee 协议: payload 注入 hook_event_name（含 tool_response → PostToolUse，否则
#    PreToolUse，等价 v1 D5 事件检测）；每 run 生成新 UUID MULTICA_TASK_ID 并显式
#    HOOK_SCOPE_ID=$MULTICA_TASK_ID，防 session 级环境泄漏造成 sentinel 跨用例污染。
#  - v1→v2 输出协议: block → permissionDecision:'deny'，reason 前缀 '[unified-hook] ' +
#    规则 block_message（v1 为 '[skill-check] '）；remind → additionalContext = 原始
#    message（无 '[skill-check]' 前缀）；无命中/透传 → stdout == stdin 逐字节 + exit 0。
#  - sentinel 键: v2 为 /tmp/.hook-fired-<rule>-<scope>（v1 为 /tmp/skill-check-*），
#    规则名 sanitization 规则不变（非 [a-zA-Z0-9_-] → '-'）。
#  - mem-search-context 规则已从规则集退役（SEE-1330 S4 漂移）：原 mem-search-context
#    "无 agents 限定 remind 规则对所有 agent per-run 一次触发"的用例语义迁移到
#    recall-reminder（无 agents 限定、无 when、one_shot run、PreToolUse）等价钉住。
#  - doc-reminder 迁移后 enabled=false → disabled 规则永不触发（引擎在 when 求值前即
#    continue）；v1 的 PostToolUse-only remind 断言按 "不触发" 语义收紧。
#  - 规则集 14 条 = 6 deny（4 agent skill-check + mention-confirm-check +
#    child-issue-guard）+ 7 context（4 agent reminder + recall-reminder +
#    grepai-search-reminder + tscn-tres-guard）+ 1 disabled（doc-reminder），enabled=13。
#  - used_skill 拓扑（v1 D5 漂移）：v2 引擎 used_skill 真实执行 `multica issue
#    run-messages <uuid> --output json`。本套件注入 multica shim：无 MOCK_TRANSCRIPT
#    时返回 `[]`（transcriptAvailable=true、无技能使用 → not(any used_skill)=true →
#    block 拦截；即 comment_add 未用技能 = 正确 deny，与 v1 "transcript 不可用则
#    skip" 语义不同，属 SEE-1330 P0 设计变更）；MOCK_TRANSCRIPT 指向含 Skill
#    tool_use 记录的 JSON 数组文件时 → not(any)=false → 放行（无 block）。
#
# Related Issue: SEE-764 (suite), SEE-1330 S5 (re-target)
# Test Type: Regression + E2E
# Author: Revy (QA Agent)

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
RESULTS=()

pass() {
    echo -e "  ${GREEN}[PASS]${NC} $1"
    PASS=$((PASS + 1))
    RESULTS+=("PASS|$1")
}

fail() {
    echo -e "  ${RED}[FAIL]${NC} $1"
    FAIL=$((FAIL + 1))
    RESULTS+=("FAIL|$1")
}

separator() {
    echo ""
    echo -e "${CYAN}--- $1 ---${NC}"
}

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SCRIPT="$PROJECT_ROOT/hooks/unified/unified-hook.sh"
RULES_FILE="$PROJECT_ROOT/hooks/unified/rules-v2.json"
# SEE-1381 §SPEC-014 对齐现行实现（SEE-1333 D4 终态）：skill-check deny ×4 与
# agent remind ×4 的 one_shot 窗口 = [MULTICA_AGENT_NAME, HOOK_ISSUE_ID]；引擎对
# 空窗口变量 fail-open skip。生产环境平台注入 MULTICA_ISSUE_ID——套件等价注入。
ISSUE_ID="see764-regression-issue"
# 引擎 one_shot 哨兵落点 = HOOK_STATE_DIR || ~/.claude/hooks/unified/state/。
# 套件必须隔离到临时 state：否则哨兵写入生产 state 且 cleanup 只扫 /tmp 永远
# 清不掉，跨 run 永久压制同窗口规则（SEE-1381 §SPEC-012/014 根因）。
STATE_DIR="$(mktemp -d /tmp/see764-state.XXXXXX)"

# multica shim：v2 引擎 used_skill 会执行 `multica issue run-messages <uuid> --output json`。
# 无 MOCK_TRANSCRIPT → 返回 `[]`（transcript 可用、无技能记录）；有 MOCK_TRANSCRIPT →
# 返回指定 JSON 数组文件内容。
MOCK_SHIM_DIR="$(mktemp -d /tmp/see764-shim.XXXXXX)"
cat > "$MOCK_SHIM_DIR/multica" <<'SHIMEOF'
#!/bin/bash
if [ -n "$MOCK_TRANSCRIPT" ] && [ -f "$MOCK_TRANSCRIPT" ]; then
    cat "$MOCK_TRANSCRIPT"
else
    echo "[]"
fi
SHIMEOF

chmod +x "$MOCK_SHIM_DIR/multica"

# mock transcript：run 中已使用 Skill(revy-testing)（P0-1b pass 分支用）
TRANSCRIPT_SKILL_REVY="$(mktemp /tmp/see764-transcript-revy.XXXXXX)"
printf '%s' '[{"type":"tool_use","tool":"Skill","input":{"skill":"revy-testing"}}]' > "$TRANSCRIPT_SKILL_REVY"

pick_transcript() {
    case "$1" in
        shim-revy) printf '%s' "$TRANSCRIPT_SKILL_REVY" ;;
        *) printf '%s' "$TRANSCRIPT_SKILL_USED" ;;
    esac
}

# mock transcript：run 中已使用 Skill(taskflow) → not(any used_skill)=false
TRANSCRIPT_SKILL_USED="$(mktemp /tmp/see764-transcript.XXXXXX)"
printf '%s' '[{"type":"tool_use","tool":"Skill","input":{"skill":"taskflow"}}]' > "$TRANSCRIPT_SKILL_USED"

# Cleanup sentinels between tests（v1 skill-check-* + v2 .hook-fired-* 双清理）
cleanup_sentinels() {
    rm -f /tmp/skill-check-* 2>/dev/null
    rm -f /tmp/.hook-fired-* 2>/dev/null
    rm -f "$STATE_DIR"/.hook-fired-* 2>/dev/null
}

new_task_id() {
    (uuidgen 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())') | tr 'A-F' 'a-f'
}

# v2 protocol run wrapper:
#  - 注入 hook_event_name（payload 含 tool_response → PostToolUse，否则 PreToolUse）
#  - 每 run 新 UUID task id + 显式 HOOK_SCOPE_ID（防 session 泄漏污染 sentinel）
#  - PATH 前置 multica shim；UNIFIED_RULES_FILE 指向 rules-v2.json
run_hook() {
    local INPUT="$1"
    local AGENT_NAME="${2:-Atlas}"
    local SHIM="${3:+1}"
    local TASK_ID
    TASK_ID="$(new_task_id)"

    cleanup_sentinels

    local STDOUT_FILE STDERR_FILE EVENT INJECTED
    STDOUT_FILE=$(mktemp /tmp/see764-stdout.XXXXXX)
    STDERR_FILE=$(mktemp /tmp/see764-stderr.XXXXXX)

    EVENT="PreToolUse"
    if echo "$INPUT" | grep -q '"tool_response"'; then
        EVENT="PostToolUse"
    fi
    # 注入 hook_event_name；非 JSON 载荷原样透传（供 malformed 用例使用）
    INJECTED=$(printf '%s' "$INPUT" | node -e '
let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{
  const e=process.argv[1];let p;try{p=JSON.parse(d)}catch(err){process.stdout.write(d);return}
  p.hook_event_name=e;process.stdout.write(JSON.stringify(p));
});' "$EVENT")

    if [ -n "$SHIM" ]; then
        printf '%s' "$INJECTED" | \
            env PATH="$MOCK_SHIM_DIR:$PATH" MOCK_TRANSCRIPT="$(pick_transcript "$3")" \
                MULTICA_AGENT_NAME="$AGENT_NAME" MULTICA_TASK_ID="$TASK_ID" \
                MULTICA_ISSUE_ID="$ISSUE_ID" HOOK_STATE_DIR="$STATE_DIR" \
                HOOK_SCOPE_ID="$TASK_ID" PWD="$PROJECT_ROOT" PROJECT_ROOT="$PROJECT_ROOT" \
                UNIFIED_RULES_FILE="$RULES_FILE" bash "$HOOK_SCRIPT" > "$STDOUT_FILE" 2> "$STDERR_FILE"
    else
        printf '%s' "$INJECTED" | \
            env PATH="$MOCK_SHIM_DIR:$PATH" \
                MULTICA_AGENT_NAME="$AGENT_NAME" MULTICA_TASK_ID="$TASK_ID" \
                MULTICA_ISSUE_ID="$ISSUE_ID" HOOK_STATE_DIR="$STATE_DIR" \
                HOOK_SCOPE_ID="$TASK_ID" PWD="$PROJECT_ROOT" PROJECT_ROOT="$PROJECT_ROOT" \
                UNIFIED_RULES_FILE="$RULES_FILE" bash "$HOOK_SCRIPT" > "$STDOUT_FILE" 2> "$STDERR_FILE"
    fi
    local EXIT_CODE=$?

    HOOK_STDOUT=$(cat "$STDOUT_FILE")
    HOOK_STDERR=$(cat "$STDERR_FILE")
    HOOK_EXIT=$EXIT_CODE
    HOOK_PAYLOAD="$INJECTED"

    rm -f "$STDOUT_FILE" "$STDERR_FILE"
}

# Run without cleaning sentinels (for sentinel lifecycle test)
run_hook_preserve_sentinel() {
    local INPUT="$1"
    local AGENT_NAME="${2:-Atlas}"
    local TASK_ID="$3"
    local WIN_ISSUE="${4:-$ISSUE_ID}"

    local STDOUT_FILE INJECTED
    STDOUT_FILE=$(mktemp /tmp/see764-stdout.XXXXXX)

    INJECTED=$(printf '%s' "$INPUT" | node -e '
let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{
  p=JSON.parse(d);p.hook_event_name="PreToolUse";
  process.stdout.write(JSON.stringify(p));
});')

    printf '%s' "$INJECTED" | \
        env PATH="$MOCK_SHIM_DIR:$PATH" \
            MULTICA_AGENT_NAME="$AGENT_NAME" MULTICA_TASK_ID="$TASK_ID" \
            MULTICA_ISSUE_ID="$WIN_ISSUE" HOOK_STATE_DIR="$STATE_DIR" \
            HOOK_SCOPE_ID="$TASK_ID" PWD="$PROJECT_ROOT" PROJECT_ROOT="$PROJECT_ROOT" \
            UNIFIED_RULES_FILE="$RULES_FILE" bash "$HOOK_SCRIPT" > "$STDOUT_FILE" 2>/dev/null
    HOOK_EXIT=$?
    HOOK_STDOUT=$(cat "$STDOUT_FILE")
    HOOK_PAYLOAD="$INJECTED"
    rm -f "$STDOUT_FILE"
}

assert_blocks() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"permissionDecision"."deny"'; then
        pass "$label — BLOCKED"
    else
        fail "$label — NOT blocked. stdout: '${HOOK_STDOUT:0:300}'"
    fi
}

# block reason 前缀断言：v2 = '[unified-hook] ' + block_message
assert_block_prefix() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"permissionDecisionReason":"\[unified-hook\] '; then
        pass "$label — deny reason prefixed '[unified-hook] '"
    else
        fail "$label — deny reason missing '[unified-hook] ' prefix. stdout: '${HOOK_STDOUT:0:300}'"
    fi
}

assert_block_message() {
    local label="$1"
    local needle="$2"
    if echo "$HOOK_STDOUT" | grep -q "$needle"; then
        pass "$label — deny reason contains '$needle'"
    else
        fail "$label — deny reason missing '$needle'. stdout: '${HOOK_STDOUT:0:400}'"
    fi
}

assert_allows() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"permissionDecision"."deny"'; then
        fail "$label — incorrectly BLOCKED. stdout: '${HOOK_STDOUT:0:300}'"
    else
        pass "$label — ALLOWED"
    fi
}

assert_remind() {
    local label="$1"
    local expected_msg="$2"
    if echo "$HOOK_STDOUT" | grep -q "additionalContext" && echo "$HOOK_STDOUT" | grep -q "$expected_msg"; then
        pass "$label — REMIND injected"
    else
        fail "$label — REMIND missing. stdout: '${HOOK_STDOUT:0:300}'"
    fi
}

assert_remind_not_deny() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"permissionDecision"."deny"'; then
        fail "$label — remind incorrectly denied tool"
    else
        pass "$label — remind did not deny"
    fi
}

assert_no_output() {
    local label="$1"
    if [ -z "$HOOK_STDOUT" ]; then
        pass "$label — no engine output (passthrough)"
    else
        fail "$label — unexpected output. stdout: '${HOOK_STDOUT:0:200}'"
    fi
}

assert_passthrough() {
    local label="$1"
    local expected="$2"
    if [ "$HOOK_STDOUT" = "$expected" ]; then
        pass "$label — passthrough preserves input bytes"
    else
        fail "$label — passthrough corrupted. Expected first 100: '${expected:0:100}', Got: '${HOOK_STDOUT:0:100}'"
    fi
}

assert_exit_0() {
    local label="$1"
    if [ "$HOOK_EXIT" -eq 0 ]; then
        pass "$label — exit code 0"
    else
        fail "$label — exit code $HOOK_EXIT, expected 0"
    fi
}

echo "============================================================"
echo "  SEE-764 Regression: Unified Rule Engine (v2)"
echo "  Date: $(date -Iseconds)"
echo "  Author: Revy (QA Agent)"
echo "  Branch: $(git branch --show-current 2>/dev/null || echo none)"
echo "============================================================"

#####################################################################
# Prerequisite Checks
#####################################################################
separator "Prerequisites"

if [ -f "$HOOK_SCRIPT" ]; then
    pass "unified-hook.sh exists"
else
    fail "unified-hook.sh MISSING"
    exit 1
fi

if [ -f "$RULES_FILE" ]; then
    pass "rules-v2.json exists"
else
    fail "rules-v2.json MISSING"
    exit 1
fi

# Verify old scripts are deleted
OLD_SCRIPTS=(
    ".claude/hooks/child-issue-guard.sh"
    ".claude/hooks/doc-reminder.sh"
    ".claude/hooks/atlas-bash-skill-reminder.sh"
    ".claude/hooks/archi-doc-edit-reminder.sh"
    ".claude/hooks/revy-testing-reminder.sh"
    ".claude/hooks/mem-search-context.sh"
)
for old in "${OLD_SCRIPTS[@]}"; do
    if [ -f "$PROJECT_ROOT/$old" ]; then
        fail "Old script still exists: $old"
    else
        pass "Old script deleted: $old"
    fi
done

# Verify rules JSON is valid
if node -e "JSON.parse(require('fs').readFileSync('$RULES_FILE','utf8'))" 2>/dev/null; then
    pass "rules-v2.json is valid JSON"
else
    fail "rules-v2.json is INVALID JSON"
fi

# Verify 13 rules（SEE-1388 SPEC-004：doc-reminder 死规则物理删除 → v2: 6 deny + 7 context + 0 disabled）
RULE_COUNT=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$RULES_FILE','utf8')).rules.length)")
if [ "$RULE_COUNT" -eq 13 ]; then
    pass "Rule count: $RULE_COUNT (expected 13)"
else
    fail "Rule count: $RULE_COUNT (expected 13)"
fi

# Verify 6 deny rules (4 agent skill-check + mention-confirm-check + child-issue-guard)
BLOCK_COUNT=$(node -e "const r=JSON.parse(require('fs').readFileSync('$RULES_FILE','utf8')).rules; console.log(r.filter(x=>Array.isArray(x.action)&&x.action.some(a=>a&&a.op==='deny')).length)")
if [ "$BLOCK_COUNT" -eq 6 ]; then
    pass "Deny rules: $BLOCK_COUNT (expected 6)"
else
    fail "Deny rules: $BLOCK_COUNT (expected 6)"
fi

# Verify 7 context rules (4 agent reminders + recall-reminder + grepai + tscn-tres-guard)
REMIND_COUNT=$(node -e "const r=JSON.parse(require('fs').readFileSync('$RULES_FILE','utf8')).rules; console.log(r.filter(x=>x.enabled!==false&&Array.isArray(x.action)&&x.action.some(a=>a&&a.op==='context')).length)")
if [ "$REMIND_COUNT" -eq 7 ]; then
    pass "Context rules: $REMIND_COUNT (expected 7)"
else
    fail "Context rules: $REMIND_COUNT (expected 7)"
fi

# SEE-1388 SPEC-004（fingerprint b9361f0c8695）：doc-reminder 死规则已物理删除，
# disabled 规则归零；且 rules-v2.json 不得再含 doc-reminder。
DISABLED=$(node -e "const r=JSON.parse(require('fs').readFileSync('$RULES_FILE','utf8')).rules; const d=r.filter(x=>x.enabled===false).map(x=>x.name); console.log(d.length===0?'ok':'bad:'+d.join(','))" 2>/dev/null)
if [ "$DISABLED" = "ok" ]; then
    pass "Disabled rules: 0（doc-reminder 已删除，无 enabled=false 死规则）"
else
    fail "Disabled rules unexpected: $DISABLED"
fi
if node -e "const r=JSON.parse(require('fs').readFileSync('$RULES_FILE','utf8')).rules; process.exit(r.some(x=>x.name==='doc-reminder')?0:1)"; then
    fail "doc-reminder still present in rules-v2.json（SPEC-004 要求物理删除）"
else
    pass "doc-reminder absent from rules-v2.json（SPEC-004）"
fi

# Verify mem-search-context is fully retired from v2 ruleset
if node -e "const r=JSON.parse(require('fs').readFileSync('$RULES_FILE','utf8')).rules; process.stdout.write(String(r.some(x=>String(x.name).includes('mem-search'))))" | grep -q true; then
    fail "mem-search-context still present in rules-v2.json (should be retired)"
else
    pass "mem-search-context retired from rules-v2.json"
fi

# Verify no curly quotes in JSON
if grep -qP '[\x{201C}\x{201D}]' "$RULES_FILE"; then
    fail "Rules JSON contains curly quotes (U+201C/U+201D)"
else
    pass "Rules JSON has no curly quotes"
fi

#####################################################################
# P0-1: agent skill-check block rules — used_skill topology (v2)
# v2: used_skill 依赖 multica run-messages transcript。无 MOCK_TRANSCRIPT →
# transcript 可用且无技能使用 → not(any used_skill)=true → comment_add 正确 deny
#（v1 语义为 "transcript 不可用则 skip"，S5 漂移说明见文件头）。
# MOCK_TRANSCRIPT（含 Skill 使用记录）→ not(any)=false → 放行分支。
#####################################################################
separator "P0-1: agent skill-check — used_skill topology (v2)"

# atlas-workflow-skill-check: Atlas + comment_add + not(used taskflow/task-assign/code-review)
run_hook '{"tool_input":{"command":"multica issue comment add test-id --content-stdin"}}' "Atlas"
assert_blocks "P0-1a: Atlas comment_add, transcript 无技能使用 → BLOCKED"
assert_block_prefix "P0-1a: deny reason '[unified-hook] ' prefix"
assert_block_message "P0-1a: deny message mentions taskflow" "taskflow"
assert_exit_0 "P0-1a: exit 0"

# pass branch: transcript 含 Skill(taskflow) 使用记录 → 不拦截
run_hook '{"tool_input":{"command":"multica issue comment add test-id --content-stdin"}}' "Atlas" "shim"
assert_allows "P0-1a-pass: Atlas comment_add with Skill(taskflow) used → ALLOWED"
assert_exit_0 "P0-1a-pass: exit 0"

# revy-testing-skill-check: Revy + not(used revy-testing)
run_hook '{"tool_input":{"command":"multica issue comment add test-id --content-stdin"}}' "Revy"
assert_blocks "P0-1b: Revy comment_add, transcript 无技能使用 → BLOCKED"
assert_block_message "P0-1b: deny message mentions revy-testing" "revy-testing"
assert_exit_0 "P0-1b: exit 0"

# pass branch for Revy: skill used → 放行
run_hook '{"tool_input":{"command":"multica issue comment add test-id --content-stdin"}}' "Revy" "shim-revy"
assert_allows "P0-1b-pass: Revy comment_add with Skill used → ALLOWED"
assert_exit_0 "P0-1b-pass: exit 0"

# archi-doc-edit-skill-check: Archi + not(used doc-edit 系列)
run_hook '{"tool_input":{"command":"multica issue comment add test-id --content-stdin"}}' "Archi"
assert_blocks "P0-1c: Archi comment_add, transcript 无技能使用 → BLOCKED"
assert_block_message "P0-1c: deny message mentions doc-edit" "doc-edit"
assert_block_message "P0-1c: rule 作用域正确（不误报 revy-testing）" "doc-edit"
assert_exit_0 "P0-1c: exit 0"

# 逐 agent 隔离：每 agent block message 互不串扰（Bachi → bachi-coding 规则）
run_hook '{"tool_input":{"command":"multica issue comment add test-id --content-stdin"}}' "Bachi"
assert_blocks "P0-1d: Bachi comment_add matched by its own bachi-coding-skill-check → BLOCKED"
assert_block_message "P0-1d: deny message mentions bachi-coding (rule-scoped, not other agents)" "/bachi-coding"

# 非 agent 目标（unknown agent）不受任何 agent-specific block 规则影响
run_hook '{"tool_input":{"command":"multica issue comment add test-id --content-stdin"}}' "UnknownAgent"
assert_allows "P0-1e: unknown agent — no agent-specific block rule matches → ALLOWED"
assert_exit_0 "P0-1e: exit 0"

#####################################################################
# P0-2: child-issue-guard migrated rule (command_matches)
#####################################################################
separator "P0-2: child-issue-guard — command_matches (migrated)"

# Block: create with --parent value
run_hook '{"tool_input":{"command":"multica issue create --parent abc123 --title \"test\""}}'
assert_blocks "P0-2a: create --parent abc123 → BLOCKED"
assert_block_prefix "P0-2a: deny reason '[unified-hook] ' prefix"
assert_block_message "P0-2a: deny message is child-issue-guard" "child-issue-guard"
assert_exit_0 "P0-2a: exit 0"

# Block: update with --parent value
run_hook '{"tool_input":{"command":"multica issue update 420c414c --parent abc123"}}'
assert_blocks "P0-2b: update --parent abc123 → BLOCKED"
assert_exit_0 "P0-2b: exit 0"

# Block: create with --parent=value
run_hook '{"tool_input":{"command":"multica issue create --parent=abc123 --title \"test\""}}'
assert_blocks "P0-2c: create --parent=abc123 → BLOCKED"
assert_exit_0 "P0-2c: exit 0"

# Allow: no --parent
INPUT='{"tool_input":{"command":"multica issue create --title \"normal\""}}'
run_hook "$INPUT"
assert_allows "P0-2d: create without --parent → ALLOWED"
assert_exit_0 "P0-2d: exit 0"

# Allow: empty --parent
INPUT='{"tool_input":{"command":"multica issue create --parent \"\" --title \"test\""}}'
run_hook "$INPUT"
assert_allows "P0-2e: create --parent empty string → ALLOWED"
assert_exit_0 "P0-2e: exit 0"

# Block: full UUID parent
run_hook '{"tool_input":{"command":"multica issue create --parent 23bee88a-76b7-4aad-97cb-a829f093e6f0 --title \"[SEE-736]\""}}'
assert_blocks "P0-2f: create --parent UUID → BLOCKED"
assert_exit_0 "P0-2f: exit 0"

# Allow: other multica subcommands
INPUT='{"tool_input":{"command":"multica issue get 420c414c"}}'
run_hook "$INPUT"
assert_allows "P0-2g: issue get → ALLOWED"
assert_exit_0 "P0-2g: exit 0"

INPUT='{"tool_input":{"command":"multica issue comment add 420c414c --content-stdin"}}'
run_hook "$INPUT" "Bachi"
assert_blocks "P0-2h: issue comment add (Bachi) → blocked by bachi-coding-skill-check (comment_add)"
assert_block_message "P0-2h: deny message mentions bachi-coding (rule scoping)" "/bachi-coding"
assert_exit_0 "P0-2h: exit 0"

# Allow: non-multica command
INPUT='{"tool_input":{"command":"git push origin main"}}'
run_hook "$INPUT"
assert_allows "P0-2i: git push → ALLOWED"
assert_exit_0 "P0-2i: exit 0"

#####################################################################
# P0-3: command_matches — heredoc and nested commands
#####################################################################
separator "P0-3: command_matches — heredoc and nested extraction"

# Heredoc piped with --parent
run_hook '{"tool_input":{"command":"cat <<'"'"'DESCRIPTION'"'"' | multica issue create --title \"test\" --description-stdin --parent abc123\nDESCRIPTION"}}'
assert_blocks "P0-3a: heredoc piped create with --parent → BLOCKED"
assert_exit_0 "P0-3a: exit 0"

# Heredoc body contains --parent text (should NOT block — heredoc body stripped)
INPUT='{"tool_input":{"command":"cat <<'"'"'EOF'"'"' | multica issue create --title \"test\" --description-stdin\nThis explains --parent usage.\nEOF"}}'
run_hook "$INPUT"
assert_allows "P0-3b: heredoc body with --parent text → ALLOWED"
assert_exit_0 "P0-3b: exit 0"

# Nested bash -c with --parent
run_hook '{"tool_input":{"command":"bash -c \"multica issue create --parent abc123 --title test\""}}'
assert_blocks "P0-3c: bash -c nested create --parent → BLOCKED"
assert_exit_0 "P0-3c: exit 0"

# Nested sh -c with --parent
run_hook '{"tool_input":{"command":"sh -c \"multica issue update id --parent abc123\""}}'
assert_blocks "P0-3d: sh -c nested update --parent → BLOCKED"
assert_exit_0 "P0-3d: exit 0"

# Compound command with nested --parent
run_hook '{"tool_input":{"command":"echo hello && bash -c \"multica issue create --parent abc123\""}}'
assert_blocks "P0-3e: compound with nested --parent → BLOCKED"
assert_exit_0 "P0-3e: exit 0"

#####################################################################
# P0-6: Block + Remind coexistence (D12)
#####################################################################
separator "P0-6: Block + remind coexist"

# child-issue-guard deny for Atlas; Atlas one-shot reminders fire in same run while unused-skill block is irrelevant → deny is terminal, reminders appended into deny reason
run_hook '{"tool_input":{"command":"multica issue create --parent abc123 --title \"test\""}}' "Atlas"
assert_blocks "P0-6a: block + remind coexist — still blocks"
assert_block_prefix "P0-6a: deny reason '[unified-hook] ' prefix"
assert_block_message "P0-6a: deny message is child-issue-guard" "child-issue-guard"
assert_block_message "P0-6a: reminder context appended into deny reason" "atlas-bash-skill-reminder"
if echo "$HOOK_STDOUT" | grep -q "hookSpecificOutput"; then
    pass "P0-6a: hookSpecificOutput present"
else
    fail "P0-6a: hookSpecificOutput missing"
fi
assert_exit_0 "P0-6a: exit 0"

#####################################################################
# P0-7: child-issue-guard migration equivalence
# Replicate key tests from test_child_issue_guard_see747.sh
#####################################################################
separator "P0-7: child-issue-guard migration equivalence"

# G1d-style: full command
run_hook '{"tool_input":{"command":"multica issue create --parent 23bee88a-76b7-4aad-97cb-a829f093e6f0 --title \"[SEE-736] Phase 1\" --priority high --status todo --assignee-id abc --project f0db1de0"}}'
assert_blocks "P0-7a: full Atlas-style command → BLOCKED"

# G4a-style: heredoc piped
run_hook '{"tool_input":{"command":"cat <<'"'"'DESCRIPTION'"'"' | multica issue create --title \"[SEE-736] Phase X\" --description-stdin --priority high --parent 23bee88a-76b7-4aad-97cb-a829f093e6f0 --project f0db1de0\nDESCRIPTION"}}'
assert_blocks "P0-7b: heredoc piped create with --parent → BLOCKED"

# G5a-style: normal create (no parent)
INPUT='{"tool_input":{"command":"multica issue create --title \"normal issue\""}}'
run_hook "$INPUT"
assert_allows "P0-7c: normal create without parent → ALLOWED"

# G6c-style: update with empty parent (clear parent)
INPUT='{"tool_input":{"command":"multica issue update id --parent \"\""}}'
run_hook "$INPUT"
assert_allows "P0-7d: update --parent empty (clear) → ALLOWED"

# G7a-style: --parent in title value (false positive protection)
INPUT='{"tool_input":{"command":"multica issue create --title \"foo --parent\""}}'
run_hook "$INPUT"
assert_allows "P0-7e: --parent inside --title value → ALLOWED"

# G10a-style: heredoc body contains --parent text
INPUT='{"tool_input":{"command":"cat <<'"'"'EOF'"'"' | multica issue create --title \"test\" --description-stdin\nThis doc explains --parent usage.\nEOF"}}'
run_hook "$INPUT"
assert_allows "P0-7f: heredoc body --parent text → ALLOWED"

# G12b-style: multiple spaces
run_hook '{"tool_input":{"command":"multica   issue   create   --parent   abc123"}}'
assert_blocks "P0-7g: multiple spaces → BLOCKED"

# G12d-style: --parent before subcommand
INPUT='{"tool_input":{"command":"multica issue --parent abc123 create"}}'
run_hook "$INPUT"
assert_allows "P0-7h: --parent before subcommand → ALLOWED"

# G12i-style: multica not at start
INPUT='{"tool_input":{"command":"echo multica issue create --parent abc123"}}'
run_hook "$INPUT"
assert_allows "P0-7i: multica not at command start → ALLOWED"

# G11b-style: malformed JSON
MALFORMED='{not valid json}'
run_hook "$MALFORMED"
assert_exit_0 "P0-7j: malformed JSON — exit 0"
assert_passthrough "P0-7j: malformed JSON — passthrough preserves input" "$HOOK_PAYLOAD"

# G11d-style: missing tool_input
run_hook '{"other_field":"value"}'
assert_allows "P0-7k: missing tool_input → ALLOWED"
assert_exit_0 "P0-7k: exit 0"

#####################################################################
# P0-8: mention-confirm-check (v2 new rule)
# content mention regex + one_shot run + deny。used_skill 拓扑隔离:
# MOCK_TRANSCRIPT（已用技能）→ agent skill-check 放行，只剩 mention 规则可观察。
#####################################################################
separator "P0-8: mention-confirm-check"

# 已用技能 + 内容含 [@X](mention://agent/...) → deny（提及自查）
run_hook '{"tool_input":{"command":"multica issue comment add test-id --content \"reply [@Atlas](mention://agent/23354e78-8322-418b-b44d-375287a0650c) hi\""}}' "Atlas" "shim"
assert_blocks "P0-8a: comment_add with @mention (skill used) → BLOCKED by mention-confirm-check"
assert_block_message "P0-8a: deny message mentions mention-self-check wording" "mention"
assert_exit_0 "P0-8a: exit 0"

# 已用技能 + 内容无 mention → 放行（提醒仍可注入，但不得 deny）
run_hook '{"tool_input":{"command":"multica issue comment add test-id --content \"plain reply no mention\""}}' "Atlas" "shim"
assert_remind_not_deny "P0-8b: comment_add without mention (skill used) → not denied"
assert_exit_0 "P0-8b: exit 0"

# --content-stdin（空 body）→ 无 mention → 不触发 mention 规则
run_hook '{"tool_input":{"command":"multica issue comment add test-id --content-stdin"}}' "Atlas" "shim"
assert_remind_not_deny "P0-8c: --content-stdin empty body → no mention deny"
assert_exit_0 "P0-8c: exit 0"

#####################################################################
# P0-4: Remind does not deny tool calls（v2 重写，原 mem-search-context 用例）
#####################################################################
separator "P0-4: Remind rules — no deny (agent reminders + agent-less reminder)"

# Atlas PreToolUse 任意命令 → atlas-bash-skill-reminder（原 mem 部分迁至 recall-reminder）
run_hook '{"tool_input":{"command":"ls -la"}}' "Atlas"
assert_remind_not_deny "P0-4a: Atlas anytime remind — does not deny"
assert_remind "P0-4a" "atlas-bash-skill-reminder"
assert_remind "P0-4a: agent-less reminder also fires" "recall-reminder"
assert_exit_0 "P0-4a: exit 0"

# Revy
run_hook '{"tool_input":{"command":"ls -la"}}' "Revy"
assert_remind_not_deny "P0-4b: Revy anytime remind — does not deny"
assert_remind "P0-4b" "revy-testing-reminder"
assert_exit_0 "P0-4b: exit 0"

# Archi
run_hook '{"tool_input":{"command":"ls -la"}}' "Archi"
assert_remind_not_deny "P0-4c: Archi anytime remind — does not deny"
assert_remind "P0-4c" "archi-doc-edit-reminder"
assert_exit_0 "P0-4c: exit 0"

# Bachi（v1 此处断言 mem-search-context → v2 迁移至 bachi 专属 reminder + recall-reminder）
run_hook '{"tool_input":{"command":"ls -la"}}' "Bachi"
assert_remind_not_deny "P0-4d: Bachi anytime remind — does not deny"
assert_remind "P0-4d" "bachi-coding-reminder"
assert_exit_0 "P0-4d: exit 0"

#####################################################################
# P0-5: Agent-less remind triggers for every agent（recall-reminder 迁移钉）
#####################################################################
separator "P0-5: no-agents remind — fires for all agents"

run_hook '{"tool_input":{"command":"ls -la"}}' "Atlas"
if echo "$HOOK_STDOUT" | grep -q "recall-reminder"; then
    pass "P0-5a: recall-reminder remind fires for Atlas"
else
    fail "P0-5a: recall-reminder NOT firing for Atlas"
fi

run_hook '{"tool_input":{"command":"ls -la"}}' "Bachi"
if echo "$HOOK_STDOUT" | grep -q "recall-reminder"; then
    pass "P0-5b: recall-reminder remind fires for Bachi (match-all agents)"
else
    fail "P0-5b: recall-reminder NOT firing for Bachi"
fi

run_hook '{"tool_input":{"command":"ls -la"}}' "Revy"
if echo "$HOOK_STDOUT" | grep -q "recall-reminder"; then
    pass "P0-5c: recall-reminder remind fires for Revy"
else
    fail "P0-5c: recall-reminder NOT firing for Revy"
fi

run_hook '{"tool_input":{"command":"ls -la"}}' "UnknownAgent"
if echo "$HOOK_STDOUT" | grep -q "recall-reminder"; then
    pass "P0-5d: recall-reminder remind fires for unknown agent (no agents field)"
else
    fail "P0-5d: recall-reminder NOT firing for UnknownAgent"
fi

#####################################################################
# P0-9: grepai-search-reminder + tscn-tres-guard (v2 context rules)
#####################################################################
separator "P0-9: grepai reminder & tscn-tres guard"

# grep 类命令 → grepai 提醒（规则 on=PostToolUse：提醒在工具执行后注入）
run_hook '{"tool_input":{"command":"rg searchpattern src"},"tool_response":{"stdout":"match"}}' "Atlas"
assert_remind "P0-9a: rg command → grepai-search-reminder remind" "grepai-search-reminder"
assert_remind_not_deny "P0-9a: remind does not deny"
assert_exit_0 "P0-9a: exit 0"

# Grep 工具 → grepai 提醒（PostToolUse）
run_hook '{"tool_name":"Grep","tool_input":{"pattern":"foo"},"tool_response":{"stdout":"hit"}}' "Atlas"
assert_remind "P0-9b: Grep tool → grepai-search-reminder remind" "grepai-search-reminder"
assert_exit_0 "P0-9b: exit 0"

# 非 grep 命令 → 无 grepai 提醒（本次 run 内）
run_hook '{"tool_input":{"command":"ls -la"}}' "Revy"
if echo "$HOOK_STDOUT" | grep -q "grepai-search-reminder"; then
    fail "P0-9c: non-grep command → grepai reminder incorrectly fires"
else
    pass "P0-9c: non-grep command → no grepai reminder"
fi

# Write/Edit 工具 + .tscn 文件 → tscn-tres-guard 提醒
run_hook '{"tool_name":"Edit","tool_input":{"file_path":"/proj/scenes/main.tscn","old_string":"a","new_string":"b"}}' "Bachi"
assert_remind "P0-9d: Edit .tscn → tscn-tres-guard remind" "tscn-tres-guard"
assert_remind_not_deny "P0-9d: remind does not deny"
assert_exit_0 "P0-9d: exit 0"

# 非 .tscn/.tres 文件 → 不触发
run_hook '{"tool_name":"Edit","tool_input":{"file_path":"/proj/scripts/player.gd","old_string":"a","new_string":"b"}}' "Bachi"
if echo "$HOOK_STDOUT" | grep -q "tscn-tres-guard"; then
    fail "P0-9e: non-.tscn file → tscn guard incorrectly fires"
else
    pass "P0-9e: non-.tscn file → no tscn guard"
fi

#####################################################################
# P1-1: file_matches / PostToolUse（v2 漂移收紧，原 doc-reminder 断言）
# doc-reminder 迁移后 enabled=false → disabled 规则在 when 求值前 continue，
# 永不触发。所有 PostToolUse .md 断言按 "不触发" 收紧。
#####################################################################
separator "P1-1: file_matches — doc-reminder disabled (never fires)"

# PostToolUse with .md file → doc-reminder 不触发（disabled）
run_hook '{"tool_input":{"file_path":"/home/user/project/docs/readme.md"},"tool_response":{"result":"ok"}}' "Atlas"
if echo "$HOOK_STDOUT" | grep -q "doc-reminder"; then
    fail "P1-1a: disabled doc-reminder fired for .md PostToolUse"
else
    pass "P1-1a: .md file PostToolUse → doc-reminder does not fire (enabled=false)"
fi
assert_exit_0 "P1-1a: exit 0"

# PostToolUse with nested .md file → 同样不触发
run_hook '{"tool_input":{"file_path":"/home/user/project/sub/deep/docs/guide.md"},"tool_response":{"result":"ok"}}' "Atlas"
if echo "$HOOK_STDOUT" | grep -q "doc-reminder"; then
    fail "P1-1b: disabled doc-reminder fired for nested .md PostToolUse"
else
    pass "P1-1b: nested .md file → doc-reminder does not fire (disabled)"
fi

# PostToolUse with non-.md file → 不触发
run_hook '{"tool_input":{"file_path":"/home/user/project/src/main.ts"},"tool_response":{"result":"ok"}}' "Atlas"
if echo "$HOOK_STDOUT" | grep -q "doc-reminder"; then
    fail "P1-1c: non-.md file → doc-reminder incorrectly fires"
else
    pass "P1-1c: non-.md file → no doc-reminder"
fi

# 注意：v1 P1-1 的 PostToolUse additionalContext 格式断言（原 P1-3）随 doc-reminder
# disabled 一并收紧：v2 当前无 enabled 的 PostToolUse-only 规则，PostToolUse 载荷
# 全部透传（无 deny / 无 additionalContext）。
run_hook '{"tool_input":{"file_path":"/home/user/project/CLAUDE.md"},"tool_response":{"result":"ok"}}' "Atlas"
if echo "$HOOK_STDOUT" | grep -q "additionalContext"; then
    fail "P1-3a: PostToolUse payload produced additionalContext (no enabled PostToolUse rule exists)"
else
    pass "P1-3a: PostToolUse payload → passthrough (v2: no enabled PostToolUse rule)"
fi
if echo "$HOOK_STDOUT" | grep -q '"permissionDecision"."deny"'; then
    fail "P1-3b: PostToolUse payload incorrectly denied"
else
    pass "P1-3b: PostToolUse payload does not deny"
fi

#####################################################################
# P1-2: branch_is / non-git directory（doc-reminder disabled：不触发即过）
# 附加说明：branch_is 在非 git 目录恒 false（M1 注记），doc-reminder 的 when
# 即使规则未来重新启用也不会在此目录命中；本用例保持 P1-2 形状的“不触发”断言。
#####################################################################
separator "P1-2: non-git directory — doc-reminder does not fire"

run_hook '{"tool_input":{"file_path":"/tmp/test.md"},"tool_response":{"result":"ok"}}' "Atlas"
if echo "$HOOK_STDOUT" | grep -q "doc-reminder"; then
    fail "P1-2a: doc-reminder fired (should never fire while disabled)"
else
    pass "P1-2a: doc-reminder does not fire (disabled; branch_is false in non-git dir per M1)"
fi

#####################################################################
# P2-1: Pure remind rules — zero JSONL I/O (lazy load D3)
#####################################################################
separator "P2-1: Pure remind rules — lazy transcript load"

# agent-less remind（recall-reminder，无 when → 不依赖 transcript/JSONL IO）
run_hook '{"tool_input":{"command":"ls -la"}}' "Bachi"
assert_remind "P2-1a: recall-reminder reassigned firing without transcript dependency" "recall-reminder"
assert_remind_not_deny "P2-1a: remind does not deny"
assert_exit_0 "P2-1a: exit 0"

# v2 used_skill 拓扑：comment_add + 无技能使用 transcript（shim 返回 []）→ deny（v1: skip）
run_hook '{"tool_input":{"command":"multica issue comment add test --content-stdin"}}' "Atlas"
assert_blocks "P2-1b: atlas-workflow-skill-check — transcript with no skill use → denies (v2 semantics)"
assert_exit_0 "P2-1b: exit 0"

# 即使 block 场景中 deny 是终态，agent remind 规则依旧在同一 run 内先于 deny 命中并叠加进 reason
run_hook '{"tool_input":{"command":"ls -la"}}' "Atlas"
assert_remind "P2-1c: Atlas gets remind regardless of block-rule transcript state" "atlas-bash-skill-reminder"
assert_remind_not_deny "P2-1c: remind does not deny"

#####################################################################
# P2-2: Sentinel lifecycle — one-shot remind creates /tmp/.hook-fired-* sentinel
#####################################################################
separator "P2-2: Sentinel lifecycle (v2 keys)"

TASK_ID="$(new_task_id)"
cleanup_sentinels

# First call: remind should fire (DO NOT cleanup sentinel between calls)
run_hook_preserve_sentinel '{"tool_input":{"command":"ls -la"}}' "Atlas" "$TASK_ID"
assert_remind "P2-2a: first call — remind fires" "atlas-bash-skill-reminder"

# Check sentinel was created (v2 key: /tmp/.hook-fired-<rule>-<scope>)
SENTINEL_FOUND=0
for f in "$STATE_DIR/.hook-fired-atlas-bash-skill-reminder-Atlas-$ISSUE_ID" "$STATE_DIR/.hook-fired-recall-reminder-Atlas-$TASK_ID"; do
    if [ -f "$f" ]; then
        SENTINEL_FOUND=1
        pass "P2-2b: sentinel created: $(basename "$f")"
    fi
done
if [ "$SENTINEL_FOUND" -eq 0 ]; then
    fail "P2-2b: no /tmp/.hook-fired-* sentinel files found"
fi

# Second call with same task ID: remind should NOT fire (one-shot sentinel blocks)
run_hook_preserve_sentinel '{"tool_input":{"command":"ls -la"}}' "Atlas" "$TASK_ID"
if echo "$HOOK_STDOUT" | grep -q "atlas-bash-skill-reminder"; then
    fail "P2-2c: second call — atlas-bash-skill-reminder still fires (sentinel not working)"
else
    pass "P2-2c: same issue window — atlas-bash-skill-reminder suppressed by sentinel"
fi

if echo "$HOOK_STDOUT" | grep -q "recall-reminder"; then
    fail "P2-2d: second call — recall-reminder still fires (sentinel not working)"
else
    pass "P2-2d: second call — recall-reminder suppressed by sentinel"
fi

# Second call output should be pure passthrough (byte-for-byte echo of input)
assert_passthrough "P2-2d2: suppressed run is byte-for-byte passthrough" "$HOOK_PAYLOAD"
assert_exit_0 "P2-2d2: exit 0"

# Third call with DIFFERENT issue ID（同 task）: issue-window one-shot 重新触发
run_hook_preserve_sentinel '{"tool_input":{"command":"ls -la"}}' "Atlas" "$TASK_ID" "see764-other-issue"
assert_remind "P2-2e: different issue ID — remind fires again (issue-window one-shot)" "atlas-bash-skill-reminder"

cleanup_sentinels

#####################################################################
# P2-3: Passthrough preserves input byte-for-byte (no-hit cases)
#####################################################################
separator "P2-3: Passthrough preserves input"

# Unknown agent with git status: agent reminders skip, grep reminder skips
# → recall-reminder(无 agents 限定) 仍触发（per-run 一次）
INPUT='{"tool_input":{"command":"git status"},"session_id":"abc-123","extra":"data"}'
run_hook "$INPUT" "UnknownAgent"
assert_remind "P2-3a: unknown agent gets agent-less remind" "recall-reminder"
assert_remind_not_deny "P2-3a: remind does not deny"

# 完全无命中 → 引擎不输出 → 入口透传原 stdin（逐字节） + exit 0
# burn the per-run one-shot agent-less remind on the same scope first:
TASK_ID_P23="$(new_task_id)"
run_hook_preserve_sentinel '{"tool_input":{"command":"git status"},"session_id":"abc-123","extra":"data"}' "UnknownAgent" "$TASK_ID_P23"
# second call on same scope: all one-shot rules suppressed → no engine output → pure passthrough
run_hook_preserve_sentinel '{"tool_input":{"command":"git push origin main"},"session_id":"abc-123","extra":"data"}' "UnknownAgent" "$TASK_ID_P23"
assert_exit_0 "P2-3b: no-hit passthrough — exit 0"
if [ "$HOOK_STDOUT" = "$HOOK_PAYLOAD" ]; then
    pass "P2-3b: no-hit passthrough preserves INPUT byte-for-byte"
else
    fail "P2-3b: passthrough corrupted. Expected: '${HOOK_PAYLOAD:0:100}', Got: '${HOOK_STDOUT:0:100}'"
fi

rm -f "$TRANSCRIPT_SKILL_USED"
rm -rf "$MOCK_SHIM_DIR"
rm -rf "$STATE_DIR"
cleanup_sentinels

#####################################################################
# SUMMARY
#####################################################################
separator "Summary"

echo ""
echo -e "${CYAN}Results:${NC}"
echo -e "  ${GREEN}Passed:${NC}    $PASS"
echo -e "  ${RED}Failed:${NC}    $FAIL"
echo ""

TOTAL=$((PASS + FAIL))
echo "  Total: $TOTAL tests"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}Overall: PASS${NC}"
    exit 0
else
    echo -e "${RED}Overall: FAIL ($FAIL failures)${NC}"
    echo ""
    echo "Failed tests:"
    for R in "${RESULTS[@]}"; do
        if [[ "$R" == FAIL* ]]; then
            echo -e "  ${RED}x${NC} ${R#FAIL|}"
        fi
    done
    exit 1
fi
