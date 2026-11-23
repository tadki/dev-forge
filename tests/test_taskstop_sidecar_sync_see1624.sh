#!/bin/bash
# SEE-1624 §SPEC-018 — TaskStop/sidecar 生命周期同步根修判别力测试。
#
# 根因（Atlas 2026-11-23 定位）：CC TaskStop 成功停止后任务注册表已无活动
# agent，但 sidecar meta 未回写 finished:true → stop-guard-subagents.sh
# 把已停止 agent 当作"未结束"，每次 Stop 误报（exit 2 假阳性）。
#
# 覆盖（行为断言，不看源码）：
#   A. 成功停止 → 仅目标 meta 变为 finished:true（其他字段保留）
#   B. TaskStop 失败（is_error / 非成功文案）→ 不写任何文件
#   C. task not found → 不写
#   D. 非法/穿越 id（".."、含 "/"、空）→ 不写、不越界（暂存区外零文件）
#   E. 无 meta 的后台任务 id → 不创建任何文件
#   F. 重复 Stop 幂等（内容不变、无残留临时文件）
#   G. live 且缺 finished 的 agent → stop-guard 仍 exit 2（既有防线不退化）
#
# 约束：本套件只读产品面（脚本/规则 JSON），全部状态在 mktemp fixture 内。
# Run:    bash tests/test_taskstop_sidecar_sync_see1624.sh
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
GUARD="$REPO_ROOT/claude-hooks/scripts/stop-guard-subagents.sh"
RULE="$REPO_ROOT/claude-hooks/unified/rules.d/taskstop-sidecar-sync.json"
FIXTURE="$(mktemp -d /tmp/taskstop-sync-see1624.XXXXXX)"

trap 'rm -rf "$FIXTURE"' EXIT

# --- fixture：<sid>.jsonl 转录占位 + <sid>/subagents/<id>.meta.json ----------
make_tree() {  # make_tree <sid> <agent-id> [finished]
    mkdir -p "$FIXTURE/$1/subagents"
    printf '{}' > "$FIXTURE/$1.jsonl"
    if [ -n "${3:-}" ]; then
        printf '{"agentType":"general-purpose","description":"probe","finished":%s}' "$3" \
            > "$FIXTURE/$1/subagents/$2.meta.json"
    else
        printf '{"agentType":"general-purpose","description":"probe"}' \
            > "$FIXTURE/$1/subagents/$2.meta.json"
    fi
}

payload() {  # payload <session_id> <task_id> <message> [is_error]
    local sid="$1" tid="$2" msg="$3" err="${4:-false}"
    printf '{"tool_name":"TaskStop","session_id":"%s","transcript_path":"%s/%s.jsonl",' \
        "$sid" "$FIXTURE" "$sid"
    printf '"tool_input":{"task_id":"%s"},' "$tid"
    printf '"tool_response":{"message":%s,"is_error":%s}}' \
        "$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" "$err"
}

run_sync() {  # run_sync <payload-json>；输出 rc
    local p="$FIXTURE/in.json"
    printf '%s' "$1" > "$p"
    timeout 10 bash "$SYNC" < "$p" > "$FIXTURE/out.txt" 2> "$FIXTURE/err.txt"
    echo $?
}

finished_of() {  # finished_of <meta-path> → true/false/null
    [ -f "$1" ] || { echo "missing"; return; }
    jq -r 'if has("finished") then (.finished|tostring) else "absent" end' "$1" 2>/dev/null || echo "unreadable"
}

separator "A. 成功停止 → 目标 meta finished:true（其他字段保留）"
make_tree sidA agent-ok
RC="$(run_sync "$(payload sidA agent-ok 'Successfully stopped task: agent-ok (some detail)')")"
[ "$RC" = "0" ] && pass "A1: 成功停止 exit 0" || fail "A1: 成功停止 exit=$RC"
[ "$(finished_of "$FIXTURE/sidA/subagents/agent-ok.meta.json")" = "true" ] \
    && pass "A2: 目标 meta finished=true" || fail "A2: finished=$(finished_of "$FIXTURE/sidA/subagents/agent-ok.meta.json")"
jq -e '.description == "probe" and .agentType == "general-purpose"' \
    "$FIXTURE/sidA/subagents/agent-ok.meta.json" >/dev/null 2>&1 \
    && pass "A3: 其他字段保留" || fail "A3: 其他字段丢失"
ls "$FIXTURE/sidA/subagents/" | grep -v 'meta.json$' | grep -q . \
    && fail "A4: 残留临时文件" || pass "A4: 无残留临时文件"

separator "B. TaskStop 失败 → 不写任何文件"
make_tree sidB agent-fail
RC="$(run_sync "$(payload sidB agent-fail 'Failed to stop task: agent-fail' true)")"
[ "$RC" = "0" ] && pass "B1: 失败停止 exit 0（不阻断工具调用）" || fail "B1: exit=$RC"
[ "$(finished_of "$FIXTURE/sidB/subagents/agent-fail.meta.json")" = "absent" ] \
    && pass "B2: 失败停止不写 meta" || fail "B2: finished=$(finished_of "$FIXTURE/sidB/subagents/agent-fail.meta.json")"

separator "C. task not found → 不写"
make_tree sidC agent-gone
RC="$(run_sync "$(payload sidC agent-gone 'Task agent-gone not found' true)")"
[ "$RC" = "0" ] && pass "C1: not-found exit 0" || fail "C1: exit=$RC"
[ "$(finished_of "$FIXTURE/sidC/subagents/agent-gone.meta.json")" = "absent" ] \
    && pass "C2: not-found 不写 meta" || fail "C2: finished=$(finished_of "$FIXTURE/sidC/subagents/agent-gone.meta.json")"

separator "D. 非法/穿越 id → 不写、不越界"
make_tree sidD agent-keep
for bad_id in "../../evil" "sub/agent" "" "../sidD/subagents/agent-keep"; do
    RC="$(run_sync "$(payload sidD "$bad_id" 'Successfully stopped task: x')")"
    if [ "$RC" = "0" ] && [ "$(finished_of "$FIXTURE/sidD/subagents/agent-keep.meta.json")" = "absent" ]; then
        pass "D: 非法 id [$bad_id] 不写不改"
    else
        fail "D: 非法 id [$bad_id] exit=$RC finished=$(finished_of "$FIXTURE/sidD/subagents/agent-keep.meta.json")"
    fi
done
[ -e "$FIXTURE/evil.meta.json" ] && fail "D: 穿越写越界" || pass "D: 穿越未越界（暂存区外零文件）"
OUTSIDE="$(find "$FIXTURE" -maxdepth 1 -name '*.meta.json' | wc -l)"
[ "$OUTSIDE" = "0" ] && pass "D: 暂存区外零 meta" || fail "D: 暂存区外存在 meta x$OUTSIDE"

separator "E. 无 meta 的后台任务 → 不创建任何文件"
make_tree sidE agent-other
RC="$(run_sync "$(payload sidE bg-task-123 'Successfully stopped task: bg-task-123')")"
[ "$RC" = "0" ] && pass "E1: 无 meta exit 0" || fail "E1: exit=$RC"
[ ! -e "$FIXTURE/sidE/subagents/bg-task-123.meta.json" ] \
    && pass "E2: 未创建 meta（无 sidecar 不生成）" || fail "E2: 凭空创建 meta"

separator "F. 重复 Stop 幂等"
make_tree sidF agent-idem
run_sync "$(payload sidF agent-idem 'Successfully stopped task: agent-idem')" > /dev/null
BEFORE="$(cat "$FIXTURE/sidF/subagents/agent-idem.meta.json")"
run_sync "$(payload sidF agent-idem 'Successfully stopped task: agent-idem')" > /dev/null
AFTER="$(cat "$FIXTURE/sidF/subagents/agent-idem.meta.json")"
[ "$BEFORE" = "$AFTER" ] && pass "F1: 重复 Stop 内容不变" || fail "F1: 重复 Stop 改了内容"
ls "$FIXTURE/sidF/subagents/" | grep -v 'meta.json$' | grep -q . \
    && fail "F2: 残留临时文件" || pass "F2: 无残留临时文件"

separator "G. live 且缺 finished → stop-guard 仍 exit 2（防线不退化）"
make_tree sidG agent-live
GUARD_PAYLOAD="$FIXTURE/guard.json"
printf '{"session_id":"sidG","transcript_path":"%s/sidG.jsonl"}' "$FIXTURE" > "$GUARD_PAYLOAD"
timeout 10 bash "$GUARD" < "$GUARD_PAYLOAD" > "$FIXTURE/g.out" 2> "$FIXTURE/g.err"
GRC=$?
[ "$GRC" = "2" ] && pass "G1: live 缺 finished 仍 exit 2" || fail "G1: guard exit=$GRC"
grep -q "agent-live" "$FIXTURE/g.err" \
    && pass "G2: guard 仍点名 live agent" || fail "G2: guard 未点名"

separator "H. 同步成功后 stop-guard 不再误报"
make_tree sidH agent-done
run_sync "$(payload sidH agent-done 'Successfully stopped task: agent-done')" > /dev/null
printf '{"session_id":"sidH","transcript_path":"%s/sidH.jsonl"}' "$FIXTURE" > "$GUARD_PAYLOAD"
timeout 10 bash "$GUARD" < "$GUARD_PAYLOAD" > "$FIXTURE/h.out" 2> "$FIXTURE/h.err"
HRC=$?
[ "$HRC" = "0" ] && pass "H1: 已停止 agent 不再误报（exit 0）" || fail "H1: guard exit=$HRC"

separator "I. 规则注册存在且被引擎校验接受"
[ -f "$RULE" ] && pass "I1: rules.d 规则文件存在" || fail "I1: 缺 rules.d/taskstop-sidecar-sync.json"
if [ -f "$RULE" ]; then
    node "$REPO_ROOT/claude-hooks/validate-rules.js" "$RULE" > "$FIXTURE/v.out" 2>&1
    VRC=$?
    [ "$VRC" = "0" ] && pass "I2: 规则通过 validate-rules.js" \
        || fail "I2: 规则校验失败 rc=$VRC: $(head -3 "$FIXTURE/v.out" | tr '\n' ' ')"
fi
grep -q "taskstop-sidecar-sync" "$REPO_ROOT/bootstrap/hooks-registration.json" \
    && pass "I3: bootstrap 注册清单含新脚本/规则" || fail "I3: bootstrap 未登记"


separator "J. 引擎端到端（真实规则文件派生 overlay → unified-hook 触发同步）"
ENTRY="$REPO_ROOT/claude-hooks/unified/unified-hook.sh"
E2E_RULES="$FIXTURE/rules-overlay.json"
E2E_FIRELOG="$FIXTURE/e2e-fire.log"
E2E_STATE="$FIXTURE/e2e-state"
node -e '
const fs = require("fs");
const real = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const picked = (real.rules || []).filter(r => r.name === "taskstop-sidecar-finished-sync");
if (picked.length !== 1) { console.error("rule not found"); process.exit(1); }
for (const r of picked) for (const a of r.action || [])
  if (a.path) a.path = a.path.replace("${HOOKS_DIR}", process.argv[2]);
fs.writeFileSync(process.argv[3], JSON.stringify({ version: 2, rules: picked }));
' "$RULE" "$REPO_ROOT/claude-hooks" "$E2E_RULES" >/dev/null 2>&1
if [ -f "$E2E_RULES" ]; then
    pass "J1: 真实规则文件派生 overlay 成功"
else
    fail "J1: overlay 派生失败"
fi

e2e_payload() {  # e2e_payload <sid> <task_id> <message>
    local sid="$1" tid="$2" msg="$3"
    printf '{"hook_event_name":"PostToolUse","tool_name":"TaskStop","session_id":"%s",' "$sid"
    printf '"transcript_path":"%s/%s.jsonl","tool_input":{"task_id":"%s"},' "$FIXTURE" "$sid" "$tid"
    printf '"tool_response":{"message":%s}}' \
        "$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
}

make_tree sidJ agent-j
printf '%s' "$(e2e_payload sidJ agent-j 'Successfully stopped task: agent-j')" > "$FIXTURE/j-in.json"
: > "$E2E_FIRELOG"
E2E_RC=0
UNIFIED_RULES_FILE="$E2E_RULES" HOOK_FIRE_LOG="$E2E_FIRELOG" \
    HOOK_STATE_DIR="$E2E_STATE" PROJECT_ROOT="$REPO_ROOT" \
    timeout 20 bash "$ENTRY" < "$FIXTURE/j-in.json" > "$FIXTURE/j-out.txt" 2> "$FIXTURE/j-err.txt" || E2E_RC=$?
if [ "$E2E_RC" = "0" ] && [ "$(finished_of "$FIXTURE/sidJ/subagents/agent-j.meta.json")" = "true" ]; then
    pass "J2: 引擎 E2E 成功停止 → meta finished=true"
else
    fail "J2: 引擎 E2E 未同步 rc=$E2E_RC finished=$(finished_of "$FIXTURE/sidJ/subagents/agent-j.meta.json")"
fi

make_tree sidK agent-k
printf '%s' "$(e2e_payload sidK agent-k 'Task agent-k not found')" > "$FIXTURE/k-in.json"
UNIFIED_RULES_FILE="$E2E_RULES" HOOK_FIRE_LOG="$E2E_FIRELOG" \
    HOOK_STATE_DIR="$E2E_STATE" PROJECT_ROOT="$REPO_ROOT" \
    timeout 20 bash "$ENTRY" < "$FIXTURE/k-in.json" > "$FIXTURE/k-out.txt" 2> "$FIXTURE/k-err.txt"
KRC=$?
if [ "$KRC" = "0" ] && [ "$(finished_of "$FIXTURE/sidK/subagents/agent-k.meta.json")" = "absent" ]; then
    pass "J3: 引擎 E2E 失败停止 → 不写 meta 且不阻断工具调用"
else
    fail "J3: 引擎 E2E 失败停止语义破坏 rc=$KRC finished=$(finished_of "$FIXTURE/sidK/subagents/agent-k.meta.json")"
fi

echo ""
echo -e "=== 结果：PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -ne 0 ]; then
    printf '%s\n' "${RESULTS[@]}" | grep '^FAIL|' || true
    exit 1
fi
exit 0
