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
JUNIT_STABLE_PATH_ARG=""
for ARG in "$@"; do
  if [ -n "$SKIP_NEXT" ]; then
    SKIP_NEXT=""
    # SEE-1460 决策 6' (AC-9): a space-form flag consumes AND captures its
    # value — dropping it here made the autopilot command line silently lose
    # --workspace-root / --current-hash values.
    case "$SKIP_TARGET" in
      workspace-root)
        WORKSPACE_ROOT="$ARG"
        ;;
      current-hash)
        CURRENT_HASH="$ARG"
        ;;
      junit-stable-path)
        JUNIT_STABLE_PATH_ARG="$ARG"
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
      # SEE-1516 F2: dead parameter — the Python layer dropped it too (it was
      # parsed there and never read). This case is a consume-and-drop shim so
      # legacy command lines (SEE-1460 AC-9 space/equals forms) neither lose
      # their positional stream nor leak the flag downstream; the value is
      # intentionally discarded (no branch in the SKIP_TARGET consume case).
      case "$ARG" in
        --execution-issue-id)
          SKIP_NEXT=1
          SKIP_TARGET=execution-issue-id-drop
          ;;
      esac
      ;;
    --junit-stable-path|--junit-stable-path=*)
      case "$ARG" in
        --junit-stable-path)
          SKIP_NEXT=1
          SKIP_TARGET=junit-stable-path
          ;;
        --junit-stable-path=*)
          JUNIT_STABLE_PATH_ARG="${ARG#--junit-stable-path=}"
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
# A missing/unreadable file (e.g. no .gutconfig.json in the patrol repo on the
# Monday-autoactivated L1 path, SEE-1625) yields an EMPTY value so each
# caller's empty-value handling applies; sed's exit-2 on a missing input file
# must not abort the wrapper via set -e/pipefail. Fail-loud contracts for a
# missing kol.json stay owned by sweep_materialize's explicit pre-checks.
sweep_config_value() {
  local key="$1" config_file="$2"
  sed -n "s/^.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*$/\1/p" "$config_file" 2>/dev/null | head -n 1 || true
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

# SEE-1593 §SPEC-001 (route A2): L1 self-produced GUT junit.
#
# The GUT dimension used to read a junit borrowed from a sibling workspace
# slot; the platform reclaims done-issue slots, so the source vanished and the
# dimension went blind (SEE-1593). On an L1 round the patrol now runs a full
# GUT pass in the checkout it is sweeping, so the junit shares the sweep's
# HEAD and depends on nothing GC-volatile.
#
# Failure discipline: this is a best-effort input producer, never a gate.
# Import failure, run failure, timeout and a missing report are each reported
# explicitly on stderr, then the static sweep still runs — the Python layer
# surfaces the missing input (GUT_UNVERIFIED, escalating on repetition) rather
# than the wrapper swallowing the error or aborting the whole patrol.
sweep_gut_timeout() {
  local value="${1:-}" default="${2:-60}"
  case "$value" in
    ''|*[!0-9]*) printf '%s\n' "$default" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

sweep_self_produce_junit() {
  local run_l1=0
  if [ -n "$L1_ARG" ] || [ "$(date -u +%u)" = "1" ]; then
    run_l1=1
  fi
  [ "$run_l1" = "1" ] || return 0
  [ -z "$DRY_RUN_ARG" ] || return 0
  [ -z "$FAST_ARG" ] || return 0
  [ "$KILL_SWITCH" != "true" ] || return 0
  # Paused-file fuse is the canonical machine-level stop (kill_switch.py);
  # skip the write-side GUT batch when it is present.
  if [ -e "${DEV_FORGE_PAUSED_FILE:-$HOME/.multica/toolchain-reports/DISABLED}" ]; then
    return 0
  fi

  local config_file="${ARCH_SWEEP_CONFIG:-$SCRIPT_DIR/configs/kol.json}"
  local repo_name kol_repo
  repo_name="$(sweep_config_value "repo_name" "$config_file")"
  [ -n "$repo_name" ] || return 0
  kol_repo="$(sweep_locate_repo "$repo_name" "$WORKSPACE_ROOT" "$CURRENT_HASH")" || return 0

  # SEE-1593 §SPEC-010 (Final Review HIGH-1): a reused checkout keeps
  # tests/reports/ (gitignored) across rounds, so a previous round's junit
  # would be read back as this round's verification if the batch below fails.
  # Remove stale local products BEFORE any attempt, so every failure/skip exit
  # below — godot missing, timeout missing, import fail, run fail, timeout, no
  # output — leaves the Python layer with no local junit (GUT_UNVERIFIED),
  # never a stale wrong-pass. Covers both timestamp conventions the Python
  # resolver globs (`<stem>_*.xml` and `<base>_*.xml`).
  local junit_rel junit_path reports_dir junit_name
  junit_rel="$(sweep_config_value "junit_xml_file" "$kol_repo/.gutconfig.json")"
  junit_rel="${junit_rel#res://}"
  [ -n "$junit_rel" ] || junit_rel="tests/reports/junit_report.xml"
  junit_path="$kol_repo/$junit_rel"
  reports_dir="$(dirname "$junit_path")"
  junit_name="$(basename "$junit_path")"
  if ! rm -f "$junit_path" \
      "$reports_dir/${junit_name}"_*.xml \
      "$reports_dir/${junit_name%.xml}"_*.xml; then
    echo "[arch-sweep] ERROR: L1 GUT could not remove stale junit under $reports_dir; a stale report could be misread as verified this round (SEE-1593 §SPEC-010)" >&2
  fi

  local godot_bin="${GODOT:-godot}"
  if ! command -v "$godot_bin" >/dev/null 2>&1; then
    echo "[arch-sweep] ERROR: L1 GUT self-production skipped: godot binary not found (GODOT=$godot_bin); GUT dimension will be unverified this round" >&2
    return 0
  fi
  if ! command -v timeout >/dev/null 2>&1; then
    echo "[arch-sweep] ERROR: L1 GUT self-production skipped: 'timeout' not found (timeout guard required); GUT dimension will be unverified this round" >&2
    return 0
  fi

  local import_timeout run_timeout
  import_timeout="$(sweep_gut_timeout "${ARCH_SWEEP_GUT_IMPORT_TIMEOUT_SECONDS:-}" 900)"
  run_timeout="$(sweep_gut_timeout "${ARCH_SWEEP_GUT_TIMEOUT_SECONDS:-}" 3600)"

  local log_dir="${MULTICA_HOME:-$HOME/.multica}/arch-patrol"
  local log="$log_dir/gut-last-run.log"
  if ! mkdir -p "$log_dir"; then
    # LOW-1 (Final Review): surface why the log dir could not be created
    # instead of swallowing it; fall back to /dev/null so the batch can still
    # run and produce a junit.
    echo "[arch-sweep] ERROR: L1 GUT cannot create log dir $log_dir; using /dev/null for the batch log" >&2
    log="/dev/null"
  fi

  echo "[arch-sweep] L1 GUT self-production: repo=$kol_repo import_timeout=${import_timeout}s run_timeout=${run_timeout}s log=$log" >&2

  local rc=0
  timeout -k 10 "$import_timeout" "$godot_bin" --headless --path "$kol_repo" --import >"$log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[arch-sweep] ERROR: L1 GUT import failed (rc=$rc) in $kol_repo; continuing static sweep without a self-produced junit (log: $log)" >&2
    return 0
  fi

  rc=0
  # run_tests.sh cds to the repo root, so run it from anywhere with GODOT set.
  GODOT="$godot_bin" timeout -k 10 "$run_timeout" bash "$kol_repo/tests/run_tests.sh" --all >>"$log" 2>&1 || rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    echo "[arch-sweep] ERROR: L1 GUT run timed out after ${run_timeout}s in $kol_repo; continuing static sweep (log: $log)" >&2
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    echo "[arch-sweep] ERROR: L1 GUT run failed (rc=$rc) in $kol_repo; continuing static sweep (log: $log)" >&2
    return 0
  fi

  if [ -f "$junit_path" ]; then
    echo "[arch-sweep] L1 GUT junit produced: $junit_path" >&2
  else
    echo "[arch-sweep] ERROR: L1 GUT run exited 0 but produced no junit at $junit_path; GUT dimension will be unverified this round (log: $log)" >&2
  fi
  return 0
}

sweep_materialize || exit 1
sweep_self_produce_junit

# D8: omit --workspace-root / --current-hash when unknown so the python script
# auto-detects them instead of receiving an empty override.
PY_ARGS=("$SCRIPT_DIR/architecture_sweep.py")
if [ -n "$WORKSPACE_ROOT" ]; then
  PY_ARGS+=(--workspace-root "$WORKSPACE_ROOT")
fi
if [ -n "$CURRENT_HASH" ]; then
  PY_ARGS+=(--current-hash "$CURRENT_HASH")
fi
PY_ARGS+=(${FAST_ARG:-} ${DRY_RUN_ARG:-} ${L1_ARG:-})
# SEE-1499: forward the explicit stable junit source when provided (an unset
# flag omits it so the Python layer resolves config/env defaults itself).
if [ -n "$JUNIT_STABLE_PATH_ARG" ]; then
  PY_ARGS+=(--junit-stable-path "$JUNIT_STABLE_PATH_ARG")
fi
if [ "$KILL_SWITCH_FROM_ENV" = "1" ]; then
  PY_ARGS+=(--kill-switch "$KILL_SWITCH")
fi

"$PYTHON_CMD" "${PY_ARGS[@]}"
