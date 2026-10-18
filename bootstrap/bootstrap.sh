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
WRAPPER_DIR="$REPO_ROOT/claude-hooks"
WRAPPER="$WRAPPER_DIR/hook-wrapper.sh"


# ---- 修订 B：toolchain env 注入（写 ~/.config/dev-forge/toolchain.env）----
# systemd 单元以 EnvironmentFile 读取本文件取得 TARGET_REPO_ROOT；dev-forge 仓内
# 不落任何真实检出路径。用法：bootstrap.sh --write-toolchain-env --target-repo-root /path/to/repo
if [ "${1:-}" = "--write-toolchain-env" ]; then
  shift
  TRR=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --target-repo-root) TRR="$2"; shift 2 ;;
      *) echo "bootstrap: unknown arg $1" >&2; exit 1 ;;
    esac
  done
  [ -n "$TRR" ] && [ -d "$TRR/.dev" ] || { echo "bootstrap: --target-repo-root must point to a repo with .dev/" >&2; exit 1; }
  mkdir -p "$HOME/.config/dev-forge"
  printf '# written by dev-forge bootstrap (SEE-1429 revision B)\nTARGET_REPO_ROOT=%s\n' "$TRR" > "$HOME/.config/dev-forge/toolchain.env"
  echo "bootstrap: toolchain env written - $HOME/.config/dev-forge/toolchain.env"
  exit 0
fi

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
