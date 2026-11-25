#!/bin/bash
# SEE-1636 §SPEC-001~004: stop-guard-background-tasks 判别力测试（直跑行为断言 +
# 引擎 exit2 通道端到端 + 与 stop-guard-live-subagents 并存不遮蔽）。
#
# 覆盖：
#   A. 直跑行为断言（§SPEC-001/002）——MULTICA_TASK_ID 门控（未设/为空放行）/
#      stop_hook_active 自守 / 空载荷与非 JSON fail-open / background_tasks 缺失·
#      null·空数组·非数组放行 / 仅 agent 型任务放行 / 终态词表判定（completed·
#      failed·killed·stopped·cancelled·exited·done·timed_out 放行；running·
#      pending·缺失·未知按活任务拦截）/ 混合清单只列活任务 / jq 不可用 fail-open /
#      拦截文案要点（前台等待同回合收尾·卡死先 TaskStop·常驻服务例外·无绕过提示）/
#      与 sub-agent 守卫并存时代送其指引（引擎 exitChannel 首条胜出，本守卫规则
#      文件名排序在前）。
#   B. 引擎端到端（§SPEC-003）——UNIFIED_RULES_FILE overlay 由真实规则文件派生，
#      经 unified-hook.sh 全链验证：拦截 exit 2 + stderr 指引 + firelog
#      run-script-exit2 rule=stop-guard-background-tasks code=2 + stdout 零污染；
#      放行 exit 0 + 原载荷透传。
#   C. 与既有 sub-agent 守卫并存（§SPEC-004）——双规则 overlay 经引擎全链：
#      仅后台任务存活（stderr 仅新守卫段）/ 仅 sub-agent 存活（stderr 仅既有守卫段）/
#      两者同时存活（两段指引都送达，不遮蔽）/ 两者皆无（透传）。
#
# 约束：本套件只读产品面（脚本/规则 JSON/引擎），全部状态在 mktemp fixture 内；
# E2E 预置 HOOK_ISSUE_ID + 隔离 HOME，使入口层不做 daemon.log 反查、不写任何
# 生产 state 与 firelog。
# Run:    bash tests/test_stop_guard_background_tasks_see1636.sh
set -uo pipefail

# 隔离宿主 agent/会话环境变量（test_stop_guard_subagents_see1559.sh 既有惯例）：
# 宿主 MULTICA_* 泄漏不影响断言判定，但保持隔离纪律；用例内按需显式注入。
unset MULTICA_TASK_ID MULTICA_AGENT_ID MULTICA_AGENT_NAME \
      MULTICA_TOKEN MULTICA_SERVER_URL MULTICA_WORKSPACE_ID

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0; RESULTS=()
pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); RESULTS+=("PASS|$1"); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); RESULTS+=("FAIL|$1"); }
separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$REPO_ROOT/claude-hooks/scripts/stop-guard-background-tasks.sh"
RULE_FILE="$REPO_ROOT/claude-hooks/unified/rules.d/stop-guard-background-tasks.json"
ENTRY="$REPO_ROOT/claude-hooks/unified/unified-hook.sh"
FIXTURE="$(mktemp -d /tmp/stop-guard-see1636.XXXXXX)"
RULES_ONE="$FIXTURE/rules-overlay.json"
RULES_BOTH="$FIXTURE/rules-both-overlay.json"
FIRELOG="$FIXTURE/hook-fire.log"
STATE="$FIXTURE/state"
HOME_DIR="$FIXTURE/home"
mkdir -p "$HOME_DIR"

trap 'rm -rf "$FIXTURE"' EXIT

# --- 载荷构造（Stop 载荷形状 = issue 附件 stop-hook-payloads.jsonl 实录） --------
bg_task() {  # bg_task <id> <type> <status> [description]
    printf '{"id":"%s","type":"%s","status":"%s","description":"%s","command":"sleep 25; echo hi"}' \
        "$1" "$2" "$3" "${4:-probe background task}"
}
bg_payload() {  # bg_payload <tasks-json-raw> [stop_hook_active] [session_id]
    local SID="${3:-see1636-a}"
    printf '{"hook_event_name":"Stop","session_id":"%s","transcript_path":"%s/%s.jsonl","stop_hook_active":%s,"background_tasks":%s}' \
        "$SID" "$FIXTURE" "$SID" "${2:-false}" "$1"
}

# --- 直跑辅助：payload 经文件重定向喂入，stdout/stderr 分流留证，timeout 兜底 ----
RUN_RC=""; RUN_OUT=""; RUN_ERR=""
run_guard() {  # run_guard <'-'=不注入 MULTICA_TASK_ID | 其他=注入该值(可为空串)> <payload>
    local TASK_ID="$1"
    local IN="$FIXTURE/in.json"
    if [ -n "$2" ]; then
        printf '%s' "$2" > "$IN"
    else
        : > "$IN"
    fi
    RUN_OUT="$FIXTURE/out.txt"; RUN_ERR="$FIXTURE/err.txt"
    if [ "$TASK_ID" = "-" ]; then
        timeout 10 bash "$GUARD" < "$IN" > "$RUN_OUT" 2> "$RUN_ERR"
    else
        MULTICA_TASK_ID="$TASK_ID" timeout 10 bash "$GUARD" < "$IN" > "$RUN_OUT" 2> "$RUN_ERR"
    fi
    RUN_RC=$?
}

# --- meta 树构造（sub-agent 并存面：<sid>/subagents/*.meta.json） ----------------
make_tree() {  # make_tree <sid>
    mkdir -p "$FIXTURE/$1/subagents"
    printf '{}' > "$FIXTURE/$1.jsonl"
}
write_meta() {  # write_meta <sid> <agent> <json-body>
    printf '%s' "$3" > "$FIXTURE/$1/subagents/$2.meta.json"
}

# =====================================================================
separator "A. 直跑行为断言（门控 / 终态词表 / fail-open / 文案要点）"
# =====================================================================

# A1: 托管运行 + shell/running → exit 2 + stderr 指引含任务 id
run_guard "see1636-test" "$(bg_payload "[$(bg_task t1 shell running)]" false sa1)"
ERR1="$(cat "$RUN_ERR" 2>/dev/null)"
if [ "$RUN_RC" -eq 2 ] && grep -q "stop-guard-background-tasks" <<< "$ERR1" && grep -q "t1" <<< "$ERR1"; then
    pass "A1: 托管运行 + shell/running → exit 2 + stderr 指引含任务 id"
else
    fail "A1: 拦截通道断链 rc=$RUN_RC err='$(echo "$ERR1" | head -c 100)'"
fi

# A2: pending 状态 → 拦截（本轮核实：Stop 载荷 background_tasks 只含 running/pending，
#     只判 running 会漏 pending——原型缺陷，本守卫按终态词表判定）
run_guard "see1636-test" "$(bg_payload "[$(bg_task t2 shell pending)]" false sa2)"
if [ "$RUN_RC" -eq 2 ] && grep -q "t2" <<< "$(cat "$RUN_ERR" 2>/dev/null)"; then
    pass "A2: status=pending → exit 2（终态词表判定，非 ==running）"
else
    fail "A2: pending 漏拦 rc=$RUN_RC"
fi

# A3: status 字段缺失 → 按活任务计 → 拦截（缺省=未结束，保守向）
run_guard "see1636-test" "$(bg_payload '[{"id":"t3","type":"shell","description":"no status","command":"sleep 25"}]' false sa3)"
if [ "$RUN_RC" -eq 2 ] && grep -q "t3" <<< "$(cat "$RUN_ERR" 2>/dev/null)"; then
    pass "A3: status 缺失 → exit 2（缺省按活任务计）"
else
    fail "A3: status 缺失误放行 rc=$RUN_RC"
fi

# A4: status 未知词（queued，不在终态词表）→ 按活任务计 → 拦截
run_guard "see1636-test" "$(bg_payload "[$(bg_task t4 shell queued)]" false sa4)"
if [ "$RUN_RC" -eq 2 ]; then
    pass "A4: status=queued（未知词）→ exit 2（未知按活任务计）"
else
    fail "A4: 未知状态误放行 rc=$RUN_RC"
fi

# A5: 多任务存活（含带空格类型 MCP task）→ exit 2 且逐项列出
T5A="$(bg_task t5-shell shell running)"; T5B="$(bg_task t5-monitor monitor pending)"
T5C="$(bg_task t5-mcp "MCP task" running)"
run_guard "see1636-test" "$(bg_payload "[$T5A,$T5B,$T5C]" false sa5)"
ERR5="$(cat "$RUN_ERR" 2>/dev/null)"
if [ "$RUN_RC" -eq 2 ] && grep -q "t5-shell" <<< "$ERR5" && grep -q "t5-monitor" <<< "$ERR5" && grep -q "t5-mcp" <<< "$ERR5"; then
    pass "A5: 多任务存活 → exit 2 且逐项列出（含带空格类型）"
else
    fail "A5: 多任务清单失真 rc=$RUN_RC err='$(echo "$ERR5" | head -c 120)'"
fi

# A6: MULTICA_TASK_ID 未设（交互式会话）→ 放行零输出
run_guard "-" "$(bg_payload "[$(bg_task t6 shell running)]" false sa6)"
if [ "$RUN_RC" -eq 0 ] && [ ! -s "$RUN_OUT" ] && [ ! -s "$RUN_ERR" ]; then
    pass "A6: MULTICA_TASK_ID 未设 → exit 0 零输出（交互会话不受影响）"
else
    fail "A6: 交互会话误拦 rc=$RUN_RC err='$(cat "$RUN_ERR" 2>/dev/null | head -c 80)'"
fi

# A6b: MULTICA_TASK_ID 为空串 → 放行零输出
run_guard "" "$(bg_payload "[$(bg_task t6b shell running)]" false sa6b)"
if [ "$RUN_RC" -eq 0 ] && [ ! -s "$RUN_OUT" ] && [ ! -s "$RUN_ERR" ]; then
    pass "A6b: MULTICA_TASK_ID 为空 → exit 0 零输出"
else
    fail "A6b: 空任务 id 误拦 rc=$RUN_RC"
fi

# A7: stop_hook_active=true → 自守放行（每回合只拦一次，防 Stop 阻止死循环）
run_guard "see1636-test" "$(bg_payload "[$(bg_task t7 shell running)]" true sa7)"
if [ "$RUN_RC" -eq 0 ] && [ ! -s "$RUN_OUT" ] && [ ! -s "$RUN_ERR" ]; then
    pass "A7: stop_hook_active=true → exit 0（自守优先于存活任务）"
else
    fail "A7: 自守失效 rc=$RUN_RC err='$(cat "$RUN_ERR" 2>/dev/null | head -c 80)'"
fi

# A8: 空载荷 → fail-open 放行
run_guard "see1636-test" ""
if [ "$RUN_RC" -eq 0 ] && [ ! -s "$RUN_OUT" ] && [ ! -s "$RUN_ERR" ]; then
    pass "A8: 空载荷 → exit 0 零输出（fail-open）"
else
    fail "A8: 空载荷误拦 rc=$RUN_RC"
fi

# A9: 非 JSON 载荷 → fail-open 放行
run_guard "see1636-test" "not-json{{"
if [ "$RUN_RC" -eq 0 ] && [ ! -s "$RUN_OUT" ] && [ ! -s "$RUN_ERR" ]; then
    pass "A9: 非 JSON 载荷 → exit 0 零输出（jq 解析失败 fail-open）"
else
    fail "A9: 非 JSON 误拦 rc=$RUN_RC"
fi

# A10: background_tasks 字段缺失 → 放行
run_guard "see1636-test" '{"hook_event_name":"Stop","stop_hook_active":false}'
if [ "$RUN_RC" -eq 0 ]; then
    pass "A10: background_tasks 缺失 → exit 0"
else
    fail "A10: 字段缺失误拦 rc=$RUN_RC"
fi

# A10b: background_tasks 显式 null → 放行
run_guard "see1636-test" "$(bg_payload "null" false sa10b)"
if [ "$RUN_RC" -eq 0 ]; then
    pass "A10b: background_tasks=null → exit 0"
else
    fail "A10b: null 误拦 rc=$RUN_RC"
fi

# A11: background_tasks 空数组 → 放行
run_guard "see1636-test" "$(bg_payload "[]" false sa11)"
if [ "$RUN_RC" -eq 0 ] && [ ! -s "$RUN_ERR" ]; then
    pass "A11: background_tasks=[] → exit 0"
else
    fail "A11: 空数组误拦 rc=$RUN_RC"
fi

# A12: background_tasks 非数组（字符串）→ 放行
run_guard "see1636-test" "$(bg_payload '"just-a-string"' false sa12)"
if [ "$RUN_RC" -eq 0 ]; then
    pass "A12: background_tasks 非数组 → exit 0"
else
    fail "A12: 非数组误拦 rc=$RUN_RC"
fi

# A13: 仅 subagent 型任务存活 → 放行（type 含 agent 排除，归既有 sub-agent 守卫管）
T13A="$(bg_task t13-sub subagent running)"
run_guard "see1636-test" "$(bg_payload "[$T13A]" false sa13)"
if [ "$RUN_RC" -eq 0 ] && [ ! -s "$RUN_OUT" ] && [ ! -s "$RUN_ERR" ]; then
    pass "A13: 仅 agent 型任务（subagent）→ exit 0 零输出（type 含 agent 排除）"
else
    fail "A13: agent 型误拦 rc=$RUN_RC err='$(cat "$RUN_ERR" 2>/dev/null | head -c 80)'"
fi

# A13b: teammate 型存活 → 拦截（「本轮核实的事实」：只排除 type 含 agent 的条目，
# teammate 不含 agent → 按后台任务计，保守向）
run_guard "see1636-test" "$(bg_payload "[$(bg_task t13b-team teammate pending)]" false sa13b)"
if [ "$RUN_RC" -eq 2 ] && grep -q "t13b-team" <<< "$(cat "$RUN_ERR" 2>/dev/null)"; then
    pass "A13b: teammate 型 → exit 2（不含 agent 按后台任务计）"
else
    fail "A13b: teammate 漏拦 rc=$RUN_RC"
fi

# A14: 非 agent 任务全部终态（8 个终态词逐一）→ 放行
TERMS=(completed failed killed stopped cancelled exited done timed_out)
TASKS14=""
FIRST=1
for i in "${!TERMS[@]}"; do
    T="$(bg_task "t14-$i" shell "${TERMS[$i]}")"
    if [ "$FIRST" -eq 1 ]; then TASKS14="$T"; FIRST=0; else TASKS14="$TASKS14,$T"; fi
done
run_guard "see1636-test" "$(bg_payload "[$TASKS14]" false sa14)"
if [ "$RUN_RC" -eq 0 ] && [ ! -s "$RUN_ERR" ]; then
    pass "A14: 8 个终态词全部放行 → exit 0"
else
    fail "A14: 终态词表误拦 rc=$RUN_RC err='$(cat "$RUN_ERR" 2>/dev/null | head -c 80)'"
fi

# A15: jq 不可用 → fail-open 放行（最小 PATH：链接 timeout/bash/dirname/cat，
# 独缺 jq；payload 可读、门控可达，失败落在 jq 调用本身）
NOJQ_BIN="$FIXTURE/nojq-bin"; mkdir -p "$NOJQ_BIN"
for tool in timeout bash dirname cat; do
    _p="$(command -v "$tool" 2>/dev/null)" && ln -s "$_p" "$NOJQ_BIN/$tool"
done
printf '%s' "$(bg_payload "[$(bg_task t15 shell running)]" false sa15)" > "$FIXTURE/in15.json"
MULTICA_TASK_ID="see1636-test" PATH="$NOJQ_BIN" \
    timeout 10 bash "$GUARD" < "$FIXTURE/in15.json" > "$FIXTURE/out15.txt" 2> "$FIXTURE/err15.txt"
RC15=$?
if [ "$RC15" -eq 0 ] && [ ! -s "$FIXTURE/out15.txt" ] && [ ! -s "$FIXTURE/err15.txt" ]; then
    pass "A15: jq 不可用 → exit 0 零输出（fail-open）"
else
    fail "A15: jq 缺失误拦 rc=$RC15 err='$(cat "$FIXTURE/err15.txt" 2>/dev/null | head -c 80)'"
fi

# A16: 拦截文案要点必含（§SPEC-002）：前台等待并同回合收尾 / 卡死先 TaskStop /
#      常驻服务例外 / 控制通道后果说明；沿用附件原型实测有效文案
run_guard "see1636-test" "$(bg_payload "[$(bg_task t16 shell running)]" false sa16)"
ERR16="$(cat "$RUN_ERR" 2>/dev/null)"
TXT_OK=1
for frag in "前台阻塞等待" "收尾" "TaskStop" "常驻" "例外" "控制通道" "t16"; do
    grep -q "$frag" <<< "$ERR16" || { TXT_OK=0; break; }
done
if [ "$RUN_RC" -eq 2 ] && [ "$TXT_OK" -eq 1 ]; then
    pass "A16: 文案要点齐备（前台等待/收尾/TaskStop/常驻例外/控制通道/任务清单）"
else
    fail "A16: 文案要点缺失 rc=$RUN_RC err='$(echo "$ERR16" | head -c 160)'"
fi

# A17: 文案禁含绕过提示（实测：提示「再结束一次即可绕过」后模型 2/6 绕过）
BYPASS=0
grep -qE "再结束一次|第二次|stop_hook_active" <<< "$ERR16" && BYPASS=1
if [ "$BYPASS" -eq 0 ]; then
    pass "A17: 无绕过提示（不出现再结束一次/第二次/stop_hook_active 字样）"
else
    fail "A17: 文案含绕过提示（复刻已知无效文案）"
fi

# A18: 拦截路径 stdout 零污染（stdout 是引擎协议/上下文通道，不得混入）
if [ ! -s "$RUN_OUT" ]; then
    pass "A18: 拦截路径 stdout 为空（stderr 单通道指引）"
else
    fail "A18: 拦截路径 stdout 污染: '$(head -c 80 "$RUN_OUT")'"
fi

# A19: 混合清单只列活任务（终态与 agent 型不列）
T19A="$(bg_task t19-alive shell running)"; T19B="$(bg_task t19-done shell completed)"
T19C="$(bg_task t19-sub subagent running)"
run_guard "see1636-test" "$(bg_payload "[$T19A,$T19B,$T19C]" false sa19)"
ERR19="$(cat "$RUN_ERR" 2>/dev/null)"
if [ "$RUN_RC" -eq 2 ] && grep -q "t19-alive" <<< "$ERR19" \
   && ! grep -q "t19-done" <<< "$ERR19" && ! grep -q "t19-sub" <<< "$ERR19"; then
    pass "A19: 混合清单 → stderr 仅列活任务（终态/agent 型不列）"
else
    fail "A19: 混合判定失真 rc=$RUN_RC err='$(echo "$ERR19" | head -c 120)'"
fi

# A20: 与 sub-agent 守卫同时命中（直跑面）→ stderr 两段指引都送达
make_tree "sa20"; write_meta "sa20" "agent-live20" '{"finished":false}'
run_guard "see1636-test" "$(bg_payload "[$(bg_task t20 shell running)]" false sa20)"
ERR20="$(cat "$RUN_ERR" 2>/dev/null)"
if [ "$RUN_RC" -eq 2 ] \
   && grep -qF "[stop-guard-background-tasks]" <<< "$ERR20" \
   && grep -qF "[stop-guard-subagents]" <<< "$ERR20" \
   && grep -q "尚未结束的后台 sub-agent" <<< "$ERR20" \
   && grep -q "前台阻塞等待" <<< "$ERR20"; then
    pass "A20: 双守卫同时命中 → stderr 同时包含两段指引（不遮蔽）"
else
    fail "A20: 并存代送失效 rc=$RUN_RC err='$(echo "$ERR20" | head -c 160)'"
fi

# A21: 仅后台任务命中（无 sub-agent meta）→ stderr 只有新守卫段
run_guard "see1636-test" "$(bg_payload "[$(bg_task t21 shell running)]" false sa21)"
ERR21="$(cat "$RUN_ERR" 2>/dev/null)"
if [ "$RUN_RC" -eq 2 ] && grep -qF "[stop-guard-background-tasks]" <<< "$ERR21" \
   && ! grep -qF "[stop-guard-subagents]" <<< "$ERR21"; then
    pass "A21: 仅后台任务命中 → stderr 无 sub-agent 段"
else
    fail "A21: 单命中文案混入他段 rc=$RUN_RC"
fi

# =====================================================================
separator "B. 引擎端到端（run_script + deny_exit_codes=[2] → Stop exit2 直通）"
# =====================================================================

# overlay 由真实规则文件派生（非手写副本）：抽取 stop-guard-background-tasks 规则，
# ${HOOKS_DIR} 重写为本仓 claude-hooks/ 绝对路径（overlay 在 fixture 内，
# hooksDir 解析不可用，绝对路径经引擎 resolveScriptPath 原样放行）。
# 派生式 E2E 使规则 JSON 自身（路径/deny_exit_codes/时点/enabled）进入判定面：
# 产品侧规则文件任何破坏通道的改动都会令 B 系列变红。
node -e '
const fs = require("fs");
const real = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const picked = (real.rules || []).filter(r => r.name === "stop-guard-background-tasks");
if (picked.length !== 1) { console.error("rule not found in real rule file"); process.exit(1); }
for (const r of picked) for (const a of r.action || [])
  if (a.path) a.path = a.path.replace("${HOOKS_DIR}", process.argv[2]);
fs.writeFileSync(process.argv[3], JSON.stringify({ version: 2, rules: picked }));
' "$RULE_FILE" "$REPO_ROOT/claude-hooks" "$RULES_ONE" \
  || { echo -e "  ${RED}[FAIL]${NC} B0: 真实规则文件不可读/派生失败"; FAIL=$((FAIL+1)); RESULTS+=("FAIL|B0: 真实规则文件派生"); }

# E2E 辅助：经 unified-hook.sh 全链，stdout/stderr/退出码三分留证。
# 预置 HOOK_ISSUE_ID + 隔离 HOME：入口层跳过 daemon.log 反查与 /tmp 缓存写入，
# 全部状态留在 fixture。
E2E_RC=""; E2E_OUT=""; E2E_ERR=""
run_e2e() {  # run_e2e <'-'=不注入 MULTICA_TASK_ID | 其他=注入> <rules-file> <payload>
    local TASK_ID="$1" RULES="$2"
    printf '%s' "$3" > "$FIXTURE/e2e-in.json"
    : > "$FIRELOG"
    E2E_OUT="$FIXTURE/e2e-out.txt"; E2E_ERR="$FIXTURE/e2e-err.txt"
    if [ "$TASK_ID" = "-" ]; then
        UNIFIED_RULES_FILE="$RULES" HOOK_FIRE_LOG="$FIRELOG" HOOK_STATE_DIR="$STATE" \
            PROJECT_ROOT="$REPO_ROOT" HOME="$HOME_DIR" HOOK_ISSUE_ID="see1636-issue" \
            timeout 15 bash "$ENTRY" < "$FIXTURE/e2e-in.json" > "$E2E_OUT" 2> "$E2E_ERR"
    else
        UNIFIED_RULES_FILE="$RULES" HOOK_FIRE_LOG="$FIRELOG" HOOK_STATE_DIR="$STATE" \
            PROJECT_ROOT="$REPO_ROOT" HOME="$HOME_DIR" HOOK_ISSUE_ID="see1636-issue" \
            MULTICA_TASK_ID="$TASK_ID" \
            timeout 15 bash "$ENTRY" < "$FIXTURE/e2e-in.json" > "$E2E_OUT" 2> "$E2E_ERR"
    fi
    E2E_RC=$?
}

# B1: 存活后台任务 + 托管运行 → 引擎 exitChannel 直通：exit 2 + stderr 指引 +
#     firelog 审计行 + stdout 零污染
run_e2e "see1636-test" "$RULES_ONE" "$(bg_payload "[$(bg_task t-b1 shell running)]" false sb1)"
E2E_ERR_BODY="$(cat "$E2E_ERR" 2>/dev/null)"
if [ "$E2E_RC" -eq 2 ] \
   && grep -qF "[stop-guard-background-tasks]" <<< "$E2E_ERR_BODY" \
   && grep -q "t-b1" <<< "$E2E_ERR_BODY" \
   && grep -q "前台阻塞等待" <<< "$E2E_ERR_BODY" \
   && [ ! -s "$E2E_OUT" ] \
   && grep -q "run-script-exit2 rule=stop-guard-background-tasks code=2" "$FIRELOG" 2>/dev/null; then
    pass "B1: E2E 拦截 → exit 2 + stderr 指引 + firelog run-script-exit2 审计 + stdout 零污染"
else
    fail "B1: E2E 通道断链 rc=$E2E_RC err='$(echo "$E2E_ERR_BODY" | head -c 100)' firelog='$(grep -c "run-script-exit2" "$FIRELOG" 2>/dev/null)'"
fi

# B2: 全部终态 → 引擎放行：exit 0 + 原载荷透传契约 + 无 exit2 审计
run_e2e "see1636-test" "$RULES_ONE" "$(bg_payload "[$(bg_task t-b2 shell completed)]" false sb2)"
if [ "$E2E_RC" -eq 0 ] && grep -q '"session_id":"sb2"' <<< "$(cat "$E2E_OUT" 2>/dev/null)" \
   && ! grep -q "run-script-exit2" "$FIRELOG" 2>/dev/null; then
    pass "B2: E2E 全部终态 → exit 0 + 原载荷透传 + 无 exit2 审计"
else
    fail "B2: E2E 已结束误拦 rc=$E2E_RC out='$(head -c 80 "$E2E_OUT" 2>/dev/null)'"
fi

# B3: 交互会话（无 MULTICA_TASK_ID）+ 存活任务 → 引擎放行透传
run_e2e "-" "$RULES_ONE" "$(bg_payload "[$(bg_task t-b3 shell running)]" false sb3)"
if [ "$E2E_RC" -eq 0 ] && grep -q '"session_id":"sb3"' <<< "$(cat "$E2E_OUT" 2>/dev/null)" \
   && ! grep -q "run-script-exit2" "$FIRELOG" 2>/dev/null; then
    pass "B3: E2E 交互会话存活任务 → exit 0 + 透传（门控生效）"
else
    fail "B3: E2E 交互会话误拦 rc=$E2E_RC out='$(head -c 80 "$E2E_OUT" 2>/dev/null)'"
fi

# =====================================================================
separator "C. 与既有 sub-agent 守卫并存（双规则 overlay，不遮蔽判定）"
# =====================================================================

# C0: 双规则 overlay 派生：两条规则取自各自真实规则文件，数组顺序 =
#     rules.d 文件名排序实际求值顺序（stop-guard-background-tasks 在前）
node -e '
const fs = require("fs");
const want = [
  ["stop-guard-background-tasks", process.argv[1]],
  ["stop-guard-live-subagents", process.argv[2]],
];
const picked = [];
for (const [name, file] of want) {
  const real = JSON.parse(fs.readFileSync(file, "utf8"));
  const hit = (real.rules || []).filter(r => r.name === name);
  if (hit.length !== 1) { console.error("rule not found: " + name); process.exit(1); }
  picked.push(hit[0]);
}
for (const r of picked) for (const a of r.action || [])
  if (a.path) a.path = a.path.replace("${HOOKS_DIR}", process.argv[3]);
fs.writeFileSync(process.argv[4], JSON.stringify({ version: 2, rules: picked }));
' "$RULE_FILE" "$REPO_ROOT/claude-hooks/unified/rules.d/stop-guard-subagents.json" \
  "$REPO_ROOT/claude-hooks" "$RULES_BOTH" \
  || { echo -e "  ${RED}[FAIL]${NC} C0: 双规则 overlay 派生失败"; FAIL=$((FAIL+1)); RESULTS+=("FAIL|C0: 双规则 overlay 派生"); }

# C1: 仅后台任务存活 → exit 2，stderr 只有新守卫段；firelog exit2 仅新规则
run_e2e "see1636-test" "$RULES_BOTH" "$(bg_payload "[$(bg_task t-c1 shell running)]" false sc1)"
C1ERR="$(cat "$E2E_ERR" 2>/dev/null)"
if [ "$E2E_RC" -eq 2 ] && grep -qF "[stop-guard-background-tasks]" <<< "$C1ERR" \
   && ! grep -qF "[stop-guard-subagents]" <<< "$C1ERR" \
   && grep -q "run-script-exit2 rule=stop-guard-background-tasks code=2" "$FIRELOG" 2>/dev/null \
   && ! grep -q "run-script-exit2 rule=stop-guard-live-subagents" "$FIRELOG" 2>/dev/null; then
    pass "C1: 仅后台任务存活 → exit 2，stderr 仅新守卫段，firelog 仅新规则"
else
    fail "C1: 单存活并存失真 rc=$E2E_RC err='$(echo "$C1ERR" | head -c 120)'"
fi

# C2: 仅 sub-agent 存活（background_tasks 只有 subagent 型 + meta 树存活）→
#     exit 2，stderr 只有既有守卫段；firelog exit2 仅既有规则
make_tree "sc2"; write_meta "sc2" "agent-live-c2" '{"finished":false}'
run_e2e "see1636-test" "$RULES_BOTH" "$(bg_payload "[$(bg_task t-c2-sub subagent running)]" false sc2)"
C2ERR="$(cat "$E2E_ERR" 2>/dev/null)"
if [ "$E2E_RC" -eq 2 ] && grep -qF "[stop-guard-subagents]" <<< "$C2ERR" \
   && ! grep -qF "[stop-guard-background-tasks]" <<< "$C2ERR" \
   && grep -q "run-script-exit2 rule=stop-guard-live-subagents code=2" "$FIRELOG" 2>/dev/null \
   && ! grep -q "run-script-exit2 rule=stop-guard-background-tasks" "$FIRELOG" 2>/dev/null; then
    pass "C2: 仅 sub-agent 存活 → exit 2，stderr 仅既有守卫段，firelog 仅既有规则"
else
    fail "C2: 既有守卫单存活失真 rc=$E2E_RC err='$(echo "$C2ERR" | head -c 120)'"
fi

# C3: 两者同时存活 → exit 2，stderr 两段指引都在（引擎 exitChannel 首条胜出，
#     新守卫代送既有守卫文案，不遮蔽）
make_tree "sc3"; write_meta "sc3" "agent-live-c3" '{"finished":false}'
run_e2e "see1636-test" "$RULES_BOTH" "$(bg_payload "[$(bg_task t-c3 shell running)]" false sc3)"
C3ERR="$(cat "$E2E_ERR" 2>/dev/null)"
if [ "$E2E_RC" -eq 2 ] \
   && grep -qF "[stop-guard-background-tasks]" <<< "$C3ERR" \
   && grep -qF "[stop-guard-subagents]" <<< "$C3ERR" \
   && grep -q "前台阻塞等待" <<< "$C3ERR" \
   && grep -q "尚未结束的后台 sub-agent" <<< "$C3ERR"; then
    pass "C3: 双存活 → exit 2，stderr 同时包含两段指引（首条胜出不遮蔽）"
else
    fail "C3: 双存活文案缺失 rc=$E2E_RC err='$(echo "$C3ERR" | head -c 160)'"
fi

# C4: 两者皆无 → exit 0 + 原载荷透传
run_e2e "see1636-test" "$RULES_BOTH" "$(bg_payload "[$(bg_task t-c4 shell completed)]" false sc4)"
if [ "$E2E_RC" -eq 0 ] && grep -q '"session_id":"sc4"' <<< "$(cat "$E2E_OUT" 2>/dev/null)"; then
    pass "C4: 两者皆无 → exit 0 + 透传"
else
    fail "C4: 空场景误拦 rc=$E2E_RC"
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
