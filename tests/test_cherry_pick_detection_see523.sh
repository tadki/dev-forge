#!/bin/bash
# test_cherry_pick_detection_see523.sh
# QA Test Suite for SEE-523: Cherry-pick detection in auto-pr-on-stop.sh
# Covers: Scenario A (skip), Scenario B (partial match → no skip),
#         Scenario C (no open PR → no skip), boundary conditions
#
# Related Issue: SEE-523
# Test Type: Unit + Functional + Boundary
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

TEST_TMPDIR=""
ORIG_DIR="$(pwd)"
cleanup_items=()

setup() {
    # Clean up previous test artifacts
    rm -f /tmp/test-see523-*.log 2>/dev/null || true
    rm -f /tmp/test-see523-*.txt 2>/dev/null || true
    TEST_TMPDIR=$(mktemp -d /tmp/test-see523.XXXXXX)
    cleanup_items+=("$TEST_TMPDIR")
}

# Create a bare repo + clone it, setup origin/master
create_test_repo() {
    local bare_dir="$TEST_TMPDIR/bare-repo.git"
    local clone_dir="$TEST_TMPDIR/local-repo"

    git init --bare "$bare_dir" >/dev/null 2>&1
    git clone "$bare_dir" "$clone_dir" >/dev/null 2>&1

    cd "$clone_dir"
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > README.md
    git add README.md
    git commit -m "init: master" >/dev/null 2>&1
    git push -u origin master >/dev/null 2>&1

    # Ensure origin/HEAD points to origin/master
    git remote set-head origin master >/dev/null 2>&1 || true

    echo "$clone_dir"
}

# Create mock gh command that logs and returns configured responses
# Usage: create_mock_gh <pr_list_output> [pr_list_exit]
#
# Distinguishes two gh pr list call patterns:
#   1. --state open (cherry-pick detection: list all open PR branches)
#   2. --state all --head <branch> (existing PR check for specific branch)
create_mock_gh() {
    local pr_list_output="${1:-}"
    local pr_list_exit="${2:-0}"
    local gh_path="$TEST_TMPDIR/bin/gh"

    mkdir -p "$TEST_TMPDIR/bin"

    # Use Python to write the mock script, avoiding heredoc escaping issues
    python3 -c "
import os
pr_list_output = '''$pr_list_output'''
pr_list_exit = $pr_list_exit

lines = [
    '#!/bin/bash',
    'LOGFILE=\"/tmp/test-see523-gh-calls.log\"',
    'echo \"gh \$*\" >> \"\$LOGFILE\"',
    'case \"\$1\" in',
    '    auth) exit 0 ;;',
    '    pr)',
    '        shift',
    '        case \"\$1\" in',
    '            list)',
]
if pr_list_exit != 0:
    lines += [
        '                echo \"gh pr list failed (simulated)\" >&2',
        '                exit {}'.format(pr_list_exit),
    ]
else:
    lines += [
        '                is_head_check=false',
        '                head_val=\"\"',
        '                i=1',
        '                while [ \$i -le \$# ]; do',
        '                    eval \"arg=\\\$\$i\"',
        '                    if [ \"\$arg\" = \"--head\" ]; then',
        '                        j=\$((i+1))',
        '                        eval \"head_val=\\\$\$j\"',
        '                        is_head_check=true',
        '                        break',
        '                    fi',
        '                    i=\$((i+1))',
        '                done',
        '                if [ \"\$is_head_check\" = \"true\" ]; then',
        '                    if echo \"{}\" | grep -qx \"\$head_val\"; then'.format(pr_list_output),
        '                        echo \"\$head_val\"',
        '                    fi',
        '                else',
        '                    echo \"{}\"'.format(pr_list_output),
        '                fi',
    ]
lines += [
    '                ;;',
    '            create)',
    '                echo \"CREATE_CALLED\" >> \"\$LOGFILE\"',
    '                echo \"https://github.com/test/repo/pull/999\"',
    '                ;;',
    '        esac',
    '        ;;',
    'esac',
    'exit 0',
]

with open('$gh_path', 'w') as f:
    f.write('\n'.join(lines) + '\n')
os.chmod('$gh_path', 0o755)
"
}

# Run the hook in a given directory with given stdin JSON
# Sets globals: HOOK_EXIT, HOOK_STDERR
run_hook() {
    local stdin_json="${1:-{}}"
    local repo_dir="${2:-$ORIG_DIR}"

    local stdout_file=$(mktemp /tmp/test-see523-stdout.XXXXXX)
    local stderr_file=$(mktemp /tmp/test-see523-stderr.XXXXXX)
    cleanup_items+=("$stdout_file" "$stderr_file")

    cd "$repo_dir"
    MULTICA_TASK_ID= \
    MULTICA_AGENT_ID= \
    MULTICA_TOKEN= \
    MULTICA_SERVER_URL= \
    MULTICA_WORKSPACE_ID= \
    GH_TOKEN="fake-token" \
    GITHUB_PERSONAL_ACCESS_TOKEN="fake-token" \
    PATH="$TEST_TMPDIR/bin:$PATH" \
    bash "$HOOK_SCRIPT" <<< "$stdin_json" > "$stdout_file" 2> "$stderr_file"
    HOOK_EXIT=$?
    HOOK_STDERR=$(cat "$stderr_file")
}

assert_exit() {
    local expected="$1"
    local msg="$2"
    if [ "$HOOK_EXIT" -eq "$expected" ]; then
        pass "$msg (exit=$HOOK_EXIT)"
    else
        fail "$msg (expected exit=$expected, got $HOOK_EXIT)"
    fi
}

assert_stderr_contains() {
    local needle="$1"
    local msg="$2"
    if echo "$HOOK_STDERR" | grep -q "$needle"; then
        pass "$msg"
    else
        fail "$msg (expected '$needle' in stderr, got: '$HOOK_STDERR')"
    fi
}

assert_stderr_not_contains() {
    local needle="$1"
    local msg="$2"
    if echo "$HOOK_STDERR" | grep -q "$needle"; then
        fail "$msg (unexpected '$needle' in stderr: '$HOOK_STDERR')"
    else
        pass "$msg"
    fi
}

assert_file_exists() {
    local f="$1"
    local msg="$2"
    if [ -f "$f" ]; then
        pass "$msg"
    else
        fail "$msg (missing: $f)"
    fi
}

# ==============================================================
# Suite 1: Static checks
# ==============================================================
suite_static_checks() {
    separator "Suite 1: Static checks"

    # Test 1: bash -n syntax check
    if bash -n "$HOOK_SCRIPT" 2>/dev/null; then
        pass "S1.T1: bash -n syntax check passes"
    else
        fail "S1.T1: bash -n syntax check fails"
    fi

    # Test 2: shellcheck (if available)
    if command -v shellcheck >/dev/null 2>&1; then
        if shellcheck --severity=error "$HOOK_SCRIPT" 2>/dev/null; then
            pass "S1.T2: shellcheck --severity=error passes"
        else
            fail "S1.T2: shellcheck --severity=error finds errors"
        fi
    else
        warn "S1.T2: shellcheck not installed, skipped"
    fi

    # Test 3: set +e / set -e pairing around cherry-pick block
    # The cherry-pick block is the 2nd set +e / 3rd set -e pair:
    #   Line 89:  set +e (push block)
    #   Line 92:  set -e (push block end)
    #   Line 100: set +e (cherry-pick block)
    #   Line 155: set -e (cherry-pick block end)
    #   Line 180: set +e (PR create block)
    #   Line 183: set -e (PR create block end)
    local cherry_pick_start
    local cherry_pick_end
    cherry_pick_start=$(grep -n 'set +e' "$HOOK_SCRIPT" | awk 'NR==2{print $1}' | cut -d: -f1)
    cherry_pick_end=$(grep -n 'set -e$' "$HOOK_SCRIPT" | awk 'NR==2{print $1}' | cut -d: -f1)

    if [ -n "$cherry_pick_start" ] && [ -n "$cherry_pick_end" ] && [ "$cherry_pick_start" -lt "$cherry_pick_end" ]; then
        pass "S1.T3: cherry-pick block has set +e ($cherry_pick_start) / set -e ($cherry_pick_end) pairing"
    else
        fail "S1.T3: cherry-pick block set +e/set -e pairing incorrect (start=$cherry_pick_start, end=$cherry_pick_end)"
    fi

    # Test 4: Verify cherry-pick detection code exists in script
    if grep -q 'Cherry-pick detection' "$HOOK_SCRIPT"; then
        pass "S1.T4: cherry-pick detection section present in script"
    else
        fail "S1.T4: cherry-pick detection section missing"
    fi

    # Test 5: Verify SKIP_PR variable usage
    if grep -q 'SKIP_PR' "$HOOK_SCRIPT"; then
        pass "S1.T5: SKIP_PR variable used in script"
    else
        fail "S1.T5: SKIP_PR variable missing"
    fi

    # Test 6: Verify patch-id fallback exists
    if grep -q 'patch-id' "$HOOK_SCRIPT"; then
        pass "S1.T6: patch-id fallback logic present"
    else
        fail "S1.T6: patch-id fallback logic missing"
    fi

    # Test 7: Verify break 2 for nested loop exit
    if grep -q 'break 2' "$HOOK_SCRIPT"; then
        pass "S1.T7: break 2 present for nested loop exit"
    else
        fail "S1.T7: break 2 missing"
    fi

    # Test 8: Verify is-ancestor check exists
    if grep -q 'merge-base --is-ancestor' "$HOOK_SCRIPT"; then
        pass "S1.T8: git merge-base --is-ancestor check present"
    else
        fail "S1.T8: git merge-base --is-ancestor check missing"
    fi
}

# ==============================================================
# Suite 2: Scenario A - All commits found in open PR → skip
# ==============================================================
suite_scenario_a_skip() {
    separator "Suite 2: Scenario A - All commits exist in open PR branch"

    setup
    local repo_dir
    repo_dir=$(create_test_repo)

    # Step 1: Create pr-branch with commit A1, push it
    cd "$repo_dir"
    git checkout -b "pr-branch-see523" >/dev/null 2>&1
    echo "feature A1" > feature_a.txt
    git add feature_a.txt
    git commit -m "feat: A1" >/dev/null 2>&1
    git push -u origin "pr-branch-see523" >/dev/null 2>&1

    # Step 2: Create current-branch from pr-branch (all commits are ancestors)
    git checkout -b "current-branch-see523" >/dev/null 2>&1
    # No new commits — current-branch is at same commit as pr-branch
    git push -u origin "current-branch-see523" >/dev/null 2>&1

    # Step 3: Mock gh pr list returns pr-branch as open PR
    create_mock_gh "pr-branch-see523"
    > /tmp/test-see523-gh-calls.log

    # Step 4: Run hook on current-branch
    cd "$repo_dir"
    run_hook '{}' "$repo_dir"

    # Verify: should skip PR creation
    assert_exit 0 "S2.T1: hook exits 0 when all commits in open PR"
    assert_stderr_contains "Skipping PR creation" "S2.T1: stderr shows skip message"
    assert_stderr_not_contains "Draft PR created" "S2.T1: no PR was created"
}

# ==============================================================
# Suite 3: Scenario B - Partial match → do NOT skip
# ==============================================================
suite_scenario_b_partial() {
    separator "Suite 3: Scenario B - Only partial commits match open PR"

    setup
    local repo_dir
    repo_dir=$(create_test_repo)

    # Step 1: Create pr-branch with commit A1, push
    cd "$repo_dir"
    git checkout -b "pr-branch-partial" >/dev/null 2>&1
    echo "feature A1" > a1.txt
    git add a1.txt
    git commit -m "feat: A1 partial" >/dev/null 2>&1
    git push -u origin "pr-branch-partial" >/dev/null 2>&1

    # Step 2: Create current-branch from pr-branch, add NEW commit A2
    git checkout -b "current-partial" >/dev/null 2>&1
    echo "feature A2" > a2.txt
    git add a2.txt
    git commit -m "feat: A2 new" >/dev/null 2>&1
    git push -u origin "current-partial" >/dev/null 2>&1

    # Step 3: Mock gh pr list returns pr-branch-partial
    create_mock_gh "pr-branch-partial"
    > /tmp/test-see523-gh-calls.log

    # Step 4: Run hook
    cd "$repo_dir"
    run_hook '{}' "$repo_dir"

    # Verify: should NOT skip, should attempt PR creation
    assert_exit 0 "S3.T1: hook exits 0 for partial match"
    assert_stderr_not_contains "Skipping PR creation" "S3.T1: no skip message for partial match"
    assert_stderr_contains "Draft PR created" "S3.T1: PR is created for partial match"
}

# ==============================================================
# Suite 4: Scenario C - No open PR → do NOT skip
# ==============================================================
suite_scenario_c_no_pr() {
    separator "Suite 4: Scenario C - No open PR branches"

    setup
    local repo_dir
    repo_dir=$(create_test_repo)

    cd "$repo_dir"
    git checkout -b "current-no-pr" >/dev/null 2>&1
    echo "standalone feature" > standalone.txt
    git add standalone.txt
    git commit -m "feat: standalone" >/dev/null 2>&1
    git push -u origin "current-no-pr" >/dev/null 2>&1

    # Mock gh pr list returns empty
    create_mock_gh ""
    > /tmp/test-see523-gh-calls.log

    cd "$repo_dir"
    run_hook '{}' "$repo_dir"

    assert_exit 0 "S4.T1: hook exits 0 when no open PRs"
    assert_stderr_not_contains "Skipping PR creation" "S4.T1: no skip when no open PRs"
    assert_stderr_contains "Draft PR created" "S4.T1: PR created when no open PRs"
}

# ==============================================================
# Suite 5: Patch-ID fallback (true cherry-pick, different hash)
# ==============================================================
suite_patch_id_fallback() {
    separator "Suite 5: Patch-ID fallback - different hash, same content"

    setup
    local repo_dir
    repo_dir=$(create_test_repo)

    # Step 1: Create pr-branch with commit A1, push
    cd "$repo_dir"
    git checkout -b "pr-branch-patch" >/dev/null 2>&1
    echo "same content for patch-id test" > patchfile.txt
    git add patchfile.txt
    git commit -m "feat: patch-id commit" >/dev/null 2>&1
    local a1_hash
    a1_hash=$(git rev-parse HEAD)
    git push -u origin "pr-branch-patch" >/dev/null 2>&1

    # Step 2: Create current-branch from master, cherry-pick A1
    git checkout master >/dev/null 2>&1
    git checkout -b "current-patch" >/dev/null 2>&1
    # Cherry-pick A1 — creates new hash with same patch content
    git cherry-pick "$a1_hash" --no-commit >/dev/null 2>&1
    # Need to commit to make it a real commit
    git commit -m "feat: patch-id commit (cherry-picked)" >/dev/null 2>&1
    local a2_hash
    a2_hash=$(git rev-parse HEAD)
    git push -u origin "current-patch" >/dev/null 2>&1

    # Verify hashes are different (true cherry-pick scenario)
    if [ "$a1_hash" != "$a2_hash" ]; then
        pass "S5-pre: cherry-pick created different hash ($a1_hash vs $a2_hash)"
    else
        fail "S5-pre: expected different hashes after cherry-pick"
        return
    fi

    # Verify is-ancestor fails for different hash
    if ! git merge-base --is-ancestor "$a2_hash" "origin/pr-branch-patch" >/dev/null 2>&1; then
        pass "S5-pre: is-ancestor correctly fails for different hash"
    else
        warn "S5-pre: is-ancestor unexpectedly succeeds for different hash"
    fi

    # Step 3: Mock gh pr list returns pr-branch-patch
    create_mock_gh "pr-branch-patch"
    > /tmp/test-see523-gh-calls.log

    # Step 4: Run hook
    cd "$repo_dir"
    run_hook '{}' "$repo_dir"

    # Verify: patch-id should match, skip PR creation
    assert_exit 0 "S5.T1: hook exits 0 for patch-id match"
    assert_stderr_contains "Skipping PR creation" "S5.T1: patch-id fallback skips PR creation"
}

# ==============================================================
# Suite 6: Boundary conditions
# ==============================================================
suite_boundary_conditions() {
    separator "Suite 6: Boundary conditions"

    # Test 1: gh pr list fails → conservative, do NOT skip
    setup
    local repo_dir
    repo_dir=$(create_test_repo)

    cd "$repo_dir"
    git checkout -b "current-gh-fail" >/dev/null 2>&1
    echo "content" > fail.txt
    git add fail.txt
    git commit -m "feat: gh fail test" >/dev/null 2>&1
    git push -u origin "current-gh-fail" >/dev/null 2>&1

    create_mock_gh "" 1
    > /tmp/test-see523-gh-calls.log

    cd "$repo_dir"
    run_hook '{}' "$repo_dir"

    assert_exit 0 "S6.T1: gh pr list failure → exits 0 (conservative)"
    assert_stderr_not_contains "Skipping PR creation" "S6.T1: no skip when gh pr list fails"
    assert_stderr_contains "Draft PR created" "S6.T1: PR created when gh pr list fails"

    # Test 2: Empty commit list (branch aligned with master) → exit early
    setup
    repo_dir=$(create_test_repo)

    cd "$repo_dir"
    git checkout -b "current-empty" >/dev/null 2>&1
    git push -u origin "current-empty" >/dev/null 2>&1
    # No commits ahead of master

    create_mock_gh "some-branch"
    > /tmp/test-see523-gh-calls.log

    cd "$repo_dir"
    run_hook '{}' "$repo_dir"

    assert_exit 0 "S6.T2: empty commit list → exits 0 early"
    assert_stderr_not_contains "Skipping PR creation" "S6.T2: no cherry-pick check for empty commits"
    assert_stderr_not_contains "Draft PR created" "S6.T2: no PR created for empty commits"

    # Test 3: CURRENT_BRANCH excluded from open PR list
    setup
    repo_dir=$(create_test_repo)

    cd "$repo_dir"
    git checkout -b "current-self" >/dev/null 2>&1
    echo "self" > self.txt
    git add self.txt
    git commit -m "feat: self" >/dev/null 2>&1
    git push -u origin "current-self" >/dev/null 2>&1

    # Mock returns current branch itself — should be excluded by grep -vFx
    create_mock_gh "current-self"
    > /tmp/test-see523-gh-calls.log

    cd "$repo_dir"
    run_hook '{}' "$repo_dir"

    assert_exit 0 "S6.T3: own branch excluded from PR check"
    assert_stderr_not_contains "Skipping PR creation" "S6.T3: no self-skip when only own branch has PR"
    # Note: hook correctly exits before PR creation because EXISTING_PR check
    # finds current-self already has a PR — this is expected behavior, not a bug
    assert_stderr_not_contains "Draft PR created" "S6.T3: no redundant PR when branch already has one"

    # Test 4: Multiple open PR branches, all commits found in one of them
    setup
    repo_dir=$(create_test_repo)

    cd "$repo_dir"
    git checkout -b "pr-branch-multi" >/dev/null 2>&1
    echo "multi" > multi.txt
    git add multi.txt
    git commit -m "feat: multi" >/dev/null 2>&1
    git push -u origin "pr-branch-multi" >/dev/null 2>&1

    git checkout -b "current-multi" >/dev/null 2>&1
    git push -u origin "current-multi" >/dev/null 2>&1

    # Mock returns another unrelated PR branch + the matching one
    create_mock_gh $'other-branch\npr-branch-multi'
    > /tmp/test-see523-gh-calls.log

    cd "$repo_dir"
    run_hook '{}' "$repo_dir"

    assert_exit 0 "S6.T4: multiple PR branches, match in one → skip"
    assert_stderr_contains "Skipping PR creation" "S6.T4: skip when match found across multiple PR branches"
}

# ==============================================================
# Suite 7: Regression - existing SEE-465 behavior preserved
# ==============================================================
suite_regression() {
    separator "Suite 7: Regression - SEE-465 behavior preserved"

    setup
    local repo_dir
    repo_dir=$(create_test_repo)

    cd "$repo_dir"
    git checkout -b "current-regression" >/dev/null 2>&1
    echo "regression" > reg.txt
    git add reg.txt
    git commit -m "feat: regression test" >/dev/null 2>&1
    git push -u origin "current-regression" >/dev/null 2>&1

    # No open PRs → normal PR creation flow still works
    create_mock_gh ""
    > /tmp/test-see523-gh-calls.log

    cd "$repo_dir"
    run_hook '{}' "$repo_dir"

    assert_exit 0 "S7.T1: normal PR creation flow preserved"
    assert_stderr_contains "Draft PR created" "S7.T1: PR created in normal flow"
}

# ==============================================================
# Main
# ==============================================================
echo "=================================================="
echo "QA Test Suite: Cherry-pick Detection (SEE-523)"
echo "Target: .claude/hooks/scripts/auto-pr-on-stop.sh"
echo "Date: $(date -u '+%Y-%m-%d %H:%M UTC')"
echo "Branch: $(git branch --show-current 2>/dev/null || echo 'N/A')"
echo "=================================================="

assert_file_exists "$HOOK_SCRIPT" "Pre-check: target script exists"

suite_static_checks
suite_scenario_a_skip
suite_scenario_b_partial
suite_scenario_c_no_pr
suite_patch_id_fallback
suite_boundary_conditions
suite_regression

# --- Cleanup ---
cd "$ORIG_DIR"
for item in "${cleanup_items[@]}"; do
    rm -rf "$item" 2>/dev/null || true
done
rm -f /tmp/test-see523-*.log 2>/dev/null || true
rm -f /tmp/test-see523-*.txt 2>/dev/null || true

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
