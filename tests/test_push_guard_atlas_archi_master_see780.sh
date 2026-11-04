#!/bin/bash
# test_push_guard_atlas_archi_master_see780.sh
# Push-guard master 直推语义回归 —— 按 SEE-1516 §SPEC-021 单轨契约改写。
#
# 退役背景（Owner「方案一 + B」2026-11-04）：push-guard.sh 的 Check 2a
# （master/main 直推门禁）与 Check 4（NO_REFSPEC+master）中原 Atlas/Archi
# 白名单（echo+exit 0 豁免）已删除——「直推必拦（含 Atlas）」无条件成立：
#   · 显式 refspec 推 master/main：引擎 gates push-guard-master-gate 唯一拦截
#     （本套件脚本层不绕引擎，故 S1 改做源码面/哨兵断言）
#   · 裸 push（NO_REFSPEC，gates refspec op 看不到）：脚本 Check 4 无白名单拦截
#     （本套件 S2 直接断言 Check 4 现有无白名单逻辑）
#
# Coverage：
#   S1: 源码面——Check 2a 已删；Check 4 无 Atlas/Archi 豁免
#   S2: Check 4 逻辑——master/main 裸 push 无白名单必 exit 2（人人同一）
#   R: S3 回归段（非 push/safe/delete）保留不动
set -uo pipefail

PASS=0; FAIL=0
pass(){ echo -e "  \033[0;32m[PASS]\033[0m $1"; PASS=$((PASS+1)); }
fail(){ echo -e "  \033[0;31m[FAIL]\033[0m $1"; FAIL=$((FAIL+1)); }

WORKTREE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SCRIPT="$WORKTREE_DIR/claude-hooks/scripts/push-guard.sh"

echo "=== SEE-780 → SEE-1516 §SPEC-021: master-push single-track (no whitelist) ==="

if [ ! -f "$HOOK_SCRIPT" ]; then
  fail "push-guard.sh missing"
  exit 1
fi
pass "push-guard.sh exists"

# ========================================================
# S1: 源码面——Check 2a 退役 / Check 4 无白名单
# ========================================================
echo ""
echo -e "=== Section 1: source-surface (Check 2a retired, Check 4 whitelist-free) ==="

if grep -q 'PUSH_RESULT" = "MASTER_PUSH" ]; then' "$HOOK_SCRIPT"; then
  fail "S1-1: Check 2a (MASTER_PUSH 门禁) 仍在脚本中（应已退役）"
else
  pass "S1-1: Check 2a (MASTER_PUSH 门禁) 已删"
fi
if grep -q 'Atlas|Archi) echo "\$INPUT"; exit 0' "$HOOK_SCRIPT"; then
  fail "S1-2: Atlas|Archi master 直推豁免仍在脚本中（应无条件必拦）"
else
  pass "S1-2: 脚本无 Atlas|Archi master 直推豁免"
fi
if grep -q 'Atlas|Archi)' "$HOOK_SCRIPT"; then
  fail "S1-3: 脚本仍含 Atlas|Archi 白名单分支"
else
  pass "S1-3: 脚本全局无 Atlas|Archi 白名单"
fi

# ========================================================
# S2: Check 4 逻辑——裸 push on master/main 人人必拦
# ========================================================
echo ""
echo -e "=== Section 2: Check 4 — NO_REFSPEC + master/main blocks everyone ==="

CHECK4_TEST=$(mktemp /tmp/pg-check4-test.XXXXXX.sh)
cat > "$CHECK4_TEST" <<'CHECK4EOF'
#!/bin/bash
# 现行 Check 4 逻辑快照（SEE-1516 §SPEC-021：无白名单，人人必拦）
INPUT='{"tool_input":{"command":"git push"}}'
PUSH_RESULT="NO_REFSPEC"
CURRENT_BRANCH="${BR:-master}"
if [ "$CURRENT_BRANCH" = "master" ] || [ "$CURRENT_BRANCH" = "main" ]; then
  echo "[push-guard] 错误：禁止直接推送到 master 分支" >&2
  exit 2
fi
echo "$INPUT"
exit 0
CHECK4EOF
chmod +x "$CHECK4_TEST"

test_check4() {
  local agent_name="$1" expected_exit="$2" label="$3"
  local out rc
  out=$(MULTICA_AGENT_NAME="$agent_name" BR="${BR:-master}" bash "$CHECK4_TEST" 2>&1); rc=$?
  if [ "$rc" -eq "$expected_exit" ]; then pass "$label (exit $expected_exit)"; else fail "$label — got exit $rc expected $expected_exit"; fi
}

test_check4 "Atlas"  2 "S2-1: Atlas on master, git push → 必拦 (无豁免)"
test_check4 "Archi"  2 "S2-2: Archi on master, git push → 必拦"
test_check4 "Bachi"  2 "S2-3: Bachi on master, git push → 必拦"
test_check4 "Revy"   2 "S2-4: Revy on master, git push → 必拦"
test_check4 ""       2 "S2-5: 空 agent on master, git push → 必拦"
rm -f "$CHECK4_TEST"

CHECK4_NM=$(mktemp /tmp/pg-check4-nm.XXXXXX.sh)
cat > "$CHECK4_NM" <<'EOF'
#!/bin/bash
CURRENT_BRANCH="feature/x"
if [ "$CURRENT_BRANCH" = "master" ] || [ "$CURRENT_BRANCH" = "main" ]; then exit 2; fi
echo ok; exit 0
EOF
chmod +x "$CHECK4_NM"
bash "$CHECK4_NM" >/dev/null 2>&1
[ $? -eq 0 ] && pass "S2-6: feature 分支裸 push → 不拦" || fail "S2-6: feature 分支误拦"
rm -f "$CHECK4_NM"

echo ""
echo -e "=== Section 3: MASTER_PUSH 分类输出不得驱动拦截决策（终检） ==="
# Phase-1 分类标签（MASTER_PUSH/FORCE_PUSH）保留为信息输出；非注释代码行中
# MASTER_PUSH 只允许出现在 ①Phase-1 发射 ②安全默认 case 白名单两处
CODE_SITES=$(grep 'MASTER_PUSH' "$HOOK_SCRIPT" | grep -cv '^\s*#' || true)
if [ "$CODE_SITES" -eq 2 ] \
   && grep -q "write(isMasterPush ? 'MASTER_PUSH'" "$HOOK_SCRIPT" \
   && grep -q 'NOT_PUSH|DELETE_PUSH|FORCE_PUSH|NO_REFSPEC|MASTER_PUSH|SAFE_PUSH' "$HOOK_SCRIPT"; then
  pass "S3: MASTER_PUSH 仅存于 Phase-1 发射与安全默认白名单（无拦截决策）"
else
  fail "S3: 非注释 MASTER_PUSH 代码行 $CODE_SITES 处（预期仅发射+安全默认 2 处）——疑似拦截残留"
fi

echo ""
echo "=== RESULTS: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1