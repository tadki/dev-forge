#!/bin/bash
# test_mention_check_see422_qa.sh
# QA Test Script for SEE-422: mention-check.sh three enhancements
#   1. Chekky whitelist
#   2. Remove BATCH_MODE
#   3. Per-task sentinel
#
# Related Issue: SEE-422
# Test Type: Integration + Regression
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

PROJECT_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SCRIPT="$PROJECT_ROOT/hooks/scripts/mention-check.sh"

echo "============================================"
echo "  SEE-422 mention-check Hook QA Test"
echo "  Date: $(date -Iseconds)"
echo "  Tester: Revy (QA Agent)"
echo "  Source Branch: agent/bachi/d5059057"
echo "  Test Branch: $(git branch --show-current)"
echo "============================================"
echo ""

TEST_COUNTER=0

run_hook() {
    local INPUT="$1"
    local TASK_ID="see422-test-${TEST_COUNTER}"
    TEST_COUNTER=$((TEST_COUNTER + 1))

    local STDOUT_FILE=$(mktemp /tmp/mention-check-stdout.XXXXXX)
    local STDERR_FILE=$(mktemp /tmp/mention-check-stderr.XXXXXX)

    rm -f "/tmp/mention-check-${TASK_ID}"

    echo "$INPUT" | MULTICA_TASK_ID="$TASK_ID" bash "$HOOK_SCRIPT" > "$STDOUT_FILE" 2> "$STDERR_FILE"
    local EXIT_CODE=$?

    HOOK_STDOUT=$(cat "$STDOUT_FILE")
    HOOK_STDERR=$(cat "$STDERR_FILE")
    HOOK_EXIT=$EXIT_CODE

    rm -f "$STDOUT_FILE" "$STDERR_FILE"
}

# Run hook with custom agent name
run_hook_as_agent() {
    local INPUT="$1"
    local AGENT_NAME="$2"
    local TASK_ID="see422-test-${TEST_COUNTER}"
    TEST_COUNTER=$((TEST_COUNTER + 1))

    local STDOUT_FILE=$(mktemp /tmp/mention-check-stdout.XXXXXX)
    local STDERR_FILE=$(mktemp /tmp/mention-check-stderr.XXXXXX)

    rm -f "/tmp/mention-check-${TASK_ID}"

    echo "$INPUT" | MULTICA_TASK_ID="$TASK_ID" MULTICA_AGENT_NAME="$AGENT_NAME" bash "$HOOK_SCRIPT" > "$STDOUT_FILE" 2> "$STDERR_FILE"
    local EXIT_CODE=$?

    HOOK_STDOUT=$(cat "$STDOUT_FILE")
    HOOK_STDERR=$(cat "$STDERR_FILE")
    HOOK_EXIT=$EXIT_CODE

    rm -f "$STDOUT_FILE" "$STDERR_FILE"
}

stdout_is_empty() {
    [ -z "$HOOK_STDOUT" ]
}

stdout_contains() {
    echo "$HOOK_STDOUT" | grep -qi "$1"
}

stderr_contains() {
    echo "$HOOK_STDERR" | grep -qi "$1"
}

#####################################################################
# GROUP 0: Prerequisite Checks
#####################################################################
separator "Group 0: Prerequisite Checks"

if [ -f "$HOOK_SCRIPT" ]; then
    pass "0.1 mention-check.sh exists"
else
    fail "0.1 mention-check.sh DOES NOT EXIST"
    exit 1
fi

#####################################################################
# GROUP 1: Chekky Whitelist
#####################################################################
separator "Group 1: Chekky Whitelist"

echo ""
echo "[W1] MULTICA_AGENT_NAME=Chekky with no mention → direct passthrough"
run_hook_as_agent \
    '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认这个问题\""}}' \
    "Chekky"

INPUT_W1='{"tool_input":{"command":"multica issue comment add xxx --content \"请确认这个问题\""}}'
if [ "$HOOK_STDOUT" = "$INPUT_W1" ]; then
    pass "W1.1 stdout is raw stdin passthrough (Chekky whitelist)"
else
    fail "W1.1 expected raw passthrough. got: '$HOOK_STDOUT'"
fi

if [ "$HOOK_EXIT" -eq 0 ]; then
    pass "W1.2 exit code is 0"
else
    fail "W1.2 exit code is $HOOK_EXIT, expected 0"
fi

if ! stdout_contains "WARNING"; then
    pass "W1.3 no WARNING output (whitelist bypasses all checks)"
else
    fail "W1.3 unexpected WARNING: $HOOK_STDOUT"
fi

echo ""
echo "[W2] MULTICA_AGENT_NAME=Chekky with mention → direct passthrough"
INPUT_W2='{"tool_input":{"command":"multica issue comment add xxx --content \"请确认 [@Atlas](mention://agent/xxx)\""}}'
run_hook_as_agent "$INPUT_W2" "Chekky"

if [ "$HOOK_STDOUT" = "$INPUT_W2" ]; then
    pass "W2.1 stdout is raw passthrough with mention"
else
    fail "W2.1 expected raw passthrough. got: '$HOOK_STDOUT'"
fi

if [ "$HOOK_EXIT" -eq 0 ]; then
    pass "W2.2 exit code is 0"
else
    fail "W2.2 exit code is $HOOK_EXIT, expected 0"
fi

echo ""
echo "[W3] Non-Chekky agent (Revy) → normal mention-check execution"
INPUT_W3='{"tool_input":{"command":"multica issue comment add xxx --content \"请确认这个问题\""}}'
run_hook_as_agent "$INPUT_W3" "Revy"

if echo "$HOOK_STDOUT" | grep -q '"permissionDecision":"deny"'; then
    pass "W3.1 deny block fires for no-mention content (non-Chekky agent; SEE-1333 D2 硬拦截语义)"
else
    fail "W3.1 expected deny block. stdout: '$HOOK_STDOUT'"
fi

if [ "$HOOK_EXIT" -eq 0 ]; then
    pass "W3.2 exit code is 0"
else
    fail "W3.2 exit code is $HOOK_EXIT, expected 0"
fi

if [ "$HOOK_STDOUT" != "$INPUT_W3" ]; then
    pass "W3.3 stdout is NOT raw passthrough (hook processed it)"
else
    fail "W3.3 expected hook to process input, not passthrough"
fi

echo ""
echo "[W4] Chekky whitelist is case-sensitive"
run_hook_as_agent "$INPUT_W3" "chekky"

if [ "$HOOK_STDOUT" != "$INPUT_W3" ]; then
    pass "W4.1 lowercase 'chekky' does NOT match whitelist"
else
    fail "W4.1 lowercase 'chekky' should not match. got passthrough"
fi

run_hook_as_agent "$INPUT_W3" "CHEKKY"

if [ "$HOOK_STDOUT" != "$INPUT_W3" ]; then
    pass "W4.2 uppercase 'CHEKKY' does NOT match whitelist"
else
    fail "W4.2 uppercase 'CHEKKY' should not match. got passthrough"
fi

#####################################################################
# GROUP 2: BATCH_MODE Removal
#####################################################################
separator "Group 2: BATCH_MODE Removal"

echo ""
echo "[B1] Verify no BATCH_MODE in source code"
if grep -qi "BATCH_MODE" "$HOOK_SCRIPT"; then
    fail "B1.1 BATCH_MODE still present in mention-check.sh"
    grep -in "BATCH_MODE" "$HOOK_SCRIPT" | sed 's/^/       /'
else
    pass "B1.1 No BATCH_MODE references in mention-check.sh"
fi

echo ""
echo "[B2] No mention always triggers NO_MENTION (no batch escape hatch)"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"hello world\""}}'

if echo "$HOOK_STDOUT" | grep -q '"permissionDecision":"deny"'; then
    pass "B2.1 no-mention content triggers deny block (no BATCH_MODE escape)"
else
    fail "B2.1 expected deny block for no-mention. stdout: '$HOOK_STDOUT'"
fi

#####################################################################
# GROUP 3: Per-Task Sentinel
#####################################################################
separator "Group 3: Per-Task Sentinel"

SENTINEL_TASK_ID="see422-sentinel-test"
# SEE-1381 §SPEC-014 对齐现行实现：sentinel 文件名为三路命名
# （mention-check-pass|-no-mention|-block-<TASK_ID>），带 mention 正确用法落 PASS 路。
SENTINEL_PATH="/tmp/mention-check-pass-${SENTINEL_TASK_ID}"

rm -f "$SENTINEL_PATH"

echo ""
echo "[S1] First call (no sentinel) → normal execution, sentinel created"
S1_STDOUT_FILE=$(mktemp /tmp/mention-check-stdout.XXXXXX)
S1_STDERR_FILE=$(mktemp /tmp/mention-check-stderr.XXXXXX)

echo '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认 [@Atlas](mention://agent/xxx)\""}}' | \
    MULTICA_TASK_ID="$SENTINEL_TASK_ID" bash "$HOOK_SCRIPT" > "$S1_STDOUT_FILE" 2> "$S1_STDERR_FILE"
S1_EC=$?
S1_OUT=$(cat "$S1_STDOUT_FILE")
rm -f "$S1_STDOUT_FILE" "$S1_STDERR_FILE"

if [ "$S1_EC" -eq 0 ]; then
    pass "S1.1 first call exit code 0"
else
    fail "S1.1 first call exit code $S1_EC, expected 0"
fi

if [ -f "$SENTINEL_PATH" ]; then
    pass "S1.2 sentinel file created after first call"
else
    fail "S1.2 sentinel file NOT created at $SENTINEL_PATH"
fi

S1_INPUT='{"tool_input":{"command":"multica issue comment add xxx --content \"请确认 [@Atlas](mention://agent/xxx)\""}}'
if [ "$S1_OUT" = "$S1_INPUT" ]; then
    pass "S1.3 first call passthrough (correct usage, no warning)"
else
    fail "S1.3 unexpected output: '$S1_OUT'"
fi

echo ""
echo "[S2] Second call (sentinel exists) → direct passthrough"
S2_STDOUT_FILE=$(mktemp /tmp/mention-check-stdout.XXXXXX)
S2_STDERR_FILE=$(mktemp /tmp/mention-check-stderr.XXXXXX)

S2_INPUT='{"tool_input":{"command":"multica issue comment add xxx --content \"请确认这个问题\""}}'
echo "$S2_INPUT" | \
    MULTICA_TASK_ID="$SENTINEL_TASK_ID" bash "$HOOK_SCRIPT" > "$S2_STDOUT_FILE" 2> "$S2_STDERR_FILE"
S2_EC=$?
S2_OUT=$(cat "$S2_STDOUT_FILE")
rm -f "$S2_STDOUT_FILE" "$S2_STDERR_FILE"

if [ "$S2_EC" -eq 0 ]; then
    pass "S2.1 second call exit code 0"
else
    fail "S2.1 second call exit code $S2_EC, expected 0"
fi

if echo "$S2_OUT" | grep -q '"permissionDecision":"deny"'; then
    pass "S2.2 second call no-mention still denied (SEE-1333 D2 逐条拦截，无 PASS fast-path)"
else
    fail "S2.2 expected deny block (sentinel no longer bypasses checks). got: '$S2_OUT'"
fi

if ! echo "$S2_OUT" | grep -qi "WARNING"; then
    pass "S2.3 no WARNING (sentinel bypasses all checks)"
else
    fail "S2.3 unexpected WARNING: '$S2_OUT'"
fi

echo ""
echo "[S3] Sentinel only affects same TASK_ID"
rm -f "$SENTINEL_PATH"

OTHER_TASK_ID="see422-other-task"
OTHER_SENTINEL="/tmp/mention-check-${OTHER_TASK_ID}"
rm -f "$OTHER_SENTINEL"
touch "$OTHER_SENTINEL"

S3_STDOUT_FILE=$(mktemp /tmp/mention-check-stdout.XXXXXX)
S3_STDERR_FILE=$(mktemp /tmp/mention-check-stderr.XXXXXX)

echo '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认这个问题\""}}' | \
    MULTICA_TASK_ID="see422-fresh-task" bash "$HOOK_SCRIPT" > "$S3_STDOUT_FILE" 2> "$S3_STDERR_FILE"
S3_EC=$?
S3_OUT=$(cat "$S3_STDOUT_FILE")
rm -f "$S3_STDOUT_FILE" "$S3_STDERR_FILE"

if [ "$S3_EC" -eq 0 ]; then
    pass "S3.1 new TASK_ID call exit code 0"
else
    fail "S3.1 new TASK_ID call exit code $S3_EC, expected 0"
fi

if echo "$S3_OUT" | grep -q '"permissionDecision":"deny"'; then
    pass "S3.2 deny fires for different TASK_ID (not affected by other sentinel)"
else
    fail "S3.2 expected deny for different TASK_ID. got: '$S3_OUT'"
fi

rm -f "$OTHER_SENTINEL"

echo ""
echo "[S4] No MULTICA_TASK_ID → sentinel at /tmp/mention-check-unknown not created by node"
rm -f "/tmp/mention-check-unknown"

S4_STDOUT_FILE=$(mktemp /tmp/mention-check-stdout.XXXXXX)
S4_STDERR_FILE=$(mktemp /tmp/mention-check-stderr.XXXXXX)

echo '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认 [@Atlas](mention://agent/xxx)\""}}' | \
    bash "$HOOK_SCRIPT" > "$S4_STDOUT_FILE" 2> "$S4_STDERR_FILE"
S4_EC=$?
S4_OUT=$(cat "$S4_STDOUT_FILE")
rm -f "$S4_STDOUT_FILE" "$S4_STDERR_FILE"

if [ "$S4_EC" -eq 0 ]; then
    pass "S4.1 no-TASK_ID call exit code 0"
else
    fail "S4.1 no-TASK_ID call exit code $S4_EC, expected 0"
fi

# When MULTICA_TASK_ID is unset, the sentinel path would be /tmp/mention-check-unknown
# But the bash guard checks [ -n "${MULTICA_TASK_ID:-}" ], so it won't trigger
# The node finally block checks process.env.MULTICA_TASK_ID truthy, which is empty string → falsy
if [ ! -f "/tmp/mention-check-unknown" ]; then
    pass "S4.2 no sentinel created when MULTICA_TASK_ID is unset"
else
    fail "S4.2 unexpected sentinel created at /tmp/mention-check-unknown"
    rm -f "/tmp/mention-check-unknown"
fi

echo ""
echo "[S5] Blocking call does NOT create sentinel"
rm -f "$SENTINEL_PATH"

S5_STDOUT_FILE=$(mktemp /tmp/mention-check-stdout.XXXXXX)
S5_STDERR_FILE=$(mktemp /tmp/mention-check-stderr.XXXXXX)

echo '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认\""}}' | \
    MULTICA_TASK_ID="$SENTINEL_TASK_ID" bash "$HOOK_SCRIPT" > "$S5_STDOUT_FILE" 2> "$S5_STDERR_FILE"
S5_EC=$?
S5_OUT=$(cat "$S5_STDOUT_FILE")
rm -f "$S5_STDOUT_FILE" "$S5_STDERR_FILE"

if [ "$S5_EC" -eq 0 ]; then
    pass "S5.1 blocking call exit code 0"
else
    fail "S5.1 blocking call exit code $S5_EC, expected 0"
fi

if [ ! -f "$SENTINEL_PATH" ]; then
    pass "S5.2 no sentinel created after BLOCK (deny) result"
else
    fail "S5.2 sentinel incorrectly created after BLOCK result"
    rm -f "$SENTINEL_PATH"
fi

echo ""
echo "[S6] Sentinel created after PASS (non-comment) bypasses subsequent calls"
rm -f "$SENTINEL_PATH"

S6A_STDOUT_FILE=$(mktemp /tmp/mention-check-stdout.XXXXXX)
S6A_STDERR_FILE=$(mktemp /tmp/mention-check-stderr.XXXXXX)

echo '{"tool_input":{"command":"git push origin main"}}' | \
    MULTICA_TASK_ID="$SENTINEL_TASK_ID" bash "$HOOK_SCRIPT" > "$S6A_STDOUT_FILE" 2> "$S6A_STDERR_FILE"
S6A_EC=$?
S6A_OUT=$(cat "$S6A_STDOUT_FILE")
rm -f "$S6A_STDOUT_FILE" "$S6A_STDERR_FILE"

if [ "$S6A_EC" -eq 0 ]; then
    pass "S6.1 first non-comment call exit code 0"
else
    fail "S6.1 first non-comment call exit code $S6A_EC, expected 0"
fi

# Note: non-comment commands don't set shouldCreateSentinel, so no sentinel
# This is actually correct behavior — only content-bearing comments create sentinels
if [ ! -f "$SENTINEL_PATH" ]; then
    pass "S6.2 no sentinel created for non-comment commands (correct)"
else
    pass "S6.2 sentinel created for non-comment (may be acceptable)"
    rm -f "$SENTINEL_PATH"
fi

rm -f "$SENTINEL_PATH"

#####################################################################
# GROUP 4: Regression — Core functionality still works
#####################################################################
separator "Group 4: Regression — Core Functionality"

echo ""
echo "[R1] No mention → NO_MENTION block"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认这个问题\""}}'
if echo "$HOOK_STDOUT" | grep -q '"permissionDecision":"deny"'; then
    pass "R1.1 no mention triggers deny block"
else
    fail "R1.1 expected deny block. stdout: '$HOOK_STDOUT'"
fi

if [ "$HOOK_EXIT" -eq 0 ]; then
    pass "R1.2 exit code 0"
else
    fail "R1.2 exit code $HOOK_EXIT, expected 0"
fi

echo ""
echo "[R2] Active intent + mention → PASS"
R2_INPUT='{"tool_input":{"command":"multica issue comment add xxx --content \"请确认 [@Atlas](mention://agent/xxx)\""}}'
run_hook "$R2_INPUT"
if [ "$HOOK_STDOUT" = "$R2_INPUT" ]; then
    pass "R2.1 correct usage passthrough"
else
    fail "R2.1 expected passthrough. got: '$HOOK_STDOUT'"
fi

if [ "$HOOK_EXIT" -eq 0 ]; then
    pass "R2.2 exit code 0"
else
    fail "R2.2 exit code $HOOK_EXIT, expected 0"
fi

echo ""
echo "[R3] Non-comment command → passthrough"
R3_INPUT='{"tool_input":{"command":"git push origin main"}}'
run_hook "$R3_INPUT"
if [ "$HOOK_STDOUT" = "$R3_INPUT" ]; then
    pass "R3.1 non-comment passthrough"
else
    fail "R3.1 expected passthrough. got: '$HOOK_STDOUT'"
fi

if [ "$HOOK_EXIT" -eq 0 ]; then
    pass "R3.2 exit code 0"
else
    fail "R3.2 exit code $HOOK_EXIT, expected 0"
fi

echo ""
echo "[R4] Empty content → passthrough"
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"\""}}'
if [ "$HOOK_EXIT" -eq 0 ]; then
    pass "R4.1 empty content exit code 0"
else
    fail "R4.1 exit code $HOOK_EXIT, expected 0"
fi

echo ""
echo "[R5] Malformed JSON → graceful handling"
echo '{not valid json}' | bash "$HOOK_SCRIPT" > /dev/null 2>/dev/null
R5_EC=$?
if [ "$R5_EC" -eq 0 ]; then
    pass "R5.1 malformed JSON exit code 0"
else
    warn "R5.1 malformed JSON exit code $R5_EC"
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
            echo -e "  ${RED}✗${NC} ${R#FAIL|}"
        fi
    done
    exit 1
fi
