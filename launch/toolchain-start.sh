#!/usr/bin/env bash
# Single launcher for the King of Likes dev tool chain (SEE-894 Plan 2).
#
# Starts the repo-sync daemon in the background, then execs the multica daemon
# in the foreground so systemd's MainPID is the daemon process itself.
#
# Invoked as ExecStart by launch/systemd/toolchain-start-all.service, or run
# manually:   bash launch/toolchain-start.sh
#
# Plan 2 intentionally trades away the previous layering (machine env file,
# project JSON config loader, PID-file idempotency, graceful agent-task drain,
# and the migration/upgrade helpers) for a minimal 1-unit-1-script shape. The
# repo checkout path and user are HARDCODED below — edit them here if the WSL
# checkout moves. Known accepted tradeoffs:
#   * hardcoded WSL path / user (no per-machine override)
#   * SIGTERM coarse stop (no graceful drain of running agent tasks)
#   * no PID-file idempotency for repo-sync (rely on systemd single-instance)
#   * no migrate-to-start-all helper for legacy unit rollover

set -euo pipefail

# Hardcoded main-repo checkout (Plan 2 tradeoff: no machine env override).
REPO_ROOT="${TARGET_REPO_ROOT:-/mnt/d/GodotProjects/king-of-likes}"
DEV_DIR="$REPO_ROOT/.dev"
DAEMON_LOG="${KOL_DAEMON_LOG:-$HOME/.multica/daemon.log}"

# repo_sync_config.json uses the __TARGET_REPO_ROOT__ sentinel; the daemon
# resolves it from this env var at config-load time.
export TARGET_REPO_ROOT="$REPO_ROOT"

MULTICA="${MULTICA:-multica}"
if ! command -v "$MULTICA" &>/dev/null; then
    echo "[start] ERROR: multica not found in PATH" >&2
    exit 1
fi

mkdir -p "$DEV_DIR/logs" "$(dirname "$DAEMON_LOG")"

# repo-sync in the background. Detached subshell so it survives this script's
# exec; the daemon writes its own pid file from repo_sync_config.json.
echo "[start] Starting repo-sync daemon..."
( cd "$DEV_DIR" && \
  nohup python3 repo-sync/repo_sync_daemon.py --config repo-sync/repo_sync_config.json \
    >> "$DEV_DIR/logs/repo-sync-daemon.log" 2>&1 & )

# GQT repo-sync daemon (SEE-1406): companion canonical checkout at
# ~/tools/godot-qa-toolkit, synced by its own repo-sync triple (lock files are
# godot-qa-toolkit-namespaced, no collision with the KOL daemon above). The
# GQT daemon pid-locks itself via /tmp/godot-qa-toolkit-sync-daemon.pid, so
# re-running start-all after a partial boot will not double-start it.
GQT_REPO_ROOT="${GQT_REPO_ROOT:-$HOME/tools/godot-qa-toolkit}"
if [ -d "$GQT_REPO_ROOT/.dev/repo-sync" ]; then
  echo "[start] Starting GQT repo-sync daemon..."
  ( cd "$GQT_REPO_ROOT/.dev" && \
    GQT_REPO_ROOT="$GQT_REPO_ROOT" nohup python3 repo-sync/repo_sync_daemon.py \
      --config repo-sync/repo_sync_config.json \
      >> "$GQT_REPO_ROOT/.dev/logs/repo-sync-daemon.log" 2>&1 & )
else
  echo "[start] GQT repo-sync skipped (no $GQT_REPO_ROOT/.dev/repo-sync)" >&2
fi

# multica per-task routing affinity (same as 105 deployment): make the daemon
# launch the wrapper instead of plain claude, so each task run stamps
# x-multica-task-session-id (litellm session affinity key).
export MULTICA_CLAUDE_PATH="$HOME/.local/bin/multica-claude"

# multica daemon in the foreground: systemd supervises this PID directly.
echo "[start] Starting multica daemon in foreground (log: $DAEMON_LOG)..."
exec "$MULTICA" daemon start --foreground >> "$DAEMON_LOG" 2>&1
