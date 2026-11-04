#!/bin/bash
# test_push_guard_atlas_whitelist_see1069.sh
# SEE-1069 Atlas force-push whitelist RETIREMENT regression suite.
#
# 背景（退役裁定，SEE-1516 §SPEC-021 / Owner「方案一 + B」2026-11-04）：原
# SEE-1069 为 squash-merge 分歧场景给 Atlas 加了 agent_id 白名单 + 审计日志。
# 团队 PR 实际一直走 rebase merge（线性历史），squash 前提不成立——白名单是
# 用不到的历史遗留特权，且被 gates push-guard-force-push-gate 无差别 deny 覆盖
# 而死亡（双轨）。E1 单轨收编按 Owner 裁决删除白名单与审计链：force-push 拦截
# 唯一防线 = gates（无任何 agent 豁免，含 Atlas）。
#
# Coverage（按新契约改写）：
#   R1: 源码不再含 ATLAS_AGENT_ID 白名单常量与审计日志路径
#   R2: Atlas 身份 + force 形态 → 脚本不再特判（无审计文件产生；透传进后续检查）
#   R3: 非 Atlas / 空 agent_id + force 形态 → 同上（脚本层不再 exit 2，deny 归 gates）
#   R4: 任何路径均不产生 push-guard-force-audit.log
#
# Related Issue: SEE-1069（退役）→ SEE-1516 §SPEC-021
# Author: Bachi

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); }

WORKTREE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SCRIPT="$WORKTREE_DIR/claude-hooks/scripts/push-guard.sh"
ATLAS_ID="fac3e3a1-dcda-498d-8613-e8c2811f3ef5"
# git 仓 fixture 内执行：force 走普通 Phase 3 管线（空仓无 upstream → 各检查
# 自然跳过 → exit 0 透传），证明无白名单特判；PROJECT_ROOT 指向受控临时目录，
# 供断言「审计文件不再产生」。
NEUTRAL_DIR="$(mktemp -d /tmp/pgw-neutral.XXXXXX)"
GITFIX="$NEUTRAL_DIR/repo"
git init -q -b master "$GITFIX"
git -C "$GITFIX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git init -q --bare "$NEUTRAL_DIR/origin.git"
git -C "$GITFIX" remote add origin "$NEUTRAL_DIR/origin.git"
git -C "$GITFIX" push -q -u origin master 2>/dev/null

echo "============================================"
echo "  SEE-1069 whitelist retirement (SEE-1516 §SPEC-021)"
echo "  Hook: $HOOK_SCRIPT"
echo "============================================"

if [ ! -f "$HOOK_SCRIPT" ]; then
  fail "push-guard.sh not found at $HOOK_SCRIPT"
  exit 1
fi
pass "push-guard.sh exists"

# -------------------------------------------------------
# R1: 源码退役面断言
# -------------------------------------------------------
echo -e "${CYAN}--- R1 source retirement assertions ---${NC}"

if grep -q 'ATLAS_AGENT_ID' "$HOOK_SCRIPT"; then
  fail "R1-1: ATLAS_AGENT_ID 白名单常量仍在源码中"
else
  pass "R1-1: 源码无 ATLAS_AGENT_ID 白名单常量"
fi
if grep -q 'AUDIT_LOG=' "$HOOK_SCRIPT"; then
  fail "R1-2: 活动审计代码（AUDIT_LOG=）仍在源码中"
else
  pass "R1-2: 源码无活动审计代码（退役注释中的路径字样为意向保留）"
fi
if grep -q 'PUSH_RESULT" = "FORCE_PUSH" ]; then' "$HOOK_SCRIPT"; then
  fail "R1-3: FORCE_PUSH 拦截块仍在源码中"
else
  pass "R1-3: 源码无 FORCE_PUSH 拦截块"
fi

# -------------------------------------------------------
# Helper: run the hook with a controlled PROJECT_ROOT and capture exit.
# Sets MULTICA_TASK_ID="" to skip working-branch resolution.
# -------------------------------------------------------
run_hook() {
  local agent_id="$1"
  local agent_name="$2"
  local cmd="$3"
  local audit_dir="$4"

  local input
  input=$(printf '{"tool_input":{"command":"%s"}}' "$cmd")

  local stdout_file stderr_file
  stdout_file=$(mktemp /tmp/pgw-out.XXXXXX)
  stderr_file=$(mktemp /tmp/pgw-err.XXXXXX)

  (
    cd "$GITFIX" || exit 99
    unset TARGET_REPO_ROOT GIT_ROOT
    export MULTICA_AGENT_ID="$agent_id"
    export MULTICA_AGENT_NAME="$agent_name"
    export MULTICA_TASK_ID=""
    export PROJECT_ROOT="$audit_dir"
    echo "$input" | bash "$HOOK_SCRIPT" > "$stdout_file" 2> "$stderr_file"
  )
  local actual_exit=$?

  local stderr_content
  stderr_content=$(cat "$stderr_file")
  rm -f "$stdout_file" "$stderr_file"

  echo "$actual_exit"
  echo "---STDERR---"
  echo "$stderr_content"
}

# ========================================================
# R2: Atlas 身份 + force 形态 → 白名单特判消失
# ========================================================
echo ""
echo -e "${CYAN}=== R2: Atlas + force form → no special-case ===${NC}"

AUDIT_DIR_R2=$(mktemp -d /tmp/pgw-audit-r2.XXXXXX)

OUT=$(run_hook "$ATLAS_ID" "Atlas" \
  "git push --force-with-lease origin HEAD:refs/heads/shared/SEE-1067" \
  "$AUDIT_DIR_R2")
EXIT=$(echo "$OUT" | head -1)
if [ "$EXIT" -eq 0 ] && ! grep -q "Atlas whitelist" <<<"$OUT"; then
  pass "R2-1: Atlas --force-with-lease → 脚本无白名单特判（exit 0 透传）"
else
  fail "R2-1: 预期 exit 0 且无白名单文案，got exit=$EXIT"
fi
[ -f "$AUDIT_DIR_R2/.claude/push-guard-force-audit.log" ] \
  && fail "R2-2: 审计文件不应再产生" \
  || pass "R2-2: 无审计文件产生"

OUT=$(run_hook "$ATLAS_ID" "Atlas" \
  "git push --force origin HEAD:refs/heads/shared/SEE-1067" "$AUDIT_DIR_R2")
EXIT=$(echo "$OUT" | head -1)
[ "$EXIT" -eq 0 ] && pass "R2-3: Atlas --force → 脚本不再特判" || fail "R2-3: got exit=$EXIT"

# ========================================================
# R3: 非 Atlas / 空 agent_id + force 形态 → 同路径（deny 归 gates）
# ========================================================
echo ""
echo -e "${CYAN}=== R3: non-Atlas + force → same path (gates own deny) ===${NC}"

AUDIT_DIR_R3=$(mktemp -d /tmp/pgw-audit-r3.XXXXXX)

OUT=$(run_hook "other-agent-uuid" "Bachi" \
  "git push --force origin HEAD:refs/heads/shared/SEE-1067" "$AUDIT_DIR_R3")
EXIT=$(echo "$OUT" | head -1)
if [ "$EXIT" -eq 0 ]; then
  pass "R3-1: 非 Atlas force → 脚本不再 exit 2（deny 归 gates 层，见 B7/E2 套件）"
else
  fail "R3-1: 预期脚本透传（exit 0），got exit=$EXIT"
fi

OUT=$(run_hook "" "" "git push -f origin feature/x" "$AUDIT_DIR_R3")
EXIT=$(echo "$OUT" | head -1)
[ "$EXIT" -eq 0 ] && pass "R3-2: 空 agent_id force → 脚本透传" || fail "R3-2: got exit=$EXIT"

# ========================================================
# R4: 全路径无审计文件
# ========================================================
echo -e "${CYAN}=== R4: no audit file anywhere ===${NC}"
FOUND=0
for d in "$AUDIT_DIR_R2" "$AUDIT_DIR_R3" "$NEUTRAL_DIR"; do
  [ -e "$d/.claude/push-guard-force-audit.log" ] && FOUND=1
done
[ "$FOUND" -eq 0 ] && pass "R4: 全路径无 push-guard-force-audit.log" || fail "R4: 审计文件仍被产生"

# --- Summary ---
rm -rf "$NEUTRAL_DIR" "$AUDIT_DIR_R2" "$AUDIT_DIR_R3"
echo ""
echo -e "${CYAN}--- Results Summary ---${NC}"
echo ""
echo "Total: $((PASS + FAIL)) | PASS: $PASS | FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo -e "${RED}$FAIL TEST(S) FAILED${NC}"
  exit 1
fi
echo -e "${GREEN}ALL TESTS PASSED${NC}"
exit 0
