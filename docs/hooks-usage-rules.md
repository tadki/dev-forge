# Claude Code Hooks 官方使用规则

> 本文档为 Claude Code hooks 官方规则的整理，与 `hooks-implementation-guide.md`（团队实践踩坑记录）互补。

---

## 1. Hook 事件

Hooks 在特定的生命周期节点执行。官方事件按触发周期划分为四组。

### 1.1 会话级事件（每个会话一次）

| 事件 | 触发时机 | Matcher 过滤字段 |
|------|---------|-----------------|
| `SessionStart` | 会话启动或恢复时 | 启动方式：`startup`, `resume`, `clear`, `compact` |
| `Setup` | 运行 `--init-only`, `-p --init`, `-p --maintenance` 时 | CLI 标志：`init`, `maintenance` |
| `SessionEnd` | 会话终止时 | 结束原因：`clear`, `resume`, `logout`, `prompt_input_exit`, `bypass_permissions_disabled`, `other` |

### 1.2 回合级事件（每个回合一次）

| 事件 | 触发时机 | Matcher 过滤字段 |
|------|---------|-----------------|
| `UserPromptSubmit` | 用户提交 prompt 后、Claude 处理前 | 无（总是触发） |
| `UserPromptExpansion` | 斜杠命令展开为 prompt 时 | 命令名称 |
| `Stop` | Claude 响应结束时 | 无（总是触发） |
| `StopFailure` | 回合因 API 错误结束时 | 错误类型：`rate_limit`, `authentication_failed`, `oauth_org_not_allowed`, `billing_error`, `invalid_request`, `server_error`, `max_output_tokens`, `unknown` |

### 1.3 工具调用级事件（智能体循环期间，每次工具调用一次）

| 事件 | 触发时机 | Matcher 过滤字段 |
|------|---------|-----------------|
| `PreToolUse` | 工具调用执行之前（可阻止其执行） | 工具名称（`Bash`, `Edit`, `Write`, …） |
| `PermissionRequest` | 权限对话框弹出时 | 工具名称 |
| `PermissionDenied` | 工具调用被自动模式拒绝时 | 工具名称 |
| `PostToolUse` | 工具调用成功之后 | 工具名称 |
| `PostToolUseFailure` | 工具调用失败之后 | 工具名称 |
| `PostToolBatch` | 一批并行工具调用全部完成之后 | 无（总是触发） |

### 1.4 异步/后台事件

| 事件 | 触发时机 | Matcher 过滤字段 |
|------|---------|-----------------|
| `Notification` | CC 发送通知时 | 通知类型 |
| `SubagentStart` | 子代理启动时 | 代理类型 |
| `SubagentStop` | 子代理结束时 | 代理类型 |
| `TaskCreated` | 通过 TaskCreate 创建任务时 | 无 |
| `TaskCompleted` | 任务被标记完成时 | 无 |
| `InstructionsLoaded` | 加载 CLAUDE.md 或 rules 时 | 加载原因 |
| `ConfigChange` | 配置文件发生变化时 | 配置位置 |
| `CwdChanged` | 工作目录变更时 | 无 |
| `FileChanged` | 被监听文件在磁盘发生变化时 | 文件名（`.envrc\|.env`） |
| `PreCompact` | 上下文压缩之前 | 触发方式：`manual`, `auto` |
| `PostCompact` | 上下文压缩之后 | 触发方式：`manual`, `auto` |
| `WorktreeCreate` | 创建 worktree 时 | 无 |
| `WorktreeRemove` | 移除 worktree 时 | 无 |
| `TeammateIdle` | 团队协作成员进入 idle 时 | 无 |
| `Elicitation` | MCP 服务器请求用户输入时 | MCP 服务器名称 |
| `ElicitationResult` | 用户响应 MCP elicitation 之后 | MCP 服务器名称 |

### 1.5 不支持 Matcher 的事件

以下事件忽略 `matcher` 字段，总是在每次触发时执行：

`UserPromptSubmit`, `Stop`, `PostToolBatch`, `TeammateIdle`, `TaskCreated`, `TaskCompleted`, `WorktreeCreate`, `WorktreeRemove`, `CwdChanged`

---

## 2. settings.json 配置格式

Hooks 在 JSON 配置文件中定义，采用三层嵌套结构：

```json
{
  "hooks": {
    "<EventName>": [
      {
        "matcher": "<ToolName>|<ToolName>",
        "hooks": [
          {
            "type": "command",
            "command": "<shell command>"
          }
        ]
      }
    ]
  }
}
```

要点：

- `<EventName>` 为官方事件名（`PreToolUse` / `PostToolUse` / `SessionStart` / …）
- `matcher` 使用官方允许的过滤字段（工具名通过 `|` 组合，支持正则）
- `hooks` 数组中 `type` 固定为 `"command"`，`command` 为实际执行的命令字符串
- **不可**把 `command` 直接写在 `matcher` 对象的同级字段——那是 CC 不识别的扁平写法

### 配置位置

| 位置 | 作用域 |
|------|--------|
| `~/.claude/settings.json` | 所有项目（全局） |
| `.claude/settings.json` | 单个项目（可共享） |
| `.claude/settings.local.json` | 单个项目（gitignore） |
| Managed policy settings | 组织级 |
| Plugin `hooks/hooks.json` | 插件启用时 |
| Skill/agent frontmatter | 组件活跃期间 |

### Settings 加载层级

Enterprise / Managed policy > CLI args > Local project > Shared project > User

CC 会自动合并所有层级的 settings，无需 CLI 参数控制加载哪些层级。

---

## 3. Matcher 语法

`matcher` 字段用于过滤 hook 的触发时机：

| Matcher 值 | 解析方式 |
|-----------|---------|
| `"*"`, `""` 或省略 | 匹配所有 |
| 仅包含字母、数字、`_` 和 `\|` | 确匹配或 `\|` 分隔列表 |
| 包含其他字符 | JavaScript 正则表达式 |

**示例：**

- `Bash` — 精确匹配 Bash 工具
- `Edit\|Write` — 匹配 Edit 或 Write
- `^Notebook` — 正则：匹配以 Notebook 开头
- `mcp__memory__.*` — memory 服务器的所有工具
- `mcp__.*__write.*` — 任意 MCP 服务器中以 `write` 开头的工具

**MCP 工具匹配注意：** MCP 工具命名为 `mcp__<server>__<tool>`。要匹配某服务器下的所有工具**必须**用 `.*`（如 `mcp__memory__.*`）；写成 `mcp__memory`（无 `.*`）会被当作字面字符串比对，匹配不到任何工具。

**各事件的 matcher 过滤字段见 §1 各事件表的「Matcher 过滤字段」列。**

---

## 4. 命令执行

**命令 hook 字段：**

```json
{
  "type": "command",
  "command": "/path/to/script.sh",
  "async": false,
  "asyncRewake": false,
  "shell": "bash",
  "timeout": 600
}
```

**退出码行为：**

| 退出码 | 含义 |
|--------|------|
| 0 | 成功；解析 stdout 的 JSON 输出 |
| 2 | 阻塞错误；stderr 作为错误反馈给 Claude |
| 其他 | 靧阻塞错误；继续执行 |

**JSON 输出格式：**

```json
{
  "continue": true,
  "stopReason": "message",
  "suppressOutput": false,
  "systemMessage": "warning message",
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "context for Claude"
  }
}
```

**PreToolUse 的决策控制：**

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Destructive command blocked"
  }
}
```

决策值：`allow`、`deny`、`ask`、`defer`

---

## 5. 环境变量

| 变量 | 描述 |
|------|------|
| `$CLAUDE_PROJECT_DIR` | 项目根目录 |
| `${CLAUDE_PLUGIN_ROOT}` | 插件安装目录 |
| `${CLAUDE_PLUGIN_DATA}` | 插件持久化数据目录 |
| `$CLAUDE_CODE_REMOTE` | 在远程 Web 环境中为 `"true"` |
| `$CLAUDE_ENV_FILE` | 用于持久化环境变量的文件路径（SessionStart、Setup、CwdChanged、FileChanged 事件） |
| `$TOOL_NAME` | 当前触发 hook 的工具名称（由 CC 注入） |

**持久化环境变量：**

```bash
if [ -n "$CLAUDE_ENV_FILE" ]; then
  echo 'export NODE_ENV=production' >> "$CLAUDE_ENV_FILE"
fi
```

---

## 6. 最佳实践

**Hook 解析流程：**

1. 事件触发
2. Matcher 检查激活 hook 分组
3. `if` 条件进一步匹配到特定处理器
4. Hook 处理器运行并返回决策

**使用 `if` 字段提升效率：**

```json
{
  "type": "command",
  "if": "Bash(git *)",
  "command": "git-verify.sh"
}
```

仅在 Bash 子命令匹配 `git *` 时才启动处理器。

**JSON 验证：** 确保返回结构化输出时 stdout 仅包含 JSON。启动时打印输出的 shell 配置可能干扰 hook 执行。

**超时默认值：** 命令 600s，prompt 30s，agent 60s。

**异步 Hooks：** 使用 `async` 实现非阻塞后台执行；使用 `asyncRewake` 在退出码 2 时唤醒 Claude。

**输出限制：** 上下文注入上限 10,000 字符；超出部分保存到文件并显示预览。

**Skill/agent Hooks：** 在组件 frontmatter 中使用 `once: true` 实现单次执行的 hooks。

**测试 Hooks：** 使用 `/hooks` 菜单验证配置并检查来源。

**配置变更不热加载：** CC 在 session 启动时读取 hooks 配置。运行期间修改 settings.json 不会生效，需要启动新 session。

---

## 7. 配置文件示例

### 阻止危险命令

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "if": "Bash(rm *)",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/block-rm.sh"
          }
        ]
      }
    ]
  }
}
```

### 自动格式化（PostToolUse）

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/format-on-save.sh"
          }
        ]
      }
    ]
  }
}
```

### 环境持久化

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "setup-env.sh"
          }
        ]
      }
    ]
  }
}
```

---

*文档版本：2026-05-10*
*来源：Claude Code 官方文档 (https://code.claude.com/docs/en/hooks) + SEE-201 实践经验*