#!/bin/bash
# test_mention_check_content_file_unreadable.sh
# Tests for SEE-1054 P0: --content-file 读取失败时钩子诚实报错，
# 返回 CONTENT_FILE_UNREADABLE 而非 NO_MENTION；不创建/消费任何 sentinel；
# 每次都报，让 agent 立即修正。
#
# Related Issue: SEE-1054
# Test Type: Functional / Regression
# Author: Bachi (Backend Agent)

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

# Robust PROJECT_ROOT: walk up from script dir until we find .claude/hooks/scripts/mention-check.sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
for _ in 1 2 3 4 5; do
    if [ -f "$PROJECT_ROOT/claude-hooks/scripts/mention-check.sh" ]; then
        break
    fi
    PROJECT_ROOT="$(dirname "$PROJECT_ROOT")"
done
HOOK_SCRIPT="$PROJECT_ROOT/claude-hooks/scripts/mention-check.sh"

TEST_COUNTER=0

sp()  { echo "/tmp/mention-check-pass-$1"; }
snm() { echo "/tmp/mention-check-no-mention-$1"; }
sb()  { echo "/tmp/mention-check-block-$1"; }

cleanup_sentinels() {
    local tid="$1"
    rm -f "$(sp "$tid")" "$(snm "$tid")" "$(sb "$tid")"
}

run_hook() {
    local INPUT="$1"
    local TASK_ID="see1054-cfu-${TEST_COUNTER}-$$"
    TEST_COUNTER=$((TEST_COUNTER + 1))
    cleanup_sentinels "$TASK_ID"

    local STDOUT_FILE=$(mktemp /tmp/see1054-cfu-stdout.XXXXXX)
    local STDERR_FILE=$(mktemp /tmp/see1054-cfu-stderr.XXXXXX)

    printf '%s' "$INPUT" | MULTICA_TASK_ID="$TASK_ID" bash "$HOOK_SCRIPT" > "$STDOUT_FILE" 2> "$STDERR_FILE"
    HOOK_EXIT=$?
    HOOK_STDOUT=$(cat "$STDOUT_FILE")
    HOOK_STDERR=$(cat "$STDERR_FILE")
    HOOK_TASK_ID="$TASK_ID"

    rm -f "$STDOUT_FILE" "$STDERR_FILE"
}

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
    if [ -n "$HOOK_STDOUT" ] && ! echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
        pass "$label — passthrough (no deny)"
    else
        fail "$label — unexpectedly blocked or empty. stdout: '$HOOK_STDOUT'"
    fi
}

assert_contains() {
    local label="$1"
    local needle="$2"
    if echo "$HOOK_STDOUT" | grep -qF "$needle"; then
        pass "$label — contains '$needle'"
    else
        fail "$label — missing '$needle'. stdout: '$HOOK_STDOUT'"
    fi
}

assert_no_sentinels() {
    local label="$1"
    local tid="$2"
    if [ ! -f "$(snm "$tid")" ] && [ ! -f "$(sp "$tid")" ] && [ ! -f "$(sb "$tid")" ]; then
        pass "$label — no sentinel created (hard error)"
    else
        fail "$label — sentinel created unexpectedly. snm=$( [ -f "$(snm "$tid")" ] && echo yes || echo no ) sp=$( [ -f "$(sp "$tid")" ] && echo yes || echo no ) sb=$( [ -f "$(sb "$tid")" ] && echo yes || echo no )"
    fi
}

echo "============================================"
echo "  SEE-1054 P0 CONTENT_FILE_UNREADABLE Tests"
echo "  Date: $(date -Iseconds)"
echo "  Author: Bachi (Backend Agent)"
echo "  Branch: $(git branch --show-current 2>/dev/null || echo 'unknown')"
echo "============================================"

#####################################################################
# Prerequisite
#####################################################################
separator "Prerequisite"

if [ -f "$HOOK_SCRIPT" ]; then
    pass "Hook file exists: $HOOK_SCRIPT"
else
    fail "Hook file MISSING at $HOOK_SCRIPT"
    exit 1
fi

# Verify the fix is in place
if grep -q "CONTENT_FILE_UNREADABLE" "$HOOK_SCRIPT"; then
    pass "Hook contains CONTENT_FILE_UNREADABLE result type"
else
    fail "Hook MISSING CONTENT_FILE_UNREADABLE — fix not applied"
fi

#####################################################################
# G1: --content-file ./nonexistent.md → CONTENT_FILE_UNREADABLE hard error
#####################################################################
separator "G1: content-file not found → CONTENT_FILE_UNREADABLE"

# G1.1: relative nonexistent path → blocked + honest error
REL_NAME="nonexistent-$$.md"
run_hook "{\"tool_input\":{\"command\":\"multica issue comment add SEE-999 --content-file ./${REL_NAME}\"}}"
assert_blocked "G1.1 nonexistent content-file → blocked"
assert_contains "G1.1 honest error header" "无法读取 --content-file 指向的文件"
assert_contains "G1.1 reports resolved path" "$REL_NAME"
assert_contains "G1.1 reports CWD field" "当前 CWD:"
assert_contains "G1.1 reports error reason" "错误原因:"
assert_contains "G1.1 reports suggestion" "建议:"
assert_no_sentinels "G1.1 no sentinel created" "$HOOK_TASK_ID"

# G1.2: MUST NOT fall into the normal mention-missing path
if echo "$HOOK_STDOUT" | grep -qF "缺少有效的 @mention"; then
    fail "G1.2 output incorrectly falls into NO_MENTION path (误报)"
else
    pass "G1.2 does NOT misreport as missing-mention"
fi

# G1.3: absolute nonexistent path also yields hard error with path
ABS_NAME="/tmp/see1054-definitely-not-there-$$.md"
run_hook "{\"tool_input\":{\"command\":\"multica issue comment add SEE-999 --content-file ${ABS_NAME}\"}}"
assert_blocked "G1.3 absolute nonexistent path → blocked"
assert_contains "G1.3 absolute path echoed" "$ABS_NAME"
assert_no_sentinels "G1.3 no sentinel created" "$HOOK_TASK_ID"

# G1.4: quoted path also handled
QUOTED_NAME="/tmp/see1054-quoted-$$.md"
run_hook "{\"tool_input\":{\"command\":\"multica issue comment add SEE-999 --content-file \\\"${QUOTED_NAME}\\\"\"}}"
assert_blocked "G1.4 quoted nonexistent path → blocked"
assert_contains "G1.4 quoted path echoed" "$QUOTED_NAME"
assert_no_sentinels "G1.4 no sentinel created" "$HOOK_TASK_ID"

#####################################################################
# G2: 每次都报 (hard error repeats; no sentinel consumption)
#####################################################################
separator "G2: 硬错误重复触发（不消费 sentinel）"

TID="see1054-cfu-repeat-$$"
cleanup_sentinels "$TID"
REPEAT_NAME="still-not-there-$$.md"
INPUT="{\"tool_input\":{\"command\":\"multica issue comment add SEE-999 --content-file ./${REPEAT_NAME}\"}}"

# First call
printf '%s' "$INPUT" | MULTICA_TASK_ID="$TID" bash "$HOOK_SCRIPT" > /tmp/see1054-r1.out 2>/dev/null
FIRST_OUT=$(cat /tmp/see1054-r1.out)
rm -f /tmp/see1054-r1.out

# Second call with SAME TASK_ID — must STILL be blocked (not passthrough)
printf '%s' "$INPUT" | MULTICA_TASK_ID="$TID" bash "$HOOK_SCRIPT" > /tmp/see1054-r2.out 2>/dev/null
SECOND_OUT=$(cat /tmp/see1054-r2.out)
rm -f /tmp/see1054-r2.out

if echo "$FIRST_OUT" | grep -q '"permissionDecision"'; then
    pass "G2.1 first call → blocked"
else
    fail "G2.1 first call not blocked: $FIRST_OUT"
fi

if echo "$SECOND_OUT" | grep -q '"permissionDecision"'; then
    pass "G2.2 second call → STILL blocked (硬错误不消费 sentinel)"
else
    fail "G2.2 second call became passthrough — sentinel leak. stdout: $SECOND_OUT"
fi

cleanup_sentinels "$TID"

#####################################################################
# G3: 正常 mention 通过路径不受影响（regression）
#####################################################################
separator "G3: mention-valid content-file still works (regression)"

FIXTURE_DIR=$(mktemp -d /tmp/see1054-fixtures.XXXXXX)
echo "via existing file [@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5) please check" > "$FIXTURE_DIR/with_mention.txt"

run_hook "{\"tool_input\":{\"command\":\"multica issue comment add SEE-999 --content-file $FIXTURE_DIR/with_mention.txt\"}}"
assert_passthrough "G3.1 existing content-file with mention → passthrough"
# PASS sentinel created (normal behavior preserved)
if [ -f "$(sp "$HOOK_TASK_ID")" ]; then
    pass "G3.2 PASS sentinel created on success"
else
    fail "G3.2 PASS sentinel missing after successful read"
fi
cleanup_sentinels "$HOOK_TASK_ID"
rm -rf "$FIXTURE_DIR"

#####################################################################
# Cleanup
#####################################################################
for i in $(seq 0 $((TEST_COUNTER - 1))); do
    cleanup_sentinels "see1054-cfu-${i}-$$"
done
rm -f /tmp/see1054-cfu-*

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
