#!/usr/bin/env bash
# 采集器：把 2026-11-03 的 VS Code Claude 扩展 effort=max 隔离配置决定
# 注册为 Forge Console 通用资产（custom kind），payload 含完整事实链与待复核点。
# 纯配置记录，无外挂本体文件——payload 自包含。
set -euo pipefail

python3 - <<'PY'
import json, datetime

asset = {
    "id": "custom:vscode-claude-effort-config",
    "kind": "custom",
    "name": "VS Code Claude effort=max 隔离配置",
    "summary": "2026-11-03 落地：VS Code 扩展专用 effort=max 经 claudeCode.environmentVariables 注入（Windows 侧用户设置）；全局 ~/.claude/settings.json 不放 effort 变量——env 优先级高于 multica 自带的 --effort 旗标，放全局会顶掉它。Owner 指示后续复核",
    "attach": {"level": "user"},
    "enforcement": "advisory",
    "platforms": ["claude-code"],
    "provenance": "first-party",
    "tags": ["vscode", "claude-code", "effort", "multica", "owner-review"],
    "source": {"collector": "vscode-claude-effort", "path": "console/collectors.d/vscode-claude-effort.sh"},
    "payload": {
        "assetType": "config-record",
        "status": "applied-pending-owner-review",
        "decidedAt": "2026-11-03",
        "requirement": [
            "Owner 要求：VS Code 里 Claude 默认模型钉 Sonnet 4.6、思考档位钉 Max；",
            "硬边界：不得影响 multica 平台拉起的 CC。",
        ],
        "verifiedFacts": [
            "~/.claude/settings.json 是用户级全局：本机所有 CC 进程都读，包括 multica daemon spawn 的 claude 与 VS Code 扩展拉的 CC；CC 层面没有『仅 VS Code』的独立配置文件",
            "multica 启动 CC 显式传 --model agent-fronti[1m] --effort max（2026-11-03 活进程 ps 验证）",
            "优先级：模型 --model > ANTHROPIC_MODEL env > settings model 键；effort CLAUDE_CODE_EFFORT_LEVEL env > --effort CLI > modelSettings.effortLevel —— effort env 放全局会覆盖 multica 自己的 --effort（当日恰同值无感，结构上错误，已撤销）",
            "modelSettings.<model>.effortLevel 枚举只收 low|medium|high|xhigh，收不了 max；schema 的 maxEffortLevel 是上限钳制不是设定值；钉 max 只能走 CLAUDE_CODE_EFFORT_LEVEL env 或 --effort 旗标",
            "Sonnet 4.6 支持档位 low|medium|high|max（无 xhigh；settings 遗留的 claude-sonnet-4-6: xhigh 条目对该模型无效，被 env 盖住，无害）",
        ],
        "appliedConfig": {
            "model": "~/.claude/settings.json env 原有 ANTHROPIC_MODEL=claude-sonnet-4-6 保持不动（multica 的 --model 优先级更高，无冲突）",
            "effort": "/mnt/c/Users/Jerry/AppData/Roaming/Code/User/settings.json 新增 claudeCode.environmentVariables = {CLAUDE_CODE_EFFORT_LEVEL: max}——仅注入 VS Code 扩展拉起的 CC 进程，multica daemon 独立进程读不到",
            "global": "~/.claude/settings.json 未留任何 effort 变量（中途曾加，Owner 质询作用域后撤销，jq 验证 NOT SET）",
        },
        "reviewPoints": [
            "multica 侧是否需要独立 effort 策略",
            "modelSettings 里的无效 xhigh 条目是否清理",
            "LiteLLM 网关（192.168.1.210:4000）是否透传 effort/reasoning 参数——不透传则 max 实际不生效，需用 /effort 或 /status 实测",
        ],
        "reusableLesson": "做『仅 VS Code 生效』的 CC 配置用 VS Code settings 的 claudeCode.environmentVariables 注入 env；改全局 CC 配置前先 ps 看本机还有谁在拉起 CC，再对照优先级决定放哪一层",
    },
}

collection = {
    "collector": "vscode-claude-effort",
    "collectedAt": datetime.datetime.now(datetime.timezone.utc).astimezone().isoformat(timespec="seconds"),
    "assets": [asset],
    "relations": [],
    "diagnostics": [],
}
print(json.dumps(collection, ensure_ascii=False))
PY
