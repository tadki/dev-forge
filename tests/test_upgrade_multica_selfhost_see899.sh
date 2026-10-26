#!/bin/bash
# SEE-1470 Track A: canonical upgrade-surface test for SEE-899 (static + compat).
# 迁移并合并 KOL devtests 三件静态语义：
#   tests/devtests/scripts/test_see899_regression.sh        (fail-fast / idiom / helpers)
#   tests/devtests/scripts/test_see899_r2_bash32_compat.sh  (bash 3.2 兼容面 + R2 结构)
#   tests/devtests/abtest/test_see899_empty_array_bash32_ab.sh (idiom 功能行为)
# Source-driven: 全部断言直接指向现役生产脚本 adapters/upgrade-multica-selfhost.sh，
# 不再经 DEVFORGE_ROOT 环境推断跨仓寻址。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/adapters/upgrade-multica-selfhost.sh"

fail=0
note() { echo "[see899-static] $*"; }

# --- 1. 语法（R1/R2 两轮修改不得引入 quoting/heredoc 损伤） -------------------
if bash -n "$TARGET"; then
    note "PASS: bash -n syntax check"
else
    note "FAIL: bash -n syntax check"
    fail=1
fi

# --- 2. bash 3.2 目标平台：4.0+ 独占构造必须缺席 ------------------------------
declare -a offenders=(
    'declare -A'
    'local -A'
    'mapfile '
    'readarray '
    '${,[^}]*}'
    '${^[^}]*}'
    'coproc '
    '&>> '
)
hit=0
for pat in "${offenders[@]}"; do
    # 允许注释行携带示例；仅活动代码违规计数
    if grep -nE "$pat" "$TARGET" | grep -qv '^[0-9]*: *#'; then
        note "FAIL: bash 4.0+ only construct found matching /$pat/:"
        grep -nE "$pat" "$TARGET" | grep -v '^[0-9]*: *#' | sed 's/^/    /'
        fail=1
        hit=1
    fi
done
[[ "$hit" -eq 0 ]] && note "PASS: no bash 4.0+ only constructs"

# --- 3. R1 idiom：安全展开在位、裸展开缺席（结构断言生产脚本） ----------------
if grep -qE 'for _img in \$\{_PULL_IMAGES\[@\]\+"\$\{_PULL_IMAGES\[@\]\}"\}; do' "$TARGET" \
   && ! grep -qE 'for _img in "\$\{_PULL_IMAGES\[@\]\}"; do' "$TARGET"; then
    note "PASS: bash 3.2-safe array expansion idiom intact (bare form absent)"
else
    note "FAIL: R1 array expansion idiom regressed"
    fail=1
fi

# --- 4. stash pop fail-fast：exit 1 在位、输出抑制缺席 ------------------------
if grep -qE '_err "Stashed changes conflict with the updated compose file\."' "$TARGET" \
   && awk '/git stash pop; then/{f=1} f&&/exit 1/{print; exit}' "$TARGET" | grep -q 'exit 1'; then
    note "PASS: fail-fast exit 1 present on stash pop failure"
else
    note "FAIL: fail-fast exit 1 missing on stash pop failure"
    fail=1
fi
if grep -nE 'git stash pop' "$TARGET" | grep -q '2>/dev/null'; then
    note "FAIL: 'git stash pop' still has 2>/dev/null (conflict output hidden)"
    fail=1
else
    note "PASS: stash pop output no longer suppressed"
fi

# --- 5. 修复依赖的 helpers 与手动恢复引导 -------------------------------------
for fn in '_err()' '_warn()' '_log()'; do
    if ! grep -qE "^$fn" "$TARGET"; then
        note "FAIL: helper $fn not defined"
        fail=1
    fi
done
[[ "$fail" -eq 0 ]] && note "PASS: _err/_warn/_log helpers defined"
for needle in 'git stash pop' 'git stash list' 'git status'; do
    if ! grep -q "$needle" "$TARGET"; then
        note "FAIL: recovery guidance missing '$needle'"
        fail=1
    fi
done
[[ "$fail" -eq 0 ]] && note "PASS: recovery guidance commands present"

# --- 6. R2 recovery block：markers 在位且先于 pull/stash ----------------------
if grep -q '# 0\. Pre-flight worktree recovery' "$TARGET" \
   && grep -q 'Stale .git/index.lock found' "$TARGET" \
   && grep -q 'git merge --abort' "$TARGET" \
   && grep -q 'git reset --hard origin/main' "$TARGET" \
   && grep -q 'A git process is running' "$TARGET"; then
    note "PASS: R2 recovery block markers present"
else
    note "FAIL: R2 recovery block markers missing"
    fail=1
fi
recovery_line=$(grep -n '# 0\. Pre-flight worktree recovery' "$TARGET" | head -1 | cut -d: -f1)
stash_line=$(grep -n 'git stash push' "$TARGET" | head -1 | cut -d: -f1)
pulling_line=$(grep -n '_log "Pulling latest source' "$TARGET" | head -1 | cut -d: -f1)
if [[ -n "$recovery_line" && -n "$stash_line" && -n "$pulling_line" ]] \
   && [[ "$recovery_line" -lt "$pulling_line" && "$pulling_line" -lt "$stash_line" ]]; then
    note "PASS: recovery/pull/stash ordering ($recovery_line < $pulling_line < $stash_line)"
else
    note "FAIL: recovery/pull/stash ordering wrong"
    fail=1
fi

# --- 7. recovery block 片段独立可解析 ----------------------------------------
RECOV="$(mktemp)"
trap 'rm -f "$RECOV"' EXIT
awk '
    /# 0\. Pre-flight worktree recovery/ { p = 1 }
    p && /^    _log "Pulling latest source\.\.\."/ { exit }
    p { sub(/^    /, ""); print }
' "$TARGET" > "$RECOV"
if bash -n "$RECOV"; then
    note "PASS: extracted recovery block parses standalone"
else
    note "FAIL: extracted recovery block has syntax errors"
    fail=1
fi

# --- 8. idiom 功能行为（当前 bash 上；bash 3.2 原生复现仅 macOS 有） ----------
before_loop='for x in "${arr[@]}"; do echo "elem:[$x]"; done; echo "DONE"'
after_loop='for x in ${arr[@]+"${arr[@]}"}; do echo "elem:[$x]"; done; echo "DONE"'
if b_empty_out=$(bash -c "set -euo pipefail; arr=(); $after_loop" 2>&1); then
    if printf '%s\n' "$b_empty_out" | grep -q 'DONE'; then
        note "PASS: AFTER idiom survives empty array under set -euo pipefail"
    else
        note "FAIL: AFTER idiom empty array did not reach DONE"
        fail=1
    fi
else
    note "FAIL: AFTER idiom aborted on empty array"
    fail=1
fi
pop_out="$(bash -c "set -euo pipefail; arr=(nginx:latest 'redis:7.0-alpine'); $after_loop" 2>&1)"
pop_count=$(printf '%s\n' "$pop_out" | grep -c 'elem:')
if [[ "$pop_count" == "2" ]] \
   && printf '%s\n' "$pop_out" | grep -q 'elem:\[nginx:latest\]' \
   && printf '%s\n' "$pop_out" | grep -q 'elem:\[redis:7.0-alpine\]'; then
    note "PASS: AFTER idiom iterates populated array with elements intact"
else
    note "FAIL: AFTER idiom populated-array iteration broken (count=$pop_count)"
    fail=1
fi
bash_major=$(bash --version | head -1 | sed -E 's/.*GNU bash, version ([0-9]+).*/\1/')
bash_minor=$(bash --version | head -1 | sed -E 's/.*GNU bash, version [0-9]+\.([0-9]+).*/\1/')
# BEFORE 形态仅在 bash <4.4 复现 unbound abort；本环境多为 5.x，只记录不复现信息。
if [[ "$bash_major" -eq 3 ]]; then
    if bash -c "set -euo pipefail; arr=(); $before_loop" >/dev/null 2>&1; then
        note "INFO: BEFORE idiom passed on bash 3.$bash_minor (expected abort on 3.2)"
    else
        note "INFO: BEFORE idiom aborts on bash 3.$bash_minor (3.2 bug reproduced)"
    fi
else
    note "INFO: bash $bash_major.$bash_minor does not reproduce the 3.2 abort; structural check (item 3) is the guard"
fi

if [[ "$fail" -eq 0 ]]; then
    echo "PASS: SEE-899 upgrade-surface static + compat guards all green ($TARGET)."
    exit 0
else
    exit 1
fi
