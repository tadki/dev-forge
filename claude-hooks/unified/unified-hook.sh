#!/bin/bash
# unified-hook.sh - v2 engine entry (SEE-1330 P0)
# CC 全时点注入后由 dispatcher 以 alias=unified-hook 路由到此。
# 契约：stdin 收 CC hook payload JSON；有命中输出 hookSpecificOutput JSON，
# 无命中/任何失败输出为空 → 调用方透传原 stdin。
# 硬约束 fail-open：node 缺失/引擎崩溃/非零退出 → 透传原 stdin + exit 0 +
# hook-fire.log ERROR 审计行（引擎崩溃 = 全钩子失效，绝不可拦截工具调用）。

INPUT=""
while IFS= read -r -t 3 line || [ -n "$line" ]; do
    INPUT="${INPUT}${line}"$'\n'
done
INPUT="${INPUT%$'\n'}"

# 入口层 HOOK_SCOPE_ID 映射（关键实施决策 2）：引擎核心只认 HOOK_SCOPE_ID，
# Multica 宿主把 run id 注入 MULTICA_TASK_ID；显式 HOOK_SCOPE_ID 优先。
# SEE-1330 Owner 指令（2026-09-21）：one_shot 窗口按规则分型——
#   skill 检测类（block 4 + remind 5 + recall + grepai）= per issue per agent：
#     scope id 优先取 MULTICA_ISSUE_ID（issue 维度，同 issue 跨 run 抑制；
#     per agent 隔离由规则 agents 门控承担）；
#   mention-confirm-check = per run：窗口锚定 MULTICA_TASK_ID（每次 run 首检即拦）。
#   区分机制：payload 无规则维度，故按「issue id 可用即 issue 窗口」注入，而
#   mention-confirm-check 单独走 run 窗口（引擎对 mention-confirm-check 规则
#   使用 RUN scope id；实现 = 双变量注入，引擎按规则名分流）。
HOOK_SCOPE_ID="${HOOK_SCOPE_ID:-${MULTICA_ISSUE_ID:-${MULTICA_TASK_ID:-}}}"
HOOK_RUN_SCOPE_ID="${HOOK_RUN_SCOPE_ID:-${MULTICA_TASK_ID:-}}"
export HOOK_SCOPE_ID HOOK_RUN_SCOPE_ID

# HOOK_ISSUE_ID 解析（per issue one_shot 窗口，Owner 指令 2026-09-21）：
# 平台注入 MULTICA_ISSUE_ID 优先；否则经 `multica issue runs <TASK_ID>` 反查一次并缓存（每 run 一次 CLI 成本）；
# 失败/超时 → 留空（scope:issue 规则降级 run 并告警，fail-open 精神）。
HOOK_ISSUE_ID="${HOOK_ISSUE_ID:-${MULTICA_ISSUE_ID:-}}"
if [ -n "$MULTICA_TASK_ID" ] && [ -z "$HOOK_ISSUE_ID" ]; then
  ISSUE_CACHE="/tmp/.hook-issue-id-${MULTICA_TASK_ID}"
  if [ -s "$ISSUE_CACHE" ]; then
    HOOK_ISSUE_ID=$(cat "$ISSUE_CACHE")
  else
    # 反查源 = Multica daemon 日志（`picked task ... task=<run> issue=<issue>`，最新匹配即本 run 绑定）。
    # 用法：grep 该 run 的最后一次 picked 行 → 抽取 issue= 值；无 daemon.log/无匹配 → 留空降级。
    _DL="${MULTICA_DAEMON_LOG:-$HOME/.multica/daemon.log}"
    if [ -r "$_DL" ]; then
      # grep -a = 二进制安全防线（daemon.log 可能含 CC 输出的 NUL/转义字节，裸 grep 会被
      # 判定为 binary file 而静默吞掉匹配行，issue 反查失效）。SEE-1388 SPEC-001。
      HOOK_ISSUE_ID=$(grep -a "picked task" "$_DL" 2>/dev/null | grep -a "task=$MULTICA_TASK_ID " | tail -1 | sed -n 's/.* issue=\([^ ]*\).*/\1/p' | tr -d '"')
      [ "$HOOK_ISSUE_ID" = "''" ] && HOOK_ISSUE_ID=""
    fi
    [ -n "$HOOK_ISSUE_ID" ] && printf '%s' "$HOOK_ISSUE_ID" > "$ISSUE_CACHE" 2>/dev/null
  fi
fi
export HOOK_ISSUE_ID

# firelog 路径：与 hook-wrapper 同一解析顺序，保证入口错误行有落点
# 单源实现（SEE-1388 SPEC-002）：解析逻辑收敛于 scripts/lib/hook-fire-path.lib.sh，
# 本目录（unified/）相对 == ../scripts/lib（repo 布局与全局部署位一致）。
_lib_dir="$(cd "$(dirname "$0")" && pwd)"
for _cand in "$_lib_dir/../scripts/lib/hook-fire-path.lib.sh"; do
  [ -f "$_cand" ] && . "$_cand" && break
done
LOG_FILE=$(resolve_hook_fire_log_path 2>/dev/null) || LOG_FILE="$HOME/.claude/hook-fire.log"
maybe_rotate_hook_fire_log "$LOG_FILE" 2>/dev/null || true

ENGINE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/engine.js"
# fail-open 注入测试通道：替换引擎路径
[ -n "$UNIFIED_ENGINE_JS" ] && ENGINE="$UNIFIED_ENGINE_JS"

if [ ! -f "$ENGINE" ]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [unified-hook] ERROR engine-missing path=$ENGINE" >> "$LOG_FILE" 2>/dev/null || true
  printf '%s' "$INPUT"
  exit 0
fi

if ! command -v node >/dev/null 2>&1; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [unified-hook] ERROR node-missing" >> "$LOG_FILE" 2>/dev/null || true
  printf '%s' "$INPUT"
  exit 0
fi

ERR_FILE=$(mktemp /tmp/unified-hook-err.XXXXXX)
OUT=$(printf '%s' "$INPUT" | PROJECT_ROOT="${PROJECT_ROOT:-}" HOOK_RUN_SCOPE_ID="$HOOK_RUN_SCOPE_ID" node "$ENGINE" 2>"$ERR_FILE")
EXIT_CODE=$?

# exit-2 通道直通（S6 run_script fail-close 桥接）：CC 将 exit 2 视为阻塞错误并取 stderr
if [ "$EXIT_CODE" -eq 2 ]; then
  cat "$ERR_FILE" >&2 2>/dev/null || true
  rm -f "$ERR_FILE"
  exit 2
fi
rm -f "$ERR_FILE"

if [ "$EXIT_CODE" -ne 0 ]; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [unified-hook] ERROR engine-exit code=$EXIT_CODE" >> "$LOG_FILE" 2>/dev/null || true
  printf '%s' "$INPUT"
  exit 0
fi

if [ -n "$OUT" ]; then
  printf '%s' "$OUT"
else
  printf '%s' "$INPUT"
fi
exit 0
