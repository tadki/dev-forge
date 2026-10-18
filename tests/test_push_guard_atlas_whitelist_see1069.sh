#!/bin/bash
# test_push_guard_atlas_whitelist_see1069.sh
# Regression test for SEE-1069: push-guard.sh Atlas force-push whitelist + audit log.
#
# Background: when reconciling squash-merge divergence on a shared branch, Atlas
# (Leader agent) needs to force-push but was hard-blocked by the FORCE_PUSH guard
# (exit 2). SEE-1069 adds an agent_id whitelist: when MULTICA_AGENT_ID matches
# Atlas's UUID, the force-push is allowed and an audit line is appended to
# .claude/push-guard-force-audit.log.
#
# Coverage:
#   S1: Atlas + force form → exit 0 + audit log line written
#   S2: other / empty agent_id + force form → exit 2 (existing block preserved)
#   S3: Atlas + non-force / non-push → original flow, NO audit line
#   S4: audit log line format (iso ts + agent + name + cmd)
#
# Related Issue: SEE-1069
# Author: Bachi

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); }

WORKTREE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SCRIPT="$WORKTREE_DIR/claude-hooks/scripts/push-guard.sh"
ATLAS_ID="fac3e3a1-dcda-498d-8613-e8c2811f3ef5"

echo "============================================"
echo "  SEE-1069: push-guard.sh Atlas force-push whitelist + audit"
echo "  Hook: $HOOK_SCRIPT"
echo "============================================"

# -------------------------------------------------------
# Pre-check: file existence + whitelist source presence
# -------------------------------------------------------
echo -e "${CYAN}--- Pre-check ---${NC}"

if [ ! -f "$HOOK_SCRIPT" ]; then
  fail "push-guard.sh not found at $HOOK_SCRIPT"
  exit 1
fi
pass "push-guard.sh exists"

if grep -q 'ATLAS_AGENT_ID="fac3e3a1-dcda-498d-8613-e8c2811f3ef5"' "$HOOK_SCRIPT"; then
  pass "source: Atlas agent_id whitelist present"
else
  fail "source: Atlas agent_id whitelist missing"
fi
if grep -q 'push-guard-force-audit.log' "$HOOK_SCRIPT"; then
  pass "source: audit log path present"
else
  fail "source: audit log path missing"
fi

# -------------------------------------------------------
# Helper: run the hook with a controlled PROJECT_ROOT (so the
# audit log lands in a temp dir we own) and capture exit/stderr.
# Sets MULTICA_TASK_ID="" to skip working-branch resolution.
# -------------------------------------------------------
run_hook() {
  local agent_id="$1"
  local agent_name="$2"
  local cmd="$3"
  local audit_dir="$4"

  local input
  input=$(printf '{"tool_input":{"command":"%s"}}' "$cmd")

  local stdout_file stderr_file
  stdout_file=$(mktemp /tmp/pgw-out.XXXXXX)
  stderr_file=$(mktemp /tmp/pgw-err.XXXXXX)

  (
    export MULTICA_AGENT_ID="$agent_id"
    export MULTICA_AGENT_NAME="$agent_name"
    export MULTICA_TASK_ID=""
    export PROJECT_ROOT="$audit_dir"
    echo "$input" | bash "$HOOK_SCRIPT" > "$stdout_file" 2> "$stderr_file"
  )
  local actual_exit=$?

  local stderr_content
  stderr_content=$(cat "$stderr_file")
  rm -f "$stdout_file" "$stderr_file"

  echo "$actual_exit"
  echo "---STDERR---"
  echo "$stderr_content"
}

# ========================================================
# Section 1: Atlas + force form → exit 0 + audit log
# ========================================================
echo ""
echo -e "${CYAN}=== Section 1: Atlas + force form → allowed + audited ===${NC}"

AUDIT_DIR_S1=$(mktemp -d /tmp/pgw-audit-s1.XXXXXX)

# Atlas --force-with-lease → exit 0, audit log written with the cmd
OUT=$(run_hook "$ATLAS_ID" "Atlas" \
  "git push --force-with-lease origin HEAD:refs/heads/shared/SEE-1067" \
  "$AUDIT_DIR_S1")
EXIT=$(echo "$OUT" | head -1)
LOG_FILE="$AUDIT_DIR_S1/.claude/push-guard-force-audit.log"
if [ "$EXIT" -eq 0 ] && [ -f "$LOG_FILE" ]; then
  pass "S1-1: Atlas --force-with-lease → exit 0 + audit file created"
else
  fail "S1-1: expected exit 0 + audit file, got exit=$EXIT file=$LOG_FILE"
fi
if [ -f "$LOG_FILE" ] && grep -q "cmd=git push --force-with-lease" "$LOG_FILE"; then
  pass "S1-1b: audit line records the forced command"
else
  fail "S1-1b: audit line missing forced cmd (log=$(cat "$LOG_FILE" 2>/dev/null))"
fi

# Atlas --force and -f also allowed + audited
OUT=$(run_hook "$ATLAS_ID" "Atlas" \
  "git push --force origin HEAD:refs/heads/shared/SEE-1067" "$AUDIT_DIR_S1")
EXIT=$(echo "$OUT" | head -1)
[ "$EXIT" -eq 0 ] && pass "S1-2: Atlas --force → exit 0" || fail "S1-2: got exit=$EXIT"

OUT=$(run_hook "$ATLAS_ID" "Atlas" \
  "git push -f origin HEAD:refs/heads/shared/SEE-1067" "$AUDIT_DIR_S1")
EXIT=$(echo "$OUT" | head -1)
[ "$EXIT" -eq 0 ] && pass "S1-3: Atlas -f → exit 0" || fail "S1-3: got exit=$EXIT"

# Audit file should have accumulated 3 lines (one per allowed force-push)
LINE_COUNT=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
if [ "$LINE_COUNT" -eq 3 ]; then
  pass "S1-4: audit log appended 3 lines (one per force-push)"
else
  fail "S1-4: expected 3 audit lines, got $LINE_COUNT"
fi

rm -rf "$AUDIT_DIR_S1"

# ========================================================
# Section 2: other / empty agent_id + force → exit 2
# ========================================================
echo ""
echo -e "${CYAN}=== Section 2: non-Atlas + force form → blocked (exit 2) ===${NC}"

assert_force_blocked() {
  local agent_id="$1" agent_name="$2" cmd="$3" label="$4"
  local audit_dir
  audit_dir=$(mktemp -d /tmp/pgw-blk.XXXXXX)
  local out exit_code stderr_content
  out=$(run_hook "$agent_id" "$agent_name" "$cmd" "$audit_dir")
  exit_code=$(echo "$out" | head -1)
  stderr_content=$(echo "$out" | sed -n '/---STDERR---/,$p' | tail -n +2)
  local log_file="$audit_dir/.claude/push-guard-force-audit.log"

  if [ "$exit_code" -eq 2 ] && echo "$stderr_content" | grep -q "禁止 force-push"; then
    pass "$label (exit 2)"
  else
    fail "$label — got exit=$exit_code (stderr: $stderr_content)"
  fi
  # Audit log must NOT have been written for a blocked force-push
  if [ -f "$log_file" ]; then
    fail "$label — audit log unexpectedly written (security: blocked push must not audit as allowed)"
  else
    pass "$label — no audit file (blocked push not recorded as allowed)"
  fi
  rm -rf "$audit_dir"
}

assert_force_blocked "a5c250e8-7257-466e-b45a-03f995c7206c" "Bachi" \
  "git push --force-with-lease origin HEAD:refs/heads/shared/SEE-1067" \
  "S2-1: Bachi --force-with-lease → exit 2"
assert_force_blocked "2660961d-6add-4d15-8d1b-dea446142a94" "Revy" \
  "git push --force origin HEAD:refs/heads/shared/SEE-1067" \
  "S2-2: Revy --force → exit 2"
assert_force_blocked "23354e78-8322-418b-b44d-375287a0650c" "Fronti" \
  "git push -f origin HEAD:refs/heads/shared/SEE-1067" \
  "S2-3: Fronti -f → exit 2"
# Atlas NAME but wrong/non-matching agent_id → still blocked (whitelist is by ID)
assert_force_blocked "00000000-0000-0000-0000-000000000000" "Atlas" \
  "git push --force-with-lease origin HEAD:refs/heads/shared/SEE-1067" \
  "S2-4: name=Atlas but foreign agent_id → exit 2 (whitelist is by ID, not name)"
# Empty agent_id → blocked
assert_force_blocked "" "" \
  "git push --force-with-lease origin HEAD:refs/heads/shared/SEE-1067" \
  "S2-5: empty agent_id → exit 2"

# ========================================================
# Section 3: Atlas + non-force / non-push → original flow, NO audit
# ========================================================
echo ""
echo -e "${CYAN}=== Section 3: Atlas non-force → unaffected by whitelist ===${NC}"

run_atlas_non_force() {
  local cmd="$1" label="$2"
  local audit_dir
  audit_dir=$(mktemp -d /tmp/pgw-nf.XXXXXX)
  local out exit_code log_file
  out=$(run_hook "$ATLAS_ID" "Atlas" "$cmd" "$audit_dir")
  exit_code=$(echo "$out" | head -1)
  log_file="$audit_dir/.claude/push-guard-force-audit.log"

  # Must NOT be force-blocked (no "禁止 force-push" error)
  local force_blocked=0
  if [ "$exit_code" -eq 2 ] && echo "$out" | grep -q "禁止 force-push"; then
    force_blocked=1
  fi
  if [ "$force_blocked" -eq 0 ]; then
    pass "$label — not force-blocked (exit=$exit_code)"
  else
    fail "$label — unexpectedly force-blocked"
  fi
  # No audit line for a non-force command
  if [ -f "$log_file" ]; then
    fail "$label — audit log unexpectedly written (whitelist must only audit force-pushes)"
  else
    pass "$label — no audit file (whitelist did not trigger)"
  fi
  rm -rf "$audit_dir"
}

run_atlas_non_force "git status" \
  "S3-1: Atlas git status (NOT_PUSH passthrough)"
run_atlas_non_force "ls -la" \
  "S3-2: Atlas ls -la (not a push)"
run_atlas_non_force "git push origin HEAD:refs/heads/shared/SEE-1067" \
  "S3-3: Atlas plain safe push (no force flag)"
run_atlas_non_force "git push origin --delete old-branch" \
  "S3-4: Atlas delete push (DELETE_PUSH bypass)"

# ========================================================
# Section 4: audit log line format
# ========================================================
echo ""
echo -e "${CYAN}=== Section 4: audit log format ===${NC}"

AUDIT_DIR_S4=$(mktemp -d /tmp/pgw-fmt.XXXXXX)
run_hook "$ATLAS_ID" "Atlas" \
  "git push --force-with-lease origin HEAD:refs/heads/shared/SEE-1067" \
  "$AUDIT_DIR_S4" >/dev/null
LOG_FILE_S4="$AUDIT_DIR_S4/.claude/push-guard-force-audit.log"

# ISO-8601 timestamp prefix (date -Iseconds → YYYY-MM-DDTHH:MM:SS+ZZ:ZZ)
if grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' "$LOG_FILE_S4"; then
  pass "S4-1: line starts with ISO-8601 timestamp"
else
  fail "S4-1: bad timestamp prefix (log=$(cat "$LOG_FILE_S4" 2>/dev/null))"
fi
grep -q "agent=$ATLAS_ID" "$LOG_FILE_S4" \
  && pass "S4-2: line contains agent=<atlas-id>" \
  || fail "S4-2: agent field missing/wrong"
grep -q "name=Atlas" "$LOG_FILE_S4" \
  && pass "S4-3: line contains name=Atlas" \
  || fail "S4-3: name field missing/wrong"
grep -Eq 'cmd=git push --force-with-lease origin HEAD:refs/heads/shared/SEE-1067' "$LOG_FILE_S4" \
  && pass "S4-4: line contains cmd=<forced command>" \
  || fail "S4-4: cmd field missing/wrong (log=$(cat "$LOG_FILE_S4" 2>/dev/null))"

rm -rf "$AUDIT_DIR_S4"

# ========================================================
# Summary
# ========================================================
echo ""
echo "============================================"
echo -e "${CYAN}Results:${NC} ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "============================================"

if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}Overall: PASS${NC}"
  exit 0
else
  echo -e "${RED}Overall: FAIL ($FAIL failures)${NC}"
  exit 1
fi
