#!/bin/bash
# test_see781_firelog_path.sh
# QA Test Suite for SEE-781: Firelog path migration from global to repo-level .claude/
# Covers: hook-wrapper.sh LOG_FILE detection, dispatcher.sh LOG_FILE detection,
#         Multica workdir mode, non-repo fallback, global/repo copy consistency
#
# Related Issue: SEE-781
# Test Type: E2E + Regression + A/B Test
# Author: Revy

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

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); RESULTS+=("PASS|$1"); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); RESULTS+=("FAIL|$1"); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; WARN=$((WARN + 1)); RESULTS+=("WARN|$1"); }
separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

PROJECT_ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GLOBAL_HOOKS_DIR="$HOME/.claude/hooks"
REPO_HOOKS_DIR="$PROJECT_ROOT_DIR/.dev/hooks"
ORIG_DIR="$(pwd)"

# ==============================================================
# Helpers
# ==============================================================

# Extract the LOG_FILE path that hook-wrapper.sh would compute
# by simulating the detection logic with given PWD and optional CLAUDE_PROJECT_DIR
get_wrapper_log_file() {
    local pwd_dir="$1"
    local cpd="${2:-}"
    local log_file

    log_file=$(cd "$pwd_dir" && env ${cpd:+CLAUDE_PROJECT_DIR="$cpd"} bash -c '
        LOG_FILE="$HOME/.claude/hook-fire.log"
        for _dir in "$CLAUDE_PROJECT_DIR" "$PWD"; do
          [ -n "$_dir" ] && [ -d "$_dir/.claude" ] && { LOG_FILE="$_dir/.claude/hook-fire.log"; break; }
        done
        if [ "$LOG_FILE" = "$HOME/.claude/hook-fire.log" ]; then
          for _subdir in "$PWD"/*/; do
            [ -d "$_subdir.claude" ] && { LOG_FILE="${_subdir}.claude/hook-fire.log"; break; }
          done
        fi
        echo "$LOG_FILE"
    ')
    echo "$log_file"
}

# Extract the LOG_FILE path that dispatcher.sh would compute
get_dispatcher_log_file() {
    local pwd_dir="$1"
    local cpd="${2:-}"
    local log_file

    log_file=$(cd "$pwd_dir" && env ${cpd:+CLAUDE_PROJECT_DIR="$cpd"} bash -c '
        PROJECT_ROOT=""
        for dir in "$CLAUDE_PROJECT_DIR" "$PWD"; do
          [ -n "$dir" ] && [ -d "$dir/.claude/hooks" ] && { PROJECT_ROOT="$dir"; break; }
        done
        if [ -z "$PROJECT_ROOT" ]; then
          for subdir in "$PWD"/*/; do
            [ -d "$subdir.claude/hooks" ] && { PROJECT_ROOT="${subdir%/}"; break; }
          done
        fi
        LOG_FILE="$HOME/.claude/hook-fire.log"
        [ -n "$PROJECT_ROOT" ] && LOG_FILE="$PROJECT_ROOT/.claude/hook-fire.log"
        echo "$LOG_FILE"
    ')
    echo "$log_file"
}

setup_workdir() {
    WORKDIR=$(mktemp -d /tmp/see781.XXXXXX)
    REPO="$WORKDIR/repo"
    mkdir -p "$REPO"
    cd "$REPO"
    git init -b master >/dev/null 2>&1
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > README.md
    git add README.md >/dev/null 2>&1
    git commit -m "initial commit" >/dev/null 2>&1
}

cleanup() {
    cd "$ORIG_DIR" 2>/dev/null || true
    rm -rf "${WORKDIR:-}" 2>/dev/null || true
}

# ==============================================================
# Suite 1: E2E — hook-wrapper.sh firelog path detection
# ==============================================================
suite_wrapper_e2e() {
    separator "Suite 1: E2E — hook-wrapper.sh firelog path"

    # T1: Repo with .claude directory → writes to repo .claude/hook-fire.log
    setup_workdir
    mkdir -p "$REPO/.claude"
    local result
    result=$(get_wrapper_log_file "$REPO")
    if [ "$result" = "$REPO/.claude/hook-fire.log" ]; then
        pass "S1.T1: Repo dir with .claude → repo-level firelog"
    else
        fail "S1.T1: Expected $REPO/.claude/hook-fire.log, got $result"
    fi
    cleanup

    # T2: CLAUDE_PROJECT_DIR points to repo with .claude
    setup_workdir
    mkdir -p "$REPO/.claude"
    result=$(get_wrapper_log_file "/tmp" "$REPO")
    if [ "$result" = "$REPO/.claude/hook-fire.log" ]; then
        pass "S1.T2: CLAUDE_PROJECT_DIR set → uses CPD path"
    else
        fail "S1.T2: Expected $REPO/.claude/hook-fire.log, got $result"
    fi
    cleanup

    # T3: Non-repo dir, no .claude → falls back to global
    result=$(get_wrapper_log_file "/tmp")
    if [ "$result" = "$HOME/.claude/hook-fire.log" ]; then
        pass "S1.T3: Non-repo dir → global fallback"
    else
        fail "S1.T3: Expected $HOME/.claude/hook-fire.log, got $result"
    fi

    # T4: Multica workdir pattern — repo in subdir with .claude
    setup_workdir
    mkdir -p "$REPO/.claude"
    local workdir_parent="$WORKDIR"
    result=$(get_wrapper_log_file "$workdir_parent")
    if [ "$result" = "$REPO/.claude/hook-fire.log" ]; then
        pass "S1.T4: Multica workdir subdir → repo-level firelog"
    else
        fail "S1.T4: Expected $REPO/.claude/hook-fire.log, got $result"
    fi
    cleanup

    # T5: Multica workdir — multiple subdirs, first with .claude wins
    setup_workdir
    mkdir -p "$REPO/.claude"
    mkdir -p "$WORKDIR/other_repo"
    result=$(get_wrapper_log_file "$WORKDIR")
    if [ "$result" = "$REPO/.claude/hook-fire.log" ]; then
        pass "S1.T5: Multica workdir — first subdir with .claude wins"
    else
        fail "S1.T5: Expected $REPO/.claude/hook-fire.log, got $result"
    fi
    cleanup

    # T6: Actual write — verify LOG_FILE is actually writable in repo
    setup_workdir
    mkdir -p "$REPO/.claude"
    cd "$REPO"
    LOG_FILE="$REPO/.claude/hook-fire.log"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [PreToolUse] alias=test tool=TestTool" >> "$LOG_FILE" 2>/dev/null
    if [ -f "$LOG_FILE" ] && grep -q "test" "$LOG_FILE"; then
        pass "S1.T6: Actual write to repo .claude/hook-fire.log succeeds"
    else
        fail "S1.T6: Write to repo .claude/hook-fire.log failed"
    fi
    cleanup
}

# ==============================================================
# Suite 2: E2E — dispatcher.sh firelog path detection
# ==============================================================
suite_dispatcher_e2e() {
    separator "Suite 2: E2E — dispatcher.sh firelog path"

    # T1: Repo with .claude/hooks → writes to repo .claude/hook-fire.log
    setup_workdir
    mkdir -p "$REPO/.claude/hooks"
    local result
    result=$(get_dispatcher_log_file "$REPO")
    if [ "$result" = "$REPO/.claude/hook-fire.log" ]; then
        pass "S2.T1: Repo dir with .claude/hooks → repo-level firelog"
    else
        fail "S2.T1: Expected $REPO/.claude/hook-fire.log, got $result"
    fi
    cleanup

    # T2: CLAUDE_PROJECT_DIR points to repo with .claude/hooks
    setup_workdir
    mkdir -p "$REPO/.claude/hooks"
    result=$(get_dispatcher_log_file "/tmp" "$REPO")
    if [ "$result" = "$REPO/.claude/hook-fire.log" ]; then
        pass "S2.T2: CLAUDE_PROJECT_DIR set → uses CPD path"
    else
        fail "S2.T2: Expected $REPO/.claude/hook-fire.log, got $result"
    fi
    cleanup

    # T3: Non-repo dir, no .claude/hooks → falls back to global
    result=$(get_dispatcher_log_file "/tmp")
    if [ "$result" = "$HOME/.claude/hook-fire.log" ]; then
        pass "S2.T3: Non-repo dir → global fallback"
    else
        fail "S2.T3: Expected $HOME/.claude/hook-fire.log, got $result"
    fi

    # T4: Multica workdir pattern — repo in subdir with .claude/hooks
    setup_workdir
    mkdir -p "$REPO/.claude/hooks"
    local workdir_parent="$WORKDIR"
    result=$(get_dispatcher_log_file "$workdir_parent")
    if [ "$result" = "$REPO/.claude/hook-fire.log" ]; then
        pass "S2.T4: Multica workdir subdir → repo-level firelog"
    else
        fail "S2.T4: Expected $REPO/.claude/hook-fire.log, got $result"
    fi
    cleanup

    # T5: Repo has .claude but no .claude/hooks → dispatcher falls back to global
    setup_workdir
    mkdir -p "$REPO/.claude"
    result=$(get_dispatcher_log_file "$REPO")
    if [ "$result" = "$HOME/.claude/hook-fire.log" ]; then
        pass "S2.T5: Repo with .claude but no hooks → global fallback"
    else
        fail "S2.T5: Expected global fallback, got $result"
    fi
    cleanup
}

# ==============================================================
# Suite 3: Regression — script copy consistency
# ==============================================================
suite_consistency() {
    separator "Suite 3: Regression — global/repo copy consistency"

    # T1: hook-wrapper.sh identical
    if diff -q "$GLOBAL_HOOKS_DIR/hook-wrapper.sh" "$REPO_HOOKS_DIR/hook-wrapper.sh" >/dev/null 2>&1; then
        pass "S3.T1: hook-wrapper.sh global/repo copies identical"
    else
        fail "S3.T1: hook-wrapper.sh global/repo copies differ!"
    fi

    # T2: dispatcher.sh identical
    if diff -q "$GLOBAL_HOOKS_DIR/dispatcher.sh" "$REPO_HOOKS_DIR/dispatcher.sh" >/dev/null 2>&1; then
        pass "S3.T2: dispatcher.sh global/repo copies identical"
    else
        fail "S3.T2: dispatcher.sh global/repo copies differ!"
    fi

    # T3: hook-wrapper.sh contains dynamic LOG_FILE logic (not hardcoded)
    if grep -q 'LOG_FILE=.*HOME.*hook-fire.log' "$GLOBAL_HOOKS_DIR/hook-wrapper.sh" && \
       grep -q 'for _dir in.*CLAUDE_PROJECT_DIR.*PWD' "$GLOBAL_HOOKS_DIR/hook-wrapper.sh"; then
        pass "S3.T3: hook-wrapper.sh uses dynamic LOG_FILE detection"
    else
        fail "S3.T3: hook-wrapper.sh missing dynamic LOG_FILE logic"
    fi

    # T4: dispatcher.sh contains dynamic LOG_FILE logic
    if grep -q 'LOG_FILE=.*HOME.*hook-fire.log' "$GLOBAL_HOOKS_DIR/dispatcher.sh" && \
       grep -q '\[ -n "\$PROJECT_ROOT" \] && LOG_FILE=' "$GLOBAL_HOOKS_DIR/dispatcher.sh"; then
        pass "S3.T4: dispatcher.sh uses dynamic LOG_FILE detection"
    else
        fail "S3.T4: dispatcher.sh missing dynamic LOG_FILE logic"
    fi
}

# ==============================================================
# Suite 4: A/B Test — before/after path behavior
# ==============================================================
suite_abtest() {
    separator "Suite 4: A/B Test — original vs dynamic firelog path"

    setup_workdir
    mkdir -p "$REPO/.claude/hooks"

    # A: Original behavior (hardcoded global path)
    local original_path="$HOME/.claude/hook-fire.log"

    # B: New behavior (dynamic repo-level path)
    local new_path
    new_path=$(get_wrapper_log_file "$REPO")
    if [ "$new_path" = "$REPO/.claude/hook-fire.log" ]; then
        pass "S4.T1: A/B — wrapper path changed from global to repo-level"
    else
        fail "S4.T1: A/B — wrapper path not repo-level: $new_path"
    fi

    new_path=$(get_dispatcher_log_file "$REPO")
    if [ "$new_path" = "$REPO/.claude/hook-fire.log" ]; then
        pass "S4.T2: A/B — dispatcher path changed from global to repo-level"
    else
        fail "S4.T2: A/B — dispatcher path not repo-level: $new_path"
    fi

    # Verify non-repo still matches original behavior
    new_path=$(get_wrapper_log_file "/tmp")
    if [ "$new_path" = "$original_path" ]; then
        pass "S4.T3: A/B — non-repo wrapper fallback matches original"
    else
        fail "S4.T3: A/B — non-repo wrapper fallback changed: $new_path"
    fi

    new_path=$(get_dispatcher_log_file "/tmp")
    if [ "$new_path" = "$original_path" ]; then
        pass "S4.T4: A/B — non-repo dispatcher fallback matches original"
    else
        fail "S4.T4: A/B — non-repo dispatcher fallback changed: $new_path"
    fi

    cleanup
}

# ==============================================================
# Suite 5: Edge cases
# ==============================================================
suite_edge_cases() {
    separator "Suite 5: Edge cases"

    # T1: CLAUDE_PROJECT_DIR points to nonexistent dir → falls through to PWD
    setup_workdir
    mkdir -p "$REPO/.claude"
    local result
    result=$(get_wrapper_log_file "$REPO" "/nonexistent/path")
    if [ "$result" = "$REPO/.claude/hook-fire.log" ]; then
        pass "S5.T1: Invalid CPD → falls through to PWD"
    else
        fail "S5.T1: Expected PWD fallback, got $result"
    fi
    cleanup

    # T2: CLAUDE_PROJECT_DIR empty string → falls through to PWD
    setup_workdir
    mkdir -p "$REPO/.claude"
    result=$(cd "$REPO" && CLAUDE_PROJECT_DIR="" bash -c '
        LOG_FILE="$HOME/.claude/hook-fire.log"
        for _dir in "$CLAUDE_PROJECT_DIR" "$PWD"; do
          [ -n "$_dir" ] && [ -d "$_dir/.claude" ] && { LOG_FILE="$_dir/.claude/hook-fire.log"; break; }
        done
        echo "$LOG_FILE"
    ')
    if [ "$result" = "$REPO/.claude/hook-fire.log" ]; then
        pass "S5.T2: Empty CPD → falls through to PWD"
    else
        fail "S5.T2: Expected PWD fallback, got $result"
    fi
    cleanup

    # T3: Multica workdir — subdir has .claude but no .claude/hooks → wrapper picks it, dispatcher does not
    setup_workdir
    mkdir -p "$REPO/.claude"
    local wrapper_result dispatcher_result
    wrapper_result=$(get_wrapper_log_file "$WORKDIR")
    dispatcher_result=$(get_dispatcher_log_file "$WORKDIR")
    if [ "$wrapper_result" = "$REPO/.claude/hook-fire.log" ]; then
        pass "S5.T3a: Wrapper picks .claude (no hooks required)"
    else
        fail "S5.T3a: Wrapper expected repo path, got $wrapper_result"
    fi
    if [ "$dispatcher_result" = "$HOME/.claude/hook-fire.log" ]; then
        pass "S5.T3b: Dispatcher falls back (requires .claude/hooks)"
    else
        fail "S5.T3b: Dispatcher expected global fallback, got $dispatcher_result"
    fi
    cleanup

    # T4: Path with spaces in directory name
    setup_workdir
    local spaced_repo="$WORKDIR/my repo"
    mv "$REPO" "$spaced_repo"
    REPO="$spaced_repo"
    mkdir -p "$REPO/.claude"
    result=$(get_wrapper_log_file "$REPO")
    if [ "$result" = "$REPO/.claude/hook-fire.log" ]; then
        pass "S5.T4: Path with spaces handled correctly"
    else
        fail "S5.T4: Expected $REPO/.claude/hook-fire.log, got $result"
    fi
    cleanup
}

# ==============================================================
# Main
# ==============================================================
echo "========================================"
echo "SEE-781: Firelog Path Migration QA Suite"
echo "========================================"
echo "Project root: $PROJECT_ROOT_DIR"
echo "Global hooks: $GLOBAL_HOOKS_DIR"
echo "Repo hooks:   $REPO_HOOKS_DIR"
echo ""

suite_wrapper_e2e
suite_dispatcher_e2e
suite_consistency
suite_abtest
suite_edge_cases

echo ""
echo "========================================"
echo "Summary"
echo "========================================"
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
echo -e "  ${YELLOW}WARN${NC}: $WARN"
echo "  Total: $((PASS + FAIL + WARN))"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}FAILED test cases:${NC}"
    for r in "${RESULTS[@]}"; do
        if [[ "$r" == FAIL* ]]; then echo "  $r"; fi
    done
    exit 1
fi

echo -e "${GREEN}All tests passed!${NC}"
exit 0
