#!/usr/bin/env bash
# §SPEC-017 (SEE-1516 substep D2, fingerprint bd8072282067):
# deny 副作用短路 —— 多规则 deny 文案聚合保留（SEE-1330），但被拦后
# run_script 不再执行（被拦 push 白付 git fetch/multica CLI 副作用归零）。
#
# 判据：
#   T1: 规则A(config deny) + 规则B(run_script 摸探针文件) 同事件命中 →
#       B 的探针文件不存在（无副作用）+ A 文案输出。
#   T2: 规则A(config deny) + 规则B(config deny) → 两条文案都在（聚合保留）。
#   T3: 无 deny 时 run_script 正常执行（探针存在，行为零回归）。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE=$(mktemp -d /tmp/deny-shortcircuit-XXXXXX)
trap 'rm -rf "$BASE"' EXIT
FAIL=0

pass() { echo "  [PASS] $1"; }
fail_() { echo "  [FAIL] $1"; FAIL=1; }

UNIFIED_HOOK="$ROOT/claude-hooks/unified/unified-hook.sh"
export UNIFIED_HOOK

PAYLOAD='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push origin main"}}'

run_engine() { # $1=rules_file ; 探针文件路径经 PROBE env 传给 stub 脚本
    HOOK_STDOUT=$(cd "$BASE" && \
        env PATH="$PATH" \
            HOME="$BASE/home" \
            MULTICA_AGENT_NAME="AnyAgent" \
            MULTICA_TASK_ID="$(cat /proc/sys/kernel/random/uuid)" \
            PROJECT_ROOT="$BASE" \
            PWD="$BASE" \
            UNIFIED_RULES_FILE="$1" \
            bash "$UNIFIED_HOOK" <<< "$PAYLOAD" 2>/dev/null)
}

# run_script 探针脚本：执行即摸 PROBE 文件（副作用观测面）
cat > "$BASE/probe.sh" <<'EOF'
#!/usr/bin/env bash
touch "$PROBE_FILE"
exit 0
EOF
chmod +x "$BASE/probe.sh"

make_rules() { # $1=out $2=include_probe(0|1) $3=probe_rules_json
    node -e '
const [out, includeProbe, extra] = process.argv.slice(1);
const rules = [
  { name: "rule-a-deny", on: { in: ["PreToolUse"] }, enabled: true,
    when: { op: "tool", in: ["Bash"] },
    action: [{ op: "deny", message: "DENY-A-MESSAGE" }] },
];
if (includeProbe === "1") rules.push(...JSON.parse(extra).rules);
require("fs").writeFileSync(out, JSON.stringify({ rules }));
' "$1" "$2" "$3"
}

# --- T1: deny 后 run_script 跳过 ----------------------------------------------
PROBE="$BASE/probe-t1"
rm -f "$PROBE"
make_rules "$BASE/rules-t1.json" 1 '{"rules":[{"name":"rule-b-script","on":{"in":["PreToolUse"]},"enabled":true,"when":{"op":"tool","in":["Bash"]},"action":[{"op":"run_script","path":"'"$BASE"'/probe.sh","timeout_ms":5000,"on_fail":"open"}]}]}'
PROBE_FILE="$PROBE" run_engine "$BASE/rules-t1.json"
if [ -e "$PROBE" ]; then
    fail_ "T1: deny 后 run_script 仍执行（探针文件存在 = 副作用未短路）"
else
    pass "T1: deny 后 run_script 跳过（探针文件不存在，副作用归零）"
fi
echo "$HOOK_STDOUT" | grep -q "DENY-A-MESSAGE" \
    && pass "T1: deny 文案输出保留" \
    || fail_ "T1: deny 文案丢失"

# --- T2: 多规则 config deny 文案聚合 -------------------------------------------
make_rules "$BASE/rules-t2.json" 1 '{"rules":[{"name":"rule-b-deny","on":{"in":["PreToolUse"]},"enabled":true,"when":{"op":"tool","in":["Bash"]},"action":[{"op":"deny","message":"DENY-B-MESSAGE"}]}]}'
run_engine "$BASE/rules-t2.json"
echo "$HOOK_STDOUT" | grep -q "DENY-A-MESSAGE" && echo "$HOOK_STDOUT" | grep -q "DENY-B-MESSAGE" \
    && pass "T2: 多规则 deny 文案全输出（SEE-1330 聚合保留）" \
    || fail_ "T2: deny 文案聚合破坏 ($HOOK_STDOUT)"

# --- T3: 无 deny 时 run_script 正常执行（零回归） -------------------------------
PROBE="$BASE/probe-t3"
rm -f "$PROBE"
node -e '
const [out, probe] = process.argv.slice(1);
require("fs").writeFileSync(out, JSON.stringify({ rules: [
  { name: "rule-c-script", on: { in: ["PreToolUse"] }, enabled: true,
    when: { op: "tool", in: ["Bash"] },
    action: [{ op: "run_script", path: probe, timeout_ms: 5000, on_fail: "open" }] },
]}));
' "$BASE/rules-t3.json" "$BASE/probe.sh"
PROBE_FILE="$PROBE" run_engine "$BASE/rules-t3.json"
if [ -e "$PROBE" ]; then
    pass "T3: 无 deny 时 run_script 正常执行（行为零回归）"
else
    fail_ "T3: run_script 无 deny 也不执行（过度短路回归）"
fi

if [ "$FAIL" -ne 0 ]; then echo "deny side-effect shortcircuit: FAIL"; exit 1; fi
echo "deny side-effect shortcircuit: PASS"
exit 0
