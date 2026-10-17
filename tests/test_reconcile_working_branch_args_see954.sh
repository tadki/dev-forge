#!/bin/bash
# test_reconcile_working_branch_args_see954.sh
# Regression test for SEE-954 LOW-2 + LOW-3 on .dev/scripts/reconcile-working-branch.sh.
#
# LOW-2: the double `set -eo pipefail` + `set -u` is merged into one `set -euo pipefail`.
# LOW-3: add `--issue-id <id>` (and MULTICA_ISSUE_ID env) so a manual Leader run can
#        still clear stale blocked_reason / waiting_on metadata without MULTICA_TASK_ID.
#
# Only the usage/error paths are exercised E2E (they exit before any git work); the
# happy-path arg capture and metadata resolution are locked in by source guards.

set -uo pipefail

PASS=0; FAIL=0
pass(){ echo -e "  \033[0;32m[PASS]\033[0m $1"; PASS=$((PASS+1)); }
fail(){ echo -e "  \033[0;31m[FAIL]\033[0m $1"; FAIL=$((FAIL+1)); }

WORKTREE_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$WORKTREE_DIR/hooks/scripts/reconcile-working-branch.sh"

echo "=== SEE-954 LOW-2 + LOW-3: reconcile-working-branch.sh ==="

if [ ! -f "$SCRIPT" ]; then fail "script missing at $SCRIPT"; exit 1; fi
pass "script exists"

echo ""
echo "--- Source guards (LOW-2 merged set, LOW-3 issue-id resolution) ---"
if grep -q '^set -euo pipefail' "$SCRIPT"; then pass "LOW-2: single 'set -euo pipefail'"; else fail "LOW-2: merged set missing"; fi
if grep -qE '^set -u$' "$SCRIPT"; then fail "LOW-2: stale bare 'set -u' still present"; else pass "LOW-2: no stale bare 'set -u'"; fi
if grep -q -- "--issue-id" "$SCRIPT"; then pass "LOW-3: --issue-id option present"; else fail "LOW-3: --issue-id missing"; fi
if grep -q -- "MULTICA_ISSUE_ID" "$SCRIPT"; then pass "LOW-3: MULTICA_ISSUE_ID env fallback present"; else fail "LOW-3: env fallback missing"; fi
# Resolution priority: explicit arg > env > task-id derivation
if grep -q 'ISSUE_ID_ARG:-${MULTICA_ISSUE_ID' "$SCRIPT"; then pass "LOW-3: arg-over-env resolution priority"; else fail "LOW-3: resolution priority missing"; fi

echo ""
echo "--- Usage / error paths (exit before git ops) ---"

# --help → exit 0, prints Usage
out=$(bash "$SCRIPT" --help 2>/dev/null); code=$?
if [ "$code" -eq 0 ] && echo "$out" | grep -q "Usage"; then pass "--help → exit 0 + Usage"; else fail "--help (exit=$code)"; fi

# no args → exit 1
bash "$SCRIPT" >/dev/null 2>&1; code=$?
if [ "$code" -eq 1 ]; then pass "no args → exit 1 (usage)"; else fail "no args (exit=$code, expect 1)"; fi

# --issue-id with no value → exit 1
bash "$SCRIPT" --issue-id >/dev/null 2>&1; code=$?
if [ "$code" -eq 1 ]; then pass "--issue-id without value → exit 1"; else fail "--issue-id no-value (exit=$code, expect 1)"; fi

# --issue-id <id> but no working_branch → exit 1
bash "$SCRIPT" --issue-id 864670c8-6637-4f65-920a-793dfe965483 >/dev/null 2>&1; code=$?
if [ "$code" -eq 1 ]; then pass "--issue-id <id> without working_branch → exit 1"; else fail "--issue-id+no-wb (exit=$code, expect 1)"; fi

echo ""
echo "=== RESULTS: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
