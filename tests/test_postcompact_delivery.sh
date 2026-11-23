#!/bin/bash
# SEE-1621 R3: PostCompact→PreToolUse 补投路线行为测试（§SPEC-012 引擎行为面，
# 每次 compact 补投 horizon / 方案一，Owner 2026-11-23 终裁）。
# 背景：CC 2.1.329 不消费 PostCompact 的 additionalContext（到达 0/6）、PreCompact
# stdout 仅指导摘要生成。Owner 改定补投路线并终裁多次 compact 语义：
# arm 不配置 one_shot，每次 PostCompact 都以覆盖模式写同一 key+session pending；
# deliver 保持无 one_shot、存在才消费、消费即删。窗口语义 =
#   compact → 覆盖写 pending → 下一个 PreToolUse 消费并输出 1 次
#   → 再下一个 PreToolUse 无 pending 不输出 → 下一次 compact 重新可提醒；
# 两次 compact 间无任何工具调用时只保留一个标记，下一次工具调用提醒一次。
# 本套件驱动**真实生产链**（hook-wrapper.sh → dispatcher.sh → unified-hook.sh →
# engine.js + 真实生产规则，不注入 UNIFIED_RULES_FILE），证明：
#   - 首次 compact 记账 → 下一次 PreToolUse 补投一次并消费；
#   - 每次 compact 重臂：同 session 再次 compact 后下一次 PreToolUse 再次提醒；
#   - 连续 compact 无工具调用只留单标记，下一次工具调用只提醒一次；
#   - 无 compact 不触发；非 Atlas 隔离；session 隔离；跨 repo 生效；任意工具触发；
#   - 无 session_id 拒写/拒消费（fail-open 拒绝 + 审计，§SPEC-013 补强）；
#   - 全程非阻断/无 deny；PostCompact/PreCompact 基线透传契约不回退。
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
# 清空宿主 Multica/HOOK 身份变量防止外层 run 泄漏。pending 窗口 = key+session，
# 与 issue 维度无关（R3 起 arm 无 one_shot）；HOOK_ISSUE_ID 参数仅为既有调用形态保留。
run_chain() {
    local AGENT="$1" PAYLOAD="$2" REPO_DIR="$3" EVENT="$4" ISSUE="$5"
    printf '%s' "$PAYLOAD" > "$FIXTURE/stdin.json"
    HOOK_STDOUT=$(cd "$REPO_DIR" && \
        env -u MULTICA_ISSUE_ID -u MULTICA_TASK_ID -u MULTICA_AGENT_ID \
            -u HOOK_SCOPE_ID -u HOOK_RUN_SCOPE_ID \
            -u CLAUDE_CODE_SESSION_ID \
        HOOK_FIRE_LOG="$FIRELOG" \
        HOOK_STATE_DIR="$STATE" \
        HOOK_ISSUE_ID="$ISSUE" \
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
# 精确针对本路线：其他 reminder 规则（atlas-bash-skill-reminder 等同型一次性）
# 在各自 issue 首次工具调用时注入属合法既有行为，不算补投送达。
assert_no_delivery() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"additionalContext"' && echo "$HOOK_STDOUT" | grep -q "post-compact-reminder"; then
        fail "$label — 补投提醒误送达. got: '${HOOK_STDOUT:0:200}'"
    else
        pass "$label — 补投提醒未注入"
    fi
}
assert_marker() {
    local label="$1" session="$2" expect="$3"
    local f="$STATE/pending-atlas-postcompact-reminder-$session"
    if [ "$expect" = "present" ] && [ -f "$f" ]; then pass "$label — pending 标记在位"
    elif [ "$expect" = "absent" ] && [ ! -f "$f" ]; then pass "$label — pending 标记不存在"
    else fail "$label — pending 标记状态不符（expect=$expect file=$f）"; fi
}
assert_marker_total() {
    local label="$1" expect="$2"
    local n
    n=$(ls "$STATE"/pending-atlas-postcompact-reminder-* 2>/dev/null | wc -l)
    if [ "$n" -eq "$expect" ]; then pass "$label — pending 标记总数=$n"; else fail "$label — pending 标记总数=$n 预期=$expect"; fi
}
assert_pendingset_count() {
    local label="$1" expect="$2"
    local n
    n=$(grep -c "pending-set rule=atlas-postcompact-arm" "$FIRELOG" 2>/dev/null || true)
    if [ "$n" -eq "$expect" ]; then pass "$label — pending-set 次数=$n"; else fail "$label — pending-set 次数=$n 预期=$expect"; fi
}
assert_firelog_has() {
    local label="$1" pattern="$2"
    if grep -q "$pattern" "$FIRELOG" 2>/dev/null; then pass "$label — firelog 命中"; else fail "$label — firelog 未命中 '$pattern'"; fi
}

BASH_TOOL='{"command":"ls -la"}'

echo "============================================================"
echo "  SEE-1621 R3: PostCompact→PreToolUse delivery (per-compact horizon)"
echo "  Date: $(date -Iseconds)"
echo "============================================================"

separator "Prerequisites"
[ -f "$WRAPPER" ] && pass "hook-wrapper.sh exists" || { fail "hook-wrapper.sh MISSING"; exit 1; }
node -e "const c=JSON.parse(require('fs').readFileSync('$RULES_FILE','utf8')); const a=c.rules.find(x=>x.name==='atlas-postcompact-arm'); const d=c.rules.find(x=>x.name==='atlas-postcompact-deliver'); const ok=a&&d&&!a.one_shot; process.exit(ok?0:1)" 2>/dev/null \
    && pass "arm has NO one_shot（每次 compact 均重臂，方案一）" \
    || fail "arm 不应配置 one_shot（Owner 已否定 agent+issue 全局一次性语义）"

#####################################################################
# 1. 核心：首次 compact → 补投一次并消费
#####################################################################
separator "1. First compact arms → next PreToolUse delivers once (sess-A1)"
run_chain "Atlas" "$(postcompact_payload sess-A1)" "$REPO_A" PostCompact "ISSUE-A"
assert_exit_0 "1a: PostCompact exit 0"
assert_marker "1b: arm writes session marker" "sess-A1" present
assert_pendingset_count "1c: exactly one pending-set" 1
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" sess-A1)" "$REPO_A" PreToolUse "ISSUE-A"
assert_exit_0 "1d: PreToolUse exit 0"
assert_no_deny "1e: no deny on delivery"
assert_reminder "1f: next PreToolUse delivers full reminder"
assert_marker "1g: marker consumed after delivery (无残留 pending)" "sess-A1" absent
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" sess-A1)" "$REPO_A" PreToolUse "ISSUE-A"
assert_no_delivery "1h: second PreToolUse injects nothing"

#####################################################################
# 2. 每次 compact 重臂：同 session 再次 compact → 下一次 PreToolUse 再次提醒
#####################################################################
separator "2. Every compact re-arms (per-compact horizon)"
run_chain "Atlas" "$(postcompact_payload sess-A1)" "$REPO_A" PostCompact "ISSUE-A"
assert_exit_0 "2a: second PostCompact exit 0"
assert_marker "2b: re-armed after second compact (覆盖式写同 key+session 标记)" "sess-A1" present
assert_pendingset_count "2c: pending-set fires again (count=2)" 2
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" sess-A1)" "$REPO_A" PreToolUse "ISSUE-A"
assert_reminder "2d: next PreToolUse delivers again (每次 compact 均提醒)"
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" sess-A1)" "$REPO_A" PreToolUse "ISSUE-A"
assert_no_delivery "2e: same window second tool call does not repeat"

#####################################################################
# 3. 连续 compact 无工具调用 → 单标记，下一次工具只提醒一次
#####################################################################
separator "3. Two compacts with no tool call keep a single marker"
run_chain "Atlas" "$(postcompact_payload sess-A1)" "$REPO_A" PostCompact "ISSUE-A"
run_chain "Atlas" "$(postcompact_payload sess-A1)" "$REPO_A" PostCompact "ISSUE-A"
assert_exit_0 "3a: consecutive PostCompacts exit 0"
assert_marker_total "3b: overwrite keeps a single marker" 1
assert_pendingset_count "3c: pending-set count=4 (每次 compact 均记账)" 4
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" sess-A1)" "$REPO_A" PreToolUse "ISSUE-A"
assert_reminder "3d: next tool call delivers exactly once"
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" sess-A1)" "$REPO_A" PreToolUse "ISSUE-A"
assert_no_delivery "3e: no repeat after consumption"

#####################################################################
# 4. 未 compact 不触发
#####################################################################
separator "4. No compact → no reminder (ISSUE-C)"
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" sess-C1)" "$REPO_A" PreToolUse "ISSUE-C"
assert_no_delivery "4a: PreToolUse without compact injects nothing"
assert_marker "4b: no marker without compact" "sess-C1" absent

#####################################################################
# 5. 非 Atlas 隔离（ISSUE-D）
#####################################################################
separator "5. Non-Atlas isolation"
run_chain "Bachi" "$(postcompact_payload sess-D1)" "$REPO_A" PostCompact "ISSUE-D"
assert_marker "5a: non-Atlas arm writes no marker" "sess-D1" absent
run_chain "Bachi" "$(pretool_payload Bash "$BASH_TOOL" sess-D1)" "$REPO_A" PreToolUse "ISSUE-D"
assert_no_delivery "5b: non-Atlas PreToolUse injects nothing"
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" sess-D1)" "$REPO_A" PreToolUse "ISSUE-D"
assert_no_delivery "5c: no cross-agent delivery in Bachi session"

#####################################################################
# 6. session 隔离（ISSUE-E）
#####################################################################
separator "6. Session isolation (ISSUE-E)"
run_chain "Atlas" "$(postcompact_payload sess-E1)" "$REPO_A" PostCompact "ISSUE-E"
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" sess-E2)" "$REPO_A" PreToolUse "ISSUE-E"
assert_no_delivery "6a: other session does not consume"
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" sess-E1)" "$REPO_A" PreToolUse "ISSUE-E"
assert_reminder "6b: original session still delivers"

#####################################################################
# 7. 跨 repo 生效 + 任意工具（ISSUE-F）
#####################################################################
separator "7. Cross-repo + any tool (ISSUE-F)"
run_chain "Atlas" "$(postcompact_payload sess-F1)" "$REPO_A" PostCompact "ISSUE-F"
run_chain "Atlas" "$(pretool_payload Read '{"file_path":"/x/a.md"}' sess-F1)" "$REPO_B" PreToolUse "ISSUE-F"
assert_reminder "7a: delivery in another repo + Read tool"

#####################################################################
# 8. 无 session_id 拒写/拒消费（fail-open 拒绝 + 审计；§SPEC-013 补强）
# 植入无 session 标记作为陷阱：session 缺失的调用不得消费它（防跨会话串扰契约）。
#####################################################################
separator "8. Missing session_id refuses pending write/consume"
run_chain "Atlas" "$(postcompact_payload "")" "$REPO_A" PostCompact "ISSUE-G"
assert_marker "8a: no marker without session_id" "" absent
assert_firelog_has "8b: pending-set-skip WARN audited" "pending-set-skip rule=atlas-postcompact-arm reason=no-session-id"
: > "$STATE/pending-atlas-postcompact-reminder-"
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" "")" "$REPO_A" PreToolUse "ISSUE-G"
assert_no_delivery "8c: no-session PreToolUse must not consume planted marker"
assert_firelog_has "8d: pending-consume-skip WARN audited" "pending-consume-skip rule=atlas-postcompact-deliver reason=no-session-id"

#####################################################################
# 9. 既有契约不回退
#####################################################################
separator "9. Existing contracts unchanged"
run_chain "Atlas" "$(postcompact_payload sess-L1)" "$REPO_A" PostCompact "ISSUE-L"
if [ "$HOOK_STDOUT" = "$HOOK_STDIN" ]; then
    pass "9a: PostCompact passthrough（不可达旧规则已按 §SPEC-014 移除；arm 记账无输出）"
else
    fail "9a: PostCompact 输出异常. got: '${HOOK_STDOUT:0:160}'"
fi
run_chain "Atlas" '{"hook_event_name":"PreCompact","trigger":"auto","session_id":"sess-P1"}' "$REPO_A" PreCompact "ISSUE-L"
if [ "$HOOK_STDOUT" = "$HOOK_STDIN" ]; then
    pass "9b: PreCompact passthrough（§SPEC-014 移除试验残留后恢复基线透传契约）"
else
    fail "9b: PreCompact 输出异常. got: '${HOOK_STDOUT:0:160}'"
fi

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
