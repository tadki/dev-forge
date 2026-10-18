# hook-fire-path.lib.sh - hook-fire.log 落点解析单源实现（SEE-1388 SPEC-002）
# bash 三入口（hook-wrapper.sh / dispatcher.sh / unified-hook.sh）统一 source 本文件，
# 经 resolve_hook_fire_log_path 取落点；JS 权威实现为 .claude/hooks/unified/engine.js
# resolveFirelogPath()。同 env 同落点。全局部署位布局：~/.claude/hooks/scripts/lib/。
# 写入侧约定不变：firelog 写失败绝不影响主流程（调用方 || true）。

# 解析顺序（与 engine.js resolveFirelogPath 等价）：
#   1. HOOK_FIRE_LOG（测试注入，全入口支持）
#   2. PROJECT_ROOT / PROJECT_ROOT_CANON（调用方可指定项目根）
#   3. CLAUDE_PROJECT_DIR → PWD
#   4. PWD 子目录一层扫描（Multica workdir 形态：repo 落在 workdir 内）
#      仅当调用方未设 FIRELOG_NO_PWD_SCAN=1（dispatcher 保留自身"无 PROJECT_ROOT
#      即全局兜底"的既有形态）
#   5. $HOME/.claude/hook-fire.log 全局兜底
resolve_hook_fire_log_path() {
  if [ -n "${HOOK_FIRE_LOG:-}" ]; then
    printf '%s' "$HOOK_FIRE_LOG"
    return 0
  fi
  local _root="${PROJECT_ROOT_CANON:-${PROJECT_ROOT:-}}"
  local _dir
  for _dir in "$_root" "${CLAUDE_PROJECT_DIR:-}" "$PWD"; do
    [ -n "$_dir" ] && [ -d "$_dir/.claude" ] && { printf '%s' "$_dir/.claude/hook-fire.log"; return 0; }
  done
  if [ "${FIRELOG_NO_PWD_SCAN:-0}" != "1" ]; then
    local _subdir
    for _subdir in "$PWD"/*/; do
      [ -d "${_subdir}.claude" ] && { printf '%s' "${_subdir}.claude/hook-fire.log"; return 0; }
    done 2>/dev/null
  fi
  printf '%s' "$HOME/.claude/hook-fire.log"
}

# lib 定位引用（各入口按自身目录拓扑 source，2 行内，不算第二份实现）
source_hook_fire_path_lib() {
  local _self_dir _lib
  _self_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
  for _lib in \
    "$_self_dir/../scripts/lib/hook-fire-path.lib.sh" \
    "$_self_dir/../../.claude/hooks/scripts/lib/hook-fire-path.lib.sh" \
    "$HOME/.claude/hooks/scripts/lib/hook-fire-path.lib.sh"; do
    if [ -f "$_lib" ]; then
      . "$_lib"
      return 0
    fi
  done
  return 1
}
