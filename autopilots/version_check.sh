#!/usr/bin/env bash
# Multica version release inspection script for Autopilot.
# Fetches GitHub releases, compares against current version, outputs analysis.
#
# Delegates to version_check.py for cross-platform compatibility.
# Shared env→flag boilerplate is sourced from lib/common_env.sh (SEE-1440).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common_env.sh
source "$SCRIPT_DIR/lib/common_env.sh"

DRY_RUN="${DRY_RUN:-true}"
VERBOSE="${VERBOSE:-false}"
SELF_AGENT_ID="${SELF_AGENT_ID:-a5c250e8-7257-466e-b45a-03f995c7206c}"
PID_FILE="${PID_FILE:-${TMPDIR:-/tmp}/version_check.pid}"
LOCK_TIMEOUT="${LOCK_TIMEOUT:-300}"
ISSUE_ID="${ISSUE_ID:-}"
OUTPUT_JSON="${OUTPUT_JSON:-false}"

autopilots_kill_switch
autopilots_detect_python || exit 1

DRY_RUN_ARG="$(autopilots_dry_run_pair "$DRY_RUN")"
VERBOSE_ARG="$(autopilots_flag_if_true --verbose "$VERBOSE")"
OUTPUT_JSON_ARG="$(autopilots_flag_if_true --output-json "$OUTPUT_JSON")"

"$PYTHON_CMD" "$SCRIPT_DIR/version_check.py" \
    $DRY_RUN_ARG \
    $VERBOSE_ARG \
    $OUTPUT_JSON_ARG \
    --self-agent-id "$SELF_AGENT_ID" \
    --kill-switch "$KILL_SWITCH" \
    --pid-file "$PID_FILE" \
    --lock-timeout "$LOCK_TIMEOUT" \
    ${ISSUE_ID:+--issue-id "$ISSUE_ID"}
