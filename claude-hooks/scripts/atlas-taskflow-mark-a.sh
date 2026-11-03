#!/bin/bash
# atlas-taskflow-mark-a.sh - PostToolUse hook: mark a when taskflow skill is used on an issue with comments
# Trigger: Skill tool (matcher: Skill)
# Logic: write mark_a=true to state file if skill=taskflow, MULTICA_TASK_ID exists, and issue has comments

# WSL-safe stdin read (3s timeout) — SEE-1516 F3 单源：scripts/lib/read-stdin.lib.sh
_RS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/read-stdin.lib.sh"
# shellcheck source=scripts/lib/read-stdin.lib.sh
[ -f "$_RS_LIB" ] && . "$_RS_LIB" && hook_read_stdin

# Only for Atlas agent
if [ "${MULTICA_AGENT_NAME:-}" != "Atlas" ]; then
    exit 0
fi

# Check MULTICA_TASK_ID exists (we are in an issue context)
if [ -z "${MULTICA_TASK_ID:-}" ]; then
    exit 0
fi

# Extract skill name from stdin JSON (SEE-1516 F3 单源：hook_json_field)
SKILL_NAME=$(printf '%s' "$INPUT" | hook_json_field tool_input.skill)

# Only trigger for taskflow skill
if [ "$SKILL_NAME" != "taskflow" ]; then
    exit 0
fi

# Resolve the real issue ID from .agent_context/issue_context.md
# MULTICA_TASK_ID is a task/session ID, not an issue ID — using it for API calls returns 404
ISSUE_ID=""
if [ -f ".agent_context/issue_context.md" ]; then
    ISSUE_ID=$(sed -n 's/.*\*\*Issue ID:\*\* *\([a-f0-9-]\{36\}\).*/\1/p' ".agent_context/issue_context.md" | head -1)
fi
# Fallback: if extraction failed, use MULTICA_TASK_ID (backward compat for non-issue contexts)
if [ -z "$ISSUE_ID" ]; then
    ISSUE_ID="$MULTICA_TASK_ID"
fi

# Check if current issue has comments
# --recent 1 returns latest thread; non-empty array means at least one comment exists
COMMENTS=$(multica issue comment list "$ISSUE_ID" --recent 1 --output json 2>/dev/null)
if [ -z "$COMMENTS" ] || [ "$COMMENTS" = "[]" ]; then
    exit 0
fi

# Write mark a to state file
STATE_FILE="/tmp/atlas-taskflow-state-${MULTICA_TASK_ID}"
{
    echo "mark_a=true"
    echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$STATE_FILE"

exit 0
