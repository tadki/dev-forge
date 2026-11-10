#!/bin/bash
# SEE-1559 §SPEC-005 hardener: stop-guard-subagents.sh 判别力测试（直跑行为断言 +
# 引擎 exit2 通道端到端）。
#
# 覆盖（对齐防线脚本 5 个判定分支）：
#   A. 直跑行为断言——空载荷 fail-open / stop_hook_active 自守 / transcript 缺失
#      fail-open / finished 判定（false·缺省·混合·空目录）/ subagents 目录缺失 /
#      session_id 兜底（basename 剥 .jsonl）/ session_id 权威（优先于 transcript 词干）/
#      meta 级 jq 失败 fail-closed（视为未结束）/ 拦截通道（exit 2 + stderr 指引，
#      stdout 零污染）。
#   B. 引擎端到端——UNIFIED_RULES_FILE overlay 复刻真实规则 action（run_script +
#      deny_exit_codes=[2] 绝对路径），经 unified-hook.sh 验证 Stop 时点 exit 2 +
#      stderr 直通、firelog 审计行、放行路径透传契约。
#
# 约束：本套件只读产品面（脚本/规则 JSON/引擎），全部状态在 mktemp fixture 内。
# Run:    bash tests/test_stop_guard_subagents_see1559.sh
set -uo pipefail

# 隔离宿主 agent/会话环境变量（test_plan_mode_permission_allow.sh 既有惯例）：
# 宿主 MULTICA_* 泄漏不影响本套件直跑断言，但保持与同目录套件一致的隔离纪律。
unset MULTICA_TASK_ID MULTICA_AGENT_ID MULTICA_AGENT_NAME \
      MULTICA_TOKEN MULTICA_SERVER_URL MULTICA_WORKSPACE_ID

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0; RESULTS=()
pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); RESULTS+=("PASS|$1"); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); RESULTS+=("FAIL|$1"); }
separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$REPO_ROOT/claude-hooks/scripts/stop-guard-subagents.sh"
ENTRY="$REPO_ROOT/claude-hooks/unified/unified-hook.sh"
FIXTURE="$(mktemp -d /tmp/stop-guard-see1559.XXXXXX)"
RULES="$FIXTURE/rules-overlay.json"
FIRELOG="$FIXTURE/hook-fire.log"
STATE="$FIXTURE/state"

trap 'rm -rf "$FIXTURE"' EXIT

# --- 直跑辅助：payload 经文件重定向喂入（防管道写者饿死触发读超时）， ------------
# timeout 10 兜底（挂起即视为抓到），stdout/stderr 分流留证。
RUN_RC=""; RUN_OUT=""; RUN_ERR=""
run_guard() {
    local PAYLOAD="$1"
    local IN="$FIXTURE/in.json"
    if [ -n "$PAYLOAD" ]; then
        printf '%s' "$PAYLOAD" > "$IN"
    else
        : > "$IN"
    fi
    RUN_OUT="$FIXTURE/out.txt"; RUN_ERR="$FIXTURE/err.txt"
    timeout 10 bash "$GUARD" < "$IN" > "$RUN_OUT" 2> "$RUN_ERR"
    RUN_RC=$?
}

# --- meta 树构造：<sid>.jsonl 转录占位 + <sid>/subagents/*.meta.json -------------
make_tree() {  # make_tree <sid>
    mkdir -p "$FIXTURE/$1/subagents"
    printf '{}' > "$FIXTURE/$1.jsonl"
}
write_meta() {  # write_meta <sid> <agent> <json-body>
    printf '%s' "$3" > "$FIXTURE/$1/subagents/$2.meta.json"
}
stop_payload() {  # stop_payload <sid> <stop_hook_active> [session_id-覆盖]
    local SID="$1" SHA="$2" OVERRIDE="${3:-}"
    local SESS="${OVERRIDE:-$SID}"
    printf '{"hook_event_name":"Stop","session_id":"%s","transcript_path":"%s/%s.jsonl","stop_hook_active":%s}' \
        "$SESS" "$FIXTURE" "$SID" "$SHA"
}

# =====================================================================
separator "A. 直跑行为断言（fail-open / 自守 / finished 判定）"
# =====================================================================

# A1: 空载荷 → fail-open 放行
run_guard ""
if [ "$RUN_RC" -eq 0 ] && [ ! -s "$RUN_OUT" ] && [ ! -s "$RUN_ERR" ]; then
    pass "A1: 空载荷 → exit 0 零输出（fail-open）"
else
    fail "A1: 空载荷 rc=$RUN_RC out='$(cat "$RUN_OUT" 2>/dev/null | head -c 80)' err='$(cat "$RUN_ERR" 2>/dev/null | head -c 80)'"
fi

# A2: stop_hook_active=true + 存活 sub-agent → 自守放行（防 Stop 阻止死循环）
make_tree "sess2"; write_meta "sess2" "agent-a" '{"finished":false}'
run_guard "$(stop_payload "sess2" "true")"
if [ "$RUN_RC" -eq 0 ] && [ ! -s "$RUN_OUT" ]; then
    pass "A2: stop_hook_active=true → exit 0（自守优先于存活 meta）"
else
    fail "A2: 自守失效 rc=$RUN_RC err='$(cat "$RUN_ERR" 2>/dev/null | head -c 80)'"
fi

# A3: transcript_path 缺失 → fail-open 放行
run_guard '{"hook_event_name":"Stop","session_id":"sess3","stop_hook_active":false}'
if [ "$RUN_RC" -eq 0 ]; then
    pass "A3: transcript_path 缺失 → exit 0（fail-open）"
else
    fail "A3: transcript 缺失误拦 rc=$RUN_RC err='$(cat "$RUN_ERR" 2>/dev/null | head -c 60)'"
fi

# A4: finished=false 存活 meta → exit 2 + stderr 指引（含 agent 名与 TaskStop 处置）
make_tree "sess4"; write_meta "sess4" "agent-live" '{"finished":false}'
run_guard "$(stop_payload "sess4" "false")"
GUARD_ERR="$(cat "$RUN_ERR" 2>/dev/null)"
if [ "$RUN_RC" -eq 2 ] && grep -q "agent-live" <<< "$GUARD_ERR" && grep -q "TaskStop" <<< "$GUARD_ERR"; then
    pass "A4: finished=false → exit 2 + stderr 指引（agent 名 + TaskStop 处置）"
else
    fail "A4: 拦截通道断链 rc=$RUN_RC err='$(echo "$GUARD_ERR" | head -c 100)'"
fi

# A5: 全部 finished=true → 放行
make_tree "sess5"; write_meta "sess5" "agent-done" '{"finished":true}'
run_guard "$(stop_payload "sess5" "false")"
if [ "$RUN_RC" -eq 0 ]; then
    pass "A5: 全部 finished=true → exit 0"
else
    fail "A5: 已结束 meta 被误拦 rc=$RUN_RC err='$(cat "$RUN_ERR" 2>/dev/null | head -c 80)'"
fi

# A5b: subagents 目录存在但无 meta 文件 → 放行（裸 glob 字面量守卫）
make_tree "sess5b"
run_guard "$(stop_payload "sess5b" "false")"
if [ "$RUN_RC" -eq 0 ]; then
    pass "A5b: subagents 目录为空（无 *.meta.json）→ exit 0"
else
    fail "A5b: 空 meta 目录被误拦 rc=$RUN_RC err='$(cat "$RUN_ERR" 2>/dev/null | head -c 80)'"
fi

# A6: meta 缺 finished 字段 → 视为未结束（.finished // false 缺省）→ 拦截
make_tree "sess6"; write_meta "sess6" "agent-nofield" '{"agentType":"general-purpose"}'
run_guard "$(stop_payload "sess6" "false")"
if [ "$RUN_RC" -eq 2 ]; then
    pass "A6: meta 缺 finished 字段 → exit 2（缺省=未结束，保守向）"
else
    fail "A6: finished 缺省值反转 rc=$RUN_RC"
fi

# A7: 无 subagents 目录 → fail-open 放行
printf '{}' > "$FIXTURE/sess7.jsonl"
run_guard "$(stop_payload "sess7" "false")"
if [ "$RUN_RC" -eq 0 ]; then
    pass "A7: 无 subagents 目录 → exit 0（fail-open）"
else
    fail "A7: 目录缺失误拦 rc=$RUN_RC err='$(cat "$RUN_ERR" 2>/dev/null | head -c 80)'"
fi

# A8: session_id 缺失 → transcript 词干兜底（剥 .jsonl）→ 仍能命中 meta 树并拦截
printf '{}' > "$FIXTURE/sess8.jsonl"
mkdir -p "$FIXTURE/sess8/subagents"
write_meta "sess8" "agent-fallback" '{"finished":false}'
run_guard '{"hook_event_name":"Stop","transcript_path":"'"$FIXTURE"'/sess8.jsonl","stop_hook_active":false}'
if [ "$RUN_RC" -eq 2 ] && grep -q "agent-fallback" <<< "$(cat "$RUN_ERR" 2>/dev/null)"; then
    pass "A8: session_id 缺失 → 词干兜底命中 meta → exit 2"
else
    fail "A8: session_id 兜底失效 rc=$RUN_RC"
fi

# A9: session_id 与转录词干不同 → meta 树以 session_id 为权威（非 basename）
printf '{}' > "$FIXTURE/other-stem.jsonl"
mkdir -p "$FIXTURE/sess9/subagents"
write_meta "sess9" "agent-authoritative" '{"finished":false}'
run_guard "$(stop_payload "other-stem" "false" "sess9")"
if [ "$RUN_RC" -eq 2 ] && grep -q "agent-authoritative" <<< "$(cat "$RUN_ERR" 2>/dev/null)"; then
    pass "A9: META_DIR 按 session_id 解析（非转录词干）→ exit 2"
else
    fail "A9: meta 路径解析未按 session_id 权威 rc=$RUN_RC"
fi

# A10: 混合 finished → 拦截且 stderr 仅列未结束者
make_tree "sess10"
write_meta "sess10" "agent-done10" '{"finished":true}'
write_meta "sess10" "agent-live10" '{"finished":false}'
run_guard "$(stop_payload "sess10" "false")"
GUARD_ERR="$(cat "$RUN_ERR" 2>/dev/null)"
if [ "$RUN_RC" -eq 2 ] && grep -q "agent-live10" <<< "$GUARD_ERR" && ! grep -q "agent-done10" <<< "$GUARD_ERR"; then
    pass "A10: 混合 finished → exit 2 且 stderr 仅列未结束 agent"
else
    fail "A10: 混合判定失真 rc=$RUN_RC err='$(echo "$GUARD_ERR" | head -c 120)'"
fi

# A11: 拦截路径 stdout 零污染（stdout 是引擎协议/上下文通道，不得混入）
if [ ! -s "$RUN_OUT" ]; then
    pass "A11: 拦截路径 stdout 为空（stderr 单通道指引）"
else
    fail "A11: 拦截路径 stdout 污染: '$(head -c 80 "$RUN_OUT")'"
fi

# A12: meta JSON 损坏（jq 失败）→ fail-closed 视为未结束 → 拦截（|| echo false 保守向）
make_tree "sess12"; write_meta "sess12" "agent-corrupt" '{invalid json'
run_guard "$(stop_payload "sess12" "false")"
if [ "$RUN_RC" -eq 2 ]; then
    pass "A12: meta JSON 损坏 → exit 2（meta 级 fail-closed，不可验证=未结束）"
else
    fail "A12: meta 级 jq 失败误放行 rc=$RUN_RC"
fi

# =====================================================================
separator "B. 引擎端到端（run_script + deny_exit_codes=[2] → Stop exit2 直通）"
# =====================================================================

# overlay 由真实规则文件派生（非手写副本）：抽取 stop-guard-live-subagents 规则，
# ${HOOKS_DIR} 重写为本仓 claude-hooks/ 绝对路径（overlay 在 fixture 内，
# hooksDir 解析不可用，绝对路径经 engine resolveScriptPath 原样放行）。
# 派生式 E2E 使规则 JSON 自身（路径/deny_exit_codes/时点/enabled）进入判定面：
# 产品侧规则文件任何破坏通道的改动都会令 B 系列变红。
RULE_SRC="$REPO_ROOT/claude-hooks/unified/rules.d/stop-guard-subagents.json"
node -e '
const fs = require("fs");
const real = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const picked = (real.rules || []).filter(r => r.name === "stop-guard-live-subagents");
if (picked.length !== 1) { console.error("rule not found in real rule file"); process.exit(1); }
for (const r of picked) for (const a of r.action || [])
  if (a.path) a.path = a.path.replace("${HOOKS_DIR}", process.argv[2]);
fs.writeFileSync(process.argv[3], JSON.stringify({ version: 2, rules: picked }));
' "$RULE_SRC" "$REPO_ROOT/claude-hooks" "$RULES" || { echo -e "  ${RED}[FAIL]${NC} B0: real rule file unreadable/derivation failed"; FAIL=$((FAIL+1)); }

# E2E 辅助：经 unified-hook.sh 全链，stdout/stderr/退出码三分留证
E2E_RC=""; E2E_OUT=""; E2E_ERR=""
run_e2e() {
    local PAYLOAD="$1"
    printf '%s' "$PAYLOAD" > "$FIXTURE/e2e-in.json"
    : > "$FIRELOG"
    E2E_OUT="$FIXTURE/e2e-out.txt"; E2E_ERR="$FIXTURE/e2e-err.txt"
    UNIFIED_RULES_FILE="$RULES" HOOK_FIRE_LOG="$FIRELOG" HOOK_STATE_DIR="$STATE" \
        PROJECT_ROOT="$REPO_ROOT" \
        timeout 15 bash "$ENTRY" < "$FIXTURE/e2e-in.json" > "$E2E_OUT" 2> "$E2E_ERR"
    E2E_RC=$?
}

# B1: 存活 meta → 引擎 exitChannel 直通：exit 2 + stderr 指引 + firelog 审计行
make_tree "e2e1"; write_meta "e2e1" "agent-e2e" '{"finished":false}'
run_e2e "$(stop_payload "e2e1" "false")"
E2E_ERR_BODY="$(cat "$E2E_ERR" 2>/dev/null)"
if [ "$E2E_RC" -eq 2 ] \
   && grep -q "\[stop-guard-subagents\]" <<< "$E2E_ERR_BODY" \
   && grep -q "agent-e2e" <<< "$E2E_ERR_BODY" \
   && [ ! -s "$E2E_OUT" ] \
   && grep -q "run-script-exit2 rule=stop-guard-live-subagents code=2" "$FIRELOG" 2>/dev/null; then
    pass "B1: E2E 存活 sub-agent → exit 2 + stderr 指引 + firelog exit2 审计 + stdout 零污染"
else
    fail "B1: E2E 通道断链 rc=$E2E_RC err='$(echo "$E2E_ERR_BODY" | head -c 100)' firelog='$(grep -c "run-script-exit2" "$FIRELOG" 2>/dev/null)'"
fi

# B2: stop_hook_active=true → 引擎放行：exit 0 + 透传原 stdin 契约
run_e2e "$(stop_payload "e2e1" "true")"
if [ "$E2E_RC" -eq 0 ] && grep -q '"stop_hook_active":true' <<< "$(cat "$E2E_OUT" 2>/dev/null)" \
   && ! grep -q "run-script-exit2" "$FIRELOG" 2>/dev/null; then
    pass "B2: E2E 自守 → exit 0 + 原载荷透传 + 无 exit2 审计"
else
    fail "B2: E2E 自守失效 rc=$E2E_RC out='$(head -c 80 "$E2E_OUT" 2>/dev/null)'"
fi

# B3: 全部 finished=true → 引擎放行透传
make_tree "e2e3"; write_meta "e2e3" "agent-e2e-done" '{"finished":true}'
run_e2e "$(stop_payload "e2e3" "false")"
if [ "$E2E_RC" -eq 0 ] && grep -q '"session_id":"e2e3"' <<< "$(cat "$E2E_OUT" 2>/dev/null)"; then
    pass "B3: E2E 全部已结束 → exit 0 + 透传"
else
    fail "B3: E2E 已结束误拦 rc=$E2E_RC"
fi

# =====================================================================
separator "Summary"
echo ""
echo -e "${CYAN}Results:${NC}"
echo -e "  ${GREEN}Passed:${NC} $PASS"
echo -e "  ${RED}Failed:${NC} $FAIL"
echo ""
if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}Overall: PASS${NC}"
    exit 0
else
    echo -e "${RED}Overall: FAIL ($FAIL failures)${NC}"
    for R in "${RESULTS[@]}"; do
        [[ "$R" == FAIL* ]] && echo -e "  ${RED}x${NC} ${R#FAIL|}"
    done
    exit 1
fi
