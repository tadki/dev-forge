#!/bin/bash
# SEE-1470 Track A: workspace-env-check adapter 行为矩阵（自 KOL devtests 迁入）。
# 源件 tests/devtests/scripts/test_workspace_env_check.sh（SEE-1465 §SPEC-017
# 重裁版）1:1 保持 adapter 合同断言；SEE-1430 迁移后生产脚本已在本仓，寻址
# 改为本仓相对路径，不再经 DEVFORGE_ROOT 跨仓推断（~/tools 硬编码随之移除）。
# 覆盖：summary 格式、--repo-dir、裸 workdir 自动 cd、--hard-reset 守卫与
# --fix 流、--issue-id 工作分支解析成功/失败双腿（PATH shim 模拟 multica CLI）。
# hermetic：全部场景运行于一次性 sandbox 仓，默认 CI 收集面可安全执行。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../adapters/workspace-env-check.sh"
TARGET_BRANCH="qa/workspace-env-check-sandbox"

if [[ ! -f "$SCRIPT" ]]; then
  echo "ERROR: workspace-env-check.sh not found at $SCRIPT" >&2
  exit 1
fi

run_check() {
  "$SCRIPT" "$@"
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# Origin bare repo with master (default) + TARGET_BRANCH, then a clean clone
# aligned on TARGET_BRANCH — the full-PASS precondition for Tests 1/2.
git init -q --bare -b master "$SANDBOX/origin.git"
git clone -q "$SANDBOX/origin.git" "$SANDBOX/seed"
git -C "$SANDBOX/seed" config user.email "qa@kingoflikes.test"
git -C "$SANDBOX/seed" config user.name "SEE1470 sandbox"
echo base > "$SANDBOX/seed/base.txt"
git -C "$SANDBOX/seed" add -A
git -C "$SANDBOX/seed" commit -qm "base"
git -C "$SANDBOX/seed" push -q origin HEAD:refs/heads/master
git -C "$SANDBOX/seed" checkout -qb "$TARGET_BRANCH"
echo target > "$SANDBOX/seed/target.txt"
git -C "$SANDBOX/seed" add -A
git -C "$SANDBOX/seed" commit -qm "target"
git -C "$SANDBOX/seed" push -q origin "$TARGET_BRANCH"
git clone -q "$SANDBOX/origin.git" "$SANDBOX/work"
git -C "$SANDBOX/work" config user.email "qa@kingoflikes.test"
git -C "$SANDBOX/work" config user.name "SEE1470 sandbox"
git -C "$SANDBOX/work" checkout -q "$TARGET_BRANCH"

echo "=== Test 1: NESTED summary has no duplicate 0 (regression) ==="
cd "$SANDBOX/work"
output=$(run_check "$TARGET_BRANCH")
echo "$output" | grep -q "RESULT:   PASS"
if echo "$output" | grep -A1 '^NESTED:' | tail -1 | grep -qE '^[0-9]+$'; then
  echo "FAIL: NESTED duplicate 0 regression" >&2
  exit 1
fi
echo "PASS"

echo "=== Test 2: --repo-dir works from arbitrary CWD ==="
cd "$SANDBOX"
output=$(run_check --repo-dir "$SANDBOX/work" "$TARGET_BRANCH")
echo "$output" | grep -q "RESULT:   PASS"
echo "PASS"

echo "=== Test 3: auto-cd from bare workdir root ==="
mkdir -p "$SANDBOX/bare_parent"
git clone -q "$SANDBOX/origin.git" "$SANDBOX/bare_parent/work3"
git -C "$SANDBOX/bare_parent/work3" checkout -q "$TARGET_BRANCH"
cd "$SANDBOX/bare_parent"
output=$("$SCRIPT" "$TARGET_BRANCH")
echo "$output" | grep -q "Bare workdir detected"
echo "$output" | grep -q "RESULT:   PASS"
echo "PASS"

echo "=== Test 4: --hard-reset without --fix must error ==="
cd "$SANDBOX/work"
if output=$(run_check --hard-reset "$TARGET_BRANCH" 2>&1); then
  echo "FAIL: --hard-reset without --fix should have failed" >&2
  exit 1
fi
echo "$output" | grep -q "requires --fix"
echo "PASS"

echo "=== Test 5: --fix --hard-reset resets and rebases on target branch ==="
cd "$SANDBOX/work"
echo local > "$SANDBOX/work/local.txt"
git -C "$SANDBOX/work" add -A
git -C "$SANDBOX/work" commit -qm "local-only commit (to be discarded)"
output=$(run_check --fix --hard-reset "$TARGET_BRANCH" 2>&1)
echo "$output" | grep -q "WARN: --hard-reset:"
echo "$output" | grep -q "OK: Reset to"
echo "$output" | grep -q "OK: Rebased onto"
echo "$output" | grep -q "RESULT:   PASS"
echo "PASS"

# --- Tests 6/7: --issue-id -> working-branch resolution path ---
# The adapter has two distinct target sources: positional TARGET_BRANCH
# (Tests 1-5) and resolve_target_from_issue via `multica issue metadata list`.
# A PATH shim mocks the metadata API; breaking resolve_target_from_issue must
# turn Test 6 red (mutation evidence in the sub-step report).
SHIM_BIN="$SANDBOX/shim_bin"
mkdir -p "$SHIM_BIN"

echo "=== Test 6: --issue-id resolves working branch (success leg) ==="
cat > "$SHIM_BIN/multica" <<SHIMEOF
#!/bin/bash
if [ "\$1" = issue ] && [ "\$2" = metadata ] && [ "\$3" = list ]; then
  echo '{"working_branch":"$TARGET_BRANCH","pr_number":7}'
  exit 0
fi
exit 0
SHIMEOF
chmod +x "$SHIM_BIN/multica"
cd "$SANDBOX/work"
output=$(PATH="$SHIM_BIN:$PATH" run_check --issue-id "00000000-0000-4000-8000-000000000000" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: --issue-id success leg rc=$rc (resolve_target_from_issue broken?)" >&2
  echo "$output" >&2
  exit 1
fi
echo "$output" | grep -q "RESULT:   PASS"
echo "$output" | grep -q "$TARGET_BRANCH"
echo "PASS"

echo "=== Test 7: --issue-id with no working_branch in metadata must error ==="
cat > "$SHIM_BIN/multica" <<SHIMEOF
#!/bin/bash
if [ "\$1" = issue ] && [ "\$2" = metadata ] && [ "\$3" = list ]; then
  echo '{}'
  exit 0
fi
exit 0
SHIMEOF
chmod +x "$SHIM_BIN/multica"
if output=$(PATH="$SHIM_BIN:$PATH" run_check --issue-id "00000000-0000-4000-8000-000000000000" 2>&1); then
  echo "FAIL: --issue-id failure leg should not resolve (metadata lacks working_branch)" >&2
  echo "$output" >&2
  exit 1
fi
echo "$output" | grep -q "Cannot determine target branch"
echo "PASS"

echo ""
echo "All workspace-env-check adapter tests passed."
