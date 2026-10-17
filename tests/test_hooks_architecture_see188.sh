#!/bin/bash
# test_hooks_architecture_see188.sh — v2 终态重写（SEE-1330 P4 收敛批）
# 原版巡检 v1 三层架构（wrapper → dispatcher alias 路由 → 散装业务脚本）；
# P4 收敛后架构 = wrapper → dispatcher（仅 unified-hook，全局部署位优先）→
# unified-hook.sh → engine.js（rules-v2.json + rules.d/*.json 配置驱动 / run_script 挂载）。
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0
pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); }
separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISPATCHER="$REPO_ROOT/hooks/dispatcher.sh"
UNIFIED="$REPO_ROOT/hooks/unified"
ENGINE="$UNIFIED/engine.js"
ENTRY="$UNIFIED/unified-hook.sh"
WHEN_OPS="$UNIFIED/when-ops.js"
RULES="$UNIFIED/rules-v2.json"
RULES_D="$UNIFIED/rules.d/runscript-mounts.json"
MANIFEST="$REPO_ROOT/bootstrap/hooks-registration.json"
INSTALLER="$REPO_ROOT/bootstrap/bootstrap.sh"
VALIDATOR="$REPO_ROOT/hooks/unified/validate-rules.js"

separator "1. 调用链组件在位"
for f in "$DISPATCHER" "$ENGINE" "$ENTRY" "$WHEN_OPS" "$RULES" "$RULES_D" "$MANIFEST" "$INSTALLER" "$VALIDATOR" \
         "$REPO_ROOT/hooks/scripts/gdformat-gdlint.sh" \
         "$REPO_ROOT/hooks/scripts/mention-check.sh" \
         "$REPO_ROOT/hooks/scripts/push-guard.sh" \
         "$REPO_ROOT/hooks/scripts/auto-pr-on-stop.sh" \
         "$REPO_ROOT/hooks/scripts/repo-checkout.sh" \
         "$REPO_ROOT/hooks/scripts/atlas-taskflow-mark-a.sh" \
         "$REPO_ROOT/hooks/scripts/atlas-taskflow-mark-b.sh" \
         "$REPO_ROOT/hooks/scripts/atlas-taskflow-exit-reminder.sh"; do
  [ -f "$f" ] && pass "在位: $(basename "$f")" || fail "缺失: $f"
done

separator "2. dispatcher 单一路由收敛"
if grep -q 'unified-hook)' "$DISPATCHER"; then pass "unified-hook case 在位"; else fail "unified-hook case 缺失"; fi
V1_CASES=$(grep -cE "^[[:space:]]+(skill-check|skill-check-post|mention-check|push-guard|auto-pr|tscn-tres-guard|gdformat-gdlint)\)" "$DISPATCHER" 2>/dev/null)
V1_CASES=${V1_CASES:-0}
[ "$V1_CASES" -eq 0 ] && pass "v1 alias case = 0（单一路由）" || fail "v1 alias case 残留 $V1_CASES 个"
if grep -q 'pwd)/unified/unified-hook.sh' "$DISPATCHER"; then pass "自定位路由在位（dev-forge 最终态）"; else fail "unified-hook 路由缺失"; fi

separator "3. v1 兼容层退役"
[ ! -f "$UNIFIED/desugar.js" ] && pass "desugar.js 已退役" || fail "desugar.js 仍存在"
grep -rq 'v1_compat\|v1_rules_file' "$UNIFIED" 2>/dev/null && fail "unified 树存在 v1 兼容字段残留" || pass "unified 树 v1 兼容字段零残留"
[ -f "$REPO_ROOT/hooks/pre-comment-skill-check.sh" ] || [ -f "$REPO_ROOT/hooks/tscn-tres-guard.sh" ] \
  && echo -e "  ${CYAN}[NOTE]${NC} 死文件物理删除随 S22 §7.2 裁定收尾批执行（当前允许留仓）" \
  || pass "v1 死文件已物理删除"

separator "4. 规则与校验器自洽"
R2=$(node -e "const c=require('$RULES'); console.log(c.rules.length)" 2>/dev/null || echo ERR)
RD=$(node -e "const c=require('$RULES_D'); console.log(c.rules.length)" 2>/dev/null || echo ERR)
if [ "$R2" != "ERR" ] && [ "$RD" != "ERR" ]; then pass "rules-v2=$R2 条 + rules.d=$RD 条 可解析"; else fail "规则文件解析失败 (r2=$R2 rd=$RD)"; fi
node "$VALIDATOR" "$RULES" >/dev/null 2>&1 && pass "rules-v2 validator VALID" || fail "rules-v2 validator 未通过"
node "$VALIDATOR" "$RULES_D" >/dev/null 2>&1 && pass "rules.d validator VALID" || fail "rules.d validator 未通过"

separator "SUMMARY"
echo -e "  Pass: $PASS  Fail: $FAIL"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
