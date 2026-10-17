#!/usr/bin/env bash
# Multica version release inspection script for Autopilot.
# Fetches GitHub releases, compares against current version, outputs analysis.
#
# Delegates to version_check.py for cross-platform compatibility.
set -uo pipefail

DRY_RUN="${DRY_RUN:-true}"
VERBOSE="${VERBOSE:-false}"
SELF_AGENT_ID="${SELF_AGENT_ID:-a5c250e8-7257-466e-b45a-03f995c7206c}"
PID_FILE="${PID_FILE:-${TMPDIR:-/tmp}/version_check.pid}"
LOCK_TIMEOUT="${LOCK_TIMEOUT:-300}"
ISSUE_ID="${ISSUE_ID:-}"
OUTPUT_JSON="${OUTPUT_JSON:-false}"

# Kill switch: if set, downgrade to pure output mode (no write operations)
KILL_SWITCH="${KILL_SWITCH:-false}"

# Determine script directory for calling the Python script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Dynamic Python detection
if command -v python3 &>/dev/null; then
    PYTHON_CMD=python3
elif command -v python &>/dev/null; then
    PYTHON_CMD=python
else
    echo '{"error": "Python not found"}' >&2
    exit 1
fi

# Build flag arguments
DRY_RUN_ARG=""
if [ "$DRY_RUN" = "true" ]; then
  DRY_RUN_ARG="--dry-run"
elif [ "$DRY_RUN" = "false" ]; then
  DRY_RUN_ARG="--no-dry-run"
fi

VERBOSE_ARG=""
if [ "$VERBOSE" = "true" ]; then
  VERBOSE_ARG="--verbose"
fi

OUTPUT_JSON_ARG=""
if [ "$OUTPUT_JSON" = "true" ]; then
  OUTPUT_JSON_ARG="--output-json"
fi

"$PYTHON_CMD" "$SCRIPT_DIR/version_check.py" \
    $DRY_RUN_ARG \
    $VERBOSE_ARG \
    $OUTPUT_JSON_ARG \
    --self-agent-id "$SELF_AGENT_ID" \
    --kill-switch "$KILL_SWITCH" \
    --pid-file "$PID_FILE" \
    --lock-timeout "$LOCK_TIMEOUT" \
    ${ISSUE_ID:+--issue-id "$ISSUE_ID"}
