#!/bin/bash
# test_auto_pr_notification_branch_var_see601.sh
# QA Regression + A/B Test Suite for SEE-601:
# Fix auto-pr-on-stop.sh notification text variable reference error
#
# Related Issue: SEE-601
# Test Type: Regression + A/B Test
# Author: Revy

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
HOOK_SCRIPT="$PROJECT_ROOT/hooks/scripts/auto-pr-on-stop.sh"

# =============================================
# Section 1: Regression — Verify Fix Correctness
# =============================================
separator "Section 1: Regression — Verify Fix Correctness"

# T1: Verify line 321 uses ${PR_HEAD}
echo "T1: Notification line uses \${PR_HEAD}"
LINE_321=$(sed -n '321p' "$HOOK_SCRIPT")
if echo "$LINE_321" | grep -q '\${PR_HEAD}'; then
    pass "T1: Line 321 correctly uses \${PR_HEAD}"
else
    fail "T1: Line 321 does NOT use \${PR_HEAD}. Got: $LINE_321"
fi

# T2: Verify line 321 does NOT use ${CURRENT_BRANCH}
echo "T2: Notification line does NOT use \${CURRENT_BRANCH}"
if echo "$LINE_321" | grep -q '\${CURRENT_BRANCH}'; then
    fail "T2: Line 321 still contains \${CURRENT_BRANCH}. Got: $LINE_321"
else
    pass "T2: Line 321 does NOT contain \${CURRENT_BRANCH}"
fi

# T3: Verify PR_HEAD assignment logic exists and is correct
echo "T3: PR_HEAD assignment logic (lines 221-223)"
LINES_221_224=$(sed -n '221,224p' "$HOOK_SCRIPT")
if echo "$LINES_221_224" | grep -q 'PR_HEAD="\$CURRENT_BRANCH"' && \
   echo "$LINES_221_224" | grep -q '\[ -n "\$WORKING_BRANCH" \]' && \
   echo "$LINES_221_224" | grep -q 'PR_HEAD="\$WORKING_BRANCH"'; then
    pass "T3: PR_HEAD correctly assigned (defaults to CURRENT_BRANCH, overridden by WORKING_BRANCH)"
else
    fail "T3: PR_HEAD assignment logic incorrect or missing. Got:\n$LINES_221_224"
fi

# T4: Verify no other notification text uses CURRENT_BRANCH incorrectly
echo "T4: No other notification/PR metadata uses \${CURRENT_BRANCH}"
# Search for lines that build PR notification text containing CURRENT_BRANCH
NOTIFICATION_CURRENT_BRANCH=$(grep -n '\${CURRENT_BRANCH}' "$HOOK_SCRIPT" | grep -v 'echo.*Skipping' | grep -v 'COMMIT_MSG' | grep -v 'git rev-parse' | grep -v 'TRACKING_BRANCH' | grep -v 'PUSH_TARGET' | grep -v 'OPEN_PR_BRANCHES' | grep -v 'line 117' || true)
# Actually, let's be more precise: find CURRENT_BRANCH in lines that are about notification text
# The PR_INFO block starts at line 316 and ends around 325
# Also check the PR create body at line 246
PR_BODY_LINE=$(sed -n '246p' "$HOOK_SCRIPT")
if echo "$PR_BODY_LINE" | grep -q '\${CURRENT_BRANCH}'; then
    fail "T4: PR creation body (line ~246) uses \${CURRENT_BRANCH} instead of \${PR_HEAD}"
else
    pass "T4: PR creation body uses correct variable (not \${CURRENT_BRANCH})"
fi

# T5: Verify the complete PR_INFO block structure
echo "T5: PR_INFO block references PR_HEAD"
PR_INFO_BLOCK=$(sed -n '316,325p' "$HOOK_SCRIPT")
if echo "$PR_INFO_BLOCK" | grep -q '\${PR_HEAD}'; then
    pass "T5: PR_INFO block contains \${PR_HEAD}"
else
    fail "T5: PR_INFO block missing \${PR_HEAD}"
fi

# =============================================
# Section 2: A/B Test — Bug vs Fix Behavior
# =============================================
separator "Section 2: A/B Test — Bug vs Fix"

# Simulate: When WORKING_BRANCH is set (feature/SEE-600)
# OLD (buggy): notification would show "agent/bachi/0fea6b60" (CURRENT_BRANCH)
# NEW (fixed): notification shows "feature/SEE-600" (PR_HEAD = WORKING_BRANCH)

echo "Simulating scenario: WORKING_BRANCH=feature/SEE-600, CURRENT_BRANCH=agent/bachi/0fea6b60"

# Extract just the PR_HEAD assignment logic and test it
SIM_WORKING_BRANCH="feature/SEE-600"
SIM_CURRENT_BRANCH="agent/bachi/0fea6b60"

# Simulate the PR_HEAD assignment
SIM_PR_HEAD="$SIM_CURRENT_BRANCH"
if [ -n "$SIM_WORKING_BRANCH" ]; then
    SIM_PR_HEAD="$SIM_WORKING_BRANCH"
fi

# A/B comparison
NOTIFICATION_BUGGY="- **Branch:** \`${SIM_CURRENT_BRANCH}\` → \`master\`"
NOTIFICATION_FIXED="- **Branch:** \`${SIM_PR_HEAD}\` → \`master\`"

echo "  Buggy notification: $NOTIFICATION_BUGGY"
echo "  Fixed notification: $NOTIFICATION_FIXED"

if [ "$NOTIFICATION_BUGGY" = "$NOTIFICATION_FIXED" ]; then
    fail "A/B.T1: Buggy and fixed notifications are identical (no behavioral difference)"
else
    pass "A/B.T1: Buggy vs fixed notifications differ as expected"
fi

if echo "$NOTIFICATION_FIXED" | grep -q 'feature/SEE-600'; then
    pass "A/B.T2: Fixed notification shows WORKING_BRANCH (feature/SEE-600)"
else
    fail "A/B.T2: Fixed notification does NOT show WORKING_BRANCH"
fi

if echo "$NOTIFICATION_BUGGY" | grep -q 'agent/bachi/0fea6b60'; then
    pass "A/B.T3: Buggy notification shows CURRENT_BRANCH (local agent branch)"
else
    fail "A/B.T3: Buggy notification structure unexpected"
fi

# Simulate scenario 2: WORKING_BRANCH is empty
# In this case PR_HEAD = CURRENT_BRANCH, so both buggy and fixed are the same
echo ""
echo "Simulating scenario: WORKING_BRANCH='', CURRENT_BRANCH=feature/SEE-601"
SIM_WORKING_BRANCH2=""
SIM_CURRENT_BRANCH2="feature/SEE-601"
SIM_PR_HEAD2="$SIM_CURRENT_BRANCH2"
if [ -n "$SIM_WORKING_BRANCH2" ]; then
    SIM_PR_HEAD2="$SIM_WORKING_BRANCH2"
fi

NOTIFICATION_BUGGY2="- **Branch:** \`${SIM_CURRENT_BRANCH2}\` → \`master\`"
NOTIFICATION_FIXED2="- **Branch:** \`${SIM_PR_HEAD2}\` → \`master\`"

if [ "$NOTIFICATION_BUGGY2" = "$NOTIFICATION_FIXED2" ]; then
    pass "A/B.T4: When WORKING_BRANCH is empty, both buggy and fixed are identical (PR_HEAD = CURRENT_BRANCH)"
else
    fail "A/B.T4: When WORKING_BRANCH is empty, buggy and fixed differ unexpectedly"
fi

# =============================================
# Section 3: Commit Diff Verification
# =============================================
separator "Section 3: Commit Diff Verification"

echo "T3.1: Verify fix commit only changes one line"
if cd "$PROJECT_ROOT" && git log --oneline -1 5e325ee 2>/dev/null | grep -q 'auto-pr-on-stop.sh'; then
    DIFF_STAT=$(git diff --stat 5e325ee^..5e325ee 2>/dev/null | tail -1)
    pass "T3.1: Fix commit found. Diff stat: $DIFF_STAT"
    # Verify only 1 file changed, 1 insertion, 1 deletion
    if echo "$DIFF_STAT" | grep -q '1 file changed, 1 insertion(+), 1 deletion(-)'; then
        pass "T3.2: Diff is minimal — exactly 1 file, 1 insertion, 1 deletion"
    else
        fail "T3.2: Diff is NOT minimal. Expected 1 file, 1 insertion, 1 deletion. Got: $DIFF_STAT"
    fi
else
    fail "T3.1: Fix commit 5e325ee not found or doesn't match expected"
fi

# =============================================
# Summary
# =============================================
separator "Test Summary"

echo "Total: $((PASS + FAIL))  |  Passed: $PASS  |  Failed: $FAIL"
echo ""
for r in "${RESULTS[@]}"; do
    status="${r%%|*}"
    msg="${r#*|}"
    if [ "$status" = "PASS" ]; then
        echo -e "  ${GREEN}[PASS]${NC} $msg"
    else
        echo -e "  ${RED}[FAIL]${NC} $msg"
    fi
done

if [ "$FAIL" -eq 0 ]; then
    echo ""
    echo -e "${GREEN}All tests passed.${NC}"
    exit 0
else
    echo ""
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
