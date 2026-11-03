#!/usr/bin/env bash
# Single launcher for the dev-forge tool chain (SEE-894 Plan 2, SEE-1430b).
#
# Starts one repo-sync daemon instance per registered repo (scan of
# repo-sync/repos.d/*.json — the single source of truth for which repos are
# enrolled), then execs the multica daemon in the foreground so systemd's
# MainPID is the daemon process itself.
#
# Invoked as ExecStart by launch/systemd/toolchain-start-all.service, or run
# manually:   bash launch/toolchain-start.sh
#
# SEE-1430b: repo-sync 三件套已迁 dev-forge repo-sync/（注册制 repos.d/，
# 新仓 = 落一份 JSON 即生效）。本脚本扫注册目录逐仓各起一实例（沿用各注册
# 文件的 pid/lock 显式值），GQT 双启动器收敛为 dev-forge 单侧——gqt 的
# godot-qa-toolkit-start.sh 不再自起 repo-sync（退役为 thin-wrap，见该仓 PR）。
# SEE-1519: daemon 已在运行时脚本幂等驻留而非 exec→exit 1（旧路径使 systemd
# 判失败并连带杀掉刚拉起的 repo-sync）；unit 落 KillMode=process，stop/restart
# 只信号 MainPID，repo-sync 不再被 cgroup 连带杀，已停实例由每次激活的拉起
# 循环补拉（每个 daemon 经注册 pid_file 自锁，存活实例不会被 double-start）。

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
REGISTRY_DIR="$REPO_ROOT/repo-sync/repos.d"
DEV_FORGE_ROOT="$REPO_ROOT"

DAEMON_LOG="${TOOLCHAIN_DAEMON_LOG:-$HOME/.multica/daemon.log}"
# SEE-1519 §SPEC-001: 已运行分支的驻留轮询间隔。守护消失后最迟一个间隔 +
# RestartSec 内由 systemd 重启补位；轮询（而非 tail --pid）可无感穿越 daemon
# 自身 auto-reload 换 PID，避免 unit 无谓 churn。
HOLD_POLL_INTERVAL="${TOOLCHAIN_HOLD_POLL_INTERVAL:-30}"

MULTICA="${MULTICA:-multica}"
if ! command -v "$MULTICA" &>/dev/null; then
    echo "[start] ERROR: multica not found in PATH" >&2
    exit 1
fi

[ -d "$REGISTRY_DIR" ] || { echo "[start] ERROR: registry dir not found: $REGISTRY_DIR" >&2; exit 1; }

mkdir -p "$(dirname "$DAEMON_LOG")"

# One repo-sync daemon instance per registered repo. Each instance self-locks
# via the pid_file written in its registration JSON, so re-running start-all
# after a partial boot will not double-start any of them.
shopt -s nullglob
REGISTRATIONS=("$REGISTRY_DIR"/*.json)
shopt -u nullglob
if [ "${#REGISTRATIONS[@]}" -eq 0 ]; then
    echo "[start] ERROR: no registrations in $REGISTRY_DIR" >&2
    exit 1
fi

for reg in "${REGISTRATIONS[@]}"; do
    name="$(basename "$reg" .json)"
    echo "[start] Starting repo-sync daemon for '$name' (registry: $reg)..."
    nohup python3 "$DEV_FORGE_ROOT/repo-sync/repo_sync_daemon.py" \
        --config "$reg" \
        >> /tmp/repo-sync-daemon-"$name".log 2>&1 &
done

# multica per-task routing affinity (same as 105 deployment): make the daemon
# launch the wrapper instead of plain claude, so each task run stamps
# x-multica-task-session-id (litellm session affinity key).
export MULTICA_CLAUDE_PATH="$HOME/.local/bin/multica-claude"

multica_daemon_running() {
    # CLI 契约（SEE-1519 code 节点实机验证 2026-11-04）: `daemon status --output json`
    # 在 daemon 运行时 exit 0 且 JSON "status":"running"；未运行/profile 已占用时
    # 非零。解析用 bash 正则而非 python3：本脚本 PATH 可能被部署环境前置 stub
    # （python3 拉起 daemon 的解析点是有意为之），探测不应被 PATH 影子劫持。
    # 探测失败（命令错误/输出非 JSON）一律视为「不可判」→ 交调用方走 exec
    # 前台分支（= 改动前行为），失败面不扩大。
    local status_json
    if ! status_json="$("$MULTICA" daemon status --output json 2>/dev/null)"; then
        return 1
    fi
    [[ "$status_json" =~ \"status\"[[:space:]]*:[[:space:]]*\"(running|starting)\" ]]
}

# SEE-1519 §SPEC-001: 若 daemon 已在运行，不得 exec（CLI 会 exit 1 → systemd 判
# 失败 → 旧 KillMode=control-group 连带杀 repo-sync）。也不得立即 exit 0：
# Type=simple + Restart=always 会把立即退出变成每 10s 空转重启。保持前台驻留
# 轮询，守护消失后退出交 systemd 重启补位（届时走下方 exec 分支重新接监督）。
if multica_daemon_running; then
    echo "[start] multica daemon already running or starting — idempotent hold" \
         "(poll ${HOLD_POLL_INTERVAL}s)"
    while true; do
        sleep "$HOLD_POLL_INTERVAL"
        if ! multica_daemon_running; then
            echo "[start] multica daemon no longer running — exiting for systemd restart" >&2
            exit 0
        fi
    done
fi

# multica daemon in the foreground: systemd supervises this PID directly.
echo "[start] Starting multica daemon in foreground (log: $DAEMON_LOG)..."
exec "$MULTICA" daemon start --foreground >> "$DAEMON_LOG" 2>&1
