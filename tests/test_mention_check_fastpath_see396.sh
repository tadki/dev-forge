#!/bin/bash
# test_mention_check_fastpath_see396.sh
# Unit tests for SEE-396: PHASE 1 sentence extraction（SEE-1381 §SPEC-014 断言对齐现行实现：PHASE 2 reranker 退役、SEE-1333 D2 硬拦截）
# Covers all boundary scenarios from the issue spec
#
# Related Issue: SEE-396
# Test Type: Unit + Boundary + Regression
# Author: Bachi

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0
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
HOOK_SCRIPT="$PROJECT_ROOT/hooks/scripts/mention-check.sh"

run_hook() {
    local INPUT="$1"
    local STDOUT_FILE=$(mktemp /tmp/mention-check-see396-stdout.XXXXXX)
    local STDERR_FILE=$(mktemp /tmp/mention-check-see396-stderr.XXXXXX)

    echo "$INPUT" | bash "$HOOK_SCRIPT" > "$STDOUT_FILE" 2> "$STDERR_FILE"
    local EXIT_CODE=$?

    HOOK_STDOUT=$(cat "$STDOUT_FILE")
    HOOK_STDERR=$(cat "$STDERR_FILE")
    HOOK_EXIT=$EXIT_CODE

    rm -f "$STDOUT_FILE" "$STDERR_FILE"
}

assert_exit() {
    local expected="$1"
    local label="$2"
    if [ "$HOOK_EXIT" -eq "$expected" ]; then
        pass "$label — exit code is $expected"
    else
        fail "$label — exit code is $HOOK_EXIT, expected $expected"
    fi
}

assert_warning() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -qi "WARNING"; then
        pass "$label — WARNING present"
    else
        fail "$label — WARNING missing. stdout: '$HOOK_STDOUT'"
    fi
}

assert_no_warning() {
    local label="$1"
    if [ -z "$HOOK_STDOUT" ] || ! echo "$HOOK_STDOUT" | grep -qi "WARNING"; then
        pass "$label — no WARNING"
    else
        fail "$label — unexpected WARNING: $HOOK_STDOUT"
    fi
}

# SEE-1381 §SPEC-014 对齐现行实现：PHASE 2 reranker 已退役（migration），提及+
# 转述类句子不再产生 reference warning/deny——预期为无拦输出（透传）。
assert_mention_pass() {
    local label="$1"
    if [ -n "$HOOK_STDOUT" ] && ! echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
        pass "$label — passthrough (PHASE 2 retired, no reference warning)"
    else
        fail "$label — expected passthrough. stdout: '$HOOK_STDOUT'"
    fi
}

# SEE-1333 D2：no-mention 为硬 deny（exit 0 + ERROR 引导文案），非旧 WARNING 字样。
assert_deny_text() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q "缺少有效的 @mention"; then
        pass "$label — deny guidance text present"
    else
        fail "$label — deny guidance text missing. stdout: '$HOOK_STDOUT'"
    fi
}

assert_permission_deny() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"permissionDecision".*"deny"'; then
        pass "$label — permissionDecision=deny present"
    else
        fail "$label — permissionDecision=deny missing. stdout: '$HOOK_STDOUT'"
    fi
}

echo "============================================"
echo "  SEE-396 PHASE 1 Fast Path Unit Tests"
echo "  Date: $(date -Iseconds)"
echo "  Author: Bachi (Backend Agent)"
echo "  Branch: $(git branch --show-current)"
echo "============================================"

#####################################################################
# Prerequisite
#####################################################################
separator "Prerequisite"

if [ -f "$HOOK_SCRIPT" ]; then
    pass "Hook file exists"
else
    fail "Hook file MISSING at $HOOK_SCRIPT"
    exit 1
fi

if grep -q "Extract mention-bearing sentences" "$HOOK_SCRIPT"; then
    pass "Hook declares PHASE 1 sentence extraction"
else
    fail "Hook missing PHASE 1 sentence extraction declaration"
fi

if grep -q "actionNegationPatterns" "$HOOK_SCRIPT"; then
    fail "Hook still contains actionNegationPatterns (should be removed)"
else
    pass "actionNegationPatterns removed"
fi

if grep -q "refWeakPatterns" "$HOOK_SCRIPT"; then
    fail "Hook still contains refWeakPatterns (should be removed)"
else
    pass "refWeakPatterns removed"
fi

if grep -q "hasActionNegation" "$HOOK_SCRIPT"; then
    fail "Hook still contains hasActionNegation (should be removed)"
else
    pass "hasActionNegation removed"
fi

if grep -q "extractMentionSentences" "$HOOK_SCRIPT"; then
    pass "Hook contains extractMentionSentences function"
else
    fail "Hook missing extractMentionSentences function"
fi

if grep -q "isDirectCallOut" "$HOOK_SCRIPT"; then
    pass "Hook contains isDirectCallOut function"
else
    fail "Hook missing isDirectCallOut function"
fi

#####################################################################
# GROUP 1: Single mention + strong reference → PASS (PHASE 2 retired, SEE-1381 §SPEC-014)
# All mentions use correct [@Name] format
#####################################################################
separator "G1: Single mention + strong ref → PASS (PHASE 2 retired)"

# G1a: "Atlas 说" pattern + mention
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 说这个方案可行 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_exit 0 "G1a: Atlas说 + mention"
assert_mention_pass "G1a: Atlas说 + mention"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Revy 提到这个问题 [@Revy](mention://agent/2660961d)\""}}'
assert_exit 0 "G1b: Revy提到 + mention"
assert_mention_pass "G1b: Revy提到 + mention"

# G1c: "Bachi 认为" pattern
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Bachi 认为可以这样做 [@Bachi](mention://agent/a5c250e8)\""}}'
assert_exit 0 "G1c: Bachi认为 + mention"
assert_mention_pass "G1c: Bachi认为 + mention"

# G1d: "根据X的建议" pattern
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"根据 Bachi 的建议这个方案可行 [@Bachi](mention://agent/a5c250e8)\""}}'
assert_exit 0 "G1d: 根据建议 + mention"
assert_mention_pass "G1d: 根据建议 + mention"

# G1e: "Fronti 的观点" pattern
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Fronti 的观点很有道理 [@Fronti](mention://agent/23354e78)\""}}'
assert_exit 0 "G1e: 的观点 + mention"
assert_mention_pass "G1e: 的观点 + mention"

# G1f: "之前提到的" pattern
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"之前提到的方案需要调整 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_exit 0 "G1f: 之前提到 + mention"
assert_mention_pass "G1f: 之前提到 + mention"

# G1g: "Archi 建议" pattern
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Archi 建议用新架构 [@Archi](mention://agent/809951ab)\""}}'
assert_exit 0 "G1g: Archi建议 + mention"
assert_mention_pass "G1g: Archi建议 + mention"

# G1h: "Atlas 指出" pattern
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 指出了关键问题 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_exit 0 "G1h: Atlas指出 + mention"
assert_mention_pass "G1h: Atlas指出 + mention"

# G1i: member:// mention type + strong ref
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 说得对 [@Atlas](mention://member/some-user-id)\""}}'
assert_exit 0 "G1i: member:// + strong ref"
assert_mention_pass "G1i: member:// + strong ref"

#####################################################################
# GROUP 2: Single mention + NO strong reference → pass through to PHASE 2
#####################################################################
separator "G2: Single mention + no strong ref → PHASE 2 (pass or BLOCK via PHASE 2)"

# G2a: Plain mention, no ref pattern
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"[@Bachi](mention://agent/a5c250e8) 代码已经合并了\""}}'
assert_no_warning "G2a: plain mention, no ref"
assert_exit 0 "G2a: plain mention, no ref"

# G2b: Mention + action text (action no longer detected by PHASE 1, goes to PHASE 2)
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认这个 [@Bachi](mention://agent/a5c250e8)\""}}'
assert_no_warning "G2b: 请确认 + mention"
assert_exit 0 "G2b: 请确认 + mention"

# G2c: Mention + generic text
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"这个任务完成了 [@Bachi](mention://agent/a5c250e8)\""}}'
assert_no_warning "G2c: generic + mention"
assert_exit 0 "G2c: generic + mention"

# G2d: Mention + neutral text
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"收到，已确认 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_no_warning "G2d: neutral + mention"
assert_exit 0 "G2d: neutral + mention"

#####################################################################
# GROUP 3: Same sentence 2+ mentions → PHASE 2 (not BLOCK even with ref)
#####################################################################
separator "G3: Same sentence ≥2 mentions → PHASE 2"

# G3a: 2 mentions in same sentence + strong ref → should NOT BLOCK in PHASE 1
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 说这个方案可行，请确认 [@Atlas](mention://agent/fac3e3a1) 和 [@Bachi](mention://agent/a5c250e8)\""}}'
assert_no_warning "G3a: 2 mentions + strong ref → PHASE 2"
assert_exit 0 "G3a: 2 mentions + strong ref"

# G3b: 2 mentions, no ref → pass
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认 [@Atlas](mention://agent/fac3e3a1) 和 [@Bachi](mention://agent/a5c250e8) 都看一下\""}}'
assert_no_warning "G3b: 2 mentions, no ref"
assert_exit 0 "G3b: 2 mentions, no ref"

# G3c: 3 mentions in same sentence
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"[@Atlas](mention://agent/fac3e3a1) [@Bachi](mention://agent/a5c250e8) [@Revy](mention://agent/2660961d) 都确认一下\""}}'
assert_no_warning "G3c: 3 mentions"
assert_exit 0 "G3c: 3 mentions"

#####################################################################
# GROUP 4: Multi-sentence — each sentence 1 mention, one hits strong ref
#####################################################################
separator "G4: Multi-sentence, one sentence hits ref → PASS (PHASE 2 retired)"

# G4a: Two sentences, second has ref + mention
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"这个任务完成了。Atlas 说得对 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_mention_pass "G4a: second sentence ref + mention"
assert_exit 0 "G4a: second sentence ref + mention"

# G4b: Two sentences, first has ref + mention
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 说这个方案可行 [@Atlas](mention://agent/fac3e3a1)。已提交代码。\""}}'
assert_mention_pass "G4b: first sentence ref + mention"
assert_exit 0 "G4b: first sentence ref + mention"

# G4c: Two sentences, second has ref + mention (different pattern)
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"已确认。Revy 的观点很有道理 [@Revy](mention://agent/2660961d)\""}}'
assert_mention_pass "G4c: second sentence has ref + mention"
assert_exit 0 "G4c: second sentence has ref + mention"

#####################################################################
# GROUP 5: Multi-sentence, mentions in different sentences, no ref
#####################################################################
separator "G5: Multi-sentence, mentions spread, no ref → pass"

# G5a: Two sentences, each has 1 mention, no ref
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"[@Bachi](mention://agent/a5c250e8) 代码已合并。[@Revy](mention://agent/2660961d) 测试通过了\""}}'
assert_no_warning "G5a: two mentions in diff sentences, no ref"
assert_exit 0 "G5a: two mentions in diff sentences, no ref"

# G5b: Mix of sentences with and without mention
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"代码已完成。[@Bachi](mention://agent/a5c250e8) 请review。测试也通过了\""}}'
assert_no_warning "G5b: mention in one sentence, no ref"
assert_exit 0 "G5b: mention in one sentence, no ref"

#####################################################################
# GROUP 6: No mention → PHASE 0 blocks with NO_MENTION
#####################################################################
separator "G6: No mention → PHASE 0 blocks with NO_MENTION"

# G6a: Strong ref text but no mention link → PHASE 0 NO_MENTION
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 说这个方案可行\""}}'
assert_exit 0 "G6a: ref text, no mention → NO_MENTION"
assert_deny_text "G6a: ref text, no mention → NO_MENTION"
assert_permission_deny "G6a: ref text, no mention → NO_MENTION"

# G6b: Action text, no mention → PHASE 0 NO_MENTION
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认这个问题\""}}'
assert_exit 0 "G6b: action text, no mention → NO_MENTION"
assert_deny_text "G6b: action text, no mention → NO_MENTION"

# G6c: Plain text, no mention → PHASE 0 NO_MENTION
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"hello world\""}}'
assert_exit 0 "G6c: plain text, no mention → NO_MENTION"
assert_deny_text "G6c: plain text, no mention → NO_MENTION"

#####################################################################
# GROUP 7: Edge Cases
#####################################################################
separator "G7: Edge Cases"

# G7a: Empty content → PHASE 0 NO_MENTION (no mention found)
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"\""}}'
assert_exit 0 "G7a: empty content → NO_MENTION"
assert_deny_text "G7a: empty content → NO_MENTION"
assert_permission_deny "G7a: empty content → NO_MENTION"

# G7b: --content-stdin mode (no inline content to parse)
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content-stdin"}}'
assert_exit 0 "G7b: --content-stdin"
assert_no_warning "G7b: --content-stdin"

# G7c: Non-comment command
run_hook '{"tool_input":{"command":"git push origin main"}}'
assert_exit 0 "G7c: git push"
assert_no_warning "G7c: git push"

# G7d: mention://issue/ link (not agent/member) → no mention detected → NO_MENTION
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 说这个方案可行 [SEE-123](mention://issue/abc)\""}}'
assert_exit 0 "G7d: issue mention link → NO_MENTION"
assert_deny_text "G7d: issue mention link → NO_MENTION"

# G7e: Multiple sentence delimiters in a row + ref + mention
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"。。Atlas 说这个方案可行 [@Atlas](mention://agent/fac3e3a1)。。\""}}'
assert_mention_pass "G7e: multiple delimiters + ref + mention"
assert_exit 0 "G7e: multiple delimiters + ref + mention"

# G7f: Newline as sentence delimiter
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"已确认\\nAtlas 说得对 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_mention_pass "G7f: newline delimiter + ref + mention"
assert_exit 0 "G7f: newline delimiter + ref + mention"

# G7g: Short sentence filtered (< 2 chars) but mention still present
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"a [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_no_warning "G7g: short sentence with mention → PHASE 2"
assert_exit 0 "G7g: short sentence with mention"

#####################################################################
# GROUP 8: Regression — hook output format
#####################################################################
separator "G8: Regression Tests"

# G8a: SEE-1381 §SPEC-014 对齐现行实现——mention+转述句在 PHASE 2 退役后透传
# （无 reference deny）；deny 输出格式由 G6 组 no-mention 场景覆盖。
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 说这个方案可行 [@Atlas](mention://agent/fac3e3a1)\""}}'
if [ -n "$HOOK_STDOUT" ] && ! echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
    pass "G8a: mention+ref prose → passthrough (PHASE 2 retired)"
else
    fail "G8a: expected passthrough. stdout: '$HOOK_STDOUT'"
fi
if [ -n "$HOOK_STDOUT" ] && ! echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
    pass "G8a: no deny on mention-bearing prose (aligned)"
else
    fail "G8a: permissionDecision=deny missing. stdout: '$HOOK_STDOUT'"
fi

# G8b: Malformed JSON → pass
MALFORMED='{not valid json}'
echo "$MALFORMED" | bash "$HOOK_SCRIPT" > /dev/null 2>/dev/null
EC=$?
if [ "$EC" -eq 0 ]; then
    pass "G8b: malformed JSON → exit 0"
else
    fail "G8b: malformed JSON exit code $EC, expected 0"
fi

# G8c: BATCH_MODE=1 skips NO_MENTION
BATCH_RESULT=$(echo '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认这个问题\""}}' | BATCH_MODE=1 bash "$HOOK_SCRIPT" 2>/dev/null)
BATCH_EC=$?
if [ "$BATCH_EC" -eq 0 ]; then
    pass "G8c: BATCH_MODE=1 skips NO_MENTION"
else
    fail "G8c: BATCH_MODE=1 exit $BATCH_EC, expected 0. stdout: '$BATCH_RESULT'"
fi

# G8d: Passthrough when mention present + no ref
PASS_JSON='{"tool_input":{"command":"multica issue comment add test-issue --content \"[@Bachi](mention://agent/a5c250e8) 已完成\""},"session_id":"test-123"}'
STDOUT_FILE=$(mktemp /tmp/see396-regression.XXXXXX)
echo "$PASS_JSON" | bash "$HOOK_SCRIPT" > "$STDOUT_FILE" 2>/dev/null
ACTUAL=$(cat "$STDOUT_FILE")
rm -f "$STDOUT_FILE"
if [ "$ACTUAL" = "$PASS_JSON" ]; then
    pass "G8d: passthrough preserves JSON"
else
    fail "G8d: passthrough corrupted. Expected: $PASS_JSON, Got: $ACTUAL"
fi

# G8e: Non-comment command passthrough
NC_JSON='{"tool_input":{"command":"git push origin main"}}'
STDOUT_FILE2=$(mktemp /tmp/see396-regression2.XXXXXX)
echo "$NC_JSON" | bash "$HOOK_SCRIPT" > "$STDOUT_FILE2" 2>/dev/null
ACTUAL2=$(cat "$STDOUT_FILE2")
rm -f "$STDOUT_FILE2"
if [ "$ACTUAL2" = "$NC_JSON" ]; then
    pass "G8e: non-comment passthrough preserves JSON"
else
    fail "G8e: non-comment passthrough corrupted. Got: $ACTUAL2"
fi

#####################################################################
# SUMMARY
#####################################################################
separator "Summary"

echo ""
echo -e "${CYAN}Results:${NC}"
echo -e "  ${GREEN}Passed:${NC}    $PASS"
echo -e "  ${RED}Failed:${NC}    $FAIL"
echo -e "  ${YELLOW}Warnings:${NC}  $WARN"
echo ""

TOTAL=$((PASS + FAIL + WARN))
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
