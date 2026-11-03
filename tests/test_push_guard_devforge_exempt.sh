#!/bin/bash
# test_push_guard_devforge_exempt.sh
# dev-forge 仓库 push-guard 豁免回归（Owner 指令 2026-11-03）。
#
# 豁免实现分两层，本套件三层覆盖：
#   A. 脚本层 push-guard.sh Phase 1b：push 目标仓库根 == hooks 部署仓库根，
#      或目标 origin URL 含 dev-forge → 全部守卫豁免（master/force/祖先/NO_REFSPEC）。
#   B. 引擎层 rules.d/push-guard-gates.json：cwd 位于 dev-forge 检出内（路径分量
#      dev-forge）或命令串含 /dev-forge → 两条声明式门禁不命中；其他仓库照常拦截。
#   C. validator：gates 规则文件（含新 cwd op）整体 VALID。
#
# Test Type: Regression + Boundary
set -uo pipefail

# 身份隔离：豁免与身份无关，锁非白名单 agent 钉住这一点（see954 同型）。
export MULTICA_AGENT_ID="a5c250e8-7277-466e-b45a-03f995c7206c"  # Bachi
export MULTICA_AGENT_NAME="Bachi"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'
PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SCRIPT="$REPO_ROOT/claude-hooks/scripts/push-guard.sh"
ENGINE="$REPO_ROOT/claude-hooks/unified/engine.js"
GATES_FILE="$REPO_ROOT/claude-hooks/unified/rules.d/push-guard-gates.json"
VALIDATOR="$REPO_ROOT/claude-hooks/validate-rules.js"

FIX="$(mktemp -d /tmp/pgdf-fixture.XXXXXX)"     # 脚本层 fixture 仓
NEUTRAL="$(mktemp -d /tmp/pgdf-neutral.XXXXXX)" # 引擎层非 dev-forge cwd
STATE_DIR="$(mktemp -d /tmp/pgdf-state.XXXXXX)"
FIRE_LOG="$(mktemp -u /tmp/pgdf-fire.XXXXXX)"

# run_script <workdir> <command-json-escaped> → echo "exit\nstdout"
run_script() {
  local workdir="$1" cmd="$2"
  local input out rc
  input=$(printf '{"tool_input":{"command":"%s"}}' "$cmd")
  out=$( cd "$workdir" && unset PROJECT_ROOT TARGET_REPO_ROOT && \
         printf '%s' "$input" | bash "$HOOK_SCRIPT" 2>/dev/null )
  rc=$?
  echo "$rc"
  printf '%s' "$out"
}

# run_engine <workdir> <command> → engine stdout（空 = 无 deny）
run_engine() {
  local workdir="$1" cmd="$2"
  ( cd "$workdir" && \
    printf '{"tool_name":"Bash","hook_event_name":"PreToolUse","tool_input":{"command":"%s"}}' "$cmd" | \
    UNIFIED_RULES_FILE="$GATES_FILE" HOOK_STATE_DIR="$STATE_DIR" \
    HOOK_FIRE_LOG="$FIRE_LOG" HOOK_SCOPE_ID="pgdf-exempt-suite" \
    node "$ENGINE" 2>/dev/null )
}

echo "============================================"
echo "  dev-forge push-guard exemption (Owner 2026-11-03)"
echo "  Date: $(date -Iseconds)"
echo "============================================"

# --- Group A: push-guard.sh 脚本层豁免 ---
echo ""
echo -e "${CYAN}--- Group A: script-layer exemption ---${NC}"

sa() { # script-assert <label> <workdir> <cmd> <expected-exit> [expect-passthrough]
  local label="$1" workdir="$2" cmd="$3" want="$4" pt="${5:-}"
  local res out rc
  res=$(run_script "$workdir" "$cmd")
  rc=$(echo "$res" | head -1)
  out=$(echo "$res" | tail -n +2)
  local input; input=$(printf '{"tool_input":{"command":"%s"}}' "$cmd")
  if [ "$rc" -eq "$want" ]; then
    if [ -n "$pt" ] && [ "$out" != "$input" ]; then
      fail "$label — exit ok but stdout != passthrough (got: $out)"
      return
    fi
    pass "$label (exit $want)"
  else
    fail "$label — exit: got $rc, expected $want"
  fi
}

sa "A1 canonical 检出 master 直推 → 0+透传" "$REPO_ROOT" "git push origin main" 0 pt
sa "A2 canonical 检出 force-push → 0+透传"  "$REPO_ROOT" "git push --force-with-lease origin main" 0 pt
sa "A3 canonical 检出 no-refspec(main) → 0+透传" "$REPO_ROOT" "git push" 0 pt
sa "A4 子目录 cwd（claude-hooks/）→ 0+透传" "$REPO_ROOT/claude-hooks" "git push origin main" 0 pt
sa "A5 外部 cwd + git -C dev-forge → 0+透传" "$NEUTRAL" "git -C $REPO_ROOT push origin main" 0 pt

# 控制组 fixture：普通 origin（URL 不含 dev-forge），force 仍被拦
git init -q -b master "$FIX/work"
git -C "$FIX/work" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git init -q --bare "$FIX/origin.git"
git -C "$FIX/work" remote add origin "$FIX/origin.git"
git -C "$FIX/work" push -q -u origin master 2>/dev/null
sa "A6 非 dev-forge 仓 force-push → 2（仍拦截）" "$FIX/work" "git push --force origin master" 2

# URL 锚点组：workdir 检出（根 ≠ 部署位），origin URL 含 dev-forge → 豁免
git init -q -b master "$FIX/work2"
git -C "$FIX/work2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git init -q --bare "$FIX/dev-forge.git"
git -C "$FIX/work2" remote add origin "$FIX/dev-forge.git"
git -C "$FIX/work2" push -q -u origin master 2>/dev/null
sa "A7 workdir 检出 origin 含 dev-forge → 0+透传" "$FIX/work2" "git push origin master" 0 pt

# --- Group B: 引擎层 gates 门禁豁免 ---
echo ""
echo -e "${CYAN}--- Group B: engine-layer gate exemption ---${NC}"

ea() { # engine-assert <label> <workdir> <cmd> <expect: allow|deny> [deny-grep]
  local label="$1" workdir="$2" cmd="$3" expect="$4" pattern="${5:-}"
  local out
  out=$(run_engine "$workdir" "$cmd")
  if [ "$expect" = "allow" ]; then
    if [ -z "$out" ]; then pass "$label — no deny"; else fail "$label — unexpected output: $out"; fi
  else
    if printf '%s' "$out" | grep -q "permissionDecision.:.deny" && \
       { [ -z "$pattern" ] || printf '%s' "$out" | grep -q "$pattern"; }; then
      pass "$label — denied"
    else
      fail "$label — expected deny ($pattern), got: $out"
    fi
  fi
}

ea "B1 dev-forge cwd master 直推 → 门禁不命中" "$REPO_ROOT" "git push origin main" allow
ea "B2 dev-forge 子目录 cwd → 门禁不命中" "$REPO_ROOT/claude-hooks" "git push origin main" allow
ea "B3 dev-forge cwd force → 门禁不命中" "$REPO_ROOT" "git push --force origin main" allow
ea "B4 其他 cwd master 直推 → 仍 deny" "$NEUTRAL" "git push origin main" deny "禁止直接 push"
ea "B5 其他 cwd force → 仍 deny" "$NEUTRAL" "git push --force origin feature/x" deny "禁止 force-push"
ea "B6 其他 cwd + 命令指涉 /dev-forge → 不命中" "$NEUTRAL" "git -C $REPO_ROOT push origin main" allow

# --- Group C: validator ---
echo ""
echo -e "${CYAN}--- Group C: rules validator ---${NC}"

VOUT=$(node "$VALIDATOR" "$GATES_FILE" 2>&1)
VRC=$?
if [ "$VRC" -eq 0 ] && echo "$VOUT" | grep -q "2 rules, 2 valid, 0 invalid"; then
  pass "C1 gates 规则（含 cwd op）整体 VALID"
else
  fail "C1 validator: rc=$VRC out=$VOUT"
fi

# --- Summary ---
rm -rf "$FIX" "$NEUTRAL" "$STATE_DIR"; rm -f "$FIRE_LOG"
echo ""
echo "============================================"
echo -e "${CYAN}Results:${NC} ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "============================================"
[ "$FAIL" -eq 0 ] && echo -e "${GREEN}Overall: PASS${NC}" && exit 0 \
  || echo -e "${RED}Overall: FAIL ($FAIL failures)${NC}" && exit 1
