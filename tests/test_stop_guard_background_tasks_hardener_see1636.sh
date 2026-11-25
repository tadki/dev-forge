#!/bin/bash
# SEE-1636 §SPEC-010 hardener 增补判别力（Harti 轮）：既有套件（31 断言）未钉住的
# 守卫行为面，每条用例对应一个独立构造变异点的 kill 判据（变异台账见交付报告）：
#   H1  终态词表锚定匹配（status=undone 含 done 子串 → 仍按活任务拦）
#   H2  终态词表大小写敏感（status=Completed 不在词表 → 按活任务拦）
#   H3  拦截清单含活任务 description 文本（逐项列出须可读）
#   H4  清单行格式：换行 + 两空格缩进 + `<id> [`（多行逐项形态）
#   H5  无 id 任务以 `? [` 占位逐项列出（缺字段不丢行）
#   H6  规则文件治理校验通过（validate-rules：全规则须 boolean blocking；deny⇒true）
# 约束：只读产品面（脚本/规则 JSON/validator），全部状态在 mktemp fixture 内，
# 不写生产 state 与 firelog。
# Run:    bash tests/test_stop_guard_background_tasks_hardener_see1636.sh
set -uo pipefail

unset MULTICA_TASK_ID MULTICA_AGENT_ID MULTICA_AGENT_NAME \
      MULTICA_TOKEN MULTICA_SERVER_URL MULTICA_WORKSPACE_ID

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0; RESULTS=()
pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); RESULTS+=("PASS|$1"); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); RESULTS+=("FAIL|$1"); }
separator() { echo ""; echo -e "${CYAN}--- $1 ---${NC}"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$REPO_ROOT/claude-hooks/scripts/stop-guard-background-tasks.sh"
RULE_FILE="$REPO_ROOT/claude-hooks/unified/rules.d/stop-guard-background-tasks.json"
VALIDATOR="$REPO_ROOT/claude-hooks/validate-rules.js"
FIXTURE="$(mktemp -d /tmp/stop-guard-hardener-see1636.XXXXXX)"

trap 'rm -rf "$FIXTURE"' EXIT

payload() {  # payload <tasks-json-raw>
    printf '{"hook_event_name":"Stop","session_id":"see1636-h","transcript_path":"%s/h.jsonl","stop_hook_active":false,"background_tasks":%s}' \
        "$FIXTURE" "$1"
}

RUN_RC=""; RUN_ERR=""
run_guard() {  # run_guard <tasks-json-raw>
    printf '%s' "$(payload "$1")" > "$FIXTURE/in.json"
    RUN_ERR="$FIXTURE/err.txt"
    MULTICA_TASK_ID="see1636-hardener" timeout 10 bash "$GUARD" \
        < "$FIXTURE/in.json" > "$FIXTURE/out.txt" 2> "$RUN_ERR"
    RUN_RC=$?
}

# =====================================================================
separator "H. hardener 判别力增补（锚定 / 大小写 / 清单可读性 / 治理校验）"
# =====================================================================

# H1: 终态词表锚定——status=undone 含 "done" 子串但不在词表 → 按活任务拦
run_guard '[{"id":"h1","type":"shell","status":"undone","description":"substring must not count terminal"}]'
if [ "$RUN_RC" -eq 2 ] && grep -q "h1" <<< "$(cat "$RUN_ERR" 2>/dev/null)"; then
    pass "H1: status=undone（done 子串）→ exit 2（词表锚定匹配，子串不得误判终态）"
else
    fail "H1: 子串误判终态 rc=$RUN_RC err='$(cat "$RUN_ERR" 2>/dev/null | head -c 80)'"
fi

# H2: 词表大小写敏感——status=Completed 不在词表（completed 才是）→ 按活任务拦
run_guard '[{"id":"h2","type":"shell","status":"Completed","description":"case variant not in list"}]'
if [ "$RUN_RC" -eq 2 ] && grep -q "h2" <<< "$(cat "$RUN_ERR" 2>/dev/null)"; then
    pass "H2: status=Completed → exit 2（词表大小写敏感，未知写法按活任务计）"
else
    fail "H2: 大小写变体误判终态 rc=$RUN_RC"
fi

# H3: 清单含活任务 description——逐项列出须携带可读描述
run_guard '[{"id":"h3","type":"shell","status":"running","description":"see1636-h3-desc-marker"}]'
if [ "$RUN_RC" -eq 2 ] && grep -qF "see1636-h3-desc-marker" <<< "$(cat "$RUN_ERR" 2>/dev/null)"; then
    pass "H3: stderr 清单含活任务 description 文本"
else
    fail "H3: description 未入清单 rc=$RUN_RC"
fi

# H4: 清单行格式——换行 + 两空格缩进 + `<id> [`（多行逐项形态，非单行串接；
#     双活任务使条目间分隔符进入判定面，join 形态失真即红）
run_guard '[{"id":"h4","type":"shell","status":"running","description":"fmt check"},{"id":"h4b","type":"monitor","status":"pending","description":"second entry"}]'
ERR_H4="$(cat "$RUN_ERR" 2>/dev/null)"
if [ "$RUN_RC" -eq 2 ] && grep -q $'\n  h4 \[' <<< "$ERR_H4" && grep -q $'\n  h4b \[' <<< "$ERR_H4"; then
    pass "H4: 清单行格式 = 换行 + 两空格缩进 + '<id> ['（双条目逐行）"
else
    fail "H4: 清单行格式失真 rc=$RUN_RC"
fi

# H5: 无 id 任务——以 ? 占位逐项列出，不丢行
run_guard '[{"type":"shell","status":"running","description":"no id field"}]'
if [ "$RUN_RC" -eq 2 ] && grep -qF '? [shell]' <<< "$(cat "$RUN_ERR" 2>/dev/null)"; then
    pass "H5: 无 id 任务 → '? [' 占位逐项列出"
else
    fail "H5: 无 id 任务清单失真 rc=$RUN_RC err='$(cat "$RUN_ERR" 2>/dev/null | head -c 100)'"
fi

# H6: 规则文件治理校验（§SPEC-005 同款判据入套件）：全规则须 boolean blocking；
#     run_script deny_exit_codes 通道的阻断属性失实（非 boolean）必须被校验拒绝
if node "$VALIDATOR" "$RULE_FILE" > "$FIXTURE/validate.out" 2> "$FIXTURE/validate.err" \
   && grep -q "^VALID" "$FIXTURE/validate.out" \
   && grep -q "0 invalid" "$FIXTURE/validate.out"; then
    pass "H6: 规则文件过 validate-rules 治理校验（VALID + 0 invalid）"
else
    fail "H6: 治理校验未通过 out='$(head -c 120 "$FIXTURE/validate.out" 2>/dev/null)' err='$(head -c 120 "$FIXTURE/validate.err" 2>/dev/null)'"
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
