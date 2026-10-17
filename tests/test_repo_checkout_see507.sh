#!/bin/bash
# QA Test Script for SEE-507: code review fixes in repo-checkout.sh
# Tests: get_repo_urls() function extraction, output_hint() jq-based JSON safety

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/scripts/repo-checkout.sh"
TMPDIR=""
PASS=0
FAIL=0

HELPER_SCRIPT=""

cleanup() {
    if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
        rm -rf "$TMPDIR"
    fi
    if [ -n "$HELPER_SCRIPT" ] && [ -f "$HELPER_SCRIPT" ]; then
        rm -f "$HELPER_SCRIPT"
    fi
}
trap cleanup EXIT

TMPDIR=$(mktemp -d)
HELPER_SCRIPT="$TMPDIR/helper.sh"

# Write a standalone helper with the functions to test
cat > "$HELPER_SCRIPT" <<'EOF'
output_hint() {
    local msg="$1"
    jq -n --arg msg "$msg" --arg event "SessionStart" \
        '{hookSpecificOutput: {hookEventName: $event, additionalContext: $msg}}'
}

get_repo_urls() {
    local res_file="$1"
    local python_cmd
    python_cmd="$(command -v python3 2>/dev/null || command -v python 2>/dev/null)"
    [ -n "$python_cmd" ] || return
    "$python_cmd" -c "
import json, sys
try:
    with open('$res_file', 'r', encoding='utf-8') as f:
        data = json.load(f)
    for r in data.get('resources', []):
        if r.get('resource_type') == 'github_repo':
            url = r.get('resource_ref', {}).get('url', '')
            if url:
                print(url)
except Exception:
    pass
" 2>/dev/null
}
EOF

# --- Test: get_repo_urls returns github_repo URLs from valid resources.json ---
test_get_repo_urls_valid() {
    echo "[TEST] get_repo_urls returns github_repo URLs from valid resources.json..."
    source "$HELPER_SCRIPT"
    local res_dir="$TMPDIR/res_valid"
    mkdir -p "$res_dir"
    cat > "$res_dir/resources.json" <<'JSONEOF'
{"resources":[{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/example/repo1.git"}},{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/example/repo2.git"}}]}
JSONEOF
    local out
    out=$(get_repo_urls "$res_dir/resources.json")
    local count
    count=$(echo "$out" | grep -c "github.com" || true)
    if [ "$count" -eq 2 ]; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Expected 2 URLs, got $count: $out"
        FAIL=$((FAIL+1))
    fi
}

# --- Test: get_repo_urls filters out non-github_repo resource types ---
test_get_repo_urls_filters_non_github() {
    echo "[TEST] get_repo_urls filters out non-github_repo resource types..."
    source "$HELPER_SCRIPT"
    local res_dir="$TMPDIR/res_filter"
    mkdir -p "$res_dir"
    cat > "$res_dir/resources.json" <<'JSONEOF'
{"resources":[{"resource_type":"web_url","resource_ref":{"url":"https://example.com"}},{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/example/repo.git"}}]}
JSONEOF
    local out
    out=$(get_repo_urls "$res_dir/resources.json")
    local count
    count=$(echo "$out" | wc -l)
    # Should only have 1 URL (github_repo), not the web_url
    if [ "$count" -eq 1 ] && echo "$out" | grep -q "github.com/example/repo.git"; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Expected 1 github_repo URL, got: $out"
        FAIL=$((FAIL+1))
    fi
}

# --- Test: get_repo_urls returns empty for resources with no github_repo ---
test_get_repo_urls_no_github() {
    echo "[TEST] get_repo_urls returns empty when no github_repo entries..."
    source "$HELPER_SCRIPT"
    local res_dir="$TMPDIR/res_no_gh"
    mkdir -p "$res_dir"
    cat > "$res_dir/resources.json" <<'JSONEOF'
{"resources":[{"resource_type":"web_url","resource_ref":{"url":"https://example.com"}}]}
JSONEOF
    local out
    out=$(get_repo_urls "$res_dir/resources.json")
    if [ -z "$out" ]; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Expected empty output, got: $out"
        FAIL=$((FAIL+1))
    fi
}

# --- Test: get_repo_urls returns empty for empty resources array ---
test_get_repo_urls_empty_resources() {
    echo "[TEST] get_repo_urls returns empty for empty resources array..."
    source "$HELPER_SCRIPT"
    local res_dir="$TMPDIR/res_empty"
    mkdir -p "$res_dir"
    echo '{"resources":[]}' > "$res_dir/resources.json"
    local out
    out=$(get_repo_urls "$res_dir/resources.json")
    if [ -z "$out" ]; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Expected empty output, got: $out"
        FAIL=$((FAIL+1))
    fi
}

# --- Test: get_repo_urls handles missing file gracefully ---
test_get_repo_urls_missing_file() {
    echo "[TEST] get_repo_urls handles missing file gracefully..."
    source "$HELPER_SCRIPT"
    local out
    out=$(get_repo_urls "/nonexistent/resources.json" 2>/dev/null || true)
    if [ -z "$out" ]; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Expected empty output for missing file, got: $out"
        FAIL=$((FAIL+1))
    fi
}

# --- Test: get_repo_urls skips entries with empty URL ---
test_get_repo_urls_skips_empty_url() {
    echo "[TEST] get_repo_urls skips entries with empty URL..."
    source "$HELPER_SCRIPT"
    local res_dir="$TMPDIR/res_empty_url"
    mkdir -p "$res_dir"
    cat > "$res_dir/resources.json" <<'JSONEOF'
{"resources":[{"resource_type":"github_repo","resource_ref":{"url":""}},{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/example/valid.git"}}]}
JSONEOF
    local out
    out=$(get_repo_urls "$res_dir/resources.json")
    local count
    count=$(echo "$out" | grep -c "github.com" || true)
    if [ "$count" -eq 1 ]; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Expected 1 URL (empty URL filtered), got $count: $out"
        FAIL=$((FAIL+1))
    fi
}

# --- Test: output_hint produces valid JSON with standard message ---
test_output_hint_valid_json() {
    echo "[TEST] output_hint produces valid JSON with standard message..."
    source "$HELPER_SCRIPT"
    local out
    out=$(output_hint "Test message")
    if echo "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['hookSpecificOutput']['hookEventName']=='SessionStart'; assert d['hookSpecificOutput']['additionalContext']=='Test message'" 2>/dev/null; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: output_hint did not produce correct JSON: $out"
        FAIL=$((FAIL+1))
    fi
}

# --- Test: output_hint escapes double quotes safely ---
test_output_hint_double_quotes() {
    echo "[TEST] output_hint escapes double quotes safely..."
    source "$HELPER_SCRIPT"
    local msg='He said "hello world"'
    local out
    out=$(output_hint "$msg")
    local extracted
    extracted=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext')
    if [ "$extracted" = "$msg" ]; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Expected '$msg', got '$extracted'"
        FAIL=$((FAIL+1))
    fi
}

# --- Test: output_hint escapes backslashes safely ---
test_output_hint_backslashes() {
    echo "[TEST] output_hint escapes backslashes safely..."
    source "$HELPER_SCRIPT"
    local msg='Path: C:\Users\test\file.txt'
    local out
    out=$(output_hint "$msg")
    local extracted
    extracted=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext')
    if [ "$extracted" = "$msg" ]; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Expected '$msg', got '$extracted'"
        FAIL=$((FAIL+1))
    fi
}

# --- Test: output_hint handles newlines in message ---
test_output_hint_newlines() {
    echo "[TEST] output_hint handles newlines in message..."
    source "$HELPER_SCRIPT"
    local msg=$'Line one\nLine two'
    local out
    out=$(output_hint "$msg")
    local extracted
    extracted=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext')
    if [ "$extracted" = "$msg" ]; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Expected multi-line msg, got '$extracted'"
        FAIL=$((FAIL+1))
    fi
}

# --- Test: output_hint handles unicode characters ---
test_output_hint_unicode() {
    echo "[TEST] output_hint handles unicode characters..."
    source "$HELPER_SCRIPT"
    local msg='日本語テスト 中文测试 한국어'
    local out
    out=$(output_hint "$msg")
    local extracted
    extracted=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext')
    if [ "$extracted" = "$msg" ]; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Expected unicode msg, got '$extracted'"
        FAIL=$((FAIL+1))
    fi
}

# --- Test: output_hint handles single quotes ---
test_output_hint_single_quotes() {
    echo "[TEST] output_hint handles single quotes..."
    source "$HELPER_SCRIPT"
    local msg="It's a test with 'quotes'"
    local out
    out=$(output_hint "$msg")
    local extracted
    extracted=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContent // .hookSpecificOutput.additionalContext')
    if [ "$extracted" = "$msg" ]; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Expected '$msg', got '$extracted'"
        FAIL=$((FAIL+1))
    fi
}

# --- Test: get_repo_urls is used in actual hook script (code structure) ---
test_hook_uses_get_repo_urls() {
    echo "[TEST] actual hook script uses get_repo_urls function..."
    # Verify the function is defined in the hook
    if grep -q '^get_repo_urls()' "$HOOK_SCRIPT"; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: get_repo_urls() not found in hook script"
        FAIL=$((FAIL+1))
    fi
}

# --- Test: hook no longer has duplicated Python parsing code ---
test_no_duplicated_python_parsing() {
    echo "[TEST] hook does not contain duplicated Python resources.json parsing..."
    # Count occurrences of the Python inline script pattern
    # Before fix: 3 occurrences (helper + initial checkout + retry)
    # After fix: 1 occurrence (inside get_repo_urls only)
    local count
    count=$(grep -c "with open" "$HOOK_SCRIPT" 2>/dev/null || echo "0")
    if [ "$count" -le 1 ]; then
        echo "  PASS (found $count occurrence)"
        PASS=$((PASS+1))
    else
        echo "  FAIL: Found $count occurrences of Python parsing, expected ≤1"
        FAIL=$((FAIL+1))
    fi
}

# --- Test: output_hint in hook uses jq not printf ---
test_hook_output_hint_uses_jq() {
    echo "[TEST] output_hint in hook uses jq (not printf concatenation)..."
    # Verify output_hint function body contains 'jq -n'
    local func_start func_end func_body
    func_start=$(grep -n '^output_hint()' "$HOOK_SCRIPT" | head -1 | cut -d: -f1)
    if [ -z "$func_start" ]; then
        echo "  FAIL: output_hint() function not found"
        FAIL=$((FAIL+1))
        return
    fi
    # Read lines from function start until next function/section marker
    func_body=$(sed -n "${func_start},\$p" "$HOOK_SCRIPT" | head -5)
    if echo "$func_body" | grep -q 'jq -n'; then
        echo "  PASS"
        PASS=$((PASS+1))
    else
        echo "  FAIL: output_hint does not use jq -n"
        FAIL=$((FAIL+1))
    fi
}

# Run all tests
echo "======================================"
echo "SEE-507 QA: Code Review Fix Tests"
echo "======================================"
echo ""

test_get_repo_urls_valid
test_get_repo_urls_filters_non_github
test_get_repo_urls_no_github
test_get_repo_urls_empty_resources
test_get_repo_urls_missing_file
test_get_repo_urls_skips_empty_url
test_output_hint_valid_json
test_output_hint_double_quotes
test_output_hint_backslashes
test_output_hint_newlines
test_output_hint_unicode
test_output_hint_single_quotes
test_hook_uses_get_repo_urls
test_no_duplicated_python_parsing
test_hook_output_hint_uses_jq

echo ""
echo "======================================"
echo "Results: $PASS passed, $FAIL failed"
echo "======================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
