#!/usr/bin/env bash
# forge-console 单元/API 测试接入 tests/run_all.sh
# 自包含：依赖未安装则 SKIP（exit 0），绝不联网自动安装。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONSOLE_DIR="$REPO_ROOT/console"

if [[ ! -d "$CONSOLE_DIR/node_modules" ]]; then
  echo "[SKIP] forge-console deps not installed (run: cd console && npx pnpm install)"
  exit 0
fi

cd "$CONSOLE_DIR" || exit 1

status=0
for pkg in packages/schema packages/collectors packages/server; do
  echo "--- console: $pkg ---"
  if ! npx pnpm@9 --filter "./$pkg" test; then
    status=1
  fi
done

exit "$status"
