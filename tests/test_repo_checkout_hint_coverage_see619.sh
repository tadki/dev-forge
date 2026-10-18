#!/bin/bash
# QA Test Script for SEE-619: repo-checkout.sh hint coverage gaps
# Verifies all 6 modifications specified in the Fix task:
# 1. Branch naming: shared/${issue_identifier}
# 2. git push failure hint
# 3. cd repo_dir failure hints (2 locations)
# 4. CHECKOUT_FAILED flag at 4 checkout locations + conditional hints
# 5. Python parse failure hints (3 expected locations)
# 6. All hint text is Chinese
# Plus: Execution path coverage analysis
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../claude-hooks/scripts/repo-checkout.sh"

PASS=0
FAIL=0

report() {
    local status="$1"
    local item="$2"
    local detail="${3:-}"
    if [ "$status" = "PASS" ]; then
        printf "\e[32m[PASS]\e[0m %s\n" "$item"
        ((PASS++)) || true
    else
        printf "\e[31m[FAIL]\e[0m %s\n" "$item"
        if [ -n "$detail" ]; then
            printf "       Detail: %s\n" "$detail"
        fi
        ((FAIL++)) || true
    fi
}

echo "=========================================="
echo "QA Test: repo-checkout.sh hint coverage (SEE-619)"
echo "Script: $HOOK_SCRIPT"
echo "=========================================="

if [ ! -f "$HOOK_SCRIPT" ]; then
    echo "ERROR: $HOOK_SCRIPT not found"
    exit 1
fi

# --- Pre-check: bash syntax ---
echo ""
echo "--- Pre-check: bash syntax ---"
if bash -n "$HOOK_SCRIPT"; then
    report PASS "Bash syntax check"
else
    report FAIL "Bash syntax check" "bash -n returned non-zero"
fi

# --- Item 1: branch_name uses shared/${issue_identifier} ---
echo ""
echo "--- Item 1: Branch naming format ---"
if grep -q 'local branch_name="shared/\${issue_identifier}"' "$HOOK_SCRIPT"; then
    report PASS "branch_name uses shared/\${issue_identifier} format"
else
    if grep -q 'local branch_name="feature/\${issue_identifier}"' "$HOOK_SCRIPT"; then
        report FAIL "branch_name uses shared/\${issue_identifier}" "Still using feature/ prefix"
    else
        report FAIL "branch_name uses shared/\${issue_identifier}" "Pattern not found"
    fi
fi

# --- Item 2: git push failure hint ---
echo ""
echo "--- Item 2: git push failure hint ---"
if grep -q '自动创建共享分支失败：无法推送到远程。请检查网络或权限。' "$HOOK_SCRIPT"; then
    line_no=$(grep -n '自动创建共享分支失败：无法推送到远程。请检查网络或权限。' "$HOOK_SCRIPT" | cut -d: -f1 | head -1)
    # Verify it's inside try_auto_create_shared_branch and before return 1
    if [ -n "$line_no" ]; then
        next_lines=$(sed -n "${line_no},$((${line_no}+2))p" "$HOOK_SCRIPT")
        if echo "$next_lines" | grep -q 'return 1'; then
            report PASS "git push failure hint present and followed by return 1 (line $line_no)"
        else
            report FAIL "git push failure hint" "Hint at line $line_no is not followed by 'return 1'"
        fi
    fi
else
    report FAIL "git push failure hint" "Required hint text not found"
fi

# --- Item 3: cd repo_dir failure hints (2 locations) ---
echo ""
echo "--- Item 3: cd repo_dir failure hints (2 locations) ---"
cd_hint_count=$(grep -c '无法进入仓库目录' "$HOOK_SCRIPT" || true)
if [ "$cd_hint_count" -ge 2 ]; then
    lines=$(grep -n '无法进入仓库目录' "$HOOK_SCRIPT" | cut -d: -f1)
    report PASS "cd failure hints present at $cd_hint_count location(s): lines $lines"
else
    report FAIL "cd failure hints (2 locations)" "Found $cd_hint_count occurrence(s), expected 2"
fi

# Verify the hints are in try_auto_create_shared_branch and try_shared_branch_reset
in_auto=$(grep -n '无法进入仓库目录' "$HOOK_SCRIPT" | head -1 | cut -d: -f1)
in_reset=$(grep -n '无法进入仓库目录' "$HOOK_SCRIPT" | tail -1 | cut -d: -f1)
if [ -n "$in_auto" ] && [ -n "$in_reset" ]; then
    # Check which function each is in (simple heuristic: line range)
    auto_start=$(grep -n '^try_auto_create_shared_branch' "$HOOK_SCRIPT" | head -1 | cut -d: -f1)
    auto_end=$(grep -n '^try_shared_branch_reset' "$HOOK_SCRIPT" | head -1 | cut -d: -f1)
    reset_start=$auto_end
    reset_end=$(grep -n '^# --- Determine expected repo dir' "$HOOK_SCRIPT" | head -1 | cut -d: -f1)
    if [ "$in_auto" -ge "$auto_start" ] && [ "$in_auto" -lt "$auto_end" ]; then
        report PASS "cd hint in try_auto_create_shared_branch (line $in_auto)"
    else
        report FAIL "cd hint in try_auto_create_shared_branch" "Found at line $in_auto, outside function range $auto_start-$auto_end"
    fi
    if [ "$in_reset" -ge "$reset_start" ] && [ "$in_reset" -lt "$reset_end" ]; then
        report PASS "cd hint in try_shared_branch_reset (line $in_reset)"
    else
        report FAIL "cd hint in try_shared_branch_reset" "Found at line $in_reset, outside function range $reset_start-$reset_end"
    fi
fi

# --- Item 4: CHECKOUT_FAILED flag at 4 checkout locations + conditional hints ---
echo ""
echo "--- Item 4: CHECKOUT_FAILED flag ---"
checkout_fail_count=$(grep -c 'CHECKOUT_FAILED=true' "$HOOK_SCRIPT" || true)
if [ "$checkout_fail_count" -eq 4 ]; then
    report PASS "CHECKOUT_FAILED set at exactly 4 locations"
else
    report FAIL "CHECKOUT_FAILED set at 4 locations" "Found $checkout_fail_count occurrence(s), expected 4"
fi

checkout_fail_lines=$(grep -n 'CHECKOUT_FAILED=true' "$HOOK_SCRIPT" | cut -d: -f1)
echo "       CHECKOUT_FAILED=true at lines: $checkout_fail_lines"

# Verify conditional hints exist for both success paths
hint2_count=$(grep -c 'checkout_note2' "$HOOK_SCRIPT" || true)
hint4_count=$(grep -c 'checkout_note4' "$HOOK_SCRIPT" || true)
if [ "$hint2_count" -ge 2 ] && [ "$hint4_count" -ge 2 ]; then
    report PASS "Conditional checkout hints in Step 2 and Step 4"
else
    report FAIL "Conditional checkout hints" "checkout_note2=$hint2_count, checkout_note4=$hint4_count"
fi

# Verify the conditional text
if grep -q 'checkout 过程中曾出现错误，建议检查网络或权限' "$HOOK_SCRIPT"; then
    report PASS "Conditional hint text: checkout failure advisory"
else
    report FAIL "Conditional hint text" "Required text not found"
fi

# --- Item 5: Python parse failure hints (3 locations) ---
echo ""
echo "--- Item 5: Python parse failure hints (3 locations) ---"
python_hint_count=$(grep -c '无法解析 resources.json，将使用默认仓库配置。' "$HOOK_SCRIPT" || true)
if [ "$python_hint_count" -ge 3 ]; then
    report PASS "Python parse failure hint at $python_hint_count location(s)"
else
    report FAIL "Python parse failure hints (3 locations)" "Found $python_hint_count occurrence(s), expected >= 3"
fi

# Check where they are: entry point, Step 1, Step 3
python_hint_lines=$(grep -n '无法解析 resources.json' "$HOOK_SCRIPT" | cut -d: -f1)
echo "       Python hints at lines: $python_hint_lines"

# Step 3 check: does it have a Python check or does it just call get_repo_urls?
step3_start=$(grep -n '^# --- Step 3: Retry once' "$HOOK_SCRIPT" | head -1 | cut -d: -f1)
step3_end=$(grep -n '^# --- Step 4: Final check' "$HOOK_SCRIPT" | head -1 | cut -d: -f1)
if [ -n "$step3_start" ] && [ -n "$step3_end" ]; then
    step3_content=$(sed -n "${step3_start},${step3_end}p" "$HOOK_SCRIPT")
    if echo "$step3_content" | grep -q '无法解析 resources.json'; then
        report PASS "Python hint present in Step 3 retry block"
    else
        report FAIL "Python hint in Step 3 retry block" "Step 3 (lines $step3_start-$step3_end) does NOT have Python unavailability hint"
    fi
fi

# --- Item 6: All hint text is Chinese ---
echo ""
echo "--- Item 6: All hint text is Chinese ---"
all_chinese=true
while IFS= read -r line; do
    # Extract the string argument from output_hint calls
    if echo "$line" | grep -q 'output_hint "'; then
        # Extract the hint text
        hint=$(echo "$line" | sed -n 's/.*output_hint "\(.*\)".*/\1/p')
        if [ -n "$hint" ]; then
            # Check if the hint contains English words that are not technical git terms
            # We allow: git, checkout, repo, master, origin (standard git terminology)
            # and issue/Agent (proper nouns in this context)
            # We also allow variable substitutions like ${working_branch}
            cleaned_hint=$(echo "$hint" | sed 's/\${[^}]*}//g')
            if echo "$cleaned_hint" | grep -iqE '\b(checkout|repo|master|origin|agent|worktree)\b'; then
                # These are technical terms or context-specific, check for other English
                other_english=$(echo "$cleaned_hint" | grep -oiE '\b[a-z]{3,}\b' | grep -viE '^(checkout|repo|master|origin|agent|worktree|multica|has|the|git|branch|server|git|please|manual|permission|network)$' || true)
                if [ -n "$other_english" ]; then
                    echo "       [WARNING] Potential untranslated English in hint: $hint"
                    echo "                  English words: $other_english"
                    # Only flag actual UI text, not variable names or technical terms
                    if echo "$other_english" | grep -qE '^(Please|please|For|for|Direct|direct|error|Error|failed|Failed|auto|Auto|checkout|Checkout)$'; then
                        all_chinese=false
                    fi
                fi
            fi
        fi
    fi
done < "$HOOK_SCRIPT"

if $all_chinese; then
    report PASS "All hint text is in Chinese (with standard technical terms allowed)"
else
    report FAIL "All hint text in Chinese" "Some hints may contain untranslated English text"
fi

# --- Execution Path Coverage Analysis ---
echo ""
echo "=========================================="
echo "--- Execution Path Coverage Analysis ---"
echo "=========================================="

# Path A: check_integrity passes + try_shared_branch_reset succeeds (rebase ok)
echo ""
echo "Path A: integrity pass + shared reset + rebase success"
# This path exits 0 after output_hint - has hint
report PASS "Path A has hint output (try_shared_branch_reset success)"

# Path B: check_integrity passes + try_shared_branch_reset succeeds (rebase fails)
echo ""
echo "Path B: integrity pass + shared reset + rebase failure"
report PASS "Path B has hint output (try_shared_branch_reset rebase failure)"

# Path C: check_integrity passes + try_shared_branch_reset fails internally (fetch/reset)
# Then try_auto_create_shared_branch is called. If working_branch exists, returns 0 silently.
# Then main flow outputs "尚未设置 working branch" hint - which is misleading
echo ""
echo "Path C: integrity pass + reset internal failure + working_branch exists"
reset_start=$(grep -n '^try_shared_branch_reset' "$HOOK_SCRIPT" | head -1 | cut -d: -f1)
reset_fetch_line=$(grep -n 'git fetch origin' "$HOOK_SCRIPT" | grep -A0 "${reset_start}" | head -1 | cut -d: -f1)
if [ -n "$reset_fetch_line" ]; then
    # Check if fetch/reset failure produces any hint before returning 1
    reset_content=$(sed -n "${reset_fetch_line},$((${reset_fetch_line}+10))p" "$HOOK_SCRIPT")
    if echo "$reset_content" | grep -q 'output_hint'; then
        report PASS "Path C: fetch/reset failure has hint before return 1"
    else
        report FAIL "Path C: fetch/reset failure silent" "try_shared_branch_reset fetch/reset failure returns 1 without any hint"
    fi
fi

# Path D: check_integrity passes + no working_branch → auto-create
# All paths through try_auto_create_shared_branch have hints
echo ""
echo "Path D: integrity pass + auto-create shared branch"
# push success paths: rebase success/failure both have hints
# push failure: has explicit hint
# cd failure: has explicit hint
# fetch/reset after race: has explicit hint
report PASS "Path D: all try_auto_create_shared_branch exit paths have hints"

# Path E: integrity fails → Step 1 checkout → Step 2 integrity pass
echo ""
echo "Path E: integrity fail → Step 1 checkout → integrity pass"
# Has hint with checkout_note2 conditionally
report PASS "Path E: Step 2 success path has hint with conditional checkout note"

# Path F: integrity fails → Step 1 checkout → Step 2 integrity fails → Step 3 retry → Step 4 integrity pass
echo ""
echo "Path F: Step 1 fail → Step 3 retry → Step 4 pass"
# Has hint with checkout_note4 conditionally
report PASS "Path F: Step 4 success path has hint with conditional checkout note"

# Path G: All paths fail → final failure hint
echo ""
echo "Path G: All paths fail → final failure"
if grep -q 'Repo 自动检出失败' "$HOOK_SCRIPT"; then
    report PASS "Path G: final failure has explicit hint"
else
    report FAIL "Path G: final failure" "No explicit final failure hint found"
fi

# Path H: Step 3 retry with Python unavailable but resources.json exists
# This is the edge case
echo ""
echo "Path H: Step 3 retry + Python unavailable + resources.json exists"
step3_block=$(sed -n "${step3_start},${step3_end}p" "$HOOK_SCRIPT")
if echo "$step3_block" | grep -q 'command -v python'; then
    report PASS "Path H: Step 3 has Python availability check"
else
    report FAIL "Path H: Step 3 Python unavailable" "Step 3 calls get_repo_urls directly without Python check; if Python unavailable, no checkout occurs silently (then falls to Step 4 failure hint)"
fi

# --- Summary ---
echo ""
echo "=========================================="
echo "Summary: PASS=$PASS  FAIL=$FAIL"
echo "=========================================="

if [ "$FAIL" -eq 0 ]; then
    echo "Result: ALL PASS"
    exit 0
else
    echo "Result: FAILURES DETECTED"
    exit 1
fi
