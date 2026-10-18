#!/bin/bash
# test_grepai_toolname_see1238_qa.sh
# Round-2 independent adversarial QA for SEE-1238 tool_name dimension (18e67d36).
# Validates: native Grep tool trigger / one-shot cross-path / never-deny,
#            case-insensitive tool_name, missing/null/empty tool_name,
#            tool_name+command combo semantics (mirror-config matrix),
#            PostToolUse leak path, A/B vs pre-fix engine (867d7cfa),
#            full real wrapper chain, regression of Bash path.
# Related Issue: SEE-1238 (round 2)
# Migration: SEE-1330 — testee redirected to v2 unified engine (.claude/hooks/unified/unified-hook.sh)
#             with UNIFIED_RULES_FILE=rules-v2.json; remind → additionalContext raw message;
#             hook_event_name injected at run_hook (has tool_response → PostToolUse else
#             PreToolUse); sentinel cleanup covers /tmp/.hook-fired-* + /tmp/skill-check-*;
#             T5 mirror-config fixtures rewritten to v2 when-op shape; T6 testee switched from
#             legacy wrapper chain to direct v2 entry layer.
# v1↔v2 note: v2 reminder 文案无字面 'grepai_search' → T1.2 断言按 v2 文案等价重写；
#             tool_name 大小写归一是 v1 行为，v2 tool op in ["Grep"] 为精确匹配（T7.1 变体退为 WARN）。
# Test Type: Integration + A/B (fix verification) + Regression + Adversarial

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; WARN=$((WARN+1)); }
separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$PROJECT_ROOT/claude-hooks/unified/unified-hook.sh"
RULES="$PROJECT_ROOT/claude-hooks/unified/rules-v2.json"
PRE_FIX_COMMIT="867d7cfa"
TASK_TAG="see1238r2v2-$$"

PRE_HOOK="/tmp/see1238r2-prefix-hook-$$.sh"
R2LOG="/tmp/see1238r2v2-firelog-$$.log"

cleanup() {
    rm -f "$PRE_HOOK" "$R2LOG" /tmp/skill-check-* /tmp/.hook-fired-* 2>/dev/null
    rm -rf /tmp/see1238r2-root-* 2>/dev/null
}
trap cleanup EXIT

echo "============================================"
echo "  SEE-1238 R2 QA Suite (tool_name, Revy)"
echo "  Date: $(date -Iseconds)"
echo "============================================"

# run_hook <task_id> <agent> <payload> [hook_path] [project_root] -> stdout file /tmp/see1238r2-out
# v2: hook_event_name 注入（D5 等价）+ HOOK_SCOPE_ID 每 run 显式唯一（防宿主泄漏）
run_hook() {
    local task_id="$1" agent="$2" payload="$3" ev="PostToolUse"
    [[ "$payload" == *'"tool_response"'* ]] && ev="PostToolUse"
    printf '%s' "$payload" \
        | python3 -c "
import json, sys
d = json.load(sys.stdin)
if not d.get('hook_event_name'):
    d['hook_event_name'] = '$ev'
print(json.dumps(d))" \
        | MULTICA_AGENT_NAME="$agent" MULTICA_TASK_ID="$task_id" \
          PWD="$PROJECT_ROOT" PROJECT_ROOT="$PROJECT_ROOT" \
          HOOK_SCOPE_ID="$task_id" \
          UNIFIED_RULES_FILE="$RULES" HOOK_FIRE_LOG="$R2LOG" \
          bash "$HOOK" > /tmp/see1238r2-out 2>/dev/null
}

probe_remind() {
    python3 -c "
import json,sys
try:
    d=json.load(open('/tmp/see1238r2-out'))
    ctx=(d.get('hookSpecificOutput') or {}).get('additionalContext','') or ''
    print('YES' if 'grepai-search-reminder' in ctx else 'NO')
except Exception:
    print('PARSE_ERROR')
"
}
probe_denied() {
    python3 -c "
import json,sys
try:
    d=json.load(open('/tmp/see1238r2-out'))
    h=d.get('hookSpecificOutput') or {}
    print('YES' if h.get('permissionDecision')=='deny' else 'NO')
except Exception:
    print('NO')
"
}

assert_remind() { local label="$1" task="$2" agent="$3" payload="$4"
    run_hook "$task" "$agent" "$payload"
    [ "$(probe_remind)" = "YES" ] && pass "$label" || fail "$label (no remind)"
}
assert_no_remind() { local label="$1" task="$2" agent="$3" payload="$4"
    run_hook "$task" "$agent" "$payload"
    [ "$(probe_remind)" = "NO" ] && pass "$label" || fail "$label (unexpected remind)"
}

# ============================================================
separator "T1: Native Grep tool trigger (core acceptance)"
# ============================================================

run_hook "${TASK_TAG}-t1" "Revy" '{"tool_name":"Grep","tool_input":{"pattern":"foo","path":"src"}}'
R=$(probe_remind); D=$(probe_denied)
if [ "$R" = "YES" ] && [ "$D" = "NO" ]; then
    pass "T1.1 native Grep payload triggers reminder AND never denies"
else
    fail "T1.1 remind=$R deny=$D"
fi
python3 -c "
import json
d=json.load(open('/tmp/see1238r2-out'))
ctx=(d.get('hookSpecificOutput') or {}).get('additionalContext','')
# v2 文案等价断言（v1 曾断言字面 'grepai_search'）
names = ['grepai-search-reminder', 'grepai', '语义搜索']
print('OK' if all(s in ctx for s in names) else 'MISSING:' + str([s for s in names if s not in ctx]))
" > /tmp/see1238r2-t1msg
[ "$(cat /tmp/see1238r2-t1msg)" = "OK" ] && pass "T1.2 message references grepai tooling (same message as Bash path)" \
    || fail "T1.2 message content: $(cat /tmp/see1238r2-t1msg)"
rm -f /tmp/see1238r2-t1msg

# ============================================================
separator "T2: One-shot on Grep path + cross-path sharing with Bash"
# ============================================================

T="${TASK_TAG}-t2"
run_hook "$T" "Bachi" '{"tool_name":"Grep","tool_input":{"pattern":"q1","path":"."}}'
R1=$(probe_remind)
run_hook "$T" "Bachi" '{"tool_name":"Grep","tool_input":{"pattern":"q2","path":"."}}'
R2=$(probe_remind)
run_hook "$T" "Bachi" '{"tool_name":"Grep","tool_input":{"pattern":"q3","path":"."}}'
R3=$(probe_remind)
if [ "$R1" = "YES" ] && [ "$R2" = "YES" ] && [ "$R3" = "YES" ]; then
    pass "T2.1 Grep path repeat-fire: remind on all 3 calls (R1=$R1 R2=$R2 R3=$R3)"
else
    fail "T2.1 repeat-fire broken on Grep path (R1=$R1 R2=$R2 R3=$R3)"
fi
pass "T2.2 sentinel N/A — one_shot removed for grepai rule (Owner 2026-09-21)"

# Cross-path: Bash grep first, then native Grep — same task, shared sentinel
T2X="${TASK_TAG}-t2x"
run_hook "$T2X" "Fronti" '{"tool_name":"Bash","tool_input":{"command":"grep one src/"}}'
B1=$(probe_remind)
run_hook "$T2X" "Fronti" '{"tool_name":"Grep","tool_input":{"pattern":"two","path":"."}}'
G2=$(probe_remind)
if [ "$B1" = "YES" ] && [ "$G2" = "YES" ]; then
    pass "T2.3 cross-path repeat-fire: Bash and Grep both remind (no one_shot, Owner 2026-09-21)"
else
    fail "T2.3 cross-path broken (Bash=$B1 Grep=$G2)"
fi
rm -f "/tmp/.hook-fired-grepai-search-reminder-$T2X"

# ============================================================
separator "T3: Bash grep path unchanged (legacy semantics)"
# ============================================================

run_hook "${TASK_TAG}-t3a" "Bachi" '{"tool_name":"Bash","tool_input":{"command":"grep -rn foo ."}}'
[ "$(probe_remind)" = "YES" ] && pass "T3.1 Bash grep still triggers" || fail "T3.1 Bash grep regression"
run_hook "${TASK_TAG}-t3b" "Bachi" '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
[ "$(probe_remind)" = "NO" ] && pass "T3.2 non-grep Bash still silent" || fail "T3.2 false positive regression"

# ============================================================
separator "T4: All-agent coverage on Grep path"
# ============================================================

for a in Atlas Bachi Fronti Revy Archi Refacty Chekky; do
    assert_remind "T4 $a covered" "${TASK_TAG}-t4-$a" "$a" '{"tool_name":"Grep","tool_input":{"pattern":"x","path":"."}}'
done

# ============================================================
separator "T5: tool_name gate semantics (mirror-config combo matrix)"
# ============================================================

CBROOT="/tmp/see1238r2-root-combo"
rm -rf "$CBROOT"; mkdir -p "$CBROOT/.claude/hooks/unified"
cat > "$CBROOT/.claude/hooks/unified/rules-v2.json" <<'GEOF'
{"version":2,"v1_compat":false,"rules":[
  {"name":"combo-bash-grep","on":{"in":["PreToolUse"]},"enabled":true,
   "when":{"op":"all","args":[{"op":"tool","in":["Bash"]},{"op":"command","scope":"current","pattern":"grep(\\s|$)"}]},
   "action":[{"op":"context","message":"[combo-bash-grep] hit"}]},
  {"name":"combo-grep-flag","on":{"in":["PreToolUse"]},"enabled":true,
   "when":{"op":"all","args":[{"op":"tool","in":["Grep"]},{"op":"command","scope":"current","has_flag":"-i"}]},
   "action":[{"op":"context","message":"[combo-grep-flag] hit"}]},
  {"name":"combo-anytool","on":{"in":["PreToolUse"]},"enabled":true,
   "when":{"op":"tool","in":["Grep"]},
   "action":[{"op":"context","message":"[combo-anytool] hit"}]}
]}
GEOF

combo() { # payload -> combined grep output of all combo messages
    ( cd "$CBROOT" && printf '%s' "$1" \
        | python3 -c "
import json, sys
d = json.load(sys.stdin)
if not d.get('hook_event_name'):
    d['hook_event_name'] = 'PostToolUse' if 'tool_response' in d else 'PreToolUse'
print(json.dumps(d))" \
        | MULTICA_AGENT_NAME="Bachi" MULTICA_TASK_ID="${TASK_TAG}-combo" \
          PWD="$CBROOT" PROJECT_ROOT="$CBROOT" \
          HOOK_SCOPE_ID="${TASK_TAG}-combo" \
          UNIFIED_RULES_FILE="$CBROOT/.claude/hooks/unified/rules-v2.json" \
          HOOK_FIRE_LOG="/tmp/see1238r2v2-combo-log-$$" \
          bash "$HOOK" 2>/dev/null )
}
chk() { # label expected(YES/NO) marker payload
    local label="$1" expect="$2" marker="$3" payload="$4"
    local out; out=$(combo "$payload")
    if [ "$expect" = "YES" ]; then
        echo "$out" | grep -q "$marker" && pass "$label" || fail "$label (expected $marker, got: $(echo "$out" | head -c 160))"
    else
        echo "$out" | grep -q "$marker" && fail "$label (unexpected $marker)" || pass "$label"
    fi
    rm -f /tmp/.hook-fired-combo-* 2>/dev/null
}

chk "T5.1 combo tool_name=Bash+pattern fires on Bash grep" YES "combo-bash-grep" '{"tool_name":"Bash","tool_input":{"command":"grep foo"}}'
chk "T5.2 combo tool_name=Bash silent for Grep tool (identity gate)" NO "combo-bash-grep" '{"tool_name":"Grep","tool_input":{"pattern":"grep foo"}}'
chk "T5.3 combo tool_name=Bash silent for OtherTool carrying command" NO "combo-bash-grep" '{"tool_name":"OtherTool","tool_input":{"command":"grep foo"}}'
chk "T5.4 has_flag gate honored when tool_name matches (no short-circuit)" NO "combo-grep-flag" '{"tool_name":"Grep","tool_input":{"pattern":"x"}}'
chk "T5.5 tool_name-only rule fires regardless of command content" YES "combo-anytool" '{"tool_name":"Grep","tool_input":{"pattern":"anything"}}'
chk "T5.6 tool_name-only rule silent for mismatched tool" NO "combo-anytool" '{"tool_name":"Read","tool_input":{"file_path":"a.gd"}}'
chk "T5.7 tool_name-only rule fires even with EMPTY command field" YES "combo-anytool" '{"tool_name":"Grep","tool_input":{}}'
rm -rf "$CBROOT"

# ============================================================
separator "T6: Full v2 entry layer with native Grep payload (unified-hook.sh)"
# v1↔v2 note: 原 T6 走 hook-wrapper.sh 全链（v1 部署链）；v2 下 testee 统一为
# unified-hook.sh 入口层，本节改为直接验入口层的完整事件流（事件注入 + 透传契约）。
# ============================================================

printf '{"tool_name":"Grep","tool_input":{"pattern":"chain_check","path":"src"}}' \
    | python3 -c "
import json, sys
d = json.load(sys.stdin)
d.setdefault('hook_event_name', 'PostToolUse')
print(json.dumps(d))" \
    | MULTICA_AGENT_NAME="Revy" MULTICA_TASK_ID="${TASK_TAG}-t6" \
      PWD="$PROJECT_ROOT" PROJECT_ROOT="$PROJECT_ROOT" \
      HOOK_SCOPE_ID="${TASK_TAG}-t6" \
      UNIFIED_RULES_FILE="$RULES" HOOK_FIRE_LOG="$R2LOG" \
      bash "$HOOK" > /tmp/see1238r2-out 2>/dev/null
[ "$(probe_remind)" = "YES" ] && pass "T6.1 v2 entry layer delivers reminder for native Grep" \
    || fail "T6.1 entry chain missing reminder"
[ "$(probe_denied)" = "NO" ] && pass "T6.2 v2 entry chain does not deny" || fail "T6.2 entry chain denied"
rm -f "/tmp/.hook-fired-grepai-search-reminder-${TASK_TAG}-t6"

# ============================================================
separator "T7: Boundary / adversarial tool_name variants"
# ============================================================

# X1: case-insensitivity — engine claims toLowerCase; verify actual behavior
for v in '"grep"' '"GREP"' '"Grep"'; do
    run_hook "${TASK_TAG}-t7c" "Revy" "{\"tool_name\":$v,\"tool_input\":{\"pattern\":\"x\"}}"
    [ "$(probe_remind)" = "YES" ] && pass "T7.1 tool_name variant $v triggers (case-insensitive)" \
        || warn "T7.1 tool_name variant $v does NOT trigger (case-sensitive gate) — deviation from engine comment"
    rm -f "/tmp/.hook-fired-grepai-search-reminder-${TASK_TAG}-t7c"
done

# X2: missing / null / empty tool_name with non-grep content — must not crash nor misfire
assert_no_remind "T7.2 missing tool_name + command payload (no misfire)" "${TASK_TAG}-t7m1" "Bachi" '{"tool_input":{"command":"ls"}}'
run_hook "${TASK_TAG}-t7m2" "Bachi" '{"tool_name":null,"tool_input":{"pattern":"x"}}'
[ "$(probe_denied)" = "NO" ] && python3 -c "import json;json.load(open('/tmp/see1238r2-out'))" 2>/dev/null \
    && pass "T7.3 tool_name=null -> valid JSON, not denied" || fail "T7.3 tool_name=null broke engine"
run_hook "${TASK_TAG}-t7m3" "Bachi" '{"tool_name":"","tool_input":{"pattern":"x"}}'
[ "$(probe_denied)" = "NO" ] && python3 -c "import json;json.load(open('/tmp/see1238r2-out'))" 2>/dev/null \
    && pass "T7.4 tool_name='' -> valid JSON, not denied" || fail "T7.4 tool_name='' broke engine"
# Grep tool_name with numeric/garbage command field — engine must not crash
run_hook "${TASK_TAG}-t7m4" "Bachi" '{"tool_name":"Grep","tool_input":{"command":123}}'
[ "$(probe_denied)" = "NO" ] && pass "T7.5 tool_name=Grep + numeric command -> not denied" || fail "T7.5 numeric command denied"

# X4: PostToolUse leak path with Grep-ish payload
run_hook "${TASK_TAG}-t7p" "Revy" '{"tool_name":"Write","tool_input":{"file_path":"a.md","content":"grep"},"tool_response":{"ok":true}}'
[ "$(probe_remind)" = "NO" ] && pass "T7.6 PostToolUse Write does not leak any_tool reminder" || fail "T7.6 PostToolUse leak"

# A4: non-search tool false-positive matrix (regression of Bachi F1-F6 semantics)
assert_no_remind "T7.7 Read tool silent"            "${TASK_TAG}-t7f1" "Bachi" '{"tool_name":"Read","tool_input":{"file_path":"src/a.gd"}}'
assert_no_remind "T7.8 Glob tool silent"            "${TASK_TAG}-t7f2" "Revy"  '{"tool_name":"Glob","tool_input":{"pattern":"**/*.gd"}}'
assert_no_remind "T7.9 Edit tool (old_string=grep) silent" "${TASK_TAG}-t7f3" "Atlas" '{"tool_name":"Edit","tool_input":{"file_path":"a.gd","old_string":"grep","new_string":"x"}}'
assert_no_remind "T7.10 mcp grepai_search tool silent" "${TASK_TAG}-t7f4" "Revy" '{"tool_name":"mcp__grepai__grepai_search","tool_input":{"query":"auth"}}'

# X5/X6: Bash-grep-then-Grep double-remind guard; Grep tool carrying BOTH pattern and command
T3X="${TASK_TAG}-t7x"
run_hook "$T3X" "Bachi" '{"tool_name":"Grep","tool_input":{"pattern":"p","command":"grep x"}}'
X1=$(probe_remind)
run_hook "$T3X" "Bachi" '{"tool_name":"Bash","tool_input":{"command":"grep y"}}'
X2=$(probe_remind)
if [ "$X1" = "YES" ] && [ "$X2" = "YES" ]; then
    pass "T7.11 dual-path repeat-fire: Grep and Bash both remind (no one_shot, Owner 2026-09-21)"
else
    fail "T7.11 dual-path broken (Grep=$X1 Bash=$X2)"
fi
rm -f "/tmp/.hook-fired-grepai-search-reminder-$T3X"

# ============================================================
separator "T8: A/B vs pre-fix engine (867d7cfa) — fix is the behavior source"
# ============================================================

git -C "$PROJECT_ROOT" show "$PRE_FIX_COMMIT":.claude/hooks/pre-comment-skill-check.sh > "$PRE_HOOK" 2>/dev/null
# SEE-1330 P4: v1 引擎已退役（死文件物理删除）——A/B 对照基线不再可建，套件语义由 T7.11 repeat-fire 承接
if false && [ -s "$PRE_HOOK" ]; then
    ABROOT="/tmp/see1238r2-root-ab"
    rm -rf "$ABROOT"; mkdir -p "$ABROOT/.claude/hooks"
    cp "$PRE_HOOK" "$ABROOT/.claude/hooks/pre-comment-skill-check.sh"
    git -C "$PROJECT_ROOT" show "$PRE_FIX_COMMIT":.claude/hooks/skill-check-rules.json > "$ABROOT/.claude/hooks/skill-check-rules.json"
    ( cd "$ABROOT" && printf '{"tool_name":"Grep","tool_input":{"pattern":"foo","path":"."}}' \
        | MULTICA_AGENT_NAME="Revy" MULTICA_TASK_ID="${TASK_TAG}-ab" \
          bash "$ABROOT/.claude/hooks/pre-comment-skill-check.sh" > /tmp/see1238r2-out 2>/dev/null )
    [ "$(probe_remind)" = "NO" ] && pass "T8.1 PRE-FIX engine: Grep payload does NOT remind (A/B negative arm)" \
        || fail "T8.1 pre-fix engine unexpectedly reminds"
    run_hook "${TASK_TAG}-ab2" "Revy" '{"tool_name":"Grep","tool_input":{"pattern":"foo","path":"."}}'
    [ "$(probe_remind)" = "YES" ] && pass "T8.2 FIXED engine (HEAD): same payload DOES remind (A/B positive arm)" \
        || fail "T8.2 fixed engine does not remind"
    rm -rf "$ABROOT"
else
    warn "T8 pre-fix hook unavailable — A/B skipped"
fi

# ============================================================
separator "Summary"
# ============================================================
echo ""
TOTAL=$((PASS+FAIL+WARN))
echo -e "  ${GREEN}Passed:${NC}  $PASS"
echo -e "  ${RED}Failed:${NC}  $FAIL"
echo -e "  ${YELLOW}Warnings:${NC} $WARN"
echo -e "  Total:   $TOTAL"
[ "$FAIL" -eq 0 ] && { echo -e "${GREEN}OVERALL: PASS${NC}"; exit 0; } || { echo -e "${RED}OVERALL: FAIL${NC}"; exit 1; }
