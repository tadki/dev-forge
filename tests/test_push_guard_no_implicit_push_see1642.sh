#!/bin/bash
# test_push_guard_no_implicit_push_see1642.sh
# SEE-1642 §SPEC-001 behavioral regression: a non-push Bash payload must leave
# every ref of the remote untouched, even when the session cwd's branch is
# ahead of its same-named upstream by a fast-forwardable commit.
#
# Historical defect (fingerprint 195308ebc961): a legacy backtick pair inside
# the Phase-1 `node -e "..."` double-quoted string was command-substituted by
# bash, executing `git push` in the hook's cwd before every Bash tool call.
#
# Fixture: /tmp-isolated local bare remote + a clone that is ahead of its
# same-named upstream. All paths are local; no real remote is contacted.
# Assertions are behavioral only (exit code / stdout passthrough / ref snapshot).
#
# Related Issue: SEE-1642
# Test Type: Behavioral regression (fixture + A/B ref snapshot)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUSH_GUARD="$REPO_ROOT/claude-hooks/scripts/push-guard.sh"

PASS=0
FAIL=0
pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

FIXTURE="$(mktemp -d /tmp/push-guard-see1642.XXXXXX)"
cleanup() { rm -rf "$FIXTURE"; }
trap cleanup EXIT

BRANCH="feature/see1642-fixture"
PAYLOAD='{"session_id":"see1642-test","tool_name":"Bash","tool_input":{"command":"ls -la /tmp"}}'
REMOTE="$FIXTURE/origin.git"
WORK="$FIXTURE/work"

echo "============================================"
echo "  SEE-1642: non-push payload must not mutate remote refs"
echo "  Date: $(date -Iseconds)"
echo "  Hook: $PUSH_GUARD"
echo "  Fixture: $FIXTURE"
echo "============================================"

if [ ! -f "$PUSH_GUARD" ]; then
  fail "push-guard.sh not found at $PUSH_GUARD"
  echo "FAIL=0 no — blocker, aborting"
  exit 1
fi

# --- Fixture: bare remote + clone ahead of same-named upstream by 1 commit ---
git init --bare -q -b main "$REMOTE" || { fail "bare remote init"; exit 1; }
git clone -q "$REMOTE" "$WORK" 2>/dev/null || { fail "clone"; exit 1; }
git -C "$WORK" config user.email see1642-test@local
git -C "$WORK" config user.name see1642-test
git -C "$WORK" checkout -q -b "$BRANCH"
echo seed > "$WORK/seed.txt"
git -C "$WORK" add seed.txt
git -C "$WORK" commit -qm "seed"
git -C "$WORK" push -q -u origin "$BRANCH" || { fail "fixture upstream push"; exit 1; }
# One fast-forwardable commit ahead of origin/<same-name>
echo ahead > "$WORK/ahead.txt"
git -C "$WORK" add ahead.txt
git -C "$WORK" commit -qm "ahead-by-1"

REMOTE_HEAD_BEFORE="$(git -C "$REMOTE" rev-parse "refs/heads/$BRANCH")"
LOCAL_HEAD="$(git -C "$WORK" rev-parse HEAD)"
if [ "$REMOTE_HEAD_BEFORE" != "$LOCAL_HEAD" ]; then
  pass "fixture: local ahead of same-named upstream by >=1 commit"
else
  fail "fixture precondition: local is not ahead of upstream"
  exit 1
fi

snapshot_refs() { git -C "$REMOTE" for-each-ref --format='%(refname) %(objectname)' | LC_ALL=C sort; }
BEFORE="$(snapshot_refs)"

# --- Act: run push-guard from the fixture cwd with a non-push payload ---
# Session-level env vars are stripped so the judgment depends only on the fixture.
OUT="$(cd "$WORK" && env -u PROJECT_ROOT -u TARGET_REPO_ROOT -u GQT_REPO_ROOT -u MULTICA_TASK_ID \
  bash "$PUSH_GUARD" <<< "$PAYLOAD" 2>"$FIXTURE/stderr.log")"
RC=$?
AFTER="$(snapshot_refs)"

# --- Assert ---
if [ "$RC" -eq 0 ]; then
  pass "non-push payload exits 0 (got $RC)"
else
  fail "non-push payload exit code: got $RC, want 0 (stderr: $(head -c 200 "$FIXTURE/stderr.log"))"
fi

if [ "$OUT" = "$PAYLOAD" ]; then
  pass "payload passed through unchanged"
else
  fail "payload passthrough mismatch: got '$OUT'"
fi

if [ "$AFTER" = "$BEFORE" ]; then
  pass "bare remote refs unchanged (no implicit push)"
else
  fail "bare remote refs mutated: before=[$BEFORE] after=[$AFTER]"
fi

# --- Hardened (SEE-1642 hardener): parser fail-open safety net ---
# When the Phase-1 parser produces an unexpected/empty result (the only path
# where the safety net is reachable — node itself must exit 0), the safety net
# must default the non-push payload to NOT_PUSH: pass through, exit 0, refs
# intact. Falling through to any Phase-3 verdict instead would mis-block
# non-push payloads (exit 2).
mkdir -p "$FIXTURE/fakebin"
printf '#!/bin/sh\nexit 0\n' > "$FIXTURE/fakebin/node"
chmod +x "$FIXTURE/fakebin/node"
OUT2="$(cd "$WORK" && env -u PROJECT_ROOT -u TARGET_REPO_ROOT -u GQT_REPO_ROOT -u MULTICA_TASK_ID \
  PATH="$FIXTURE/fakebin:$PATH" bash "$PUSH_GUARD" <<< "$PAYLOAD" 2>"$FIXTURE/stderr2.log")"
RC2=$?
AFTER2="$(snapshot_refs)"

if [ "$RC2" -eq 0 ]; then
  pass "parser-degenerate payload exits 0 (fail-open, got $RC2)"
else
  fail "parser-degenerate exit code: got $RC2, want 0 (stderr: $(head -c 200 "$FIXTURE/stderr2.log"))"
fi

if [ "$OUT2" = "$PAYLOAD" ]; then
  pass "parser-degenerate payload passed through unchanged"
else
  fail "parser-degenerate passthrough mismatch: got '$OUT2'"
fi

if [ "$AFTER2" = "$AFTER" ]; then
  pass "bare remote refs unchanged with parser-degenerate output (no implicit push)"
else
  fail "bare remote refs mutated with parser-degenerate output: before=[$AFTER] after=[$AFTER2]"
fi

# --- Summary ---
echo "Results: $PASS passed, $FAIL failed"
echo "FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "Overall: PASS"
  exit 0
else
  echo "Overall: FAIL ($FAIL failures)"
  exit 1
fi
