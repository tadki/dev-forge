#!/bin/bash
# test_push_guard_devforge_exempt.sh
# dev-forge 仓库 push-guard 豁免 + repos.json 仓库门控作用域回归。
#
# 演进（Owner 正式方案 2026-11-03）：豁免升级为仓库门控作用域——
# 声明式门禁（rules.d/push-guard-gates.json）when 追加 repo op
# in:[kol,gqt]（凭 repos.json 注册的 origin git URL 判定），dev-forge
# 不在作用域即豁免；命令串 /dev-forge belt 防跨仓 -C 边角。
# 脚本层（push-guard.sh Phase 1b）维持路径/URL 锚点豁免，与注册表解耦。
#
# 三层覆盖：
#   A. 脚本层：canonical/workdir 检出全守卫豁免；非 dev-forge 仍拦。
#   B. 引擎层：devforge 作用域外放行；注册仓（含 URL 归一化形态）deny；
#      未注册仓作用域外放行（正式语义：门禁只管注册仓）；注册表缺失 fail-open
#      + WARN 审计。
#   C. validator：gates 规则 VALID + repo op 结构校验（in[] XOR registered）。
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
REG_FILE="$REPO_ROOT/claude-hooks/unified/repos.json"
RULES_V2="$REPO_ROOT/claude-hooks/unified/rules-v2.json"

KOL_GIT="https://github.com/tadki/KingOfLikes-Godot.git"

FIX="$(mktemp -d /tmp/pgdf-fixture.XXXXXX)"     # 脚本层/引擎层 fixture 仓
NEUTRAL="$(mktemp -d /tmp/pgdf-neutral.XXXXXX)" # 非 git 中性目录
STATE_DIR="$(mktemp -d /tmp/pgdf-state.XXXXXX)"
FIRE_LOG="$(mktemp -u /tmp/pgdf-fire.XXXXXX)"

# run_script <workdir> <command> → echo "exit\nstdout"
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

# run_engine <workdir> <command> [registry-path-override|DEFAULT] [rules-file] → engine stdout
# reg=DEFAULT 时不注入 HOOK_REPO_REGISTRY——钉住引擎默认注册表路径解析（生产口径）
run_engine() {
  local workdir="$1" cmd="$2" reg="${3:-$REG_FILE}" rules="${4:-$GATES_FILE}"
  local envreg=""
  [ "$reg" != "DEFAULT" ] && envreg="HOOK_REPO_REGISTRY=$reg"
  ( cd "$workdir" && \
    printf '{"tool_name":"Bash","hook_event_name":"PreToolUse","tool_input":{"command":"%s"}}' "$cmd" | \
    env UNIFIED_RULES_FILE="$rules" $envreg HOOK_STATE_DIR="$STATE_DIR" \
    HOOK_FIRE_LOG="$FIRE_LOG" HOOK_SCOPE_ID="pgdf-exempt-suite" \
    node "$ENGINE" 2>/dev/null )
}

echo "============================================"
echo "  dev-forge push-guard exemption + repo gating scope"
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

# 控制组 fixture：普通 origin（URL 不含 dev-forge），force 仍被拦（脚本层不依赖注册表）
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

# 引擎层 fixture：注册仓 origin（真实 KOL URL）+ GQT ssh 形态（归一化钉子）
git init -q -b master "$FIX/work_kol"
git -C "$FIX/work_kol" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$FIX/work_kol" remote add origin "$KOL_GIT"
git init -q -b master "$FIX/work_gqt_ssh"
git -C "$FIX/work_gqt_ssh" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$FIX/work_gqt_ssh" remote add origin "ssh://git@github.com/tadki/godot-qa-toolkit"
git init -q -b master "$FIX/work_scp"
git -C "$FIX/work_scp" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$FIX/work_scp" remote add origin "git@github.com:tadki/KingOfLikes-Godot"

# --- Group B: 引擎层 repo 作用域门禁 ---
echo ""
echo -e "${CYAN}--- Group B: engine-layer repo-scoped gates ---${NC}"

ea() { # engine-assert <label> <workdir> <cmd> <expect: allow|deny> [deny-grep] [registry-override]
  local label="$1" workdir="$2" cmd="$3" expect="$4" pattern="${5:-}" reg="${6:-$REG_FILE}"
  local out
  out=$(run_engine "$workdir" "$cmd" "$reg")
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

ea "B1 devforge canonical master 直推 → 作用域外放行" "$REPO_ROOT" "git push origin main" allow
ea "B2 devforge 子目录 cwd → 作用域外放行" "$REPO_ROOT/claude-hooks" "git push origin main" allow
ea "B3 devforge canonical force → 作用域外放行" "$REPO_ROOT" "git push --force origin main" allow
ea "B4 未注册仓 master 直推 → 作用域外放行（门禁只管注册仓）" "$FIX/work" "git push origin main" allow
ea "B5 未注册仓 force → 作用域外放行" "$FIX/work" "git push --force origin feature/x" allow
ea "B6 注册仓 kol（真实 origin URL）master 直推 → deny" "$FIX/work_kol" "git push origin main" deny "禁止直接 push"
ea "B7 注册仓 gqt（ssh 形态 URL 归一化）force → deny" "$FIX/work_gqt_ssh" "git push --force origin feature/x" deny "禁止 force-push"
ea "B8 kol 会话 -C dev-forge push → belt 防跨仓误拦" "$FIX/work_kol" "git -C $REPO_ROOT push origin main" allow

# 注册表缺失 → repo op 恒 false（fail-open 门禁）+ WARN 审计
ea "B9 注册表缺失 → 门禁 fail-open 放行" "$FIX/work_kol" "git push origin main" allow "" "/nonexistent/pgdf-registry.json"
if grep -q "repo-registry-unavailable" "$FIRE_LOG" 2>/dev/null; then
  pass "B9b 注册表缺失 WARN 已入 firelog 审计"
else
  fail "B9b — firelog 缺 repo-registry-unavailable 行"
fi

# B10（CRITICAL 回归，review PR#51）：生产默认口径——configFile = unified/rules-v2.json
# 且不注入 HOOK_REPO_REGISTRY，引擎必须经 __dirname 默认解析找到 repos.json → deny。
# 默认路径若解析错误（曾经 dirname³ 锚错为 <repo>/unified/），此处将放行而非 deny。
FIRE_B10=$(mktemp -u /tmp/pgdf-b10.XXXXXX)
B10_OUT=$( cd "$FIX/work_kol" && \
  printf '{"tool_name":"Bash","hook_event_name":"PreToolUse","tool_input":{"command":"git push origin main"}}' | \
  env UNIFIED_RULES_FILE="$RULES_V2" HOOK_STATE_DIR="$STATE_DIR" \
      HOOK_FIRE_LOG="$FIRE_B10" HOOK_SCOPE_ID="pgdf-b10" \
      node "$ENGINE" 2>/dev/null )
if printf '%s' "$B10_OUT" | grep -q "permissionDecision.:.deny"; then
  pass "B10 默认注册表路径（rules-v2 config + 无 env）→ deny"
else
  fail "B10 — 默认路径解析失败（期望 deny）: $B10_OUT"
fi
if grep -q "repo-registry-unavailable" "$FIRE_B10" 2>/dev/null; then
  fail "B10b — 默认路径不应产生注册表缺失 WARN"
else
  pass "B10b 默认路径无缺失 WARN"
fi

# B11：scp 形态 origin（git@host:path，无 .git 后缀）→ 归一化命中注册仓
ea "B11 注册仓 kol scp 形态 master 直推 → deny" "$FIX/work_scp" "git push origin main" deny "禁止直接 push"

# B12：registered:true 端到端 + git 多 URL 数组注册
C3_RULES=$(mktemp -u /tmp/pgdf-c3.XXXXXX).json
C3_REG=$(mktemp -u /tmp/pgdf-c3.XXXXXX).json
cat > "$C3_RULES" <<'EOF'
{"version":2,"rules":[{"name":"repo-reg-hit","on":{"in":["PreToolUse"]},"when":{"op":"repo","registered":true},"action":[{"op":"context","message":"[reg-hit] registered repo"}]}]}
EOF
cat > "$C3_REG" <<EOF
{"version":1,"repos":[{"id":"kolsplit","git":["$KOL_GIT","git@github.com:tadki:KingOfLikes-Godot"]}]}
EOF
C3_HIT=$(run_engine "$FIX/work_kol" "git status" "$C3_REG" "$C3_RULES")
if printf '%s' "$C3_HIT" | grep -q "additionalContext" && printf '%s' "$C3_HIT" | grep -q "reg-hit"; then
  pass "B12a registered:true 命中（多 URL 数组注册）→ context 注入"
else
  fail "B12a — 期望 reg-hit context，got: $C3_HIT"
fi
C3_MISS=$(run_engine "$FIX/work" "git status" "$C3_REG" "$C3_RULES")
if [ -z "$C3_MISS" ]; then
  pass "B12b 未注册仓 registered:true 不命中 → 无输出"
else
  fail "B12b — 未注册仓意外命中: $C3_MISS"
fi
rm -f "$C3_RULES" "$C3_REG"

# --- Group C: validator ---
echo ""
echo -e "${CYAN}--- Group C: rules validator ---${NC}"

VOUT=$(node "$VALIDATOR" "$GATES_FILE" 2>&1)
VRC=$?
if [ "$VRC" -eq 0 ] && echo "$VOUT" | grep -q "2 rules, 2 valid, 0 invalid"; then
  pass "C1 gates 规则（repo op 作用域）整体 VALID"
else
  fail "C1 validator: rc=$VRC out=$VOUT"
fi

# repo op 结构校验矩阵：in[] ok / registered ok / 双填 INVALID / 双空 INVALID
C_TMP=$(mktemp -u /tmp/pgdf-rules.XXXXXX).json
cat > "$C_TMP" <<'EOF'
{"version":2,"rules":[
 {"name":"repo-in-ok","on":{"in":["PreToolUse"]},"when":{"op":"repo","in":["kol"]},"action":[{"op":"context","message":"x"}]},
 {"name":"repo-reg-ok","on":{"in":["PreToolUse"]},"when":{"op":"repo","registered":true},"action":[{"op":"context","message":"x"}]},
 {"name":"repo-both-bad","on":{"in":["PreToolUse"]},"when":{"op":"repo","in":["kol"],"registered":true},"action":[{"op":"context","message":"x"}]},
 {"name":"repo-empty-bad","on":{"in":["PreToolUse"]},"when":{"op":"repo"},"action":[{"op":"context","message":"x"}]}
]}
EOF
C_OUT=$(node "$VALIDATOR" "$C_TMP" 2>&1); C_RC=$?
if [ "$C_RC" -eq 1 ] \
   && echo "$C_OUT" | grep -q "VALID   repo-in-ok" \
   && echo "$C_OUT" | grep -q "VALID   repo-reg-ok" \
   && echo "$C_OUT" | grep -q "INVALID repo-both-bad" \
   && echo "$C_OUT" | grep -q "INVALID repo-empty-bad"; then
  pass "C2 repo op 结构矩阵（in/registered XOR）符合预期"
else
  fail "C2 validator 矩阵: rc=$C_RC out=$C_OUT"
fi
rm -f "$C_TMP"

# --- Summary ---
rm -rf "$FIX" "$NEUTRAL" "$STATE_DIR"; rm -f "$FIRE_LOG"
echo ""
echo "============================================"
echo -e "${CYAN}Results:${NC} ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "============================================"
[ "$FAIL" -eq 0 ] && echo -e "${GREEN}Overall: PASS${NC}" && exit 0 \
  || echo -e "${RED}Overall: FAIL ($FAIL failures)${NC}" && exit 1
