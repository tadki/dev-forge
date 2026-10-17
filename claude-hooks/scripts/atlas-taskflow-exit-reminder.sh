#!/bin/bash
# atlas-taskflow-exit-reminder.sh - PreToolUse hook: remind Atlas to exit after taskflow orchestration
# Trigger: Bash tool with multica comment add (matcher: Bash)
# Logic: inject reminder when mark_a + mark_b exist and Atlas is about to add a comment

# WSL-safe stdin read (3s timeout)
INPUT=""
while IFS= read -r -t 3 line || [ -n "$line" ]; do
    INPUT="${INPUT}${line}"$'\n'
done
INPUT="${INPUT%$'\n'}"

# Only for Atlas agent
if [ "${MULTICA_AGENT_NAME:-}" != "Atlas" ]; then
    printf '%s' "$INPUT"
    exit 0
fi

# Check state file exists and has both marks
STATE_FILE="/tmp/atlas-taskflow-state-${MULTICA_TASK_ID:-none}"
if [ ! -f "$STATE_FILE" ]; then
    printf '%s' "$INPUT"
    exit 0
fi
if ! grep -q "^mark_a=true" "$STATE_FILE" 2>/dev/null || ! grep -q "^mark_b=true" "$STATE_FILE" 2>/dev/null; then
    printf '%s' "$INPUT"
    exit 0
fi

# Extract command from stdin JSON
COMMAND=$(printf '%s' "$INPUT" | node -e "
  let d = '';
  process.stdin.on('data', c => d += c);
  process.stdin.on('end', () => {
    try {
      const i = JSON.parse(d);
      process.stdout.write(i.tool_input?.command || '');
    } catch(e) { process.stdout.write(''); }
  });
" 2>/dev/null)

# Only trigger for multica comment add commands
if ! echo "$COMMAND" | grep -q "multica[[:space:]][[:space:]]*issue[[:space:]][[:space:]]*comment[[:space:]][[:space:]]*add"; then
    printf '%s' "$INPUT"
    exit 0
fi

# Extract target issue ID from command
# Uses node regex to properly handle quoted flag values (e.g. --content "hello world")
TARGET_ISSUE=$(printf '%s' "$COMMAND" | node -e "
  let d = '';
  process.stdin.on('data', c => d += c);
  process.stdin.on('end', () => {
    const cmd = d.trim();
    // Match 'comment add', then skip any --flag value pairs (values may be quoted), capture first non-flag arg
    const m = cmd.match(/comment\\s+add\\s+(?:--\\S+\\s+(?:'[^']*'|\"[^\"]*\"|\\S+)\\s+)*([^\\s-][^\\s]*)/);
    process.stdout.write(m ? m[1] : '');
  });
" 2>/dev/null)

# Read task issue ID from state file (if available)
TASK_ISSUE_ID=$(grep "^task_issue_id=" "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2)

if [ -n "$TASK_ISSUE_ID" ] && [ "$TARGET_ISSUE" = "$TASK_ISSUE_ID" ]; then
    # Target matches the newly created task issue ID → BLOCK
    HOOK_MSG="ERROR: Comment blocked. Per /taskflow skill requirements, after creating the new task issue and reporting to the owner in the source issue, you must end this session."

    # Output deny format (reference: mention-check.sh block style)
    printf '%s' "$HOOK_MSG" | node -e "
      let msg = '';
      process.stdin.on('data', c => msg += c);
      process.stdin.on('end', () => {
        console.log(JSON.stringify({
          hookSpecificOutput: {
            hookEventName: 'PreToolUse',
            permissionDecision: 'deny',
            permissionDecisionReason: msg,
            additionalContext: msg
          }
        }));
      });
    "
    exit 0
else
    # mark_a + mark_b are set but target does not match task issue ID (or task_issue_id unknown)
    # This covers the correct case: commenting on source issue to report
    HOOK_MSG="REMINDER: You have completed taskflow orchestration (taskflow used + new task issue created). After this comment, you must exit this session. Do not start new work after reporting."

    # Inject reminder via hookSpecificOutput using node for proper JSON escaping
    HOOK_JSON=$(HOOK_MSG="$HOOK_MSG" node -e "
      const msg = process.env.HOOK_MSG || '';
      const out = { hookSpecificOutput: { hookEventName: 'PreToolUse', additionalContext: msg } };
      process.stdout.write(JSON.stringify(out));
    " 2>/dev/null)

    if [ -n "$HOOK_JSON" ]; then
        printf '%s\n' "$HOOK_JSON"
    else
        printf '%s' "$INPUT"
    fi
    exit 0
fi
