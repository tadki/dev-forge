#!/bin/bash
# QA Test Script for SEE-1268 §7.4(d): auto-pr gitlink 条件保留 — FULL SEQUENCE.
# Replicates the REAL hook order (code-review MEDIUM-1): 判定块 → git add -A →
# 后置 unstage, then asserts on `git diff --cached --name-status`.
#   A) healthy pointer ADVANCED (≠HEAD) -> retained (staged for commit)
#   B) dangling -> NOT staged (stripped for real)
#   C) uninit '-' -> deletion NOT staged, gitlink stays in index
#   D) 无 .gitmodules -> zero-engagement
# Run: bash .dev/tests/hooks/test_auto_pr_gitlink_see1268.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
PASS=0; FAIL=0; TMP=""
cleanup() { [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
gq() { git -c protocol.file.allow=always "$@"; }

# Extract the (d) sequence: 判定块 + `git add -A` + 后置 gitlink unstage.
# Ends right before the SEE-905 screenshots unstage (out of scope).
extract_d_sequence() {
    local src="$REPO_ROOT/claude-hooks/scripts/auto-pr-on-stop.sh" out="$1"
    local start end
    start=$(grep -n 'SEE-1268 §7.4(d) gitlink 条件保留' "$src" | head -1 | cut -d: -f1)
    end=$(grep -n '^  # Unstage godot-mcp E2E screenshots' "$src" | head -1 | cut -d: -f1)
    if [ -z "$start" ] || [ -z "$end" ]; then
        echo "ERROR: cannot locate (d) sequence in $src" >&2; return 1
    fi
    sed -n "${start},$((end - 1))p" "$src" > "$out"
}

# Build parent + submodule fixture. mode: healthy_advanced | dangling | uninit
build_fixture() {
    local root="$1" mode="$2"
    local parent="$root/parent"
    mkdir -p "$parent"; git init -q -b master "$parent"
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
    gq push -q origin "master:refs/heads/master"

    cd "$parent" || return 1
    gq submodule add "$child_origin" vendor/sub >/dev/null 2>&1
    git commit -qm "add sub"

    case "$mode" in
      healthy_advanced)
        # Advance the child, push it, and move the parent's checkout to v2 so
        # the working-tree gitlink (v2) differs from HEAD's recorded v1.
        ( cd "$parent/vendor/sub" \
            && git config user.email qa@kol.test && git config user.name QA \
            && echo v2 > tool.py && git commit -qam v2 \
            && gq push -q origin "master:refs/heads/master" )
        ;;
      dangling)
        ( cd "$parent/vendor/sub" \
            && git config user.email qa@kol.test && git config user.name QA \
            && echo v2 > tool.py && git commit -qam v2 )
        ;;
      uninit)
        gq submodule deinit -f vendor/sub >/dev/null 2>&1
        rm -rf "$parent/vendor/sub"
        ;;
    esac
    echo "$parent"
}

# Run the full (d) sequence in the fixture cwd.
run_d_sequence() {
    local seq="$1" work="$2"
    mkdir -p "$work/.claude/hooks"
    mkdir -p "$work/.claude/hooks/scripts"
    ln -sfn "$REPO_ROOT/claude-hooks/scripts/lib" "$work/.claude/hooks/scripts/lib"
    (
        cd "$work"
        source "$seq"
    ) 2>&1
}

TMP=$(mktemp -d)
SEQ="$TMP/d-seq.sh"
extract_d_sequence "$SEQ" || exit 1

echo "=== A) healthy advanced pointer retained (staged) ==="
WORK_A=$(build_fixture "$TMP/a" "healthy_advanced")
cd "$WORK_A" || exit 1
# Precondition: working-tree gitlink differs from HEAD (real pointer advance).
PRE_A=$(git diff --name-only -- vendor/sub)
[ -n "$PRE_A" ] && pass "A: precondition pointer advanced (differs from HEAD)" \
              || fail "A: fixture did not advance the pointer"
OUT_A=$(run_d_sequence "$SEQ" "$WORK_A"); RC_A=$?
[ "$RC_A" = "0" ] && pass "A: sequence rc=0" || fail "A: rc=$RC_A"
STAGED_A=$(git diff --cached --name-only -- vendor/sub)
[ -n "$STAGED_A" ] && pass "A: healthy pointer retained in index (will be committed)" \
                   || fail "A: healthy pointer was stripped from the commit"
case "$OUT_A" in
    *剥离*) fail "A: unexpected strip warning — got: $OUT_A" ;;
    *) pass "A: no strip warning for healthy" ;;
esac

echo "=== B) dangling stripped for real (NOT staged) ==="
WORK_B=$(build_fixture "$TMP/b" "dangling")
cd "$WORK_B" || exit 1
SHA_B=$(git -C vendor/sub rev-parse HEAD)
OUT_B=$(run_d_sequence "$SEQ" "$WORK_B")
case "$OUT_B" in
    *dangling*gitlink*剥离*) pass "B: dangling strip warning present" ;;
    *) fail "B: dangling warning missing — got: $OUT_B" ;;
esac
case "$OUT_B" in
    *"$SHA_B"*) pass "B: dangling SHA named" ;;
    *) fail "B: SHA missing — got: $OUT_B" ;;
esac
STAGED_B=$(git diff --cached --name-status -- vendor/sub)
[ -z "$STAGED_B" ] && pass "B: dangling pointer NOT staged (stripped for real)" \
                   || fail "B: dangling pointer still staged — got: $STAGED_B"

echo "=== C) uninit '-' deletion NOT staged, gitlink stays in index ==="
WORK_C=$(build_fixture "$TMP/c" "uninit")
cd "$WORK_C" || exit 1
OUT_C=$(run_d_sequence "$SEQ" "$WORK_C")
case "$OUT_C" in
    *未初始化*) pass "C: uninit warning present" ;;
    *) fail "C: uninit warning missing — got: $OUT_C" ;;
esac
case "$OUT_C" in
    *dangling*gitlink*) fail "C: uninit mislabeled dangling — got: $OUT_C" ;;
    *) pass "C: not labeled dangling" ;;
esac
STAGED_C=$(git diff --cached --name-status -- vendor/sub)
case "$STAGED_C" in
    D*vendor/sub*) fail "C: submodule deletion was staged (data-loss path) — got: $STAGED_C" ;;
    *) pass "C: submodule deletion NOT staged" ;;
esac
GITLINK_C=$(git ls-files --stage 2>/dev/null | grep -c '^160000' || true)
[ "$GITLINK_C" -eq 1 ] && pass "C: gitlink still in index" \
                       || fail "C: gitlink lost from index (count=$GITLINK_C)"

echo "=== D) no .gitmodules -> zero-engagement ==="
WORK_D="$TMP/d"; mkdir -p "$WORK_D"; git init -q -b master "$WORK_D"
OUT_D=$(run_d_sequence "$SEQ" "$WORK_D"); RC_D=$?
[ "$RC_D" = "0" ] && pass "D: rc=0" || fail "D: rc=$RC_D"
case "$OUT_D" in
    *剥离*|*dangling*|*未初始化*) fail "D: unexpected engagement — got: $OUT_D" ;;
    *) pass "D: no engagement without .gitmodules" ;;
esac

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
