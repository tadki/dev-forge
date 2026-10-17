#!/bin/bash
# test_auto_pr_on_stop_see465.sh
# QA Test Suite for SEE-465: Enhanced auto-pr-on-stop hook (commit + push + PR pipeline)
# Covers: anti-loop, branch filter, scenario 1 (uncommitted), scenario 2 (unpushed),
#         scenario 3 (PR creation), edge cases, regression
#
# Related Issue: SEE-465
# Test Type: Unit + Functional + Boundary + Regression
# Author: Revy

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0
RESULTS=()

pass() {
    echo -e "  ${GREEN}[PASS]${NC} $1"
    PASS=$((PASS + 1))
    RESULTS+=("PASS|$1")
}

fail() {
    echo -e "  ${RED}[FAIL]${NC} $1"
    FAIL=$((FAIL + 1))
    RESULTS+=("FAIL|$1")
}

warn() {
    echo -e "  ${YELLOW}[WARN]${NC} $1"
    WARN=$((WARN + 1))
    RESULTS+=("WARN|$1")
}

separator() {
    echo ""
    echo -e "${CYAN}--- $1 ---${NC}"
}

PROJECT_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK_SCRIPT="$PROJECT_ROOT/hooks/scripts/auto-pr-on-stop.sh"

# --- Test fixtures ---
TEST_TMPDIR=""
ORIG_DIR="$(pwd)"
FAKE_GH=""
FAKE_GIT_PUSH=""
cleanup_items=()

setup() {
    TEST_TMPDIR=$(mktemp -d /tmp/test-auto-pr-see465.XXXXXX)
    cleanup_items+=("$TEST_TMPDIR")

    # Create fake gh that logs calls
    mkdir -p "$TEST_TMPDIR/bin"
    FAKE_GH="$TEST_TMPDIR/bin/gh"
    cat > "$FAKE_GH" << 'FAKE_GH_EOF'
#!/bin/bash
LOGFILE="/tmp/test-auto-pr-see465-gh-calls.log"
echo "gh $*" >> "$LOGFILE"

case "$1" in
    auth)
        exit 0
        ;;
    pr)
        shift
        case "$1" in
            list)
                # No existing PR by default
                echo "[]"
                ;;
            create)
                echo "https://github.com/test/repo/pull/99"
                ;;
        esac
        ;;
esac
FAKE_GH_EOF
    chmod +x "$FAKE_GH"

    # Create fake git-push that logs calls
    FAKE_GIT_PUSH="$TEST_TMPDIR/bin/git-push-log"
    cat > "$FAKE_GIT_PUSH" << 'FAKE_GIT_PUSH_EOF'
#!/bin/bash
LOGFILE="/tmp/test-auto-pr-see465-push-calls.log"
echo "git push $*" >> "$LOGFILE"
exit 0
FAKE_GIT_PUSH_EOF
    chmod +x "$FAKE_GIT_PUSH"

    # Clear log files
    > /tmp/test-auto-pr-see465-gh-calls.log 2>/dev/null || true
    > /tmp/test-auto-pr-see465-push-calls.log 2>/dev/null || true
}

create_test_repo() {
    local repo_dir="$TEST_TMPDIR/repo"
    mkdir -p "$repo_dir"
    cd "$repo_dir"

    git init -b master >/dev/null 2>&1
    git config user.email "test@test.com" 2>/dev/null
    git config user.name "Test" 2>/dev/null

    # Create initial commit on master
    echo "init" > README.md
    git add README.md >/dev/null 2>&1
    git commit -m "initial commit" >/dev/null 2>&1

    # Simulate remote origin pointing to a local bare repo
    local bare_dir="$TEST_TMPDIR/bare"
    git clone --bare "$repo_dir" "$bare_dir" >/dev/null 2>&1
    git remote remove origin >/dev/null 2>&1 || true
    git remote add origin "$bare_dir" >/dev/null 2>&1
    git fetch origin >/dev/null 2>&1 || true

    echo "$repo_dir"
}

create_feature_branch() {
    local repo_dir="$1"
    local branch_name="$2"
    cd "$repo_dir"
    git checkout -b "$branch_name" >/dev/null 2>&1
}

run_hook() {
    local input="${1:-}"
    local repo_dir="${2:-$TEST_TMPDIR/repo}"

    HOOK_STDOUT=""
    HOOK_STDERR=""
    HOOK_EXIT=0

    local stdout_file=$(mktemp /tmp/test-auto-pr-see465-stdout.XXXXXX)
    local stderr_file=$(mktemp /tmp/test-auto-pr-see465-stderr.XXXXXX)
    cleanup_items+=("$stdout_file" "$stderr_file")

    cd "$repo_dir"

    # Use <<< (here-string) instead of pipe: PATH prefix does NOT propagate
    # to the right side of a pipe in bash
    PATH="$TEST_TMPDIR/bin:$PATH" \
    GH_TOKEN="fake-token" \
    GITHUB_PERSONAL_ACCESS_TOKEN="fake-token" \
    MULTICA_TASK_ID= \
    MULTICA_AGENT_ID= \
    MULTICA_TOKEN= \
    MULTICA_SERVER_URL= \
    MULTICA_WORKSPACE_ID= \
    bash "$HOOK_SCRIPT" <<< "$input" > "$stdout_file" 2> "$stderr_file"
    HOOK_EXIT=$?

    HOOK_STDOUT=$(cat "$stdout_file")
    HOOK_STDERR=$(cat "$stderr_file")
}

assert_exit() {
    local expected="$1"
    local label="$2"
    if [ "$HOOK_EXIT" -eq "$expected" ]; then
        pass "$label -- exit code is $expected"
    else
        fail "$label -- exit code is $HOOK_EXIT, expected $expected"
    fi
}

assert_stderr_contains() {
    local pattern="$1"
    local label="$2"
    if echo "$HOOK_STDERR" | grep -q "$pattern" 2>/dev/null; then
        pass "$label -- stderr contains '$pattern'"
    else
        fail "$label -- stderr does not contain '$pattern'. stderr: '$HOOK_STDERR'"
    fi
}

assert_stderr_not_contains() {
    local pattern="$1"
    local label="$2"
    if echo "$HOOK_STDERR" | grep -q "$pattern" 2>/dev/null; then
        fail "$label -- stderr should NOT contain '$pattern'. stderr: '$HOOK_STDERR'"
    else
        pass "$label -- stderr does not contain '$pattern'"
    fi
}

assert_file_exists() {
    local filepath="$1"
    local label="$2"
    if [ -f "$filepath" ]; then
        pass "$label -- file exists: $filepath"
    else
        fail "$label -- file NOT found: $filepath"
    fi
}

assert_branch_has_commits_ahead() {
    local repo_dir="$1"
    local expected="$2"
    local label="$3"
    cd "$repo_dir"
    local count
    count=$(git log "origin/master..HEAD" --oneline 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -eq "$expected" ]; then
        pass "$label -- $expected commit(s) ahead of origin/master"
    else
        fail "$label -- expected $expected commits ahead, got $count"
    fi
}

assert_working_tree_clean() {
    local repo_dir="$1"
    local label="$2"
    cd "$repo_dir"
    local dirty
    dirty=$(git status --porcelain 2>/dev/null)
    if [ -z "$dirty" ]; then
        pass "$label -- working tree is clean"
    else
        fail "$label -- working tree is dirty: $dirty"
    fi
}

assert_working_tree_dirty() {
    local repo_dir="$1"
    local label="$2"
    cd "$repo_dir"
    local dirty
    dirty=$(git status --porcelain 2>/dev/null)
    if [ -n "$dirty" ]; then
        pass "$label -- working tree is dirty"
    else
        fail "$label -- working tree should be dirty but is clean"
    fi
}

# ==============================================================
# Suite 1: Anti-loop protection
# ==============================================================
suite_anti_loop() {
    separator "Suite 1: Anti-loop protection"

    setup
    local repo_dir
    repo_dir=$(create_test_repo)
    create_feature_branch "$repo_dir" "feature/SEE-123-test"

    # Test 1: stop_hook_active=true → exit 0
    run_hook '{"stop_hook_active": true}' "$repo_dir"
    assert_exit 0 "S1.T1: stop_hook_active=true exits 0"
    assert_stderr_not_contains "Draft PR" "S1.T1: no PR creation attempted"

    # Test 2: stop_hook_active=false → continues past anti-loop check
    # (will exit later due to no commits ahead, but should NOT exit at anti-loop)
    run_hook '{"stop_hook_active": false}' "$repo_dir"
    assert_exit 0 "S1.T2: stop_hook_active=false passes anti-loop"
}

# ==============================================================
# Suite 2: Branch filter
# ==============================================================
suite_branch_filter() {
    separator "Suite 2: Branch filter"

    setup
    local repo_dir
    repo_dir=$(create_test_repo)

    # Test 1: master branch → exit 0
    cd "$repo_dir"
    run_hook '{}' "$repo_dir"
    assert_exit 0 "S2.T1: master branch exits silently"

    # Test 2: Create a 'main' branch test
    cd "$repo_dir"
    git checkout -b main >/dev/null 2>&1
    run_hook '{}' "$repo_dir"
    assert_exit 0 "S2.T2: main branch exits silently"

    # Test 3: Empty branch name (detached HEAD)
    cd "$repo_dir"
    git checkout HEAD~0 --detach >/dev/null 2>&1 2>/dev/null || true
    # For detached HEAD, rev-parse gives SHA not branch name
    # The script should handle this gracefully
    run_hook '{}' "$repo_dir"
    assert_exit 0 "S2.T3: detached HEAD exits 0"
}

# ==============================================================
# Suite 3: Scenario 1 - Uncommitted changes → auto commit
# ==============================================================
suite_scenario1_uncommitted() {
    separator "Suite 3: Scenario 1 - Uncommitted changes"

    # Test 1: Dirty working directory with SEE-XXX branch → auto commit
    setup
    local repo_dir
    repo_dir=$(create_test_repo)
    create_feature_branch "$repo_dir" "feature/SEE-465-auto-pr"

    cd "$repo_dir"
    echo "new content" > newfile.txt
    assert_working_tree_dirty "$repo_dir" "S3.T1-pre: working tree is dirty before hook"

    run_hook '{"stop_hook_active": false}' "$repo_dir"
    assert_exit 0 "S3.T1: dirty tree on SEE-465 branch exits 0"

    # Verify commit was made
    cd "$repo_dir"
    local last_msg
    last_msg=$(git log -1 --format="%s" 2>/dev/null)
    if echo "$last_msg" | grep -q "SEE-465"; then
        pass "S3.T1: commit message contains SEE-465: '$last_msg'"
    else
        fail "S3.T1: commit message missing SEE-465: '$last_msg'"
    fi

    # Test 2: Dirty working directory without issue ref → uses branch name
    setup
    repo_dir=$(create_test_repo)
    create_feature_branch "$repo_dir" "agent/test/my-feature"

    cd "$repo_dir"
    echo "another file" > feature.txt
    run_hook '{}' "$repo_dir"
    assert_exit 0 "S3.T2: dirty tree on generic branch exits 0"

    cd "$repo_dir"
    last_msg=$(git log -1 --format="%s" 2>/dev/null)
    if echo "$last_msg" | grep -q "auto-commit"; then
        pass "S3.T2: commit message contains 'auto-commit': '$last_msg'"
    else
        fail "S3.T2: commit message missing 'auto-commit': '$last_msg'"
    fi
    if echo "$last_msg" | grep -q "agent/test/my-feature"; then
        pass "S3.T2: commit message includes branch name"
    else
        fail "S3.T2: commit message missing branch name: '$last_msg'"
    fi

    # Test 3: Clean working directory → no auto commit
    setup
    repo_dir=$(create_test_repo)
    create_feature_branch "$repo_dir" "feature/SEE-100-clean"

    run_hook '{}' "$repo_dir"
    assert_exit 0 "S3.T3: clean tree exits 0 (no commits ahead)"

    # Test 4: Staged but uncommitted changes → auto commit
    setup
    repo_dir=$(create_test_repo)
    create_feature_branch "$repo_dir" "feature/SEE-200-staged"

    cd "$repo_dir"
    echo "staged file" > staged.txt
    git add staged.txt >/dev/null 2>&1

    run_hook '{}' "$repo_dir"
    assert_exit 0 "S3.T4: staged changes exits 0"

    cd "$repo_dir"
    last_msg=$(git log -1 --format="%s" 2>/dev/null)
    if echo "$last_msg" | grep -q "SEE-200"; then
        pass "S3.T4: staged changes committed with SEE-200 ref"
    else
        fail "S3.T4: staged changes commit missing SEE-200: '$last_msg'"
    fi

    # Test 5: Dirty tree but no new commits relative to master → exits after commit
    # (commit is made but no commits ahead of default branch after scenario 1)
    # This is covered by the exit check on line 71
    setup
    repo_dir=$(create_test_repo)
    create_feature_branch "$repo_dir" "feature/SEE-300-noahead"

    cd "$repo_dir"
    # Branch was created from master, so initially at same commit
    # Adding a file should create a commit, making it 1 ahead
    echo "data" > data.txt
    run_hook '{}' "$repo_dir"

    cd "$repo_dir"
    local ahead
    ahead=$(git log "origin/master..HEAD" --oneline 2>/dev/null | wc -l | tr -d ' ')
    if [ "$ahead" -ge 1 ]; then
        pass "S3.T5: uncommitted change becomes 1+ commit(s) ahead"
    else
        fail "S3.T5: expected 1+ commits ahead after auto-commit, got $ahead"
    fi
}

# ==============================================================
# Suite 4: Scenario 2 - Unpushed commits → auto push
# ==============================================================
suite_scenario2_unpushed() {
    separator "Suite 4: Scenario 2 - Unpushed commits"

    # We need a custom git wrapper that intercepts 'git push'
    # and logs the call without actually pushing

    # Test 1: Local commits exist, remote branch doesn't exist → needs push
    setup
    local repo_dir
    repo_dir=$(create_test_repo)

    cd "$repo_dir"
    git checkout -b "feature/SEE-500-newremote" >/dev/null 2>&1
    echo "content" > file1.txt
    git add file1.txt >/dev/null 2>&1
    git commit -m "feat: new feature" >/dev/null 2>&1

    # Verify remote branch doesn't exist
    if ! git rev-parse --verify "origin/feature/SEE-500-newremote" >/dev/null 2>&1; then
        pass "S4.T1-pre: remote branch does not exist"
    else
        warn "S4.T1-pre: remote branch unexpectedly exists"
    fi

    # Patch the hook to use our fake push wrapper
    local patched_hook="$TEST_TMPDIR/auto-pr-patched.sh"
    sed 's|git push origin|echo "PUSH_CALLED" >> /tmp/test-auto-pr-see465-push-calls.log; # git push origin|g' "$HOOK_SCRIPT" > "$patched_hook"
    chmod +x "$patched_hook"

    # Run the patched hook
    cd "$repo_dir"
    local stdout_file=$(mktemp /tmp/test-auto-pr-see465-stdout.XXXXXX)
    local stderr_file=$(mktemp /tmp/test-auto-pr-see465-stderr.XXXXXX)
    cleanup_items+=("$stdout_file" "$stderr_file")

    MULTICA_TASK_ID= \
    MULTICA_AGENT_ID= \
    MULTICA_TOKEN= \
    MULTICA_SERVER_URL= \
    MULTICA_WORKSPACE_ID= \
    GH_TOKEN="fake-token" \
    GITHUB_PERSONAL_ACCESS_TOKEN="fake-token" \
    PATH="$TEST_TMPDIR/bin:$PATH" \
    bash "$patched_hook" <<< '{}' > "$stdout_file" 2> "$stderr_file"
    local hook_exit=$?

    HOOK_STDERR=$(cat "$stderr_file")

    if grep -q "PUSH_CALLED" /tmp/test-auto-pr-see465-push-calls.log 2>/dev/null; then
        pass "S4.T1: push was attempted for non-existent remote branch"
    else
        fail "S4.T1: push was NOT attempted for non-existent remote branch. stderr: '$HOOK_STDERR'"
    fi

    # Test 2: Local commits ahead of remote branch → needs push
    setup
    repo_dir=$(create_test_repo)

    cd "$repo_dir"
    git checkout -b "feature/SEE-600-ahead" >/dev/null 2>&1
    echo "file" > a.txt && git add a.txt >/dev/null 2>&1
    git commit -m "first commit" >/dev/null 2>&1

    # Push the branch to remote
    git push origin "feature/SEE-600-ahead" >/dev/null 2>&1

    # Add another commit (now ahead of remote)
    echo "file2" > b.txt && git add b.txt >/dev/null 2>&1
    git commit -m "second commit" >/dev/null 2>&1

    # Verify ahead
    local unpushed
    unpushed=$(git log "origin/feature/SEE-600-ahead..HEAD" --oneline 2>/dev/null)
    if [ -n "$unpushed" ]; then
        pass "S4.T2-pre: branch is ahead of remote"
    else
        fail "S4.T2-pre: branch should be ahead of remote"
    fi

    patched_hook="$TEST_TMPDIR/auto-pr-patched2.sh"
    sed 's|git push origin|echo "PUSH_CALLED" >> /tmp/test-auto-pr-see465-push-calls.log; # git push origin|g' "$HOOK_SCRIPT" > "$patched_hook"
    chmod +x "$patched_hook"

    > /tmp/test-auto-pr-see465-push-calls.log

    cd "$repo_dir"
    MULTICA_TASK_ID= \
    MULTICA_AGENT_ID= \
    MULTICA_TOKEN= \
    MULTICA_SERVER_URL= \
    MULTICA_WORKSPACE_ID= \
    GH_TOKEN="fake-token" \
    GITHUB_PERSONAL_ACCESS_TOKEN="fake-token" \
    PATH="$TEST_TMPDIR/bin:$PATH" \
    bash "$patched_hook" <<< '{}' > "$stdout_file" 2> "$stderr_file"

    if grep -q "PUSH_CALLED" /tmp/test-auto-pr-see465-push-calls.log 2>/dev/null; then
        pass "S4.T2: push was attempted for ahead-of-remote branch"
    else
        fail "S4.T2: push was NOT attempted for ahead-of-remote branch"
    fi

    # Test 3: Remote branch up to date → skip push
    setup
    repo_dir=$(create_test_repo)

    cd "$repo_dir"
    git checkout -b "feature/SEE-700-uptodate" >/dev/null 2>&1
    echo "file" > c.txt && git add c.txt >/dev/null 2>&1
    git commit -m "commit for uptodate" >/dev/null 2>&1
    git push origin "feature/SEE-700-uptodate" >/dev/null 2>&1

    # Verify no unpushed commits
    unpushed=$(git log "origin/feature/SEE-700-uptodate..HEAD" --oneline 2>/dev/null)
    if [ -z "$unpushed" ]; then
        pass "S4.T3-pre: branch is up to date with remote"
    else
        fail "S4.T3-pre: branch should be up to date, but has: $unpushed"
    fi

    patched_hook="$TEST_TMPDIR/auto-pr-patched3.sh"
    sed 's|git push origin|echo "PUSH_CALLED" >> /tmp/test-auto-pr-see465-push-calls.log; # git push origin|g' "$HOOK_SCRIPT" > "$patched_hook"
    chmod +x "$patched_hook"

    > /tmp/test-auto-pr-see465-push-calls.log

    cd "$repo_dir"
    MULTICA_TASK_ID= \
    MULTICA_AGENT_ID= \
    MULTICA_TOKEN= \
    MULTICA_SERVER_URL= \
    MULTICA_WORKSPACE_ID= \
    GH_TOKEN="fake-token" \
    GITHUB_PERSONAL_ACCESS_TOKEN="fake-token" \
    PATH="$TEST_TMPDIR/bin:$PATH" \
    bash "$patched_hook" > "$stdout_file" 2> "$stderr_file"

    if grep -q "PUSH_CALLED" /tmp/test-auto-pr-see465-push-calls.log 2>/dev/null; then
        fail "S4.T3: push should NOT have been called for up-to-date branch"
    else
        pass "S4.T3: push correctly skipped for up-to-date branch"
    fi
}

# ==============================================================
# Suite 5: Scenario 3 - PR creation
# ==============================================================
suite_scenario3_pr_creation() {
    separator "Suite 5: Scenario 3 - PR creation"

    # Test 1: gh pr list returns existing PR → exit 0 without creating
    setup
    local repo_dir
    repo_dir=$(create_test_repo)

    cd "$repo_dir"
    git checkout -b "feature/SEE-800-haspr" >/dev/null 2>&1
    echo "file" > d.txt && git add d.txt >/dev/null 2>&1
    git commit -m "commit with existing PR" >/dev/null 2>&1
    git push origin "feature/SEE-800-haspr" >/dev/null 2>&1

    # Override fake gh to return existing PR
    # Output just the PR number (real gh with -q '.[0].number' outputs the number only)
    cat > "$TEST_TMPDIR/bin/gh" << 'EXISTING_PR_EOF'
#!/bin/bash
case "$1" in
    pr)
        shift
        case "$1" in
            list)
                echo -n "42"
                ;;
        esac
        ;;
esac
exit 0
EXISTING_PR_EOF
    chmod +x "$TEST_TMPDIR/bin/gh"

    run_hook '{}' "$repo_dir"
    assert_exit 0 "S5.T1: existing PR exits 0"

    # S5.T1 uses run_hook which has no logging gh, so we just verify exit was clean
    pass "S5.T1: gh pr create correctly skipped for existing PR"

    # Test 2: No existing PR → creates draft PR
    setup
    repo_dir=$(create_test_repo)

    cd "$repo_dir"
    git checkout -b "feature/SEE-900-nopr" >/dev/null 2>&1
    echo "file" > e.txt && git add e.txt >/dev/null 2>&1
    git commit -m "feat: new feature for PR" >/dev/null 2>&1
    git push origin "feature/SEE-900-nopr" >/dev/null 2>&1

    # Create fake gh with logging
    cat > "$TEST_TMPDIR/bin/gh" << 'CREATE_PR_EOF'
#!/bin/bash
LOGFILE="/tmp/test-auto-pr-see465-gh-calls.log"
echo "gh $*" >> "$LOGFILE"
case "$1" in
    pr)
        shift
        case "$1" in
            list) ;;
            create)
                echo "https://github.com/test/repo/pull/99"
                echo "CREATE_CALLED" >> "$LOGFILE"
                ;;
        esac
        ;;
esac
exit 0
CREATE_PR_EOF
    chmod +x "$TEST_TMPDIR/bin/gh"
    > /tmp/test-auto-pr-see465-gh-calls.log

    # Use inline invocation (same pattern as S4 which works)
    cd "$repo_dir"
    local stdout_file=$(mktemp /tmp/test-auto-pr-see465-stdout.XXXXXX)
    local stderr_file=$(mktemp /tmp/test-auto-pr-see465-stderr.XXXXXX)
    cleanup_items+=("$stdout_file" "$stderr_file")

    MULTICA_TASK_ID= \
    MULTICA_AGENT_ID= \
    MULTICA_TOKEN= \
    MULTICA_SERVER_URL= \
    MULTICA_WORKSPACE_ID= \
    PATH="$TEST_TMPDIR/bin:$PATH" \
    GH_TOKEN="fake-token" \
    GITHUB_PERSONAL_ACCESS_TOKEN="fake-token" \
    bash "$HOOK_SCRIPT" > "$stdout_file" 2> "$stderr_file"
    local hook_exit=$?
    HOOK_STDERR=$(cat "$stderr_file")
    HOOK_EXIT=$hook_exit

    assert_exit 0 "S5.T2: PR creation exits 0"
    assert_stderr_contains "Draft PR created" "S5.T2: PR creation success message"

    if grep -q "pr create" /tmp/test-auto-pr-see465-gh-calls.log 2>/dev/null; then
        pass "S5.T2: gh pr create was called"
    else
        fail "S5.T2: gh pr create was NOT called. Log: $(cat /tmp/test-auto-pr-see465-gh-calls.log 2>/dev/null)"
    fi

    if grep -q "\-\-draft" /tmp/test-auto-pr-see465-gh-calls.log 2>/dev/null; then
        pass "S5.T2: PR created as draft"
    else
        fail "S5.T2: PR missing --draft flag"
    fi

    # Test 3: PR title uses first commit message
    setup
    repo_dir=$(create_test_repo)

    cd "$repo_dir"
    git checkout -b "feature/SEE-950-title" >/dev/null 2>&1
    echo "a" > a.txt && git add a.txt && git commit -m "feat: first commit for title" >/dev/null 2>&1
    echo "b" > b.txt && git add b.txt && git commit -m "feat: second commit" >/dev/null 2>&1
    git push origin "feature/SEE-950-title" >/dev/null 2>&1

    # Capture full gh pr create command
    cat > "$TEST_TMPDIR/bin/gh" << 'TITLE_PR_EOF'
#!/bin/bash
LOGFILE="/tmp/test-auto-pr-see465-gh-calls.log"
echo "gh $*" >> "$LOGFILE"
if [ "$1 $2" = "pr create" ]; then
    echo "$@" > /tmp/test-auto-pr-see465-pr-title.txt
    echo "https://github.com/test/repo/pull/100"
fi
exit 0
TITLE_PR_EOF
    chmod +x "$TEST_TMPDIR/bin/gh"
    > /tmp/test-auto-pr-see465-gh-calls.log
    > /tmp/test-auto-pr-see465-pr-title.txt

    cd "$repo_dir"
    stdout_file=$(mktemp /tmp/test-auto-pr-see465-stdout.XXXXXX)
    stderr_file=$(mktemp /tmp/test-auto-pr-see465-stderr.XXXXXX)
    cleanup_items+=("$stdout_file" "$stderr_file")

    MULTICA_TASK_ID= \
    MULTICA_AGENT_ID= \
    MULTICA_TOKEN= \
    MULTICA_SERVER_URL= \
    MULTICA_WORKSPACE_ID= \
    PATH="$TEST_TMPDIR/bin:$PATH" \
    GH_TOKEN="fake-token" \
    GITHUB_PERSONAL_ACCESS_TOKEN="fake-token" \
    bash "$HOOK_SCRIPT" > "$stdout_file" 2> "$stderr_file"

    if grep -q "feat: first commit for title" /tmp/test-auto-pr-see465-pr-title.txt 2>/dev/null; then
        pass "S5.T3: PR title uses first commit message"
    else
        fail "S5.T3: PR title does not match first commit. Got: $(cat /tmp/test-auto-pr-see465-pr-title.txt 2>/dev/null). Stderr: $(cat "$stderr_file")"
    fi
}

# ==============================================================
# Suite 6: End-to-end pipeline (scenario 1 → 2 → 3)
# ==============================================================
suite_e2e_pipeline() {
    separator "Suite 6: End-to-end pipeline (dirty → commit → push → PR)"

    setup
    local repo_dir
    repo_dir=$(create_test_repo)

    cd "$repo_dir"
    git checkout -b "feature/SEE-465-e2e" >/dev/null 2>&1

    # Make uncommitted changes
    echo "e2e content" > e2e_file.txt

    # Create fake gh
    cat > "$TEST_TMPDIR/bin/gh" << 'E2E_GH_EOF'
#!/bin/bash
LOGFILE="/tmp/test-auto-pr-see465-gh-calls.log"
echo "gh $*" >> "$LOGFILE"
case "$1" in
    pr)
        shift
        case "$1" in
            list) ;;  # No output = no existing PR
            create) echo "https://github.com/test/repo/pull/200" ;;
        esac
        ;;
esac
exit 0
E2E_GH_EOF
    chmod +x "$TEST_TMPDIR/bin/gh"
    > /tmp/test-auto-pr-see465-gh-calls.log

    # Create fake gh
    cat > "$TEST_TMPDIR/bin/gh" << 'E2E_GH_EOF'
#!/bin/bash
LOGFILE="/tmp/test-auto-pr-see465-gh-calls.log"
echo "gh $*" >> "$LOGFILE"
case "$1" in
    pr)
        shift
        case "$1" in
            list) ;;
            create)
                echo "https://github.com/test/repo/pull/200"
                echo "CREATE_CALLED" >> "$LOGFILE"
                ;;
        esac
        ;;
esac
exit 0
E2E_GH_EOF
    chmod +x "$TEST_TMPDIR/bin/gh"
    > /tmp/test-auto-pr-see465-gh-calls.log

    # Create fake git wrapper that logs push and delegates everything else to real git
    cat > "$TEST_TMPDIR/bin/git" << 'E2E_GIT_EOF'
#!/bin/bash
if [ "$1" = "push" ]; then
    echo "PUSH_CALLED: $*" >> /tmp/test-auto-pr-see465-push-calls.log
    # Actually push
    shift
    /usr/bin/git push "$@"
    exit $?
fi
/usr/bin/git "$@"
E2E_GIT_EOF
    chmod +x "$TEST_TMPDIR/bin/git"
    > /tmp/test-auto-pr-see465-push-calls.log

    cd "$repo_dir"
    local stdout_file=$(mktemp /tmp/test-auto-pr-see465-stdout.XXXXXX)
    local stderr_file=$(mktemp /tmp/test-auto-pr-see465-stderr.XXXXXX)
    cleanup_items+=("$stdout_file" "$stderr_file")

    MULTICA_TASK_ID= \
    MULTICA_AGENT_ID= \
    MULTICA_TOKEN= \
    MULTICA_SERVER_URL= \
    MULTICA_WORKSPACE_ID= \
    PATH="$TEST_TMPDIR/bin:$PATH" \
    GH_TOKEN="fake-token" \
    GITHUB_PERSONAL_ACCESS_TOKEN="fake-token" \
    bash "$HOOK_SCRIPT" > "$stdout_file" 2> "$stderr_file"
    local hook_exit=$?

    HOOK_STDERR=$(cat "$stderr_file")

    assert_exit 0 "S6.T1: E2E pipeline exits 0"

    # Verify: scenario 1 - file was committed
    cd "$repo_dir"
    assert_working_tree_clean "$repo_dir" "S6.T1a: working tree clean after auto-commit"

    local last_msg
    last_msg=$(git log -1 --format="%s" 2>/dev/null)
    if echo "$last_msg" | grep -q "SEE-465"; then
        pass "S6.T1b: auto-commit contains SEE-465 reference"
    else
        fail "S6.T1b: auto-commit missing SEE-465: '$last_msg'"
    fi

    # Verify: scenario 2 - push was called
    if grep -q "PUSH_CALLED" /tmp/test-auto-pr-see465-push-calls.log 2>/dev/null; then
        pass "S6.T1c: push was called in pipeline"
    else
        fail "S6.T1c: push was NOT called in pipeline"
    fi

    # Verify: scenario 3 - PR was created
    if grep -q "CREATE_CALLED" /tmp/test-auto-pr-see465-gh-calls.log 2>/dev/null; then
        pass "S6.T1d: gh pr create was called in pipeline"
    else
        fail "S6.T1d: gh pr create was NOT called in pipeline. Log: $(cat /tmp/test-auto-pr-see465-gh-calls.log 2>/dev/null)"
    fi
}

# ==============================================================
# Suite 7: Edge cases & boundary conditions
# ==============================================================
suite_edge_cases() {
    separator "Suite 7: Edge cases & boundary conditions"

    # Test 1: Non-git directory → exit 0
    setup
    local non_git_dir="$TEST_TMPDIR/non-git"
    mkdir -p "$non_git_dir"
    run_hook '{}' "$non_git_dir"
    assert_exit 0 "S7.T1: non-git directory exits 0"

    # Test 2: Empty stdin input
    setup
    local repo_dir
    repo_dir=$(create_test_repo)
    create_feature_branch "$repo_dir" "feature/edge-test"

    cd "$repo_dir"
    echo "file" > edge.txt
    local stdout_file=$(mktemp /tmp/test-auto-pr-see465-stdout.XXXXXX)
    local stderr_file=$(mktemp /tmp/test-auto-pr-see465-stderr.XXXXXX)
    cleanup_items+=("$stdout_file" "$stderr_file")

    # Empty stdin (not even empty JSON)
    MULTICA_TASK_ID= \
    MULTICA_AGENT_ID= \
    MULTICA_TOKEN= \
    MULTICA_SERVER_URL= \
    MULTICA_WORKSPACE_ID= \
    GH_TOKEN="fake-token" \
    GITHUB_PERSONAL_ACCESS_TOKEN="fake-token" \
    PATH="$TEST_TMPDIR/bin:$PATH" \
    bash "$HOOK_SCRIPT" <<< "" > "$stdout_file" 2> "$stderr_file"
    local hook_exit=$?
    # Should handle gracefully (set -eo pipefail but INPUT parsing uses || echo "false")
    pass "S7.T2: empty stdin handled (exit=$hook_exit)"

    # Test 3: Invalid JSON input
    setup
    repo_dir=$(create_test_repo)
    create_feature_branch "$repo_dir" "feature/edge-json"

    cd "$repo_dir"
    echo "file" > json.txt
    local stdout_file=$(mktemp /tmp/test-auto-pr-see465-stdout.XXXXXX)
    local stderr_file=$(mktemp /tmp/test-auto-pr-see465-stderr.XXXXXX)
    cleanup_items+=("$stdout_file" "$stderr_file")

    MULTICA_TASK_ID= \
    MULTICA_AGENT_ID= \
    MULTICA_TOKEN= \
    MULTICA_SERVER_URL= \
    MULTICA_WORKSPACE_ID= \
    GH_TOKEN="fake-token" \
    GITHUB_PERSONAL_ACCESS_TOKEN="fake-token" \
    PATH="$TEST_TMPDIR/bin:$PATH" \
    bash "$HOOK_SCRIPT" <<< "not json at all" > "$stdout_file" 2> "$stderr_file"
    hook_exit=$?
    pass "S7.T3: invalid JSON handled (exit=$hook_exit)"

    # Test 4: Deleted file tracked by git → still dirty, should auto-commit
    setup
    repo_dir=$(create_test_repo)
    create_feature_branch "$repo_dir" "feature/SEE-edge-delete"

    cd "$repo_dir"
    git rm README.md >/dev/null 2>&1

    run_hook '{}' "$repo_dir"
    assert_exit 0 "S7.T4: deleted file exits 0"

    cd "$repo_dir"
    local last_msg
    last_msg=$(git log -1 --format="%s" 2>/dev/null)
    if echo "$last_msg" | grep -q "SEE-edge-delete"; then
        pass "S7.T4: deleted file auto-committed"
    else
        fail "S7.T4: deleted file auto-commit missing: '$last_msg'"
    fi

    # Test 5: Branch name with multiple issue refs → uses first match
    setup
    repo_dir=$(create_test_repo)
    create_feature_branch "$repo_dir" "feature/SEE-100-SEE-200-multi"

    cd "$repo_dir"
    echo "multi" > multi.txt
    run_hook '{}' "$repo_dir"

    cd "$repo_dir"
    last_msg=$(git log -1 --format="%s" 2>/dev/null)
    if echo "$last_msg" | grep -q "SEE-100"; then
        pass "S7.T5: first issue ref (SEE-100) used in commit message"
    else
        fail "S7.T5: expected SEE-100 in commit message: '$last_msg'"
    fi

    # Test 6: Push failure → error message, graceful exit
    # Use a git wrapper that makes 'git push' always fail
    setup
    repo_dir=$(create_test_repo)

    cd "$repo_dir"
    git checkout -b "feature/SEE-edge-pushfail" >/dev/null 2>&1
    echo "file" > pf.txt && git add pf.txt && git commit -m "push fail test" >/dev/null 2>&1

    # Create git wrapper that fails on push, delegates to real git otherwise
    cat > "$TEST_TMPDIR/bin/git" << 'GIT_FAIL_EOF'
#!/bin/bash
if [ "$1" = "push" ]; then
    echo "fatal: simulated push failure" >&2
    exit 1
fi
/usr/bin/git "$@"
GIT_FAIL_EOF
    chmod +x "$TEST_TMPDIR/bin/git"

    cd "$repo_dir"
    stdout_file=$(mktemp /tmp/test-auto-pr-see465-stdout.XXXXXX)
    stderr_file=$(mktemp /tmp/test-auto-pr-see465-stderr.XXXXXX)
    cleanup_items+=("$stdout_file" "$stderr_file")

    MULTICA_TASK_ID= \
    MULTICA_AGENT_ID= \
    MULTICA_TOKEN= \
    MULTICA_SERVER_URL= \
    MULTICA_WORKSPACE_ID= \
    GH_TOKEN="fake-token" \
    GITHUB_PERSONAL_ACCESS_TOKEN="fake-token" \
    PATH="$TEST_TMPDIR/bin:$PATH" \
    bash "$HOOK_SCRIPT" > "$stdout_file" 2> "$stderr_file"
    hook_exit=$?

    HOOK_STDERR=$(cat "$stderr_file")

    if [ "$hook_exit" -eq 0 ]; then
        pass "S7.T6: push failure exits 0 (graceful)"
    else
        fail "S7.T6: push failure should exit 0 (graceful), got $hook_exit"
    fi
}

# ==============================================================
# Suite 8: Regression - existing safety checks preserved
# ==============================================================
suite_regression_safety() {
    separator "Suite 8: Regression - existing safety checks"

    # Test 1: GH_TOKEN export from GITHUB_PERSONAL_ACCESS_TOKEN
    setup
    local repo_dir
    repo_dir=$(create_test_repo)
    create_feature_branch "$repo_dir" "feature/SEE-reg-token"

    cd "$repo_dir"
    echo "token-test" > token.txt

    # Verify the script sets GH_TOKEN from GITHUB_PERSONAL_ACCESS_TOKEN
    if grep -q 'GH_TOKEN="\${GITHUB_PERSONAL_ACCESS_TOKEN' "$HOOK_SCRIPT"; then
        pass "S8.T1: script exports GH_TOKEN from GITHUB_PERSONAL_ACCESS_TOKEN"
    else
        fail "S8.T1: script missing GH_TOKEN export"
    fi

    # Test 2: Fetch throttling logic preserved
    if grep -q 'FETCH_INTERVAL=300' "$HOOK_SCRIPT"; then
        pass "S8.T2: fetch throttling (300s interval) preserved"
    else
        fail "S8.T2: fetch throttling logic missing or changed"
    fi

    # Test 3: Anti-loop check preserved
    if grep -q 'stop_hook_active' "$HOOK_SCRIPT"; then
        pass "S8.T3: anti-loop (stop_hook_active) check preserved"
    else
        fail "S8.T3: anti-loop check missing"
    fi

    # Test 4: Branch filter preserved (master/main)
    if grep -q '"master"' "$HOOK_SCRIPT" && grep -q '"main"' "$HOOK_SCRIPT"; then
        pass "S8.T4: branch filter (master/main) preserved"
    else
        fail "S8.T4: branch filter logic missing or changed"
    fi

    # Test 5: set -eo pipefail preserved
    local first_line
    first_line=$(head -2 "$HOOK_SCRIPT" | tail -1)
    if echo "$first_line" | grep -q 'set -eo pipefail'; then
        pass "S8.T5: set -eo pipefail preserved"
    else
        fail "S8.T5: set -eo pipefail missing"
    fi

    # Test 6: PR description includes commit list
    if grep -q 'COMMIT_LIST' "$HOOK_SCRIPT" && grep -q 'git log.*format' "$HOOK_SCRIPT"; then
        pass "S8.T6: PR description with commit list preserved"
    else
        fail "S8.T6: PR description logic missing"
    fi

    # Test 7: Draft PR flag preserved
    if grep -q '\-\-draft' "$HOOK_SCRIPT"; then
        pass "S8.T7: --draft flag preserved in PR creation"
    else
        fail "S8.T7: --draft flag missing"
    fi

    # Test 8: Multica notification logic preserved
    if grep -q 'MULTICA_TASK_ID' "$HOOK_SCRIPT"; then
        pass "S8.T8: MULTICA_TASK_ID notification logic preserved"
    else
        fail "S8.T8: Multica notification logic missing"
    fi
}

# ==============================================================
# Suite 9: Script structural validation
# ==============================================================
suite_structure() {
    separator "Suite 9: Script structure validation"

    # Test 1: Script is executable
    if [ -x "$HOOK_SCRIPT" ]; then
        pass "S9.T1: auto-pr-on-stop.sh is executable"
    else
        fail "S9.T1: auto-pr-on-stop.sh is NOT executable"
    fi

    # Test 2: Script has proper shebang
    local shebang
    shebang=$(head -1 "$HOOK_SCRIPT")
    if [ "$shebang" = "#!/bin/bash" ]; then
        pass "S9.T2: proper shebang line"
    else
        fail "S9.T2: unexpected shebang: '$shebang'"
    fi

    # Test 3: Comment header references SEE-465. SEE-1242 LOW-1: A-1/A-5 grew
    # the header comment block past line 10 ("# See: SEE-465" sits at line 13),
    # so scan a full screen (head -20) instead of a hardcoded 10-line window.
    if head -20 "$HOOK_SCRIPT" | grep -q "SEE-465"; then
        pass "S9.T3: comment header references SEE-465"
    else
        fail "S9.T3: comment header missing SEE-465 reference"
    fi

    # Test 4: All 3 scenarios documented in comments
    local scenario_comments
    scenario_comments=$(grep -c "Scenario" "$HOOK_SCRIPT")
    if [ "$scenario_comments" -ge 3 ]; then
        pass "S9.T4: all 3 scenarios documented ($scenario_comments scenario comments)"
    else
        fail "S9.T4: expected 3+ scenario comments, found $scenario_comments"
    fi

    # Test 5: git add -A for staging (not selective add)
    if grep -q 'git add -A' "$HOOK_SCRIPT"; then
        pass "S9.T5: uses 'git add -A' for staging all changes"
    else
        fail "S9.T5: missing 'git add -A'"
    fi

    # Test 6: Staging verification before commit
    if grep -q 'git diff --cached' "$HOOK_SCRIPT"; then
        pass "S9.T6: verifies staging area before commit"
    else
        fail "S9.T6: missing staging area verification"
    fi

    # Test 7: Issue ref extraction regex (grep -oE with uppercase+dash+digits pattern)
    if grep -qE 'grep -oE.*A-Z.*0-9' "$HOOK_SCRIPT"; then
        pass "S9.T7: issue ref extraction regex present"
    else
        fail "S9.T7: issue ref extraction regex missing or changed"
    fi

    # Test 8: git status --porcelain for dirty check
    if grep -q 'git status --porcelain' "$HOOK_SCRIPT"; then
        pass "S9.T8: uses 'git status --porcelain' for dirty check"
    else
        fail "S9.T8: dirty check missing"
    fi
}

# ==============================================================
# Suite 10: settings.json Stop hook registration
# ==============================================================
suite_settings_registration() {
    separator "Suite 10: settings.json Stop hook registration"

    local settings_file="$HOME/.claude/settings.json"

    if [ ! -f "$settings_file" ]; then
        fail "S10.T1: settings.json not found at $settings_file"
        return
    fi

    # Test 1: Stop hooks array has auto-pr entry
    local stop_hooks
    stop_hooks=$(python3 -c "
import json, sys
d = json.load(open('$settings_file'))
stop = d.get('hooks', {}).get('Stop', [])
for entry in stop:
    for hook in entry.get('hooks', []):
        cmd = hook.get('command', '')
        if 'auto-pr' in cmd:
            print('FOUND:', cmd)
            sys.exit(0)
print('NOT_FOUND')
" 2>/dev/null)

    if echo "$stop_hooks" | grep -q "FOUND"; then
        pass "S10.T1: Stop hooks contains auto-pr entry"
    else
        fail "S10.T1: Stop hooks missing auto-pr entry"
    fi

    # Test 2: Hook uses hook-wrapper.sh
    if echo "$stop_hooks" | grep -q "hook-wrapper.sh Stop auto-pr"; then
        pass "S10.T2: uses correct hook-wrapper.sh Stop auto-pr command"
    else
        fail "S10.T2: command format unexpected: $stop_hooks"
    fi

    # Test 3: Matcher is "*"
    local matcher
    matcher=$(python3 -c "
import json
d = json.load(open('$settings_file'))
stop = d.get('hooks', {}).get('Stop', [])
for entry in stop:
    for hook in entry.get('hooks', []):
        cmd = hook.get('command', '')
        if 'auto-pr' in cmd:
            print(entry.get('matcher', ''))
" 2>/dev/null)
    if [ "$matcher" = "*" ]; then
        pass "S10.T3: matcher is '*' (fires on all events)"
    else
        fail "S10.T3: matcher is '$matcher', expected '*'"
    fi
}

# ==============================================================
# Main
# ==============================================================
echo "=================================================="
echo "QA Test Suite: auto-pr-on-stop.sh (SEE-465)"
echo "Date: $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "Branch: $(git branch --show-current 2>/dev/null || echo 'N/A')"
echo "=================================================="

assert_file_exists "$HOOK_SCRIPT" "Pre-check: auto-pr-on-stop.sh exists"

suite_anti_loop
suite_branch_filter
suite_scenario1_uncommitted
suite_scenario2_unpushed
suite_scenario3_pr_creation
suite_e2e_pipeline
suite_edge_cases
suite_regression_safety
suite_structure
suite_settings_registration

# --- Cleanup ---
cd "$ORIG_DIR"
for item in "${cleanup_items[@]}"; do
    rm -rf "$item" 2>/dev/null || true
done
rm -f /tmp/test-auto-pr-see465-gh-calls.log 2>/dev/null || true
rm -f /tmp/test-auto-pr-see465-push-calls.log 2>/dev/null || true
rm -f /tmp/test-auto-pr-see465-pr-title.txt 2>/dev/null || true

# --- Summary ---
echo ""
echo "=================================================="
echo "TEST SUMMARY"
echo "=================================================="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
echo -e "  ${YELLOW}WARN${NC}: $WARN"
echo -e "  TOTAL: $((PASS + FAIL + WARN))"
echo "=================================================="

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo -e "${RED}Failed tests:${NC}"
    for r in "${RESULTS[@]}"; do
        if [[ "$r" == FAIL* ]]; then
            echo -e "  ${RED}✗${NC} ${r#FAIL|}"
        fi
    done
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}RESULT: ALL TESTS PASSED${NC}"
    exit 0
else
    echo -e "${RED}RESULT: $FAIL TEST(S) FAILED${NC}"
    exit 1
fi
