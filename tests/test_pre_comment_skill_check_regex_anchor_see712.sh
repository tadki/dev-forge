#!/bin/bash
# test_pre_comment_skill_check_regex_anchor_see712.sh
# QA Validation for SEE-712: pre-comment-skill-check.sh pipe-aware regex fix
# Verifies that the pipe-aware regex matches direct invocation and heredoc-pipe forms,
# while correctly excluding substrings inside echo/git-commit string literals.
#
# Related Issue: SEE-712
# PR: https://github.com/tadki/KingOfLikes-Godot/pull/272
# Author: Revy (QA Agent)

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

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# S5 再定向说明 (SEE-1330 S5)：v1 时代本套件的源级断言检查 pre-comment-skill-check.sh 内的
# pipe-aware command_matches 正则；v2 统一引擎下源级等价物 = when-ops.js 的 extractCommands
# heredoc-pipe 提取（pipeRe）+ rules-v2.json 内 comment_add 类规则的 command pattern（base+sub
# 前缀锚定运行时等价，语义时钟对 v1 正则行为见下方 Node 纯正则校验段）。
REAL_HOOK="$PROJECT_ROOT/hooks/unified/unified-hook.sh"
WHEN_OPS="$PROJECT_ROOT/hooks/unified/when-ops.js"
RULES_V2="$PROJECT_ROOT/hooks/unified/rules-v2.json"

# Source-level fix verification: pipe-aware extraction + comment_add anchored pattern in v2
FIXED_REGEX=$(grep -F 'pipeRe' "$WHEN_OPS" | head -1)
COMMENT_ADD_PATTERN=$(grep -cF 'multica issue comment add' "$RULES_V2")
OLD_REGEX=$(grep -F '/^multica' "$WHEN_OPS" "$RULES_V2" 2>/dev/null | head -1)

echo "=== SEE-712 Hook Regex QA Validation ==="
echo ""
echo "Fix verification:"
if [ -n "$FIXED_REGEX" ]; then
    echo "  OK: Pipe-aware extraction found in when-ops.js"
else
    echo "  FAIL: Pipe-aware regex (pipeRe) not found in when-ops.js"
    exit 1
fi

if [ "$COMMENT_ADD_PATTERN" -gt 0 ]; then
    echo "  OK: comment_add anchored pattern present in rules-v2.json"
else
    echo "  FAIL: comment_add pattern missing in rules-v2.json"
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
    cmd: 'multica issue comment add 3690ca45-0874-4650-9081-e36faa2c6583 --content \"hello\"',
    oldExpected: true,
    newExpected: true,
  },
  {
    name: 'Heredoc pipe (single quote): cat <<EOF | multica issue comment add',
    cmd: \"cat <<'REPORT_EOF' | multica issue comment add 85315b73-597d-4053-a55d-eada635418bf --parent 43a65dbd-... --content-stdin\",
    oldExpected: false,
    newExpected: true,
  },
  {
    name: 'Heredoc pipe (no quote): cat <<EOF | multica issue comment add',
    cmd: 'cat <<EOF | multica issue comment add 3690ca45-0874-4650-9081-e36faa2c6583 --content-stdin',
    oldExpected: false,
    newExpected: true,
  },
  {
    name: 'Heredoc pipe with env prefix: MULTICA_AGENT_NAME=Revy cat <<EOF | multica issue comment add',
    cmd: 'cat <<EOF | MULTICA_AGENT_NAME=Revy multica issue comment add 3690ca45 --content-stdin',
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
    cmd: 'cat <<REPORT_EOF | multica issue comment add 85315b73-597d-4053-a55d-eada635418bf --parent 43a65dbd-4328-4d09-9286-183f6ae44077 --content-stdin',
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

# Run the actual hook against heredoc pipe commands to confirm it now enters skill-check logic.
# We use a BLOCKING rule (skill "explore" NOT used) so that when the hook intercepts,
# it will output a permissionDecision. When it does NOT intercept, it passthroughs the original stdin.
TEST_BASE="/tmp/see712-qa-$(date +%s)-$$"
mkdir -p "$TEST_BASE"

# Create a minimal fixture
FIX_PWD="$TEST_BASE/project"
mkdir -p "$FIX_PWD/.claude/hooks"

# v2 fixture rules: block Revy if /explore skill NOT used, anchored at comment_add pattern
# (v2 when op tree；in v2 explorer loader: 无 multica shim/非 UUID task id → used_skill=false → not(any) 命中 → BLOCK)
printf '{"rules":[{"name":"see712-live-test","on":{"in":["PreToolUse"]},"agents":{"include":["Revy"]},"enabled":true,"when":{"op":"all","args":[{"op":"command","scope":"current","pattern":"multica issue comment add(\\\\s|$)"},{"op":"not","arg":{"op":"used_skill","skill":"explore"}}]},"action":[{"op":"deny","message":"SEE-712 live test block"}]}]}' > "$FIX_PWD/.claude/hooks/rules-v2.json"

# v2 引擎需要 multica issue run-messages（仅 UUID task id 触达）——本套件不依赖 transcript：
# used_skill 数据源在无 transcript 时恒 false，not(used)=true 照旧命中，语义与 v1 一致。
SEE712_RUN_UUID=$(cat /proc/sys/kernel/random/uuid)

run_hook() {
    local input_json="$1"
    local label="$2"
    local expect_block="$3"

    local stdout_f stderr_f
    stdout_f=$(mktemp /tmp/see712-stdout.XXXXXX)
    stderr_f=$(mktemp /tmp/see712-stderr.XXXXXX)

    # S5 再定向：payload 注入 hook_event_name（无 tool_response → PreToolUse）；
    # testee 为 v2 unified-hook 入口（无命中 → 逐字节透传，exit 0）
    (cd "$FIX_PWD" && \
        env HOME="$HOME" \
            MULTICA_AGENT_NAME="Revy" \
            MULTICA_TASK_ID="$SEE712_RUN_UUID" \
            HOOK_SCOPE_ID="$SEE712_RUN_UUID" \
            CLAUDE_CODE_SESSION_ID="see712-session" \
            PWD="$FIX_PWD" \
            UNIFIED_RULES_FILE="$FIX_PWD/.claude/hooks/rules-v2.json" \
            PROJECT_ROOT="$PROJECT_ROOT" \
            bash "$REAL_HOOK" \
            <<< "$(printf '%s' "$input_json" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{const p=JSON.parse(d);p.hook_event_name="PreToolUse";process.stdout.write(JSON.stringify(p))})')") \
        > "$stdout_f" 2> "$stderr_f"

    local stdout_str expected_pass_payload
    stdout_str=$(cat "$stdout_f")
    rm -f "$stdout_f" "$stderr_f"
    expected_pass_payload=$(printf '%s' "$input_json" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{const p=JSON.parse(d);p.hook_event_name="PreToolUse";process.stdout.write(JSON.stringify(p))})')

    if [ "$expect_block" = "yes" ]; then
        if echo "$stdout_str" | grep -q '"permissionDecision"'; then
            pass "$label — hook correctly intercepts and BLOCKS"
        else
            fail "$label — hook did NOT intercept (expected BLOCK). stdout: $(echo "$stdout_str" | head -c 200)"
        fi
    else
        if echo "$stdout_str" | grep -q '"permissionDecision"'; then
            fail "$label — hook BLOCKED unexpectedly (expected passthrough)"
        elif [ "$stdout_str" = "$expected_pass_payload" ]; then
            pass "$label — hook correctly passthroughs without processing"
        else
            fail "$label — unexpected hook output: $(echo "$stdout_str" | head -c 200)"
        fi
    fi
}

# Test 1: Direct command should be intercepted -> BLOCKED
run_hook '{"tool_input":{"command":"multica issue comment add 3690ca45 --content \"hello\""},"transcript_path":"'$TEST_BASE/session.jsonl'"}' "Direct command: hook intercepts and BLOCKS" "yes"

# Test 2: Heredoc pipe should NOW be intercepted -> BLOCKED (this was the bug)
run_hook '{"tool_input":{"command":"cat <<EOF | multica issue comment add 3690ca45 --content-stdin"},"transcript_path":"'$TEST_BASE/session.jsonl'"}' "Heredoc pipe: hook now intercepts and BLOCKS" "yes"

# Test 3: Non-comment command should NOT be intercepted -> passthrough original stdin
run_hook '{"tool_input":{"command":"echo \"hello world\""},"transcript_path":"'$TEST_BASE/session.jsonl'"}' "Non-comment: hook passthrough without processing" "no"

# Cleanup
rm -rf "$TEST_BASE"

echo ""
echo "================================================================"
echo " SEE-712 QA Validation Complete"
echo "================================================================"
echo "  Total: $((PASS + FAIL)) tests"
echo "  ${GREEN}Pass: $PASS${NC}"
echo "  ${RED}Fail: $FAIL${NC}"
echo "================================================================"

if [ $FAIL -gt 0 ]; then
    exit 1
fi
exit 0
