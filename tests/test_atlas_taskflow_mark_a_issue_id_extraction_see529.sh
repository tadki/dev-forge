#!/bin/bash
# test_atlas_taskflow_mark_a_issue_id_extraction_see529.sh
# Unit tests for SEE-529: atlas-taskflow-mark-a.sh issue ID extraction from issue_context.md
#
# Related Issue: SEE-529
# Test Type: Unit
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
HOOK_SCRIPT="$PROJECT_ROOT/hooks/scripts/atlas-taskflow-mark-a.sh"

# Real issue ID and task ID for testing
REAL_ISSUE_ID="0261d5ab-4b5d-4c59-8a7c-43c019ac3d73"
TASK_ID="78c0744d-test-session"

# Helper: run the extraction logic in isolation and return the resolved issue ID
extract_issue_id() {
    local issue_context_file="$1"
    local task_id="${2:-$TASK_ID}"

    # Replicate the extraction logic from mark-a.sh
    local extracted=""
    if [ -f "$issue_context_file" ]; then
        extracted=$(sed -n 's/.*\*\*Issue ID:\*\* *\([a-f0-9-]\{36\}\).*/\1/p' "$issue_context_file" | head -1)
    fi
    if [ -z "$extracted" ]; then
        extracted="$task_id"
    fi
    echo "$extracted"
}

echo "============================================"
echo "  SEE-529 Issue ID Extraction Unit Tests"
echo "  Date: $(date -Iseconds)"
echo "  Author: Bachi"
echo "  Branch: $(git branch --show-current 2>/dev/null || echo 'N/A')"
echo "============================================"

#####################################################################
# GROUP 1: Direct extraction logic tests
#####################################################################
separator "G1: Extraction from issue_context.md"

# G1a: Standard format
TMP_CTX=$(mktemp /tmp/see529-ctx.XXXXXX)
echo '**Issue ID:** 0261d5ab-4b5d-4c59-8a7c-43c019ac3d73' > "$TMP_CTX"
RESULT=$(extract_issue_id "$TMP_CTX")
if [ "$RESULT" = "$REAL_ISSUE_ID" ]; then
    pass "G1a: Standard format extraction"
else
    fail "G1a: Expected $REAL_ISSUE_ID, got '$RESULT'"
fi
rm -f "$TMP_CTX"

# G1b: With extra whitespace
TMP_CTX=$(mktemp /tmp/see529-ctx.XXXXXX)
echo '**Issue ID:**   0261d5ab-4b5d-4c59-8a7c-43c019ac3d73  ' > "$TMP_CTX"
RESULT=$(extract_issue_id "$TMP_CTX")
if [ "$RESULT" = "$REAL_ISSUE_ID" ]; then
    pass "G1b: Extra whitespace handling"
else
    fail "G1b: Expected $REAL_ISSUE_ID, got '$RESULT'"
fi
rm -f "$TMP_CTX"

# G1c: Embedded in markdown with other content
TMP_CTX=$(mktemp /tmp/see529-ctx.XXXXXX)
cat > "$TMP_CTX" << 'EOF'
# Issue Context

**Issue ID:** 0261d5ab-4b5d-4c59-8a7c-43c019ac3d73
**Title:** Test Issue
**Status:** in_progress
EOF
RESULT=$(extract_issue_id "$TMP_CTX")
if [ "$RESULT" = "$REAL_ISSUE_ID" ]; then
    pass "G1c: Embedded in markdown content"
else
    fail "G1c: Expected $REAL_ISSUE_ID, got '$RESULT'"
fi
rm -f "$TMP_CTX"

# G1d: File does not exist — fallback to task ID
RESULT=$(extract_issue_id "/nonexistent/file")
if [ "$RESULT" = "$TASK_ID" ]; then
    pass "G1d: Fallback to task ID when file missing"
else
    fail "G1d: Expected fallback '$TASK_ID', got '$RESULT'"
fi

# G1e: File exists but no Issue ID line — fallback
TMP_CTX=$(mktemp /tmp/see529-ctx.XXXXXX)
echo 'Some other content without the magic keyword' > "$TMP_CTX"
RESULT=$(extract_issue_id "$TMP_CTX")
if [ "$RESULT" = "$TASK_ID" ]; then
    pass "G1e: Fallback when Issue ID line missing"
else
    fail "G1e: Expected fallback '$TASK_ID', got '$RESULT'"
fi
rm -f "$TMP_CTX"

# G1f: Malformed UUID — fallback
TMP_CTX=$(mktemp /tmp/see529-ctx.XXXXXX)
echo '**Issue ID:** not-a-valid-uuid' > "$TMP_CTX"
RESULT=$(extract_issue_id "$TMP_CTX")
if [ "$RESULT" = "$TASK_ID" ]; then
    pass "G1f: Fallback on malformed UUID"
else
    fail "G1f: Expected fallback '$TASK_ID', got '$RESULT'"
fi
rm -f "$TMP_CTX"

# G1g: First line has Issue ID, second line also has one — uses first
TMP_CTX=$(mktemp /tmp/see529-ctx.XXXXXX)
cat > "$TMP_CTX" << 'EOF'
**Issue ID:** 0261d5ab-4b5d-4c59-8a7c-43c019ac3d73
**Parent Issue ID:** 11111111-1111-1111-1111-111111111111
EOF
RESULT=$(extract_issue_id "$TMP_CTX")
if [ "$RESULT" = "$REAL_ISSUE_ID" ]; then
    pass "G1g: Uses first Issue ID occurrence"
else
    fail "G1g: Expected first ID '$REAL_ISSUE_ID', got '$RESULT'"
fi
rm -f "$TMP_CTX"

# G1h: Empty file — fallback
TMP_CTX=$(mktemp /tmp/see529-ctx.XXXXXX)
> "$TMP_CTX"
RESULT=$(extract_issue_id "$TMP_CTX")
if [ "$RESULT" = "$TASK_ID" ]; then
    pass "G1h: Fallback on empty file"
else
    fail "G1h: Expected fallback '$TASK_ID', got '$RESULT'"
fi
rm -f "$TMP_CTX"

#####################################################################
# GROUP 2: Hook code structure verification
#####################################################################
separator "G2: Hook code structure verification"

# G2a: Hook references issue_context.md
if grep -q "issue_context\\.md" "$HOOK_SCRIPT"; then
    pass "G2a: Hook references issue_context.md"
else
    fail "G2a: Hook missing issue_context.md reference"
fi

# G2b: Hook uses ISSUE_ID variable for multica call
if grep -q 'multica issue comment list "\$ISSUE_ID"' "$HOOK_SCRIPT"; then
    pass "G2b: Hook uses ISSUE_ID for multica comment list"
else
    fail "G2b: Hook does not use ISSUE_ID for multica call"
fi

# G2c: Hook has fallback to MULTICA_TASK_ID
if grep -q 'ISSUE_ID="\$MULTICA_TASK_ID"' "$HOOK_SCRIPT"; then
    pass "G2c: Hook has fallback to MULTICA_TASK_ID"
else
    fail "G2c: Hook missing fallback logic"
fi

# G2d: State file still uses MULTICA_TASK_ID as key (unchanged)
if grep -q 'STATE_FILE="/tmp/atlas-taskflow-state-\${MULTICA_TASK_ID}"' "$HOOK_SCRIPT"; then
    pass "G2d: State file key uses MULTICA_TASK_ID (unchanged)"
else
    fail "G2d: State file key changed unexpectedly"
fi

# G2e: Hook no longer uses MULTICA_TASK_ID directly for multica comment list
if ! grep -q 'multica issue comment list.*MULTICA_TASK_ID' "$HOOK_SCRIPT"; then
    pass "G2e: No direct MULTICA_TASK_ID usage in multica comment list"
else
    fail "G2e: MULTICA_TASK_ID still used directly in multica comment list"
fi

#####################################################################
# GROUP 3: Edge cases
#####################################################################
separator "G3: Edge cases"

# G3a: UUID with uppercase letters (should not match — regex is lowercase)
TMP_CTX=$(mktemp /tmp/see529-ctx.XXXXXX)
echo '**Issue ID:** 0261D5AB-4B5D-4C59-8A7C-43C019AC3D73' > "$TMP_CTX"
RESULT=$(extract_issue_id "$TMP_CTX")
if [ "$RESULT" = "$TASK_ID" ]; then
    pass "G3a: Uppercase UUID rejected (case sensitive)"
else
    fail "G3a: Expected fallback, got '$RESULT'"
fi
rm -f "$TMP_CTX"

# G3b: Partial UUID (too short)
TMP_CTX=$(mktemp /tmp/see529-ctx.XXXXXX)
echo '**Issue ID:** 0261d5ab-4b5d-4c59' > "$TMP_CTX"
RESULT=$(extract_issue_id "$TMP_CTX")
if [ "$RESULT" = "$TASK_ID" ]; then
    pass "G3b: Short UUID rejected"
else
    fail "G3b: Expected fallback, got '$RESULT'"
fi
rm -f "$TMP_CTX"

# G3c: UUID with extra chars attached
TMP_CTX=$(mktemp /tmp/see529-ctx.XXXXXX)
echo '**Issue ID:** 0261d5ab-4b5d-4c59-8a7c-43c019ac3d73-extra' > "$TMP_CTX"
RESULT=$(extract_issue_id "$TMP_CTX")
if [ "$RESULT" = "$REAL_ISSUE_ID" ]; then
    pass "G3c: Extracts clean UUID even with trailing text"
else
    fail "G3c: Expected '$REAL_ISSUE_ID', got '$RESULT'"
fi
rm -f "$TMP_CTX"

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
