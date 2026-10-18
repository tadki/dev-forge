#!/usr/bin/env bash
# SEE-1273 T5-F: godot-mcp launch 工具路径解析库（hooks 共用）。
#
# T5-F 旧路径体系完全退役后，launch 工具链唯一落点是 submodule 挂载内的
# addons/godot_mcp/launch/（gitlink 已切 fork main，submodule 内 launch/
# 自 T1 提根后随 addon 挂载落地）。本库按此单落点解析。
# 历史注：T3 期曾按「优先 submodule 内、兜底 .dev/godot-mcp/launch」双落点，
# 兜底分支已随 T5-F 旧目录整体删除一并移除——现在解析不到即返回 1（调用方
# 自行决定降级行为），不再回退任何 legacy 路径。
#
# 用法：source 本文件后调用 mcp_launch_script <name>，输出可执行文件路径。

mcp_launch_dir() {
    local root="${1:-$PWD}"
    if [ -d "$root/addons/godot_mcp/launch" ]; then
        printf '%s\n' "$root/addons/godot_mcp/launch"
    else
        return 1
    fi
}

mcp_launch_script() {
    local name="$1" root="${2:-$PWD}" dir
    dir="$(mcp_launch_dir "$root")" || return 1
    if [ -x "$dir/$name" ]; then
        printf '%s\n' "$dir/$name"
        return 0
    fi
    return 1
}
