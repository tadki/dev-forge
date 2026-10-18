#!/bin/bash
# SEE-1330 P0: v2 idempotent installer test suite (SPEC-009)
# All operations run against FIXTURE paths only — never the real
# ~/.claude/settings.json or ~/.claude/hooks/.
# Covers: render/patch 9-point registration, unrelated-field preservation,
#         idempotency (2nd run diff=0), backup existence, rollback fidelity,
#         per-phase v1 disable + rollback, runtime deploy idempotency,
#         firelog unified-hook result line via fixture wrapper chain.
# Run:    bash .dev/tests/hooks/test_v2_installer_p0.sh
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0; RESULTS=()
pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); RESULTS+=("PASS|$1"); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); RESULTS+=("FAIL|$1"); }
separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$REPO_ROOT/bootstrap/bootstrap.sh"
MANIFEST="$REPO_ROOT/bootstrap/hooks-registration.json"
FIXTURE="$(mktemp -d /tmp/v2installer-p0.XXXXXX)"
SETTINGS="$FIXTURE/home/.claude/settings.json"
GLOBAL_HOOKS="$FIXTURE/home/.claude/hooks"

trap 'rm -rf "$FIXTURE"' EXIT

POINTS=(PreToolUse PostToolUse SessionStart SessionEnd Stop SubagentStop UserPromptSubmit Notification PreCompact)
V1_ALIASES_P1=(skill-check skill-check-post mention-check push-guard tscn-tres-guard gdformat-gdlint atlas-taskflow-mark-a atlas-taskflow-mark-b atlas-taskflow-exit-reminder)

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

echo "============================================================"
echo "  SEE-1330 P0: v2 Idempotent Installer (fixture-only)"
echo "  Date: $(date -Iseconds)"
echo "============================================================"

separator "Prerequisites"
[ -f "$INSTALLER" ] && pass "install-hooks.sh exists" || { fail "installer MISSING"; exit 1; }
[ -f "$MANIFEST" ] && pass "hooks-registration.json exists" || { fail "manifest MISSING"; exit 1; }
node -e "const m=require('$MANIFEST'); if (m.hook_points.length !== 9) process.exit(1)" 2>/dev/null \
    && pass "manifest declares 9 hook points" || fail "manifest hook_points != 9"

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
# 1. install P0：9 时点注册渲染 + 无关字段/v1 注册保留
#####################################################################
separator "1. install P0"
bash "$INSTALLER" install --settings "$SETTINGS" --global-hooks "$GLOBAL_HOOKS" --repo-root "$REPO_ROOT" --phase P0 > "$FIXTURE/install1.log" 2>&1
[ $? -eq 0 ] && pass "1a: install exits 0" || { fail "1a: install failed: $(cat "$FIXTURE/install1.log")"; }

MISSING=0
for P in "${POINTS[@]}"; do
    node -e "
const s = require('$SETTINGS');
const want = '$GLOBAL_HOOKS/hook-wrapper.sh $P unified-hook';
const groups = (s.hooks||{})['$P'] || [];
const ok = groups.some(g => (g.hooks||[]).some(h => h.command === want && g.matcher === '*'));
process.exit(ok ? 0 : 1);
" 2>/dev/null || MISSING=1
done
[ "$MISSING" -eq 0 ] && pass "1b: all 9 points registered with matcher=*" || fail "1b: some points missing/matcher wrong"

node -e "
const s = require('$SETTINGS');
if (s.permissions && s.permissions.allow && s.permissions.allow.length === 1 && s.enableAllProjectMcpServers === true) process.exit(0);
process.exit(1);
" 2>/dev/null && pass "1c: unrelated fields preserved" || fail "1c: unrelated fields lost"

node -e "
const s = require('$SETTINGS');
const pre = (s.hooks.PreToolUse||[]).some(g => (g.hooks||[]).some(h => (h.command||'').endsWith(' push-guard')));
if (pre) process.exit(0);
process.exit(1);
" 2>/dev/null && pass "1d: v1 registrations intact in P0" || fail "1d: v1 registrations lost in P0"

# P0 disable_v1 为空：auto-pr/repo-checkout/skill-check 均在
V1_COUNT=$(node -e "
const s = require('$SETTINGS');
let n = 0;
for (const p of Object.keys(s.hooks)) for (const g of s.hooks[p]||[]) for (const h of g.hooks||[]) if (!/ unified-hook$/.test(h.command||'')) n++;
console.log(n);
")
[ "$V1_COUNT" -eq 5 ] && pass "1e: v1 entries count 5 (unchanged)" || fail "1e: v1 entries count $V1_COUNT != 5"

#####################################################################
# 2. 幂等：二次运行 diff=0
#####################################################################
separator "2. Idempotency"
cp "$SETTINGS" "$FIXTURE/after1.json"
BACKUP_COUNT_1=$(ls "$FIXTURE/home/.claude/" | grep -c "settings.json.bak-" || true)
bash "$INSTALLER" install --settings "$SETTINGS" --global-hooks "$GLOBAL_HOOKS" --repo-root "$REPO_ROOT" --phase P0 > "$FIXTURE/install2.log" 2>&1
[ $? -eq 0 ] && pass "2a: 2nd install exits 0" || fail "2a: 2nd install failed"
if cmp -s "$FIXTURE/after1.json" "$SETTINGS"; then
    pass "2b: 2nd install diff=0"
else
    fail "2b: 2nd install changed settings"
fi
BACKUP_COUNT_2=$(ls "$FIXTURE/home/.claude/" | grep -c "settings.json.bak-" || true)
[ "$BACKUP_COUNT_2" -eq "$BACKUP_COUNT_1" ] && pass "2c: no extra backup on no-op run" || fail "2c: backup count $BACKUP_COUNT_1 → $BACKUP_COUNT_2"
V2_N=$(count_v2_entries)
[ "$V2_N" -eq 9 ] && pass "2d: no duplicate v2 entries (count=9)" || fail "2d: v2 entries = $V2_N (duplication?)"

# 无关临时文件无残留
TMP_LEFT=$(ls "$FIXTURE/home/.claude/" | grep -c "tmp\." || true)
[ "$TMP_LEFT" -eq 0 ] && pass "2e: no tmp residue (atomic write)" || fail "2e: tmp files left: $TMP_LEFT"

#####################################################################
# 3. 备份存在
#####################################################################
separator "3. Backup"
BACKUPS=( "$FIXTURE/home/.claude/"settings.json.bak-* )
[ -f "${BACKUPS[0]}" ] && pass "3a: backup file exists (${BACKUPS[0]##*/})" || fail "3a: no backup found"
if cmp -s "${BACKUPS[0]}" "$FIXTURE/original-settings.json"; then
    pass "3b: backup content = pre-install settings"
else
    fail "3b: backup content differs from original"
fi

#####################################################################
# 4. 回滚后 settings 与部署前一致
#####################################################################
separator "4. Rollback"
bash "$INSTALLER" rollback --settings "$SETTINGS" > "$FIXTURE/rollback.log" 2>&1
[ $? -eq 0 ] && pass "4a: rollback exits 0" || fail "4a: rollback failed: $(cat "$FIXTURE/rollback.log")"
if cmp -s "$SETTINGS" "$FIXTURE/original-settings.json"; then
    pass "4b: settings identical to pre-install"
else
    fail "4b: rollback content mismatch"
fi
# 回滚后重装可再次达到同一终态（可逆性）
bash "$INSTALLER" install --settings "$SETTINGS" --global-hooks "$GLOBAL_HOOKS" --repo-root "$REPO_ROOT" --phase P0 > /dev/null 2>&1
cmp -s "$FIXTURE/after1.json" "$SETTINGS" && pass "4c: reinstall reaches same end state" || fail "4c: reinstall diverged"

#####################################################################
# 5. per-phase cutover：disable-v1 P1 + 回滚
#####################################################################
separator "5. per-phase disable-v1"
bash "$INSTALLER" disable-v1 --settings "$SETTINGS" --manifest "$MANIFEST" --global-hooks "$GLOBAL_HOOKS" --phase P1 > "$FIXTURE/p1.log" 2>&1
[ $? -eq 0 ] && pass "5a: disable-v1 P1 exits 0" || fail "5a: disable-v1 failed: $(cat "$FIXTURE/p1.log")"
cp "$FIXTURE/after1.json" "$FIXTURE/pre-disable-state.json"

P1_LEFT=0
for A in "${V1_ALIASES_P1[@]}"; do
    node -e "
const s = require('$SETTINGS');
for (const p of Object.keys(s.hooks)) for (const g of s.hooks[p]||[]) for (const h of g.hooks||[])
  if ((h.command||'').endsWith(' $A')) process.exit(1);
process.exit(0);
" 2>/dev/null || P1_LEFT=1
done
[ "$P1_LEFT" -eq 0 ] && pass "5b: all 9 P1 v1 aliases disabled" || fail "5b: some P1 v1 aliases remain"

node -e "
const s = require('$SETTINGS');
const keep1 = (s.hooks.Stop||[]).some(g => (g.hooks||[]).some(h => (h.command||'').endsWith(' auto-pr')));
const keep2 = (s.hooks.SessionStart||[]).some(g => (g.hooks||[]).some(h => (h.command||'').endsWith(' repo-checkout')));
process.exit(keep1 && keep2 ? 0 : 1);
" 2>/dev/null && pass "5c: P2/P3 v1 aliases (auto-pr, repo-checkout) untouched" || fail "5c: other-phase v1 aliases wrongly removed"
V2_N=$(count_v2_entries)
[ "$V2_N" -eq 9 ] && pass "5d: v2 entries intact after disable (9)" || fail "5d: v2 entries = $V2_N"

bash "$INSTALLER" rollback --settings "$SETTINGS" > /dev/null 2>&1
cmp -s "$SETTINGS" "$FIXTURE/pre-disable-state.json" && pass "5e: rollback after disable-v1 restores pre-disable state" || fail "5e: rollback mismatch"

# disable-v1 幂等
bash "$INSTALLER" disable-v1 --settings "$SETTINGS" --manifest "$MANIFEST" --global-hooks "$GLOBAL_HOOKS" --phase P1 > /dev/null 2>&1
cp "$SETTINGS" "$FIXTURE/p1-state.json"
bash "$INSTALLER" disable-v1 --settings "$SETTINGS" --manifest "$MANIFEST" --global-hooks "$GLOBAL_HOOKS" --phase P1 > /dev/null 2>&1
cmp -s "$FIXTURE/p1-state.json" "$SETTINGS" && pass "5f: disable-v1 idempotent" || fail "5f: disable-v1 not idempotent"
bash "$INSTALLER" rollback --settings "$SETTINGS" > /dev/null 2>&1

#####################################################################
# 6. 运行物部署（fixture 全局 hooks 目录）幂等 + 执行位
#####################################################################
separator "6. Runtime artifacts deploy"
for f in unified/unified-hook.sh unified/engine.js unified/when-ops.js unified/rules-v2.json validate-rules.js; do
    [ -f "$GLOBAL_HOOKS/$f" ] && pass "6a: deployed $f" || fail "6a: missing $f"
done
[ -x "$GLOBAL_HOOKS/unified/unified-hook.sh" ] && pass "6b: unified-hook.sh executable" || fail "6b: not executable"
# 幂等：二次部署内容不变（mtime 变化也算部署器不幂等——用内容校验 + 不重复日志）
DEPLOY_LOG_1="$FIXTURE/install1.log"; DEPLOY_LOG_2="$FIXTURE/install2.log"
DEP1=$(grep -c "deployed:" "$DEPLOY_LOG_1" || true)
DEP2=$(grep -c "deployed:" "$DEPLOY_LOG_2" || true)
[ "$DEP2" -eq 0 ] && [ "$DEP1" -gt 0 ] && pass "6c: 2nd install deploys nothing (idempotent)" || fail "6c: deploy counts 1st=$DEP1 2nd=$DEP2"
cmp -s "$GLOBAL_HOOKS/unified/engine.js" "$REPO_ROOT/claude-hooks/unified/engine.js" && pass "6d: deployed engine.js matches repo" || fail "6d: engine.js drifted"

# 全局兜底规则配置：部署位 rules-v2.json 可被引擎 __dirname 兜底发现。
# P1 再定向说明（S5）：repo 真源 rules-v2.json 自 P1 起含 14 条规则（不再为空），本用例的
# P0「零行为」前提改为以空规则覆盖层（empty overlay）验证引擎兜底零输出语义——部署位配置
# 的 P1 行为变化由 Atlas cutover 与对照清单管理。
printf '{"version":2,"v1_compat":false,"rules":[]}' > "$FIXTURE/empty-rules.json"
DEPLOY_RULES=$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' | \
    HOME="$FIXTURE/home" CLAUDE_PROJECT_DIR="" HOOK_FIRE_LOG="$FIXTURE/fallback-fire.log" \
    MULTICA_TASK_ID="cccc1111-2222-3333-4444-555555555555" \
    CLAUDE_CODE_SESSION_ID="" PWD="$FIXTURE" \
    UNIFIED_RULES_FILE="$FIXTURE/empty-rules.json" \
    node "$GLOBAL_HOOKS/unified/engine.js" 2>/dev/null)
[ -z "$DEPLOY_RULES" ] && pass "6e: deployed engine emits nothing under empty-rules overlay (P1 note)" || fail "6e: unexpected deploy rules output: '${DEPLOY_RULES:0:80}'"

#####################################################################
# 7. cutover 后 firelog 出现 unified-hook result 行（部署位运行单元）
#####################################################################
separator "7. firelog unified-hook result line"
LOG_HOME="$FIXTURE/loghome"
mkdir -p "$LOG_HOME/.claude"
# 注入一条 probe 规则到部署位配置（真实部署位规则由 Atlas cutover 管理）
printf '{"version":2,"rules":[{"name":"cutover-probe","on":{"in":["PreToolUse"]},"when":{"op":"tool","in":["Bash"]},"action":[{"op":"context","message":"[cutover-probe]"}]}]}' > "$GLOBAL_HOOKS/unified/rules-v2.json"
CHAIN_OUT=$(cd "$FIXTURE" && printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' | \
    HOME="$LOG_HOME" CLAUDE_PROJECT_DIR="" HOOK_FIRE_LOG="$LOG_HOME/.claude/hook-fire.log" \
    MULTICA_TASK_ID="dddd1111-2222-3333-4444-555555555555" \
    bash "$GLOBAL_HOOKS/unified/unified-hook.sh" 2>/dev/null)
if echo "$CHAIN_OUT" | grep -q '"additionalContext"'; then
    pass "7a: deployed entry fires probe rule"
else
    fail "7a: chain output: '${CHAIN_OUT:0:120}'"
fi
if grep -q "\[unified-hook\] event=PreToolUse" "$LOG_HOME/.claude/hook-fire.log" 2>/dev/null; then
    pass "7b: firelog has unified-hook result line"
else
    fail "7b: firelog missing result line: $(tail -2 "$LOG_HOME/.claude/hook-fire.log" 2>/dev/null | tr '\n' ';')"
fi
# 恢复部署位空规则（保持 P0 灰度语义：空规则零行为变化）
printf '{\n  "version": 2,\n  "v1_compat": false,\n  "rules": []\n}\n' > "$GLOBAL_HOOKS/unified/rules-v2.json"

#####################################################################
# 8. 备份时序稳定性（5e 缺陷修复回归钉）：≥10 次同秒循环变更→rollback，
#    rollback 必须恢复「最近一次变更前」状态（mtime 序脱钩根因消除）
#####################################################################
separator "8. Backup timing stability (5e regression pin)"
STAB_SETTINGS="$FIXTURE/stab-home/.claude/settings.json"
mkdir -p "$(dirname "$STAB_SETTINGS")"
printf '{"version":1,"marker":0,"hooks":{}}' > "$STAB_SETTINGS"
MISMATCH=0
for i in $(seq 1 10); do
    # 每轮改动 marker（内容必然变化 → 必产生备份），同秒内高频执行复现碰撞窗口
    node -e "const fs=require('fs');const p='$STAB_SETTINGS';const s=JSON.parse(fs.readFileSync(p,'utf8'));s.marker=$i;fs.writeFileSync(p,JSON.stringify(s))" 2>/dev/null
    cp "$STAB_SETTINGS" "$FIXTURE/stab-expected-$i.json"
    # install（空规则 → v2 注册写入，settings 变更 → 备份 marker=i 状态）
    bash "$INSTALLER" install --settings "$STAB_SETTINGS" --global-hooks "$GLOBAL_HOOKS" --repo-root "$REPO_ROOT" --phase P0 > /dev/null 2>&1
    # rollback（缺省 latest_backup）：必须恢复 marker=i 的状态
    bash "$INSTALLER" rollback --settings "$STAB_SETTINGS" > /dev/null 2>&1
    if ! cmp -s "$STAB_SETTINGS" "$FIXTURE/stab-expected-$i.json"; then
        MISMATCH=$((MISMATCH+1))
        fail "8: round $i rollback mismatch (restored wrong backup)"
    fi
    # 复位为 install 后状态以进入下一轮
    node -e "const fs=require('fs');const p='$STAB_SETTINGS';const s=JSON.parse(fs.readFileSync(p,'utf8'));s.marker=$i;fs.writeFileSync(p,JSON.stringify(s))" 2>/dev/null
done
[ "$MISMATCH" -eq 0 ] && pass "8a: 10-round same-second change→rollback zero mismatch (pointer-ordered)" \
    || fail "8a: $MISMATCH/10 rounds restored wrong backup"

# 8a2 多代备份时序脱钩复现（旧码实测命中：第 2 代 rollback 恢复第 1 代备份）——
# 旧码 cp 保留源 mtime 使第 2 代备份 mtime 平序/早于第 1 代 → ls -1t 选错
MISMATCH2=0
SEQ_SETTINGS="$FIXTURE/seq-home/.claude/settings.json"
mkdir -p "$(dirname "$SEQ_SETTINGS")"
printf '{"marker":0}' > "$SEQ_SETTINGS"
for i in 1 2 3; do
    node -e "const fs=require('fs');const p='$SEQ_SETTINGS';const s=JSON.parse(fs.readFileSync(p,'utf8'));s.marker=$i;fs.writeFileSync(p,JSON.stringify(s))" 2>/dev/null
    cp "$SEQ_SETTINGS" "$FIXTURE/seq-exp-$i.json"
    bash "$INSTALLER" install --settings "$SEQ_SETTINGS" --global-hooks "$GLOBAL_HOOKS" --repo-root "$REPO_ROOT" --phase P0 > /dev/null 2>&1
    bash "$INSTALLER" rollback --settings "$SEQ_SETTINGS" > /dev/null 2>&1
    cmp -s "$SEQ_SETTINGS" "$FIXTURE/seq-exp-$i.json" || MISMATCH2=$((MISMATCH2+1))
    node -e "const fs=require('fs');const p='$SEQ_SETTINGS';const s=JSON.parse(fs.readFileSync(p,'utf8'));s.marker=$i;fs.writeFileSync(p,JSON.stringify(s))" 2>/dev/null
done
[ "$MISMATCH2" -eq 0 ] && pass "8a2: 3-generation backup sequence — each rollback restores its own pre-state" \
    || fail "8a2: $MISMATCH2/3 generations restored wrong backup (mtime decoupling)"

# 8b 指针存在且指向最新备份
LAST_POINTER="$(dirname "$STAB_SETTINGS")/.settings.json.last-backup"
if [ -f "$LAST_POINTER" ] && [ -f "$(cat "$LAST_POINTER")" ]; then
    pass "8b: .last-backup pointer exists and resolves"
else
    fail "8b: pointer missing or dangling"
fi

# 8c 同秒双备份不碰撞（文件名唯一性）
BAK_COUNT=$(ls "$(dirname "$STAB_SETTINGS")" | grep -c "settings.json.bak-" || true)
[ "$BAK_COUNT" -ge 10 ] && pass "8c: backups unique across rapid rounds (count=$BAK_COUNT, no overwrite)" \
    || fail "8c: backup count $BAK_COUNT < 10 — same-second collision overwrote backups"

#####################################################################
# 9. 事故 6 修复钉：部署完整性 —— 清单必须覆盖挂载层全部 run_script 目标，
#    部署后逐 artifact cmp 仓库真源（缺失/漂移即红）
#####################################################################
separator "9. Deploy completeness (incident-6 regression pin)"

# 9a 清单覆盖挂载脚本全集（rules.d 每条 run_script path 必须在 runtime_artifacts）
MOUNT_SCRIPTS=$(node -e "
const r = require('$REPO_ROOT/claude-hooks/unified/rules.d/runscript-mounts.json');
const m = require('$MANIFEST');
const need = [...new Set(r.rules.filter(x=>x.action[0].op==='run_script').map(x=>x.action[0].path.replace('\${HOOKS_DIR}/','')))].sort();
const have = m.runtime_artifacts.filter(a=>!a.startsWith('unified/')).sort();
const missing = need.filter(n=>!have.includes(n));
console.log(missing.length === 0 ? 'COMPLETE' : 'MISSING:' + missing.join(','));
" 2>/dev/null)
[ "$MOUNT_SCRIPTS" = "COMPLETE" ] && pass "9a: manifest covers all rules.d run_script targets" \
    || fail "9a: manifest incomplete — $MOUNT_SCRIPTS"

# 9b install 后逐 artifact cmp 仓库真源 + 全部存在（事故 6 根因 = P2/P3 新增脚本缺失）
# 源解析与 installer deploy_runtime 同序：.claude/hooks/ 相对为主，hook-wrapper.sh /
# dispatcher.sh 的仓库单源在 claude-hooks/（SEE-1388 SPEC-006 入册；SEE-1430 迁 dev-forge）。
DEP_MISSING=0
for A in $(node -e "const m=require('$MANIFEST'); console.log(m.runtime_artifacts.join(' '))"); do
    SRC="$REPO_ROOT/claude-hooks/$A"
    [ -f "$SRC" ] || SRC="$REPO_ROOT/claude-hooks/$A"
    if [ ! -f "$GLOBAL_HOOKS/$A" ] || ! cmp -s "$SRC" "$GLOBAL_HOOKS/$A"; then
        DEP_MISSING=1
        fail "9b: deployed artifact missing/drifted: $A"
    fi
done
[ "$DEP_MISSING" -eq 0 ] && pass "9b: all runtime_artifacts deployed byte-identical (incl auto-pr-on-stop.sh, repo-checkout.sh)" || true

# 9c 挂载脚本执行位（事故 6 恢复时需手工 chmod —— 断言安装器保证）
EXEC_MISSING=0
for A in $(node -e "const m=require('$MANIFEST'); console.log(m.runtime_artifacts.filter(a=>a.endsWith('.sh')&&!a.startsWith('unified/')).join(' '))"); do
    [ -x "$GLOBAL_HOOKS/$A" ] || { EXEC_MISSING=1; fail "9c: not executable: $A"; }
done
[ "$EXEC_MISSING" -eq 0 ] && pass "9c: deployed .sh artifacts executable" || true

# 9d SEE-1388 §SPEC-006（fingerprint 9f280832efd6）：链路组件显式在册断言。
# 9a 仅覆盖 rules.d 挂载全集、9b 仅逐条比对清单内条目——清单条目被摘除时二者
# 均保持绿（盲区的实证：21c 注）。8 个链路组件逐名断言在册，任一摘除即红。
LINK_COMPONENTS="hook-wrapper.sh dispatcher.sh scripts/mcp-tool-presence.sh scripts/godot-mcp-launch-path.lib.sh scripts/lib/gitlink-probe.sh scripts/lib/gitlink-sync-hint.sh scripts/lib/hook-fire-path.lib.sh"
MANIFEST_MISSING=""
for C in $LINK_COMPONENTS; do
    node -e "const m=require('$MANIFEST'); process.exit((m.runtime_artifacts||[]).includes('$C')?0:1)" \
        || MANIFEST_MISSING="$MANIFEST_MISSING $C"
done
[ -z "$MANIFEST_MISSING" ] && pass "9d: 7 链路组件全在 runtime_artifacts（hook-wrapper/dispatcher/mcp-tool-presence/godot-mcp-launch-path/lib×3）" \
    || fail "9d: runtime_artifacts 缺链路组件:$MANIFEST_MISSING（SPEC-006 回退）"

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
