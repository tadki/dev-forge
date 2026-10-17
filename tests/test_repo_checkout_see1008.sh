#!/bin/bash
# QA Test Script for SEE-1008: repo-checkout.sh Bug A/B fixes
# Runs A/B tests against pre-fix (c115529^) and post-fix (c115529) plus regressions.
#
# Run: bash .dev/tests/hooks/test_repo_checkout_see1008.sh
# or: ./.dev/tests/hooks/test_repo_checkout_see1008.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../../.."
TMPDIR=""
PASS=0
FAIL=0
WARN=0

NEW_REF="c115529"
OLD_REF="c115529^"

# --- Helpers ---
cleanup() {
    if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
        rm -rf "$TMPDIR"
    fi
}
trap cleanup EXIT

fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
warn() { echo "  WARN: $1"; WARN=$((WARN+1)); }

# Extract helper lib from a specific git ref of repo-checkout.sh.
# Includes output_hint through the end of align_agent_branch_to_working_branch.
extract_helper_lib() {
    local ref="$1"
    local out_file="$2"
    local content
    content=$(git -C "$REPO_ROOT" show "$ref:.claude/hooks/repo-checkout.sh" 2>/dev/null)
    if [ -z "$content" ]; then
        echo "ERROR: cannot extract $ref:.claude/hooks/repo-checkout.sh" >&2
        return 1
    fi
    local end_line
    end_line=$(echo "$content" | grep -n '^try_auto_create_shared_branch()' | head -1 | cut -d: -f1)
    if [ -z "$end_line" ]; then
        end_line=$(echo "$content" | wc -l)
    fi
    echo "$content" | sed -n "8,$((end_line - 1))p" > "$out_file"
}

# Parse hint JSON from stdout
jq_context() {
    echo "$1" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}

# Build a fixture with a local bare "origin" and a working clone named
# KingOfLikes-Godot. The clone starts on a branch "agent/revy" tracking
# origin/master.
#   master: m1 -> m2
# On entry, caller can decide where to place the shared branch (e.g. at m1 or m2).
build_fixture() {
    local root="$1"
    local remote="$root/origin.git"
    local work="$root/work/KingOfLikes-Godot"

    mkdir -p "$root/work"
    git init --bare --quiet "$remote"
    git init --quiet "$work"
    cd "$work"
    git config user.email "qa@kol.test"
    git config user.name "QA"
    git remote add origin "$remote"

    echo "line1" > f.txt
    echo "stable" > stable.txt
    git add f.txt stable.txt
    git commit -qm "m1"
    git branch -M master
    git push -q origin master

    echo "master_line2" >> f.txt
    git add f.txt
    git commit -qm "m2"
    git push -q origin master

    git checkout -qb agent/revy
    git branch -u origin/master agent/revy >/dev/null 2>&1

    echo "$work"
}

# Ensure the shared branch exists on origin at the requested commit.
# branch_point: "m1" or "m2" (m2 is current master tip)
ensure_shared_branch() {
    local work="$1"
    local branch_name="$2"
    local branch_point="$3"
    (
        cd "$work"
        git checkout -q master
        if [ "$branch_point" = "m2" ]; then
            git checkout -qb "$branch_name"
        else
            git checkout -qb "$branch_name" master~1
        fi
        git push -q origin "$branch_name"
        git checkout -q agent/revy
    )
}

# Invoke align_agent_branch_to_working_branch in a subshell from inside the
# fixture repo.  Captures exit code and stdout.  The helper function exits 0 on
# success/hint, so a subshell is mandatory.
run_align() {
    local helper_lib="$1"
    local work="$2"
    local repo_arg="$3"
    local wb="$4"
    local success_msg="${5:-SUCCESS}"
    local rebase_fail_msg="${6:-REBASE_FAIL}"
    (
        source "$helper_lib"
        cd "$work"
        align_agent_branch_to_working_branch "$repo_arg" "$wb" "$success_msg" "$rebase_fail_msg"
    )
}

# Print a concise git state summary for diagnostics
git_state() {
    local work="$1"
    (cd "$work" && echo "HEAD=$(git rev-parse --short HEAD) branch=$(git branch --show-current) upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || echo none) dirty=$(git diff-index --quiet HEAD -- && echo clean || echo dirty)")
}

# --- Static checks ---
test_static_checks() {
    echo "[STATIC] shellcheck + bash -n on .claude/hooks/scripts/repo-checkout.sh"
    (
        cd "$REPO_ROOT"
        local sc_out
        sc_out=$(shellcheck .claude/hooks/scripts/repo-checkout.sh 2>&1)
        if bash -n .claude/hooks/scripts/repo-checkout.sh; then
            pass "bash -n clean"
        else
            fail "bash -n failed"
        fi
        # Note: shellcheck exits 1 for infos, so count the warning lines.
        local sc_count
        sc_count=$(echo "$sc_out" | grep -c '^In .* line ' || true)
        if [ "$sc_count" -eq 3 ]; then
            pass "shellcheck has exactly 3 SC2015 info (pre-existing)"
        else
            fail "shellcheck expected 3 SC2015 info, got $sc_count: $sc_out"
        fi
    )
}

# --- Bug A: resolve_issue_id on first SessionStart ---
# Create a fake multica that simulates first SessionStart:
#   run-messages -> []
#   agent tasks  -> target task with status=dispatched, work_dir="", id=known, issue_id=known
#                 + distractor task
make_bug_a_mock_multica() {
    local bin_dir="$1"
    local task_id="$2"
    local agent_id="$3"
    local issue_id="$4"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/multica" <<EOF
#!/bin/bash
# Fake multica for Bug A first-SessionStart reproduction.
# Distractor task is a different running task with a different work_dir, so it
# neither matches the target task id (Path 0) nor the work_dir=\$PWD filter
# (Path 2).
if [ "\$1" = "issue" ] && [ "\$2" = "run-messages" ]; then
    echo '[]'
    exit 0
fi
if [ "\$1" = "agent" ] && [ "\$2" = "tasks" ]; then
    cat <<JSON
[
  {"id": "distractor-1111-2222-3333", "issue_id": "11111111-1111-1111-1111-111111111111", "status": "running", "work_dir": "/some/other/workdir"},
  {"id": "$task_id", "issue_id": "$issue_id", "status": "dispatched", "work_dir": ""}
]
JSON
    exit 0
fi
echo "unhandled multica command: \$@" >&2
exit 1
EOF
    chmod +x "$bin_dir/multica"
}

run_resolve_with_lib() {
    local helper_lib="$1"
    local mock_bin="$2"
    local test_mode="$3"
    local task_id="$4"
    local agent_id="$5"
    local issue_id="$6"
    (
        PATH="$mock_bin:$PATH"
        export MULTICA_TASK_ID="$task_id"
        export MULTICA_AGENT_ID="$agent_id"
        export MULTICA_AGENT_TASK_ID="$task_id"  # not used by current code, but harmless
        source "$helper_lib"
        case "$test_mode" in
            path0)
                resolve_issue_id
                ;;
            path1)
                unset MULTICA_AGENT_ID
                resolve_issue_id
                ;;
            path2)
                unset MULTICA_TASK_ID
                resolve_issue_id
                ;;
        esac
    )
}

test_bug_a_ab() {
    echo "[BUG-A] first SessionStart issue_id resolution (A/B)"
    local task_id="task-834eb833-2c9f-4ee4-89ae-15b34cc06bd5"
    local agent_id="agent-revy-2660961d-6add-4d15-8d1b-dea446142a94"
    local issue_id="834eb833-2c9f-4ee4-89ae-15b34cc06bd5"

    local mock_bin="$TMPDIR/mock_multica_a"
    make_bug_a_mock_multica "$mock_bin" "$task_id" "$agent_id" "$issue_id"

    local new_lib="$TMPDIR/helper_lib_new.sh"
    local old_lib="$TMPDIR/helper_lib_old.sh"
    extract_helper_lib "$NEW_REF" "$new_lib"
    extract_helper_lib "$OLD_REF" "$old_lib"

    # Path 0: new code returns issue_id, old code returns empty (no Path 0)
    local new_result old_result
    new_result=$(run_resolve_with_lib "$new_lib" "$mock_bin" path0 "$task_id" "$agent_id" "$issue_id")
    old_result=$(run_resolve_with_lib "$old_lib" "$mock_bin" path0 "$task_id" "$agent_id" "$issue_id")

    if [ "$new_result" = "$issue_id" ]; then
        pass "Path 0 (new) returns issue_id $issue_id"
    else
        fail "Path 0 (new) expected $issue_id, got '$new_result'"
    fi

    if [ -z "$old_result" ]; then
        pass "Path 0 absent in old code: returns empty as expected"
    else
        fail "Path 0 in old code unexpectedly returned '$old_result'"
    fi

    # Path 1: both old and new should return empty because run-messages is []
    new_result=$(run_resolve_with_lib "$new_lib" "$mock_bin" path1 "$task_id" "$agent_id" "$issue_id")
    old_result=$(run_resolve_with_lib "$old_lib" "$mock_bin" path1 "$task_id" "$agent_id" "$issue_id")
    if [ -z "$new_result" ] && [ -z "$old_result" ]; then
        pass "Path 1 returns empty when run-messages is []"
    else
        fail "Path 1 should return empty: new='$new_result' old='$old_result'"
    fi

    # Path 2: both old and new should return empty because task is dispatched and work_dir is empty
    new_result=$(run_resolve_with_lib "$new_lib" "$mock_bin" path2 "$task_id" "$agent_id" "$issue_id")
    old_result=$(run_resolve_with_lib "$old_lib" "$mock_bin" path2 "$task_id" "$agent_id" "$issue_id")
    if [ -z "$new_result" ] && [ -z "$old_result" ]; then
        pass "Path 2 returns empty when task is dispatched with empty work_dir"
    else
        fail "Path 2 should return empty: new='$new_result' old='$old_result'"
    fi
}

# --- Bug B: double-cd with relative repo_dir ---
test_bug_b_ab() {
    echo "[BUG-B] double-cd when caller already inside repo (A/B)"
    local new_lib="$TMPDIR/helper_lib_new.sh"
    local old_lib="$TMPDIR/helper_lib_old.sh"
    extract_helper_lib "$NEW_REF" "$new_lib"
    extract_helper_lib "$OLD_REF" "$old_lib"

    local work
    work=$(build_fixture "$TMPDIR/b")
    ensure_shared_branch "$work" "shared/SEE-1008" "m2"  # shared at m2, agent branch at m2

    # Move agent HEAD back to m1 so a real reset is required
    (cd "$work" && git reset --hard HEAD~1)

    local out_old rc_old out_new rc_new
    out_old=$(run_align "$old_lib" "$work" "KingOfLikes-Godot" "shared/SEE-1008" "OLD_SUCCESS" "OLD_REBASE_FAIL")
    rc_old=$?
    out_new=$(run_align "$new_lib" "$work" "KingOfLikes-Godot" "shared/SEE-1008" "NEW_SUCCESS" "NEW_REBASE_FAIL")
    rc_new=$?

    local hint_old hint_new
    hint_old=$(jq_context "$out_old")
    hint_new=$(jq_context "$out_new")

    # Old code: should fail because cd relative basename fails
    if [ "$rc_old" -ne 0 ] && echo "$hint_old" | grep -q "无法进入仓库目录"; then
        pass "Old code fails with '无法进入仓库目录' as expected"
    else
        fail "Old code expected to fail with path error; rc=$rc_old, hint='$hint_old'"
    fi

    # New code: should succeed and reset to origin/shared/SEE-1008
    if [ "$rc_new" -eq 0 ] && echo "$hint_new" | grep -q "NEW_SUCCESS"; then
        pass "New code succeeds and emits success hint"
    else
        fail "New code expected exit 0 + success hint; rc=$rc_new, hint='$hint_new'"
    fi

    local head_sha upstream_sha
    head_sha=$(cd "$work" && git rev-parse HEAD)
    upstream_sha=$(cd "$work" && git rev-parse "origin/shared/SEE-1008")
    if [ "$head_sha" = "$upstream_sha" ]; then
        pass "New code reset HEAD to origin/shared/SEE-1008"
    else
        fail "New code HEAD mismatch: HEAD=$head_sha origin/shared/SEE-1008=$upstream_sha"
    fi
}

# --- Regression: dirty worktree ---
test_regression_dirty() {
    echo "[REGRESSION] dirty worktree is stashed, reset, and restored"
    local new_lib="$TMPDIR/helper_lib_new.sh"
    extract_helper_lib "$NEW_REF" "$new_lib"

    local work
    work=$(build_fixture "$TMPDIR/r_dirty")
    ensure_shared_branch "$work" "shared/SEE-1008" "m2"
    (cd "$work" && git reset --hard HEAD~1)  # agent behind shared

    # Make a dirty change to a stable file (content identical at m1 and m2 so
    # the stash pop after reset is conflict-free).
    echo "dirty_line" >> "$work/stable.txt"

    local out rc
    out=$(run_align "$new_lib" "$work" "$work" "shared/SEE-1008" "RDIRTY_SUCCESS" "RDIRTY_REBASE_FAIL")
    rc=$?

    if [ "$rc" -ne 0 ]; then
        fail "expected exit 0, got $rc; out=$(jq_context "$out")"; return
    fi
    if ! echo "$out" | grep -q "RDIRTY_SUCCESS"; then
        fail "success hint missing; out=$(jq_context "$out")"; return
    fi
    if ! grep -q "dirty_line" "$work/stable.txt"; then
        fail "dirty_line was not restored after stash/reset/pop; content=$(cat "$work/stable.txt")"; return
    fi
    pass "dirty worktree preserved through stash/reset/pop"
}

# --- Regression: unpushed commit protection ---
test_regression_unpushed() {
    echo "[REGRESSION] unpushed local commit triggers protection and aborts"
    local new_lib="$TMPDIR/helper_lib_new.sh"
    extract_helper_lib "$NEW_REF" "$new_lib"

    local work
    work=$(build_fixture "$TMPDIR/r_unpushed")
    ensure_shared_branch "$work" "shared/SEE-1008" "m2"

    # Create an unpushed commit on the agent branch by adding a NEW file
    # so the commit is not on master or on origin/shared/SEE-1008.
    echo "local_only_body" > "$work/local_only.txt"
    (cd "$work" && git add local_only.txt && git commit -qm "local-only commit")

    # Snapshot HEAD immediately before align — the protection must keep HEAD here.
    local head_before
    head_before=$(cd "$work" && git rev-parse HEAD)

    local out rc
    out=$(run_align "$new_lib" "$work" "$work" "shared/SEE-1008" "RUNPUSHED_SUCCESS" "RUNPUSHED_REBASE_FAIL")
    rc=$?

    if [ "$rc" -ne 0 ]; then
        fail "expected exit 0, got $rc; out=$(jq_context "$out")"; return
    fi
    local hint
    hint=$(jq_context "$out")
    if ! echo "$hint" | grep -q "本地未推送 commit 保护"; then
        fail "expected protection hint, got: $hint"; return
    fi
    local head_after
    head_after=$(cd "$work" && git rev-parse HEAD)
    if [ "$head_before" != "$head_after" ]; then
        fail "HEAD moved despite protection; before=$head_before after=$head_after"; return
    fi
    if [ ! -f "$work/local_only.txt" ]; then
        fail "local_only.txt disappeared despite protection"; return
    fi
    pass "unpushed commit protection aborted reset and preserved HEAD"
}

# --- Regression: shared branch behind master is auto-rebased ---
test_regression_behind_master() {
    echo "[REGRESSION] shared branch behind master is auto-rebased onto master"
    local new_lib="$TMPDIR/helper_lib_new.sh"
    extract_helper_lib "$NEW_REF" "$new_lib"

    local work
    work=$(build_fixture "$TMPDIR/r_behind")
    # shared at m1, master at m2 -> shared is behind master
    ensure_shared_branch "$work" "shared/SEE-1008" "m1"

    local out rc
    out=$(run_align "$new_lib" "$work" "$work" "shared/SEE-1008" "RBEHIND_SUCCESS" "RBEHIND_REBASE_FAIL")
    rc=$?

    if [ "$rc" -ne 0 ]; then
        fail "expected exit 0, got $rc; out=$(jq_context "$out")"; return
    fi
    if ! echo "$out" | grep -q "RBEHIND_SUCCESS"; then
        fail "success hint missing; out=$(jq_context "$out")"; return
    fi
    if (cd "$work" && git merge-base --is-ancestor origin/master "origin/shared/SEE-1008"); then
        pass "origin/shared/SEE-1008 now contains origin/master"
    else
        fail "auto-rebase did not advance shared branch to contain master"
    fi
    local head_sha upstream_sha
    head_sha=$(cd "$work" && git rev-parse HEAD)
    upstream_sha=$(cd "$work" && git rev-parse "origin/shared/SEE-1008")
    if [ "$head_sha" = "$upstream_sha" ]; then
        pass "HEAD aligned to rebased origin/shared/SEE-1008"
    else
        fail "HEAD not aligned: HEAD=$head_sha origin/shared/SEE-1008=$upstream_sha"
    fi
}

# --- Main ---
TMPDIR=$(mktemp -d -t see1008-XXXXXX)

echo "==================================="
echo "SEE-1008 QA: repo-checkout.sh fixes"
echo "==================================="
echo "New ref: $NEW_REF"
echo "Old ref: $OLD_REF"
echo ""

test_static_checks
test_bug_a_ab
test_bug_b_ab
test_regression_dirty
test_regression_unpushed
test_regression_behind_master

echo ""
echo "==================================="
echo "RESULT: PASS=$PASS FAIL=$FAIL WARN=$WARN"
echo "==================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
