#!/bin/bash
# SEE-1636 §SPEC-013/014: registry-patch 注册链收敛与漂移可检出（行为断言）。
#
# 覆盖：
#   A. §SPEC-013 merge 收敛——渲染本检出注册后清除指向其他检出路径的
#      `hook-wrapper.sh <任意时点> unified-hook` 注册（整组清空则移除组、混合组
#      只剔除该条目）；非 unified-hook 命令（hindsight 挂载、旧 alias 条目）原样
#      保留；对已收敛 settings 重跑输出 unchanged 且文件逐字节不变。
#   B. §SPEC-014 verify 漂移检出——settings 仍有指向其他路径的 unified-hook 注册
#      时 verify exit 1 并在 stderr 列出条目；缺条目行为保持（missing 上报）；
#      经 merge 收敛后 verify 输出 verified。
#   C. doctor 联动（CLAUDE_SETTINGS 指向 fixture、隔离 HOME）——漂移时判失败
#      （inconsistent with manifest）；收敛后 §5 阶段判 PASS。
#
# 约束：全部状态在 mktemp fixture 内；不对真实 ~/.claude/settings.json 运行；
# bootstrap.sh 与 doctor.sh 零改动（doctor 经 CLAUDE_SETTINGS 注入被测）。
# Run:    bash tests/test_registry_patch_stale_prune_see1636.sh
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0; RESULTS=()
pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); RESULTS+=("PASS|$1"); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); RESULTS+=("FAIL|$1"); }
separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH="$REPO_ROOT/bootstrap/registry-patch.js"
MANIFEST="$REPO_ROOT/bootstrap/hooks-registration.json"
HOOKS="$REPO_ROOT/claude-hooks"
FIXTURE="$(mktemp -d /tmp/see1636-registry.XXXXXX)"
mkdir -p "$FIXTURE/home" "$FIXTURE/tmp"
STALE="$FIXTURE/gone-checkout/claude-hooks"

trap 'rm -rf "$FIXTURE"' EXIT

# --- fixture 构造：漂移 settings（悬空 unified-hook ×多时点 + hindsight + 旧 alias）
make_drift_settings() {  # make_drift_settings <out-file>
    cat > "$1" <<JSON
{
  "hooks": {
    "Stop": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "$STALE/hook-wrapper.sh Stop unified-hook" } ] }
    ],
    "PreToolUse": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "$STALE/hook-wrapper.sh PreToolUse unified-hook" } ] }
    ],
    "PostCompact": [
      { "matcher": "*", "hooks": [
        { "type": "command", "command": "$STALE/hook-wrapper.sh PostCompact unified-hook" },
        { "type": "command", "command": "hindsight sync --once" }
      ] }
    ],
    "Notification": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "ENVVAR=demo $STALE/hook-wrapper.sh Notification unified-hook" } ] }
    ],
    "UserPromptSubmit": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "hindsight recall --hook" } ] }
    ],
    "SessionEnd": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "$STALE/hook-wrapper.sh SessionEnd mention-check" } ] }
    ]
  }
}
JSON
}

run_merge() {  # run_merge <settings-file> [phase]
    MERGE_OUT="$FIXTURE/merge.out"; MERGE_ERR="$FIXTURE/merge.err"
    node "$PATCH" merge --settings "$1" --manifest "$MANIFEST" --global-hooks "$HOOKS" \
        ${2:+--phase "$2"} > "$MERGE_OUT" 2> "$MERGE_ERR"
    MERGE_RC=$?
}

run_verify() {  # run_verify <settings-file>
    VERIFY_OUT="$FIXTURE/verify.out"; VERIFY_ERR="$FIXTURE/verify.err"
    node "$PATCH" verify --settings "$1" --manifest "$MANIFEST" --global-hooks "$HOOKS" \
        > "$VERIFY_OUT" 2> "$VERIFY_ERR"
    VERIFY_RC=$?
}

# =====================================================================
separator "A. §SPEC-013 merge 收敛悬空注册"
# =====================================================================

make_drift_settings "$FIXTURE/drift.json"
run_merge "$FIXTURE/drift.json"
# A1: merge 成功且报告 changed
if [ "$MERGE_RC" -eq 0 ] && grep -q "changed" "$MERGE_OUT"; then
    pass "A1: merge exit 0 且输出 changed"
else
    fail "A1: merge 异常 rc=$MERGE_RC out='$(cat "$MERGE_OUT" 2>/dev/null | head -c 60)' err='$(cat "$MERGE_ERR" 2>/dev/null | head -c 60)'"
fi

# A2: 悬空 unified-hook 注册全清除（多时点 + env 前缀形态；SessionEnd mention-check
# 旧条目非 unified-hook，不计入悬空面——其保留由 A3 断言）
STALE_LEFT=$(grep "$STALE/hook-wrapper.sh" "$FIXTURE/drift.json" 2>/dev/null | grep -c "unified-hook$")
if [ "${STALE_LEFT:-1}" = "0" ]; then
    pass "A2: 指向其他检出的 unified-hook 注册全部清除（Stop/PreToolUse/PostCompact/Notification）"
else
    fail "A2: 残留悬空注册 $STALE_LEFT 条"
fi

# A3: 非 unified-hook 命令原样保留（hindsight ×2 + 旧 alias mention-check）
HS1=$(grep -c 'hindsight sync --once' "$FIXTURE/drift.json" 2>/dev/null || true)
HS2=$(grep -c 'hindsight recall --hook' "$FIXTURE/drift.json" 2>/dev/null || true)
V1=$(grep -c "$STALE/hook-wrapper.sh SessionEnd mention-check" "$FIXTURE/drift.json" 2>/dev/null || true)
if [ "${HS1:-0}" = "1" ] && [ "${HS2:-0}" = "1" ] && [ "${V1:-0}" = "1" ]; then
    pass "A3: hindsight 挂载与非 unified-hook 旧条目原样保留"
else
    fail "A3: 无关条目被误删 hs1=$HS1 hs2=$HS2 v1=$V1"
fi

# A4: 本检出 11 时点注册齐全（含悬空占据过的 Stop）
MISSING_POINTS=0
for pt in PreToolUse PostToolUse SessionStart SessionEnd Stop SubagentStop UserPromptSubmit Notification PreCompact PostCompact PermissionRequest; do
    grep -q "$HOOKS/hook-wrapper.sh $pt unified-hook" "$FIXTURE/drift.json" || MISSING_POINTS=$((MISSING_POINTS+1))
done
if [ "$MISSING_POINTS" -eq 0 ]; then
    pass "A4: 本检出 11 时点 unified-hook 注册全部渲染"
else
    fail "A4: 缺 $MISSING_POINTS 个时点注册"
fi

# A5: 混合组只剔除悬空条目，组内 hindsight 仍在同组（unified-hook 悬空面清零）
if grep -q '"hindsight sync --once"' "$FIXTURE/drift.json" \
   && [ "$(grep "$STALE/hook-wrapper.sh" "$FIXTURE/drift.json" 2>/dev/null | grep -c "unified-hook$")" = "0" ]; then
    pass "A5: 混合组收敛 = 剔除悬空条目、保留组内其他命令"
else
    fail "A5: 混合组收敛失真"
fi

# A6: 幂等——重跑输出 unchanged 且文件逐字节不变
cp "$FIXTURE/drift.json" "$FIXTURE/drift.snapshot"
run_merge "$FIXTURE/drift.json"
if [ "$MERGE_RC" -eq 0 ] && grep -q "unchanged" "$MERGE_OUT" \
   && [ "$(sha256sum < "$FIXTURE/drift.json" | cut -d' ' -f1)" = "$(sha256sum < "$FIXTURE/drift.snapshot" | cut -d' ' -f1)" ]; then
    pass "A6: 已收敛 settings 重跑 → unchanged 且零写盘"
else
    fail "A6: 幂等失效 rc=$MERGE_RC out='$(cat "$MERGE_OUT" 2>/dev/null | head -c 60)'"
fi

# =====================================================================
separator "B. §SPEC-014 verify 漂移检出"
# =====================================================================

# B1: 漂移 settings → verify exit 1，stderr 列出悬空条目
make_drift_settings "$FIXTURE/drift2.json"
run_verify "$FIXTURE/drift2.json"
if [ "$VERIFY_RC" -eq 1 ] && grep -q "VERIFY FAIL" "$VERIFY_ERR" \
   && grep -qF "$STALE/hook-wrapper.sh PostCompact unified-hook" "$VERIFY_ERR"; then
    pass "B1: 漂移 settings → verify exit 1 + stderr 列出悬空条目"
else
    fail "B1: 漂移未被检出 rc=$VERIFY_RC err='$(cat "$VERIFY_ERR" 2>/dev/null | head -c 100)'"
fi

# B2: 缺条目行为保持——空 settings → exit 1 + missing 上报
printf '{}\n' > "$FIXTURE/empty-settings.json"
run_verify "$FIXTURE/empty-settings.json"
if [ "$VERIFY_RC" -eq 1 ] && grep -q "missing" "$VERIFY_ERR"; then
    pass "B2: 缺注册 → verify exit 1 + missing 上报（既有行为保持）"
else
    fail "B2: missing 行为回退 rc=$VERIFY_RC"
fi

# B3: 收敛后 → verify 输出 verified
make_drift_settings "$FIXTURE/drift3.json"
run_merge "$FIXTURE/drift3.json"
run_verify "$FIXTURE/drift3.json"
if [ "$VERIFY_RC" -eq 0 ] && grep -q "verified" "$VERIFY_OUT"; then
    pass "B3: merge 收敛后 → verify exit 0 + verified"
else
    fail "B3: 收敛后 verify 未通过 rc=$VERIFY_RC out='$(cat "$VERIFY_OUT" 2>/dev/null | head -c 60)'"
fi

# =====================================================================
separator "C. doctor 联动（CLAUDE_SETTINGS=fixture，隔离 HOME）"
# =====================================================================

run_doctor() {  # run_doctor <settings-file> <out-file>
    HOME="$FIXTURE/home" TMPDIR="$FIXTURE/tmp" XDG_DATA_HOME="$FIXTURE/tmp" MULTICA_HOME="$FIXTURE/tmp" \
        CLAUDE_SETTINGS="$1" bash "$REPO_ROOT/bootstrap/doctor.sh" > "$2" 2>&1
    DOCTOR_RC=$?
}

# doctor 漂移 fixture：本检出有效注册（doctor §5 的 grep 前置条件）+ 悬空注册并存
# ——复刻现网真实形态（10 条有效 + N 条指向已删除检出）。
make_doctor_drift_settings() {  # make_doctor_drift_settings <out-file>
    cat > "$1" <<JSON
{
  "hooks": {
    "Stop": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "$HOOKS/hook-wrapper.sh Stop unified-hook" } ] },
      { "matcher": "*", "hooks": [ { "type": "command", "command": "$STALE/hook-wrapper.sh Stop unified-hook" } ] }
    ],
    "UserPromptSubmit": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "hindsight recall --hook" } ] }
    ]
  }
}
JSON
}

# C1: 漂移 settings（有效+悬空并存）→ doctor 判失败且归因 §5 注册不一致
make_doctor_drift_settings "$FIXTURE/doctor-drift.json"
run_doctor "$FIXTURE/doctor-drift.json" "$FIXTURE/doctor-drift.log"
if [ "$DOCTOR_RC" -eq 1 ] && grep -q "settings registered but inconsistent with manifest" "$FIXTURE/doctor-drift.log"; then
    pass "C1: 漂移 settings → doctor exit 1（inconsistent with manifest）"
else
    fail "C1: doctor 漂移判定失效 rc=$DOCTOR_RC tail='$(tail -3 "$FIXTURE/doctor-drift.log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | head -c 120)'"
fi

# C2: 经 merge 收敛 → doctor §5 阶段判 PASS（registered → this checkout）。
# 注：本仓 doctor ④b 存量 KOL 字面量命中（origin/main 既有，repos.json notes 与
# harness-console-plan.md 示例），doctor 总退出码在存量漂移修复前恒为 1——本断言
# 只锁 §SPEC-014 关心的注册阶段行为，不以总退出码判定。
run_merge "$FIXTURE/doctor-drift.json"
run_doctor "$FIXTURE/doctor-drift.json" "$FIXTURE/doctor-ok.log"
if grep -q "settings registered → this checkout" "$FIXTURE/doctor-ok.log" \
   && ! grep -q "settings registered but inconsistent" "$FIXTURE/doctor-ok.log"; then
    pass "C2: 收敛后 → doctor §5 判 registered → this checkout"
else
    fail "C2: doctor 收敛判定失效 tail='$(tail -5 "$FIXTURE/doctor-ok.log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | head -c 160)'"
fi

# =====================================================================
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
