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

echo "[$TIMESTAMP] [$HOOK_TYPE] alias=$ALIAS tool=$TOOL_NAME" >> "$LOG_FILE" 2>/dev/null || true

exec "$(cd "$(dirname "$0")" && pwd)/dispatcher.sh" "$ALIAS"