#!/usr/bin/env bash
# stop-guard-subagents.sh — Stop 时点防线：存在未结束 sub-agent 时阻止结束回合（SEE-1559）
#
# 根因（SEE-1559 调查定案，2026-11-10）：Multica daemon 在 result 事件即关闭 stdin
# （claude.go closeAfterControls），而 supplement 会话经 control 协议注册的
# PreToolUse/PostToolUse 等 hook 会被 sub-agent 继承——stdin 关闭后这些 hook
# callback 永无应答，sub-agent 的全部后续工具调用一律以
# "The user doesn't want to take this action right now" 被拒。
# 本防线在 agent 可控面兜底：主会话想结束回合时，若仍有 sub-agent 未结束
# （subagents/*.meta.json finished != true），以 exit 2 阻止，直到其结束或被
# 显式停止。fail-open：载荷缺失/目录不存在/jq 失败一律放行（exit 0）。
#
# stdin: CC Stop 载荷（session_id / transcript_path / stop_hook_active）。
# 输出：无未结束 sub-agent → 无输出 exit 0（放行）；
#       有未结束 sub-agent → stderr 给出处置指引，exit 2（引擎 exitChannel 转发，CC 阻止 Stop）；
#       stop_hook_active=true（上次 Stop 已被本规则阻止过）→ 放行，防死循环。
set -u
PAYLOAD="$(cat 2>/dev/null || true)"
[ -z "$PAYLOAD" ] && exit 0

STOP_HOOK_ACTIVE="$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null)"
[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

TRANSCRIPT_PATH="$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null)"
SESSION_ID="$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null)"
[ -z "$TRANSCRIPT_PATH" ] && exit 0
# session_id 缺失时从 transcript 文件名兜底
if [ -z "$SESSION_ID" ]; then
  SESSION_ID="$(basename "$TRANSCRIPT_PATH")"
  SESSION_ID="${SESSION_ID%.jsonl}"
fi
[ -z "$SESSION_ID" ] && exit 0

META_DIR="$(dirname "$TRANSCRIPT_PATH")/$SESSION_ID/subagents"
[ -d "$META_DIR" ] || exit 0

LIVE=""
for meta in "$META_DIR"/*.meta.json; do
  [ -f "$meta" ] || continue
  FINISHED="$(jq -r '.finished // false' "$meta" 2>/dev/null || echo false)"
  [ "$FINISHED" = "true" ] || LIVE="$LIVE $(basename "$meta" .meta.json)"
done
[ -z "$LIVE" ] && exit 0

cat >&2 <<EOF
[stop-guard-subagents] 检测到尚未结束的后台 sub-agent：$LIVE
当前回合结束后，宿主会在 result 时关闭控制通道，这些 sub-agent 的后续工具调用会被全部拒绝（SEE-1559 根因：supplement PreToolUse hook callback 无应答 → 逐调用拒绝）。
请勿结束回合：等待 sub-agent 完成（Monitor / TaskGet 轮询其状态）并在本回合内收集结果；若 sub-agent 已死或卡死，先用 TaskStop 显式终止，再结束回合。
EOF
exit 2
