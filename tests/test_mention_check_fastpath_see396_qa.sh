#!/bin/bash
# test_mention_check_fastpath_see396_qa.sh
# Independent QA tests for SEE-396 by Revy (QA Agent)
# Covers edge cases and strong ref patterns not tested by Bachi's unit tests
#
# Related Issue: SEE-396
# Test Type: QA / Boundary / Regression
# Author: Revy

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

PROJECT_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SCRIPT="$PROJECT_ROOT/hooks/scripts/mention-check.sh"

run_hook() {
    local INPUT="$1"
    local STDOUT_FILE=$(mktemp /tmp/mention-check-see396-qa-stdout.XXXXXX)
    local STDERR_FILE=$(mktemp /tmp/mention-check-see396-qa-stderr.XXXXXX)

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
        fail "$label — exit code is $HOOK_EXIT, expected $expected (stdout: $HOOK_STDOUT)"
    fi
}

# SEE-1381 §SPEC-014 对齐现行实现：PHASE 2 reranker 退役——提及+转述句不再
# reference-warning/deny，预期为无拦输出（透传）；hook 恒 exit 0。
assert_mention_pass() {
    local label="$1"
    if [ -n "$HOOK_STDOUT" ] && ! echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
        pass "$label — passthrough (PHASE 2 retired)"
    else
        fail "$label — expected passthrough. stdout: '$HOOK_STDOUT'"
    fi
}

# SEE-1333 D2：no-mention 为硬 deny（exit 0 + ERROR 引导文案）。
assert_deny_text() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q "缺少有效的 @mention"; then
        pass "$label — deny guidance text present"
    else
        fail "$label — deny guidance text missing. stdout: '$HOOK_STDOUT'"
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

assert_json_output() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"hookSpecificOutput"'; then
        pass "$label — hookSpecificOutput JSON present"
    else
        fail "$label — hookSpecificOutput JSON missing. stdout: '$HOOK_STDOUT'"
    fi
}

echo "============================================"
echo "  SEE-396 PHASE 1 Fast Path QA Tests"
echo "  Date: $(date -Iseconds)"
echo "  Author: Revy (QA Agent)"
echo "  Branch: $(git branch --show-current)"
echo "============================================"

#####################################################################
# R1: All strong reference patterns, single mention -> PASS（PHASE 2 retired，
# SEE-1381 §SPEC-014 对齐现行实现；历史 BLOCK 语义见 git 历史）
#####################################################################
separator "R1: All strong ref patterns with single mention → PASS (PHASE 2 retired)"

# R1a: Pattern 1 — "Atlas 说" (agent name + verb)
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 说这个很好 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_exit 0 "R1a: Pattern 1 (name+说)"
assert_mention_pass "R1a: Pattern 1 (name+说)"

# R1b: Pattern 1 variant — "Chekky 表示"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Chekky 表示没问题 [@Chekky](mention://agent/b2384294)\""}}'
assert_exit 0 "R1b: Pattern 1 variant (Chekky+表示)"
assert_mention_pass "R1b: Pattern 1 variant (Chekky+表示)"

# R1c: Pattern 1 variant — "Refacty 指出"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Refacty 指出代码问题 [@Refacty](mention://agent/3c6b6d88)\""}}'
assert_exit 0 "R1c: Pattern 1 variant (Refacty+指出)"
assert_mention_pass "R1c: Pattern 1 variant (Refacty+指出)"

# R1d: Pattern 1 with .{0,3} space — "Fronti 的观点"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Fronti 的观点很好 [@Fronti](mention://agent/23354e78)\""}}'
assert_exit 0 "R1d: Pattern 1 with space (Fronti+观点)"
assert_mention_pass "R1d: Pattern 1 with space (Fronti+观点)"

# R1e: Pattern 2 — "根据 Bachi 的建议"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"根据 Bachi 的建议我们这样做 [@Bachi](mention://agent/a5c250e8)\""}}'
assert_exit 0 "R1e: Pattern 2 (根据...建议)"
assert_mention_pass "R1e: Pattern 2 (根据...建议)"

# R1f: Pattern 2 variant — "根据 Revy 的测试结论"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"根据 Revy 的测试结论一切正常 [@Revy](mention://agent/2660961d)\""}}'
assert_exit 0 "R1f: Pattern 2 variant (根据...结论)"
assert_mention_pass "R1f: Pattern 2 variant (根据...结论)"

# R1g: Pattern 3 — "正如上文所述"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"正如上文所述这个方案可行 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_exit 0 "R1g: Pattern 3 (正如上文所述)"
assert_mention_pass "R1g: Pattern 3 (正如上文所述)"

# R1h: Pattern 3 variant — "如之前所讨论"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"如之前所讨论我们采用方案A [@Bachi](mention://agent/a5c250e8)\""}}'
assert_exit 0 "R1h: Pattern 3 variant (如之前所讨论)"
assert_mention_pass "R1h: Pattern 3 variant (如之前所讨论)"

# R1i: Pattern 4 — "上面提到的"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"上面提到的方案需要调整 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_exit 0 "R1i: Pattern 4 (上面提到的)"
assert_mention_pass "R1i: Pattern 4 (上面提到的)"

# R1j: Pattern 4 variant — "前面说到的" (NOTE: Pattern 4 expects "说的" not "说到的", falls through to PHASE 2)
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"前面说到的内容已经更新 [@Bachi](mention://agent/a5c250e8)\""}}'
assert_no_warning "R1j: Pattern 4 variant (前面说到的) → PHASE 2 (no match)"
assert_exit 0 "R1j: Pattern 4 variant (前面说到的) → PHASE 2"

# R1k: Pattern 5 — "他说" (NOTE: Pattern 5 requires suffix like "的/对/有道理" after verb; bare "他说" falls through)
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"他说这个没问题 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_no_warning "R1k: Pattern 5 (他说) → PHASE 2 (no suffix match)"
assert_exit 0 "R1k: Pattern 5 (他说) → PHASE 2"

# R1l: Pattern 5 variant — "她认为"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"她认为方案可行 [@Revy](mention://agent/2660961d)\""}}'
assert_exit 0 "R1l: Pattern 5 variant (她认为)"
assert_mention_pass "R1l: Pattern 5 variant (她认为)"

# R1m: Pattern 5 variant — "他们指出" (NOTE: Pattern 5 requires suffix immediately after verb)
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"他们指出关键问题 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_no_warning "R1m: Pattern 5 variant (他们指出) → PHASE 2 (no suffix match)"
assert_exit 0 "R1m: Pattern 5 variant (他们指出) → PHASE 2"

# R1n: Pattern 6 — "引用了"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"引用了 Atlas 的观点 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_exit 0 "R1n: Pattern 6 (引用了)"
assert_mention_pass "R1n: Pattern 6 (引用了)"

# R1o: Pattern 6 variant — "转述了"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"转述了 Bachi 的说法 [@Bachi](mention://agent/a5c250e8)\""}}'
assert_exit 0 "R1o: Pattern 6 variant (转述了)"
assert_mention_pass "R1o: Pattern 6 variant (转述了)"

# R1p: Pattern 6 variant — "复述"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"复述一下 Atlas 的意见 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_exit 0 "R1p: Pattern 6 variant (复述)"
assert_mention_pass "R1p: Pattern 6 variant (复述)"

#####################################################################
# R2: Strong ref WITHOUT mention -> NO_MENTION (not REF_WITH_MENTION)
#####################################################################
separator "R2: Strong ref without mention -> NO_MENTION"

# R2a: Pattern 1 without mention
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 说这个很好\""}}'
assert_exit 0 "R2a: Pattern 1 no mention"
assert_deny_text "R2a: Pattern 1 no mention"

# R2b: Pattern 2 without mention
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"根据 Bachi 的建议\""}}'
assert_exit 0 "R2b: Pattern 2 no mention"
assert_deny_text "R2b: Pattern 2 no mention"

# R2c: Pattern 5 without mention
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"他说没问题\""}}'
assert_exit 0 "R2c: Pattern 5 no mention"
assert_deny_text "R2c: Pattern 5 no mention"

# R2d: Pattern 6 without mention
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"引用了 Atlas 的观点\""}}'
assert_exit 0 "R2d: Pattern 6 no mention"
assert_deny_text "R2d: Pattern 6 no mention"

#####################################################################
# R3: ≥2 mentions in same sentence -> PHASE 2 (never BLOCK in PHASE 1)
#####################################################################
separator "R3: Same sentence >=2 mentions -> PHASE 2"

# R3a: 2 mentions + strong ref in same sentence -> should NOT block in PHASE 1
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 说很好 [@Atlas](mention://agent/fac3e3a1) 和 [@Bachi](mention://agent/a5c250e8)\""}}'
assert_no_warning "R3a: 2 mentions + ref -> PHASE 2"
assert_exit 0 "R3a: 2 mentions + ref -> PHASE 2"

# R3b: 2 mentions separated by comma (chinese) + strong ref
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 说了，[@Atlas](mention://agent/fac3e3a1)，[@Bachi](mention://agent/a5c250e8) 请确认\""}}'
assert_no_warning "R3b: 2 mentions comma sep + ref -> PHASE 2"
assert_exit 0 "R3b: 2 mentions comma sep + ref -> PHASE 2"

# R3c: Exactly 2 mentions, no ref -> pass
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"[@Atlas](mention://agent/fac3e3a1) [@Bachi](mention://agent/a5c250e8) 请查看\""}}'
assert_no_warning "R3c: 2 mentions no ref -> pass"
assert_exit 0 "R3c: 2 mentions no ref -> pass"

# R3d: 4 mentions in same sentence
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"[@Atlas](mention://agent/fac3e3a1)[@Bachi](mention://agent/a5c250e8)[@Revy](mention://agent/2660961d)[@Archi](mention://agent/809951ab) 全体注意\""}}'
assert_no_warning "R3d: 4 mentions -> PHASE 2"
assert_exit 0 "R3d: 4 mentions -> PHASE 2"

#####################################################################
# R4: Multi-sentence boundary cases
#####################################################################
separator "R4: Multi-sentence boundary cases"

# R4a: Semicolon delimiter between sentences
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"任务完成；Atlas 说得对 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_mention_pass "R4a: semicolon delimiter"
assert_exit 0 "R4a: semicolon delimiter"

# R4b: Exclamation mark delimiter
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"完成了！Atlas 说得对 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_mention_pass "R4b: exclamation delimiter"
assert_exit 0 "R4b: exclamation delimiter"

# R4c: Question mark delimiter
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"完成了？Atlas 说得对 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_mention_pass "R4c: question delimiter"
assert_exit 0 "R4c: question delimiter"

# R4d: Chinese semicolon delimiter
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"任务完成；Bachi 认为可行 [@Bachi](mention://agent/a5c250e8)\""}}'
assert_mention_pass "R4d: chinese semicolon delimiter"
assert_exit 0 "R4d: chinese semicolon delimiter"

# R4e: Mixed delimiters
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"任务完成。下一步？Atlas 说得对 [@Atlas](mention://agent/fac3e3a1)！\""}}'
assert_mention_pass "R4e: mixed delimiters"
assert_exit 0 "R4e: mixed delimiters"

# R4f: Newline + tab as delimiters
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"任务完成\tAtlas 说得对 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_mention_pass "R4f: tab delimiter"
assert_exit 0 "R4f: tab delimiter"

# R4g: Sentence with 2 mentions, next sentence with 1 mention + ref
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"[@Atlas](mention://agent/fac3e3a1) 和 [@Bachi](mention://agent/a5c250e8) 请查看。Revy 认为通过 [@Revy](mention://agent/2660961d)\""}}'
assert_mention_pass "R4g: 2-mention sentence + ref sentence"
assert_exit 0 "R4g: 2-mention sentence + ref sentence"

# R4h: Sentence with ref+mention, next sentence with 2 mentions
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 说得对 [@Atlas](mention://agent/fac3e3a1)。[@Bachi](mention://agent/a5c250e8) 和 [@Revy](mention://agent/2660961d) 请确认\""}}'
assert_mention_pass "R4h: ref sentence + 2-mention sentence"
assert_exit 0 "R4h: ref sentence + 2-mention sentence"

#####################################################################
# R5: Negative cases — no false positives
#####################################################################
separator "R5: Negative cases — no false positives"

# R5a: Generic text with single mention, no ref pattern
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"[@Bachi](mention://agent/a5c250e8) 你好\""}}'
assert_no_warning "R5a: generic greeting + mention"
assert_exit 0 "R5a: generic greeting + mention"

# R5b: Action-like text with single mention (PHASE 1 no longer blocks actions)
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"[@Bachi](mention://agent/a5c250e8) 请处理这个任务\""}}'
assert_no_warning "R5b: action + mention -> PHASE 2"
assert_exit 0 "R5b: action + mention -> PHASE 2"

# R5c: "Bachi 这个观点" matches Pattern 1 (agent name + .{0,3} + 观点) — this IS a ref pattern
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"[@Bachi](mention://agent/a5c250e8) 这个观点我同意\""}}'
assert_mention_pass "R5c: Bachi + 观点 matches Pattern 1"
assert_exit 0 "R5c: Bachi + 观点 matches Pattern 1"

# R5d: "建议" as a verb, not "根据...的建议"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"[@Bachi](mention://agent/a5c250e8) 我建议用方案A\""}}'
assert_no_warning "R5d: 建议 as verb, not ref pattern"
assert_exit 0 "R5d: 建议 as verb, not ref pattern"

# R5e: "提到" as action, not ref pattern (no name before it)
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"[@Bachi](mention://agent/a5c250e8) 我提到这个问题\""}}'
assert_no_warning "R5e: 提到 without name prefix"
assert_exit 0 "R5e: 提到 without name prefix"

# R5f: Long generic text with single mention
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"[@Bachi](mention://agent/a5c250e8) 这是一个很长的普通文本，没有任何引用模式，也没有动作关键词，只是普通的描述性文字，应该顺利通过第一阶段快速路径检查。\""}}'
assert_no_warning "R5f: long generic text + mention"
assert_exit 0 "R5f: long generic text + mention"

#####################################################################
# R6: Content format edge cases
#####################################################################
separator "R6: Content format edge cases"

# R6a: Content with markdown bold
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"**Atlas 说得对** [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_mention_pass "R6a: markdown bold + ref + mention"
assert_exit 0 "R6a: markdown bold + ref + mention"

# R6b: Content with markdown code inline
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"`Atlas 说得对` [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_mention_pass "R6b: inline code + ref + mention"
assert_exit 0 "R6b: inline code + ref + mention"

# R6c: Content with backslash escapes in JSON — escaped mention not detected, strong ref triggers NO_MENTION
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 说得对 \\[\\@Atlas\\](mention://agent/fac3e3a1)\""}}'
assert_exit 0 "R6c: backslash escapes → NO_MENTION (no real mention)"
assert_deny_text "R6c: backslash escapes → NO_MENTION"

# R6d: Unicode characters in content
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \" Atlas 说得对 [@Atlas](mention://agent/fac3e3a1)\""}}'
assert_mention_pass "R6d: unicode emoji + ref + mention"
assert_exit 0 "R6d: unicode emoji + ref + mention"

#####################################################################
# R7: PHASE 0 behavior verification
#####################################################################
separator "R7: PHASE 0 behavior verification"

# R7a: No mention, ref text -> NO_MENTION
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 说得对\""}}'
assert_exit 0 "R7a: no mention + ref -> NO_MENTION"
assert_deny_text "R7a: no mention + ref -> NO_MENTION"
assert_json_output "R7a: JSON output on block"

# R7b: No mention, action text -> NO_MENTION
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认这个问题\""}}'
assert_exit 0 "R7b: no mention + action -> NO_MENTION"
assert_deny_text "R7b: no mention + action -> NO_MENTION"

# R7c: BATCH_MODE=1 with no mention -> pass
BATCH_RESULT=$(echo '{"tool_input":{"command":"multica issue comment add xxx --content "请确认这个问题""}}' | BATCH_MODE=1 bash "$HOOK_SCRIPT" 2>/dev/null)
BATCH_EC=$?
if [ "$BATCH_EC" -eq 0 ]; then
    pass "R7c: BATCH_MODE=1 skips NO_MENTION"
else
    fail "R7c: BATCH_MODE=1 exit $BATCH_EC, expected 0"
fi

# R7d: Only issue mention, no agent/member -> NO_MENTION
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 说得对 [SEE-123](mention://issue/abc)\""}}'
assert_exit 0 "R7d: issue mention only -> NO_MENTION"
assert_deny_text "R7d: issue mention only -> NO_MENTION"

#####################################################################
# R8: Regression — passthrough and format
#####################################################################
separator "R8: Regression tests"

# R8a: Passthrough preserves JSON when no warning
PASS_JSON='{"tool_input":{"command":"multica issue comment add test-issue --content "[@Bachi](mention://agent/a5c250e8) 已完成""},"session_id":"test-123"}'
STDOUT_FILE=$(mktemp /tmp/see396-qa-regression.XXXXXX)
echo "$PASS_JSON" | bash "$HOOK_SCRIPT" > "$STDOUT_FILE" 2>/dev/null
ACTUAL=$(cat "$STDOUT_FILE")
rm -f "$STDOUT_FILE"
if [ "$ACTUAL" = "$PASS_JSON" ]; then
    pass "R8a: passthrough preserves JSON"
else
    fail "R8a: passthrough corrupted. Expected: $PASS_JSON, Got: $ACTUAL"
fi

# R8b: Non-comment command passthrough
NC_JSON='{"tool_input":{"command":"git push origin main"}}'
STDOUT_FILE2=$(mktemp /tmp/see396-qa-regression2.XXXXXX)
echo "$NC_JSON" | bash "$HOOK_SCRIPT" > "$STDOUT_FILE2" 2>/dev/null
ACTUAL2=$(cat "$STDOUT_FILE2")
rm -f "$STDOUT_FILE2"
if [ "$ACTUAL2" = "$NC_JSON" ]; then
    pass "R8b: non-comment passthrough preserves JSON"
else
    fail "R8b: non-comment passthrough corrupted. Got: $ACTUAL2"
fi

# R8c: Block produces valid JSON
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 说得对 [@Atlas](mention://agent/fac3e3a1)\""}}'
if echo "$HOOK_STDOUT" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    pass "R8c: block output is valid JSON"
else
    fail "R8c: block output is invalid JSON: '$HOOK_STDOUT'"
fi

# R8d: Malformed JSON -> passthrough
MALFORMED='{not valid json}'
STDOUT_FILE3=$(mktemp /tmp/see396-qa-regression3.XXXXXX)
echo "$MALFORMED" | bash "$HOOK_SCRIPT" > "$STDOUT_FILE3" 2>/dev/null
ACTUAL3=$(cat "$STDOUT_FILE3")
rm -f "$STDOUT_FILE3"
if [ "$ACTUAL3" = "$MALFORMED" ]; then
    pass "R8d: malformed JSON passthrough"
else
    fail "R8d: malformed JSON corrupted. Got: $ACTUAL3"
fi

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
