#!/bin/bash
# test_mention_check_regex_anchor_see756.sh
# QA Validation for SEE-756: mention-check.sh pipe-aware regex fix
# Verifies that the pipe-aware regex matches direct invocation and heredoc-pipe forms,
# while correctly excluding substrings inside echo/git-commit string literals.
#
# Related Issue: SEE-756, SEE-758
# Author: Bachi (Dev Agent)

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

PROJECT_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
REAL_HOOK="$PROJECT_ROOT/hooks/scripts/mention-check.sh"

# Extract the regex line from the hook script to confirm fix
FIXED_REGEX=$(grep -F '(?:^|\\|)' "$REAL_HOOK" | head -1)
OLD_REGEX=$(grep -F '/^multica' "$REAL_HOOK" | head -1)

echo "=== SEE-756 Hook Regex QA Validation ==="
echo ""
echo "Fix verification:"
if [ -n "$FIXED_REGEX" ]; then
    echo "  OK: Pipe-aware regex found in hook"
else
    echo "  FAIL: Pipe-aware regex not found in hook"
    exit 1
fi

if [ -z "$OLD_REGEX" ]; then
    echo "  OK: Old regex (with ^ anchor) removed"
else
    echo "  FAIL: Old regex still present in hook"
    exit 1
fi
echo ""

# Run regex validation via Node.js
echo "=== Regex Pattern Validation ==="

node -e "
const oldRe = /^multica\s+issue\s+comment\s+add/;
const newRe = /(?:^|\|)\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S+\s+)*multica\s+issue\s+comment\s+add/;

const cases = [
  {
    name: 'Direct command: multica issue comment add',
    cmd: 'multica issue comment add 59d0507b-8fa6-4fdd-bc3b-7ed6d15be5c1 --content \"hello\"',
    oldExpected: true,
    newExpected: true,
  },
  {
    name: 'Heredoc pipe (single quote): cat <<EOF | multica issue comment add',
    cmd: \"cat <<'COMMENT' | multica issue comment add 59d0507b-8fa6-4fdd-bc3b-7ed6d15be5c1 --parent a992d9c4-... --content-stdin\",
    oldExpected: false,
    newExpected: true,
  },
  {
    name: 'Heredoc pipe (no quote): cat <<EOF | multica issue comment add',
    cmd: 'cat <<EOF | multica issue comment add 59d0507b-8fa6-4fdd-bc3b-7ed6d15be5c1 --content-stdin',
    oldExpected: false,
    newExpected: true,
  },
  {
    name: 'Heredoc pipe with env prefix: MULTICA_AGENT_NAME=Revy cat <<EOF | multica issue comment add',
    cmd: 'cat <<EOF | MULTICA_AGENT_NAME=Revy multica issue comment add 59d0507b --content-stdin',
    oldExpected: false,
    newExpected: true,
  },
  {
    name: 'Non-matching: multica issue list',
    cmd: 'multica issue list --output json',
    oldExpected: false,
    newExpected: false,
  },
  {
    // Pipe-aware regex does NOT match substrings inside string literals (echo, git commit, etc.)
    name: 'Edge case: echo containing multica issue comment add (does NOT match new regex)',
    cmd: 'echo \"multica issue comment add\"',
    oldExpected: false,
    newExpected: false,
  },
  {
    name: 'Edge case: git commit message containing multica issue comment add (does NOT match new regex)',
    cmd: 'git commit -m \"multica issue comment add test\"',
    oldExpected: false,
    newExpected: false,
  },
  {
    name: 'Heredoc with content: cat <<REPORT_EOF | multica issue comment add',
    cmd: 'cat <<REPORT_EOF | multica issue comment add 59d0507b-8fa6-4fdd-bc3b-7ed6d15be5c1 --parent a992d9c4-600a-4d56-ab0d-f5d54a0d3570 --content-stdin',
    oldExpected: false,
    newExpected: true,
  },
  {
    name: 'Env var prefix without pipe: MULTICA_AGENT_NAME=Bachi multica issue comment add',
    cmd: 'MULTICA_AGENT_NAME=Bachi multica issue comment add 59d0507b --content \"hello\"',
    oldExpected: false,
    newExpected: true,
  },
];

let pass = 0;
let fail = 0;

for (const tc of cases) {
  const oldMatch = oldRe.test(tc.cmd);
  const newMatch = newRe.test(tc.cmd);
  const oldOk = oldMatch === tc.oldExpected;
  const newOk = newMatch === tc.newExpected;

  if (oldOk && newOk) {
    pass++;
    console.log('  PASS: ' + tc.name);
  } else {
    fail++;
    console.log('  FAIL: ' + tc.name);
    if (!oldOk) console.log('    Old regex: expected ' + tc.oldExpected + ', got ' + oldMatch);
    if (!newOk) console.log('    New regex: expected ' + tc.newExpected + ', got ' + newMatch);
  }
}

console.log('');
console.log('Results: ' + pass + ' passed, ' + fail + ' failed out of ' + cases.length);
process.exit(fail > 0 ? 1 : 0);
"

NODE_EXIT=$?
if [ $NODE_EXIT -ne 0 ]; then
    echo ""
    echo "Regex validation FAILED"
    exit 1
fi

echo ""
echo "=== Live Hook Validation ==="

# Run the actual hook against commands to confirm it now intercepts heredoc pipe forms.
# When the hook intercepts a comment-add without a mention, it outputs permissionDecision=deny (NO_MENTION).
# When it does NOT intercept, it passthroughs the original stdin.
TEST_BASE="/tmp/see756-qa-$(date +%s)-$$"
mkdir -p "$TEST_BASE"

run_hook() {
    local input_json="$1"
    local label="$2"
    local expect_block="$3"

    local stdout_f stderr_f
    stdout_f=$(mktemp /tmp/see756-stdout.XXXXXX)
    stderr_f=$(mktemp /tmp/see756-stderr.XXXXXX)

    (cd "$PROJECT_ROOT" && \
        env HOME="$HOME" \
            MULTICA_AGENT_NAME="Bachi" \
            MULTICA_TASK_ID="see756-task" \
            bash "$REAL_HOOK" \
            <<< "$input_json") \
        > "$stdout_f" 2> "$stderr_f"

    local stdout_str
    stdout_str=$(cat "$stdout_f")
    rm -f "$stdout_f" "$stderr_f"

    if [ "$expect_block" = "yes" ]; then
        if echo "$stdout_str" | grep -q '"permissionDecision"'; then
            pass "$label -- hook correctly intercepts and BLOCKS"
        else
            fail "$label -- hook did NOT intercept (expected BLOCK). stdout: $(echo "$stdout_str" | head -c 200)"
        fi
    else
        if echo "$stdout_str" | grep -q '"permissionDecision"'; then
            fail "$label -- hook BLOCKED unexpectedly (expected passthrough)"
        elif [ "$stdout_str" = "$input_json" ]; then
            pass "$label -- hook correctly passthroughs without processing"
        else
            fail "$label -- unexpected hook output: $(echo "$stdout_str" | head -c 200)"
        fi
    fi
}

# Test 1: Direct command without mention -> BLOCKED (NO_MENTION)
run_hook '{"tool_input":{"command":"multica issue comment add 59d0507b --content \"hello world\""}}' \
    "Direct command (no mention): hook intercepts and BLOCKS" \
    "yes"

# Test 2: Heredoc pipe without mention -> should NOW be intercepted -> BLOCKED (this was the bug)
run_hook '{"tool_input":{"command":"cat <<EOF | multica issue comment add 59d0507b --content-stdin"}}' \
    "Heredoc pipe (no mention): hook now intercepts and BLOCKS" \
    "yes"

# Test 3: Non-comment command should NOT be intercepted -> passthrough original stdin
run_hook '{"tool_input":{"command":"echo \"hello world\""}}' \
    "Non-comment: hook passthrough without processing" \
    "no"

# Test 4: Command with a direct mention call-out -> PASS (pure call-out bypasses Phase 2)
run_hook '{"tool_input":{"command":"multica issue comment add 59d0507b --content \"[@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c281f3ef5)\""}}' \
    "Direct command (pure mention call-out): hook intercepts and PASSES" \
    "no"

# Test 5: Heredoc pipe WITH mention in body -> PASS (heredoc extraction must find @mention, not NO_MENTION)
run_hook '{"tool_input":{"command":"cat <<COMMENT | multica issue comment add 59d0507b --parent a992d9c4-600a-4d56-ab0d-f5d54a0d3570 --content-stdin\n[@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c281f3ef5) 内容提取测试\nCOMMENT"}}' \
    "Heredoc pipe (with mention in body): hook extracts content and PASSES" \
    "no"

# Cleanup
rm -rf "$TEST_BASE"

echo ""
echo "================================================================"
echo " SEE-756 QA Validation Complete"
echo "================================================================"
echo "  Total: $((PASS + FAIL)) tests"
echo "  ${GREEN}Pass: $PASS${NC}"
echo "  ${RED}Fail: $FAIL${NC}"
echo "================================================================"

if [ $FAIL -gt 0 ]; then
    exit 1
fi
exit 0
