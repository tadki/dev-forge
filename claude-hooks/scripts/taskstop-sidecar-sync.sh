#!/usr/bin/env bash
# taskstop-sidecar-sync.sh — TaskStop 成功后同步 sub-agent sidecar meta
# （SEE-1624 §SPEC-018）。
#
# 根因（Atlas 2026-11-23 定位）：CC TaskStop 成功停止后任务注册表已无活动
# agent，但 sidecar meta 未回写 finished:true → stop-guard-subagents.sh 把
# 已停止 agent 当作"未结束"，每次 Stop 误报 exit 2（假阳性，宿主随后关闭
# 控制通道）。本脚本让停止事件与 meta 生命周期一致。
#
# 纪律（不放宽可写面）：
#   - 只有**明确成功**的停止才写：tool_response 非错误 + "Successfully
#     stopped task" 文案 + 文案中的 task id 与请求 id 一致；失败、not
#     found、文案含糊一律不写（不可验证=不写，保守取向）。
#   - task id 形态受限（无 "/"、".."、空）：防路径穿越写。
#   - 目标 meta 必须已存在（无 sidecar 的后台任务不生成文件），且解析后
#     父目录必须仍是该会话的 subagents 目录（symlink 逃逸亦拒）。
#   - 幂等：已是 finished:true 不重复写；写用临时文件 + 原子 mv。
#   - 全程 fail-open：任何异常路径 exit 0（本钩子不得阻断工具调用）。
#
# stdin: CC PostToolUse 载荷（tool_name / tool_input.task_id /
#        tool_response / transcript_path / session_id）。
set -u

PAYLOAD="$(cat 2>/dev/null || true)"
[ -z "$PAYLOAD" ] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

TOOL_NAME="$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[ "$TOOL_NAME" = "TaskStop" ] || exit 0

TASK_ID="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.task_id // empty' 2>/dev/null || true)"
[ -n "$TASK_ID" ] || exit 0
# id 形态闸：禁路径分隔符与 ..（穿越写防线）
case "$TASK_ID" in
  */*|*..*) exit 0 ;;
esac
case "$TASK_ID" in
  [A-Za-z0-9]*) ;;
  *) exit 0 ;;
esac
# 剩余字符仅允许安全集（字母数字与 . _ -）
if ! printf '%s' "$TASK_ID" | grep -qE '^[A-Za-z0-9][A-Za-z0-9_.-]*$'; then
  exit 0
fi

# --- 成功判定 ---------------------------------------------------------------
IS_ERROR="$(printf '%s' "$PAYLOAD" | jq -r \
  'if .tool_response.is_error == true then "true" else "false" end' 2>/dev/null || echo false)"
[ "$IS_ERROR" = "true" ] && exit 0

MESSAGE="$(printf '%s' "$PAYLOAD" | jq -r '
  def text_of:
    if type == "string" then .
    elif type == "object" then (.message // .stdout // "")
    elif type == "array" then ([ .[]? | select(.type == "text") | .text ] | join(""))
    else "" end;
  (.tool_response // {}) | text_of' 2>/dev/null || true)"
[ -n "$MESSAGE" ] || exit 0
printf '%s' "$MESSAGE" | grep -qi "successfully stopped" || exit 0
# 文案中的 task id 必须与请求一致（不一致=不可验证=不写）
STOPPED_ID="$(printf '%s' "$MESSAGE" | sed -n 's/.*[Ss]uccessfully stopped task: *\([A-Za-z0-9_.-]*\).*/\1/p' | head -1)"
if [ -n "$STOPPED_ID" ]; then
  [ "$STOPPED_ID" = "$TASK_ID" ] || exit 0
else
  printf '%s' "$MESSAGE" | grep -qF "$TASK_ID" || exit 0
fi

# --- 目标 meta 解析（会话 subagents 目录内） -------------------------------
TRANSCRIPT_PATH="$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
SESSION_ID="$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null || true)"
[ -n "$TRANSCRIPT_PATH" ] || exit 0
[ -n "$SESSION_ID" ] || exit 0
case "$SESSION_ID" in
  */*|*..*) exit 0 ;;
esac

META_DIR="$(dirname "$TRANSCRIPT_PATH")/$SESSION_ID/subagents"
[ -d "$META_DIR" ] || exit 0

META="$META_DIR/$TASK_ID.meta.json"
[ -f "$META" ] || exit 0

# containment 复核：解析后父目录必须仍是该 subagents 目录（symlink 逃逸拒）
META_DIR_REAL="$(cd "$META_DIR" 2>/dev/null && pwd -P)" || exit 0
META_PARENT_REAL="$(cd "$(dirname "$META")" 2>/dev/null && pwd -P)" || exit 0
[ "$META_DIR_REAL" = "$META_PARENT_REAL" ] || exit 0

# 幂等：已 finished=true 不重复写
CURRENT="$(jq -r 'if (.finished == true) then "true" else "false" end' "$META" 2>/dev/null || echo false)"
[ "$CURRENT" = "true" ] && exit 0

# --- 写 finished:true（原子，保留其余字段） --------------------------------
TMP="$META.gqt-tmp.$$"
if jq '.finished = true' "$META" > "$TMP" 2>/dev/null; then
  mv -f "$TMP" "$META" 2>/dev/null || rm -f "$TMP"
else
  rm -f "$TMP"
fi
exit 0
