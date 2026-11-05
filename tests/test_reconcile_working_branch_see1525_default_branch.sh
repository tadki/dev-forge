#!/bin/bash
# QA Test for SEE-1525 (dev-forge): reconcile-working-branch.sh must resolve the
# rebase base per-repo (origin default branch), never hardcode origin/master.
#
# Companion to tests/test_repo_checkout_see1525_default_branch.sh (§B fix).
# This script is the Leader manual conflict-recovery tool: on a main-default
# repo (dev-forge itself) `git rebase origin/master` can never succeed, and in
# normal mode an unresolvable base must stop LOUDLY before touching state.
#
# Scenarios:
#   A. main-default repo, shared branch behind origin/main → normal reconcile:
#      exit 0, origin/<wb> contains origin/main, completion message names the
#      resolved branch, lease file + reconcile branch cleaned up.
#   B. default branch unresolvable (origin/HEAD absent + ls-remote failing) →
#      hard error exit 3 with readable message, origin/<wb> untouched, no
#      reconcile branch created (never rebase a guessed base).
#   C. master-default repo, shared branch behind origin/master → legacy
#      behavior unchanged (exit 0, rebased onto origin/master).
#   D. static: no executable `git rebase origin/master` remains.
#
# Run: bash tests/test_reconcile_working_branch_see1525_default_branch.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
SCRIPT="$REPO_ROOT/scripts/reconcile-working-branch.sh"
TMPDIR=""
PASS=0
FAIL=0

cleanup() {
    if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
        rm -rf "$TMPDIR"
    fi
}
trap cleanup EXIT

fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }

# git passthrough shim that makes the default-branch SYMREF lookup fail
# (simulates an origin that cannot report its HEAD symref), used only inside
# scenario B's script invocation. Deliberately narrow: plain ls-remote queries
# (branch existence checks) must keep working so the scenario exercises the
# resolution chain, not unrelated guards.
make_no_lsremote_git_shim() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/git" <<EOF
#!/bin/bash
if [ "\$1" = "ls-remote" ] && [ "\${2:-}" = "--symref" ]; then
    exit 1
fi
exec "$(command -v git)" "\$@"
EOF
    chmod +x "$bin_dir/git"
}

# Bare origin whose default branch is $3 + working clone.
#   <default>: m1 -> m2 (m2 = tip)
build_fixture() {
    local root="$1" name="$2" default_branch="$3"
    local remote="$root/origin.git"
    local work="$root/work/$name"

    mkdir -p "$root/work"
    git init --bare --quiet "$remote"
    git -C "$remote" symbolic-ref HEAD "refs/heads/$default_branch"
    git init --quiet "$work"
    (
        cd "$work"
        git config user.email "qa@devforge.test"
        git config user.name "QA"
        git remote add origin "$remote"
        echo "line1" > f.txt
        git add f.txt
        git commit -qm "m1"
        git branch -M "$default_branch"
        git push -q origin "$default_branch"
        echo "line2" >> f.txt
        git add f.txt
        git commit -qm "m2"
        git push -q origin "$default_branch"
    )
    echo "$work"
}

# Create origin/<wb> at a given commit of the default branch.
# point: m1 (behind) | m2 (== tip).
ensure_shared_branch() {
    local work="$1" branch_name="$2" default_branch="$3" point="$4"
    (
        cd "$work"
        git checkout -q "$default_branch"
        if [ "$point" = "m2" ]; then
            git checkout -qb "$branch_name"
        else
            git checkout -qb "$branch_name" "$default_branch~1"
        fi
        git push -q origin "$branch_name"
        git checkout -q "$default_branch"
    )
}

# Run the reconcile script from inside the working clone.
#   extra_path (arg 5): optional PATH prefix (git shim dir).
run_reconcile() {
    local work="$1" wb="$2" extra_path="${3:-}"
    (
        export PATH="${extra_path:+$extra_path:}$PATH"
        export PROJECT_ROOT="$work"
        cd "$work"
        bash "$SCRIPT" "$wb" 2>&1
    )
}

# --- Scenario A: main-default normal reconcile ---
test_main_repo_reconcile() {
    echo "[A] main-default repo: reconcile rebases onto origin/main"
    local work
    work=$(build_fixture "$TMPDIR/a" "DevForge" "main")
    ensure_shared_branch "$work" "shared/SEE-1525" "main" "m2"
    # Advance origin/main so the shared branch is behind (real reconcile needed).
    (cd "$work" \
        && git checkout -q main \
        && echo "main_line3" >> f.txt && git add f.txt && git commit -qm "m3" \
        && git push -q origin main)

    local out rc
    out=$(run_reconcile "$work" "shared/SEE-1525")
    rc=$?

    if [ "$rc" -eq 0 ]; then
        pass "exit 0"
    else
        fail "expected exit 0, got $rc; output: $out"
    fi
    if (cd "$work" && git merge-base --is-ancestor "origin/main" "origin/shared/SEE-1525"); then
        pass "origin/shared/SEE-1525 now contains origin/main (rebased on resolved default)"
    else
        fail "reconcile did not rebase shared branch onto origin/main"
    fi
    if echo "$out" | grep -q 'origin/main'; then
        pass "completion message names the resolved default branch (origin/main)"
    else
        fail "completion message should name origin/main; output: $out"
    fi
    if echo "$out" | grep -q 'origin/master'; then
        fail "output still mentions origin/master"
    else
        pass "no origin/master anywhere in output"
    fi
    if (cd "$work" && git rev-parse --verify "reconcile/shared-SEE-1525" >/dev/null 2>&1); then
        fail "reconcile branch not cleaned up"
    else
        pass "reconcile branch cleaned up"
    fi
    local lease
    lease="$(cd "$work" && git rev-parse --git-dir)/reconcile_lease_shared-SEE-1525"
    if [ -f "$lease" ]; then
        fail "lease file not cleaned up: $lease"
    else
        pass "lease file cleaned up"
    fi
}

# --- Scenario B: unresolvable default branch → loud hard error ---
test_unresolvable_hard_error() {
    echo "[B] unresolvable default: hard error exit 3, no rebase, no state change"
    local shim="$TMPDIR/shim_b"
    make_no_lsremote_git_shim "$shim"
    local work
    work=$(build_fixture "$TMPDIR/b" "DevForge" "main")
    ensure_shared_branch "$work" "shared/SEE-1525" "main" "m2"
    (cd "$work" \
        && git checkout -q main \
        && echo "main_line3" >> f.txt && git add f.txt && git commit -qm "m3" \
        && git push -q origin main \
        && { git symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null || true; })
    local wb_before
    wb_before=$(cd "$work" && git rev-parse "origin/shared/SEE-1525")

    local out rc
    out=$(run_reconcile "$work" "shared/SEE-1525" "$shim")
    rc=$?

    if [ "$rc" -eq 3 ]; then
        pass "exit 3 (hard error)"
    else
        fail "expected exit 3, got $rc; output: $out"
    fi
    if echo "$out" | grep -q '无法解析 origin 默认分支'; then
        pass "readable hard-error message emitted"
    else
        fail "expected 无法解析 origin 默认分支 message; output: $out"
    fi
    local wb_after
    wb_after=$(cd "$work" && git rev-parse "origin/shared/SEE-1525")
    if [ "$wb_before" = "$wb_after" ]; then
        pass "origin/shared/SEE-1525 untouched (no rebase against a guessed base)"
    else
        fail "shared branch was rewritten: $wb_before -> $wb_after"
    fi
    if (cd "$work" && git rev-parse --verify "reconcile/shared-SEE-1525" >/dev/null 2>&1); then
        fail "reconcile branch created despite unresolvable base"
    else
        pass "no reconcile branch created"
    fi
}

# --- Scenario C: master-default repo unchanged ---
test_master_repo_unchanged() {
    echo "[C] master-default repo: legacy reconcile onto origin/master preserved"
    local work
    work=$(build_fixture "$TMPDIR/c" "KingOfLikes-Godot" "master")
    ensure_shared_branch "$work" "shared/SEE-1008" "master" "m1"   # behind master (m2)

    local out rc
    out=$(run_reconcile "$work" "shared/SEE-1008")
    rc=$?

    if [ "$rc" -eq 0 ]; then
        pass "exit 0"
    else
        fail "expected exit 0, got $rc; output: $out"
    fi
    if (cd "$work" && git merge-base --is-ancestor "origin/master" "origin/shared/SEE-1008"); then
        pass "origin/shared/SEE-1008 still rebased onto origin/master"
    else
        fail "master-default reconcile behavior regressed"
    fi
}

# --- Static: no executable hardcoded rebase base remains ---
test_no_hardcoded_rebase_base() {
    echo "[STATIC] reconcile rebase base resolves per-repo (no origin/master hardcode)"
    local code_lines
    code_lines=$(grep -vE '^\s*(#.*)?$' "$SCRIPT" | grep -n 'rebase origin/master')
    if [ -n "$code_lines" ]; then
        fail "hardcoded origin/master rebase base still present in executable lines: $code_lines"
    else
        pass "no hardcoded origin/master rebase in executable lines"
    fi
    if bash -n "$SCRIPT"; then
        pass "bash -n clean"
    else
        fail "bash -n failed"
    fi
}

TMPDIR=$(mktemp -d -t see1525-recon-XXXXXX)

echo "======================================================"
echo "SEE-1525 QA: reconcile-working-branch default branch"
echo "======================================================"

test_no_hardcoded_rebase_base
test_main_repo_reconcile
test_unresolvable_hard_error
test_master_repo_unchanged

echo ""
echo "======================================================"
echo "RESULT: PASS=$PASS FAIL=$FAIL"
echo "======================================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
