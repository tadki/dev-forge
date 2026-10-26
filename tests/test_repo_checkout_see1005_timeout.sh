#!/bin/bash
# SEE-1470 Track A: SEE-1005 repo-checkout 超时保护 + 重入/marker 语义（hermetic 版）。
# 自 KOL devtests/scripts/test_see1005_repo_checkout_timeout.sh 迁入并 sandbox 化：
#   - 硬编码 issue id / 真实远端分支 / 真实 multica CLI 依赖全部移除；
#   - origin = 一次性本地 bare 仓，multica CLI = PATH shim，git 可选 sentinel 包装；
#   - TEMP 重定向进沙箱，marker 断言不再触碰真实 /tmp 上的生产 marker。
# 覆盖（与源件 §SPEC-021/022 对齐）：
#   S0 静态: 所有阻塞网络 op 均被 timeout 包裹（对现役生产脚本）
#   S1 重入早退: 冷/暖双探针 — exit 0、有界、0 网络 sentinel、合法 hint JSON
#   S2 align writer: marker 过期 → 有界 exit 0 + marker 重写为新鲜
#   S3 timeout 软失败: 网络挂起 → timeout 杀死 → fallback exit 0
# 裁定（不迁移，Track B 删除源件后语义由本套件与既有 EXCLUDED 簇承接）：
#   - 源件 S4（hook-wrapper→dispatcher→repo-checkout 真实三层管道）依赖真实
#     multica CLI/workdir 布局，属 run_all EXCLUDED 的 env:multica-cli 簇口径
#     （test_repo_checkout_see1008_prod_sim.sh 等真机套件已覆盖该链路）；
#   - 源件 S5（pre/post 修复 A/B）依赖 KOL git 历史中的 c520ceb 提交，
#     devtests 目录本身即 Track B 删除对象，历史考古不可持续；修复有效性
#     由本套件 S3（timeout 生效）与 S0（静态覆盖）共同承接。
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/claude-hooks/scripts/repo-checkout.sh"
[[ -f "$SCRIPT" ]] || { echo "FAIL: repo-checkout.sh not found at $SCRIPT" >&2; exit 1; }

SANDBOX="$(mktemp -d)"
TEMP_SANDBOX="$SANDBOX/tmp"
WORKING_BRANCH="qa/see1005-canon"
REPO_DIR_NAME="repo-checkout-canon"
FAKE_ISSUE_ID="00000000-0000-4000-8000-000000000000"
trap 'rm -rf "$SANDBOX"' EXIT
export TEMP="$TEMP_SANDBOX"
mkdir -p "$TEMP_SANDBOX"

PASS=0; FAIL=0; FAIL_NAMES=()
pass() { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); FAIL_NAMES+=("$1"); }
info() { echo "         $*"; }
now_ms() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f", b-a}'; }
marker_path() { printf '%s/.cc-aligned-%s' "$TEMP_SANDBOX" "$(printf '%s' "$WORKDIR/$REPO_DIR_NAME" | tr '/' '_' | tr ' ' '_')"; }

# --- 合成 multica workdir + 本地 bare origin ---------------------------------
setup_workdir() {
    git init -q --bare -b master "$SANDBOX/origin.git"
    git clone -q "$SANDBOX/origin.git" "$SANDBOX/seed"
    git -C "$SANDBOX/seed" config user.email "qa@kingoflikes.test"
    git -C "$SANDBOX/seed" config user.name "SEE1470 sandbox"
    echo base > "$SANDBOX/seed/base.txt"
    git -C "$SANDBOX/seed" add -A && git -C "$SANDBOX/seed" commit -qm base
    git -C "$SANDBOX/seed" push -q origin master
    # working branch 快进在 master 之上 → §B auto-rebase 的 merge-base 前置恒真
    git -C "$SANDBOX/seed" checkout -qb "$WORKING_BRANCH"
    echo wb > "$SANDBOX/seed/wb.txt"
    git -C "$SANDBOX/seed" add -A && git -C "$SANDBOX/seed" commit -qm wb
    git -C "$SANDBOX/seed" push -q origin "$WORKING_BRANCH"

    WORKDIR="$SANDBOX/workdir"
    mkdir -p "$WORKDIR/.multica/project"
    cat > "$WORKDIR/.multica/project/resources.json" <<EOF
{"resources": [{"resource_type": "github_repo", "resource_ref": {"url": "https://git.local/test/$REPO_DIR_NAME.git"}}]}
EOF
    # 预置检出（multica repo checkout 产物同构）：本地分支跟踪 origin/<wb>
    git clone -q "$SANDBOX/origin.git" "$WORKDIR/$REPO_DIR_NAME"
    git -C "$WORKDIR/$REPO_DIR_NAME" config user.email "qa@kingoflikes.test"
    git -C "$WORKDIR/$REPO_DIR_NAME" config user.name "SEE1470 sandbox"
    git -C "$WORKDIR/$REPO_DIR_NAME" checkout -q -b "agent/see1005canon" "origin/$WORKING_BRANCH"
}

# --- PATH shim：fake multica（metadata/repo-checkout 合同）+ 可选 sentinel git
BIN_DIR=""
build_shadow_bin() {
    local mode="$1" flag="$2"   # mode: record | hang
    BIN_DIR="$(mktemp -d)"
    local real_git
    real_git="$(command -v git)"
    cat > "$BIN_DIR/git" <<EOF
#!/bin/bash
case " \$* " in
  *" fetch "*|*" ls-remote "*|*" push "*|*" clone "*)
    echo "NETWORK: git \$*" >> "$flag"
    [ "$mode" = "hang" ] && sleep 60
    exit 1
    ;;
esac
exec "$real_git" "\$@"
EOF
    chmod +x "$BIN_DIR/git"
    make_multica_shim "$BIN_DIR"
}
# 无 sentinel 场景（S2 真跑本地 align）也必须隔离真实 multica CLI。
make_multica_shim() {
    local dir="$1"
    cat > "$dir/multica" <<EOF
#!/bin/bash
case "\$1" in
  issue)
    case "\$2" in
      metadata)
        [ "\$3" = list ] && { echo '{"working_branch":"$WORKING_BRANCH","pr_number":0}'; exit 0; }
        exit 0 ;;
      run-messages) echo '[{"issue_id":"$FAKE_ISSUE_ID"}]'; exit 0 ;;
      get) echo '{"identifier":"SEE-0000","id":"$FAKE_ISSUE_ID"}'; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  agent) exit 0 ;;
  repo)
    # multica repo checkout 合同：repo 已在则 KEPT；否则从本地 bare 建检出并
    # 建 agent 分支跟踪 origin/<wb>（与生产 CLI 检出形态同构）。
    if [ "\$2" = checkout ]; then
      if [ -d "\$PWD/$REPO_DIR_NAME/.git" ]; then exit 0; fi
      git clone -q "$SANDBOX/origin.git" "\$PWD/$REPO_DIR_NAME"
      git -C "\$PWD/$REPO_DIR_NAME" checkout -q -b agent/shim "origin/$WORKING_BRANCH"
      exit 0
    fi
    exit 0 ;;
  daemon) exit 0 ;;
  *) exit 0 ;;
esac
EOF
    chmod +x "$dir/multica"
}

# 运行生产脚本（空 stdin），记录 wall/exit/输出。
run_script() {
    local target="$1" t0 t1
    t0=$(now_ms)
    OUT="$( cd "$WORKDIR" && printf '' | bash "$target" 2>/dev/null )"
    RC=$?
    t1=$(now_ms)
    ELAPSED=$(elapsed "$t0" "$t1")
}
assert_json() {
    printf '%s' "$OUT" | grep -q '"hookSpecificOutput"'
}

# --- S0: 静态 timeout 覆盖 ----------------------------------------------------
s0_static_timeout_coverage() {
    echo "S0  静态: 阻塞网络 op 是否全部被 timeout 包裹"
    local n_fetch n_lsremote n_push n_rebase n_multica n_checkout
    n_fetch=$(grep -cE 'timeout "\$GIT_FETCH_TIMEOUT" git fetch' "$SCRIPT")
    n_lsremote=$(grep -cE 'timeout "\$GIT_FETCH_TIMEOUT" git ls-remote' "$SCRIPT")
    n_push=$(grep -cE 'timeout "\$GIT_PUSH_TIMEOUT" git .*push' "$SCRIPT")
    n_rebase=$(grep -cE 'timeout "\$GIT_REBASE_TIMEOUT" git' "$SCRIPT")
    n_multica=$(grep -cE 'timeout "\$MULTICA_CLI_TIMEOUT" multica' "$SCRIPT")
    n_checkout=$(grep -cE 'timeout "\$REPO_CHECKOUT_TIMEOUT" multica repo checkout' "$SCRIPT")
    info "git fetch=$n_fetch ls-remote=$n_lsremote push=$n_push rebase/wt=$n_rebase multica=$n_multica repo-checkout=$n_checkout"
    if [ "$n_fetch" -ge 1 ] && [ "$n_lsremote" -ge 1 ] && [ "$n_push" -ge 1 ] \
       && [ "$n_rebase" -ge 1 ] && [ "$n_multica" -ge 4 ] && [ "$n_checkout" -ge 1 ]; then
        pass "S0 所有阻塞 op 族均有 timeout 包裹"
    else
        fail "S0 timeout 覆盖不全 (见上计数)"
    fi
    # 强断言：剥离双引号字符串与注释后，不得残留裸（无 timeout）的 git 网络命令
    local bare
    bare=$(awk '
        BEGIN { in_str = 0 }
        {
            out = ""
            n = split($0, ch, "")
            for (i = 1; i <= n; i++) {
                if (ch[i] == "\"") { in_str = !in_str; continue }
                if (!in_str) out = out ch[i]
            }
            sub(/#.*/, "", out)
            if (out ~ /git (fetch|ls-remote|push)/ && out !~ /timeout/) bare++
        }
        END { print bare+0 }
    ' "$SCRIPT")
    if [ "$bare" -eq 0 ]; then
        pass "S0 无裸 (无 timeout) 的可执行 git fetch/ls-remote/push"
    else
        fail "S0 发现 $bare 处裸网络 op"
    fi
}

# --- S1: 重入早退（冷/暖双探针；marker 新鲜 + upstream 在位） ------------------
s1_early_exit() {
    echo "S1  重入早退: 冷物化有界 + 暖重入瞬时 (0 网络 sentinel)"
    fresh_marker
    local flag; flag="$(mktemp)"
    build_shadow_bin record "$flag"

    ( cd "$WORKDIR" && PATH="$BIN_DIR:$PATH" run_script "$SCRIPT"
      printf '%s' "$RC" > "$flag.rc"; printf '%s' "$ELAPSED" > "$flag.el"; printf '%s' "$OUT" > "$flag.out" )
    local rc el out
    rc=$(cat "$flag.rc"); el=$(cat "$flag.el"); out=$(cat "$flag.out")
    OUT="$out"
    info "[cold] exit=$rc elapsed=${el}s sentinel hits=$(wc -l < "$flag")"
    [ "$rc" -eq 0 ] && pass "S1 probe1 exit 0" || fail "S1 probe1 非零退出 rc=$rc"
    awk -v e="$el" 'BEGIN{exit !(e<10)}' && pass "S1 probe1 <10s 有界 (${el}s)" || fail "S1 probe1 超 10s (${el}s)"
    [ ! -s "$flag" ] && pass "S1 probe1 0 网络 I/O (sentinel)" || fail "S1 probe1 触发网络 op: $(cat "$flag")"
    assert_json && pass "S1 probe1 输出合法 hookSpecificOutput JSON" || fail "S1 probe1 输出非 JSON"
    printf '%s' "$out" | grep -q '重入/子进程保护' \
        && pass "S1 probe1 命中早退提示" || fail "S1 probe1 未命中早退提示"

    local flag2; flag2="$(mktemp)"
    build_shadow_bin record "$flag2"
    ( cd "$WORKDIR" && PATH="$BIN_DIR:$PATH" run_script "$SCRIPT"
      printf '%s' "$RC" > "$flag2.rc"; printf '%s' "$ELAPSED" > "$flag2.el"; printf '%s' "$OUT" > "$flag2.out" )
    rc=$(cat "$flag2.rc"); el=$(cat "$flag2.el"); out=$(cat "$flag2.out")
    OUT="$out"
    info "[warm] exit=$rc elapsed=${el}s sentinel hits=$(wc -l < "$flag2")"
    [ "$rc" -eq 0 ] && pass "S1 probe2 exit 0" || fail "S1 probe2 非零退出 rc=$rc"
    awk -v e="$el" 'BEGIN{exit !(e<0.5)}' && pass "S1 probe2 <0.5s 瞬时 (${el}s) — SEE-1005 重入契约" || fail "S1 probe2 超 0.5s (${el}s)"
    [ ! -s "$flag2" ] && pass "S1 probe2 0 网络 I/O (sentinel)" || fail "S1 probe2 触发了网络 op: $(cat "$flag2")"
    printf '%s' "$out" | grep -q '重入/子进程保护' && pass "S1 probe2 命中早退提示" || fail "S1 probe2 未命中早退提示"
    rm -rf "$BIN_DIR" "$flag" "$flag".rc "$flag".el "$flag".out "$flag2" "$flag2".rc "$flag2".el "$flag2".out
}

# --- S2: align writer——marker 过期 → 有界 exit 0 + marker 重写 ----------------
s2_full_align() {
    echo "S2  align (本地 origin): marker 过期 → 有界 exit 0 + marker 重写"
    local marker; marker="$(marker_path)"
    touch -d '2 hours ago' "$marker"   # stale
    local shim_dir; shim_dir="$(mktemp -d)"
    make_multica_shim "$shim_dir"
    ( cd "$WORKDIR" && PATH="$shim_dir:$PATH" run_script "$SCRIPT"
      printf '%s' "$RC" > "$SANDBOX/.s2.rc"; printf '%s' "$ELAPSED" > "$SANDBOX/.s2.el"; printf '%s' "$OUT" > "$SANDBOX/.s2.out" )
    local rc el out
    rc=$(cat "$SANDBOX/.s2.rc"); el=$(cat "$SANDBOX/.s2.el"); out=$(cat "$SANDBOX/.s2.out")
    OUT="$out"
    info "exit=$rc elapsed=${el}s"
    [ "$rc" -eq 0 ] && pass "S2 exit 0" || fail "S2 非零退出 rc=$rc"
    awk -v e="$el" 'BEGIN{exit !(e<15)}' && pass "S2 <15s 有界 (${el}s)" || fail "S2 超 15s (${el}s) — 可能阻塞"
    assert_json && pass "S2 输出合法 hint JSON" || fail "S2 输出非 JSON"
    # marker 重写 = writer 侧；S1 early-exit 读 = reader 侧，共同钉死 writer↔reader 合同
    local age=-1
    [ -f "$marker" ] && age=$(( $(date +%s) - $(stat -c %Y "$marker") ))
    [ "$age" -ge 0 ] && [ "$age" -le 30 ] && pass "S2 align 后 marker 重写为新鲜 (age=${age}s)" || fail "S2 marker 未重写 (age=${age}s)"
    rm -rf "$shim_dir" "$SANDBOX/.s2.rc" "$SANDBOX/.s2.el" "$SANDBOX/.s2.out"
}

# --- S3: timeout 软失败（hermetic）--------------------------------------------
s3_timeout_soft_fail() {
    echo "S3  timeout 软失败: 网络挂起 → timeout 杀死 → fallback exit 0"
    local copy; copy="$(mktemp)"
    sed -e 's/^GIT_FETCH_TIMEOUT=30.*/GIT_FETCH_TIMEOUT=1/' \
        -e 's/^GIT_PUSH_TIMEOUT=45.*/GIT_PUSH_TIMEOUT=1/' \
        -e 's/^GIT_REBASE_TIMEOUT=60.*/GIT_REBASE_TIMEOUT=1/' \
        -e 's/^MULTICA_CLI_TIMEOUT=20.*/MULTICA_CLI_TIMEOUT=1/' \
        -e 's/^REPO_CHECKOUT_TIMEOUT=120.*/REPO_CHECKOUT_TIMEOUT=1/' "$SCRIPT" > "$copy"
    local marker; marker="$(marker_path)"
    touch -d '2 hours ago' "$marker"   # stale → 走 align → fetch 挂起
    local flag; flag="$(mktemp)"
    build_shadow_bin hang "$flag"
    ( cd "$WORKDIR" && PATH="$BIN_DIR:$PATH" run_script "$copy"
      printf '%s' "$RC" > "$flag.rc"; printf '%s' "$ELAPSED" > "$flag.el"; printf '%s' "$OUT" > "$flag.out" )
    local rc el out
    rc=$(cat "$flag.rc"); el=$(cat "$flag.el"); out=$(cat "$flag.out")
    OUT="$out"
    info "exit=$rc elapsed=${el}s sentinel hits=$(wc -l < "$flag")"
    [ "$rc" -eq 0 ] && pass "S3 网络挂起下仍 exit 0 (软失败走 fallback)" || fail "S3 非零退出 rc=$rc"
    awk -v e="$el" 'BEGIN{exit !(e<12)}' && pass "S3 <12s 有界 (${el}s, timeout 杀死挂起 op)" || fail "S3 超 12s (${el}s) — timeout 未生效"
    [ -s "$flag" ] && pass "S3 确实触达网络 op 并被 timeout 截断 ($(wc -l < "$flag") 次)" || fail "S3 未触达网络 op, 未真正测试 timeout"
    assert_json && pass "S3 fallback 产出合法 hint JSON" || fail "S3 fallback 无合法 JSON"
    rm -rf "$BIN_DIR" "$copy" "$flag" "$flag".rc "$flag".el "$flag".out
    fresh_marker   # 恢复（S3 align 失败 marker 未重写）
}
fresh_marker() { touch "$(marker_path)"; }

# --- main ---------------------------------------------------------------------
setup_workdir
s0_static_timeout_coverage
s3_timeout_soft_fail      # hermetic 先行（不推进状态）
s1_early_exit
s2_full_align             # writer 侧真跑本地 align

echo
echo "=== 总结: PASS=$PASS FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
    echo "失败项:"; printf '  - %s\n' "${FAIL_NAMES[@]}"
    exit 1
fi
echo "全部通过。"
exit 0
