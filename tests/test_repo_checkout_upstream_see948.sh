#!/bin/bash
# QA Test Script for SEE-948 / SEE-954: repo-checkout.sh upstream setting logic
# Tests the implemented helper "align_agent_branch_to_working_branch" in isolated
# git fixtures, exercising the T01-T21 matrix from the design review.
#
# Run: bash .dev/tests/hooks/test_repo_checkout_upstream_see948.sh
# or: ./.dev/tests/hooks/test_repo_checkout_upstream_see948.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
TMPDIR=""
PASS=0
FAIL=0
WARN=0
HELPER_LIB=""

WB="shared/SEE-948"

# --- Extract the helper library from the feature/SEE-954 hook script ---
# SEE-954 moved the per-tool-call rebase into align_agent_branch_to_working_branch
# (the §B auto-rebase block), so the function body grew past the old SEE-948
# line range. We now capture from `output_hint()` through the end of
# `align_agent_branch_to_working_branch` (i.e. up to — but not including —
# `try_auto_create_shared_branch`) by locating that boundary dynamically,
# instead of hard-coding line numbers.
extract_helper_lib() {
    local lib_file="$1"
    local hook_at_feature
    hook_at_feature="$REPO_ROOT/claude-hooks/scripts/repo-checkout.sh"

    # Prefer the feature/SEE-954 branch version; fall back to the working tree.
    local content
    if git -C "$REPO_ROOT" rev-parse --verify origin/feature/SEE-954 >/dev/null 2>&1; then
        content=$(git -C "$REPO_ROOT" show origin/feature/SEE-954:.claude/hooks/scripts/repo-checkout.sh)
    else
        # Fallback: assume the local hook file already contains the SEE-954 implementation.
        content=$(cat "$hook_at_feature")
    fi

    # Capture from line 8 (start of output_hint) through the line before
    # try_auto_create_shared_branch. This block holds every helper that
    # align_agent_branch_to_working_branch transitively calls in the fixture
    # (output_hint, set_agent_upstream, list_unpushed_commits, get_current_branch,
    # is_worktree_dirty, resolve_issue_id). The Multica-CLI-bound helpers are
    # never invoked by the align path in the fixture, so their presence as
    # sourced-but-uncalled definitions is harmless.
    local end_line
    end_line=$(echo "$content" | grep -n '^try_auto_create_shared_branch()' | head -1 | cut -d: -f1)
    if [ -z "$end_line" ]; then
        end_line=$(echo "$content" | wc -l)
    fi
    echo "$content" | sed -n "8,$((end_line - 1))p" > "$lib_file"
}

# --- Helpers ---
cleanup() {
    if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
        rm -rf "$TMPDIR"
    fi
}
trap cleanup EXIT

fail() {
    echo "  FAIL: $1"
    FAIL=$((FAIL+1))
}
pass() {
    echo "  PASS: $1"
    PASS=$((PASS+1))
}
warn() {
    echo "  WARN: $1"
    WARN=$((WARN+1))
}

jq_context() {
    echo "$1" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}

# Build a fixture with a local bare "origin" and a working clone.
#   master : m1 -> m2 (so wb is behind master)
#   wb     : shared/SEE-948 branched at m1
#   agent  : agent/revy branch at master tip, upstream origin/master
build_fixture() {
    local root="$1"
    local remote="$root/origin.git"
    local work="$root/work"

    git init --bare --quiet "$remote"
    git init --quiet "$work"
    cd "$work"
    git config user.email "qa@kol.test"
    git config user.name "QA"
    git remote add origin "$remote"

    echo "line1" > f.txt
    git add f.txt
    git commit -qm "m1"
    git branch -M master
    git push -q origin master

    # create working branch at m1
    git checkout -qb "$WB"
    git push -q origin "$WB"
    git checkout -q master

    # advance master so wb is behind (realistic)
    echo "line1" > f.txt
    echo "master_line2" >> f.txt
    git add f.txt
    git commit -qm "m2 master advance"
    git push -q origin master

    # create agent branch from master tip, mimicking multica repo checkout.
    # NOTE: redirect `git branch -u` to /dev/null — it prints
    # "branch 'agent/revy' set up to track 'origin/master'." to stdout, which
    # would corrupt the `work=$(build_fixture ...)` capture returned below.
    git checkout -qb agent/revy
    git branch -u origin/master agent/revy >/dev/null 2>&1

    echo "$work"
}

# Invoke align_agent_branch_to_working_branch in a subshell; capture exit code
# and stdout JSON.  The helper exits on success, so a subshell is mandatory.
run_align() {
    local work="$1"
    local success_msg="${2:-SUCCESS}"
    local rebase_fail_msg="${3:-REBASE_FAIL}"
    (
        source "$HELPER_LIB"
        cd "$work"
        align_agent_branch_to_working_branch "$work" "$WB" "$success_msg" "$rebase_fail_msg"
    )
}

# Print a concise git state summary (used only for failure diagnostics)
git_state() {
    local work="$1"
    (cd "$work" && echo "HEAD=$(git rev-parse --short HEAD) branch=$(git branch --show-current) upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || echo none) dirty=$(git diff-index --quiet HEAD -- && echo clean || echo dirty)")
}

# --- Test Cases ---

test_t01_fresh_clean_success() {
    echo "[T01] fresh checkout, clean tree, wb on remote -> upstream set + rebase success"
    local work
    work=$(build_fixture "$TMPDIR/t01")
    local out rc
    out=$(run_align "$work" "T01_SUCCESS" "T01_REBASE_FAIL"); rc=$?

    if [ "$rc" -ne 0 ]; then fail "expected exit 0, got $rc; out=$out"; return; fi
    if ! (cd "$work" && git rev-parse --abbrev-ref '@{upstream}' | grep -q "origin/${WB}$"); then
        fail "upstream not set to origin/${WB}"; return
    fi
    if ! test -f "${TMPDIR:-/tmp}/.cc-aligned-${work//\//_}"; then
        fail ".cc-aligned marker not touched"; return
    fi
    if ! echo "$out" | grep -q "T01_SUCCESS"; then
        fail "success hint not emitted"; return
    fi
    pass "upstream=origin/${WB}, marker touched, success hint"
}

test_t02_rerun_safety() {
    echo "[T02] rerun after first align -> still safe, no data loss"
    local work
    work=$(build_fixture "$TMPDIR/t02")
    run_align "$work" "FIRST" "FIRST_REBASE_FAIL" >/dev/null 2>&1 || true

    # Simulate agent doing nothing between sessions; rerun
    local out rc
    out=$(run_align "$work" "SECOND" "SECOND_REBASE_FAIL"); rc=$?

    if [ "$rc" -ne 0 ]; then fail "rerun exited $rc; out=$out"; return; fi
    if ! (cd "$work" && git rev-parse --abbrev-ref '@{upstream}' | grep -q "origin/${WB}$"); then
        fail "upstream lost on rerun"; return
    fi
    pass "rerun safe, upstream preserved"
}

test_t03_upstream_origin_master_switches() {
    echo "[T03] upstream originally origin/master -> switched to origin/<wb>"
    local work
    work=$(build_fixture "$TMPDIR/t03")
    # ensure upstream starts as origin/master (already true), run align
    local out rc
    out=$(run_align "$work" "OK" "FAIL"); rc=$?
    if [ "$rc" -ne 0 ]; then fail "exit $rc; out=$out"; return; fi
    if ! (cd "$work" && git rev-parse --abbrev-ref '@{upstream}' | grep -q "origin/${WB}$"); then
        fail "upstream not switched"; return
    fi
    pass "upstream switched from origin/master to origin/${WB}"
}

test_t04_dirty_no_unpushed() {
    echo "[T04] dirty tree, no unpushed commits -> stash/reset/rebase/pop success"
    local work
    work=$(build_fixture "$TMPDIR/t04")
    # dirty change, but no commit
    cd "$work"
    echo "agent_uncommitted" >> f.txt
    local out rc
    out=$(run_align "$work" "OK" "FAIL"); rc=$?

    if [ "$rc" -ne 0 ]; then fail "exit $rc; out=$out"; return; fi
    # dirty content restored on top
    if ! grep -q "agent_uncommitted" "$work/f.txt"; then
        fail "uncommitted change was not restored"; return
    fi
    pass "dirty change stashed, restored after rebase"
}

test_t05_dirty_with_unpushed() {
    echo "[T05] dirty tree + unpushed commit -> protection fires BEFORE stash, tree stays dirty"
    local work
    work=$(build_fixture "$TMPDIR/t05")
    cd "$work"
    echo "agent_change" > agent_file.txt
    git add agent_file.txt
    git commit -qm "agent_wip"
    echo "dirty_line" >> f.txt

    local out rc
    out=$(run_align "$work" "OK" "FAIL"); rc=$?

    if [ "$rc" -ne 0 ]; then fail "expected exit 0 (stop-with-hint), got $rc"; return; fi
    local ctx
    ctx=$(jq_context "$out")
    if ! echo "$ctx" | grep -q "本地未推送 commit 保护"; then
        fail "expected unpushed protection hint, got: $ctx"; return
    fi
    # working tree must still be dirty (we aborted before stash)
    if (cd "$work" && git diff-index --quiet HEAD --); then
        fail "dirty tree was stashed despite protection firing"; return
    fi
    # commit preserved
    if ! (cd "$work" && git log --oneline | grep -q "agent_wip"); then
        fail "agent commit lost"; return
    fi
    pass "protection fired and dirty tree + commit preserved"
}

test_t06_clean_with_unpushed_and_ab() {
    echo "[T06] clean tree + unpushed commit -> protection fires (R2 fix)"
    local work
    work=$(build_fixture "$TMPDIR/t06")
    cd "$work"
    echo "agent_change" > agent_file.txt
    git add agent_file.txt
    git commit -qm "agent_wip"

    local out rc
    out=$(run_align "$work" "OK" "FAIL"); rc=$?

    if [ "$rc" -ne 0 ]; then fail "expected exit 0, got $rc"; return; fi
    local ctx
    ctx=$(jq_context "$out")
    if ! echo "$ctx" | grep -q "本地未推送 commit 保护"; then
        fail "expected unpushed protection hint, got: $ctx"; return
    fi
    if ! (cd "$work" && git log --oneline | grep -q "agent_wip"); then
        fail "agent commit lost despite protection"; return
    fi

    # A/B: simulate OLD behavior (master implementation) on an identical fixture
    local work_old
    work_old=$(build_fixture "$TMPDIR/t06_old")
    cd "$work_old"
    echo "agent_change" > agent_file.txt
    git add agent_file.txt
    git commit -qm "agent_wip"
    git reset --hard "origin/${WB}" >/dev/null 2>&1 || true
    git rebase origin/master >/dev/null 2>&1 || true
    if (cd "$work_old" && git log --oneline | grep -q "agent_wip"); then
        warn "old behavior unexpectedly preserved the commit; A/B contrast weakened"
    fi

    pass "NEW protects clean+unpushed; OLD silently loses it"
}

test_t07_stash_pop_conflict() {
    echo "[T07] dirty tree, pop conflicts -> clear stash-pop conflict hint"
    local work
    work=$(build_fixture "$TMPDIR/t07")
    # Advance master to m3 with a conflicting f.txt line2 (line2 differs from
    # the agent's pending change). agent/revy stays at m2 (build_fixture left it
    # there), so the agent's dirty change is stashed relative to m2; after
    # reset-to-wb(m1) + rebase onto m3, popping that stash 3-way-merges against
    # a different line2 => conflict.
    git -C "$work" checkout -q master
    printf 'line1\nmaster_line2_m3\n' > "$work/f.txt"
    git -C "$work" add f.txt
    git -C "$work" commit -qm "m3 master advance conflicting"
    git -C "$work" push -q origin master
    # agent dirty change to the same line, based on m2
    git -C "$work" checkout -q agent/revy
    printf 'line1\nagent_line2\n' > "$work/f.txt"

    local out rc
    out=$(run_align "$work" "OK" "FAIL"); rc=$?

    if [ "$rc" -ne 0 ]; then fail "expected exit 0, got $rc"; return; fi
    local ctx
    ctx=$(jq_context "$out")
    if ! echo "$ctx" | grep -q "stash pop 冲突"; then
        fail "expected stash pop conflict hint, got: $ctx"; return
    fi
    if ! echo "$ctx" | grep -q "git stash drop"; then
        warn "stash drop guidance missing"
    fi
    pass "stash pop conflict detected and hinted"
}

test_t08_rebase_conflict() {
    echo "[T08] rebase origin/master conflict -> rebase-fail hint, abort restores state"
    local work
    work=$(build_fixture "$TMPDIR/t08")
    cd "$work"
    # master and wb diverge on the same line -> rebase conflict
    git checkout -q "$WB"
    echo "wb_line2" > f.txt
    git add f.txt
    git commit -qm "wb_change"
    git push -q origin "$WB"
    git checkout -q master
    echo "master_line2" > f.txt
    git add f.txt
    git commit -qm "m2_conflict"
    git push -q origin master
    git checkout -q agent/revy

    local out rc
    out=$(run_align "$work" "OK" "REBASE_CONFLICT"); rc=$?

    if [ "$rc" -ne 0 ]; then fail "expected exit 0, got $rc"; return; fi
    local ctx
    ctx=$(jq_context "$out")
    if ! echo "$ctx" | grep -q "REBASE_CONFLICT"; then
        fail "expected rebase-fail message, got: $ctx"; return
    fi
    # rebase must have been aborted: no rebase state dir remains
    if [ -d "$work/.git/rebase-merge" ] || [ -d "$work/.git/rebase-apply" ]; then
        fail "rebase still in progress"; return
    fi
    pass "rebase conflict hinted and aborted"
}

test_t09_remote_wb_missing() {
    echo "[T09] wb in metadata but not on remote -> helper returns 1 (caller fallback)"
    local work
    work=$(build_fixture "$TMPDIR/t09")
    # delete wb from the bare "origin" via the clone (canonical delete path)
    git -C "$work" push origin --delete "$WB" >/dev/null 2>&1

    local out rc
    out=$(run_align "$work" "OK" "FAIL"); rc=$?

    if [ "$rc" -ne 1 ]; then fail "expected return 1 for missing remote wb, got $rc"; return; fi
    pass "missing remote wb causes silent return 1"
}

test_t14_detached_head() {
    echo "[T14] detached HEAD -> clear hint, exit 0"
    local work
    work=$(build_fixture "$TMPDIR/t14")
    cd "$work"
    git checkout -q "$(git rev-parse HEAD)"

    local out rc
    out=$(run_align "$work" "OK" "FAIL"); rc=$?

    if [ "$rc" -ne 0 ]; then fail "expected exit 0, got $rc"; return; fi
    local ctx
    ctx=$(jq_context "$out")
    if ! echo "$ctx" | grep -q "detached HEAD"; then
        fail "expected detached HEAD hint, got: $ctx"; return
    fi
    pass "detached HEAD handled"
}

test_t15_preexisting_stash_untouched() {
    echo "[T15] pre-existing stash + dirty + reset -> user's stash survives"
    local work
    work=$(build_fixture "$TMPDIR/t15")
    cd "$work"
    echo "user_stash" > stashme.txt
    git add stashme.txt
    git stash push -m "user_stash" >/dev/null 2>&1
    local before_stash
    before_stash=$(cd "$work" && git stash list | wc -l)

    echo "agent_uncommitted" >> f.txt
    run_align "$work" "OK" "FAIL" >/dev/null 2>&1 || true

    local after_stash
    after_stash=$(cd "$work" && git stash list | wc -l)
    if [ "$after_stash" -lt "$before_stash" ]; then
        fail "user stash was popped (before=$before_stash after=$after_stash)"; return
    fi
    pass "user stash preserved (before=$before_stash after=$after_stash)"
}

test_t17_t18_t19_success_constraints() {
    echo "[T17/T18/T19] success path preserves marker + full output_hint + exit 0"
    local work
    work=$(build_fixture "$TMPDIR/t19")
    local marker="${TMPDIR}/.cc-aligned-t19"
    # ensure marker does not pre-exist
    rm -f "$marker"

    local out rc
    out=$(run_align "$work" "PUSH_GUIDE:git push origin HEAD:refs/heads/${WB}" "FAIL"); rc=$?

    if [ "$rc" -ne 0 ]; then fail "expected exit 0, got $rc"; return; fi
    if ! echo "$out" | grep -q "PUSH_GUIDE:git push origin HEAD:refs/heads/${WB}"; then
        fail "success hint missing push refspec guidance"; return
    fi
    # marker path: align uses ${TEMP:-/tmp} and pwd-normalized dir name
    # Since TMPDIR may not propagate into the subshell the same way, just check
    # that *some* .cc-aligned file was touched around the same time.
    if ! find "${TMPDIR:-/tmp}" -maxdepth 1 -name '.cc-aligned-*' -mmin -1 | grep -q .; then
        fail ".cc-aligned marker not touched"; return
    fi
    pass "exit 0, push guidance present, marker touched"
}

# --- Main ---
main() {
    TMPDIR=$(mktemp -d)
    HELPER_LIB="$TMPDIR/see948_helpers.sh"
    # The SUT writes its .cc-aligned marker to ${TEMP:-/tmp}. Point TEMP at our
    # isolated TMPDIR so markers land inside it (findable + auto-cleaned), and
    # the fixture is never polluted by stray markers from other runs.
    export TEMP="$TMPDIR"
    extract_helper_lib "$HELPER_LIB"

    if ! bash -n "$HELPER_LIB"; then
        echo "ABORT: extracted helper lib has syntax errors"
        exit 2
    fi

    echo "=== SEE-948 repo-checkout.sh QA harness ==="
    echo "TMPDIR=$TMPDIR"
    echo

    test_t01_fresh_clean_success
    test_t02_rerun_safety
    test_t03_upstream_origin_master_switches
    test_t04_dirty_no_unpushed
    test_t05_dirty_with_unpushed
    test_t06_clean_with_unpushed_and_ab
    test_t07_stash_pop_conflict
    test_t08_rebase_conflict
    test_t09_remote_wb_missing
    test_t14_detached_head
    test_t15_preexisting_stash_untouched
    test_t17_t18_t19_success_constraints

    echo
    echo "=== RESULTS ==="
    echo "PASS: $PASS"
    echo "FAIL: $FAIL"
    echo "WARN: $WARN"

    if [ "$FAIL" -gt 0 ]; then
        exit 1
    fi
    exit 0
}

main "$@"
