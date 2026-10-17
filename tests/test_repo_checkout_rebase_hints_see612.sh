#!/bin/bash
# QA Test Script for SEE-612 / SEE-954: repo-checkout.sh hint text & align behavior.
#
# SEE-954 rewrote the coordination model:
#   - rebase-before-work.sh was DELETED (per-tool-call rebase removed).
#   - repo-checkout.sh now owns SessionStart alignment: it calls
#     align_agent_branch_to_working_branch, which sets upstream, runs an
#     idempotent §B auto-rebase of master onto origin/<working_branch> in an
#     isolated worktree (first-agent-wins via --force-with-lease), touches the
#     .cc-aligned-<dir> marker on success, and emits caller-supplied
#     success_msg / conflict_msg hints.
#   - The old .cc-rebase-* marker is renamed to .cc-aligned-*; a one-shot
#     `rm -f .cc-rebase-*` sweep runs at SessionStart entry to garbage-collect
#     stale markers from the deleted hook.
#
# This file was rewritten under SEE-954 to assert the NEW model with grep-based
# (not line-frozen) checks. The previous version's sections that asserted
# rebase-before-work.sh internals (Chinese stderr, hookSpecificOutput format,
# _DIR cross-script parity) are intentionally dropped: that script no longer
# exists, so the assertions are moot. The shared-branch-coordination-plan.md
# doc-accuracy section is also dropped: updating that planning doc is Archi's
# remit and out of scope for this test-rewrite step.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../../.."
REPO_CHECKOUT="$REPO_ROOT/hooks/scripts/repo-checkout.sh"
DELETED_REBASE_HOOK="$REPO_ROOT/hooks/rebase-before-work.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
section() { echo ""; echo "=== $1 ==="; }

assert_contains() {
    local needle="$1" label="$2" file="${3:-$REPO_CHECKOUT}"
    if grep -qF "$needle" "$file"; then
        pass "$label"
    else
        fail "$label (missing: '$needle')"
    fi
}

assert_absent() {
    local needle="$1" label="$2" file="${3:-$REPO_CHECKOUT}"
    if grep -qF "$needle" "$file"; then
        fail "$label (should be absent: '$needle')"
    else
        pass "$label"
    fi
}

# ============================================================
section "1. repo-checkout.sh — No-working-branch SessionStart hint text"
# ============================================================
assert_contains "本 issue 尚未设置 working branch" "no-WB hint mentions unset working branch"
assert_contains "故已自动创建默认 worktree"          "no-WB hint mentions default worktree creation"
assert_contains "严禁直接修改本地 main repo"        "no-WB hint warns against touching main repo"

# The no-WB path has no working branch to push to, so it must not carry a push
# refspec instruction (that belongs only to the WB success path).
NO_WB_BLOCK=$(awk '/本 issue 尚未设置 working branch/{flag=1} flag{print} /"/ && flag && /"|/ {flag=0}' "$REPO_CHECKOUT")
# Simpler: scan the single output_hint line that carries the no-WB text.
NO_WB_LINE=$(grep "本 issue 尚未设置 working branch" "$REPO_CHECKOUT" | head -1)
if echo "$NO_WB_LINE" | grep -qF "git push origin HEAD:refs/heads"; then
    fail "no-WB hint should NOT contain a push refspec"
else
    pass "no-WB hint correctly excludes push refspec"
fi

# ============================================================
section "2. repo-checkout.sh — align success path (.cc-aligned marker + success_msg)"
# ============================================================
assert_contains 'touch "${TEMP:-/tmp}/.cc-aligned-'  "success path writes .cc-aligned marker"
assert_contains 'output_hint "${success_msg}"'      "success path emits caller success_msg"

# Marker touch must come BEFORE the success exit (correct SessionStart ordering).
TOUCH_LINE=$(grep -n 'touch "${TEMP:-/tmp}/.cc-aligned-' "$REPO_CHECKOUT" | head -1 | cut -d: -f1)
SUCC_LINE=$(grep -n 'output_hint "${success_msg}"' "$REPO_CHECKOUT" | head -1 | cut -d: -f1)
if [ -n "$TOUCH_LINE" ] && [ -n "$SUCC_LINE" ] && [ "$TOUCH_LINE" -lt "$SUCC_LINE" ]; then
    pass "marker touch precedes success_msg emission"
else
    fail "marker touch must precede success_msg (touch=$TOUCH_LINE succ=$SUCC_LINE)"
fi

# ============================================================
section "3. repo-checkout.sh — §B auto-rebase master (new SEE-954 model)"
# ============================================================
# The §B block rebases master onto origin/<wb> in an ISOLATED worktree so the
# agent's (possibly dirty) worktree is never touched, then pushes with an
# explicit lease (first-agent-wins). On conflict it aborts and emits conflict_msg.
assert_contains "git worktree add"              "§B rebases master in an isolated worktree"
assert_contains "force-with-lease"              "§B push uses --force-with-lease (first-agent-wins)"
assert_contains "rebase origin/master"          "§B rebases onto origin/master"
assert_contains "git -C \"\$rebase_wt\" rebase --abort" "§B aborts rebase on conflict"
assert_contains 'output_hint "${conflict_msg}"' "§B emits conflict_msg on rebase conflict"

# Idempotency guard: §B only fires when master is NOT already an ancestor.
assert_contains "merge-base --is-ancestor origin/master" "§B guarded by merge-base ancestor check"

# ============================================================
section "4. repo-checkout.sh — Checkout failure message (Chinese)"
# ============================================================
assert_contains "Repo 自动检出失败" "checkout-failure message is in Chinese"

# ============================================================
section "5. _DIR marker encoding (within repo-checkout.sh)"
# ============================================================
# rebase-before-work.sh is gone, so cross-script _DIR parity is N/A; we verify
# repo-checkout.sh's own 3-transform encoding is intact (produces a filesystem-
# safe marker name from the repo path).
assert_contains '_DIR="${_DIR////_}"' "_DIR: replace / with _"
assert_contains '_DIR="${_DIR//\/_}"'  "_DIR: strip leading underscore"
assert_contains '_DIR="${_DIR// /_}"'  "_DIR: replace spaces with _"

# ============================================================
section "6. SEE-954 model invariants (deleted hook + legacy marker sweep)"
# ============================================================
if [ ! -f "$DELETED_REBASE_HOOK" ]; then
    pass "rebase-before-work.sh intentionally absent (SEE-954)"
else
    fail "rebase-before-work.sh still present — expected deletion"
fi
assert_contains 'rm -f "${TEMP:-/tmp}"/.cc-rebase-*' "legacy .cc-rebase-* markers garbage-collected at SessionStart"
# The only legitimate remaining .cc-rebase- reference is the rm -f sweep above
# (a deleter, not a writer). No `touch` of .cc-rebase- may remain.
if grep -q 'touch.*\.cc-rebase-' "$REPO_CHECKOUT"; then
    fail "found a .cc-rebase- marker writer (should be .cc-aligned-)"
else
    pass "no .cc-rebase- marker writer remains (renamed to .cc-aligned-)"
fi

# ============================================================
section "7. output_hint helper unchanged (non-blocking SessionStart hint)"
# ============================================================
OUTPUT_HINT_FN=$(sed -n '/^output_hint()/,/^}/p' "$REPO_CHECKOUT")
if echo "$OUTPUT_HINT_FN" | grep -q "SessionStart"; then
    pass "output_hint still emits SessionStart hookSpecificOutput"
else
    fail "output_hint no longer references SessionStart"
fi

# ============================================================
echo ""
echo "========================================"
echo "Test Results: $PASS PASSED, $FAIL FAILED"
echo "========================================"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
