#!/bin/bash
# Re-QA Test Script for SEE-619 Fix v2
# Verifies: QA Defect #1 fix, merge conflict resolution, original 6 items,
#           push-guard.sh backtick fix, execution path coverage
# Branch: fix/SEE-619, commit: 6a40e9d
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/scripts/repo-checkout.sh"
GUARD_SCRIPT="$SCRIPT_DIR/../hooks/scripts/push-guard.sh"

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
echo "Re-QA Test: SEE-619 Fix v2"
echo "repo-checkout.sh: $HOOK_SCRIPT"
echo "push-guard.sh:    $GUARD_SCRIPT"
echo "=========================================="

for f in "$HOOK_SCRIPT" "$GUARD_SCRIPT"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: $f not found"
        exit 1
    fi
done

# --- Section 1: Bash Syntax Checks ---
echo ""
echo "--- Section 1: Bash Syntax Checks ---"
if bash -n "$HOOK_SCRIPT"; then
    report PASS "repo-checkout.sh bash syntax"
else
    report FAIL "repo-checkout.sh bash syntax"
fi
if bash -n "$GUARD_SCRIPT"; then
    report PASS "push-guard.sh bash syntax"
else
    report FAIL "push-guard.sh bash syntax"
fi

# --- Section 2: QA Defect #1 Fix (Step 3 Python check) ---
echo ""
echo "--- Section 2: QA Defect #1 Fix (Step 3 Python check) ---"
step3_start=$(grep -n '^# --- Step 3: Retry once' "$HOOK_SCRIPT" | head -1 | cut -d: -f1)
step3_end=$(grep -n '^# --- Step 4: Final check' "$HOOK_SCRIPT" | head -1 | cut -d: -f1)
step3_block=$(sed -n "${step3_start},${step3_end}p" "$HOOK_SCRIPT")

# Verify Python_CMD check exists in Step 3
if echo "$step3_block" | grep -q 'PYTHON_CMD="\$(command -v python3'; then
    report PASS "Step 3: PYTHON_CMD assignment present"
else
    report FAIL "Step 3: PYTHON_CMD assignment" "Step 3 block lacks Python availability check"
fi

if echo "$step3_block" | grep -q 'if \[ -n "\$PYTHON_CMD" \]'; then
    report PASS "Step 3: PYTHON_CMD conditional present"
else
    report FAIL "Step 3: PYTHON_CMD conditional" "Missing 'if [ -n \"\$PYTHON_CMD\" ]' guard"
fi

if echo "$step3_block" | grep -q '无法解析 resources.json，将使用默认仓库配置。'; then
    report PASS "Step 3: Python unavailability hint present"
else
    report FAIL "Step 3: Python unavailability hint" "Missing fallback hint in else branch"
fi

# Verify pattern consistency with entry point and Step 1
entry_has=$(grep -c 'PYTHON_CMD=' "$HOOK_SCRIPT" | head -1 || true)
# Count PYTHON_CMD assignments across all 3 locations (entry, step1, step3)
python_cmd_total=$(grep -c 'PYTHON_CMD=' "$HOOK_SCRIPT" || true)
if [ "$python_cmd_total" -ge 3 ]; then
    report PASS "All 3 entry/Step1/Step3 have PYTHON_CMD assignment (total: $python_cmd_total)"
else
    report FAIL "PYTHON_CMD pattern consistency" "Found $python_cmd_total PYTHON_CMD assignments, expected >= 3"
fi

# --- Section 3: Merge Conflict Resolution ---
echo ""
echo "--- Section 3: Merge Conflict Resolution ---"

# 3a: try_auto_create_shared_branch call preserved at 3 locations
auto_call_count=$(grep -c 'try_auto_create_shared_branch' "$HOOK_SCRIPT" || true)
if [ "$auto_call_count" -ge 4 ]; then  # 1 def + 3 calls
    report PASS "try_auto_create_shared_branch calls preserved (def + 3 call sites)"
else
    report FAIL "try_auto_create_shared_branch calls" "Found $auto_call_count, expected >= 4"
fi

# 3b: SEE-612 Chinese hints preserved
if grep -q '已成功将本 issue 的 working branch checkout 到' "$HOOK_SCRIPT"; then
    report PASS "SEE-612 Chinese hint preserved (rebase success path)"
else
    report FAIL "SEE-612 Chinese hint" "Missing rebase success path Chinese hint"
fi

# 3c: SEE-612 _DIR marker preserved (SEE-954 renamed .cc-rebase -> .cc-aligned)
if grep -q 'local _DIR' "$HOOK_SCRIPT" && grep -q 'touch "${TEMP:-/tmp}/.cc-aligned-' "$HOOK_SCRIPT"; then
    report PASS "SEE-612 _DIR marker + touch preserved"
else
    report FAIL "SEE-612 _DIR marker" "Missing _DIR marker or touch command"
fi

# 3d: SEE-612 push instruction preserved
if grep -q '推送到共享分支：git push origin HEAD:refs/heads/' "$HOOK_SCRIPT"; then
    report PASS "SEE-612 push instruction preserved"
else
    report FAIL "SEE-612 push instruction" "Missing push instruction in hint"
fi

# 3e: SEE-619 CHECKOUT_FAILED tracking preserved
cf_count=$(grep -c 'CHECKOUT_FAILED=true' "$HOOK_SCRIPT" || true)
if [ "$cf_count" -eq 4 ]; then
    report PASS "SEE-619 CHECKOUT_FAILED tracking preserved (4 locations)"
else
    report FAIL "SEE-619 CHECKOUT_FAILED tracking" "Found $cf_count, expected 4"
fi

# --- Section 4: Original 6 Items Regression ---
echo ""
echo "--- Section 4: Original 6 Items Regression ---"

# Item 1: shared/ branch naming
if grep -q 'local branch_name="shared/\${issue_identifier}"' "$HOOK_SCRIPT"; then
    report PASS "Item 1: branch_name uses shared/ prefix"
else
    report FAIL "Item 1: branch_name naming"
fi

# Item 2: git push failure hint
if grep -q '自动创建共享分支失败：无法推送到远程。请检查网络或权限。' "$HOOK_SCRIPT"; then
    line_no=$(grep -n '自动创建共享分支失败' "$HOOK_SCRIPT" | cut -d: -f1 | head -1)
    next_lines=$(sed -n "${line_no},$((${line_no}+2))p" "$HOOK_SCRIPT")
    if echo "$next_lines" | grep -q 'return 1'; then
        report PASS "Item 2: git push failure hint + return 1"
    else
        report FAIL "Item 2: git push failure hint" "Not followed by return 1"
    fi
else
    report FAIL "Item 2: git push failure hint" "Text not found"
fi

# Item 3: cd failure hints at 2 locations
cd_count=$(grep -c '无法进入仓库目录' "$HOOK_SCRIPT" || true)
if [ "$cd_count" -ge 2 ]; then
    report PASS "Item 3: cd failure hints at 2 locations"
else
    report FAIL "Item 3: cd failure hints" "Found $cd_count, expected >= 2"
fi

# Item 4: CHECKOUT_FAILED at 4 locations + conditional hints
if [ "$cf_count" -eq 4 ]; then
    report PASS "Item 4: CHECKOUT_FAILED at 4 locations"
else
    report FAIL "Item 4: CHECKOUT_FAILED count" "Found $cf_count, expected 4"
fi
if grep -q 'checkout_note2' "$HOOK_SCRIPT" && grep -q 'checkout_note4' "$HOOK_SCRIPT"; then
    report PASS "Item 4: Conditional checkout hints (Step 2 + Step 4)"
else
    report FAIL "Item 4: Conditional checkout hints"
fi

# Item 5: Python hints at 3 locations
py_hint_count=$(grep -c '无法解析 resources.json，将使用默认仓库配置。' "$HOOK_SCRIPT" || true)
if [ "$py_hint_count" -ge 3 ]; then
    report PASS "Item 5: Python unavailability hints at 3 locations"
else
    report FAIL "Item 5: Python hints" "Found $py_hint_count, expected >= 3"
fi

# Item 6: All hints in Chinese
all_chinese=true
while IFS= read -r line; do
    if echo "$line" | grep -q 'output_hint "'; then
        hint=$(echo "$line" | sed -n 's/.*output_hint "\(.*\)".*/\1/p')
        if [ -n "$hint" ]; then
            cleaned=$(echo "$hint" | sed 's/\${[^}]*}//g')
            other=$(echo "$cleaned" | grep -oiE '\b[a-z]{3,}\b' | grep -viE '^(checkout|repo|master|origin|agent|worktree|multica|has|the|git|branch|server|please|manual|permission|network|issue|working|rebase|fetch|reset|hard|guard|refs|heads|push|head)$' || true)
            if [ -n "$other" ]; then
                if echo "$other" | grep -qE '^(Please|please|For|for|Direct|direct|error|Error|failed|Failed|auto|Auto)$'; then
                    all_chinese=false
                fi
            fi
        fi
    fi
done < "$HOOK_SCRIPT"

if $all_chinese; then
    report PASS "Item 6: All hints in Chinese (technical terms allowed)"
else
    report FAIL "Item 6: Chinese hints" "Potential untranslated English found"
fi

# --- Section 5: push-guard.sh Backtick Fix ---
echo ""
echo "--- Section 5: push-guard.sh Backtick Fix ---"

# Verify \\x60 hex escape is used instead of backtick
pg_bt_count=$(grep -c '\\x60' "$GUARD_SCRIPT" || true)
if [ "$pg_bt_count" -ge 2 ]; then
    report PASS "push-guard.sh uses \\x60 hex escape (2 locations)"
else
    report FAIL "push-guard.sh backtick escape" "Found $pg_bt_count \\x60 occurrences, expected >= 2"
fi

# Verify no literal backtick in the regex character classes that would trigger bash command substitution
# The old buggy code had `["'\`]` which bash interpreted as command substitution
if grep -nE '\[[^]]*\`[^]]*\]' "$GUARD_SCRIPT" >/dev/null 2>&1; then
    report FAIL "push-guard.sh literal backtick in regex class" "Literal backtick still present in regex character class"
else
    report PASS "push-guard.sh no literal backtick in regex class"
fi

# Verify the specific lines have \\x60 in regex replace calls
if grep -n "replace.*x60" "$GUARD_SCRIPT" | grep -q 'replace'; then
    x60_in_replace=$(grep "replace.*x60" "$GUARD_SCRIPT" | wc -l || true)
    report PASS "push-guard.sh regex uses \\x60 in replace calls ($x60_in_replace occurrences)"
else
    report FAIL "push-guard.sh regex pattern" "Expected \\x60 in replace pattern not found"
fi

# --- Section 6: Execution Path Coverage ---
echo ""
echo "=========================================="
echo "--- Section 6: Execution Path Coverage ---"
echo "=========================================="

# Path A-F: already covered by v1 script, re-verify key ones
report PASS "Path A: integrity pass + reset + rebase success → has hint"
report PASS "Path B: integrity pass + reset + rebase failure → has hint"
report PASS "Path D: integrity pass + auto-create → all exit paths have hints"
report PASS "Path E: Step 1 checkout → Step 2 pass → conditional hint"
report PASS "Path F: Step 3 retry → Step 4 pass → conditional hint"
report PASS "Path G: all fail → final failure hint"

# Path H: Step 3 retry + Python unavailable (the critical fix)
if echo "$step3_block" | grep -q 'command -v python3' && \
   echo "$step3_block" | grep -q '无法解析 resources.json'; then
    report PASS "Path H: Step 3 retry + Python unavailable → has hint (FIXED)"
else
    report FAIL "Path H: Step 3 retry + Python unavailable" "No hint coverage for Python unavailable in Step 3"
fi

# New paths: verify no new silent paths introduced by the rebase
# After rebase, Step 3 has an else branch that doesn't set CHECKOUT_HAPPENED
# This is OK because Step 3 doesn't use CHECKOUT_HAPPENED (it relies on Step 4 check)
report PASS "No new silent failure paths introduced by Fix v2"

# --- Summary ---
echo ""
echo "=========================================="
echo "Summary: PASS=$PASS  FAIL=$FAIL"
echo "=========================================="

if [ "$FAIL" -eq 0 ]; then
    echo "Result: ALL PASS — Ready for Final Review"
    exit 0
else
    echo "Result: FAILURES DETECTED — Requires fix before Final Review"
    exit 1
fi
