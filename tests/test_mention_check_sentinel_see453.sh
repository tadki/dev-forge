#!/bin/bash
# test_mention_check_sentinel_see453.sh
# QA Tests for SEE-453: sentinel mechanism across all comment input paths
#
# Validates that Phase1 (NO_MENTION) and Phase2 (BLOCK) sentinels fire
# exactly once per TASK_ID regardless of input mode (--content,
# --content-stdin, --content-file), and that the three modes share
# sentinel state under the same task.
#
# Related Issue: SEE-453
# Test Type: Functional / Unit / Regression
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

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SCRIPT="$PROJECT_ROOT/hooks/scripts/mention-check.sh"

# Unique task IDs per scenario (PID-suffixed for isolation)
TASK_S1="see453-s1-$$"  # Scenario 1: NO_MENTION sentinel
TASK_S2="see453-s2-$$"  # Scenario 2: BLOCK sentinel
TASK_S3="see453-s3-$$"  # Scenario 3: Cross-mode sharing
TASK_S4="see453-s4-$$"  # Scenario 4: Reranker skip logic

# Sentinel path helpers
sp()  { echo "/tmp/mention-check-pass-$1"; }
snm() { echo "/tmp/mention-check-no-mention-$1"; }
sb()  { echo "/tmp/mention-check-block-$1"; }

ALL_TASKS=("$TASK_S1" "$TASK_S2" "$TASK_S3" "$TASK_S4")

cleanup_all_sentinels() {
    for tid in "${ALL_TASKS[@]}"; do
        rm -f "$(sp "$tid")" "$(snm "$tid")" "$(sb "$tid")"
    done
}

cleanup_all_sentinels

run_hook() {
    local task_id="$1"
    local input="$2"
    local stdout_f stderr_f
    stdout_f=$(mktemp /tmp/see453-stdout.XXXXXX)
    stderr_f=$(mktemp /tmp/see453-stderr.XXXXXX)

    printf '%s' "$input" | MULTICA_TASK_ID="$task_id" bash "$HOOK_SCRIPT" > "$stdout_f" 2> "$stderr_f"
    HOOK_EXIT=$?
    HOOK_STDOUT=$(cat "$stdout_f")
    HOOK_STDERR=$(cat "$stderr_f")

    rm -f "$stdout_f" "$stderr_f"
}

# --- Assertions ---

assert_blocked() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
        pass "$label — blocked (deny)"
    else
        fail "$label — not blocked. stdout: '$HOOK_STDOUT'"
    fi
}

assert_passthrough() {
    local label="$1"
    local input="$2"
    if [ "$HOOK_STDOUT" = "$input" ]; then
        pass "$label — passthrough (output == input)"
    elif echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
        fail "$label — unexpectedly blocked. stdout: '$HOOK_STDOUT'"
    else
        pass "$label — passthrough (no deny in output)"
    fi
}

assert_sentinel_exists() {
    local file="$1"
    local label="$2"
    if [ -f "$file" ]; then
        pass "$label — sentinel exists: $(basename "$file")"
    else
        fail "$label — sentinel missing: $file"
    fi
}

assert_sentinel_not_exists() {
    local file="$1"
    local label="$2"
    if [ ! -f "$file" ]; then
        pass "$label — sentinel correctly absent: $(basename "$file")"
    else
        fail "$label — sentinel unexpectedly exists: $file"
    fi
}

# --- Input builders for the three modes ---

# Mode: --content "..."
build_content_input() {
    local body="$1"
    echo "{\"tool_input\":{\"command\":\"multica issue comment add SEE-999 --content \\\"${body}\\\"\"}}"
}

# Mode: --content-stdin with heredoc
build_heredoc_input() {
    local body="$1"
    echo "{\"tool_input\":{\"command\":\"multica issue comment add SEE-999 --content-stdin <<-EOF\n${body}\nEOF\"}}"
}

# Mode: --content-file <path>
build_file_input() {
    local file_path="$1"
    echo "{\"tool_input\":{\"command\":\"multica issue comment add SEE-999 --content-file ${file_path}\"}}"
}

# --- Test content ---

# No-mention content (triggers Phase 0 → NO_MENTION)
NO_MENTION_BODY='这是一条没有mention的普通评论'

# Mention-bearing content with reference-like sentence (passes after PHASE2 removal)
MENTION_BODY='我同意 Atlas 的看法，这个方案确实可行 [@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5)'

# PASS content: mention + action request sentence (passes all phases)
PASS_BODY='[@Bachi](mention://agent/a5c250e8-7257-466e-b45a-03f995c7206c) 请处理这个任务工作'

# --- Temp content files ---
NO_MENTION_FILE="/tmp/see453-test-content-no-mention-$$.txt"
MENTION_FILE="/tmp/see453-test-content-mention-$$.txt"
CROSS_FILE_A="/tmp/see453-test-content-cross-a-$$.txt"
CROSS_FILE_B="/tmp/see453-test-content-cross-b-$$.txt"

echo "$NO_MENTION_BODY" > "$NO_MENTION_FILE"
echo "$MENTION_BODY" > "$MENTION_FILE"
echo "文件评论无mention交叉验证" > "$CROSS_FILE_A"
echo "$MENTION_BODY" > "$CROSS_FILE_B"

echo "============================================"
echo "  SEE-453 Sentinel Full-Path QA Tests"
echo "  Date: $(date -Iseconds)"
echo "  Author: Revy (QA Agent)"
echo "  Branch: $(git branch --show-current 2>/dev/null || echo 'unknown')"
echo "============================================"

#####################################################################
# Scenario 1: Phase1 sentinel (NO_MENTION) — each input path fires once
#####################################################################
separator "Scenario 1: NO_MENTION sentinel — all input paths"

# S1a: --content sends no-mention comment → first BLOCK + creates NO_MENTION sentinel
S1_CONTENT_INPUT=$(build_content_input "$NO_MENTION_BODY")
run_hook "$TASK_S1" "$S1_CONTENT_INPUT"
assert_blocked "S1a: --content no-mention → first-time BLOCK"
assert_sentinel_exists "$(snm "$TASK_S1")" "S1a: NO_MENTION sentinel created by --content"
assert_sentinel_not_exists "$(sp "$TASK_S1")" "S1a: PASS sentinel NOT created (was blocked)"
assert_sentinel_not_exists "$(sb "$TASK_S1")" "S1a: BLOCK sentinel NOT created (Phase 0 only)"

# S1b: --content-stdin sends no-mention → still BLOCKED
# SEE-1333 D2（Owner 裁定）：移除 NO_MENTION fast-path，无 mention 逐条拦截
S1_HEREDOC_INPUT=$(build_heredoc_input "$NO_MENTION_BODY")
run_hook "$TASK_S1" "$S1_HEREDOC_INPUT"
assert_blocked "S1b: --content-stdin no-mention → still BLOCKED (SEE-1333 D2 逐条拦截)"

# S1c: PASS sentinel should NOT exist (no-mention never passes → no PASS write)
assert_sentinel_not_exists "$(sp "$TASK_S1")" "S1c: PASS sentinel NOT created (D2: no-mention never passes)"

# S1d: --content-file sends no-mention → still BLOCKED
S1_FILE_INPUT=$(build_file_input "$NO_MENTION_FILE")
run_hook "$TASK_S1" "$S1_FILE_INPUT"
assert_blocked "S1d: --content-file no-mention → still BLOCKED (SEE-1333 D2 逐条拦截)"

# S1e: NO_MENTION sentinel persists (no PASS creation → no reset)
NM_COUNT=$(find /tmp -maxdepth 1 -name "mention-check-no-mention-${TASK_S1}" 2>/dev/null | wc -l)
if [ "$NM_COUNT" -eq 1 ]; then
    pass "S1e: NO_MENTION sentinel persists (D2: no PASS reset)"
else
    fail "S1e: expected 1 NO_MENTION sentinel, found $NM_COUNT"
fi

# S1f: Verify 0 PASS sentinel
SP_COUNT=$(find /tmp -maxdepth 1 -name "mention-check-pass-${TASK_S1}" 2>/dev/null | wc -l)
if [ "$SP_COUNT" -eq 0 ]; then
    pass "S1f: no PASS sentinel file (D2: no-mention never passes)"
else
    fail "S1f: expected 0 PASS sentinel, found $SP_COUNT"
fi

#####################################################################
# Scenario 2: Mention-bearing content passes through all input paths
#####################################################################
separator "Scenario 2: mention-bearing content — all input paths"

# S2a: --content sends mention-bearing content → passthrough + PASS sentinel
S2_CONTENT_INPUT=$(build_content_input "$MENTION_BODY")
run_hook "$TASK_S2" "$S2_CONTENT_INPUT"
assert_passthrough "S2a: --content mention-bearing content → passthrough" "$S2_CONTENT_INPUT"
assert_sentinel_exists "$(sp "$TASK_S2")" "S2a: PASS sentinel created by --content"
assert_sentinel_not_exists "$(sb "$TASK_S2")" "S2a: BLOCK sentinel NOT created (PHASE2 removed)"
assert_sentinel_not_exists "$(snm "$TASK_S2")" "S2a: NO_MENTION sentinel NOT created (content has mention)"

# S2b: --content-stdin sends mention-bearing content → passthrough (PASS sentinel exists)
S2_HEREDOC_INPUT=$(build_heredoc_input "$MENTION_BODY")
run_hook "$TASK_S2" "$S2_HEREDOC_INPUT"
assert_passthrough "S2b: --content-stdin mention-bearing content → passthrough (PASS sentinel exists)" "$S2_HEREDOC_INPUT"

# S2c: PASS sentinel persists
assert_sentinel_exists "$(sp "$TASK_S2")" "S2c: PASS sentinel persists"

# S2d: --content-file sends mention-bearing content → passthrough (PASS sentinel exists)
S2_FILE_INPUT=$(build_file_input "$MENTION_FILE")
run_hook "$TASK_S2" "$S2_FILE_INPUT"
assert_passthrough "S2d: --content-file mention-bearing content → passthrough (PASS sentinel exists)" "$S2_FILE_INPUT"

# S2e: Verify BLOCK sentinel never created
BL_COUNT=$(find /tmp -maxdepth 1 -name "mention-check-block-${TASK_S2}" 2>/dev/null | wc -l)
if [ "$BL_COUNT" -eq 0 ]; then
    pass "S2e: no BLOCK sentinel created (PHASE2 removed)"
else
    fail "S2e: expected 0 BLOCK sentinel, found $BL_COUNT"
fi

#####################################################################
# Scenario 3: Three input modes share sentinel state
#####################################################################
separator "Scenario 3: Cross-mode sentinel sharing"

# Recreate content files (cleanup may have run between scenarios)
echo "$NO_MENTION_BODY" > "$NO_MENTION_FILE"
echo "$MENTION_BODY" > "$MENTION_FILE"
echo "文件评论无mention交叉验证" > "$CROSS_FILE_A"
echo "$MENTION_BODY" > "$CROSS_FILE_B"

# --- 3A: NO_MENTION sentinel sharing across modes ---
cleanup_all_sentinels

# Step 1: --content-file creates the NO_MENTION sentinel
S3A_FILE_INPUT=$(build_file_input "$CROSS_FILE_A")
run_hook "$TASK_S3" "$S3A_FILE_INPUT"
assert_blocked "S3A-1: --content-file creates NO_MENTION sentinel"
assert_sentinel_exists "$(snm "$TASK_S3")" "S3A-1: NO_MENTION sentinel from --content-file"

# Step 2: --content no-mention → still BLOCKED (SEE-1333 D2 逐条拦截)
S3A_CONTENT_INPUT=$(build_content_input "评论无mention交叉A")
run_hook "$TASK_S3" "$S3A_CONTENT_INPUT"
assert_blocked "S3A-2: --content no-mention → still BLOCKED (SEE-1333 D2)"

# Step 3: NO_MENTION persists, no PASS created
assert_sentinel_not_exists "$(sp "$TASK_S3")" "S3A-3: no PASS sentinel (D2: no-mention never passes)"
assert_sentinel_exists "$(snm "$TASK_S3")" "S3A-3: NO_MENTION sentinel persists (D2: no PASS reset)"

# Step 4: --content-stdin with no mention → still BLOCKED
S3A_HEREDOC_INPUT=$(build_heredoc_input "heredoc评论无mention交叉A")
run_hook "$TASK_S3" "$S3A_HEREDOC_INPUT"
assert_blocked "S3A-4: --content-stdin no-mention → still BLOCKED (SEE-1333 D2)"

# Step 5: Verify single NO_MENTION sentinel persisted and no PASS
NM_COUNT=$(find /tmp -maxdepth 1 -name "mention-check-no-mention-${TASK_S3}" 2>/dev/null | wc -l)
SP_COUNT=$(find /tmp -maxdepth 1 -name "mention-check-pass-${TASK_S3}" 2>/dev/null | wc -l)
if [ "$NM_COUNT" -eq 1 ] && [ "$SP_COUNT" -eq 0 ]; then
    pass "S3A-5: single NO_MENTION sentinel, no PASS sentinel after cross-mode no-mention calls (D2)"
else
    fail "S3A-5: expected 1 NO_MENTION and 0 PASS sentinel, found NO_MENTION=$NM_COUNT PASS=$SP_COUNT"
fi

# --- 3B: Mention-bearing content sharing across modes ---
cleanup_all_sentinels

# Step 1: --content mention-bearing → creates PASS sentinel
S3B_CONTENT_INPUT=$(build_content_input "$MENTION_BODY")
run_hook "$TASK_S3" "$S3B_CONTENT_INPUT"
assert_passthrough "S3B-1: --content mention-bearing creates PASS sentinel" "$S3B_CONTENT_INPUT"
assert_sentinel_exists "$(sp "$TASK_S3")" "S3B-1: PASS sentinel from --content"
assert_sentinel_not_exists "$(sb "$TASK_S3")" "S3B-1: BLOCK sentinel NOT created"

# Step 2: --content-stdin shares PASS sentinel → passthrough
S3B_HEREDOC_INPUT=$(build_heredoc_input "$MENTION_BODY")
run_hook "$TASK_S3" "$S3B_HEREDOC_INPUT"
assert_passthrough "S3B-2: --content-stdin shares PASS sentinel → passthrough" "$S3B_HEREDOC_INPUT"

# Step 3: Remove PASS sentinel to test --content-file
rm -f "$(sp "$TASK_S3")"

# Step 4: --content-file mention-bearing → creates PASS sentinel again
S3B_FILE_INPUT=$(build_file_input "$CROSS_FILE_B")
run_hook "$TASK_S3" "$S3B_FILE_INPUT"
assert_passthrough "S3B-4: --content-file mention-bearing → passthrough" "$S3B_FILE_INPUT"
assert_sentinel_exists "$(sp "$TASK_S3")" "S3B-4: PASS sentinel from --content-file"

# Step 5: Verify no BLOCK sentinel was ever created
BL_COUNT=$(find /tmp -maxdepth 1 -name "mention-check-block-${TASK_S3}" 2>/dev/null | wc -l)
if [ "$BL_COUNT" -eq 0 ]; then
    pass "S3B-5: no BLOCK sentinel created across all three modes"
else
    fail "S3B-5: expected 0 BLOCK sentinel, found $BL_COUNT"
fi

# --- 3C: Mixed sentinel sharing (NO_MENTION from one mode, mention content from another) ---
cleanup_all_sentinels

# Step 1: --content no-mention → creates NO_MENTION sentinel
S3C_CONTENT_INPUT=$(build_content_input "$NO_MENTION_BODY")
run_hook "$TASK_S3" "$S3C_CONTENT_INPUT"
assert_blocked "S3C-1: --content no-mention creates NO_MENTION sentinel"
assert_sentinel_exists "$(snm "$TASK_S3")" "S3C-1: NO_MENTION sentinel created"

# Step 2: --content-file with no-mention content → still BLOCKED (SEE-1333 D2 逐条拦截)
rm -f "$(sp "$TASK_S3")"

S3C_FILE_INPUT=$(build_file_input "$NO_MENTION_FILE")
run_hook "$TASK_S3" "$S3C_FILE_INPUT"
assert_blocked "S3C-2: --content-file no-mention → still BLOCKED (SEE-1333 D2)"

# Step 3: Now heredoc no-mention → also BLOCKED (no sentinel-based passthrough)
S3C_HEREDOC_INPUT=$(build_heredoc_input "$NO_MENTION_BODY")
run_hook "$TASK_S3" "$S3C_HEREDOC_INPUT"
assert_blocked "S3C-3: --content-stdin no-mention → still BLOCKED (SEE-1333 D2)"

#####################################################################
# Scenario 4: Mention-bearing content always passes (PHASE2 removed)
#####################################################################
separator "Scenario 4: mention-bearing content always passes"

# Verify direct call-out mention passes
CALLOUT_BODY='[@Bachi](mention://agent/a5c250e8-7257-466e-b45a-03f995c7206c)'
S4_CALLOUT_INPUT=$(build_content_input "$CALLOUT_BODY")
run_hook "$TASK_S4" "$S4_CALLOUT_INPUT"
assert_passthrough "S4a: pure call-out mention passes (no sentences to check)" "$S4_CALLOUT_INPUT"
assert_sentinel_exists "$(sp "$TASK_S4")" "S4a: PASS sentinel created for pure call-out"

# Verify reference-like mention-bearing content also passes
cleanup_all_sentinels
S4_MENTION_INPUT=$(build_content_input "$MENTION_BODY")
run_hook "$TASK_S4" "$S4_MENTION_INPUT"
assert_passthrough "S4b: mention-bearing content passes without reranker (PHASE2 removed)" "$S4_MENTION_INPUT"
assert_sentinel_exists "$(sp "$TASK_S4")" "S4b: PASS sentinel created for mention-bearing content"
assert_sentinel_not_exists "$(sb "$TASK_S4")" "S4b: BLOCK sentinel NOT created"

#####################################################################
# Cleanup
#####################################################################
cleanup_all_sentinels
rm -f "$NO_MENTION_FILE" "$MENTION_FILE" "$CROSS_FILE_A" "$CROSS_FILE_B"

#####################################################################
# SUMMARY
#####################################################################
separator "Summary"

echo ""
echo -e "${CYAN}Results:${NC}"
echo -e "  ${GREEN}Passed:${NC}    $PASS"
echo -e "  ${RED}Failed:${NC}    $FAIL"
echo -e "  ${YELLOW}Skipped:${NC}    $SKIP"
echo ""

TOTAL=$((PASS + FAIL + SKIP))
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
