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

# 攻击运行器（确定性）：wrapper 打印自身 $$ 后**等待 go 文件**再 exec 同步
# 脚本（exec 保留 PID）——测试据 pidfile 预置同名临时路径并确认就位后才放行
# 脚本执行：无固定 sleep、无 PID 猜测；任一 setup 失败即显式失败（返回非 0），
# 杜绝"攻击未发生却判绿"。
run_sync_attacked() {  # run_sync_attacked <payload> <tmpbase> <sentinel> <symlink|hardlink>
    local pl="$1" tb="$2" sen="$3" mode="$4"
    local pidfile="$FIXTURE/attack.pid" gofile="$FIXTURE/attack.go"
    rm -f "$pidfile" "$gofile"
    printf '%s' "$pl" > "$FIXTURE/attack-in.json"
    bash -c 'echo $$ > "$1"; while [ ! -e "$2" ]; do sleep 0.05; done; exec bash "$3" < "$4" > /dev/null 2>&1' \
        _ "$pidfile" "$gofile" "$SYNC" "$FIXTURE/attack-in.json" &
    local wrapper=$!
    local i spid=""
    for i in $(seq 1 100); do
        [ -s "$pidfile" ] && { spid="$(cat "$pidfile")"; break; }
        sleep 0.05
    done
    if [ -z "$spid" ]; then
        kill "$wrapper" 2>/dev/null || true
        wait "$wrapper" 2>/dev/null || true
        echo "attack setup failed: no script pid" >&2
        return 1
    fi
    if [ "$mode" = "hardlink" ]; then
        ln "$sen" "$tb.$spid" 2>/dev/null || {
            kill "$wrapper" 2>/dev/null || true; wait "$wrapper" 2>/dev/null || true
            echo "attack setup failed: hardlink not created" >&2; return 1; }
    else
        ln -s "$sen" "$tb.$spid" 2>/dev/null || {
            kill "$wrapper" 2>/dev/null || true; wait "$wrapper" 2>/dev/null || true
            echo "attack setup failed: symlink not created" >&2; return 1; }
    fi
    # 确认攻击确实就位（链接存在），否则不得放行脚本
    if [ ! -e "$tb.$spid" ] && [ ! -L "$tb.$spid" ]; then
        kill "$wrapper" 2>/dev/null || true
        wait "$wrapper" 2>/dev/null || true
        echo "attack setup failed: planted path not in place" >&2
        return 1
    fi
    : > "$gofile"          # 放行同步脚本（攻击已就位）
    wait "$wrapper"
    return 0
}

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

separator "I. 规则被引擎校验接受（注册/部署一致性由既有行为门覆盖）"
# 注册与部署一致性属**结构面**，由既有行为门承担：
#   tests/test_hooks_5_1_registration.sh（规则名 ⊆ §5.1 现役清单 + 治理校验）
#   tests/test_hook_registration_see270.sh（部署清单完整性）
#   两者均由 tests/run_all.sh 聚合执行；本套件另以 J 段引擎 E2E 证明规则
#   **实际会触发**（行为面），不再重复断言产品文件存在/注册清单文本。
node "$REPO_ROOT/claude-hooks/validate-rules.js" "$RULE" > "$FIXTURE/v.out" 2>&1
VRC=$?
[ "$VRC" = "0" ] && pass "I1: 规则通过 validate-rules.js（校验器判定）" \
    || fail "I1: 规则校验失败 rc=$VRC: $(head -3 "$FIXTURE/v.out" | tr '\n' ' ')"


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

separator "K. 真实 sidecar 命名反例（agent-<task_id>.meta.json，裸 hex id）"
# 真实 CC 形态：TaskStop 的 task_id 可能是不带前缀的裸 hex，而 sidecar
# 文件名恒为 agent-<hex>.meta.json（411/411 实测形态）。初版脚本拼
# "$TASK_ID.meta.json" → 真实事件下找不到目标文件、静默 exit 0，
# finished:true 从未写入。
make_tree_real() {  # make_tree_real <sid> <agent-hex>
    mkdir -p "$FIXTURE/$1/subagents"
    printf '{}' > "$FIXTURE/$1.jsonl"
    printf '{"agentType":"general-purpose","description":"real-shape"}' \
        > "$FIXTURE/$1/subagents/agent-$2.meta.json"
}

make_tree_real sidL ac08001741afe9ea3
RC="$(run_sync "$(payload sidL ac08001741afe9ea3 'Successfully stopped task: ac08001741afe9ea3')")"
if [ "$RC" = "0" ] && [ "$(finished_of "$FIXTURE/sidL/subagents/agent-ac08001741afe9ea3.meta.json")" = "true" ]; then
    pass "K1: 裸 hex id → 真实命名 agent-<id>.meta.json 被同步"
else
    fail "K1: 真实命名未同步 rc=$RC finished=$(finished_of "$FIXTURE/sidL/subagents/agent-ac08001741afe9ea3.meta.json")"
fi
if [ -e "$FIXTURE/sidL/subagents/ac08001741afe9ea3.meta.json" ]; then
    fail "K2: 拼出了非真实命名的 meta 文件"
else
    pass "K2: 未创建 <id>.meta.json（只认真实命名）"
fi
OTHER="$(ls "$FIXTURE/sidL/subagents/" | grep -v '^agent-ac08001741afe9ea3.meta.json$' || true)"
[ -z "$OTHER" ] && pass "K3: 其他文件零改动" || fail "K3: 其他文件被改动: $OTHER"

# 带前缀 id → 不得双前缀（agent-agent-<hex>）
make_tree_real sidM a1098fce0dd6a5a75
RC="$(run_sync "$(payload sidM agent-a1098fce0dd6a5a75 'Successfully stopped task: agent-a1098fce0dd6a5a75')")"
if [ "$RC" = "0" ] && [ "$(finished_of "$FIXTURE/sidM/subagents/agent-a1098fce0dd6a5a75.meta.json")" = "true" ]; then
    pass "K4: 带 agent- 前缀 id → 命中同一真实命名（无双前缀）"
else
    fail "K4: 前缀 id 未命中 rc=$RC finished=$(finished_of "$FIXTURE/sidM/subagents/agent-a1098fce0dd6a5a75.meta.json")"
fi
[ -e "$FIXTURE/sidM/subagents/agent-agent-a1098fce0dd6a5a75.meta.json" ] \
    && fail "K5: 产生双前缀文件" || pass "K5: 无双前缀文件"

separator "L. 真实 tool_use_error 字符串形态（实机 not found 载荷）"
# 实机观测：TaskStop 对已消失任务的 tool_response 是字符串
# "<tool_use_error>No task found with ID: agent-xxx</tool_use_error>"
# —— 该形态必须不写任何文件（不是成功停止）。
make_tree_real sidN a1098fce0dd6a5a75
ERR_PAYLOAD="$FIXTURE/n-in.json"
printf '{"hook_event_name":"PostToolUse","tool_name":"TaskStop","session_id":"sidN",' > "$ERR_PAYLOAD"
printf '"transcript_path":"%s/sidN.jsonl","tool_input":{"task_id":"agent-a1098fce0dd6a5a75"},' "$FIXTURE" >> "$ERR_PAYLOAD"
printf '"tool_response":"<tool_use_error>No task found with ID: agent-a1098fce0dd6a5a75</tool_use_error>"}}' >> "$ERR_PAYLOAD"
timeout 10 bash "$SYNC" < "$ERR_PAYLOAD" > "$FIXTURE/n-out.txt" 2> "$FIXTURE/n-err.txt"
NRC=$?
if [ "$NRC" = "0" ] && [ "$(finished_of "$FIXTURE/sidN/subagents/agent-a1098fce0dd6a5a75.meta.json")" = "absent" ]; then
    pass "L1: 真实 not-found 字符串载荷 → 不写 meta 且不阻断"
else
    fail "L1: not-found 载荷语义破坏 rc=$NRC finished=$(finished_of "$FIXTURE/sidN/subagents/agent-a1098fce0dd6a5a75.meta.json")"
fi

separator "M. 文件系统边界反例（Final Review HIGH-1/HIGH-2）"
# M1: subagents/ 目录自身是 symlink → 指向外部目录；成功停止不得写外部
EXT="$FIXTURE/outside-subagents"; mkdir -p "$EXT"
printf '{"agentType":"general-purpose","description":"outside"}' \
    > "$EXT/agent-abc123.meta.json"
printf 'DO-NOT-OVERWRITE' > "$FIXTURE/outside-sentinel.txt"
mkdir -p "$FIXTURE/sidP"; printf '{}' > "$FIXTURE/sidP.jsonl"
ln -s "$EXT" "$FIXTURE/sidP/subagents"
run_sync "$(payload sidP abc123 'Successfully stopped task: abc123')" > /dev/null
if [ "$(finished_of "$EXT/agent-abc123.meta.json")" = "absent" ] \
   && [ "$(cat "$FIXTURE/outside-sentinel.txt")" = "DO-NOT-OVERWRITE" ]; then
    pass "M1: subagents 目录 symlink 逃逸 → 外部零写入"
else
    fail "M1: 目录逃逸仍写入外部 finished=$(finished_of "$EXT/agent-abc123.meta.json") sentinel=$(cat "$FIXTURE/outside-sentinel.txt")"
fi

# M2: 预置可预测临时路径 symlink（同名族 PID 区间）→ 外部文件不得被覆盖
make_tree sidQ agent-abc123
SENTINEL="$FIXTURE/sentinel-q.txt"; printf 'DO-NOT-OVERWRITE' > "$SENTINEL"
TMPLINK_BASE="$FIXTURE/sidQ/subagents/agent-abc123.meta.json.gqt-tmp"
if ! run_sync_attacked "$(payload sidQ agent-abc123 'Successfully stopped task: agent-abc123')" \
        "$TMPLINK_BASE" "$SENTINEL" symlink; then
    fail "M2: 攻击 setup 失败（未预置临时路径）→ 判定不成立"
fi
if [ "$(cat "$SENTINEL")" = "DO-NOT-OVERWRITE" ]; then
    pass "M2: 预置临时 symlink → 外部文件零改动"
else
    fail "M2: 外部文件被覆盖: $(cat "$SENTINEL")"
fi
if [ -L "$FIXTURE/sidQ/subagents/agent-abc123.meta.json" ]; then
    fail "M3: 目标 meta 变成 symlink（指向外部文件）"
else
    pass "M3: 目标 meta 仍为普通文件"
fi
if [ "$(finished_of "$FIXTURE/sidQ/subagents/agent-abc123.meta.json")" = "true" ]; then
    pass "M4: 真实布局同步仍写入 finished=true"
else
    fail "M4: 同步未生效 finished=$(finished_of "$FIXTURE/sidQ/subagents/agent-abc123.meta.json")"
fi

# M5: 预置硬链接临时路径 → 外部文件内容不得被就地改写
make_tree sidR agent-def456
SENTINEL2="$FIXTURE/sentinel-r.txt"; printf 'DO-NOT-OVERWRITE' > "$SENTINEL2"
TMPLINK_BASE2="$FIXTURE/sidR/subagents/agent-def456.meta.json.gqt-tmp"
if ! run_sync_attacked "$(payload sidR agent-def456 'Successfully stopped task: agent-def456')" \
        "$TMPLINK_BASE2" "$SENTINEL2" hardlink; then
    fail "M5: 攻击 setup 失败（未预置硬链接）→ 判定不成立"
fi
if [ "$(cat "$SENTINEL2")" = "DO-NOT-OVERWRITE" ]; then
    pass "M5: 预置硬链接 → 外部文件零改动"
else
    fail "M5: 外部文件被就地改写: $(cat "$SENTINEL2")"
fi

# M7: 攻击 setup 失败必须显式失败（不得静默继续判绿）
SENT3="$FIXTURE/sentinel-x.txt"; printf 'DO-NOT-OVERWRITE' > "$SENT3"
if run_sync_attacked "$(payload sidX agent-x 'Successfully stopped task: agent-x')" \
        "/proc/1/nonexistent-dir/x" "$SENT3" symlink >/dev/null 2>&1; then
    fail "M7: 攻击 setup 失败却误报成功（应显式失败）"
else
    pass "M7: setup 失败 → 显式失败（不静默继续）"
fi
if [ "$(cat "$SENT3")" = "DO-NOT-OVERWRITE" ]; then
    pass "M8: setup 失败时外部文件零改动"
else
    fail "M8: setup 失败仍改动外部文件"
fi

separator "N. 成功判定反例（否定/含糊/is_error 字符串）"
# 文案 id 与请求 id 一致（Leader 实测载荷），只靠否定语义拒绝
make_tree sidS agent-ghi789
run_sync "$(payload sidS ghi789 'Not successfully stopped task: ghi789')" > /dev/null
[ "$(finished_of "$FIXTURE/sidS/subagents/agent-ghi789.meta.json")" = "absent" ] \
    && pass "N1: 否定文案（id 一致）→ 不写" \
    || fail "N1: 否定文案被当成成功 finished=$(finished_of "$FIXTURE/sidS/subagents/agent-ghi789.meta.json")"

make_tree sidT agent-vague22
run_sync "$(payload sidT agent-vague22 'stopped task agent-vague22')" > /dev/null
[ "$(finished_of "$FIXTURE/sidT/subagents/agent-vague22.meta.json")" = "absent" ] \
    && pass "N2: 含糊文案 → 不写" \
    || fail "N2: 含糊文案被当成成功 finished=$(finished_of "$FIXTURE/sidT/subagents/agent-vague22.meta.json")"

make_tree sidU agent-err333
run_sync "$(payload sidU agent-err333 'Successfully stopped task: agent-err333' '"true"')" > /dev/null
[ "$(finished_of "$FIXTURE/sidU/subagents/agent-err333.meta.json")" = "absent" ] \
    && pass "N3: is_error 字符串 true → 不写" \
    || fail "N3: is_error 字符串未拦截 finished=$(finished_of "$FIXTURE/sidU/subagents/agent-err333.meta.json")"

# 合法成功事件：任务描述后缀里出现 "not successfully stopped" 字样
make_tree sidW agent-desc55
run_sync "$(payload sidW agent-desc55 'Successfully stopped task: agent-desc55 (review not successfully stopped wording)')" > /dev/null
if [ "$(finished_of "$FIXTURE/sidW/subagents/agent-desc55.meta.json")" = "true" ]; then
    pass "N5: 合法成功描述（含否定短语后缀）仍写入 finished=true"
else
    fail "N5: 合法成功描述被误拒 finished=$(finished_of "$FIXTURE/sidW/subagents/agent-desc55.meta.json")"
fi
if jq -e '.description == "probe"' "$FIXTURE/sidW/subagents/agent-desc55.meta.json" >/dev/null 2>&1; then
    pass "N6: 合法成功描述写入后其余字段保留"
else
    fail "N6: 其余字段丢失"
fi

make_tree sidV agent-ok444
run_sync "$(payload sidV agent-ok444 'Successfully stopped task: agent-ok444 (python3 -c pass)')" > /dev/null
[ "$(finished_of "$FIXTURE/sidV/subagents/agent-ok444.meta.json")" = "true" ] \
    && pass "N4: 真实成功文案（含描述后缀）仍命中" \
    || fail "N4: 真实成功文案未命中 finished=$(finished_of "$FIXTURE/sidV/subagents/agent-ok444.meta.json")"

echo ""
echo -e "=== 结果：PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -ne 0 ]; then
    printf '%s\n' "${RESULTS[@]}" | grep '^FAIL|' || true
    exit 1
fi
exit 0
