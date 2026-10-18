#!/bin/bash
# test_see300_hook_visibility.sh
# QA Test Script for SEE-300: Hook Agent Visibility Fix
#
# SEE-954 rewrote the branch-sync model and DELETED rebase-before-work.sh
# (per-tool-call rebase is replaced by repo-checkout.sh's SessionStart §B
# auto-rebase). This test therefore no longer asserts rebase-before-work.sh
# hookSpecificOutput behavior; the visibility checks for gdformat-gdlint.sh
# are retained unchanged because that hook was not touched by SEE-954.

set -uo pipefail

# Colors
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

# Resolve paths dynamically (avoid stale agent-specific workdir paths).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."
HOOKS_DIR="$PROJECT_ROOT/claude-hooks"
TEST_TMP="$PROJECT_ROOT/tests/_fixtures/see300"
GDFORMAT_HOOK="$HOOKS_DIR/scripts/gdformat-gdlint.sh"

echo "============================================"
echo "  SEE-300 Hook Agent Visibility E2E Test"
echo "  Date: $(date -Iseconds)"
echo "  Tester: Revy (QA Agent)"
echo "============================================"

# Ensure hook exists
if [ ! -f "$GDFORMAT_HOOK" ]; then
    echo "ERROR: gdformat-gdlint.sh not found at $GDFORMAT_HOOK"
    exit 1
fi

# Clean up test temp
rm -rf "$TEST_TMP"
mkdir -p "$TEST_TMP"

separator "Test Suite A: rebase-before-work.sh (INTENTIONALLY REMOVED by SEE-954)"

echo ""
echo "[A1] rebase-before-work.sh is no longer present"
if [ ! -f "$HOOKS_DIR/rebase-before-work.sh" ]; then
    pass "A1.1 rebase-before-work.sh deleted (SEE-954)"
else
    fail "A1.1 rebase-before-work.sh still exists (expected deletion)"
fi

echo ""
echo "[A2] Legacy .cc-rebase-* marker no longer written by any hook"
if grep -rF '.cc-rebase-' "$HOOKS_DIR"/*.sh 2>/dev/null | grep -q "touch"; then
    fail "A2.1 found a .cc-rebase- marker writer (should be .cc-aligned-)"
else
    pass "A2.1 no .cc-rebase- marker writer in project hooks"
fi

separator "Test Suite B: gdformat-gdlint.sh"

echo ""
echo "[B1] gdformat failure path: badly formatted .gd → exit 2 + stderr"

BAD_FORMAT_GD="$TEST_TMP/bad_format.gd"
cat > "$BAD_FORMAT_GD" << 'GDCODE'
# Badly formatted GDScript - inconsistent indentation and spacing
class_name BadFormat
extends Node

func _ready():
var x=1+2
   var y   =   3
     if x>0:
      print("hello")
GDCODE

HOOK_STDOUT3=$(mktemp)
HOOK_STDERR3=$(mktemp)
echo '{"tool_input":{"file_path":"'$BAD_FORMAT_GD'"}}' | bash "$GDFORMAT_HOOK" > "$HOOK_STDOUT3" 2> "$HOOK_STDERR3"
EXIT_CODE3=$?

if [ "$EXIT_CODE3" -eq 2 ]; then
    pass "B1.1 Exit code is 2 on gdformat failure"
else
    fail "B1.1 Exit code is $EXIT_CODE3, expected 2 on gdformat failure"
fi

STDERR3=$(cat "$HOOK_STDERR3")
if echo "$STDERR3" | grep -q '\[gdformat\] Formatting failed'; then
    pass "B1.2 stderr contains '[gdformat] Formatting failed'"
else
    fail "B1.2 stderr missing '[gdformat] Formatting failed'. Got: $STDERR3"
fi

echo ""
echo "[B2] gdlint failure path: lint-error .gd → exit 2 + stderr"

BAD_LINT_GD="$TEST_TMP/bad_lint.gd"
cat > "$BAD_LINT_GD" << 'GDCODE'
class_name BadLint
extends Node

# This function has bad naming (snake_case required) and unused variable
func BadFunctionName():
    var unused_var = 42
    pass
GDCODE

# First format it so gdformat passes
gdformat "$BAD_LINT_GD" 2>/dev/null || true

HOOK_STDOUT4=$(mktemp)
HOOK_STDERR4=$(mktemp)
echo '{"tool_input":{"file_path":"'$BAD_LINT_GD'"}}' | bash "$GDFORMAT_HOOK" > "$HOOK_STDOUT4" 2> "$HOOK_STDERR4"
EXIT_CODE4=$?

if [ "$EXIT_CODE4" -eq 2 ]; then
    pass "B2.1 Exit code is 2 on gdlint failure"
else
    fail "B2.1 Exit code is $EXIT_CODE4, expected 2 on gdlint failure"
fi

STDERR4=$(cat "$HOOK_STDERR4")
if echo "$STDERR4" | grep -q '\[gdlint\] Lint issues found'; then
    pass "B2.2 stderr contains '[gdlint] Lint issues found'"
else
    fail "B2.2 stderr missing '[gdlint] Lint issues found'. Got: $STDERR4"
fi

echo ""
echo "[B3] Success path: valid .gd → exit 0"

GOOD_GD="$TEST_TMP/good_format.gd"
cat > "$GOOD_GD" << 'GDCODE'
class_name GoodFormat
extends Node


func _ready():
    var x = 1 + 2
    if x > 0:
        print("hello")
GDCODE

HOOK_STDOUT5=$(mktemp)
HOOK_STDERR5=$(mktemp)
echo '{"tool_input":{"file_path":"'$GOOD_GD'"}}' | bash "$GDFORMAT_HOOK" > "$HOOK_STDOUT5" 2> "$HOOK_STDERR5"
EXIT_CODE5=$?

if [ "$EXIT_CODE5" -eq 0 ]; then
    pass "B3.1 Exit code is 0 on valid .gd file"
else
    fail "B3.1 Exit code is $EXIT_CODE5, expected 0 on valid .gd file"
fi

separator "Test Suite C: Source Code Verification"

echo ""
echo "[C1] gdformat-gdlint.sh: verify gdformat failure has exit 2"

GDFORMAT_BLOCK=$(sed -n '/^gdformat /,/^}$/p' "$GDFORMAT_HOOK")
if echo "$GDFORMAT_BLOCK" | grep -q 'exit 2'; then
    pass "C1.1 gdformat failure block contains 'exit 2'"
else
    fail "C1.1 gdformat failure block missing 'exit 2'"
fi

# Cleanup test temp directory
rm -rf "$TEST_TMP"

separator "Summary"

echo ""
echo -e "${CYAN}Results:${NC}"
echo -e "  ${GREEN}Passed:${NC}  $PASS"
echo -e "  ${RED}Failed:${NC}  $FAIL"
echo -e "  ${YELLOW}Warnings:${NC} $WARN"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}OVERALL: PASS${NC}"
    exit 0
else
    echo -e "${RED}OVERALL: FAIL${NC}"
    exit 1
fi
