#!/usr/bin/env bash
# §SPEC-022 (SEE-1516 substep E2, fingerprint 7501c09c15a4):
# push-guard gates/脚本 token 解析结构化改造的 FP/FN 用例集。
#
# FP（不得误拦）：
#   push 到 main-branch / maintenance / feature/master-docs 类分支名
# FN（必须拦）：
#   句尾 -f / -nf 短簇 / +refspec 加号 force / HEAD:master 无空格形态 /
#   git -C dir push（gates 声明式 pattern 曾漏）
# 零回归（必须拦，现行行为保持）：
#   git push origin master / HEAD:refs/heads/master / --force / --force-with-lease
#   --no-force 显式豁免不拦 force 门
set -uo pipefail

# SEE-1516 tidy（Atlas 指定处置）：隔离宿主 agent/会话环境变量。本套件的
# 期望建立在「无 whitelist agent」的确定性基线上（见下方脚本层注释）——宿主
# 运行环境的 MULTICA_AGENT_ID/NAME（如 Atlas 运行时）若泄漏，会触发 agent
# 白名单/agents 门控路径使 FORCE/MASTER 判定漂移而假红。只清环境、不动判据，
# 与 test_auto_pr_on_stop_boundary_cases.sh:34 的既有隔离惯例同款。
unset MULTICA_TASK_ID MULTICA_AGENT_ID MULTICA_AGENT_NAME \
      MULTICA_TOKEN MULTICA_SERVER_URL MULTICA_WORKSPACE_ID

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/claude-hooks/unified/engine.js"
GATES="$ROOT/claude-hooks/unified/rules.d/push-guard-gates.json"
GUARD="$ROOT/claude-hooks/scripts/push-guard.sh"
PASS=0; FAIL=0

ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# --- fixtures: 注册 kol 仓的临时检出 + 注册表 -----------------------------------
FIX=$(mktemp -d /tmp/pgref-XXXXXX)
trap 'rm -rf "$FIX"' EXIT
git init -q -b master "$FIX/kol"
git -C "$FIX/kol" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$FIX/kol" remote add origin "https://github.com/tadki/KingOfLikes-Godot.git"
REG="$FIX/registry.json"
cat > "$REG" <<EOF
{"version":1,"repos":[{"id":"kol","git":["https://github.com/tadki/KingOfLikes-Godot.git"]}]}
EOF
STATE=$(mktemp -d /tmp/pgref-state-XXXXXX)

# --- gates 层（引擎 + gates 规则） ----------------------------------------------
gate() { # gate <cmd> → 引擎 stdout（deny 文案或空）
  ( cd "$FIX/kol" && \
    printf '{"tool_name":"Bash","hook_event_name":"PreToolUse","tool_input":{"command":"%s"}}' "$1" | \
    env UNIFIED_RULES_FILE="$GATES" HOOK_REPO_REGISTRY="$REG" HOOK_STATE_DIR="$STATE" \
        HOOK_FIRE_LOG="$FIX/fire.log" HOOK_SCOPE_ID="pgref" \
        node "$ENGINE" 2>/dev/null )
}

gate_expect_deny() { # <label> <cmd> <message-substr>
  local out; out=$(gate "$2")
  if printf '%s' "$out" | grep -q "permissionDecision.:.deny" && printf '%s' "$out" | grep -qF "$3"; then
    ok "$1"
  else
    bad "$1 — got: $(printf '%s' "$out" | head -c 160)"
  fi
}
gate_expect_allow() { # <label> <cmd>
  local out; out=$(gate "$2")
  if [ -z "$out" ]; then
    ok "$1"
  else
    bad "$1 — 意外命中: $(printf '%s' "$out" | head -c 160)"
  fi
}

echo "--- gates 层: FP 用例（不得误拦） ---"
gate_expect_allow "FP1 push origin main-branch 不误拦"        "git push origin main-branch"
gate_expect_allow "FP2 push origin maintenance 不误拦"        "git push origin maintenance"
gate_expect_allow "FP3 push origin feature/master-docs 不误拦" "git push origin feature/master-docs"

echo "--- gates 层: FN 用例（必须拦） ---"
gate_expect_deny "FN1 句尾 -f → force 门"                     "git push origin feature/x -f" "禁止 force-push"
gate_expect_deny "FN2 -nf 短簇 → force 门"                    "git push -nf origin feature/x" "禁止 force-push"
gate_expect_deny "FN3 +refspec 加号 force → force 门"         "git push origin +feature/x" "禁止 force-push"
gate_expect_deny "FN4 +HEAD:refs/heads/master → 双门命中"      "git push origin +HEAD:refs/heads/master" "禁止"
gate_expect_deny "FN5 git -C dir push master → master 门"     "git -C $FIX/kol push origin master" "禁止直接 push"
gate_expect_deny "FN6 HEAD:master 无空格形态 → master 门"      "git push origin HEAD:master" "禁止直接 push"

echo "--- gates 层: 零回归（现行拦截保持） ---"
gate_expect_deny "R1 直推 master → master 门"                  "git push origin master" "禁止直接 push"
gate_expect_deny "R2 直推 main → master 门"                    "git push origin main" "禁止直接 push"
gate_expect_deny "R3 HEAD:refs/heads/master → master 门"       "git push origin HEAD:refs/heads/master" "禁止直接 push"
gate_expect_deny "R4 --force → force 门"                       "git push --force origin feature/x" "禁止 force-push"
gate_expect_deny "R5 --force-with-lease → force 门"            "git push --force-with-lease origin feature/x" "禁止 force-push"

echo "--- gates 层: 硬化补测（+master/引号形态/force+no-force 组合） ---"
gate_expect_deny "FN7 +master 加号形态 → master 门"            "git push origin +master" "禁止直接 push"
gate_expect_deny "FN8 引号包裹 \"master\" → master 门"         'git push origin \"master\"' "禁止直接 push"
gate_expect_allow "NF2 --force --no-force 组合显式豁免"        "git push --force --no-force origin feature/x"

echo "--- gates 层: --no-force 显式豁免 ---"
gate_expect_allow "NF1 --no-force 不触发 force 门"             "git push --no-force origin feature/x"

# --- 脚本层（push-guard.sh Phase 1 判定） ---------------------------------------
guard_expect() { # <label> <cmd> <expected-verdict>
  local label="$1" cmd="$2" want="$3"
  local input; input=$(printf '{"tool_input":{"command":"%s"}}' "$cmd")
  local out rc
  out=$(cd "$FIX/kol" && printf '%s' "$input" | bash "$GUARD" 2>/dev/null); rc=$?
  # 脚本层在 kol 检出：MASTER_PUSH→exit2；SAFE_PUSH 走后续 checks
  case "$want" in
    FORCE)
      # 走到 force 段被拦 exit2（多 agent 提示）
      [ "$rc" -eq 2 ] && ok "$1" || bad "$1 — rc=$rc want=2"
      ;;
    MASTER_BLOCK)
      [ "$rc" -eq 2 ] && ok "$1" || bad "$1 — rc=$rc want=2"
      ;;
    NOT_MASTER)
      # 非 master：Phase2 不拦；Phase3 ancestry 可能拦（fixture 无 upstream）——
      # 只判 stderr 不含 master 直推文案
      if printf '%s' "$out" | grep -qF "禁止直接推送到 master"; then bad "$1 — 误拦"; else ok "$1"; fi
      ;;
  esac
}

echo "--- 脚本层: FP/FN 用例 ---"
# 注意：脚本层在无 whitelist agent 的环境下 FORCE_PUSH/MASTER_PUSH 均 exit2
guard_expect "S-FP1 main-branch 不判 MASTER"    "git push origin main-branch"        NOT_MASTER
guard_expect "S-FN1 句尾 -f 判 FORCE"           "git push origin feature/x -f"       FORCE
guard_expect "S-FN2 -nf 短簇判 FORCE"           "git push -nf origin feature/x"      FORCE
guard_expect "S-FN3 +refspec 判 FORCE"          "git push origin +feature/x"         FORCE
guard_expect "S-R1 直推 master 判 MASTER"       "git push origin master"             MASTER_BLOCK
guard_expect "S-FN4 HEAD:master 判 MASTER"      "git push origin HEAD:master"        MASTER_BLOCK
guard_expect "S-NF1 --no-force 豁免"            "git push --no-force origin feature/x" NOT_MASTER

echo ""
if [ "$FAIL" -eq 0 ]; then echo "push_refspec FP/FN suite: ALL PASS ($PASS)"; exit 0; fi
echo "push_refspec FP/FN suite: FAIL ($FAIL of $((PASS+FAIL)))"
exit 1
