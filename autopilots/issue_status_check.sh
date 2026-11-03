#!/usr/bin/env bash
# Issue status inspection script for Multica Autopilot
# Scans issues across all statuses, collects metadata, counts push reminders,
# checks run states, and outputs structured JSON for agent decision-making.
#
# Delegates to issue_status_check.py for cross-platform compatibility.
# The Python script includes its own PID file locking with stale lock detection.
# Shared env→flag boilerplate is sourced from lib/common_env.sh (SEE-1440).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common_env.sh
source "$SCRIPT_DIR/lib/common_env.sh"

DRY_RUN="${DRY_RUN:-true}"
VERBOSE="${VERBOSE:-false}"
SELF_AGENT_ID="${SELF_AGENT_ID:-b2384294-919a-4a91-9f35-2c45848577aa}"
PID_FILE="${PID_FILE:-${TMPDIR:-/tmp}/issue_status_check.pid}"
LOCK_TIMEOUT="${LOCK_TIMEOUT:-300}"

# SEE-1516 §SPEC-006 (fingerprint 1df221b87557): 仅在 env 显式设置时透传
# --kill-switch（同 sweep SEE-1460 决策 6' 已修同款）。未设时省略 flag，
# 由 Python 侧 kill_switch_default()（paused 文件 OR env 单源）解析真值；
# 无条件透传默认 "false" 会覆盖 paused-file 契约（B1 根因）。
KILL_SWITCH_FROM_ENV=0
if [ -n "${KILL_SWITCH+x}" ]; then
  KILL_SWITCH_FROM_ENV=1
fi

autopilots_kill_switch
autopilots_detect_python || exit 1

DRY_RUN_ARG="$(autopilots_dry_run_pair "$DRY_RUN")"
VERBOSE_ARG="$(autopilots_flag_if_true --verbose "$VERBOSE")"
KILL_SWITCH_ARG=""
if [ "$KILL_SWITCH_FROM_ENV" = "1" ]; then
  KILL_SWITCH_ARG="--kill-switch $KILL_SWITCH"
fi

"$PYTHON_CMD" "$SCRIPT_DIR/issue_status_check.py" \
    $DRY_RUN_ARG \
    $VERBOSE_ARG \
    --self-agent-id "$SELF_AGENT_ID" \
    $KILL_SWITCH_ARG \
    --pid-file "$PID_FILE" \
    --lock-timeout "$LOCK_TIMEOUT"
