#!/bin/bash
# bootstrap.sh - one-shot first-install (SEE-1429 Phase 2)
# 备份现 settings hooks 段 → 按 hooks-registration.json 渲染 9 时点注册行
# （绝对路径指向本检出）→ 幂等（重跑 diff=0）。运行期零部署动作：
# 注册链直指本仓检出，本地改文件即生效（editable 单一真源）。
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
SETTINGS="${1:-$HOME/.claude/settings.json}"
MANIFEST="$SELF_DIR/hooks-registration.json"
WRAPPER_DIR="$REPO_ROOT/hooks"
WRAPPER="$WRAPPER_DIR/hook-wrapper.sh"

[ -f "$SETTINGS" ] || { echo "bootstrap: settings not found: $SETTINGS" >&2; exit 1; }
[ -f "$WRAPPER" ] || { echo "bootstrap: wrapper missing: $WRAPPER" >&2; exit 1; }
[ -f "$MANIFEST" ] || { echo "bootstrap: manifest missing: $MANIFEST" >&2; exit 1; }

TS="$(date -u +%Y%m%dT%H%M%SZ)"
BAK="$SETTINGS.bak-bootstrap-$TS"
cp "$SETTINGS" "$BAK"
echo "bootstrap: settings backed up → $BAK"

node "$SELF_DIR/registry-patch.js" merge --settings "$SETTINGS" \
  --manifest "$MANIFEST" --global-hooks "$WRAPPER_DIR"

echo "bootstrap: verifying registration…"
if node "$SELF_DIR/registry-patch.js" verify --settings "$SETTINGS" \
  --manifest "$MANIFEST" --global-hooks "$WRAPPER_DIR"; then
  echo "bootstrap: OK — 9 hook points registered → $WRAPPER_DIR"
else
  echo "bootstrap: verify FAILED — rollback.sh can restore $BAK" >&2
  exit 1
fi
