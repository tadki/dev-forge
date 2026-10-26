#!/bin/bash
# SEE-1470 Track A: canonical RECOVERY test for SEE-899 R2 pre-flight block.
# 迁移并合并 KOL devtests 两件恢复语义：
#   tests/devtests/e2e/test_see899_r2_worktree_recovery_live_e2e.sh (A/B1/B2/C/D 场景)
#   tests/devtests/abtest/test_see899_r2_indexlock_recovery_ab.sh   (BEFORE/AFTER 差异)
# Source-driven: recovery 块从现役生产脚本 adapters/upgrade-multica-selfhost.sh
# verbatim 提取后执行；pgrep 经 PATH stub 受控（本 QA 宿主常有并发 git 守护，
# 真实 pgrep -x git 恒真——stub 才能建模目标 Mac 的"无并发 git"前提）。
# hermetic：本地 git 仓 + stub PATH，无远端依赖；故不再沿用 KOL 侧 `_live_` 命名。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/adapters/upgrade-multica-selfhost.sh"
[[ -f "$TARGET" ]] || { echo "FAIL: production script not found at $TARGET" >&2; exit 1; }

OUT_DIR="$(mktemp -d)"
RECOVERY_BLOCK="$OUT_DIR/recovery_block.sh"
HELPERS="$OUT_DIR/helpers.sh"
trap 'rm -rf "$OUT_DIR"' EXIT

# 提取范围："# 0. Pre-flight worktree recovery" 至 "Pulling latest source..." 行前，
# 去掉函数体外的 4 空格缩进（块原文位于 if [[ -d .git ]] 内）。awk 取代 sed：
# 停止模式含 "..."，与部分 sed 构建的范围语法冲突。
awk '
    /# 0\. Pre-flight worktree recovery/ { p = 1 }
    p && /^    _log "Pulling latest source\.\.\."/ { exit }
    p { sub(/^    /, ""); print }
' "$TARGET" > "$RECOVERY_BLOCK"
# 块内 _log/_err/_warn 依赖生产 helpers——一并 verbatim 提取（source 进执行上下文）。
awk '/^_log\(\) \{/,/^\}/' "$TARGET" > "$OUT_DIR/_log.fn"
awk '/^_err\(\) \{/,/^\}/' "$TARGET" > "$OUT_DIR/_err.fn"
awk '/^_warn\(\) \{/,/^\}/' "$TARGET" > "$OUT_DIR/_warn.fn"
cat "$OUT_DIR/_log.fn" "$OUT_DIR/_err.fn" "$OUT_DIR/_warn.fn" > "$HELPERS"
if [[ ! -s "$RECOVERY_BLOCK" ]] || ! bash -n "$RECOVERY_BLOCK" 2>/dev/null; then
    echo "FAIL: recovery block extraction empty/unparsable — anchor drifted in $TARGET" >&2
    cat "$RECOVERY_BLOCK" >&2
    exit 1
fi

fail=0
# pgrep stub：exit 1 = 无 git 进程（目标 Mac，锁是 stale）；0 = 有 git 进程（活锁）。
make_stubs() {
    local dir="$1" pgrep_exit="$2"
    rm -rf "$dir"; mkdir -p "$dir"
    cat > "$dir/pgrep" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-x" && "\$2" == "git" ]]; then exit ${pgrep_exit}; fi
exit 0
EOF
    chmod +x "$dir/pgrep"
}
# 同 shell source：块内 exit 才是"生产块的退出语义"，且 helpers 已在上下文中。
run_recovery_block() {
    local pgrep_exit="$1" stub_dir rc
    stub_dir="$(mktemp -d)"
    make_stubs "$stub_dir" "$pgrep_exit"
    . "$HELPERS"
    PATH="$stub_dir:$PATH"
    . "$RECOVERY_BLOCK"
    rc=$?
    rm -rf "$stub_dir"
    return $rc
}
init_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email "qa@kingoflikes.test"
    git -C "$repo" config user.name "SEE1470 sandbox"
}
# Scenario A/D 共用的 merge 冲突仓装配：main 与 feat 交替改同一 compose 后互 merge；
# 仅 frontend 服务块随场景不同（A 双服务，D 单服务传空）。
build_merge_conflict_repo() {
    local repo="$1" frontend_block="$2"
    (
        cd "$repo"
        git symbolic-ref HEAD refs/heads/main
        printf 'services:\n  backend:\n    image: v1\n%s' "$frontend_block" > docker-compose.selfhost.yml
        git add -A && git commit -qm base
        git checkout -q -b feat
        printf 'services:\n  backend:\n    image: v2-feat\n%s' "$frontend_block" > docker-compose.selfhost.yml
        git commit -qam feat
        git checkout -q main
        printf 'services:\n  backend:\n    image: v3-main\n%s' "$frontend_block" > docker-compose.selfhost.yml
        git commit -qam mainchange
        git merge feat >/dev/null 2>&1 || true
    )
}

# -----------------------------------------------------------------------------
# Scenario A: MERGE_HEAD + unmerged paths → merge --abort → HEAD 态恢复
# -----------------------------------------------------------------------------
echo "=== Scenario A: MERGE_HEAD + unmerged paths ==="
REPO_A="$(mktemp -d)"
init_repo "$REPO_A"
build_merge_conflict_repo "$REPO_A" $'  frontend:\n    image: fe1\n'
before_mh=$(test -f "$REPO_A/.git/MERGE_HEAD" && echo Y || echo N)
echo "Before: MERGE_HEAD=$before_mh"
( cd "$REPO_A" && run_recovery_block 1 ) > "$OUT_DIR/A.out" 2>&1
exit_a=$?
after_mh=$(test -f "$REPO_A/.git/MERGE_HEAD" && echo Y || echo N)
after_um=$(git -C "$REPO_A" ls-files --unmerged | wc -l)
head_image=$(grep -o 'image: v3-main' "$REPO_A/docker-compose.selfhost.yml" | head -1)
echo "After: MERGE_HEAD=$after_mh unmerged=$after_um exit=$exit_a"
cat "$OUT_DIR/A.out"
[[ "$exit_a" != "0" ]] && { echo "FAIL [A]: recovery block exited $exit_a"; fail=1; }
[[ "$after_mh" != "N" ]] && { echo "FAIL [A]: MERGE_HEAD still present"; fail=1; }
[[ "$after_um" != "0" ]] && { echo "FAIL [A]: unmerged paths remain"; fail=1; }
[[ "$head_image" != "image: v3-main" ]] && { echo "FAIL [A]: working tree not restored to HEAD"; fail=1; }
rm -rf "$REPO_A"

# -----------------------------------------------------------------------------
# Scenario B1: stale index.lock（无 git 进程）→ _warn + 移除 + 继续
#   （indexlock AB 的 AFTER 腿：lock_after=removed、后续 stash 可用）
# -----------------------------------------------------------------------------
echo ""
echo "=== Scenario B1: stale index.lock (no git process) ==="
REPO_B1="$(mktemp -d)"
init_repo "$REPO_B1"
printf 'services:\n  backend:\n    image: backend:v1\n' > "$REPO_B1/docker-compose.selfhost.yml"
git -C "$REPO_B1" add -A && git -C "$REPO_B1" commit -qm base
printf 'services:\n  backend:\n    image: backend:local\n' > "$REPO_B1/docker-compose.selfhost.yml"
touch "$REPO_B1/.git/index.lock"
( cd "$REPO_B1" && run_recovery_block 1 ) > "$OUT_DIR/B1.out" 2>&1
exit_b1=$?
lock_b1=$(test -f "$REPO_B1/.git/index.lock" && echo REMAINS || echo removed)
stash_ok=$(git -C "$REPO_B1" stash push -m post-recovery >/dev/null 2>&1 && echo stashed || echo blocked)
echo "exit=$exit_b1 lock=$lock_b1 post_stash=$stash_ok"
cat "$OUT_DIR/B1.out"
[[ "$exit_b1" != "0" ]] && { echo "FAIL [B1]: stale lock removal caused exit $exit_b1"; fail=1; }
[[ "$lock_b1" != "removed" ]] && { echo "FAIL [B1]: stale lock not removed"; fail=1; }
grep -q 'index.lock found — removing' "$OUT_DIR/B1.out" \
    || { echo "FAIL [B1]: missing stale-lock warn message"; fail=1; }
[[ "$stash_ok" != "stashed" ]] && { echo "FAIL [B1]: git index unusable after recovery (stash $stash_ok)"; fail=1; }
rm -rf "$REPO_B1"

# -----------------------------------------------------------------------------
# Scenario B2: index.lock + live git 进程 → fail-fast，锁保留
# -----------------------------------------------------------------------------
echo ""
echo "=== Scenario B2: index.lock with live git process ==="
REPO_B2="$(mktemp -d)"
init_repo "$REPO_B2"
printf 'x\n' > "$REPO_B2/f.txt"
git -C "$REPO_B2" add -A && git -C "$REPO_B2" commit -qm base
touch "$REPO_B2/.git/index.lock"
( cd "$REPO_B2" && run_recovery_block 0 ) > "$OUT_DIR/B2.out" 2>&1
exit_b2=$?
lock_b2=$(test -f "$REPO_B2/.git/index.lock" && echo REMAINS || echo removed)
echo "exit=$exit_b2 lock=$lock_b2"
cat "$OUT_DIR/B2.out"
[[ "$exit_b2" == "0" ]] && { echo "FAIL [B2]: should have failed-fast on live lock"; fail=1; }
[[ "$lock_b2" != "REMAINS" ]] && { echo "FAIL [B2]: lock should be preserved when git is running"; fail=1; }
grep -q 'A git process is running' "$OUT_DIR/B2.out" \
    || { echo "FAIL [B2]: missing actionable error about running git process"; fail=1; }
rm -rf "$REPO_B2"

# -----------------------------------------------------------------------------
# Scenario C: 健康仓库 → 零干扰（无 WARN、工作树不变）
# -----------------------------------------------------------------------------
echo ""
echo "=== Scenario C: healthy repo (zero interference) ==="
REPO_C="$(mktemp -d)"
init_repo "$REPO_C"
printf 'x\n' > "$REPO_C/f.txt"
git -C "$REPO_C" add -A && git -C "$REPO_C" commit -qm base
printf 'local\n' > "$REPO_C/local.txt"
( cd "$REPO_C" && run_recovery_block 1 ) > "$OUT_DIR/C.out" 2>&1
exit_c=$?
status_c=$(git -C "$REPO_C" status --short | tr '\n' ' ')
warn_c=$(grep -c 'WARN' "$OUT_DIR/C.out" || true)
echo "exit=$exit_c status_after=[$status_c] warns=$warn_c"
[[ "$exit_c" != "0" ]] && { echo "FAIL [C]: healthy repo caused exit $exit_c"; fail=1; }
[[ "$warn_c" != "0" ]] && { echo "FAIL [C]: recovery block warned on healthy repo"; fail=1; }
[[ "$status_c" != "?? local.txt " ]] && { echo "FAIL [C]: healthy repo state altered"; fail=1; }
rm -rf "$REPO_C"

# -----------------------------------------------------------------------------
# Scenario D: 冲突态恢复 → worktree 干净，正常 stash/pull/pop 流可继续
# -----------------------------------------------------------------------------
echo ""
echo "=== Scenario D: recovery then normal flow readiness ==="
REPO_D="$(mktemp -d)"
init_repo "$REPO_D"
build_merge_conflict_repo "$REPO_D" ""
( cd "$REPO_D" && run_recovery_block 1 ) > "$OUT_DIR/D.out" 2>&1
exit_d=$?
d_status=$(git -C "$REPO_D" status --short | wc -l)
echo "recovery exit=$exit_d post-recovery dirty entries=$d_status"
cat "$OUT_DIR/D.out"
[[ "$exit_d" != "0" ]] && { echo "FAIL [D]: recovery did not exit cleanly ($exit_d)"; fail=1; }
[[ "$d_status" != "0" ]] && { echo "FAIL [D]: worktree not clean after recovery ($d_status dirty entries)"; fail=1; }
rm -rf "$REPO_D"

echo ""
if [[ "$fail" -eq 0 ]]; then
    echo "PASS: SEE-899 R2 recovery block scenarios all green (extracted verbatim from $TARGET)."
    exit 0
else
    exit 1
fi
