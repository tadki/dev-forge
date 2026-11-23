#!/bin/bash
# hook-wrapper.sh - entry point for CC hooks
# Called by CC with hook type as $1 and alias as $2
# Logs to hook-fire.log then delegates to dispatcher.sh

HOOK_TYPE="${1:-unknown}"
ALIAS="${2:-unknown}"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)"

# Dynamic firelog path: 单源实现（SEE-1388 SPEC-002），repo-level .claude/ when available, global fallback
_lib_dir="$(cd "$(dirname "$0")" && pwd)"
for _cand in "$_lib_dir/scripts/lib/hook-fire-path.lib.sh"; do
  [ -f "$_cand" ] && . "$_cand" && break
done
LOG_FILE=$(resolve_hook_fire_log_path 2>/dev/null) || LOG_FILE="$HOME/.claude/hook-fire.log"
maybe_rotate_hook_fire_log "$LOG_FILE" 2>/dev/null || true

# §SPEC-020 (SEE-1516, fingerprint 81cc9a4a20e6): tool= 字段删除 —— $TOOL_NAME
# 环境变量 CC 从不注入（工具名在 stdin payload JSON 内），本层读 stdin 会吞掉
# dispatcher/engine 的输入，原字段恒空属排障误导。工具名观测面由引擎侧
# firelog（payload 解析后）承载。
echo "[$TIMESTAMP] [$HOOK_TYPE] alias=$ALIAS" >> "$LOG_FILE" 2>/dev/null || true

exec "$(cd "$(dirname "$0")" && pwd)/dispatcher.sh" "$ALIAS"