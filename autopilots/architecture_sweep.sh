#!/usr/bin/env bash
# Architecture Sweep — daily static architecture patrol for KingOfLikes-Godot.
# SEE-1180 Thread 1: read-only static inspection, no writes to shared branches.
#
# Delegates to architecture_sweep.py for cross-platform compatibility.
# SEE-956 L1: `set -e` added so the wrapper fails fast if the Python script
# exits non-zero, instead of silently returning success.
# Shared env→flag boilerplate is sourced from lib/common_env.sh (SEE-1440).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common_env.sh
source "$SCRIPT_DIR/lib/common_env.sh"

# D7: parse both flag-style and positional args so `--dry-run` (or any flag)
# never gets mistaken for a workspace-root positional, matching the python
# script's argparse semantics. Positionals: first is the workspace root,
# second is the current worktree hash.
WORKSPACE_ROOT=""
CURRENT_HASH=""
FAST_ARG=""
DRY_RUN_ARG=""
L1_ARG=""
SKIP_NEXT=""
EXECUTION_ISSUE_ID=""
for ARG in "$@"; do
  if [ -n "$SKIP_NEXT" ]; then
    SKIP_NEXT=""
    continue
  fi
  case "$ARG" in
    --fast)
      FAST_ARG="--fast"
      ;;
    --dry-run)
      DRY_RUN_ARG="--dry-run"
      ;;
    --l1)
      L1_ARG="--l1"
      ;;
    --workspace-root|--workspace-root=*|--current-hash|--current-hash=*)
      case "$ARG" in
        --workspace-root)
          SKIP_NEXT=1
          ;;
        --workspace-root=*)
          WORKSPACE_ROOT="${ARG#--workspace-root=}"
          ;;
        --current-hash)
          SKIP_NEXT=1
          ;;
        --current-hash=*)
          CURRENT_HASH="${ARG#--current-hash=}"
          ;;
      esac
      ;;
    --execution-issue-id|--execution-issue-id=*)
      case "$ARG" in
        --execution-issue-id)
          SKIP_NEXT=1
          ;;
        --execution-issue-id=*)
          EXECUTION_ISSUE_ID="${ARG#--execution-issue-id=}"
          ;;
      esac
      ;;
    *)
      if [ -z "$WORKSPACE_ROOT" ]; then
        WORKSPACE_ROOT="$ARG"
      elif [ -z "$CURRENT_HASH" ]; then
        CURRENT_HASH="$ARG"
      fi
      ;;
  esac
done
if [ -z "$WORKSPACE_ROOT" ]; then
  WORKSPACE_ROOT="${MULTICA_WORKSPACE_ROOT:-}"
fi

DRY_RUN="${DRY_RUN:-false}"

autopilots_kill_switch
autopilots_detect_python || exit 1

# --dry-run / --l1 via env vars (legacy) still work.
if [ -z "$DRY_RUN_ARG" ] && [ "$DRY_RUN" = "true" ]; then
  DRY_RUN_ARG="--dry-run"
fi
if [ -z "$L1_ARG" ] && [ "${ARCH_SWEEP_L1:-false}" = "true" ]; then
  L1_ARG="--l1"
fi

# Determine current worktree hash to skip (env var wins, else derive from PWD).
# The helper falls back to PWD only when MULTICA_WORKTREE_HASH is unset, which
# matches the original two-step fallback here.
if [ -z "$CURRENT_HASH" ]; then
  CURRENT_HASH="$(autopilots_current_hash "$WORKSPACE_ROOT")"
fi

# D8: omit --workspace-root / --current-hash when unknown so the python script
# auto-detects them instead of receiving an empty override.
PY_ARGS=("$SCRIPT_DIR/architecture_sweep.py")
if [ -n "$WORKSPACE_ROOT" ]; then
  PY_ARGS+=(--workspace-root "$WORKSPACE_ROOT")
fi
if [ -n "$CURRENT_HASH" ]; then
  PY_ARGS+=(--current-hash "$CURRENT_HASH")
fi
PY_ARGS+=(${FAST_ARG:-} ${DRY_RUN_ARG:-} ${L1_ARG:-} --execution-issue-id "$EXECUTION_ISSUE_ID" --kill-switch "$KILL_SWITCH")

"$PYTHON_CMD" "${PY_ARGS[@]}"
