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
# Known accepted tradeoffs:
#   * SIGTERM coarse stop (no graceful drain of running agent tasks)
#   * no PID-file idempotency at launcher level (each daemon self-locks via
#     its registered pid_file, so re-running start-all will not double-start)

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
REGISTRY_DIR="$REPO_ROOT/repo-sync/repos.d"
DEV_FORGE_ROOT="$REPO_ROOT"

DAEMON_LOG="${TOOLCHAIN_DAEMON_LOG:-$HOME/.multica/daemon.log}"

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

# multica daemon in the foreground: systemd supervises this PID directly.
echo "[start] Starting multica daemon in foreground (log: $DAEMON_LOG)..."
exec "$MULTICA" daemon start --foreground >> "$DAEMON_LOG" 2>&1
