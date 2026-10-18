#!/bin/bash
# SEE-1242 B-2 P3-2: godot-mcp 工具清单被动记录（hook-fire.log）。
#
# 目的：把「本会话 MCP 注入形态」作为 B-0 归因的原始证据落盘——每次
# SessionStart 记录 MCP_TIMEOUT/MCP_TOOL_TIMEOUT 是否注入、ECC_DISABLED_MCPS
# 名单、daemon 注入的 mcp-config 路径与 godot 条目有无。与 P3-1 的注册层
# verdict 组合成 B-1 裁决要求的「当刻组合证据」：
#   配置完好 + tool list 缺失 → 注册窗口时序竞态（platform）
#   command 缺失/指向失效    → 注册层损坏（2026-08-01 形态）
#
# 约束：只读 env + /tmp 的 mcp-config，零副作用，任何失败 exit 0 不阻塞。
#
# SEE-1316 (hardener): 父进程 cmdline 探测在 daemon-chained hook 下常拿不到
# --mcp-config（PPID 是 hook wrapper 而非 claude 进程）→ godot_entry 恒
# unknown。补三级回退：PPID 祖先链（向上走 3 层）→ 本会话 /tmp/multica-mcp-*/
# 最新 mcp-config.json 兜底扫描。分辨率标注来源（parent|ancestor|tmp-fallback），
# 让 B-0 归因能区分「父链探测成功」与「兜底扫描命中」。

# firelog 落点走单源 lib（SEE-1388 §SPEC-018，QA O1 残余收敛）；lib 缺失时保持
# 旧内联构造兜底（fail-open：落点解析失败绝不阻塞本只读脚本）。
_lib_dir="$(cd "$(dirname "$0")" && pwd)"
for _cand in "$_lib_dir/lib/hook-fire-path.lib.sh" \
  "$HOME/.claude/hooks/scripts/lib/hook-fire-path.lib.sh"; do
  [ -f "$_cand" ] && . "$_cand" && break
done
if declare -F resolve_hook_fire_log_path >/dev/null 2>&1; then
  HOOK_FIRE_LOG=$(resolve_hook_fire_log_path 2>/dev/null) || HOOK_FIRE_LOG=""
else
  # lib 缺失兜底（与 lib 最终候选同一路径，单一回退字面量）
  HOOK_FIRE_LOG=""
fi
if [ -z "$HOOK_FIRE_LOG" ]; then
  HOOK_FIRE_LOG="$HOME/.claude/hook-fire.log"
fi

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

MCP_TIMEOUT_SET="${MCP_TIMEOUT:+set=${MCP_TIMEOUT}}"
MCP_TIMEOUT_SET="${MCP_TIMEOUT_SET:-unset}"
MCP_TOOL_TIMEOUT_SET="${MCP_TOOL_TIMEOUT:+set=${MCP_TOOL_TIMEOUT}}"
MCP_TOOL_TIMEOUT_SET="${MCP_TOOL_TIMEOUT_SET:-unset}"

MCP_CFG_PATH=""
CFG_SOURCE="not-found"

# 1) direct parent cmdline（历史行为）
MCP_CFG_PATH="$(ps -o args= -p "$PPID" 2>/dev/null | grep -oE '\-\-mcp-config [^ ]+' | head -1 | awk '{print $2}')"
[[ -n "$MCP_CFG_PATH" ]] && CFG_SOURCE="parent"

# 2) ancestor chain (up to 3 hops): daemon → claude → hook → this script
if [[ -z "$MCP_CFG_PATH" ]]; then
    _p="$PPID"
    for _i in 1 2 3; do
        _p="$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d '[:space:]')"
        [[ -n "$_p" && "$_p" != "1" && "$_p" != "0" ]] || break
        _hit="$(ps -o args= -p "$_p" 2>/dev/null | grep -oE '\-\-mcp-config [^ ]+' | head -1 | awk '{print $2}')"
        if [[ -n "$_hit" ]]; then
            MCP_CFG_PATH="$_hit"
            CFG_SOURCE="ancestor-$_i"
            break
        fi
    done
fi

# 3) /tmp/multica-mcp-*/ fallback: newest mcp-config.json containing a godot
#    entry. Ambiguity note (recorded in the log line): with concurrent runtime
#    sessions the newest file is USUALLY this session's (configs are written at
#    session start), but this is a heuristic — the source tag makes the guess
#    explicit for downstream attribution.
if [[ -z "$MCP_CFG_PATH" ]]; then
    _best=""
    _best_mtime=0
    for _f in /tmp/multica-mcp-*/mcp-config.json; do
        [[ -f "$_f" ]] || continue
        _m="$(stat -c %Y "$_f" 2>/dev/null || echo 0)"
        if (( _m > _best_mtime )); then
            _best_mtime="$_m"
            _best="$_f"
        fi
    done
    if [[ -n "$_best" ]]; then
        MCP_CFG_PATH="$_best"
        CFG_SOURCE="tmp-fallback"
    fi
fi

GODOT_IN_CFG="unknown"
if [[ -n "$MCP_CFG_PATH" && -f "$MCP_CFG_PATH" ]]; then
    if grep -q '"godot' "$MCP_CFG_PATH" 2>/dev/null; then
        GODOT_IN_CFG="present"
    else
        GODOT_IN_CFG="absent"
    fi
else
    MCP_CFG_PATH="${MCP_CFG_PATH:-not-found-in-parent-cmdline}"
fi

printf '[%s] [mcp-tool-presence] session_start MCP_TIMEOUT=%s MCP_TOOL_TIMEOUT=%s ECC_DISABLED_MCPS=%s mcp_config_path=%s cfg_source=%s godot_entry=%s\n' \
    "$TS" "$MCP_TIMEOUT_SET" "$MCP_TOOL_TIMEOUT_SET" \
    "${ECC_DISABLED_MCPS:-<none>}" "$MCP_CFG_PATH" "$CFG_SOURCE" "$GODOT_IN_CFG" \
    >> "$HOOK_FIRE_LOG" 2>/dev/null || true

exit 0
