#!/bin/bash
# test_mention_check_see400_json_escaping.sh
# Regression tests for SEE-400: JSON output format compliance
# Validates: valid JSON, permissionDecision=deny, JSON escaping safety
#
# Related Issue: SEE-400
# Test Type: Regression + Boundary
# Author: Bachi

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
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
TEST_COUNTER=0

run_hook() {
    local INPUT="$1"
    local TASK_ID="see400-test-${TEST_COUNTER}"
    TEST_COUNTER=$((TEST_COUNTER + 1))

    rm -f "/tmp/mention-check-${TASK_ID}"

    local STDOUT_FILE=$(mktemp /tmp/mention-check-see400-stdout.XXXXXX)
    local STDERR_FILE=$(mktemp /tmp/mention-check-see400-stderr.XXXXXX)

    echo "$INPUT" | MULTICA_TASK_ID="$TASK_ID" bash "$HOOK_SCRIPT" > "$STDOUT_FILE" 2> "$STDERR_FILE"
    local EXIT_CODE=$?

    HOOK_STDOUT=$(cat "$STDOUT_FILE")
    HOOK_STDERR=$(cat "$STDERR_FILE")
    HOOK_EXIT=$EXIT_CODE

    rm -f "$STDOUT_FILE" "$STDERR_FILE" "/tmp/mention-check-${TASK_ID}"
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

echo "============================================"
echo "  SEE-400 JSON Escaping Regression Tests"
echo "  Date: $(date -Iseconds)"
echo "  Author: Bachi (Backend Agent)"
echo "  Branch: $(git branch --show-current)"
echo "============================================"

#####################################################################
# GROUP 1: Exit 0 + permissionDecision=deny on BLOCK
#####################################################################
separator "G1: Block scenarios produce exit 0 + permissionDecision=deny"

# G1a: NO_MENTION block
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认这个问题\""}}'
assert_exit 0 "G1a: NO_MENTION block exit 0"

if echo "$HOOK_STDOUT" | grep -q '"permissionDecision".*"deny"'; then
    pass "G1a: permissionDecision=deny present"
else
    fail "G1a: permissionDecision=deny missing. stdout: '$HOOK_STDOUT'"
fi

if echo "$HOOK_STDOUT" | grep -q '"hookEventName".*"PreToolUse"'; then
    pass "G1a: hookEventName=PreToolUse present"
else
    fail "G1a: hookEventName missing. stdout: '$HOOK_STDOUT'"
fi

if echo "$HOOK_STDOUT" | grep -q '"permissionDecisionReason"'; then
    pass "G1a: permissionDecisionReason present"
else
    fail "G1a: permissionDecisionReason missing. stdout: '$HOOK_STDOUT'"
fi

# G1b: REF_WITH_MENTION — SEE-1330 PHASE2 移除后 mention-bearing 一律放行（原 reranker deny 语义已废）
G1B_INPUT='{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 说这个方案可行 [@Atlas](mention://agent/fac3e3a1)\""}}'
run_hook "$G1B_INPUT"
assert_exit 0 "G1b: REF_WITH_MENTION passthrough exit 0"

if [ "$HOOK_STDOUT" = "$G1B_INPUT" ]; then
    pass "G1b: mention-bearing content passthrough preserves stdin"
else
    fail "G1b: expected passthrough. stdout: '$HOOK_STDOUT'"
fi

#####################################################################
# GROUP 2: Valid JSON structure
#####################################################################
separator "G2: Output is valid parseable JSON"

# G2a: NO_MENTION output is valid JSON
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请处理\""}}'
PARSE_RESULT=$(echo "$HOOK_STDOUT" | node -e "
    let d = '';
    process.stdin.on('data', c => d += c);
    process.stdin.on('end', () => {
        try {
            const obj = JSON.parse(d);
            if (obj.hookSpecificOutput && obj.hookSpecificOutput.permissionDecision === 'deny') {
                process.stdout.write('VALID');
            } else {
                process.stdout.write('INVALID_STRUCTURE');
            }
        } catch (e) {
            process.stdout.write('PARSE_ERROR: ' + e.message);
        }
    });
" 2>&1)
if [ "$PARSE_RESULT" = "VALID" ]; then
    pass "G2a: NO_MENTION output is valid JSON with correct structure"
else
    fail "G2a: JSON parse/structure issue: $PARSE_RESULT. stdout: '$HOOK_STDOUT'"
fi

# G2b: REF_WITH_MENTION output — SEE-1330 PHASE2 移除后 passthrough 语义
G2B_INPUT='{"tool_input":{"command":"multica issue comment add xxx --content \"Revy 提到这个 [@Revy](mention://agent/2660961d)\""}}'
run_hook "$G2B_INPUT"
if [ "$HOOK_STDOUT" = "$G2B_INPUT" ]; then
    pass "G2b: mention-bearing content passthrough preserves stdin"
else
    fail "G2b: expected passthrough. stdout: '$HOOK_STDOUT'"
fi

#####################################################################
# GROUP 3: Passthrough scenarios (no JSON output, just stdin)
#####################################################################
separator "G3: Passthrough scenarios preserve stdin unchanged"

# G3a: Correct mention + intent
PASS_JSON='{"tool_input":{"command":"multica issue comment add test-issue --content \"[@Bachi](mention://agent/a5c250e8) 请确认\""},"session_id":"test-123"}'
STDOUT_FILE=$(mktemp /tmp/see400-passthrough.XXXXXX)
echo "$PASS_JSON" | bash "$HOOK_SCRIPT" > "$STDOUT_FILE" 2>/dev/null
ACTUAL=$(cat "$STDOUT_FILE")
rm -f "$STDOUT_FILE"
if [ "$ACTUAL" = "$PASS_JSON" ]; then
    pass "G3a: passthrough preserves JSON exactly"
else
    fail "G3a: passthrough corrupted. Expected: $PASS_JSON, Got: $ACTUAL"
fi

# G3b: Non-comment command
NC_JSON='{"tool_input":{"command":"git push origin main"}}'
STDOUT_FILE2=$(mktemp /tmp/see400-passthrough2.XXXXXX)
echo "$NC_JSON" | bash "$HOOK_SCRIPT" > "$STDOUT_FILE2" 2>/dev/null
ACTUAL2=$(cat "$STDOUT_FILE2")
rm -f "$STDOUT_FILE2"
if [ "$ACTUAL2" = "$NC_JSON" ]; then
    pass "G3b: non-comment passthrough preserves JSON"
else
    fail "G3b: non-comment passthrough corrupted. Got: $ACTUAL2"
fi

#####################################################################
# GROUP 4: Stderr preservation (2>/dev/null removed)
#####################################################################
separator "G4: Stderr is preserved for debugging"

# G4a: Hook produces no stderr on normal operation
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"请确认\""}}'
if [ -z "$HOOK_STDERR" ]; then
    pass "G4a: no unexpected stderr on normal block"
else
    fail "G4a: unexpected stderr: '$HOOK_STDERR'"
fi

# G4b: Hook produces no stderr on passthrough
run_hook '{"tool_input":{"command":"multica issue comment add xxx --content \"[@Atlas](mention://agent/fac3e3a1) 请确认\""}}'
if [ -z "$HOOK_STDERR" ]; then
    pass "G4b: no unexpected stderr on passthrough"
else
    fail "G4b: unexpected stderr: '$HOOK_STDERR'"
fi

#####################################################################
# GROUP 5: Mention-bearing reference sentence passes (PHASE2 removed)
#####################################################################
separator "G5: Mention-bearing passthrough preserves stdin"

# SEE-1330 PHASE2 移除后 mention-bearing 一律放行；SEE-1333 D2 后本用例保留 passthrough 断言
G5_INPUT='{"tool_input":{"command":"multica issue comment add xxx --content \"Atlas 说这个方案可行 [@Atlas](mention://agent/fac3e3a1)\""}}'
run_hook "$G5_INPUT"
if [ "$HOOK_STDOUT" = "$G5_INPUT" ]; then
    pass "G5: mention-bearing passthrough preserves stdin exactly"
else
    fail "G5: expected passthrough. stdout: '$HOOK_STDOUT'"
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
