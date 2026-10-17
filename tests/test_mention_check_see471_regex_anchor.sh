#!/bin/bash
# test_mention_check_see471_regex_anchor.sh
# Tests for SEE-471: regex ^ anchor fix — non comment-add commands with
#   "multica issue comment add" as a substring must NOT be intercepted.
#
# Related Issue: SEE-471
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

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
    local TASK_ID="see471-test-${TEST_COUNTER}"
    TEST_COUNTER=$((TEST_COUNTER + 1))
    cleanup_sentinels "$TASK_ID"

    local STDOUT_FILE=$(mktemp /tmp/see471-stdout.XXXXXX)
    local STDERR_FILE=$(mktemp /tmp/see471-stderr.XXXXXX)

    printf '%s' "$INPUT" | MULTICA_TASK_ID="$TASK_ID" bash "$HOOK_SCRIPT" > "$STDOUT_FILE" 2> "$STDERR_FILE"
    local EXIT_CODE=$?

    HOOK_STDOUT=$(cat "$STDOUT_FILE")
    HOOK_STDERR=$(cat "$STDERR_FILE")
    HOOK_EXIT=$EXIT_CODE

    rm -f "$STDOUT_FILE" "$STDERR_FILE"
}

assert_passthrough() {
    local label="$1"
    local input="$2"
    if [ "$HOOK_STDOUT" = "$input" ]; then
        pass "$label — raw passthrough"
    elif echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
        fail "$label — unexpectedly blocked. stdout: '$HOOK_STDOUT'"
    else
        pass "$label — passthrough (no deny)"
    fi
}

assert_blocked() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
        pass "$label — blocked (deny)"
    else
        fail "$label — not blocked. stdout: '$HOOK_STDOUT'"
    fi
}

echo "============================================"
echo "  SEE-471 Regex Anchor Fix Tests"
echo "  Date: $(date -Iseconds)"
echo "  Author: Bachi (Backend Agent)"
echo "  Branch: $(git branch --show-current 2>/dev/null || echo 'unknown')"
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

# Verify the fix is in place (SEE-756 pipe-aware anchor supersedes SEE-471's bare ^ anchor)
if grep -Fq '(?:^|\\|)' "$HOOK_SCRIPT"; then
    pass "Regex contains pipe-aware anchor (?:^|\\|)"
else
    fail "Regex MISSING pipe-aware anchor — fix not applied"
fi

#####################################################################
# G1: multica issue create with substring in description → passthrough
#####################################################################
separator "G1: issue create with substring in description"

# G1a: Exact reproduction from SEE-471
G1A_INPUT='{"tool_input":{"command":"multica issue create --title \"test\" --description \"When using multica issue comment add command\""}}'
run_hook "$G1A_INPUT"
assert_passthrough "G1a: multica issue create --description with substring" "$G1A_INPUT"

# G1b: multica issue create with description containing substring at end
G1B_INPUT='{"tool_input":{"command":"multica issue create --title \"test\" --description \"See multica issue comment add for details\""}}'
run_hook "$G1B_INPUT"
assert_passthrough "G1b: substring at end of description" "$G1B_INPUT"

# G1c: multica issue create with description containing substring at start
G1C_INPUT='{"tool_input":{"command":"multica issue create --title \"test\" --description \"multica issue comment add is the command\""}}'
run_hook "$G1C_INPUT"
assert_passthrough "G1c: substring at start of description" "$G1C_INPUT"

# G1d: multica issue update with substring
G1D_INPUT='{"tool_input":{"command":"multica issue update SEE-123 --description \"Use multica issue comment add to reply\""}}'
run_hook "$G1D_INPUT"
assert_passthrough "G1d: multica issue update with substring" "$G1D_INPUT"

#####################################################################
# G2: Other commands with substring → passthrough
#####################################################################
separator "G2: Other commands with substring in args"

# G2a: echo command containing the substring
G2A_INPUT='{"tool_input":{"command":"echo \"multica issue comment add is blocked\""}}'
run_hook "$G2A_INPUT"
assert_passthrough "G2a: echo with substring" "$G2A_INPUT"

# G2b: cat heredoc containing the substring
G2B_INPUT='{"tool_input":{"command":"cat <<EOF\\nmultica issue comment add\\nEOF"}}'
run_hook "$G2B_INPUT"
assert_passthrough "G2b: cat heredoc with substring" "$G2B_INPUT"

# G2c: grep for the substring
G2C_INPUT='{"tool_input":{"command":"grep -r \"multica issue comment add\" ."}}'
run_hook "$G2C_INPUT"
assert_passthrough "G2c: grep with substring" "$G2C_INPUT"

# G2d: Variable assignment containing the substring
G2D_INPUT='{"tool_input":{"command":"CMD=\"multica issue comment add\" && echo $CMD"}}'
run_hook "$G2D_INPUT"
assert_passthrough "G2d: variable with substring" "$G2D_INPUT"

# G2e: git commit message containing the substring
G2E_INPUT='{"tool_input":{"command":"git commit -m \"fix: multica issue comment add regex\""}}'
run_hook "$G2E_INPUT"
assert_passthrough "G2e: git commit with substring" "$G2E_INPUT"

#####################################################################
# G3: Actual multica issue comment add still detected
#####################################################################
separator "G3: Actual comment-add commands still detected"

# G3a: Standard comment-add with mention → passthrough (valid)
G3A_INPUT='{"tool_input":{"command":"multica issue comment add SEE-123 --content \"请处理这个任务 [@Atlas](mention://agent/fac3e3a1)\""}}'
run_hook "$G3A_INPUT"
assert_passthrough "G3a: valid comment-add with mention" "$G3A_INPUT"

# G3b: comment-add without mention → blocked
G3B_INPUT='{"tool_input":{"command":"multica issue comment add SEE-123 --content \"普通评论\""}}'
run_hook "$G3B_INPUT"
assert_blocked "G3b: comment-add without mention → blocked"

# G3c: comment-add with extra whitespace at start — pipe-aware regex \s* consumes leading space, still detected
G3C_INPUT='{"tool_input":{"command":" multica issue comment add SEE-123 --content \"测试\""}}'
run_hook "$G3C_INPUT"
assert_blocked "G3c: leading space before multica → still detected (no mention)"

# G3d: comment-add with no content flags → blocked
G3D_INPUT='{"tool_input":{"command":"multica issue comment add SEE-123"}}'
run_hook "$G3D_INPUT"
assert_blocked "G3d: comment-add no content → blocked"

# G3e: comment-add with --content-stdin → blocked (no extractable content)
G3E_INPUT='{"tool_input":{"command":"multica issue comment add SEE-123 --content-stdin"}}'
run_hook "$G3E_INPUT"
assert_blocked "G3e: comment-add --content-stdin → blocked"

#####################################################################
# G4: Edge — substring in content of comment-add still detected
#####################################################################
separator "G4: Edge cases"

# G4a: comment-add with substring in content → still detected (no mention → blocked)
G4A_INPUT='{"tool_input":{"command":"multica issue comment add SEE-123 --content \"testing multica issue comment add in content\""}}'
run_hook "$G4A_INPUT"
assert_blocked "G4a: comment-add with substring in content → still detected (no mention)"

#####################################################################
# Cleanup
#####################################################################
for i in $(seq 0 $((TEST_COUNTER - 1))); do
    cleanup_sentinels "see471-test-$i"
done
rm -f /tmp/see471-*

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
