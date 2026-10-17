#!/bin/bash
# test_iscommentadd_compound_see1151.sh
# SEE-1151: isCommentAdd must detect `multica issue comment add` in any segment
# of a compound command (&&, ;, newline, bash -c, ||, pipes), while NOT firing
# for echo/grep/cat/git mentioning the literal string.
#
# Historia: Refacty twice broke this hook by writing the new isCommentAdd logic
# with double-quoted node strings inside the bash heredoc, causing the whole hook
# to fail with `syntax error near unexpected token`. This suite exists to
# guard the fix.
#
# v2 redirect (SEE-1330): v1 isCommentAdd 探针规则 → v2 when-ops.js 词法语义。
# Testee: node -e 'require("$PROJECT_ROOT/hooks/unified/when-ops.js")'
# 直接调用 extractCommands + parseCommand（经 createEvaluator 的
# command/current op 等价树），对每条原用例命令断言 probe 条件
# {op:"command",scope:"current",pattern:"multica issue comment add(\\s|$)"}
# fire / not-fire（P/N 组）；M 组断言 mention 正则对 --content 参数值命中
# （content op 数据源的词法层等价断言）。
# 期望逐字节等价于 v1 移植。
# DRIFT（一行）：N06 "multica issue comment list" 在 v2 为 ^前缀锚定失败（与
# v1 not-fired 结论一致，无期望翻转）。
#
# Related Issues: SEE-1151, SEE-1330
# Author: Bachi (Backend Agent)

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); }
separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

PROJECT_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WHEN_OPS_JS="$PROJECT_ROOT/hooks/unified/when-ops.js"

if [ ! -f "$WHEN_OPS_JS" ]; then
    echo "ERROR: when-ops.js not found at $WHEN_OPS_JS"
    exit 1
fi

FIX_PWD="/tmp/see1151-ic-fixture-$$"
mkdir -p "$FIX_PWD"

# Gate A: v2 词法模块语法必须有效（Refacty 曾两次用双引号 node 字符串破坏 hook）。
# v2 对应的语法门 = node --check when-ops.js + require 成功。
separator "0. Syntax gate (node --check)"
if node --check "$WHEN_OPS_JS" 2>/dev/null; then
    pass "node --check when-ops.js"
else
    fail "node --check when-ops.js — module has syntax errors"
fi

# classify(cmp, kind): kind=comment-add | mention
# 使用 when-ops.js 的 extractCommands + parseCommand + createEvaluator（v2 词法等价树）
classify() { # $1 = raw command string ; $2 = mode(comment|mention)
    node - "$WHEN_OPS_JS" "$1" "${2:-comment}" <<'NODEEOF'
const [whenOpsPath, cmd, mode] = process.argv.slice(2);
const { createEvaluator, extractCommands, parseCommand } = require(whenOpsPath);
if (mode === 'mention') {
  // content op 数据源词法层：从 parseCommand.flags 取 --content 值测正则
  const re = new RegExp('[@][^\\]]+\\]\\(mention:\\/\\/(?:agent|member)\\/[^)]+\\)');
  let fired = false;
  for (const seg of extractCommands(cmd)) {
    const parsed = parseCommand(seg);
    if (!parsed) continue;
    const c = parsed.flags['--content'];
    if (typeof c === 'string' && re.test(c)) { fired = true; break; }
  }
  console.log(fired ? 'FIRED' : 'QUIET');
} else {
  const payload = { hook_event_name: 'PreToolUse', tool_input: { command: cmd } };
  const ev = createEvaluator(payload, { cwd: '', projectRoot: '', taskId: '' });
  const when = { op: 'command', scope: 'current', pattern: 'multica issue comment add(\\s|$)' };
  console.log(ev.evaluate(when) ? 'FIRED' : 'QUIET');
}
NODEEOF
}

RAW=""
assert_fired() {
    local label="$1" out
    out=$(classify "$RAW" comment)
    if [ "$out" = "FIRED" ]; then
        pass "$label"
    else
        fail "$label — expected rule to fire; got $out"
    fi
}

assert_not_fired() {
    local label="$1" out
    out=$(classify "$RAW" comment)
    if [ "$out" = "FIRED" ]; then
        fail "$label — rule fired but expected not to"
    else
        pass "$label"
    fi
}

assert_mention_fired() {
    local label="$1" out
    out=$(classify "$RAW" mention)
    if [ "$out" = "FIRED" ]; then
        pass "$label"
    else
        fail "$label — expected mention detection to fire; got $out"
    fi
}

separator "1. Positive cases: compound comment_add SHOULD trigger"

RAW='multica issue comment add X --content hi'
assert_fired "P01 plain comment add"

RAW='FOO=bar multica issue comment add X --content hi'
assert_fired "P02 env-prefix comment add"

RAW='echo one && multica issue comment add X --content hi'
assert_fired "P03 comment add after &&"

RAW='echo one; multica issue comment add X --content hi'
assert_fired "P04 comment add after ;"

RAW="$(printf 'echo one\nmultica issue comment add X --content hi')"
assert_fired "P05 comment add on newline"

RAW="bash -c 'multica issue comment add X --content hi'"
assert_fired "P06 bash -c single-quoted"

RAW='bash -c "multica issue comment add X --content hi"'
assert_fired "P07 bash -c double-quoted"

RAW='multica issue comment add X --content hi | tee log'
assert_fired "P08 comment add piped (lhs of |)"

RAW='false || multica issue comment add X --content hi'
assert_fired "P09 comment add after ||"

RAW='a && b && c; d; multica issue comment add X --content hi'
assert_fired "P10 deep chain"

separator "2. Negative cases: literal strings MUST NOT trigger"

RAW='echo "multica issue comment add" --foo'
assert_not_fired "N01 echo literal does not fire"

RAW='grep -r "multica issue comment add" .'
assert_not_fired "N02 grep literal does not fire"

RAW='cat some_file_with_multica_issue_comment_add_in_name'
assert_not_fired "N03 cat of similarly-named file does not fire"

RAW='git log --oneline | grep "multica issue comment add"'
assert_not_fired "N04 git log piped to grep literal does not fire"

RAW='ls -la /tmp'
assert_not_fired "N05 unrelated command does not fire"

RAW='multica issue comment list X'
assert_not_fired "N06 comment list (not add) does not fire"

RAW='multica issue create --title x'
assert_not_fired "N07 issue create does not fire"

separator "3. Mention on compound commands (production scenario; content op lexical source)"

RAW='echo prep && multica issue comment add X --content "[@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5) check"'
assert_mention_fired "M01 mention in compound command is detected"

RAW="$(printf 'echo prep\nmultica issue comment add X --content "[@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5) check"')"
assert_mention_fired "M02 mention via newline-separated compound is detected"

separator "4. Module loads cleanly (Refacty's failure mode)"

if node -e 'const m=require(process.argv[1]); if (typeof m.extractCommands==="function" && typeof m.parseCommand==="function") process.exit(0)' "$WHEN_OPS_JS" 2>/dev/null; then
    pass "S01 when-ops.js loads with no syntax error"
else
    fail "S01 when-ops.js failed to load"
fi

separator "Summary"

echo "Total: $((PASS + FAIL)) | PASS: $PASS | FAIL: $FAIL"
rm -rf "$FIX_PWD" 2>/dev/null
rm -f /tmp/skill-check-see1151-* 2>/dev/null
for _f in /tmp/.hook-fired-*; do [ -f "$_f" ] && rm -f "$_f"; done

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
    exit 0
else
    echo -e "${RED}$FAIL TEST(S) FAILED${NC}"
    exit 1
fi
