#!/bin/bash
# CC Hooks Dispatcher - finds and runs project-level hooks
# Called with alias as argument (e.g. push-guard, auto-pr, repo-checkout)
# Maps alias directly to the final business script

ALIAS="${1:-unknown}"

# Buffer stdin so we can pass it through if no hook is found
# timeout: prevents blocking when CC launches bash with --login -i
# (interactive bash doesn't propagate pipe EOF properly to cat)
INPUT=""
while IFS= read -r -t 3 line || [ -n "$line" ]; do
    INPUT="${INPUT}${line}"$'\n'
done
# Trim trailing newline added by the loop
INPUT="${INPUT%$'\n'}"

# Environment-aware project directory fallback (SEE-1381 §SPEC-017)：
# 不再硬编码 WSL 挂载点——显式 KOL_REPO_ROOT 环境变量优先（与 .dev/systemd/
# kingoflikes-start-all.service 的哨兵约定同源），WSL 场景仅由环境探测推导
# （非 WSL 环境 /mnt/* 不存在即自然为空，alias 路由不再透传前断链）。
ADDITIONAL_DIRS=""
if [ -n "$KOL_REPO_ROOT" ] && [ -d "$KOL_REPO_ROOT/.claude/hooks" ]; then
  ADDITIONAL_DIRS="$KOL_REPO_ROOT"
else
  # WSL 环境探测：仅 WSL 下才扫描挂载点（/proc/version 含 microsoft 标识）
  if grep -qi microsoft /proc/version 2>/dev/null; then
    WSL_CANDIDATES=(
      "/mnt/d/GodotProjects/king-of-likes"
      "/mnt/c/Users/$USER/GodotProjects/king-of-likes"
    )
    # Also scan /mnt/c/Users/*/GodotProjects/king-of-likes for other users
    for user_dir in /mnt/c/Users/*/GodotProjects/king-of-likes; do
      if [ -d "$user_dir" ]; then
        WSL_CANDIDATES+=("$user_dir")
      fi
    done
    # Pick the first existing candidate
    for candidate in "${WSL_CANDIDATES[@]}"; do
      if [ -d "$candidate" ]; then
        ADDITIONAL_DIRS="$candidate"
        break
      fi
    done
  fi
fi

# Find project root containing .claude/hooks/
# Order: CC official > PWD > PWD subdirs (Multica workdir) > WSL fallback
PROJECT_ROOT=""
for dir in "$CLAUDE_PROJECT_DIR" "$PWD"; do
  [ -n "$dir" ] && [ -d "$dir/.claude/hooks" ] && { PROJECT_ROOT="$dir"; break; }
done

# Search one level deep (Multica workdir pattern: repo checked out inside workdir)
if [ -z "$PROJECT_ROOT" ]; then
  for subdir in "$PWD"/*/; do
    [ -d "$subdir.claude/hooks" ] && { PROJECT_ROOT="${subdir%/}"; break; }
  done
fi

# WSL fallback (last resort)
if [ -z "$PROJECT_ROOT" ]; then
  for dir in $ADDITIONAL_DIRS; do
    [ -n "$dir" ] && [ -d "$dir/.claude/hooks" ] && { PROJECT_ROOT="$dir"; break; }
  done
fi

# Dynamic firelog path: repo-level when available, global fallback（单源实现 SEE-1388 SPEC-002）
# FIRELOG_NO_PWD_SCAN=1 保留 dispatcher 既有形态：仅用自身算出的 PROJECT_ROOT，无则全局兜底。
_lib_dir="$(cd "$(dirname "$0")" && pwd)"
for _cand in "$_lib_dir/../scripts/lib/hook-fire-path.lib.sh" \
  "$_lib_dir/../../.claude/hooks/scripts/lib/hook-fire-path.lib.sh" \
  "$HOME/.claude/hooks/scripts/lib/hook-fire-path.lib.sh"; do
  [ -f "$_cand" ] && . "$_cand" && break
done
FIRELOG_NO_PWD_SCAN=1
PROJECT_ROOT_CANON="$PROJECT_ROOT"
LOG_FILE=$(resolve_hook_fire_log_path 2>/dev/null) || LOG_FILE="$HOME/.claude/hook-fire.log"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [dispatcher.sh] alias=$ALIAS PWD=$PWD HOME=$HOME PROJECT_ROOT=${PROJECT_ROOT:-<none>}" >> "$LOG_FILE" 2>/dev/null || true

# No hooks directory -> pass stdin through unchanged
if [ -z "$PROJECT_ROOT" ]; then
  printf '%s' "$INPUT"
  exit 0
fi

# Map alias to final business script.
# Convention-based routing (SEE-1185 F4): alias maps to .claude/hooks/<alias>.sh;
# only aliases that break the convention are listed explicitly.
# Adding a new hook = drop script at .claude/hooks/<alias>.sh + register in settings.json.
case "$ALIAS" in
  unified-hook)
    # SEE-1330 P1 cutover 修正：全局部署位优先 —— v2 配置必须单一真源。
    # 事故根因（2026-09-20）：PROJECT_ROOT 优先使各在跑会话按各自 checkout 的
    # 异构 v2 配置求值（规则集互不一致 + 与 v1 双轨），违背 P0 空规则灰度前提。
    # P4 收敛：alias 路由仅剩 unified-hook（v1 时点已全部由 v2 引擎接管，
    # v1 业务脚本由挂载层 run_script 调用，不再经 dispatcher 路由）。
    SCRIPT="$HOME/.claude/hooks/unified/unified-hook.sh"
    [ -f "$SCRIPT" ] || SCRIPT="$PROJECT_ROOT/.claude/hooks/unified/unified-hook.sh"
    ;;
  *)
    # P4 收敛：v1 alias 不再路由（settings 中 v1 wrapper 注册行已全部移除）。
    # 未知 alias 静默透传（fail-open，与 v1 未匹配行为一致）。
    SCRIPT=""
    ;;
esac
if [ -z "$SCRIPT" ]; then
  printf '%s' "$INPUT"
  exit 0
fi

# Script missing -> pass stdin through unchanged
if [ ! -f "$SCRIPT" ]; then
  printf '%s' "$INPUT"
  exit 0
fi

# Run the project-level hook, piping buffered stdin to it
# Capture hook stdout so we can decide whether to pass hook output or stdin
HOOK_OUTPUT=$(printf '%s' "$INPUT" | PROJECT_ROOT="$PROJECT_ROOT" "$SCRIPT")
EXIT_CODE=$?
# SEE-1185 F5: record the hook result so the daily check can distinguish
# "no failures" from "failures invisible" (firelog previously had no outcome field)
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [result] alias=$ALIAS exit=$EXIT_CODE script=$(basename "$SCRIPT")" >> "$LOG_FILE" 2>/dev/null || true
if [ "$EXIT_CODE" -ne 0 ]; then
  printf '%s' "$INPUT"
  exit "$EXIT_CODE"
fi
# On exit 0: if hook produced hookSpecificOutput JSON, pass it through;
# otherwise pass the original stdin (passthrough)
if echo "$HOOK_OUTPUT" | grep -q '"hookSpecificOutput"'; then
  printf '%s' "$HOOK_OUTPUT"
else
  printf '%s' "$INPUT"
fi
exit 0
