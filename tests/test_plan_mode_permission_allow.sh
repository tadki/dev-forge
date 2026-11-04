#!/bin/bash
# plan-mode-permission-allow: PermissionRequest 时点 plan 模式自动放行（Mac 原 jq
# 一行式钩子的 v2 引擎迁移）。覆盖：validator 新时点接纳 / payload 字符串等值 /
# 引擎端到端（plan→allow JSON，非 plan→透传）/ 挂载脚本直连行为。
# Run:    bash tests/test_plan_mode_permission_allow.sh
set -uo pipefail

# SEE-1516 tidy（方案外修复·显式标注）：隔离宿主 agent/会话环境变量，与
# test_push_guard_refspec_see1516.sh 同款处置（test_auto_pr_on_stop_boundary_cases.sh
# 既有惯例）。宿主运行时的 MULTICA_AGENT_NAME（如 Refacty/Atlas）泄漏会命中
# rules-v2.json 的 agents 门控规则（recall-reminder 等），令「无命中 → 透传」
# 用例得到额外 additionalContext 而假红。只清环境、不动判据。
unset MULTICA_TASK_ID MULTICA_AGENT_ID MULTICA_AGENT_NAME \
      MULTICA_TOKEN MULTICA_SERVER_URL MULTICA_WORKSPACE_ID

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0; RESULTS=()

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); RESULTS+=("PASS|$1"); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); RESULTS+=("FAIL|$1"); }
separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTRY="$REPO_ROOT/claude-hooks/unified/unified-hook.sh"
VALIDATOR="$REPO_ROOT/claude-hooks/validate-rules.js"
WHEN_OPS="$REPO_ROOT/claude-hooks/unified/when-ops.js"
RULE_FILE="$REPO_ROOT/claude-hooks/unified/rules.d/plan-mode-auto-allow.json"
ALLOW_SCRIPT="$REPO_ROOT/claude-hooks/scripts/plan-mode-allow.sh"
REGISTRATION="$REPO_ROOT/bootstrap/hooks-registration.json"
FIXTURE="$(mktemp -d /tmp/plan-allow-test.XXXXXX)"
RULES="$FIXTURE/rules-v2.json"
FIRELOG="$FIXTURE/hook-fire.log"
STATE="$FIXTURE/state"
trap 'rm -rf "$FIXTURE"' EXIT

ALLOW_JSON='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'

run_entry() {
    local INPUT="$1"
    : > "$FIRELOG"
    printf '%s' "$INPUT" > "$FIXTURE/stdin.json"
    HOOK_STDOUT=$(UNIFIED_RULES_FILE="$RULES" \
        HOOK_FIRE_LOG="$FIRELOG" \
        HOOK_STATE_DIR="$STATE" \
        PROJECT_ROOT="$REPO_ROOT" \
        bash "$ENTRY" < "$FIXTURE/stdin.json" 2>/dev/null)
    HOOK_EXIT=$?
}

# ---- 1. validator：新时点 + 规则文件接纳 ----
separator "validator 接纳"
if node -e "const v=require('$VALIDATOR'); process.exit(v.HOOK_POINTS.includes('PermissionRequest') ? 0 : 1)"; then
    pass "HOOK_POINTS 含 PermissionRequest"
else
    fail "HOOK_POINTS 含 PermissionRequest"
fi

echo '{"rules":[]}' > "$RULES"
if node "$VALIDATOR" "$RULE_FILE" >/dev/null 2>&1; then
    pass "rules.d/plan-mode-auto-allow.json 全规则 VALID"
else
    fail "rules.d/plan-mode-auto-allow.json 全规则 VALID"
fi

if jq -e '.hook_points | index("PermissionRequest")' "$REGISTRATION" >/dev/null 2>&1; then
    pass "hooks-registration.json hook_points 含 PermissionRequest"
else
    fail "hooks-registration.json hook_points 含 PermissionRequest"
fi
jq -e '.runtime_artifacts | index("scripts/plan-mode-allow.sh")' "$REGISTRATION" >/dev/null 2>&1 \
    && pass "runtime_artifacts 登记 plan-mode-allow.sh" \
    || fail "runtime_artifacts 登记 plan-mode-allow.sh"
jq -e '.runtime_artifacts | index("unified/rules.d/plan-mode-auto-allow.json")' "$REGISTRATION" >/dev/null 2>&1 \
    && pass "runtime_artifacts 登记 plan-mode-auto-allow.json" \
    || fail "runtime_artifacts 登记 plan-mode-auto-allow.json"

# ---- 2. payload 字符串等值（when-ops 直评） ----
separator "payload 字符串等值"
eval_payload() {
    node -e "
const { createEvaluator } = require('$WHEN_OPS');
const payload = JSON.parse(process.argv[1]);
const ev = createEvaluator(payload, {});
const hit = ev.evaluate({ op: 'payload', path: 'permission_mode', equals: 'plan' });
process.stdout.write(hit ? 'HIT' : 'MISS');
" "$1"
}
[ "$(eval_payload '{"hook_event_name":"PermissionRequest","permission_mode":"plan"}')" = "HIT" ] \
    && pass "permission_mode=plan 命中" || fail "permission_mode=plan 命中"
[ "$(eval_payload '{"hook_event_name":"PermissionRequest","permission_mode":"default"}')" = "MISS" ] \
    && pass "permission_mode=default 不命中" || fail "permission_mode=default 不命中"
[ "$(eval_payload '{"hook_event_name":"PermissionRequest","permission_mode":"acceptEdits"}')" = "MISS" ] \
    && pass "permission_mode=acceptEdits 不命中" || fail "permission_mode=acceptEdits 不命中"
[ "$(eval_payload '{"hook_event_name":"PermissionRequest"}')" = "MISS" ] \
    && pass "permission_mode 缺失不命中" || fail "permission_mode 缺失不命中"

# ---- 3. 挂载脚本直连（与 Mac 原始 jq 行为对齐） ----
separator "挂载脚本直连"
SCRIPT_OUT=$(printf '%s' '{"permission_mode":"plan"}' | bash "$ALLOW_SCRIPT" 2>/dev/null)
[ "$SCRIPT_OUT" = "$ALLOW_JSON" ] && pass "plan → allow JSON" || fail "plan → allow JSON（got: $SCRIPT_OUT）"
SCRIPT_OUT=$(printf '%s' '{"permission_mode":"default"}' | bash "$ALLOW_SCRIPT" 2>/dev/null)
[ -z "$SCRIPT_OUT" ] && pass "非 plan → 空输出" || fail "非 plan → 空输出（got: $SCRIPT_OUT）"

# ---- 4. 引擎端到端（真实部署位配置：repo 检出即全局部署位，rules.d 与
#         ${HOOKS_DIR} 解析均按生产路径生效） ----
separator "引擎端到端"
RULES="$REPO_ROOT/claude-hooks/unified/rules-v2.json"
run_entry '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"},"permission_mode":"plan"}'
if [ "$HOOK_EXIT" -eq 0 ] && [ "$HOOK_STDOUT" = "$ALLOW_JSON" ]; then
    pass "PermissionRequest × plan → 引擎输出 allow 协议 JSON"
else
    fail "PermissionRequest × plan → 引擎输出 allow 协议 JSON（exit=$HOOK_EXIT got: $HOOK_STDOUT）"
fi

run_entry '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"},"permission_mode":"default"}'
PASS_THROUGH='{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"},"permission_mode":"default"}'
if [ "$HOOK_EXIT" -eq 0 ] && [ "$HOOK_STDOUT" = "$PASS_THROUGH" ]; then
    pass "PermissionRequest × default → 规则不命中，入口透传原 stdin（原审批流保持）"
else
    fail "PermissionRequest × default → 规则不命中，入口透传原 stdin（exit=$HOOK_EXIT got: $HOOK_STDOUT）"
fi

# 非 plan 模式下 PreToolUse 既有规则不受新时点影响（无命中透传）
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"},"permission_mode":"default"}'
PASS_THROUGH='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"},"permission_mode":"default"}'
if [ "$HOOK_EXIT" -eq 0 ] && [ "$HOOK_STDOUT" = "$PASS_THROUGH" ]; then
    pass "PreToolUse 无命中 → 透传不受影响"
else
    fail "PreToolUse 无命中 → 透传不受影响（got: $HOOK_STDOUT）"
fi

# ---- 汇总 ----
echo ""
echo "========================================="
echo "PASS: $PASS  FAIL: $FAIL"
echo "========================================="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
