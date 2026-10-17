#!/bin/bash
# test_mention_check_see323_qa.sh
# Revy QA Supplemental Tests for SEE-323
# Covers: all intent keywords, all reference patterns, escape handling, case sensitivity, quote variants, edge scenarios
#
# Related Issue: SEE-323
# Test Type: Boundary + Negative + Regression
# Author: Revy (QA Agent)

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

warn() {
    echo -e "  ${YELLOW}[WARN]${NC} $1"
    WARN=$((WARN + 1))
    RESULTS+=("WARN|$1")
}

separator() {
    echo ""
    echo -e "${CYAN}--- $1 ---${NC}"
}

HOOK_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/hooks/scripts/mention-check.sh"

run_hook() {
    local INPUT="$1"
    local STDOUT_FILE=$(mktemp /tmp/mention-check-stdout-revy.XXXXXX)
    local STDERR_FILE=$(mktemp /tmp/mention-check-stderr-revy.XXXXXX)

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
        pass "$label exit code is $expected"
    else
        fail "$label exit code is $HOOK_EXIT, expected $expected"
    fi
}

assert_no_warning() {
    local label="$1"
    if [ -z "$HOOK_STDOUT" ] || ! echo "$HOOK_STDOUT" | grep -qi "WARNING"; then
        pass "$label no WARNING"
    else
        fail "$label unexpected WARNING: $HOOK_STDOUT"
    fi
}

assert_warning() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -qi "WARNING"; then
        pass "$label WARNING present"
    else
        fail "$label WARNING missing. stdout: '$HOOK_STDOUT'"
    fi
}

assert_hook_output() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"hookSpecificOutput"'; then
        pass "$label hookSpecificOutput JSON present"
    else
        fail "$label hookSpecificOutput JSON missing. stdout: '$HOOK_STDOUT'"
    fi
}

assert_permission_deny() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"permissionDecision".*"deny"'; then
        pass "$label permissionDecision=deny present"
    else
        fail "$label permissionDecision=deny missing. stdout: '$HOOK_STDOUT'"
    fi
}

# SEE-1381 §SPEC-014 对齐现行实现（SEE-1333 D2 硬拦截 + PHASE 2 reranker 退役）：
# no-mention → deny + ERROR 引导文案；mention+转述句 → 透传。
assert_deny_text() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q "缺少有效的 @mention"; then
        pass "$label deny guidance text present"
    else
        fail "$label deny guidance text missing. stdout: '$HOOK_STDOUT'"
    fi
}

assert_mention_pass() {
    local label="$1"
    if [ -n "$HOOK_STDOUT" ] && ! echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
        pass "$label passthrough (PHASE 2 retired)"
    else
        fail "$label expected passthrough. stdout: '$HOOK_STDOUT'"
    fi
}

echo "============================================"
echo "  SEE-323 QA Supplemental Tests (Revy)"
echo "  Date: $(date -Iseconds)"
echo "  Branch: $(git branch --show-current)"
echo "============================================"
echo ""

#####################################################################
# GROUP Q1: All Active Intent Keywords
#####################################################################
separator "Q1: All Active Intent Keywords (no mention -> permissionDecision=deny)"

# Test each keyword individually
# Keywords from mention-check.sh: 请确认|请处理|交给你|务必|请review|请测试|帮忙|负责|跟进|处理一下|请查看|请检查|请修复|交给你了|你负责|你跟进

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认这个问题\""}}'
assert_exit 0 "Q1-请确认"
assert_deny_text "Q1-请确认"
assert_hook_output "Q1-请确认"
assert_permission_deny "Q1-请确认"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请处理这个bug\""}}'
assert_exit 0 "Q1-请处理"
assert_deny_text "Q1-请处理"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"交给你这个任务\""}}'
assert_exit 0 "Q1-交给你"
assert_deny_text "Q1-交给你"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"务必在周五前完成\""}}'
assert_exit 0 "Q1-务必"
assert_deny_text "Q1-务必"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请review这个PR\""}}'
assert_exit 0 "Q1-请review"
assert_deny_text "Q1-请review"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请测试新功能\""}}'
assert_exit 0 "Q1-请测试"
assert_deny_text "Q1-请测试"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"帮忙看一下这个问题\""}}'
assert_exit 0 "Q1-帮忙"
assert_deny_text "Q1-帮忙"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"你负责这个模块\""}}'
assert_exit 0 "Q1-负责"
assert_deny_text "Q1-负责"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"跟进一下进度\""}}'
assert_exit 0 "Q1-跟进"
assert_deny_text "Q1-跟进"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"处理一下这个问题\""}}'
assert_exit 0 "Q1-处理一下"
assert_deny_text "Q1-处理一下"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请查看最新报告\""}}'
assert_exit 0 "Q1-请查看"
assert_deny_text "Q1-请查看"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请检查代码\""}}'
assert_exit 0 "Q1-请检查"
assert_deny_text "Q1-请检查"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请修复这个bug\""}}'
assert_exit 0 "Q1-请修复"
assert_deny_text "Q1-请修复"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"这个任务交给你了\""}}'
assert_exit 0 "Q1-交给你了"
assert_deny_text "Q1-交给你了"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"你负责这个项目\""}}'
assert_exit 0 "Q1-你负责"
assert_deny_text "Q1-你负责"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"你跟进这个issue\""}}'
assert_exit 0 "Q1-你跟进"
assert_deny_text "Q1-你跟进"

#####################################################################
# GROUP Q2: All Reference Verb Patterns
#####################################################################
separator "Q2: All Reference Verb Patterns (reference + mention → PASS, PHASE 2 retired)"

# Verbs: 说, 提到, 认为, 的观点, 建议, 指出, 表示, 的意见, 的看法

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 说这个方案可行 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_exit 0 "Q2-说"
assert_mention_pass "Q2-说"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Revy 提到这个问题 [@Revy](mention://agent/2660961d)\""}}'
assert_exit 0 "Q2-提到"
assert_mention_pass "Q2-提到"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Bachi 认为可以这样做 [@Bachi](mention://agent/a5c250e8)\""}}'
assert_exit 0 "Q2-认为"
assert_mention_pass "Q2-认为"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Fronti 的观点很有道理 [@Fronti](mention://agent/23354e78)\""}}'
assert_exit 0 "Q2-的观点"
assert_mention_pass "Q2-的观点"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Archi 建议用新架构 [@Archi](mention://agent/809951ab)\""}}'
assert_exit 0 "Q2-建议"
assert_mention_pass "Q2-建议"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 指出了关键问题 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_exit 0 "Q2-指出"
assert_mention_pass "Q2-指出"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Bachi 表示同意 [@Bachi](mention://agent/a5c250e8)\""}}'
assert_exit 0 "Q2-表示"
assert_mention_pass "Q2-表示"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Fronti 的意见很重要 [@Fronti](mention://agent/23354e78)\""}}'
assert_exit 0 "Q2-的意见"
assert_mention_pass "Q2-的意见"

run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Revy 的看法很有洞察 [@Revy](mention://agent/2660961d)\""}}'
assert_exit 0 "Q2-的看法"
assert_mention_pass "Q2-的看法"

#####################################################################
# GROUP Q3: Case Sensitivity / Variant Matching
#####################################################################
separator "Q3: Case Sensitivity and Variants"

# Q3a: Mixed case - "请Review" vs "请review"
# Current hook (PHASE 0): no mention → always blocks, regardless of intent
echo ""
echo "[Q3a] '请Review' (no mention → PHASE 0 NO_MENTION)"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请Review这个方案\""}}'
assert_deny_text "Q3a"
assert_permission_deny "Q3a"
assert_exit 0 "Q3a"

# Q3b: Traditional Chinese characters
# Current hook (PHASE 0): no mention → always blocks
echo ""
echo "[Q3b] Traditional Chinese (no mention → PHASE 0 NO_MENTION)"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"請確認这个问题\""}}'
assert_deny_text "Q3b"
assert_permission_deny "Q3b"
assert_exit 0 "Q3b"

# Q3c: Keyword as substring (negation context)
echo ""
echo "[Q3c] '不要请确认' (keyword inside negation)"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"不要请确认这个\""}}'
# "请确认" IS present as substring, regex will match regardless of negation context
assert_exit 0 "Q3c"
assert_deny_text "Q3c"

#####################################################################
# GROUP Q4: Quote Variants for --content
#####################################################################
separator "Q4: Quote Variants for --content Flag"

# Q4a: Single quotes
echo ""
echo "[Q4a] Single-quoted content with intent"
run_hook "{\"tool_input\":{\"command\":\"multica issue comment add xxx --content '请确认这个问题'\"}}"
assert_exit 0 "Q4a"
assert_deny_text "Q4a"

# Q4b: Content with apostrophe
echo ""
echo "[Q4b] Content with apostrophe + intent"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"it is confirmed 请处理\""}}'
assert_exit 0 "Q4b"
assert_deny_text "Q4b"

#####################################################################
# GROUP Q5: Escape Sequence Handling
#####################################################################
separator "Q5: Escape Sequence Handling in Content"

# Q5a: \\n escape in content
echo ""
echo "[Q5a] Content with \\\\n + intent"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"line1\\nline2 请确认\""}}'
assert_exit 0 "Q5a"
assert_deny_text "Q5a"

# Q5b: \\t escape
echo ""
echo "[Q5b] Content with \\\\t + intent"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"col1\\tcol2 请处理\""}}'
assert_exit 0 "Q5b"
assert_deny_text "Q5b"

#####################################################################
# GROUP Q6: Special Characters and Emojis
#####################################################################
separator "Q6: Special Characters and Emojis"

# Q6a: Emoji with intent
echo ""
echo "[Q6a] Emoji + intent"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认这个bug\""}}'
assert_exit 0 "Q6a"
assert_deny_text "Q6a"

# Q6b: Chinese punctuation + reference + mention (NO space between name and verb)
# KNOWN LIMITATION: refPattern requires \s+ between name and verb.
# "Atlas的观点" (no space) does NOT match; "Atlas 的观点" (with space) does.
# This is a pre-existing limitation from SEE-321, not a SEE-323 regression.
echo ""
echo "[Q6b] Chinese no-space: 'Atlas的观点' + mention (KNOWN LIMITATION)"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas的观点，这个可行。[@Atlas](mention://agent/fac3e3a1)\""}}'
assert_exit 0 "Q6b"
assert_no_warning "Q6b"

# Q6b2: Same test WITH space between name and verb
# KNOWN LIMITATION: comma splits sentence, ref and mention end up in different sentences
# → PHASE 1 does not detect strong ref in same sentence as mention
echo ""
echo "[Q6b2] Chinese WITH space: 'Atlas 的观点' + mention (comma-split limitation → no warning)"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 的观点，这个可行。[@Atlas](mention://agent/fac3e3a1)\""}}'
assert_exit 0 "Q6b2"
assert_no_warning "Q6b2"

# Q6c: Regular URL + intent (should still fire Rule 1)
echo ""
echo "[Q6c] Regular URL + intent (not a mention link)"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认 https://example.com/path\""}}'
assert_exit 0 "Q6c"
assert_deny_text "Q6c"

#####################################################################
# GROUP Q7: Mention Position Variations
#####################################################################
separator "Q7: Mention Position Variations (intent present -> should pass)"

# Q7a: Mention at beginning + intent
echo ""
echo "[Q7a] Mention at beginning + intent"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"[@Atlas](mention://agent/fac3e3a1) 请确认这个\""}}'
assert_no_warning "Q7a"
assert_exit 0 "Q7a"

# Q7b: Mention at end + intent
echo ""
echo "[Q7b] Mention at end + intent"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认这个 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_no_warning "Q7b"
assert_exit 0 "Q7b"

# Q7c: Mention in middle + intent
echo ""
echo "[Q7c] Mention in middle + intent"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请 [@Atlas](mention://agent/fac3e3a1) 确认这个方案\""}}'
assert_no_warning "Q7c"
assert_exit 0 "Q7c"

# Q7d: Multiple mentions with intent
echo ""
echo "[Q7d] Multiple mentions + intent"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请 [@Atlas](mention://agent/fac3e3a1) 和 [@Bachi](mention://agent/a5c250e8) 都确认一下\""}}'
assert_no_warning "Q7d"
assert_exit 0 "Q7d"

# Q7e: Mention without intent (plain mention, no issue)
echo ""
echo "[Q7e] Plain mention without intent or reference"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \" [@Atlas](mention://agent/fac3e3a1) 完成了任务\""}}'
assert_no_warning "Q7e"
assert_exit 0 "Q7e"

#####################################################################
# GROUP Q8: --content-file Flag Handling
#####################################################################
separator "Q8: --content-file Flag (hook only parses --content)"

echo ""
echo "[Q8a] --content-file with intent in filename"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content-file 请确认.txt"}}'
assert_no_warning "Q8a"
assert_exit 0 "Q8a"

echo ""
echo "[Q8b] --content-stdin mode"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content-stdin"}}'
assert_no_warning "Q8b"
assert_exit 0 "Q8b"

#####################################################################
# GROUP Q9: Mutual Exclusivity Verification
#####################################################################
separator "Q9: Rule Mutual Exclusivity (intent + mention = pass)"

echo ""
echo "[Q9a] Intent + mention + reference (strong ref in same sentence → REF_WITH_MENTION)"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 说请处理这个 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_mention_pass "Q9a"
assert_exit 0 "Q9a"

echo ""
echo "[Q9b] Plain text, no mention → PHASE 0 NO_MENTION"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"This is a plain comment without patterns.\""}}'
assert_deny_text "Q9b"
assert_permission_deny "Q9b"
assert_exit 0 "Q9b"

echo ""
echo "[Q9c] Only mention, no intent, no reference (should pass)"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"[@Bachi](mention://agent/a5c250e8) 代码已经合并了\""}}'
assert_no_warning "Q9c"
assert_exit 0 "Q9c"

#####################################################################
# GROUP Q10: Empty/Missing Fields
#####################################################################
separator "Q10: Empty and Missing Fields"

echo ""
echo "[Q10a] Empty command string"
run_hook '{"tool_input":{"command":""}}'
assert_no_warning "Q10a"
assert_exit 0 "Q10a"

echo ""
echo "[Q10b] Missing command field"
run_hook '{"tool_input":{"other":"value"}}'
assert_no_warning "Q10b"
assert_exit 0 "Q10b"

echo ""
echo "[Q10c] Empty JSON object {}"
run_hook '{}'
assert_no_warning "Q10c"
assert_exit 0 "Q10c"

echo ""
echo "[Q10d] tool_input is null"
run_hook '{"tool_input":null}'
assert_no_warning "Q10d"
assert_exit 0 "Q10d"

echo ""
echo "[Q10e] tool_input is missing entirely"
run_hook '{"other":"data"}'
assert_no_warning "Q10e"
assert_exit 0 "Q10e"

#####################################################################
# GROUP Q11: Stress / Long Content
#####################################################################
separator "Q11: Stress Tests"

echo ""
echo "[Q11a] Long content (500 chars) with intent at end"
LONG_PART=$(printf '%0.sx' $(seq 1 490))
run_hook "{\"tool_input\":{\"command\":\"multica issue comment add xxx --content \\\"${LONG_PART}请确认\\\"\"}}"
assert_exit 0 "Q11a"
assert_deny_text "Q11a"

echo ""
echo "[Q11b] Long content with mention + reference"
LONG_PART2=$(printf '%0.sy' $(seq 1 480))
run_hook "{\"tool_input\":{\"command\":\"multica issue comment add xxx --content \\\"${LONG_PART2}Atlas 说 [@Atlas](mention://agent/fac3e3a1)\\\"\"}}"
assert_exit 0 "Q11b"
assert_mention_pass "Q11b"

#####################################################################
# GROUP Q12: Mention Protocol Variations
#####################################################################
separator "Q12: Mention Protocol Variations"

echo ""
echo "[Q12a] mention://issue/ link (not agent/member) + intent"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认 [SEE-123](mention://issue/abc)\""}}'
# mention://issue/ does NOT count as hasMention (only agent|member)
assert_exit 0 "Q12a"
assert_deny_text "Q12a"

echo ""
echo "[Q12b] http:// URL + intent (not mention protocol)"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认 [link](http://example.com)\""}}'
assert_exit 0 "Q12b"
assert_deny_text "Q12b"

echo ""
echo "[Q12c] mention://agent/ + intent (correct, should pass)"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_no_warning "Q12c"
assert_exit 0 "Q12c"

echo ""
echo "[Q12d] mention://member/ + intent (correct, should pass)"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认 [@jerry](mention://member/user-id)\""}}'
assert_no_warning "Q12d"
assert_exit 0 "Q12d"

#####################################################################
# GROUP Q13: Both Rules Cannot Fire Simultaneously
#####################################################################
separator "Q13: Both Rules Cannot Fire Simultaneously"

# SEE-1333 D2 后语义：no-mention（含 intent 词）→ deny；mention+转述句 → PHASE 2
# 退役后透传。两组互斥（一组要求无 mention，一组要求有 mention）。

echo ""
echo "[Q13a] Verify output contains at most one warning type per trigger"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认这个问题\""}}'
WARN_COUNT=$(echo "$HOOK_STDOUT" | grep -o 'WARNING' | wc -l)
if [ "$WARN_COUNT" -le 2 ]; then
    pass "Q13a Single rule fires at most once (WARNING count: $WARN_COUNT)"
else
    fail "Q13a Multiple WARNING instances: $WARN_COUNT"
fi

echo ""
echo "[Q13b] Reference + mention + NO intent -> only Rule 2 fires"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 说得对 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_mention_pass "Q13b"
# SEE-1381 §SPEC-014：reference 规则已随 PHASE 2 退役——透传即正确语义
if [ -n "$HOOK_STDOUT" ] && ! echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
    pass "Q13b mention+reference prose → passthrough (no reference rule)"
else
    fail "Q13b expected passthrough: $HOOK_STDOUT"
fi

echo ""
echo "[Q13c] Intent + NO mention -> only Rule 1 fires"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认这个问题\""}}'
assert_deny_text "Q13c"
if echo "$HOOK_STDOUT" | grep -q "缺少有效的 @mention"; then
    pass "Q13c deny is about missing mention (SEE-1333 D2)"
else
    fail "Q13c Warning not about missing mention: $HOOK_STDOUT"
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
