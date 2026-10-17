#!/bin/bash
# test_see665_bash_executed_skill_check.sh
# QA Test for SEE-665: bash_executed condition operator verification
# Validates: command (exact base-name matching), exclude (pre-filter), keyword/pattern
#            isolation of args matching (command leakage fix), transcript + bash cmd extraction
#
# v2 redirect (SEE-1330): v1 `bash_executed` → v2 `{op:"command", scope:"run"}`.
# Testee: bash $PROJECT_ROOT/hooks/unified/unified-hook.sh
# ENGINE: .claude/hooks/unified/engine.js (evalCommandRun) + when-ops.js
# Env: MULTICA_AGENT_NAME / MULTICA_TASK_ID (UUID format — engine requires
# ^[0-9a-f-]{36}$ to load transcript) / HOOK_SCOPE_ID (per-run unique UUID) /
# PWD / PROJECT_ROOT / UNIFIED_RULES_FILE (mktemp fixture rules) + multica PATH
# shim returning run-messages transcript JSON.
#
# DRIFT (v1 bash_executed vs v2 cmd-run, 语义基准按 v2):
#   D1 pattern: v1 在 command 设定时对 args 正则裸匹配 → v2 pattern 按
#      parseCommand 的 base+subcommand 前缀锚定 (^prefix，参数不在匹配范围) →
#      T5A 改为前缀等价 pattern "multica issue"。
#   D2 v2 validate-rules 状态机: cmd-run 的 when 拒绝"command 单独存在"
#      （要求 ≥1 约束 pattern/has_flag/keyword/exclude，fail-soft 跳过）→
#      原 command-alone 用例改为 command+pattern 等价场景（T1D/T3A）。
#   D3 旧"JSONL via transcript_path / upward traversal"数据通道不存在：v2 经
#      multica shim 提供 transcript；shim 不可用/task id 非 UUID → 引擎
#      fail-open 不拦截（改为第 9 节断言）。
#
# Related Issues: SEE-665, SEE-1330
# Author: Revy (QA Agent)

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0
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
UNIFIED_HOOK="$PROJECT_ROOT/hooks/unified/unified-hook.sh"
WHEN_OPS_JS="$PROJECT_ROOT/hooks/unified/when-ops.js"
ENGINE_JS="$PROJECT_ROOT/hooks/unified/engine.js"

for f in "$UNIFIED_HOOK" "$WHEN_OPS_JS" "$ENGINE_JS"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Required file missing: $f"
        exit 1
    fi
done

TEST_RUN_ID="see665-$(date +%s)-$$"
TEST_BASE="/tmp/$TEST_RUN_ID"
mkdir -p "$TEST_BASE"
SHIM_BIN="$TEST_BASE/bin"
mkdir -p "$SHIM_BIN"
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

new_uuid() { cat /proc/sys/kernel/random/uuid; }

# --- v2 rule builder (via node for safe JSON embedding) ---
make_rules_file() { # $1=outfile $2=rulename $3=when_json $4=block_msg
    node -e '
const [out, name, whenJson, msg] = process.argv.slice(1);
const rule = {
  name,
  on: { in: ["PreToolUse"] },
  agents: { include: ["TestAgent"] },
  enabled: true,
  when: JSON.parse(whenJson),
  action: [{ op: "deny", message: msg }],
};
require("fs").writeFileSync(out, JSON.stringify({ rules: [rule] }));
' "$1" "$2" "$3" "$4"
}

# --- transcript builder: frags are "bash:<cmd>" / "skill:<name>" / "text:<t>" ---
make_transcript() {
    node - "$@" <<'NODEEOF'
const frags = process.argv.slice(2);
const msgs = frags.map(f => {
    const idx = f.indexOf(':');
    const kind = f.slice(0, idx), val = f.slice(idx + 1);
    if (kind === 'bash') return { type: 'tool_use', tool: 'Bash', input: { command: val } };
    if (kind === 'skill') return { type: 'tool_use', tool: 'Skill', input: { skill: val } };
    return { type: 'text', text: val };
});
console.log(JSON.stringify(msgs));
NODEEOF
}

HOOK_STDOUT=""

run_hook() { # $1=when_json $2=block_msg ; rest: transcript frags
    local when_json="$1" msg="$2"
    shift 2
    local fix_dir="$TEST_BASE/project-$(new_uuid)"
    mkdir -p "$fix_dir"
    local rules_file="$fix_dir/rules-fixture.json"
    make_rules_file "$rules_file" "see665-rule" "$when_json" "$msg"
    local mesg="$fix_dir/messages.json"
    make_transcript "$@" > "$mesg"
    local task_id
    task_id=$(new_uuid)

    local payload='{"hook_event_name":"PreToolUse","tool_input":{"command":"multica issue comment add --content test"}}'
    HOOK_STDOUT=$(cd "$fix_dir" && \
        env PATH="$SHIM_BIN:$PATH" \
            MESG_FILE="$mesg" \
            MULTICA_AGENT_NAME="TestAgent" \
            MULTICA_TASK_ID="$task_id" \
            HOOK_SCOPE_ID="$task_id" \
            PROJECT_ROOT="$fix_dir" \
            PWD="$fix_dir" \
            UNIFIED_RULES_FILE="$rules_file" \
            bash "$UNIFIED_HOOK" <<< "$payload" 2>/dev/null)
}

assert_fired() {
    local label="$1" want="${2:-}"
    if ! echo "$HOOK_STDOUT" | grep -q '"permissionDecision":"deny"'; then
        fail "$label — expected BLOCK. stdout: $(echo "$HOOK_STDOUT" | head -c 300)"
    elif [ -n "$want" ] && ! echo "$HOOK_STDOUT" | grep -qF "$want"; then
        fail "$label — blocked but message missing '$want'. stdout: $(echo "$HOOK_STDOUT" | head -c 300)"
    else
        pass "$label"
    fi
}

assert_not_fired() {
    local label="$1"
    if echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
        fail "$label — unexpected protocol output (expected no hit). stdout: $(echo "$HOOK_STDOUT" | head -c 300)"
    else
        pass "$label"
    fi
}

# --- condition builders (v2 command scope:run shapes) ---
git_commit_rule()  { printf '{"op":"command","scope":"run","command":"git","keyword":"commit"}'; }
multica_rule()     { printf '{"op":"command","scope":"run","command":"multica","keyword":"comment"}'; }

echo ""
echo "================================================================"
echo " SEE-665 command scope:'run' Tests (v2 redirect)"
echo " Testee: unified-hook.sh -> engine.js evalCommandRun (when-ops.js)"
echo "================================================================"

separator "1. command: base-name Exact Match (argv[0])"

run_hook "$(git_commit_rule)" "must use git commit" "bash:git commit -m test"
assert_fired "T1A: command=git matches 'git commit' -> BLOCK" "must use git commit"

run_hook "$(git_commit_rule)" "must use git commit" "bash:gitstatus --short"
assert_not_fired "T1B: command=git does NOT match 'gitstatus' -> PASS (no leakage)"

run_hook "$(git_commit_rule)" "must use git commit" "bash:echo git commit"
assert_not_fired "T1C: command=git does NOT match 'echo git commit' -> PASS (no leakage)"

run_hook "$(printf '{"op":"command","scope":"run","command":"git","pattern":"git"}')" "git used" \
    "bash:git"
assert_fired "T1D: command=git (pattern='git' secondary constraint per D2) matches bare 'git' -> BLOCK"

run_hook "$(printf '{"op":"command","scope":"run","command":"git","pattern":"git"}')" "git used" \
    "bash:   git diff"
assert_fired "T1E: base filter trims leading whitespace ('   git diff') -> BLOCK"

separator "2. command + keyword: Isolated Args Matching (Leakage Fix)"

run_hook "$(multica_rule)" "multica only" "bash:multica issue comment add --content test"
assert_fired "T2A: command=multica keyword=comment matches 'multica issue comment add' -> BLOCK"

run_hook "$(multica_rule)" "multica only" "bash:git commit -m 'multica issue comment'"
assert_not_fired "T2B: command=multica keyword=comment does NOT match 'git commit' -> PASS (no leakage)"

run_hook "$(git_commit_rule)" "git only" "bash:multica issue comment add --content test"
assert_not_fired "T2C: command=git keyword=commit does NOT match 'multica issue comment add' -> PASS"

separator "3. command + required secondary constraint (D2)"

run_hook "$(printf '{"op":"command","scope":"run","command":"npm","pattern":"npm"}')" "npm used" \
    "bash:npm install"
assert_fired "T3A: command=npm pattern='npm' matches 'npm install' -> BLOCK"

run_hook "$(printf '{"op":"command","scope":"run","command":"npm","pattern":"npm"}')" "npm used" \
    "bash:pnpm install"
assert_not_fired "T3B: command=npm pattern does NOT match 'pnpm install' -> PASS"

separator "4. exclude: Pre-Filter Commands"

run_hook "$(printf '{"op":"command","scope":"run","exclude":"^git","keyword":"commit"}')" "exclude test" \
    "bash:git commit -m test"
assert_not_fired "T4A: exclude='^git' filters out 'git commit' -> PASS"

run_hook "$(printf '{"op":"command","scope":"run","exclude":"^git","keyword":"commit"}')" "exclude test" \
    "bash:svn commit -m test"
assert_fired "T4B: exclude='^git' keeps 'svn commit', keyword=commit matches args -> BLOCK"

run_hook "$(printf '{"op":"command","scope":"run","exclude":"^echo","command":"git","keyword":"push"}')" "exclude cmd test" \
    "bash:echo git push" "bash:git push origin main"
assert_fired "T4C: exclude='^echo' + command=git + keyword=push -> BLOCK (echo filtered, git push matches)"

separator "5. pattern with command: base+sub prefix anchored (D1)"

run_hook "$(printf '{"op":"command","scope":"run","command":"multica","pattern":"multica issue"}')" "pattern test" \
    "bash:multica issue comment add --content test"
assert_fired "T5A: command=multica pattern='multica issue' anchored prefix matches -> BLOCK"

run_hook "$(printf '{"op":"command","scope":"run","command":"multica","pattern":"multica issue\\s+comment"}')" "pattern test" \
    "bash:multica issue get ABC --output json"
assert_not_fired "T5B: pattern 'multica issue\\s+comment' does NOT match base+sub 'multica issue' -> PASS"

run_hook "$(printf '{"op":"command","scope":"run","command":"multica","pattern":"multica issue"}')" "pattern test" \
    "bash:git issue comment"
assert_not_fired "T5C: command=multica pattern does NOT match 'git issue comment' -> PASS (no leakage)"

separator "6. No command filter (args-scope keyword): keyword matches args substring"

run_hook "$(printf '{"op":"command","scope":"run","keyword":"commit"}')" "legacy test" \
    "bash:git commit -m test"
assert_fired "T6A: No command filter, keyword=commit matches args 'commit -m test' -> BLOCK"

run_hook "$(printf '{"op":"command","scope":"run","keyword":"commit"}')" "legacy test" \
    "bash:echo 'commit message'"
assert_fired "T6B: No command filter, keyword=commit matches args of 'echo commit message' -> BLOCK (args-scope leak preserved)"

separator "7. Multiple Bash commands in transcript"

run_hook "$(git_commit_rule)" "must use git commit" "bash:echo hello" "bash:git commit -m test"
assert_fired "T7A: Multiple bash commands, 'git commit' matches -> BLOCK"

run_hook "$(git_commit_rule)" "must use git commit" "bash:echo hello" "bash:ls -la"
assert_not_fired "T7B: Multiple bash commands, none match -> PASS"

separator "8. Mixed Skill and Bash in transcript"

run_hook "$(git_commit_rule)" "must use git commit" "skill:explore" "bash:echo hello"
assert_not_fired "T8A: Skill use + unrelated bash -> PASS (used_skill does not satisfy cmd-run)"

run_hook "$(git_commit_rule)" "must use git commit" "skill:explore" "bash:git commit -m test"
assert_fired "T8B: Skill + matching bash present -> BLOCK"

separator "9. Transcript unavailable → engine fail-open (v2 replaces JSONL traversal, D3)"

broken_shim_case() {
    local fix_dir="$TEST_BASE/project-broken-$(new_uuid)"
    mkdir -p "$fix_dir"
    make_rules_file "$fix_dir/rules-fixture.json" "see665-broken" "$(git_commit_rule)" "must use git commit"
    printf 'not-a-json-array' > "$fix_dir/messages.json"
    local task_id
    task_id=$(new_uuid)
    HOOK_STDOUT=$(cd "$fix_dir" && \
        env PATH="$SHIM_BIN:$PATH" \
            MESG_FILE="$fix_dir/messages.json" \
            MULTICA_AGENT_NAME="TestAgent" \
            MULTICA_TASK_ID="$task_id" \
            HOOK_SCOPE_ID="$task_id" \
            PROJECT_ROOT="$fix_dir" \
            PWD="$fix_dir" \
            UNIFIED_RULES_FILE="$fix_dir/rules-fixture.json" \
            bash "$UNIFIED_HOOK" <<< '{"hook_event_name":"PreToolUse","tool_input":{"command":"multica issue comment add --content test"}}' 2>/dev/null)
}
broken_shim_case
assert_not_fired "U1: transcript unavailable (shim garbage) → cmd-run false, fail-open -> PASS"

no_multica_case() {
    local fix_dir="$TEST_BASE/project-nomultica-$(new_uuid)"
    mkdir -p "$fix_dir"
    make_rules_file "$fix_dir/rules-fixture.json" "see665-nomultica" "$(git_commit_rule)" "must use git commit"
    local task_id
    task_id=$(new_uuid)
    HOOK_STDOUT=$(cd "$fix_dir" && \
        env PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            MULTICA_AGENT_NAME="TestAgent" \
            MULTICA_TASK_ID="$task_id" \
            HOOK_SCOPE_ID="$task_id" \
            PROJECT_ROOT="$fix_dir" \
            PWD="$fix_dir" \
            UNIFIED_RULES_FILE="$fix_dir/rules-fixture.json" \
            bash "$UNIFIED_HOOK" <<< '{"hook_event_name":"PreToolUse","tool_input":{"command":"multica issue comment add --content test"}}' 2>/dev/null)
}
no_multica_case
assert_not_fired "U2: no multica on PATH → transcript unavailable, fail-open -> PASS"

bad_task_id_case() {
    local fix_dir="$TEST_BASE/project-badtask-$(new_uuid)"
    mkdir -p "$fix_dir"
    make_rules_file "$fix_dir/rules-fixture.json" "see665-badtask" "$(git_commit_rule)" "must use git commit"
    local mesg="$fix_dir/messages.json"
    make_transcript "bash:git commit -m test" > "$mesg"
    HOOK_STDOUT=$(cd "$fix_dir" && \
        env PATH="$SHIM_BIN:$PATH" \
            MESG_FILE="$mesg" \
            MULTICA_AGENT_NAME="TestAgent" \
            MULTICA_TASK_ID="see665-badtaskid" \
            HOOK_SCOPE_ID="$(new_uuid)" \
            PROJECT_ROOT="$fix_dir" \
            PWD="$fix_dir" \
            UNIFIED_RULES_FILE="$fix_dir/rules-fixture.json" \
            bash "$UNIFIED_HOOK" <<< '{"hook_event_name":"PreToolUse","tool_input":{"command":"multica issue comment add --content test"}}' 2>/dev/null)
}
bad_task_id_case
assert_not_fired "U3: MULTICA_TASK_ID not UUID → transcript not loaded (TASK_ID_RE), fail-open -> PASS"

separator "10. Source Code Verification (v2 implementation)"

if grep -q "function evalCommandRun" "$WHEN_OPS_JS"; then
    pass "T10A: evalCommandRun (v1 bash_executed equivalent) exists in when-ops.js"
else
    fail "T10A: evalCommandRun not found in when-ops.js"
fi

if grep -q 'node.exclude' "$WHEN_OPS_JS"; then
    pass "T10B: exclude parameter handling exists in when-ops.js"
else
    fail "T10B: exclude parameter not found in when-ops.js"
fi

if grep -q 'node.command' "$WHEN_OPS_JS"; then
    pass "T10C: command (base-name filter) parameter handling exists in when-ops.js"
else
    fail "T10C: command parameter not found in when-ops.js"
fi

if grep -q "'Bash'" "$WHEN_OPS_JS"; then
    pass "T10D: Bash tool_use extraction exists in when-ops.js loadTranscript"
else
    fail "T10D: Bash tool_use extraction not found in when-ops.js"
fi

if grep -q 'runBashCommands' "$WHEN_OPS_JS"; then
    pass "T10E: runBashCommands array exists in when-ops.js"
else
    fail "T10E: runBashCommands array not found in when-ops.js"
fi

if grep -q 'argsList' "$WHEN_OPS_JS"; then
    pass "T10F: argsList isolation exists (keyword matched against args only)"
else
    fail "T10F: argsList isolation not found in when-ops.js"
fi

if grep -q 'TASK_ID_RE' "$WHEN_OPS_JS"; then
    pass "T10G: transcript gating on UUID task id (TASK_ID_RE) exists"
else
    fail "T10G: TASK_ID_RE gating not found in when-ops.js"
fi

if node -e 'require(process.argv[1])' "$WHEN_OPS_JS" 2>/dev/null; then
    pass "S01: when-ops.js loads without syntax error (Refacty failure-mode gate)"
else
    fail "S01: when-ops.js failed to load"
fi

# --- Cleanup ---
separator "Cleanup"
rm -rf "$TEST_BASE"
rm -f /tmp/skill-check-see665-* /tmp/skill-check-* 2>/dev/null
for _f in /tmp/.hook-fired-*; do [ -f "$_f" ] && rm -f "$_f"; done

# --- Results Summary ---
separator "Results Summary"

Total=$((PASS + FAIL + SKIP))
echo ""
echo "Total: $Total | PASS: $PASS | FAIL: $FAIL | SKIP: $SKIP"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
    exit 0
else
    echo -e "${RED}$FAIL TEST(S) FAILED${NC}"
    for r in "${RESULTS[@]}"; do
        if [[ "$r" == FAIL* ]]; then
            echo -e "  ${RED}$r${NC}"
        fi
    done
    exit 1
fi
