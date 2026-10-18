#!/bin/bash
# atlas-taskflow-mark-b.sh - PostToolUse hook: mark b when multica issue create succeeds after mark a
# Trigger: Bash tool (matcher: Bash)
# Logic: write mark_b=true + task_issue_id to state file if command contains 'multica issue create', mark_a exists

# WSL-safe stdin read (3s timeout)
INPUT=""
while IFS= read -r -t 3 line || [ -n "$line" ]; do
    INPUT="${INPUT}${line}"$'\n'
done
INPUT="${INPUT%$'\n'}"

# Only for Atlas agent
if [ "${MULTICA_AGENT_NAME:-}" != "Atlas" ]; then
    exit 0
fi

# Check mark a exists in state file
STATE_FILE="/tmp/atlas-taskflow-state-${MULTICA_TASK_ID:-none}"
if [ ! -f "$STATE_FILE" ]; then
    exit 0
fi
if ! grep -q "^mark_a=true" "$STATE_FILE"; then
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

# Only trigger for multica issue create commands (at least one space between words)
if ! echo "$COMMAND" | grep -q "multica[[:space:]][[:space:]]*issue[[:space:]][[:space:]]*create"; then
    exit 0
fi

# Extract new issue ID from tool output in stdin JSON
# Try multiple field paths since CC's PostToolUse stdin format may vary
ISSUE_ID=$(printf '%s' "$INPUT" | node -e "
  let d = '';
  process.stdin.on('data', c => d += c);
  process.stdin.on('end', () => {
    try {
      const i = JSON.parse(d);
      // CC PostToolUse uses tool_response; try legacy names as fallback
      let stdout = '';
      if (i.tool_response) {
        if (typeof i.tool_response === 'string') stdout = i.tool_response;
        else if (i.tool_response.stdout) stdout = i.tool_response.stdout;
        else if (Array.isArray(i.tool_response.content)) {
          stdout = i.tool_response.content.filter(c => c.type === 'text').map(c => c.text).join('');
        }
      }
      if (!stdout && i.tool_result) {
        if (typeof i.tool_result === 'string') stdout = i.tool_result;
        else if (i.tool_result.stdout) stdout = i.tool_result.stdout;
        else if (Array.isArray(i.tool_result.content)) {
          stdout = i.tool_result.content.filter(c => c.type === 'text').map(c => c.text).join('');
        }
      }
      if (!stdout && i.tool_output) {
        if (typeof i.tool_output === 'string') stdout = i.tool_output;
        else if (i.tool_output.stdout) stdout = i.tool_output.stdout;
      }
      if (!stdout && i.output) {
        if (typeof i.output === 'string') stdout = i.output;
        else if (Array.isArray(i.output)) {
          stdout = i.output.filter(c => c.type === 'text').map(c => c.text).join('');
        }
      }
      // Try to parse stdout as JSON and extract id
      if (stdout) {
        try {
          const json = JSON.parse(stdout);
          process.stdout.write(json.id || '');
        } catch(e) {
          // stdout not valid JSON, try regex fallback (JSON key or plain text)
          const match = stdout.match(/\"id\"\\s*:\\s*\"([^\"]+)\"/) || stdout.match(/\\bid\\s*[:=]\\s*\"([^\"]+)\"/);
          process.stdout.write(match ? match[1] : '');
        }
      } else {
        process.stdout.write('');
      }
    } catch(e) { process.stdout.write(''); }
  });
" 2>/dev/null)

# Write mark_b + task_issue_id to state file (replace any existing entries)
TMP_FILE="${STATE_FILE}.tmp"
grep -v "^mark_b=" "$STATE_FILE" | grep -v "^task_issue_id=" > "$TMP_FILE" 2>/dev/null || true
{
    cat "$TMP_FILE"
    echo "mark_b=true"
    if [ -n "$ISSUE_ID" ]; then
        echo "task_issue_id=${ISSUE_ID}"
    fi
} > "$STATE_FILE"
rm -f "$TMP_FILE"

exit 0
