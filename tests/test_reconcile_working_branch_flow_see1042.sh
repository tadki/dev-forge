#!/bin/bash
# test_reconcile_working_branch_flow_see1042.sh
# QA test for SEE-1042: verify reconcile-working-branch.sh behavior on
# happy path, rebase conflict, and lease-race scenarios.
#
# This test creates a temporary local bare "origin" plus clones to simulate the
# shared working-branch environment without touching the real remote.

set -uo pipefail

PASS=0; FAIL=0
pass(){ echo -e "  \033[0;32m[PASS]\033[0m $1"; PASS=$((PASS+1)); }
fail(){ echo -e "  \033[0;31m[FAIL]\033[0m $1"; FAIL=$((FAIL+1)); }

WORKTREE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$WORKTREE_DIR/claude-hooks/scripts/reconcile-working-branch.sh"
WORKING_BRANCH="test/wb-see1042"
RECONCILE_BRANCH="reconcile/${WORKING_BRANCH//\//-}"

if [ ! -f "$SCRIPT" ]; then
    fail "script missing at $SCRIPT"
    exit 1
fi
pass "script exists"

prepare_origin() {
    local tmp="$1"
    local origin="$tmp/origin.git"
    local seeder="$tmp/seeder"
    git init --bare "$origin" >/dev/null 2>&1
    git clone "$origin" "$seeder" >/dev/null 2>&1
    (
        cd "$seeder" || exit 1
        git config user.email "seeder@example.com"
        git config user.name "Seeder"
        echo "master initial" > file.txt
        git add file.txt
        git commit -m "master initial" >/dev/null 2>&1
        git push origin HEAD:master >/dev/null 2>&1
        echo "wb initial" > wb-only.txt
        git add wb-only.txt
        git commit -m "wb initial" >/dev/null 2>&1
        git push origin HEAD:refs/heads/"$WORKING_BRANCH" >/dev/null 2>&1
    )
    rm -rf "$seeder"
}

clone_wt() {
    local origin="$1" path="$2"
    git clone "$origin" "$path" >/dev/null 2>&1
    (
        cd "$path" || exit 1
        git config user.email "agent@example.com"
        git config user.name "Agent"
        git checkout -t origin/"$WORKING_BRANCH" >/dev/null 2>&1
    )
}

run_reconcile_with() {
    local dir="$1"; shift
    (
        cd "$dir" || exit 1
        bash "$SCRIPT" "$@"
    )
}

run_reconcile() {
    run_reconcile_with "$1" "$WORKING_BRANCH"
}

echo "=== SEE-1042: reconcile-working-branch.sh flow tests ==="

# --- Happy path: master advances on a separate file, rebase clean, push succeeds ---
echo ""
echo "--- Happy path ---"
TMP_DIR=$(mktemp -d /tmp/reconcile-see1042.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT
prepare_origin "$TMP_DIR"
clone_wt "$TMP_DIR/origin.git" "$TMP_DIR/clone-a"
(
    cd "$TMP_DIR/clone-a" || exit 1
    git checkout master >/dev/null 2>&1
    echo "master advance" > file.txt
    git commit -am "master advance" >/dev/null 2>&1
    git push origin HEAD:master >/dev/null 2>&1
    git checkout "$WORKING_BRANCH" >/dev/null 2>&1
    echo "wb feature" > wb-only.txt
    git commit -am "wb feature" >/dev/null 2>&1
    git push origin HEAD:refs/heads/"$WORKING_BRANCH" >/dev/null 2>&1
)

if run_reconcile "$TMP_DIR/clone-a" >/dev/null 2>&1; then
    pass "happy path: reconcile succeeds with exit 0"
else
    fail "happy path: reconcile failed (exit=$?)"
fi

(
    cd "$TMP_DIR/clone-a" || exit 1
    git fetch origin >/dev/null 2>&1
)
if (
    cd "$TMP_DIR/clone-a" || exit 1
    git merge-base --is-ancestor origin/master "origin/$WORKING_BRANCH"
); then
    pass "happy path: working branch contains origin/master after reconcile"
else
    fail "happy path: working branch missing origin/master"
fi

if (
    cd "$TMP_DIR/clone-a" || exit 1
    ! git rev-parse --verify "$RECONCILE_BRANCH" >/dev/null 2>&1
); then
    pass "happy path: reconcile branch cleaned up"
else
    fail "happy path: reconcile branch still exists"
fi

rm -rf "$TMP_DIR"

# --- Conflict path: rebase conflict → exit 1, branch retained, --continue recovers ---
echo ""
echo "--- Rebase conflict + --continue recovery ---"
TMP_DIR=$(mktemp -d /tmp/reconcile-see1042.XXXXXX)
prepare_origin "$TMP_DIR"
clone_wt "$TMP_DIR/origin.git" "$TMP_DIR/clone-a"
(
    cd "$TMP_DIR/clone-a" || exit 1
    git checkout master >/dev/null 2>&1
    echo "line one" > conflict.txt
    git add conflict.txt
    git commit -m "master adds conflict.txt" >/dev/null 2>&1
    git push origin HEAD:master >/dev/null 2>&1
    git checkout "$WORKING_BRANCH" >/dev/null 2>&1
    echo "line two" > conflict.txt
    git add conflict.txt
    git commit -m "wb adds conflict.txt" >/dev/null 2>&1
    git push origin HEAD:refs/heads/"$WORKING_BRANCH" >/dev/null 2>&1
)

# Normal run hits the conflict → must exit 1 (rebase conflict, branch retained).
run_reconcile "$TMP_DIR/clone-a" >/dev/null 2>&1; code=$?
if [ "$code" -eq 1 ]; then
    pass "conflict: reconcile exits 1 on rebase conflict"
else
    fail "conflict: expected exit 1 (got $code)"
fi

if (
    cd "$TMP_DIR/clone-a" || exit 1
    git rev-parse --verify "$RECONCILE_BRANCH" >/dev/null 2>&1
); then
    pass "conflict: reconcile branch retained for resolution"
else
    fail "conflict: reconcile branch missing"
fi

# Resolve the conflict on the reconcile branch, then drive --continue to finish.
(
    cd "$TMP_DIR/clone-a" || exit 1
    git checkout "$RECONCILE_BRANCH" >/dev/null 2>&1
    printf "line one\nline two\n" > conflict.txt
    git add conflict.txt
    GIT_EDITOR=true git rebase --continue >/dev/null 2>&1
)
run_reconcile_with "$TMP_DIR/clone-a" --continue "$WORKING_BRANCH" >/dev/null 2>&1; code=$?
if [ "$code" -eq 0 ]; then
    pass "--continue: exits 0 after conflict resolution + lease push"
else
    fail "--continue: expected exit 0 (got $code)"
fi

if (
    cd "$TMP_DIR/clone-a" || exit 1
    git fetch origin >/dev/null 2>&1
    git merge-base --is-ancestor origin/master "origin/$WORKING_BRANCH"
); then
    pass "--continue: working branch contains origin/master"
else
    fail "--continue: working branch missing origin/master"
fi

if (
    cd "$TMP_DIR/clone-a" || exit 1
    ! git rev-parse --verify "$RECONCILE_BRANCH" >/dev/null 2>&1
); then
    pass "--continue: reconcile branch cleaned up"
else
    fail "--continue: reconcile branch still exists"
fi

rm -rf "$TMP_DIR"

# --- Rerun safety: re-running normal mode during an in-progress rebase does not clobber ---
echo ""
echo "--- Reentry safety (in-progress rebase) ---"
TMP_DIR=$(mktemp -d /tmp/reconcile-see1042.XXXXXX)
prepare_origin "$TMP_DIR"
clone_wt "$TMP_DIR/origin.git" "$TMP_DIR/clone-a"
(
    cd "$TMP_DIR/clone-a" || exit 1
    git checkout master >/dev/null 2>&1
    echo "line one" > conflict.txt
    git add conflict.txt
    git commit -m "master adds conflict.txt" >/dev/null 2>&1
    git push origin HEAD:master >/dev/null 2>&1
    git checkout "$WORKING_BRANCH" >/dev/null 2>&1
    echo "line two" > conflict.txt
    git add conflict.txt
    git commit -m "wb adds conflict.txt" >/dev/null 2>&1
    git push origin HEAD:refs/heads/"$WORKING_BRANCH" >/dev/null 2>&1
)
# First run leaves reconcile/<wb> mid-rebase.
run_reconcile "$TMP_DIR/clone-a" >/dev/null 2>&1 || true
# A second normal run must NOT branch -D the in-progress branch — it exits 1
# (still in conflict) and keeps the branch so human resolution is preserved.
run_reconcile "$TMP_DIR/clone-a" >/dev/null 2>&1; code=$?
if [ "$code" -eq 1 ]; then
    pass "reentry: second normal run exits 1 (does not clobber in-progress rebase)"
else
    fail "reentry: expected exit 1 on rerun during rebase (got $code)"
fi
if (
    cd "$TMP_DIR/clone-a" || exit 1
    git rev-parse --verify "$RECONCILE_BRANCH" >/dev/null 2>&1
); then
    pass "reentry: reconcile branch still present after rerun"
else
    fail "reentry: reconcile branch was wrongly deleted by rerun"
fi

rm -rf "$TMP_DIR"

# --- Lease-race path: first reconciler fails lease when another commit lands during reconcile ---
# This triggers exit 2 (lease lost), not exit 1 (conflict), and is rerunnable.
echo ""
echo "--- Lease race ---"
TMP_DIR=$(mktemp -d /tmp/reconcile-see1042.XXXXXX)
prepare_origin "$TMP_DIR"
clone_wt "$TMP_DIR/origin.git" "$TMP_DIR/clone-a"
clone_wt "$TMP_DIR/origin.git" "$TMP_DIR/clone-racer"
(
    cd "$TMP_DIR/clone-racer" || exit 1
    git checkout "$WORKING_BRANCH" >/dev/null 2>&1
    echo "racer" > racer.txt
    git add racer.txt
    git commit -m "racer commit" >/dev/null 2>&1
)
(
    cd "$TMP_DIR/clone-a" || exit 1
    git checkout "$WORKING_BRANCH" >/dev/null 2>&1
    echo "a" > wb-only.txt
    git commit -am "a" >/dev/null 2>&1
    git push origin HEAD:refs/heads/"$WORKING_BRANCH" >/dev/null 2>&1

    # Pre-push hook: inject a racer commit into the remote so the script's lease fails.
    # The hook runs in git's child-process environment, which does NOT inherit
    # shell variables from the test unless they are exported. To avoid relying on
    # $TMP_DIR being visible at hook runtime, we bake the literal path here during
    # heredoc expansion (leave $WORKING_BRANCH unescaped, drop the \ before $TMP_DIR).
    cat > .git/hooks/pre-push <<EOF
#!/bin/bash
set -e
exec >&2
if [ -f "$TMP_DIR/.race_done" ]; then
    exit 0
fi
# Racer pushes a new commit to origin while the script is about to push.
git -C "$TMP_DIR/clone-racer" push origin HEAD:refs/heads/"$WORKING_BRANCH" >/dev/null 2>&1
touch "$TMP_DIR/.race_done"
EOF
    chmod +x .git/hooks/pre-push
)

run_reconcile "$TMP_DIR/clone-a" >/dev/null 2>&1; code=$?
if [ "$code" -eq 2 ]; then
    pass "lease race: reconcile exits 2 (lease lost)"
else
    fail "lease race: expected exit 2 (got $code)"
fi

rm -rf "$TMP_DIR"

# --- Worktree compatibility: .git is a file ---
echo ""
echo "--- Worktree compatibility ---"
TMP_DIR=$(mktemp -d /tmp/reconcile-see1042.XXXXXX)
prepare_origin "$TMP_DIR"
clone_wt "$TMP_DIR/origin.git" "$TMP_DIR/clone-a"
WORKTREE_PATH="$TMP_DIR/wt"
# Add a detached worktree (not a branch already checked out in the clone) so
# Git creates an independent .git file.
(
    cd "$TMP_DIR/clone-a" || exit 1
    git worktree add --no-checkout -b "reconcile/wt-test" "$WORKTREE_PATH" >/dev/null 2>&1
    git -C "$WORKTREE_PATH" checkout "$WORKING_BRANCH" >/dev/null 2>&1
)
if [ -f "$WORKTREE_PATH/.git" ] && [ ! -d "$WORKTREE_PATH/.git" ]; then
    pass "worktree: .git is a file as expected"
else
    fail "worktree: .git is not a file"
fi
if (
    cd "$WORKTREE_PATH" || exit 1
    bash "$SCRIPT" "$WORKING_BRANCH" >/dev/null 2>&1
); then
    pass "worktree: script runs when .git is a file"
else
    fail "worktree: script failed when .git is a file"
fi

rm -rf "$TMP_DIR"

echo ""
echo "=== RESULTS: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
