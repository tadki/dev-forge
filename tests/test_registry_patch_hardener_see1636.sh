#!/bin/bash
# SEE-1636 §SPEC-010 hardener 增补判别力（Harti 轮）：既有套件（19 断言）未钉住的
# registry-patch.js 行为面，每条用例对应一个独立构造变异点的 kill 判据（变异台账
# 见交付报告）：
#   K1  改指闸拒绝退出码恰为 3（§SPEC-018 专口，非任意非零）
#   K2  混合组剔除是唯一变化时 merge 仍须报 changed 并写盘（收敛信号不被渲染信号
#       掩蔽）
#   K3  既有本检出注册 matcher 漂移（matcher≠*）被 merge 收敛回声明值
#   K4  --phase P2 的 v1 禁用按 `hook-wrapper.sh <时点> <alias>` 形态命中
#   K5  非 unified-hook 形态（unified-hook 后带尾参）不属悬空收敛面，merge 保留、
#       verify 不点名
#   K6  rollback 逐字节恢复 backup 内容
#   K7  rollback 输出契约 rolled-back
#   K8  未知子命令 exit 2 + 用法 stderr
#   K9  rollback backup 不存在 → 非零退出 + rollback FAIL stderr
# 约束：全部状态在 mktemp fixture 内；不对真实 ~/.claude/settings.json 运行。
# Run:    bash tests/test_registry_patch_hardener_see1636.sh
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
POINTS=(PreToolUse PostToolUse SessionStart SessionEnd Stop SubagentStop UserPromptSubmit Notification PreCompact PostCompact PermissionRequest)
FIXTURE="$(mktemp -d /tmp/see1636-hardener-registry.XXXXXX)"
STALE="$FIXTURE/gone-checkout/claude-hooks"
mkdir -p "$STALE"

trap 'rm -rf "$FIXTURE"' EXIT

OUT=""; ERR=""; RC=0
run_patch() {  # run_patch <args...>
    OUT="$FIXTURE/patch.out"; ERR="$FIXTURE/patch.err"
    node "$PATCH" "$@" > "$OUT" 2> "$ERR"
    RC=$?
}

# 全 11 时点本检出注册（渲染零增量的前提——唯一 delta 落在被测收敛面上）
make_converged_settings() {  # make_converged_settings <out-file>
    {
        printf '{\n  "hooks": {\n'
        local first=1
        for pt in "${POINTS[@]}"; do
            [ "$first" -eq 1 ] || printf ',\n'
            printf '    "%s": [\n      { "matcher": "*", "hooks": [ { "type": "command", "command": "%s/hook-wrapper.sh %s unified-hook" } ] }\n    ]' \
                "$pt" "$HOOKS" "$pt"
            first=0
        done
        printf '\n  }\n}\n'
    } > "$1"
}

# =====================================================================
separator "K. hardener 判别力增补（registry-patch 错误出口 / 收敛信号 / v1 禁用）"
# =====================================================================

# K1 (§SPEC-018): 改指闸拒绝退出码恰为 3 —— 活检出占位 + 本检出无注册 + 无 env
LIVING="$FIXTURE/living-checkout/claude-hooks"
mkdir -p "$LIVING"
printf '#!/bin/bash\n' > "$LIVING/hook-wrapper.sh"
printf '{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"%s/hook-wrapper.sh Stop unified-hook"}]}]}}\n' \
    "$LIVING" > "$FIXTURE/k1.json"
cp "$FIXTURE/k1.json" "$FIXTURE/k1.snapshot"
run_patch merge --settings "$FIXTURE/k1.json" --manifest "$MANIFEST" --global-hooks "$HOOKS"
if [ "$RC" -eq 3 ] && grep -q "MERGE REFUSED" "$ERR" \
   && [ "$(sha256sum < "$FIXTURE/k1.json" | cut -d' ' -f1)" = "$(sha256sum < "$FIXTURE/k1.snapshot" | cut -d' ' -f1)" ]; then
    pass "K1: 改指闸拒绝 → exit 恰为 3 + MERGE REFUSED + 零写盘（§SPEC-018 专口）"
else
    fail "K1: 拒绝退出码失准 rc=$RC"
fi

# K2: 混合组剔除是唯一变化 → 仍须报 changed 并写盘（收敛信号独立于渲染信号）
# 全 11 时点已注册（渲染零增量），Stop 挂第二个混合组：悬空条目 + 组内其他命令
cat > "$FIXTURE/k2.json" <<JSON
{
  "hooks": {
    "Stop": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "$HOOKS/hook-wrapper.sh Stop unified-hook" } ] },
      { "matcher": "*", "hooks": [
        { "type": "command", "command": "hindsight k2 --keep" },
        { "type": "command", "command": "$STALE/hook-wrapper.sh Stop unified-hook" }
      ] }
    ],
    "PostToolUse": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "$HOOKS/hook-wrapper.sh PostToolUse unified-hook" } ] }
    ],
    "SessionStart": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "$HOOKS/hook-wrapper.sh SessionStart unified-hook" } ] }
    ],
    "SessionEnd": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "$HOOKS/hook-wrapper.sh SessionEnd unified-hook" } ] }
    ],
    "SubagentStop": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "$HOOKS/hook-wrapper.sh SubagentStop unified-hook" } ] }
    ],
    "UserPromptSubmit": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "$HOOKS/hook-wrapper.sh UserPromptSubmit unified-hook" } ] }
    ],
    "Notification": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "$HOOKS/hook-wrapper.sh Notification unified-hook" } ] }
    ],
    "PreCompact": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "$HOOKS/hook-wrapper.sh PreCompact unified-hook" } ] }
    ],
    "PostCompact": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "$HOOKS/hook-wrapper.sh PostCompact unified-hook" } ] }
    ],
    "PermissionRequest": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "$HOOKS/hook-wrapper.sh PermissionRequest unified-hook" } ] }
    ],
    "PreToolUse": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "$HOOKS/hook-wrapper.sh PreToolUse unified-hook" } ] }
    ]
  }
}
JSON
run_patch merge --settings "$FIXTURE/k2.json" --manifest "$MANIFEST" --global-hooks "$HOOKS"
if [ "$RC" -eq 0 ] && grep -q "changed" "$OUT" \
   && ! grep -q "$STALE/hook-wrapper.sh" "$FIXTURE/k2.json" \
   && grep -q "hindsight k2 --keep" "$FIXTURE/k2.json" \
   && grep -q "$HOOKS/hook-wrapper.sh Stop unified-hook" "$FIXTURE/k2.json"; then
    pass "K2: 仅混合组剔除 → changed + 写盘（悬空条目消失、组内其他命令保留）"
else
    fail "K2: 收敛信号被渲染信号掩蔽 rc=$RC out='$(cat "$OUT" 2>/dev/null | head -c 40)'"
fi

# K3: 既有本检出注册 matcher 漂移（Bash）→ merge 收敛回 matcher=* 单条目
printf '{"hooks":{"Stop":[{"matcher":"Bash","hooks":[{"type":"command","command":"%s/hook-wrapper.sh Stop unified-hook"},{"type":"command","command":"echo stray"}]}]}}\n' \
    "$HOOKS" > "$FIXTURE/k3.json"
run_patch merge --settings "$FIXTURE/k3.json" --manifest "$MANIFEST" --global-hooks "$HOOKS"
K3_OK=0
if command -v jq >/dev/null 2>&1; then
    jq -e '.hooks.Stop | length == 1 and .[0].matcher == "*" and (.[0].hooks | length == 1) and .[0].hooks[0].command == ("'"$HOOKS"'/hook-wrapper.sh Stop unified-hook")' \
        "$FIXTURE/k3.json" > /dev/null 2>&1 && K3_OK=1
fi
if [ "$RC" -eq 0 ] && [ "$K3_OK" -eq 1 ]; then
    pass "K3: matcher 漂移的既有注册收敛回 * + 单条目"
else
    fail "K3: matcher 收敛失准 rc=$RC state='$(cat "$FIXTURE/k3.json" 2>/dev/null | tr -d '\n' | head -c 160)'"
fi

# K4: --phase P2 v1 禁用按 `hook-wrapper.sh <时点> <alias>` 命中（auto-pr）
printf '{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"%s/hook-wrapper.sh Stop unified-hook"}]},{"matcher":"*","hooks":[{"type":"command","command":"%s/hook-wrapper.sh Stop auto-pr"}]}]}}\n' \
    "$HOOKS" "$HOOKS" > "$FIXTURE/k4.json"
run_patch merge --settings "$FIXTURE/k4.json" --manifest "$MANIFEST" --global-hooks "$HOOKS" --phase P2
if [ "$RC" -eq 0 ] && [ "$(grep -c "hook-wrapper.sh Stop auto-pr" "$FIXTURE/k4.json" 2>/dev/null)" = "0" ] \
   && grep -q "$HOOKS/hook-wrapper.sh Stop unified-hook" "$FIXTURE/k4.json"; then
    pass "K4: --phase P2 → v1 auto-pr 条目按形态禁用，v2 注册保留"
else
    fail "K4: v1 禁用未按形态命中 rc=$RC left=$(grep -c "Stop auto-pr" "$FIXTURE/k4.json" 2>/dev/null)"
fi

# K5: unified-hook 后带尾参的命令不属悬空收敛面——merge 保留、verify 不点名
make_converged_settings "$FIXTURE/k5.json"
printf '{"hooks":{"LegacyEvent":[{"matcher":"*","hooks":[{"type":"command","command":"%s/hook-wrapper.sh LegacyEvent unified-hook --persist"}]}]}}\n' \
    "$STALE" > "$FIXTURE/k5-extra.json"
node -e '
const fs = require("fs");
const base = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const extra = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
base.hooks.LegacyEvent = extra.hooks.LegacyEvent;
fs.writeFileSync(process.argv[1], JSON.stringify(base, null, 2) + "\n");
' "$FIXTURE/k5.json" "$FIXTURE/k5-extra.json"
run_patch merge --settings "$FIXTURE/k5.json" --manifest "$MANIFEST" --global-hooks "$HOOKS"
run_verify_rc=0
node "$PATCH" verify --settings "$FIXTURE/k5.json" --manifest "$MANIFEST" --global-hooks "$HOOKS" \
    > "$FIXTURE/k5-verify.out" 2> "$FIXTURE/k5-verify.err" || run_verify_rc=$?
if [ "$RC" -eq 0 ] && grep -q "unified-hook --persist" "$FIXTURE/k5.json" \
   && [ "$run_verify_rc" -eq 0 ] && grep -q "verified" "$FIXTURE/k5-verify.out"; then
    pass "K5: 尾参形态非悬空注册 → merge 保留 + verify verified"
else
    fail "K5: 尾参形态被误收敛/误点名 rc=$RC verify_rc=$run_verify_rc"
fi

# K6+K7: rollback 逐字节恢复 backup 内容 + 输出契约 rolled-back
printf '{"hooks":{"UserPromptSubmit":[{"matcher":"*","hooks":[{"type":"command","command":"hindsight recall --hook"}]}]},"k6":"original-bytes"}\n' > "$FIXTURE/k6.json"
cp "$FIXTURE/k6.json" "$FIXTURE/k6.backup"
printf '{"k6":"overwritten"}\n' > "$FIXTURE/k6.json"
run_patch rollback --settings "$FIXTURE/k6.json" --backup "$FIXTURE/k6.backup"
if [ "$RC" -eq 0 ] && grep -q "^rolled-back$" "$OUT" \
   && [ "$(sha256sum < "$FIXTURE/k6.json" | cut -d' ' -f1)" = "$(sha256sum < "$FIXTURE/k6.backup" | cut -d' ' -f1)" ]; then
    pass "K6/K7: rollback → 输出 rolled-back + backup 内容逐字节恢复"
else
    fail "K6/K7: rollback 契约失准 rc=$RC out='$(cat "$OUT" 2>/dev/null | head -c 40)'"
fi

# K8: 未知子命令 → exit 2 + 用法 stderr
run_patch frobnicate --settings "$FIXTURE/k6.json" --manifest "$MANIFEST" --global-hooks "$HOOKS"
if [ "$RC" -eq 2 ] && grep -q "用法" "$ERR"; then
    pass "K8: 未知子命令 → exit 2 + 用法 stderr"
else
    fail "K8: 用法出口失准 rc=$RC"
fi

# K9: rollback backup 不存在 → 非零退出 + rollback FAIL stderr
run_patch rollback --settings "$FIXTURE/k6.json" --backup "$FIXTURE/nonexistent.backup"
if [ "$RC" -ne 0 ] && grep -q "rollback FAIL" "$ERR"; then
    pass "K9: backup 缺失 → 非零退出 + rollback FAIL stderr"
else
    fail "K9: backup 缺失误报成功 rc=$RC"
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
