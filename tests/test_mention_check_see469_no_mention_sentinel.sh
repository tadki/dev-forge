#!/bin/bash
# test_mention_check_see469_no_mention_sentinel.sh
# QA Tests for SEE-469: Retroactive QA for PR #120
# Validates the 3 NO_MENTION sentinel creation paths and bash fast-path.
#
# Related Issue: SEE-469
# Test Type: Functional / Regression / Boundary
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

PROJECT_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SCRIPT="$PROJECT_ROOT/hooks/scripts/mention-check.sh"

# Unique task IDs per scenario (PID-suffixed for isolation)
TASK_G1="see469-g1-$$"
TASK_G2="see469-g2-$$"
TASK_G3="see469-g3-$$"
TASK_G4="see469-g4-$$"
TASK_G5="see469-g5-$$"

# Sentinel path helpers
sp()  { echo "/tmp/mention-check-pass-$1"; }
snm() { echo "/tmp/mention-check-no-mention-$1"; }
sb()  { echo "/tmp/mention-check-block-$1"; }

ALL_TASKS=("$TASK_G1" "$TASK_G2" "$TASK_G3" "$TASK_G4" "$TASK_G5")

cleanup_all_sentinels() {
    for tid in "${ALL_TASKS[@]}"; do
        rm -f "$(sp "$tid")" "$(snm "$tid")" "$(sb "$tid")"
    done
}

cleanup_all_sentinels

run_hook() {
    local task_id="$1"
    local input="$2"
    local stdout_f stderr_f
    stdout_f=$(mktemp /tmp/see469-stdout.XXXXXX)
    stderr_f=$(mktemp /tmp/see469-stderr.XXXXXX)

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

echo "============================================"
echo "  SEE-469 Retroactive QA for PR #120"
echo "  Date: $(date -Iseconds)"
echo "  Author: Revy (QA Agent)"
echo "  Branch: $(git branch --show-current 2>/dev/null || echo 'unknown')"
echo "============================================"

#####################################################################
# Group 1: NO_MENTION sentinel creation (3 paths from PR #120)
#####################################################################
separator "G1: NO_MENTION sentinel creation — 3 new paths"

# --- G1a: --content-stdin with no heredoc body (extraction fails) ---
# The command has --content-stdin but the heredoc body is not in tool_input.command
# This simulates the case where the shell passes heredoc via stdin to the multica CLI
G1A_INPUT='{"tool_input":{"command":"multica issue comment add SEE-999 --content-stdin"}}'
run_hook "$TASK_G1" "$G1A_INPUT"
assert_blocked "G1a: --content-stdin with no heredoc body → first-time BLOCK"
assert_sentinel_exists "$(snm "$TASK_G1")" "G1a: NO_MENTION sentinel created (stdin extraction fail)"
assert_sentinel_not_exists "$(sp "$TASK_G1")" "G1a: PASS sentinel NOT created (was blocked)"

# Second call with same task → still BLOCKED (SEE-1333 D2: 逐条拦截, no fast-path)
run_hook "$TASK_G1" "$G1A_INPUT"
assert_blocked "G1a-2: second call → still BLOCKED (SEE-1333 D2 逐条拦截)"

# --- G1b: --content-stdin with malformed/unterminated heredoc ---
cleanup_all_sentinels
# This heredoc format cannot be parsed by the hook's regex (unterminated)
G1B_INPUT='{"tool_input":{"command":"multica issue comment add SEE-999 --content-stdin <<EOF\nunterminated content"}}'
run_hook "$TASK_G2" "$G1B_INPUT"
assert_blocked "G1b: --content-stdin malformed heredoc → BLOCK"
assert_sentinel_exists "$(snm "$TASK_G2")" "G1b: NO_MENTION sentinel created (malformed stdin)"

# Second call → still BLOCKED (SEE-1333 D2: 逐条拦截)
run_hook "$TASK_G2" "$G1B_INPUT"
assert_blocked "G1b-2: second call → still BLOCKED (SEE-1333 D2 逐条拦截)"

# --- G1c: --content-file with non-existent file ---
# SEE-1054 P0: file-not-found is now a hard error (CONTENT_FILE_UNREADABLE),
# not NO_MENTION. No sentinel is created or consumed — every call reports.
cleanup_all_sentinels
G1C_INPUT='{"tool_input":{"command":"multica issue comment add SEE-999 --content-file /tmp/see469-nonexistent-file-$$.txt"}}'
run_hook "$TASK_G3" "$G1C_INPUT"
assert_blocked "G1c: --content-file non-existent → BLOCK (hard error)"
assert_sentinel_not_exists "$(snm "$TASK_G3")" "G1c: NO_MENTION sentinel NOT created (hard error, no sentinel)"
assert_sentinel_not_exists "$(sp "$TASK_G3")" "G1c: PASS sentinel NOT created (was blocked)"

# Second call → still BLOCKED (硬错误不消费 sentinel, 每次都报)
run_hook "$TASK_G3" "$G1C_INPUT"
assert_blocked "G1c-2: second call → still BLOCKED (hard error repeats)"

# --- G1d: --content-file with here-string-like path that doesn't exist ---
# SEE-1054 P0: same hard-error semantics for quoted path
cleanup_all_sentinels
G1D_INPUT='{"tool_input":{"command":"multica issue comment add SEE-999 --content-file \"/tmp/see469-missing-$$.txt\""}}'
run_hook "$TASK_G4" "$G1D_INPUT"
assert_blocked "G1d: --content-file quoted non-existent → BLOCK (hard error)"
assert_sentinel_not_exists "$(snm "$TASK_G4")" "G1d: NO_MENTION sentinel NOT created (hard error)"
assert_sentinel_not_exists "$(sp "$TASK_G4")" "G1d: PASS sentinel NOT created"

# Second call → still BLOCKED (硬错误不消费 sentinel, 每次都报)
run_hook "$TASK_G4" "$G1D_INPUT"
assert_blocked "G1d-2: second call → still BLOCKED (hard error repeats)"

# --- G1e: No content mode matched at all (no --content, --content-stdin, or --content-file) ---
cleanup_all_sentinels
# The command is a comment-add but has no content flag at all
G1E_INPUT='{"tool_input":{"command":"multica issue comment add SEE-999"}}'
run_hook "$TASK_G5" "$G1E_INPUT"
assert_blocked "G1e: no content mode matched → BLOCK"
assert_sentinel_exists "$(snm "$TASK_G5")" "G1e: NO_MENTION sentinel created (no content mode)"
assert_sentinel_not_exists "$(sp "$TASK_G5")" "G1e: PASS sentinel NOT created (was blocked)"

# Second call → still BLOCKED (SEE-1333 D2: 逐条拦截)
run_hook "$TASK_G5" "$G1E_INPUT"
assert_blocked "G1e-2: second call → still BLOCKED (SEE-1333 D2 逐条拦截)"

# --- G1f: Combined — verify each path creates only 1 sentinel per task ---
cleanup_all_sentinels
TASK_COMB="see469-comb-$$"
run_hook "$TASK_COMB" "$G1A_INPUT"
assert_sentinel_exists "$(snm "$TASK_COMB")" "G1f-1: first call creates NO_MENTION sentinel"

# Multiple second calls
run_hook "$TASK_COMB" "$G1A_INPUT"
run_hook "$TASK_COMB" "$G1A_INPUT"
NM_COUNT=$(find /tmp -maxdepth 1 -name "mention-check-no-mention-${TASK_COMB}" 2>/dev/null | wc -l)
if [ "$NM_COUNT" -eq 1 ]; then
    pass "G1f-2: exactly 1 NO_MENTION sentinel after multiple calls"
else
    fail "G1f-2: expected 1 NO_MENTION sentinel, found $NM_COUNT"
fi
rm -f "$(snm "$TASK_COMB")" "$(sp "$TASK_COMB")"

#####################################################################
# Group 2: Bash layer fast-path (all 3 sentinel types)
#####################################################################
separator "G2: Bash layer fast-path — Node.js skip verification"

# --- G2a: Pre-create PASS sentinel → bash exits without Node.js ---
cleanup_all_sentinels
TASK_FP="see469-fp-$$"
touch "$(sp "$TASK_FP")"

# Use malformed JSON that would crash Node.js if it ran
MALFORMED='{not valid json at all!!!}'
run_hook "$TASK_FP" "$MALFORMED"
assert_passthrough "G2a: PASS sentinel → bash early exit (malformed input survives)" "$MALFORMED"
rm -f "$(sp "$TASK_FP")"

# --- G2b: Pre-create NO_MENTION sentinel → bash exits without Node.js ---
touch "$(snm "$TASK_FP")"
run_hook "$TASK_FP" "$MALFORMED"
assert_passthrough "G2b: NO_MENTION sentinel → bash early exit (malformed input survives)" "$MALFORMED"
rm -f "$(snm "$TASK_FP")"

# --- G2c: Pre-create BLOCK sentinel → bash exits without Node.js ---
touch "$(sb "$TASK_FP")"
run_hook "$TASK_FP" "$MALFORMED"
assert_passthrough "G2c: BLOCK sentinel → bash early exit (malformed input survives)" "$MALFORMED"
rm -f "$(sb "$TASK_FP")"

# --- G2d: Multiple sentinel types present → bash still exits ---
touch "$(snm "$TASK_FP")"
touch "$(sb "$TASK_FP")"
run_hook "$TASK_FP" "$MALFORMED"
assert_passthrough "G2d: both NO_MENTION+BLOCK sentinels → bash early exit" "$MALFORMED"
rm -f "$(snm "$TASK_FP")" "$(sb "$TASK_FP")"

# --- G2e: No MULTICA_TASK_ID → no sentinel check, Node.js runs normally ---
# Must explicitly unset MULTICA_TASK_ID to avoid inheriting from parent environment
NO_TASK_STDOUT_F=$(mktemp /tmp/see469-fp.XXXXXX)
printf '%s' '{"tool_input":{"command":"multica issue comment add SEE-999 --content \"no mention\""}}' | env -u MULTICA_TASK_ID bash "$HOOK_SCRIPT" > "$NO_TASK_STDOUT_F" 2>/dev/null
NO_TASK_EXIT=$?
NO_TASK_OUTPUT=$(cat "$NO_TASK_STDOUT_F")
rm -f "$NO_TASK_STDOUT_F"

if echo "$NO_TASK_OUTPUT" | grep -q '"permissionDecision"'; then
    pass "G2e: no TASK_ID → Node.js runs (blocked correctly, no sentinels)"
else
    fail "G2e: no TASK_ID → expected block, got passthrough"
fi

#####################################################################
# Group 3: Regression — normal paths still work
#####################################################################
separator "G3: Regression — normal paths"

# --- G3a: Normal mention content → still blocked (first time) ---
cleanup_all_sentinels
TASK_REG="see469-reg-$$"
MENTION_BODY='[@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5) 请处理这个任务'
G3A_INPUT="{\"tool_input\":{\"command\":\"multica issue comment add SEE-999 --content \\\"${MENTION_BODY}\\\"\"}}"
run_hook "$TASK_REG" "$G3A_INPUT"
assert_passthrough "G3a: valid action mention → passes (no block)" "$G3A_INPUT"
assert_sentinel_exists "$(sp "$TASK_REG")" "G3a: PASS sentinel created for valid action mention"

# --- G3b: Normal no-mention content → still blocked on first call ---
cleanup_all_sentinels
TASK_REG2="see469-reg2-$$"
NO_MENTION_BODY='这是一条没有mention的普通评论'
G3B_INPUT="{\"tool_input\":{\"command\":\"multica issue comment add SEE-999 --content \\\"${NO_MENTION_BODY}\\\"\"}}"
run_hook "$TASK_REG2" "$G3B_INPUT"
assert_blocked "G3b: no-mention content → blocked (first time)"
assert_sentinel_exists "$(snm "$TASK_REG2")" "G3b: NO_MENTION sentinel created for no-mention content"

# Second call → still BLOCKED (SEE-1333 D2: 逐条拦截)
run_hook "$TASK_REG2" "$G3B_INPUT"
assert_blocked "G3b-2: no-mention second call → still BLOCKED (SEE-1333 D2 逐条拦截)"

# --- G3c: Non-comment command → passthrough regardless ---
cleanup_all_sentinels
G3C_INPUT='{"tool_input":{"command":"git push origin main"}}'
run_hook "$TASK_REG2" "$G3C_INPUT"
assert_passthrough "G3c: non-comment command → passthrough" "$G3C_INPUT"

# --- G3d: Pure call-out mention → passes ---
G3D_INPUT='{"tool_input":{"command":"multica issue comment add SEE-999 --content \"[@Bachi](mention://agent/a5c250e8-7257-466e-b45a-03f995c7206c)\""}}'
run_hook "$TASK_REG2" "$G3D_INPUT"
assert_passthrough "G3d: pure call-out mention → passes" "$G3D_INPUT"

# --- G3e: heredoc with valid mention content → passes ---
cleanup_all_sentinels
TASK_REG3="see469-reg3-$$"
G3E_INPUT="{\"tool_input\":{\"command\":\"multica issue comment add SEE-999 --content-stdin <<-EOF\\n[@Bachi](mention://agent/a5c250e8-7257-466e-b45a-03f995c7206c) 请帮忙检查\\nEOF\"}}"
run_hook "$TASK_REG3" "$G3E_INPUT"
assert_passthrough "G3e: heredoc with valid action mention → passes" "$G3E_INPUT"

# --- G3f: --content-file with valid no-mention content → blocked first time, passthrough second ---
cleanup_all_sentinels
TASK_REG4="see469-reg4-$$"
CONTENT_FILE="/tmp/see469-reg4-content-$$.txt"
echo "普通评论无mention" > "$CONTENT_FILE"
G3F_INPUT="{\"tool_input\":{\"command\":\"multica issue comment add SEE-999 --content-file ${CONTENT_FILE}\"}}"
run_hook "$TASK_REG4" "$G3F_INPUT"
assert_blocked "G3f: --content-file no-mention → blocked (first time)"
assert_sentinel_exists "$(snm "$TASK_REG4")" "G3f: NO_MENTION sentinel created"

run_hook "$TASK_REG4" "$G3F_INPUT"
assert_blocked "G3f-2: --content-file no-mention → still BLOCKED (SEE-1333 D2 逐条拦截)"
rm -f "$CONTENT_FILE"

# --- G3g: here-string with valid content → passes ---
cleanup_all_sentinels
TASK_REG5="see469-reg5-$$"
G3G_INPUT='{"tool_input":{"command":"multica issue comment add SEE-999 --content-stdin <<< \"[@Bachi](mention://agent/a5c250e8-7257-466e-b45a-03f995c7206c) 请确认\""}}'
run_hook "$TASK_REG5" "$G3G_INPUT"
assert_passthrough "G3g: here-string with valid action mention → passes" "$G3G_INPUT"

#####################################################################
# Cleanup
#####################################################################
cleanup_all_sentinels
rm -f /tmp/see469-*

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
