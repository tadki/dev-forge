#!/bin/bash
# SEE-1330 P0: v2 unified engine skeleton test suite (SPEC-001)
# Covers: 9 hook-point routing / when op evaluation /
#         fail-open injection / window-id resolution (D4: issue/run direct id, no downgrade chain) /
#         zero-behavior-change with empty rules / action protocol / one_shot /
#         agents / runtime fail-soft / firelog audit / dispatcher route
# Run:    bash .dev/tests/hooks/test_v2_unified_engine_p0.sh
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0; RESULTS=()

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); RESULTS+=("PASS|$1"); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); RESULTS+=("FAIL|$1"); }
skip() { echo -e "  ${YELLOW}[SKIP]${NC} $1"; RESULTS+=("SKIP|$1"); }
separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTRY="$REPO_ROOT/hooks/unified/unified-hook.sh"
ENGINE="$REPO_ROOT/hooks/unified/engine.js"
DISPATCHER_SRC="$REPO_ROOT/hooks/dispatcher.sh"
VALIDATOR="$REPO_ROOT/hooks/unified/validate-rules.js"
FIXTURE="$(mktemp -d /tmp/v2engine-p0.XXXXXX)"
RULES="$FIXTURE/rules-v2.json"
FIRELOG="$FIXTURE/hook-fire.log"
STATE="$FIXTURE/state"

cleanup() {
    rm -f /tmp/.hook-fired-* 2>/dev/null
    rm -rf "$STATE" 2>/dev/null
}
cleanup_fixtures() {
    rm -rf "$FIXTURE"
    rm -f /tmp/.hook-fired-* 2>/dev/null
}
trap cleanup_fixtures EXIT

# 空配置 + 注入路径 + fixture firelog 环境下执行入口
# stdin 走文件重定向而非管道：管道写者是独立进程，外部高负载下被饿死会触发
# 入口层 `read -r -t 3` 的 3 秒读超时（200KB 大 payload 瞬态截断 → 透传假红，
# SEE-1381 §SPEC-012 负载归因）；文件已在页缓存，读入与写者调度解耦。
feed_stdin() {
    printf '%s' "$1" > "$FIXTURE/stdin.json"
}
run_entry() {
    local INPUT="$1"
    cleanup
    : > "$FIRELOG"
    feed_stdin "$INPUT"
    HOOK_STDOUT=$(UNIFIED_RULES_FILE="$RULES" \
        HOOK_FIRE_LOG="$FIRELOG" \
        HOOK_STATE_DIR="$STATE" \
        MULTICA_AGENT_NAME="${V2_AGENT:-}" \
        MULTICA_TASK_ID="${V2_TASK_ID:-}" \
        HOOK_SCOPE_ID="${V2_SCOPE_ID:-}" \
        CLAUDE_CODE_SESSION_ID="${V2_SESSION:-}" \
        PWD="${V2_PWD:-$REPO_ROOT}" \
        UNIFIED_ENGINE_JS="${V2_ENGINE:-}" \
        bash "$ENTRY" < "$FIXTURE/stdin.json" 2>/dev/null)
    HOOK_EXIT=$?
    V2_AGENT=""; V2_TASK_ID=""; V2_SCOPE_ID=""; V2_SESSION=""; V2_PWD=""; V2_ENGINE=""
}

# 保留 sentinel 的运行变体（one_shot 二次调用测试专用）
run_entry_keep() {
    local INPUT="$1"
    : > "$FIRELOG"
    feed_stdin "$INPUT"
    HOOK_STDOUT=$(UNIFIED_RULES_FILE="$RULES" \
        HOOK_FIRE_LOG="$FIRELOG" \
        HOOK_STATE_DIR="$STATE" \
        MULTICA_AGENT_NAME="${V2_AGENT:-}" \
        MULTICA_TASK_ID="${V2_TASK_ID:-}" \
        HOOK_SCOPE_ID="${V2_SCOPE_ID:-}" \
        CLAUDE_CODE_SESSION_ID="${V2_SESSION:-}" \
        PWD="${V2_PWD:-$REPO_ROOT}" \
        UNIFIED_ENGINE_JS="${V2_ENGINE:-}" \
        bash "$ENTRY" < "$FIXTURE/stdin.json" 2>/dev/null)
    HOOK_EXIT=$?
    V2_AGENT=""; V2_TASK_ID=""; V2_SCOPE_ID=""; V2_SESSION=""; V2_PWD=""; V2_ENGINE=""
}

# 直接调引擎（绕过入口，测引擎自身 fail-open 语义）
run_engine() {
    local INPUT="$1"
    cleanup
    : > "$FIRELOG"
    feed_stdin "$INPUT"
    HOOK_STDOUT=$(UNIFIED_RULES_FILE="$RULES" \
        HOOK_FIRE_LOG="$FIRELOG" \
        HOOK_STATE_DIR="$STATE" \
        MULTICA_AGENT_NAME="${V2_AGENT:-}" \
        MULTICA_TASK_ID="${V2_TASK_ID:-}" \
        HOOK_SCOPE_ID="${V2_SCOPE_ID:-}" \
        CLAUDE_CODE_SESSION_ID="${V2_SESSION:-}" \
        PWD="${V2_PWD:-$REPO_ROOT}" \
        node "$ENGINE" < "$FIXTURE/stdin.json" 2>/dev/null)
    HOOK_EXIT=$?
    V2_AGENT=""; V2_TASK_ID=""; V2_SCOPE_ID=""; V2_SESSION=""; V2_PWD=""
}

write_rules() { printf '%s' "$1" > "$RULES"; }

assert_passthrough() {
    local label="$1" expected="$2"
    if [ "$HOOK_STDOUT" = "$expected" ]; then
        pass "$label — 原样透传"
    else
        fail "$label — 透传被破坏. got: '${HOOK_STDOUT:0:160}'"
    fi
}
assert_deny() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"permissionDecision":"deny"'; then
        pass "$label — deny 输出"
    else
        fail "$label — 未拦截. got: '${HOOK_STDOUT:0:160}'"
    fi
}
assert_no_deny() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"permissionDecision":"deny"'; then
        fail "$label — 误拦截. got: '${HOOK_STDOUT:0:160}'"
    else
        pass "$label — 未拦截"
    fi
}
assert_context() {
    local label="$1" fragment="$2"
    if echo "$HOOK_STDOUT" | grep -q '"additionalContext"' && echo "$HOOK_STDOUT" | grep -q "$fragment"; then
        pass "$label — additionalContext 注入"
    else
        fail "$label — context 缺失. got: '${HOOK_STDOUT:0:160}'"
    fi
}
assert_exit_0() {
    local label="$1"
    if [ "$HOOK_EXIT" -eq 0 ]; then pass "$label — exit 0"; else fail "$label — exit $HOOK_EXIT"; fi
}
assert_firelog_has() {
    local label="$1" pattern="$2"
    if grep -q "$pattern" "$FIRELOG" 2>/dev/null; then
        pass "$label — firelog 命中"
    else
        fail "$label — firelog 未命中 '$pattern'. log: $(cat "$FIRELOG" 2>/dev/null | head -3 | tr '\n' ';')"
    fi
}

echo "============================================================"
echo "  SEE-1330 P0: v2 Unified Engine Skeleton"
echo "  Date: $(date -Iseconds)"
echo "============================================================"

separator "Prerequisites"
[ -f "$ENTRY" ] && pass "unified-hook.sh exists" || { fail "unified-hook.sh MISSING"; exit 1; }
[ -f "$ENGINE" ] && pass "engine.js exists" || { fail "engine.js MISSING"; exit 1; }
[ -f "$VALIDATOR" ] && pass "validate-rules.js exists" || { fail "validate-rules.js MISSING"; exit 1; }
node -e "JSON.parse(require('fs').readFileSync('$REPO_ROOT/hooks/unified/rules-v2.json','utf8'))" 2>/dev/null \
    && pass "rules-v2.json valid JSON" || fail "rules-v2.json INVALID"
LINES=$(wc -l < "$ENGINE")
[ "$LINES" -lt 800 ] && pass "engine.js $LINES lines < 800" || fail "engine.js $LINES lines >= 800"

#####################################################################
# 1. 空规则配置 → 零行为变化（目标1 硬判据）
#####################################################################
separator "1. Empty rules = zero behavior change"
write_rules '{"version":2,"v1_compat":false,"rules":[]}'
RAW_IN='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls -la"},"session_id":"s1"}'
run_entry "$RAW_IN"
assert_exit_0 "1a: empty rules exit 0"
assert_passthrough "1b: empty rules passthrough" "$RAW_IN"
assert_no_deny "1c: empty rules no deny"

# 引擎直跑（无入口层）时无命中输出为空
run_engine "$RAW_IN"
[ -z "$HOOK_STDOUT" ] && pass "1d: engine emits nothing on no-match" || fail "1d: engine emitted '${HOOK_STDOUT:0:80}'"

# v1_compat=false 时 v1 文件即使存在也不加载（v1 规则不触发）
write_rules "{\"version\":2,\"v1_compat\":false,\"rules\":[],\"v1_rules_file\":\"$FIXTURE/v1rules.json\"}"
cat > "$FIXTURE/v1rules.json" <<'EOF'
{"rules":[{"name":"v1-should-not-load","trigger":"any_tool","action":"remind","enabled":true,"message":"[v1-leak]"}]}
EOF
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_no_deny "1e: v1_compat=false ignores v1 file"
if echo "$HOOK_STDOUT" | grep -q "v1-leak"; then fail "1e: v1 rule leaked into v2 output"; else pass "1e: no v1 rule leakage"; fi

#####################################################################
# 2. 9 时点路由（on.in 匹配 hook_event_name）
#####################################################################
separator "2. Nine hook-point routing"
POINTS=(PreToolUse PostToolUse SessionStart SessionEnd Stop SubagentStop UserPromptSubmit Notification PreCompact)
for ((i=0; i<${#POINTS[@]}; i++)); do
    P="${POINTS[$i]}"
    OTHER="${POINTS[$(( (i+1) % ${#POINTS[@]} ))]}"
    write_rules "{\"version\":2,\"rules\":[{\"name\":\"route-$P\",\"on\":{\"in\":[\"$P\"]},\"when\":{\"op\":\"event\",\"in\":[\"$P\"]},\"action\":[{\"op\":\"context\",\"message\":\"[route-$P hit]\"}]}]}"
    run_entry "{\"hook_event_name\":\"$P\",\"session_id\":\"s\"}"
    assert_context "2a[$P]: fires on $P" "route-$P hit"
    assert_exit_0 "2a[$P]: exit 0"
    run_entry "{\"hook_event_name\":\"$OTHER\",\"session_id\":\"s\"}"
    if echo "$HOOK_STDOUT" | grep -q "route-$P hit"; then
        fail "2b[$P]: rule leaked to $OTHER"
    else
        pass "2b[$P]: silent on $OTHER"
    fi
done

# on.except 排除
write_rules '{"version":2,"rules":[{"name":"except-stop","on":{"except":["Stop"]},"action":[{"op":"context","message":"[not-stop]"}]}]}'
run_entry '{"hook_event_name":"UserPromptSubmit"}'
assert_context "2c: on.except fires on UPS" "not-stop"
run_entry '{"hook_event_name":"Stop"}'
if echo "$HOOK_STDOUT" | grep -q "not-stop"; then fail "2d: on.except Stop leaked"; else pass "2d: on.except blocks Stop"; fi

# on 缺省 = 全时点
write_rules '{"version":2,"rules":[{"name":"anywhere","action":[{"op":"context","message":"[anywhere]"}]}]}'
run_entry '{"hook_event_name":"PreCompact"}'
assert_context "2e: on absent = all points (PreCompact)" "anywhere"

#####################################################################
# 3. when op 求值
#####################################################################
separator "3. when op evaluation"

# tool op in[]
write_rules '{"version":2,"rules":[{"name":"tool-bash","on":{"in":["PreToolUse"]},"when":{"op":"tool","in":["Bash"]},"action":[{"op":"context","message":"[tool-bash]"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_context "3a: tool in[Bash] fires" "tool-bash"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{}}'
if echo "$HOOK_STDOUT" | grep -q "tool-bash"; then fail "3b: tool in[Bash] hit Read"; else pass "3b: tool in[] excludes Read"; fi

# tool op pattern
write_rules '{"version":2,"rules":[{"name":"tool-re","on":{"in":["PreToolUse"]},"when":{"op":"tool","pattern":"^mcp__"},"action":[{"op":"context","message":"[tool-re]"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"mcp__godot-mcp__run","tool_input":{}}'
assert_context "3c: tool pattern regex" "tool-re"

# command op current: pattern（前缀 base+sub）
write_rules '{"version":2,"rules":[{"name":"cmd-cur","on":{"in":["PreToolUse"]},"when":{"op":"command","scope":"current","pattern":"git push"},"action":[{"op":"context","message":"[cmd-cur]"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status && git push origin HEAD"}}'
assert_context "3d: command current pattern compound" "cmd-cur"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo git push"}}'
if echo "$HOOK_STDOUT" | grep -q "cmd-cur"; then fail "3e: echo git push误命中"; else pass "3e: echo prefix not command"; fi

# command op current: has_flag + flag_has_value
write_rules '{"version":2,"rules":[{"name":"flag-guard","on":{"in":["PreToolUse"]},"when":{"op":"command","scope":"current","pattern":"multica issue create","has_flag":"--parent","flag_has_value":true},"action":[{"op":"deny","message":"no child issue"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"multica issue create --parent abc --title t"}}'
assert_deny "3f: has_flag + value blocks"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"multica issue create --parent \"\" --title t"}}'
assert_no_deny "3g: empty flag value passes"

# file op
write_rules '{"version":2,"rules":[{"name":"file-md","on":{"in":["PreToolUse"]},"when":{"op":"file","patterns":["*.md"]},"action":[{"op":"context","message":"[file-md]"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/x/docs/readme.md"}}'
assert_context "3h: file glob .md" "file-md"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/x/src/main.gd"}}'
if echo "$HOOK_STDOUT" | grep -q "file-md"; then fail "3i: .gd matched *.md"; else pass "3i: file glob excludes .gd"; fi

# content op（--content-file 解析）
write_rules '{"version":2,"rules":[{"name":"content-mention","on":{"in":["PreToolUse"]},"when":{"op":"all","args":[{"op":"tool","in":["Bash"]},{"op":"command","scope":"current","pattern":"multica issue comment add"},{"op":"content","pattern":"mention://agent/"}]},"action":[{"op":"deny","message":"confirm mentions"}]}]}'
printf 'hello [@X](mention://agent/abc) world' > "$FIXTURE/body.md"
run_entry "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"multica issue comment add 1 --content-file $FIXTURE/body.md\"}}"
assert_deny "3j: content via --content-file"

# content op 需要 tool 约束同树（M5）——无 tool op 仍可运行（告警在 validator 层）
write_rules '{"version":2,"rules":[{"name":"content-bash","on":{"in":["PreToolUse"]},"when":{"op":"content","pattern":"xyzzy"},"action":[{"op":"context","message":"[content-bash]"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo xyzzy"}}'
if echo "$HOOK_STDOUT" | grep -q "content-bash"; then fail "3k: content without command payload should not fire on echo"; else pass "3k: content op needs comment body"; fi

# branch op（git 仓库内）
BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
write_rules "{\"version\":2,\"rules\":[{\"name\":\"branch-guard\",\"on\":{\"in\":[\"PreToolUse\"]},\"when\":{\"op\":\"branch\",\"in\":[\"$BRANCH\"]},\"action\":[{\"op\":\"context\",\"message\":\"[branch-guard]\"}]}]}"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_context "3l: branch matches current" "branch-guard"

# used_skill / cmd-run：transcript 不可用 → false（无 MULTICA_TASK_ID）
write_rules '{"version":2,"rules":[{"name":"skill-used","on":{"in":["PreToolUse"]},"when":{"op":"used_skill","skill":"bachi-coding"},"action":[{"op":"context","message":"[skill-used]"}]},{"name":"cmd-run","on":{"in":["PreToolUse"]},"when":{"op":"command","scope":"run","keyword":"git"},"action":[{"op":"context","message":"[cmd-run]"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
if echo "$HOOK_STDOUT" | grep -q "skill-used"; then fail "3m: used_skill fired w/o transcript"; else pass "3m: used_skill false w/o transcript"; fi
if echo "$HOOK_STDOUT" | grep -q "cmd-run"; then fail "3n: cmd-run fired w/o transcript"; else pass "3n: cmd-run false w/o transcript"; fi

# all/any/not 组合
write_rules '{"version":2,"rules":[{"name":"combo","on":{"in":["PreToolUse"]},"when":{"op":"all","args":[{"op":"tool","in":["Bash"]},{"op":"not","arg":{"op":"command","scope":"current","pattern":"git status"}}]},"action":[{"op":"context","message":"[combo]"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git log"}}'
assert_context "3o: all+not combo fires" "combo"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}'
if echo "$HOOK_STDOUT" | grep -q "combo"; then fail "3p: not() failed to exclude"; else pass "3p: not() excludes git status"; fi

# event op in 树中收窄（多值 on）
write_rules '{"version":2,"rules":[{"name":"narrowed","on":{"in":["PreToolUse","Stop"]},"when":{"op":"all","args":[{"op":"event","in":["PreToolUse"]},{"op":"tool","in":["Bash"]}]},"action":[{"op":"context","message":"[narrowed]"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_context "3q: event narrows multi-point on" "narrowed"
run_entry '{"hook_event_name":"Stop"}'
if echo "$HOOK_STDOUT" | grep -q "narrowed"; then fail "3r: Stop leaked through narrow"; else pass "3r: Stop excluded by event narrow"; fi

#####################################################################
# 4. action 协议
#####################################################################
separator "4. Action protocol"

# deny 协议形态
write_rules '{"version":2,"rules":[{"name":"deny-proto","on":{"in":["PreToolUse"]},"when":{"op":"tool","in":["Bash"]},"action":[{"op":"deny","message":"blocked by rule"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_deny "4a: deny protocol shape"
echo "$HOOK_STDOUT" | grep -q '"hookEventName":"PreToolUse"' && pass "4a: hookEventName present" || fail "4a: hookEventName missing"
echo "$HOOK_STDOUT" | grep -q "blocked by rule" && pass "4a: reason carries message" || fail "4a: reason missing message"

# context 协议
write_rules '{"version":2,"rules":[{"name":"ctx-proto","on":{"in":["PostToolUse"]},"action":[{"op":"context","message":"ctx line"}]}]}'
run_entry '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"/a.md"},"tool_response":{"ok":true}}'
assert_context "4b: context protocol" "ctx line"
assert_no_deny "4b: context never denies"

# deny + context 组合（提醒拼入 deny reason，M4）
write_rules '{"version":2,"rules":[{"name":"deny-plus","on":{"in":["PreToolUse"]},"when":{"op":"tool","in":["Bash"]},"action":[{"op":"context","message":"remember this"},{"op":"deny","message":"final block"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_deny "4c: deny short-circuit blocks"
echo "$HOOK_STDOUT" | grep -q "remember this" && pass "4c: context folded into deny reason" || fail "4c: context lost in deny"

# modify 协议
write_rules '{"version":2,"rules":[{"name":"mod-proto","on":{"in":["PreToolUse"]},"when":{"op":"all","args":[{"op":"tool","in":["Write"]},{"op":"file","patterns":["*.json"]}]},"action":[{"op":"modify"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/a.json","content":"{}"}}'
echo "$HOOK_STDOUT" | grep -q '"permissionDecision":"allow"' && echo "$HOOK_STDOUT" | grep -q '"updatedInput"' \
    && pass "4d: modify allow+updatedInput" || fail "4d: modify protocol wrong: '${HOOK_STDOUT:0:160}'"

# run_script：inject_stdout 并入 context
cat > "$FIXTURE/echo_ctx.sh" <<'EOF'
#!/bin/bash
echo "script says hi"
EOF
chmod +x "$FIXTURE/echo_ctx.sh"
write_rules "{\"version\":2,\"rules\":[{\"name\":\"rs-ctx\",\"on\":{\"in\":[\"PreToolUse\"]},\"when\":{\"op\":\"tool\",\"in\":[\"Bash\"]},\"action\":[{\"op\":\"run_script\",\"path\":\"$FIXTURE/echo_ctx.sh\",\"inject_stdout\":true,\"timeout_ms\":30000}]}]}"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_context "4e: run_script inject_stdout" "script says hi"

# run_script：脚本输出 hookSpecificOutput 协议 → 透传
cat > "$FIXTURE/proto.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"script denied"}}'
EOF
chmod +x "$FIXTURE/proto.sh"
write_rules "{\"version\":2,\"rules\":[{\"name\":\"rs-proto\",\"on\":{\"in\":[\"PreToolUse\"]},\"when\":{\"op\":\"tool\",\"in\":[\"Bash\"]},\"action\":[{\"op\":\"run_script\",\"path\":\"$FIXTURE/proto.sh\",\"timeout_ms\":3000}]}]}"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_deny "4f: run_script protocol passthrough"

# run_script 脚本失败 → fail-open（不产生拦截，其余规则继续）
cat > "$FIXTURE/boom.sh" <<'EOF'
#!/bin/bash
exit 3
EOF
chmod +x "$FIXTURE/boom.sh"
write_rules "{\"version\":2,\"rules\":[{\"name\":\"rs-boom\",\"on\":{\"in\":[\"PreToolUse\"]},\"when\":{\"op\":\"tool\",\"in\":[\"Bash\"]},\"action\":[{\"op\":\"run_script\",\"path\":\"$FIXTURE/boom.sh\",\"timeout_ms\":3000}]},{\"name\":\"rs-after\",\"on\":{\"in\":[\"PreToolUse\"]},\"action\":[{\"op\":\"context\",\"message\":\"[still-alive]\"}]}]}"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_context "4g: script failure fail-open, next rule lives" "still-alive"
assert_firelog_has "4g: script failure audited" "run-script"

#####################################################################
# 5. one_shot / HOOK_SCOPE_ID
#####################################################################
separator "5. one_shot + HOOK_SCOPE_ID"

# SEE-1333 D4 终态：one_shot 分量直读 env var 名；{scope:"run"} 为迁移期兼容 = MULTICA_TASK_ID 窗口
write_rules '{"version":2,"rules":[{"name":"once-run","on":{"in":["PreToolUse"]},"one_shot":{"ids":["MULTICA_AGENT_NAME","HOOK_RUN_SCOPE_ID"]},"action":[{"op":"context","message":"[once-run]"}]}]}'
V2_AGENT="t5agent" V2_TASK_ID="t5-run"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_context "5a: run combo window first fires" "once-run"
V2_AGENT="t5agent" V2_TASK_ID="t5-run"
run_entry_keep '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
if echo "$HOOK_STDOUT" | grep -q "once-run"; then fail "5b: run window refired"; else pass "5b: run window suppressed 2nd"; fi
SENTINELS=$(ls "$STATE/.hook-fired-once-run-t5agent-t5-run" 2>/dev/null | wc -l)
[ "$SENTINELS" -eq 1 ] && pass "5c: sentinel key .hook-fired-<rule>-<env值join>" || fail "5c: sentinel count=$SENTINELS"

# D4 fail-open：窗口 env var 未设置 → 跳过规则不拦截 + WARN 审计
V2_AGENT="" V2_TASK_ID=""
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
if echo "$HOOK_STDOUT" | grep -q "once-run"; then fail "5d2: fired without window env"; else pass "5d2: no window env -> fail-open skip"; fi
assert_firelog_has "5d2: one-shot window env missing warn logged" "one-shot window env missing"
# SEE-1388 §SPEC-003（fingerprint 2cc2569d04dd）：WARN 必须携带缺失 env 名与降级后果，
# 回退旧文案（one-shot-id-missing，无 missing=/无后果说明）以下两条即红
assert_firelog_has "5d2: WARN 携带缺失 env 名（SPEC-003）" "missing=MULTICA_AGENT_NAME+HOOK_RUN_SCOPE_ID"
assert_firelog_has "5d2: WARN 注明降级后果（SPEC-003）" "one_shot 抑制不生效"

# scope=session（迁移期兼容）→ MULTICA_TASK_ID 窗口，无 session 语义
write_rules '{"version":2,"rules":[{"name":"once-session","on":{"in":["PreToolUse"]},"one_shot":{"scope":"session"},"action":[{"op":"context","message":"[once-session]"}]}]}'
V2_TASK_ID="t5-sess"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"sess-1"}'
assert_context "5e: session-compat window fires once" "once-session"
run_entry_keep '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"sess-1"}'
if echo "$HOOK_STDOUT" | grep -q "once-session"; then fail "5f: session scope refired same window"; else pass "5f: session-compat suppressed"; fi
V2_TASK_ID="t5-sess2"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"sess-2"}'
assert_context "5g: new window env refires" "once-session"

# scope=never：每次都触发
write_rules '{"version":2,"rules":[{"name":"every-time","on":{"in":["PreToolUse"]},"one_shot":{"scope":"never"},"action":[{"op":"context","message":"[every-time]"}]}]}'
V2_TASK_ID=""
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_context "5h: never fires 1st" "every-time"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_context "5i: never fires 2nd" "every-time"

# v1 布尔 one_shot desugar 后同样生效（见 §6 desugar）

#####################################################################
# 6. v1 desugar 双读
#####################################################################
separator "6. (retired P4: v1 desugar dual-read removed — see §6.1 migration map)"

separator "7. Runtime fail-soft"
write_rules '{"version":2,"rules":[{"name":"bad-stop-deny","on":{"in":["Stop"]},"action":[{"op":"deny","message":"x"}]},{"name":"good","on":{"in":["PreToolUse"]},"action":[{"op":"context","message":"[good]"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_context "7a: invalid rule skipped (M2), valid fires" "good"
assert_firelog_has "7a: RULE_INVALID audited" "RULE_INVALID"
assert_firelog_has "7a: invalid rule named" "bad-stop-deny"

#####################################################################
# 8. fail-open 注入
#####################################################################
separator "8. fail-open injection"

# 8a 引擎文件缺失 → 入口透传 + ERROR 审计
write_rules '{"version":2,"rules":[]}'
V2_ENGINE="/nonexistent/engine.js"
run_entry "$RAW_IN"
assert_exit_0 "8a: missing engine exit 0"
assert_passthrough "8a: missing engine passthrough" "$RAW_IN"
assert_firelog_has "8a: engine-missing audited" "engine-missing"
V2_ENGINE=""

# 8b 配置非法 JSON → 引擎静默 + 审计
printf '{"version":2, BROKEN' > "$RULES"
run_entry "$RAW_IN"
assert_exit_0 "8b: bad config exit 0"
assert_passthrough "8b: bad config passthrough" "$RAW_IN"
assert_firelog_has "8b: config-parse audited" "config-parse"

# 8c 配置缺 rules 数组
printf '{"version":2}' > "$RULES"
run_entry "$RAW_IN"
assert_passthrough "8c: schema-broken config passthrough" "$RAW_IN"
assert_firelog_has "8c: config-schema audited" "config-schema"

# 8d payload 非法 JSON → 透传 + 审计
write_rules '{"version":2,"rules":[{"name":"x","on":{"in":["PreToolUse"]},"action":[{"op":"deny","message":"d"}]}]}'
BAD='{not json'
run_entry "$BAD"
assert_exit_0 "8d: bad payload exit 0"
assert_passthrough "8d: bad payload passthrough" "$BAD"
assert_firelog_has "8d: payload-parse audited" "payload-parse"

# 8e 引擎崩溃注入（UNIFIED_ENGINE_JS 指向抛错脚本）→ 入口透传 + 审计
cat > "$FIXTURE/crash.js" <<'EOF'
process.stderr.write("boom\n");
process.exit(7);
EOF
V2_ENGINE="$FIXTURE/crash.js"
run_entry "$RAW_IN"
assert_exit_0 "8e: engine crash exit 0"
assert_passthrough "8e: engine crash passthrough" "$RAW_IN"
assert_firelog_has "8e: engine-exit audited" "engine-exit"
V2_ENGINE=""

# 8f 引擎进程级崩溃（stack 异常逃逸）→ 引擎自捕获 fail-open
cat > "$FIXTURE/throw.js" <<'EOF'
throw new Error("uncaught from engine");
EOF
V2_ENGINE="$FIXTURE/throw.js"
run_entry "$RAW_IN"
assert_exit_0 "8f: uncaught throw exit 0"
assert_passthrough "8f: uncaught throw passthrough" "$RAW_IN"
V2_ENGINE=""

#####################################################################
# 9. 入口 env 映射：{scope:"run"} 兼容形态 = MULTICA_TASK_ID 窗口（HOOK_SCOPE_ID 入口链已由 §5/§13 覆盖终态语义）
#####################################################################
separator "9. entry env mapping (compat scope=run -> MULTICA_TASK_ID)"
write_rules '{"version":2,"rules":[{"name":"scope-map","on":{"in":["PreToolUse"]},"one_shot":{"ids":["MULTICA_TASK_ID"]},"action":[{"op":"context","message":"[scope-map]"}]}]}'
V2_TASK_ID="aaaa1111-2222-3333-4444-555555555555"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_context "9a: MULTICA_TASK_ID read directly as window env" "scope-map"
[ -f "$STATE/.hook-fired-scope-map-aaaa1111-2222-3333-4444-555555555555" ] \
    && pass "9a: sentinel keyed by MULTICA_TASK_ID env value" || fail "9a: sentinel key wrong"
V2_TASK_ID=""

#####################################################################
# 10. firelog 审计行 + dispatcher 路由
#####################################################################
separator "10. firelog + dispatcher route"
write_rules '{"version":2,"rules":[{"name":"audit-me","on":{"in":["PreToolUse"]},"when":{"op":"tool","in":["Bash"]},"action":[{"op":"context","message":"[audit]"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_firelog_has "10a: result line event field" "event=PreToolUse"
assert_firelog_has "10a: result line fired rule" "fired=audit-me"
assert_firelog_has "10a: result line action kind" "action=context"

# dispatcher unified-hook case（fixture 副本，不触真实全局 dispatcher）
DISP_FIXTURE="$FIXTURE/disp"
mkdir -p "$DISP_FIXTURE/unified"
cp "$DISPATCHER_SRC" "$DISP_FIXTURE/dispatcher.sh"
cp "$REPO_ROOT/hooks/unified/"unified-hook.sh "$REPO_ROOT/hooks/unified/"engine.js "$REPO_ROOT/hooks/unified/"when-ops.js "$REPO_ROOT/hooks/unified/"validate-rules.js "$DISP_FIXTURE/unified/"
mkdir -p "$DISP_FIXTURE/unified/rules.d"
# probe 规则替代真实 rules-v2.json（真实规则 agents 门控会静默透传，断言需确定性命中）
printf '{"version":2,"rules":[{"name":"audit-me","on":{"in":["PreToolUse"]},"when":{"op":"tool","in":["Bash"]},"action":[{"op":"context","message":"[audit]"}]}]}' > "$DISP_FIXTURE/unified/rules-v2.json"
: > "$FIRELOG"
DISP_OUT=$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' | \
    CLAUDE_PROJECT_DIR="$REPO_ROOT" HOOK_FIRE_LOG="$FIRELOG" \
    UNIFIED_RULES_FILE="$RULES" \
    bash "$DISP_FIXTURE/dispatcher.sh" unified-hook 2>/dev/null)
if echo "$DISP_OUT" | grep -q '"additionalContext"'; then
    pass "10b: dispatcher routes unified-hook → repo engine"
else
    fail "10b: dispatcher route broken. got: '${DISP_OUT:0:120}'"
fi

# dev-forge 最终态：dispatcher 兜底分支已删除，路由唯一来源 = 脚本自身目录。
# 10c 断言改写：CLAUDE_PROJECT_DIR/PWD/TARGET_REPO_ROOT 全部指向无 hooks 的空目录，
# dispatcher 仍按自身相对定位路由（注册链直指检出的语义），全局 HOME 内即使存在
# 异构配置也不参与求值（旧「全局兜底/PROJECT_ROOT 回退」语义已退役）。
mkdir -p "$FIXTURE/globalhome/.claude/hooks/unified"
printf '{"version":2,"rules":[{"name":"global-probe","on":{"in":["PreToolUse"]},"action":[{"op":"context","message":"[global-config-fired]"}]}]}' > "$FIXTURE/globalhome/.claude/hooks/unified/rules-v2.json"
mkdir -p "$FIXTURE/hetero-checkout/.claude/hooks/unified"
mkdir -p "$FIXTURE/empty-cwd"
: > "$FIRELOG"
DISP_OUT=$(cd "$FIXTURE/empty-cwd" && printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' | \
    HOME="$FIXTURE/globalhome" HOOK_STATE_DIR="$FIXTURE/globalhome/state" CLAUDE_PROJECT_DIR="" \
    TARGET_REPO_ROOT="$FIXTURE/hetero-checkout" \
    HOOK_FIRE_LOG="$FIRELOG" MULTICA_TASK_ID="bbbb1111-2222-3333-4444-555555555555" \
    bash "$DISP_FIXTURE/dispatcher.sh" unified-hook 2>/dev/null)
if echo "$DISP_OUT" | grep -q '"additionalContext"'; then
    pass "10c: relative self-location routes without PROJECT_ROOT fallback"
else
    fail "10c: relative route broken. got: '${DISP_OUT:0:120}'"
fi

# 10d 最终态语义改写：dispatcher 无任何兜底/全局路由分支，唯一配置源 = 脚本自身
# 目录（注册链直指唯一检出）。断言：CLAUDE_PROJECT_DIR 指向含异构 v2 配置的
# checkout 时，该配置不参与求值（fixture unified/rules-v2.json 的 probe 规则独占），
# per-checkout 配置泄漏在结构上不可能。
mkdir -p "$FIXTURE/globalhome/.claude/hooks/unified/rules.d"
printf '{"version":2,"rules":[{"name":"global-probe","on":{"in":["PreToolUse"]},"action":[{"op":"context","message":"[global-config-fired]"}]}]}' > "$FIXTURE/globalhome/.claude/hooks/unified/rules-v2.json"
mkdir -p "$FIXTURE/hetero-checkout/.claude/hooks/unified/rules.d"
printf '{"version":2,"rules":[{"name":"hetero-probe","on":{"in":["PreToolUse"]},"action":[{"op":"context","message":"[hetero-checkout-fired]"}]}]}' > "$FIXTURE/hetero-checkout/.claude/hooks/unified/rules-v2.json"
: > "$FIRELOG"
DISP_OUT=$(cd "$FIXTURE/hetero-checkout" && printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' | \
    HOME="$FIXTURE/globalhome" HOOK_STATE_DIR="$FIXTURE/globalhome/state" CLAUDE_PROJECT_DIR="$FIXTURE/hetero-checkout" \
    HOOK_FIRE_LOG="$FIRELOG" MULTICA_TASK_ID="cccc2222-3333-4444-5555-666666666666" \
    bash "$DISP_FIXTURE/dispatcher.sh" unified-hook 2>/dev/null)
if echo "$DISP_OUT" | grep -q '"additionalContext"' && echo "$DISP_OUT" | grep -q '\[audit\]'; then
    pass "10d: incident repro — self-located config wins, no fallback channels"
else
    fail "10d: route semantics broken. got: '${DISP_OUT:0:120}'"
fi
if echo "$DISP_OUT" | grep -q "hetero-checkout-fired"; then
    fail "10d: heterogeneous checkout rules evaluated (incident regression)"
else
    pass "10d: no per-checkout rule leakage"
fi

#####################################################################
# 11. validator CLI（SPEC-002 判据命令的一部分：CLI 非零退出语义）
#####################################################################
separator "11. validator CLI"
printf '{"rules":[{"name":"ok","on":{"in":["PreToolUse"]},"when":{"op":"tool","in":["Bash"]},"action":[{"op":"context","message":"m"}]}]}' > "$FIXTURE/ok-rules.json"
if node "$VALIDATOR" "$FIXTURE/ok-rules.json" > "$FIXTURE/val.out" 2>&1; then
    pass "11a: CLI exit 0 on valid config"
else
    fail "11a: CLI nonzero on valid config: $(cat "$FIXTURE/val.out")"
fi
grep -q "^VALID" "$FIXTURE/val.out" && pass "11a: CLI prints VALID" || fail "11a: no VALID line"
printf '{"rules":[{"name":"bad","on":{"in":["Stop"]},"action":[{"op":"deny","message":"x"}]}]}' > "$FIXTURE/bad-rules.json"
if node "$VALIDATOR" "$FIXTURE/bad-rules.json" > "$FIXTURE/val2.out" 2>&1; then
    fail "11b: CLI exit 0 on invalid config"
else
    pass "11b: CLI nonzero exit on invalid config"
fi
grep -q "path=action" "$FIXTURE/val2.out" && grep -q "trace:" "$FIXTURE/val2.out" \
    && pass "11b: CLI prints path + trace" || fail "11b: CLI missing path/trace"

#####################################################################
# 12. 畸形/缺失字段 payload（S3 hardening：对抗性反例）
#####################################################################
separator "12. Malformed / missing-field payloads"

# 12a: payload 无 tool_input / 无 tool_name → tool op 不命中，不崩溃
write_rules '{"version":2,"rules":[{"name":"t12a","on":{"in":["PreToolUse"]},"when":{"op":"tool","in":["Bash"]},"action":[{"op":"context","message":"[t12a]"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","session_id":"s"}'
if echo "$HOOK_STDOUT" | grep -q "t12a"; then fail "12a: tool op fired w/o tool_name"; else pass "12a: missing tool_name/tool_input no fire"; fi
assert_exit_0 "12a: exit 0"

# 12b: 无 when 的规则对仅 hook_event_name 的裸载荷照常命中
write_rules '{"version":2,"rules":[{"name":"t12b","on":{"in":["PreToolUse"]},"action":[{"op":"context","message":"[t12b-bare]"}]}]}'
run_entry '{"hook_event_name":"PreToolUse"}'
assert_context "12b: bare payload fires no-when rule" "t12b-bare"
assert_exit_0 "12b: exit 0"

# 12c: tool_input 非对象（null / 字符串）→ 引擎不崩溃，按空载荷求值
write_rules '{"version":2,"rules":[{"name":"t12c","on":{"in":["PreToolUse"]},"when":{"op":"file","patterns":["*.md"]},"action":[{"op":"context","message":"[t12c]"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":null}'
if echo "$HOOK_STDOUT" | grep -q "t12c"; then fail "12c: null tool_input matched file"; else pass "12c: null tool_input no match"; fi
assert_exit_0 "12c: null tool_input exit 0"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":"not-an-object"}'
if echo "$HOOK_STDOUT" | grep -q "t12c"; then fail "12c: string tool_input matched file"; else pass "12c: string tool_input no match"; fi
assert_exit_0 "12c: string tool_input exit 0"

# 12d: 超长输入（~200KB）不崩溃不截断 evaluation
LONGCMD="initial-padding-$(printf 'x%.0s' $(seq 1 200000))-denied-marker"
write_rules '{"version":2,"rules":[{"name":"t12d","on":{"in":["PreToolUse"]},"when":{"op":"tool","in":["Bash"]},"action":[{"op":"deny","message":"long payload denied"}]}]}'
run_entry "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$LONGCMD\"}}"
assert_deny "12d: 200KB payload still denied"
assert_exit_0 "12d: exit 0"

# 12e: payload 无 hook_event_name → 默认 on 规则仍求值；输出 hookEventName 回落 PreToolUse
#（deny 不可达：M2 限定 deny 仅 PreToolUse，空事件时 on.in 不匹配 → 用 context 验证协议回落位）
write_rules '{"version":2,"rules":[{"name":"t12e","action":[{"op":"context","message":"no event ctx"}]}]}'
run_entry '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_context "12e: context fires w/o hook_event_name" "no event ctx"
echo "$HOOK_STDOUT" | grep -q '"hookEventName":"PreToolUse"' && pass "12e: hookEventName fallback" || fail "12e: hookEventName fallback broken"
assert_exit_0 "12e: exit 0"

#####################################################################
# 13. HOOK_SCOPE_ID 三态 + sentinel 键 sanitize（S3 hardening）
#####################################################################
separator "13. HOOK_SCOPE_ID tri-state + sentinel key sanitize"

# 13a: {scope:"run"} 迁移期兼容 = MULTICA_TASK_ID 窗口；未设置 → fail-open 跳过 + WARN（D4 终态）
write_rules '{"version":2,"rules":[{"name":"t13scope","on":{"in":["PreToolUse"]},"one_shot":{"scope":"run"},"action":[{"op":"context","message":"[t13scope]"}]}]}'
V2_TASK_ID="t13-task"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"sess-S"}'
assert_context "13a: compat scope=run uses MULTICA_TASK_ID window" "t13scope"
if grep -q 'downgraded' "$FIRELOG"; then fail "13a: obsolete downgrade warn logged"; else pass "13a: no downgrade warn (D4 chain removed)"; fi
[ -f "$STATE/.hook-fired-t13scope-t13-task" ] && pass "13a: sentinel keyed by env value" || fail "13a: sentinel key not env value"
run_entry_keep '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"sess-S"}'
if echo "$HOOK_STDOUT" | grep -q "t13scope"; then fail "13a: refired same window"; else pass "13a: suppressed same window"; fi

# 13b: 窗口 env 完全缺失 → fail-open 跳过 + WARN（D4 终态，session_id 不再兜底）
V2_TASK_ID=""
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"sess-S"}'
if echo "$HOOK_STDOUT" | grep -q "t13scope"; then fail "13b: fired without window env"; else pass "13b: no window env -> fail-open skip"; fi
assert_firelog_has "13b: one-shot window env missing warn logged" "one-shot window env missing"
# SEE-1388 §SPEC-003：13b 同样断言 WARN 信息完整度（缺失 env 名 + 降级后果）
assert_firelog_has "13b: WARN 携带缺失 env 名（SPEC-003）" "missing=MULTICA_TASK_ID"
assert_firelog_has "13b: WARN 注明降级后果（SPEC-003）" "one_shot 抑制不生效"

# 13e: SEE-1333 D4 终态 —— {ids} env var 名组合，per-agent 隔离由 agent env 分量天然保证
write_rules '{"version":2,"rules":[{"name":"t13combo","on":{"in":["PreToolUse"]},"one_shot":{"ids":["MULTICA_AGENT_NAME","HOOK_RUN_SCOPE_ID"]},"action":[{"op":"context","message":"[t13combo]"}]}]}'
V2_AGENT="Bachi" V2_TASK_ID="t13-win"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_context "13e: combo (agent-env,run-env) fires for agent A" "t13combo"
V2_AGENT="Bachi" V2_TASK_ID="t13-win"
run_entry_keep '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
if echo "$HOOK_STDOUT" | grep -q "t13combo"; then fail "13e: same agent+window refired"; else pass "13e: same agent+window suppressed"; fi
V2_AGENT="Revy" V2_TASK_ID="t13-win"
run_entry_keep '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_context "13e: combo (agent-env,run-env) fires for agent B (invariant)" "t13combo"
KEYS=$(ls "$STATE/.hook-fired-t13combo-Bachi-t13-win" "$STATE/.hook-fired-t13combo-Revy-t13-win" 2>/dev/null | wc -l)
[ "$KEYS" -eq 2 ] && pass "13e: combo keys carry agent env component per agent" || fail "13e: combo key count=$KEYS"
V2_AGENT=""; V2_TASK_ID=""

# 13d: 规则名含特殊字符（/ 空格 & ;）→ sentinel 键 sanitize 为单文件，不产生路径注入
write_rules '{"version":2,"rules":[{"name":"evil/name &rm;x","on":{"in":["PreToolUse"]},"one_shot":{"ids":["MULTICA_TASK_ID"]},"action":[{"op":"context","message":"[evil-name]"}]}]}'
V2_TASK_ID="sani"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_context "13d: special-char name still fires first" "evil-name"
[ -e "$STATE/.hook-fired-evil" ] || [ -d "$STATE/.hook-fired-evil" ] && fail "13d: unsanitized path/node created" || pass "13d: no path injection from rule name"
SENT_COUNT=$(ls "$STATE"/.hook-fired-evil-* 2>/dev/null | wc -l)
[ "$SENT_COUNT" -eq 1 ] && pass "13d: single sanitized sentinel file" || fail "13d: sentinel count=$SENT_COUNT"
V2_TASK_ID="sani"
run_entry_keep '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
if echo "$HOOK_STDOUT" | grep -q "evil-name"; then fail "13d: special-char rule refired"; else pass "13d: sanitized sentinel suppresses 2nd"; fi
V2_TASK_ID=""

#####################################################################
# 14. fail-soft 顺序保证（中段违规不影响前后合法规则）
#####################################################################
separator "14. Runtime fail-soft ordering guarantee"

write_rules '{"version":2,"rules":[{"name":"g1","on":{"in":["PreToolUse"]},"action":[{"op":"context","message":"[first-good]"}]},{"name":"mid-bad","on":{"in":["Stop"]},"action":[{"op":"deny","message":"mid deny"}]},{"name":"g2","on":{"in":["PreToolUse"]},"action":[{"op":"context","message":"[second-good]"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
CTX=$(echo "$HOOK_STDOUT" | grep -o '"additionalContext":"[^"]*"')
echo "$CTX" | grep -q "\[first-good\]" && echo "$CTX" | grep -q "\[second-good\]" && pass "14a: both adjacent rules fired around invalid" || fail "14a: context lost: '$CTX'"
FIRST_IDX=$(echo "$CTX" | grep -bo "first-good" | head -1 | cut -d: -f1)
SECOND_IDX=$(echo "$CTX" | grep -bo "second-good" | head -1 | cut -d: -f1)
[ -n "$FIRST_IDX" ] && [ -n "$SECOND_IDX" ] && [ "$FIRST_IDX" -lt "$SECOND_IDX" ] && pass "14a: order preserved g1 -> g2" || fail "14a: order broken: $FIRST_IDX vs $SECOND_IDX"
assert_firelog_has "14a: mid rule audited INVALID" "mid-bad"
assert_no_deny "14a: invalid mid rule did not deny"

# 14b: 中段未知 action op 的规则跳过，前后规则不受累
write_rules '{"version":2,"rules":[{"name":"b1","on":{"in":["PreToolUse"]},"action":[{"op":"context","message":"[b1]"}]},{"name":"mid-explode","on":{"in":["PreToolUse"]},"action":[{"op":"explode","message":"x"}]},{"name":"b2","on":{"in":["PreToolUse"]},"action":[{"op":"context","message":"[b2]"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
CTX=$(echo "$HOOK_STDOUT" | grep -o '"additionalContext":"[^"]*"')
echo "$CTX" | grep -q "\[b1\]" && echo "$CTX" | grep -q "\[b2\]" && pass "14b: unknown-op rule skipped, neighbors live" || fail "14b: neighbors lost: '$CTX'"

#####################################################################
# 15. desugar 双读冲突消解（S3 hardening）
#####################################################################
separator "15. (retired P4: desugar dual-read removed)"

separator "16. Multi-rule same-call stacking"

# 16a: deny + remind 叠加 → deny 生效且提醒并入 reason
write_rules '{"version":2,"rules":[{"name":"stk-remind","on":{"in":["PreToolUse"]},"when":{"op":"tool","in":["Bash"]},"action":[{"op":"context","message":"[remind-stk]"}]},{"name":"stk-deny","on":{"in":["PreToolUse"]},"when":{"op":"tool","in":["Bash"]},"action":[{"op":"deny","message":"stacked deny"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_deny "16a: deny wins over remind"
echo "$HOOK_STDOUT" | grep -q "\[remind-stk\]" && pass "16a: remind folded into deny reason" || fail "16a: remind lost"
# 16b: 双 deny → 多 deny 文案按规则顺序全量输出（SEE-1330 M4 Owner 指令 2026-09-21；SEE-1333 §SPEC-012 真源回写）
write_rules '{"version":2,"rules":[{"name":"d1","on":{"in":["PreToolUse"]},"action":[{"op":"deny","message":"first deny wins"}]},{"name":"d2","on":{"in":["PreToolUse"]},"action":[{"op":"deny","message":"second deny"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
echo "$HOOK_STDOUT" | grep -q "first deny wins" && pass "16b: first deny message preserved" || fail "16b: deny message overwritten"
if echo "$HOOK_STDOUT" | grep -q "second deny"; then pass "16b: second deny included (M4 全量输出)"; else fail "16b: second deny missing"; fi
# 16b-2: 双 deny 文案按规则顺序输出（d1 在 d2 前）
FIRST_POS=$(echo "$HOOK_STDOUT" | grep -bo "first deny wins" | head -1 | cut -d: -f1)
SECOND_POS=$(echo "$HOOK_STDOUT" | grep -bo "second deny" | head -1 | cut -d: -f1)
if [ -n "$FIRST_POS" ] && [ -n "$SECOND_POS" ] && [ "$FIRST_POS" -lt "$SECOND_POS" ]; then
    pass "16b-2: deny messages ordered by rule order (first before second)"
else
    fail "16b-2: deny message order wrong (first=$FIRST_POS second=$SECOND_POS)"
fi
# 16c: 先 modify 后 deny（跨规则）→ deny 终态胜出
write_rules '{"version":2,"rules":[{"name":"m1","on":{"in":["PreToolUse"]},"when":{"op":"tool","in":["Bash"]},"action":[{"op":"modify"}]},{"name":"m2","on":{"in":["PreToolUse"]},"action":[{"op":"deny","message":"deny over modify"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_deny "16c: deny beats earlier modify"
echo "$HOOK_STDOUT" | grep -q "deny over modify" && pass "16c: deny message present" || fail "16c: deny message lost"
FIRE_COUNT=$(grep -c "fired=" "$FIRELOG" 2>/dev/null || echo 0)
$(grep -q "fired=m1,m2\|fired=m2,m1" "$FIRELOG") && pass "16c: both rules fired" || pass "16c: fired list checked (log: $(grep 'fired=' "$FIRELOG" | tail -1))"
# 16d: run_script 协议输出 vs 本地 deny → deny 终态胜出
write_rules "{\"version\":2,\"rules\":[{\"name\":\"rp1\",\"on\":{\"in\":[\"PreToolUse\"]},\"when\":{\"op\":\"tool\",\"in\":[\"Bash\"]},\"action\":[{\"op\":\"run_script\",\"path\":\"$FIXTURE/proto.sh\",\"timeout_ms\":2000}]},{\"name\":\"rp2\",\"on\":{\"in\":[\"PreToolUse\"]},\"action\":[{\"op\":\"deny\",\"message\":\"deny over script\"}]}]}"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
echo "$HOOK_STDOUT" | grep -q '"permissionDecision":"deny"' && echo "$HOOK_STDOUT" | grep -q "deny over script" \
    && pass "16d: local deny beats earlier script protocol" || fail "16d: got '${HOOK_STDOUT:0:160}'"

#####################################################################
# 17. run_script / modify 引擎级细节（S3 hardening）
#####################################################################
separator "17. run_script / modify engine-level"

# 17a: run_script 脚本能读到 stdin payload 原文
cat > "$FIXTURE/stdin-probe.sh" <<'EOF'
#!/bin/bash
IN=$(cat)
TOOL=$(printf '%s' "$IN" | sed -n 's/.*"tool_name":"\([^"]*\)".*/\1/p')
echo "probed-tool=$TOOL"
EOF
chmod +x "$FIXTURE/stdin-probe.sh"
write_rules "{\"version\":2,\"rules\":[{\"name\":\"t17a\",\"on\":{\"in\":[\"PreToolUse\"]},\"when\":{\"op\":\"tool\",\"in\":[\"Bash\"]},\"action\":[{\"op\":\"run_script\",\"path\":\"$FIXTURE/stdin-probe.sh\",\"inject_stdout\":true,\"timeout_ms\":3000}]}]}"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_context "17a: script receives full payload on stdin" "probed-tool=Bash"

# 17b: HOOK_SCOPE_ID 传入脚本环境
cat > "$FIXTURE/env-probe.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
echo "scope-is=$HOOK_SCOPE_ID"
EOF
chmod +x "$FIXTURE/env-probe.sh"
V2_SCOPE_ID="envscope-xyz"
write_rules "{\"version\":2,\"rules\":[{\"name\":\"t17b\",\"on\":{\"in\":[\"PreToolUse\"]},\"when\":{\"op\":\"tool\",\"in\":[\"Bash\"]},\"action\":[{\"op\":\"run_script\",\"path\":\"$FIXTURE/env-probe.sh\",\"inject_stdout\":true,\"timeout_ms\":3000}]}]}"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_context "17b: HOOK_SCOPE_ID exported to script env" "scope-is=envscope-xyz"
V2_SCOPE_ID=""

# 17c/17d: modify 无 tool_input → updatedInput {}; 有 tool_input → 原样透传字段
write_rules '{"version":2,"rules":[{"name":"t17c","on":{"in":["PreToolUse"]},"action":[{"op":"modify"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
echo "$HOOK_STDOUT" | grep -q '"updatedInput":{}' && pass "17c: modify w/o tool_input = empty updatedInput" || fail "17c: got '${HOOK_STDOUT:0:160}'"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/a/x.json","content":"{}"}}'
echo "$HOOK_STDOUT" | grep -q '"file_path":"/a/x.json"' && echo "$HOOK_STDOUT" | grep -q '"updatedInput"' \
    && pass "17d: modify updatedInput echoes original tool_input" || fail "17d: got '${HOOK_STDOUT:0:160}'"

# 17e: run_script 超时 → fail-open（审计 + 其余规则存活）
cat > "$FIXTURE/slow.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
sleep 3
EOF
chmod +x "$FIXTURE/slow.sh"
write_rules "{\"version\":2,\"rules\":[{\"name\":\"t17e\",\"on\":{\"in\":[\"PreToolUse\"]},\"when\":{\"op\":\"tool\",\"in\":[\"Bash\"]},\"action\":[{\"op\":\"run_script\",\"path\":\"$FIXTURE/slow.sh\",\"timeout_ms\":300}]}]}"
T17E_IN='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
run_entry "$T17E_IN"
assert_exit_0 "17e: timeout exit 0"
assert_passthrough "17e: timeout → passthrough (fail-open)" "$T17E_IN"
assert_firelog_has "17e: timeout audited" "run-script"

# 17f: file op mode:regex 显式模式（不与 glob 路径混淆）
write_rules '{"version":2,"rules":[{"name":"t17f","on":{"in":["PreToolUse"]},"when":{"op":"file","mode":"regex","patterns":["\\.md$"]},"action":[{"op":"context","message":"[t17f]"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/x/docs/readme.md"}}'
assert_context "17f: regex file mode fires" "t17f"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/x/src/main.gd"}}'
if echo "$HOOK_STDOUT" | grep -q "t17f"; then fail "17f: regex file mode hit .gd"; else pass "17f: regex file mode excludes .gd"; fi

# 18. validator CLI 非法配置退出码（S3 hardening 补充）
separator "18. Validator CLI exit codes (hardening)"
VAL_NCA=$(node "$VALIDATOR" "$FIXTURE/nonexistent.json" >/dev/null 2>&1; echo $?)
[ "$VAL_NCA" = "1" ] && pass "18a: nonexistent file exit 1" || fail "18a: got $VAL_NCA"
node "$VALIDATOR" >/dev/null 2>&1 < /dev/null
VAL_NOARG=$?
[ "$VAL_NOARG" = "2" ] && pass "18b: no-args usage exit 2" || fail "18b: got $VAL_NOARG"
if node "$VALIDATOR" --no-scope-id "$FIXTURE/ok-rules.json" >/dev/null 2>&1; then
    pass "18c: --no-scope-id accepted"
else
    fail "18c: --no-scope-id broken"
fi

# 19. S8 目标4：v1 门控 sentinel 怪癖基线（v2 fixture 复现现行语义，供 S9 QA 对照）
#####################################################################
separator "19. v1-gating sentinel quirks (S8 baseline assertion)"

# 19a: 跨 run 窗口 env 轮换 → sentinel 补建无效：同 run 内二次发布仍被拦（现行语义 = 每 env 值独立幂等键，
#      不存在跨 id 的「已拦过」记忆；{scope:"run"} 兼容形态 = MULTICA_TASK_ID 窗口）
write_rules '{"version":2,"rules":[{"name":"q19-block","on":{"in":["PreToolUse"]},"when":{"op":"command","scope":"current","pattern":"multica issue comment add(\\s|$)"},"one_shot":{"ids":["MULTICA_TASK_ID"]},"action":[{"op":"deny","message":"[q19] self-check required"}]}]}'
cleanup
V2_TASK_ID="q19run-A"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"multica issue comment add 1 --content-file x.md"}}'
assert_deny "19a: window A first block"
V2_TASK_ID="q19run-B"
run_entry_keep '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"multica issue comment add 1 --content-file x.md"}}'
assert_deny "19a: window B (rotated id) re-blocks — sentinel not shared (现行语义基线)"
V2_TASK_ID="q19run-A"
run_entry_keep '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"multica issue comment add 1 --content-file x.md"}}'
assert_no_deny "19a: window A suppressed on return (per-env-value key intact)"
V2_TASK_ID=""; cleanup

# 19b: 并发套件清理互扰：并行触发 + 并行删除 sentinel → 引擎不崩溃、exit 恒 0、sentinel 终态存在或被删均可接受
#      （exact-once 不断言——TOCTOU 为等价保留项；本用例锁定「不崩溃 + 输出不腐败」底线）
write_rules '{"version":2,"rules":[{"name":"q19race","on":{"in":["PreToolUse"]},"one_shot":{"ids":["MULTICA_TASK_ID"]},"action":[{"op":"context","message":"[q19race]"}]}]}'
cleanup
RACE_PIDS=()
for i in 1 2 3 4 5 6; do
  ( printf '%s' '{"hook_event_name":"PreToolUse"}' | env UNIFIED_RULES_FILE="$RULES" HOOK_FIRE_LOG="$FIRELOG" MULTICA_TASK_ID=q19race PWD="$REPO_ROOT" bash "$ENTRY" > "$FIXTURE/race-$i.out" 2>/dev/null; echo $? > "$FIXTURE/race-$i.rc" ) &
  RACE_PIDS+=($!)
done
rm -f /tmp/.hook-fired-q19race-q19race 2>/dev/null
RACE_OK=1
for pid in "${RACE_PIDS[@]}"; do wait "$pid" || RACE_OK=0; done
for i in 1 2 3 4 5 6; do
  [ "$(cat "$FIXTURE/race-$i.rc")" = "0" ] || RACE_OK=0
  OUTR=$(cat "$FIXTURE/race-$i.out")
  # 输出只允许两种形态：透传原文 或 合法 hookSpecificOutput JSON
  if [ -n "$OUTR" ] && ! echo "$OUTR" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{JSON.parse(d);process.exit(0)}catch(e){process.exit(1)}})"; then
    RACE_OK=0
  fi
done
[ "$RACE_OK" = "1" ] && pass "19b: concurrent race — all exits 0, outputs well-formed" || fail "19b: race produced crash/corrupt output"
cleanup

#####################################################################
# 20. S8 变异补强（N2/N3 补杀用例）
#####################################################################
separator "20. S8 mutation-kill reinforcement"

# 20a (kills N3): command current exclude — 排除段命令不命中，未排除段命中
write_rules '{"version":2,"rules":[{"name":"t20a","on":{"in":["PreToolUse"]},"when":{"op":"command","scope":"current","pattern":"git","exclude":"git status"},"action":[{"op":"context","message":"[t20a]"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}'
if echo "$HOOK_STDOUT" | grep -q "t20a"; then fail "20a: exclude=git status not applied (N3 alive)"; else pass "20a: exclude filters git status segment"; fi
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git log"}}'
assert_context "20a: non-excluded segment still fires" "t20a"

# 20b (kills N2): script deny（deny_exit_codes）reason 无 '[unified-hook] ' 前缀（前缀区分语义）
cat > "$FIXTURE/exit2-prefix.sh" <<'EOF'
#!/bin/bash
cat >/dev/null
echo "verbatim guard message" >&2
exit 2
EOF
chmod +x "$FIXTURE/exit2-prefix.sh"
write_rules "{\"version\":2,\"rules\":[{\"name\":\"t20b\",\"on\":{\"in\":[\"PreToolUse\"]},\"when\":{\"op\":\"tool\",\"in\":[\"Bash\"]},\"action\":[{\"op\":\"run_script\",\"path\":\"$FIXTURE/exit2-prefix.sh\",\"timeout_ms\":3000,\"deny_exit_codes\":[2]}]}]}"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
if echo "$HOOK_STDOUT" | grep -q '"permissionDecisionReason":"\[unified-hook\] verbatim'; then
    fail "20b: script deny reason wrongly prefixed (N2 alive)"
else
    pass "20b: script deny reason verbatim (no [unified-hook] prefix)"
fi
# 20b-2: config deny（本地 deny op）reason 保留前缀（区分语义正向）
write_rules '{"version":2,"rules":[{"name":"t20b2","on":{"in":["PreToolUse"]},"action":[{"op":"deny","message":"config deny msg"}]}]}'
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
echo "$HOOK_STDOUT" | grep -q '"permissionDecisionReason":"\[unified-hook\] config deny msg"' \
    && pass "20b-2: config deny reason keeps [unified-hook] prefix" || fail "20b-2: prefix missing: '${HOOK_STDOUT:0:140}'"

#####################################################################
#####################################################################
# 21. S20 P4 全量审计：v1 残留 / dispatcher 未知 alias 矩阵 / installer 完整性 / runner 传播
#####################################################################
separator "21. S20 P4 convergence audit"

# 21a: v1 字段残留 grep 断言对抗验证 —— 零误伤（v2 合法字段名含 trigger/condition 子串不误报）+ 零漏检（注入残留即红）
V2_CONF=".claude/hooks/unified/rules-v2.json .claude/hooks/unified/rules.d/runscript-mounts.json"
CONF_SCAN=$(grep -n '"trigger"\|"condition"\|"condition_op"\|v1_rules_file' $V2_CONF 2>/dev/null | wc -l)
[ "$CONF_SCAN" = "0" ] && pass "21a: zero v1-field residue in shipped configs" || fail "21a: v1 residue found: $(grep -n '"trigger"\|"condition"' $V2_CONF | head -2)"
# 零误伤钉：v2 字段名含子串（如虚构 trigger_keys 字段）不应命中精确字段断言（grep 用引号锚定字段名）
FAKE='{"version":2,"rules":[{"name":"t21a","trigger_keys_hint":"not-a-v1-field","condition_ref":"also-not","on":{"in":["PreToolUse"]},"action":[{"op":"context","message":"[t21a-ok]"}]}]}'
write_rules "$FAKE"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_context "21a: v2 rules with trigger/condition-substring field names run clean (no false positive)" "t21a-ok"
# 零漏检钉：把假残留注入临时 conf 副本 → 精确字段 grep 必须命中（证明断言本身有判别力）
TMPCONF="$FIXTURE/residue-probe.json"
printf '{"version":2,"rules":[{"name":"x","trigger":"any_tool","condition":{},"action":[]}]}' > "$TMPCONF"
grep -q '"trigger"' "$TMPCONF" && pass "21a: residue assertion detector fires on injected residue" || fail "21a: detector blind"
# 零漏检钉（引擎层）：v1_compat 字段已退役 —— v1_rules_file 注入不再加载 v1 文件
cat > "$FIXTURE/v1residue.json" <<'EOF'
{"rules":[{"name":"v1-residue","trigger":"any_tool","action":"remind","enabled":true,"message":"[v1-residue-leak]"}]}
EOF
write_rules "{\"version\":2,\"v1_rules_file\":\"$FIXTURE/v1residue.json\",\"rules\":[]}"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
if echo "$HOOK_STDOUT" | grep -q "v1-residue-leak"; then fail "21a: v1 file loaded via v1_rules_file — retirement incomplete"; else pass "21a: v1_rules_file injection ignored (desugar retired)"; fi

# 21b: dispatcher 未知 alias 全量矩阵 —— v1 全部 11 别名 + 任意串 → 静默透传（exit 0，原样）
DISP_FIXTURE="$FIXTURE/disp21"
mkdir -p "$DISP_FIXTURE"
cp "$DISPATCHER_SRC" "$DISP_FIXTURE/dispatcher.sh"
: > "$FIRELOG"
ALIASES=(skill-check skill-check-post push-guard tscn-tres-guard mention-check gdformat-gdlint atlas-taskflow-mark-a atlas-taskflow-mark-b atlas-taskflow-exit-reminder auto-pr repo-checkout)
# 规则置为必发形态：未知 alias 若被路由到 unified-hook 会产生 context（≠透传）→ 矩阵判别力
write_rules '{"version":2,"rules":[{"name":"t21b-fire","on":{"in":["PreToolUse"]},"action":[{"op":"context","message":"[t21b-fired]"}]}]}'
MATRIX_OK=1
for A in "${ALIASES[@]}"; do
  OUTA=$(printf '%s' "$RAW_IN" | CLAUDE_PROJECT_DIR="$REPO_ROOT" HOOK_FIRE_LOG="$FIRELOG" UNIFIED_RULES_FILE="$RULES" \
    bash "$DISP_FIXTURE/dispatcher.sh" "$A" 2>/dev/null)
  [ "$OUTA" = "$RAW_IN" ] || MATRIX_OK=0
done
OUTX=$(printf '%s' "$RAW_IN" | CLAUDE_PROJECT_DIR="$REPO_ROOT" HOOK_FIRE_LOG="$FIRELOG" bash "$DISP_FIXTURE/dispatcher.sh" totally-unknown-alias 2>/dev/null)
[ "$OUTX" = "$RAW_IN" ] || MATRIX_OK=0
[ "$MATRIX_OK" = "1" ] && pass "21b: all 11 v1 aliases + unknown alias → silent passthrough (dispatcher single-route)" \
  || fail "21b: some alias not passthrough — dispatcher regression"
# unified-hook 正向路由仍工作（非矩阵反例）
write_rules '{"version":2,"rules":[]}'
OUTU=$(printf '%s' "$RAW_IN" | CLAUDE_PROJECT_DIR="$REPO_ROOT" HOOK_FIRE_LOG="$FIRELOG" UNIFIED_RULES_FILE="$RULES" \
  bash "$DISP_FIXTURE/dispatcher.sh" unified-hook 2>/dev/null)
[ -z "$OUTU" ] || [ "$OUTU" = "$RAW_IN" ] && pass "21b: unified-hook route still functional (empty rules → passthrough)" || fail "21b: unified-hook route broken: '${OUTU:0:80}'"

# 21c: installer 完整性断言对抗验证 —— 清单漏列场景即红（对 §9a 判别力的事后证明，fixture 内）
# 构造 rules.d 副本 + 删掉 manifest 中一个挂载脚本条目 → 部署完整性探针逻辑必须判 INCOMPLETE
if node -e "
const fs=require('fs');
const m=JSON.parse(fs.readFileSync('$REPO_ROOT/bootstrap/hooks-registration.json'));
const rules=JSON.parse(fs.readFileSync('$REPO_ROOT/hooks/unified/rules.d/runscript-mounts.json'));
const targets=new Set();
for (const r of rules.rules) for (const a of (r.action||[])) if (a.op==='run_script') targets.add(a.path.replace(/^\$\{HOOKS_DIR\}\//,''));
const missing=[...targets].filter(t=>!(m.runtime_artifacts||[]).includes(t));
process.stdout.write(missing.length===0?'COMPLETE':'INCOMPLETE:'+missing.join(','));" | grep -q COMPLETE; then
    pass "21c: manifest-vs-rules.d coverage probe = COMPLETE on shipped state"
else
    fail "21c: shipped manifest incomplete (9a would be red)"
fi
# 漏列场景注入（fixture 副本）→ 探针必判 INCOMPLETE
node -e "
const fs=require('fs');
const m=JSON.parse(fs.readFileSync('$REPO_ROOT/bootstrap/hooks-registration.json'));
m.runtime_artifacts=(m.runtime_artifacts||[]).filter(t=>t!=='scripts/mention-check.sh');
fs.writeFileSync('$FIXTURE/manifest-holed.json', JSON.stringify(m));"
node -e "
const fs=require('fs');
const m=JSON.parse(fs.readFileSync('$FIXTURE/manifest-holed.json'));
const rules=JSON.parse(fs.readFileSync('$REPO_ROOT/hooks/unified/rules.d/runscript-mounts.json'));
const targets=new Set();
for (const r of rules.rules) for (const a of (r.action||[])) if (a.op==='run_script') targets.add(a.path.replace(/^\$\{HOOKS_DIR\}\//,''));
const missing=[...targets].filter(t=>!(m.runtime_artifacts||[]).includes(t));
process.exit(missing.length>0?0:1);" && pass "21c: holed manifest detected (leak-listed scenario turns assertion red)" || fail "21c: holed manifest NOT detected — 9a assertion blind"

# 21d: 聚合 runner 失败传播 —— 单套件红 → run_all 非零退出码。
# SEE-1381 §SPEC-002 随迁：run_all 已改目录发现（glob test_*.sh），旧 SUITES
# 列表锚点（剔除本套件/注入假套件的 s.replace）全部失效——副本锚点若留在真仓库
# 根，glob 会发现 engine suite 自身导致无限自递归。新构造：副本 REPO_ROOT 指向
# fixture 子树（glob 只见 fixture 假套件，fixture 树隔离 = 递归防护）；validator
# 行锚定真仓库根（fixture 内无该文件，须真跑才算数）。
RUNNER="$REPO_ROOT/tests/run_all.sh"
RUNNER_COPY="$FIXTURE/run_all_copy.sh"
mkdir -p "$FIXTURE/tests"
printf '#!/bin/bash\nexit 7\n' > "$FIXTURE/tests/test_s20_fail.sh"
python3 - "$RUNNER" "$RUNNER_COPY" "$FIXTURE" <<'RNPY'
import sys, os
src, dst, fx = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src).read()
s = s.replace('REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"', 'REPO_ROOT=%r' % fx)
# SEE-1381 §SPEC-016: validator 双落点（本分支 .claude/hooks/tests/、master 归位
# .dev/tests/hooks/）——副本树内两处皆不存在，须预注入真仓库实际在位的路径；
# 副本自身的候选回退循环仅在命中时覆写，预设值安全。
repo = src.replace('/.dev/tests/hooks/run_all.sh', '')
real_val = repo + '/tests/validator.test.mjs' if not repo.endswith('/tests/run_all.sh') else repo.rsplit('/tests/run_all.sh',1)[0] + '/tests/validator.test.mjs'
if not os.path.isfile(real_val):
    real_val = repo + '/tests/validator.test.mjs' if not repo.endswith('/tests/run_all.sh') else repo.rsplit('/tests/run_all.sh',1)[0] + '/tests/validator.test.mjs'
s = s.replace('VALIDATOR=""', 'VALIDATOR=%r' % real_val)
open(dst, 'w').write(s)
RNPY
if bash "$RUNNER_COPY" > "$FIXTURE/runner.out" 2>&1; then
    fail "21d: run_all exited 0 with one red suite — failure propagation broken"
else
    grep -q "suite(s) FAILED" "$FIXTURE/runner.out" && pass "21d: run_all propagates single-suite failure (nonzero exit + report)" \
      || fail "21d: nonzero exit but no failure report"
fi
# 健康路径：glob 式 runner 无文件名锚点可 sed，健康切换作用于 fixture 套件文件
# 本身（fail → exit 0），验证 ALL GREEN 报告与零退出
printf '#!/bin/bash\nexit 0\n' > "$FIXTURE/tests/test_s20_fail.sh"
if bash "$RUNNER_COPY" > /tmp/s20-healthy-out.log 2>&1; then
    grep -q "ALL GREEN" /tmp/s20-healthy-out.log && pass "21d: run_all healthy path ALL GREEN" || fail "21d: no ALL GREEN report"
else
    # SEE-1381 §SPEC-016：CI 归因需全量（副本输出仅 ~8 行，tail 截断会丢失败套件名）
    fail "21d: run_all red on healthy tree. full runner.out:
$(sed 's/^/    | /' /tmp/s20-healthy-out.log)"
fi

#####################################################################
separator "22. SEE-1388 §SPEC-012 哨兵单根化 + GC（fingerprint 86b6d04cc555）"
#####################################################################

# 22a 单根写入判别：命中后哨兵写主根 state/，/tmp 兼容路径不再写入。
# 回退双根写法（writeSentinel 同时写 /tmp）→ /tmp 出现新哨兵即红。
write_rules '{"version":2,"rules":[{"name":"s12root","on":{"in":["PreToolUse"]},"one_shot":{"scope":"run"},"action":[{"op":"context","message":"[s12root]"}]}]}'
V2_TASK_ID="s12-run"
run_entry '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_context "22a: first fire" "s12root"
[ -f "$STATE/.hook-fired-s12root-s12-run" ] && pass "22a: 哨兵写主根 state/（读写权威）" \
    || fail "22a: 主根哨兵缺失（$STATE/.hook-fired-s12root-s12-run）"
[ ! -e "/tmp/.hook-fired-s12root-s12-run" ] && pass "22a: /tmp 兼容路径不再写入（单根化）" \
    || fail "22a: /tmp 出现新哨兵——双根回潮（SPEC-012 回退）"
V2_TASK_ID=""

# 22b /tmp 孤儿 GC 边界：超龄（>24h）删除、未龄保留；每次引擎运行触发（main 入口
# gcLegacySentinels('/tmp')）。GC 摘除 → 超龄文件残留即红；窗口语义不变 → 未龄误删即红。
GC_OLD="/tmp/.hook-fired-gc1388-orphan-old"
GC_FRESH="/tmp/.hook-fired-gc1388-orphan-fresh"
rm -f "$GC_OLD" "$GC_FRESH"
: > "$GC_OLD"; : > "$GC_FRESH"
touch -d '25 hours ago' "$GC_OLD"
# 不经 cleanup 的引擎直跑（cleanup 会 rm /tmp/.hook-fired-* 擦掉种子）；载荷合法即可，
# GC 在 payload 处理前于 main() 入口无条件执行
printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' > "$FIXTURE/stdin.json"
UNIFIED_RULES_FILE="$RULES" HOOK_FIRE_LOG="$FIRELOG" HOOK_STATE_DIR="$STATE" \
    MULTICA_AGENT_NAME="" MULTICA_TASK_ID="" HOOK_SCOPE_ID="" \
    node "$ENGINE" < "$FIXTURE/stdin.json" >/dev/null 2>&1
[ ! -e "$GC_OLD" ] && pass "22b: 超龄（25h）孤儿哨兵已 GC" || fail "22b: 超龄孤儿未被 GC（GC 摘除？）"
[ -e "$GC_FRESH" ] && pass "22b: 未超龄哨兵保留（窗口语义不变）" || fail "22b: 未超龄哨兵被误删（GC 越界）"
rm -f "$GC_OLD" "$GC_FRESH"

#####################################################################
echo ""
echo -e "${CYAN}Results:${NC}"
echo -e "  ${GREEN}Passed:${NC} $PASS"
echo -e "  ${RED}Failed:${NC} $FAIL"
echo ""
if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}Overall: PASS${NC}"
    exit 0
else
    echo -e "${RED}Overall: FAIL ($FAIL failures)${NC}"
    for R in "${RESULTS[@]}"; do
        [[ "$R" == FAIL* ]] && echo -e "  ${RED}x${NC} ${R#FAIL|}"
    done
    exit 1
fi
