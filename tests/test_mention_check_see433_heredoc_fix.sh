#!/bin/bash
# test_mention_check_see433_heredoc_fix.sh
# QA Test Script for SEE-433: mention-check hook heredoc content extraction fix
#
# Validates two fix points in .claude/hooks/scripts/mention-check.sh:
#   FIX-1 (line 75-82): MODE 2 --content-stdin detected but heredoc body absent → NO_MENTION
#   FIX-2 (line 101-106): content=null fallback → NO_MENTION (was PASS before fix)
#
# Test matrix:
#   - MODE 1: --content "..." with/without mention
#   - MODE 2: --content-stdin + here-string <<< with/without mention
#   - MODE 2: --content-stdin + heredoc no body (core fix, FIX-1)
#   - MODE 2: --content-stdin alone, no heredoc (FIX-1)
#   - MODE 3: --content-file <path> with/without mention
#   - Fallback: content=null (FIX-2)
#   - Regression: existing behavior preserved
#
# Related Issue: SEE-433
# Test Type: Functional + Regression
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

TEST_COUNTER=0

run_hook() {
    local INPUT="$1"
    local TASK_ID="see433-test-${TEST_COUNTER}"
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

assert_exit_0() {
    local label="$1"
    if [ "$HOOK_EXIT" -eq 0 ]; then
        pass "$label — exit code is 0"
    else
        fail "$label — exit code is $HOOK_EXIT, expected 0"
    fi
}

assert_blocked() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"permissionDecision".*"deny"'; then
        pass "$label — BLOCKED (permissionDecision=deny)"
    else
        fail "$label — NOT blocked. stdout: '$HOOK_STDOUT'"
    fi
}

assert_passthrough() {
    local label="$1"
    if [ -n "$HOOK_STDOUT" ] && ! echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
        pass "$label — PASSTHROUGH (no deny)"
    else
        fail "$label — unexpectedly blocked or empty. stdout: '$HOOK_STDOUT'"
    fi
}

assert_has_warning() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -qi "WARNING"; then
        pass "$label — WARNING present"
    else
        fail "$label — WARNING missing. stdout: '$HOOK_STDOUT'"
    fi
}

# SEE-1381 §SPEC-014 对齐现行实现：no-mention 拦截输出为 deny + ERROR 引导文案
# （SEE-1333 D2 硬拦截），不再是旧 WARNING 字样。
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

echo "============================================"
echo "  SEE-433 mention-check Heredoc Fix QA Test"
echo "  Date: $(date -Iseconds)"
echo "  Tester: Revy (QA Agent)"
echo "  Source Branch: agent/bachi/c8a821a4-1779098727"
echo "  Fix Commit: f725065"
echo "  Test Branch: $(git branch --show-current)"
echo "============================================"
echo ""

#####################################################################
# GROUP 0: Prerequisites
#####################################################################
separator "Group 0: Prerequisites"

if [ -f "$HOOK_SCRIPT" ]; then
    pass "G0.1 hook script exists"
else
    fail "G0.1 hook script missing: $HOOK_SCRIPT"
    echo "FATAL: cannot proceed"
    exit 1
fi

# Verify the fix is present by checking for the new NO_MENTION in MODE 2 fallback
if grep -q "content cannot be extracted" "$HOOK_SCRIPT" && grep -q "heredoc body" "$HOOK_SCRIPT"; then
    pass "G0.2 FIX-1 code present (MODE 2 else → NO_MENTION)"
else
    fail "G0.2 FIX-1 code NOT found — wrong version of hook?"
fi

if grep -q "No content mode matched or extraction failed" "$HOOK_SCRIPT"; then
    pass "G0.3 FIX-2 code present (fallback content=null → NO_MENTION)"
else
    fail "G0.3 FIX-2 code NOT found — wrong version of hook?"
fi

#####################################################################
# GROUP 1: MODE 1 --content "..." (Normal Path)
#####################################################################
separator "Group 1: MODE 1 --content (Normal Path)"

# G1.1: MODE 1 with mention → PASS (passthrough)
run_hook '{"tool_input":{"command":"multica issue comment add issue-123 --content \"Test message with [@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5) please review\""}}'
assert_passthrough "G1.1 MODE 1 with mention → passthrough"
assert_exit_0 "G1.1"

# G1.2: MODE 1 without mention → BLOCK (NO_MENTION)
run_hook '{"tool_input":{"command":"multica issue comment add issue-123 --content \"Just a regular comment no mention\""}}'
assert_blocked "G1.2 MODE 1 no mention → BLOCKED"
assert_deny_text "G1.2"
assert_exit_0 "G1.2"

# G1.3: MODE 1 with mention but reference semantics → depends on reranker
# Using direct callout (mention-only sentence) → should PASS
run_hook '{"tool_input":{"command":"multica issue comment add issue-123 --content \"[@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5)\""}}'
assert_passthrough "G1.3 MODE 1 mention-only callout → passthrough"
assert_exit_0 "G1.3"

#####################################################################
# GROUP 2: MODE 2 --content-stdin + here-string <<< (Normal Path)
#####################################################################
separator "Group 2: MODE 2 --content-stdin + here-string <<< (Normal Path)"

# G2.1: MODE 2 here-string with mention → PASS
run_hook '{"tool_input":{"command":"multica issue comment add issue-123 --content-stdin <<< '"'"'Test with [@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5)'"'"'"}}'
assert_passthrough "G2.1 MODE 2 here-string with mention → passthrough"
assert_exit_0 "G2.1"

# G2.2: MODE 2 here-string without mention → BLOCK (NO_MENTION)
run_hook '{"tool_input":{"command":"multica issue comment add issue-123 --content-stdin <<< '"'"'Regular content no mention here'"'"'"}}'
assert_blocked "G2.2 MODE 2 here-string no mention → BLOCKED"
assert_deny_text "G2.2"
assert_exit_0 "G2.2"

# G2.3: MODE 2 here-string with double quotes + mention
run_hook '{"tool_input":{"command":"multica issue comment add issue-123 --content-stdin <<< \"Hello [@Revy](mention://agent/2660961d-6add-4d15-8d1b-dea446142a94)\""}}'
assert_passthrough "G2.3 MODE 2 here-string double-quote with mention → passthrough"
assert_exit_0 "G2.3"

#####################################################################
# GROUP 3: MODE 2 --content-stdin + heredoc no body (CORE FIX POINT, FIX-1)
#####################################################################
separator "Group 3: MODE 2 --content-stdin + heredoc no body (FIX-1, Core Fix)"

# G3.1: --content-stdin with heredoc syntax but body not in command string
# This simulates the real-world bypass scenario: heredoc body goes through
# shell stdin, not present in tool_input.command
run_hook '{"tool_input":{"command":"multica issue comment add issue-123 --content-stdin <<EOF\nEOF"}}'
assert_blocked "G3.1 MODE 2 heredoc empty body → BLOCKED (was PASS before fix)"
assert_deny_text "G3.1"
assert_exit_0 "G3.1"

# G3.2: --content-stdin with heredoc, body contains mention but NOT in command
# The heredoc body goes through shell stdin so it's invisible to the regex
# This is the exact bypass vector that was exploited → must BLOCK
run_hook '{"tool_input":{"command":"multica issue comment add issue-123 --content-stdin <<HEREDOC\nHEREDOC"}}'
assert_blocked "G3.2 MODE 2 heredoc with named delimiter no body → BLOCKED"
assert_exit_0 "G3.2"

# G3.3: --content-stdin with strip-tabs heredoc <<-
run_hook '{"tool_input":{"command":"multica issue comment add issue-123 --content-stdin <<-END\nEND"}}'
assert_blocked "G3.3 MODE 2 <<- heredoc no body → BLOCKED"
assert_exit_0 "G3.3"

# G3.4: --content-stdin with heredoc that HAS body in command → should extract and check
run_hook '{"tool_input":{"command":"multica issue comment add issue-123 --content-stdin <<EOF\nHello no mention\nEOF"}}'
assert_blocked "G3.4 MODE 2 heredoc with body no mention → BLOCKED"
assert_exit_0 "G3.4"

# G3.5: --content-stdin with heredoc body that HAS mention → should PASS
run_hook '{"tool_input":{"command":"multica issue comment add issue-123 --content-stdin <<EOF\nHello [@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5)\nEOF"}}'
assert_passthrough "G3.5 MODE 2 heredoc with body + mention → passthrough"
assert_exit_0 "G3.5"

#####################################################################
# GROUP 4: MODE 2 --content-stdin alone (no heredoc/here-string, FIX-1)
#####################################################################
separator "Group 4: MODE 2 --content-stdin alone (FIX-1)"

# G4.1: --content-stdin with no heredoc or here-string → BLOCK
# This is the case where content comes from piped stdin, not visible in command
run_hook '{"tool_input":{"command":"multica issue comment add issue-123 --content-stdin"}}'
assert_blocked "G4.1 MODE 2 --content-stdin alone → BLOCKED"
assert_deny_text "G4.1"
assert_exit_0 "G4.1"

# G4.2: --content-stdin at end with trailing spaces
run_hook '{"tool_input":{"command":"multica issue comment add issue-123 --content-stdin  "}}'
assert_blocked "G4.2 MODE 2 --content-stdin with trailing spaces → BLOCKED"
assert_exit_0 "G4.2"

# G4.3: --content-stdin with parent flag (real-world scenario)
run_hook '{"tool_input":{"command":"multica issue comment add issue-123 --parent comment-456 --content-stdin"}}'
assert_blocked "G4.3 MODE 2 --content-stdin with parent → BLOCKED"
assert_exit_0 "G4.3"

#####################################################################
# GROUP 5: MODE 3 --content-file (Normal Path)
#####################################################################
separator "Group 5: MODE 3 --content-file (Normal Path)"

# Create temporary test files
FIXTURE_DIR=$(mktemp -d /tmp/see433-fixtures.XXXXXX)

echo "Test content with [@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5) please check" > "$FIXTURE_DIR/with_mention.txt"
echo "Just a regular comment without any mention" > "$FIXTURE_DIR/no_mention.txt"

# G5.1: MODE 3 with mention → PASS
run_hook "{\"tool_input\":{\"command\":\"multica issue comment add issue-123 --content-file $FIXTURE_DIR/with_mention.txt\"}}"
assert_passthrough "G5.1 MODE 3 file with mention → passthrough"
assert_exit_0 "G5.1"

# G5.2: MODE 3 without mention → BLOCK (NO_MENTION)
run_hook "{\"tool_input\":{\"command\":\"multica issue comment add issue-123 --content-file $FIXTURE_DIR/no_mention.txt\"}}"
assert_blocked "G5.2 MODE 3 file no mention → BLOCKED"
assert_deny_text "G5.2"
assert_exit_0 "G5.2"

# G5.3: MODE 3 file not found → PASS (file read error = allow through)
run_hook '{"tool_input":{"command":"multica issue comment add issue-123 --content-file /nonexistent/path/file.txt"}}'
# When file cannot be read, the hook returns PASS (no content to check, allows through)
# This is NOT the same as content=null fallback — it's a file-read-error path
if [ -n "$HOOK_STDOUT" ] && ! echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
    pass "G5.3 MODE 3 file not found → passthrough (file read error)"
else
    # Could also be BLOCKED if the code treats missing file differently
    warn "G5.3 MODE 3 file not found → unexpected: '$HOOK_STDOUT'"
fi
assert_exit_0 "G5.3"

# Cleanup
rm -rf "$FIXTURE_DIR"

#####################################################################
# GROUP 6: Fallback content=null (FIX-2)
#####################################################################
separator "Group 6: Fallback content=null (FIX-2)"

# G6.1: No content mode matched at all → BLOCK
# Simulate a comment-add command with no recognizable content input mode
run_hook '{"tool_input":{"command":"multica issue comment add issue-123"}}'
assert_blocked "G6.1 Fallback no content mode → BLOCKED (was PASS before fix)"
assert_deny_text "G6.1"
assert_exit_0 "G6.1"

# G6.2: Content mode not recognized (garbage after --content)
run_hook '{"tool_input":{"command":"multica issue comment add issue-123 --unknown-flag value"}}'
assert_blocked "G6.2 Fallback unrecognized flags → BLOCKED"
assert_exit_0 "G6.2"

# G6.3: Verify FIX-2 does NOT affect non-comment commands
run_hook '{"tool_input":{"command":"multica issue list --output json"}}'
assert_passthrough "G6.3 Non-comment command → passthrough (unaffected)"
assert_no_warning "G6.3"
assert_exit_0 "G6.3"

#####################################################################
# GROUP 7: Regression — Core Functionality Preserved
#####################################################################
separator "Group 7: Regression — Core Functionality Preserved"

# G7.1: Chekky agent whitelist still works
run_hook '{"tool_input":{"command":"multica issue comment add issue-123 --content \"No mention from Chekky\""}}'
# Run as Chekky
TASK_ID="see433-test-${TEST_COUNTER}"
TEST_COUNTER=$((TEST_COUNTER + 1))
rm -f "/tmp/mention-check-${TASK_ID}"
echo '{"tool_input":{"command":"multica issue comment add issue-123 --content \"No mention from Chekky\""}}' | MULTICA_TASK_ID="$TASK_ID" MULTICA_AGENT_NAME="Chekky" bash "$HOOK_SCRIPT" > /tmp/hook-test-stdout 2>/tmp/hook-test-stderr
CHEKKY_EXIT=$?
CHEKKY_OUT=$(cat /tmp/hook-test-stdout)
rm -f /tmp/hook-test-stdout /tmp/hook-test-stderr

if [ "$CHEKKY_EXIT" -eq 0 ] && ! echo "$CHEKKY_OUT" | grep -q '"permissionDecision"'; then
    pass "G7.1 Chekky whitelist → passthrough"
else
    fail "G7.1 Chekky whitelist broken. stdout: '$CHEKKY_OUT'"
fi

# G7.2: Sentinel 语义对齐现行实现（SEE-1333 D2 逐条拦截）：PASS 哨兵写入
# mention-check-pass-<TASK>，但不再提供「带 mention 通过后无 mention 免检直通」
# fast-path——同 task 第二次无 mention 调用仍被 deny。
TASK_ID="see433-sentinel-test"
rm -f "/tmp/mention-check-pass-${TASK_ID}" "/tmp/mention-check-no-mention-${TASK_ID}"
# First call — mention-bearing content, creates PASS sentinel
echo '{"tool_input":{"command":"multica issue comment add issue-123 --content \"[@Atlas](mention://agent/fac3e3a1) test\""}}' | MULTICA_TASK_ID="$TASK_ID" bash "$HOOK_SCRIPT" > /dev/null 2>&1
if [ -f "/tmp/mention-check-pass-${TASK_ID}" ]; then
    pass "G7.2a PASS sentinel created after mention-bearing pass"
else
    fail "G7.2a PASS sentinel missing after mention-bearing pass"
fi
# Second call — no mention, same task: must STILL be denied (no fast-path bypass)
echo '{"tool_input":{"command":"multica issue comment add issue-123 --content \"No mention at all\""}}' | MULTICA_TASK_ID="$TASK_ID" bash "$HOOK_SCRIPT" > /tmp/hook-test-stdout 2>/tmp/hook-test-stderr
SENTINEL_EXIT=$?
SENTINEL_OUT=$(cat /tmp/hook-test-stdout)
rm -f /tmp/hook-test-stdout /tmp/hook-test-stderr "/tmp/mention-check-pass-${TASK_ID}" "/tmp/mention-check-no-mention-${TASK_ID}"

if [ "$SENTINEL_EXIT" -eq 0 ] && echo "$SENTINEL_OUT" | grep -q '"permissionDecision":"deny"'; then
    pass "G7.2 Sentinel no longer bypasses: second no-mention call still denied"
else
    fail "G7.2 expected deny on second no-mention call (SEE-1333 D2). stdout: '$SENTINEL_OUT'"
fi

# G7.3: Non-comment command passthrough
run_hook '{"tool_input":{"command":"git status"}}'
assert_passthrough "G7.3 Non-comment command → passthrough"
assert_exit_0 "G7.3"

# G7.4: Malformed JSON → graceful handling (exit 0, no crash)
MALFORMED_INPUT='{invalid json'
echo "$MALFORMED_INPUT" | bash "$HOOK_SCRIPT" > /tmp/hook-test-stdout 2>/tmp/hook-test-stderr
MALFORMED_EXIT=$?
rm -f /tmp/hook-test-stdout /tmp/hook-test-stderr

if [ "$MALFORMED_EXIT" -eq 0 ]; then
    pass "G7.4 Malformed JSON → exit 0 (no crash)"
else
    fail "G7.4 Malformed JSON → crashed with exit $MALFORMED_EXIT"
fi

#####################################################################
# GROUP 8: Edge Cases
#####################################################################
separator "Group 8: Edge Cases"

# G8.1: MODE 1 with escaped mention in content
run_hook '{"tool_input":{"command":"multica issue comment add issue-123 --content \"Report about [@Atlas](mention://agent/fac3e3a1) is done\""}}'
# This is a direct callout sentence → should PASS
assert_passthrough "G8.1 MODE 1 mention callout → passthrough"
assert_exit_0 "G8.1"

# G8.2: MODE 2 --content-stdin with pipe (not heredoc or here-string)
run_hook '{"tool_input":{"command":"cat report.txt | multica issue comment add issue-123 --content-stdin"}}'
assert_blocked "G8.2 MODE 2 piped stdin → BLOCKED"
assert_exit_0 "G8.2"

# G8.3: Mixed mode — --content overrides --content-stdin
run_hook '{"tool_input":{"command":"multica issue comment add issue-123 --content \"[@Atlas](mention://agent/fac3e3a1)\" --content-stdin"}}'
assert_passthrough "G8.3 MODE 1 takes priority over MODE 2 → passthrough"
assert_exit_0 "G8.3"

# G8.4: --content-stdin with --content-file — MODE 2 takes priority over MODE 3
run_hook '{"tool_input":{"command":"multica issue comment add issue-123 --content-stdin --content-file /tmp/test.txt"}}'
assert_blocked "G8.4 MODE 2 takes priority over MODE 3, no content extracted → BLOCKED"
assert_exit_0 "G8.4"

#####################################################################
# Summary
#####################################################################
separator "Summary"

echo ""
echo -e "${CYAN}Results:${NC}"
echo -e "  ${GREEN}Passed:${NC}    $PASS"
echo -e "  ${RED}Failed:${NC}    $FAIL"
echo -e "  ${YELLOW}Warnings:${NC}  $WARN"
echo ""
echo -e "  Total: $((PASS + FAIL + WARN)) tests"
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}Overall: PASS${NC}"
    echo ""
    echo "Fix verification:"
    echo "  FIX-1 (MODE 2 heredoc no body → NO_MENTION): VERIFIED"
    echo "  FIX-2 (Fallback content=null → NO_MENTION): VERIFIED"
else
    echo -e "${RED}Overall: FAIL${NC}"
    echo ""
    echo "Failed tests:"
    for r in "${RESULTS[@]}"; do
        if [[ "$r" == FAIL* ]]; then
            echo -e "  ${RED}x${NC} ${r#FAIL|}"
        fi
    done
fi

echo ""
echo "Baseline comparison:"
echo "  SEE-422 (test_mention_check_see422_qa.sh): expected 35/35"
echo "  SEE-405 (test_mention_check_see405_phase2_simplify.sh): expected ~34/49"
echo "  SEE-400 (test_mention_check_see400_json_escaping.sh): expected ~6/13"

exit $FAIL
