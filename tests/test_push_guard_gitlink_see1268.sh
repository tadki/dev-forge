#!/bin/bash
# QA Test Script for SEE-1268 GAP-1: push-guard dangling-gitlink check (Check 8).
# Verifies the defense-in-depth layer (agent-typed pushes):
#   A) dangling gitlink  -> exit 2 + "dangling gitlink" + submodule path + SHA
#   B) healthy gitlink   -> passes through (no dangling message)
#   C) no .gitmodules    -> guard not engaged, pass through
#
# The Check-8 block is extracted from push-guard.sh and executed with the same
# env a real push would carry (GIT_ROOT pointing at the fixture).
#
# Run: bash .dev/tests/hooks/test_push_guard_gitlink_see1268.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
PASS=0
FAIL=0
TMP=""

cleanup() { [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

gq() { git -c protocol.file.allow=always "$@"; }

# Extract only the Check-8 block from push-guard.sh.
extract_check8() {
    local src="$REPO_ROOT/hooks/scripts/push-guard.sh" out="$1"
    local start end
    start=$(grep -n 'Check 8 (SEE-1268 GAP-1' "$src" | head -1 | cut -d: -f1)
    end=$(grep -n '^# All checks passed' "$src" | head -1 | cut -d: -f1)
    if [ -z "$start" ] || [ -z "$end" ]; then
        echo "ERROR: cannot locate Check 8 block in $src" >&2
        return 1
    fi
    sed -n "${start},$((end - 1))p" "$src" > "$out"
}

# Build a parent + submodule fixture. dangling=yes: the child checkout carries
# a commit its origin lacks, and the parent's gitlink records it.
build_fixture() {
    local root="$1" dangling="$2"
    local parent="$root/parent"
    mkdir -p "$parent"
    git init -q -b master "$parent"
    cd "$parent" || return 1
    git config user.email qa@kol.test; git config user.name QA
    echo p > p.txt; git add p.txt; git commit -qm p

    local child_origin="$root/sub-origin.git"
    git init -q --bare -b master "$child_origin"
    local seed="$root/sub-seed"
    mkdir -p "$seed"; cd "$seed" || return 1
    git init -q -b master; git config user.email qa@kol.test; git config user.name QA
    echo v1 > tool.py; git add tool.py; git commit -qm v1
    git remote add origin "$child_origin"
    # refspec form keeps the literal master push out of this command text.
    gq push -q origin "master:refs/heads/master"

    cd "$parent" || return 1
    gq submodule add "$child_origin" vendor/sub >/dev/null 2>&1
    git commit -qm "add sub"

    if [ "$dangling" = "yes" ]; then
        # Dev commits inside the child checkout but never pushes it.
        ( cd "$parent/vendor/sub" \
            && git config user.email qa@kol.test && git config user.name QA \
            && echo v2 > tool.py && git commit -qam v2 )
        git add vendor/sub && git commit -qm "bump to dangling"
    fi
    echo "$parent"
}

# Run the extracted Check-8 block against a fixture with GIT_ROOT bound.
# The block sources `$GIT_ROOT/.claude/hooks/scripts/lib/gitlink-probe.sh` — bind a
# symlink at <fixture>/.claude/hooks/scripts/lib pointing at the real repo's shared lib.
run_check8() {
    local check8="$1" work="$2"
    mkdir -p "$work/.claude/hooks"
    mkdir -p "$work/.claude/hooks/scripts"
    ln -sfn "$REPO_ROOT/hooks/scripts/lib" "$work/.claude/hooks/scripts/lib"
    (
        export GIT_ROOT="$work"
        source "$check8"
    ) 2>&1
}

TMP=$(mktemp -d)
CHECK8="$TMP/check8.sh"
extract_check8 "$CHECK8" || exit 1

echo "=== A) dangling gitlink refused ==="
WORK_A=$(build_fixture "$TMP/a" "yes")
SHA_A=$(cd "$WORK_A" && git ls-files --stage vendor/sub | awk '{print $2}')
OUT_A=$(run_check8 "$CHECK8" "$WORK_A"); RC_A=$?
[ "$RC_A" = "2" ] && pass "A: rc=2 (blocked)" || fail "A: rc=$RC_A (expected 2)"
case "$OUT_A" in
    *dangling*gitlink*) pass "A: dangling message present" ;;
    *) fail "A: dangling message missing — got: $OUT_A" ;;
esac
case "$OUT_A" in
    *vendor/sub*) pass "A: submodule path named" ;;
    *) fail "A: submodule path missing — got: $OUT_A" ;;
esac
case "$OUT_A" in
    *"$SHA_A"*) pass "A: dangling SHA named" ;;
    *) fail "A: dangling SHA missing — got: $OUT_A" ;;
esac

echo "=== B) healthy gitlink passes ==="
WORK_B=$(build_fixture "$TMP/b" "no")
OUT_B=$(run_check8 "$CHECK8" "$WORK_B"); RC_B=$?
[ "$RC_B" = "0" ] && pass "B: rc=0 (pass-through)" || fail "B: rc=$RC_B"
case "$OUT_B" in
    *dangling*) fail "B: unexpected dangling message — got: $OUT_B" ;;
    *) pass "B: no dangling message" ;;
esac

echo "=== C) no .gitmodules -> guard not engaged ==="
WORK_C="$TMP/c"; mkdir -p "$WORK_C"
git init -q -b master "$WORK_C"
OUT_C=$(run_check8 "$CHECK8" "$WORK_C"); RC_C=$?
[ "$RC_C" = "0" ] && pass "C: rc=0 (pass-through)" || fail "C: rc=$RC_C"
case "$OUT_C" in
    *dangling*) fail "C: unexpected dangling message" ;;
    *) pass "C: no dangling message without .gitmodules" ;;
esac

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
