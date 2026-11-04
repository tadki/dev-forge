#!/bin/bash
# test_push_guard_force_detection_see954.sh
# SEE-954 LOW-1 force token 分类语义回归 —— 按 SEE-1516 §SPEC-021 单轨契约改写。
#
# 退役背景（Owner「方案一 + B」2026-11-04）：push-guard.sh 的 force-push 拦截段
# （含 SEE-1069 Atlas 白名单 + 审计链）已删除——force 拦截唯一防线 = 声明式
# gates（rules.d/push-guard-gates.json push-guard-force-push-gate，无任何 agent
# 豁免）。本套件改断言**分类语义仍在引擎侧结构化解析中成立**（when-ops.js
# push_refspec op 短簇全簇/加号 refspec/--no-force 豁免），并断言脚本层对 force
# 不再有自己的拦截决策（脚本透传，deny 归 gates——由
# test_push_guard_refspec_see1516.sh 的 gates 层用例承接判定）。
#
# 断言口径：
#   D1: 源码面——脚本无 FORCE_PUSH 拦截决策块；when-ops push_refspec 短簇
#       'f' 检查与 --no-force 豁免在位
#   D2: 行为面——脚本层对全部 force 形态透传（exit 0、无「禁止 force-push」
#       stderr），含旧 LOW-1 的短簇/等值/句尾变体全表
#   （gates 层 force deny 判定 = tests/test_push_guard_refspec_see1516.sh）

set -uo pipefail

PASS=0; FAIL=0
pass(){ echo -e "  \033[0;32m[PASS]\033[0m $1"; PASS=$((PASS+1)); }
fail(){ echo -e "  \033[0;31m[FAIL]\033[0m $1"; FAIL=$((FAIL+1)); }

WORKTREE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SCRIPT="$WORKTREE_DIR/claude-hooks/scripts/push-guard.sh"
WHEN_OPS="$WORKTREE_DIR/claude-hooks/unified/when-ops.js"
# 中性非 git 目录执行：仓库豁免与 Phase-3 仓库判定不参与（see526 G6 同型隔离）
NEUTRAL_DIR="$(mktemp -d /tmp/pgf-neutral.XXXXXX)"

echo "=== SEE-954 → SEE-1516 §SPEC-021: force classification single-track ==="

if [ ! -f "$HOOK_SCRIPT" ]; then
  fail "push-guard.sh missing at $HOOK_SCRIPT"
  exit 1
fi
pass "push-guard.sh exists"

# --- D1: 源码面 ---
echo ""
echo "--- D1 source assertions ---"
if grep -q 'PUSH_RESULT" = "FORCE_PUSH" ]; then' "$HOOK_SCRIPT"; then
  fail "D1-1: FORCE_PUSH 拦截决策块仍在脚本中（应已退役）"
else
  pass "D1-1: 脚本无 FORCE_PUSH 拦截决策块（单轨退役）"
fi
if grep -q "t.indexOf('f')" "$HOOK_SCRIPT"; then
  pass "D1-2: Phase-1 force 检出（短簇 'f' 检查）仍在（仅分类，不再拦截）"
else
  fail "D1-2: Phase-1 force 检出丢失"
fi
if grep -q -- "--no-force" "$HOOK_SCRIPT"; then
  pass "D1-3: --no-force 豁免在位（脚本 Phase-1）"
else
  fail "D1-3: --no-force 豁免缺失"
fi
if grep -q "kind === 'force'" "$WHEN_OPS"; then
  pass "D1-4: gates 结构化 force 判定在 when-ops（唯一防线载体）"
else
  fail "D1-4: when-ops push_refspec force 判定缺失"
fi

# --- D2: 行为面（脚本层透传） ---
echo ""
echo "--- D2 script passthrough on all force forms ---"
run_hook() {
  local cmd="$1" label="$2"
  local input stdout_file stderr_file actual_exit stderr_content
  input=$(printf '{"tool_input":{"command":"%s"}}' "$cmd")
  stdout_file=$(mktemp /tmp/pgf-out.XXXXXX)
  stderr_file=$(mktemp /tmp/pgf-err.XXXXXX)
  (
    cd "$NEUTRAL_DIR" || exit 99
    unset PROJECT_ROOT TARGET_REPO_ROOT GIT_ROOT
    unset MULTICA_AGENT_ID MULTICA_AGENT_NAME
    export MULTICA_TASK_ID=""
    echo "$input" | bash "$HOOK_SCRIPT" > "$stdout_file" 2> "$stderr_file"
  )
  actual_exit=$?
  stderr_content=$(cat "$stderr_file")
  rm -f "$stdout_file" "$stderr_file"

  # 单轨契约：脚本层对 force 无独立拦截决策 → 不得出现 force 拦 stderr。
  # （exit 可能因 Phase 3 no-repo 守卫为 2 —— 与 force 分类正交，不判。）
  if echo "$stderr_content" | grep -q "禁止 force-push"; then
    fail "$label（脚本层仍拦 force——双轨回潮）"
  else
    pass "$label"
  fi
}

run_hook "git push --force origin HEAD:refs/heads/feature/x" "F1: --force 脚本不拦"
run_hook "git push -f origin HEAD:refs/heads/feature/x" "F2: -f 脚本不拦"
run_hook "git push -fn origin HEAD:refs/heads/feature/x" "F3: -fn 脚本不拦"
run_hook "git push -uf origin HEAD:refs/heads/feature/x" "F4: -uf 脚本不拦"
run_hook "git push -fo origin HEAD:refs/heads/feature/x" "F5: -fo 脚本不拦"
run_hook "git push --force=true origin HEAD:refs/heads/feature/x" "F6: --force=true 脚本不拦"
run_hook "git push --force-with-lease origin HEAD:refs/heads/feature/x" "F7: --force-with-lease 脚本不拦"
run_hook "git push --force-with-lease=feature/x:abc123 origin HEAD:refs/heads/feature/x" "F8: --force-with-lease=ref:sha 脚本不拦"
run_hook "git push origin HEAD:refs/heads/feature/x --force" "F9: 句尾 --force 脚本不拦"
run_hook "git push --no-force origin HEAD:refs/heads/feature/x" "N1: --no-force 脚本不拦"

rm -rf "$NEUTRAL_DIR"
echo ""
echo "=== RESULTS: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
