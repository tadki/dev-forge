#!/bin/bash
# QA Test Suite for SEE-634: repo-checkout.sh text prompt fix
# Verifies Bachi's commit b091d3a changes are correct and no regressions introduced

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$REPO_ROOT/claude-hooks/scripts/repo-checkout.sh"
OLD_REV="e05aa15"
NEW_REV="b091d3a"

PASS=0
FAIL=0
TOTAL=0

assert() {
    local desc="$1" actual="$2" expected="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "    Missing substring: $needle"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  FAIL: $desc"
        echo "    Unexpected substring found: $needle"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

echo "=========================================="
echo "QA Test Suite: SEE-634 repo-checkout.sh"
echo "Target: $TARGET"
echo "=========================================="
echo ""

# --- TC-001: bash -n syntax check ---
echo "[TC-001] Syntax check (bash -n)"
bash -n "$TARGET" 2>/dev/null
assert "bash -n syntax check" $? "0"
echo ""

# --- TC-002: Branch C fix - no silent return ---
echo "[TC-002] Branch C fix: working_branch exists => output_hint + exit 0"
BRANCH_C_SECTION=$(sed -n '130,150p' "$TARGET")
assert_contains "Branch C outputs hint when working_branch exists" \
    "$BRANCH_C_SECTION" "本 issue 已设置 working branch"
assert_contains "Branch C exits with exit 0" \
    "$BRANCH_C_SECTION" "exit 0"
assert_not_contains "Branch C does NOT have silent return 0" \
    "$BRANCH_C_SECTION" "return 0"
echo ""

# --- TC-003: Line 174 fix - rebase failure text ---
echo "[TC-003] Line 174: rebase failure text change"
LINE_174=$(sed -n '174p' "$TARGET")
assert_contains "Rebase failure says 'checkout 流程已停止'" \
    "$LINE_174" "自动 checkout 流程已停止"
assert_not_contains "Rebase failure does NOT say '继续运行'" \
    "$LINE_174" "继续运行"
echo ""

# --- TC-004: output_fallback_hint helper exists and has correct logic ---
echo "[TC-004] output_fallback_hint helper"
HELPER_SECTION=$(sed -n '16,39p' "$TARGET")
assert_contains "Helper function defined" \
    "$(sed -n '16p' "$TARGET")" "output_fallback_hint()"
assert_contains "Helper checks for working_branch in metadata" \
    "$HELPER_SECTION" "meta.working_branch"
assert_contains "Helper has '已设置' branch when working_branch exists" \
    "$HELPER_SECTION" "已设置 working branch"
assert_contains "Helper has '尚未设置' branch when no working_branch" \
    "$HELPER_SECTION" "尚未设置 working branch"
echo ""

# --- TC-005: 3 fallback routes use output_fallback_hint ---
echo "[TC-005] 3 fallback routes use output_fallback_hint"
assert "Fallback route 1 (line ~248) uses output_fallback_hint" \
    "$(sed -n '248p' "$TARGET" | grep -c 'output_fallback_hint')" "1"
assert "Fallback route 2 (line ~289) uses output_fallback_hint" \
    "$(sed -n '289p' "$TARGET" | grep -c 'output_fallback_hint')" "1"
assert "Fallback route 3 (line ~322) uses output_fallback_hint" \
    "$(sed -n '322p' "$TARGET" | grep -c 'output_fallback_hint')" "1"
echo ""

# --- TC-006: 11 remaining output_hint calls unchanged ---
echo "[TC-006] 11 remaining output_hint unchanged (via diff)"
DIFF_OUTPUT=$(cd "$REPO_ROOT" && git diff $OLD_REV..$NEW_REV -- .claude/hooks/scripts/repo-checkout.sh)
CHANGED_HINT_LINES=$(echo "$DIFF_OUTPUT" | grep -cE '^\+.*output_hint[^_]' || true)
REMOVED_HINT_LINES=$(echo "$DIFF_OUTPUT" | grep -cE '^-.*output_hint[^_]' || true)
# New helper adds 2 internal output_hint calls, Branch C adds 1 new, line 174 modifies 1, 3 replaced by fallback
# So: added output_hint = 2 (helper internal) + 1 (Branch C) = 3 new lines with output_hint
# Replaced: 3 output_hint lines removed (fallback routes)
# Modified: 1 line (174 text change)
# Expected: 4 added output_hint lines (2 in helper + 1 Branch C + 1 modified), 4 removed (3 fallback + 1 modified)
assert "Added output_hint lines in diff (expect 4: 2 helper + 1 Branch C + 1 modified)" \
    "$CHANGED_HINT_LINES" "4"
assert "Removed output_hint lines in diff (expect 4: 3 fallback replaced + 1 modified)" \
    "$REMOVED_HINT_LINES" "4"
echo ""

# --- TC-007: Core git operations unchanged ---
echo "[TC-007] Core git operations unchanged"
DIFF_GIT=$(echo "$DIFF_OUTPUT" | grep -E '^[+-].*git (fetch|push|reset --hard|rebase|ls-remote)' || true)
CORE_GIT_CHANGED=$(echo "$DIFF_GIT" | grep -cvE '(output_hint|#)' || true)
assert "No core git operation lines changed (0)" "$CORE_GIT_CHANGED" "0"
echo ""

# --- TC-008: A/B comparison - verify specific before/after patterns ---
echo "[TC-008] A/B comparison: old patterns removed, new patterns present"
OLD_FILE=$(cd "$REPO_ROOT" && git show $OLD_REV:.claude/hooks/scripts/repo-checkout.sh)
NEW_FILE=$(cat "$TARGET")

assert_contains "OLD had silent 'return 0' in Branch C (bug)" \
    "$(echo "$OLD_FILE" | sed -n '116p')" "return 0"
assert_contains "NEW has 'output_hint' + 'exit 0' in Branch C (fix)" \
    "$(echo "$NEW_FILE" | sed -n '143p')" "output_hint"

assert_contains "OLD had '继续运行' at line 145" \
    "$(echo "$OLD_FILE" | sed -n '145p')" "继续运行"
assert_not_contains "NEW does NOT have '继续运行' at line 174" \
    "$(echo "$NEW_FILE" | sed -n '174p')" "继续运行"

assert_contains "OLD had hardcoded fallback at line 219" \
    "$(echo "$OLD_FILE" | sed -n '219p')" "output_hint"
assert_contains "NEW has output_fallback_hint at line 248" \
    "$(echo "$NEW_FILE" | sed -n '248p')" "output_fallback_hint"
echo ""

# --- TC-009: No stray output_hint with old "尚未设置" outside helper ---
echo "[TC-009] No stray '尚未设置' output_hint outside output_fallback_hint"
# output_fallback_hint helper spans lines 16-39; only calls outside this range count as stray
STRAY_LINES=$(awk '/^\s+output_hint ".*尚未设置/ && (NR < 16 || NR > 39)' "$TARGET" | wc -l)
assert "No direct output_hint calls with '尚未设置' outside helper (0)" "$STRAY_LINES" "0"
echo ""

# --- Summary ---
echo "=========================================="
echo "RESULTS: $PASS/$TOTAL passed, $FAIL failed"
echo "=========================================="

exit $FAIL
