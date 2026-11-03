#!/usr/bin/env bash
# 采集器：把 Owner 的 hindsight 本地补丁（.assets/hindsight-local-mods.sh）
# 注册为 Forge Console 通用资产（custom kind），payload 含用途说明与脚本全文。
# 补丁本体放 .assets/（点开头目录不会被 registry 当采集器执行）。
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/.assets/hindsight-local-mods.sh"

[ -f "$SRC" ] || { echo "patch source missing: $SRC" >&2; exit 1; }

python3 - "$SRC" <<'PY'
import json, sys, hashlib, datetime

src = sys.argv[1]
body = open(src, encoding="utf-8").read()
sha = hashlib.sha256(body.encode()).hexdigest()

asset = {
    "id": "custom:hindsight-local-mods-patch",
    "kind": "custom",
    "name": "hindsight-local-mods.sh",
    "summary": "Owner 定制的 hindsight 插件功能裁剪补丁：删 capture_initiative 工具与提示、移除插件自带 stdio MCP（只删不配）、关 autoUpdate 与五个自管知识页、保活三条自动记忆 hooks；每次 install/update 后必须重放",
    "attach": {"level": "user"},
    "enforcement": "advisory",
    "platforms": ["claude-code"],
    "provenance": "first-party",
    "tags": ["hindsight", "patch", "owner-policy", "memory"],
    "source": {"collector": "hindsight-local-mods", "path": "console/collectors.d/.assets/hindsight-local-mods.sh"},
    "payload": {
        "assetType": "owner-patch",
        "purpose": [
            "patch 掉目标机器上 hindsight 插件（@vectorize-io/hindsight-coding-agents）的部分功能：",
            "1. 删除注入 tool guide 里的 hindsight_capture_initiative 提示行与 MCP 工具注册块",
            "2. 移除插件自带 stdio MCP 注册（只删不配——新 MCP 由 Owner 在需要的机器上单独决定，如 WSL 的 HTTP 桥 192.168.1.210:4894/hindsight）",
            "3. coding-agent.json 关闭 autoUpdate、五个自管知识页全部 false",
            "4. settings.json env 加 HINDSIGHT_MANAGE_BANK_CONFIG=false",
            "5. 保活三条自动 hooks：SessionStart 注入 / UserPromptSubmit recall / Stop retain（缺失即补回）",
        ],
        "bankRouting": "机器策略必须显式选择：Mac（独立机）用 --bank solo；WSL multica 机用 --bank multica（bankIdTemplate=claude_code，顶层 bankId 会压掉 per-agent HINDSIGHT_BANK_ID 造成串库）",
        "replayPolicy": "幂等可重复；每次 npx @vectorize-io/hindsight-coding-agents install|update 之后必须重跑一次（bash ~/.hindsight/patches/hindsight-local-mods.sh [--bank ...]）",
        "origin": "Mac 192.168.1.210 ~/.hindsight/patches/hindsight-local-mods.sh（2026-10-29 编写，针对 runtime 0.8.2）",
        "incident20261103": "WSL(105) 侧 known_marketplaces.json 于 09:17 被 Windows 侧实例以 C:\\Users\\Jerry 路径整体重写（跨边界 home 泄漏），同期 hindsight HTTP 桥 MCP 注册缺失；当日修复（注册表路径改回 Linux、注册 HTTP 桥）并将补丁本体存档至本采集器旁的 .assets/ 以防再次丢失",
        "sha256": sha,
        "script": body,
    },
}

collection = {
    "collector": "hindsight-local-mods",
    "collectedAt": datetime.datetime.now(datetime.timezone.utc).astimezone().isoformat(timespec="seconds"),
    "assets": [asset],
    "relations": [],
    "diagnostics": [],
}
print(json.dumps(collection, ensure_ascii=False))
PY
