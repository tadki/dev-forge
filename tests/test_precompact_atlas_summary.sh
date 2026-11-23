#!/bin/bash
# SEE-1621 R1: atlas-precompact-summary 引擎行为测试（§SPEC-010 引擎行为面）
# 背景：CC 2.1.329 不消费 PostCompact 的 hookSpecificOutput.additionalContext
# （QA 6 次真实 compact 到达 0/6），但官方契约明确 PreCompact「退出 0 且不阻断时
# stdout 作为压缩摘要指令」。本套件驱动**真实生产链**
# （hook-wrapper.sh → dispatcher.sh → unified-hook.sh → engine.js + 真实生产规则），
# 不注入 UNIFIED_RULES_FILE，证明：
#   - Atlas 的 PreCompact 以纯 stdout 输出完整提醒块（非 JSON additionalContext）；
#   - 非 Atlas / 无命中时 PreCompact stdout 必须为空（不得把 payload JSON 回显成
#     摘要指令——这是本次修复的既有污染缺陷）；
#   - 无 repo 过滤（两个不同仓库上下文均生效）；无 one_shot（每次 compact 均输出）；
#   - 非阻断、exit 0、无 deny；其他事件的常规透传契约不被破坏。
# Run: bash tests/test_precompact_atlas_summary.sh
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0; RESULTS=()
pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); RESULTS+=("PASS|$1"); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); RESULTS+=("FAIL|$1"); }
separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$REPO_ROOT/claude-hooks/hook-wrapper.sh"
ENGINE="$REPO_ROOT/claude-hooks/unified/engine.js"
RULES_FILE="$REPO_ROOT/claude-hooks/unified/rules-v2.json"
FIXTURE="$(mktemp -d /tmp/precompact-atlas.XXXXXX)"
FIRELOG="$FIXTURE/hook-fire.log"
STATE="$FIXTURE/state"
FAKE_HOME="$FIXTURE/home"
mkdir -p "$FAKE_HOME/.claude"

cleanup_fixtures() {
    rm -rf "$FIXTURE"
    rm -f /tmp/.hook-fired-* 2>/dev/null
}
trap cleanup_fixtures EXIT

# 两个不同 repo/cwd 上下文（各带 .claude/，模拟真实仓库形态）
REPO_A="$FIXTURE/repo-alpha"; mkdir -p "$REPO_A/.claude"
REPO_B="$FIXTURE/repo-beta"; mkdir -p "$REPO_B/.claude"

# 真实生产链（wrapper → dispatcher → unified-hook → engine），真实全局部署位规则
run_chain() {
    local AGENT="$1" PAYLOAD="$2" REPO_DIR="$3" EVENT="${4:-PreCompact}"
    : > "$FIRELOG"
    printf '%s' "$PAYLOAD" > "$FIXTURE/stdin.json"
    HOOK_STDOUT=$(cd "$REPO_DIR" && \
        HOOK_FIRE_LOG="$FIRELOG" \
        HOOK_STATE_DIR="$STATE" \
        MULTICA_AGENT_NAME="$AGENT" \
        HOME="$FAKE_HOME" \
        bash "$WRAPPER" "$EVENT" unified-hook < "$FIXTURE/stdin.json" 2>/dev/null)
    HOOK_EXIT=$?
    HOOK_STDIN=$(cat "$FIXTURE/stdin.json")
}

# 引擎直跑（测引擎输出通道形状）
run_engine() {
    local AGENT="$1" PAYLOAD="$2" REPO_DIR="$3"
    : > "$FIRELOG"
    printf '%s' "$PAYLOAD" > "$FIXTURE/stdin.json"
    HOOK_STDOUT=$(cd "$REPO_DIR" && \
        HOOK_FIRE_LOG="$FIRELOG" HOOK_STATE_DIR="$STATE" \
        MULTICA_AGENT_NAME="$AGENT" \
        node "$ENGINE" < "$FIXTURE/stdin.json" 2>/dev/null)
    HOOK_EXIT=$?
}

assert_exit_0() {
    local label="$1"
    if [ "$HOOK_EXIT" -eq 0 ]; then pass "$label — exit 0"; else fail "$label — exit $HOOK_EXIT"; fi
}

assert_summary_has() {
    local label="$1" fragment="$2"
    if echo "$HOOK_STDOUT" | grep -F -q "$fragment"; then
        pass "$label — 含 '$fragment'"
    else
        fail "$label — 摘要指令不含 '$fragment'. got: '${HOOK_STDOUT:0:200}'"
    fi
}

assert_plain_stdout() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"hookSpecificOutput"'; then
        fail "$label — 输出为 JSON 协议（PreCompact 应为纯 stdout 摘要指令）"
    else
        pass "$label — 纯文本 stdout（非 JSON 协议）"
    fi
}

assert_empty_stdout() {
    local label="$1"
    if [ -z "$HOOK_STDOUT" ]; then
        pass "$label — stdout 为空"
    else
        fail "$label — stdout 非空（会污染摘要指令）. got: '${HOOK_STDOUT:0:200}'"
    fi
}

assert_no_deny() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"permissionDecision":"deny"'; then
        fail "$label — 误产生 deny（非阻断契约破坏）"
    else
        pass "$label — 无 deny 输出"
    fi
}

assert_passthrough() {
    local label="$1"
    if [ "$HOOK_STDOUT" = "$HOOK_STDIN" ]; then
        pass "$label — 原样透传"
    else
        fail "$label — 透传被破坏. got: '${HOOK_STDOUT:0:200}'"
    fi
}

assert_firelog_has() {
    local label="$1" pattern="$2"
    if grep -q "$pattern" "$FIRELOG" 2>/dev/null; then
        pass "$label — firelog 命中"
    else
        fail "$label — firelog 未命中 '$pattern'. log: $(cat "$FIRELOG" 2>/dev/null | head -3 | tr '\n' ';')"
    fi
}

ATLAS_PRECOMPACT='{"hook_event_name":"PreCompact","trigger":"auto","custom_instructions":null,"session_id":"sess-precompact-1","cwd":"'"$REPO_A"'"}'

echo "============================================================"
echo "  SEE-1621 R1: atlas-precompact-summary engine behavior"
echo "  Date: $(date -Iseconds)"
echo "============================================================"

separator "Prerequisites"
[ -f "$WRAPPER" ] && pass "hook-wrapper.sh exists" || { fail "hook-wrapper.sh MISSING"; exit 1; }
[ -f "$ENGINE" ] && pass "engine.js exists" || { fail "engine.js MISSING"; exit 1; }
node -e "const c=JSON.parse(require('fs').readFileSync('$RULES_FILE','utf8')); process.exit(c.rules.some(x=>x.name==='atlas-precompact-summary')?0:1)" 2>/dev/null \
    && pass "rules-v2.json declares atlas-precompact-summary" \
    || fail "atlas-precompact-summary missing from rules-v2.json（规则未登记）"

#####################################################################
# 1. Atlas PreCompact → 纯 stdout 完整提醒块（进入压缩摘要指令通道）
#####################################################################
separator "1. Atlas PreCompact emits plain-text summary instruction"
run_chain "Atlas" "$ATLAS_PRECOMPACT" "$REPO_A"
assert_exit_0 "1a: chain exit 0"
assert_no_deny "1b: no deny (non-blocking)"
assert_plain_stdout "1c: plain text channel (not JSON protocol)"
assert_summary_has "1d: 压缩事实" "已经被压缩"
assert_summary_has "1e: /task-explore 探索指令" "/task-explore"
assert_summary_has "1f: owner-order 召回命令" "/recall owner-order"
assert_summary_has "1g: owner-order 页面 ID" "kp-cb6e073b333974583acdc872916438ff"
assert_summary_has "1h: Leader /task-run 要求" "/task-run"
if [ "$HOOK_STDOUT" != "$HOOK_STDIN" ]; then
    pass "1i: stdout 是摘要指令而非 payload 回显"
else
    fail "1i: stdout 等于 payload 回显（CC 会把 JSON 当摘要指令）"
fi

run_engine "Atlas" "$ATLAS_PRECOMPACT" "$REPO_A"
assert_exit_0 "1j: engine direct exit 0"
assert_plain_stdout "1k: engine direct plain text"
assert_summary_has "1l: engine direct summary text" "已经被压缩"
assert_firelog_has "1m: firelog event line" "event=PreCompact agent=Atlas"
assert_firelog_has "1n: firelog action=context" "action=context"

#####################################################################
# 2. 非 Atlas / 无命中 → PreCompact stdout 必须为空（不得回显 payload）
#####################################################################
separator "2. Non-Atlas PreCompact stdout stays empty"
for AG in Bachi Revy ""; do
    run_chain "$AG" "$ATLAS_PRECOMPACT" "$REPO_A"
    assert_exit_0 "2[${AG:-<unset>}]: exit 0"
    assert_empty_stdout "2[${AG:-<unset>}]: empty stdout (no payload-as-instructions pollution)"
done

#####################################################################
# 3. 跨仓库命中（规则无 repo 过滤）
#####################################################################
separator "3. Cross-repo hit (no repo filter)"
run_chain "Atlas" "$ATLAS_PRECOMPACT" "$REPO_A"
assert_summary_has "3a: repo-alpha emits" "已经被压缩"
run_chain "Atlas" "$ATLAS_PRECOMPACT" "$REPO_B"
assert_summary_has "3b: repo-beta emits too" "已经被压缩"

#####################################################################
# 4. 每次 compact 均生效（无 one_shot）+ 零 sentinel
#####################################################################
separator "4. Repeated compacts re-emit (no one_shot)"
run_chain "Atlas" "$ATLAS_PRECOMPACT" "$REPO_A"
assert_summary_has "4a: first compact emits" "已经被压缩"
run_chain "Atlas" "$ATLAS_PRECOMPACT" "$REPO_A"
assert_summary_has "4b: second compact emits again" "已经被压缩"
SENTINEL_LEFT=$(ls "$STATE" 2>/dev/null | grep -c "precompact" || true)
SENTINEL_TMP=$(ls /tmp/.hook-fired-atlas-precompact-summary* 2>/dev/null | wc -l)
if [ "$SENTINEL_LEFT" -eq 0 ] && [ "$SENTINEL_TMP" -eq 0 ]; then
    pass "4c: zero sentinel writes (repeatable by design, no one_shot)"
else
    fail "4c: sentinel residue state=$SENTINEL_LEFT tmp=$SENTINEL_TMP"
fi

#####################################################################
# 5. 其他事件常规契约不被破坏
#####################################################################
separator "5. Other events keep their normal contracts"
# 5a: 非压缩事件无命中 → 原样透传（dispatcher 常规通道）
run_chain "Atlas" '{"hook_event_name":"SessionEnd","session_id":"sess-x"}' "$REPO_A" "SessionEnd"
assert_passthrough "5a: SessionEnd passthrough (normal channel intact)"
# 5b: PostCompact 通道保持既有 JSON additionalContext 契约（不因 PreCompact 改动回退）
run_chain "Atlas" '{"hook_event_name":"PostCompact","trigger":"manual","compact_summary":"x","session_id":"sess-x"}' "$REPO_A" "PostCompact"
if echo "$HOOK_STDOUT" | grep -q '"additionalContext"'; then
    pass "5b: PostCompact still emits JSON additionalContext (unchanged contract)"
else
    fail "5b: PostCompact JSON contract broken. got: '${HOOK_STDOUT:0:200}'"
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
