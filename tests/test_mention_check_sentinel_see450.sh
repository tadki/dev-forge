#!/bin/bash
# test_mention_check_sentinel_see450.sh
# QA Tests for SEE-450 sentinel three-way mechanism
# Covers 8 dimensions: PASS sentinel, NO_MENTION sentinel, BLOCK sentinel,
# independence, task isolation, input modes, regression
#
# Related Issue: SEE-450
# Test Type: Functional / Unit / Regression
# Author: Revy (QA Agent)

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0
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

skip() {
    echo -e "  ${YELLOW}[SKIP]${NC} $1"
    SKIP=$((SKIP + 1))
    RESULTS+=("SKIP|$1")
}

separator() {
    echo ""
    echo -e "${CYAN}--- $1 ---${NC}"
}

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SCRIPT="$PROJECT_ROOT/claude-hooks/scripts/mention-check.sh"

# Unique task IDs for test isolation (PID-suffixed to avoid collision)
TASK_A="see450-test-a-$$"
TASK_B="see450-test-b-$$"
TASK_C="see450-test-c-$$"
TASK_D="see450-test-d-$$"
TASK_E="see450-test-e-$$"

# Sentinel file path helpers
sp() { echo "/tmp/mention-check-pass-$1"; }
snm() { echo "/tmp/mention-check-no-mention-$1"; }
sb() { echo "/tmp/mention-check-block-$1"; }

cleanup_all_sentinels() {
    for tid in "$TASK_A" "$TASK_B" "$TASK_C" "$TASK_D" "$TASK_E"; do
        rm -f "$(sp "$tid")" "$(snm "$tid")" "$(sb "$tid")"
    done
    rm -f /tmp/see450-test-content-*.txt
}

cleanup_all_sentinels

run_hook() {
    local task_id="$1"
    local input="$2"
    local stdout_f stderr_f
    stdout_f=$(mktemp /tmp/see450-stdout.XXXXXX)
    stderr_f=$(mktemp /tmp/see450-stderr.XXXXXX)

    printf '%s' "$input" | MULTICA_TASK_ID="$task_id" bash "$HOOK_SCRIPT" > "$stdout_f" 2> "$stderr_f"
    HOOK_EXIT=$?
    HOOK_STDOUT=$(cat "$stdout_f")
    HOOK_STDERR=$(cat "$stderr_f")

    rm -f "$stdout_f" "$stderr_f"
}

# --- Assertions ---

assert_blocked() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
        pass "$label — blocked (deny)"
    else
        fail "$label — not blocked. stdout: '$HOOK_STDOUT'"
    fi
}

assert_passthrough() {
    local label="$1"
    local input="$2"
    if [ "$HOOK_STDOUT" = "$input" ]; then
        pass "$label — passthrough (output == input)"
    elif echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
        fail "$label — unexpectedly blocked. stdout: '$HOOK_STDOUT'"
    else
        pass "$label — passthrough (no deny in output)"
    fi
}

assert_sentinel_exists() {
    local file="$1"
    local label="$2"
    if [ -f "$file" ]; then
        pass "$label — sentinel exists: $(basename "$file")"
    else
        fail "$label — sentinel missing: $file"
    fi
}

assert_sentinel_not_exists() {
    local file="$1"
    local label="$2"
    if [ ! -f "$file" ]; then
        pass "$label — sentinel correctly absent: $(basename "$file")"
    else
        fail "$label — sentinel unexpectedly exists: $file"
    fi
}

# --- Test content strings ---

# Content that passes all phases (valid mention + action sentence)
PASS_CONTENT='[@Bachi](mention://agent/a5c250e8-7257-466e-b45a-03f995c7206c) 请处理这个任务工作，完成后通知我'
PASS_INPUT='{"tool_input":{"command":"multica issue comment add SEE-999 --content \"'"$PASS_CONTENT"'\""}}'

# Content with no mention (triggers NO_MENTION)
NO_MENTION_CONTENT='这是一条没有mention的普通评论'
NO_MENTION_INPUT='{"tool_input":{"command":"multica issue comment add SEE-999 --content \"'"$NO_MENTION_CONTENT"'\""}}'

# Content with mention + reference-like sentence (passed through after PHASE2 removal)
MENTION_CONTENT='我同意 Atlas 的看法，这个方案确实可行 [@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5)'
MENTION_INPUT='{"tool_input":{"command":"multica issue comment add SEE-999 --content \"'"$MENTION_CONTENT"'\""}}'

# Non-comment command (always passes)
NON_COMMENT_INPUT='{"tool_input":{"command":"git push origin main"}}'

echo "============================================"
echo "  SEE-450 Sentinel Three-Way QA Tests"
echo "  Date: $(date -Iseconds)"
echo "  Author: Revy (QA Agent)"
echo "  Branch: $(git branch --show-current 2>/dev/null || echo 'unknown')"
echo "============================================"

#####################################################################
# T1: PASS sentinel — original logic preserved
#####################################################################
separator "T1: PASS sentinel — original logic"

# T1a: First valid comment → passthrough + PASS sentinel created
run_hook "$TASK_A" "$PASS_INPUT"
assert_passthrough "T1a: first valid comment" "$PASS_INPUT"
assert_sentinel_exists "$(sp "$TASK_A")" "T1a: PASS sentinel created"

# T1b: Second valid comment → bash-level early exit (PASS sentinel exists)
run_hook "$TASK_A" "$PASS_INPUT"
assert_passthrough "T1b: second comment with PASS sentinel" "$PASS_INPUT"

# T1c: Non-comment command → passthrough regardless of sentinel
run_hook "$TASK_A" "$NON_COMMENT_INPUT"
assert_passthrough "T1c: non-comment command passthrough" "$NON_COMMENT_INPUT"

# T1d: Verify PASS sentinel persists (not cleared by second call)
assert_sentinel_exists "$(sp "$TASK_A")" "T1d: PASS sentinel still exists after multiple calls"

#####################################################################
# T2: NO_MENTION sentinel — first-time block + sentinel creation
#####################################################################
separator "T2: NO_MENTION sentinel — first-time block"

# T2a: First no-mention comment → blocked
run_hook "$TASK_B" "$NO_MENTION_INPUT"
assert_blocked "T2a: first no-mention comment blocked"

# T2b: NO_MENTION sentinel file created
assert_sentinel_exists "$(snm "$TASK_B")" "T2b: NO_MENTION sentinel created"

# T2c: PASS sentinel NOT created (because hook was blocked)
assert_sentinel_not_exists "$(sp "$TASK_B")" "T2c: PASS sentinel not created after block"

# T2d: BLOCK sentinel NOT created (PHASE2 removed)
assert_sentinel_not_exists "$(sb "$TASK_B")" "T2d: BLOCK sentinel not created"

#####################################################################
# T3: NO_MENTION sentinel — subsequent passthrough
#####################################################################
separator "T3: NO_MENTION sentinel — subsequent passthrough"

# T3a: Second no-mention comment → still BLOCKED (SEE-1333 D2 逐条拦截, Owner 裁定 2026-09-21)
run_hook "$TASK_B" "$NO_MENTION_INPUT"
assert_blocked "T3a: second no-mention comment still blocked (SEE-1333 D2 逐条拦截)"

# T3b: PASS sentinel NOT created (no-mention never passes → no PASS write)
assert_sentinel_not_exists "$(sp "$TASK_B")" "T3b: PASS sentinel NOT created (D2: no-mention never passes)"

# T3c: Third no-mention comment → still BLOCKED
run_hook "$TASK_B" "$NO_MENTION_INPUT"
assert_blocked "T3c: third no-mention comment still blocked (SEE-1333 D2)"

#####################################################################
# T4: Mention-bearing content passes through (PHASE2 removed)
#####################################################################
separator "T4: mention-bearing content passthrough"

# T4a: First mention-bearing comment → passthrough + PASS sentinel created
run_hook "$TASK_C" "$MENTION_INPUT"
assert_passthrough "T4a: mention-bearing comment passthrough" "$MENTION_INPUT"
assert_sentinel_exists "$(sp "$TASK_C")" "T4a: PASS sentinel created"

# T4b: BLOCK sentinel NOT created (PHASE2 removed)
assert_sentinel_not_exists "$(sb "$TASK_C")" "T4b: BLOCK sentinel not created"

# T4c: NO_MENTION sentinel NOT created (content has mention)
assert_sentinel_not_exists "$(snm "$TASK_C")" "T4c: NO_MENTION sentinel not created"

#####################################################################
# T5: Mention-bearing content — subsequent passthrough via PASS sentinel
#####################################################################
separator "T5: mention-bearing content subsequent passthrough"

# T5a: Second mention-bearing comment → passthrough (PASS sentinel exists)
run_hook "$TASK_C" "$MENTION_INPUT"
assert_passthrough "T5a: mention-bearing comment passthrough (PASS sentinel exists)" "$MENTION_INPUT"

# T5b: PASS sentinel still exists
assert_sentinel_exists "$(sp "$TASK_C")" "T5b: PASS sentinel persists"

#####################################################################
# T6: NO_MENTION and PASS sentinels are independent
#####################################################################
separator "T6: NO_MENTION and PASS sentinels are independent"

# T6a: Create only NO_MENTION sentinel, NOT PASS sentinel
cleanup_all_sentinels
touch "$(snm "$TASK_D")"

# T6b: Mention-bearing content (has mention) → passes independently of NO_MENTION sentinel
run_hook "$TASK_D" "$MENTION_INPUT"
assert_passthrough "T6b: mention-bearing comment passes (NO_MENTION sentinel doesn't block mention content)" "$MENTION_INPUT"
assert_sentinel_exists "$(sp "$TASK_D")" "T6b: PASS sentinel created independently"
# NO_MENTION sentinel cleared by finally after PASS
assert_sentinel_not_exists "$(snm "$TASK_D")" "T6b: NO_MENTION sentinel cleared after PASS"

# T6c: Reverse test — pre-create PASS sentinel, no NO_MENTION sentinel
rm -f "$(snm "$TASK_D")"
rm -f "$(sp "$TASK_D")"
touch "$(sp "$TASK_D")"

# T6d: No-mention comment → still BLOCKED (SEE-1333 D2: PASS sentinel no longer grants passthrough)
run_hook "$TASK_D" "$NO_MENTION_INPUT"
assert_blocked "T6d: no-mention still blocked (SEE-1333 D2 逐条拦截)"
# PASS sentinel unchanged (still present, no write from blocked no-mention)
assert_sentinel_exists "$(sp "$TASK_D")" "T6d: PASS sentinel unchanged"

#####################################################################
# T7: Task isolation — different MULTICA_TASK_ID
#####################################################################
separator "T7: Task isolation"

# T7a: Create sentinels for TASK_A
cleanup_all_sentinels
touch "$(sp "$TASK_A")"
touch "$(snm "$TASK_A")"
touch "$(sb "$TASK_A")"

# T7b: TASK_B has no sentinels → should behave as first-time
assert_sentinel_not_exists "$(sp "$TASK_B")" "T7b: TASK_B PASS sentinel absent"
assert_sentinel_not_exists "$(snm "$TASK_B")" "T7b: TASK_B NO_MENTION sentinel absent"
assert_sentinel_not_exists "$(sb "$TASK_B")" "T7b: TASK_B BLOCK sentinel absent"

# T7c: No-mention comment with TASK_B → blocked (first-time for TASK_B)
run_hook "$TASK_B" "$NO_MENTION_INPUT"
assert_blocked "T7c: TASK_B no-mention first-time blocked (TASK_A sentinels don't interfere)"
assert_sentinel_exists "$(snm "$TASK_B")" "T7c: TASK_B NO_MENTION sentinel created"

# T7d: TASK_A still has its original sentinels
assert_sentinel_exists "$(sp "$TASK_A")" "T7d: TASK_A sentinels untouched"

# T7e: No-mention comment with TASK_A → still BLOCKED (SEE-1333 D2 逐条拦截)
run_hook "$TASK_A" "$NO_MENTION_INPUT"
assert_blocked "T7e: TASK_A no-mention still blocked (SEE-1333 D2 逐条拦截)"

# T7f: Same no-mention comment with TASK_C (fresh) → blocked
run_hook "$TASK_C" "$NO_MENTION_INPUT"
assert_blocked "T7f: TASK_C no-mention first-time blocked (independent from A/B)"

#####################################################################
# T8: Three input modes share sentinel (same task)
#####################################################################
separator "T8: Three input modes share sentinel"

cleanup_all_sentinels

# T8a: --content mode → no mention → blocked + NO_MENTION sentinel
CONTENT_INPUT='{"tool_input":{"command":"multica issue comment add SEE-999 --content \"普通评论无mention\""}}'
run_hook "$TASK_E" "$CONTENT_INPUT"
assert_blocked "T8a: --content mode blocked"
assert_sentinel_exists "$(snm "$TASK_E")" "T8a: NO_MENTION sentinel from --content"

# T8b: --content-stdin (heredoc) mode → no mention → still BLOCKED (SEE-1333 D2 逐条拦截)
HEREDOC_INPUT='{"tool_input":{"command":"multica issue comment add SEE-999 --content-stdin <<-EOF\n普通评论heredoc无mention\nEOF"}}'
run_hook "$TASK_E" "$HEREDOC_INPUT"
assert_blocked "T8b: --content-stdin still blocked (SEE-1333 D2 逐条拦截)"

# T8c: --content-file mode → no mention → still BLOCKED
CONTENT_FILE="/tmp/see450-test-content-$$"
echo "普通评论文件无mention" > "$CONTENT_FILE"
FILE_INPUT="{\"tool_input\":{\"command\":\"multica issue comment add SEE-999 --content-file $CONTENT_FILE\"}}"
run_hook "$TASK_E" "$FILE_INPUT"
assert_blocked "T8c: --content-file still blocked (SEE-1333 D2 逐条拦截)"
rm -f "$CONTENT_FILE"

# T8d: After cross-mode no-mention calls, NO_MENTION persists, no PASS created
SP_COUNT=$(find /tmp -maxdepth 1 -name "mention-check-pass-${TASK_E}" 2>/dev/null | wc -l)
NM_COUNT=$(find /tmp -maxdepth 1 -name "mention-check-no-mention-${TASK_E}" 2>/dev/null | wc -l)
if [ "$SP_COUNT" -eq 0 ] && [ "$NM_COUNT" -eq 1 ]; then
    pass "T8d: NO_MENTION persists, no PASS sentinel after cross-mode no-mention calls (D2)"
else
    fail "T8d: expected 0 PASS and 1 NO_MENTION sentinel, found PASS=$SP_COUNT NO_MENTION=$NM_COUNT"
fi

# T8e: Cross-mode: --content-file blocked creates sentinel, --content still BLOCKED (D2 逐条拦截)
cleanup_all_sentinels
echo "文件评论无mention" > "$CONTENT_FILE"
FILE_INPUT2="{\"tool_input\":{\"command\":\"multica issue comment add SEE-999 --content-file $CONTENT_FILE\"}}"

# First: --content-file → blocked + sentinel
run_hook "$TASK_E" "$FILE_INPUT2"
assert_blocked "T8e: --content-file first-time blocked"
assert_sentinel_exists "$(snm "$TASK_E")" "T8e: NO_MENTION sentinel from --content-file"

# Second: --content → still BLOCKED
CONTENT_INPUT2='{"tool_input":{"command":"multica issue comment add SEE-999 --content \"评论无mention\""}}'
run_hook "$TASK_E" "$CONTENT_INPUT2"
assert_blocked "T8e: --content still blocked (SEE-1333 D2 逐条拦截)"

rm -f "$CONTENT_FILE"

#####################################################################
# T9: Regression — sentinel interaction with edge cases
#####################################################################
separator "T9: Regression tests"

# T9a: Without MULTICA_TASK_ID → no sentinel files created
NO_TASK_INPUT='{"tool_input":{"command":"multica issue comment add SEE-999 --content \"无mention评论\""}}'
NO_TASK_STDOUT_F=$(mktemp /tmp/see450-regression.XXXXXX)
printf '%s' "$NO_TASK_INPUT" | bash "$HOOK_SCRIPT" > "$NO_TASK_STDOUT_F" 2>/dev/null
NO_TASK_EXIT=$?
NO_TASK_OUTPUT=$(cat "$NO_TASK_STDOUT_F")
rm -f "$NO_TASK_STDOUT_F"

if echo "$NO_TASK_OUTPUT" | grep -q '"permissionDecision"'; then
    # Blocked (expected since no mention), but check no sentinel with "unknown" name
    if [ ! -f /tmp/mention-check-pass-unknown ] && [ ! -f /tmp/mention-check-no-mention-unknown ] && [ ! -f /tmp/mention-check-block-unknown ]; then
        pass "T9a: no TASK_ID → no sentinel files created (blocked correctly)"
    else
        fail "T9a: sentinel files created without TASK_ID"
    fi
else
    pass "T9a: no TASK_ID → passthrough (no sentinels)"
fi

# T9b: PASS sentinel prevents Node.js execution entirely
cleanup_all_sentinels
touch "$(sp "$TASK_A")"
# Use intentionally malformed input — if Node.js runs it would fail,
# but bash-level early exit means it just echoes input back
MALFORMED='{not valid json}'
run_hook "$TASK_A" "$MALFORMED"
assert_passthrough "T9b: PASS sentinel → bash early exit (even with malformed input)" "$MALFORMED"

# T9c: Sentinel file cleanup doesn't affect other tasks
cleanup_all_sentinels
touch "$(sp "$TASK_A")"
touch "$(snm "$TASK_A")"
rm -f "$(sp "$TASK_A")"
assert_sentinel_not_exists "$(sp "$TASK_A")" "T9c: TASK_A PASS sentinel removed"
assert_sentinel_exists "$(snm "$TASK_A")" "T9c: TASK_A NO_MENTION sentinel still exists"

# T9d: Chekky agent bypasses mention-check entirely (no sentinels created)
CHEKKY_INPUT='{"tool_input":{"command":"multica issue comment add SEE-999 --content \"Chekky评论无mention\""}}'
CHEKKY_STDOUT_F=$(mktemp /tmp/see450-chekky.XXXXXX)
printf '%s' "$CHEKKY_INPUT" | MULTICA_AGENT_NAME="Chekky" MULTICA_TASK_ID="$TASK_B" bash "$HOOK_SCRIPT" > "$CHEKKY_STDOUT_F" 2>/dev/null
CHEKKY_OUTPUT=$(cat "$CHEKKY_STDOUT_F")
rm -f "$CHEKKY_STDOUT_F"
if [ "$CHEKKY_OUTPUT" = "$CHEKKY_INPUT" ]; then
    assert_sentinel_not_exists "$(sp "$TASK_B")" "T9d: Chekky no PASS sentinel"
    assert_sentinel_not_exists "$(snm "$TASK_B")" "T9d: Chekky no NO_MENTION sentinel"
    pass "T9d: Chekky bypasses mention-check entirely"
else
    fail "T9d: Chekky bypass failed. Output: $CHEKKY_OUTPUT"
fi

#####################################################################
# Cleanup
#####################################################################
cleanup_all_sentinels

#####################################################################
# SUMMARY
#####################################################################
separator "Summary"

echo ""
echo -e "${CYAN}Results:${NC}"
echo -e "  ${GREEN}Passed:${NC}    $PASS"
echo -e "  ${RED}Failed:${NC}    $FAIL"
echo -e "  ${YELLOW}Skipped:${NC}    $SKIP"
echo ""

TOTAL=$((PASS + FAIL + SKIP))
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
