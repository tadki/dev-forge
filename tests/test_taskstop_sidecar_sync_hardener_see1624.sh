#!/bin/bash
# SEE-1624 §SPEC-018 hardener（Harti）— 语义变异幸存者判别力补强。
#
# 背景：本 issue 的教训是「测试全绿但真实事件零写入」。Round-1 语义变异
# 在下列位点存活（现有断言面缺口），逐点补钉当前生产行为（零行为变更，
# 断言均为"现状即正确"的判别力钉）：
#
#   M. 失败信号与非成功文案的真实载荷形态：is_error:true + 成功文案、
#      无 error 旗标 + 失败文案 → 一律不写（错误门与文案门各自独立）
#   N. 文案 id 与请求 id 一致性：不一致不写；无 id 的成功文案不写
#      （不可验证=不写）；带/裸前缀交叉写法归一命中（真实两种写法）
#   O. 非 TaskStop 工具名载荷不触发同步（脚本侧纵深闸）
#   P. 损坏 meta：不写、内容不变、零 .gqt-tmp 残留（fail-open 且不脏写）；
#      可读未完成 meta 的写入口对照
#   Q. tool_response 为 text-array 形态（真实载荷变体）→ 成功写入
#   R. 真实命名 agent-<hex>.meta.json 写入时保留其余字段
#
# 约束：只读产品面；全部状态在 mktemp fixture 内；不改动既有 33 项套件。
# Run:    bash tests/test_taskstop_sidecar_sync_hardener_see1624.sh
set -uo pipefail

unset MULTICA_TASK_ID MULTICA_AGENT_ID MULTICA_AGENT_NAME \
      MULTICA_TOKEN MULTICA_SERVER_URL MULTICA_WORKSPACE_ID

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0; RESULTS=()
pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); RESULTS+=("PASS|$1"); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); RESULTS+=("FAIL|$1"); }
separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYNC="$REPO_ROOT/claude-hooks/scripts/taskstop-sidecar-sync.sh"
FIXTURE="$(mktemp -d /tmp/taskstop-sync-hardener-see1624.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

# 真实 sidecar 形态 fixture：<sid>/subagents/agent-<key>.meta.json
make_real_tree() {  # make_real_tree <sid> <key> [finished-raw-json]
    mkdir -p "$FIXTURE/$1/subagents"
    printf '{}' > "$FIXTURE/$1.jsonl"
    printf '{"agentType":"general-purpose","description":"real","finished":%s}' \
        "${3:-false}" > "$FIXTURE/$1/subagents/agent-$2.meta.json"
}

# 真实事件载荷（object tool_response）；msg 经 python3 JSON 转义
payload_obj_simple() {  # payload_obj_simple <sid> <task_id> <message> [is_error-json]
    local sid="$1" tid="$2" msg="$3" err="${4:-}"
    local esc
    esc="$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
    local tr="{\"message\":$esc"
    [ -n "$err" ] && tr="$tr,\"is_error\":$err"
    tr="$tr}"
    printf '{"hook_event_name":"PostToolUse","tool_name":"TaskStop","session_id":"%s","transcript_path":"%s/%s.jsonl","tool_input":{"task_id":"%s"},"tool_response":%s}' \
        "$sid" "$FIXTURE" "$sid" "$tid" "$tr"
}

payload_tool() {  # payload_tool <tool_name> <sid> <task_id> <message>
    local tool="$1" sid="$2" tid="$3" msg="$4"
    local esc
    esc="$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
    printf '{"hook_event_name":"PostToolUse","tool_name":"%s","session_id":"%s","transcript_path":"%s/%s.jsonl","tool_input":{"task_id":"%s"},"tool_response":{"message":%s}}' \
        "$tool" "$sid" "$FIXTURE" "$sid" "$tid" "$esc"
}

payload_array() {  # payload_array <sid> <task_id> <text>
    local sid="$1" tid="$2" text="$3"
    local esc
    esc="$(printf '%s' "$text" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
    printf '{"hook_event_name":"PostToolUse","tool_name":"TaskStop","session_id":"%s","transcript_path":"%s/%s.jsonl","tool_input":{"task_id":"%s"},"tool_response":[{"type":"text","text":%s}]}' \
        "$sid" "$FIXTURE" "$sid" "$tid" "$esc"
}

run_sync() {  # run_sync <payload-json>
    local p="$FIXTURE/in.json"
    printf '%s' "$1" > "$p"
    timeout 10 bash "$SYNC" < "$p" > "$FIXTURE/out.txt" 2> "$FIXTURE/err.txt"
    echo $?
}

finished_of() {
    [ -f "$1" ] || { echo "missing"; return; }
    jq -r 'if has("finished") then (.finished|tostring) else "absent" end' "$1" 2>/dev/null || echo "unreadable"
}

residue_of() {  # residue_of <sid>：非 .meta.json 文件清单
    ls "$FIXTURE/$1/subagents/" 2>/dev/null | grep -v 'meta.json$' || true
}

# ---------------- M. 失败信号 + 文案的真实载荷组合 ----------------
separator "M. 失败信号/失败文案（真实载荷形态）→ 不写"
make_real_tree sidM1 m1hex0001
RC="$(run_sync "$(payload_obj_simple sidM1 agent-m1hex0001 'Successfully stopped task: agent-m1hex0001' true)")"
if [ "$RC" = "0" ] && [ "$(finished_of "$FIXTURE/sidM1/subagents/agent-m1hex0001.meta.json")" = "false" ]; then
    pass "M1: is_error:true + 成功文案 → 不写（错误门独立生效）"
else
    fail "M1: 错误门失效 rc=$RC finished=$(finished_of "$FIXTURE/sidM1/subagents/agent-m1hex0001.meta.json")"
fi

make_real_tree sidM2 m2hex0002
RC="$(run_sync "$(payload_obj_simple sidM2 agent-m2hex0002 'Failed to stop task: agent-m2hex0002')")"
if [ "$RC" = "0" ] && [ "$(finished_of "$FIXTURE/sidM2/subagents/agent-m2hex0002.meta.json")" = "false" ]; then
    pass "M2: 无 is_error 旗标 + 失败文案 → 不写（文案门独立生效）"
else
    fail "M2: 文案门失效 rc=$RC finished=$(finished_of "$FIXTURE/sidM2/subagents/agent-m2hex0002.meta.json")"
fi

# ---------------- N. 文案/请求 id 一致性 ----------------
separator "N. 文案 id 与请求 id 一致性（不可验证=不写）"
make_real_tree sidN1 n1hex0001
RC="$(run_sync "$(payload_obj_simple sidN1 agent-n1hex0001 'Successfully stopped task: agent-other9999')")"
if [ "$RC" = "0" ] && [ "$(finished_of "$FIXTURE/sidN1/subagents/agent-n1hex0001.meta.json")" = "false" ]; then
    pass "N1: 文案 id 与请求不一致 → 不写"
else
    fail "N1: id 不一致仍写 rc=$RC finished=$(finished_of "$FIXTURE/sidN1/subagents/agent-n1hex0001.meta.json")"
fi

make_real_tree sidN2 n2hex0002
RC="$(run_sync "$(payload_obj_simple sidN2 agent-n2hex0002 'Successfully stopped task.')")"
if [ "$RC" = "0" ] && [ "$(finished_of "$FIXTURE/sidN2/subagents/agent-n2hex0002.meta.json")" = "false" ]; then
    pass "N2: 成功文案无任何 id → 不写（不可验证=不写）"
else
    fail "N2: 无 id 文案仍写 rc=$RC finished=$(finished_of "$FIXTURE/sidN2/subagents/agent-n2hex0002.meta.json")"
fi

make_real_tree sidN3 a1b2c3d4e5f60718
RC="$(run_sync "$(payload_obj_simple sidN3 a1b2c3d4e5f60718 'Successfully stopped task: agent-a1b2c3d4e5f60718')")"
if [ "$RC" = "0" ] && [ "$(finished_of "$FIXTURE/sidN3/subagents/agent-a1b2c3d4e5f60718.meta.json")" = "true" ]; then
    pass "N3: 裸 hex 请求 + 带前缀文案 → 归一命中写入（真实交叉写法）"
else
    fail "N3: 交叉写法未命中 rc=$RC finished=$(finished_of "$FIXTURE/sidN3/subagents/agent-a1b2c3d4e5f60718.meta.json")"
fi

# ---------------- O. 工具名纵深闸 ----------------
separator "O. 非 TaskStop 工具 → 不触发同步"
make_real_tree sidO o1hex0001
RC="$(run_sync "$(payload_tool TaskGet sidO agent-o1hex0001 'Successfully stopped task: agent-o1hex0001')")"
if [ "$RC" = "0" ] && [ "$(finished_of "$FIXTURE/sidO/subagents/agent-o1hex0001.meta.json")" = "false" ]; then
    pass "O1: tool_name=TaskGet → 不写"
else
    fail "O1: 非 TaskStop 仍写 rc=$RC finished=$(finished_of "$FIXTURE/sidO/subagents/agent-o1hex0001.meta.json")"
fi

# ---------------- P. 损坏 meta：fail-open 且零残留 ----------------
separator "P. 损坏 meta → 不写、零临时残留；可读未完成 meta 对照"
mkdir -p "$FIXTURE/sidP1/subagents"
printf '{}' > "$FIXTURE/sidP1.jsonl"
printf '{not-json' > "$FIXTURE/sidP1/subagents/agent-p1hex0001.meta.json"
BEFORE_P1="$(cat "$FIXTURE/sidP1/subagents/agent-p1hex0001.meta.json")"
RC="$(run_sync "$(payload_obj_simple sidP1 agent-p1hex0001 'Successfully stopped task: agent-p1hex0001')")"
AFTER_P1="$(cat "$FIXTURE/sidP1/subagents/agent-p1hex0001.meta.json")"
[ "$RC" = "0" ] && pass "P1a: 损坏 meta exit 0（fail-open）" || fail "P1a: exit=$RC"
[ "$BEFORE_P1" = "$AFTER_P1" ] && pass "P1b: 损坏 meta 内容不变" || fail "P1b: 损坏 meta 被改写"
RES="$(residue_of sidP1)"
[ -z "$RES" ] && pass "P1c: 损坏 meta 零 .gqt-tmp 残留" || fail "P1c: 残留临时文件: $RES"

make_real_tree sidP2 p2hex0002 false
RC="$(run_sync "$(payload_obj_simple sidP2 agent-p2hex0002 'Successfully stopped task: agent-p2hex0002')")"
[ "$RC" = "0" ] && [ "$(finished_of "$FIXTURE/sidP2/subagents/agent-p2hex0002.meta.json")" = "true" ] \
    && pass "P2: 对照——可读未完成 meta 正常写入" \
    || fail "P2: 对照未写入 rc=$RC"

# ---------------- Q. text-array 载荷形态 ----------------
separator "Q. tool_response 为 text-array（真实载荷变体）"
make_real_tree sidQ q1hex0001
RC="$(run_sync "$(payload_array sidQ agent-q1hex0001 'Successfully stopped task: agent-q1hex0001')")"
if [ "$RC" = "0" ] && [ "$(finished_of "$FIXTURE/sidQ/subagents/agent-q1hex0001.meta.json")" = "true" ]; then
    pass "Q1: text-array 成功形态 → 写入 finished=true"
else
    fail "Q1: text-array 未写 rc=$RC finished=$(finished_of "$FIXTURE/sidQ/subagents/agent-q1hex0001.meta.json")"
fi

# ---------------- S. 无 sidecar 的真实命名 id → 不创建任何文件 ----------------
separator "S. 无 sidecar 的后台任务（真实命名）→ 零创建"
make_real_tree sidS keep1hex11 false
RC="$(run_sync "$(payload_obj_simple sidS bghex9999 'Successfully stopped task: bghex9999')")"
if [ "$RC" = "0" ] && [ ! -e "$FIXTURE/sidS/subagents/agent-bghex9999.meta.json" ]; then
    pass "S1: 无 sidecar 的真实命名 → 未创建 agent-<id>.meta.json"
else
    fail "S1: 凭空创建真实命名 meta rc=$RC"
fi
COUNT="$(ls "$FIXTURE/sidS/subagents/" | wc -l)"
[ "$COUNT" = "1" ] && pass "S2: subagents 目录文件数不变（仅预置 1 份）" \
    || fail "S2: 目录文件数=$COUNT（预期 1）"

# ---------------- R. 真实命名写入保留其余字段 ----------------
separator "R. 真实命名 agent-<hex>.meta.json 写入保留其余字段"
make_real_tree sidR r1hex0001 false
RC="$(run_sync "$(payload_obj_simple sidR agent-r1hex0001 'Successfully stopped task: agent-r1hex0001')")"
if [ "$RC" = "0" ] && jq -e '.agentType == "general-purpose" and .description == "real" and .finished == true' \
      "$FIXTURE/sidR/subagents/agent-r1hex0001.meta.json" >/dev/null 2>&1; then
    pass "R1: finished=true 且其余字段保留（真实命名）"
else
    fail "R1: 字段丢失或未写 rc=$RC"
fi

echo ""
echo -e "=== 结果：PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -ne 0 ]; then
    printf '%s\n' "${RESULTS[@]}" | grep '^FAIL|' || true
    exit 1
fi
exit 0
