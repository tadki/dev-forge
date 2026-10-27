#!/usr/bin/env bash
# autopilots/lib/common_env.sh — wrapper env→flag 单源（SEE-1440 / fingerprint ee57f95b522c）
#
# 三个 autopilot wrapper（version_check / issue_status_check /
# architecture_sweep）共享的样板收敛于此：
#   - Python 解释器探测（PYTHON_CMD）
#   - Kill Switch 环境变量透传默认值（KILL_SWITCH）
#   - env 布尔值 → argparse flag 换算
#   - worktree hash 推导（MULTICA_WORKTREE_HASH / PWD 回落）
#
# 供 wrapper source，不独立执行。helper 只做既有样板的原样收敛，
# 不改变各 wrapper 的比较语义（保持精确 "true"/"false" 字面量比较）。
# shellcheck shell=bash

# 探测 Python 解释器并设置 PYTHON_CMD；找不到时输出 JSON 错误并以非零返回。
autopilots_detect_python() {
    if command -v python3 &>/dev/null; then
        PYTHON_CMD=python3
    elif command -v python &>/dev/null; then
        PYTHON_CMD=python
    else
        echo '{"error": "Python not found"}' >&2
        return 1
    fi
}

# Kill Switch 透传默认值（显式 env 覆盖优先；语义见 autopilots/kill_switch.py）。
autopilots_kill_switch() {
    KILL_SWITCH="${KILL_SWITCH:-false}"
}

# env 值精确等于 "true" 时打印 flag，否则打印空串（不区分大小写不变，保持原样比较）。
autopilots_flag_if_true() {
    if [ "$2" = "true" ]; then
        printf '%s\n' "$1"
    fi
    return 0
}

# DRY_RUN 三态换算：true → --dry-run；false → --no-dry-run；其他 → 空串。
autopilots_dry_run_pair() {
    if [ "$1" = "true" ]; then
        printf '%s\n' "--dry-run"
    elif [ "$1" = "false" ]; then
        printf '%s\n' "--no-dry-run"
    fi
    return 0
}

# 推导当前 worktree hash：MULTICA_WORKTREE_HASH 优先，否则在 WORKSPACE_ROOT
# 内按首段目录名回落；两者皆缺时打印空串。
autopilots_current_hash() {
    if [ -n "${MULTICA_WORKTREE_HASH:-}" ]; then
        printf '%s\n' "$MULTICA_WORKTREE_HASH"
    elif [ -n "${1:-}" ]; then
        case "$PWD" in
            "$1"/*)
                rel="${PWD#"$1"/}"
                printf '%s\n' "${rel%%/*}"
                ;;
        esac
    fi
    return 0
}
