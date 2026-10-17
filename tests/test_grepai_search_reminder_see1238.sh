#!/bin/bash
# test_grepai_search_reminder_see1238.sh
# QA Test Script for SEE-1238: grepai-search-reminder rule in skill-check-rules.json
# Validates: rule presence/shape, trigger on grep-family commands,
#            one-shot behavior, no-block (remind only, never deny),
#            all-agent scope, false-positive guards, regression safety.
#
# Related Issue: SEE-1238
# Migration: SEE-1330 — testee redirected to v2 unified engine (.claude/hooks/unified/unified-hook.sh)
#             with UNIFIED_RULES_FILE=rules-v2.json; remind → additionalContext raw message
#             (no prefix); hook_event_name injected at run_hook (has tool_response → PostToolUse
#             else PreToolUse); sentinel cleanup covers /tmp/.hook-fired-* + /tmp/skill-check-*.
# v1↔v2 note: v2 的 reminder 文案不含字面 'grepai_search'（改为 'grepai MCP 工具集'），
#             A2 等消息断言按 v2 文案等价重写；规则结构断言改为 v2 when-op 树形状。
# Test Type: Unit + Integration + Regression

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

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); RESULTS+=("PASS|$1"); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); RESULTS+=("FAIL|$1"); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; WARN=$((WARN + 1)); RESULTS+=("WARN|$1"); }

separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RULES="$PROJECT_ROOT/hooks/unified/rules-v2.json"
HOOK="$PROJECT_ROOT/hooks/unified/unified-hook.sh"
TMP_OUT=$(mktemp)
TMP_CFG=$(mktemp)
TMP_LOG=$(mktemp)
# Unique per-run task tag: one_shot sentinels live in /tmp keyed by scope id,
# so reusing fixed ids across runs would make the suite non-idempotent.
TASK_TAG="see1238v2-$$"

echo "============================================"
echo "  SEE-1238 grepai-search-reminder QA Suite (v2 engine)"
echo "  Date: $(date -Iseconds)"
echo "============================================"

cleanup() {
    rm -f "$TMP_OUT" "$TMP_CFG" "$TMP_LOG" /tmp/skill-check-* /tmp/.hook-fired-* 2>/dev/null
}
trap cleanup EXIT

# run_hook <task_id> <agent> <command_json_value> -> writes hook stdout to $TMP_OUT
# v2: hook_event_name 注入（D5 等价）+ HOOK_SCOPE_ID 每 run 唯一（per-run 显式，防宿主泄漏）
run_hook() {
    local task_id="$1" agent="$2" cmd="$3" ev="PostToolUse"
    local payload
    payload=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$cmd" \
        | python3 -c "
import json, sys
d = json.load(sys.stdin)
if not d.get('hook_event_name'):
    d['hook_event_name'] = 'PostToolUse' if 'tool_response' in d else '$ev'
print(json.dumps(d))")
    printf '%s' "$payload" \
        | MULTICA_AGENT_NAME="$agent" MULTICA_TASK_ID="$task_id" \
          PWD="$PROJECT_ROOT" PROJECT_ROOT="$PROJECT_ROOT" \
          HOOK_SCOPE_ID="$task_id" \
          UNIFIED_RULES_FILE="$RULES" HOOK_FIRE_LOG="$TMP_LOG" \
          bash "$HOOK" > "$TMP_OUT" 2>/dev/null
}

# has_grepai_remind -> 0 if remind present in output context
has_grepai_remind() {
    python3 -c "
import json
try:
    d = json.load(open('$TMP_OUT'))
    ctx = d.get('hookSpecificOutput', {}).get('additionalContext', '')
    print('YES' if 'grepai-search-reminder' in ctx else 'NO')
except Exception:
    print('PARSE_ERROR')
"
}

# is_denied -> YES if hook denied the tool call (blocking)
is_denied() {
    python3 -c "
import json
try:
    d = json.load(open('$TMP_OUT'))
    print('YES' if d.get('hookSpecificOutput', {}).get('permissionDecision') == 'deny' else 'NO')
except Exception:
    print('PARSE_ERROR')
"
}

assert_remind() {
    local label="$1" task_id="$2" agent="$3" cmd="$4"
    run_hook "$task_id" "$agent" "$cmd"
    if [ "$(has_grepai_remind)" = "YES" ]; then
        pass "$label"
    else
        fail "$label (no grepai-search-reminder in output)"
    fi
}

assert_no_remind() {
    local label="$1" task_id="$2" agent="$3" cmd="$4"
    run_hook "$task_id" "$agent" "$cmd"
    if [ "$(has_grepai_remind)" = "NO" ]; then
        pass "$label"
    else
        fail "$label (unexpected grepai-search-reminder in output)"
    fi
}

assert_never_denied() {
    local label="$1"
    if [ "$(is_denied)" = "NO" ]; then
        pass "$label"
    else
        fail "$label (hook denied — rule must be non-blocking)"
    fi
}

# ============================================================
separator "Suite A: Rule definition (config)"
# ============================================================

echo ""
echo "[A1] JSON file parses and rule exists with correct v2 shape"
python3 - "$RULES" > "$TMP_CFG" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
rules = [r for r in d.get('rules', []) if r.get('name') == 'grepai-search-reminder']
if len(rules) != 1:
    print("MISSING")
else:
    r = rules[0]
    when = r.get('when') or {}
    args = when.get('args') if isinstance(when, dict) else None
    wArgs = args if isinstance(args, list) else []
    cmd_ops = [a for a in wArgs if isinstance(a, dict) and a.get('op') == 'command']
    tool_ops = [a for a in wArgs if isinstance(a, dict) and a.get('op') == 'tool']
    action = r.get('action') or []
    checks = {
        'when_any': when.get('op') == 'any',
        'cmd_pattern_grep': any(a.get('pattern') == r'grep(\s|$)' for a in cmd_ops),
        'cmd_pattern_rg': any(a.get('pattern') == r'rg(\s|$)' for a in cmd_ops),
        'cmd_pattern_ag': any(a.get('pattern') == r'ag(\s|$)' for a in cmd_ops),
        'cmd_pattern_ack': any(a.get('pattern') == r'ack(\s|$)' for a in cmd_ops),
        'cmd_scope_current': all(a.get('scope') == 'current' for a in cmd_ops),
        'tool_grep_dim': any(a.get('in') == ['Grep'] for a in tool_ops),
        'no_one_shot': 'one_shot' not in r,
        'on_posttooluse': (r.get('on') or {}).get('in') == ['PostToolUse']
                        if isinstance(r.get('on'), dict) else False,
        'enabled': r.get('enabled') is True,
        'all_agent_scope': 'agents' not in r,
        'action_context': len(action) >= 1 and action[0].get('op') == 'context',
        'has_message': action and bool(action[0].get('message')),
    }
    print("OK" if all(checks.values()) else "BAD:" + ",".join(k for k, v in checks.items() if not v))
PYEOF
A1_RESULT=$(cat "$TMP_CFG")
if [ "$A1_RESULT" = "OK" ]; then
    pass "A1.1 grepai-search-reminder v2 rule exists (context/PostToolUse/when-any 4 command + tool Grep/no one_shot/all-agent)"
else
    fail "A1.1 v2 rule shape invalid: $A1_RESULT"
fi

echo ""
echo "[A2] Message content quality"
run_hook "${TASK_TAG}-a2" "Bachi" '"grep -rn foo ."'
python3 - "$TMP_OUT" > "$TMP_CFG" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
ctx = d.get('hookSpecificOutput', {}).get('additionalContext', '')
# v2 文案等价断言：规则名 + 建议 grepai 工具集 + 语义搜索（原 v1 断言字面 'grepai_search' 不再出现在文案中）
ok = all(s in ctx for s in ['grepai-search-reminder', 'grepai', '语义搜索'])
print('OK' if ok else 'MISSING:' + str([s for s in ['grepai-search-reminder', 'grepai', '语义搜索'] if s not in ctx]))
PYEOF
A2_RESULT=$(cat "$TMP_CFG")
if [ "$A2_RESULT" = "OK" ]; then
    pass "A2.1 Message references grepai tooling and states semantic-search intent"
else
    fail "A2.1 Message content check: $A2_RESULT"
fi

# ============================================================
separator "Suite B: Trigger on grep-family commands (Unit)"
# ============================================================

echo ""
echo "[B1] Positive triggers"
assert_remind "B1.1 plain grep triggers"          "${TASK_TAG}-b1a" "Bachi"  '"grep -rn foo ."'
assert_remind "B1.2 bare grep triggers"           "${TASK_TAG}-b1b" "Bachi"  '"grep"'
assert_remind "B1.3 rg triggers"                  "${TASK_TAG}-b1c" "Revy"   '"rg pattern src/"'
assert_remind "B1.4 ag triggers"                  "${TASK_TAG}-b1d" "Atlas"  '"ag func ."'
assert_remind "B1.5 ack triggers"                 "${TASK_TAG}-b1e" "Fronti" '"ack --type gd hp_bar"'
assert_never_denied "B1.6 triggers never deny (non-blocking)"

echo ""
echo "[B2] Negative cases (no false positives)"
assert_no_remind "B2.1 ls does not trigger"       "${TASK_TAG}-b2a" "Bachi"  '"ls -la"'
assert_no_remind "B2.2 cat does not trigger"      "${TASK_TAG}-b2b" "Bachi"  '"cat file.txt"'
assert_no_remind "B2.3 echo with grep literal does not trigger" "${TASK_TAG}-b2c" "Atlas" '"echo grep foo"'
assert_no_remind "B2.4 cat of grep.txt does not trigger" "${TASK_TAG}-b2d" "Bachi" '"cat grep.txt"'
assert_no_remind "B2.5 egrep does not trigger"    "${TASK_TAG}-b2e" "Bachi"  '"egrep foo"'
assert_no_remind "B2.6 git grep does not trigger (base=git)" "${TASK_TAG}-b2f" "Archi" '"git grep TODO"'
assert_no_remind "B2.7 find does not trigger"     "${TASK_TAG}-b2g" "Bachi"  '"find . -name *.gd"'
assert_no_remind "B2.8 echo with quoted grep literal (JSON-escaped) does not trigger" "${TASK_TAG}-b2h" "Atlas" '"echo \"grep foo\""'

# ============================================================
separator "Suite C: Repeat-fire (no one_shot, Owner 2026-09-21) & all-agent scope (Unit)"
# ============================================================

echo ""
echo "[C1] Repeat-fire: every grep call reminds (no one_shot)"
assert_remind "C1.1 first invocation reminds"     "${TASK_TAG}-c1" "Bachi" '"grep -rn foo ."'
assert_remind "C1.2 second invocation reminds again"  "${TASK_TAG}-c1" "Bachi" '"grep -rn foo ."'

echo ""
echo "[C2] All agents covered (no agents field)"
assert_remind "C2.1 Bachi covered"                "${TASK_TAG}-c2a" "Bachi"  '"grep foo"'
assert_remind "C2.2 Atlas covered"                "${TASK_TAG}-c2b" "Atlas"  '"grep foo"'
assert_remind "C2.3 Revy covered"                 "${TASK_TAG}-c2c" "Revy"   '"grep foo"'
assert_remind "C2.4 Archi covered"                "${TASK_TAG}-c2d" "Archi"  '"grep foo"'
assert_remind "C2.5 Fronti covered"               "${TASK_TAG}-c2e" "Fronti" '"grep foo"'

# ============================================================
separator "Suite D: Regression safety (existing rules)"
# ============================================================

echo ""
echo "[D1] Non-grep tool calls on clean task still remind existing rules only"
#!/bin/bash
# test_grepai_search_reminder_see1238.sh
# QA Test Script for SEE-1238: grepai-search-reminder rule in skill-check-rules.json
# Validates: rule presence/shape, trigger on grep-family commands,
#            one-shot behavior, no-block (remind only, never deny),
#            all-agent scope, false-positive guards, regression safety.
#
# Related Issue: SEE-1238
# Migration: SEE-1330 — testee redirected to v2 unified engine (.claude/hooks/unified/unified-hook.sh)
#             with UNIFIED_RULES_FILE=rules-v2.json; remind → additionalContext raw message
#             (no prefix); hook_event_name injected at run_hook (has tool_response → PostToolUse
#             else PreToolUse); sentinel cleanup covers /tmp/.hook-fired-* + /tmp/skill-check-*.
# v1↔v2 note: v2 的 reminder 文案不含字面 'grepai_search'（改为 'grepai MCP 工具集'），
#             A2 等消息断言按 v2 文案等价重写；规则结构断言改为 v2 when-op 树形状。
# Test Type: Unit + Integration + Regression

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

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); RESULTS+=("PASS|$1"); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); RESULTS+=("FAIL|$1"); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; WARN=$((WARN + 1)); RESULTS+=("WARN|$1"); }

separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RULES="$PROJECT_ROOT/hooks/unified/rules-v2.json"
HOOK="$PROJECT_ROOT/hooks/unified/unified-hook.sh"
TMP_OUT=$(mktemp)
TMP_CFG=$(mktemp)
TMP_LOG=$(mktemp)
# Unique per-run task tag: one_shot sentinels live in /tmp keyed by scope id,
# so reusing fixed ids across runs would make the suite non-idempotent.
TASK_TAG="see1238v2-$$"

echo "============================================"
echo "  SEE-1238 grepai-search-reminder QA Suite (v2 engine)"
echo "  Date: $(date -Iseconds)"
echo "============================================"

cleanup() {
    rm -f "$TMP_OUT" "$TMP_CFG" "$TMP_LOG" /tmp/skill-check-* /tmp/.hook-fired-* 2>/dev/null
}
trap cleanup EXIT

# run_hook <task_id> <agent> <command_json_value> -> writes hook stdout to $TMP_OUT
# v2: hook_event_name 注入（D5 等价）+ HOOK_SCOPE_ID 每 run 唯一（per-run 显式，防宿主泄漏）
run_hook() {
    local task_id="$1" agent="$2" cmd="$3" ev="PostToolUse"
    local payload
    payload=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$cmd" \
        | python3 -c "
import json, sys
d = json.load(sys.stdin)
if not d.get('hook_event_name'):
    d['hook_event_name'] = 'PostToolUse' if 'tool_response' in d else '$ev'
print(json.dumps(d))")
    printf '%s' "$payload" \
        | MULTICA_AGENT_NAME="$agent" MULTICA_TASK_ID="$task_id" \
          PWD="$PROJECT_ROOT" PROJECT_ROOT="$PROJECT_ROOT" \
          HOOK_SCOPE_ID="$task_id" \
          UNIFIED_RULES_FILE="$RULES" HOOK_FIRE_LOG="$TMP_LOG" \
          bash "$HOOK" > "$TMP_OUT" 2>/dev/null
}

# has_grepai_remind -> 0 if remind present in output context
has_grepai_remind() {
    python3 -c "
import json
try:
    d = json.load(open('$TMP_OUT'))
    ctx = d.get('hookSpecificOutput', {}).get('additionalContext', '')
    print('YES' if 'grepai-search-reminder' in ctx else 'NO')
except Exception:
    print('PARSE_ERROR')
"
}

# is_denied -> YES if hook denied the tool call (blocking)
is_denied() {
    python3 -c "
import json
try:
    d = json.load(open('$TMP_OUT'))
    print('YES' if d.get('hookSpecificOutput', {}).get('permissionDecision') == 'deny' else 'NO')
except Exception:
    print('PARSE_ERROR')
"
}

assert_remind() {
    local label="$1" task_id="$2" agent="$3" cmd="$4"
    run_hook "$task_id" "$agent" "$cmd"
    if [ "$(has_grepai_remind)" = "YES" ]; then
        pass "$label"
    else
        fail "$label (no grepai-search-reminder in output)"
    fi
}

assert_no_remind() {
    local label="$1" task_id="$2" agent="$3" cmd="$4"
    run_hook "$task_id" "$agent" "$cmd"
    if [ "$(has_grepai_remind)" = "NO" ]; then
        pass "$label"
    else
        fail "$label (unexpected grepai-search-reminder in output)"
    fi
}

assert_never_denied() {
    local label="$1"
    if [ "$(is_denied)" = "NO" ]; then
        pass "$label"
    else
        fail "$label (hook denied — rule must be non-blocking)"
    fi
}

# ============================================================
separator "Suite A: Rule definition (config)"
# ============================================================

echo ""
echo "[A1] JSON file parses and rule exists with correct v2 shape"
python3 - "$RULES" > "$TMP_CFG" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
rules = [r for r in d.get('rules', []) if r.get('name') == 'grepai-search-reminder']
if len(rules) != 1:
    print("MISSING")
else:
    r = rules[0]
    when = r.get('when') or {}
    args = when.get('args') if isinstance(when, dict) else None
    wArgs = args if isinstance(args, list) else []
    cmd_ops = [a for a in wArgs if isinstance(a, dict) and a.get('op') == 'command']
    tool_ops = [a for a in wArgs if isinstance(a, dict) and a.get('op') == 'tool']
    action = r.get('action') or []
    checks = {
        'when_any': when.get('op') == 'any',
        'cmd_pattern_grep': any(a.get('pattern') == r'grep(\s|$)' for a in cmd_ops),
        'cmd_pattern_rg': any(a.get('pattern') == r'rg(\s|$)' for a in cmd_ops),
        'cmd_pattern_ag': any(a.get('pattern') == r'ag(\s|$)' for a in cmd_ops),
        'cmd_pattern_ack': any(a.get('pattern') == r'ack(\s|$)' for a in cmd_ops),
        'cmd_scope_current': all(a.get('scope') == 'current' for a in cmd_ops),
        'tool_grep_dim': any(a.get('in') == ['Grep'] for a in tool_ops),
        'no_one_shot': 'one_shot' not in r,
        'on_posttooluse': (r.get('on') or {}).get('in') == ['PostToolUse']
                        if isinstance(r.get('on'), dict) else False,
        'enabled': r.get('enabled') is True,
        'all_agent_scope': 'agents' not in r,
        'action_context': len(action) >= 1 and action[0].get('op') == 'context',
        'has_message': action and bool(action[0].get('message')),
    }
    print("OK" if all(checks.values()) else "BAD:" + ",".join(k for k, v in checks.items() if not v))
PYEOF
A1_RESULT=$(cat "$TMP_CFG")
if [ "$A1_RESULT" = "OK" ]; then
    pass "A1.1 grepai-search-reminder v2 rule exists (context/PostToolUse/when-any 4 command + tool Grep/no one_shot/all-agent)"
else
    fail "A1.1 v2 rule shape invalid: $A1_RESULT"
fi

echo ""
echo "[A2] Message content quality"
run_hook "${TASK_TAG}-a2" "Bachi" '"grep -rn foo ."'
python3 - "$TMP_OUT" > "$TMP_CFG" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
ctx = d.get('hookSpecificOutput', {}).get('additionalContext', '')
# v2 文案等价断言：规则名 + 建议 grepai 工具集 + 语义搜索（原 v1 断言字面 'grepai_search' 不再出现在文案中）
ok = all(s in ctx for s in ['grepai-search-reminder', 'grepai', '语义搜索'])
print('OK' if ok else 'MISSING:' + str([s for s in ['grepai-search-reminder', 'grepai', '语义搜索'] if s not in ctx]))
PYEOF
A2_RESULT=$(cat "$TMP_CFG")
if [ "$A2_RESULT" = "OK" ]; then
    pass "A2.1 Message references grepai tooling and states semantic-search intent"
else
    fail "A2.1 Message content check: $A2_RESULT"
fi

# ============================================================
separator "Suite B: Trigger on grep-family commands (Unit)"
# ============================================================

echo ""
echo "[B1] Positive triggers"
assert_remind "B1.1 plain grep triggers"          "${TASK_TAG}-b1a" "Bachi"  '"grep -rn foo ."'
assert_remind "B1.2 bare grep triggers"           "${TASK_TAG}-b1b" "Bachi"  '"grep"'
assert_remind "B1.3 rg triggers"                  "${TASK_TAG}-b1c" "Revy"   '"rg pattern src/"'
assert_remind "B1.4 ag triggers"                  "${TASK_TAG}-b1d" "Atlas"  '"ag func ."'
assert_remind "B1.5 ack triggers"                 "${TASK_TAG}-b1e" "Fronti" '"ack --type gd hp_bar"'
assert_never_denied "B1.6 triggers never deny (non-blocking)"

echo ""
echo "[B2] Negative cases (no false positives)"
assert_no_remind "B2.1 ls does not trigger"       "${TASK_TAG}-b2a" "Bachi"  '"ls -la"'
assert_no_remind "B2.2 cat does not trigger"      "${TASK_TAG}-b2b" "Bachi"  '"cat file.txt"'
assert_no_remind "B2.3 echo with grep literal does not trigger" "${TASK_TAG}-b2c" "Atlas" '"echo grep foo"'
assert_no_remind "B2.4 cat of grep.txt does not trigger" "${TASK_TAG}-b2d" "Bachi" '"cat grep.txt"'
assert_no_remind "B2.5 egrep does not trigger"    "${TASK_TAG}-b2e" "Bachi"  '"egrep foo"'
assert_no_remind "B2.6 git grep does not trigger (base=git)" "${TASK_TAG}-b2f" "Archi" '"git grep TODO"'
assert_no_remind "B2.7 find does not trigger"     "${TASK_TAG}-b2g" "Bachi"  '"find . -name *.gd"'
assert_no_remind "B2.8 echo with quoted grep literal (JSON-escaped) does not trigger" "${TASK_TAG}-b2h" "Atlas" '"echo \"grep foo\""'

# ============================================================
separator "Suite C: Repeat-fire (no one_shot, Owner 2026-09-21) & all-agent scope (Unit)"
# ============================================================

echo ""
echo "[C1] Repeat-fire: every grep call reminds (no one_shot)"
assert_remind "C1.1 first invocation reminds"     "${TASK_TAG}-c1" "Bachi" '"grep -rn foo ."'
assert_remind "C1.2 second invocation reminds again"  "${TASK_TAG}-c1" "Bachi" '"grep -rn foo ."'

echo ""
echo "[C2] All agents covered (no agents field)"
assert_remind "C2.1 Bachi covered"                "${TASK_TAG}-c2a" "Bachi"  '"grep foo"'
assert_remind "C2.2 Atlas covered"                "${TASK_TAG}-c2b" "Atlas"  '"grep foo"'
assert_remind "C2.3 Revy covered"                 "${TASK_TAG}-c2c" "Revy"   '"grep foo"'
assert_remind "C2.4 Archi covered"                "${TASK_TAG}-c2d" "Archi"  '"grep foo"'
assert_remind "C2.5 Fronti covered"               "${TASK_TAG}-c2e" "Fronti" '"grep foo"'

# ============================================================
separator "Suite D: Regression safety (existing rules)"
# ============================================================

echo ""
echo "[D1] Non-grep tool calls on clean task still remind existing rules only"
# D1 显式 PreToolUse 直调（remind-5 回 v1 时点；run_tool 缺省 PostToolUse 不适用于本用例）
printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls -la"}}' \
  | MULTICA_AGENT_NAME=Bachi MULTICA_TASK_ID="${TASK_TAG}-d1" \
    PWD="$PROJECT_ROOT" PROJECT_ROOT="$PROJECT_ROOT" HOOK_SCOPE_ID="${TASK_TAG}-d1" \
    UNIFIED_RULES_FILE="$RULES" HOOK_FIRE_LOG="$TMP_LOG" \
    bash "$HOOK" > "$TMP_OUT" 2>/dev/null
python3 - "$TMP_OUT" > "$TMP_CFG" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
ctx = d.get('hookSpecificOutput', {}).get('additionalContext', '')
print('OK' if ('bachi-coding-reminder' in ctx and 'recall-reminder' in ctx) else 'MISSING_EXISTING')
PYEOF
D1_RESULT=$(cat "$TMP_CFG")
if [ "$D1_RESULT" = "OK" ]; then
    pass "D1.1 Existing any_tool reminders (bachi/recall) still fire"
else
    fail "D1.1 Existing reminders regression: $D1_RESULT"
fi

echo ""
echo "[D2] v2 config validity + rule count sanity (v2 config holds 14 rules incl. grepai rule)"
python3 - "$RULES" > "$TMP_CFG" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
names = [r.get('name') for r in d.get('rules', [])]
print(str(len(names)) + '|' + ('OK' if len(names) == len(set(names)) else 'DUPES'))
PYEOF
D2_COUNT=$(cut -d'|' -f1 "$TMP_CFG")
D2_DUPES=$(cut -d'|' -f2 "$TMP_CFG")
if [ "$D2_DUPES" = "OK" ] && [ "$D2_COUNT" -ge 13 ]; then
    pass "D2.1 Config valid, $D2_COUNT rules, no duplicate names (incl. new rule)"
else
    fail "D2.1 Config check: count=$D2_COUNT dupes=$D2_DUPES"
fi

# ============================================================
separator "Suite E: Native Grep tool via tool_name dimension (SEE-1238 fix)"
# ============================================================

# run_tool <task_id> <agent> <payload> — full-payload variant of run_hook
run_tool() {
    local task_id="$1" agent="$2" payload="$3"
    printf '%s' "$payload" \
        | python3 -c "
import json, sys
d = json.load(sys.stdin)
if not d.get('hook_event_name'):
    if not d.get('hook_event_name'):
        d['hook_event_name'] = 'PostToolUse'
print(json.dumps(d))" 2>/tmp/dbg-py.err \
        | tee /tmp/dbg-payload.txt \
        | MULTICA_AGENT_NAME="$agent" MULTICA_TASK_ID="$task_id" \
          PWD="$PROJECT_ROOT" PROJECT_ROOT="$PROJECT_ROOT" \
          HOOK_SCOPE_ID="$task_id" \
          UNIFIED_RULES_FILE="$RULES" HOOK_FIRE_LOG="$TMP_LOG" \
          bash "$HOOK" > "$TMP_OUT" 2>/dev/null
}

echo ""
echo "[E1] Native Grep payload (tool_input.pattern, no command) triggers"
run_tool "${TASK_TAG}-e1" "Revy" '{"tool_name":"Grep","tool_input":{"pattern":"foo","path":"src"}}'
if [ "$(has_grepai_remind)" = "YES" ]; then
    pass "E1.1 native Grep payload triggers grepai-search-reminder"
else
    fail "E1.1 native Grep payload did not trigger (tool_name dimension missing?)"
fi
assert_never_denied "E1.2 native Grep trigger never denies (non-blocking)"

echo ""
echo "[E2] Native Grep repeat-fire: second call reminds again (no one_shot)"
run_tool "${TASK_TAG}-e2" "Bachi" '{"tool_name":"Grep","tool_input":{"pattern":"q1","path":"src"}}'
if [ "$(has_grepai_remind)" = "YES" ]; then
    pass "E2.1 first native Grep call reminds"
else
    fail "E2.1 first native Grep call did not remind"
fi
run_tool "${TASK_TAG}-e2" "Bachi" '{"tool_name":"Grep","tool_input":{"pattern":"q2","path":"src"}}'
if [ "$(has_grepai_remind)" = "YES" ]; then
    pass "E2.2 second native Grep call reminds again (no one_shot)"
else
    fail "E2.2 second native Grep call silent (repeat-fire broken)"
fi

echo ""
echo "[E3] Native Grep covered for all agents"
for a in Atlas Bachi Fronti Revy Archi Refacty Chekky; do
    run_tool "${TASK_TAG}-e3-$a" "$a" '{"tool_name":"Grep","tool_input":{"pattern":"x","path":"."}}'
    if [ "$(has_grepai_remind)" = "YES" ]; then
        pass "E3 native Grep covered: $a"
    else
        fail "E3 native Grep NOT covered: $a"
    fi
done

# ============================================================
separator "Suite F: tool_name false-positive matrix (non-search tools)"
# ============================================================

assert_tool_no_remind() {
    local label="$1" task_id="$2" agent="$3" payload="$4"
    run_tool "$task_id" "$agent" "$payload"
    if [ "$(has_grepai_remind)" = "NO" ]; then
        pass "$label"
    else
        fail "$label (unexpected grepai-search-reminder for non-search tool)"
    fi
}

assert_tool_no_remind "F1 Read tool does not trigger"          "${TASK_TAG}-f1" "Bachi" '{"tool_name":"Read","tool_input":{"file_path":"src/a.gd"}}'
assert_tool_no_remind "F2 Write tool (content has grep literal) does not trigger" "${TASK_TAG}-f2" "Bachi" '{"tool_name":"Write","tool_input":{"file_path":"a.txt","content":"grep foo"}}'
assert_tool_no_remind "F3 Glob tool does not trigger"          "${TASK_TAG}-f3" "Revy"  '{"tool_name":"Glob","tool_input":{"pattern":"**/*.gd"}}'
assert_tool_no_remind "F4 Edit tool (old_string has grep) does not trigger" "${TASK_TAG}-f4" "Atlas" '{"tool_name":"Edit","tool_input":{"file_path":"a.gd","old_string":"grep","new_string":"x"}}'
assert_tool_no_remind "F5 Task tool (prompt has grep) does not trigger" "${TASK_TAG}-f5" "Fronti" '{"tool_name":"Task","tool_input":{"prompt":"run grep over src"}}'
assert_tool_no_remind "F6 grepai_search MCP tool does not trigger (tool_name gate)" "${TASK_TAG}-f6" "Revy" '{"tool_name":"mcp__grepai__grepai_search","tool_input":{"query":"auth flow"}}'

# ============================================================
separator "Suite G: tool_name + command_pattern combination semantics"
# ============================================================

GDIR="/tmp/see1238-gdir-$$"
rm -rf "$GDIR"; mkdir -p "$GDIR/.claude/hooks/unified"
cat > "$GDIR/.claude/hooks/unified/rules-v2.json" <<'GEOF'
{"version":2,"v1_compat":false,"rules":[{"name":"combo-rule","on":{"in":["PreToolUse"]},"one_shot":{"scope":"run"},"enabled":true,"when":{"op":"all","args":[{"op":"tool","in":["Bash"]},{"op":"command","scope":"current","pattern":"grep(\\s|$)"}]},"action":[{"op":"context","message":"[combo-rule] hit"}]}]}
GEOF

run_g() {
    local payload="$1" out="$2"
    ( cd "$GDIR" && printf '%s' "$payload" \
        | python3 -c "
import json, sys
d = json.load(sys.stdin)
if not d.get('hook_event_name'):
    d['hook_event_name'] = 'PostToolUse' if 'tool_response' in d else 'PreToolUse'
print(json.dumps(d))" \
        | MULTICA_AGENT_NAME="Bachi" MULTICA_TASK_ID="see1238v2-g-$$" \
          PWD="$GDIR" PROJECT_ROOT="$GDIR" \
          HOOK_SCOPE_ID="see1238v2-g-$$" \
          UNIFIED_RULES_FILE="$GDIR/.claude/hooks/unified/rules-v2.json" \
          HOOK_FIRE_LOG="/tmp/see1238v2-glog-$$" \
          bash "$HOOK" > "$out" 2>/dev/null )
}

run_g '{"tool_name":"Bash","tool_input":{"command":"grep foo"}}' "$TMP_CFG"
if grep -q "combo-rule" "$TMP_CFG" 2>/dev/null; then
    pass "G1 tool_name+command_pattern combo fires on matching tool and command"
else
    fail "G1 combo rule did not fire for Bash grep"
fi
run_g '{"tool_name":"Grep","tool_input":{"pattern":"grep foo"}}' "$TMP_CFG"
if grep -q "combo-rule" "$TMP_CFG" 2>/dev/null; then
    fail "G2 combo rule fired despite tool_name mismatch (Grep tool)"
else
    pass "G2 combo rule silent on tool_name mismatch (command_pattern not evaluated)"
fi
run_g '{"tool_name":"OtherTool","tool_input":{"command":"grep foo"}}' "$TMP_CFG"
if grep -q "combo-rule" "$TMP_CFG" 2>/dev/null; then
    fail "G3 combo rule fired for non-Bash tool carrying command field"
else
    pass "G3 combo rule silent for non-Bash tool with command field"
fi
rm -rf "$GDIR"; rm -f /tmp/.hook-fired-combo-* "/tmp/see1238v2-glog-$$" 2>/dev/null

# ============================================================
separator "Summary"
# ============================================================

echo ""
echo -e "${CYAN}Results:${NC}"
echo -e "  ${GREEN}Passed:${NC}  $PASS"
echo -e "  ${RED}Failed:${NC}  $FAIL"
echo -e "  ${YELLOW}Warnings:${NC} $WARN"
echo ""
TOTAL=$((PASS + FAIL + WARN))
echo -e "  Total:   $TOTAL"

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}OVERALL: PASS${NC}"
    exit 0
else
    echo -e "${RED}OVERALL: FAIL${NC}"
    exit 1
fi

python3 - "$TMP_OUT" > "$TMP_CFG" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
ctx = d.get('hookSpecificOutput', {}).get('additionalContext', '')
print('OK' if ('bachi-coding-reminder' in ctx and 'recall-reminder' in ctx) else 'MISSING_EXISTING')
PYEOF
D1_RESULT=$(cat "$TMP_CFG")
if [ "$D1_RESULT" = "OK" ]; then
    pass "D1.1 Existing any_tool reminders (bachi/recall) still fire"
else
    fail "D1.1 Existing reminders regression: $D1_RESULT"
fi

echo ""
echo "[D2] v2 config validity + rule count sanity (v2 config holds 14 rules incl. grepai rule)"
python3 - "$RULES" > "$TMP_CFG" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
names = [r.get('name') for r in d.get('rules', [])]
print(str(len(names)) + '|' + ('OK' if len(names) == len(set(names)) else 'DUPES'))
PYEOF
D2_COUNT=$(cut -d'|' -f1 "$TMP_CFG")
D2_DUPES=$(cut -d'|' -f2 "$TMP_CFG")
if [ "$D2_DUPES" = "OK" ] && [ "$D2_COUNT" -ge 13 ]; then
    pass "D2.1 Config valid, $D2_COUNT rules, no duplicate names (incl. new rule)"
else
    fail "D2.1 Config check: count=$D2_COUNT dupes=$D2_DUPES"
fi

# ============================================================
separator "Suite E: Native Grep tool via tool_name dimension (SEE-1238 fix)"
# ============================================================

# run_tool <task_id> <agent> <payload> — full-payload variant of run_hook
run_tool() {
    local task_id="$1" agent="$2" payload="$3"
    printf '%s' "$payload" \
        | python3 -c "
import json, sys
d = json.load(sys.stdin)
if not d.get('hook_event_name'):
    if not d.get('hook_event_name'):
        d['hook_event_name'] = 'PostToolUse'
print(json.dumps(d))" 2>/tmp/dbg-py.err \
        | tee /tmp/dbg-payload.txt \
        | MULTICA_AGENT_NAME="$agent" MULTICA_TASK_ID="$task_id" \
          PWD="$PROJECT_ROOT" PROJECT_ROOT="$PROJECT_ROOT" \
          HOOK_SCOPE_ID="$task_id" \
          UNIFIED_RULES_FILE="$RULES" HOOK_FIRE_LOG="$TMP_LOG" \
          bash "$HOOK" > "$TMP_OUT" 2>/dev/null
}

echo ""
echo "[E1] Native Grep payload (tool_input.pattern, no command) triggers"
run_tool "${TASK_TAG}-e1" "Revy" '{"tool_name":"Grep","tool_input":{"pattern":"foo","path":"src"}}'
if [ "$(has_grepai_remind)" = "YES" ]; then
    pass "E1.1 native Grep payload triggers grepai-search-reminder"
else
    fail "E1.1 native Grep payload did not trigger (tool_name dimension missing?)"
fi
assert_never_denied "E1.2 native Grep trigger never denies (non-blocking)"

echo ""
echo "[E2] Native Grep repeat-fire: second call reminds again (no one_shot)"
run_tool "${TASK_TAG}-e2" "Bachi" '{"tool_name":"Grep","tool_input":{"pattern":"q1","path":"src"}}'
if [ "$(has_grepai_remind)" = "YES" ]; then
    pass "E2.1 first native Grep call reminds"
else
    fail "E2.1 first native Grep call did not remind"
fi
run_tool "${TASK_TAG}-e2" "Bachi" '{"tool_name":"Grep","tool_input":{"pattern":"q2","path":"src"}}'
if [ "$(has_grepai_remind)" = "YES" ]; then
    pass "E2.2 second native Grep call reminds again (no one_shot)"
else
    fail "E2.2 second native Grep call silent (repeat-fire broken)"
fi

echo ""
echo "[E3] Native Grep covered for all agents"
for a in Atlas Bachi Fronti Revy Archi Refacty Chekky; do
    run_tool "${TASK_TAG}-e3-$a" "$a" '{"tool_name":"Grep","tool_input":{"pattern":"x","path":"."}}'
    if [ "$(has_grepai_remind)" = "YES" ]; then
        pass "E3 native Grep covered: $a"
    else
        fail "E3 native Grep NOT covered: $a"
    fi
done

# ============================================================
separator "Suite F: tool_name false-positive matrix (non-search tools)"
# ============================================================

assert_tool_no_remind() {
    local label="$1" task_id="$2" agent="$3" payload="$4"
    run_tool "$task_id" "$agent" "$payload"
    if [ "$(has_grepai_remind)" = "NO" ]; then
        pass "$label"
    else
        fail "$label (unexpected grepai-search-reminder for non-search tool)"
    fi
}

assert_tool_no_remind "F1 Read tool does not trigger"          "${TASK_TAG}-f1" "Bachi" '{"tool_name":"Read","tool_input":{"file_path":"src/a.gd"}}'
assert_tool_no_remind "F2 Write tool (content has grep literal) does not trigger" "${TASK_TAG}-f2" "Bachi" '{"tool_name":"Write","tool_input":{"file_path":"a.txt","content":"grep foo"}}'
assert_tool_no_remind "F3 Glob tool does not trigger"          "${TASK_TAG}-f3" "Revy"  '{"tool_name":"Glob","tool_input":{"pattern":"**/*.gd"}}'
assert_tool_no_remind "F4 Edit tool (old_string has grep) does not trigger" "${TASK_TAG}-f4" "Atlas" '{"tool_name":"Edit","tool_input":{"file_path":"a.gd","old_string":"grep","new_string":"x"}}'
assert_tool_no_remind "F5 Task tool (prompt has grep) does not trigger" "${TASK_TAG}-f5" "Fronti" '{"tool_name":"Task","tool_input":{"prompt":"run grep over src"}}'
assert_tool_no_remind "F6 grepai_search MCP tool does not trigger (tool_name gate)" "${TASK_TAG}-f6" "Revy" '{"tool_name":"mcp__grepai__grepai_search","tool_input":{"query":"auth flow"}}'

# ============================================================
separator "Suite G: tool_name + command_pattern combination semantics"
# ============================================================

GDIR="/tmp/see1238-gdir-$$"
rm -rf "$GDIR"; mkdir -p "$GDIR/.claude/hooks/unified"
cat > "$GDIR/.claude/hooks/unified/rules-v2.json" <<'GEOF'
{"version":2,"v1_compat":false,"rules":[{"name":"combo-rule","on":{"in":["PreToolUse"]},"one_shot":{"scope":"run"},"enabled":true,"when":{"op":"all","args":[{"op":"tool","in":["Bash"]},{"op":"command","scope":"current","pattern":"grep(\\s|$)"}]},"action":[{"op":"context","message":"[combo-rule] hit"}]}]}
GEOF

run_g() {
    local payload="$1" out="$2"
    ( cd "$GDIR" && printf '%s' "$payload" \
        | python3 -c "
import json, sys
d = json.load(sys.stdin)
if not d.get('hook_event_name'):
    d['hook_event_name'] = 'PostToolUse' if 'tool_response' in d else 'PreToolUse'
print(json.dumps(d))" \
        | MULTICA_AGENT_NAME="Bachi" MULTICA_TASK_ID="see1238v2-g-$$" \
          PWD="$GDIR" PROJECT_ROOT="$GDIR" \
          HOOK_SCOPE_ID="see1238v2-g-$$" \
          UNIFIED_RULES_FILE="$GDIR/.claude/hooks/unified/rules-v2.json" \
          HOOK_FIRE_LOG="/tmp/see1238v2-glog-$$" \
          bash "$HOOK" > "$out" 2>/dev/null )
}

run_g '{"tool_name":"Bash","tool_input":{"command":"grep foo"}}' "$TMP_CFG"
if grep -q "combo-rule" "$TMP_CFG" 2>/dev/null; then
    pass "G1 tool_name+command_pattern combo fires on matching tool and command"
else
    fail "G1 combo rule did not fire for Bash grep"
fi
run_g '{"tool_name":"Grep","tool_input":{"pattern":"grep foo"}}' "$TMP_CFG"
if grep -q "combo-rule" "$TMP_CFG" 2>/dev/null; then
    fail "G2 combo rule fired despite tool_name mismatch (Grep tool)"
else
    pass "G2 combo rule silent on tool_name mismatch (command_pattern not evaluated)"
fi
run_g '{"tool_name":"OtherTool","tool_input":{"command":"grep foo"}}' "$TMP_CFG"
if grep -q "combo-rule" "$TMP_CFG" 2>/dev/null; then
    fail "G3 combo rule fired for non-Bash tool carrying command field"
else
    pass "G3 combo rule silent for non-Bash tool with command field"
fi
rm -rf "$GDIR"; rm -f /tmp/.hook-fired-combo-* "/tmp/see1238v2-glog-$$" 2>/dev/null

# ============================================================
separator "Summary"
# ============================================================

echo ""
echo -e "${CYAN}Results:${NC}"
echo -e "  ${GREEN}Passed:${NC}  $PASS"
echo -e "  ${RED}Failed:${NC}  $FAIL"
echo -e "  ${YELLOW}Warnings:${NC} $WARN"
echo ""
TOTAL=$((PASS + FAIL + WARN))
echo -e "  Total:   $TOTAL"

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}OVERALL: PASS${NC}"
    exit 0
else
    echo -e "${RED}OVERALL: FAIL${NC}"
    exit 1
fi
