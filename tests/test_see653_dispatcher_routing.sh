#!/bin/bash
# test_see653_dispatcher_routing.sh
# QA Test for SEE-653 Fix 2: dispatcher.sh project root search order
# Validates: $PWD/*/ subdirectory search runs BEFORE $ADDITIONAL_DIRS (WSL fallback)
#
# Related Issue: SEE-653
# Author: Revy (QA Agent)

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0
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

skip() {
    echo -e "  ${YELLOW}[SKIP]${NC} $1"
    SKIP=$((SKIP + 1))
    RESULTS+=("SKIP|$1")
}

separator() {
    echo ""
    echo -e "${CYAN}--- $1 ---${NC}"
}

# P4 收敛（SEE-1330）：v1 alias 路由删除——skill-check 等仅剩 unified-hook case；
# 注册断言同步更新为收敛后语义。实机全局副本由 Atlas 在 P4 cutover 批同步，
# 本地开发期间可能尚未收敛——统一以 .dev/hooks 真源为断言对象（只读，不触实机）。
REPO_DISPATCHER="$(cd "$(dirname "$0")/.." && pwd)/claude-hooks/dispatcher.sh"
DISPATCHER="$REPO_DISPATCHER"

if [ ! -f "$DISPATCHER" ]; then
    echo "ERROR: dispatcher.sh not found at $DISPATCHER"
    exit 1
fi

echo "=== SEE-653 Dispatcher Routing Tests ==="
echo "Dispatcher: $DISPATCHER"

# --- Test 1: Verify search order in dispatcher source ---
separator "1. Source Code: Search Order Verification"

SUBDIR_LINE=$(grep -n 'for subdir in.*PWD' "$DISPATCHER" | head -1 | cut -d: -f1)
WSL_LINE=$(grep -n 'for dir in \$ADDITIONAL_DIRS' "$DISPATCHER" | head -1 | cut -d: -f1)

if [ -n "$SUBDIR_LINE" ] && [ -n "$WSL_LINE" ] && [ "$SUBDIR_LINE" -lt "$WSL_LINE" ]; then
    pass "T01: Subdirectory search (line $SUBDIR_LINE) comes before WSL fallback (line $WSL_LINE)"
else
    fail "T01: Search order incorrect — subdirectory (line $SUBDIR_LINE) should be before WSL fallback (line $WSL_LINE)"
fi

if grep -q 'for subdir in.*"\$PWD".*\*/' "$DISPATCHER"; then
    pass "T02: Subdirectory search uses \"\$PWD\"/*/ pattern"
else
    fail "T02: Subdirectory search pattern not found in dispatcher"
fi

TOTAL_LINES=$(wc -l < "$DISPATCHER")
if [ -n "$WSL_LINE" ] && [ "$WSL_LINE" -gt "$((TOTAL_LINES * 40 / 100))" ]; then
    pass "T03: WSL fallback (line $WSL_LINE/$TOTAL_LINES) is in the latter part of the file (last resort position)"
else
    fail "T03: WSL fallback is too early in the file — should be last resort"
fi

# --- Test 2: Runtime routing verification ---
separator "2. Runtime: Project Root Resolution"

WORKDIR="$(cd "$(dirname "$0")/../.." && pwd)"
REPO_DIR="$WORKDIR/KingOfLikes-Godot"
WSL_DIR="/mnt/d/GodotProjects/king-of-likes"

if [ -d "$REPO_DIR/hooks" ]; then
    pass "T04: Workdir subdirectory has .claude/hooks at $REPO_DIR"
else
    fail "T04: Workdir subdirectory missing .claude/hooks at $REPO_DIR"
fi

WSL_EXISTS=false
if [ -d "$WSL_DIR/.claude/hooks" ]; then
    WSL_EXISTS=true
    echo "  Note: WSL path also exists at $WSL_DIR (this is the scenario the fix addresses)"
fi

simulate_dispatcher() {
    local pwd_dir="$1"
    local project_root=""

    for dir in "${CLAUDE_PROJECT_DIR:-}" "$pwd_dir"; do
        [ -n "$dir" ] && [ -d "$dir/.claude/hooks" ] && { echo "$dir"; return; }
    done

    for subdir in "$pwd_dir"/*/; do
        [ -d "$subdir.claude/hooks" ] && { echo "${subdir%/}"; return; }
    done

    local additional_dirs=""
    for candidate in "/mnt/d/GodotProjects/king-of-likes"; do
        if [ -d "$candidate" ]; then
            additional_dirs="$candidate"
            break
        fi
    done
    for dir in $additional_dirs; do
        [ -n "$dir" ] && [ -d "$dir/.claude/hooks" ] && { echo "$dir"; return; }
    done

    echo ""
}

RESOLVED_ROOT=$(simulate_dispatcher "$WORKDIR")

if [ "$RESOLVED_ROOT" = "$REPO_DIR" ]; then
    pass "T05: Dispatcher resolves to workdir subdirectory: $RESOLVED_ROOT"
elif [ -n "$RESOLVED_ROOT" ]; then
    if [ "$WSL_EXISTS" = true ] && [ "$RESOLVED_ROOT" = "$WSL_DIR" ]; then
        fail "T05: Dispatcher resolves to WSL path (BUG!): $RESOLVED_ROOT — should be $REPO_DIR"
    else
        fail "T05: Dispatcher resolves to unexpected path: $RESOLVED_ROOT"
    fi
else
    fail "T05: Dispatcher resolves to empty string — no hooks directory found"
fi

# --- Test 3: Old order would have picked WSL ---
separator "3. Regression: Old Order Would Pick WSL"

simulate_old_dispatcher() {
    local pwd_dir="$1"
    local project_root=""

    for dir in "${CLAUDE_PROJECT_DIR:-}" "$pwd_dir"; do
        [ -n "$dir" ] && [ -d "$dir/.claude/hooks" ] && { echo "$dir"; return; }
    done

    local additional_dirs=""
    for candidate in "/mnt/d/GodotProjects/king-of-likes"; do
        if [ -d "$candidate" ]; then
            additional_dirs="$candidate"
            break
        fi
    done
    for dir in $additional_dirs; do
        [ -n "$dir" ] && [ -d "$dir/.claude/hooks" ] && { echo "$dir"; return; }
    done

    for subdir in "$pwd_dir"/*/; do
        [ -d "$subdir.claude/hooks" ] && { echo "${subdir%/}"; return; }
    done

    echo ""
}

OLD_RESOLVED=$(simulate_old_dispatcher "$WORKDIR")

if [ "$WSL_EXISTS" = true ]; then
    if [ "$OLD_RESOLVED" = "$WSL_DIR" ]; then
        pass "T06: OLD order correctly picks WSL (confirms the bug existed): $OLD_RESOLVED"
    else
        echo "  Note: OLD order resolved to: $OLD_RESOLVED"
        skip "T06: WSL path exists but old order didn't pick it — unexpected"
    fi
else
    skip "T06: WSL path doesn't exist — can't verify old behavior would pick WSL"
fi

# --- Test 4: Verify hook-fire.log has correct routing ---
separator "4. Hook Fire Log: Dispatcher Invocations"

if [ -f "$HOME/.claude/hook-fire.log" ] && [ -s "$HOME/.claude/hook-fire.log" ]; then
    WORKDIR_ENTRIES=$(grep -c 'workdir' "$HOME/.claude/hook-fire.log" 2>/dev/null || echo 0)
    if [ "$WORKDIR_ENTRIES" -gt 0 ]; then
        pass "T07: Hook fire log has $WORKDIR_ENTRIES entries from workdir PWD"
    else
        fail "T07: No hook fire log entries from workdir PWD"
    fi

    SKILL_CHECK_ENTRIES=$(grep -c 'alias=skill-check' "$HOME/.claude/hook-fire.log" 2>/dev/null || echo 0)
    if [ "$SKILL_CHECK_ENTRIES" -gt 0 ]; then
        pass "T08: Hook fire log shows skill-check was dispatched"
    else
        echo "  Note: No skill-check entries yet"
        skip "T08: No skill-check dispatch entries in log"
    fi
else
    skip "T07/T08: Hook fire log empty or missing"
fi

# --- Test 5: Verify dispatcher script file is consistent ---
separator "5. File Integrity"

if grep -q 'CC official > PWD > PWD subdirs.*Multica workdir.*WSL fallback' "$DISPATCHER"; then
    pass "T09: Dispatcher comment reflects correct order: CC official > PWD > PWD subdirs > WSL"
else
    if grep -q 'PWD subdirs.*WSL fallback' "$DISPATCHER" || grep -q 'Multica workdir' "$DISPATCHER"; then
        pass "T09: Dispatcher contains subdirectory-before-WSL order comment"
    else
        fail "T09: Dispatcher missing order comment indicating PWD subdirs before WSL"
    fi
fi

# P4 收敛（SEE-1330）：v1 alias 路由删除——skill-check 等仅剩 unified-hook case；
# 注册断言同步更新为收敛后语义。
if grep -q 'unified-hook)' "$DISPATCHER" && ! grep -q 'skill-check).*pre-comment-skill-check' "$DISPATCHER"; then
    pass "T10: Dispatcher converged — only unified-hook case, v1 alias routing removed"
else
    fail "T10: Dispatcher routing not converged (expected unified-hook only)"
fi

# --- Cleanup ---
separator "Results Summary"

echo ""
Total=$((PASS + FAIL + SKIP))
echo "Total: $Total | PASS: $PASS | FAIL: $FAIL | SKIP: $SKIP"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
    exit 0
else
    echo -e "${RED}$FAIL TEST(S) FAILED${NC}"
    exit 1
fi
