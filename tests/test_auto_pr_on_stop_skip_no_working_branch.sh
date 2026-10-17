#!/bin/bash
set -euo pipefail

# Test: auto-pr-on-stop.sh must skip pushing an agent/<X>/<Y> branch to origin
# when no working_branch metadata is provided. SEE-1033.
#
# Case 1: agent/<X>/<Y> branch + empty WORKING_BRANCH -> push skipped, warning emitted,
#         no agent/* branch created on origin.
# Case 2: feature/<X> branch + empty WORKING_BRANCH -> guard NOT triggered (regression
#         guard so the fix does not over-block legitimate local-dev pushes).

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
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

run_hook_isolated() {
  # Run the hook against the temp repo, isolated from the real Multica session
  # so it does not read the parent issue's working_branch metadata.
  local stderr_file="$1"
  (
    cd "$REPO_DIR"
    unset MULTICA_TASK_ID MULTICA_AGENT_ID MULTICA_TOKEN MULTICA_SERVER_URL MULTICA_WORKSPACE_ID
    printf '%s' '{"stop_hook_active": false}' | bash "$HOOK_PATH"
  ) 2> "$stderr_file"
  return 0
}

# ====================== Case 1: agent/<X>/<Y>, no working_branch ======================
git -C "$REPO_DIR" checkout --quiet -b "agent/archi/deadbeef"
echo "agent work" > "$REPO_DIR/agent.txt"
git -C "$REPO_DIR" add agent.txt
git -C "$REPO_DIR" commit --quiet -m "Agent commit"

STDERR_FILE="$TEST_DIR/stderr.txt"
run_hook_isolated "$STDERR_FILE"

echo "--- Case 1 hook stderr ---"
cat "$STDERR_FILE"
echo "--------------------------"

# Case 1a: documented warning must be emitted.
if ! grep -q "跳过 push" "$STDERR_FILE"; then
  echo "FAIL: expected warning message about skipping push" >&2
  exit 1
fi
if ! grep -q "agent/<X>/<Y>" "$STDERR_FILE"; then
  echo "FAIL: expected warning to mention agent/<X>/<Y>" >&2
  exit 1
fi

# Case 1b: no agent/* branch must exist on the remote.
REMOTE_AGENT_REFS=$(git -C "$REPO_DIR" ls-remote origin 'refs/heads/agent/*' || true)
if [ -n "$REMOTE_AGENT_REFS" ]; then
  echo "FAIL: agent branch was pushed to origin despite guard" >&2
  echo "$REMOTE_AGENT_REFS" >&2
  exit 1
fi

echo "PASS: Case 1 - agent/<X>/<Y> with no working_branch was NOT pushed"

# ===================== Case 2: feature/<X>, no working_branch =====================
# A non-agent branch with no working_branch (local dev) must still go through the
# normal push path; the NO_REFSPEC guard must not fire here.
git -C "$REPO_DIR" checkout --quiet master
git -C "$REPO_DIR" checkout --quiet -b "feature/SEE-9999-regression"
echo "feature work" > "$REPO_DIR/feature.txt"
git -C "$REPO_DIR" add feature.txt
git -C "$REPO_DIR" commit --quiet -m "Feature commit"

STDERR_FILE2="$TEST_DIR/stderr2.txt"
run_hook_isolated "$STDERR_FILE2"

echo "--- Case 2 hook stderr ---"
cat "$STDERR_FILE2"
echo "---------------------------"

# The push itself fails in this sandbox (no GitHub auth), which is expected and not
# asserted. What matters: the NO_REFSPEC guard was NOT triggered for a non-agent branch.
if grep -q "跳过 push" "$STDERR_FILE2"; then
  echo "FAIL: non-agent branch was incorrectly blocked by NO_REFSPEC guard" >&2
  exit 1
fi

echo "PASS: Case 2 - feature/<X> branch was not blocked (guard scoped to agent/*/*)"

echo
echo "ALL TESTS PASSED"
