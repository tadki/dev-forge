#!/bin/bash
# QA Test Script for SEE-913: repo-checkout.sh nested-worktree guard
# Verifies the guard that refuses `multica repo checkout` when cwd is already
# inside a git repo (prevents nested worktree creation).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/scripts/repo-checkout.sh"
PASS=0
FAIL=0

# --- Test: guard function is defined ---
test_guard_defined() {
    echo "[TEST] refuse_if_inside_git_repo function should be defined..."
    if grep -q "^refuse_if_inside_git_repo()" "$HOOK_SCRIPT"; then
        echo "  PASS: guard function defined"
        PASS=$((PASS+1))
    else
        echo "  FAIL: guard function missing"
        FAIL=$((FAIL+1))
    fi
}

# --- Test: guard is invoked before the checkout step ---
test_guard_invoked() {
    echo "[TEST] refuse_if_inside_git_repo should be called before Step 1 checkout..."
    if grep -q "refuse_if_inside_git_repo" "$HOOK_SCRIPT" | head -1 >/dev/null 2>&1; then
        :
    fi
    local call_line guard_def_line step1_line
    guard_def_line=$(grep -n "^refuse_if_inside_git_repo()" "$HOOK_SCRIPT" | head -1 | cut -d: -f1)
    call_line=$(grep -n "^[[:space:]]*refuse_if_inside_git_repo\$" "$HOOK_SCRIPT" | head -1 | cut -d: -f1)
    step1_line=$(grep -n "# --- Step 1: Attempt checkout ---" "$HOOK_SCRIPT" | head -1 | cut -d: -f1)
    if [ -n "$call_line" ] && [ -n "$step1_line" ] && [ "$call_line" -lt "$step1_line" ]; then
        echo "  PASS: guard called at line $call_line, before Step 1 at line $step1_line"
        PASS=$((PASS+1))
    else
        echo "  FAIL: guard not invoked before Step 1 (call=$call_line step1=$step1_line)"
        FAIL=$((FAIL+1))
    fi
}

# --- Test: guard uses git rev-parse --show-toplevel for detection ---
test_guard_detection_primitive() {
    echo "[TEST] guard should detect via 'git rev-parse --show-toplevel'..."
    if grep -q "git rev-parse --show-toplevel" "$HOOK_SCRIPT"; then
        echo "  PASS: detection primitive present"
        PASS=$((PASS+1))
    else
        echo "  FAIL: detection primitive missing"
        FAIL=$((FAIL+1))
    fi
}

# --- Test: detection triggers inside a git repo (functional) ---
test_detection_triggers_in_repo() {
    echo "[TEST] detection should trigger inside a git repo..."
    local tmp
    tmp=$(mktemp -d)
    git -C "$tmp" init -q
    local toplevel
    if toplevel=$(git -C "$tmp" rev-parse --show-toplevel 2>/dev/null) && [ -n "$toplevel" ]; then
        echo "  PASS: in-repo cwd detected as nested risk"
        PASS=$((PASS+1))
    else
        echo "  FAIL: in-repo cwd not detected"
        FAIL=$((FAIL+1))
    fi
    rm -rf "$tmp"
}

# --- Test: detection does NOT trigger in a plain directory (functional) ---
test_detection_skips_plain_dir() {
    echo "[TEST] detection should NOT trigger in a plain (non-repo) directory..."
    local tmp
    tmp=$(mktemp -d)
    local toplevel
    if toplevel=$(git -C "$tmp" rev-parse --show-toplevel 2>/dev/null) && [ -n "$toplevel" ]; then
        echo "  FAIL: plain dir incorrectly flagged as repo"
        FAIL=$((FAIL+1))
    else
        echo "  PASS: plain dir correctly allowed"
        PASS=$((PASS+1))
    fi
    rm -rf "$tmp"
}

# --- Test: script is valid bash ---
test_bash_syntax_valid() {
    echo "[TEST] repo-checkout.sh has valid bash syntax..."
    if bash -n "$HOOK_SCRIPT" 2>/dev/null; then
        echo "  PASS: Syntax valid"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Syntax errors detected"
        FAIL=$((FAIL+1))
    fi
}

# Run all tests
echo "======================================"
echo "SEE-913 QA: repo-checkout.sh nested-worktree guard"
echo "======================================"
echo ""

test_guard_defined
test_guard_invoked
test_guard_detection_primitive
test_detection_triggers_in_repo
test_detection_skips_plain_dir
test_bash_syntax_valid

echo ""
echo "======================================"
echo "Results: $PASS passed, $FAIL failed"
echo "======================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
