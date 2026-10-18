#!/bin/bash
# QA Test Script for SEE-1268: repo-checkout.sh submodule materialization fallback.
# Verifies ensure_submodules_materialized inside the align flow:
#   A) .gitmodules absent  -> no-op, align succeeds, no submodule hint
#   B) .gitmodules present, child content missing -> materialized after align
#   C) corrupt submodule URL -> align still succeeds, hint emitted (best-effort)
#
# Run: bash .dev/tests/hooks/test_repo_checkout_submodule_see1268.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
TMPDIR=""
PASS=0
FAIL=0

cleanup() {
    [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ] && rm -rf "$TMPDIR"
}
trap cleanup EXIT

fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }

gq() { git -c protocol.file.allow=always "$@"; }

# Extract the align function + SEE-1268 helper from the current repo-checkout.sh
# (everything from output_hint through align_agent_branch_to_working_branch's
# closing brace, plus the ensure_submodules_materialized block).
extract_helper_lib() {
    local src="$REPO_ROOT/claude-hooks/scripts/repo-checkout.sh"
    local out_file="$1"
    local end_line
    end_line=$(grep -n '^try_auto_create_shared_branch()' "$src" | head -1 | cut -d: -f1)
    if [ -z "$end_line" ]; then
        echo "ERROR: cannot locate lib boundary in $src" >&2
        return 1
    fi
    sed -n "15,$((end_line - 1))p" "$src" > "$out_file"
    # `maybe_early_exit_if_aligned` lives after the align helpers and before the
    # hook's top-level entry code — appended separately so the re-entrancy fast
    # path (which also materializes submodules) is covered.
    local early_start early_end
    early_start=$(grep -n '^maybe_early_exit_if_aligned()' "$src" | head -1 | cut -d: -f1)
    early_end=$(grep -n '^# --- Determine expected repo directory ---' "$src" | head -1 | cut -d: -f1)
    if [ -n "$early_start" ] && [ -n "$early_end" ]; then
        sed -n "${early_start},$((early_end - 1))p" "$src" >> "$out_file"
    fi
}

# Fixture: bare origin + working clone "KingOfLikes-Godot" on master, with an
# optional submodule. With_sub = "yes" adds vendor/subtool (bare child origin).
build_fixture() {
    local root="$1" with_sub="$2"
    local remote="$root/origin.git"
    local work="$root/work/KingOfLikes-Godot"

    mkdir -p "$root/work"
    git init --bare --quiet "$remote"

    if [ "$with_sub" = "yes" ]; then
        local sub_origin="$root/sub.git"
        git init --bare --quiet "$sub_origin"
        local seed="$root/sub-seed"
        mkdir -p "$seed"
        cd "$seed"
        git init -q -b master
        git config user.email "qa@kol.test"; git config user.name "QA"
        echo "TOOL_V1 = 1" > tool.py
        git add tool.py && git commit -qm "sub v1"
        git remote add origin "$sub_origin"
        gq push -q origin master
    fi

    git init -q -b master "$work"
    cd "$work"
    git config user.email "qa@kol.test"; git config user.name "QA"
    echo "line1" > f.txt
    git add f.txt
    git commit -qm "m1"
    git remote add origin "$remote"
    gq push -q origin master

    if [ "$with_sub" = "yes" ]; then
        gq submodule add "$root/sub.git" vendor/subtool >/dev/null 2>&1
        git commit -qm "m2 with submodule"
        gq push -q origin master
    fi
    echo "$work"
}

# Run the align flow in a subshell (it exits 0 internally) and capture hints.
# GIT_CONFIG_* env re-allows the file transport (CVE-2022-39253 hardening) for
# the local-path fixture remotes — the hook itself stays protocol-strict and
# production remotes are https.
run_align() {
    local helper_lib="$1" work="$2" wb="$3"
    (
        export GIT_CONFIG_COUNT=1
        export GIT_CONFIG_KEY_0=protocol.file.allow
        export GIT_CONFIG_VALUE_0=always
        source "$helper_lib"
        cd "$work"
        align_agent_branch_to_working_branch "$work" "$wb" "SUCCESS" "REBASE_FAIL"
    ) 2>&1
}

hint_text() { echo "$1" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }

TMPDIR=$(mktemp -d)
HELPER_LIB="$TMPDIR/helper-lib.sh"
extract_helper_lib "$HELPER_LIB" || { echo "FATAL: lib extraction failed"; exit 1; }
# Drop the exit-bound log/marker lines not needed for the lib context is not
# possible — run_align sources it whole; helpers above try_auto_create are
# self-contained.

echo "=== A) align succeeds without .gitmodules; no submodule fallback noise ==="
WORK_A=$(build_fixture "$TMPDIR/a" "no")
cd "$WORK_A" || exit 1
git checkout -qb shared/qa1268 origin/master 2>/dev/null || git checkout -qb shared/qa1268
gq push -q origin shared/qa1268
OUT_A=$(run_align "$HELPER_LIB" "$WORK_A" "shared/qa1268")
RC_A=$?
[ "$RC_A" = "0" ] && pass "A: align rc=0" || fail "A: align rc=$RC_A"
HINT_A=$(hint_text "$OUT_A")
case "$HINT_A" in
    *SUCCESS*) pass "A: success hint present" ;;
    *) fail "A: success hint missing — got: $HINT_A" ;;
esac
case "$OUT_A" in
    *submodule*) fail "A: unexpected submodule mention" ;;
    *) pass "A: no submodule hint without .gitmodules" ;;
esac

echo "=== B) submodule content materialized by align ==="
WORK_B=$(build_fixture "$TMPDIR/b" "yes")
cd "$WORK_B" || exit 1
git checkout -qb shared/qa1268 origin/master 2>/dev/null || git checkout -qb shared/qa1268
gq push -q origin shared/qa1268
# Simulate the multica checkout gap: worktree has the gitlink but no content.
gq submodule deinit -f vendor/subtool >/dev/null 2>&1
rm -rf vendor
rm -rf .git/modules/vendor
[ -f vendor/subtool/tool.py ] && fail "B: pre-state should lack child content" \
                              || pass "B: pre-state lacks child content"
OUT_B=$(run_align "$HELPER_LIB" "$WORK_B" "shared/qa1268")
RC_B=$?
[ "$RC_B" = "0" ] && pass "B: align rc=0" || fail "B: align rc=$RC_B"
[ -f vendor/subtool/tool.py ] && pass "B: child content materialized by align" \
                              || fail "B: child content still missing after align"
HINT_B=$(hint_text "$OUT_B")
case "$HINT_B" in
    *SUCCESS*) pass "B: success hint present" ;;
    *) fail "B: success hint missing — got: $HINT_B" ;;
esac

echo "=== C) broken submodule origin: align survives, hint carries failure ==="
WORK_C=$(build_fixture "$TMPDIR/c" "yes")
cd "$WORK_C" || exit 1
git checkout -qb shared/qa1268 origin/master 2>/dev/null || git checkout -qb shared/qa1268
gq push -q origin shared/qa1268
gq submodule deinit -f vendor/subtool >/dev/null 2>&1
rm -rf vendor
rm -rf .git/modules/vendor
# Point .gitmodules at a nonexistent origin so the update fails loudly.
git config -f .gitmodules submodule.vendor/subtool.url "$TMPDIR/c/nonexistent.git"
OUT_C=$(run_align "$HELPER_LIB" "$WORK_C" "shared/qa1268")
RC_C=$?
[ "$RC_C" = "0" ] && pass "C: align rc=0 despite submodule failure" || fail "C: align rc=$RC_C"
case "$OUT_C" in
    *submodule*兜底失败*) pass "C: failure hint emitted (no silent skip)" ;;
    *) fail "C: expected submodule failure hint — got: $(hint_text "$OUT_C")" ;;
esac

echo "=== D) re-entrancy fast path still materializes submodules ==="
# The SessionStart early-exit skips the align flow; if it did not materialize,
# an agent would get a broken addon whenever its align marker was still fresh.
WORK_D=$(build_fixture "$TMPDIR/d" "yes")
cd "$WORK_D" || exit 1
git checkout -qb shared/qa1268 origin/master 2>/dev/null || git checkout -qb shared/qa1268
gq push -q origin shared/qa1268
gq submodule deinit -f vendor/subtool >/dev/null 2>&1
rm -rf vendor
rm -rf .git/modules/vendor
# Fresh align marker so the fast path engages (same encoding the hook uses).
DIR_ENC="$(pwd)"; DIR_ENC="${DIR_ENC////_}"; DIR_ENC="${DIR_ENC// /_}"
mkdir -p "$TMPDIR/tmpdir"; touch "$TMPDIR/tmpdir/.cc-aligned-${DIR_ENC}"
OUT_D=$(
    export TEMP="$TMPDIR/tmpdir"
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
    source "$HELPER_LIB"
    cd "$WORK_D"
    maybe_early_exit_if_aligned "$WORK_D"
) 2>&1
RC_D=$?
[ "$RC_D" = "0" ] && pass "D: early-exit rc=0" || fail "D: early-exit rc=$RC_D"
[ -f vendor/subtool/tool.py ] && pass "D: fast path materialized submodule content" \
                              || fail "D: fast path left submodule content missing"
HINT_D=$(hint_text "$OUT_D")
case "$HINT_D" in
    *跳过自动检出*) pass "D: early-exit hint still emitted" ;;
    *) fail "D: early-exit hint missing — got: $HINT_D" ;;
esac

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
