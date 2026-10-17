#!/bin/bash
# QA Test Script for SEE-747: child-issue-guard rule via unified pre-comment-skill-check engine
# Tests: block child issue creation, allow normal issue creation, bypass protection
#
# Related Issue: SEE-747
# Migration: SEE-764 — migrated from standalone child-issue-guard.sh to unified engine
# Migration: SEE-1330 — testee redirected to v2 unified engine (.claude/hooks/unified/unified-hook.sh)
#             with UNIFIED_RULES_FILE=rules-v2.json; deny → permissionDecision=deny +
#             reason prefix '[unified-hook] '; hook_event_name injected at run_hook (D5 equivalent).
# v1↔v2 note: fixture-side config dropped — rule sourced from rules-v2.json (v2 when-op shape).
# Test Type: Unit + Boundary + E2E + Regression
# Author: Revy (QA Agent)

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
HOOK_SCRIPT="$PROJECT_ROOT/hooks/unified/unified-hook.sh"
RULES_FILE="$PROJECT_ROOT/hooks/unified/rules-v2.json"

# --- Test infrastructure (SEE-764 unified engine → SEE-1330 v2 redirect) ---

TEST_RUN_ID="see747-$(date +%s)-$$"
TEST_BASE="/tmp/$TEST_RUN_ID"
mkdir -p "$TEST_BASE"

SESSION_COUNTER=0
TASK_COUNTER=0

setup_fixture() {
    local rules_json="${1:-}"   # retained for call-site compatibility; v2 config is external

    SESSION_COUNTER=$((SESSION_COUNTER + 1))
    FIX_SESSION="see747-session-$SESSION_COUNTER-$$"
    TASK_COUNTER=$((TASK_COUNTER + 1))
    FIX_TASK="see747-task-$TASK_COUNTER-$$"

    # v2: rule 语句走 rules-v2.json（UNIFIED_RULES_FILE），fixture 仅负责生成
    # 每 run 唯一的 scope/task id，保证 one_shot sentinel 互不串扰。
}

run_hook() {
    local INPUT="$1"
    local STDOUT_FILE=$(mktemp /tmp/see747-stdout.XXXXXX)
    local STDERR_FILE=$(mktemp /tmp/see747-stderr.XXXXXX)

    # hook_event_name 注入（v1 D5 等价）：含 tool_response → PostToolUse，否则 PreToolUse
    local EV="PreToolUse"
    [[ "$INPUT" == *'"tool_response"'* ]] && EV="PostToolUse"
    local PAYLOAD
    PAYLOAD=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
d.setdefault('hook_event_name', '$EV')
print(json.dumps(d))")

    printf '%s' "$PAYLOAD" | \
        env PWD="$PROJECT_ROOT" \
            PROJECT_ROOT="$PROJECT_ROOT" \
            UNIFIED_RULES_FILE="$RULES_FILE" \
            MULTICA_AGENT_NAME="TestAgent" \
            MULTICA_TASK_ID="$FIX_TASK" \
            HOOK_SCOPE_ID="$FIX_TASK" \
            CLAUDE_CODE_SESSION_ID="$FIX_SESSION" \
            bash "$HOOK_SCRIPT" \
            > "$STDOUT_FILE" 2> "$STDERR_FILE"

    HOOK_EXIT=$?
    HOOK_STDOUT=$(cat "$STDOUT_FILE")
    HOOK_STDERR=$(cat "$STDERR_FILE")

    rm -f "$STDOUT_FILE" "$STDERR_FILE"
}

assert_blocks() {
    local label="$1"
    local expected_msg="${2:-}"
    if echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
        if echo "$HOOK_STDOUT" | grep -q '"deny"'; then
            # v2: deny reason 必以 '[unified-hook] ' 前缀
            if ! echo "$HOOK_STDOUT" | grep -qF '[unified-hook] '; then
                fail "$label — BLOCKED but missing '[unified-hook] ' reason prefix. stdout: '${HOOK_STDOUT:0:300}'"
            elif [ -n "$expected_msg" ] && ! echo "$HOOK_STDOUT" | grep -qF "$expected_msg"; then
                fail "$label — BLOCKED but message missing '$expected_msg'. stdout: '${HOOK_STDOUT:0:300}'"
            else
                pass "$label — BLOCKED (permissionDecision=deny)"
            fi
        else
            fail "$label — permissionDecision not 'deny'. stdout: '${HOOK_STDOUT:0:300}'"
        fi
    else
        fail "$label — NOT blocked. stdout: '${HOOK_STDOUT:0:300}'"
    fi
}

assert_allows() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
        fail "$label — incorrectly BLOCKED. stdout: '${HOOK_STDOUT:0:300}'"
    else
        pass "$label — ALLOWED"
    fi
}

assert_exit_0() {
    local label="$1"
    if [ "$HOOK_EXIT" -eq 0 ]; then
        pass "$label — exit code 0"
    else
        fail "$label — exit code $HOOK_EXIT, expected 0"
    fi
}

echo "================================================================"
echo "  SEE-747 QA: child-issue-guard (unified engine)"
echo "  Date: $(date -Iseconds)"
echo "  Hook: $HOOK_SCRIPT"
echo "  Branch: $(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo 'unknown')"
echo "================================================================"

#####################################################################
# Prerequisite
#####################################################################
separator "Prerequisite"

if [ -f "$HOOK_SCRIPT" ]; then
    pass "V2 unified engine hook file exists"
else
    fail "Hook file MISSING at $HOOK_SCRIPT"
    exit 1
fi

if [ -f "$RULES_FILE" ]; then
    pass "rules-v2.json exists"
else
    fail "rules-v2.json MISSING at $RULES_FILE"
    exit 1
fi

if grep -q '"has_flag"' "$RULES_FILE" && grep -q '"flag_has_value"' "$RULES_FILE"; then
    pass "v2 config supports has_flag/flag_has_value command constraints"
else
    fail "v2 config missing has_flag/flag_has_value operators"
fi

if grep -q "child-issue-guard" "$RULES_FILE"; then
    pass "child-issue-guard rule exists in rules-v2.json"
else
    fail "child-issue-guard rule missing from rules-v2.json"
fi

if grep -q "严禁创建任何子 issue" "$RULES_FILE"; then
    pass "Chinese block message present in config"
else
    fail "Chinese block message missing from config"
fi

BLOCK_MSG_FRAGMENT="严禁创建任何子 issue"

#####################################################################
# GROUP 1: BLOCK — multica issue create --parent <non-empty>
#####################################################################
separator "G1: BLOCK — issue create with --parent <non-empty>"

setup_fixture
run_hook '{"tool_input":{"command":"multica issue create --parent abc123 --title \"test\""}}'
assert_blocks "G1a: create --parent abc123" "$BLOCK_MSG_FRAGMENT"
assert_exit_0 "G1a: create --parent abc123"

setup_fixture
run_hook '{"tool_input":{"command":"multica issue create --parent=abc123 --title \"test\""}}'
assert_blocks "G1b: create --parent=abc123" "$BLOCK_MSG_FRAGMENT"
assert_exit_0 "G1b: create --parent=abc123"

setup_fixture
run_hook '{"tool_input":{"command":"multica issue create --title \"test\" --parent abc123"}}'
assert_blocks "G1c: create --title then --parent" "$BLOCK_MSG_FRAGMENT"
assert_exit_0 "G1c: create --title then --parent"

setup_fixture
run_hook '{"tool_input":{"command":"multica issue create --parent 23bee88a-76b7-4aad-97cb-a829f093e6f0 --title \"[SEE-736] Phase 1\" --priority high --status todo --assignee-id abc --project f0db1de0"}}'
assert_blocks "G1d: create full Atlas-style command" "$BLOCK_MSG_FRAGMENT"
assert_exit_0 "G1d: create full Atlas-style command"

setup_fixture
run_hook '{"tool_input":{"command":"multica issue create --parent '\''abc123'\'' --title \"test\""}}'
assert_blocks "G1e: create --parent with single-quoted value" "$BLOCK_MSG_FRAGMENT"
assert_exit_0 "G1e: create --parent with single-quoted value"

#####################################################################
# GROUP 2: BLOCK — multica issue update <id> --parent <non-empty>
#####################################################################
separator "G2: BLOCK — issue update with --parent <non-empty>"

setup_fixture
run_hook '{"tool_input":{"command":"multica issue update 420c414c --parent abc123"}}'
assert_blocks "G2a: update --parent abc123" "$BLOCK_MSG_FRAGMENT"
assert_exit_0 "G2a: update --parent abc123"

setup_fixture
run_hook '{"tool_input":{"command":"multica issue update 420c414c --parent=abc123"}}'
assert_blocks "G2b: update --parent=abc123" "$BLOCK_MSG_FRAGMENT"
assert_exit_0 "G2b: update --parent=abc123"

setup_fixture
run_hook '{"tool_input":{"command":"multica issue update 420c414c --title \"new title\" --parent abc123"}}'
assert_blocks "G2c: update with title and parent" "$BLOCK_MSG_FRAGMENT"
assert_exit_0 "G2c: update with title and parent"

#####################################################################
# GROUP 3: BLOCK — Nested commands (bash -c / sh -c)
#####################################################################
separator "G3: BLOCK — Nested commands"

setup_fixture
run_hook '{"tool_input":{"command":"bash -c \"multica issue create --parent abc123 --title test\""}}'
assert_blocks "G3a: bash -c nested create" "$BLOCK_MSG_FRAGMENT"
assert_exit_0 "G3a: bash -c nested create"

setup_fixture
run_hook '{"tool_input":{"command":"sh -c \"multica issue update id --parent abc123\""}}'
assert_blocks "G3b: sh -c nested update" "$BLOCK_MSG_FRAGMENT"
assert_exit_0 "G3b: sh -c nested update"

# G3c: bash -c with single-quoted --parent argument
G3C_INPUT=$(cat <<'G3C_HEREDOC'
{"tool_input":{"command":"bash -c 'multica issue create --parent=abc123'"}}
G3C_HEREDOC
)
setup_fixture
run_hook "$G3C_INPUT"
assert_blocks "G3c: bash -c single-quoted nested" "$BLOCK_MSG_FRAGMENT"
assert_exit_0 "G3c: bash -c single-quoted nested"

#####################################################################
# GROUP 4: BLOCK — heredoc piped to multica
#####################################################################
separator "G4: BLOCK — heredoc piped commands"

# Atlas-style heredoc pattern
setup_fixture
run_hook '{"tool_input":{"command":"cat <<DESCRIPTION | multica issue create --title \"[SEE-736] Phase X\" --description-stdin --priority high --parent 23bee88a-76b7-4aad-97cb-a829f093e6f0 --project f0db1de0\nDESCRIPTION"}}'
assert_blocks "G4a: heredoc piped create with --parent" "$BLOCK_MSG_FRAGMENT"
assert_exit_0 "G4a: heredoc piped create with --parent"

#####################################################################
# GROUP 5: ALLOW — Normal issue creation (no --parent)
#####################################################################
separator "G5: ALLOW — Normal issue creation"

setup_fixture
run_hook '{"tool_input":{"command":"multica issue create --title \"normal issue\""}}'
assert_allows "G5a: create without --parent"
assert_exit_0 "G5a: create without --parent"

setup_fixture
run_hook '{"tool_input":{"command":"multica issue create --title \"test\" --priority high --status todo"}}'
assert_allows "G5b: create with multiple flags, no parent"
assert_exit_0 "G5b: create with multiple flags, no parent"

setup_fixture
run_hook '{"tool_input":{"command":"multica issue create --description \"some desc\""}}'
assert_allows "G5c: create with description only"
assert_exit_0 "G5c: create with description only"

#####################################################################
# GROUP 6: ALLOW — Empty --parent (clearing parent)
#####################################################################
separator "G6: ALLOW — Empty --parent"

setup_fixture
run_hook '{"tool_input":{"command":"multica issue create --parent \"\" --title \"test\""}}'
assert_allows "G6a: create --parent empty string"
assert_exit_0 "G6a: create --parent empty string"

setup_fixture
run_hook '{"tool_input":{"command":"multica issue create --parent=\"\" --title \"test\""}}'
assert_allows "G6b: create --parent= empty string"
assert_exit_0 "G6b: create --parent= empty string"

setup_fixture
run_hook '{"tool_input":{"command":"multica issue update id --parent \"\""}}'
assert_allows "G6c: update --parent empty string (clear parent)"
assert_exit_0 "G6c: update --parent empty string"

setup_fixture
run_hook '{"tool_input":{"command":"multica issue update id --parent=\"\""}}'
assert_allows "G6d: update --parent= empty string"
assert_exit_0 "G6d: update --parent= empty string"

#####################################################################
# GROUP 7: ALLOW — False positive protection (--parent in values)
#####################################################################
separator "G7: ALLOW — False positive protection"

setup_fixture
run_hook '{"tool_input":{"command":"multica issue create --title \"foo --parent\""}}'
assert_allows "G7a: --parent inside --title value"
assert_exit_0 "G7a: --parent inside --title value"

setup_fixture
run_hook '{"tool_input":{"command":"multica issue create --title \"how to use --parent flag\""}}'
assert_allows "G7b: --parent inside longer title value"
assert_exit_0 "G7b: --parent inside longer title value"

setup_fixture
run_hook '{"tool_input":{"command":"multica issue create --description \"the --parent option\""}}'
assert_allows "G7c: --parent inside --description value"
assert_exit_0 "G7c: --parent inside --description value"

#####################################################################
# GROUP 8: ALLOW — Non-multica commands
#####################################################################
separator "G8: ALLOW — Non-multica commands"

setup_fixture
run_hook '{"tool_input":{"command":"git push origin main"}}'
assert_allows "G8a: git push"
assert_exit_0 "G8a: git push"

setup_fixture
run_hook '{"tool_input":{"command":"ls -la"}}'
assert_allows "G8b: ls"
assert_exit_0 "G8b: ls"

setup_fixture
run_hook '{"tool_input":{"command":"echo \"hello world\""}}'
assert_allows "G8c: echo"
assert_exit_0 "G8c: echo"

setup_fixture
run_hook '{"tool_input":{"command":"node -e \"console.log(1)\""}}'
assert_allows "G8d: node command"
assert_exit_0 "G8d: node command"

#####################################################################
# GROUP 9: ALLOW — multica commands that are NOT create/update
#####################################################################
separator "G9: ALLOW — Other multica issue subcommands"

setup_fixture
run_hook '{"tool_input":{"command":"multica issue get 420c414c"}}'
assert_allows "G9a: issue get"
assert_exit_0 "G9a: issue get"

setup_fixture
run_hook '{"tool_input":{"command":"multica issue comment add 420c414c --content \"hello\""}}'
assert_allows "G9b: issue comment add"
assert_exit_0 "G9b: issue comment add"

setup_fixture
run_hook '{"tool_input":{"command":"multica issue list --status open"}}'
assert_allows "G9c: issue list"
assert_exit_0 "G9c: issue list"

setup_fixture
run_hook '{"tool_input":{"command":"multica issue update 420c414c --title \"new title\""}}'
assert_allows "G9d: issue update without --parent"
assert_exit_0 "G9d: issue update without --parent"

#####################################################################
# GROUP 10: ALLOW — heredoc content with --parent text (not flag)
#####################################################################
separator "G10: ALLOW — heredoc content false positive"

setup_fixture
run_hook '{"tool_input":{"command":"cat <<EOF | multica issue create --title \"test\" --description-stdin\nThis doc explains --parent usage.\nEOF"}}'
assert_allows "G10a: heredoc body contains --parent text"
assert_exit_0 "G10a: heredoc body contains --parent text"

#####################################################################
# GROUP 11: Regression — Output format and error handling
#####################################################################
separator "G11: Regression Tests"

# G11a: Block produces hookSpecificOutput with permissionDecision=deny
setup_fixture
run_hook '{"tool_input":{"command":"multica issue create --parent abc123"}}'
if echo "$HOOK_STDOUT" | grep -q '"hookSpecificOutput"'; then
    pass "G11a: hookSpecificOutput JSON present on block"
else
    fail "G11a: hookSpecificOutput missing. stdout: '$HOOK_STDOUT'"
fi
if echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
    pass "G11a: permissionDecision=deny present"
else
    fail "G11a: permissionDecision=deny missing"
fi
if echo "$HOOK_STDOUT" | grep -qF "$BLOCK_MSG_FRAGMENT"; then
    pass "G11a: Chinese block message present"
else
    fail "G11a: Chinese block message missing"
fi

# G11b: Malformed JSON → passthrough
setup_fixture
run_hook '{not valid json}'
assert_allows "G11b: malformed JSON"
assert_exit_0 "G11b: malformed JSON"

# G11c: Empty tool_input.command → passthrough
setup_fixture
run_hook '{"tool_input":{"command":""}}'
assert_allows "G11c: empty command"
assert_exit_0 "G11c: empty command"

# G11d: Missing tool_input → passthrough
setup_fixture
run_hook '{"other_field":"value"}'
assert_allows "G11d: missing tool_input"
assert_exit_0 "G11d: missing tool_input"

#####################################################################
# GROUP 12: Edge Cases
#####################################################################
separator "G12: Edge Cases"

# G12a: --parent at end with no value (should not crash)
setup_fixture
run_hook '{"tool_input":{"command":"multica issue create --title \"test\" --parent"}}'
assert_allows "G12a: --parent at end with no value"
assert_exit_0 "G12a: --parent at end with no value"

# G12b: Multiple spaces between tokens
setup_fixture
run_hook '{"tool_input":{"command":"multica   issue   create   --parent   abc123"}}'
assert_blocks "G12b: multiple spaces between tokens" "$BLOCK_MSG_FRAGMENT"
assert_exit_0 "G12b: multiple spaces between tokens"

# G12c: Tab-separated tokens
setup_fixture
run_hook '{"tool_input":{"command":"multica\tissue\tcreate\t--parent\tabc123"}}'
assert_blocks "G12c: tab-separated tokens" "$BLOCK_MSG_FRAGMENT"
assert_exit_0 "G12c: tab-separated tokens"

# G12d: --parent before subcommand (not create|update at expected position)
setup_fixture
run_hook '{"tool_input":{"command":"multica issue --parent abc123 create"}}'
assert_allows "G12d: --parent before subcommand"
assert_exit_0 "G12d: --parent before subcommand"

# G12e: Whitespace-only parent value
setup_fixture
run_hook '{"tool_input":{"command":"multica issue create --parent \"   \""}}'
assert_allows "G12e: whitespace-only parent value treated as empty"
assert_exit_0 "G12e: whitespace-only parent value treated as empty"

# G12f: Mixed nested command with real outer command
setup_fixture
run_hook '{"tool_input":{"command":"echo hello && bash -c \"multica issue create --parent abc123\""}}'
assert_blocks "G12f: nested command in compound statement" "$BLOCK_MSG_FRAGMENT"
assert_exit_0 "G12f: nested command in compound statement"

# G12g: Parent value with hyphens (UUID-like)
setup_fixture
run_hook '{"tool_input":{"command":"multica issue create --parent 23bee88a-76b7-4aad-97cb-a829f093e6f0"}}'
assert_blocks "G12g: UUID-like parent value" "$BLOCK_MSG_FRAGMENT"
assert_exit_0 "G12g: UUID-like parent value"

# G12h: Update with description and parent
setup_fixture
run_hook '{"tool_input":{"command":"multica issue update 420c414c --description \"updated\" --parent abc123"}}'
assert_blocks "G12h: update with description and parent" "$BLOCK_MSG_FRAGMENT"
assert_exit_0 "G12h: update with description and parent"

# G12i: multica at different position (should not match)
setup_fixture
run_hook '{"tool_input":{"command":"echo multica issue create --parent abc123"}}'
assert_allows "G12i: multica not at start"
assert_exit_0 "G12i: multica not at start"

#####################################################################
# CLEANUP
#####################################################################
separator "Cleanup"
rm -rf "$TEST_BASE"
rm -f /tmp/see747-stdout.* /tmp/see747-stderr.*
rm -f /tmp/skill-check-* /tmp/.hook-fired-* 2>/dev/null

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
