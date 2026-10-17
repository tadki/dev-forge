#!/bin/bash
# SEE-1008 production simulator: proves the c115529 hook auto-creates and sets
# working_branch end-to-end against REAL platform data, WITHOUT merging to master.
#
# Faithfulness contract:
#   - Path 0 uses the REAL `multica agent tasks` (Chekky task -> SEE-1011).
#   - issue get / metadata list use REAL multica.
#   - The ONLY simulated timing is `issue run-messages -> []` (Bug A's
#     first-SessionStart condition).
#   - `issue metadata set` is intercepted+logged (never writes the real issue),
#     because the branch lives on the sandbox remote, not the real origin.
#   - Git push/reset run against a sandbox bare remote (no real-origin writes,
#     no push-guard interference).
# Then re-runs the SAME scenario with the OLD hook (c115529^) to show the old
# code fails to resolve issue_id here (Bug A reproduced in the sim).
#
# Run: bash /tmp/see1008_prod_sim.sh

set -uo pipefail

REPO_ROOT="/home/jerry/multica_workspaces/1a011680-a476-4553-929d-478690824e46/90321f9c/workdir/KingOfLikes-Godot"
AGENT_ID="b2384294-919a-4a91-9f35-2c45848577aa"
TASK_ID="9670acec-6bf7-4858-9439-6e3ca2581b00"
ISSUE_ID="14b591b0-be48-42c7-a131-688a17947701"   # SEE-1011
EXPECTED_BRANCH="shared/SEE-1011"

TOP=""
PASS=0
FAIL=0

cleanup() { [ -n "$TOP" ] && [ -d "$TOP" ] && rm -rf "$TOP"; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

extract_hook() { git -C "$REPO_ROOT" show "$1:.claude/hooks/scripts/repo-checkout.sh" > "$2" 2>/dev/null; }

# Build sandbox: bare origin + clone KingOfLikes-Godot (master m1->m2, agent/sim
# tracking origin/master, clean). Echoes the clone path.
build_fixture() {
    local root="$1" remote="$root/origin.git" work="$root/workdir/KingOfLikes-Godot"
    mkdir -p "$root/workdir"
    git init --bare --quiet "$remote"
    git init --quiet "$work"
    (
        cd "$work"
        git config user.email qa@kol.test; git config user.name QA
        git remote add origin "$remote"
        echo line1 > f.txt; echo stable > stable.txt
        git add f.txt stable.txt; git commit -qm m1
        git branch -M master; git push -q origin master
        echo m2 >> f.txt; git add f.txt; git commit -qm m2; git push -q origin master
        git checkout -qb agent/sim
        git branch -u origin/master agent/sim >/dev/null 2>&1
    ) >/dev/null 2>&1
    echo "$work"
}

# Minimal mock wrapper: run-messages=[] + metadata set logged; all else -> real.
write_mock() {
    local f="$1"
    cat > "$f" <<'MOCK'
#!/bin/bash
if [ "$1" = issue ] && [ "$2" = run-messages ]; then echo "[]"; exit 0; fi
if [ "$1" = issue ] && [ "$2" = metadata ] && [ "$3" = set ]; then
    printf '%s\n' "$*" >> "$MOCK_LOG"; exit 0
fi
exec "$REAL_MULTICA" "$@"
MOCK
    chmod +x "$f"
}

# Run hook for a ref on a fresh sandbox; sets globals: WORK, STDOUT, MOCKLOG.
run_hook() {
    local ref="$1" root="$2"
    REAL_MULTICA=$(command -v multica)
    export REAL_MULTICA
    WORK=$(build_fixture "$root")
    MOCKLOG="$root/mock_calls.log"; : > "$MOCKLOG"; export MOCK_LOG="$MOCKLOG"
    local mockbin="$root/mockbin"; mkdir -p "$mockbin"; write_mock "$mockbin/multica"
    local hook="$root/repo-checkout.sh"; extract_hook "$ref" "$hook"
    STDOUT="$root/hook_stdout.txt"
    (
        cd "${WORK%/*}"          # parent of the clone == multica task workdir
        export MULTICA_AGENT_ID="$AGENT_ID" MULTICA_TASK_ID="$TASK_ID"
        export PATH="$mockbin:$PATH"
        bash "$hook"
    ) > "$STDOUT" 2>&1
}

echo "==================================="
echo "SEE-1008 production simulation"
echo "==================================="

TOP=$(mktemp -d -t see1008-prod-XXXXXX)

# ---------- Phase 1: NEW hook (c115529) ----------
echo ""; echo "[Phase 1] NEW hook @ c115529 (fix present, Path 0 available)"
NEW_ROOT="$TOP/new"; run_hook c115529 "$NEW_ROOT"
echo "  hook exit: $?  work: $WORK"

# 1. Path 0 resolves real issue_id (source helper, real multica via mock delegation)
end=$(grep -n '^try_auto_create_shared_branch()' "$NEW_ROOT/repo-checkout.sh" | head -1 | cut -d: -f1)
helper="$NEW_ROOT/helper.sh"; sed -n "8,$((end-1))p" "$NEW_ROOT/repo-checkout.sh" > "$helper"
rid=$(
    REAL_MULTICA=$(command -v multica) MOCK_LOG=/dev/null \
    MULTICA_AGENT_ID="$AGENT_ID" MULTICA_TASK_ID="$TASK_ID" \
    PATH="$NEW_ROOT/mockbin:$PATH" bash -c 'source "$0"; resolve_issue_id' "$helper"
)
[ "$rid" = "$ISSUE_ID" ] && pass "Path 0 resolve_issue_id -> $ISSUE_ID (REAL agent tasks)" \
                          || fail "Path 0 expected $ISSUE_ID, got '$rid'"

# 2. shared/SEE-1011 created on sandbox remote
git -C "$NEW_ROOT/origin.git" show-ref --verify --quiet "refs/heads/$EXPECTED_BRANCH" \
    && pass "sandbox remote has $EXPECTED_BRANCH" \
    || fail "sandbox remote missing $EXPECTED_BRANCH"

# 3. metadata set logged with correct key+value+issue
grep -q "working_branch" "$MOCKLOG" && grep -q "$EXPECTED_BRANCH" "$MOCKLOG" && grep -q "$ISSUE_ID" "$MOCKLOG" \
    && pass "metadata set logged: working_branch=$EXPECTED_BRANCH for $ISSUE_ID" \
    || { fail "metadata set log wrong"; echo "---- log ----"; cat "$MOCKLOG"; echo "----"; }

# 4. local HEAD aligned to origin/shared/SEE-1011
h=$(git -C "$WORK" rev-parse HEAD); o=$(git -C "$WORK" rev-parse "origin/$EXPECTED_BRANCH" 2>/dev/null)
[ "$h" = "$o" ] && [ -n "$o" ] && pass "local HEAD aligned to origin/$EXPECTED_BRANCH" \
                               || fail "HEAD mismatch: $h vs $o"

# 5. agent/sim upstream -> origin/shared/SEE-1011
u=$(git -C "$WORK" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || echo NONE)
[ "$u" = "origin/$EXPECTED_BRANCH" ] && pass "agent/sim upstream -> origin/$EXPECTED_BRANCH" \
                                       || fail "upstream=$u"

# 6. .cc-aligned marker appeared in /tmp during the run
marker=$(find /tmp -maxdepth 1 -name '.cc-aligned-*' -newermt '-3 minutes' 2>/dev/null | head -1)
[ -n "$marker" ] && pass ".cc-aligned marker created ($marker)" || fail "no .cc-aligned marker"

# 7. success hint
grep -q "已自动创建共享分支" "$STDOUT" && pass "success hint '已自动创建共享分支' emitted" \
                                     || { fail "success hint missing"; echo "---- stdout ----"; cat "$STDOUT"; }

NEW_FAIL=$FAIL

# ---------- Phase 2: OLD hook (c115529^) ----------
echo ""; echo "[Phase 2] OLD hook @ c115529^ (no Path 0) — Bug A should reproduce"
OLD_ROOT="$TOP/old"; run_hook c115529^ "$OLD_ROOT"
echo "  hook exit: $?  work: $WORK"

# 8. OLD hook did NOT create the shared branch on its sandbox remote
git -C "$OLD_ROOT/origin.git" show-ref --verify --quiet "refs/heads/$EXPECTED_BRANCH" \
    && fail "OLD hook unexpectedly created $EXPECTED_BRANCH" \
    || pass "OLD hook did NOT create $EXPECTED_BRANCH (Bug A reproduced)"

# 9. OLD hook did NOT issue any metadata set (resolve_issue_id was empty)
if [ ! -s "$MOCKLOG" ]; then pass "OLD hook issued no metadata set (resolve empty)";
else fail "OLD hook log non-empty:"; sed 's/^/    /' "$MOCKLOG"; fi

# 10. OLD hook stdout shows the "尚未设置 working branch" fallback
grep -q "尚未设置 working branch" "$STDOUT" && pass "OLD hook fell back to default worktree hint" \
                                              || { fail "OLD hook fallback hint missing"; echo "---- stdout ----"; cat "$STDOUT"; }

echo ""
echo "==================================="
echo "RESULT: PASS=$PASS FAIL=$FAIL  (Phase1 NEW fail=$NEW_FAIL)"
echo "==================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
