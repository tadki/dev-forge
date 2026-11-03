#!/bin/bash
# SEE-1429 bootstrap 契约测试（取代 SEE-1330 P0 installer 测试——旧版针对已退役的
# install-hooks.sh 子命令 CLI，59 个失败全因 install 链跑不起来，2026-11-03 重写）
# All operations run against FIXTURE paths only — never the real
# ~/.claude/settings.json or ~/.claude/hooks/.
# bootstrap.sh 真实契约（editable 单一真源，运行期零部署）：
#   bootstrap.sh [SETTINGS_PATH]      备份（无条件）→ registry-patch merge（P0，幂等）→ verify
#   bootstrap.sh --write-toolchain-env --target-repo-root DIR   修订 B：toolchain env
# 渲染的注册链直指本仓检出 claude-hooks/（无 fixture 部署位概念）。
# Covers: render/patch 10-point registration, unrelated-field preservation,
#         v1 preservation under P0, idempotency (2nd run diff=0),
#         unconditional pre-merge backup, rollback (default latest / explicit),
#         editable artifacts presence + exec bits in repo checkout,
#         firelog unified-hook result line via repo-checkout chain,
#         backup/rollback round-trip stability.
# Run:    bash tests/test_v2_installer_p0.sh
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0; RESULTS=()
pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); RESULTS+=("PASS|$1"); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); RESULTS+=("FAIL|$1"); }
separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$REPO_ROOT/bootstrap/bootstrap.sh"
ROLLBACK="$REPO_ROOT/bootstrap/rollback.sh"
PATCHER="$REPO_ROOT/bootstrap/registry-patch.js"
MANIFEST="$REPO_ROOT/bootstrap/hooks-registration.json"
WRAPPER_DIR="$REPO_ROOT/claude-hooks"
FIXTURE="$(mktemp -d /tmp/v2installer-p0.XXXXXX)"
SETTINGS="$FIXTURE/home/.claude/settings.json"

trap 'rm -rf "$FIXTURE"' EXIT

POINTS=(PreToolUse PostToolUse SessionStart SessionEnd Stop SubagentStop UserPromptSubmit Notification PreCompact PermissionRequest)

count_v2_entries() {
    # 统计 settings 中 unified-hook 注册条目数
    node -e "
const s = require('$SETTINGS');
let n = 0;
for (const point of Object.keys(s.hooks || {})) {
  for (const g of s.hooks[point] || []) {
    for (const h of g.hooks || []) if ((h.command||'').endsWith(' unified-hook')) n++;
  }
}
console.log(n);
" 2>/dev/null
}

count_v1_entries() {
    node -e "
const s = require('$SETTINGS');
let n = 0;
for (const p of Object.keys(s.hooks||{})) for (const g of s.hooks[p]||[]) for (const h of g.hooks||[])
  if (!/ unified-hook\$/.test(h.command||'')) n++;
console.log(n);
" 2>/dev/null
}

echo "============================================================"
echo "  SEE-1429: bootstrap.sh contract test (fixture-only)"
echo "  Date: $(date -Iseconds)"
echo "============================================================"

separator "0. Prerequisites + CLI hygiene"
[ -f "$INSTALLER" ] && pass "bootstrap.sh exists" || { fail "bootstrap.sh MISSING"; exit 1; }
[ -f "$ROLLBACK" ] && pass "rollback.sh exists" || fail "rollback.sh MISSING"
[ -f "$PATCHER" ] && pass "registry-patch.js exists" || fail "registry-patch.js MISSING"
[ -f "$MANIFEST" ] && pass "hooks-registration.json exists" || { fail "manifest MISSING"; exit 1; }
node -e "const m=require('$MANIFEST'); if (m.hook_points.length !== 10) process.exit(1)" 2>/dev/null \
    && pass "manifest declares 10 hook points" || fail "manifest hook_points != 10"
node -e "const m=require('$MANIFEST'); process.exit(m.phases.P0.disable_v1.length===0?0:1)" 2>/dev/null \
    && pass "manifest P0 disable_v1 empty (first-install keeps v1)" || fail "P0 disable_v1 not empty — fixture v1 expectations stale"

# 0a settings 缺失 → 快速失败（旧测试误用 install 子命令踩中的正是这条错误路径）
OUT=$(bash "$INSTALLER" "$FIXTURE/absent.json" 2>&1); RC=$?
[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "settings not found" \
    && pass "0a: missing settings fails fast (settings not found)" \
    || fail "0a: missing settings: rc=$RC out='${OUT:0:80}'"

# 0b --write-toolchain-env：HOME 定向 fixture，真机 ~/.config 零接触
TRT="$FIXTURE/target-repo"; mkdir -p "$TRT/.dev"
OUT=$(HOME="$FIXTURE/home" bash "$INSTALLER" --write-toolchain-env --target-repo-root "$TRT" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && grep -q "TARGET_REPO_ROOT=$TRT" "$FIXTURE/home/.config/dev-forge/toolchain.env" 2>/dev/null; then
    pass "0b: --write-toolchain-env writes TARGET_REPO_ROOT under fixture HOME"
else
    fail "0b: write-toolchain-env rc=$RC out='${OUT:0:80}'"
fi
OUT=$(HOME="$FIXTURE/home" bash "$INSTALLER" --write-toolchain-env --target-repo-root "$FIXTURE" 2>&1); RC=$?
[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "\.dev" \
    && pass "0b2: target without .dev/ rejected" \
    || fail "0b2: missing .dev/ target accepted (rc=$RC)"

# fixture：带无关字段 + v1 注册样本的用户级 settings
mkdir -p "$(dirname "$SETTINGS")"
cat > "$SETTINGS" <<'EOF'
{
  "permissions": {"allow": ["Bash(echo '')"]},
  "enableAllProjectMcpServers": true,
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "/home/jerry/.claude/hooks/hook-wrapper.sh PreToolUse push-guard"}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "/home/jerry/.claude/hooks/hook-wrapper.sh PreToolUse mention-check"}]},
      {"matcher": "*", "hooks": [{"type": "command", "command": "/home/jerry/.claude/hooks/hook-wrapper.sh PreToolUse skill-check"}]}
    ],
    "Stop": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "/home/jerry/.claude/hooks/hook-wrapper.sh Stop auto-pr"}]}
    ],
    "SessionStart": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "/home/jerry/.claude/hooks/hook-wrapper.sh SessionStart repo-checkout"}]}
    ]
  }
}
EOF
cp "$SETTINGS" "$FIXTURE/original-settings.json"
pass "fixture settings prepared (v1 registrations + unrelated fields)"

#####################################################################
# 1. 首次安装：10 时点注册渲染（指向本仓检出）+ 无关字段/v1 保留
#####################################################################
separator "1. First install"
bash "$INSTALLER" "$SETTINGS" > "$FIXTURE/install1.log" 2>&1
[ $? -eq 0 ] && pass "1a: bootstrap exits 0" || { fail "1a: bootstrap failed: $(cat "$FIXTURE/install1.log")"; }

MISSING=0
for P in "${POINTS[@]}"; do
    node -e "
const s = require('$SETTINGS');
const want = '$WRAPPER_DIR/hook-wrapper.sh $P unified-hook';
const groups = (s.hooks||{})['$P'] || [];
const ok = groups.some(g => (g.hooks||[]).some(h => h.command === want && g.matcher === '*'));
process.exit(ok ? 0 : 1);
" 2>/dev/null || MISSING=1
done
[ "$MISSING" -eq 0 ] && pass "1b: all 10 points registered, matcher=*, command→repo checkout" || fail "1b: some points missing/wrong path/matcher"

node -e "
const s = require('$SETTINGS');
if (s.permissions && s.permissions.allow && s.permissions.allow.length === 1 && s.enableAllProjectMcpServers === true) process.exit(0);
process.exit(1);
" 2>/dev/null && pass "1c: unrelated fields preserved" || fail "1c: unrelated fields lost"

V1_COUNT=$(count_v1_entries)
[ "$V1_COUNT" -eq 5 ] && pass "1d: v1 entries preserved under P0 (count=5)" || fail "1d: v1 entries count $V1_COUNT != 5"

grep -q "hook points registered" "$FIXTURE/install1.log" \
    && pass "1e: verify OK reported by bootstrap" || fail "1e: no verify-OK in bootstrap log"

#####################################################################
# 2. 幂等：二次运行 settings diff=0（契约：备份无条件，每次运行 +1）
#####################################################################
separator "2. Idempotency"
cp "$SETTINGS" "$FIXTURE/after1.json"
BAK_COUNT_1=$(ls "$(dirname "$SETTINGS")" | grep -c "settings.json.bak-bootstrap-" || true)
bash "$INSTALLER" "$SETTINGS" > "$FIXTURE/install2.log" 2>&1
[ $? -eq 0 ] && pass "2a: 2nd bootstrap exits 0" || fail "2a: 2nd bootstrap failed"
if cmp -s "$FIXTURE/after1.json" "$SETTINGS"; then
    pass "2b: 2nd bootstrap diff=0"
else
    fail "2b: 2nd bootstrap changed settings"
fi
BAK_COUNT_2=$(ls "$(dirname "$SETTINGS")" | grep -c "settings.json.bak-bootstrap-" || true)
[ "$BAK_COUNT_2" -eq "$((BAK_COUNT_1 + 1))" ] && pass "2c: backup +1 per run (unconditional pre-merge contract)" \
    || fail "2c: backup count $BAK_COUNT_1 → $BAK_COUNT_2"
V2_N=$(count_v2_entries)
[ "$V2_N" -eq 10 ] && pass "2d: no duplicate v2 entries (count=10)" || fail "2d: v2 entries = $V2_N (duplication?)"

# 无关临时文件无残留
TMP_LEFT=$(ls "$(dirname "$SETTINGS")" | grep -c "\.tmp\." || true)
[ "$TMP_LEFT" -eq 0 ] && pass "2e: no tmp residue (atomic write)" || fail "2e: tmp files left: $TMP_LEFT"

#####################################################################
# 3. 备份存在且最早一代 = 安装前原貌
#####################################################################
separator "3. Backups"
BACKUPS=( "$(dirname "$SETTINGS")/"settings.json.bak-bootstrap-* )
[ -f "${BACKUPS[0]}" ] && pass "3a: backup file exists (${BACKUPS[0]##*/})" || fail "3a: no backup found"
if cmp -s "${BACKUPS[0]}" "$FIXTURE/original-settings.json"; then
    pass "3b: earliest backup = pre-install settings"
else
    fail "3b: earliest backup content differs from original"
fi

#####################################################################
# 4. 回滚：缺省取最新一代；显式 --backup 取任意代；重装回到同一终态
#####################################################################
separator "4. Rollback"
bash "$ROLLBACK" --settings "$SETTINGS" > "$FIXTURE/rollback1.log" 2>&1
[ $? -eq 0 ] && pass "4a: rollback (default latest) exits 0" || fail "4a: rollback failed: $(cat "$FIXTURE/rollback1.log")"
if cmp -s "$SETTINGS" "$FIXTURE/after1.json"; then
    pass "4b: default rollback restores latest pre-run state"
else
    fail "4b: default rollback content mismatch"
fi
bash "$ROLLBACK" --settings "$SETTINGS" --backup "${BACKUPS[0]}" > /dev/null 2>&1
cmp -s "$SETTINGS" "$FIXTURE/original-settings.json" \
    && pass "4c: explicit --backup restores original pre-install state" \
    || fail "4c: explicit rollback content mismatch"
bash "$INSTALLER" "$SETTINGS" > /dev/null 2>&1
cmp -s "$FIXTURE/after1.json" "$SETTINGS" && pass "4d: reinstall reaches same end state" || fail "4d: reinstall diverged"

#####################################################################
# 5. editable 单源：注册链指向的本仓运行物在位 + 入口可执行
#    （取代旧 6/9b/9c 部署位断言——editable 模型无独立部署位）
#####################################################################
separator "5. Editable runtime artifacts (repo checkout)"
ART_MISSING=0
for A in $(node -e "const m=require('$MANIFEST'); console.log(m.runtime_artifacts.join(' '))"); do
    [ -f "$WRAPPER_DIR/$A" ] || { ART_MISSING=1; fail "5a: repo artifact missing: $A"; }
done
[ "$ART_MISSING" -eq 0 ] && pass "5a: all runtime_artifacts present in repo checkout" || true

# 入口可执行位：链路入口 + executable_artifacts + scripts/*.sh（排除 lib 库文件）
EXEC_MISSING=0
for A in dispatcher.sh hook-wrapper.sh $(node -e "const m=require('$MANIFEST'); console.log((m.executable_artifacts||[]).join(' '))") \
         $(node -e "const m=require('$MANIFEST'); console.log(m.runtime_artifacts.filter(a=>a.startsWith('scripts/')&&!a.includes('/lib/')&&!a.endsWith('.lib.sh')).join(' '))"); do
    [ -x "$WRAPPER_DIR/$A" ] || { EXEC_MISSING=1; fail "5b: not executable: $A"; }
done
[ "$EXEC_MISSING" -eq 0 ] && pass "5b: entry-point .sh artifacts executable in repo checkout" || true

# 5c 清单覆盖挂载脚本全集（事故 6 回归钉，与部署无关的清单完整性）
MOUNT_SCRIPTS=$(node -e "
const r = require('$REPO_ROOT/claude-hooks/unified/rules.d/runscript-mounts.json');
const m = require('$MANIFEST');
const need = [...new Set(r.rules.filter(x=>x.action[0].op==='run_script').map(x=>x.action[0].path.replace('\${HOOKS_DIR}/','')))].sort();
const have = m.runtime_artifacts.filter(a=>!a.startsWith('unified/')).sort();
const missing = need.filter(n=>!have.includes(n));
console.log(missing.length === 0 ? 'COMPLETE' : 'MISSING:' + missing.join(','));
" 2>/dev/null)
[ "$MOUNT_SCRIPTS" = "COMPLETE" ] && pass "5c: manifest covers all rules.d run_script targets" \
    || fail "5c: manifest incomplete — $MOUNT_SCRIPTS"

# 5d SEE-1388 §SPEC-006：链路组件显式在册（清单条目被摘除时 5c 不变红，此为盲区钉）
LINK_COMPONENTS="hook-wrapper.sh dispatcher.sh scripts/mcp-tool-presence.sh scripts/godot-mcp-launch-path.lib.sh scripts/lib/gitlink-probe.sh scripts/lib/gitlink-sync-hint.sh scripts/lib/hook-fire-path.lib.sh"
MANIFEST_MISSING=""
for C in $LINK_COMPONENTS; do
    node -e "const m=require('$MANIFEST'); process.exit((m.runtime_artifacts||[]).includes('$C')?0:1)" \
        || MANIFEST_MISSING="$MANIFEST_MISSING $C"
done
[ -z "$MANIFEST_MISSING" ] && pass "5d: 7 链路组件全在 runtime_artifacts（SPEC-006）" \
    || fail "5d: runtime_artifacts 缺链路组件:$MANIFEST_MISSING"

#####################################################################
# 6. firelog 链路（本仓检出运行单元，规则经 UNIFIED_RULES_FILE 覆盖层注入）
#####################################################################
separator "6. firelog unified-hook result line"
LOG_HOME="$FIXTURE/loghome"
mkdir -p "$LOG_HOME/.claude"
# 真源 rules-v2.json 不动（editable 单源不可污染），规则走覆盖层 env
PROBE_RULES="$FIXTURE/probe-rules.json"
printf '{"version":2,"rules":[{"name":"cutover-probe","on":{"in":["PreToolUse"]},"when":{"op":"tool","in":["Bash"]},"action":[{"op":"context","message":"[cutover-probe]"}]}]}' > "$PROBE_RULES"
CHAIN_OUT=$(cd "$FIXTURE" && printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' | \
    HOME="$LOG_HOME" CLAUDE_PROJECT_DIR="" HOOK_FIRE_LOG="$LOG_HOME/.claude/hook-fire.log" \
    MULTICA_TASK_ID="dddd1111-2222-3333-4444-555555555555" \
    UNIFIED_RULES_FILE="$PROBE_RULES" \
    bash "$WRAPPER_DIR/unified/unified-hook.sh" 2>/dev/null)
if echo "$CHAIN_OUT" | grep -q '"additionalContext"'; then
    pass "6a: repo-checkout entry fires probe rule"
else
    fail "6a: chain output: '${CHAIN_OUT:0:120}'"
fi
if grep -q "\[unified-hook\] event=PreToolUse" "$LOG_HOME/.claude/hook-fire.log" 2>/dev/null; then
    pass "6b: firelog has unified-hook result line"
else
    fail "6b: firelog missing result line: $(tail -2 "$LOG_HOME/.claude/hook-fire.log" 2>/dev/null | tr '\n' ';')"
fi

#####################################################################
# 7. 备份/回滚往返稳定性（回归钉：每轮 rollback 必须恢复本轮变更前状态；
#    轮间隔 sleep 1.1 避开同秒备份名碰撞——bootstrap 备份名秒级粒度，无指针机制）
#####################################################################
separator "7. Backup/rollback round-trip stability"
STAB_SETTINGS="$FIXTURE/stab-home/.claude/settings.json"
mkdir -p "$(dirname "$STAB_SETTINGS")"
printf '{"version":1,"marker":0,"hooks":{}}' > "$STAB_SETTINGS"
MISMATCH=0
for i in 1 2 3; do
    node -e "const fs=require('fs');const p='$STAB_SETTINGS';const s=JSON.parse(fs.readFileSync(p,'utf8'));s.marker=$i;fs.writeFileSync(p,JSON.stringify(s))" 2>/dev/null
    cp "$STAB_SETTINGS" "$FIXTURE/stab-expected-$i.json"
    bash "$INSTALLER" "$STAB_SETTINGS" > /dev/null 2>&1
    bash "$ROLLBACK" --settings "$STAB_SETTINGS" > /dev/null 2>&1
    if ! cmp -s "$STAB_SETTINGS" "$FIXTURE/stab-expected-$i.json"; then
        MISMATCH=$((MISMATCH+1))
        fail "7: round $i rollback mismatch (restored wrong backup)"
    fi
    [ "$i" -lt 3 ] && sleep 1.1
done
[ "$MISMATCH" -eq 0 ] && pass "7a: 3-round change→bootstrap→rollback zero mismatch" \
    || fail "7a: $MISMATCH/3 rounds restored wrong backup"

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
