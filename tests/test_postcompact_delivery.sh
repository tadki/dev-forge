#!/bin/bash
# SEE-1621 R2: PostCompact→PreToolUse 补投路线行为测试（§SPEC-012 引擎行为面）
# 背景：CC 2.1.329 不消费 PostCompact 的 additionalContext（到达 0/6）、PreCompact
# stdout 仅指导摘要生成（Owner 判定不符合强制提醒目标）。Owner 改定补投路线：
# Atlas 的 PostCompact 只记录 session 级待提醒状态；下一次 PreToolUse（任意工具）
# 消费并注入完整提醒（PreToolUse additionalContext 已有实机到达证据）。
# 本套件驱动**真实生产链**（hook-wrapper.sh → dispatcher.sh → unified-hook.sh →
# engine.js + 真实生产规则，不注入 UNIFIED_RULES_FILE），证明：
#   - PostCompact 记账（session 级标记）且不重复消费：同一 compact 只补投一次；
#   - 下一次 PreToolUse 注入完整提醒块并清除标记；无 compact 不触发；
#   - 连续 compact 各可重臂；任意工具触发；跨 repo 生效；
#   - 非 Atlas 不触发；session 隔离无串扰；全程非阻断/无 deny；
#   - PostCompact 既有 JSON 契约不回退；PreCompact 不回显 payload（防摘要污染）。
# Run: bash tests/test_postcompact_delivery.sh
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0; RESULTS=()
pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); RESULTS+=("PASS|$1"); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); RESULTS+=("FAIL|$1"); }
separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$REPO_ROOT/claude-hooks/hook-wrapper.sh"
RULES_FILE="$REPO_ROOT/claude-hooks/unified/rules-v2.json"
FIXTURE="$(mktemp -d /tmp/postcompact-delivery.XXXXXX)"
FIRELOG="$FIXTURE/hook-fire.log"
STATE="$FIXTURE/state"
FAKE_HOME="$FIXTURE/home"
mkdir -p "$FAKE_HOME/.claude"

cleanup_fixtures() {
    rm -rf "$FIXTURE"
    rm -f /tmp/.hook-fired-* 2>/dev/null
}
trap cleanup_fixtures EXIT

REPO_A="$FIXTURE/repo-alpha"; mkdir -p "$REPO_A/.claude"
REPO_B="$FIXTURE/repo-beta"; mkdir -p "$REPO_B/.claude"

# 真实生产链（wrapper → dispatcher → unified-hook → engine），真实生产规则。
# 清空宿主 Multica/HOOK 身份变量：否则 one_shot 规则（skill/recall 提醒）会被
# 外层 agent 运行时的 issue/run id 激活，污染「无 context」类断言的确定性。
run_chain() {
    local AGENT="$1" PAYLOAD="$2" REPO_DIR="$3" EVENT="$4"
    : > "$FIRELOG"
    printf '%s' "$PAYLOAD" > "$FIXTURE/stdin.json"
    HOOK_STDOUT=$(cd "$REPO_DIR" && \
        env -u MULTICA_ISSUE_ID -u MULTICA_TASK_ID -u MULTICA_AGENT_ID \
            -u HOOK_ISSUE_ID -u HOOK_SCOPE_ID -u HOOK_RUN_SCOPE_ID \
            -u CLAUDE_CODE_SESSION_ID \
        HOOK_FIRE_LOG="$FIRELOG" \
        HOOK_STATE_DIR="$STATE" \
        MULTICA_AGENT_NAME="$AGENT" \
        HOME="$FAKE_HOME" \
        bash "$WRAPPER" "$EVENT" unified-hook < "$FIXTURE/stdin.json" 2>/dev/null)
    HOOK_EXIT=$?
    HOOK_STDIN=$(cat "$FIXTURE/stdin.json")
}

postcompact_payload() { printf '{"hook_event_name":"PostCompact","trigger":"auto","compact_summary":"s","session_id":"%s"}' "$1"; }
pretool_payload()     { printf '{"hook_event_name":"PreToolUse","tool_name":"%s","tool_input":%s,"session_id":"%s"}' "$1" "$2" "$3"; }

assert_exit_0() {
    local label="$1"
    if [ "$HOOK_EXIT" -eq 0 ]; then pass "$label — exit 0"; else fail "$label — exit $HOOK_EXIT"; fi
}
assert_no_deny() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"permissionDecision":"deny"'; then
        fail "$label — 误产生 deny（非阻断契约破坏）"
    else
        pass "$label — 无 deny 输出"
    fi
}
assert_reminder() {
    local label="$1"
    local bad=0
    for frag in "已经被压缩" "/task-explore" "/recall owner-order" "kp-cb6e073b333974583acdc872916438ff" "/task-run"; do
        echo "$HOOK_STDOUT" | grep -F -q "$frag" || bad=1
    done
    if echo "$HOOK_STDOUT" | grep -q '"additionalContext"' && [ "$bad" -eq 0 ]; then
        pass "$label — additionalContext 含完整提醒块"
    else
        fail "$label — 提醒缺片段或非 additionalContext. got: '${HOOK_STDOUT:0:200}'"
    fi
}
assert_no_context() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"additionalContext"'; then
        fail "$label — 误注入 context. got: '${HOOK_STDOUT:0:200}'"
    else
        pass "$label — 无 context 注入"
    fi
}
assert_marker() {
    local label="$1" session="$2" expect="$3"
    local f="$STATE/pending-atlas-postcompact-reminder-$session"
    if [ "$expect" = "present" ] && [ -f "$f" ]; then pass "$label — pending 标记在位"
    elif [ "$expect" = "absent" ] && [ ! -f "$f" ]; then pass "$label — pending 标记已消费"
    else fail "$label — pending 标记状态不符（expect=$expect file=$f）"; fi
}
assert_firelog_has() {
    local label="$1" pattern="$2"
    if grep -q "$pattern" "$FIRELOG" 2>/dev/null; then pass "$label — firelog 命中"; else fail "$label — firelog 未命中 '$pattern'"; fi
}
assert_empty_stdout() {
    local label="$1"
    if [ -z "$HOOK_STDOUT" ]; then pass "$label — stdout 为空"; else fail "$label — stdout 非空. got: '${HOOK_STDOUT:0:160}'"; fi
}

BASH_TOOL='{"command":"ls -la"}'

echo "============================================================"
echo "  SEE-1621 R2: PostCompact→PreToolUse delivery engine behavior"
echo "  Date: $(date -Iseconds)"
echo "============================================================"

separator "Prerequisites"
[ -f "$WRAPPER" ] && pass "hook-wrapper.sh exists" || { fail "hook-wrapper.sh MISSING"; exit 1; }
node -e "const c=JSON.parse(require('fs').readFileSync('$RULES_FILE','utf8')); const n=new Set(c.rules.map(x=>x.name)); process.exit(n.has('atlas-postcompact-arm')&&n.has('atlas-postcompact-deliver')?0:1)" 2>/dev/null \
    && pass "rules-v2.json declares arm + deliver rules" \
    || fail "atlas-postcompact-arm/deliver missing from rules-v2.json"

#####################################################################
# 1. 核心：PostCompact 记账 → 下一次 PreToolUse 补投一次并消费
#####################################################################
separator "1. Arm on PostCompact → deliver once on next PreToolUse"
run_chain "Atlas" "$(postcompact_payload sess-A1)" "$REPO_A" PostCompact
assert_exit_0 "1a: PostCompact exit 0"
assert_marker "1b: arm writes session marker" "sess-A1" present
assert_firelog_has "1c: firelog pending-set" "pending-set"
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" sess-A1)" "$REPO_A" PreToolUse
assert_exit_0 "1d: PreToolUse exit 0"
assert_no_deny "1e: no deny on delivery"
assert_reminder "1f: next PreToolUse delivers full reminder"
assert_marker "1g: marker consumed after delivery" "sess-A1" absent
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" sess-A1)" "$REPO_A" PreToolUse
assert_no_context "1h: same compact delivered only once"

#####################################################################
# 2. 未 compact 不触发
#####################################################################
separator "2. No compact → no reminder"
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" sess-NONE)" "$REPO_A" PreToolUse
assert_no_context "2a: PreToolUse without compact injects nothing"

#####################################################################
# 3. 连续 compact 各可重臂
#####################################################################
separator "3. Consecutive compacts re-arm"
run_chain "Atlas" "$(postcompact_payload sess-A3)" "$REPO_A" PostCompact
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" sess-A3)" "$REPO_A" PreToolUse
assert_reminder "3a: first compact delivers"
run_chain "Atlas" "$(postcompact_payload sess-A3)" "$REPO_A" PostCompact
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" sess-A3)" "$REPO_A" PreToolUse
assert_reminder "3b: second compact arms and delivers again"

#####################################################################
# 4. 非 Atlas 隔离
#####################################################################
separator "4. Non-Atlas isolation"
run_chain "Bachi" "$(postcompact_payload sess-B4)" "$REPO_A" PostCompact
assert_marker "4a: non-Atlas arm writes no marker" "sess-B4" absent
run_chain "Bachi" "$(pretool_payload Bash "$BASH_TOOL" sess-B4)" "$REPO_A" PreToolUse
assert_no_context "4b: non-Atlas PreToolUse injects nothing"
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" sess-B4)" "$REPO_A" PreToolUse
assert_no_context "4c: no cross-agent delivery in Bachi session"

#####################################################################
# 5. session 隔离（无跨 session 串扰）
#####################################################################
separator "5. Session isolation"
run_chain "Atlas" "$(postcompact_payload sess-S5)" "$REPO_A" PostCompact
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" sess-S6)" "$REPO_A" PreToolUse
assert_no_context "5a: other session does not consume"
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" sess-S5)" "$REPO_A" PreToolUse
assert_reminder "5b: original session still delivers"

#####################################################################
# 6. 跨 repo 生效 + 任意工具
#####################################################################
separator "6. Cross-repo + any tool"
run_chain "Atlas" "$(postcompact_payload sess-C7)" "$REPO_A" PostCompact
run_chain "Atlas" "$(pretool_payload Read '{"file_path":"/x/a.md"}' sess-C7)" "$REPO_B" PreToolUse
assert_reminder "6a: delivery in another repo + Read tool"

#####################################################################
# 7. 既有契约不回退
#####################################################################
separator "7. Existing contracts unchanged"
run_chain "Atlas" "$(postcompact_payload sess-L8)" "$REPO_A" PostCompact
if echo "$HOOK_STDOUT" | grep -q '"additionalContext"'; then
    pass "7a: PostCompact keeps JSON additionalContext contract (legacy rule)"
else
    fail "7a: PostCompact JSON contract broken. got: '${HOOK_STDOUT:0:160}'"
fi
run_chain "Atlas" '{"hook_event_name":"PreCompact","trigger":"auto","session_id":"sess-P9"}' "$REPO_A" PreCompact
assert_empty_stdout "7b: PreCompact stdout stays empty (no payload-as-summary pollution)"

#####################################################################
separator "Summary"
echo ""
echo -e "${CYAN}Results:${NC}"
echo -e "  ${GREEN}Passed:${NC} $PASS"
echo -e "  ${RED}Failed:${NC} $FAIL"
echo ""
if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}Overall: PASS${NC}"
    exit 0
else
    echo -e "${RED}Overall: FAIL ($FAIL failures)${NC}"
    for R in "${RESULTS[@]}"; do
        [[ "$R" == FAIL* ]] && echo -e "  ${RED}x${NC} ${R#FAIL|}"
    done
    exit 1
fi
