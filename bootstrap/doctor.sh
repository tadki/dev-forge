#!/bin/bash
# doctor.sh - repeatable health check for the dev-forge hooks chain (SEE-1429 Phase 2).
# ① 注册路径可达且解析到本检出 ② engine 自测（rules validate + dry-run when 求值）
# ③ rules schema 校验（validate-rules.js） ④ $HOME/.claude/hooks 引用残留扫描
# ⑤ settings 注册一致性（registry-patch verify）
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "=== dev-forge doctor ==="

# ① runtime artifacts exist within this checkout
echo "--- 1. runtime artifacts reachable in this checkout"
while IFS= read -r art; do
  [ -z "$art" ] && continue
  path="$REPO_ROOT/hooks/${art#\$\{HOOKS_DIR\}/}"
  if [ -e "$path" ]; then ok "$art"; else bad "$art MISSING"; fi
done < <(node -e "const m=require('$REPO_ROOT/bootstrap/hooks-registration.json');for(const a of m.runtime_artifacts)console.log(a)")

# ② engine dry-run when evaluation
echo "--- 2. engine dry-run"
OUT=$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo doctor-probe"}}' | \
  HOOK_STATE_DIR="$(mktemp -d)" PROJECT_ROOT="$REPO_ROOT" node "$REPO_ROOT/hooks/unified/engine.js" 2>&1)
EC=$?
[ "$EC" -eq 0 ] && ok "engine exit 0 (dry-run)" || bad "engine exit $EC"

# ③ rules schema validation
echo "--- 3. rules schema"
if node "$REPO_ROOT/hooks/unified/validate-rules.js" "$REPO_ROOT/hooks/unified/rules-v2.json" >/dev/null 2>&1; then
  ok "rules-v2.json VALID"
else bad "rules-v2.json INVALID"; fi
if node "$REPO_ROOT/hooks/unified/validate-rules.js" "$REPO_ROOT/hooks/unified/rules.d/runscript-mounts.json" >/dev/null 2>&1; then
  ok "runscript-mounts.json VALID"
else bad "runscript-mounts.json INVALID"; fi

# ④ legacy global-position reference residue
echo "--- 4. legacy ~/.claude/hooks references"
HITS=$(grep -rn 'HOME/\.claude/hooks\|/home/[^ ]*/\.claude/hooks' "$REPO_ROOT/hooks" "$REPO_ROOT/bootstrap" "$REPO_ROOT/launch" "$REPO_ROOT/adapters" 2>/dev/null | grep -v ':\s*#' | grep -v ':#!' | wc -l)
if [ "$HITS" -eq 0 ]; then ok "no legacy global-position references"; else bad "$HITS legacy references remain"; fi

# ⑤ settings registration consistency (only meaningful post-cutover)
echo "--- 5. settings registration (post-cutover check)"
if [ -f "$SETTINGS" ] && grep -q "$REPO_ROOT/hooks/hook-wrapper.sh" "$SETTINGS" 2>/dev/null; then
  if node "$SELF_DIR/registry-patch.js" verify --settings "$SETTINGS" \
    --manifest "$SELF_DIR/hooks-registration.json" --global-hooks "$REPO_ROOT/hooks" >/dev/null 2>&1; then
    ok "settings registered → this checkout"
  else bad "settings registered but inconsistent with manifest"; fi
else
  echo "  [SKIP] settings not yet pointed at this checkout (pre-cutover state is valid)"
fi

echo "=== doctor: $PASS PASS / $FAIL FAIL ==="
[ "$FAIL" -eq 0 ]
