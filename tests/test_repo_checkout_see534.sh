#!/bin/bash
# QA Test Script for SEE-534: repo-checkout.sh refactoring
# Verifies: marker file removed, check_integrity() as sole source of truth,
#           git detection removed, correct flow: integrity → checkout → retry → final check
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../claude-hooks/scripts/repo-checkout.sh"

PASS=0
FAIL=0
SKIP=0
TMPDIR=""

cleanup() {
    if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
        rm -rf "$TMPDIR"
    fi
}
trap cleanup EXIT
TMPDIR=$(mktemp -d)

# Create a minimal valid git repo for integrity check tests
make_valid_repo() {
    local dir="$1"
    mkdir -p "$dir"
    (cd "$dir" && git init --quiet && echo "hello" > "test.txt" && git add test.txt && git commit -m "init" --quiet)
}

# Create a mock multica that succeeds (creates a valid repo)
make_mock_multica_success() {
    local bindir="$1"
    local repo_name="$2"
    mkdir -p "$bindir"
    cat > "$bindir/multica" <<SCRIPT
#!/bin/bash
# Mock multica: create a valid git repo at expected location
if [ "\$1" = "repo" ] && [ "\$2" = "checkout" ]; then
    repo_dir="\$(basename "\$3" .git)"
    if [ ! -d "\$repo_dir" ]; then
        mkdir -p "\$repo_dir"
        cd "\$repo_dir"
        git init --quiet
        echo "mock-file" > mock.txt
        git add mock.txt
        git commit -m "mock init" --quiet
    fi
    exit 0
fi
exit 0
SCRIPT
    chmod +x "$bindir/multica"
}

# Create a mock multica that fails (does nothing)
make_mock_multica_fail() {
    local bindir="$1"
    mkdir -p "$bindir"
    cat > "$bindir/multica" <<'SCRIPT'
#!/bin/bash
# Mock multica: always fails silently
exit 1
SCRIPT
    chmod +x "$bindir/multica"
}

# Helper: run hook script in a controlled env with optional mock PATH
run_hook() {
    local workdir="$1"
    shift
    local extra_path=""
    if [ $# -gt 0 ]; then
        extra_path="$1:"
    fi
    (cd "$workdir" && PATH="${extra_path}${PATH}" bash "$HOOK_SCRIPT" 2>&1) || true
}

# Extract additionalContext from JSON output
get_hint() {
    echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin)['hookSpecificOutput']['additionalContext'])" 2>/dev/null || echo ""
}

# ============================================================
# Suite A: Entry Point — check_integrity() First
# ============================================================

test_A1_valid_repo_exists_skip_checkout() {
    echo "[TEST A1] Valid repo exists → success hint on first check, exit 0..."
    local wd="$TMPDIR/A1"
    mkdir -p "$wd/.multica/project"
    echo '{"resources":[{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/tadki/KingOfLikes-Godot.git"}}]}' > "$wd/.multica/project/resources.json"
    make_valid_repo "$wd/KingOfLikes-Godot"

    local out
    out=$(run_hook "$wd")

    local hint
    hint=$(get_hint "$out")
    if echo "$hint" | grep -q "自动检出" && \
       echo "$hint" | grep -q "cd 到" && \
       echo "$hint" | grep -q "KingOfLikes-Godot"; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Expected success hint with repo name, got: $hint"
        FAIL=$((FAIL+1))
    fi
}

test_A2_no_repo_no_resources_fallback() {
    echo "[TEST A2] No repo, no resources.json → fallback checkout with mock..."
    local wd="$TMPDIR/A2"
    mkdir -p "$wd"
    local mockbin="$TMPDIR/A2_mock_bin"
    make_mock_multica_success "$mockbin" "KingOfLikes-Godot"

    local out
    out=$(run_hook "$wd" "$mockbin")

    local hint
    hint=$(get_hint "$out")
    if echo "$hint" | grep -q "自动检出"; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Expected success hint after fallback checkout, got: $hint"
        FAIL=$((FAIL+1))
    fi
}

test_A3_corrupt_repo_dir_proceeds_to_checkout() {
    echo "[TEST A3] Repo dir exists but empty (no .git) → proceeds to checkout..."
    local wd="$TMPDIR/A3"
    mkdir -p "$wd/.multica/project"
    echo '{"resources":[{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/tadki/KingOfLikes-Godot.git"}}]}' > "$wd/.multica/project/resources.json"
    # Create corrupt repo (no .git, no files)
    mkdir -p "$wd/KingOfLikes-Godot"

    local mockbin="$TMPDIR/A3_mock_bin"
    make_mock_multica_success "$mockbin" "KingOfLikes-Godot"

    local out
    out=$(run_hook "$wd" "$mockbin")

    local hint
    hint=$(get_hint "$out")
    if echo "$hint" | grep -q "自动检出"; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Expected success hint after fixing corrupt repo, got: $hint"
        FAIL=$((FAIL+1))
    fi
}

# ============================================================
# Suite B: Marker File Completely Ignored (Regression)
# ============================================================

test_B1_marker_success_but_corrupt_repo_proceeds() {
    echo "[TEST B1] Marker file 'success' + corrupt repo → NOT skipped, proceeds to checkout..."
    local wd="$TMPDIR/B1"
    mkdir -p "$wd/.multica/project"
    echo '{"resources":[{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/tadki/KingOfLikes-Godot.git"}}]}' > "$wd/.multica/project/resources.json"
    # Old marker file says success
    echo "success" > "$wd/.repos-checked-out"
    # But repo is corrupt (missing .git)
    mkdir -p "$wd/KingOfLikes-Godot"

    local mockbin="$TMPDIR/B1_mock_bin"
    make_mock_multica_success "$mockbin" "KingOfLikes-Godot"

    local out
    out=$(run_hook "$wd" "$mockbin")

    local hint
    hint=$(get_hint "$out")
    # Should NOT show the old "previously failed" hint, should show success after checkout
    if echo "$hint" | grep -q "自动检出" && \
       ! echo "$hint" | grep -q "failed previously"; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Marker file should be ignored, got: $hint"
        FAIL=$((FAIL+1))
    fi
}

test_B2_marker_failed_but_valid_repo_succeeds() {
    echo "[TEST B2] Marker file 'failed' + valid repo → success hint (marker ignored)..."
    local wd="$TMPDIR/B2"
    mkdir -p "$wd/.multica/project"
    echo '{"resources":[{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/tadki/KingOfLikes-Godot.git"}}]}' > "$wd/.multica/project/resources.json"
    # Old marker file says failed
    echo "failed" > "$wd/.repos-checked-out"
    # But repo is actually valid
    make_valid_repo "$wd/KingOfLikes-Godot"

    local out
    out=$(run_hook "$wd")

    local hint
    hint=$(get_hint "$out")
    # Should show success, not "failed previously"
    if echo "$hint" | grep -q "自动检出" && \
       ! echo "$hint" | grep -q "failed"; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Should show success since repo is valid, got: $hint"
        FAIL=$((FAIL+1))
    fi
}

test_B3_no_marker_file_created() {
    echo "[TEST B3] After successful run, no marker file is created..."
    local wd="$TMPDIR/B3"
    mkdir -p "$wd/.multica/project"
    echo '{"resources":[{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/tadki/KingOfLikes-Godot.git"}}]}' > "$wd/.multica/project/resources.json"
    make_valid_repo "$wd/KingOfLikes-Godot"

    run_hook "$wd" >/dev/null 2>&1 || true

    if [ ! -f "$wd/.repos-checked-out" ]; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Marker file should not be created in new design"
        FAIL=$((FAIL+1))
    fi
}

# ============================================================
# Suite C: Git Detection Removed (Regression)
# ============================================================

test_C1_inside_git_repo_but_expected_repo_missing() {
    echo "[TEST C1] PWD is git repo but expected repo dir missing → proceeds to checkout..."
    local wd="$TMPDIR/C1"
    mkdir -p "$wd/.multica/project"
    echo '{"resources":[{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/tadki/KingOfLikes-Godot.git"}}]}' > "$wd/.multica/project/resources.json"
    # Make PWD itself a git repo (old behavior: would silently exit)
    (cd "$wd" && git init --quiet && echo "x" > x.txt && git add x.txt && git commit -m "init" --quiet)

    local mockbin="$TMPDIR/C1_mock_bin"
    make_mock_multica_success "$mockbin" "KingOfLikes-Godot"

    local out
    out=$(run_hook "$wd" "$mockbin")

    local hint
    hint=$(get_hint "$out")
    # Should NOT silently exit, should proceed to checkout
    if echo "$hint" | grep -q "自动检出"; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Should proceed to checkout even when PWD is git repo, got: $hint"
        FAIL=$((FAIL+1))
    fi
}

# ============================================================
# Suite D: Full Flow — Checkout + Retry
# ============================================================

test_D1_checkout_succeeds_first_try() {
    echo "[TEST D1] No repo dir → checkout succeeds on first try → success hint..."
    local wd="$TMPDIR/D1"
    mkdir -p "$wd/.multica/project"
    echo '{"resources":[{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/tadki/KingOfLikes-Godot.git"}}]}' > "$wd/.multica/project/resources.json"

    local mockbin="$TMPDIR/D1_mock_bin"
    make_mock_multica_success "$mockbin" "KingOfLikes-Godot"

    local out
    out=$(run_hook "$wd" "$mockbin")

    local hint
    hint=$(get_hint "$out")
    if echo "$hint" | grep -q "自动检出"; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Expected success hint, got: $hint"
        FAIL=$((FAIL+1))
    fi
}

test_D2_checkout_fails_retry_fails() {
    echo "[TEST D2] Checkout fails, retry fails → failure hint + cleanup..."
    local wd="$TMPDIR/D2"
    mkdir -p "$wd/.multica/project"
    echo '{"resources":[{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/tadki/KingOfLikes-Godot.git"}}]}' > "$wd/.multica/project/resources.json"

    local mockbin="$TMPDIR/D2_mock_bin"
    make_mock_multica_fail "$mockbin"

    local out
    out=$(run_hook "$wd" "$mockbin")

    local hint
    hint=$(get_hint "$out")
    if echo "$hint" | grep -q "自动检出失败"; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Expected failure hint, got: $hint"
        FAIL=$((FAIL+1))
    fi

    # Verify cleanup: repo dir should be removed after failure
    if [ ! -d "$wd/KingOfLikes-Godot" ]; then
        echo "  PASS (cleanup verified)"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Incomplete repo dir should be cleaned up after failure"
        FAIL=$((FAIL+1))
    fi
}

test_D3_corrupt_repo_cleaned_and_rechecked() {
    echo "[TEST D3] Corrupt repo → cleaned and re-checkout attempted..."
    local wd="$TMPDIR/D3"
    mkdir -p "$wd/.multica/project"
    echo '{"resources":[{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/tadki/KingOfLikes-Godot.git"}}]}' > "$wd/.multica/project/resources.json"
    # Create corrupt repo
    mkdir -p "$wd/KingOfLikes-Godot"
    echo "corrupt" > "$wd/KingOfLikes-Godot/corrupt.txt"

    local mockbin="$TMPDIR/D3_mock_bin"
    make_mock_multica_success "$mockbin" "KingOfLikes-Godot"

    local out
    out=$(run_hook "$wd" "$mockbin")

    local hint
    hint=$(get_hint "$out")
    if echo "$hint" | grep -q "自动检出"; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Expected success after retry, got: $hint"
        FAIL=$((FAIL+1))
    fi
}

# ============================================================
# Suite E: Hint Content Verification
# ============================================================

test_E1_success_hint_no_successfully() {
    echo "[TEST E1] Success hints do NOT contain 'successfully'..."
    local wd="$TMPDIR/E1"
    mkdir -p "$wd/.multica/project"
    echo '{"resources":[{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/tadki/KingOfLikes-Godot.git"}}]}' > "$wd/.multica/project/resources.json"
    make_valid_repo "$wd/KingOfLikes-Godot"

    local out
    out=$(run_hook "$wd")

    local hint
    hint=$(get_hint "$out")
    if echo "$hint" | grep -qi "successfully"; then
        echo "  FAIL: Success hint should not contain 'successfully', got: $hint"
        FAIL=$((FAIL+1))
    else
        echo "  PASS"
        PASS=$((PASS+1))
    fi
}

test_E2_failure_hint_correct_keywords() {
    echo "[TEST E2] Failure hint contains correct keywords..."
    local wd="$TMPDIR/E2"
    mkdir -p "$wd/.multica/project"
    echo '{"resources":[{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/tadki/KingOfLikes-Godot.git"}}]}' > "$wd/.multica/project/resources.json"

    local mockbin="$TMPDIR/E2_mock_bin"
    make_mock_multica_fail "$mockbin"

    local out
    out=$(run_hook "$wd" "$mockbin")

    local hint
    hint=$(get_hint "$out")
    if echo "$hint" | grep -q "自动检出失败" && \
       echo "$hint" | grep -q "手动 checkout" && \
       echo "$hint" | grep -q "严禁直接修改"; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Failure hint missing required keywords, got: $hint"
        FAIL=$((FAIL+1))
    fi
}

test_E3_hint_uses_detected_repo_dir() {
    echo "[TEST E3] Success hint references detected repo name from resources.json..."
    local wd="$TMPDIR/E3"
    mkdir -p "$wd/.multica/project"
    echo '{"resources":[{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/example/CustomRepo.git"}}]}' > "$wd/.multica/project/resources.json"
    make_valid_repo "$wd/CustomRepo"

    local out
    out=$(run_hook "$wd")

    local hint
    hint=$(get_hint "$out")
    if echo "$hint" | grep -q "CustomRepo"; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Hint should reference 'CustomRepo', got: $hint"
        FAIL=$((FAIL+1))
    fi
}

# ============================================================
# Suite F: resources.json Parsing
# ============================================================

test_F1_valid_resources_uses_detected_name() {
    echo "[TEST F1] Valid resources.json with URL → uses detected repo name..."
    local wd="$TMPDIR/F1"
    mkdir -p "$wd/.multica/project"
    echo '{"resources":[{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/example/MyRepo.git"}}]}' > "$wd/.multica/project/resources.json"
    make_valid_repo "$wd/MyRepo"

    local out
    out=$(run_hook "$wd")

    local hint
    hint=$(get_hint "$out")
    if echo "$hint" | grep -q "MyRepo"; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Should use 'MyRepo' from resources.json, got: $hint"
        FAIL=$((FAIL+1))
    fi
}

test_F2_empty_resources_falls_back() {
    echo "[TEST F2] Empty resources.json → falls back to REPO_NAME..."
    local wd="$TMPDIR/F2"
    mkdir -p "$wd/.multica/project"
    echo '{"resources":[]}' > "$wd/.multica/project/resources.json"
    make_valid_repo "$wd/KingOfLikes-Godot"

    local out
    out=$(run_hook "$wd")

    local hint
    hint=$(get_hint "$out")
    if echo "$hint" | grep -q "KingOfLikes-Godot"; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Should fall back to 'KingOfLikes-Godot', got: $hint"
        FAIL=$((FAIL+1))
    fi
}

test_F3_no_resources_file_falls_back() {
    echo "[TEST F3] No resources.json → falls back to REPO_NAME..."
    local wd="$TMPDIR/F3"
    mkdir -p "$wd"
    make_valid_repo "$wd/KingOfLikes-Godot"

    local out
    out=$(run_hook "$wd")

    local hint
    hint=$(get_hint "$out")
    if echo "$hint" | grep -q "KingOfLikes-Godot"; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Should fall back to 'KingOfLikes-Godot', got: $hint"
        FAIL=$((FAIL+1))
    fi
}

# ============================================================
# Suite G: output_hint() and check_integrity() Unchanged
# ============================================================

test_G1_output_hint_valid_json() {
    echo "[TEST G1] output_hint() produces valid JSON..."
    # Source the functions directly
    local wd="$TMPDIR/G1"
    mkdir -p "$wd"
    (cd "$wd" && source <(sed -n '/^output_hint/,/^}/p' "$HOOK_SCRIPT"))
    local out
    out=$(cd "$TMPDIR/G1" && source <(sed -n '/^output_hint/,/^}/p' "$HOOK_SCRIPT") && output_hint "test")
    if echo "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['hookSpecificOutput']['hookEventName']=='SessionStart'" 2>/dev/null; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: output_hint did not produce valid JSON"
        FAIL=$((FAIL+1))
    fi
}

test_G2_check_integrity_unchanged() {
    echo "[TEST G2] check_integrity() behavior unchanged..."
    local wd="$TMPDIR/G2"
    mkdir -p "$wd"

    # Extract check_integrity function
    local ci_script="$TMPDIR/G2_ci.sh"
    sed -n '/^check_integrity()/,/^}/p' "$HOOK_SCRIPT" > "$ci_script"

    # Test with valid repo
    make_valid_repo "$wd/valid"
    if (cd "$wd" && source "$ci_script" && check_integrity "valid"); then
        PASS=$((PASS+1))
    else
        echo "  FAIL: check_integrity should pass on valid repo"
        FAIL=$((FAIL+1))
    fi

    # Test with missing dir
    if (cd "$wd" && source "$ci_script" && check_integrity "nonexistent" 2>/dev/null); then
        echo "  FAIL: check_integrity should fail on missing dir"
        FAIL=$((FAIL+1))
    else
        PASS=$((PASS+1))
    fi

    # Test with empty repo (only .git)
    mkdir -p "$wd/empty"
    (cd "$wd/empty" && git init --quiet)
    if (cd "$wd" && source "$ci_script" && check_integrity "empty" 2>/dev/null); then
        echo "  FAIL: check_integrity should fail on empty repo"
        FAIL=$((FAIL+1))
    else
        PASS=$((PASS+1))
        echo "  PASS (3 sub-tests)"
    fi
}

# ============================================================
# Suite H: Script Structure Verification
# ============================================================

test_H1_no_marker_file_references() {
    echo "[TEST H1] Script contains no MARKER_FILE references..."
    if grep -q "MARKER_FILE" "$HOOK_SCRIPT"; then
        echo "  FAIL: Script still references MARKER_FILE"
        FAIL=$((FAIL+1))
    else
        echo "  PASS"
        PASS=$((PASS+1))
    fi
}

test_H2_no_git_rev_parse_skip() {
    echo "[TEST H2] Script has no 'git rev-parse --git-dir' silent exit..."
    if grep -A2 "git rev-parse" "$HOOK_SCRIPT" | grep -q "exit 0"; then
        echo "  FAIL: Found git rev-parse with exit 0 pattern"
        FAIL=$((FAIL+1))
    else
        echo "  PASS"
        PASS=$((PASS+1))
    fi
}

test_H3_no_repos_checked_out_file() {
    echo "[TEST H3] Script contains no '.repos-checked-out' references..."
    if grep -q "\.repos-checked-out" "$HOOK_SCRIPT"; then
        echo "  FAIL: Script still references .repos-checked-out"
        FAIL=$((FAIL+1))
    else
        echo "  PASS"
        PASS=$((PASS+1))
    fi
}

test_H4_check_integrity_called_at_entry() {
    echo "[TEST H4] check_integrity() is called at script entry point..."
    # The first substantive call after function definitions should be check_integrity
    local entry_section
    entry_section=$(sed -n '/^# --- Determine expected/,/^# --- Step 1/p' "$HOOK_SCRIPT" | grep "check_integrity")
    if [ -n "$entry_section" ]; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: check_integrity() not called at entry point"
        FAIL=$((FAIL+1))
    fi
}

test_H5_three_functions_unchanged() {
    echo "[TEST H5] output_hint, get_repo_urls, check_integrity functions present..."
    local has_output_hint has_get_urls has_check
    has_output_hint=$(grep -c "^output_hint()" "$HOOK_SCRIPT" || true)
    has_get_urls=$(grep -c "^get_repo_urls()" "$HOOK_SCRIPT" || true)
    has_check=$(grep -c "^check_integrity()" "$HOOK_SCRIPT" || true)

    if [ "$has_output_hint" -ge 1 ] && [ "$has_get_urls" -ge 1 ] && [ "$has_check" -ge 1 ]; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Missing functions: output_hint=$has_output_hint, get_repo_urls=$has_get_urls, check_integrity=$has_check"
        FAIL=$((FAIL+1))
    fi
}

# ============================================================
# Run All Tests
# ============================================================
echo "=============================================="
echo "SEE-534 QA: repo-checkout.sh Refactoring Tests"
echo "=============================================="
echo ""

echo "--- Suite A: Entry Point — check_integrity() First ---"
test_A1_valid_repo_exists_skip_checkout
test_A2_no_repo_no_resources_fallback
test_A3_corrupt_repo_dir_proceeds_to_checkout

echo ""
echo "--- Suite B: Marker File Ignored (Regression) ---"
test_B1_marker_success_but_corrupt_repo_proceeds
test_B2_marker_failed_but_valid_repo_succeeds
test_B3_no_marker_file_created

echo ""
echo "--- Suite C: Git Detection Removed (Regression) ---"
test_C1_inside_git_repo_but_expected_repo_missing

echo ""
echo "--- Suite D: Full Flow — Checkout + Retry ---"
test_D1_checkout_succeeds_first_try
test_D2_checkout_fails_retry_fails
test_D3_corrupt_repo_cleaned_and_rechecked

echo ""
echo "--- Suite E: Hint Content Verification ---"
test_E1_success_hint_no_successfully
test_E2_failure_hint_correct_keywords
test_E3_hint_uses_detected_repo_dir

echo ""
echo "--- Suite F: resources.json Parsing ---"
test_F1_valid_resources_uses_detected_name
test_F2_empty_resources_falls_back
test_F3_no_resources_file_falls_back

echo ""
echo "--- Suite G: Unchanged Functions ---"
test_G1_output_hint_valid_json
test_G2_check_integrity_unchanged

echo ""
echo "--- Suite H: Script Structure ---"
test_H1_no_marker_file_references
test_H2_no_git_rev_parse_skip
test_H3_no_repos_checked_out_file
test_H4_check_integrity_called_at_entry
test_H5_three_functions_unchanged

echo ""
echo "=============================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
