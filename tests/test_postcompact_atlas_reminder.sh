#!/bin/bash
# SEE-1621: atlas-postcompact-reminder 引擎行为测试（§SPEC-003/§SPEC-004）
# 被测对象 = 真实引擎链（claude-hooks/unified/ 入口 + engine.js）+ 真实生产规则
# （不注入 UNIFIED_RULES_FILE —— findConfigFile 首选部署位 rules-v2.json，
#  即本仓检出的生产规则，规则命中行为而非仅 JSON 结构）。
# 判据：
#   - agent=Atlas 的 PostCompact payload 注入 additionalContext，文案覆盖
#     「已经被压缩」/ /task-explore / /recall owner-order / owner-order 页面 ID
#     kp-cb6e073b333974583acdc872916438ff / /task-run；exit 0；无 deny 输出。
#   - 非 Atlas（Bachi/Revy/未设）不触发该规则（透传原 stdin）。
#   - 无 repo 过滤：两个不同 repo/cwd 上下文均命中。
#   - 未配置 one_shot：同一 session 连续两次 PostCompact 均重新注入，且零 sentinel 写入。
#   - 其他事件（SessionEnd/PostToolUse）不误触发。
# Run: bash tests/test_postcompact_atlas_reminder.sh
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0; RESULTS=()
pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); RESULTS+=("PASS|$1"); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); RESULTS+=("FAIL|$1"); }
separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTRY="$REPO_ROOT/claude-hooks/unified/unified-hook.sh"
ENGINE="$REPO_ROOT/claude-hooks/unified/engine.js"
RULES_FILE="$REPO_ROOT/claude-hooks/unified/rules-v2.json"
FIXTURE="$(mktemp -d /tmp/postcompact-atlas.XXXXXX)"
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

# 入口层运行（unified-hook.sh）：cwd 切入目标 repo 目录，注册链/引擎自定位真实部署位
run_entry() {
    local AGENT="$1" PAYLOAD="$2" REPO_DIR="$3"
    : > "$FIRELOG"
    printf '%s' "$PAYLOAD" > "$FIXTURE/stdin.json"
    HOOK_STDOUT=$(cd "$REPO_DIR" && \
        HOOK_FIRE_LOG="$FIRELOG" \
        HOOK_STATE_DIR="$STATE" \
        MULTICA_AGENT_NAME="$AGENT" \
        PROJECT_ROOT="$REPO_DIR" \
        HOME="$FAKE_HOME" \
        bash "$ENTRY" < "$FIXTURE/stdin.json" 2>/dev/null)
    HOOK_EXIT=$?
    HOOK_STDIN=$(cat "$FIXTURE/stdin.json")
}

# 引擎直跑（engine.js）：真实生产规则 + 真实引擎主流程（firelog 审计断言用）
run_engine() {
    local AGENT="$1" PAYLOAD="$2" REPO_DIR="$3"
    : > "$FIRELOG"
    printf '%s' "$PAYLOAD" > "$FIXTURE/stdin.json"
    HOOK_STDOUT=$(cd "$REPO_DIR" && \
        HOOK_FIRE_LOG="$FIRELOG" \
        HOOK_STATE_DIR="$STATE" \
        MULTICA_AGENT_NAME="$AGENT" \
        PROJECT_ROOT="$REPO_DIR" \
        node "$ENGINE" < "$FIXTURE/stdin.json" 2>/dev/null)
    HOOK_EXIT=$?
}

assert_exit_0() {
    local label="$1"
    if [ "$HOOK_EXIT" -eq 0 ]; then pass "$label — exit 0"; else fail "$label — exit $HOOK_EXIT"; fi
}

assert_context_has() {
    local label="$1" fragment="$2"
    if echo "$HOOK_STDOUT" | grep -q '"additionalContext"' && echo "$HOOK_STDOUT" | grep -F -q "$fragment"; then
        pass "$label — 含 '$fragment'"
    else
        fail "$label — additionalContext 缺失或不含 '$fragment'. got: '${HOOK_STDOUT:0:200}'"
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

ATLAS_POSTCOMPACT='{"hook_event_name":"PostCompact","trigger":"manual","compact_summary":"SEE-1621 任务上下文压缩","session_id":"sess-postcompact-1","cwd":"'"$REPO_A"'"}'

echo "============================================================"
echo "  SEE-1621: atlas-postcompact-reminder engine behavior"
echo "  Date: $(date -Iseconds)"
echo "============================================================"

separator "Prerequisites"
[ -f "$ENTRY" ] && pass "unified-hook.sh exists" || { fail "unified-hook.sh MISSING"; exit 1; }
[ -f "$ENGINE" ] && pass "engine.js exists" || { fail "engine.js MISSING"; exit 1; }
node -e "const c=JSON.parse(require('fs').readFileSync('$RULES_FILE','utf8')); const r=c.rules.find(x=>x.name==='atlas-postcompact-reminder'); process.exit(r?0:1)" 2>/dev/null \
    && pass "rules-v2.json declares atlas-postcompact-reminder" \
    || { fail "atlas-postcompact-reminder missing from rules-v2.json（规则未登记）"; }

#####################################################################
# 1. Atlas PostCompact → 注入完整提醒文案，exit 0，无 deny
#####################################################################
separator "1. Atlas PostCompact fires full reminder (no deny)"
run_entry "Atlas" "$ATLAS_POSTCOMPACT" "$REPO_A"
assert_exit_0 "1a: entry exit 0"
assert_no_deny "1b: no deny output (non-blocking context contract)"
assert_context_has "1c: 压缩事实" "已经被压缩"
assert_context_has "1d: /task-explore 探索指令" "/task-explore"
assert_context_has "1e: owner-order 召回命令" "/recall owner-order"
assert_context_has "1f: owner-order 页面 ID" "kp-cb6e073b333974583acdc872916438ff"
assert_context_has "1g: Leader /task-run 要求" "/task-run"
if echo "$HOOK_STDOUT" | grep -q '"hookEventName":"PostCompact"'; then
    pass "1h: hookEventName=PostCompact"
else
    fail "1h: hookEventName != PostCompact. got: '${HOOK_STDOUT:0:200}'"
fi

# 引擎直跑 + firelog 审计（真实引擎行为留痕）
run_engine "Atlas" "$ATLAS_POSTCOMPACT" "$REPO_A"
assert_exit_0 "1i: engine direct exit 0"
assert_context_has "1j: engine direct context" "已经被压缩"
assert_firelog_has "1k: firelog event line" "event=PostCompact agent=Atlas"
assert_firelog_has "1l: firelog action=context" "action=context"

#####################################################################
# 2. 非 Atlas 不触发（透传原 stdin）
#####################################################################
separator "2. Non-Atlas agents do not trigger"
for AG in Bachi Revy ""; do
    run_entry "$AG" "$ATLAS_POSTCOMPACT" "$REPO_A"
    assert_no_context "2[${AG:-<unset>}]: no context for agent='${AG:-<unset>}'"
    assert_passthrough "2[${AG:-<unset>}]: passthrough stdin"
done

#####################################################################
# 3. 跨仓库命中（规则无 repo 过滤：两个不同 repo/cwd 上下文均触发）
#####################################################################
separator "3. Cross-repo hit (no repo filter)"
run_entry "Atlas" "$ATLAS_POSTCOMPACT" "$REPO_A"
assert_context_has "3a: repo-alpha fires" "已经被压缩"
run_entry "Atlas" "$ATLAS_POSTCOMPACT" "$REPO_B"
assert_context_has "3b: repo-beta fires too" "已经被压缩"

#####################################################################
# 4. 同一 session 连续两次 PostCompact 均重新提醒（未配置 one_shot），
#    且零 sentinel 写入（可重复触发契约）
#####################################################################
separator "4. Same-session repeated PostCompact re-fires (no one_shot)"
run_entry "Atlas" "$ATLAS_POSTCOMPACT" "$REPO_A"
assert_context_has "4a: first PostCompact fires" "已经被压缩"
run_entry "Atlas" "$ATLAS_POSTCOMPACT" "$REPO_A"
assert_context_has "4b: second PostCompact fires again" "已经被压缩"
# 无 one_shot 哨兵（.hook-fired-*）；pending-* 标记是 R2 补投路线的合法状态，不计入。
SENTINEL_LEFT=$(ls "$STATE" 2>/dev/null | grep -c "^\.hook-fired-" || true)
SENTINEL_TMP=$(ls /tmp/.hook-fired-atlas-postcompact-reminder* 2>/dev/null | wc -l)
if [ "$SENTINEL_LEFT" -eq 0 ] && [ "$SENTINEL_TMP" -eq 0 ]; then
    pass "4c: zero one_shot sentinel writes (repeatable by design)"
else
    fail "4c: one_shot sentinel residue state=$SENTINEL_LEFT tmp=$SENTINEL_TMP"
fi

#####################################################################
# 5. 其他事件不误触发
#####################################################################
separator "5. Other events do not mis-fire"
run_entry "Atlas" '{"hook_event_name":"SessionEnd","session_id":"sess-postcompact-1"}' "$REPO_A"
assert_no_context "5a: SessionEnd does not mis-fire"
assert_passthrough "5a: SessionEnd passthrough"
run_entry "Atlas" '{"hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"/x/a.md"},"session_id":"sess-postcompact-1"}' "$REPO_A"
assert_no_context "5b: PostToolUse does not mis-fire (plain payload)"

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
