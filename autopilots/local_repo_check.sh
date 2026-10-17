#!/usr/bin/env bash
# Local worktree inspection script for Multica workspace
# Scans worktree directories, collects metadata, checks git status,
# auto-deletes clean+pushed worktrees, and outputs structured JSON.
#
# Delegates to local_repo_check.py for cross-platform compatibility.
# SEE-956 L1: `set -e` added so the wrapper fails fast if the Python script (or
# any setup step) exits non-zero, instead of silently returning success.
set -euo pipefail

# SEE-1181: WORKSPACE_ROOT is no longer hardcoded. The Python script derives it
# from MULTICA_WORKSPACE_ID (or by walking up from the script location). Only
# pass --workspace-root when the caller supplies one explicitly.
WORKSPACE_ROOT="${1:-}"
DRY_RUN="${DRY_RUN:-false}"
EXECUTION_ISSUE_ID="${EXECUTION_ISSUE_ID:-}"

# Kill switch: if set, downgrade to pure output mode (SEE-1224 #4; mirrors
# version_check.sh KILL_SWITCH passthrough).
KILL_SWITCH="${KILL_SWITCH:-false}"

# Determine script directory for calling the Python script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Determine current worktree hash to skip
CURRENT_HASH=""
if [ -n "${MULTICA_WORKTREE_HASH:-}" ]; then
  CURRENT_HASH="$MULTICA_WORKTREE_HASH"
elif [ -n "$WORKSPACE_ROOT" ]; then
  case "$PWD" in
    "$WORKSPACE_ROOT"/*)
      rel="${PWD#$WORKSPACE_ROOT/}"
      CURRENT_HASH="${rel%%/*}"
      ;;
  esac
fi

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
fi

WORKSPACE_ROOT_ARG=()
if [ -n "$WORKSPACE_ROOT" ]; then
  WORKSPACE_ROOT_ARG=(--workspace-root "$WORKSPACE_ROOT")
fi

"$PYTHON_CMD" "$SCRIPT_DIR/local_repo_check.py" \
    "${WORKSPACE_ROOT_ARG[@]}" \
    --current-hash "$CURRENT_HASH" \
    $DRY_RUN_ARG \
    --kill-switch "$KILL_SWITCH" \
    --execution-issue-id "$EXECUTION_ISSUE_ID"
