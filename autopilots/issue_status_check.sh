#!/usr/bin/env bash
# Issue status inspection script for Multica Autopilot
# Scans issues across all statuses, collects metadata, counts push reminders,
# checks run states, and outputs structured JSON for agent decision-making.
#
# Delegates to issue_status_check.py for cross-platform compatibility.
# The Python script includes its own PID file locking with stale lock detection.
set -uo pipefail

DRY_RUN="${DRY_RUN:-true}"
VERBOSE="${VERBOSE:-false}"
SELF_AGENT_ID="${SELF_AGENT_ID:-b2384294-919a-4a91-9f35-2c45848577aa}"
PID_FILE="${PID_FILE:-${TMPDIR:-/tmp}/issue_status_check.pid}"
LOCK_TIMEOUT="${LOCK_TIMEOUT:-300}"

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

# Build flag arguments (new argparse interface uses flags, not string values)
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

"$PYTHON_CMD" "$SCRIPT_DIR/issue_status_check.py" \
    $DRY_RUN_ARG \
    $VERBOSE_ARG \
    --self-agent-id "$SELF_AGENT_ID" \
    --kill-switch "$KILL_SWITCH" \
    --pid-file "$PID_FILE" \
    --lock-timeout "$LOCK_TIMEOUT"