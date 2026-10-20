#!/bin/bash
# §SPEC-022 hardening (SEE-1440 / §SPEC-013, fingerprint ee57f95b522c):
# autopilots/lib/common_env.sh 的 env→flag 换算语义此前无任何自动化守护
#（既有 wrapper 级用例仅走 DRY_RUN 一条路径且网络失败时静默跳过）。本套件
# 直接 source 单源并钉扎各 helper 的精确语义：
#   - autopilots_flag_if_true   仅精确 "true" 换算（TRUE/1/空 不换算）
#   - autopilots_dry_run_pair   true→--dry-run / false→--no-dry-run / 其他→空
#   - autopilots_kill_switch    显式 env 优先，缺省 false
#   - autopilots_current_hash   env 优先，PWD 回落首段，域外为空
# 换算分支反转/字面量漂移的变异会被对应断言击杀。Hermetic：临时目录，无网络。
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/autopilots/lib/common_env.sh"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
check() { # label expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — got '$3', expected '$2'"; fi
}

[ -f "$LIB" ] || { echo "lib missing: $LIB"; exit 1; }
# shellcheck source=../autopilots/lib/common_env.sh
source "$LIB"

# --- autopilots_flag_if_true：精确 "true" 字面量 ---
check "flag_if_true exact true converts"        "--json" "$(autopilots_flag_if_true --json true)"
check "flag_if_true false stays empty"          ""       "$(autopilots_flag_if_true --json false)"
check "flag_if_true TRUE stays empty (literal)" ""       "$(autopilots_flag_if_true --json TRUE)"
check "flag_if_true 1 stays empty"              ""       "$(autopilots_flag_if_true --json 1)"
check "flag_if_true empty stays empty"          ""       "$(autopilots_flag_if_true --json '')"

# --- autopilots_dry_run_pair：三态换算 ---
check "dry_run_pair true → --dry-run"       "--dry-run"     "$(autopilots_dry_run_pair true)"
check "dry_run_pair false → --no-dry-run"   "--no-dry-run"  "$(autopilots_dry_run_pair false)"
check "dry_run_pair other → empty"          ""              "$(autopilots_dry_run_pair yes)"
check "dry_run_pair empty → empty"          ""              "$(autopilots_dry_run_pair '')"

# --- autopilots_kill_switch：显式 env 优先 / 缺省 false ---
check "kill_switch default false" "false" "$(KILL_SWITCH=; autopilots_kill_switch; printf '%s' "$KILL_SWITCH")"
check "kill_switch env passthrough" "true" "$(KILL_SWITCH=true; autopilots_kill_switch; printf '%s' "$KILL_SWITCH")"

# --- autopilots_detect_python ---
out=$(autopilots_detect_python >/dev/null 2>&1; printf '%s' "${PYTHON_CMD:-}")
case "$out" in
  python3|python) pass "detect_python resolves an interpreter ($out)" ;;
  *) fail "detect_python resolves an interpreter — got '$out'" ;;
esac

# --- autopilots_current_hash：env 优先 / PWD 回落 / 域外空 ---
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/ws/abc123/workdir"
check "current_hash env override" "deadbeef" "$(
  cd "$TMP/ws/abc123/workdir" &&
  MULTICA_WORKTREE_HASH=deadbeef autopilots_current_hash "$TMP/ws")"
check "current_hash PWD fallback first segment" "abc123" "$(
  cd "$TMP/ws/abc123/workdir" &&
  unset MULTICA_WORKTREE_HASH && autopilots_current_hash "$TMP/ws")"
check "current_hash outside root empty" "" "$(
  cd "$TMP" &&
  unset MULTICA_WORKTREE_HASH && autopilots_current_hash "$TMP/ws")"
check "current_hash no args outside → empty" "" "$(
  cd "$TMP" && unset MULTICA_WORKTREE_HASH && autopilots_current_hash)"

echo ""
echo "============================================"
echo "Results: $PASS passed, $FAIL failed"
echo "============================================"
if [ "$FAIL" -eq 0 ]; then
  echo "Overall: PASS"
  exit 0
else
  echo "Overall: FAIL ($FAIL failures)"
  exit 1
fi
