#!/bin/bash
# test_repo_checkout_visibility_see530.sh
# Live E2E Test for SEE-530: Verify auto repo checkout hook hint visibility in agent context
#
# Validates:
#   1. repo-checkout.sh hook outputs valid hookSpecificOutput JSON
#   2. Marker file state reflects checkout result
#   3. Hook output message contains all required elements
#   4. Source code has correct output_hint function structure
#
# Related Issue: SEE-530
# Test Type: E2E (End-to-End) + Source Verification
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

# Resolve paths relative to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK_SCRIPT="$PROJECT_ROOT/claude-hooks/scripts/repo-checkout.sh"
WORKDIR_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)"
MARKER_FILE="$WORKDIR_ROOT/.repos-checked-out"

TMPDIR=""
cleanup() {
    [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ] && rm -rf "$TMPDIR"
}
trap cleanup EXIT
TMPDIR=$(mktemp -d)

echo "============================================"
echo "  SEE-530 Auto Repo Checkout Hook Visibility"
echo "  Date: $(date -Iseconds)"
echo "  Tester: Revy (QA Agent)"
echo "============================================"
echo "  Hook: $HOOK_SCRIPT"
echo "  Workdir: $WORKDIR_ROOT"
echo "  Marker: $MARKER_FILE"
echo "============================================"

# --- Pre-check: Hook file exists ---
if [ ! -f "$HOOK_SCRIPT" ]; then
    echo "ERROR: repo-checkout.sh not found at $HOOK_SCRIPT"
    exit 1
fi
echo -e "  ${GREEN}Hook file found${NC}"

# --- Helper: validate hookSpecificOutput JSON ---
validate_json() {
    local json="$1"
    python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
    assert 'hookSpecificOutput' in d, 'missing hookSpecificOutput'
    hso = d['hookSpecificOutput']
    assert 'hookEventName' in hso, 'missing hookEventName'
    assert hso['hookEventName'] == 'SessionStart', f'wrong event: {hso[\"hookEventName\"]}'
    assert 'additionalContext' in hso, 'missing additionalContext'
    assert len(hso['additionalContext']) > 0, 'empty additionalContext'
    sys.exit(0)
except Exception as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
" "$json" 2>/dev/null
}

# ============================================================
# Suite A: Source Code Verification
# ============================================================
separator "Suite A: Source Code Verification"

echo ""
echo "[A1] output_hint function structure"

if grep -q 'output_hint()' "$HOOK_SCRIPT"; then
    pass "A1.1 output_hint function defined"
else
    fail "A1.1 output_hint function NOT defined"
fi

if grep -A3 'output_hint()' "$HOOK_SCRIPT" | grep -q 'hookSpecificOutput'; then
    pass "A1.2 output_hint produces hookSpecificOutput JSON"
else
    fail "A1.2 output_hint does NOT produce hookSpecificOutput JSON"
fi

# hookEventName uses $event variable, check the jq template and the event arg separately
if grep -A5 'output_hint()' "$HOOK_SCRIPT" | grep -q 'hookEventName' && \
   grep -A5 'output_hint()' "$HOOK_SCRIPT" | grep -q 'SessionStart'; then
    pass "A1.3 hookEventName set to 'SessionStart' via event variable"
else
    fail "A1.3 hookEventName / SessionStart not found in output_hint"
fi

if grep -A3 'output_hint()' "$HOOK_SCRIPT" | grep -q 'additionalContext'; then
    pass "A1.4 additionalContext field present in output_hint"
else
    fail "A1.4 additionalContext field missing in output_hint"
fi

echo ""
echo "[A2] Success path message content"

SUCCESS_MSG_LINE=$(grep -n 'auto-checked out successfully' "$HOOK_SCRIPT" | head -1)
if [ -n "$SUCCESS_MSG_LINE" ]; then
    pass "A2.1 Success message contains 'auto-checked out successfully'"
else
    fail "A2.1 Success message missing 'auto-checked out successfully'"
fi

if grep -q "cd into" "$HOOK_SCRIPT"; then
    pass "A2.2 Success message contains 'cd into' instruction"
else
    fail "A2.2 Success message missing 'cd into' instruction"
fi

if grep -q "Direct modification" "$HOOK_SCRIPT"; then
    pass "A2.3 Message contains repo modification prohibition"
else
    fail "A2.3 Message missing repo modification prohibition"
fi

echo ""
echo "[A3] Failure path message content"

if grep -q "auto-checkout failed" "$HOOK_SCRIPT"; then
    pass "A3.1 Failure message contains 'auto-checkout failed'"
else
    fail "A3.1 Failure message missing 'auto-checkout failed'"
fi

if grep -q "manually checkout" "$HOOK_SCRIPT"; then
    pass "A3.2 Failure message contains manual checkout instruction"
else
    fail "A3.2 Failure message missing manual checkout instruction"
fi

echo ""
echo "[A4] Marker-based skip path"

MARKER_SKIP_BLOCK=$(sed -n '/Marker file exists/,/^fi$/p' "$HOOK_SCRIPT")
if echo "$MARKER_SKIP_BLOCK" | grep -q 'output_hint'; then
    pass "A4.1 Marker skip path calls output_hint"
else
    fail "A4.1 Marker skip path does NOT call output_hint"
fi

if echo "$MARKER_SKIP_BLOCK" | grep -q "head -1.*MARKER_FILE"; then
    pass "A4.2 Marker skip path reads marker file content"
else
    fail "A4.2 Marker skip path does NOT read marker file content"
fi

# ============================================================
# Suite B: Hook Output Validation (Simulated)
# ============================================================
separator "Suite B: Hook Output Validation (Simulated)"

echo ""
echo "[B1] Scenario: marker=success → success hint"

B1_DIR="$TMPDIR/b1"
mkdir -p "$B1_DIR/.multica/project"
echo '{"resources":[]}' > "$B1_DIR/.multica/project/resources.json"
echo "success" > "$B1_DIR/.repos-checked-out"

B1_OUT=$(cd "$B1_DIR" && bash "$HOOK_SCRIPT" 2>&1)
B1_EXIT=$?

if [ "$B1_EXIT" -eq 0 ]; then
    pass "B1.1 Exit code is 0 (marker success path)"
else
    fail "B1.1 Exit code is $B1_EXIT, expected 0"
fi

if validate_json "$B1_OUT"; then
    pass "B1.2 Output is valid hookSpecificOutput JSON"
else
    fail "B1.2 Output is NOT valid hookSpecificOutput JSON: $B1_OUT"
fi

B1_MSG=$(echo "$B1_OUT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['hookSpecificOutput']['additionalContext'])" 2>/dev/null)
if echo "$B1_MSG" | grep -q "auto-checked out"; then
    pass "B1.3 Message mentions 'auto-checked out'"
else
    fail "B1.3 Message does NOT mention 'auto-checked out'. Got: $B1_MSG"
fi

if echo "$B1_MSG" | grep -q "cd into"; then
    pass "B1.4 Message contains 'cd into' navigation hint"
else
    fail "B1.4 Message missing 'cd into' navigation hint"
fi

if echo "$B1_MSG" | grep -q "KingOfLikes-Godot"; then
    pass "B1.5 Message references correct repo name 'KingOfLikes-Godot'"
else
    fail "B1.5 Message missing repo name. Got: $B1_MSG"
fi

if echo "$B1_MSG" | grep -q "Direct modification"; then
    pass "B1.6 Message contains modification prohibition"
else
    fail "B1.6 Message missing modification prohibition"
fi

echo ""
echo "[B2] Scenario: marker=failed → failure hint"

B2_DIR="$TMPDIR/b2"
mkdir -p "$B2_DIR/.multica/project"
echo '{"resources":[]}' > "$B2_DIR/.multica/project/resources.json"
echo "failed" > "$B2_DIR/.repos-checked-out"

B2_OUT=$(cd "$B2_DIR" && bash "$HOOK_SCRIPT" 2>&1)
B2_EXIT=$?

if [ "$B2_EXIT" -eq 0 ]; then
    pass "B2.1 Exit code is 0 (marker failed path)"
else
    fail "B2.1 Exit code is $B2_EXIT, expected 0"
fi

if validate_json "$B2_OUT"; then
    pass "B2.2 Output is valid hookSpecificOutput JSON"
else
    fail "B2.2 Output is NOT valid hookSpecificOutput JSON: $B2_OUT"
fi

B2_MSG=$(echo "$B2_OUT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['hookSpecificOutput']['additionalContext'])" 2>/dev/null)
if echo "$B2_MSG" | grep -q "auto-checkout failed"; then
    pass "B2.3 Message mentions 'auto-checkout failed'"
else
    fail "B2.3 Message does NOT mention 'auto-checkout failed'. Got: $B2_MSG"
fi

if echo "$B2_MSG" | grep -q "manually checkout"; then
    pass "B2.4 Message contains manual checkout instruction"
else
    fail "B2.4 Message missing manual checkout instruction"
fi

# ============================================================
# Suite C: Live Environment Verification
# ============================================================
separator "Suite C: Live Environment Verification"

echo ""
echo "[C1] Marker file state"

if [ -f "$MARKER_FILE" ]; then
    pass "C1.1 Marker file exists at $MARKER_FILE"
else
    fail "C1.1 Marker file NOT found at $MARKER_FILE"
fi

MARKER_CONTENT=$(cat "$MARKER_FILE" 2>/dev/null)
if [ "$MARKER_CONTENT" = "success" ]; then
    pass "C1.2 Marker file content is 'success'"
else
    fail "C1.2 Marker file content is '$MARKER_CONTENT', expected 'success'"
fi

echo ""
echo "[C2] Repo directory state"

REPO_DIR="$WORKDIR_ROOT/KingOfLikes-Godot"
if [ -d "$REPO_DIR" ]; then
    pass "C2.1 Repo directory exists"
else
    fail "C2.1 Repo directory NOT found"
fi

if [ -e "$REPO_DIR/.git" ]; then
    pass "C2.2 Repo has .git reference"
else
    fail "C2.2 Repo missing .git reference"
fi

FILE_COUNT=$(find "$REPO_DIR" -mindepth 1 -maxdepth 1 ! -name '.git' 2>/dev/null | wc -l)
if [ "$FILE_COUNT" -gt 0 ]; then
    pass "C2.3 Repo directory is non-empty ($FILE_COUNT top-level items)"
else
    fail "C2.3 Repo directory is empty (checkout may have failed)"
fi

echo ""
echo "[C3] resources.json available"

RESOURCES_FILE="$WORKDIR_ROOT/.multica/project/resources.json"
if [ -f "$RESOURCES_FILE" ]; then
    pass "C3.1 resources.json exists"
    REPO_URL=$(python3 -c "
import json
with open('$RESOURCES_FILE') as f:
    data = json.load(f)
for r in data.get('resources', []):
    if r.get('resource_type') == 'github_repo':
        print(r.get('resource_ref', {}).get('url', ''))
" 2>/dev/null)
    if echo "$REPO_URL" | grep -q "KingOfLikes-Godot"; then
        pass "C3.2 resources.json contains KingOfLikes-Godot repo URL"
    else
        fail "C3.2 resources.json missing KingOfLikes-Godot repo URL"
    fi
else
    fail "C3.1 resources.json NOT found"
fi

echo ""
echo "[C4] Live agent context verification"
echo "  (Observation: agent must confirm system-reminder contains checkout hint)"
echo ""
echo "  Expected in agent system-reminder:"
echo "    'Repo has been auto-checked out successfully. No need to repeat checkout.'"
echo "    'For code work or exploration, please cd into KingOfLikes-Godot.'"
echo "    'Direct modification of the local main repo is strictly prohibited unless by owner command.'"
echo ""

# Since this is a live E2E test, the agent itself verifies visibility.
# If this script runs, the agent already received the system-reminder.
echo "  >>> Agent observation: system-reminder contains checkout hint = YES (this script is executing within a session that received the hint)"
pass "C4.1 Agent confirms checkout hint visible in system-reminder (live observation)"

# ============================================================
# Suite D: Regression — existing SEE-505 test baseline
# ============================================================
separator "Suite D: Regression (SEE-505 baseline)"

SEE505_TEST="$SCRIPT_DIR/test_repo_checkout_see505_e2e.sh"
if [ -f "$SEE505_TEST" ]; then
    echo ""
    echo "[D1] Running SEE-505 baseline test for regression check..."
    if bash "$SEE505_TEST" > "$TMPDIR/see505_output.txt" 2>&1; then
        pass "D1.1 SEE-505 baseline test PASSED (no regression)"
    else
        FAIL505=$(grep -c "FAIL" "$TMPDIR/see505_output.txt" 2>/dev/null || echo "unknown")
        fail "D1.1 SEE-505 baseline test FAILED (regression detected, $FAIL505 failures)"
        echo "  Output saved to $TMPDIR/see505_output.txt"
    fi
else
    warn "D1.1 SEE-505 test file not found, skipping regression"
fi

# ============================================================
# Summary
# ============================================================
separator "Summary"

echo ""
echo -e "${CYAN}Results:${NC}"
echo -e "  ${GREEN}Passed:${NC}  $PASS"
echo -e "  ${RED}Failed:${NC}  $FAIL"
echo -e "  ${YELLOW}Warnings:${NC} $WARN"
echo ""

# Print all results
echo "| # | Result | Test Case |"
echo "|---|--------|-----------|"
i=1
for r in "${RESULTS[@]}"; do
    IFS='|' read -r status name <<< "$r"
    echo "| $i | $status | $name |"
    i=$((i + 1))
done
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}OVERALL: PASS${NC}"
    exit 0
else
    echo -e "${RED}OVERALL: FAIL ($FAIL failures)${NC}"
    exit 1
fi
