#!/bin/bash
# QA Test Script for SEE-519: repo-checkout.sh prune workaround removal
# Tests: prune logic removed, retry core logic intact, no bare repo detection

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/scripts/repo-checkout.sh"
PASS=0
FAIL=0

# --- Test: prune workaround completely removed ---
test_prune_removed() {
    echo "[TEST] 'git worktree prune' should NOT appear in repo-checkout.sh..."
    if grep -q "git worktree prune" "$HOOK_SCRIPT"; then
        echo "  FAIL: 'git worktree prune' still present in repo-checkout.sh"
        grep -n "git worktree prune" "$HOOK_SCRIPT" | sed 's/^/    /'
        FAIL=$((FAIL+1))
    else
        echo "  PASS: No 'git worktree prune' found"
        PASS=$((PASS+1))
    fi
}

# --- Test: BARE_REPO_PATH variable removed ---
test_bare_repo_path_removed() {
    echo "[TEST] 'BARE_REPO_PATH' variable should NOT appear in repo-checkout.sh..."
    if grep -q "BARE_REPO_PATH" "$HOOK_SCRIPT"; then
        echo "  FAIL: 'BARE_REPO_PATH' still present in repo-checkout.sh"
        grep -n "BARE_REPO_PATH" "$HOOK_SCRIPT" | sed 's/^/    /'
        FAIL=$((FAIL+1))
    else
        echo "  PASS: No 'BARE_REPO_PATH' found"
        PASS=$((PASS+1))
    fi
}

# --- Test: retry core logic preserved (rm -rf → re-checkout → check_integrity) ---
test_retry_logic_intact() {
    echo "[TEST] Retry core logic must be intact..."
    local has_rm=false
    local has_checkout=false
    local has_integrity=false

    # Check for rm -rf in retry block (Step 3 area)
    if grep -q 'rm -rf "\$REPO_DIR"' "$HOOK_SCRIPT"; then
        has_rm=true
    fi

    # Check for check_integrity call after retry
    if grep -q 'check_integrity "\$REPO_DIR"' "$HOOK_SCRIPT"; then
        has_integrity=true
    fi

    # Check for multica repo checkout in retry
    if grep -q 'multica repo checkout' "$HOOK_SCRIPT"; then
        has_checkout=true
    fi

    if [ "$has_rm" = true ] && [ "$has_checkout" = true ] && [ "$has_integrity" = true ]; then
        echo "  PASS: Retry logic intact (rm → checkout → check_integrity)"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Retry logic incomplete"
        [ "$has_rm" = false ] && echo "    Missing: rm -rf"
        [ "$has_checkout" = false ] && echo "    Missing: multica repo checkout"
        [ "$has_integrity" = false ] && echo "    Missing: check_integrity"
        FAIL=$((FAIL+1))
    fi
}

# --- Test: old CHECKOUT_SUCCESS variable removed ---
test_checkout_success_removed() {
    echo "[TEST] CHECKOUT_SUCCESS variable should NOT appear in repo-checkout.sh..."
    if grep -q "CHECKOUT_SUCCESS" "$HOOK_SCRIPT"; then
        echo "  FAIL: CHECKOUT_SUCCESS still present in repo-checkout.sh"
        grep -n "CHECKOUT_SUCCESS" "$HOOK_SCRIPT" | sed 's/^/    /'
        FAIL=$((FAIL+1))
    else
        echo "  PASS: No CHECKOUT_SUCCESS found"
        PASS=$((PASS+1))
    fi
}

# --- Test: old marker file writing removed ---
test_marker_writing_removed() {
    echo "[TEST] Marker file writing logic should NOT appear in repo-checkout.sh..."
    if grep -q "\.repos-checked-out" "$HOOK_SCRIPT"; then
        echo "  FAIL: .repos-checked-out writing still present in repo-checkout.sh"
        grep -n "\.repos-checked-out" "$HOOK_SCRIPT" | sed 's/^/    /'
        FAIL=$((FAIL+1))
    else
        echo "  PASS: No marker file writing found"
        PASS=$((PASS+1))
    fi
}

# --- Test: no bare repo path detection logic remains ---
test_no_bare_repo_detection() {
    echo "[TEST] No bare repo path detection logic should remain..."
    local has_gitdir=false
    local has_worktrees_dir=false

    if grep -q "gitdir:" "$HOOK_SCRIPT"; then
        has_gitdir=true
    fi

    if grep -q "worktrees" "$HOOK_SCRIPT"; then
        has_worktrees_dir=true
    fi

    if [ "$has_gitdir" = true ] || [ "$has_worktrees_dir" = true ]; then
        echo "  FAIL: Bare repo detection logic remnants found"
        [ "$has_gitdir" = true ] && echo "    Found: gitdir:"
        [ "$has_worktrees_dir" = true ] && echo "    Found: worktrees"
        FAIL=$((FAIL+1))
    else
        echo "  PASS: No bare repo detection logic remnants"
        PASS=$((PASS+1))
    fi
}

# --- Test: overall line count reduced (sanity check) ---
test_line_count_sanity() {
    echo "[TEST] Script line count sanity check (should be reasonable, not bloated)..."
    local lines
    lines=$(wc -l < "$HOOK_SCRIPT" | tr -d ' ')
    if [ "$lines" -lt 200 ]; then
        echo "  PASS: Script is $lines lines"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Script is $lines lines (expected < 200)"
        FAIL=$((FAIL+1))
    fi
}

# --- Test: script is still valid bash (syntax check) ---
test_bash_syntax_valid() {
    echo "[TEST] repo-checkout.sh has valid bash syntax..."
    if bash -n "$HOOK_SCRIPT" 2>/dev/null; then
        echo "  PASS: Syntax valid"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Syntax errors detected"
        bash -n "$HOOK_SCRIPT" | sed 's/^/    /'
        FAIL=$((FAIL+1))
    fi
}

# Run all tests
echo "======================================"
echo "SEE-519 QA: repo-checkout.sh Tests"
echo "======================================"
echo ""

test_prune_removed
test_bare_repo_path_removed
test_retry_logic_intact
test_checkout_success_removed
test_marker_writing_removed
test_no_bare_repo_detection
test_line_count_sanity
test_bash_syntax_valid

echo ""
echo "======================================"
echo "Results: $PASS passed, $FAIL failed"
echo "======================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
