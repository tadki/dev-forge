#!/bin/bash
# SEE-1621 R2b: PostCompact→PreToolUse 补投路线行为测试（§SPEC-012 引擎行为面，
# 一次性 agent+issue horizon，与 atlas-bash-skill-reminder 同型）。
# 背景：CC 2.1.329 不消费 PostCompact 的 additionalContext（到达 0/6）、PreCompact
# stdout 仅指导摘要生成。Owner 改定补投路线并明确 reminder 为一次性：
# `one_shot.ids=[MULTICA_AGENT_NAME, HOOK_ISSUE_ID]`（同型 horizon）——
# 同一 agent 在同一 issue 首次补投后不再提醒，后续 compact 不重复；不同 issue 独立；
# 首次消费后无残留 pending 误触发；horizon 窗口 env 缺失时 fail-open 跳过（不提醒）。
# 本套件驱动**真实生产链**（hook-wrapper.sh → dispatcher.sh → unified-hook.sh →
# engine.js + 真实生产规则，不注入 UNIFIED_RULES_FILE），按 issue 维度注入
# HOOK_ISSUE_ID 驱动 horizon，证明：
#   - 首次 compact 记账 → 下一次 PreToolUse 补投一次并消费；
#   - 同 agent+issue 第二次 compact 不再重臂/不再提醒（arm 哨兵在位）；
#   - 不同 issue 独立提醒；无 compact 不触发；非 Atlas 隔离；session 隔离；
#   - 跨 repo 生效；任意工具触发；horizon env 缺失 fail-open；
#   - 无 session_id 拒写/拒消费（fail-open 拒绝 + 审计，§SPEC-013 补强）；
#   - 全程非阻断/无 deny；PostCompact 既有 JSON 契约不回退；PreCompact 不回显 payload。
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
# 清空宿主 Multica/HOOK 身份变量防止外层 run 泄漏；按场景显式注入 HOOK_ISSUE_ID
# 驱动一次性 horizon（入口层：显式 HOOK_ISSUE_ID 优先于 MULTICA_ISSUE_ID）。
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
assert_arm_sentinel() {
    local label="$1" issue="$2" expect="$3"
    local f="$STATE/.hook-fired-atlas-postcompact-arm-Atlas-$issue"
    if [ "$expect" = "present" ] && [ -f "$f" ]; then pass "$label — arm one_shot 哨兵在位"
    elif [ "$expect" = "absent" ] && [ ! -f "$f" ]; then pass "$label — arm 哨兵不存在"
    else fail "$label — arm 哨兵状态不符（expect=$expect file=$f）"; fi
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
echo "  SEE-1621 R2b: PostCompact→PreToolUse delivery (one-shot horizon)"
echo "  Date: $(date -Iseconds)"
echo "============================================================"

separator "Prerequisites"
[ -f "$WRAPPER" ] && pass "hook-wrapper.sh exists" || { fail "hook-wrapper.sh MISSING"; exit 1; }
node -e "const c=JSON.parse(require('fs').readFileSync('$RULES_FILE','utf8')); const a=c.rules.find(x=>x.name==='atlas-postcompact-arm'); const d=c.rules.find(x=>x.name==='atlas-postcompact-deliver'); const ok=a&&d&&JSON.stringify(a.one_shot)===JSON.stringify({ids:['MULTICA_AGENT_NAME','HOOK_ISSUE_ID']}); process.exit(ok?0:1)" 2>/dev/null \
    && pass "arm carries one_shot.ids=[MULTICA_AGENT_NAME,HOOK_ISSUE_ID] (atlas-bash-skill-reminder 同型)" \
    || fail "arm 缺少同型 one_shot horizon 配置"

#####################################################################
# 1. 核心：首次 compact → 补投一次并消费（同 agent+issue 唯一一次）
#####################################################################
separator "1. First compact arms → next PreToolUse delivers once (ISSUE-A)"
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
# 2. 同 agent+issue 第二次 compact 不再提醒（一次性 horizon）
#####################################################################
separator "2. Second compact in same agent+issue does NOT re-remind"
run_chain "Atlas" "$(postcompact_payload sess-A2)" "$REPO_A" PostCompact "ISSUE-A"
assert_exit_0 "2a: second PostCompact exit 0"
assert_marker "2b: no new pending (arm horizon exhausted)" "sess-A2" absent
assert_arm_sentinel "2c: arm one_shot sentinel in place" "ISSUE-A" present
assert_pendingset_count "2d: still exactly one pending-set for ISSUE-A" 1
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" sess-A2)" "$REPO_A" PreToolUse "ISSUE-A"
assert_no_delivery "2e: no reminder after horizon-exhausted compact"

#####################################################################
# 3. 不同 issue 独立提醒
#####################################################################
separator "3. Different issue delivers independently"
run_chain "Atlas" "$(postcompact_payload sess-B1)" "$REPO_A" PostCompact "ISSUE-B"
assert_marker "3a: ISSUE-B arm writes its own marker" "sess-B1" present
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" sess-B1)" "$REPO_A" PreToolUse "ISSUE-B"
assert_reminder "3b: ISSUE-B delivers independently"

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
# 8. horizon 窗口 env 缺失 → fail-open 不提醒（与其他 reminder 同语义）
#####################################################################
separator "8. Missing horizon env fails open (no reminder)"
run_chain "Atlas" "$(postcompact_payload sess-N1)" "$REPO_A" PostCompact ""
assert_marker "8a: no marker when HOOK_ISSUE_ID missing" "sess-N1" absent
assert_firelog_has "8b: fail-open WARN audited" "one-shot window env missing"
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" sess-N1)" "$REPO_A" PreToolUse ""
assert_no_delivery "8c: no delivery without horizon window"

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
# 10. 无 session_id 拒写/拒消费（fail-open 拒绝 + 审计；§SPEC-013 补强）
# 植入无 session 标记作为陷阱：session 缺失的调用不得消费它（防跨会话串扰契约）。
#####################################################################
separator "10. Missing session_id refuses pending write/consume"
run_chain "Atlas" "$(postcompact_payload "")" "$REPO_A" PostCompact "ISSUE-G"
assert_marker "10a: no marker without session_id" "" absent
assert_firelog_has "10b: pending-set-skip WARN audited" "pending-set-skip rule=atlas-postcompact-arm reason=no-session-id"
: > "$STATE/pending-atlas-postcompact-reminder-"
run_chain "Atlas" "$(pretool_payload Bash "$BASH_TOOL" "")" "$REPO_A" PreToolUse "ISSUE-G"
assert_no_delivery "10c: no-session PreToolUse must not consume planted marker"
assert_firelog_has "10d: pending-consume-skip WARN audited" "pending-consume-skip rule=atlas-postcompact-deliver reason=no-session-id"

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
