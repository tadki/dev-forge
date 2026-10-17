#!/bin/bash
# SEE-1388 S3 hardener 判别性套件：§SPEC-001 grep -a 防线 + §SPEC-002 firelog 落点单源化。
# 判别目标（修正确置反向后本套件必红）：
#   SPEC-001 — daemon.log 含 NUL 字节时 picked-task 反查仍解析出 issue（grep -a 防线）；
#             回退为裸 grep → GNU grep 判 binary 仅出 "Binary file matches"，反查静默失效即红。
#   SPEC-002 — 三入口（unified-hook/hook-wrapper/dispatcher）source 单源 lib（契约断言）；
#             lib 与 engine.js resolveFirelogPath 同 env 同落点（5 场景对照，引擎侧以
#             payload-parse ERROR 实写落点取证）；入口错误行实落 lib 解析路径。
# Run: bash .dev/tests/hooks/test_see1388_firelog_issue_lookup.sh
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); }
separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTRY="$REPO_ROOT/hooks/unified/unified-hook.sh"
ENGINE="$REPO_ROOT/hooks/unified/engine.js"
LIB="$REPO_ROOT/hooks/scripts/lib/hook-fire-path.lib.sh"
WRAPPER="$REPO_ROOT/hooks/hook-wrapper.sh"
DISPATCHER="$REPO_ROOT/hooks/dispatcher.sh"

FIXTURE="$(mktemp -d /tmp/see1388-s1s2.XXXXXX)"
ISSUE_ID="01a12168-180d-702e-a40b-597e3d0938ff"
RUN_ID="s1388-run-a"
ISSUE_CACHE="/tmp/.hook-issue-id-${RUN_ID}"

cleanup_fixtures() {
    rm -rf "$FIXTURE"
    rm -f "$ISSUE_CACHE"
}
trap cleanup_fixtures EXIT

printf '{}' > "$FIXTURE/stdin.json"

# 回显 HOOK_ISSUE_ID 的桩引擎（经入口 export 的 env 取证反查结果）
STUB="$FIXTURE/stub-engine.js"
cat > "$STUB" <<'EOF'
process.stdout.write('ISSUE=' + (process.env.HOOK_ISSUE_ID || ''));
EOF

run_entry_with() {
    # $@ = env 赋值；stdin 走文件重定向（规避管道写者饥饿，对齐 p0 套件先例）
    HOOK_STDOUT=$(env "$@" bash "$ENTRY" < "$FIXTURE/stdin.json" 2>/dev/null)
}

#####################################################################
separator "1. SPEC-001 daemon.log picked-task 反查（grep -a 防线）"
#####################################################################

# 1a: daemon.log 含 NUL 字节（CC 输出混入形态）→ 反查仍解析出 issue
DL_BIN="$FIXTURE/daemon-binary.log"
printf 'noise line\nbinary\0garbage\0\0 bytes\n[2026-10-09T12:00:00Z] picked task id=9 task=%s issue=%s state=running\ntrailer\0bytes\n' "$RUN_ID" "$ISSUE_ID" > "$DL_BIN"
rm -f "$ISSUE_CACHE"
run_entry_with MULTICA_TASK_ID="$RUN_ID" MULTICA_DAEMON_LOG="$DL_BIN" \
    MULTICA_ISSUE_ID="" HOOK_ISSUE_ID="" \
    UNIFIED_ENGINE_JS="$STUB" HOOK_FIRE_LOG="$FIXTURE/fire-1a.log"
if [ "$HOOK_STDOUT" = "ISSUE=$ISSUE_ID" ]; then
    pass "1a: NUL 字节 daemon.log 反查解析出 issue（grep -a 生效）"
else
    fail "1a: 含 NUL daemon.log 反查失效 got='${HOOK_STDOUT:0:80}'（grep -a 防线缺失？）"
fi
# 旁证：fixture 确为 grep 语义下的 binary（裸 grep 只出 Binary file matches）
if grep "picked task" "$DL_BIN" 2>/dev/null | grep -q "task=$RUN_ID"; then
    fail "1a: fixture 自证失败——裸 grep 竟能命中，NUL fixture 未构成 binary 场景"
else
    pass "1a: fixture 自证——裸 grep 对该 fixture 无文本命中（binary 场景成立）"
fi

# 1b: 纯文本 daemon.log → 反查正常（sanity，防线不破坏既有行为）
DL_TXT="$FIXTURE/daemon-text.log"
printf '[2026-10-09T12:00:00Z] picked task id=9 task=%s issue=%s state=running\n' "$RUN_ID" "$ISSUE_ID" > "$DL_TXT"
rm -f "$ISSUE_CACHE"
run_entry_with MULTICA_TASK_ID="$RUN_ID" MULTICA_DAEMON_LOG="$DL_TXT" \
    MULTICA_ISSUE_ID="" HOOK_ISSUE_ID="" \
    UNIFIED_ENGINE_JS="$STUB" HOOK_FIRE_LOG="$FIXTURE/fire-1b.log"
[ "$HOOK_STDOUT" = "ISSUE=$ISSUE_ID" ] && pass "1b: 纯文本 daemon.log 反查正常" \
    || fail "1b: 纯文本反查被破坏 got='${HOOK_STDOUT:0:80}'"

# 1c: 无匹配 picked 行 → 留空降级（fail-open 语义不变）
DL_NONE="$FIXTURE/daemon-nomatch.log"
printf 'picked task id=9 task=other-run issue=should-not-pick state=running\n' > "$DL_NONE"
rm -f "$ISSUE_CACHE"
run_entry_with MULTICA_TASK_ID="$RUN_ID" MULTICA_DAEMON_LOG="$DL_NONE" \
    MULTICA_ISSUE_ID="" HOOK_ISSUE_ID="" \
    UNIFIED_ENGINE_JS="$STUB" HOOK_FIRE_LOG="$FIXTURE/fire-1c.log"
[ "$HOOK_STDOUT" = "ISSUE=" ] && pass "1c: 无匹配 picked 行 → 留空降级（fail-open）" \
    || fail "1c: 误取他人 issue got='${HOOK_STDOUT:0:80}'"

# 1d: 契约——picked-task 反查行携带 grep -a（§SPEC-001 判据命令）
if grep -n 'grep -a "picked task"' "$ENTRY" >/dev/null 2>&1; then
    pass "1d: unified-hook.sh picked-task 反查行含 grep -a（契约）"
else
    fail "1d: picked-task 反查行缺 grep -a（契约破坏）"
fi

#####################################################################
separator "2. SPEC-002 单源契约：三入口 source lib"
#####################################################################

for f in "$ENTRY" "$WRAPPER" "$DISPATCHER"; do
    name="$(basename "$f")"
    if grep -q 'hook-fire-path.lib.sh' "$f" && grep -q 'resolve_hook_fire_log_path' "$f"; then
        pass "2-contract: $name source 单源 lib 并调 resolve_hook_fire_log_path"
    else
        fail "2-contract: $name 未接单源 lib（内联解析回潮？）"
    fi
done
[ -f "$LIB" ] && grep -q 'resolve_hook_fire_log_path()' "$LIB" \
    && pass "2-contract: lib 存在且定义 resolve_hook_fire_log_path" \
    || fail "2-contract: lib 缺失或未定义解析函数"

#####################################################################
separator "3. SPEC-002 同 env 同落点：lib(bash) × engine.js 5 场景对照"
#####################################################################

# bash 启动会把 PWD 重置为物理 cwd（实测），故两側统一以 cd 锚定场景 PWD；
# 引擎侧以 malformed payload 触发 payload-parse ERROR 实写落点取证。
resolve_via_lib() { # $1=cd 目录；其余 env 由调用方 export
    ( cd "$1" && env -i PATH="$PATH" HOME="$E_HOME" \
        PROJECT_ROOT="${E_PROJECT_ROOT:-}" CLAUDE_PROJECT_DIR="${E_CLAUDE_PROJECT_DIR:-}" \
        HOOK_FIRE_LOG="${E_HOOK_FIRE_LOG:-}" \
        bash -c '. "$1" && resolve_hook_fire_log_path' _ "$LIB" )
}
engine_write_path() { # $1=cd 目录；$2..=候选落点清单（找出实写者）
    local dir="$1"; shift
    ( cd "$dir" && printf 'not-json' | env -i PATH="$PATH" HOME="$E_HOME" PWD="$dir" \
        PROJECT_ROOT="${E_PROJECT_ROOT:-}" CLAUDE_PROJECT_DIR="${E_CLAUDE_PROJECT_DIR:-}" \
        HOOK_FIRE_LOG="${E_HOOK_FIRE_LOG:-}" \
        node "$ENGINE" >/dev/null 2>&1 )
    local p
    for p in "$@"; do
        [ -f "$p" ] && grep -q 'payload-parse' "$p" 2>/dev/null && { printf '%s' "$p"; return 0; }
    done
    return 1
}
assert_scenario() { # $1=label $2=cd目录 $3=期望落点 $4..=候选清单
    local label="$1" dir="$2" expected="$3"; shift 3
    local lib_path eng_path
    lib_path="$(resolve_via_lib "$dir")"
    eng_path="$(engine_write_path "$dir" "$@")"
    if [ "$lib_path" = "$expected" ] && [ "$eng_path" = "$expected" ]; then
        pass "$label: lib 与 engine 同落点 $expected"
    else
        fail "$label: lib='$lib_path' engine='$eng_path' expected='$expected'"
    fi
}

E_HOME="$FIXTURE/home"; mkdir -p "$E_HOME"

# 3A: HOOK_FIRE_LOG 注入（测试通道，最高优先级）
SC="$FIXTURE/scen-a"; mkdir -p "$SC/cwd"
E_HOOK_FIRE_LOG="$SC/custom.log"; : > "$SC/custom.log"
assert_scenario "3A HOOK_FIRE_LOG 注入" "$SC/cwd" "$SC/custom.log" "$SC/custom.log"
unset E_HOOK_FIRE_LOG

# 3B: PROJECT_ROOT 带 .claude（cwd 无 .claude）
SC="$FIXTURE/scen-b"; mkdir -p "$SC/proj/.claude" "$SC/cwd"
E_PROJECT_ROOT="$SC/proj"
assert_scenario "3B PROJECT_ROOT 落点" "$SC/cwd" "$SC/proj/.claude/hook-fire.log" "$SC/proj/.claude/hook-fire.log"
unset E_PROJECT_ROOT

# 3C: 仅 cwd 带 .claude
SC="$FIXTURE/scen-c"; mkdir -p "$SC/cwd/.claude"
assert_scenario "3C PWD 落点" "$SC/cwd" "$SC/cwd/.claude/hook-fire.log" "$SC/cwd/.claude/hook-fire.log"

# 3D: cwd 无 .claude，子目录 repo/.claude（Multica workdir 形态）
SC="$FIXTURE/scen-d"; mkdir -p "$SC/cwd/repo/.claude"
assert_scenario "3D PWD 子目录扫描" "$SC/cwd" "$SC/cwd/repo/.claude/hook-fire.log" "$SC/cwd/repo/.claude/hook-fire.log"

# 3E: 全空 → HOME 全局兜底
SC="$FIXTURE/scen-e"; mkdir -p "$SC/cwd" "$SC/home2/.claude"
E_HOME="$SC/home2"
assert_scenario "3E HOME 全局兜底" "$SC/cwd" "$SC/home2/.claude/hook-fire.log" "$SC/home2/.claude/hook-fire.log"
E_HOME="$FIXTURE/home"

#####################################################################
separator "4. SPEC-002 入口集成：错误行实落 lib 解析路径"
#####################################################################

# 4a: unified-hook 引擎缺失 ERROR → 落 PROJECT_ROOT/.claude/hook-fire.log（lib 解析）
SC="$FIXTURE/int-a"; mkdir -p "$SC/proj/.claude" "$SC/cwd"
( cd "$SC/cwd" && PROJECT_ROOT="$SC/proj" CLAUDE_PROJECT_DIR="" HOOK_FIRE_LOG="" \
    UNIFIED_ENGINE_JS="$SC/nonexistent-engine.js" \
    bash "$ENTRY" < "$FIXTURE/stdin.json" >/dev/null 2>&1 )
if grep -q 'ERROR engine-missing' "$SC/proj/.claude/hook-fire.log" 2>/dev/null; then
    pass "4a: unified-hook 错误行落 lib 解析路径（PROJECT_ROOT/.claude）"
else
    fail "4a: 错误行未落 lib 解析路径（$SC/proj/.claude/hook-fire.log 无 engine-missing）"
fi

# 4b: dispatcher 在 Multica workdir 形态下写自身行 → 落 repo/.claude/hook-fire.log；
#     未知 alias 静默透传（fail-open 既有语义）
SC="$FIXTURE/int-b"; mkdir -p "$SC/wd/repo/.claude/hooks"
DISP_OUT="$(cd "$SC/wd" && TARGET_REPO_ROOT="" CLAUDE_PROJECT_DIR="" bash "$DISPATCHER" unknown-alias < "$FIXTURE/stdin.json" 2>/dev/null)"
if grep -q '\[dispatcher.sh\] alias=unknown-alias' "$SC/wd/repo/.claude/hook-fire.log" 2>/dev/null; then
    pass "4b: dispatcher 行落 workdir 子仓库 firelog（PROJECT_ROOT_CANON 经 lib）"
else
    fail "4b: dispatcher 行未落预期 firelog（$SC/wd/repo/.claude/hook-fire.log）"
fi
[ "$DISP_OUT" = '{}' ] && pass "4b: 未知 alias 静默透传（fail-open 语义不变）" \
    || fail "4b: 未知 alias 透传被破坏 got='${DISP_OUT:0:60}'"

#####################################################################
echo ""
echo -e "${CYAN}Results:${NC} Passed=$PASS Failed=$FAIL"
if [ "$FAIL" -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "SOME TESTS FAILED"
    exit 1
fi
