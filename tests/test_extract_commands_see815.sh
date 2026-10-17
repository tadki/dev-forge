#!/bin/bash
# Regression Test Suite for SEE-815: extractCommands multi-line command parsing
# Tests: splitShellCommands splits \n, &&, ||, ; while respecting quotes
#        child-issue-guard correctly blocks bypass via composite commands
#
# v2 redirect (SEE-1330): v1 `command_matches` → v2 `when-ops.js` 的
# extractCommands / splitShellCommands / parseCommand + evalCommandCurrent。
# Testee: node -e 'require("$PROJECT_ROOT/hooks/unified/when-ops.js")'
# 直接调用 createEvaluator，对每条原用例命令断言 child-issue-guard 条件
# {op:"command",scope:"current",pattern:"multica issue (create|update)",
#  has_flag:"--parent",flag_has_value:true} 的 fire / not-fire（即 BLOCK/ALLOW）。
# 期望逐字节等价于 v1 移植语义（pattern 原本就是头锚定形态，无期望翻转）。
# DRIFT（一行）：v2 pattern 为 parseCommand 的 base+subcommand ^前缀锚定；
# 本套件 fixture pattern 天然头锚定，全部用例期望与 v1 相同。
#
# Related Issue: SEE-815, SEE-1330
# Test Type: Regression + Unit
# Author: Bachi (Backend Agent)

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
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

separator() {
    echo ""
    echo -e "${CYAN}--- $1 ---${NC}"
}

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHEN_OPS_JS="$PROJECT_ROOT/hooks/unified/when-ops.js"

if [ ! -f "$WHEN_OPS_JS" ]; then
    echo "ERROR: when-ops.js not found at $WHEN_OPS_JS"
    exit 1
fi

FIXTURE_TASK="$(cat /proc/sys/kernel/random/uuid)"
FIX_PWD="/tmp/see815-hotfix-$$"
mkdir -p "$FIX_PWD"

RUN_ID="c815$(date +%s)"
check_match() { # $1 = payload json file; prints FIRE|QUIET
    node - "$WHEN_OPS_JS" "$FIXTURE_TASK" "$FIX_PWD" "$1" <<'NODEEOF'
const [whenOpsPath, taskId, cwd, payloadFile] = process.argv.slice(2);
const { createEvaluator } = require(whenOpsPath);
const fs = require('fs');
let cmd = '';
try { cmd = JSON.parse(fs.readFileSync(payloadFile, 'utf8')).tool_input.command; } catch (e) { cmd = ''; }
const payload = { hook_event_name: 'PreToolUse', tool_input: { command: cmd } };
const ev = createEvaluator(payload, { cwd, projectRoot: cwd, taskId });
const when = { op: 'command', scope: 'current', pattern: 'multica issue (create|update)', has_flag: '--parent', flag_has_value: true };
console.log(ev.evaluate(when) ? 'FIRE' : 'QUIET');
NODEEOF
}

assert_blocks() {
    local label="$1"
    if [ "$(echo "$HOOK_STDOUT" | grep -c FIRE)" -gt 0 ]; then
        pass "$label — BLOCKED"
    else
        fail "$label — NOT blocked. stdout: '${HOOK_STDOUT:0:200}'"
    fi
}

assert_allows() {
    local label="$1"
    if [ "$(echo "$HOOK_STDOUT" | grep -c FIRE)" -gt 0 ]; then
        fail "$label — incorrectly BLOCKED. stdout: '${HOOK_STDOUT:0:200}'"
    else
        pass "$label — ALLOWED"
    fi
}

echo "================================================================"
echo "  SEE-815 Regression: extractCommands composite command splitting"
echo "  Date: $(date -Iseconds)"
echo "  Testee: $WHEN_OPS_JS"
echo "  Branch: $(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo 'unknown')"
echo "================================================================"

#####################################################################
# Prerequisite
#####################################################################
separator "Prerequisites"

if node -e 'const m=require(process.argv[1]); if (typeof m.extractCommands==="function" && typeof m.splitShellCommands==="function" && typeof m.parseCommand==="function") process.exit(0); process.exit(1)' "$WHEN_OPS_JS" 2>/dev/null; then
    pass "when-ops.js loads and exports extractCommands/splitShellCommands/parseCommand"
else
    fail "when-ops.js missing required exports"
    exit 1
fi

if grep -q "function splitShellCommands" "$WHEN_OPS_JS"; then
    pass "splitShellCommands function present in when-ops.js"
else
    fail "splitShellCommands function MISSING in when-ops.js"
fi

if grep -q "function extractCommands" "$WHEN_OPS_JS"; then
    pass "extractCommands function present in when-ops.js"
else
    fail "extractCommands function MISSING in when-ops.js"
fi

if node --check "$WHEN_OPS_JS" 2>/dev/null; then
    pass "when-ops.js syntax gate (node --check)"
else
    fail "when-ops.js syntax gate"
fi

run_case() { # $1=block|allow $2=label ; $3=raw command string (plain)
    local expect="$1" label="$2" raw="$3"
    local payload_file="$FIX_PWD/payload-$RUN_ID.json"
    node -e '
const raw = process.argv[1];
console.log(JSON.stringify({ hook_event_name: "PreToolUse", tool_input: { command: raw } }));
' "$raw" > "$payload_file"
    HOOK_STDOUT=$(check_match "$payload_file")
    if [ "$expect" = "block" ]; then
        assert_blocks "$label"
    else
        assert_allows "$label"
    fi
}

#####################################################################
# S1: BLOCK — multi-line with # comment prefix
#####################################################################
separator "S1: BLOCK — # comment prefix + newline"

run_case block "S1a: # comment\\nmultica issue create --parent" "$(printf '# comment\nmultica issue create --parent abc123 --title test')"
run_case block "S1b: # comment\\nmultica issue update --parent" "$(printf '# set up env\nmultica issue update 420c414c --parent abc123')"
run_case block "S1c: multi-newline with comment and cd prefix" "$(printf '# step 1\ncd /home\nmultica issue create --parent 23bee88a --title sub')"

#####################################################################
# S2: BLOCK — && chain
#####################################################################
separator "S2: BLOCK — && chained commands"

run_case block "S2a: cd /tmp && multica issue create --parent" "cd /tmp && multica issue create --parent abc123 --title test"
run_case block "S2b: echo hello && multica issue update --parent" "echo hello && multica issue update 420c414c --parent abc123"
run_case block "S2c: triple && chain" "ls -la && pwd && multica issue create --parent abc123"

#####################################################################
# S3: BLOCK — ; separator
#####################################################################
separator "S3: BLOCK — ; separated commands"

run_case block "S3a: echo x; multica issue create --parent" "echo x; multica issue create --parent abc123 --title test"
run_case block "S3b: cd /home; multica issue update --parent" "cd /home; multica issue update id --parent abc123"
run_case block "S3c: triple ; chain" "echo a; echo b; multica issue create --parent abc123"

#####################################################################
# S4: BLOCK — || chain
#####################################################################
separator "S4: BLOCK — || chained commands"

run_case block "S4a: cd /tmp || multica issue create --parent" "cd /tmp || multica issue create --parent abc123 --title test"
run_case block "S4b: false || multica issue update --parent" "false || multica issue update 420c414c --parent abc123"

#####################################################################
# S5: BLOCK — single-line command (no separator, regression)
#####################################################################
separator "S5: BLOCK — single-line command (regression)"

run_case block "S5a: single-line create --parent" "multica issue create --parent abc123 --title test"
run_case block "S5b: single-line update --parent" "multica issue update 420c414c --parent abc123"
run_case block "S5c: single-line create --parent=value" "multica issue create --parent=abc123 --title test"

#####################################################################
# S6: ALLOW — no --parent (regression)
#####################################################################
separator "S6: ALLOW — no --parent (regression)"

run_case allow "S6a: create without --parent" "multica issue create --title normal"
run_case allow "S6b: create with multiple flags, no parent" "multica issue create --title test --priority high"
run_case allow "S6c: update without --parent" "multica issue update 420c414c --title new-title"
run_case allow "S6d: create --parent empty string" "multica issue create --parent \"\" --title test"

#####################################################################
# S7: BLOCK — heredoc nested (regression)
#####################################################################
separator "S7: BLOCK — heredoc nested (regression)"

run_case block "S7a: heredoc piped create with --parent" "$(printf 'cat <<DESCRIPTION | multica issue create --title test --description-stdin --parent abc123\nDESCRIPTION')"
run_case block "S7b: heredoc piped (single-quoted delimiter) with --parent" "$(printf "cat <<'EOF' | multica issue create --title test --description-stdin --parent 23bee88a\nEOF")"

#####################################################################
# S8: BLOCK — bash -c nested (regression)
#####################################################################
separator "S8: BLOCK — bash -c nested (regression)"

run_case block "S8a: bash -c nested create --parent" 'bash -c "multica issue create --parent abc123 --title test"'
run_case block "S8b: sh -c nested update --parent" 'sh -c "multica issue update id --parent abc123"'

#####################################################################
# S9: BLOCK — mixed composite + nested
#####################################################################
separator "S9: BLOCK — mixed composite + nested"

run_case block "S9a: && + bash -c nested --parent" 'echo hello && bash -c "multica issue create --parent abc123"'
run_case block "S9b: ; + bash -c nested --parent" 'cd /tmp; bash -c "multica issue update id --parent abc123"'

#####################################################################
# S10: quote-safe splitting
#####################################################################
separator "S10: quote-safe splitting"

run_case block "S10a: && inside double-quoted title IS a block (parent is real flag)" 'multica issue create --title "foo && bar" --parent abc123'
run_case block "S10b: ; inside double-quoted title IS a block (parent is real flag)" 'multica issue create --title "foo; bar" --parent abc123'
run_case allow "S10c: multica inside double quotes — not a real command" 'echo "multica issue create --parent abc123"'
run_case allow "S10d: git status — unrelated command" "git status"

#####################################################################
# S11: ALLOW — heredoc body with --parent text (regression)
#####################################################################
separator "S11: ALLOW — heredoc body false positive (regression)"

run_case allow "S11a: heredoc body contains --parent text" "$(printf 'cat <<EOF | multica issue create --title test --description-stdin\nThis doc explains --parent usage.\nEOF')"

#####################################################################
# S12: Edge cases
#####################################################################
separator "S12: Edge cases"

run_case block "S12a: mixed || and ; chain" "cd /tmp || echo fail; multica issue create --parent abc123"
run_case block "S12b: multiple newlines with empty lines" "$(printf '# header\n\nmultica issue create --parent abc123')"
run_case allow "S12c: composite without multica — ALLOWED" "echo hello && cd /tmp"

#####################################################################
# S13: BLOCK — backslash-escape bypass (SEE-818)
#####################################################################
separator "S13: BLOCK — backslash-escape bypass (SEE-818)"

run_case block 'S13a: echo \" && multica issue create --parent — escape bypass' 'echo \" && multica issue create --parent abc123 --title test'
run_case block 'S13b: echo \" && multica issue update --parent — escape bypass' 'echo \" && multica issue update 420c414c --parent abc123'
run_case block 'S13c: \\\\\" && create --parent — double-escape bypass' 'echo \\\\\" && multica issue create --parent abc123'
run_case allow 'S13d: backslash-escaped quotes inside double quotes — no split' 'echo "hello \"world\""'
run_case block 'S13e: echo \" ; multica issue create --parent — ; separator' 'echo \" ; multica issue create --parent abc123'

#####################################################################
# CLEANUP
#####################################################################
separator "Cleanup"
rm -rf "$FIX_PWD"
rm -f /tmp/see815-* /tmp/skill-check-see815-* 2>/dev/null
for _f in /tmp/.hook-fired-*; do [ -f "$_f" ] && rm -f "$_f"; done

#####################################################################
# SUMMARY
#####################################################################
separator "Summary"

echo ""
echo -e "${CYAN}Results:${NC}"
echo -e "  ${GREEN}Passed:${NC}    $PASS"
echo -e "  ${RED}Failed:${NC}    $FAIL"
echo ""
TOTAL=$((PASS + FAIL))
echo "  Total: $TOTAL tests"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}Overall: PASS${NC}"
    exit 0
else
    echo -e "${RED}Overall: FAIL ($FAIL failures)${NC}"
    echo ""
    echo "Failed tests:"
    for R in "${RESULTS[@]}"; do
        if [[ "$R" == FAIL* ]]; then
            echo -e "  ${RED}x${NC} ${R#FAIL|}"
        fi
    done
    exit 1
fi
