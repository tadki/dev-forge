#!/usr/bin/env bash
# stop-guard-background-tasks.sh — Stop 时点防线：托管回合还有未结束的非 agent
# 后台任务时阻止结束回合（SEE-1636 本地止血；根因链 = SEE-1635：daemon 在 result
# 时关闭控制通道，遗留回调 hook 无应答，之后任何回合的工具调用被冒充用户的
# 「The user doesn't want to take this action right now」取消）。
#
# 判定语义（以 SEE-1636 issue description「本轮核实的事实」为准）：
#   - 只对 Multica 托管运行生效（MULTICA_TASK_ID 非空）；交互式会话无本缺陷，放行。
#   - Stop 载荷 background_tasks 只含在飞任务；status 不在终态词表
#     （completed/failed/killed/stopped/cancelled/exited/done/timed_out）即算未结束，
#     缺失或未知状态按活任务计（CC 2.1.329 该列表实际只含 running/pending，
#     原型 ==running 会漏 pending）。
#   - type 含 agent 的条目（subagent 等）不归本守卫，归 stop-guard-live-subagents。
#   - stop_hook_active=true 放行：每回合只拦一次（CC 2.1.329 对连续 Stop 拦截另有
#     计数上限 CLAUDE_CODE_STOP_HOOK_BLOCK_CAP，放行语义由两守卫脚本自行承担）。
#   - 与 stop-guard-live-subagents 并存：引擎 exitChannel 首条胜出，且本守卫规则
#     文件名排序在前——本守卫命中时若 sub-agent 守卫同样命中，调用其脚本原文并
#     将其指引并入本守卫 stderr（文案单源零漂移，两段指引都送达模型）。
#
# stdin: CC Stop 载荷（background_tasks / stop_hook_active）。
# 输出：无可拦任务或任何载荷级失效 → 无输出 exit 0（fail-open）；
#       有未结束非 agent 后台任务 → stderr 处置指引（可并附 sub-agent 段），exit 2
#       （引擎 exitChannel 直通，CC 阻止 Stop）。
set -u
PAYLOAD="$(cat 2>/dev/null || true)"
[ -z "$PAYLOAD" ] && exit 0
[ -z "${MULTICA_TASK_ID:-}" ] && exit 0
LIVE="$(printf '%s' "$PAYLOAD" | jq -r '
  [(.background_tasks | select(type == "array")) // []
   | .[]
   | select((((.type // "") | tostring) | test("agent")) | not)
   | select((((.status // "") | tostring) | test("^(completed|failed|killed|stopped|cancelled|exited|done|timed_out)$")) | not)
   | "\(.id // "?") [\(.type // "?")] \(.description // .command // "")"] | join("\n  ")' 2>/dev/null)"
[ -z "$LIVE" ] && exit 0
STOP_HOOK_ACTIVE="$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null)"
[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

# 并存面：sub-agent 守卫同命中（exit 2）时其 stderr 会被引擎丢弃（exitChannel
# 首条胜出）——此处捕获其指引原文并入本守卫输出。
SUB_ERR=""
SUB_RC=0
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
SIBLING="$SELF_DIR/stop-guard-subagents.sh"
if [ -f "$SIBLING" ]; then
  SUB_ERR="$(printf '%s' "$PAYLOAD" | bash "$SIBLING" 2>&1 1>/dev/null)" || SUB_RC=$?
fi

{
cat <<MSG
[stop-guard-background-tasks] 本回合还有后台任务在运行：
  $LIVE
回合一旦结束，宿主会关闭本会话的控制通道，之后任何回合（包括后台任务完成通知触发的回合）里的每个工具调用都会被取消，并返回一句冒充用户的「The user doesn't want to take this action right now」（SEE-1635）。
请在当前回合内等待这些任务：前台阻塞等待（超时上限 10 分钟，必要时分段），然后在本回合内读取它们的输出、把该做的收尾做完，再结束回合。
任务卡死：先 TaskStop 停掉再结束。
例外：用户明确要求在回合结束后继续常驻的服务不属于此列——写清常驻交接说明（地址、日志、停止方式）后结束回合即可。
MSG
if [ "$SUB_RC" -eq 2 ] && [ -n "$SUB_ERR" ]; then
  printf '\n%s\n' "$SUB_ERR"
fi
} >&2
exit 2
