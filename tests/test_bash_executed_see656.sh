#!/bin/bash
# test_bash_executed_see656.sh
# E2E Test Suite for SEE-656/SEE-660/SEE-663: bash_executed condition operator
# v2 redirect (SEE-1330): v1 `bash_executed` → v2 `{op:"command", scope:"run"}`.
# Testee: bash $PROJECT_ROOT/claude-hooks/unified/unified-hook.sh
# ENGINE: .claude/hooks/unified/engine.js + when-ops.js evalCommandRun
# Env: MULTICA_AGENT_NAME / MULTICA_TASK_ID (UUID, per-run unique, required by
# engine to load transcript) / HOOK_SCOPE_ID (per-run unique UUID) / PWD /
# PROJECT_ROOT / UNIFIED_RULES_FILE (mktemp fixture rules) + multica PATH shim
# returning run-messages transcript with Bash tool_use entries.
#
# DRIFT (v1 bash_executed vs v2 cmd-run, 语义基准按 v2):
#   D1 keyword 无 command 时: v1 整条命令字符串裸匹配 → v2 keyword 仅匹配 args
#      (首个空格后的子串) → BE-01/03/10/36/39 断言改为 args 子串；BE-04 ('ls',
#      无 args) 由 BLOCK 改为 PASS。
#   D2 pattern: v1 整条命令字符串匹配 → v2 按 base+subcommand 前缀锚定 (^prefix，
#      参数不在匹配范围) → BE-05/09/30/40 改为前缀等价 pattern。
#   D3 keyword+pattern 并存: v1 keyword 优先且 pattern 被忽略；v2 两者均参与
#      withBase 过滤 (pattern 也必须命中) → BE-10/11 改写为并存等价场景。
#   D4 v2 validate-rules 状态机: cmd-run 的 when 拒绝"command 单独存在"（要求
#      ≥1 组合约束 pattern/has_flag/keyword/exclude，fail-soft 跳过）→ BE-28/29
#      改写为 command+keyword 等价场景（v1 的 command-alone 分支在 v2 为非法形态）。
#
# Related Issues: SEE-660, SEE-663, SEE-1330
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
UNIFIED_HOOK="$PROJECT_ROOT/claude-hooks/unified/unified-hook.sh"

if [ ! -f "$UNIFIED_HOOK" ]; then
    echo "ERROR: unified-hook.sh missing: $UNIFIED_HOOK"
    exit 1
fi

TEST_RUN_ID="see656-e2e-$(date +%s)-$$"
TEST_BASE="/tmp/$TEST_RUN_ID"
SHIM_BIN="$TEST_BASE/bin"

mkdir -p "$TEST_BASE" "$SHIM_BIN"

new_uuid() { cat /proc/sys/kernel/random/uuid; }

# multica shim: engine calls `multica issue run-messages <taskid> --output json`;
# shim cats the per-fixture MESG_FILE (JSON array of tool_use messages).
cat > "$SHIM_BIN/multica" <<'SHIMEOF'
#!/bin/bash
if [ "$1" = "issue" ] && [ "$2" = "run-messages" ]; then
    if [ -n "$MESG_FILE" ] && [ -f "$MESG_FILE" ]; then
        cat "$MESG_FILE"
    else
        echo "[]"
    fi
fi
exit 0
SHIMEOF
chmod +x "$SHIM_BIN/multica"

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

# v2 fixture rules builder (via node for safe JSON embedding)
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

HOOK_STDOUT=""
FIXTURE_TASK=""

run_case() { # $1=block|pass $2=label $3=when_json $4=want_frag $5=block_msg $6=rule_name ; rest: transcript frags
    local expect="$1" label="$2" when_json="$3" want_frag="$4" msg="$5" rname="$6"
    shift 6
    FIXTURE_TASK=$(new_uuid)
    local fix_pwd="$TEST_BASE/project-$FIXTURE_TASK"
    mkdir -p "$fix_pwd"
    local rules_file="$fix_pwd/rules-fixture.json"
    make_rules_file "$rules_file" "$rname" "$when_json" "$msg"
    local mesg="$fix_pwd/messages.json"
    make_transcript "$@" > "$mesg"

    local payload='{"hook_event_name":"PreToolUse","tool_input":{"command":"multica issue comment add ISSUE_ID --content \"hello\""}}'
    HOOK_STDOUT=$(cd "$fix_pwd" && \
        env PATH="$SHIM_BIN:$PATH" \
            MESG_FILE="$mesg" \
            MULTICA_AGENT_NAME="TestAgent" \
            MULTICA_TASK_ID="$FIXTURE_TASK" \
            HOOK_SCOPE_ID="$FIXTURE_TASK" \
            PROJECT_ROOT="$fix_pwd" \
            PWD="$fix_pwd" \
            UNIFIED_RULES_FILE="$rules_file" \
            bash "$UNIFIED_HOOK" <<< "$payload" 2>/dev/null)

    if [ "$expect" = "block" ]; then
        if ! echo "$HOOK_STDOUT" | grep -q '"permissionDecision":"deny"'; then
            fail "$label — NOT blocked (expected BLOCK). stdout: $(echo "$HOOK_STDOUT" | head -c 400)"
        elif [ -n "$want_frag" ] && ! echo "$HOOK_STDOUT" | grep -qF "$want_frag"; then
            fail "$label — blocked but message missing '$want_frag'. stdout: $(echo "$HOOK_STDOUT" | head -c 400)"
        else
            pass "$label"
        fi
    else
        if echo "$HOOK_STDOUT" | grep -q '"permissionDecision"'; then
            fail "$label — unexpectedly BLOCKED. stdout: $(echo "$HOOK_STDOUT" | head -c 400)"
        else
            pass "$label"
        fi
    fi
}

kw_rule()     { printf '{"op":"command","scope":"run","keyword":"%s"}' "$1"; }
cmdkw_rule()  { printf '{"op":"command","scope":"run","command":"%s","keyword":"%s"}' "$1" "$2"; }
pat_rule()    { printf '{"op":"command","scope":"run","pattern":"%s"}' "$1"; }
cmdpat_rule() { printf '{"op":"command","scope":"run","command":"%s","pattern":"%s"}' "$1" "$2"; }

echo ""
echo "================================================================"
echo " E2E Test Suite: command scope:'run' (v2 redirect of SEE-656/660/663)"
echo " Testee: unified-hook.sh -> engine.js evalCommandRun (when-ops.js)"
echo "================================================================"

# ===================== GROUP 1: keyword args-substring matching (D1) =====================

separator "BE-01: keyword hit — keyword is args substring (D1)"

run_case block "BE-01: keyword 'push' found in args → BLOCK" \
    "$(kw_rule push)" "must run git push" "BE01: must run git push" "be01-kw-hit" \
    "bash:git push origin shared/SEE-660"

separator "BE-02: keyword miss — args do NOT contain keyword"

run_case pass "BE-02: keyword 'git push' NOT in args of 'npm install' → PASS" \
    "$(kw_rule 'git push')" "" "BE02: must run git push" "be02-keyword-miss" \
    "bash:npm install --save-dev"

separator "BE-03: keyword partial match — substring in middle of args"

run_case block "BE-03: keyword 'myapp' is substring in middle of args → BLOCK" \
    "$(kw_rule myapp)" "partial match" "BE03: partial match" "be03-partial" \
    "bash:docker build -t myapp:v1 ."

separator "BE-04: keyword exact match with NO args (drift D1: v1 BLOCK, v2 keyword matches args only → PASS)"

run_case pass "BE-04: 'ls' has no args; keyword 'ls' never hits in v2 args-only scope → PASS" \
    "$(kw_rule ls)" "" "BE04: exact match" "be04-exact" \
    "bash:ls"

# ===================== GROUP 2: pattern base+subcommand prefix (D2) =====================

separator "BE-05: pattern hit — base+sub prefix anchored (D2)"

run_case block "BE-05: pattern 'git commit' anchors base+sub prefix → BLOCK" \
    "$(pat_rule 'git commit')" "pattern match" "BE05: pattern match" "be05-pattern-hit" \
    "bash:git commit -m 'feat: add feature'"

separator "BE-06: pattern miss — regex does NOT match base+sub"

run_case pass "BE-06: pattern 'git commit.*feat:' doesn't match 'npm test' → PASS" \
    "$(pat_rule 'git commit.*feat:')" "" "BE06: pattern miss" "be06-pattern-miss" \
    "bash:npm test --coverage"

separator "BE-07: invalid regex — safe fallback returns false"

run_case pass "BE-07: invalid regex '[invalid(regex' → safe fallback → PASS" \
    "$(pat_rule '[invalid(regex')" "" "BE07: bad regex" "be07-bad-regex" \
    "bash:echo hello"

separator "BE-08: pattern with anchors — exact match via ^$"

run_case block "BE-08: pattern '^ls$' anchors match exactly → BLOCK" \
    "$(pat_rule '^ls$')" "anchored" "BE08: anchored" "be08-anchored" \
    "bash:ls"

separator "BE-09: pattern base+sub — 'multica .+' over 'multica issue' (D2)"

run_case block "BE-09: pattern 'multica .+' matches base+sub 'multica issue' → BLOCK" \
    "$(pat_rule 'multica .+')" "special chars" "BE09: special chars" "be09-special" \
    "bash:multica issue get abc123 --output json"

# ===================== GROUP 3: keyword + pattern coexist (D3) =====================

separator "BE-10: keyword+pattern both matched → BLOCK (D3: pattern also gates withBase)"

run_case block "BE-10: keyword 'run' in args AND pattern 'npm .+' on base+sub → BLOCK" \
    "$(printf '{"op":"command","scope":"run","keyword":"run","pattern":"npm .+"}')" "keyword priority hit" \
    "BE10: keyword priority hit" "be10-kw-pattern-hit" \
    "bash:npm run build"

separator "BE-11: keyword misses (args), pattern prefix hits — keyword still gates → PASS"

run_case pass "BE-11: keyword 'npm' not in args of 'git push origin main' (pattern 'git push' hits) → PASS" \
    "$(printf '{"op":"command","scope":"run","keyword":"npm","pattern":"git push"}')" "" \
    "BE11: kw miss pattern hit" "be11-kw-over-pattern" \
    "bash:git push origin main"

separator "BE-12: empty keyword falls through to pattern"

run_case block "BE-12: empty keyword falls through, pattern 'git status' hits base+sub → BLOCK" \
    "$(printf '{"op":"command","scope":"run","keyword":"","pattern":"git status"}')" "empty kw pattern" \
    "BE12: empty kw pattern" "be12-empty-kw-pattern" \
    "bash:git status"

# ===================== GROUP 4: no keyword field, only pattern =====================

separator "BE-13: no keyword field — pattern only"

run_case block "BE-13: no keyword field, pattern 'pnpm .+' matches base+sub → BLOCK" \
    "$(pat_rule 'pnpm .+')" "pattern only" "BE13: pattern only" "be13-pattern-only" \
    "bash:pnpm build"

# ===================== GROUP 5: AND/OR/NOT combinations =====================

separator "BE-14: AND — cmd-run(keyword hit) AND used_skill(skill present) → BLOCK"

run_case block "BE-14: bash hit AND skill present → BLOCK" \
    "$(printf '{"op":"all","args":[{"op":"command","scope":"run","keyword":"push"},{"op":"used_skill","skill":"explore"}]}')" \
    "and both true" "BE14: and both true" "be14-and-both" \
    "bash:git push origin main" "skill:explore"

separator "BE-15: AND — cmd-run(keyword hit) AND used_skill(skill absent) → PASS"

run_case pass "BE-15: bash hit AND skill absent → PASS" \
    "$(printf '{"op":"all","args":[{"op":"command","scope":"run","keyword":"push"},{"op":"used_skill","skill":"explore"}]}')" \
    "" "BE15: and partial" "be15-and-partial" \
    "bash:git push origin main"

separator "BE-16: OR — cmd-run(keyword hit) OR used_skill(absent) → BLOCK"

run_case block "BE-16: bash hit OR skill absent → BLOCK" \
    "$(printf '{"op":"any","args":[{"op":"command","scope":"run","keyword":"install"},{"op":"used_skill","skill":"explore"}]}')" \
    "or bash true" "BE16: or bash true" "be16-or-bash" \
    "bash:npm install"

separator "BE-17: OR — cmd-run(keyword miss) OR used_skill(present) → BLOCK"

run_case block "BE-17: bash miss OR skill present → BLOCK" \
    "$(printf '{"op":"any","args":[{"op":"command","scope":"run","keyword":"push"},{"op":"used_skill","skill":"explore"}]}')" \
    "or skill true" "BE17: or skill true" "be17-or-skill" \
    "skill:explore"

separator "BE-18: OR — cmd-run(keyword miss) OR used_skill(absent) → PASS"

run_case pass "BE-18: bash miss OR skill absent → PASS" \
    "$(printf '{"op":"any","args":[{"op":"command","scope":"run","keyword":"push"},{"op":"used_skill","skill":"explore"}]}')" \
    "" "BE18: or none true" "be18-or-none" \
    "text:hello"

separator "BE-19: NOT — NOT cmd-run(keyword miss) → BLOCK"

run_case block "BE-19: NOT cmd-run(keyword miss) → true → BLOCK" \
    "$(printf '{"op":"not","arg":{"op":"command","scope":"run","keyword":"push"}}')" \
    "not miss blocks" "BE19: not miss blocks" "be19-not-miss" \
    "text:hello"

separator "BE-20: NOT — NOT cmd-run(keyword hit) → PASS"

run_case pass "BE-20: NOT cmd-run(keyword hit) → false → PASS" \
    "$(printf '{"op":"not","arg":{"op":"command","scope":"run","keyword":"push"}}')" \
    "" "BE20: not hit passes" "be20-not-hit" \
    "bash:git push origin main"

# ===================== GROUP 6: edge cases =====================

separator "BE-21: multiple bash commands — one contains keyword in args"

run_case block "BE-21: 3 bash commands, one contains keyword in args → BLOCK" \
    "$(kw_rule 'shared/SEE-660')" "multi match" "BE21: multi match" "be21-multi-one-match" \
    "bash:npm install" "bash:git push origin shared/SEE-660" "bash:echo done"

separator "BE-22: multiple bash commands — none match keyword"

run_case pass "BE-22: 2 bash commands, none contain keyword in args → PASS" \
    "$(kw_rule 'git push')" "" "BE22: multi no match" "be22-multi-no-match" \
    "bash:npm install" "bash:echo done"

separator "BE-23: no bash commands in transcript — cmd-run returns false"

run_case pass "BE-23: transcript has no Bash entries, cmd-run → false → PASS" \
    "$(kw_rule 'git')" "" "BE23: no bash at all" "be23-no-bash" \
    "text:do something" "skill:explore"

separator "BE-24: keyword case-sensitive — mismatch case → PASS"

run_case pass "BE-24: keyword 'push' vs args 'PUSH origin main' — case-sensitive miss → PASS" \
    "$(kw_rule push)" "" "BE24: case sensitive" "be24-case-sensitive" \
    "bash:GIT PUSH origin main"

# ===================== GROUP 7: command parameter =====================

separator "BE-25: command exact match + keyword in args → BLOCK"

run_case block "BE-25: command='git', keyword='push' in args → BLOCK" \
    "$(cmdkw_rule git push)" "cmd+kw hit" "BE25: cmd+kw hit" "be25-cmd-kw-hit" \
    "bash:git push origin shared/SEE-663"

separator "BE-26: command exact match + keyword NOT in args → PASS"

run_case pass "BE-26: command='git', keyword='push' NOT in args ('status') → PASS" \
    "$(cmdkw_rule git push)" "" "BE26: cmd+kw miss" "be26-cmd-kw-miss" \
    "bash:git status"

separator "BE-27: command prevents false positive from data leakage → PASS"

run_case pass "BE-27: command='git' filters out echo, keyword in data → no false positive → PASS" \
    "$(cmdkw_rule git push)" "" "BE27: cmd isolation" "be27-cmd-isolation" \
    "bash:echo git push origin main"

separator "BE-28: command + keyword (D4: command-alone invalid in v2) → BLOCK when command exists"

run_case block "BE-28: command='npm' with keyword 'install' in args → BLOCK" \
    "$(cmdkw_rule npm install)" "cmd only hit" \
    "BE28: cmd only hit" "be28-cmd-only-hit" \
    "bash:npm install"

separator "BE-29: command + keyword (D4) → PASS when command absent"

run_case pass "BE-29: command='npm' with keyword 'install'; command absent ('git status') → PASS" \
    "$(cmdkw_rule npm install)" "" \
    "BE29: cmd only miss" "be29-cmd-only-miss" \
    "bash:git status"

separator "BE-30: command + pattern anchored on base+sub → BLOCK (D2)"

run_case block "BE-30: command='git', pattern 'git push' anchored base+sub prefix → BLOCK" \
    "$(cmdpat_rule git 'git push')" "cmd+pattern hit" "BE30: cmd+pattern hit" "be30-cmd-pattern-hit" \
    "bash:git push origin shared/SEE-663"

separator "BE-31: command + pattern no match → PASS"

run_case pass "BE-31: command='git', pattern 'git push' does not match 'git status' → PASS" \
    "$(cmdpat_rule git 'git push')" "" \
    "BE31: cmd+pattern miss" "be31-cmd-pattern-miss" \
    "bash:git status"

separator "BE-32: command with path prefix — exact argv[0] match → PASS"

run_case pass "BE-32: command='git' does not match argv[0]='/usr/bin/git' → PASS" \
    "$(cmdkw_rule git push)" "" "BE32: cmd path prefix" "be32-cmd-path-prefix" \
    "bash:/usr/bin/git push"

# ===================== GROUP 8: exclude parameter =====================

separator "BE-33: exclude regex filters out matching commands → PASS"

run_case pass "BE-33: exclude filters out git push, keyword misses → PASS" \
    "$(printf '{"op":"command","scope":"run","keyword":"push","exclude":"git push"}')" "" \
    "BE33: exclude filter" "be33-exclude-filter" \
    "bash:git push origin main"

separator "BE-34: exclude regex does not affect non-matching commands → BLOCK"

run_case block "BE-34: exclude='npm.*install' does not match git status, keyword 'status' hits args → BLOCK" \
    "$(printf '{"op":"command","scope":"run","keyword":"status","exclude":"npm.*install"}')" \
    "exclude no match" "BE34: exclude no match" "be34-exclude-no-match" \
    "bash:git status"

separator "BE-35: invalid exclude regex safe fallback → PASS (with keyword miss)"

run_case pass "BE-35: invalid exclude regex skipped, keyword 'git' misses → PASS" \
    "$(printf '{"op":"command","scope":"run","keyword":"git","exclude":"[invalid"}')" "" \
    "BE35: exclude bad regex" "be35-exclude-bad-regex" \
    "bash:npm install"

separator "BE-36: exclude + keyword — some commands survive exclude → BLOCK"

run_case block "BE-36: exclude filters git push, git status survives, keyword 'status' hits args → BLOCK" \
    "$(printf '{"op":"command","scope":"run","keyword":"status","exclude":"git push"}')" \
    "exclude partial" "BE36: exclude partial" "be36-exclude-partial" \
    "bash:git status" "bash:git push origin main"

# ===================== GROUP 9: command + exclude combinations =====================

separator "BE-37: command + exclude + keyword → exclude removes all → PASS"

run_case pass "BE-37: command='git', exclude removes git push, no git status → keyword misses → PASS" \
    "$(printf '{"op":"command","scope":"run","command":"git","keyword":"status","exclude":"push.*origin"}')" "" \
    "BE37: cmd+excl+kw miss" "be37-cmd-excl-kw-miss" \
    "bash:git push origin main"

separator "BE-38: command + exclude + keyword → exclude no match, keyword hits args → BLOCK"

run_case block "BE-38: command='git', exclude no match, keyword 'push' hits args → BLOCK" \
    "$(printf '{"op":"command","scope":"run","command":"git","keyword":"push","exclude":"npm.*install"}')" \
    "cmd+excl+kw hit" "BE38: cmd+excl+kw hit" "be38-cmd-excl-kw-hit" \
    "bash:git push origin main"

# ===================== GROUP 10: args-scope keyword (legacy shape under v2) =====================

separator "BE-39: keyword-only — args contain keyword even under echo (args-scope preserved)"

run_case block "BE-39: no command/exclude, keyword 'git push' matches args of 'echo git push' → BLOCK" \
    "$(kw_rule 'git push')" "compat kw" "BE39: compat kw" "be39-compat-kw" \
    "bash:echo git push"

separator "BE-40: pattern-only — base+sub anchored (D2: quoted args not in match scope)"

run_case block "BE-40: no command/exclude, pattern 'git commit' anchors base+sub → BLOCK" \
    "$(pat_rule 'git commit')" "compat pattern" "BE40: compat pattern" "be40-compat-pattern" \
    "bash:git commit -m 'feat: x'"

# ===========================================================================
# CLEANUP
# ===========================================================================
separator "Cleanup"
rm -rf "$TEST_BASE"
rm -f /tmp/skill-check-be656-* /tmp/skill-check-* 2>/dev/null
for _f in /tmp/.hook-fired-*; do [ -f "$_f" ] && rm -f "$_f"; done

# ===========================================================================
# SUMMARY
# ===========================================================================
separator "Results Summary"

TOTAL=$((PASS + FAIL + SKIP))
echo ""
echo "Total: $TOTAL | PASS: $PASS | FAIL: $FAIL | SKIP: $SKIP"
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
    echo -e "${GREEN}ALL COMMAND-SCOPE-RUN (v2) E2E TESTS PASSED${NC}"
else
    echo -e "${RED}$FAIL E2E TEST(S) FAILED${NC}"
fi

exit $FAIL
