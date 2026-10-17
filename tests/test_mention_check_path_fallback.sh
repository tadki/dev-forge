#!/bin/bash
# test_mention_check_path_fallback.sh
# Tests for SEE-1054 P1: --content-file 读取失败时，依次尝试：
#   1) fp 原样
#   2) 相对 $MULTICA_WORKDIR 解析
#   3) 相对 path.resolve(cwd, '..', fp)
# 仍失败才走 P0 的 CONTENT_FILE_UNREADABLE 出口。
#
# 核心场景：「文件在 workdir 根、CWD 在 repo 子目录」—— 典型 Write/Bash 基准目录错位。
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

# Robust PROJECT_ROOT: walk up until we find .claude/hooks/scripts/mention-check.sh
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

echo "============================================"
echo "  SEE-1054 P1 Path Fallback Tests"
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

if grep -q "MULTICA_WORKDIR" "$HOOK_SCRIPT"; then
    pass "Hook contains MULTICA_WORKDIR fallback branch"
else
    fail "Hook MISSING MULTICA_WORKDIR fallback — fix not applied"
fi

if grep -q "path.resolve(cwd, '..', fp)" "$HOOK_SCRIPT"; then
    pass "Hook contains cwd/../fp fallback branch"
else
    fail "Hook MISSING cwd/../fp fallback — fix not applied"
fi

#####################################################################
# G1: 文件在 workdir 根, CWD 在 repo 子目录 → 通过 cwd/../fp 解析成功
#####################################################################
separator "G1: workdir-root file + repo-subdir CWD → path.resolve(cwd, '..', fp) fallback"

# Build an isolated sandbox:
#   <SANDBOX>/workdir/         ← "workdir root" (target file lives here)
#   <SANDBOX>/workdir/repo/    ← "repo subdir"  (hook invoked from here)
SANDBOX=$(mktemp -d /tmp/see1054-fb-XXXXXX)
WORKDIR_ROOT="$SANDBOX/workdir"
REPO_SUBDIR="$WORKDIR_ROOT/repo"
mkdir -p "$REPO_SUBDIR"

MENTION_BODY="via cwd-parent fallback [@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5) 验证路径容错"
FALLBACK_FILE="reply-fb-$$.md"
echo "$MENTION_BODY" > "$WORKDIR_ROOT/$FALLBACK_FILE"

TASK_ID="see1054-fb-g1-$$"
cleanup_sentinels "$TASK_ID"

INPUT="{\"tool_input\":{\"command\":\"multica issue comment add SEE-999 --content-file ./${FALLBACK_FILE}\"}}"

# Run the hook FROM the repo subdir (the CWD-mismatch scenario), without MULTICA_WORKDIR
OUT=$( cd "$REPO_SUBDIR" && printf '%s' "$INPUT" | env -u MULTICA_WORKDIR MULTICA_TASK_ID="$TASK_ID" bash "$HOOK_SCRIPT" 2>&1 )

if echo "$OUT" | grep -q '"permissionDecision"'; then
    fail "G1.1 cwd/../fp fallback → unexpectedly blocked. stdout: $OUT"
elif echo "$OUT" | grep -qF "$INPUT"; then
    pass "G1.1 cwd/../fp fallback → passthrough (content read + mention passed)"
else
    fail "G1.1 cwd/../fp fallback → unexpected output: $OUT"
fi

# PASS sentinel created (confirms the mention was actually validated)
if [ -f "$(sp "$TASK_ID")" ]; then
    pass "G1.2 PASS sentinel created via fallback read"
else
    fail "G1.2 PASS sentinel missing — content may not have been validated"
fi

# Verify the actual content was read (not empty fall-through): hook should have found the mention
# (If it had only passed due to null content, we'd see a different code path)
if echo "$OUT" | grep -qF "无法读取"; then
    fail "G1.3 output incorrectly reports file-unreadable — fallback did not kick in"
else
    pass "G1.3 no file-unreadable error reported"
fi

cleanup_sentinels "$TASK_ID"

#####################################################################
# G2: $MULTICA_WORKDIR fallback (priority over cwd/../fp)
#####################################################################
separator "G2: \$MULTICA_WORKDIR fallback"

WORKDIR_ENV="$SANDBOX/env-workdir"
mkdir -p "$WORKDIR_ENV"
ENV_FILE="reply-env-$$.md"
echo "via MULTICA_WORKDIR fallback [@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5)" > "$WORKDIR_ENV/$ENV_FILE"

TASK_ID="see1054-fb-g2-$$"
cleanup_sentinels "$TASK_ID"

INPUT="{\"tool_input\":{\"command\":\"multica issue comment add SEE-999 --content-file ./${ENV_FILE}\"}}"

# Run from a totally unrelated CWD (not under workdir, not parent-aligned),
# with MULTICA_WORKDIR pointing to the workdir that contains the file.
OUT=$( cd /tmp && printf '%s' "$INPUT" | MULTICA_WORKDIR="$WORKDIR_ENV" MULTICA_TASK_ID="$TASK_ID" bash "$HOOK_SCRIPT" 2>&1 )

if echo "$OUT" | grep -q '"permissionDecision"'; then
    fail "G2.1 \$MULTICA_WORKDIR fallback → unexpectedly blocked. stdout: $OUT"
elif echo "$OUT" | grep -qF "$INPUT"; then
    pass "G2.1 \$MULTICA_WORKDIR fallback → passthrough (content read via env)"
else
    fail "G2.1 \$MULTICA_WORKDIR fallback → unexpected output: $OUT"
fi

if [ -f "$(sp "$TASK_ID")" ]; then
    pass "G2.2 PASS sentinel created via \$MULTICA_WORKDIR"
else
    fail "G2.2 PASS sentinel missing"
fi

cleanup_sentinels "$TASK_ID"

#####################################################################
# G3: 两个 fallback 都失败 → 走 P0 CONTENT_FILE_UNREADABLE 出口
#####################################################################
separator "G3: 所有 fallback 都失败 → CONTENT_FILE_UNREADABLE 硬错误"

TASK_ID="see1054-fb-g3-$$"
cleanup_sentinels "$TASK_ID"

NON_EXIST="totally-missing-$$.md"
INPUT="{\"tool_input\":{\"command\":\"multica issue comment add SEE-999 --content-file ./${NON_EXIST}\"}}"

OUT=$( cd "$REPO_SUBDIR" && printf '%s' "$INPUT" | env -u MULTICA_WORKDIR MULTICA_TASK_ID="$TASK_ID" bash "$HOOK_SCRIPT" 2>&1 )

if echo "$OUT" | grep -q '"permissionDecision"' && echo "$OUT" | grep -qF "无法读取 --content-file"; then
    pass "G3.1 all fallbacks exhausted → CONTENT_FILE_UNREADABLE hard error"
else
    fail "G3.1 expected hard error. stdout: $OUT"
fi

if echo "$OUT" | grep -qF "$NON_EXIST"; then
    pass "G3.2 hard error echoes resolved path"
else
    fail "G3.2 hard error missing path. stdout: $OUT"
fi

if [ ! -f "$(snm "$TASK_ID")" ] && [ ! -f "$(sp "$TASK_ID")" ]; then
    pass "G3.3 no sentinel created on hard error"
else
    fail "G3.3 sentinel leak on hard error"
fi

cleanup_sentinels "$TASK_ID"

#####################################################################
# G4: fp 原样就能读 → 不触发任何 fallback（直读路径不受影响）
#####################################################################
separator "G4: 直读路径不受影响（regression）"

TASK_ID="see1054-fb-g4-$$"
cleanup_sentinels "$TASK_ID"

DIRECT_FILE="direct-$$.md"
echo "direct read [@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5)" > "$REPO_SUBDIR/$DIRECT_FILE"

INPUT="{\"tool_input\":{\"command\":\"multica issue comment add SEE-999 --content-file ./${DIRECT_FILE}\"}}"

OUT=$( cd "$REPO_SUBDIR" && printf '%s' "$INPUT" | env -u MULTICA_WORKDIR MULTICA_TASK_ID="$TASK_ID" bash "$HOOK_SCRIPT" 2>&1 )

if echo "$OUT" | grep -qF "$INPUT"; then
    pass "G4.1 direct read (no fallback needed) → passthrough"
else
    fail "G4.1 direct read broken. stdout: $OUT"
fi

if [ -f "$(sp "$TASK_ID")" ]; then
    pass "G4.2 PASS sentinel created via direct read"
else
    fail "G4.2 PASS sentinel missing"
fi

cleanup_sentinels "$TASK_ID"

#####################################################################
# Cleanup
#####################################################################
rm -rf "$SANDBOX"
for i in $(seq 0 $((TEST_COUNTER - 1))); do
    cleanup_sentinels "see1054-fb-${i}-$$"
done

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
