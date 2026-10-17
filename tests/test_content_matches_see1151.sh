#!/bin/bash
# test_content_matches_see1151.sh
# QA Tests for SEE-1151: skill-check `content_matches` operator + mention-confirm rule.
# Validates:
#   - content body sources: --content body, --content-file body, null fallback
#   - regex positive match → fire, no match → quiet, invalid regex → fail-open quiet
#   - composition with `not` / `or`
#   - mention-confirm rule: @mention → deny oneshot; no mention → pass; sentinel stops re-firing
#
# v2 redirect (SEE-1330): v1 `content_matches` → v2 `content` op。
# 两层 testee：
#   A) 词法/内容源层：node -e 'require("$PROJECT_ROOT/hooks/unified/when-ops.js")'
#      createEvaluator 的 content op（--content / --content-file / null 数据源）+ 正则。
#   B) 引擎层（oneshot/sentinel/agents/transcript 需完整协议）：unified-hook.sh +
#      UNIFIED_RULES_FILE fixture + multica PATH shim（per-task transcript 文件）+
#      HOOK_SCOPE_ID per-run uuid + CLAUDE_CODE_SESSION_ID="" 显式置空 +
#      hook_event_name:"PreToolUse"；deny reason 前缀 '[unified-hook] '。
# 期望逐字节等价于 v1 移植。
# DRIFT（一行）：v1 `used` op 对应 v2 used_skill op（T15），v1 `command_matches`
# 对应 v2 command/current op（T16），正则形态同源、结论不变。
#
# Related Issues: SEE-1151, SEE-1330

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

PROJECT_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WHEN_OPS_JS="$PROJECT_ROOT/hooks/unified/when-ops.js"
UNIFIED_HOOK="$PROJECT_ROOT/hooks/unified/unified-hook.sh"

for f in "$WHEN_OPS_JS" "$UNIFIED_HOOK"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Required file missing: $f"
        exit 1
    fi
done

TEST_BASE="/tmp/see1151-content-$(date +%s)-$$"
SHIM_BIN="$TEST_BASE/bin"
mkdir -p "$TEST_BASE" "$SHIM_BIN" "$TEST_BASE/transcripts"
cat > "$SHIM_BIN/multica" <<'SHIMEOF'
#!/bin/bash
if [ "$1" = "issue" ] && [ "$2" = "run-messages" ]; then
    if [ -n "$MESG_FILE" ] && [ -f "$MESG_FILE" ]; then
        cat "$MESG_FILE"
    else
        echo "[]"
    fi
    exit 0
fi
exit 0
SHIMEOF
chmod +x "$SHIM_BIN/multica"

HOOK_STDOUT=""
PAYLOAD=""

# ---------------- layer A: when-ops.js content-data-source checks ----------------

content_eval() { # $1=when_json $2=command ; prints FIRED|QUIET
    node - "$WHEN_OPS_JS" "$1" "$2" "$TEST_BASE/lex" <<'NODEEOF'
const [whenOpsPath, whenJson, cmd, cwd] = process.argv.slice(2);
const { createEvaluator } = require(whenOpsPath);
const payload = { hook_event_name: 'PreToolUse', tool_input: { command: cmd } };
const taskId = require('crypto').randomUUID();
const ev = createEvaluator(payload, { cwd, projectRoot: cwd, taskId });
console.log(ev.evaluate(JSON.parse(whenJson)) ? 'FIRED' : 'QUIET');
NODEEOF
}

lex_check() { # $1=expect(FIRED|QUIET) $2=label $3=when_json $4=command
    local expect="$1" label="$2"
    local out
    out=$(content_eval "$3" "$4")
    if [ "$out" = "$expect" ]; then
        pass "$label"
    else
        fail "$label — expected $expect; got $out"
    fi
}

# ---------------- layer B: unified engine e2e ----------------

new_rules_file() { # $1=outfile $2=name $3=when_json $4=msg $5=oneshot(on|off) $6=agents_json_or_none
    node -e '
const [out, name, whenJson, msg, oneshot, agentsJson] = process.argv.slice(1);
const rule = {
  name,
  on: { in: ["PreToolUse"] },
  enabled: true,
  when: JSON.parse(whenJson),
  action: [{ op: "deny", message: msg }],
};
if (oneshot === "on") rule.one_shot = { scope: "run" };
if (agentsJson === "none") rule.agents = undefined;
require("fs").writeFileSync(out, JSON.stringify({ rules: [rule] }));
' "$@"
}

HOOK_SCOPE_ID_OVERRIDE=""

run_engine() { # $1=rules_file $2=agent_name ; payload env already set
    local rules_file="$1" agent="${2:-TestAgent}"
    local task scope
    task=$(cat /proc/sys/kernel/random/uuid)
    if [ -n "$HOOK_SCOPE_ID_OVERRIDE" ]; then
        scope="$HOOK_SCOPE_ID_OVERRIDE"
    else
        scope=$(cat /proc/sys/kernel/random/uuid)
    fi
    HOOK_STDOUT=$(cd "$TEST_BASE" && \
        env PATH="$SHIM_BIN:$PATH" \
            TEST_BASE="$TEST_BASE" \
            MESG_FILE="${MESG_FILE:-}" \
            HOME="$TEST_BASE/home" \
            CLAUDE_CODE_SESSION_ID="" \
            MULTICA_AGENT_NAME="$agent" \
            MULTICA_TASK_ID="$task" \
            HOOK_SCOPE_ID="$scope" \
            PROJECT_ROOT="$TEST_BASE" \
            PWD="$TEST_BASE" \
            UNIFIED_RULES_FILE="$rules_file" \
            bash "$UNIFIED_HOOK" <<< "$PAYLOAD" 2>/dev/null)
}

assert_pass() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
        fail "$label — unexpectedly BLOCKED. stdout: $(echo "$HOOK_STDOUT" | head -c 300)"
    else
        pass "$label"
    fi
}

assert_blocked() {
    local label="$1"
    local expected_msg="${2:-}"
    if ! echo "$HOOK_STDOUT" | grep -q '"permissionDecision":"deny"'; then
        fail "$label — NOT blocked (expected BLOCK). stdout: $(echo "$HOOK_STDOUT" | head -c 300)"
    elif [ -n "$expected_msg" ] && ! echo "$HOOK_STDOUT" | grep -qF "$expected_msg"; then
        fail "$label — blocked but message missing '$expected_msg'. stdout: $(echo "$HOOK_STDOUT" | head -c 300)"
    elif ! echo "$HOOK_STDOUT" | grep -q 'unified-hook'; then
        fail "$label — deny reason missing '[unified-hook] ' prefix. stdout: $HOOK_STDOUT"
    else
        pass "$label"
    fi
}

comment_payload() { # $1 = content text
    node -e 'const c=process.argv[1]; console.log(JSON.stringify({hook_event_name:"PreToolUse", tool_input:{command:"multica issue comment add ISSUE_ID --content \"" + c + "\""}}));' "$1"
}

echo "================================================================"
echo " QA Test Suite: content op + mention-confirm (SEE-1151, v2 redirect)"
echo " Testees: when-ops.js (layer A) / unified-hook.sh (layer B)"
echo "================================================================"

# ----------------------------------------------------------------------------
# 1. content basics (layer A: body source resolution + regex)
# ----------------------------------------------------------------------------
separator "1. content op — Body Sources (when-ops.js)"

lex_check FIRED "T01: --content matches pattern → FIRE" \
    '{"op":"content","pattern":"hello"}' 'multica issue comment add ISSUE_ID --content "hello world"'
lex_check QUIET "T02: --content no match → QUIET" \
    '{"op":"content","pattern":"goodbye"}' 'multica issue comment add ISSUE_ID --content "hello world"'
lex_check QUIET "T05: no content flag → null → QUIET (cannot resolve)" \
    '{"op":"content","pattern":"hello"}' 'echo hello'
lex_check QUIET "T06: invalid regex → QUIET (fail-open, no crash)" \
    '{"op":"content","pattern":"[invalid("}' 'multica issue comment add ISSUE_ID --content "anything"'

mkdir -p "$TEST_BASE/lex"
echo "this body contains secret-token" > "$TEST_BASE/lex/body.txt"
lex_check FIRED "T03: --content-file body matches pattern → FIRE" \
    '{"op":"content","pattern":"secret-token"}' 'multica issue comment add ISSUE_ID --content-file body.txt'

echo "normal body text" > "$TEST_BASE/lex/body2.txt"
lex_check QUIET "T04: --content-file body no match → QUIET" \
    '{"op":"content","pattern":"zzz"}' 'multica issue comment add ISSUE_ID --content-file body2.txt'

# ----------------------------------------------------------------------------
# 2. composition with not / or (layer A)
# ----------------------------------------------------------------------------
separator "2. content — Composition with Boolean Ops"

lex_check QUIET "T07: not(content) where body matches → QUIET" \
    '{"op":"not","arg":{"op":"content","pattern":"banana"}}' 'multica issue comment add ISSUE_ID --content "banana here"'
lex_check FIRED "T08: not(content) where body lacks match → FIRE" \
    '{"op":"not","arg":{"op":"content","pattern":"banana"}}' 'multica issue comment add ISSUE_ID --content "apple here"'
lex_check FIRED "T09: or(content A, content B) — A matches → FIRE" \
    '{"op":"any","args":[{"op":"content","pattern":"alpha"},{"op":"content","pattern":"beta"}]}' \
    'multica issue comment add ISSUE_ID --content "alpha content"'
lex_check QUIET "T10: or(content A, content B) — neither matches → QUIET" \
    '{"op":"any","args":[{"op":"content","pattern":"alpha"},{"op":"content","pattern":"beta"}]}' \
    'multica issue comment add ISSUE_ID --content "gamma content"'

# ----------------------------------------------------------------------------
# 3. mention-confirm end-to-end (layer B, real regex from rules-v2 mention-confirm-check)
# ----------------------------------------------------------------------------
separator "3. mention-confirm rule (engine layer B, real regex from rules-v2.json)"

MENTION_PATTERN='\\[@[^\\]]+\\]\\(mention:\\/\\/(agent|member)\\/[^)]+\\)'
MENTION_WHEN="{\"op\":\"content\",\"pattern\":\"$MENTION_PATTERN\"}"

# T11: comment with @mention → BLOCK (oneshot deny, first hit)
RMF11="$TEST_BASE/rules-t11.json"
new_rules_file "$RMF11" "mention-confirm-check" "$MENTION_WHEN" "mention-confirm-block" on none
PAYLOAD=$(comment_payload 'hi [@Refacty](mention://agent/3c6b6d88-ce6c-4e02-a78e-24ee08e70c85) please fix')
run_engine "$RMF11" "AnyAgent"
assert_blocked "T11: comment with @mention → BLOCK (mention-confirm-check)" "mention-confirm-block"

# T12: comment without @mention → PASS
PAYLOAD=$(comment_payload 'no mention here at all')
run_engine "$RMF11" "AnyAgent"
assert_pass "T12: comment without @mention → PASS"

# T13: oneshot only fires once per HOOK_SCOPE_ID — second mention → PASS
RMF13="$TEST_BASE/rules-t13.json"
new_rules_file "$RMF13" "mention-confirm-check" "$MENTION_WHEN" "mention-confirm-block" on none
HOOK_SCOPE_ID_OVERRIDE=$(cat /proc/sys/kernel/random/uuid)
PAYLOAD=$(comment_payload 'first [@Atlas](mention://agent/abc) mention')
run_engine "$RMF13" "AnyAgent"
assert_blocked "T13a: first @mention → BLOCK"
PAYLOAD=$(comment_payload 'second [@Atlas](mention://agent/abc) mention')
run_engine "$RMF13" "AnyAgent"
assert_pass "T13b: second @mention → PASS (sentinel stops re-fire)"
HOOK_SCOPE_ID_OVERRIDE=""

# T14: rule without agents object → fires for any agent name
RMF14="$TEST_BASE/rules-t14.json"
new_rules_file "$RMF14" "mention-confirm-check" "$MENTION_WHEN" "mention-confirm-block" off none
PAYLOAD=$(comment_payload 'ping [@Owner](mention://member/xyz)')
run_engine "$RMF14" "RandomAgentName"
assert_blocked "T14: no agents object → fires for any agent" "mention-confirm-block"

# ----------------------------------------------------------------------------
# 4. regression: existing rules unaffected (engine layer, transcript shim)
# ----------------------------------------------------------------------------
separator "4. Regression: Existing Rules Unaffected (engine layer)"

# T15: existing used_skill-based rule still passes when transcript HAS the skill
RMF15="$TEST_BASE/rules-t15.json"
node -e '
require("fs").writeFileSync(process.argv[1], JSON.stringify({ rules: [{
  name: "atlas-workflow-skill-check",
  on: { in: ["PreToolUse"] },
  agents: { include: ["Atlas"] },
  enabled: true,
  one_shot: { scope: "run" },
  when: { op: "not", arg: { op: "used_skill", skill: "taskflow" } },
  action: [{ op: "deny", message: "must-use-taskflow" }],
}] }));
' "$RMF15"
MESG_FILE="$TEST_BASE/transcripts/taskflow.json"
printf '[{"type":"tool_use","tool":"Skill","input":{"skill":"taskflow"}}]' > "$MESG_FILE"
PAYLOAD='{"hook_event_name":"PreToolUse","tool_input":{"command":"multica issue comment add ISSUE_ID --content \"normal\""}}'
run_engine "$RMF15" "Atlas"
assert_pass "T15: existing used_skill(taskflow) rule still PASSes (transcript has skill)"
unset MESG_FILE

# T16: command guard (child-issue-guard shape) negative: no --parent → no output
RMF16="$TEST_BASE/rules-t16.json"
node -e '
require("fs").writeFileSync(process.argv[1], JSON.stringify({ rules: [{
  name: "child-issue-guard",
  on: { in: ["PreToolUse"] },
  enabled: true,
  when: { op: "command", scope: "current", pattern: "multica issue (create|update)", has_flag: "--parent", flag_has_value: true },
  action: [{ op: "deny", message: "child-block" }],
}] }));
' "$RMF16"
PAYLOAD='{"hook_event_name":"PreToolUse","tool_input":{"command":"multica issue update ABC --status done"}}'
run_engine "$RMF16" "TestAgent"
assert_pass "T16: existing command guard unaffected (no --parent)"

# ============================================================================
# CLEANUP
# ============================================================================
separator "Cleanup"
rm -rf "$TEST_BASE"
rm -f /tmp/skill-check-* 2>/dev/null
for _f in /tmp/.hook-fired-*; do [ -f "$_f" ] && rm -f "$_f"; done

# ============================================================================
# SUMMARY
# ============================================================================
separator "Results Summary"

TOTAL=$((PASS + FAIL))
echo ""
echo "Total: $TOTAL | PASS: $PASS | FAIL: $FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}Failed tests:${NC}"
    for r in "${RESULTS[@]}"; do
        if [[ "$r" == FAIL* ]]; then
            echo -e "  ${RED}$r${NC}"
        fi
    done
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
else
    echo -e "${RED}$FAIL TEST(S) FAILED${NC}"
fi

exit $FAIL
