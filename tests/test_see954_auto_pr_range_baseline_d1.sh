#!/bin/bash
# test_see954_auto_pr_range_baseline_d1.sh
# Regression test for SEE-954 D1 (HIGH): auto-pr-on-stop commit-range baseline.
#
# Context: synthesis §D switched NEW_COMMITS / TITLE / COMMIT_LIST baselines from
# DEFAULT_BRANCH (master) to WORKING_BRANCH (via a RANGE_BASE var). That broke
# auto-PR: after the standard agent push `git push origin HEAD:refs/heads/<wb>`, the
# local origin/<wb> ref advances to HEAD, so `origin/<wb>..HEAD` is empty -> NEW_COMMITS
# empty -> the hook exited at the gate and never created a PR. TITLE/COMMIT_LIST were
# likewise empty when reached. Fix: revert to DEFAULT_BRANCH because the PR base IS
# master (see `gh pr create --base "$DEFAULT_BRANCH"`), so the PR commit range is
# master..HEAD.
#
# Suite A — source guard: the three ranges + PR base use DEFAULT_BRANCH; no
#           RANGE_BASE-from-WORKING_BRANCH remains (prevents the D1 regression).
# Suite B — topology proof: after pushing the agent commit to <wb>, origin/<wb>..HEAD
#           is EMPTY (the D1 trigger) while origin/master..HEAD is NON-EMPTY (the
#           fix's range) and yields the correct PR title.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../../.."
HOOK="$REPO_ROOT/hooks/scripts/auto-pr-on-stop.sh"

PASS=0; FAIL=0
pass(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
section(){ echo ""; echo "=== $1 ==="; }

assert_contains(){ # needle label [file]
  if grep -qF "$1" "${3:-$HOOK}"; then pass "$2"; else fail "$2 (missing: '$1')"; fi
}
assert_absent(){ # needle label [file]
  if grep -qF "$1" "${3:-$HOOK}"; then fail "$2 (should be absent: '$1')"; else pass "$2"; fi
}

# ============================================================
section "A. auto-pr-on-stop.sh uses DEFAULT_BRANCH for commit ranges (D1 fix)"
# ============================================================
assert_contains 'NEW_COMMITS=$(git log "origin/${DEFAULT_BRANCH}..HEAD" --oneline' \
  "NEW_COMMITS range base = DEFAULT_BRANCH (master)"
assert_contains 'TITLE=$(git log "origin/${DEFAULT_BRANCH}..HEAD" --reverse --format="%s" | head -1)' \
  "TITLE range base = DEFAULT_BRANCH"
assert_contains 'COMMIT_LIST=$(git log "origin/${DEFAULT_BRANCH}..HEAD" --reverse --format="- %s")' \
  "COMMIT_LIST range base = DEFAULT_BRANCH"
assert_contains 'gh pr create --head "$PR_HEAD" --base "$DEFAULT_BRANCH"' \
  "PR base = DEFAULT_BRANCH (consistent with the commit ranges)"

# The D1 regression introduced RANGE_BASE="${WORKING_BRANCH:-$DEFAULT_BRANCH}". It
# must stay gone, and no commit range may reference WORKING_BRANCH directly.
assert_absent 'RANGE_BASE="${WORKING_BRANCH' "no RANGE_BASE-from-WORKING_BRANCH (D1 guard)"
assert_absent 'git log "origin/${WORKING_BRANCH' "no git-log range uses WORKING_BRANCH directly"

# ============================================================
section "B. topology: master..HEAD survives push; <wb>..HEAD empties (D1 trigger)"
# ============================================================
SBOX=$(mktemp -d)
BARE=$(mktemp -d)
cleanup(){ rm -rf "$SBOX" "$BARE"; }
trap cleanup EXIT

cd "$SBOX" || exit 1
git init -q -b master >/dev/null 2>&1
git config user.email d1@see954.test >/dev/null 2>&1
git config user.name "D1 QA" >/dev/null 2>&1
git init -q --bare "$BARE" >/dev/null 2>&1
git remote add origin "$BARE" >/dev/null 2>&1

echo base > base.txt; git add -A; git commit -q -m "base on master"
WB="feature/see954-d1"
git checkout -q -b "$WB"
echo agent > agent.txt; git add -A; git commit -q -m "agent commit on wb"
# Push both so origin/master and origin/<wb> remote-tracking refs exist; this mirrors
# the agent's in-session `git push origin HEAD:refs/heads/<wb>`.
git push -q origin master "$WB" 2>/dev/null
git fetch -q origin 2>/dev/null

WB_RANGE=$(git log "origin/${WB}..HEAD" --oneline 2>/dev/null | wc -l | tr -d ' ')
MASTER_RANGE=$(git log "origin/master..HEAD" --oneline 2>/dev/null | wc -l | tr -d ' ')

if [ "$WB_RANGE" -eq 0 ]; then
  pass "origin/<wb>..HEAD EMPTY after push (the D1 trigger: old WORKING_BRANCH baseline failed here)"
else
  fail "origin/<wb>..HEAD unexpectedly non-empty ($WB_RANGE) — topology assumption wrong"
fi

if [ "$MASTER_RANGE" -ge 1 ]; then
  pass "origin/master..HEAD NON-EMPTY ($MASTER_RANGE) after push — DEFAULT_BRANCH baseline is correct"
else
  fail "origin/master..HEAD empty — cannot demonstrate fix"
fi

TITLE=$(git log "origin/master..HEAD" --reverse --format="%s" | head -1)
if echo "$TITLE" | grep -q "agent commit on wb"; then
  pass "fix baseline yields correct PR title ('$TITLE')"
else
  fail "fix baseline yielded unexpected title: '$TITLE'"
fi

echo ""
echo "=== RESULTS ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
