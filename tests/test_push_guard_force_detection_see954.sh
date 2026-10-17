#!/bin/bash
# test_push_guard_force_detection_see954.sh
# Regression test for SEE-954 LOW-1: push-guard.sh force-push token hardening.
#
# Before LOW-1, force detection matched only exact --force / -f / --force-with-lease
# and the prefix --force-with-lease=. Combined short clusters (-fn, -uf, -fo) and
# --force=<v> slipped through, so an agent could accidentally force-push the shared
# branch. LOW-1 hardens it: any short cluster containing 'f' is force, plus
# --force=<v>; --no-force is an explicit opt-out and must NOT be blocked.
#
# The assertion is force-classification only: a command "is force-blocked" when it
# exits 2 with the force-push error. Non-force commands may pass or fail other
# Phase-3 checks — that is irrelevant here, so they only assert NOT force-blocked.

set -uo pipefail

# Identity isolation (SEE-1069 follow-up): lock to a non-whitelisted agent so
# the suite's result is independent of whoever runs it. These cases assert that
# force-push IS blocked, which only holds for a non-Atlas identity now that the
# force-push whitelist keys off MULTICA_AGENT_ID.
export MULTICA_AGENT_ID="a5c250e8-7257-466e-b45a-03f995c7206c"  # Bachi
export MULTICA_AGENT_NAME="Bachi"

PASS=0; FAIL=0
pass(){ echo -e "  \033[0;32m[PASS]\033[0m $1"; PASS=$((PASS+1)); }
fail(){ echo -e "  \033[0;31m[FAIL]\033[0m $1"; FAIL=$((FAIL+1)); }

WORKTREE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SCRIPT="$WORKTREE_DIR/hooks/scripts/push-guard.sh"

echo "=== SEE-954 LOW-1: push-guard force-push detection hardening ==="

if [ ! -f "$HOOK_SCRIPT" ]; then
  fail "push-guard.sh missing at $HOOK_SCRIPT"
  exit 1
fi
pass "push-guard.sh exists"

# Source guard: hardened logic present
if grep -q "t.indexOf('f')" "$HOOK_SCRIPT"; then pass "source: short-cluster 'f' check present"; else fail "source: short-cluster check missing"; fi
if grep -q -- "--no-force" "$HOOK_SCRIPT"; then pass "source: --no-force opt-out documented"; else fail "source: --no-force note missing"; fi

# run_hook <cmd> <expect_force_block 1|0> <label>
run_hook() {
  local cmd="$1" expect_force="$2" label="$3"
  local input stdout_file stderr_file actual_exit stderr_content is_force_blocked
  input=$(printf '{"tool_input":{"command":"%s"}}' "$cmd")
  stdout_file=$(mktemp /tmp/pgf-out.XXXXXX)
  stderr_file=$(mktemp /tmp/pgf-err.XXXXXX)
  (
    export MULTICA_AGENT_NAME="Bachi"
    export MULTICA_TASK_ID=""
    echo "$input" | bash "$HOOK_SCRIPT" > "$stdout_file" 2> "$stderr_file"
  )
  actual_exit=$?
  stderr_content=$(cat "$stderr_file")
  rm -f "$stdout_file" "$stderr_file"

  is_force_blocked=0
  if [ "$actual_exit" -eq 2 ] && echo "$stderr_content" | grep -q "禁止 force-push"; then
    is_force_blocked=1
  fi

  if [ "$is_force_blocked" -eq "$expect_force" ]; then
    pass "$label"
  else
    fail "$label (exit=$actual_exit force_blocked=$is_force_blocked expect=$expect_force stderr=$stderr_content)"
  fi
}

echo ""
echo "--- Force forms (MUST be blocked) ---"
run_hook "git push --force origin HEAD:refs/heads/feature/x" 1 "F1: --force"
run_hook "git push -f origin HEAD:refs/heads/feature/x" 1 "F2: -f"
run_hook "git push -fn origin HEAD:refs/heads/feature/x" 1 "F3: -fn (combined -f -n)"
run_hook "git push -uf origin HEAD:refs/heads/feature/x" 1 "F4: -uf (combined -u -f)"
run_hook "git push -fo origin HEAD:refs/heads/feature/x" 1 "F5: -fo (combined -f -o)"
run_hook "git push --force=true origin HEAD:refs/heads/feature/x" 1 "F6: --force=true"
run_hook "git push --force-with-lease origin HEAD:refs/heads/feature/x" 1 "F7: --force-with-lease"
run_hook "git push --force-with-lease=feature/x:abc123 origin HEAD:refs/heads/feature/x" 1 "F8: --force-with-lease=ref:sha"
run_hook "git push origin HEAD:refs/heads/feature/x --force" 1 "F9: --force after refspec"

echo ""
echo "--- Non-force forms (must NOT be force-blocked) ---"
run_hook "git push --no-force origin HEAD:refs/heads/feature/x" 0 "N1: --no-force (opt-out)"
run_hook "git push -n origin HEAD:refs/heads/feature/x" 0 "N2: -n dry-run only (no f)"
run_hook "git push origin HEAD:refs/heads/feature/x" 0 "N3: plain safe push"
run_hook "git status" 0 "N4: not a push (passthrough)"

echo ""
echo "=== RESULTS: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
