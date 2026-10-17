#!/bin/bash
# test_see472_regression.sh
# Comprehensive regression test for SEE-472
#
# Part A: mention-check.sh sentinel mechanism
#   - Sentinel creation timing (NO_MENTION / BLOCK / PASS, three-way independent)
#   - Mutual exclusivity: ANY sentinel exists → bash early-exit (entire hook skipped)
#   - Full-path comment flow (Phase 0 → Phase 1 → Phase 2)
#   - Task-based isolation (different TASK_ID don't interfere)
#   - Cross-content-mode sentinel sharing
#
# Part B: auto-pr-on-stop.sh comment improvements
#   - Comment has NO valid mention links (HTML comment wrapping)
#   - Comment metadata correctness (PR number, title, branch, commit count, list)
#   - content-stdin heredoc transmission correctness
#
# Related Issue: SEE-472
# Test Type: Regression / Functional / Integration
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

PROJECT_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MCH_HOOK="$PROJECT_ROOT/hooks/scripts/mention-check.sh"
APS_HOOK="$PROJECT_ROOT/hooks/scripts/auto-pr-on-stop.sh"

# Sentinel path helpers
sp()  { echo "/tmp/mention-check-pass-$1"; }
snm() { echo "/tmp/mention-check-no-mention-$1"; }
sb()  { echo "/tmp/mention-check-block-$1"; }

run_mch() {
    local task_id="$1"
    local input="$2"
    local stdout_f stderr_f
    stdout_f=$(mktemp /tmp/see472-mch-stdout.XXXXXX)
    stderr_f=$(mktemp /tmp/see472-mch-stderr.XXXXXX)

    printf '%s' "$input" | MULTICA_TASK_ID="$task_id" bash "$MCH_HOOK" > "$stdout_f" 2> "$stderr_f"
    MCH_EXIT=$?
    MCH_STDOUT=$(cat "$stdout_f")
    MCH_STDERR=$(cat "$stderr_f")

    rm -f "$stdout_f" "$stderr_f"
}

assert_mch_blocked() {
    local label="$1"
    if echo "$MCH_STDOUT" | grep -q '"permissionDecision"'; then
        pass "$label — blocked (deny)"
    else
        fail "$label — not blocked. stdout: '$MCH_STDOUT'"
    fi
}

assert_mch_passthrough() {
    local label="$1"
    local input="$2"
    if [ "$MCH_STDOUT" = "$input" ]; then
        pass "$label — passthrough (output == input)"
    elif echo "$MCH_STDOUT" | grep -q '"permissionDecision"'; then
        fail "$label — unexpectedly blocked. stdout: '$MCH_STDOUT'"
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
        pass "$label — sentinel absent: $(basename "$file")"
    else
        fail "$label — sentinel unexpectedly exists: $file"
    fi
}

cleanup_mch_sentinels() {
    rm -f /tmp/mention-check-{pass,no-mention,block}-see472-*
}

cleanup_mch_sentinels

# --- Input builders ---

build_content_input() {
    local body="$1"
    echo "{\"tool_input\":{\"command\":\"multica issue comment add SEE-999 --content \\\"${body}\\\"\"}}"
}

build_heredoc_input() {
    local body="$1"
    echo "{\"tool_input\":{\"command\":\"multica issue comment add SEE-999 --content-stdin <<-EOF\n${body}\nEOF\"}}"
}

build_file_input() {
    local file_path="$1"
    echo "{\"tool_input\":{\"command\":\"multica issue comment add SEE-999 --content-file ${file_path}\"}}"
}

# --- Test content ---
NO_MENTION_BODY='这是一条没有mention的普通评论'
MENTION_BODY='我同意 Atlas 的看法，这个方案确实可行 [@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5)'
PASS_BODY='[@Bachi](mention://agent/a5c250e8-7257-466e-b45a-03f995c7206c) 请处理这个任务工作'
CALLOUT_BODY='[@Bachi](mention://agent/a5c250e8-7257-466e-b45a-03f995c7206c)'

# Task IDs for Part A
T0="see472-t0-$$"
T1="see472-t1-$$"
T2="see472-t2-$$"
T3="see472-t3-$$"
T4="see472-t4-$$"
T5="see472-t5-$$"
T6="see472-t6-$$"
T7="see472-t7-$$"
T8="see472-t8-$$"
T9="see472-t9-$$"

# #############################################################
# Header
# #############################################################
echo "============================================"
echo "  SEE-472 Comprehensive Regression Tests"
echo "  Date: $(date -Iseconds)"
echo "  Author: Revy (QA Agent)"
echo "  Branch: $(git branch --show-current 2>/dev/null || echo 'unknown')"
echo "============================================"

assert_file_exists() {
    local filepath="$1"
    local label="$2"
    if [ -f "$filepath" ]; then
        pass "$label — file exists: $filepath"
    else
        fail "$label — file NOT found: $filepath"
    fi
}

assert_file_exists "$MCH_HOOK" "Pre-check: mention-check.sh exists"
assert_file_exists "$APS_HOOK" "Pre-check: auto-pr-on-stop.sh exists"

#####################################################################
# PART A1: Sentinel creation timing — three-way independent
#####################################################################
separator "A1: Sentinel creation timing — three-way independent"

# A1a: First no-mention → NO_MENTION created, PASS/BLOCK absent
NO_MENTION_INPUT=$(build_content_input "$NO_MENTION_BODY")
run_mch "$T0" "$NO_MENTION_INPUT"
assert_mch_blocked "A1a: first no-mention → blocked"
assert_sentinel_exists "$(snm "$T0")" "A1a: NO_MENTION sentinel created"
assert_sentinel_not_exists "$(sp "$T0")" "A1a: PASS sentinel NOT created"
assert_sentinel_not_exists "$(sb "$T0")" "A1a: BLOCK sentinel NOT created"

# A1b: First pass → PASS created, NO_MENTION/BLOCK absent
cleanup_mch_sentinels
PASS_INPUT=$(build_content_input "$PASS_BODY")
run_mch "$T1" "$PASS_INPUT"
assert_mch_passthrough "A1b: first valid mention → passthrough" "$PASS_INPUT"
assert_sentinel_exists "$(sp "$T1")" "A1b: PASS sentinel created"
assert_sentinel_not_exists "$(snm "$T1")" "A1b: NO_MENTION sentinel NOT created"
assert_sentinel_not_exists "$(sb "$T1")" "A1b: BLOCK sentinel NOT created"

# A1c: First mention-bearing content → PASS created, BLOCK/NO_MENTION absent (PHASE2 removed)
cleanup_mch_sentinels
MENTION_INPUT=$(build_content_input "$MENTION_BODY")
run_mch "$T2" "$MENTION_INPUT"
assert_mch_passthrough "A1c: first mention-bearing comment → passthrough" "$MENTION_INPUT"
assert_sentinel_exists "$(sp "$T2")" "A1c: PASS sentinel created"
assert_sentinel_not_exists "$(sb "$T2")" "A1c: BLOCK sentinel NOT created"
assert_sentinel_not_exists "$(snm "$T2")" "A1c: NO_MENTION sentinel NOT created"

# A1d: Pure call-out → PASS created
cleanup_mch_sentinels
CALLOUT_INPUT=$(build_content_input "$CALLOUT_BODY")
run_mch "$T3" "$CALLOUT_INPUT"
assert_mch_passthrough "A1d: pure call-out → passthrough" "$CALLOUT_INPUT"
assert_sentinel_exists "$(sp "$T3")" "A1d: PASS sentinel created"

#####################################################################
# PART A2: Sentinel state does not skip Node.js execution
#####################################################################
separator "A2: sentinel state does not skip Node.js execution"

# A2a: PASS sentinel exists → second valid comment still processed
cleanup_mch_sentinels
touch "$(sp "$T4")"
PASS_INPUT2=$(build_content_input "$PASS_BODY")
run_mch "$T4" "$PASS_INPUT2"
assert_mch_passthrough "A2a: PASS sentinel → second valid comment passthrough" "$PASS_INPUT2"
rm -f "$(sp "$T4")"

# A2b: NO_MENTION sentinel exists → no-mention still blocked if sentinel removed
# Pre-create NO_MENTION, remove it, then send no-mention → should block
cleanup_mch_sentinels
run_mch "$T5" "$(build_content_input "$NO_MENTION_BODY")"
assert_mch_blocked "A2b: first no-mention comment blocked"
assert_sentinel_exists "$(snm "$T5")" "A2b: NO_MENTION sentinel created"
rm -f "$(snm "$T5")"
run_mch "$T5" "$(build_content_input "$NO_MENTION_BODY")"
assert_mch_blocked "A2b: no-mention blocked after sentinel removed"

# A2c: Pre-existing BLOCK sentinel is ignored (PHASE2 removed)
cleanup_mch_sentinels
touch "$(sb "$T6")"
NO_MENTION_INPUT=$(build_content_input "$NO_MENTION_BODY")
run_mch "$T6" "$NO_MENTION_INPUT"
assert_mch_blocked "A2c: pre-existing BLOCK sentinel ignored, no-mention still blocked"
assert_sentinel_exists "$(snm "$T6")" "A2c: NO_MENTION sentinel created"
rm -f "$(sb "$T6")"

# A2d: PASS sentinel persists and protects subsequent comments
cleanup_mch_sentinels
touch "$(sp "$T7")"
touch "$(snm "$T7")"
run_mch "$T7" "$(build_content_input "$NO_MENTION_BODY")"
assert_mch_passthrough "A2d: PASS sentinel allows no-mention passthrough" "$(build_content_input "$NO_MENTION_BODY")"
rm -f "$(sp "$T7")" "$(snm "$T7")"

# A2e: Verify NO_MENTION sentinel allows subsequent passthrough and creates PASS
cleanup_mch_sentinels
run_mch "$T8" "$(build_content_input "$NO_MENTION_BODY")"
assert_mch_blocked "A2e: first no-mention blocked"
assert_sentinel_exists "$(snm "$T8")" "A2e: NO_MENTION sentinel created"
run_mch "$T8" "$(build_content_input "$NO_MENTION_BODY")"
assert_mch_passthrough "A2e: second no-mention passthrough (NO_MENTION sentinel)" "$(build_content_input "$NO_MENTION_BODY")"
assert_sentinel_exists "$(sp "$T8")" "A2e: PASS sentinel created after sentinel-allowed pass"

# A2f: Verify mention-bearing content passes without creating NO_MENTION/BLOCK
cleanup_mch_sentinels
run_mch "$T8" "$MENTION_INPUT"
assert_mch_passthrough "A2f: mention-bearing content passthrough (PHASE2 removed)" "$MENTION_INPUT"
assert_sentinel_exists "$(sp "$T8")" "A2f: PASS sentinel created"
assert_sentinel_not_exists "$(sb "$T8")" "A2f: BLOCK sentinel NOT created"

#####################################################################
# PART A3: Full-path comment flow (Phase 0 → Phase 1)
#####################################################################
separator "A3: Full-path comment flow (Phase 0 → Phase 1)"

# A3a: Phase 0 — no mention → Phase 0 gate blocks
#        This is tested in A1a

# A3b: Phase 1 — mention exists, sentence extraction, direct call-out → passes
#        This is tested in A1d (pure call-out passes Phase 1)

# A3c: Phase 1 — mention + action request → PASS
#        This is tested in A1b

# A3d: Phase 2 removed — mention + reference sentence → PASS
#        This is tested in A1c

# A3e: Full-path scenario — comment with mixed content
cleanup_mch_sentinels
# First call: no-mention → Phase 0 blocks → NO_MENTION sentinel
NO_MENT=$(build_content_input "$NO_MENTION_BODY")
run_mch "$T9" "$NO_MENT"
assert_mch_blocked "A3e-1: first call no-mention → Phase 0 blocks"
assert_sentinel_exists "$(snm "$T9")" "A3e-1: NO_MENTION sentinel created"

# Second call: valid action mention → passthrough (NO_MENTION sentinel exists)
PASS_CONTENT=$(build_content_input "$PASS_BODY")
run_mch "$T9" "$PASS_CONTENT"
assert_mch_passthrough "A3e-2: second call → passthrough (NO_MENTION sentinel exists)" "$PASS_CONTENT"
# PASS sentinel now created (Node.js finally block)
assert_sentinel_exists "$(sp "$T9")" "A3e-2: PASS sentinel created"

# Third call: same no-mention → still passthrough (PASS sentinel)
run_mch "$T9" "$NO_MENT"
assert_mch_passthrough "A3e-3: third call → still passthrough" "$NO_MENT"

# Fourth call: mention-bearing content → passthrough (PASS sentinel exists)
MENTION_CONTENT=$(build_content_input "$MENTION_BODY")
run_mch "$T9" "$MENTION_CONTENT"
assert_mch_passthrough "A3e-4: mention-bearing content → passthrough (PASS sentinel exists)" "$MENTION_CONTENT"

#####################################################################
# PART A4: Cross-content-mode sentinel sharing
#####################################################################
separator "A4: Cross-content-mode sentinel sharing"

# A4a: --content blocked → --content-stdin uses sentinel
cleanup_mch_sentinels
T_C="see472-cross-$$"
CONTENT_INPUT=$(build_content_input "$NO_MENTION_BODY")
run_mch "$T_C" "$CONTENT_INPUT"
assert_mch_blocked "A4a-1: --content creates NO_MENTION sentinel"
assert_sentinel_exists "$(snm "$T_C")" "A4a-1: NO_MENTION sentinel from --content"

# Switch to heredoc — same sentinel protects
HEREDOC_INPUT=$(build_heredoc_input "$NO_MENTION_BODY")
run_mch "$T_C" "$HEREDOC_INPUT"
assert_mch_passthrough "A4a-2: --content-stdin protected by --content's sentinel" "$HEREDOC_INPUT"

# Switch to file — same sentinel protects
T_FILE="/tmp/see472-cross-content-$$.txt"
echo "评论无mention" > "$T_FILE"
FILE_INPUT=$(build_file_input "$T_FILE")
run_mch "$T_C" "$FILE_INPUT"
assert_mch_passthrough "A4a-3: --content-file protected by shared sentinel" "$FILE_INPUT"
rm -f "$T_FILE"

# A4b: here-string → same sentinel protects
cleanup_mch_sentinels
T_H="see472-hs-$$"
HS_INPUT='{"tool_input":{"command":"multica issue comment add SEE-999 --content-stdin <<< \"普通评论\""}}'
run_mch "$T_H" "$HS_INPUT"
assert_mch_blocked "A4b-1: here-string no-mention → blocked"
assert_sentinel_exists "$(snm "$T_H")" "A4b-1: NO_MENTION sentinel from here-string"

# Second call with same content but different mode → passthrough
CONTENT2=$(build_content_input "$NO_MENTION_BODY")
run_mch "$T_H" "$CONTENT2"
assert_mch_passthrough "A4b-2: --content uses here-string's sentinel" "$CONTENT2"

# A4c: Verify sentinel state after 3 cross-mode calls
# With the two-phase hook, the first no-mention creates NO_MENTION, the second
# no-mention reuses it and creates PASS (clearing NO_MENTION), and subsequent
# calls pass via PASS. We just ensure no duplicate sentinels are created.
cleanup_mch_sentinels
T_COUNT="see472-count-$$"
run_mch "$T_COUNT" "$(build_content_input "$NO_MENTION_BODY")"
run_mch "$T_COUNT" "$(build_heredoc_input "$NO_MENTION_BODY")"
run_mch "$T_COUNT" "$(build_content_input "$NO_MENTION_BODY")"
NM_COUNT=$(find /tmp -maxdepth 1 -name "mention-check-no-mention-${T_COUNT}" 2>/dev/null | wc -l)
SP_COUNT=$(find /tmp -maxdepth 1 -name "mention-check-pass-${T_COUNT}" 2>/dev/null | wc -l)
if [ "$NM_COUNT" -eq 0 ] && [ "$SP_COUNT" -eq 1 ]; then
    pass "A4c: exactly 1 PASS sentinel and 0 NO_MENTION after 3 cross-mode calls"
else
    fail "A4c: expected 1 PASS and 0 NO_MENTION sentinel, found PASS=$SP_COUNT NO_MENTION=$NM_COUNT"
fi

#####################################################################
# PART A5: Task-based isolation
#####################################################################
separator "A5: Task-based isolation"

cleanup_mch_sentinels
T_ISOL_A="see472-isol-a-$$"
T_ISOL_B="see472-isol-b-$$"

# Create sentinels for Task A
touch "$(sp "$T_ISOL_A")"
touch "$(snm "$T_ISOL_A")"

# Verify Task B has no sentinels
assert_sentinel_not_exists "$(sp "$T_ISOL_B")" "A5a: TASK_B PASS sentinel absent"
assert_sentinel_not_exists "$(snm "$T_ISOL_B")" "A5a: TASK_B NO_MENTION sentinel absent"

# Task B no-mention → first-time blocked (not affected by Task A)
NO_M=$(build_content_input "$NO_MENTION_BODY")
run_mch "$T_ISOL_B" "$NO_M"
assert_mch_blocked "A5b: TASK_B no-mention → first-time blocked"
assert_sentinel_exists "$(snm "$T_ISOL_B")" "A5b: TASK_B NO_MENTION created independently"

# Task A sentinels still intact
assert_sentinel_exists "$(sp "$T_ISOL_A")" "A5c: TASK_A PASS sentinel intact"
assert_sentinel_exists "$(snm "$T_ISOL_A")" "A5c: TASK_A NO_MENTION sentinel intact"

#####################################################################
# PART A6: No MULTICA_TASK_ID → no sentinel, normal execution
#####################################################################
separator "A6: No MULTICA_TASK_ID → no sentinel logic"

cleanup_mch_sentinels
T_NOID=$(mktemp /tmp/see472-noid-stdout.XXXXXX)
NO_MENTION_INPUT=$(build_content_input "$NO_MENTION_BODY")
# Must explicitly unset MULTICA_TASK_ID (inherited from runtime environment)
env -u MULTICA_TASK_ID bash -c "printf '%s' '$NO_MENTION_INPUT' | bash '$MCH_HOOK'" > "$T_NOID" 2>/dev/null
NOID_OUTPUT=$(cat "$T_NOID")
rm -f "$T_NOID"

if echo "$NOID_OUTPUT" | grep -q '"permissionDecision"'; then
    pass "A6: no TASK_ID → blocked (no sentinel created)"
else
    fail "A6: expected block for no-mention without TASK_ID. stdout: '$NOID_OUTPUT'"
fi

#####################################################################
# PART A7: Sentinel cleanup verification
#####################################################################
separator "A7: Sentinel cleanup boundary"

cleanup_mch_sentinels
T_CLEAN="see472-clean-$$"
run_mch "$T_CLEAN" "$(build_content_input "$NO_MENTION_BODY")"
assert_sentinel_exists "$(snm "$T_CLEAN")" "A7a: sentinel exists before cleanup"
rm -f "$(snm "$T_CLEAN")"
assert_sentinel_not_exists "$(snm "$T_CLEAN")" "A7b: sentinel removed after cleanup"

#####################################################################
# PART B: auto-pr-on-stop.sh comment improvements
#####################################################################
separator "B: auto-pr-on-stop.sh comment improvements"

# B1: Verify mention link is wrapped in HTML comment (not active)
# HTML comment spans 3 lines: <!-- Auto-mention disabled \n [@Atlas](mention://...) \n -->
if tr '\n' '\x00' < "$APS_HOOK" | grep -qP '<!--.*?mention://agent.*?-->'; then
    pass "B1a: mention link wrapped in HTML comment (inactive)"
else
    fail "B1a: mention link not found in HTML comment wrapping"
fi

if grep -q '\[@Atlas\]' "$APS_HOOK"; then
    pass "B1b: [@Atlas] text present in comment template"
else
    fail "B1b: [@Atlas] text missing from comment template"
fi

# Verify no non-comment-wrapped mention:// URLs
# Count total mention:// lines and those within <!-- ... --> blocks
MENTION_LINES=$(grep -c 'mention://' "$APS_HOOK" || true)
# Use tr to join lines, then count comment-wrapped mentions
COMMENT_WRAPPED=$(tr '\n' '\x00' < "$APS_HOOK" | grep -oP '<!--.*?mention://agent.*?-->' | wc -l)
if [ "$MENTION_LINES" -eq "$COMMENT_WRAPPED" ]; then
    pass "B1c: all mention URLs are inside HTML comments (none active)"
else
    fail "B1c: $MENTION_LINES mention URLs but only $COMMENT_WRAPPED HTML-wrapped"
fi

# B2: Verify comment metadata fields in the script
if grep -q 'PR_NUMBER' "$APS_HOOK"; then
    pass "B2a: PR_NUMBER metadata variable present"
else
    fail "B2a: PR_NUMBER metadata variable missing"
fi

if grep -q 'COMMIT_COUNT' "$APS_HOOK"; then
    pass "B2b: COMMIT_COUNT metadata variable present"
else
    fail "B2b: COMMIT_COUNT metadata variable missing"
fi

if grep -q 'TITLE' "$APS_HOOK"; then
    pass "B2c: TITLE metadata variable present"
else
    fail "B2c: TITLE metadata variable missing"
fi

if grep -q 'CURRENT_BRANCH' "$APS_HOOK"; then
    pass "B2d: BRANCH metadata variable present"
else
    fail "B2d: BRANCH metadata variable missing"
fi

if grep -q 'COMMIT_LIST' "$APS_HOOK"; then
    pass "B2e: COMMIT_LIST metadata variable present"
else
    fail "B2e: COMMIT_LIST metadata variable missing"
fi

# B3: Verify content-stdin heredoc usage for comment posting
if grep -q 'content-stdin' "$APS_HOOK"; then
    pass "B3a: content-stdin mode used for comment posting"
else
    fail "B3a: content-stdin mode not found"
fi

if grep -q 'COMMENT' "$APS_HOOK" && grep -q 'COMMENT | multica issue comment add' "$APS_HOOK"; then
    pass "B3b: heredoc pipe to multica comment add detected"
else
    fail "B3b: heredoc pipe pattern missing"
fi

# B4: Verify the PR notification section is inside the ISSUE_ID guard
if tr '\n' '\x00' < "$APS_HOOK" | grep -qP 'ISSUE_ID.*?Draft PR created'; then
    pass "B4: PR notification comment inside ISSUE_ID guard"
else
    fail "B4: PR notification comment outside ISSUE_ID guard"
fi

# B5: Verify metadata lines appear in the comment body
# The comment body is built in the PR_INFO variable and expanded into the heredoc.
# Extract PR_INFO assignment through the heredoc terminator to capture the full template.
sed -n '/^  # Build PR notification text$/,/^COMMENT$/p' "$APS_HOOK" > /tmp/see472-aps-section-$$.txt

if grep -qE '\*\*PR.*\*\*' /tmp/see472-aps-section-$$.txt; then
    pass "B5a: '**PR**' label in comment body"
else
    fail "B5a: '**PR**' label missing from comment body"
fi

if grep -qE '\*\*Title.*\*\*' /tmp/see472-aps-section-$$.txt; then
    pass "B5b: '**Title**' label in comment body"
else
    fail "B5b: '**Title**' label missing from comment body"
fi

if grep -qE '\*\*Branch.*\*\*' /tmp/see472-aps-section-$$.txt; then
    pass "B5c: '**Branch**' label in comment body"
else
    fail "B5c: '**Branch**' label missing from comment body"
fi

if grep -qE '\*\*Commits.*\*\*' /tmp/see472-aps-section-$$.txt; then
    pass "B5d: '**Commits**' label in comment body"
else
    fail "B5d: '**Commits**' label missing from comment body"
fi

if grep -q '### Commits' /tmp/see472-aps-section-$$.txt; then
    pass "B5e: '### Commits' section header in comment body"
else
    fail "B5e: '### Commits' section missing from comment body"
fi

rm -f /tmp/see472-aps-section-$$.txt

# B6: Verify --parent resolution logic for threaded replies
if grep -q 'trigger_comment_id' "$APS_HOOK"; then
    pass "B6: --parent resolution via trigger_comment_id present"
else
    fail "B6: trigger_comment_id resolution logic missing"
fi

#####################################################################
# PART C: Cross-component consistency
#####################################################################
separator "C: Cross-component consistency"

# C1: Both hooks reference correct issue keys
if head -15 "$MCH_HOOK" | grep -q "SEE"; then
    pass "C1a: mention-check.sh references SEE issues in header"
else
    skip "C1a: mention-check.sh header (no SEE ref found)"
fi

if head -15 "$APS_HOOK" | grep -q "SEE-465"; then
    pass "C1b: auto-pr-on-stop.sh references SEE-465 in header"
else
    fail "C1b: auto-pr-on-stop.sh missing SEE-465 header reference"
fi

# C2: mention-check uses correct sentinel file name pattern
SENTINEL_PATTERNS=$(grep -c 'mention-check-' "$MCH_HOOK" || true)
if [ "$SENTINEL_PATTERNS" -ge 3 ]; then
    pass "C2: sentinel path patterns consistent (>=3 occurrences)"
else
    fail "C2: sentinel path patterns inconsistent ($SENTINEL_PATTERNS < 3)"
fi

# C3: Sentinel paths are defined only inside the Node.js block (bash-level paths removed)
BASH_PASS=$(grep 'SENTINEL_PASS=' "$MCH_HOOK" | head -1 | grep -o '/tmp/[^"]*' || true)
BASH_NO=$(grep 'SENTINEL_NO_MENTION=' "$MCH_HOOK" | head -1 | grep -o '/tmp/[^"]*' || true)
BASH_BL=$(grep 'SENTINEL_BLOCK=' "$MCH_HOOK" | head -1 | grep -o '/tmp/[^"]*' || true)
NODE_PASS=$(grep "SENTINEL_PASS.*'/tmp/" "$MCH_HOOK" | head -1 | grep -o "/tmp/[^']*")
NODE_NO=$(grep "SENTINEL_NO_MENTION.*'/tmp/" "$MCH_HOOK" | head -1 | grep -o "/tmp/[^']*")
NODE_BL=$(grep "SENTINEL_BLOCK.*'/tmp/" "$MCH_HOOK" | head -1 | grep -o "/tmp/[^']*")

if [ -z "$BASH_PASS" ] && [ -z "$BASH_NO" ] && [ -z "$BASH_BL" ]; then
    pass "C3a: no bash-level sentinel paths (all migrated to Node.js)"
else
    fail "C3a: unexpected bash-level sentinel paths present"
fi

if echo "$NODE_PASS" | grep -q '/tmp/mention-check-pass' && \
   echo "$NODE_NO" | grep -q '/tmp/mention-check-no-mention' && \
   echo "$NODE_BL" | grep -q '/tmp/mention-check-block'; then
    pass "C3b: Node.js-level sentinel paths use correct prefixes"
else
    fail "C3b: Node.js-level sentinel paths incorrect"
fi

# C4: auto-pr-on-stop correctly handles content-stdin (no content extraction needed)
if grep -q 'cat <<COMMENT' "$APS_HOOK"; then
    pass "C4: heredoc content construction present in auto-pr-on-stop"
else
    fail "C4: heredoc content construction missing"
fi

#####################################################################
# Cleanup
#####################################################################
cleanup_mch_sentinels
rm -f /tmp/see472-*

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
