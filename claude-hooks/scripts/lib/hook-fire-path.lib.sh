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

# SEE-1440 §SPEC-025：firelog 尺寸上限轮转（写入层，fail-open）。
# 超限 → 旧文件整档转存 <file>.1（覆盖上一份备份，占用有界 2×上限）→ 新空文件续写；
# 轮转失败（权限/竞态，含并发 append 竞态丢行的最坏情形）静默放行——firelog 是
# best-effort 观测日志，绝不阻断 hook 链（与上方写入侧约定同源）。
# 缺省上限 10MiB（台账暂缓区「>10MB 归档」既有口径）；HOOK_FIRE_LOG_MAX_BYTES
# 可注入供测试/调参，0 或非数字视为不设限。
HOOK_FIRE_LOG_MAX_BYTES="${HOOK_FIRE_LOG_MAX_BYTES:-10485760}"
maybe_rotate_hook_fire_log() {
  local _f="${1:-}"
  [ -n "$_f" ] && [ -f "$_f" ] || return 0
  case "$HOOK_FIRE_LOG_MAX_BYTES" in ''|*[!0-9]*|0) return 0 ;; esac
  local _size
  _size=$(wc -c <"$_f" 2>/dev/null) || return 0
  case "$_size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$_size" -le "$HOOK_FIRE_LOG_MAX_BYTES" ] && return 0
  mv -f "$_f" "$_f.1" 2>/dev/null || return 0
  : > "$_f" 2>/dev/null
  return 0
}

# lib 定位引用（各入口按自身目录拓扑 source，2 行内，不算第二份实现）
source_hook_fire_path_lib() {
  local _self_dir _lib
  _self_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
  for _lib in \
    "$_self_dir/../scripts/lib/hook-fire-path.lib.sh"; do
    if [ -f "$_lib" ]; then
      . "$_lib"
      return 0
    fi
  done
  return 1
}
