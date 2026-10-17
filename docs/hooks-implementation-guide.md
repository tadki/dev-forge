# CC Hooks 团队实现方案

> 本文档说明 KingOfLikes 团队 Claude Code (CC) hooks 的**落地架构**和**官方 settings 配置格式**。
> 官方 hooks 事件/字段/返回值等通用用法见 `hooks-usage-rules.md`。
>
> **v2 单轨架构（SEE-1330，2026-09-20 终态）**：原「wrapper → dispatcher 按别名路由 → 业务脚本」的散装 v1 体系已收敛为**统一引擎（unified-hook）单轨**——settings 全时点仅注册 unified-hook，全部触发条件/拦截语义由配置驱动（`unified/rules-v2.json` + `unified/rules.d/*.json`），复合逻辑钩子以 `run_script` 挂载复用原脚本。迁移前后行为对照与全过程记录见 `hooks-v2-migration-map.md`。本文档已按 v2 终态重写；v1 三层调用链描述仅作历史参考保留在迁移对照清单中。

---

## 1. 架构概览

### 1.1 调用链路（v2 单轨）

```
CC hook 事件（9 时点 × matcher *）
  ↓
settings.json（全局 ~）：9 时点统一注册
  "hook-wrapper.sh <HookType> unified-hook"
hook-wrapper.sh（记录日志 + exec dispatcher.sh unified-hook）
  ↓
dispatcher.sh（P4 收敛后仅剩 unified-hook case，全局部署位优先）
  ↓
~/.claude/hooks/unified/unified-hook.sh（fail-open 入口：stdin 缓冲 + HOOK_SCOPE_ID 映射）
  ↓
unified/engine.js（配置驱动求值：on → agents → when → action）
  ├─ action: deny / context / modify  → 引擎直接产出 hookSpecificOutput JSON
  └─ action: run_script               → 挂载执行业务脚本（全 env 透传，stdout 协议直通）
                                         如 push-guard.sh / mention-check.sh / gdformat-gdlint.sh
                                         / atlas-taskflow-* / auto-pr-on-stop.sh / repo-checkout.sh
```

三层职责分离：

| 层级 | 文件 | 职责 |
|------|------|------|
| **入口** | `~/.claude/settings.json` → `hook-wrapper.sh` | CC 触发 hook → 记录日志 → 委托 dispatcher |
| **路由** | `dispatcher.sh` | 仅识别 `unified-hook` 一个 alias（全局部署位优先）；未知 alias 静默透传（fail-open） |
| **求值** | `~/.claude/hooks/unified/engine.js` | 读取规则配置（rules-v2.json + rules.d/*.json），按 `on`/`agents`/`when`/`one_shot` 求值，执行 `deny`/`context`/`modify`/`run_script` 动作 |
| **配置真源** | 仓库 `.claude/hooks/unified/rules-v2.json` + `rules.d/` + `hooks-registration.json` | 规则与注册清单的声明式真源，由幂等安装器 `install-hooks.sh` 渲染部署到全局位 |
| **业务** | 项目 `.claude/hooks/*.sh`（经 run_script 挂载） | 复合逻辑：push guard / mention 检查 / 格式化 / taskflow 记账 / auto-pr / repo-checkout |

### 1.2 为什么仍需要 dispatcher

CC 的 settings 加载规则：**只**从用户全局 `~/.claude/settings.json` 读取 hooks 配置（项目级 `.claude/settings.json` 不承载 hooks）。dispatcher 保留两层价值：

1. **引号隔离**：settings command 只含简单脚本路径 + 参数（见 §2.2 设计决策），引号问题由 wrapper 吸收。
2. **全局部署位优先路由**：unified-hook 的运行物与配置统一部署在 `~/.claude/hooks/unified/`（全局优先），避免各在跑会话按各自 checkout 的异构配置求值（SEE-1330 事故 4 教训：v2 配置必须单一真源）。

dispatcher 找不到运行物时静默透传 stdin + `exit 0`（零影响，fail-open）。

### 1.3 场景覆盖

| 场景 | 配置来源 | 触发路径 |
|------|---------|---------|
| 用户本地打开 KOL 项目 | 全局 `~/.claude/settings.json` | hook-wrapper.sh → dispatcher.sh（unified-hook）→ 全局 `~/.claude/hooks/unified/` 引擎 |
| Multica Agent 在 workdir 运行 | 全局 `~/.claude/settings.json` | 同上；全局位缺失时以 checkout 内 `.claude/hooks/unified/` 兜底 |
| 其他项目 / workdir 无代码 | 全局 `~/.claude/settings.json` | dispatcher 静默跳过（透传） |

> **注意**：项目级 `.claude/settings.json` 不定义 hooks；settings 注册唯一真源为仓库 `.claude/hooks/hooks-registration.json`（声明式清单），由安装器渲染到全局 `~/.claude/settings.json`。9 时点 = PreToolUse / PostToolUse / SessionStart / SessionEnd / Stop / SubagentStop / UserPromptSubmit / Notification / PreCompact，matcher 全 `*`，触发面收敛在引擎内 when 树。

---

## 2. 全局 settings.json hooks 配置

### 2.1 当前配置（v2 终态）

路径：`~/.claude/settings.json`（仅展示 hooks 部分）

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "/home/jerry/.claude/hooks/hook-wrapper.sh PreToolUse unified-hook" } ] }
    ],
    "PostToolUse": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "/home/jerry/.claude/hooks/hook-wrapper.sh PostToolUse unified-hook" } ] }
    ],
    "SessionStart": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "/home/jerry/.claude/hooks/hook-wrapper.sh SessionStart unified-hook" } ] }
    ],
    "SessionEnd": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "/home/jerry/.claude/hooks/hook-wrapper.sh SessionEnd unified-hook" } ] }
    ],
    "Stop": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "/home/jerry/.claude/hooks/hook-wrapper.sh Stop unified-hook" } ] }
    ],
    "SubagentStop": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "/home/jerry/.claude/hooks/hook-wrapper.sh SubagentStop unified-hook" } ] }
    ],
    "UserPromptSubmit": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "/home/jerry/.claude/hooks/hook-wrapper.sh UserPromptSubmit unified-hook" } ] }
    ],
    "Notification": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "/home/jerry/.claude/hooks/hook-wrapper.sh Notification unified-hook" } ] }
    ],
    "PreCompact": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "/home/jerry/.claude/hooks/hook-wrapper.sh PreCompact unified-hook" } ] }
    ]
  }
}
```

> **v2 终态形态**：9 时点 × matcher 全 `*`，全部指向同一 `unified-hook` alias；v1 散装注册（skill-check / mention-check / push-guard 等 11 项 wrapper 行）已全部移除。settings 注册无仓库主副本——声明式真源为 `.claude/hooks/hooks-registration.json`，由幂等安装器渲染（原子写 + 备份 + 回滚，`install-hooks.sh install/verify/disable-v1/rollback`）。
>
> **路径说明**：生产环境使用绝对路径（如 `/home/jerry/.claude/hooks/...`），避免 WSL 中 `~` 展开不一致的问题。上例使用 `~` 仅为可读性。

### 2.2 关键设计决策

1. **command 格式：纯脚本路径**
   ```
   正确: ~/.claude/hooks/hook-wrapper.sh PreToolUse unified-hook
   ```
   command 只写脚本路径 + 参数，不要添加 bash 前缀或引号嵌套。

2. **每个 command 携带两个参数：HookType + Alias**
   - `HookType`（$1）：CC 官方事件名（9 时点）
   - `Alias`（$2）：v2 终态恒为 `unified-hook`（dispatcher 仅路由该 alias）

3. **matcher 全 `*`（v2 语义反转）**
   - v1 按 hook 拆多个注册项并在 matcher 层按工具过滤；v2 全时点统一 `*`，触发窗口收敛到引擎内 `when` 树（tool op / file op / command op / payload op / branch op 等组合）——单一注册 + 配置驱动，规则增删零 settings 变更

4. **注册真源为声明式清单**
   - `hooks-registration.json`：9 时点列表 + runtime_artifacts 部署清单 + per-phase 启用/禁用语义（P0–P3 历史 cutover 留档）
   - 任何 hooks 变更先改清单，再由安装器落地；禁止手工直改 settings

### 2.3 规则配置真源（v2 新增）

| 文件 | 内容 | 维护约束 |
|---|---|---|
| `.claude/hooks/unified/rules-v2.json` | 13 条配置化规则（skill-check 12 条 v1 等价翻译 + tscn-tres-guard；doc-reminder 死规则已删，SEE-1388 SPEC-004）：`on`/`agents`/`owner`/`blocking`/`when`/`one_shot`/`action[deny\|context]`；owner/blocking 为全规则强制字段，validate-rules.js 强制校验（见 §5.1） | 逐规则等价对照见迁移清单 §6.1；改动须过 validate-rules.js 状态机 |
| `.claude/hooks/unified/rules.d/runscript-mounts.json` | 8 条 run_script 挂载规则（push-guard / mention-check / gdformat-gdlint / taskflow×3 / auto-pr / repo-checkout）：`deny_exit_codes` / `on_fail` / `timeout_ms` | 挂载 lane 与 rules-v2 规则段互不交叉编辑 |
| `.claude/hooks/hooks-registration.json` | settings 注册声明式真源 + runtime_artifacts 部署清单 | 见 §2.1 |

---

## 3. hook-wrapper.sh 入口层

### 3.1 代码

路径：`~/.claude/hooks/hook-wrapper.sh`

```bash
#!/bin/bash
# hook-wrapper.sh - entry point for CC hooks
# Called by CC with hook type as $1 and alias as $2
# Logs to hook-fire.log then delegates to dispatcher.sh

HOOK_TYPE="${1:-unknown}"
ALIAS="${2:-unknown}"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)"

# Dynamic firelog path: repo-level .claude/ when available, global fallback
LOG_FILE="$HOME/.claude/hook-fire.log"
for _dir in "$CLAUDE_PROJECT_DIR" "$PWD"; do
  [ -n "$_dir" ] && [ -d "$_dir/.claude" ] && { LOG_FILE="$_dir/.claude/hook-fire.log"; break; }
done
# Multica workdir pattern: repo checked out inside workdir
if [ "$LOG_FILE" = "$HOME/.claude/hook-fire.log" ]; then
  for _subdir in "$PWD"/*/; do
    [ -d "$_subdir.claude" ] && { LOG_FILE="${_subdir}.claude/hook-fire.log"; break; }
  done
fi

echo "[$TIMESTAMP] [$HOOK_TYPE] alias=$ALIAS tool=$TOOL_NAME" >> "$LOG_FILE" 2>/dev/null || true

exec "/home/jerry/.claude/hooks/dispatcher.sh" "$ALIAS"
```

### 3.2 为什么需要 wrapper

直接在 settings.json 中调用 `dispatcher.sh` 会有引号问题：

```json
"command": "~/tools/dev-forge/claude-hooks/dispatcher.sh \"$OLD_GLOBAL_POS/dispatcher.sh\" PreToolUse"  # v1 时代引号问题示例（历史，OLD_GLOBAL_POS = 旧全局部署位）
```

引入 wrapper 后，command 只包含简单路径 + 参数，不含任何引号。

Wrapper 的职责：
1. 接收 CC 传入的参数，记录日志到 firelog（仓库级 `.claude/hook-fire.log` 或全局回退）
2. 用 `exec` 委托给 `dispatcher.sh`（不驻留额外进程）

---

## 4. dispatcher.sh 路由层

### 4.1 代码

路径：`~/.claude/hooks/dispatcher.sh`（唯一真源为 repo 内 `.dev/hooks/dispatcher.sh`，全局副本须与其字节一致）

```bash
#!/bin/bash
# CC Hooks Dispatcher - finds and runs project-level hooks
# Called with alias as argument (e.g. push-guard, auto-pr, repo-checkout)
# Maps alias directly to the final business script

ALIAS="${1:-unknown}"

# Buffer stdin with timeout (WSL fix: interactive bash doesn't propagate EOF properly)
INPUT=""
while IFS= read -r -t 3 line; do
    INPUT="${INPUT}${line}"$'\n'
done
INPUT="${INPUT%$'\n'}"

# WSL-aware project directory detection（与旧版一致，略）

# Find project root containing .claude/hooks/（与旧版一致，略）

# No hooks -> pass stdin through unchanged
if [ -z "$PROJECT_ROOT" ]; then
  printf '%s' "$INPUT"
  exit 0
fi

# Dynamic firelog path: repo-level when available, global fallback
LOG_FILE="$HOME/.claude/hook-fire.log"
[ -n "$PROJECT_ROOT" ] && LOG_FILE="$PROJECT_ROOT/.claude/hook-fire.log"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [dispatcher.sh] alias=$ALIAS ..." >> "$LOG_FILE" 2>/dev/null || true

# Map alias to final business script.
# SEE-1330 P4 收敛终态：alias 路由仅剩 unified-hook（全局部署位优先，
# 事故 4 修正：v2 配置必须单一真源，checkout 内仅兜底）。
# v1 业务脚本由挂载层 run_script 调用，不经 dispatcher 路由；
# 未知 alias 静默透传（fail-open）。
case "$ALIAS" in
  unified-hook)
    # SEE-1429 最终态：脚本自身相对定位（注册链直指 dev-forge 检出，无兜底分支）。
    SCRIPT="$(cd "$(dirname "$0")" && pwd)/unified/unified-hook.sh"
    ;;
  *)
    SCRIPT=""
    ;;
esac

# Script missing -> pass stdin through unchanged
if [ ! -f "$SCRIPT" ]; then
  printf '%s' "$INPUT"
  exit 0
fi

# Run the project-level hook, piping buffered stdin to it
HOOK_OUTPUT=$(printf '%s' "$INPUT" | PROJECT_ROOT="$PROJECT_ROOT" "$SCRIPT")
EXIT_CODE=$?
# SEE-1185 F5: record the hook result so the daily check can distinguish
# "no failures" from "failures invisible" (firelog previously had no outcome field)
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [result] alias=$ALIAS exit=$EXIT_CODE script=$(basename "$SCRIPT")" >> "$LOG_FILE" 2>/dev/null || true
if [ "$EXIT_CODE" -ne 0 ]; then
  printf '%s' "$INPUT"
  exit "$EXIT_CODE"
fi
# On exit 0: if hook produced hookSpecificOutput JSON, pass it through;
# otherwise pass the original stdin (passthrough)
if echo "$HOOK_OUTPUT" | grep -q '"hookSpecificOutput"'; then
  printf '%s' "$HOOK_OUTPUT"
else
  printf '%s' "$INPUT"
fi
exit 0
```

### 4.2 项目目录搜索策略

dispatcher.sh 按以下顺序搜索包含 `.claude/hooks/` 的项目根目录：

| 优先级 | 搜索路径 | 说明 |
|--------|---------|------|
| 1 | `$CLAUDE_PROJECT_DIR` | CC 自动注入的项目目录 |
| 2 | `$PWD` | 当前工作目录 |
| 3 | `$PWD/*/`（一级子目录） | 覆盖 Multica workdir 模式（repo checkout 在子目录中） |
| 4 | `TARGET_REPO_ROOT` 环境变量 | 显式注入的目标仓库根（toolchain.env / systemd EnvironmentFile）。SEE-1429 最终态：**WSL 挂载点硬编码候选已退役**（零检出路径耦合，修订 B）——此前版本曾内置 D/C 盘 GodotProjects 主仓库候选 |

**TARGET_REPO_ROOT 的关键作用**：本地会话 `$PWD` 不在项目目录内时，环境注入的目标仓库根确保 dispatcher 仍能定位宿主仓库 hooks 语义。dev-forge 仓内不含任何检出路径字面量——路径字面量只经 bootstrap 写入的 `~/.config/dev-forge/toolchain.env` 流入运行时。

### 4.3 stdin 读取的 WSL 兼容处理

WSL 环境下，CC 启动 bash 时可能附带 `--login -i`（交互式 shell），导致管道 EOF 无法正确传递到 `cat`。dispatcher 改用 `read -r -t 3` 循环读取 stdin，超时 3 秒后自动结束，避免阻塞。

```bash
# WSL-safe stdin buffering
INPUT=""
while IFS= read -r -t 3 line; do
    INPUT="${INPUT}${line}"$'\n'
done
INPUT="${INPUT%$'\n'}"
```

### 4.4 维护检查

- 修改本地 WSL 项目路径时，须同步更新 `dispatcher.sh` 中的 `WSL_CANDIDATES` 数组。
- **双副本同步**（SEE-1185 F1）：repo 内 `.dev/hooks/dispatcher.sh` 是唯一真源；任何改动先改 repo 副本，再整体同步到全局 `~/.claude/hooks/dispatcher.sh`（两份须字节一致，可用 `diff` 验证）。
- **结果日志**（SEE-1185 F5）：dispatcher 每次执行业务脚本后向 firelog 追加 `[result] alias=<alias> exit=<code> script=<name>` 行，使「没有失败」与「看不到失败」可区分；日检错误率统计应以该 result 行为准。

### 4.5 关键约束

- 用 `"$SCRIPT"` 直接执行（依赖 shebang `#!/bin/bash`），**不要**用 `bash "$SCRIPT"` 包一层
- 每一步失败都必须 fallback 透传 stdin + `exit 0`，**永不阻塞 CC**

---

## 5. Hook 脚本清单（v2 终态）

v2 单轨下「注册项」与「脚本」解耦：settings 仅 9 条 unified-hook 注册；业务脚本经 run_script 挂载规则触发（规则定义在 `unified/rules.d/runscript-mounts.json`），配置化规则在 `unified/rules-v2.json`。

> **维护条款：本表与 `unified/rules-v2.json` + `unified/rules.d/` + `hooks-registration.json` 同步更新。** 任何规则增删、挂载或通道调整，都必须同时更新规则配置与本表，二者不一致视为文档缺陷。拦截型（阻断）hook 必须在表中登记 owner，无 owner 的拦截不允许存在。

### 5.1 现役钩子清单（v2）

| 规则 / 挂载名 | 时点 | 触发（when） | 脚本/载体 | 是否阻断 | Owner |
|-------|------|---------|------|----------|-------|
| `push-guard-mount` | PreToolUse | tool Bash（push 深语义在脚本内） | `push-guard.sh` | **是**（deny_exit_codes[2] → 引擎转 deny JSON；v1 为 exit 2+stderr，语义等价迁移） | Atlas（工作流规范，SEE-1035 系） |
| `tscn-tres-guard`（rules-v2） | PreToolUse | tool Write\|Edit × file *.tscn/*.tres | 配置化（context 文案内置） | 否（additionalContext 提醒） | Bachi（场景文件安全） |
| `mention-check-mount` | PreToolUse | tool Bash + command `multica issue comment add`；agents except [Chekky] | `mention-check.sh` | **是**（permissionDecision=deny） | Atlas（评论 mention 规范，SEE-1053 系） |
| skill-check block 规则 ×4（rules-v2） | PreToolUse | agents include × not used_skill；one_shot{scope:run} | 配置化（deny 文案内置） | **是**（规则命中时 permissionDecision=deny） | Atlas（规则引擎，逐规则 owner 同规则 agents 维度） |
| skill-check remind 规则 ×4（rules-v2，含 recall-reminder） | PreToolUse | agents include / 无 agents（全匹配）；one_shot{scope:run} | 配置化（context 文案内置） | 否（additionalContext） | Atlas（规则引擎） |
| `mention-confirm-check`（rules-v2） | PreToolUse | command `multica issue comment add` × content 提及正则；one_shot{scope:run} | 配置化（deny 文案内置） | **是**（permissionDecision=deny，SEE-1388 SPEC-005 修正：此前误登为提醒） | Atlas（评论 mention 自查规则，SEE-1151 系） |
| `child-issue-guard`（rules-v2，SEE-1388 SPEC-005 补登） | PreToolUse | command `multica issue (create\|update)` × has_flag --parent | 配置化（deny 文案内置） | **是**（permissionDecision=deny） | Atlas（单 issue 任务纪律，SEE-747 系） |
| `grepai-search-reminder`（rules-v2，SEE-1388 SPEC-005 补登） | PostToolUse | command grep/rg/ag/ack 或 tool Grep | 配置化（context 文案内置） | 否（additionalContext） | Atlas（grepai 语义检索引导，SEE-1238 系） |
| `atlas-taskflow-mark-a-mount` | PostToolUse | tool Skill（脚本内 taskflow 判定） | `atlas-taskflow-mark-a.sh` | 否（写 /taskflow 状态标记） | Atlas |
| `atlas-taskflow-mark-b-mount` | PostToolUse | tool Bash（脚本内 issue create 判定） | `atlas-taskflow-mark-b.sh` | 否（写状态标记） | Atlas |
| `atlas-taskflow-exit-reminder-mount` | PreToolUse | tool Bash（脚本内 comment add 判定；仅 Atlas 生效） | `atlas-taskflow-exit-reminder.sh` | 条件阻断（对新建任务 issue 评论时 deny） | Atlas（/taskflow 编排闭环） |
| `gdformat-gdlint-mount` | PostToolUse | tool Write\|Edit × file *.gd | `gdformat-gdlint.sh` | **是**（exit 2 + stderr 直通，fail-close；含 SEE-1142 mcp-mouse-lint 追加规则） | Bachi（GDScript 代码质量） |
| `auto-pr-stop-mount` | Stop | payload stop_hook_active equals false（+ 脚本内第二道防线） | `auto-pr-on-stop.sh` | 否（自动 commit/push/draft PR；恒 fail-open 不阻塞 Stop） | Bachi（SEE-1129 活跃维护） |
| `repo-checkout-mount` | SessionStart | payload hook_event_name equals SessionStart | `repo-checkout.sh` | 否（session 启动自动 checkout 工作分支，additionalContext hint） | Bachi（SEE-1117 活跃维护） |

说明：

- skill-check 拦截/提醒语义现由 rules-v2.json 配置化承载（§6 为 v2 when 树说明）；原 `pre-comment-skill-check.sh` 脚本与 `skill-check-rules.json` 已退役（S22 终审裁定物理删除，见迁移清单 §7.2）。
- `atlas-taskflow-*` 三个钩子仅对 `MULTICA_AGENT_NAME=Atlas` 生效（规则 agents 顶层限定），配合 /taskflow 编排闭环使用。
- `gdformat-gdlint` 的 SEE-1142 mcp-mouse-lint 追加规则实现在 `.dev/scripts/mcp-mouse-lint.sh`，通过 `PROJECT_ROOT` 定位。
- 非 hook 挂载脚本：`mcp-tool-presence.sh`（被 repo-checkout.sh 从属调用，godot-mcp 工具审计）、`godot-mcp-launch-path.lib.sh`（source 库）——均保留原位；`reconcile-working-branch.sh`（Leader 手动调用，处理 shared working branch auto-rebase 冲突）已随 SEE-1388 §SPEC-013 归位 `.dev/scripts/`（非 hook 工具，退出 hooks 部署清单）。

### 5.2 已退役钩子（勿再引用）

以下在 v2 收敛中退役；物理删除裁定见迁移对照清单 §7.2（执行归属 Atlas 收尾批）：

| 对象 | 退役背景 |
|-------|----------|
| `rebase`（alias + 脚本） | 首次工作前自动 rebase；SEE-1185 F1 清理 |
| `revy-testing-reminder`（独立脚本，v1） | 职责并入规则引擎；v2 中为 rules-v2.json 配置化规则 |
| `mem-search-context`（v1） | 已删（/mem-search 上下文注入） |
| `doc-reminder`（独立脚本，v1） | 已删；同名规则曾以 `enabled: false` 形态保留于 rules-v2.json，SEE-1388 SPEC-004（fingerprint b9361f0c8695）按死规则裁定物理删除 |
| `pre-comment-skill-check.sh` + `skill-check-rules.json`（v1） | 14 条规则配置化入 rules-v2.json 后退役；P4 部署面下线，仓库文件待物理删除 |
| `tscn-tres-guard.sh`（v1 脚本） | 规则配置化入 rules-v2.json（文案 verbatim 保真）后退役；P4 部署面下线，仓库文件待物理删除 |
| desugar.js / engine v1 兼容层（desugar 双读 + v1_compat 键） | P4 收敛删除（S18） |

> v1→v2 迁移逐规则等价依据见 `.dev/docs/claude/hooks-v2-migration-map.md`（§6.1 逐规则对照 + 六轮 QA 核验记录）。

---

## 6. skill-check 规则（v2 when 树）

v2 下 skill-check 语义由统一引擎承载：规则声明在 `unified/rules-v2.json`，求值链 = `on`（时点）→ `agents`（include/except 顶层白名单）→ `when`（op 树，缺省恒真）→ `one_shot{scope}`（per-run 幂等 sentinel）→ `action`（deny / context）。

### 6.1 when 词表（v2）

| op | 语义 | 示例 |
|------|------|------|
| `tool` | tool_name 匹配（`in` 多值） | `{"op":"tool","in":["Bash"]}` |
| `file` | file_path glob 匹配（`patterns` 多值） | `{"op":"file","patterns":["*.gd"]}` |
| `command` | Bash 命令段匹配（`scope:current` + `keyword`/`pattern`，`has_flag`） | `{"op":"command","scope":"current","keyword":"multica issue comment add"}` |
| `content` | 正文内容正则匹配（--content-file→--content→tool_input.content 链） | `{"op":"content","pattern":"..."}` |
| `payload` | 载荷字段读取（单值 `equals`/`isSet`） | `{"op":"payload","path":"stop_hook_active","equals":false}` |
| `branch` | 当前分支匹配（`in` 多值，可 `not` 包裹） | `{"op":"branch","in":["main","master"]}` |
| `used_skill` | 会话已用 skill 判定 | `{"op":"used_skill","in":["doc-edit"]}` |
| 逻辑组合 | `all` / `any` / `not`（args 递归） | `{"op":"not","arg":{...}}` |

> 语义钉（S17 裁定）：payload op 仅支持单值 equals/isSet，多值匹配不支持、靠 `on.in` 兜底。完整词表与求值语义见 SEE-1329 定稿计划 `hook-framework-plan.md`。

### 6.2 与 v1 bash_executed 算子的对照

v1 `pre-comment-skill-check.sh` 的 `bash_executed`（`keyword`/`pattern`/`command`/`exclude` 参数，含 heredoc/数据区段误匹配问题与 SEE-663 精确化）在 v2 中由 `command` op 等价承载：`scope:current` 限定当前调用命令段、`keyword`/`pattern` 匹配参数区段、命令名锚定由 op 实现内建。逐规则翻译对照见迁移清单 §6.1（13 条规则逐条等价结论）。

**v1 历史参考（已退役）**：v1 规则文件 `skill-check-rules.json` 的 `used` / `bash_executed` / `and`/`or`/`not` 算子说明、`command`/`exclude` 参数行为（SEE-663）、keyword vs command 对比表——见本文档历史版本（git log `6aa2c1bd`），此处不再展开。
## 7. hookSpecificOutput JSON 输出规范

### 7.1 基本格式

所有通过 hook 向 agent 注入上下文的脚本，stdout **仅**输出以下 JSON（不再透传原始 stdin）：

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "注入给 agent 的上下文内容"
  }
}
```

### 7.2 hookEventName 为必需字段

| 字段 | 说明 |
|------|------|
| `hookEventName` | **必须**。值为当前触发的事件名（`PreToolUse` / `PostToolUse` / `Stop` / `SessionStart` 等）。若缺少此字段，CC 会丢弃整个输出，agent 看不到注入内容。 |
| `additionalContext` | 注入到 agent 上下文中的文本内容。支持 `\n` 换行。 |

### 7.3 与旧模式的对比

| 模式 | 实现方式 | 状态 |
|------|---------|------|
| **hookSpecificOutput JSON（推荐）** | `printf '{"hookSpecificOutput":...}'` | 当前标准 |
| stderr + exit 2（已废弃） | `echo msg >&2; exit 2` | WSL 下不稳定，不再使用 |
| stdin 透传 + 附加内容（已废弃） | `printf '%s' "$INPUT"; echo msg` | 导致重复/无效内容 |

---

## 8. 常见坑点

### 8.1 坑点速查表

| 坑点 | 现象 | 解决方式 |
|------|------|----------|
| **JSON 转义陷阱** | `uid="uid://..."` 等含转义引号的内容用双引号字符串赋值会破坏 JSON 结构 | 用单引号包裹 HOOK_MSG：`export HOOK_MSG='...'` |
| **hookEventName 缺失** | hook 触发但 agent 上下文看不到内容 | 必须包含 `hookEventName` 字段，值与当前事件匹配 |
| **stderr exit 2 不可靠** | PostToolUse 用 stderr 输出 context，在 WSL 环境下不稳定 | 统一改用 hookSpecificOutput JSON |
| **node 依赖问题** | 用 node 解析 stdin JSON 使脚本变重，且增加外部依赖 | 改用 `sed`/`printf` 纯 bash 实现 |
| **stdin 透传重复** | 旧实现透传原始 stdin + 附加内容，导致重复/无效内容 | 仅输出 hookSpecificOutput JSON，不再透传 stdin |
| **WSL read 阻塞** | 交互式 bash 下 `cat` 读取 stdin 无法获取 EOF，hook 卡住 | 改用 `read -r -t 3` 带超时读取 |
| **UserPromptSubmit 不支持 additionalContext** | hook 触发但 agent 收不到注入的上下文 | CC 仅对 PreToolUse/PostToolUse 处理 hookSpecificOutput.additionalContext，UserPromptSubmit 忽略此字段。如需注入上下文，应使用 PreToolUse + sentinel 模式 |

### 8.2 详细说明

#### JSON 转义陷阱

**错误示例**（双引号包裹，bash 会解析 `\"`）：

```bash
# BAD：bash 将 \" 解析为字面量 \"，JSON 结构被破坏
export HOOK_MSG="uid=\"uid://xxx\""
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}' "$HOOK_MSG"
# 实际输出：{"additionalContext":"uid=\"uid://xxx\""} → JSON 解析失败
```

**正确示例**（单引号包裹，bash 不解析内部内容）：

```bash
# GOOD：单引号内所有内容原样保留
export HOOK_MSG='uid="uid://xxx"'
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"'"$HOOK_MSG"'"}}'
# 实际输出：{"additionalContext":"uid=\"uid://xxx\""} → 合法 JSON
```

#### hookEventName 缺失

**错误示例**：

```bash
# BAD：缺少 hookEventName
printf '{"hookSpecificOutput":{"additionalContext":"hello"}}'
```

**正确示例**：

```bash
# GOOD：包含 hookEventName
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"hello"}}'
```

#### WSL read 阻塞

WSL 下 CC 启动 bash 可能附带 `--login -i`，交互式 shell 不会正确传递管道 EOF。`cat` 会永远等待输入。

**错误示例**：

```bash
# BAD：在 WSL 下可能永远阻塞
INPUT=$(cat)
```

**正确示例**：

```bash
# GOOD：3 秒超时自动结束
INPUT=""
while IFS= read -r -t 3 line; do
    INPUT="${INPUT}${line}"$'\n'
done
INPUT="${INPUT%$'\n'}"
```

---

*文档版本：2026-09-20（SEE-1330 v2 单轨架构终态）*
*更新记录：SEE-1330 S22 终审 — 全文按 v2 终态重写：§1 调用链改为「wrapper → dispatcher（仅 unified-hook，全局优先）→ unified-hook.sh → engine.js 配置驱动 / run_script 挂载」；§2.1 配置快照改为 9 时点 × matcher `*` 统一注册 + 声明式注册真源（hooks-registration.json），新增 §2.3 规则配置真源；§4.1 dispatcher 代码更新为单 alias case；§5 清单改挂载/规则视角（规则配置与挂载 lane 为同步对象），§5.2 退役清单含 v1 死文件（待物理删除裁定见迁移清单 §7.2）；§6 重写为 v2 when 词表（v1 bash_executed 算子历史参考降级）*
*更新记录：SEE-1185 F2 — §5 清单表按全局 settings.json 实际 11 个注册项重写（六列含是否阻断/owner），清除 rebase / revy-testing-reminder / mem-search-context / doc-reminder 四个已删钩子残留；补入 mention-check / skill-check(-post) / atlas-taskflow-\* 现役钩子；附「本表与 settings.json 同步更新」维护条款。§2.1 配置示例、§4.1 dispatcher 代码、§4.2 搜索顺序、§4.4 维护条款同步对齐 F1（rebase 死路由清理、双副本以 repo 为真源）与 F4（约定式路由）改动*
*更新记录：SEE-781 firelog 路径从全局 `~/.claude/hook-fire.log` 改为仓库级 `.claude/hook-fire.log`（hook-wrapper.sh 动态检测 + dispatcher.sh 复用 PROJECT_ROOT），非仓库场景回退全局路径*
*更新记录：SEE-663 新增 skill-check 条件算子文档（bash_executed 的 command/exclude 参数）*
*历史记录：SEE-282 钩子修复经验沉淀 — 新增 hookSpecificOutput 规范、常见坑点章节（revy-testing-reminder 独立脚本已下线，见 §5.2）*
