#!/usr/bin/env bash
# taskstop-sidecar-sync.sh — TaskStop 成功后同步 sub-agent sidecar meta
# （SEE-1624 §SPEC-018）。
#
# 根因（Atlas 2026-11-23 定位）：CC TaskStop 成功停止后任务注册表已无活动
# agent，但 sidecar meta 未回写 finished:true → stop-guard-subagents.sh 把
# 已停止 agent 当作"未结束"，每次 Stop 误报 exit 2（假阳性，宿主随后关闭
# 控制通道）。本脚本让停止事件与 meta 生命周期一致。
#
# 纪律（不放宽可写面；Final Review HIGH-1/HIGH-2/MEDIUM-3/LOW-5 后收紧）：
#   - 只有**明确成功**的停止才写：tool_response 非错误（布尔 true 或字符串
#     "true"）+ **行首锚定**的 "Successfully stopped task: <id>" 文案 +
#     文案中的 id 与请求 id 一致；**句首**否定（"Not successfully stopped
#     task:…"）、失败、not found、含糊或无 id 文案一律不写（不可验证=不写）；
#     否定守卫只看行首——任务描述后缀里出现同名字样（"…(review not
#     successfully stopped wording)"）不得否决明确的成功事件。
#   - task id 形态受限（无 "/"、".."、空）：防路径穿越写；CC 对同一
#     sub-agent 既接受 "agent-<hex>" 也接受裸 "<hex>"，统一归一后按真实
#     sidecar 命名 agent-<key>.meta.json 解析（初版按 "$TASK_ID.meta.json"
#     拼，裸 hex 事件下静默找不到目标文件 → finished 从未写入）。
#   - 目标 meta 必须已存在（无 sidecar 的后台任务不生成文件）；会话目录、
#     subagents 目录、meta 文件任一为 symlink 即拒绝（目录逃逸防线），
#     并以**独立物理判定**复核：meta 的物理父目录须落在物理会话目录内。
#   - 幂等：已是 finished:true 不重复写；写用**不可预测**临时文件
#     （mktemp 随机名 + O_EXCL）经 rename 原子替换——可预测临时名会被预置
#     symlink/hardlink 劫持而覆盖会话外文件。
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
# 归一化：CC 对同一 sub-agent 既接受 "agent-<hex>" 也接受裸 "<hex>"，
# 而 sidecar 文件名恒为 "agent-<hex>.meta.json" —— 统一取 key（去一个
# "agent-" 前缀），目标文件按真实命名解析（不产生双前缀文件）。
AGENT_KEY="${TASK_ID#agent-}"
if ! printf '%s' "$AGENT_KEY" | grep -qE '^[A-Za-z0-9][A-Za-z0-9_.-]*$'; then
  exit 0
fi

# --- 成功判定 ---------------------------------------------------------------
IS_ERROR="$(printf '%s' "$PAYLOAD" | jq -r '
  (.tool_response // {}) as $r
  | if ($r | type) == "object"
    then (if ($r.is_error == true) or ($r.is_error == "true")
          then "true" else "false" end)
    else "false" end' 2>/dev/null || echo false)"
[ "$IS_ERROR" = "true" ] && exit 0

MESSAGE="$(printf '%s' "$PAYLOAD" | jq -r '
  def text_of:
    if type == "string" then .
    elif type == "object" then (.message // .stdout // "")
    elif type == "array" then ([ .[]? | select(.type == "text") | .text ] | join(""))
    else "" end;
  (.tool_response // {}) | text_of' 2>/dev/null || true)"
[ -n "$MESSAGE" ] || exit 0
# 否定句守卫只作用于**行首**（"Not successfully stopped task: <id>" 之类）——
# 任务描述后缀里出现同名字样（"…(review not successfully stopped wording)"）
# 不得否决明确的成功事件（Final Review R2 MEDIUM-1：全局扫描会误伤合法
# 成功描述，导致已停止 agent 再次触发 stop-guard 假阳性）。
if printf '%s' "$MESSAGE" \
     | grep -qiE '^[[:space:]]*not[[:space:]]+successfully[[:space:]]+stopped'; then
  exit 0
fi
# 明确成功语义：**行首**锚定的 "Successfully stopped task: <id>"（CC 真实
# 文案形态；后缀为任务描述）。含糊/失败/无 id 文案一律不写（不可验证=不写）。
STOPPED_ID="$(printf '%s' "$MESSAGE" \
  | sed -n 's/^[[:space:]]*[Ss]uccessfully stopped task: *\([A-Za-z0-9_.-]\{1,\}\).*/\1/p' \
  | head -1)"
[ -n "$STOPPED_ID" ] || exit 0
# 文案中的 task id 必须与请求一致（不一致=不可验证=不写）
[ "${STOPPED_ID#agent-}" = "$AGENT_KEY" ] || exit 0

# --- 目标 meta 解析（会话 subagents 目录内） -------------------------------
TRANSCRIPT_PATH="$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
SESSION_ID="$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null || true)"
[ -n "$TRANSCRIPT_PATH" ] || exit 0
[ -n "$SESSION_ID" ] || exit 0
case "$SESSION_ID" in
  */*|*..*) exit 0 ;;
esac

TRANSCRIPT_DIR="$(dirname "$TRANSCRIPT_PATH")"
SESSION_DIR="$TRANSCRIPT_DIR/$SESSION_ID"
# 会话目录自身不得是 symlink（否则其下 subagents 可整体指向外部）
[ -d "$SESSION_DIR" ] || exit 0
[ ! -L "$SESSION_DIR" ] || exit 0

META_DIR="$SESSION_DIR/subagents"
[ -d "$META_DIR" ] || exit 0
# subagents 目录不得是 symlink（目录逃逸防线：物理判定而非构造等式）
[ ! -L "$META_DIR" ] || exit 0

# 真实 sidecar 命名恒为 agent-<key>.meta.json（实测 411/411）
META="$META_DIR/agent-$AGENT_KEY.meta.json"
[ -f "$META" ] || exit 0
# meta 自身不得是 symlink（读跟随会越出可写面）
[ ! -L "$META" ] || exit 0

# 独立物理 containment：meta 的物理父目录必须落在**物理会话目录**之内
# （此前用 dirname(META) 与 META_DIR 比较，两者按构造恒等 → 复核形同虚设）。
SESSION_DIR_REAL="$(cd "$SESSION_DIR" 2>/dev/null && pwd -P)" || exit 0
META_DIR_REAL="$(cd "$META_DIR" 2>/dev/null && pwd -P)" || exit 0
[ "$(dirname "$META_DIR_REAL")" = "$SESSION_DIR_REAL" ] || exit 0
META_PARENT_REAL="$(cd "$(dirname "$META")" 2>/dev/null && pwd -P)" || exit 0
[ "$META_PARENT_REAL" = "$META_DIR_REAL" ] || exit 0

# 幂等：已 finished=true 不重复写
CURRENT="$(jq -r 'if (.finished == true) then "true" else "false" end' "$META" 2>/dev/null || echo false)"
[ "$CURRENT" = "true" ] && exit 0

# --- 写 finished:true（原子，保留其余字段） --------------------------------
# 临时文件名必须**不可预测**（mktemp 随机名 + O_EXCL）：可预测名会被预置
# symlink/hardlink 劫持，导致会话外文件被覆盖（Final Review HIGH-1）。
TMP="$(mktemp "$META_DIR/.gqt-tmp.XXXXXX" 2>/dev/null)" || exit 0
if jq '.finished = true' "$META" > "$TMP" 2>/dev/null; then
  chmod 600 "$TMP" 2>/dev/null || true
  # rename 语义：替换目标路径本身（不跟随目标 symlink），会话外文件不受影响
  mv -f "$TMP" "$META" 2>/dev/null || rm -f "$TMP"
else
  rm -f "$TMP"
fi
exit 0
