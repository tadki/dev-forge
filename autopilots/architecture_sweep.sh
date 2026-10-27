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
SKIP_TARGET=""
EXECUTION_ISSUE_ID=""
for ARG in "$@"; do
  if [ -n "$SKIP_NEXT" ]; then
    SKIP_NEXT=""
    # SEE-1460 决策 6' (AC-9): a space-form flag consumes AND captures its
    # value — dropping it here made the autopilot command line silently lose
    # --execution-issue-id / --workspace-root / --current-hash values.
    case "$SKIP_TARGET" in
      workspace-root)
        WORKSPACE_ROOT="$ARG"
        ;;
      current-hash)
        CURRENT_HASH="$ARG"
        ;;
      execution-issue-id)
        EXECUTION_ISSUE_ID="$ARG"
        ;;
    esac
    SKIP_TARGET=""
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
          SKIP_TARGET=workspace-root
          ;;
        --workspace-root=*)
          WORKSPACE_ROOT="${ARG#--workspace-root=}"
          ;;
        --current-hash)
          SKIP_NEXT=1
          SKIP_TARGET=current-hash
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
          SKIP_TARGET=execution-issue-id
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

# SEE-1460 决策 6' (AC-8, Revy F-1): capture whether KILL_SWITCH came from the
# environment BEFORE autopilots_kill_switch applies its default. The flag is
# only forwarded when explicitly set; an unset env omits --kill-switch so the
# Python layer's kill_switch_default() (kill_switch.py single source: paused
# file OR env) resolves the canonical value — an unconditional flag overrode
# the paused-file contract on this entry point.
KILL_SWITCH_FROM_ENV=0
if [ -n "${KILL_SWITCH+x}" ]; then
  KILL_SWITCH_FROM_ENV=1
fi

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

# SEE-1460: SOP-side submodule materialization (SEE-1434 decision 1, wrapper
# shell layer). The Python sweep stays read-only — its unmaterialized-gitlink
# skip guard is the in-script fallback; this wrapper owns the one write-side
# action: materialize the redline gitlink before sweeping. Any failure here is
# fatal (non-zero + explicit error): silently continuing would reintroduce the
# zero-coverage `redline=skipped_uninitialized` state the guard surfaces.

# Read a quoted string value from the patrol config by key. Shell-side (sed)
# on purpose: wrapper setup must not depend on a Python one-liner, and the
# config is repo-owned with single-line string values.
sweep_config_value() {
  local key="$1" config_file="$2"
  sed -n "s/^.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*$/\1/p" "$config_file" | head -n 1
}

# Mirror architecture_sweep.py _locate_repo_root: hash-slot layouts, direct
# workspace layouts, CWD walk-up, then a scan of workspace_root slots — all
# keyed by the config's repo_name (nothing hardcoded).
sweep_locate_repo() {
  local repo_name="$1" root="$2" hash="$3" dir parent cand
  local -a cands=()
  if [ -n "$root" ]; then
    if [ -n "$hash" ]; then
      cands+=("$root/$hash/workdir/$repo_name" "$root/$hash/$repo_name")
    fi
    cands+=("$root/workdir/$repo_name" "$root/$repo_name")
  fi
  dir="$PWD"
  while :; do
    if [ -d "$dir/$repo_name" ]; then
      cands+=("$dir/$repo_name")
    fi
    parent="$(dirname "$dir")"
    if [ "$parent" = "$dir" ]; then
      break
    fi
    dir="$parent"
  done
  for cand in "${cands[@]}"; do
    if [ -d "$cand" ]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  if [ -n "$root" ] && [ -d "$root" ]; then
    for dir in "$root"/*/; do
      if [ -d "${dir}workdir/$repo_name" ]; then
        printf '%s\n' "${dir}workdir/$repo_name"
        return 0
      fi
      if [ -d "${dir}$repo_name" ]; then
        printf '%s\n' "${dir}$repo_name"
        return 0
      fi
    done
  fi
  return 1
}

# Derive the Multica platform mirror-cache directory name for a repo URL
# (SEE-1482): scheme/user stripped, ':' and '/' folded to '+', e.g.
#   https://github.com/tadki/godot-mcp.git -> github.com+tadki+godot-mcp.git
# Local path URLs map by the same rule and simply will not exist in the
# cache, which fails loudly in sweep_find_mirror instead of guessing.
sweep_mirror_name() {
  printf '%s\n' "$1" |
    sed -E -e 's#^(https?|ssh|git|file)://##' -e 's#^[^@/]+@##' -e 's#:#+#g' -e 's#/#+#g'
}

# Locate a bare mirror of the given URL inside the platform mirror cache,
# layout <root>/<workspace-id>/<mirror-name>. ARCH_SWEEP_MIRROR_ROOT
# overrides the root (tests/ops); the defaults are the daemon layout
# ($MULTICA_TASK_WORKSPACES_ROOT/.repos) first, the documented alternate
# (~/.multica/workspaces/.repos) second. Prints the path; non-zero when none.
sweep_find_mirror() {
  local url="$1" name root cand
  local -a roots=()
  name="$(sweep_mirror_name "$url")"
  if [ -z "$name" ]; then
    return 1
  fi
  if [ -n "${ARCH_SWEEP_MIRROR_ROOT:-}" ]; then
    roots+=("$ARCH_SWEEP_MIRROR_ROOT")
  else
    roots+=("${MULTICA_TASK_WORKSPACES_ROOT:-$HOME/multica_workspaces}/.repos" "$HOME/.multica/workspaces/.repos")
  fi
  for root in "${roots[@]}"; do
    if [ -n "${MULTICA_WORKSPACE_ID:-}" ]; then
      cand="$root/$MULTICA_WORKSPACE_ID/$name"
      if [ -d "$cand" ]; then
        printf '%s\n' "$cand"
        return 0
      fi
    fi
    cand="$(find "$root" -mindepth 2 -maxdepth 2 -type d -name "$name" -print -quit 2>/dev/null)"
    if [ -n "$cand" ]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

sweep_materialize() {
  local repo_name redline_dir kol_repo sub_url mirror
  local config_file="${ARCH_SWEEP_CONFIG:-$SCRIPT_DIR/configs/kol.json}"
  if [ ! -f "$config_file" ]; then
    echo "{\"error\": \"arch-sweep wrapper: patrol config not found: $config_file (cannot resolve repo_name for submodule materialization)\"}" >&2
    return 1
  fi
  repo_name="$(sweep_config_value "repo_name" "$config_file")"
  if [ -z "$repo_name" ]; then
    echo "{\"error\": \"arch-sweep wrapper: repo_name missing/unreadable in $config_file (cannot locate patrol repo for submodule materialization)\"}" >&2
    return 1
  fi
  redline_dir="$(sweep_config_value "redline_dir" "$config_file")"
  kol_repo="$(sweep_locate_repo "$repo_name" "$WORKSPACE_ROOT" "$CURRENT_HASH")" || {
    echo "{\"error\": \"arch-sweep wrapper: cannot locate $repo_name worktree for submodule materialization (searched workspace root, CWD walk-up, slot scan); refusing a redline sweep with an unmaterialized gitlink\"}" >&2
    return 1
  }
  if git -C "$kol_repo" submodule update --init --recursive; then
    :
  else
    # SEE-1482: agent shells can cut direct git-over-HTTPS at the TLS egress
    # layer (gnutls_handshake failure with TCP fine), so retry ONCE through
    # the platform mirror cache. The insteadOf rewrite is scoped to THIS git
    # invocation (never global config, never .gitmodules), and the checkout
    # stays content-addressed to the pinned gitlink — a mirror missing the
    # pinned commit fails the update rather than passing.
    sub_url="$(git -C "$kol_repo" config -f .gitmodules --get "submodule.$redline_dir.url" || true)"
    if ! mirror="$(sweep_find_mirror "${sub_url:-}")"; then
      mirror=""
    fi
    if [ -z "$mirror" ]; then
      echo "{\"error\": \"arch-sweep wrapper: direct git submodule update failed in $kol_repo and no platform mirror fallback was found for the redline submodule; refusing a redline sweep with an unmaterialized gitlink (SEE-1482)\"}" >&2
      return 1
    fi
    # protocol.file.allow: the mirror is a daemon-owned LOCAL bare repo, and
    # git >= 2.38.1 default-denies file transport for (indirect) submodule
    # clones — without this scoped override the fallback dies on any machine
    # whose global config doesn't relax it. Scoped to THIS invocation only.
    if ! git -C "$kol_repo" -c "url.$mirror.insteadOf=$sub_url" -c protocol.file.allow=always submodule update --init --recursive; then
      echo "{\"error\": \"arch-sweep wrapper: git submodule update --init --recursive failed in $kol_repo (direct and platform-mirror fallback both failed); failing explicitly instead of silently skipping redline coverage (SEE-1460)\"}" >&2
      return 1
    fi
  fi
  # Post-check mirrors the Python guard's materialized criterion (and the
  # manifest's `.git` exclusion, SEE-1289 HIGH-1): the redline dir must hold
  # content beyond the gitdir pointer, so a no-op "success" can never pass.
  # Runs on BOTH the direct and the mirror-fallback path (SEE-1482).
  if [ -n "$redline_dir" ] && [ -z "$(find "$kol_repo/$redline_dir" -mindepth 1 -maxdepth 1 -not -name .git -print -quit 2>/dev/null)" ]; then
    echo "{\"error\": \"arch-sweep wrapper: submodule update succeeded but $redline_dir is still empty in $kol_repo (gitlink materialized nothing); refusing a zero-coverage sweep\"}" >&2
    return 1
  fi
}

sweep_materialize || exit 1

# D8: omit --workspace-root / --current-hash when unknown so the python script
# auto-detects them instead of receiving an empty override.
PY_ARGS=("$SCRIPT_DIR/architecture_sweep.py")
if [ -n "$WORKSPACE_ROOT" ]; then
  PY_ARGS+=(--workspace-root "$WORKSPACE_ROOT")
fi
if [ -n "$CURRENT_HASH" ]; then
  PY_ARGS+=(--current-hash "$CURRENT_HASH")
fi
PY_ARGS+=(${FAST_ARG:-} ${DRY_RUN_ARG:-} ${L1_ARG:-} --execution-issue-id "$EXECUTION_ISSUE_ID")
if [ "$KILL_SWITCH_FROM_ENV" = "1" ]; then
  PY_ARGS+=(--kill-switch "$KILL_SWITCH")
fi

"$PYTHON_CMD" "${PY_ARGS[@]}"
