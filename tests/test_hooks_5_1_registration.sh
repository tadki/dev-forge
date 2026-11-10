#!/usr/bin/env bash
# §SPEC-019 (SEE-1516 substep D4, fingerprint e109d91186c4):
# hooks 治理登记一致性机器判据。
#
# 判据 1（validate-rules governance）：rules-v2.json 与 rules.d/*.json 全部
#   通过 owner/blocking 治理校验（无 owner 的 deny 规则 → 校验失败 CI 红）。
# 判据 2（§5.1 表覆盖）：rules-v2.json + rules.d/*.json 的全部规则名必须出现在
#   docs/hooks-implementation-guide.md §5.1 现役钩子清单（故意删行 → 本脚本红）。
#
# CI 入口：.github/workflows/ci.yml engine-tests job。
# 独立跑：bash tests/test_hooks_5_1_registration.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUIDE="$ROOT/docs/hooks-implementation-guide.md"
FAIL=0

fail() { echo "[FAIL] $1"; FAIL=1; }
ok()   { echo "[ok] $1"; }

# --- 判据 1: governance 校验全规则文件 -----------------------------------------

command -v node >/dev/null 2>&1 || { fail "node not found"; exit 1; }

for f in "$ROOT"/claude-hooks/unified/rules-v2.json "$ROOT"/claude-hooks/unified/rules.d/*.json; do
  out=$(node "$ROOT/claude-hooks/validate-rules.js" "$f" 2>&1)
  if [ $? -ne 0 ]; then
    fail "governance 校验失败: $(basename "$f")"
    echo "$out" | grep INVALID | head -5
  else
    ok "governance 校验通过: $(basename "$f")"
  fi
done

# --- 判据 2: 规则名 ⊆ §5.1 表 ---------------------------------------------------

[ -f "$GUIDE" ] || { fail "guide missing: $GUIDE"; exit 1; }

# §5.1 表段 = 「### 5.1」标题起至下一个「### 」（5.2 退役清单）
SECTION=$(awk '/^### 5\.1 /{flag=1;next}/^### /{flag=0}flag' "$GUIDE")

missing=0
# SEE-1559 hardener O2 修复：node join("\n") 无尾换行 → read 在 EOF 无换行时
# 返回非零、循环体不执行 → 排序末位规则名（stop-guard-live-subagents）从未被
# 校验（未登记规则置于末位时本门假绿，变异复跑证实）。双保险收口：
# ① 产出端补尾换行；② 消费端 `|| [ -n "$name" ]` 兜底未终止末行。
while IFS= read -r name || [ -n "$name" ]; do
  [ -z "$name" ] && continue
  # 表内登记形态：规则名/挂载名以反引号或裸文本出现即可（含 rules-v2 后缀注明）
  if ! grep -qF "$name" <<< "$SECTION"; then
    echo "[FAIL] §5.1 表缺规则行: $name"
    missing=$((missing + 1))
  fi
done < <(node -e '
const fs = require("fs");
const names = [];
const v2 = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
for (const r of v2.rules || []) names.push(r.name);
const rd = process.argv[2];
for (const f of fs.readdirSync(rd).sort()) {
  if (!f.endsWith(".json")) continue;
  const part = JSON.parse(fs.readFileSync(require("path").join(rd, f), "utf8"));
  for (const r of part.rules || []) names.push(r.name);
}
process.stdout.write(names.join("\n") + "\n");
' "$ROOT/claude-hooks/unified/rules-v2.json" "$ROOT/claude-hooks/unified/rules.d")

if [ "$missing" -eq 0 ]; then
  ok "§5.1 表覆盖全部规则名（rules-v2 + rules.d）"
else
  fail "§5.1 表缺 $missing 条规则行（登记一致性破坏）"
fi

if [ "$FAIL" -ne 0 ]; then
  echo "hooks 5.1 registration gate: FAIL"
  exit 1
fi
echo "hooks 5.1 registration gate: PASS"
exit 0
