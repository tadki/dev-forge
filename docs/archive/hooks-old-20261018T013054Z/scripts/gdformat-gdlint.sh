#!/bin/bash
set -e

# PostToolUse hook: auto-format and lint GDScript files after edit
# Trigger: Write|Edit on .gd files
# Runs gdformat then gdlint on the modified file

# Pass through stdin (required for PostToolUse hooks)
INPUT=$(cat)
echo "$INPUT"

# Extract file_path from tool input JSON via node stdin
FILE_PATH=$(printf '%s' "$INPUT" | node -e "
  let d = '';
  process.stdin.on('data', c => d += c);
  process.stdin.on('end', () => {
    try {
      const i = JSON.parse(d);
      const fp = i.tool_input?.file_path || i.tool_input?.filePath || '';
      process.stdout.write(fp);
    } catch(e) { process.stdout.write(''); }
  });
" 2>/dev/null)

# If no file_path found, exit silently
[ -z "$FILE_PATH" ] && exit 0

# Only run for .gd files
case "$FILE_PATH" in
  *.gd) ;;
  *) exit 0 ;;
esac

# Skip if file doesn't exist (e.g. deleted)
[ ! -f "$FILE_PATH" ] && exit 0

# Run gdformat
gdformat "$FILE_PATH" 2>&1 || {
  echo "[gdformat] Formatting failed for: $FILE_PATH" >&2
  exit 2
}

# Run gdlint
gdlint "$FILE_PATH" 2>&1 || {
  echo "[gdlint] Lint issues found in: $FILE_PATH" >&2
  # PostToolUse exit 2 feeds stderr to Claude as context
  exit 2
}

# SEE-1142: banned polled-cursor API lint (project-level rule; gdlint has no
# custom-rule plugin mechanism). See .dev/scripts/mcp-mouse-lint.sh header for
# scope, exclusions, and the mcp-lint-ignore[-next-line] whitelist convention.
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
MCP_LINT="$PROJECT_ROOT/.dev/scripts/mcp-mouse-lint.sh"
if [ -x "$MCP_LINT" ]; then
  "$MCP_LINT" "$FILE_PATH" || {
    echo "[mcp-mouse-lint] Banned polled cursor API in: $FILE_PATH" >&2
    exit 2
  }
fi
