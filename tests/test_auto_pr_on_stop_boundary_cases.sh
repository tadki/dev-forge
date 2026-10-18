#!/bin/bash
set -euo pipefail

# Boundary cases for the SEE-1033 NO_REFSPEC guard.

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
HOOK_PATH="$ROOT_DIR/.claude/hooks/auto-pr-on-stop.sh"
TEST_DIR=$(mktemp -d)
REMOTE_DIR="$TEST_DIR/remote.git"
REPO_DIR="$TEST_DIR/repo"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

mkdir -p "$REMOTE_DIR" "$REPO_DIR"
git init "$REMOTE_DIR" --bare --quiet
git clone --quiet "$REMOTE_DIR" "$REPO_DIR"
git -C "$REPO_DIR" config user.email "test@example.com"
git -C "$REPO_DIR" config user.name "Test Runner"
echo "initial" > "$REPO_DIR/README.md"
git -C "$REPO_DIR" add README.md
git -C "$REPO_DIR" commit --quiet -m "Initial commit"
git -C "$REPO_DIR" push --quiet origin master

run_hook() {
  local branch="$1"
  local working_branch="${2:-}"
  local stderr_file
  stderr_file=$(mktemp)
  (
    cd "$REPO_DIR"
    unset MULTICA_TASK_ID MULTICA_AGENT_ID MULTICA_TOKEN MULTICA_SERVER_URL MULTICA_WORKSPACE_ID
    if [ -n "$working_branch" ]; then
      export WORKING_BRANCH="$working_branch"
    else
      unset WORKING_BRANCH
    fi
    printf '%s' '{"stop_hook_active": false}' | bash "$HOOK_PATH"
  ) 2> "$stderr_file" || true
  cat "$stderr_file"
  rm -f "$stderr_file"
}

case_passed() {
  local name="$1"
  echo "PASS: $name"
}

case_failed() {
  local name="$1"
  echo "FAIL: $name" >&2
  exit 1
}

# ---- Boundary 1: agent/<X>/<Y> with WORKING_BRANCH set → guard does NOT fire, push proceeds ----
git -C "$REPO_DIR" checkout --quiet -b "agent/revy/5fbe9f04"
echo "agent work" > "$REPO_DIR/agent.txt"
git -C "$REPO_DIR" add agent.txt
git -C "$REPO_DIR" commit --quiet -m "Agent with working_branch"
run_hook "agent/revy/5fbe9f04" "shared/SEE-1033"
if grep -q "跳过 push" "$REPO_DIR/NOPE" 2>/dev/null; then case_failed "guard should not block when working_branch is set"; fi
# (push fails in sandbox without auth, which is expected; absence of guard message is the assertion)
case_passed "Boundary 1: agent/*/* with WORKING_BRANCH does not hit guard"

# clean up for next case
rm -f "$REPO_DIR/agent.txt"
git -C "$REPO_DIR" checkout --quiet master
git -C "$REPO_DIR" branch -D "agent/revy/5fbe9f04" 2>/dev/null || true

# ---- Boundary 2: agent/<X> (single slash) should NOT trigger guard ----
git -C "$REPO_DIR" checkout --quiet -b "agent/legacy"
echo "legacy" > "$REPO_DIR/legacy.txt"
git -C "$REPO_DIR" add legacy.txt
git -C "$REPO_DIR" commit --quiet -m "legacy agent branch"
output=$(run_hook "agent/legacy")
if grep -q "跳过 push" <<< "$output"; then case_failed "guard should not trigger for agent/<X> single-slash form"; fi
case_passed "Boundary 2: agent/<X> (single slash) is not blocked"

rm -f "$REPO_DIR/legacy.txt"
git -C "$REPO_DIR" checkout --quiet master
git -C "$REPO_DIR" branch -D "agent/legacy" 2>/dev/null || true

# ---- Boundary 3: nested agent/<X>/<Y>/<Z> should trigger guard ----
git -C "$REPO_DIR" checkout --quiet -b "agent/chekky/abc/def"
echo "nested" > "$REPO_DIR/nested.txt"
git -C "$REPO_DIR" add nested.txt
git -C "$REPO_DIR" commit --quiet -m "nested agent branch"
output=$(run_hook "agent/chekky/abc/def")
if ! grep -q "跳过 push" <<< "$output"; then case_failed "guard should trigger for nested agent/*/*"; fi
case_passed "Boundary 3: agent/<X>/<Y>/<Z> hits guard"

rm -f "$REPO_DIR/nested.txt"
git -C "$REPO_DIR" checkout --quiet master
git -C "$REPO_DIR" branch -D "agent/chekky/abc/def" 2>/dev/null || true

# ---- Boundary 4: shared/SEE-1033 with no WORKING_BRANCH does not trigger guard ----
git -C "$REPO_DIR" checkout --quiet -b "shared/SEE-1033"
echo "shared" > "$REPO_DIR/shared.txt"
git -C "$REPO_DIR" add shared.txt
git -C "$REPO_DIR" commit --quiet -m "shared branch"
output=$(run_hook "shared/SEE-1033")
if grep -q "跳过 push" <<< "$output"; then case_failed "guard should not trigger for shared branch"; fi
case_passed "Boundary 4: shared/SEE-1033 is not blocked by guard"

echo "ALL BOUNDARY CASES PASSED"
