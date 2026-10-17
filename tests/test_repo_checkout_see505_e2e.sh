#!/bin/bash
# Live E2E Test for SEE-505: repo-checkout.sh hookSpecificOutput in agent loop
# Adapted for SEE-534: marker file removed, check_integrity() is sole source of truth
# Validates the three key scenarios for CC SessionStart hook behavior:
#   1. Fresh workdir, repo present -> entry check_integrity passes -> success hint
#   2. Existing marker (success) ignored -> check_integrity passes -> success hint
#   3. Existing marker (failed) ignored -> checkout succeeds -> success hint
#
# SEE-1396 hardener:
#   A. hint 断言从英文旧契约（"auto-checked out"/"cd into"/"Direct modification"，
#      hook 早不再产出）对齐到现行契约不变量。成功路径 hint 现有三个 variant
#      （fallback："Repo 已自动检出"；align："working branch checkout 到 X"；
#      auto-create："已自动创建共享分支"），随任务身份 env 而定——断言取三
#      variant 通吃的成功不变量（checkout-success + "cd 到" 指引 +
#      "严禁直接修改本地 main repo" 防护），不锚定单一 variant 文案。
#      旧断言因本套件长期 EXCLUDED 未回归而漂移（test-impl-drift）。
#   B. 真机回归边界（为何 EXCLUDED env:multica-cli 及如何真实回归）：
#      daemon 对 `multica repo checkout` 有双重门——cwd 必须在 active task
#      workdir 内（"not owned by the active task"），且须携带完整任务身份 env
#      （"task context does not match the active task"）。本套件 mktemp -d
#      沙盒默认落在 /tmp，两条门全过不去，S2/S3 的真实 checkout 必失败。
#      真实回归 recipe（在有 daemon 的 agent 环境内）：
#        TMPDIR=<active task workdir 内的目录> bash test_repo_checkout_see505_e2e.sh
#      SEE-1396 同时修复套件自身的 TMPDIR 变量冲突 bug：原第 17 行
#      `TMPDIR=""` 把继承的环境变量清空，mktemp 永远回落 /tmp——调用方传入的
#      TMPDIR 从未生效，沙盒按构造不被 daemon 认领。套件内部变量已改名
#      SANDBOX_ROOT，环境变量 TMPDIR 原样透传给 mktemp。
#      TMPDIR 进任务 workdir + 保留任务身份 env ⇒ mktemp 沙盒被 daemon 认领，
#      S2/S3 走真实 daemon-mediated checkout（被测面本体的实机回归）。S2/S3
#      沙盒 checkout 有独立 gitdir，不触碰真实检出；S1 的 align 链经 .git
#      gitfile 解析进真实 gitdir，在 HEAD==origin/<working_branch> 且
#      origin/master 为其祖先时为可证 no-op（unpushed guard/reset/§B 全跳过）。
#
# Usage: see header note B for the real-environment invocation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../claude-hooks/scripts/repo-checkout.sh"
PASS=0
FAIL=0
SANDBOX_ROOT=""

# SEE-1381 §SPEC-012: scenario_1 cp -a 复制了整库（含 .git gitfile），副本的 git
# 链解析进真实 worktree gitdir——hook 的 submodule 兜底在副本内 `git submodule
# update --init` 时会把共享 submodule module config 的 core.worktree 改写到本
# /tmp 场景路径，真实检出 `git status` 随即 fatal。快照 + EXIT 恢复根治。
# SEE-1396：保护目标从已拆除的 .dev/qa-toolkit 改到当前仍挂载的 addons/godot_mcp。
REAL_GITDIR="$(cd "$SCRIPT_DIR/.." && git rev-parse --absolute-git-dir 2>/dev/null)"
MODULE_CONFIG=""
MODULE_CONFIG_SNAP=""
if [ -n "$REAL_GITDIR" ] && [ -f "$REAL_GITDIR/modules/addons/godot_mcp/config" ]; then
    MODULE_CONFIG="$REAL_GITDIR/modules/addons/godot_mcp/config"
    MODULE_CONFIG_SNAP="$(mktemp /tmp/see505e2e-module-config.XXXXXX)"
    cp "$MODULE_CONFIG" "$MODULE_CONFIG_SNAP"
fi

cleanup() {
    [ -n "$SANDBOX_ROOT" ] && [ -d "$SANDBOX_ROOT" ] && rm -rf "$SANDBOX_ROOT"
    if [ -n "$MODULE_CONFIG_SNAP" ] && [ -f "$MODULE_CONFIG" ] \
       && ! cmp -s "$MODULE_CONFIG" "$MODULE_CONFIG_SNAP"; then
        cp "$MODULE_CONFIG_SNAP" "$MODULE_CONFIG"
    fi
    [ -n "$MODULE_CONFIG_SNAP" ] && rm -f "$MODULE_CONFIG_SNAP"
}
trap cleanup EXIT

SANDBOX_ROOT=$(mktemp -d)
REPORT=""

log_test() {
    local name="$1"
    local result="$2"
    local detail="$3"
    if [ "$result" = "PASS" ]; then
        PASS=$((PASS+1))
        REPORT="${REPORT}| $name | PASS | $detail |\n"
    else
        FAIL=$((FAIL+1))
        REPORT="${REPORT}| $name | FAIL | $detail |\n"
    fi
}

validate_json() {
    local json="$1"
    # SEE-1396 hardener: hook 一次会话可合法产出多条 hint（每条一个 JSON 文档），
    # 旧实现 json.loads 整段 stdout 在多 hint 场景必炸。契约改为：stdout 必须是
    # 可流式解析的 JSON 文档序列，且其中至少一条满足 hookSpecificOutput 契约。
    python3 -c "
import sys, json
dec = json.JSONDecoder()
raw = sys.argv[1]
idx, found = 0, 0
while idx < len(raw):
    while idx < len(raw) and raw[idx] in ' \t\r\n':
        idx += 1
    if idx >= len(raw):
        break
    try:
        d, end = dec.raw_decode(raw, idx)
    except Exception as e:
        print(f'unparseable JSON at offset {idx}: {e}', file=sys.stderr)
        sys.exit(1)
    idx = end
    found += 1
    if isinstance(d, dict) and 'hookSpecificOutput' in d:
        hso = d['hookSpecificOutput']
        assert 'hookEventName' in hso, 'missing hookEventName'
        assert hso['hookEventName'] == 'SessionStart', f'wrong event: {hso[\"hookEventName\"]}'
        assert 'additionalContext' in hso, 'missing additionalContext'
        assert len(hso['additionalContext']) > 0, 'empty additionalContext'
        sys.exit(0)
print(f'{found} JSON doc(s) parsed, none carries hookSpecificOutput', file=sys.stderr)
sys.exit(1)
" "$json" 2>/dev/null
}

scenario_1() {
    echo "=== Scenario 1: Fresh workdir (no marker), repo present ==="
    local wd="$SANDBOX_ROOT/scenario1"
    mkdir -p "$wd"
    cp -a "$SCRIPT_DIR/.." "$wd/KingOfLikes-Godot"

    local out
    out=$(cd "$wd" && bash "$HOOK_SCRIPT" 2>&1)
    local marker_content
    marker_content=$(cat "$wd/.repos-checked-out" 2>/dev/null || echo "<missing>")

    if validate_json "$out"; then
        log_test "S1: Valid hookSpecificOutput JSON" "PASS" "hookEventName=SessionStart"
    else
        log_test "S1: Valid hookSpecificOutput JSON" "FAIL" "$out"
    fi

    if [ "$marker_content" = "<missing>" ]; then
        log_test "S1: No marker written" "PASS" ""
    else
        log_test "S1: No marker written" "FAIL" "Got: $marker_content"
    fi

    if echo "$out" | grep -qE "已自动检出|checkout 到|已自动创建共享分支"; then
        log_test "S1: Hint 自动检出成功提示" "PASS" ""
    else
        log_test "S1: Hint 自动检出成功提示" "FAIL" ""
    fi

    if echo "$out" | grep -q "cd 到"; then
        log_test "S1: Hint cd 到提示" "PASS" ""
    else
        log_test "S1: Hint cd 到提示" "FAIL" ""
    fi

    if echo "$out" | grep -q "严禁直接修改本地 main repo"; then
        log_test "S1: Hint 严禁直接修改 main repo 提示" "PASS" ""
    else
        log_test "S1: Hint 严禁直接修改 main repo 提示" "FAIL" ""
    fi
}

scenario_2() {
    echo "=== Scenario 2: Existing marker (success) ==="
    local wd="$SANDBOX_ROOT/scenario2"
    mkdir -p "$wd/.multica/project"
    echo '{"resources":[]}' > "$wd/.multica/project/resources.json"
    echo "success" > "$wd/.repos-checked-out"

    local out
    out=$(cd "$wd" && bash "$HOOK_SCRIPT" 2>&1)

    if validate_json "$out"; then
        log_test "S2: Valid hookSpecificOutput JSON" "PASS" ""
    else
        log_test "S2: Valid hookSpecificOutput JSON" "FAIL" "$out"
    fi

    if echo "$out" | grep -qE "已自动检出|checkout 到|已自动创建共享分支"; then
        log_test "S2: Hint 自动检出成功提示" "PASS" ""
    else
        log_test "S2: Hint 自动检出成功提示" "FAIL" ""
    fi

    if echo "$out" | grep -q "cd 到"; then
        log_test "S2: Hint cd 到提示" "PASS" ""
    else
        log_test "S2: Hint cd 到提示" "FAIL" ""
    fi

    if echo "$out" | grep -q "严禁直接修改本地 main repo"; then
        log_test "S2: Hint 严禁直接修改 main repo 提示" "PASS" ""
    else
        log_test "S2: Hint 严禁直接修改 main repo 提示" "FAIL" ""
    fi

    local marker_after
    marker_after=$(cat "$wd/.repos-checked-out" 2>/dev/null)
    if [ "$marker_after" = "success" ]; then
        log_test "S2: Marker unchanged" "PASS" ""
    else
        log_test "S2: Marker unchanged" "FAIL" "Changed to: $marker_after"
    fi
}

scenario_3() {
    echo "=== Scenario 3: Existing marker (failed) is ignored, check_integrity decides ==="
    local wd="$SANDBOX_ROOT/scenario3"
    mkdir -p "$wd/.multica/project"
    echo '{"resources":[]}' > "$wd/.multica/project/resources.json"
    echo "failed" > "$wd/.repos-checked-out"

    local out
    out=$(cd "$wd" && bash "$HOOK_SCRIPT" 2>&1)

    if validate_json "$out"; then
        log_test "S3: Valid hookSpecificOutput JSON" "PASS" ""
    else
        log_test "S3: Valid hookSpecificOutput JSON" "FAIL" "$out"
    fi

    # After SEE-534, marker is ignored; multica checkout succeeds, so success hint
    if echo "$out" | grep -qE "已自动检出|checkout 到|已自动创建共享分支"; then
        log_test "S3: Hint 自动检出成功提示 (marker ignored)" "PASS" ""
    else
        log_test "S3: Hint 自动检出成功提示 (marker ignored)" "FAIL" ""
    fi

    if echo "$out" | grep -q "cd 到"; then
        log_test "S3: Hint cd 到提示" "PASS" ""
    else
        log_test "S3: Hint cd 到提示" "FAIL" ""
    fi

    if echo "$out" | grep -q "严禁直接修改本地 main repo"; then
        log_test "S3: Hint 严禁直接修改 main repo 提示" "PASS" ""
    else
        log_test "S3: Hint 严禁直接修改 main repo 提示" "FAIL" ""
    fi

    local marker_after
    marker_after=$(cat "$wd/.repos-checked-out" 2>/dev/null)
    if [ "$marker_after" = "failed" ]; then
        log_test "S3: Marker unchanged (not written by hook)" "PASS" ""
    else
        log_test "S3: Marker unchanged (not written by hook)" "FAIL" "Changed to: $marker_after"
    fi
}

scenario_1
scenario_2
scenario_3

echo ""
echo "========================================"
echo "Live E2E Test Report: SEE-505"
echo "========================================"
echo ""
echo "| Test Case | Result | Detail |"
echo "|-----------|--------|--------|"
printf "%b" "$REPORT"
echo ""
echo "Total: $PASS passed, $FAIL failed"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
