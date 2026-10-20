#!/usr/bin/env bash
# Local worktree inspection script for Multica workspace
# Scans worktree directories, collects metadata, checks git status,
# auto-deletes clean+pushed worktrees, and outputs structured JSON.
#
# Delegates to local_repo_check.py for cross-platform compatibility.
# SEE-956 L1: `set -e` added so the wrapper fails fast if the Python script (or
# any setup step) exits non-zero, instead of silently returning success.
# Shared env→flag boilerplate is sourced from lib/common_env.sh (SEE-1440).
set -euo pipefail

# SEE-1181: WORKSPACE_ROOT is no longer hardcoded. The Python script derives it
# from MULTICA_WORKSPACE_ID (or by walking up from the script location). Only
# pass --workspace-root when the caller supplies one explicitly.
WORKSPACE_ROOT="${1:-}"
DRY_RUN="${DRY_RUN:-false}"
EXECUTION_ISSUE_ID="${EXECUTION_ISSUE_ID:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common_env.sh
source "$SCRIPT_DIR/lib/common_env.sh"

autopilots_kill_switch
autopilots_detect_python || exit 1

CURRENT_HASH="$(autopilots_current_hash "$WORKSPACE_ROOT")"

DRY_RUN_ARG="$(autopilots_flag_if_true --dry-run "$DRY_RUN")"

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
