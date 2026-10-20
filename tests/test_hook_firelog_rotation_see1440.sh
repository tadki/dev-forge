#!/bin/bash
# SEE-1440 §SPEC-025：firelog 尺寸上限轮转单测（hermetic——全部落在 mktemp 临时目录，
# 不触真实 hook-fire.log；HOOK_FIRE_LOG_MAX_BYTES 注入小上限触发轮转）。
# 被测：claude-hooks/scripts/lib/hook-fire-path.lib.sh :: maybe_rotate_hook_fire_log
# Usage: bash tests/test_hook_firelog_rotation_see1440.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT/claude-hooks/scripts/lib/hook-fire-path.lib.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "[PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# T1 未超限：不轮转
F="$T/t1.log"
printf 'line\n' > "$F"
HOOK_FIRE_LOG_MAX_BYTES=1000
maybe_rotate_hook_fire_log "$F"
if [ -f "$F" ] && [ ! -f "$F.1" ]; then
  pass "T1 under limit: no rotation"
else
  fail "T1 under limit: no rotation"
fi

# T2 恰好等于上限：不轮转（仅 > 上限才转）
printf 'x%.0s' $(seq 1 100) > "$F"
HOOK_FIRE_LOG_MAX_BYTES=100
maybe_rotate_hook_fire_log "$F"
if [ -f "$F" ] && [ ! -f "$F.1" ]; then
  pass "T2 at limit: no rotation"
else
  fail "T2 at limit: no rotation"
fi

# T3 超限：旧档整档转存 .1、新档为空、续写落新档
printf 'old-content%.0s' $(seq 1 20) > "$F"   # 220 bytes > 100
maybe_rotate_hook_fire_log "$F"
if [ -f "$F.1" ] && grep -q "old-content" "$F.1" && [ -f "$F" ] && [ ! -s "$F" ]; then
  pass "T3 over limit: rotated to .1, new file empty"
else
  fail "T3 over limit: rotated to .1, new file empty"
fi
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [test] post-rotate append" >> "$F"
if grep -q "post-rotate append" "$F"; then
  pass "T3b append lands in new file (format unchanged)"
else
  fail "T3b append lands in new file (format unchanged)"
fi

# T4 再次超限：.1 被覆盖（磁盘占用有界 2×上限）
printf 'second-gen%.0s' $(seq 1 20) > "$F"
maybe_rotate_hook_fire_log "$F"
if grep -q "second-gen" "$F.1" && ! grep -q "old-content" "$F.1"; then
  pass "T4 re-rotate overwrites .1 (bounded footprint)"
else
  fail "T4 re-rotate overwrites .1 (bounded footprint)"
fi

# T5 fail-open：目录不可写导致 mv 失败 → 返回 0、原档保留、无半成品
RO="$T/ro"
mkdir -p "$RO"
printf 'keep\n' > "$RO/f.log"
chmod 555 "$RO"
RC=0
maybe_rotate_hook_fire_log "$RO/f.log" || RC=$?
chmod 755 "$RO"
if [ "$RC" -eq 0 ] && [ -f "$RO/f.log" ] && [ ! -f "$RO/f.log.1" ]; then
  pass "T5 fail-open on rotation failure (hook chain unblocked)"
else
  fail "T5 fail-open on rotation failure (hook chain unblocked)"
fi

# T6 上限 0 / 非数字：视为不设限（全新文件，避免 T4 遗留 .1 干扰断言）
F6="$T/t6.log"
printf 'x%.0s' $(seq 1 200) > "$F6"
HOOK_FIRE_LOG_MAX_BYTES=0
maybe_rotate_hook_fire_log "$F6"
if [ -s "$F6" ] && [ ! -f "$F6.1" ]; then
  pass "T6 max=0: uncapped"
else
  fail "T6 max=0: uncapped"
fi
# shellcheck disable=SC2034  # 由被 source 的 maybe_rotate_hook_fire_log 读取
HOOK_FIRE_LOG_MAX_BYTES=abc
maybe_rotate_hook_fire_log "$F6"
if [ -s "$F6" ]; then
  pass "T6b non-numeric max: uncapped"
else
  fail "T6b non-numeric max: uncapped"
fi

# T7 文件不存在：no-op
if maybe_rotate_hook_fire_log "$T/missing.log"; then
  pass "T7 missing file: no-op"
else
  fail "T7 missing file: no-op"
fi

# T8 三入口接线核查（防回退：轮调用从写入路径消失即 FAIL）
for s in claude-hooks/hook-wrapper.sh claude-hooks/dispatcher.sh claude-hooks/unified/unified-hook.sh; do
  if grep -q 'maybe_rotate_hook_fire_log "$LOG_FILE"' "$REPO_ROOT/$s"; then
    pass "T8 wired: $s"
  else
    fail "T8 wired: $s"
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  echo "Overall: PASS"
  exit 0
fi
echo "Overall: FAIL"
exit 1
