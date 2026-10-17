#!/bin/bash
# rollback.sh - restore settings hooks registration from a bootstrap backup.
# Usage: rollback.sh [--settings S] [--backup B]   (defaults: latest .bak-bootstrap-*)
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="${SETTINGS:-$HOME/.claude/settings.json}"
BACKUP="${BACKUP:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --settings) SETTINGS="$2"; shift 2 ;;
    --backup)   BACKUP="$2"; shift 2 ;;
    *) echo "rollback: unknown arg $1" >&2; exit 1 ;;
  esac
done

if [ -z "$BACKUP" ]; then
  BACKUP=$(ls -1t "$SETTINGS".bak-bootstrap-* 2>/dev/null | head -1 || true)
  [ -n "$BACKUP" ] || { echo "rollback: no bootstrap backup found" >&2; exit 1; }
fi
[ -f "$BACKUP" ] || { echo "rollback: backup missing: $BACKUP" >&2; exit 1; }

cp "$BACKUP" "$SETTINGS"
echo "rollback: restored $SETTINGS ← $BACKUP"
