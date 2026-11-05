#!/bin/bash
# test_push_guard_parser_stack_see1530.sh
# SEE-1530 push-guard 命令解析栈硬化回归：预存漏拦 RC 四族 8 形态恢复 deny 主语义
# + belt 边角误拦 OB-1/2/3/5 兼容 + 脚本轨道同族审计钉。
#
# 判据锚点（issue §SPEC-001/002/003/004）：
#   RC-A 旗标精化   `git -p/-P/-pC <dir> push` 恢复 deny（无值短旗标不吞 push 词，
#                   合并簇逐字符；-C/-c 真带值旗标跳值语义保留 = SEE-1516 零回归）。
#   RC-B 分段增强   单 `&` / 单 `|` 亦为命令分隔（重定向组合 &> >& |> 与 || && |&
#                   边界除外）；每段多 push 全解析（belt all 口径 + push_refspec）。
#   RC-C exclude 实例级  `--delete <ref>` 成对消费，混合 refspec（真实 push main +
#                   删 tmpb）不再整段滤除；纯删除 push（Owner 定案）仍不走本门。
#   RC-D tokenize 边角   无空格圆括号 `(git ...)`、注释隐藏第二 push 恢复 deny；
#                   引号串为单 token（内嵌命令文本天然不参与 = 引号感知）。
#   OB-1/2/3 belt 兼容   附着短旗标 `-C<path>`、引号路径剥离、cd 旗标（-P）跳值。
#   OB-5 双 -C 相对链    按 git 真实语义锚定（后续非绝对 -C 相对前一个 -C）→ allow；
#                   对照链指向注册仓 → deny（修复不外溢）。
#   OB-4 别名远端   行为冻结零改动（diff 审查留证，本套件不为其加钉——钉 allow =
#                   祝福 FN，钉 deny = 套件红； Owner 未裁决前不纳入管辖）。
#   脚本轨道（push-guard.sh phase-1）  `git -p push`（裸 push）在 master 分支曾被
#                   判 NOT_PUSH 整段放行——Check 4（裸 push 直推 master 唯一拦截点，
#                   gates refspec op 对无 refspec 形态不可见）被绕过（双轨联合探针
#                   实测逃逸确认）。旗标判定与 unified 引擎同族精化后恢复拦截。
#
# Test Type: Regression + Boundary
set -uo pipefail

# 身份隔离：与检出位置/agent 身份无关（see954 同型锁）
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
REG_FILE="$REPO_ROOT/claude-hooks/unified/repos.json"

KOL_GIT="https://github.com/tadki/KingOfLikes-Godot.git"
DF_GIT="https://github.com/tadki/dev-forge.git"

FIX="$(mktemp -d /tmp/pgps-fixture.XXXXXX)"
STATE_DIR="$(mktemp -d /tmp/pgps-state.XXXXXX)"
FIRE_LOG="$(mktemp -u /tmp/pgps-fire.XXXXXX)"

# mktemp 目录名不含 /dev-forge 字面量——套件断言与检出位置解耦（pgdf B8 同口径）
git init -q -b master "$FIX/work_kol"
git -C "$FIX/work_kol" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$FIX/work_kol" remote add origin "$KOL_GIT"

git init -q -b main "$FIX/work_df_url"
git -C "$FIX/work_df_url" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$FIX/work_df_url" remote add origin "$DF_GIT"

git init -q -b master "$FIX/work_plain"
git -C "$FIX/work_plain" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git init -q --bare "$FIX/origin.git"
git -C "$FIX/work_plain" remote add origin "$FIX/origin.git"

# OB-5 链 fixture：$FIX/ob5dir = devforge 检出（经 `-C $FIX -C ob5dir` 相对链可达）
git init -q -b main "$FIX/ob5dir"
git -C "$FIX/ob5dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$FIX/ob5dir" remote add origin "$DF_GIT"

# 脚本轨道 fixture：master 分支 + upstream origin/master（Check 4 拦截面）与
# feature 分支对照（无新增误拦面）
git init -q -b master "$FIX/work_master"
git -C "$FIX/work_master" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$FIX/work_master" remote add origin "$FIX/origin.git"
git -C "$FIX/work_master" push -q -u origin master 2>/dev/null
git init -q -b feature/x "$FIX/work_feat"
git -C "$FIX/work_feat" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$FIX/work_feat" remote add origin "$FIX/origin.git"
git -C "$FIX/work_feat" push -q -u origin feature/x 2>/dev/null

# run_engine <workdir> <command> → engine stdout（命令 JSON 转义：OB-2 引号形态必需）
json_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
run_engine() {
  local workdir="$1" cmd="$2"
  ( cd "$workdir" && \
    printf '{"tool_name":"Bash","hook_event_name":"PreToolUse","tool_input":{"command":"%s"}}' "$(json_esc "$cmd")" | \
    env UNIFIED_RULES_FILE="$GATES_FILE" HOOK_REPO_REGISTRY="$REG_FILE" HOOK_STATE_DIR="$STATE_DIR" \
    HOOK_FIRE_LOG="$FIRE_LOG" HOOK_SCOPE_ID="pgps-see1530-suite" \
    node "$ENGINE" 2>/dev/null )
}

# ea <label> <workdir> <cmd> <expect: allow|deny> [deny-grep]
ea() {
  local label="$1" workdir="$2" cmd="$3" expect="$4" pattern="${5:-}"
  local out
  out=$(run_engine "$workdir" "$cmd")
  if [ "$expect" = "allow" ]; then
    if [ -z "$out" ]; then pass "$label"; else fail "$label — unexpected output: $out"; fi
  else
    if printf '%s' "$out" | grep -q "permissionDecision.:.deny" && \
       { [ -z "$pattern" ] || printf '%s' "$out" | grep -q "$pattern"; }; then
      pass "$label"
    else
      fail "$label — expected deny ($pattern), got: $out"
    fi
  fi
}

# run_script <workdir> <command> → echo "exit\nstdout"
run_script() {
  local workdir="$1" cmd="$2"
  local input out rc
  input=$(printf '{"tool_input":{"command":"%s"}}' "$(json_esc "$cmd")")
  out=$( cd "$workdir" && unset PROJECT_ROOT TARGET_REPO_ROOT && \
         printf '%s' "$input" | bash "$HOOK_SCRIPT" 2>/dev/null )
  rc=$?
  echo "$rc"
  printf '%s' "$out"
}

# sa <label> <workdir> <cmd> <expected-exit> [expect-passthrough]
sa() {
  local label="$1" workdir="$2" cmd="$3" want="$4" pt="${5:-}"
  local res out rc input
  res=$(run_script "$workdir" "$cmd")
  rc=$(echo "$res" | head -1)
  out=$(echo "$res" | tail -n +2)
  input=$(printf '{"tool_input":{"command":"%s"}}' "$(json_esc "$cmd")")
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

echo "============================================"
echo "  SEE-1530 push-guard parser stack regression"
echo "  Date: $(date -Iseconds)"
echo "============================================"

echo ""
echo -e "${CYAN}--- Group RC: 四族 8 形态恢复 deny 主语义（§SPEC-001）---${NC}"

# RC-A：旗标精化——无值短旗标 -p/-P 不吞 push 词；-pC 合并簇逐字符判定
ea "RC-A1 kol: git -p push origin main → deny"        "$FIX/work_kol" "git -p push origin main" deny "禁止直接 push"
ea "RC-A2 kol: git -P push origin main → deny"        "$FIX/work_kol" "git -P push origin main" deny "禁止直接 push"
ea "RC-A3 kol: git -pC kol push origin main → deny"   "$FIX/work_kol" "git -pC $FIX/work_kol push origin main" deny "禁止直接 push"

# RC-B：单 & / 单 | 分段——第二段注册仓 push 不再逃逸（belt all 口径 + refspec）
ea "RC-B1 kol: 单&双 push（df+kol）→ deny"            "$FIX/work_kol" "git -C $FIX/work_df_url push origin main & git -C $FIX/work_kol push origin main" deny "禁止直接 push"
ea "RC-B2 kol: 单|双 push（df+kol）→ deny"            "$FIX/work_kol" "git -C $FIX/work_df_url push origin main | git -C $FIX/work_kol push origin main" deny "禁止直接 push"

# RC-C：exclude 实例级——混合 refspec（真实推 main + 删 tmpb）不再整段滤除
ea "RC-C1 kol: push origin main --delete tmpb → deny" "$FIX/work_kol" "git -C $FIX/work_kol push origin main --delete tmpb" deny "禁止直接 push"
ea "RC-C2 kol: push origin main -d tmpb → deny"       "$FIX/work_kol" "git -C $FIX/work_kol push origin main -d tmpb" deny "禁止直接 push"

# RC-D：tokenize 边角——无空格圆括号、注释隐藏第二 push
ea "RC-D1 kol: (git -C kol push origin main) → deny"  "$FIX/work_kol" "(git -C $FIX/work_kol push origin main)" deny "禁止直接 push"
ea "RC-D2 kol: 注释隐藏第二 push → deny"              "$FIX/work_kol" "git -C $FIX/work_df_url push origin main # git -C $FIX/work_kol push origin main" deny "禁止直接 push"

echo ""
echo -e "${CYAN}--- Group OB: belt 边角误拦消除（§SPEC-002 / §SPEC-003）---${NC}"

# OB-1：附着短旗标 -C<path>
ea "OB-1a kol: -C<path> 附着旗标 push origin main → allow"  "$FIX/work_kol" "git -C$FIX/work_df_url push origin main" allow
ea "OB-1b kol: -C<path> 附着旗标裸 push → allow（SPEC 原形态）" "$FIX/work_kol" "git -C$FIX/work_df_url push" allow

# OB-2：引号路径剥离（引号不进入路径解析）
ea "OB-2a kol: -C \"path\" 引号 push origin main → allow"   "$FIX/work_kol" "git -C \"$FIX/work_df_url\" push origin main" allow
ea "OB-2b kol: -C \"path\" 引号裸 push → allow（SPEC 原形态）" "$FIX/work_kol" "git -C \"$FIX/work_df_url\" push" allow

# OB-3：cd 旗标（-P）跳值
ea "OB-3a kol: cd -P path && push origin main → allow"      "$FIX/work_kol" "cd -P $FIX/work_df_url && git push origin main" allow
ea "OB-3b kol: cd -P path && 裸 push → allow（SPEC 原形态）"  "$FIX/work_kol" "cd -P $FIX/work_df_url && git push" allow

# OB-5：双 -C 相对链按 git 语义锚定（后续非绝对 -C 相对前一个 -C 的目录）
ea "OB-5a kol: -C abs -C rel 链指向 devforge → allow"        "$FIX/work_kol" "git -C $FIX -C ob5dir push origin main" allow
ea "OB-5b kol: -C abs -C rel 链指向注册仓 → deny（不外溢）"   "$FIX/work_kol" "git -C $FIX -C work_kol push origin main" deny "禁止直接 push"

echo ""
echo -e "${CYAN}--- Group BND: 既有语义哨兵（§SPEC-004 零弱化 / SEE-1516 锚）---${NC}"

# SEE-1516 锚：真带值旗标跳值语义保留
ea "BND1 kol: git -C kol push origin master → deny（SEE-1516 锚）"  "$FIX/work_kol" "git -C $FIX/work_kol push origin master" deny "禁止直接 push"
ea "BND2 kol: git -C kol push origin main → deny（SEE-1516 锚）"    "$FIX/work_kol" "git -C $FIX/work_kol push origin main" deny "禁止直接 push"
ea "BND3 kol: git -c key=val push origin main → deny（-c 带值跳值保留）" "$FIX/work_kol" "git -c foo.bar=1 push origin main" deny "禁止直接 push"
ea "BND4 kol: git --no-pager push origin main → deny（长旗标逐跳保留）"  "$FIX/work_kol" "git --no-pager push origin main" deny "禁止直接 push"
ea "BND5 kol: --no-pager -C df → allow（长旗标+带值混合豁免保留）"    "$FIX/work_kol" "git --no-pager -C $FIX/work_df_url push origin main" allow

# 对照 deny 形态（Harti/Revy 实测对照面保持）
ea "BND6 kol: 带空格圆括号 ( git push ) → deny"              "$FIX/work_kol" "( git -C $FIX/work_kol push origin main )" deny "禁止直接 push"
ea "BND7 kol: 花括号组 { git push; } → deny"                 "$FIX/work_kol" "{ git -C $FIX/work_kol push origin main; }" deny "禁止直接 push"
ea "BND8 kol: GIT_DIR= 环境前缀 → deny（belt 锚不认 env 前缀）" "$FIX/work_kol" "GIT_DIR=$FIX/work_df_url/.git git push origin main" deny "禁止直接 push"
ea "BND9 kol: bash -c 嵌套 push → deny"                      "$FIX/work_kol" "bash -c \"git -C $FIX/work_kol push origin main\" &" deny "禁止直接 push"
ea "BND10 kol: -C 未注册仓 → deny（B8d 同族哨兵）"            "$FIX/work_kol" "git -C $FIX/work_plain push origin main" deny "禁止直接 push"

# 删除形态边界（Owner 定案：纯删除不走本门；冒号删除仍属 master 门）
ea "BND11 kol: 纯 --delete tmpb → allow"                     "$FIX/work_kol" "git -C $FIX/work_kol push origin --delete tmpb" allow
ea "BND12 kol: 纯 --delete 误带 -f → allow（纯删除判定优先）"  "$FIX/work_kol" "git -C $FIX/work_kol push origin --delete tmpb -f" allow
ea "BND13 kol: :refs/heads/main 冒号删除 → deny"             "$FIX/work_kol" "git -C $FIX/work_kol push origin :refs/heads/main" deny "禁止直接 push"
ea "BND14 kol: 混合 refspec + -f → deny（真实 push + force）"  "$FIX/work_kol" "git -C $FIX/work_kol push origin main --delete tmpb -f" deny "禁止 force-push"

# 复合命令 all 口径（RC-B 修复后的 belt 双侧）
ea "BND15 kol: && 双 devforge 复合 → allow（B8l 同族哨兵）"   "$FIX/work_kol" "git -C $FIX/work_df_url push origin main && git -C $FIX/work_df_url push origin feature/x" allow
ea "BND16 kol: 单& 双 devforge 复合 → allow（all 口径跨分段）" "$FIX/work_kol" "git -C $FIX/work_df_url push origin main & git -C $FIX/work_df_url push origin feature/x" allow
ea "BND17 kol: 注释双 devforge → allow（实例全解析不误拦）"    "$FIX/work_kol" "git -C $FIX/work_df_url push origin main # git -C $FIX/work_df_url push origin feature/x" allow
ea "BND18 kol: 单& df+未注册复合 → deny（不外溢）"            "$FIX/work_kol" "git -C $FIX/work_df_url push origin main & git -C $FIX/work_plain push origin main" deny "禁止直接 push"

echo ""
echo -e "${CYAN}--- Group S: 脚本轨道同族审计钉（push-guard.sh phase-1）---${NC}"

# 对照（既有行为）：裸 push 在 master 分支 → Check 4 拦（exit 2）；feature 分支放行
sa "S-C1 script: master 分支裸 push → Check4 拦 (exit 2)"          "$FIX/work_master" "git push" 2
sa "S-C2 script: feature 分支裸 push → 放行 (exit 0)"              "$FIX/work_feat" "git push" 0 pt

# 双轨联合探针定界（逃逸修复钉）：`git -p push` 裸形态曾判 NOT_PUSH 整段放行，
# 绕过 Check 4（gates refspec op 对无 refspec 形态不可见，脚本层唯一拦截点）。
# 旗标精化后 NO_REFSPEC 分类恢复 → Check 4 拦截。引擎侧对同形态 allow = 分层
# 既定口径（refspec 不可见），拦截职责归脚本 Check 4——双轨各守其面。
sa "S-FN1 script: master 分支 git -p push → Check4 拦 (exit 2)"    "$FIX/work_master" "git -p push" 2
sa "S-FN2 script: master 分支 git -P push → Check4 拦 (exit 2)"    "$FIX/work_master" "git -P push" 2
sa "S-FN3 script: master 分支 git -pC <dir> push → Check4 拦 (exit 2)" "$FIX/work_master" "git -pC $FIX/work_master push" 2
sa "S-FP1 script: feature 分支 git -p push → 放行（无新增误拦）"     "$FIX/work_feat" "git -p push" 0 pt
ea "S-REF engine: master 分支 git -p 裸 push → allow（refspec 不可见，拦截归脚本 Check4）" "$FIX/work_master" "git -p push" allow

echo ""
echo -e "${CYAN}--- OB-4 行为冻结登记（无断言）---${NC}"
echo "  OB-4 别名远端逃逸（dev-forge 检出内 push 指向 KOL 的别名 remote）："
echo "  origin-URL 身份判定固有边界，Owner 未裁决前冻结不改（本套件不为其加钉，"
echo "  零行为变化以 git diff 5320966..HEAD -- claude-hooks/ 审查留证）。"

# --- Summary ---
rm -rf "$FIX" "$STATE_DIR"; rm -f "$FIRE_LOG"
echo ""
echo "============================================"
echo -e "${CYAN}Results:${NC} ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "============================================"
[ "$FAIL" -eq 0 ] && echo -e "${GREEN}Overall: PASS${NC}" && exit 0 \
  || echo -e "${RED}Overall: FAIL ($FAIL failures)${NC}" && exit 1
