#!/bin/bash
# test_hook_registration_see270.sh — v2 终态重写（SEE-1330 P4 收敛批）
# 原版断言 v1 散装注册（11 alias wrapper 行）；P4 收敛后注册契约 =
# 9 时点仅存 unified-hook（matcher `*`）、v1 wrapper 行清零。
# 注册清单真源 = .claude/hooks/hooks-registration.json（installer §9a 完整性探针承接部署面）。
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0
pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); }
separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SETTINGS="${SEE270_SETTINGS:-$HOME/.claude/settings.json}"
if [ ! -f "$SETTINGS" ]; then SETTINGS="${SEE270_SETTINGS_FIXTURE:-}"; fi
if [ -z "$SETTINGS" ] || [ ! -f "$SETTINGS" ]; then
  echo "settings.json 不可用（未找到 $HOME/.claude/settings.json 且未注入 SEE270_SETTINGS_FIXTURE）" >&2
  exit 1
fi

EXPECTED_HOOK_POINTS=(PreToolUse PostToolUse SessionStart SessionEnd Stop SubagentStop UserPromptSubmit Notification PreCompact)

separator "1. unified-hook 9 时点注册完整性"
for hp in "${EXPECTED_HOOK_POINTS[@]}"; do
  if jq -e --arg hp "$hp" '.hooks[$hp][] | select(.matcher=="*") | .hooks[] | select(.command | contains("unified-hook"))' "$SETTINGS" >/dev/null 2>&1; then
    pass "$hp: unified-hook 注册在位（matcher *）"
  else
    fail "$hp: unified-hook 注册缺失"
  fi
done

separator "2. v1 wrapper 注册行清零（P4 终态）"
V1_ALIASES=(skill-check skill-check-post mention-check push-guard tscn-tres-guard gdformat-gdlint atlas-taskflow-mark-a atlas-taskflow-mark-b atlas-taskflow-exit-reminder auto-pr repo-checkout)
V1_LEFT=0
for alias in "${V1_ALIASES[@]}"; do
  # v1 行形态 = hook-wrapper.sh <HookPoint> <alias>（alias 为命令末段）
  if jq -e --arg a "$alias" '[.hooks[][] | .command?] // [] | map(select(type=="string" and endswith(" " + $a))) | length > 0' "$SETTINGS" >/dev/null 2>&1 \
     || grep -qE "hook-wrapper\.sh [A-Za-z]+ $alias( |\"|$)" "$SETTINGS"; then
    fail "v1 alias 残留注册: $alias"
    V1_LEFT=$((V1_LEFT+1))
  fi
done
[ "$V1_LEFT" -eq 0 ] && pass "11 个 v1 alias 注册行全部清零"

separator "3. 注册清单真源存在性"
if [ -f "$REPO_ROOT/hooks/hooks-registration.json" ]; then
  pass "hooks-registration.json 在位（逐时点比对由 installer §9a 完整性探针承接）"
else
  fail "hooks-registration.json 不存在"
fi

separator "SUMMARY"
echo -e "  Pass: $PASS  Fail: $FAIL"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
