#!/usr/bin/env bash
# Agent Watchdog wrapper — shared env→flag boilerplate (SEE-1516 §SPEC-013/C6).
# Delegates to agent_watchdog.py; sourced from lib/common_env.sh (SEE-1440).
# §SPEC-013: --kill-switch 仅在 env 显式设置时透传 (同 B1/sweep 口径), 未设时
# 省略交由 Python kill_switch_default() 单源 (paused 文件 OR env) 解析 —
# 无条件透传默认 false 会覆盖 paused-file 契约。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common_env.sh
source "$SCRIPT_DIR/lib/common_env.sh"

DRY_RUN="${DRY_RUN:-true}"
VERBOSE="${VERBOSE:-false}"
SELF_AGENT_ID="${WATCHDOG_SELF_AGENT_ID:-}"
PID_FILE="${PID_FILE:-${TMPDIR:-/tmp}/agent_watchdog.pid}"
STATE_FILE="${STATE_FILE:-}"
EXECUTION_ISSUE_ID="${EXECUTION_ISSUE_ID:-}"
ALERT_ISSUE_ID="${ALERT_ISSUE_ID:-}"

# 捕获须在 autopilots_kill_switch 应用默认值之前 (sweep 同序)。
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

"$PYTHON_CMD" "$SCRIPT_DIR/agent_watchdog.py" \
    $DRY_RUN_ARG \
    $VERBOSE_ARG \
    --self-agent-id "$SELF_AGENT_ID" \
    $KILL_SWITCH_ARG \
    --pid-file "$PID_FILE" \
    ${STATE_FILE:+--state-file "$STATE_FILE"} \
    ${EXECUTION_ISSUE_ID:+--execution-issue-id "$EXECUTION_ISSUE_ID"} \
    ${ALERT_ISSUE_ID:+--alert-issue-id "$ALERT_ISSUE_ID"}