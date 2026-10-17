#!/bin/bash
# test_mention_check_cd_chain.sh
# Regression tests for SEE-1092: mention-check.sh trigger regex hardening.
# Verifies that composite/prefixed invocations of `multica issue comment add`
# (cd && / space-separated cd / newline / semicolon / bash -c) are still
# detected and BLOCKED when the comment carries no @mention, while quoted
# string literals that merely contain the phrase are NOT intercepted.
#
# Related Issue: SEE-1092
# Test Type: Unit / Regression
# Author: Bachi

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

TEST_COUNTER=0

# Sentinel path helpers
sp()  { echo "/tmp/mention-check-pass-$1"; }
snm() { echo "/tmp/mention-check-no-mention-$1"; }
sb()  { echo "/tmp/mention-check-block-$1"; }

cleanup_sentinels() {
    local tid="$1"
    rm -f "$(sp "$tid")" "$(snm "$tid")" "$(sb "$tid")"
}

run_hook() {
    local INPUT="$1"
    local TASK_ID="see1092-test-${TEST_COUNTER}-$$"
    TEST_COUNTER=$((TEST_COUNTER + 1))
    cleanup_sentinels "$TASK_ID"

    local STDOUT_FILE=$(mktemp /tmp/see1092-stdout.XXXXXX)
    local STDERR_FILE=$(mktemp /tmp/see1092-stderr.XXXXXX)

    printf '%s' "$INPUT" | MULTICA_TASK_ID="$TASK_ID" MULTICA_AGENT_NAME="Bachi" bash "$HOOK_SCRIPT" > "$STDOUT_FILE" 2> "$STDERR_FILE"
    HOOK_EXIT=$?

    HOOK_STDOUT=$(cat "$STDOUT_FILE")
    HOOK_STDERR=$(cat "$STDERR_FILE")

    rm -f "$STDOUT_FILE" "$STDERR_FILE"
}

assert_blocked() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
        pass "$label — BLOCKED"
    else
        fail "$label — NOT blocked. stdout: '$(echo "$HOOK_STDOUT" | head -c 300)'"
    fi
}

assert_passthrough() {
    local label="$1"
    local input="$2"
    if [ "$HOOK_STDOUT" = "$input" ]; then
        pass "$label — raw passthrough"
    elif echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
        fail "$label — unexpectedly BLOCKED. stdout: '$(echo "$HOOK_STDOUT" | head -c 300)'"
    else
        pass "$label — passthrough (no deny)"
    fi
}

echo "================================================================"
echo "  SEE-1092 Trigger Regex Hardening Tests"
echo "  Date: $(date -Iseconds)"
echo "  Hook: $HOOK_SCRIPT"
echo "  Branch: $(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo 'unknown')"
echo "================================================================"

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

if grep -q "isRealCommentAdd" "$HOOK_SCRIPT"; then
    pass "isRealCommentAdd fallback present"
else
    fail "isRealCommentAdd fallback MISSING"
fi

if grep -q "splitShellCommands" "$HOOK_SCRIPT"; then
    pass "splitShellCommands present"
else
    fail "splitShellCommands MISSING"
fi

if grep -Fq '(?:^|\\|)' "$HOOK_SCRIPT"; then
    pass "Pipe-aware fast-path regex present"
else
    fail "Pipe-aware fast-path regex MISSING"
fi

#####################################################################
# T1: BLOCK — cd <path> && multica issue comment add
#####################################################################
separator "T1: BLOCK — cd && chain"

run_hook '{"tool_input":{"command":"cd /tmp && multica issue comment add SEE-123 --content \"no mention\""}}'
assert_blocked "T1a: cd /tmp && multica issue comment add"

run_hook '{"tool_input":{"command":"cd /home/jerry/workdir && multica issue comment add SEE-123 --content-stdin"}}'
assert_blocked "T1b: cd with long path && comment-add --content-stdin"

#####################################################################
# T2: BLOCK — space-separated cd (no && / ;)
#####################################################################
separator "T2: BLOCK — space-separated cd"

run_hook '{"tool_input":{"command":"cd /tmp multica issue comment add SEE-123 --content \"no mention\""}}'
assert_blocked "T2a: cd /tmp multica issue comment add"

#####################################################################
# T3: BLOCK — newline between cd and multica
#####################################################################
separator "T3: BLOCK — newline"

run_hook '{"tool_input":{"command":"cd /tmp\nmultica issue comment add SEE-123 --content \"no mention\""}}'
assert_blocked "T3a: cd /tmp newline multica issue comment add"

run_hook '{"tool_input":{"command":"# step 1\ncd /home\nmultica issue comment add SEE-123 --content \"no mention\""}}'
assert_blocked "T3b: comment line + cd + newline + comment-add"

#####################################################################
# T4: BLOCK — semicolon chain
#####################################################################
separator "T4: BLOCK — ; separator"

run_hook '{"tool_input":{"command":"cd /tmp; multica issue comment add SEE-123 --content \"no mention\""}}'
assert_blocked "T4a: cd /tmp; multica issue comment add"

run_hook '{"tool_input":{"command":"echo hello; multica issue comment add SEE-123 --content \"no mention\""}}'
assert_blocked "T4b: echo; multica issue comment add"

#####################################################################
# T5: BLOCK — bash -c nested
#####################################################################
separator "T5: BLOCK — bash -c nested"

run_hook '{"tool_input":{"command":"bash -c \"multica issue comment add SEE-123 --content \\\"no mention\\\"\""}}'
assert_blocked "T5a: bash -c double-quoted comment-add"

run_hook '{"tool_input":{"command":"sh -c '\''multica issue comment add SEE-123 --content \"no mention\"'\''"}}'
assert_blocked "T5b: sh -c single-quoted comment-add"

run_hook '{"tool_input":{"command":"echo hello && bash -c \"multica issue comment add SEE-123 --content \\\"no mention\\\"\""}}'
assert_blocked "T5c: && + bash -c nested comment-add"

#####################################################################
# T6: BLOCK — baseline: direct invocation + heredoc pipe (regression)
#####################################################################
separator "T6: BLOCK — baseline detections (regression)"

run_hook '{"tool_input":{"command":"multica issue comment add SEE-123 --content \"no mention\""}}'
assert_blocked "T6a: direct comment-add"

run_hook '{"tool_input":{"command":"cat <<EOF | multica issue comment add SEE-123 --content-stdin"}}'
assert_blocked "T6b: heredoc pipe comment-add"

run_hook '{"tool_input":{"command":"cd /tmp && MULTICA_AGENT_NAME=Bachi multica issue comment add SEE-123 --content \"no mention\""}}'
assert_blocked "T6c: cd && env-prefixed comment-add"

#####################################################################
# P1: PASS — quoted string literals are NOT intercepted
#####################################################################
separator "P1: PASS — quoted literals (no false positive)"

run_hook '{"tool_input":{"command":"echo \"multica issue comment add\""}}'
assert_passthrough "P1a: echo quoted" '{"tool_input":{"command":"echo \"multica issue comment add\""}}'

run_hook '{"tool_input":{"command":"grep -r \"multica issue comment add\" ."}}'
assert_passthrough "P1b: grep quoted" '{"tool_input":{"command":"grep -r \"multica issue comment add\" ."}}'

run_hook '{"tool_input":{"command":"git commit -m \"fix: multica issue comment add regex\""}}'
assert_passthrough "P1c: git commit quoted" '{"tool_input":{"command":"git commit -m \"fix: multica issue comment add regex\""}}'

run_hook '{"tool_input":{"command":"multica issue create --title t --description \"multica issue comment add\""}}'
assert_passthrough "P1d: issue create --description quoted" '{"tool_input":{"command":"multica issue create --title t --description \"multica issue comment add\""}}'

run_hook '{"tool_input":{"command":"cat <<EOF\nmultica issue comment add\nEOF"}}'
assert_passthrough "P1e: cat heredoc body quoted" '{"tool_input":{"command":"cat <<EOF\nmultica issue comment add\nEOF"}}'

#####################################################################
# P2: PASS — real comment-add WITH valid mention still passes
#####################################################################
separator "P2: PASS — comment-add with valid mention"

run_hook '{"tool_input":{"command":"cd /tmp && multica issue comment add SEE-123 --content \"[@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5)\""}}'
assert_passthrough "P2a: cd && comment-add with mention" '{"tool_input":{"command":"cd /tmp && multica issue comment add SEE-123 --content \"[@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5)\""}}'

#####################################################################
# Cleanup
#####################################################################
for i in $(seq 0 $((TEST_COUNTER - 1))); do
    cleanup_sentinels "see1092-test-$i-$$"
done
rm -f /tmp/see1092-stdout.* /tmp/see1092-stderr.*

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
