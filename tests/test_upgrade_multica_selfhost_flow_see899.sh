#!/usr/bin/env bash
# SEE-1470 Track A: canonical upgrade-FLOW test for SEE-899.
# 迁移并合并 KOL devtests 三件流语义：
#   tests/devtests/e2e/test_see899_upgrade_flow_live_e2e.sh          (A/A2/A3/B 路径)
#   tests/devtests/abtest/test_see899_stash_conflict_failfast_ab.sh  (BEFORE/AFTER 差异)
# Source-driven: stash-pop 块与 image-pull 循环从现役生产脚本
# adapters/upgrade-multica-selfhost.sh verbatim 提取后执行——修复逻辑本身
# 来自生产源，测试内不重写副本（§SPEC-003 不得只执行内置副本）。
# 真实脚本经 SSH/SCP 重入并对远端 Mac 操作，QA 环境不可达；两个被修复的
# 代码块以受控沙箱（docker stub + 本地 git repo）直接驱动。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/adapters/upgrade-multica-selfhost.sh"
[[ -f "$TARGET" ]] || { echo "FAIL: production script not found at $TARGET" >&2; exit 1; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
HELPERS="$SANDBOX/helpers.sh"
STASH_BLOCK="$SANDBOX/stash_block.sh"
PULL_LOOP="$SANDBOX/pull_loop.sh"

# --- verbatim 提取（锚点漂移 → 空块/语法错 → 测试红，属 Harti 硬化面） --------
awk '/^_log\(\) \{/,/^\}/' "$TARGET" > "$SANDBOX/_log.fn"
awk '/^_err\(\) \{/,/^\}/' "$TARGET" > "$SANDBOX/_err.fn"
awk '/^_warn\(\) \{/,/^\}/' "$TARGET" > "$SANDBOX/_warn.fn"
cat "$SANDBOX/_log.fn" "$SANDBOX/_err.fn" "$SANDBOX/_warn.fn" > "$HELPERS"
awk '
    /^    # Attempt to restore stashed changes/ { p = 1 }
    p && /^    _log "Source updated\."$/ { exit }
    p { sub(/^    /, ""); print }
' "$TARGET" > "$STASH_BLOCK"
awk '
    /^for _img in/ { p = 1 }
    p && /^_log "Images updated\."$/ { print; exit }
    p { print }
' "$TARGET" > "$PULL_LOOP"

fail=0
guard_extract() {
    local label="$1" file="$2"
    if [[ ! -s "$file" ]] || ! bash -n "$file" 2>/dev/null; then
        echo "FAIL: extraction of $label is empty or unparsable — anchor drifted in $TARGET" >&2
        cat "$file" >&2
        exit 1
    fi
}
guard_extract "helpers" "$HELPERS"
guard_extract "stash-pop block" "$STASH_BLOCK"
guard_extract "image-pull loop" "$PULL_LOOP"

# 生产块内的 exit 必须仍是 fail-fast 语义：提取后子 shell 退出码 1。
setup_conflict_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email "qa@kingoflikes.test"
    git -C "$repo" config user.name "SEE1470 sandbox"
    printf 'services:\n  backend:\n    image: backend:v1\n' > "$repo/docker-compose.selfhost.yml"
    git -C "$repo" add -A
    git -C "$repo" commit -qm "base compose"
    # 本地修改（升级脚本会在 pull 前 stash 它）
    printf 'services:\n  backend:\n    image: backend:v1\n    ports:\n      - "9999:8080"\n' > "$repo/docker-compose.selfhost.yml"
    git -C "$repo" stash push -qm "upgrade-multica-auto-stash-test"
    # 上游变更：与被 stash 的本地修改冲突
    printf 'services:\n  backend:\n    image: backend:v2\n    environment:\n      - FOO=bar\n' > "$repo/docker-compose.selfhost.yml"
    git -C "$repo" add -A
    git -C "$repo" commit -qm "upstream compose update"
}

# ===========================================================================
# Path B: stash pop 冲突 → 生产 fail-fast 块 exit 1 + stash 保留
# ===========================================================================
echo "=== Path B: stash pop conflict (production fail-fast block) ==="
REPO_B="$SANDBOX/repo_b"
setup_conflict_repo "$REPO_B"
b_out="$( cd "$REPO_B" && had_changes=true && . "$HELPERS" && . "$STASH_BLOCK" 2>&1 )"
b_exit=$?
b_stash=$(git -C "$REPO_B" stash list | wc -l)
echo "exit=$b_exit stash_preserved=$b_stash"
echo "$b_out"
[[ "$b_exit" != "1" ]] && { echo "FAIL [B]: production block did not fail-fast (expected exit 1, got $b_exit)"; fail=1; }
grep -q 'ERROR: Stashed changes conflict' <<<"$b_out" \
    || { echo "FAIL [B]: missing actionable conflict error message"; fail=1; }
grep -q 'git stash pop' <<<"$b_out" && grep -q 'git stash list' <<<"$b_out" \
    || { echo "FAIL [B]: missing manual recovery guidance (git stash pop/list)"; fail=1; }
grep -qi 'CONFLICT' <<<"$b_out" \
    || { echo "FAIL [B]: git conflict output suppressed (2>/dev/null present?)"; fail=1; }
[[ "$b_stash" != "1" ]] && { echo "FAIL [B]: stash entry dropped on conflict (should be preserved)"; fail=1; }

# --- A/B 对照：BEFORE（2>/dev/null 静默吞掉）行为差异证据 --------------------
echo ""
echo "=== Path B-legacy: pre-fix silent-continue behavior (A/B divergence) ==="
legacy_block='
if ! git stash pop 2>/dev/null; then
    echo "[upgrade] WARN: Stashed changes could not be automatically restored."
fi
'
REPO_BL="$SANDBOX/repo_b_legacy"
setup_conflict_repo "$REPO_BL"
bl_out="$( cd "$REPO_BL" && had_changes=true && bash -c "$legacy_block" 2>&1 )"
bl_exit=$?
bl_stash=$(git -C "$REPO_BL" stash list | wc -l)
echo "legacy exit=$bl_exit stash_preserved=$bl_stash"
if [[ "$b_exit" == "$bl_exit" ]]; then
    echo "FAIL [B-legacy]: A/B did not diverge (fix=$b_exit legacy=$bl_exit); fail-fast not demonstrated"
    fail=1
fi
[[ "$bl_exit" != "0" || "$bl_stash" != "1" ]] \
    && { echo "FAIL [B-legacy]: pre-fix baseline changed (expected exit 0 + stash kept, got $bl_exit/$bl_stash)"; fail=1; }

# ===========================================================================
# Path A3: 无冲突 stash 恢复 → 生产块干净通过
# ===========================================================================
echo ""
echo "=== Path A3: clean stash restore (production block) ==="
REPO_A3="$SANDBOX/repo_a3"
mkdir -p "$REPO_A3"
git -C "$REPO_A3" init -q
git -C "$REPO_A3" config user.email "qa@kingoflikes.test"
git -C "$REPO_A3" config user.name "SEE1470 sandbox"
printf 'base\n' > "$REPO_A3/app.conf"
git -C "$REPO_A3" add -A && git -C "$REPO_A3" commit -qm base
printf 'local\n' > "$REPO_A3/app.conf"
git -C "$REPO_A3" stash push -qm auto-stash >/dev/null
printf 'other\n' > "$REPO_A3/other.conf"
git -C "$REPO_A3" add -A && git -C "$REPO_A3" commit -qm upstream-other
a3_out="$( cd "$REPO_A3" && had_changes=true && . "$HELPERS" && . "$STASH_BLOCK" && echo "STASH_RESTORE_OK" 2>&1 )"
a3_exit=$?
echo "exit=$a3_exit out=[$a3_out]"
grep -q 'STASH_RESTORE_OK' <<<"$a3_out" && grep -q 'Restoring stashed changes' <<<"$a3_out" \
    && [[ "$a3_exit" == "0" ]] \
    || { echo "FAIL [A3]: clean stash restore did not complete (exit $a3_exit, out=[$a3_out])"; fail=1; }

# ===========================================================================
# Path A / A2: 生产 image-pull 循环（docker stub 记录每次 pull 的参数）
# ===========================================================================
echo ""
echo "=== Path A: image-pull loop with docker stub ==="
STUB_DIR="$SANDBOX/stubs"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--config" ]]; then shift 2; fi
if [[ "$1" == "pull" ]]; then
    shift
    echo "PULL:$*" >> "$DOCKER_PULL_LOG"
    exit 0
fi
exit 0
EOF
chmod +x "$STUB_DIR/docker"

DOCKER_PULL_LOG="$SANDBOX/pull.log"
export DOCKER_PULL_LOG
# 环境前缀赋值（VAR=... . file）对 source 的数组赋值解析不可靠——改为
# 子 shell 内显式赋值后再 source，语义与生产循环上下文一致。
a_out="$( cd "$SANDBOX" && . "$HELPERS" \
    && _PULL_IMAGES=("backend:v2" "registry.example.com/redis:7.0-alpine") \
    && _PULL_DIR="" && export PATH="$STUB_DIR:$PATH" && . "$PULL_LOOP" 2>&1 )"
a_exit=$?
echo "exit=$a_exit log=[$(tr '\n' ';' < "$DOCKER_PULL_LOG")]"
grep -q '^PULL:backend:v2$' "$DOCKER_PULL_LOG" \
    || { echo "FAIL [A]: docker pull not invoked for backend:v2 as a single arg"; fail=1; }
grep -q '^PULL:registry.example.com/redis:7.0-alpine$' "$DOCKER_PULL_LOG" \
    || { echo "FAIL [A]: registry image not passed as a single arg (quotation regression)"; fail=1; }
grep -q 'Images updated.' <<<"$a_out" \
    || { echo "FAIL [A]: loop did not reach 'Images updated.'"; fail=1; }
[[ "$a_exit" != "0" ]] && { echo "FAIL [A]: pull loop aborted (exit $a_exit)"; fail=1; }

echo ""
echo "=== Path A2: empty image list must not abort (bash 3.2-safe idiom) ==="
DOCKER_PULL_LOG="$SANDBOX/pull2.log"
: > "$DOCKER_PULL_LOG"
a2_out="$( cd "$SANDBOX" && . "$HELPERS" \
    && _PULL_IMAGES=() && _PULL_DIR="" && export PATH="$STUB_DIR:$PATH" && . "$PULL_LOOP" 2>&1 )"
a2_exit=$?
echo "exit=$a2_exit pulls=$(wc -l < "$DOCKER_PULL_LOG")"
[[ "$a2_exit" != "0" ]] \
    && { echo "FAIL [A2]: empty image list aborted the loop (exit $a2_exit) — safe expansion not effective"; fail=1; }
[[ -s "$DOCKER_PULL_LOG" ]] && { echo "FAIL [A2]: empty list should issue zero pulls"; fail=1; }

echo ""
if [[ "$fail" -eq 0 ]]; then
    echo "PASS: SEE-899 upgrade flow green — fail-fast conflict path, clean restore, and pull loop all driven from $TARGET."
    exit 0
else
    exit 1
fi
