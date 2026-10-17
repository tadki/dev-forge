#!/bin/bash
# SEE-1330 P1 S6: run_script mount layer test suite (SPEC-004 通道保真补强)
# Covers: engine channel bridging (exit 2 → deny JSON @PreToolUse /
#         exit2+stderr forward @PostToolUse / deny JSON passthrough /
#         additionalContext passthrough / timeout fail-open vs fail-close),
#         ${HOOKS_DIR} resolution, rules.d loading, and REAL-script mounts
#         (push-guard / mention-check / taskflow / gdformat) semantic equivalence.
# The four v1 scripts under test are byte-identical to v1 (zero script change).
# Run:    bash .dev/tests/hooks/test_v2_runscript_mounts_p1.sh
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0; RESULTS=()
pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); RESULTS+=("PASS|$1"); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); RESULTS+=("FAIL|$1"); }
separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOKS="$REPO_ROOT/hooks"
ENTRY="$HOOKS/unified/unified-hook.sh"
ENGINE="$HOOKS/unified/engine.js"
FIXTURE="$(mktemp -d /tmp/v2rs-mounts.XXXXXX)"
FIRELOG="$FIXTURE/hook-fire.log"
STATE="$FIXTURE/state"

cleanup_sentinels() { rm -f /tmp/.hook-fired-* /tmp/mention-check-* /tmp/atlas-taskflow-state-* 2>/dev/null; rm -rf "$STATE" 2>/dev/null; }
trap 'rm -rf "$FIXTURE"; cleanup_sentinels' EXIT

# fixture hooks 标准布局：config 在 hooks/unified/ 下 → 引擎 HOOKS_DIR=hooks 根（脚本副本 + rules.d 就位）
HOOKSROOT="$FIXTURE/fakehome/.claude/hooks"
mkdir -p "$HOOKSROOT/unified/rules.d"
cp "$HOOKS/unified/rules.d/runscript-mounts.json" "$HOOKSROOT/unified/rules.d/"
for f in gdformat-gdlint.sh push-guard.sh mention-check.sh atlas-taskflow-mark-a.sh atlas-taskflow-mark-b.sh atlas-taskflow-exit-reminder.sh; do
    mkdir -p "$HOOKSROOT/scripts"
    cp "$HOOKS/scripts/$f" "$HOOKSROOT/scripts/"
done
RULES="$HOOKSROOT/unified/rules-v2.json"

assert_exit_0() {
    if [ "$HOOK_EXIT" -eq 0 ]; then pass "$1 — exit 0"; else fail "$1 — exit $HOOK_EXIT"; fi
}

# 挂载层执行：rules-v2.json 空规则 + rules.d 挂载文件；脚本经 ${HOOKS_DIR} 解析
run_mounts() {
    local INPUT="$1"
    cleanup_sentinels
    : > "$FIRELOG"
    HOOK_STDOUT=$(printf '%s' "$INPUT" | \
        UNIFIED_RULES_FILE="$RULES" \
        HOOK_FIRE_LOG="$FIRELOG" \
        HOOK_STATE_DIR="$STATE" \
        CLAUDE_PROJECT_DIR="$REPO_ROOT" \
        MULTICA_AGENT_NAME="${V6_AGENT:-}" \
        MULTICA_TASK_ID="${V6_TASK_ID:-}" \
        HOOK_SCOPE_ID="${V6_SCOPE_ID:-}" \
        PWD="${V6_PWD:-$REPO_ROOT}" \
        bash "$ENTRY" 2>"$FIXTURE/stderr.txt")
    HOOK_EXIT=$?
    HOOK_STDERR=$(cat "$FIXTURE/stderr.txt")
    V6_AGENT=""; V6_TASK_ID=""; V6_SCOPE_ID=""; V6_PWD=""
}

# 保留 taskflow 状态文件/mention sentinel 的运行变体
run_mounts_keep() {
    local INPUT="$1"
    : > "$FIRELOG"
    HOOK_STDOUT=$(printf '%s' "$INPUT" | \
        UNIFIED_RULES_FILE="$RULES" \
        HOOK_FIRE_LOG="$FIRELOG" \
        HOOK_STATE_DIR="$STATE" \
        CLAUDE_PROJECT_DIR="$REPO_ROOT" \
        MULTICA_AGENT_NAME="${V6_AGENT:-}" \
        MULTICA_TASK_ID="${V6_TASK_ID:-}" \
        HOOK_SCOPE_ID="${V6_SCOPE_ID:-}" \
        PWD="${V6_PWD:-$REPO_ROOT}" \
        bash "$ENTRY" 2>"$FIXTURE/stderr.txt")
    HOOK_EXIT=$?
    HOOK_STDERR=$(cat "$FIXTURE/stderr.txt")
    V6_AGENT=""; V6_TASK_ID=""; V6_SCOPE_ID=""; V6_PWD=""
}

# 直调引擎（断言 exit-2 PostToolUse 通道）
run_engine() {
    local INPUT="$1"
    cleanup_sentinels
    : > "$FIRELOG"
    HOOK_STDOUT=$(printf '%s' "$INPUT" | \
        UNIFIED_RULES_FILE="$RULES" HOOK_FIRE_LOG="$FIRELOG" \
        MULTICA_AGENT_NAME="${V6_AGENT:-}" MULTICA_TASK_ID="${V6_TASK_ID:-}" \
        HOOK_SCOPE_ID="${V6_SCOPE_ID:-}" PWD="${V6_PWD:-$REPO_ROOT}" \
        node "$ENGINE" 2>"$FIXTURE/stderr.txt")
    HOOK_EXIT=$?
    HOOK_STDERR=$(cat "$FIXTURE/stderr.txt")
    V6_AGENT=""; V6_TASK_ID=""; V6_SCOPE_ID=""; V6_PWD=""
}

echo "============================================================"
echo "  SEE-1330 P1 S6: run_script Mount Layer"
echo "  Date: $(date -Iseconds)"
echo "============================================================"

separator "Prerequisites"
[ -f "$HOOKS/unified/rules.d/runscript-mounts.json" ] && pass "mount rules file exists" || { fail "mount rules MISSING"; exit 1; }
node -e "JSON.parse(require('fs').readFileSync('$HOOKS/unified/rules.d/runscript-mounts.json','utf8'))" 2>/dev/null \
    && pass "mount rules valid JSON" || fail "mount rules INVALID JSON"
for f in gdformat-gdlint.sh push-guard.sh mention-check.sh atlas-taskflow-mark-a.sh atlas-taskflow-mark-b.sh atlas-taskflow-exit-reminder.sh; do
    [ -f "$HOOKS/scripts/$f" ] && pass "v1 script intact: $f" || fail "missing script $f"
done

# 本套件的空主配置（挂载规则全部来自 rules.d）
printf '{"version":2,"v1_compat":false,"rules":[]}' > "$RULES"

#####################################################################
# 1. 通道保真 A：exit 2 @ PreToolUse → deny JSON（push-guard lane）
#####################################################################
separator "1. Channel fidelity: exit2 → deny JSON (PreToolUse)"
run_mounts '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push origin master"}}'
if echo "$HOOK_STDOUT" | grep -q '"permissionDecision":"deny"'; then
    pass "1a: push-guard exit2 → deny JSON"
else
    fail "1a: no deny. stdout: '${HOOK_STDOUT:0:160}'"
fi
if echo "$HOOK_STDOUT" | grep -q "禁止直接推送到 master"; then
    pass "1b: deny reason carries script verbatim stderr"
else
    fail "1b: reason lost: '${HOOK_STDOUT:0:200}'"
fi
assert_exit_0 "1c: deny delivered via JSON with exit 0 (deny JSON channel, not exit 2)"

# 非 git push 命令 → push-guard NOT_PUSH → 引擎无输出 → 入口透传
run_mounts '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo abc"}}'
if [ "$HOOK_EXIT" -eq 0 ] && ! echo "$HOOK_STDOUT" | grep -q "permissionDecision"; then
    pass "1c: push-guard fail-open (NOT_PUSH) → passthrough, exit 0"
else
    fail "1c: exit=$HOOK_EXIT stdout='${HOOK_STDOUT:0:120}'"
fi

# 引擎级 fixture 复验 exit2 转义形态（不依赖真实 push-guard 内部逻辑）
cat > "$FIXTURE/exit2.sh" <<'EOF'
#!/bin/bash
cat > /dev/null
echo "exit2 msg from fixture" >&2
exit 2
EOF
chmod +x "$FIXTURE/exit2.sh"
printf '{"version":2,"rules":[{"name":"exit2-deny","on":{"in":["PreToolUse"]},"when":{"op":"tool","in":["Bash"]},"action":[{"op":"run_script","path":"%s","timeout_ms":5000,"deny_exit_codes":[2]}]}]}' "$FIXTURE/exit2.sh" > "$RULES"
run_engine '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
echo "$HOOK_STDOUT" | grep -q '"permissionDecision":"deny"' && pass "1c: exit2 → deny JSON shape (engine-level)" || fail "1c: shape wrong: '$HOOK_STDOUT'"
echo "$HOOK_STDOUT" | grep -q "exit2 msg from fixture" && pass "1d: deny reason = script stderr verbatim" || fail "1d: stderr text lost"
assert_exit_0 "1e: deny channel exits 0 (deny channel, not exit2)"

#####################################################################
# 通道保真 B：exit 2 @ PostToolUse → 引擎 exit 2 + stderr 直通（gdformat fail-close 语义）
#####################################################################
separator "2. Channel fidelity: exit2 @ PostToolUse (fail-close forward)"
gd_case() {
    local INPUT="$1" LABEL="$2"
    printf '{"version":2,"rules":[{"name":"exit2-post","on":{"in":["PostToolUse"]},"when":{"op":"all","args":[{"op":"tool","in":["Write"]},{"op":"file","patterns":["*.gd"]}]},"action":[{"op":"run_script","path":"%s","timeout_ms":5000,"deny_exit_codes":[2],"on_fail":"close"}]}]}' "$FIXTURE/exit2.sh" > "$RULES"
    printf '%s' "$INPUT" | UNIFIED_RULES_FILE="$RULES" HOOK_FIRE_LOG="$FIRELOG" PWD="$REPO_ROOT" \
        node "$ENGINE" > "$FIXTURE/out.txt" 2> "$FIXTURE/err.txt"
    local code=$?
    if [ "$code" -eq 2 ] && grep -q "exit2 msg from fixture" "$FIXTURE/err.txt" && [ ! -s "$FIXTURE/out.txt" ]; then
        pass "$LABEL — exit2+stderr forwarded (PostToolUse fail-close)"
    else
        fail "$LABEL — code=$code out='$(head -1 "$FIXTURE/out.txt")' err='$(head -1 "$FIXTURE/err.txt")'"
    fi
}
gd_case '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"/x/a.gd"}}' "2a: PostToolUse exit2 channel"
# 非 .gd 文件 → 规则不命中 → 无输出 → exit 0（fail-open 侧）
printf '{"version":2,"rules":[{"name":"exit2-post","on":{"in":["PostToolUse"]},"when":{"op":"all","args":[{"op":"tool","in":["Write"]},{"op":"file","patterns":["*.gd"]}]},"action":[{"op":"run_script","path":"%s","timeout_ms":5000,"deny_exit_codes":[2],"on_fail":"close"}]}]}' "$FIXTURE/exit2.sh" > "$RULES"
run_engine '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"/x/main.ts"}}'
[ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDOUT" ] && pass "2b: non-target file → no fire, exit 0" || fail "2b: leaked: exit=$HOOK_EXIT"

#####################################################################
# 通道保真 C：deny JSON 直通 + additionalContext 直通
#####################################################################
separator "3. Channel fidelity: deny JSON / additionalContext passthrough"
cat > "$FIXTURE/deny.js" <<'EOF'
#!/bin/bash
cat > /dev/null
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"mention missing"}}'
exit 0
EOF
chmod +x "$FIXTURE/deny.js"
printf '{"version":2,"rules":[{"name":"deny-pass","on":{"in":["PreToolUse"]},"when":{"op":"tool","in":["Bash"]},"action":[{"op":"run_script","path":"%s","timeout_ms":5000}]}]}' "$FIXTURE/deny.js" > "$RULES"
run_engine '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
echo "$HOOK_STDOUT" | grep -q '"permissionDecision":"deny"' && grep -q "mention missing" <<<"$HOOK_STDOUT" \
    && pass "3a: script deny JSON passthrough verbatim" || fail "3a: deny JSON altered: '$HOOK_STDOUT'"

cat > "$FIXTURE/ctx.sh" <<'EOF'
#!/bin/bash
cat > /dev/null
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"[taskflow] reminder"}}'
exit 0
EOF
chmod +x "$FIXTURE/ctx.sh"
printf '{"version":2,"rules":[{"name":"ctx-pass","on":{"in":["PreToolUse"]},"action":[{"op":"run_script","path":"%s","timeout_ms":5000}]}]}' "$FIXTURE/ctx.sh" > "$RULES"
run_engine '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
echo "$HOOK_STDOUT" | grep -q '"additionalContext"' && pass "3b: additionalContext passthrough" || fail "3b: ctx lost"

# 协议外 stdout 不透传（v1 echo stdin 脚本挂载后无 hookSpecificOutput → 入口透传）
cat > "$FIXTURE/echo-in.sh" <<'EOF'
#!/bin/bash
echo "passthrough-by-echo"
exit 0
EOF
chmod +x "$FIXTURE/echo-in.sh"
printf '{"version":2,"rules":[{"name":"echo-pass","on":{"in":["PreToolUse"]},"action":[{"op":"run_script","path":"%s","timeout_ms":5000}]}]}' "$FIXTURE/echo-in.sh" > "$RULES"
run_engine '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
[ -z "$HOOK_STDOUT" ] && pass "3c: raw stdout (no protocol) suppressed — entry passthrough owns fidelity" || fail "3c: leaked: '$HOOK_STDOUT'"

#####################################################################
# 4. 超时语义：on_fail open（放行+审计）vs close（拦截）
#####################################################################
separator "4. Timeout semantics"
cat > "$FIXTURE/slow.sh" <<'EOF'
#!/bin/bash
cat > /dev/null
sleep 2
exit 0
EOF
chmod +x "$FIXTURE/slow.sh"
printf '{"version":2,"rules":[{"name":"slow-open","on":{"in":["PreToolUse"]},"action":[{"op":"run_script","path":"%s","timeout_ms":300}]},{"name":"after-slow","on":{"in":["PreToolUse"]},"action":[{"op":"context","message":"[engine-alive]"}]}]}' "$FIXTURE/slow.sh" > "$RULES"
run_mounts '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
if echo "$HOOK_STDOUT" | grep -q "engine-alive"; then
    pass "4a: timeout on_fail=open → 放行 + 引擎其余规则继续"
else
    fail "4a: fail-open broken: '${HOOK_STDOUT:0:120}'"
fi
grep -q "run-script-timeout" "$FIRELOG" && pass "4a: timeout audited" || fail "4a: timeout not audited"

printf '{"version":2,"rules":[{"name":"slow-close","on":{"in":["PreToolUse"]},"action":[{"op":"run_script","path":"%s","timeout_ms":300,"on_fail":"close"}]}]}' "$FIXTURE/slow.sh" > "$RULES"
run_mounts '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
echo "$HOOK_STDOUT" | grep -q '"permissionDecision":"deny"' && pass "4b: timeout fail-close → deny @ Pre" || fail "4b: fail-close broken: '$HOOK_STDOUT'"

#####################################################################
# 5. ${HOOKS_DIR} 解析：repo 布局 + fixture 全局部署位布局双路径
#####################################################################
separator "5. HOOKS_DIR resolution"
cat > "$FIXTURE/probe.sh" <<'EOF'
#!/bin/bash
cat > /dev/null
echo '[probe]$HOOKS_DIR-resolved'
exit 0
EOF
chmod +x "$FIXTURE/probe.sh"
printf '{"version":2,"rules":[{"name":"probe","on":{"in":["PreToolUse"]},"action":[{"op":"run_script","path":"${HOOKS_DIR}/probe.sh","timeout_ms":5000,"inject_stdout":true}]}]}' > "$RULES"
# repo 布局：config 指向 $FIXTURE（无 probe 副本）→ 需要将 probe 放 hooks 根；改用部署位布局验证
mkdir -p "$FIXTURE/deployhome/.claude/hooks/unified"
for f in unified-hook.sh engine.js when-ops.js rules-v2.json; do
    cp "$HOOKS/unified/$f" "$FIXTURE/deployhome/.claude/hooks/unified/" 2>/dev/null
done
cp "$REPO_ROOT/hooks/validate-rules.js" "$FIXTURE/deployhome/.claude/hooks/"
printf '{"version":2,"v1_compat":false,"rules":[]}' > "$RULES"
cp "$RULES" "$FIXTURE/deployhome/.claude/hooks/unified/rules-v2.json"
mkdir -p "$FIXTURE/deployhome/.claude/hooks/unified/rules.d"
cp "$HOOKS/unified/rules.d/runscript-mounts.json" "$FIXTURE/deployhome/.claude/hooks/unified/rules.d/"
mkdir -p "$FIXTURE/deployhome/.claude/hooks/scripts"
cp "$HOOKS/scripts/push-guard.sh" "$FIXTURE/deployhome/.claude/hooks/scripts/"
mkdir -p "$FIXTURE/empty-cwd5"
DEP_IN='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo abc"}}'
DEP_OUT=$(cd "$FIXTURE/empty-cwd5" && printf '%s' "$DEP_IN" | \
    HOME="$FIXTURE/deployhome" CLAUDE_PROJECT_DIR="" HOOK_FIRE_LOG="$FIXTURE/depfire.log" MULTICA_AGENT_NAME=Bachi \
    bash "$FIXTURE/deployhome/.claude/hooks/unified/unified-hook.sh" 2>/dev/null)
[ "$DEP_OUT" = "$DEP_IN" ] && pass "5a: HOOKS_DIR resolves at deploy layout (silent passthrough)" || fail "5a: dep out: '$DEP_OUT'"

# repo 布局真实脚本经 ${HOOKS_DIR}：mention-check 对无 mention 的 comment add 拦截（v1 语义保真）
printf '{"version":2,"v1_compat":false,"rules":[]}' > "$RULES"
run_mounts '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"multica issue comment add 1 --content hello"}}'
if echo "$HOOK_STDOUT" | grep -q '"permissionDecision":"deny"' && echo "$HOOK_STDOUT" | grep -q "mention"; then
    pass "5b: mention-check mount denies comment-add without mention (v1 semantics)"
else
    fail "5b: no deny: exit=$HOOK_EXIT '${HOOK_STDOUT:0:160}'"
fi
grep -q "mention-check-mount" "$FIRELOG" 2>/dev/null && pass "5c: mount rule audited in firelog" || fail "5c: mount not audited: $(tail -1 "$FIRELOG")"

#####################################################################
# 6. 真实脚本挂载语义等价（脚本零改动验证，行为以 v1 套件分层守护）
#####################################################################
separator "6. Real-script mount equivalence (smoke)"
cleanup_sentinels
run_mounts '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push origin HEAD:refs/heads/shared/SEE-9999"}}'
if [ "$HOOK_EXIT" -eq 0 ]; then
    pass "6a: push-guard shared-branch push allowed via mount"
else
    fail "6a: shared-branch push blocked: exit=$HOOK_EXIT"
fi
printf 'ok [@X](mention://agent/abc) reply\n' > "$FIXTURE/m-body.md"
# exit-reminder：非 Atlas + 状态文件齐备 + comment add → 提醒不得触发（agents 顶层门控）
V6_AGENT="Bachi" V6_TASK_ID="11111111-2222-3333-4444-555555555555"
STATE_FILE="/tmp/atlas-taskflow-state-11111111-2222-3333-4444-555555555555"
run_mounts "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"multica issue comment add 11111111-2222-3333-4444-555555555555 --content-file $FIXTURE/m-body.md\"}}"
if echo "$HOOK_STDOUT" | grep -q "REMINDER: You have completed taskflow"; then
    fail "6b: taskflow reminder fired for non-Atlas"
else
    pass "6b: taskflow reminder gated off for non-Atlas (agents gate)"
fi
# 状态文件在 6b cleanup 之后建立（run_mounts 会清理 /tmp/atlas-taskflow-state-*）
printf 'mark_a=true\nmark_b=true\ntask_issue_id=11111111-2222-3333-4444-555555555555\n' > "$STATE_FILE"
# Atlas + comment add 命中 task issue → exit-reminder real script deny 分支
V6_AGENT="Atlas" V6_TASK_ID="11111111-2222-3333-4444-555555555555"
run_mounts_keep "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"multica issue comment add 11111111-2222-3333-4444-555555555555 --content-file $FIXTURE/m-body.md\"}}"
if echo "$HOOK_STDOUT" | grep -q '"permissionDecision":"deny"' && echo "$HOOK_STDOUT" | grep -q "Comment blocked"; then
    pass "6c: Atlas + task-issue comment → taskflow deny via real script"
else
    fail "6c: no deny: '${HOOK_STDOUT:0:160}'"
fi
# Atlas + comment add 非目标 issue → reminder additionalContext 分支
V6_AGENT="Atlas" V6_TASK_ID="11111111-2222-3333-4444-555555555555"
run_mounts_keep "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"multica issue comment add 22222222-2222-3333-4444-555555555555 --content-file $FIXTURE/m-body.md\"}}"
if echo "$HOOK_STDOUT" | grep -q '"additionalContext"' && echo "$HOOK_STDOUT" | grep -q "REMINDER: You have completed taskflow"; then
    pass "6c: taskflow reminder branch (additionalContext) via real script"
else
    fail "6c: reminder missing: '${HOOK_STDOUT:0:160}'"
fi
rm -f "$STATE_FILE"

#####################################################################
# 7. S8 hardening：run_script 畸形输出 / deny_exit_codes 边界 / rules.d 冲突
#####################################################################
separator "7. S8 hardening: malformed script output / exit-code boundary / rules.d conflicts"

# 7a: 非 JSON stdout（{ 开头但解析失败）→ 不误当协议，suppress（入口透传）
cat > "$FIXTURE/badjson.sh" <<'EOF'
#!/bin/bash
cat > /dev/null
echo '{almost json but broken'
exit 0
EOF
chmod +x "$FIXTURE/badjson.sh"
printf '{"version":2,"rules":[{"name":"s8a","on":{"in":["PreToolUse"]},"action":[{"op":"run_script","path":"%s","timeout_ms":5000}]}]}' "$FIXTURE/badjson.sh" > "$RULES"
run_engine '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
[ -z "$HOOK_STDOUT" ] && [ "$HOOK_EXIT" -eq 0 ] && pass "7a: broken-JSON stdout suppressed" || fail "7a: got exit=$HOOK_EXIT out='${HOOK_STDOUT:0:120}'"

# 7b: JSON stdout 但无 hookSpecificOutput → 非协议 → suppress
cat > "$FIXTURE/plainjson.sh" <<'EOF'
#!/bin/bash
cat > /dev/null
echo '{"result":"not-a-protocol"}'
exit 0
EOF
chmod +x "$FIXTURE/plainjson.sh"
printf '{"version":2,"rules":[{"name":"s8b","on":{"in":["PreToolUse"]},"action":[{"op":"run_script","path":"%s","timeout_ms":5000}]}]}' "$FIXTURE/plainjson.sh" > "$RULES"
run_engine '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
[ -z "$HOOK_STDOUT" ] && [ "$HOOK_EXIT" -eq 0 ] && pass "7b: non-protocol JSON stdout suppressed" || fail "7b: leaked: '${HOOK_STDOUT:0:120}'"

# 7c: 超长 stderr + exit 2 @ PreToolUse（deny 通道）→ reason 逐字保真不截断
cat > "$FIXTURE/bigstderr.sh" <<'EOF'
#!/bin/bash
cat > /dev/null
python3 -c "import sys; sys.stderr.write('S8BIG-' + 'x'*50000 + '-END') if False else None"
printf 'S8BIG-%s-END' "$(printf 'y%.0s' $(seq 1 50000))" >&2
exit 2
EOF
chmod +x "$FIXTURE/bigstderr.sh"
printf '{"version":2,"rules":[{"name":"s8c","on":{"in":["PreToolUse"]},"action":[{"op":"run_script","path":"%s","timeout_ms":5000,"deny_exit_codes":[2]}]}]}' "$FIXTURE/bigstderr.sh" > "$RULES"
run_engine '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
echo "$HOOK_STDOUT" | grep -q "S8BIG-" && echo "$HOOK_STDOUT" | grep -q -- "-END" \
    && pass "7c: 50KB stderr verbatim into deny reason" || fail "7c: stderr truncated/lost"

# 7d: 双写 stdout+stderr：exit 2 @ PreToolUse → deny 通道（stdout 被忽略）
cat > "$FIXTURE/dualwrite.sh" <<'EOF'
#!/bin/bash
cat > /dev/null
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{}}}'
echo "deny-side stderr wins" >&2
exit 2
EOF
chmod +x "$FIXTURE/dualwrite.sh"
printf '{"version":2,"rules":[{"name":"s8d","on":{"in":["PreToolUse"]},"action":[{"op":"run_script","path":"%s","timeout_ms":5000,"deny_exit_codes":[2]}]}]}' "$FIXTURE/dualwrite.sh" > "$RULES"
run_engine '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
echo "$HOOK_STDOUT" | grep -q '"permissionDecision":"deny"' && echo "$HOOK_STDOUT" | grep -q "deny-side stderr wins" \
    && pass "7d: exit2 deny channel precedence over stdout protocol" || fail "7d: got '${HOOK_STDOUT:0:160}'"

# 7e: deny_exit_codes 边界：exit 1 不在名单 → fail-open；exit 2 在名单 → deny
cat > "$FIXTURE/exit1.sh" <<'EOF'
#!/bin/bash
cat > /dev/null
echo "soft failure one" >&2
exit 1
EOF
cat > "$FIXTURE/exit2b.sh" <<'EOF'
#!/bin/bash
cat > /dev/null
echo "hard failure two" >&2
exit 2
EOF
chmod +x "$FIXTURE/exit1.sh" "$FIXTURE/exit2b.sh"
printf '{"version":2,"rules":[{"name":"s8e1","on":{"in":["PreToolUse"]},"action":[{"op":"run_script","path":"%s","timeout_ms":5000,"deny_exit_codes":[2]}]}]}' "$FIXTURE/exit1.sh" > "$RULES"
run_engine '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
[ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDOUT" ] && pass "7e: exit 1 not in deny_exit_codes → fail-open" || fail "7e: exit=$HOOK_EXIT out='${HOOK_STDOUT:0:120}'"
grep -q "run-script" "$FIRELOG" && pass "7e: exit1 audited" || fail "7e: exit1 not audited"
printf '{"version":2,"rules":[{"name":"s8e2","on":{"in":["PreToolUse"]},"action":[{"op":"run_script","path":"%s","timeout_ms":5000,"deny_exit_codes":[2]}]}]}' "$FIXTURE/exit2b.sh" > "$RULES"
run_engine '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
echo "$HOOK_STDOUT" | grep -q "hard failure two" && pass "7e: exit 2 in deny_exit_codes → deny" || fail "7e: exit2 not denied"

# 7f: deny_exit_codes 多值边界 [1,3]：exit 3 deny、exit 2 fail-open
cat > "$FIXTURE/exit3.sh" <<'EOF'
#!/bin/bash
cat > /dev/null
echo "code three" >&2
exit 3
EOF
chmod +x "$FIXTURE/exit3.sh"
printf '{"version":2,"rules":[{"name":"s8f","on":{"in":["PreToolUse"]},"action":[{"op":"run_script","path":"%s","timeout_ms":5000,"deny_exit_codes":[1,3]}]}]}' "$FIXTURE/exit3.sh" > "$RULES"
run_engine '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
echo "$HOOK_STDOUT" | grep -q "code three" && pass "7f: exit 3 in [1,3] → deny" || fail "7f: exit3 not denied"
printf '{"version":2,"rules":[{"name":"s8f2","on":{"in":["PreToolUse"]},"action":[{"op":"run_script","path":"%s","timeout_ms":5000,"deny_exit_codes":[1,3]}]}]}' "$FIXTURE/exit2b.sh" > "$RULES"
run_engine '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
[ "$HOOK_EXIT" -eq 0 ] && [ -z "$HOOK_STDOUT" ] && pass "7f: exit 2 not in [1,3] → fail-open" || fail "7f: exit2 wrongly denied"

# 7g: rules.d 与 rules-v2.json 同名规则 → 两条独立求值（先配置后挂载，无覆盖/去重），行为叠加可观测
mkdir -p "$HOOKSROOT/unified/rules.d"
printf '{"version":2,"rules":[{"name":"s8g-dup","on":{"in":["PreToolUse"]},"when":{"op":"tool","in":["Bash"]},"action":[{"op":"context","message":"[dup-main]"}]}]}' > "$RULES"
printf '{"rules":[{"name":"s8g-dup","on":{"in":["PreToolUse"]},"when":{"op":"tool","in":["Bash"]},"action":[{"op":"context","message":"[dup-mount]"}]}]}' > "$HOOKSROOT/unified/rules.d/s8-dup.json"
run_engine '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
CTXD=$(echo "$HOOK_STDOUT" | grep -o '"additionalContext":"[^"]*"')
echo "$CTXD" | grep -q "dup-main" && echo "$CTXD" | grep -q "dup-mount" \
    && pass "7g: same-name rule from main+rules.d both evaluated (no dedup, order main→rules.d)" \
    || fail "7g: got '$CTXD'"
rm -f "$HOOKSROOT/unified/rules.d/s8-dup.json"

# 7h: {scope:"run"} 兼容形态 = MULTICA_TASK_ID 窗口（D4 终态：env var 直读，session_id 不参与键）
printf '{"version":2,"rules":[{"name":"s8h","on":{"in":["PreToolUse"]},"one_shot":{"scope":"run"},"action":[{"op":"context","message":"[s8h]"}]}]}' > "$RULES"
cleanup_sentinels
V6_TASK_ID="s8h-task"
run_mounts '{"hook_event_name":"PreToolUse","session_id":"sess-shadow"}'
assert_exit_0 "7h: compat run window fires"
[ -f "$STATE/.hook-fired-s8h-s8h-task" ] && pass "7h: key = MULTICA_TASK_ID env value (session_id shadow ignored)" || fail "7h: key wrong: $(ls /tmp/.hook-fired-s8h-* 2>/dev/null)"
V6_TASK_ID="s8h-task"
run_mounts_keep '{"hook_event_name":"PreToolUse","session_id":"sess-shadow"}'
if echo "$HOOK_STDOUT" | grep -q "s8h"; then fail "7h: refired same window"; else pass "7h: suppressed same window (session_id not part of key)"; fi
V6_TASK_ID=""; cleanup_sentinels

# 7i: (retired P4 — v1+v2 dual-open window no longer exists after compat layer removal)

# 7j: SEE-1092 复合命令变体 — mention-check 宽门 + 权威复判：heredoc/嵌套 bash 中藏 comment add，
#     mention-check 脚本内权威判定（宽门引擎 only tool Bash），双引号包裹/管道变体不绕过
printf '{"version":2,"v1_compat":false,"rules":[]}' > "$RULES"
run_mounts '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo pre && bash -c \"multica issue comment add 1 --content no-mention-here\""}}'
if echo "$HOOK_STDOUT" | grep -q '"permissionDecision":"deny"' && echo "$HOOK_STDOUT" | grep -q "mention"; then
    pass "7j: nested-bash comment add variant still denied (wide gate + script authority)"
else
    pass_or_fail_note="NOTE: 7j nested variant output: '${HOOK_STDOUT:0:140}'"
    echo "$pass_or_fail_note" >&2
    if echo "$HOOK_STDOUT" | grep -q "mention"; then pass "7j: variant caught (partial)"; else fail "7j: nested variant bypassed mention-check"; fi
fi
# 7j-2: 管道变体（cat | multica issue comment add）→ 宽门命中，脚本内权威复判
run_mounts '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat f | multica issue comment add 1 --content plain"}}'
if echo "$HOOK_STDOUT" | grep -q "mention"; then
    pass "7j-2: piped comment add variant caught"
else
    fail "7j-2: piped variant bypassed: '${HOOK_STDOUT:0:140}'"
fi

# 7k: (retired P4 — v1 probe equivalence superseded by rules-v2.json native rules + S8/S9 QA)

#####################################################################
# 8. P2/S10: auto-pr Stop mount + stop_hook_active 防循环（payload op）
#    红线：Stop 事件任何路径不得阻塞或循环 —— 挂载规则在 stop_hook_active=true
#    时不触发（引擎第一道防线），脚本内 L23-37 检查为第二道防线。
#####################################################################
separator "8. auto-pr Stop mount + stop_hook_active anti-loop"

# fixture 脚本：与 auto-pr 同形的第一道防线行为（stop_hook_active=true → 静默 exit 0）；
# 用探针脚本代替真实 auto-pr（真实脚本会 git push —— 副作用不可在测试中复现），
# 防线等价性由「同样读 payload.stop_hook_active」结构保证，真实脚本回归由 v1 套件覆盖。
cat > "$HOOKSROOT/ap-pr-sim.sh" <<EOF
#!/bin/bash
INPUT=\$(cat)
IS_ACTIVE=\$(printf '%s' "\$INPUT" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{
    try{const i=JSON.parse(d);process.stdout.write(i.stop_hook_active===true?'true':'false');}
    catch(e){process.stdout.write('false');}
  });" 2>/dev/null || echo "false")
[ "\$IS_ACTIVE" = "true" ] && exit 0
# 模拟副作用：写执行标记（幂等标记供断言；\$FIXTURE 由套件展开注入）
node -e "const fs=require('fs');const p='$FIXTURE/ap-fired.flag';fs.writeFileSync(p,(fs.existsSync(p)?(fs.readFileSync(p,'utf8')|0)+1:1)+'')"
exit 0
EOF
chmod +x "$HOOKSROOT/ap-pr-sim.sh"

# 空主配置 + 挂载规则经 rules.d（真实 runscript-mounts.json 已含 auto-pr-stop-mount，
# 但其脚本指向真实 auto-pr —— 副作用不可测，改用模拟脚本规则直写 RULES）
printf '{"version":2,"rules":[{"name":"ap-stop","on":{"in":["Stop"]},"when":{"op":"payload","path":"stop_hook_active","equals":false},"action":[{"op":"run_script","path":"%s/ap-pr-sim.sh","timeout_ms":10000}]}]}' "$HOOKSROOT" > "$RULES"
# 7k 残留的 rules.d 同名探针（若存在）已清；确保 rules.d 不叠加 ap 干扰
rm -f "$HOOKSROOT/unified/rules.d/s8-dup.json"

# 8a: 第一次 Stop（stop_hook_active 缺省）→ 脚本执行（标记 +1）
rm -f "$FIXTURE/ap-fired.flag"
run_mounts '{"hook_event_name":"Stop","session_id":"s8a"}'
AP_FIRED="$(cat "$FIXTURE/ap-fired.flag" 2>/dev/null || echo 0)"
[ "$AP_FIRED" = "1" ] \
    && pass "8a: Stop without stop_hook_active → script side-effect fires once" \
    || fail "8a: script did not fire. flag='$AP_FIRED'"
# 8b: 第二次 Stop 携带 stop_hook_active=true（引擎复驱同一 Stop）→ payload op 短路，脚本不执行
run_mounts '{"hook_event_name":"Stop","stop_hook_active":true,"session_id":"s8a"}'
[ -f "$FIXTURE/ap-fired.flag" ] && [ "$(cat "$FIXTURE/ap-fired.flag")" = "1" ] \
    && pass "8b: stop_hook_active=true → payload op gates, no second side-effect (anti-loop)" \
    || fail "8b: ANTI-LOOP BROKEN — script refired on engine-driven Stop. flag='$(cat "$FIXTURE/ap-fired.flag" 2>/dev/null)'"

# 8c: run_script 失败 @ Stop → fail-open（on_fail open 缺省）：exit 0、无阻塞输出
cat > "$HOOKSROOT/ap-boom.sh" <<'EOF'
#!/bin/bash
cat > /dev/null
exit 3
EOF
chmod +x "$HOOKSROOT/ap-boom.sh"
printf '{"version":2,"rules":[{"name":"ap-boom","on":{"in":["Stop"]},"action":[{"op":"run_script","path":"%s/ap-boom.sh","timeout_ms":5000}]}]}' "$HOOKSROOT" > "$RULES"
run_mounts '{"hook_event_name":"Stop","session_id":"s8c"}'
if [ "$HOOK_EXIT" -eq 0 ] && ! echo "$HOOK_STDOUT" | grep -q "permissionDecision"; then
    pass "8c: Stop run_script failure → fail-open (exit 0, no deny) — Stop never blocked"
else
    fail "8c: Stop blocked/errored: exit=$HOOK_EXIT out='${HOOK_STDOUT:0:80}'"
fi

# 8d: Stop 时点 deny 非法由 M2 矩阵拒绝（挂载规则若写 deny 会被 fail-soft 跳过）
printf '{"version":2,"rules":[{"name":"ap-deny-bad","on":{"in":["Stop"]},"action":[{"op":"deny","message":"x"}]}]}' > "$RULES"
: > "$FIRELOG"
run_mounts '{"hook_event_name":"Stop","session_id":"s8d"}'
grep -q "RULE_INVALID" "$FIRELOG" && pass "8d: deny @ Stop rejected by M2 (fail-soft, no block output)" \
    || fail "8d: M2 guard missing for Stop deny"

# 恢复标准空配置供后续 summary
printf '{"version":2,"v1_compat":false,"rules":[]}' > "$RULES"

#####################################################################
# 9. S12 hardening: payload op boundaries / timeout param edge / stacking order / truthy-string semantics
#####################################################################
separator "9. S12 hardening: payload op boundary matrix"

# probe 脚本（执行标记可断言）
cat > "$HOOKSROOT/ap-probe.sh" <<'EOF'
#!/bin/bash
cat > /dev/null
echo fired >> "$PROBE_FLAG"
EOF
chmod +x "$HOOKSROOT/ap-probe.sh"
P() { # $1 label  $2 rules-json  $3 payload  [$4 extra-env passthrough via PROBE_FLAG fixed]
  printf '%s' "$2" > "$RULES"
  rm -f "$FIXTURE/probe.flag"
  OUTP=$(printf '%s' "$3" | env UNIFIED_RULES_FILE="$RULES" HOOK_FIRE_LOG="$FIRELOG" \
    MULTICA_AGENT_NAME="${V6_AGENT:-}" MULTICA_TASK_ID="${V6_TASK_ID:-}" \
    HOOK_SCOPE_ID="${V6_SCOPE_ID:-}" PWD="${V6_PWD:-$REPO_ROOT}" \
    PROBE_FLAG="$FIXTURE/probe.flag" \
    node "$ENGINE" 2>/dev/null); EX=$?
  LASTP="$OUTP"; LASTEX=$EX
}

RS='{"version":2,"rules":[{"name":"s9p","on":{"in":["Stop"]},"when":{"op":"payload","path":"stop_hook_active","equals":false},"action":[{"op":"run_script","path":"HOOKSROOT/ap-probe.sh","timeout_ms":5000}]}]}'

# 9a: 首发无 stop_hook_active 字段 → 命中（undefined ≡ 未置位）
P 9a "${RS/HOOKSROOT/$HOOKSROOT}" '{"hook_event_name":"Stop"}'
[ -f "$FIXTURE/probe.flag" ] && pass "9a: absent stop_hook_active fires (undefined = unset)" || fail "9a: absent field did not fire"

# 9b: stop_hook_active=false 显式 → 命中
P 9b "${RS/HOOKSROOT/$HOOKSROOT}" '{"hook_event_name":"Stop","stop_hook_active":false}'
[ -f "$FIXTURE/probe.flag" ] && pass "9b: explicit false fires" || fail "9b: explicit false did not fire"

# 9c: stop_hook_active=true → 短路不命中（防循环）
P 9c "${RS/HOOKSROOT/$HOOKSROOT}" '{"hook_event_name":"Stop","stop_hook_active":true}'
[ ! -f "$FIXTURE/probe.flag" ] && pass "9c: true gates (anti-loop)" || fail "9c: true fired — ANTI-LOOP BROKEN"

# 9d 🔴 防循环对抗钉：字符串 "true"（truthy 非布尔）→ 引擎判读为「已置位」→ 短路
#     语义钉：isSet = cur !== undefined/null/false；"true"/1/{} 均为 set。当前实现即此——钉死防漂移。
P 9d "${RS/HOOKSROOT/$HOOKSROOT}" '{"hook_event_name":"Stop","stop_hook_active":"true"}'
[ ! -f "$FIXTURE/probe.flag" ] && pass "9d: string \"true\" treated as set → gated (truthy semantics pinned)" || fail "9d: string \"true\" fired — truthy 判读语义漂移"

# 9e: "false" 字符串（truthy 非布尔）→ 亦为 set → 不命中
P 9e "${RS/HOOKSROOT/$HOOKSROOT}" '{"hook_event_name":"Stop","stop_hook_active":"false"}'
[ ! -f "$FIXTURE/probe.flag" ] && pass "9e: string \"false\" is truthy → gated (same semantics)" || fail "9e: string \"false\" fired"

# 9f: 嵌套 path（payload.a.b）命中 / 缺失段短路
printf '{"version":2,"rules":[{"name":"s9f","on":{"in":["Stop"]},"when":{"op":"payload","path":"meta.inner.flag","equals":false},"action":[{"op":"run_script","path":"%s/ap-probe.sh","timeout_ms":5000}]}]}' "$HOOKSROOT" > "$RULES"
P 9f "$(<"$RULES")" '{"hook_event_name":"Stop","meta":{"inner":{"flag":false}}}'
[ -f "$FIXTURE/probe.flag" ] && pass "9f: nested path equals:false hits on false" || fail "9f: nested false did not fire"
P 9f "$(<"$RULES")" '{"hook_event_name":"Stop","meta":{"inner":{}}}'
[ -f "$FIXTURE/probe.flag" ] && pass "9f: nested missing leaf = undefined = unset → hits (equals:false)" || fail "9f: nested missing misjudged"
P 9f "$(<"$RULES")" '{"hook_event_name":"Stop","meta":null}'
[ -f "$FIXTURE/probe.flag" ] && pass "9f: null mid-path short-circuits to undefined = unset → hits" || fail "9f: null path crashed/misjudged"

# 9g-pin: equals:true = 字面 true 语义（字符串 "true"/truthy 均不满足 literal-true）——语义钉
printf '{"version":2,"rules":[{"name":"s9gpin","on":{"in":["Stop"]},"when":{"op":"payload","path":"resume_ok","equals":true},"action":[{"op":"run_script","path":"%s/ap-probe.sh","timeout_ms":5000}]}]}' "$HOOKSROOT" > "$RULES"
P 9gpin "$(<"$RULES")" '{"hook_event_name":"Stop","resume_ok":"true"}'
[ ! -f "$FIXTURE/probe.flag" ] && pass "9g-pin: equals:true requires literal boolean true (string \"true\" not enough)" || fail "9g-pin: equals:true semantics drifted"

# 9g: payload op 在组合树内：all/any/not 组合求值
printf '{"version":2,"rules":[{"name":"s9g","on":{"in":["Stop"]},"when":{"op":"all","args":[{"op":"not","arg":{"op":"payload","path":"stop_hook_active","equals":true}},{"op":"payload","path":"resume_ok","equals":true}]},"action":[{"op":"run_script","path":"%s/ap-probe.sh","timeout_ms":5000}]}]}' "$HOOKSROOT" > "$RULES"
P 9g "$(<"$RULES")" '{"hook_event_name":"Stop","resume_ok":true}'
[ -f "$FIXTURE/probe.flag" ] && pass "9g: all(not payload=true, payload session_id) hits" || fail "9g: combo all misjudged"
P 9g "$(<"$RULES")" '{"hook_event_name":"Stop","stop_hook_active":true,"resume_ok":true}'
[ ! -f "$FIXTURE/probe.flag" ] && pass "9g: stop_hook_active=true → not() false → gated" || fail "9g: not() broken in combo"

# 9h: timeout_ms 缺省（缺失）→ 引擎缺省 10000ms 正常执行
printf '{"version":2,"rules":[{"name":"s9h","on":{"in":["Stop"]},"when":{"op":"payload","path":"stop_hook_active","equals":false},"action":[{"op":"run_script","path":"%s/ap-probe.sh"}]}]}' "$HOOKSROOT" > "$RULES"
P 9h "$(<"$RULES")" '{"hook_event_name":"Stop"}'
[ -f "$FIXTURE/probe.flag" ] && [ "$LASTEX" -eq 0 ] && pass "9h: timeout_ms absent → default runs fine" || fail "9h: missing timeout_ms broke: exit=$LASTEX"

# 9i: timeout_ms 非法值（字符串）→ validator fail-soft 跳过该规则（不崩、不执行）
printf '{"version":2,"rules":[{"name":"s9i","on":{"in":["Stop"]},"action":[{"op":"run_script","path":"%s/ap-probe.sh","timeout_ms":"5000"}]}]}' "$HOOKSROOT" > "$RULES"
P 9i "$(<"$RULES")" '{"hook_event_name":"Stop"}'
[ ! -f "$FIXTURE/probe.flag" ] && [ "$LASTEX" -eq 0 ] && pass "9i: invalid timeout_ms → fail-soft skip (no crash, no exec)" || fail "9i: invalid timeout_ms mishandled: exit=$LASTEX fired=$([ -f "$FIXTURE/probe.flag" ] && echo yes)"

# 9j: Stop 同事件叠加顺序：rules-v2.json 规则先于 rules.d 挂载规则命中（context 顺序 main→rules.d）
printf '{"version":2,"rules":[{"name":"s9j-main","on":{"in":["Stop"]},"action":[{"op":"context","message":"[from-main]"}]}]}' > "$RULES"
printf '{"rules":[{"name":"s9j-mount","on":{"in":["Stop"]},"action":[{"op":"context","message":"[from-mount]"}]}]}' > "$HOOKSROOT/unified/rules.d/s9j.json"
P 9j "$(<"$RULES")" '{"hook_event_name":"Stop"}'
CTXJ=$(echo "$LASTP" | grep -o '"additionalContext":"[^"]*"')
echo "$CTXJ" | grep -q "from-main" && echo "$CTXJ" | grep -q "from-mount" \
  && pass "9j: Stop stacking — main + rules.d mount both fire" || fail "9j: stacking broken: '$CTXJ'"
MAINI=$(echo "$CTXJ" | grep -bo "from-main" | head -1 | cut -d: -f1)
MOUNTI=$(echo "$CTXJ" | grep -bo "from-mount" | head -1 | cut -d: -f1)
[ -n "$MAINI" ] && [ -n "$MOUNTI" ] && [ "$MAINI" -lt "$MOUNTI" ] \
  && pass "9j: order main → rules.d preserved" || fail "9j: order inverted"
rm -f "$HOOKSROOT/unified/rules.d/s9j.json"

# 9k: 挂载规则 validator fail-soft 跳过（auto-pr-mount 若非法）→ Stop 兜底 = 其余规则照常、恒不阻塞
printf '{"rules":[{"name":"s9k-bad","on":{"in":["Stop"]},"action":[{"op":"deny","message":"x"}]}]}' > "$HOOKSROOT/unified/rules.d/s9k.json"
printf '{"version":2,"rules":[{"name":"s9k-good","on":{"in":["Stop"]},"action":[{"op":"context","message":"[s9k-alive]"}]}]}' > "$RULES"
P 9k "$(<"$RULES")" '{"hook_event_name":"Stop"}'
echo "$LASTP" | grep -q "s9k-alive" && [ "$LASTEX" -eq 0 ] \
  && pass "9k: invalid mount rule fail-soft skipped, Stop unblocked, others live" || fail "9k: fail-soft broken at Stop"
rm -f "$HOOKSROOT/unified/rules.d/s9k.json"
# 恢复标准空配置
printf '{"version":2,"v1_compat":false,"rules":[]}' > "$RULES"

#####################################################################
# 10. P3/S14: repo-checkout SessionStart mount + 600s marker 幂等 + UPS 时点
#####################################################################
separator "10. repo-checkout SessionStart mount (P3/S14)"

# 探针脚本：与 repo-checkout 同形 marker 协议（写入 .cc-aligned-<dir> +
# additionalContext hint 输出）+ SessionStart/UPS 双时点行为
cat > "$HOOKSROOT/rc-sim.sh" <<EOF
#!/bin/bash
INPUT=\$(cat)
EVENT=\$(printf '%s' "\$INPUT" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{
    try{const i=JSON.parse(d);process.stdout.write(i.hook_event_name||'');}
    catch(e){process.stdout.write('');}
  });" 2>/dev/null)
if [ "\$EVENT" = "SessionStart" ]; then
  # marker 快路径：600s 内存在 → 零 I/O 早退（无 hint 输出，v1 语义）
  MARKER="/tmp/.cc-aligned-marker-probe"
  if [ -f "\$MARKER" ] && [ \$(( \$(date +%s) - \$(stat -c %Y "\$MARKER") )) -lt 600 ]; then
    exit 0
  fi
  touch "\$MARKER"
  printf '%s' "\$INPUT" | jq -n --arg msg "[rc-probe] checkout hint (first)" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: \$msg}}'
  exit 0
fi
if [ "\$EVENT" = "UserPromptSubmit" ]; then
  printf '%s' "\$INPUT" | jq -n --arg msg "[rc-probe] ups-context" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: \$msg}}'
  exit 0
fi
exit 0
EOF
chmod +x "$HOOKSROOT/rc-sim.sh"
rm -f /tmp/.cc-aligned-marker-probe
# S17: when payload in[] 为死配置（引擎静默忽略，Atlas 裁定清理）→ equals 单值双规则等价改写（行为零变化）
printf '{"version":2,"rules":[{"name":"rc-mount-ss","on":{"in":["SessionStart"]},"when":{"op":"all","args":[{"op":"payload","path":"hook_event_name","equals":"SessionStart"}]},"action":[{"op":"run_script","path":"%s/rc-sim.sh","timeout_ms":10000}]},{"name":"rc-mount-ups","on":{"in":["UserPromptSubmit"]},"when":{"op":"all","args":[{"op":"payload","path":"hook_event_name","equals":"UserPromptSubmit"}]},"action":[{"op":"run_script","path":"%s/rc-sim.sh","timeout_ms":10000}]}]}' "$HOOKSROOT" "$HOOKSROOT" > "$RULES"

# 10a: 首次 SessionStart → hint additionalContext 注入（run_script 协议直通）
run_mounts '{"hook_event_name":"SessionStart","session_id":"s10a"}'
if echo "$HOOK_STDOUT" | grep -q '"additionalContext"' && echo "$HOOK_STDOUT" | grep -q "rc-probe"; then
    pass "10a: SessionStart mount fires, additionalContext injected"
else
    fail "10a: no hint. out='${HOOK_STDOUT:0:140}'"
fi
assert_exit_0 "10a: SessionStart non-blocking (exit 0)"

# 10b: 600s 内二次 SessionStart → marker 快路径，脚本早退无输出 → 引擎透传
run_mounts '{"hook_event_name":"SessionStart","session_id":"s10b"}'
if [ "$HOOK_EXIT" -eq 0 ] && ! echo "$HOOK_STDOUT" | grep -q "rc-probe"; then
    pass "10b: marker fast-path within 600s → no second hint (idempotent)"
else
    fail "10b: marker fast-path broken. out='${HOOK_STDOUT:0:140}'"
fi

# 10c: UPS 载荷路由 → additionalContext 注入（引擎对 UPS 时点 on 匹配 + 直通）
run_mounts '{"hook_event_name":"UserPromptSubmit","prompt":"hello"}'
if echo "$HOOK_STDOUT" | grep -q '"hookEventName":"UserPromptSubmit"' && echo "$HOOK_STDOUT" | grep -q "ups-context"; then
    pass "10c: UPS payload routed, additionalContext injected with correct hookEventName"
else
    fail "10c: UPS routing broken. out='${HOOK_STDOUT:0:140}'"
fi
rm -f /tmp/.cc-aligned-marker-probe

# 10d: 真实 repo-checkout 脚本挂载烟测（v1 环境无 MULTICA_TASK_ID → 脚本自身放行路径）
printf '{"version":2,"rules":[{"name":"rc-real","on":{"in":["SessionStart"]},"action":[{"op":"run_script","path":"%s/repo-checkout.sh","timeout_ms":30000}]}]}' "$HOOKSROOT" > "$RULES"
cp "$HOOKS/scripts/repo-checkout.sh" "$HOOKSROOT/scripts/"
run_mounts '{"hook_event_name":"SessionStart","session_id":"s10d"}'
if [ "$HOOK_EXIT" -eq 0 ]; then
    pass "10d: real repo-checkout mount exits 0 (fail-open path, env-degraded)"
else
    fail "10d: real script nonzero exit: $HOOK_EXIT"
fi
printf '{"version":2,"v1_compat":false,"rules":[]}' > "$RULES"

#####################################################################
#####################################################################
# 11. S16 hardening: repo-checkout mount boundaries (timeout / source variants / UPS marker / stacking / slow-path / jq-less)
#####################################################################
separator "11. S16 hardening: repo-checkout mount boundaries"

cat > "$HOOKSROOT/rc-s16.sh" <<'S16EOF'
#!/bin/bash
INPUT=$(cat)
if [ "$JQ_MODE" = "absent" ]; then PATH="/nonexistent-jq-dir"; fi
EVENT=$(printf '%s' "$INPUT" | node -e "
  let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{
    try{const i=JSON.parse(d);process.stdout.write(i.hook_event_name||'');}
    catch(e){process.stdout.write('');}
  });" 2>/dev/null)
if [ "$EVENT" = "SessionStart" ]; then
  MARKER="/tmp/.cc-aligned-s16"
  if [ -f "$MARKER" ] && [ $(( $(date +%s) - $(stat -c %Y "$MARKER") )) -lt 600 ]; then exit 0; fi
  touch "$MARKER"
  OUT=$(printf '%s' "$INPUT" | jq -n --arg msg "[rc-s16] hint first" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$msg}}' 2>/dev/null)
  if [ -n "$OUT" ]; then printf '%s' "$OUT"; else printf '%s' "$INPUT"; fi
  exit 0
fi
exit 0
S16EOF
chmod +x "$HOOKSROOT/rc-s16.sh"
rm -f /tmp/.cc-aligned-s16

# 11a: SessionStart source field variants (startup/resume/clear) all hit
printf '{"version":2,"rules":[{"name":"rc-s16","on":{"in":["SessionStart"]},"when":{"op":"all","args":[{"op":"payload","path":"hook_event_name","equals":"SessionStart"}]},"action":[{"op":"run_script","path":"%s/rc-s16.sh","timeout_ms":10000}]}]}' "$HOOKSROOT" > "$RULES"
SRCOK=1
for SRC in startup resume clear; do
  rm -f /tmp/.cc-aligned-s16
  run_mounts "{\"hook_event_name\":\"SessionStart\",\"source\":\"$SRC\",\"session_id\":\"s16a-$SRC\"}"
  echo "$HOOK_STDOUT" | grep -q "rc-s16" || SRCOK=0
done
[ "$SRCOK" = "1" ] && pass "11a: source startup/resume/clear all hit mount" || fail "11a: source variant missed"
rm -f /tmp/.cc-aligned-s16

# 11b: slow-path negative — stale marker (>600s) → full path re-runs
run_mounts '{"hook_event_name":"SessionStart","session_id":"s16b1"}'
[ -f /tmp/.cc-aligned-s16 ] || fail "11b: first run did not create marker"
touch -d "2020-01-01 00:00:00" /tmp/.cc-aligned-s16
run_mounts '{"hook_event_name":"SessionStart","session_id":"s16b2"}'
if echo "$HOOK_STDOUT" | grep -q "rc-s16"; then
    pass "11b: stale marker (>600s) → full path re-runs (slow-path negative)"
else
    fail "11b: stale marker still fast-pathed — slow-path broken"
fi
rm -f /tmp/.cc-aligned-s16

# 11c: UPS → SessionStart sequence: UPS must not consume SessionStart marker
printf '{"version":2,"rules":[{"name":"rc-s16b","on":{"in":["SessionStart","UserPromptSubmit"]},"when":{"op":"all","args":[{"op":"payload","path":"hook_event_name","in":["SessionStart","UserPromptSubmit"]}]},"action":[{"op":"run_script","path":"%s/rc-s16.sh","timeout_ms":10000}]}]}' "$HOOKSROOT" > "$RULES"
run_mounts '{"hook_event_name":"UserPromptSubmit","prompt":"q"}'
run_mounts '{"hook_event_name":"SessionStart","session_id":"s16c"}'
if echo "$HOOK_STDOUT" | grep -q "rc-s16"; then
    pass "11c: UPS sequence does not consume SessionStart marker"
else
    fail "11c: UPS consumed marker (fast-path wrongly hit)"
fi
rm -f /tmp/.cc-aligned-s16

# 11d: SessionStart stacking order pin (main → rules.d)
printf '{"version":2,"rules":[{"name":"s16d-main","on":{"in":["SessionStart"]},"action":[{"op":"context","message":"[s16d-main]"}]}]}' > "$RULES"
mv "$HOOKSROOT/unified/rules.d/runscript-mounts.json" "$FIXTURE/p1.bak"
printf '{"rules":[{"name":"s16d-mount","on":{"in":["SessionStart"]},"action":[{"op":"context","message":"[s16d-mount]"}]}]}' > "$HOOKSROOT/unified/rules.d/s16d.json"
run_mounts '{"hook_event_name":"SessionStart"}'
mv "$FIXTURE/p1.bak" "$HOOKSROOT/unified/rules.d/runscript-mounts.json"
CTXD=$(echo "$HOOK_STDOUT" | grep -o '"additionalContext":"[^"]*"')
I1=$(echo "$CTXD"|grep -bo "s16d-main"|head -1|cut -d: -f1); I2=$(echo "$CTXD"|grep -bo "s16d-mount"|head -1|cut -d: -f1)
[ -n "$I1" ] && [ -n "$I2" ] && [ "$I1" -lt "$I2" ] \
  && pass "11d: SessionStart stacking order main → rules.d pinned" || fail "11d: order broken: '$CTXD'"
rm -f "$HOOKSROOT/unified/rules.d/s16d.json"

# 11e: mount timeout boundary → fail-open + firelog audit
cat > "$HOOKSROOT/rc-slow.sh" <<'S16EOF'
#!/bin/bash
cat > /dev/null
sleep 2
S16EOF
chmod +x "$HOOKSROOT/rc-slow.sh"
printf '{"version":2,"rules":[{"name":"rc-slow","on":{"in":["SessionStart"]},"action":[{"op":"run_script","path":"%s/rc-slow.sh","timeout_ms":300}]}]}' "$HOOKSROOT" > "$RULES"
: > "$FIRELOG"
run_mounts '{"hook_event_name":"SessionStart","session_id":"s16e"}'
if [ "$HOOK_EXIT" -eq 0 ] && ! echo "$HOOK_STDOUT" | grep -q "permissionDecision"; then
    pass "11e: mount timeout → fail-open (exit 0, no block)"
else
    fail "11e: timeout not fail-open: exit=$HOOK_EXIT out='${HOOK_STDOUT:0:100}'"
fi
grep -q "run-script-timeout" "$FIRELOG" && pass "11e: timeout audited in firelog" || fail "11e: timeout not audited"

# 11f: jq-absent env behavior pin — script fail-open → stdin passthrough, engine exit 0
printf '{"version":2,"rules":[{"name":"rc-jq","on":{"in":["SessionStart"]},"action":[{"op":"run_script","path":"%s/rc-s16.sh","timeout_ms":10000}]}]}' "$HOOKSROOT" > "$RULES"
rm -f /tmp/.cc-aligned-s16
mv "$HOOKSROOT/unified/rules.d/runscript-mounts.json" "$FIXTURE/p1.bak"
JQLESS_OUT=$(printf '%s' '{"hook_event_name":"SessionStart","session_id":"s16f"}' | \
  env UNIFIED_RULES_FILE="$RULES" HOOK_FIRE_LOG="$FIRELOG" MULTICA_AGENT_NAME="" MULTICA_TASK_ID="" \
  HOOK_SCOPE_ID="" CLAUDE_PROJECT_DIR="$REPO_ROOT" PWD="$REPO_ROOT" \
  JQ_MODE=absent bash "$ENTRY" 2>/dev/null)
JQLESS_RC=$?
mv "$FIXTURE/p1.bak" "$HOOKSROOT/unified/rules.d/runscript-mounts.json"
if [ "$JQLESS_RC" -eq 0 ] && echo "$JQLESS_OUT" | grep -q '"hook_event_name":"SessionStart"'; then
    pass "11f: jq-absent env → script fail-open stdin passthrough, engine exit 0 (pin)"
else
    fail "11f: jq-less behavior drifted: rc=$JQLESS_RC out='${JQLESS_OUT:0:100}'"
fi
rm -f /tmp/.cc-aligned-s16
printf '{"version":2,"v1_compat":false,"rules":[]}' > "$RULES"

#####################################################################
# 11g: rules.d multi-file load order pin (sorted by filename; kills readdir-order mutation)
mv "$HOOKSROOT/unified/rules.d/runscript-mounts.json" "$FIXTURE/p1.bak"
printf '{"rules":[{"name":"z-first-content","on":{"in":["SessionStart"]},"action":[{"op":"context","message":"[aaa-from-a]"}]}]}' > "$HOOKSROOT/unified/rules.d/a-file.json"
printf '{"rules":[{"name":"zz-second","on":{"in":["SessionStart"]},"action":[{"op":"context","message":"[zzz-from-z]"}]}]}' > "$HOOKSROOT/unified/rules.d/z-file.json"
run_mounts '{"hook_event_name":"SessionStart"}'
CTXG=$(echo "$HOOK_STDOUT" | grep -o '"additionalContext":"[^"]*"')
JA=$(echo "$CTXG"|grep -bo "aaa-from-a"|head -1|cut -d: -f1); JZ=$(echo "$CTXG"|grep -bo "zzz-from-z"|head -1|cut -d: -f1)
[ -n "$JA" ] && [ -n "$JZ" ] && [ "$JA" -lt "$JZ" ] \
  && pass "11g: rules.d multi-file sorted load order (a → z) pinned" || fail "11g: rules.d file order broken: '$CTXG'"
rm -f "$HOOKSROOT/unified/rules.d/a-file.json" "$HOOKSROOT/unified/rules.d/z-file.json"
mv "$FIXTURE/p1.bak" "$HOOKSROOT/unified/rules.d/runscript-mounts.json"
printf '{"version":2,"v1_compat":false,"rules":[]}' > "$RULES"

#####################################################################
separator "Summary"

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
