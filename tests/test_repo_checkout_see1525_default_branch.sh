#!/bin/bash
# QA Test for SEE-1525 (dev-forge): repo-checkout.sh §B auto-rebase base must be
# resolved per-repo (origin default branch), never hardcoded to origin/master.
#
# Root cause fixed here: on a main-default repo (dev-forge itself), the old §B
# `git merge-base --is-ancestor origin/master <wb>` failed with 128 (ref absent)
# and was misread as "shared branch behind" → rebase origin/master failed →
# phantom blocked_reason=auto-rebase-conflict-* + waiting_on=leader-reconcile
# pinned on the issue (8 false alarms during SEE-1525 on the gqt repo alone).
#
# Scenarios:
#   A. main-default repo, shared branch == origin/main → plain reset, NO §B
#      attempt, NO metadata pinning, NO conflict hint (phantom regression).
#   B. main-default repo, shared branch behind origin/main → real rebase onto
#      origin/main, first-agent-wins push, HEAD aligned.
#   C. default branch unresolvable (origin/HEAD absent + ls-remote failing) →
#      explicit safe degrade: §B skipped with readable hint, NO rebase, NO
#      metadata pinning, HEAD still aligned to origin/<wb>.
#   D. master-default repo, shared branch behind origin/master → unchanged
#      legacy behavior (rebase onto origin/master succeeds).
#
# Run: bash tests/test_repo_checkout_see1525_default_branch.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
HOOK="$REPO_ROOT/claude-hooks/scripts/repo-checkout.sh"
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

jq_context() {
    echo "$1" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}

# Extract the helper lib (output_hint … align_agent_branch_to_working_branch)
# from the LIVE hook file, mirroring the SEE-1008 harness convention.
extract_helper_lib() {
    local out_file="$1"
    local end_line
    end_line=$(grep -n '^try_auto_create_shared_branch()' "$HOOK" | head -1 | cut -d: -f1)
    if [ -z "$end_line" ]; then
        echo "ERROR: extraction boundary not found in $HOOK" >&2
        return 1
    fi
    sed -n "8,$((end_line - 1))p" "$HOOK" > "$out_file"
}

# Mock multica: resolve_issue_id Path 0 succeeds (so the §B conflict path WOULD
# pin metadata if reached — makes the zero-pinning assertions meaningful), and
# every `issue metadata set` is logged to $META_LOG.
make_mock_multica() {
    local bin_dir="$1" meta_log="$2"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/multica" <<EOF
#!/bin/bash
if [ "\$1" = "issue" ] && [ "\$2" = "metadata" ] && [ "\$3" = "set" ]; then
    echo "\$*" >> "$meta_log"
    exit 0
fi
if [ "\$1" = "agent" ] && [ "\$2" = "tasks" ]; then
    cat <<'JSON'
[
  {"id": "task-see1525-fix", "issue_id": "11111111-2222-3333-4444-555555555555", "status": "running", "work_dir": "/x"}
]
JSON
    exit 0
fi
exit 0
EOF
    chmod +x "$bin_dir/multica"
}

# git passthrough shim that kills BOTH default-branch lookup channels —
# `git symbolic-ref --short refs/remotes/origin/HEAD` and `git ls-remote
# --symref …` — so the resolver deterministically gets nothing on ANY git
# version. Why both: newer git (2.45+, GitHub runners) opportunistically
# CREATES refs/remotes/origin/HEAD during plain `git fetch origin`, so merely
# deleting the symref (or relying on it never existing) is version-fragile —
# CI run 41959696937 resolved "main" exactly this way. Narrow scope: other
# symbolic-ref/ls-remote argv shapes (branch checks, upstream setting) still
# pass through, keeping the scenario on the resolution chain only.
make_no_default_resolution_git_shim() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/git" <<EOF
#!/bin/bash
if [ "\$1" = "symbolic-ref" ] && [ "\$2" = "--short" ] && [ "\${3:-}" = "refs/remotes/origin/HEAD" ]; then
    exit 1
fi
if [ "\$1" = "ls-remote" ] && [ "\${2:-}" = "--symref" ]; then
    exit 1
fi
exec "$(command -v git)" "\$@"
EOF
    chmod +x "$bin_dir/git"
}

# Bare origin whose default branch is $3 (main|master) + working clone.
#   <default>: m1 -> m2 (m2 = tip)
# Working clone ends on branch agent/revy.
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
        git checkout -qb agent/revy
    )
    echo "$work"
}

# Create origin/<wb> at a given commit of the default branch and point the
# agent branch's upstream at it. point: m1 (behind) | m2 (== tip).
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
        git checkout -q agent/revy
        git branch -u "origin/$branch_name" agent/revy >/dev/null 2>&1
    )
}

# Invoke align_agent_branch_to_working_branch in a subshell from inside the
# fixture repo. Extra argv: mock_bin (mock multica on PATH), optional shim_bin
# (git ls-remote killer). Captured stdout; rc via $?.
run_align() {
    local helper_lib="$1" work="$2" wb="$3" success_msg="$4" conflict_msg="$5"
    local mock_bin="$6" shim_bin="${7:-}"
    (
        export PATH="$mock_bin${shim_bin:+:$shim_bin}:$PATH"
        export MULTICA_TASK_ID="task-see1525-fix"
        export MULTICA_AGENT_ID="agent-bachi-see1525"
        source "$helper_lib"
        cd "$work"
        align_agent_branch_to_working_branch "$work" "$wb" "$success_msg" "$conflict_msg"
    )
}

# --- Scenario A: phantom-conflict regression (the SEE-1525 root cause) ---
test_main_repo_no_phantom_pin() {
    echo "[A] main-default repo, shared==main: plain reset, no §B, no pin"
    local meta_log="$TMPDIR/meta_a.log" mock_bin="$TMPDIR/mock_a"
    : > "$meta_log"
    make_mock_multica "$mock_bin" "$meta_log"
    local lib="$TMPDIR/helper_lib.sh"
    extract_helper_lib "$lib"
    local work
    work=$(build_fixture "$TMPDIR/a" "DevForge" "main")
    ensure_shared_branch "$work" "shared/SEE-1525" "main" "m2"
    (cd "$work" && git checkout -q agent/revy && git reset --hard HEAD~1)  # agent behind wb

    local out rc hint
    out=$(run_align "$lib" "$work" "shared/SEE-1525" "A_SUCCESS" "A_REBASE_FAIL" "$mock_bin")
    rc=$?
    hint=$(jq_context "$out")

    if [ "$rc" -eq 0 ] && echo "$hint" | grep -q "A_SUCCESS"; then
        pass "exit 0 with success hint"
    else
        fail "expected exit 0 + A_SUCCESS; rc=$rc hint='$hint' out='$out'"
    fi
    if echo "$out" | grep -q "A_REBASE_FAIL"; then
        fail "conflict hint emitted on a main-default repo (phantom §B attempt)"
    else
        pass "no conflict hint (no phantom §B attempt)"
    fi
    if [ -s "$meta_log" ]; then
        fail "metadata pinned on non-conflict main repo: $(cat "$meta_log")"
    else
        pass "no blocked metadata pinned"
    fi
    local head_sha upstream_sha
    head_sha=$(cd "$work" && git rev-parse HEAD)
    upstream_sha=$(cd "$work" && git rev-parse "origin/shared/SEE-1525")
    if [ "$head_sha" = "$upstream_sha" ]; then
        pass "HEAD aligned to origin/shared/SEE-1525"
    else
        fail "HEAD not aligned: $head_sha != $upstream_sha"
    fi
}

# --- Scenario B: shared branch behind origin/main is rebased onto origin/main ---
test_main_repo_real_rebase() {
    echo "[B] main-default repo, shared behind main: real rebase onto origin/main"
    local meta_log="$TMPDIR/meta_b.log" mock_bin="$TMPDIR/mock_b"
    : > "$meta_log"
    make_mock_multica "$mock_bin" "$meta_log"
    local lib="$TMPDIR/helper_lib.sh"
    extract_helper_lib "$lib"
    local work
    work=$(build_fixture "$TMPDIR/b" "DevForge" "main")
    ensure_shared_branch "$work" "shared/SEE-1525" "main" "m2"
    # Advance origin/main to m3 (shared branch now behind the default branch).
    (cd "$work" \
        && git checkout -q main \
        && echo "main_line3" >> f.txt && git add f.txt && git commit -qm "m3" \
        && git push -q origin main \
        && git checkout -q agent/revy)

    local out rc hint
    out=$(run_align "$lib" "$work" "shared/SEE-1525" "B_SUCCESS" "B_REBASE_FAIL" "$mock_bin")
    rc=$?
    hint=$(jq_context "$out")

    if [ "$rc" -eq 0 ] && echo "$hint" | grep -q "B_SUCCESS"; then
        pass "exit 0 with success hint"
    else
        fail "expected exit 0 + B_SUCCESS; rc=$rc hint='$hint'"
    fi
    if (cd "$work" && git merge-base --is-ancestor "origin/main" "origin/shared/SEE-1525"); then
        pass "origin/shared/SEE-1525 now contains origin/main (rebased on resolved default)"
    else
        fail "§B did not rebase shared branch onto origin/main"
    fi
    if [ -s "$meta_log" ]; then
        fail "metadata pinned on a successful rebase: $(cat "$meta_log")"
    fi
    local head_sha upstream_sha
    head_sha=$(cd "$work" && git rev-parse HEAD)
    upstream_sha=$(cd "$work" && git rev-parse "origin/shared/SEE-1525")
    if [ "$head_sha" = "$upstream_sha" ]; then
        pass "HEAD aligned to rebased origin/shared/SEE-1525"
    else
        fail "HEAD not aligned after rebase"
    fi
}

# --- Scenario C: unresolvable default branch → explicit safe degrade ---
test_unresolvable_default_degrades_safely() {
    echo "[C] unresolvable default: §B skipped with hint, no rebase, no pin"
    local meta_log="$TMPDIR/meta_c.log" mock_bin="$TMPDIR/mock_c" shim_bin="$TMPDIR/shim_c"
    : > "$meta_log"
    make_mock_multica "$mock_bin" "$meta_log"
    make_no_default_resolution_git_shim "$shim_bin"
    local lib="$TMPDIR/helper_lib.sh"
    extract_helper_lib "$lib"
    local work wb_sha_before
    work=$(build_fixture "$TMPDIR/c" "DevForge" "main")
    ensure_shared_branch "$work" "shared/SEE-1525" "main" "m2"
    # Agent behind wb; pin the adversarial precondition locally to match what
    # newer git does on CI: origin/HEAD EXISTS (opportunistic set_head during
    # fetch), but BOTH lookup channels are shimmed dead, so the resolver still
    # gets nothing — deterministic on any git version.
    (cd "$work" \
        && git checkout -q agent/revy && git reset --hard HEAD~1 \
        && git symbolic-ref refs/remotes/origin/HEAD refs/heads/main)
    wb_sha_before=$(cd "$work" && git rev-parse "origin/shared/SEE-1525")

    local out rc hint
    out=$(run_align "$lib" "$work" "shared/SEE-1525" "C_SUCCESS" "C_REBASE_FAIL" "$mock_bin" "$shim_bin")
    rc=$?
    hint=$(jq_context "$out")

    if [ "$rc" -eq 0 ]; then
        pass "exit 0 (recoverable degrade)"
    else
        fail "expected exit 0; rc=$rc hint='$hint'"
    fi
    if echo "$out" | grep -q "无法解析 origin 默认分支"; then
        pass "readable skip hint emitted"
    else
        fail "expected 无法解析 origin 默认分支 hint; hint='$hint' out='$out'"
    fi
    if echo "$out" | grep -q "C_REBASE_FAIL"; then
        fail "conflict hint emitted despite unresolvable default (misread as conflict)"
    else
        pass "no conflict hint"
    fi
    if [ -s "$meta_log" ]; then
        fail "metadata pinned despite unresolvable default: $(cat "$meta_log")"
    else
        pass "no blocked metadata pinned"
    fi
    local wb_sha_after head_sha
    wb_sha_after=$(cd "$work" && git rev-parse "origin/shared/SEE-1525")
    head_sha=$(cd "$work" && git rev-parse HEAD)
    if [ "$wb_sha_before" = "$wb_sha_after" ]; then
        pass "origin/shared/SEE-1525 untouched (no rebase against a guessed base)"
    else
        fail "shared branch was rewritten: $wb_sha_before -> $wb_sha_after"
    fi
    if [ "$head_sha" = "$wb_sha_after" ]; then
        pass "HEAD aligned to origin/shared/SEE-1525"
    else
        fail "HEAD not aligned to origin/shared/SEE-1525"
    fi
}

# --- Scenario D: master-default repo unchanged (legacy regression pin) ---
test_master_repo_unchanged() {
    echo "[D] master-default repo, shared behind master: legacy rebase preserved"
    local meta_log="$TMPDIR/meta_d.log" mock_bin="$TMPDIR/mock_d"
    : > "$meta_log"
    make_mock_multica "$mock_bin" "$meta_log"
    local lib="$TMPDIR/helper_lib.sh"
    extract_helper_lib "$lib"
    local work
    work=$(build_fixture "$TMPDIR/d" "KingOfLikes-Godot" "master")
    ensure_shared_branch "$work" "shared/SEE-1008" "master" "m1"   # behind master (m2)

    local out rc hint
    out=$(run_align "$lib" "$work" "shared/SEE-1008" "D_SUCCESS" "D_REBASE_FAIL" "$mock_bin")
    rc=$?
    hint=$(jq_context "$out")

    if [ "$rc" -eq 0 ] && echo "$hint" | grep -q "D_SUCCESS"; then
        pass "exit 0 with success hint"
    else
        fail "expected exit 0 + D_SUCCESS; rc=$rc hint='$hint'"
    fi
    if (cd "$work" && git merge-base --is-ancestor "origin/master" "origin/shared/SEE-1008"); then
        pass "origin/shared/SEE-1008 still rebased onto origin/master"
    else
        fail "master-default §B behavior regressed"
    fi
}

# --- Static: no hardcoded origin/master rebase base remains in the hook ---
test_no_hardcoded_rebase_base() {
    echo "[STATIC] §B rebase base resolves per-repo (no origin/master hardcode)"
    # Strip comments first: historical prose may quote the old literal; only
    # executable lines count as a hardcode regression.
    local code_lines
    code_lines=$(grep -vE '^\s*(#.*)?$' "$HOOK" | grep -n 'merge-base --is-ancestor origin/master\|rebase origin/master')
    if [ -n "$code_lines" ]; then
        fail "hardcoded origin/master rebase base still present in $HOOK: $code_lines"
    else
        pass "no hardcoded origin/master is-ancestor/rebase in executable lines"
    fi
    if bash -n "$HOOK"; then
        pass "bash -n clean"
    else
        fail "bash -n failed"
    fi
}

TMPDIR=$(mktemp -d -t see1525-df-XXXXXX)

echo "============================================="
echo "SEE-1525 QA: repo-checkout §B default branch"
echo "============================================="

test_no_hardcoded_rebase_base
test_main_repo_no_phantom_pin
test_main_repo_real_rebase
test_unresolvable_default_degrades_safely
test_master_repo_unchanged

echo ""
echo "============================================="
echo "RESULT: PASS=$PASS FAIL=$FAIL"
echo "============================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
