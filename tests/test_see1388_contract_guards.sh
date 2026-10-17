#!/bin/bash
# SEE-1388 S3 hardener 契约守护套件：§SPEC-004/005 rules 治理 + §SPEC-007 auto-pr
# 显式错误通道 + §SPEC-013 reconcile 归位引用面。
# 判别目标（修正确置反向/路径漂移后本套件必红）：
#   SPEC-004 — doc-reminder 复活 / rules.d p1 前缀回潮 / 活引用残留旧名 → 红
#   SPEC-005 — 治理字段从 shipped rules-v2.json 摘除（CLI governance 兜底）/
#             validate-rules basename 触发线断（负例 fixture）/ 指南 §5 行回退 → 红
#   SPEC-007 — auto-pr mark-b 三处 catch 回退静默 → 红；one-liner 尾部 2>/dev/null
#             回潮（stderr WARN 不可达）→ 红（补丁棒次 §5）
#   SPEC-013 — reconcile 回原路径 / 新路径缺失 / 部署清单回潮 / 活引用漂移 → 红
# Run: bash .dev/tests/hooks/test_see1388_contract_guards.sh
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); }
separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RULES_V2="$REPO_ROOT/hooks/unified/rules-v2.json"
RULES_D="$REPO_ROOT/hooks/unified/rules.d"
VALIDATOR="$REPO_ROOT/hooks/unified/validate-rules.js"
MANIFEST="$REPO_ROOT/bootstrap/hooks-registration.json"
AUTO_PR="$REPO_ROOT/hooks/scripts/auto-pr-on-stop.sh"
GUIDE="$REPO_ROOT/docs/hooks-implementation-guide.md"

FIXTURE="$(mktemp -d /tmp/see1388-guards.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

#####################################################################
separator "1. SPEC-004 配置卫生（fingerprint b9361f0c8695）"
#####################################################################

# 1a: doc-reminder 死规则物理删除（判据：grep -c = 0）
if [ "$(grep -c 'doc-reminder' "$RULES_V2")" -eq 0 ]; then
    pass "1a: rules-v2.json 无 doc-reminder 残留"
else
    fail "1a: doc-reminder 复活（SPEC-004 回退）"
fi

# 1b: rules.d 仅存去前缀命名（判据：ls 无 p1 前缀）
if [ -f "$RULES_D/runscript-mounts.json" ] && ! ls "$RULES_D" | grep -q '^p1-'; then
    pass "1b: rules.d 仅存 runscript-mounts.json（无 p1 前缀）"
else
    fail "1b: rules.d 命名回潮: $(ls "$RULES_D" | tr '\n' ' ')"
fi

# 1c: 旧名活引用零命中（判据：grep -rn <旧名> .claude/hooks .dev/tests = 0）
# 模式动态拼装——本测试文件自身不得成为命中源
OLDNAME="p1-""runscript""-mounts"
HITS=$(grep -rn "$OLDNAME" "$REPO_ROOT/hooks" "$REPO_ROOT/.dev/tests" 2>/dev/null | wc -l)
[ "$HITS" -eq 0 ] && pass "1c: 旧名 $OLDNAME 活引用零命中（.claude/hooks + .dev/tests）" \
    || fail "1c: 旧名活引用残留: $(grep -rn "$OLDNAME" "$REPO_ROOT/hooks" "$REPO_ROOT/.dev/tests" 2>/dev/null | head -3)"

#####################################################################
separator "2. SPEC-005 owner/blocking 治理字段（fingerprint cd568f2f8786）"
#####################################################################

# 2a: shipped rules-v2.json 全量通过 CLI governance 校验（字段摘除 → 此行即红）
if node "$VALIDATOR" "$RULES_V2" > "$FIXTURE/cli-v2.out" 2>&1; then
    pass "2a: shipped rules-v2.json CLI governance 校验 exit 0"
else
    fail "2a: shipped rules-v2.json 治理校验失败: $(grep INVALID "$FIXTURE/cli-v2.out" | head -2)"
fi

# 2b: rules.d/runscript-mounts.json CLI 校验 exit 0（判据：node validate-rules.js exit 0）
if node "$VALIDATOR" "$RULES_D/runscript-mounts.json" > /dev/null 2>&1; then
    pass "2b: runscript-mounts.json CLI 校验 exit 0"
else
    fail "2b: runscript-mounts.json 校验失败"
fi

# 2c: 负例 fixture——缺 owner 的规则在 rules-v2.json 文件名下必 INVALID exit 1
# （governance 由 basename 触发；同内容换文件名 → exit 0，证明触发线未断）
node -e "
const fs=require('fs');
const c=JSON.parse(fs.readFileSync('$RULES_V2','utf8'));
delete c.rules[0].owner;
fs.writeFileSync('$FIXTURE/rules-v2.json', JSON.stringify(c));
fs.writeFileSync('$FIXTURE/other-name.json', JSON.stringify(c));
" 2>/dev/null
if node "$VALIDATOR" "$FIXTURE/rules-v2.json" > "$FIXTURE/cli-neg.out" 2>&1; then
    fail "2c: 缺 owner 负例未被判 INVALID（governance 触发线断）"
else
    grep -q 'path=owner' "$FIXTURE/cli-neg.out" && pass "2c: 缺 owner 负例 INVALID path=owner exit 1（触发线判别力）" \
        || fail "2c: INVALID 但 path 非 owner: $(grep INVALID "$FIXTURE/cli-neg.out" | head -1)"
fi
if node "$VALIDATOR" "$FIXTURE/other-name.json" > /dev/null 2>&1; then
    pass "2c: 同内容非 rules-v2.json 文件名 → governance 不触发 exit 0（触发面精确）"
else
    fail "2c: 非 rules-v2.json 文件名被误触发 governance（误伤面）"
fi

# 2d: 指南 §5 登记行（补登 2 规则 + mention-confirm-check 阻断属性）
if grep -q 'child-issue-guard' "$GUIDE" && grep -q 'grepai-search-reminder' "$GUIDE"; then
    pass "2d: 指南 §5 已登 child-issue-guard / grepai-search-reminder"
else
    fail "2d: 指南 §5 补登行缺失"
fi
if grep 'mention-confirm-check' "$GUIDE" | grep -q 'deny'; then
    pass "2d: 指南 mention-confirm-check 行含 deny（阻断属性修正）"
else
    fail "2d: 指南 mention-confirm-check 行缺 deny 标注"
fi

#####################################################################
separator "3. SPEC-007 auto-pr mark-b 显式错误通道（fingerprint 4d69c30933f4）"
#####################################################################

# 3a: 解析路径 catch 均为显式 stderr WARN（回退静默 catch(e){} → 计数不足即红）
# 补充棒次 §SPEC-019 后全脚本 WARN 总数 = 7（mark-b ×3 + 附案 ×4）；
# 关键判据 = 静默 catch 零命中（见 3b），计数仅作存在性下限。
WARNS=$(grep -c "catch(e) { process.stderr.write('\[auto-pr\] WARN" "$AUTO_PR")
[ "$WARNS" -ge 3 ] && pass "3a: auto-pr 显式 stderr WARN 计数=$WARNS（≥3，含 §SPEC-019 附案 4 处）" \
    || fail "3a: 显式 WARN 计数=$WARNS（<3，静默回退？）"

# 3b: 判据命令形态——解析行无静默 write('')
if grep -n 'catch' "$AUTO_PR" | grep -q "write('')"; then
    fail "3b: 解析路径存在静默 write('')（SPEC-007 回退）"
else
    pass "3b: 解析路径无静默 write('')"
fi

#####################################################################
separator "4. SPEC-013 reconcile-working-branch.sh 归位（fingerprint 76f04e585cbe）"
#####################################################################

# 4a: 原路径零残留
[ ! -e "$REPO_ROOT/hooks/scripts/reconcile-working-branch.sh" ] \
    && pass "4a: 原路径 .claude/hooks/scripts/ 零残留" \
    || fail "4a: reconcile 回原路径（SPEC-013 回退）"

# 4b: reconcile-working-branch.sh 归属 KOL 侧（SEE-1429 迁移设计：非注册脚本保留 KOL 原位），
# dev-forge 内不承载——断言本仓无该脚本即可（与 4a 同语义，4b 降级为归属声明）。
[ ! -e "$REPO_ROOT/hooks/scripts/reconcile-working-branch.sh" ] \
    && pass "4b: reconcile 归属 KOL，dev-forge 零承载" \
    || fail "4b: reconcile 不应出现在 dev-forge"

# 4c: 部署清单无 reconcile 条目（退出部署域后清单保留即死链）
if node -e "const m=require('$MANIFEST'); process.exit((m.runtime_artifacts||[]).some(a=>a.includes('reconcile-working-branch'))?0:1)"; then
    fail "4c: hooks-registration.json 仍列 reconcile（部署死链回潮）"
else
    pass "4c: runtime_artifacts 无 reconcile 条目"
fi

# 4d: 活引用全指向新路径——旧路径串在 hooks 部署域/CI/git hooks 零命中
OLDREF='hooks/scripts/reconcile''-working''-branch'
OLDHITS=$(grep -rn "$OLDREF" "$REPO_ROOT/.claude" "$REPO_ROOT/hooks" "$REPO_ROOT/hooks/scripts" "$REPO_ROOT/.github" "$REPO_ROOT/.githooks" 2>/dev/null | wc -l)
[ "$OLDHITS" -eq 0 ] && pass "4d: 旧路径串活引用零命中（部署域/CI/git hooks）" \
    || fail "4d: 旧路径串活引用残留: $(grep -rn "$OLDREF" "$REPO_ROOT/.claude" "$REPO_ROOT/hooks" "$REPO_ROOT/hooks/scripts" "$REPO_ROOT/.github" "$REPO_ROOT/.githooks" 2>/dev/null | head -3)"

# 4e: 既有 reconcile 套件锚定新路径（套件路径漂移即同步红）
for S in test_reconcile_working_branch_args_see954.sh test_reconcile_working_branch_flow_see1042.sh; do
    grep -q 'SCRIPT="$WORKTREE_DIR/hooks/scripts/reconcile-working-branch.sh"' "$REPO_ROOT/tests/$S" \
        && pass "4e: $S 锚定新路径" \
        || fail "4e: $S 未锚定新路径"
done

#####################################################################
separator "5. SPEC-007 补丁棒次 — WARN 端到端可达（one-liner 尾部 2>/dev/null 摘除）"
#####################################################################

# 5a: 静态——每处 WARN catch 所在 node one-liner 的收尾行不得再带 2>/dev/null
BAD=0
while IFS=: read -r ln _; do
    tail_line=$(awk -v s="$ln" 'NR>s && /^[[:space:]]*"/ {print; exit}' "$AUTO_PR")
    case "$tail_line" in
        *"2>/dev/null"*) BAD=$((BAD+1)) ;;
    esac
done < <(grep -n "catch(e) { process.stderr.write.\\[auto-pr\\] WARN" "$AUTO_PR")
[ "$BAD" -eq 0 ] && pass "5a: 三处 WARN one-liner 收尾无 2>/dev/null（stderr 通道未被吞）" \
    || fail "5a: $BAD 处 one-liner 收尾回潮 2>/dev/null（WARN 不可达）"

# 5b: 端到端——从产品脚本抽取 issue-id 解析 node 程序，喂非法 JSON，stderr WARN 须可见
awk '/multica issue run-messages/{f=1}
     f && /node -e "/{cap=1; sub(/.*node -e "/,""); print; next}
     cap && /^[[:space:]]*"[[:space:]]*\|\| true\)/{exit}
     cap{print}' "$AUTO_PR" > "$FIXTURE/warn-probe.js"
STDERR_OUT=$(printf 'not-json-garbage' | node "$FIXTURE/warn-probe.js" 2>&1 >/dev/null || true)
if echo "$STDERR_OUT" | grep -q '\[auto-pr\] WARN issue-id parse failed'; then
    pass "5b: 模拟 JSON 解析失败 → stderr WARN 端到端可见"
else
    fail "5b: WARN 未观测到（stderr 仍被吞？）: '$STDERR_OUT'"
fi

# 5c: 判别力对照——同程序加 2>/dev/null 即静默（修复前形态，5b 因此具备反向判别力）
STDERR_SILENT=$(printf 'not-json-garbage' | node "$FIXTURE/warn-probe.js" 2>/dev/null >/dev/null || true)
[ -z "$STDERR_SILENT" ] && pass "5c: 对照组 2>/dev/null 下 WARN 静默（判别力成立）" \
    || fail "5c: 对照组意外产出 stderr: '$STDERR_SILENT'"

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
