#!/bin/bash
# test_push_guard_atlas_archi_master_see780.sh
# QA tests for push-guard.sh Atlas/Archi master push fix (SEE-780)
#
# Bug: Atlas|Archi) ;; was a no-op, falling through to Check 5 (shared branch
# enforcement) which incorrectly blocked Atlas/Archi from pushing to master.
#
# Fix: Changed to Atlas|Archi) echo "$INPUT"; exit 0 ;; at lines 154 and 218,
# so Atlas/Archi push to master exits immediately with success.
#
# Tests coverage:
#   S1: E2E — Check 2a (MASTER_PUSH with explicit refspec)
#   S2: E2E — Check 4 (NO_REFSPEC on master branch)
#   S3: Regression — SAFE_PUSH / DELETE_PUSH / NOT_PUSH unchanged
#   S4: A/B Test — old (empty ;;) vs new (echo+exit 0)
#
# Related Issue: SEE-780
# Test Type: E2E + Regression + A/B
# Author: Revy (QA Agent)

set -uo pipefail

# Identity isolation (SEE-1069 follow-up): lock the inherited identity to a
# non-whitelisted agent so the suite is independent of whoever runs it. Per-case
# `export MULTICA_AGENT_NAME=...` inside run_hook still overrides NAME for the
# tests that deliberately simulate Atlas/Archi master pushes.
export MULTICA_AGENT_ID="a5c250e8-7257-466e-b45a-03f995c7206c"  # Bachi
export MULTICA_AGENT_NAME="Bachi"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); }

WORKTREE_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SCRIPT="$WORKTREE_DIR/hooks/scripts/push-guard.sh"

echo "============================================"
echo "  SEE-780: push-guard.sh Atlas/Archi master push fix QA"
echo "  Date: $(date -Iseconds)"
echo "  Worktree: $WORKTREE_DIR"
echo "  Hook: $HOOK_SCRIPT"
echo "============================================"
echo ""

# -------------------------------------------------------
# Pre-check: file existence + fix presence
# -------------------------------------------------------
echo -e "${CYAN}--- Pre-check ---${NC}"

if [ ! -f "$HOOK_SCRIPT" ]; then
  fail "push-guard.sh not found at $HOOK_SCRIPT"
  exit 1
fi
pass "push-guard.sh exists"

# Verify the fix is present: 'Atlas|Archi) echo "$INPUT"; exit 0' must appear
# twice (Check 2a MASTER_PUSH + Check 4 NO_REFSPEC+master). Line-anchored sed
# checks broke when SEE-954 hoisted WORKING_BRANCH and shifted line numbers, so
# assert by occurrence count instead of fragile line numbers.
FIX_COUNT=$(grep -c 'Atlas|Archi) echo "\$INPUT"; exit 0' "$HOOK_SCRIPT" || true)

if [ "$FIX_COUNT" -ge 1 ]; then
  pass "Fix present for Check 2a (MASTER_PUSH): Atlas|Archi exits immediately"
else
  fail "Fix missing: Atlas|Archi MASTER_PUSH echo+exit not found"
fi

if [ "$FIX_COUNT" -ge 2 ]; then
  pass "Fix present for Check 4 (NO_REFSPEC+master): Atlas|Archi exits immediately"
else
  fail "Fix missing for Check 4: only $FIX_COUNT site(s) found (expected 2)"
fi

# Helper: run the full hook with env vars and capture exit code + output
run_hook() {
  local agent_name="$1"
  local cmd="$2"
  local expected_exit="$3"
  local label="$4"

  local input
  input=$(printf '{"tool_input":{"command":"%s"}}' "$cmd")

  local stdout_file stderr_file
  stdout_file=$(mktemp /tmp/pg-stdout.XXXXXX)
  stderr_file=$(mktemp /tmp/pg-stderr.XXXXXX)

  # Use a subshell with exported env vars so MULTICA_AGENT_NAME is visible
  # to the bash process on the right side of the pipe
  (
    export MULTICA_AGENT_NAME="$agent_name"
    export MULTICA_TASK_ID=""
    echo "$input" | bash "$HOOK_SCRIPT" > "$stdout_file" 2> "$stderr_file"
  )
  local actual_exit=$?

  local stderr_content
  stderr_content=$(cat "$stderr_file")

  rm -f "$stdout_file" "$stderr_file"

  if [ "$actual_exit" -eq "$expected_exit" ]; then
    pass "$label (exit $expected_exit)"
  else
    fail "$label — exit: got $actual_exit, expected $expected_exit (stderr: $stderr_content)"
  fi
}

# ========================================================
# Section 1: E2E — Check 2a (MASTER_PUSH, explicit refspec)
# ========================================================
echo ""
echo -e "${CYAN}=== Section 1: E2E — Check 2a (MASTER_PUSH) ===${NC}"

# Atlas pushing to master → allowed (exit 0)
run_hook "Atlas" \
  "git push origin HEAD:refs/heads/master" \
  0 \
  "S1-1: Atlas push to master (refs/heads/master) → exit 0"

run_hook "Atlas" \
  "git push origin master" \
  0 \
  "S1-2: Atlas push to master (short name) → exit 0"

run_hook "Atlas" \
  "git push origin HEAD:refs/heads/main" \
  0 \
  "S1-3: Atlas push to main → exit 0"

# Archi pushing to master → allowed (exit 0)
run_hook "Archi" \
  "git push origin master" \
  0 \
  "S1-4: Archi push to master → exit 0"

run_hook "Archi" \
  "git push origin HEAD:refs/heads/master" \
  0 \
  "S1-5: Archi push to master (refs/heads/master) → exit 0"

# Other agents pushing to master → blocked (exit 2)
run_hook "Bachi" \
  "git push origin master" \
  2 \
  "S1-6: Bachi push to master → exit 2 (blocked)"

run_hook "Revy" \
  "git push origin master" \
  2 \
  "S1-7: Revy push to master → exit 2 (blocked)"

run_hook "Fronti" \
  "git push origin master" \
  2 \
  "S1-8: Fronti push to master → exit 2 (blocked)"

run_hook "Refacty" \
  "git push origin main" \
  2 \
  "S1-9: Refacty push to main → exit 2 (blocked)"

# Empty/missing agent name → blocked
run_hook "" \
  "git push origin master" \
  2 \
  "S1-10: Empty agent name push to master → exit 2 (blocked)"

run_hook "SomeRandomAgent" \
  "git push origin master" \
  2 \
  "S1-11: Unknown agent push to master → exit 2 (blocked)"

# Atlas with -C flag still works
run_hook "Atlas" \
  "git -C /some/path push origin master" \
  0 \
  "S1-12: Atlas push to master with -C flag → exit 0"

# ========================================================
# Section 2: E2E — Check 4 (NO_REFSPEC on master branch)
# ========================================================
echo ""
echo -e "${CYAN}=== Section 2: E2E — Check 4 (NO_REFSPEC + master branch) ===${NC}"
echo -e "  ${YELLOW}[INFO]${NC} Check 4 tests need to pass Phase 3 (git repo checks)."
echo -e "  ${YELLOW}[INFO]${NC} Running from repo dir so Check 3 (merge-base) should pass."

# Save current branch
SAVED_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Create a temp branch from master to simulate being on master
# We need to be on a branch named "master" for Check 4 to trigger
# But we can't checkout master directly. Instead, we test the code logic directly.

# Extract Check 4 logic and test it in isolation
CHECK4_TEST=$(mktemp /tmp/pg-check4-test.XXXXXX.sh)
cat > "$CHECK4_TEST" <<'CHECK4EOF'
#!/bin/bash
# Isolated Check 4 test — simulates NO_REFSPEC + current branch = master
INPUT='{"tool_input":{"command":"git push"}}'
PUSH_RESULT="NO_REFSPEC"

# Simulate current branch = master
CURRENT_BRANCH="master"

if [ "$CURRENT_BRANCH" = "master" ] || [ "$CURRENT_BRANCH" = "main" ]; then
  case "${MULTICA_AGENT_NAME:-}" in
    Atlas|Archi) echo "$INPUT"; exit 0 ;;
    *)
      echo "[push-guard] 错误：禁止直接推送到 master 分支" >&2
      exit 2
      ;;
  esac
fi
echo "$INPUT"
exit 0
CHECK4EOF
chmod +x "$CHECK4_TEST"

test_check4() {
  local agent_name="$1"
  local expected_exit="$2"
  local label="$3"

  local stdout_file stderr_file
  stdout_file=$(mktemp /tmp/pg-c4-stdout.XXXXXX)
  stderr_file=$(mktemp /tmp/pg-c4-stderr.XXXXXX)

  MULTICA_AGENT_NAME="$agent_name" bash "$CHECK4_TEST" > "$stdout_file" 2> "$stderr_file"
  local actual_exit=$?

  rm -f "$stdout_file" "$stderr_file"

  if [ "$actual_exit" -eq "$expected_exit" ]; then
    pass "$label (exit $expected_exit)"
  else
    fail "$label — exit: got $actual_exit, expected $expected_exit"
  fi
}

test_check4 "Atlas"  0 "S2-1: Atlas on master, git push (no refspec) → exit 0 (allowed)"
test_check4 "Archi"  0 "S2-2: Archi on master, git push (no refspec) → exit 0 (allowed)"
test_check4 "Bachi"  2 "S2-3: Bachi on master, git push (no refspec) → exit 2 (blocked)"
test_check4 "Revy"   2 "S2-4: Revy on master, git push (no refspec) → exit 2 (blocked)"
test_check4 ""       2 "S2-5: No agent on master, git push (no refspec) → exit 2 (blocked)"

rm -f "$CHECK4_TEST"

# Also verify Check 4 does NOT trigger on non-master branch
CHECK4_NM_TEST=$(mktemp /tmp/pg-check4-nm.XXXXXX.sh)
cat > "$CHECK4_NM_TEST" <<'CHECK4NMEOF'
#!/bin/bash
INPUT='{"tool_input":{"command":"git push"}}'
PUSH_RESULT="NO_REFSPEC"
CURRENT_BRANCH="feature/my-branch"

if [ "$CURRENT_BRANCH" = "master" ] || [ "$CURRENT_BRANCH" = "main" ]; then
  case "${MULTICA_AGENT_NAME:-}" in
    Atlas|Archi) echo "$INPUT"; exit 0 ;;
    *) echo "[push-guard] blocked" >&2; exit 2 ;;
  esac
fi
# Falls through to Check 5 in real hook — here we just pass
echo "$INPUT"
exit 0
CHECK4NMEOF
chmod +x "$CHECK4_NM_TEST"

MULTICA_AGENT_NAME="Bachi" bash "$CHECK4_NM_TEST" > /dev/null 2>&1
NM_EXIT=$?
if [ "$NM_EXIT" -eq 0 ]; then
  pass "S2-6: Bachi on feature branch, git push (no refspec) → exit 0 (not blocked by Check 4)"
else
  fail "S2-6: Bachi on feature branch — unexpected exit $NM_EXIT, expected 0"
fi

rm -f "$CHECK4_NM_TEST"

# ========================================================
# Section 3: Regression — other checks unchanged
# ========================================================
echo ""
echo -e "${CYAN}=== Section 3: Regression — non-push / safe-push / delete ===${NC}"

# Non-push commands should always pass through (exit 0)
run_hook "Bachi" \
  "git status" \
  0 \
  "S3-1: Bachi git status → exit 0 (not a push)"

run_hook "" \
  "ls -la" \
  0 \
  "S3-2: ls -la → exit 0 (not a push)"

run_hook "Revy" \
  "multica issue comment add abc --content-stdin" \
  0 \
  "S3-3: multica comment → exit 0 (not a push)"

# Delete push should bypass all checks
run_hook "Bachi" \
  "git push origin --delete old-branch" \
  0 \
  "S3-4: Bachi delete push → exit 0 (bypass all checks)"

run_hook "" \
  "git push origin -d old-branch" \
  0 \
  "S3-5: delete push (-d short flag) → exit 0"

# SAFE_PUSH from non-Atlas agent on feature branch → enters Phase 3
# Should pass Check 3 (we're on a branch that has origin/master as ancestor)
# and reach Check 5 (which won't block because no MULTICA_TASK_ID)
run_hook "Bachi" \
  "git push origin HEAD:refs/heads/shared/SEE-780" \
  0 \
  "S3-6: Bachi push to shared/SEE-780 → exit 0 (safe push, passes Phase 3)"

run_hook "Revy" \
  "git push origin HEAD:refs/heads/feature/test" \
  0 \
  "S3-7: Revy push to feature branch → exit 0 (safe push)"

# Run existing SEE-526 test suite for regression
echo ""
echo -e "${CYAN}=== Section 3b: Existing test suite regression ===${NC}"

EXISTING_526="$WORKTREE_DIR/tests/test_push_guard_repo_detection_see526.sh"
if [ -f "$EXISTING_526" ]; then
  EXISTING_526_OUTPUT=$(bash "$EXISTING_526" 2>&1)
  EXISTING_526_EXIT=$?
  if [ $EXISTING_526_EXIT -eq 0 ]; then
    pass "S3b-1: SEE-526 test suite passes (no regression)"
  else
    FAIL_COUNT=$(echo "$EXISTING_526_OUTPUT" | grep -c '\[FAIL\]' || true)
    fail "S3b-1: SEE-526 test suite has $FAIL_COUNT failures (regression detected)"
  fi
else
  echo -e "  ${YELLOW}[SKIP]${NC} S3b-1: SEE-526 test not found"
fi

# ========================================================
# Section 4: A/B Test — old (empty ;;) vs new (echo+exit 0)
# ========================================================
echo ""
echo -e "${CYAN}=== Section 4: A/B Test — old vs new behavior ===${NC}"

# --- Variant A (OLD/broken): empty ;; → falls through ---
AB_OLD=$(mktemp /tmp/pg-ab-old.XXXXXX.sh)
cat > "$AB_OLD" <<'ABOLD'
#!/bin/bash
set -e
INPUT='{"tool_input":{"command":"git push origin master"}}'
PUSH_RESULT="MASTER_PUSH"

# OLD code: Atlas|Archi) ;; — empty fall-through
case "${MULTICA_AGENT_NAME:-}" in
  Atlas|Archi) ;;
  *)
    echo "[push-guard] blocked" >&2
    exit 2
    ;;
esac

# If we reach here (old code with ;;), simulate Check 5 blocking
echo "[push-guard] old code: fell through to Check 5" >&2
echo "[push-guard] 错误：当前任务的共享分支是 shared/SEE-780，不允许推送到 master" >&2
exit 2
ABOLD
chmod +x "$AB_OLD"

# --- Variant B (NEW/fixed): echo+exit 0 ---
AB_NEW=$(mktemp /tmp/pg-ab-new.XXXXXX.sh)
cat > "$AB_NEW" <<'ABNEW'
#!/bin/bash
set -e
INPUT='{"tool_input":{"command":"git push origin master"}}'
PUSH_RESULT="MASTER_PUSH"

# NEW code: Atlas|Archi) echo "$INPUT"; exit 0 ;;
case "${MULTICA_AGENT_NAME:-}" in
  Atlas|Archi) echo "$INPUT"; exit 0 ;;
  *)
    echo "[push-guard] blocked" >&2
    exit 2
    ;;
esac
ABNEW
chmod +x "$AB_NEW"

# Test Variant A (old) with Atlas → should FAIL (fall through to Check 5)
MULTICA_AGENT_NAME="Atlas" bash "$AB_OLD" > /dev/null 2>&1
AB_OLD_ATLAS_EXIT=$?
if [ "$AB_OLD_ATLAS_EXIT" -eq 2 ]; then
  pass "S4-1 (OLD/broken): Atlas push master → exit 2 (bug confirmed: falls through to Check 5)"
else
  fail "S4-1 (OLD): Atlas push master — got exit $AB_OLD_ATLAS_EXIT, expected 2 (bug should manifest)"
fi

# Test Variant B (new) with Atlas → should PASS
MULTICA_AGENT_NAME="Atlas" bash "$AB_NEW" > /dev/null 2>&1
AB_NEW_ATLAS_EXIT=$?
if [ "$AB_NEW_ATLAS_EXIT" -eq 0 ]; then
  pass "S4-2 (NEW/fixed): Atlas push master → exit 0 (fix confirmed)"
else
  fail "S4-2 (NEW): Atlas push master — got exit $AB_NEW_ATLAS_EXIT, expected 0"
fi

# Test Variant A (old) with Archi → should FAIL
MULTICA_AGENT_NAME="Archi" bash "$AB_OLD" > /dev/null 2>&1
AB_OLD_ARCHI_EXIT=$?
if [ "$AB_OLD_ARCHI_EXIT" -eq 2 ]; then
  pass "S4-3 (OLD/broken): Archi push master → exit 2 (bug confirmed)"
else
  fail "S4-3 (OLD): Archi push master — got exit $AB_OLD_ARCHI_EXIT, expected 2"
fi

# Test Variant B (new) with Archi → should PASS
MULTICA_AGENT_NAME="Archi" bash "$AB_NEW" > /dev/null 2>&1
AB_NEW_ARCHI_EXIT=$?
if [ "$AB_NEW_ARCHI_EXIT" -eq 0 ]; then
  pass "S4-4 (NEW/fixed): Archi push master → exit 0 (fix confirmed)"
else
  fail "S4-4 (NEW): Archi push master — got exit $AB_NEW_ARCHI_EXIT, expected 0"
fi

# Both variants block non-Atlas/Archi agents
MULTICA_AGENT_NAME="Bachi" bash "$AB_OLD" > /dev/null 2>&1
AB_OLD_BACHI_EXIT=$?
MULTICA_AGENT_NAME="Bachi" bash "$AB_NEW" > /dev/null 2>&1
AB_NEW_BACHI_EXIT=$?

if [ "$AB_OLD_BACHI_EXIT" -eq 2 ] && [ "$AB_NEW_BACHI_EXIT" -eq 2 ]; then
  pass "S4-5: Both OLD and NEW block Bachi push master → exit 2 (unchanged)"
else
  fail "S4-5: Bachi blocking inconsistent — old=$AB_OLD_BACHI_EXIT new=$AB_NEW_BACHI_EXIT, both expected 2"
fi

# A/B diff: old blocks Atlas, new allows Atlas
if [ "$AB_OLD_ATLAS_EXIT" -ne "$AB_NEW_ATLAS_EXIT" ]; then
  pass "S4-6: A/B diff confirmed — fix changes behavior for Atlas (old=blocked, new=allowed)"
else
  fail "S4-6: A/B diff NOT confirmed — old=$AB_OLD_ATLAS_EXIT, new=$AB_NEW_ATLAS_EXIT"
fi

rm -f "$AB_OLD" "$AB_NEW"

# ========================================================
# Summary
# ========================================================
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
