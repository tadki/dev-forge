#!/bin/bash
# test_push_guard_repo_detection_see526.sh
# Unit tests for push-guard.sh Phase 1 path extraction (SEE-526)
# Covers: git -C, cd &&, no path, -C overrides cd, nonexistent path, edge cases
#
# Related Issue: SEE-526
# Test Type: Unit + Boundary
# Author: Bachi

set -uo pipefail

# Identity isolation (SEE-1069 follow-up): lock to a non-whitelisted agent so
# the suite's result is independent of whoever runs it. The G6-1/G6-2 full-hook
# cases use a master refspec and would otherwise short-circuit to exit 0 under
# the master-push Atlas/Archi whitelist when run by Atlas.
export MULTICA_AGENT_ID="a5c250e8-7257-466e-b45a-03f995c7206c"  # Bachi
export MULTICA_AGENT_NAME="Bachi"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); }

HOOK_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/claude-hooks/scripts/push-guard.sh"

# Extract Phase 1 node script from push-guard.sh
# Lines between 'node -e "' and '" 2>/dev/null)'
PHASE1_NODE=$(sed -n '/PHASE1_OUTPUT=.*node -e "/,/^" 2>\/dev\/null)/p' "$HOOK_SCRIPT" | \
  sed '1s/.*node -e "//' | \
  sed '$s/" 2>\/dev\/null).*$//')

# Run Phase 1 node script with given command, return output
run_phase1() {
  local cmd="$1"
  printf '{"tool_input":{"command":"%s"}}' "$cmd" | node -e "$PHASE1_NODE" 2>/dev/null
}

# Test Phase 1 output for CMD_GIT_ROOT and PUSH_RESULT
# Usage: test_phase1 "label" "command" "expected_root" "expected_result"
test_phase1() {
  local label="$1"
  local cmd="$2"
  local expected_root="$3"
  local expected_result="$4"

  local output
  output=$(run_phase1 "$cmd")

  local actual_root=""
  local actual_result="$output"

  if [[ "$output" == CMD_GIT_ROOT=* ]]; then
    actual_root=$(echo "$output" | head -1 | sed 's/CMD_GIT_ROOT=//')
    actual_result=$(echo "$output" | tail -1)
  fi

  if [ "$actual_result" != "$expected_result" ]; then
    fail "$label — result: got '$actual_result', expected '$expected_result'"
    return 1
  fi

  if [ "$actual_root" != "$expected_root" ]; then
    fail "$label — CMD_GIT_ROOT: got '$actual_root', expected '$expected_root'"
    return 1
  fi

  pass "$label"
}

# Test full hook with a given command, verify exit code
# Usage: test_full "label" "command" "expected_exit"
test_full() {
  local label="$1"
  local cmd="$2"
  local expected_exit="$3"

  local input
  input=$(printf '{"tool_input":{"command":"%s"}}' "$cmd")

  local STDOUT_FILE STDERR_FILE
  STDOUT_FILE=$(mktemp /tmp/push-guard-test-stdout.XXXXXX)
  STDERR_FILE=$(mktemp /tmp/push-guard-test-stderr.XXXXXX)

  echo "$input" | bash "$HOOK_SCRIPT" > "$STDOUT_FILE" 2> "$STDERR_FILE"
  local actual_exit=$?

  rm -f "$STDOUT_FILE" "$STDERR_FILE"

  if [ "$actual_exit" -eq "$expected_exit" ]; then
    pass "$label (exit $expected_exit)"
  else
    fail "$label — exit: got $actual_exit, expected $expected_exit"
  fi
}

echo "============================================"
echo "  SEE-526: push-guard.sh repo detection tests"
echo "  Date: $(date -Iseconds)"
echo "============================================"
echo ""

# --- Group 1: git -C <path> extraction ---
echo -e "${CYAN}--- Group 1: git -C <path> extraction ---${NC}"

test_phase1 "G1-1 git -C /some/path push origin master → /some/path + MASTER_PUSH" \
  "git -C /some/path push origin master" \
  "/some/path" "MASTER_PUSH"

test_phase1 "G1-2 git -C /tmp/repo push origin feature → /tmp/repo + SAFE_PUSH" \
  "git -C /tmp/repo push origin feature" \
  "/tmp/repo" "SAFE_PUSH"

test_phase1 "G1-3 git -C /path/deep/nested push origin main → nested + MASTER_PUSH" \
  "git -C /path/deep/nested push origin main" \
  "/path/deep/nested" "MASTER_PUSH"

# --- Group 2: cd <path> && extraction ---
echo ""
echo -e "${CYAN}--- Group 2: cd <path> && extraction ---${NC}"

test_phase1 "G2-1 cd /some/path && git push origin master → /some/path + MASTER_PUSH" \
  "cd /some/path && git push origin master" \
  "/some/path" "MASTER_PUSH"

test_phase1 "G2-2 cd /tmp/myrepo && git push origin feat-x → /tmp/myrepo + SAFE_PUSH" \
  "cd /tmp/myrepo && git push origin feat-x" \
  "/tmp/myrepo" "SAFE_PUSH"

test_phase1 "G2-3 last cd wins: cd /a && cd /b && git push → /b + SAFE_PUSH" \
  "cd /a && cd /b && git push origin dev" \
  "/b" "SAFE_PUSH"

# --- Group 3: no path (backward compatibility) ---
echo ""
echo -e "${CYAN}--- Group 3: no path (backward compatibility) ---${NC}"

test_phase1 "G3-1 plain git push origin feature-branch → no root + SAFE_PUSH" \
  "git push origin feature-branch" \
  "" "SAFE_PUSH"

test_phase1 "G3-2 plain git push origin master → no root + MASTER_PUSH" \
  "git push origin master" \
  "" "MASTER_PUSH"

test_phase1 "G3-3 plain git push → no root + NO_REFSPEC" \
  "git push" \
  "" "NO_REFSPEC"

# --- Group 4: -C overrides cd ---
echo ""
echo -e "${CYAN}--- Group 4: -C overrides cd ---${NC}"

test_phase1 "G4-1 cd /some && git -C /other push → /other + SAFE_PUSH" \
  "cd /some/path && git -C /other/path push origin dev" \
  "/other/path" "SAFE_PUSH"

test_phase1 "G4-2 cd /a && cd /b && git -C /c push → /c + SAFE_PUSH" \
  "cd /a && cd /b && git -C /c push origin dev" \
  "/c" "SAFE_PUSH"

# --- Group 5: edge cases ---
echo ""
echo -e "${CYAN}--- Group 5: edge cases ---${NC}"

test_phase1 "G5-1 not a git command → no root + NOT_PUSH" \
  "ls -la" \
  "" "NOT_PUSH"

test_phase1 "G5-2 delete push with -C path → /some/path + DELETE_PUSH" \
  "git -C /some/path push origin --delete feature" \
  "/some/path" "DELETE_PUSH"

test_phase1 "G5-3 no refspec with -C path → /some/path + NO_REFSPEC" \
  "git -C /some/path push" \
  "/some/path" "NO_REFSPEC"

test_phase1 "G5-4 empty command → no root + NOT_PUSH" \
  "" \
  "" "NOT_PUSH"

test_phase1 "G5-5 cd without && (not a chained command) → no root + NOT_PUSH" \
  "cd /some/path" \
  "" "NOT_PUSH"

# --- Group 6: SEE-537: HEREDOC false positive prevention ---
echo ""
echo -e "${CYAN}--- Group 6: SEE-537 — HEREDOC false positive prevention ---${NC}"

# Run Phase 1 with raw JSON (supports newlines in command string)
run_phase1_json() {
  local json="$1"
  printf '%s' "$json" | node -e "$PHASE1_NODE" 2>/dev/null
}

test_phase1_json() {
  local label="$1"
  local json="$2"
  local expected_root="$3"
  local expected_result="$4"

  local output
  output=$(run_phase1_json "$json")

  local actual_root=""
  local actual_result="$output"

  if [[ "$output" == CMD_GIT_ROOT=* ]]; then
    actual_root=$(echo "$output" | head -1 | sed 's/CMD_GIT_ROOT=//')
    actual_result=$(echo "$output" | tail -1)
  fi

  if [ "$actual_result" != "$expected_result" ]; then
    fail "$label — result: got '$actual_result', expected '$expected_result'"
    return 1
  fi

  if [ "$actual_root" != "$expected_root" ]; then
    fail "$label — CMD_GIT_ROOT: got '$actual_root', expected '$expected_root'"
    return 1
  fi

  pass "$label"
}

# HEREDOC containing "git push" inside multica comment — must NOT trigger push detection
test_phase1_json "G6-1 multica comment with HEREDOC containing git push → NOT_PUSH" \
  '{"tool_input":{"command":"multica issue comment add abc123 --content-stdin <<'\''EOF'\''\n根因分析：执行 git push 后触发检测\nEOF"}}' \
  "" "NOT_PUSH"

# HEREDOC containing "cd /path && git push" — must NOT trigger push detection
test_phase1_json "G6-2 multica comment with HEREDOC containing cd+git push → NOT_PUSH" \
  '{"tool_input":{"command":"multica issue comment add abc123 --content-stdin <<'\''EOF'\''\n需要先 cd /repo && git push origin main\nEOF"}}' \
  "" "NOT_PUSH"

# cd path && multica comment with HEREDOC containing git push — must NOT trigger
test_phase1_json "G6-3 cd /path && multica comment with HEREDOC git push → NOT_PUSH" \
  '{"tool_input":{"command":"cd /tmp && multica issue comment add abc123 --content-stdin <<'\''EOF'\''\n请执行 git push\nEOF"}}' \
  "/tmp" "NOT_PUSH"

# multica comment without HEREDOC — unchanged behavior
test_phase1 "G6-4 multica comment without HEREDOC → NOT_PUSH" \
  "multica issue comment add abc123 --content \"Hello world\"" \
  "" "NOT_PUSH"

# Actual git push with HEREDOC in its content — still detected as push (edge case)
# Note: this is a theoretical case; in practice git push doesn't use HEREDOCs
test_phase1_json "G6-5 real git push (no HEREDOC) still detected → SAFE_PUSH" \
  '{"tool_input":{"command":"git push origin feature-branch"}}' \
  "" "SAFE_PUSH"

# --- Group 7: integration — full hook with nonexistent CMD_GIT_ROOT ---
echo ""
echo -e "${CYAN}--- Group 6: integration — fallback on invalid path ---${NC}"

# Non-existent path should fall through Phase 3 to 'no git repo found' (exit 2)
# Must run from a non-git directory so PWD fallback also fails
G6_TMPDIR=$(mktemp -d)
# SEE-1440: plant an interfering sibling repo (git repo WITHOUT .claude/hooks).
# The level-4 PWD scan must NOT attribute the push to it — ownership marker is
# the gate, so the fallback still ends in the no-repo path (exit 2).
# §SPEC-022 硬化（Harti）：sibling 必须是**合法可推仓**（含 master 提交且与
# origin/master 同步），且 bare origin 必须放在 G6_TMPDIR **之外**——变异（无
# 归属校验）下 L4 扫描会按字典序采纳子目录：空仓或 bare 仓被采纳仍经 Check-3
# currency 失败得到同码 exit 2 掩盖误归属；合法 worktree 仓被采纳时 push 放行
# （exit 0），与期望 exit 2 硬冲突，归属校验回归可判定。
git init -q -b master "$G6_TMPDIR/noise-sibling"
git -C "$G6_TMPDIR/noise-sibling" -c user.email=t@t -c user.name=t \
  commit -q --allow-empty -m init
G6_ORIGIN=$(mktemp -d "${G6_TMPDIR}.origin.XXXXXX")
git init -q --bare "$G6_ORIGIN/origin.git"
git -C "$G6_TMPDIR/noise-sibling" remote add origin "$G6_ORIGIN/origin.git"
git -C "$G6_TMPDIR/noise-sibling" -c user.email=t@t -c user.name=t \
  push -q -u origin master

test_full_g6() {
  local label="$1"
  local cmd="$2"
  local expected_exit="$3"

  local input
  input=$(printf '{"tool_input":{"command":"%s"}}' "$cmd")

  local STDOUT_FILE STDERR_FILE
  STDOUT_FILE=$(mktemp /tmp/push-guard-test-stdout.XXXXXX)
  STDERR_FILE=$(mktemp /tmp/push-guard-test-stderr.XXXXXX)

  # Isolate inherited agent env (TARGET_REPO_ROOT/PROJECT_ROOT point at real
  # checkouts on dev machines) so the fallback path is what actually runs.
  (cd "$G6_TMPDIR" && unset TARGET_REPO_ROOT PROJECT_ROOT GIT_ROOT && \
    echo "$input" | bash "$HOOK_SCRIPT" > "$STDOUT_FILE" 2> "$STDERR_FILE")
  local actual_exit=$?

  rm -f "$STDOUT_FILE" "$STDERR_FILE"

  if [ "$actual_exit" -eq "$expected_exit" ]; then
    pass "$label (exit $expected_exit)"
  else
    fail "$label — exit: got $actual_exit, expected $expected_exit"
  fi
}

test_full_g6 "G6-1 nonexistent -C path falls back (non-git PWD) → exit 2" \
  "git -C /nonexistent/path/push/guard/test push origin master" \
  2

test_full_g6 "G6-2 nonexistent cd path falls back (non-git PWD) → exit 2" \
  "cd /nonexistent/path/push/guard/test && git push origin master" \
  2

rm -rf "$G6_TMPDIR" "$G6_ORIGIN"

# --- Summary ---
echo ""
echo "============================================"
echo -e "${CYAN}Results:${NC} ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "============================================"

if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}Overall: PASS${NC}"
  exit 0
else
  echo -e "${RED}Overall: FAIL ($FAIL failures)${NC}"
  exit 1
fi
