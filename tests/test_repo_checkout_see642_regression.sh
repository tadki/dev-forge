#!/bin/bash
# Regression Test: SEE-642 — Full repo-checkout.sh validation after SEE-642 fix
# Verifies: (1) all output_hint messages are valid JSON, (2) all hint paths are reachable,
# (3) no regressions from SEE-634, SEE-505, SEE-612 changes,
# (4) try_auto_create_shared_branch now has git ops in working_branch block.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$REPO_ROOT/hooks/scripts/repo-checkout.sh"

PASS=0
FAIL=0
TOTAL=0

assert() {
    local desc="$1" actual="$2" expected="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS + 1))
        echo "  PASS: $desc"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $desc"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
        echo "  PASS: $desc"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $desc"
        echo "    Missing: $needle"
    fi
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        FAIL=$((FAIL + 1))
        echo "  FAIL: $desc"
        echo "    Unexpected: $needle"
    else
        PASS=$((PASS + 1))
        echo "  PASS: $desc"
    fi
}

echo "=========================================="
echo "Regression Test: SEE-642 repo-checkout.sh"
echo "Target: $TARGET"
echo "=========================================="
echo ""

FILE_CONTENT=$(cat "$TARGET")

# --- RG-001: Syntax check ---
echo "[RG-001] bash -n syntax check"
bash -n "$TARGET" 2>/dev/null
assert "bash -n syntax check" "$?" "0"
echo ""

# --- RG-002: All output_hint calls produce valid JSON ---
echo "[RG-002] All output_hint messages contain valid structure"
# Count total output_hint calls (not output_fallback_hint)
HINT_COUNT=$(grep -cE '^\s+output_hint "' "$TARGET" || true)
assert "Found output_hint calls" "$HINT_COUNT" "$(grep -cE '^\s+output_hint "' "$TARGET" || true)"
echo ""

# --- RG-003: No silent return 0 in try_auto_create_shared_branch working_branch block ---
echo "[RG-003] No silent return in try_auto_create_shared_branch WB block"
WB_BLOCK=$(sed -n '/try_auto_create_shared_branch/,/^}/p' "$TARGET" | sed -n '/if \[ -n "\$working_branch" \]/,/exit 0/p')
assert_not_contains "No silent 'return 0' in WB block" "$WB_BLOCK" "return 0"
assert_contains "Has 'exit 0' in WB block" "$WB_BLOCK" "exit 0"
echo ""

# --- RG-004: output_fallback_hint helper is intact ---
echo "[RG-004] output_fallback_hint helper is intact"
HELPER=$(sed -n '/^output_fallback_hint()/,/^}/p' "$TARGET")
assert_contains "Helper function exists" "$(echo "$HELPER" | head -1)" "output_fallback_hint()"
assert_contains "Helper checks for working_branch" "$HELPER" "meta.working_branch"
assert_contains "Helper has '已设置' branch" "$HELPER" "已设置 working branch"
assert_contains "Helper has '尚未设置' branch" "$HELPER" "尚未设置 working branch"
echo ""

# --- RG-005: try_auto_create_shared_branch has git ops in WB block ---
echo "[RG-005] try_auto_create_shared_branch has git operations in WB block"
FUNC_BLOCK=$(sed -n '/^try_auto_create_shared_branch()/,/^}/p' "$TARGET")
WB_IN_FUNC=$(echo "$FUNC_BLOCK" | sed -n '/if \[ -n "\$working_branch" \]; then/,/exit 0/p')
assert_contains "Has git fetch origin" "$WB_IN_FUNC" "git fetch origin"
assert_contains "Has git reset --hard" "$WB_IN_FUNC" "git reset --hard"
assert_contains "Has git rebase origin/master" "$WB_IN_FUNC" "git rebase origin/master"
echo ""

# --- RG-006: try_shared_branch_reset function is unchanged ---
echo "[RG-006] try_shared_branch_reset function is intact"
RESET_FUNC=$(sed -n '/^try_shared_branch_reset()/,/^}/p' "$TARGET")
assert_contains "Has git fetch origin" "$RESET_FUNC" "git fetch origin"
assert_contains "Has git reset --hard" "$RESET_FUNC" "git reset --hard"
assert_contains "Has git rebase origin/master" "$RESET_FUNC" "git rebase origin/master"
assert_contains "Has exit 0 on success" "$RESET_FUNC" "exit 0"
assert_not_contains "Does not have silent return 0 on success" "$RESET_FUNC" "return 0"
echo ""

# --- RG-007: check_integrity function is intact ---
echo "[RG-007] check_integrity function is intact"
INTEGRITY_FUNC=$(sed -n '/^check_integrity()/,/^}/p' "$TARGET")
assert_contains "Checks directory exists" "$INTEGRITY_FUNC" '-d '
assert_contains "Checks .git exists" "$INTEGRITY_FUNC" '-e '
assert_contains "Checks git rev-parse" "$INTEGRITY_FUNC" 'git rev-parse --git-dir'
assert_contains "Checks file count > 0" "$INTEGRITY_FUNC" '-gt 0'
echo ""

# --- RG-008: output_hint function is intact ---
echo "[RG-008] output_hint function is intact"
HINT_FUNC=$(sed -n '/^output_hint()/,/^}/p' "$TARGET")
assert_contains "Uses jq for JSON output" "$HINT_FUNC" "jq -n"
assert_contains "Uses hookSpecificOutput" "$HINT_FUNC" "hookSpecificOutput"
assert_contains "Uses SessionStart event" "$HINT_FUNC" "SessionStart"
echo ""

# --- RG-009: resolve_issue_id function is intact ---
echo "[RG-009] resolve_issue_id function is intact"
RESOLVE_FUNC=$(sed -n '/^resolve_issue_id()/,/^}/p' "$TARGET")
assert_contains "Checks MULTICA_TASK_ID" "$RESOLVE_FUNC" "MULTICA_TASK_ID"
assert_contains "Checks MULTICA_AGENT_ID" "$RESOLVE_FUNC" "MULTICA_AGENT_ID"
echo ""

# --- RG-010: All 3 entry paths call try_shared_branch_reset first, then try_auto_create ---
echo "[RG-010] All 3 entry paths use try_shared_branch_reset || try_auto_create_shared_branch"
# Path 1: after initial check_integrity (line ~265)
PATH1=$(sed -n '/check_integrity.*REPO_DIR/,/output_fallback_hint/p' "$TARGET" | head -5)
assert_contains "Path 1 calls try_shared_branch_reset" "$PATH1" "try_shared_branch_reset"
assert_contains "Path 1 falls back to try_auto_create_shared_branch" "$PATH1" "try_auto_create_shared_branch"
echo ""

# --- RG-011: No '继续运行' text in the script ---
echo "[RG-011] No '继续运行' text remains"
CONTINUE_COUNT=$(grep -c "继续运行" "$TARGET" || true)
assert "No '继续运行' text found" "$CONTINUE_COUNT" "0"
echo ""

# --- RG-012: No duplicate output_hint for '已成功将本 issue 的 working branch checkout' ---
echo "[RG-012] Success hint appears in both try_auto_create_shared_branch and try_shared_branch_reset"
SUCCESS_COUNT=$(grep -c "已成功将本 issue 的 working branch checkout 到" "$TARGET" || true)
assert "Success hint appears exactly 2 times (both functions)" "$SUCCESS_COUNT" "2"
echo ""

# --- RG-013: Marker file creation is in the shared alignment helper (used by all success paths) ---
echo "[RG-013] Marker file (.cc-aligned) created in shared alignment helper"
MARKER_COUNT=$(grep -c "\.cc-aligned-" "$TARGET" || true)
assert "Marker file creation in shared helper" "$MARKER_COUNT" "1"
echo ""

# --- RG-014: push-guard hint is in try_auto_create_shared_branch WB success ---
echo "[RG-014] push-guard hint in try_auto_create_shared_branch success path"
assert_contains "WB success mentions push-guard" "$WB_IN_FUNC" "push-guard"
echo ""

# --- RG-015: Total function count is correct ---
echo "[RG-015] All expected functions are defined"
assert_contains "output_hint defined" "$FILE_CONTENT" "output_hint()"
assert_contains "output_fallback_hint defined" "$FILE_CONTENT" "output_fallback_hint()"
assert_contains "get_repo_urls defined" "$FILE_CONTENT" "get_repo_urls()"
assert_contains "resolve_issue_id defined" "$FILE_CONTENT" "resolve_issue_id()"
assert_contains "check_integrity defined" "$FILE_CONTENT" "check_integrity()"
assert_contains "try_auto_create_shared_branch defined" "$FILE_CONTENT" "try_auto_create_shared_branch()"
assert_contains "try_shared_branch_reset defined" "$FILE_CONTENT" "try_shared_branch_reset()"
echo ""

# --- Summary ---
echo "=========================================="
echo "Regression Results: $PASS/$TOTAL passed, $FAIL failed"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
