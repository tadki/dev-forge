# Harness Console 前端方案（forge-console）

> 状态：**已实施（M0+M1）**。实施记录见文末「实施状态」；代码在 [`console/`](../console/)（`console/README.md` 为运行手册）。
> 摸底基准日 2026-11-02，全部事实来自当日对本机（WSL 105）的实盘扫描。
> 交付目标：一套监控整个自建 harness 体系的 Web 前端 —— Agent 构成 / 指令（系统提示、CLAUDE.md）/ hooks / skills / 自启动服务 / autopilots 一屏可见；并作为 harness 向 multica（及未来其他平台）迁移的投影与导出基座。

---

## 0. 一句话结论

**四层解耦架构：采集器（Collectors）→ 标准资产模型（Forge Asset）→ 只读 API → Web UI。**
所有 harness 内容被规范化为同一种 JSON 资产；新增一个监控域 = 新增一个采集器（内置模块 / 丢脚本 / REST 推送三选一），UI 零改动。迁移 = 对同一份资产做"平台投影"，生成 dry-run 差异与可评审的执行脚本，绝不自动应用。

---

## 1. 目标与非目标

**目标**

1. **一眼看懂**：不查源码就能回答"我的 harness 里有什么、挂在哪、谁在跑、健康吗"。
2. **无缝迁移**：资产级平台映射（Claude Code ↔ multica），可导出迁移包、可看差距。
3. **解耦 everything**：采集、存储、API、UI 四层互不依赖；每个域一个采集器；规范格式接入 + 兜底（自定义脚本、REST 推送、通用渲染器）。
4. **复用既有数据**：dev-forge 已经是数据驱动（rules JSON、repos.d、toolchain-reports），console 只做消费与补采，不重造引擎。

**边界定义（什么是"我们的 harness"）**：主清单只收**自建 infra**（`provenance: first-party`）——我们随 multica 与 Claude Code 两个 runtime 自建的钩子/规则/脚本/autopilot/adapter/服务/指令/技能定义/接线配置。平台自带与第三方内容（ECC 插件技能 34 个、`~/.claude/rules/` 第三方规则包、claude-mem 等）标 `provenance: third-party` 归入**依赖架（dependency shelf）**：仍然采集（它们真实影响 effective harness——rules 包此刻就注入在每个会话里），但不进主清单、不参与迁移导出、UI 默认折叠。**自建配置作用于第三方组件，配置本身算自建**（如 `ECC_DISABLED_HOOKS` 禁用清单、enabledPlugins 开关）；multica 侧 owner=jerry 的 agent/skill 定义虽存于平台，也是自建。

**非目标（首期）**

- 不做写操作（改规则、重启服务、应用迁移）——只读优先，动作留到 M3 且显式 opt-in。
- 不接管 multica 服务端、不代理其前端，只读其 CLI/API 数据。
- 不监控 Mac mini 上的远端服务内部（Hindsight、multica server 仅探测健康端点）；Windows 侧 harness（`C:\Users\Jerry\.claude\{ecc,skills,...}`，由 KOL 系项目 additionalDirectories 引用）首期只登记存在性，不做采集。

---

## 2. 摸底结论（资产宇宙总图）

### 2.1 体系全貌

```
Windows 登录 ──► wsl-keepalive（保活）/ multica-daemon（旧桥，已被 systemd 取代）
systemd(system) toolchain-start-all.service
 ├─ repo-sync ×3（repos.d/{devforge,gqt,kol}.json → repo_sync_daemon.py）
 └─ multica daemon（exec 前台；每个任务 spawn multica-claude → claude -p headless）
systemd(user) grepai-watch.service / grepai-watch-devforge.service（嵌入索引 → Mac Postgres:5435）
Claude Code 会话（人机 + multica 派生）
 ├─ hooks：9 挂载点 → dev-forge hook-wrapper.sh → dispatcher → engine.js（rules-v2 + rules.d）
 │         + hindsight 旁挂 3 挂载点（SessionStart/Stop/UserPromptSubmit）
 ├─ MCP：mcp-search（全局 .mcp.json）、godot-mcp（项目级）、aseprite-mcp、hindsight-mcp-remote（adapter）
 └─ skills / rules / commands / teams（~/.claude + 项目 .claude/）
multica 平台（server @ Mac mini 192.168.1.210:9278）
 ├─ agents ×8（Atlas/Archi/Bachi/Fronti/Revy/Harti/Refacty/Chekky，服务端 JSON 定义）
 ├─ squads、autopilots（cron trigger，dev-forge autopilots 的调度方）、tasks
 └─ 本机工作区 ~/multica_workspaces（seed-*/see-*/workdir，daemon 物化 CLAUDE.md 前导 + skills）
```

### 2.2 资产清单（采集源对照表）

| 域 | 内容（当日实况） | 来源（机器可读?） |
|---|---|---|
| **Agent（multica）** | 8 个，字段 instructions/model/thinking-level/mcp_config/custom_env/custom_args/runtime_id/max_concurrent_tasks | `multica agent list --json`（服务端） |
| **Agent（CC subagent）** | 全局 agents/ 空；仅 grepai 项目有 deep-explore | `~/.claude/agents/`、`<proj>/.claude/agents/`（md+frontmatter） |
| **指令** | 5 份独立 CLAUDE.md（KOL 144 行 / s5recheck 157 行含 Harti / grepai 172 行英文 / godot-qa-toolkit 15 行 / see1410 28 行）；**3 份逐字节副本、主检出与 worktree 版规则矛盾**；全局 CLAUDE.md 不存在 | 文件系统 |
| **指令（平台侧）** | multica agent.instructions + daemon 物化的 workdir/CLAUDE.md（`MULTICA-RUNTIME auto-managed` 前导） | multica API + workdir 抽样 |
| **Rules（行为规则）** | `~/.claude/rules/`：common 10 篇 + zh 镜像 + 17 语言目录 + web | 文件系统 |
| **Hooks 注册** | 9 挂载点 × `hook-wrapper.sh <Event> unified-hook` + hindsight 3 挂载点 | `~/.claude/settings.json`、`bootstrap/hooks-registration.json` |
| **Hooks 规则** | rules-v2.json 12 条 + rules.d 2 条 + 8 个 run_script 挂载；schema：on/agents/one_shot/when(7 原子 op+3 组合器)/action(deny/context/modify/run_script) | `claude-hooks/unified/*.json` ✅ |
| **Hooks 脚本** | scripts/ 11 个业务脚本 + lib/ 4 个；state/ 2743 个 one-shot 哨兵；firelog（repo 级优先，全局兜底，10MiB 轮转） | 文件系统 + 运行态 |
| **Skills** | 全局 6（hindsight-coding-agent/recall/review-md/revy-testing/taskassign/learned）+ ECC `.agents/skills/` 34 + grepai 项目 2 + multica 平台 skills（code-review/recall/multica-cli/multica-platform…，运行时物化进 workdir） | 目录扫描 + multica API |
| **服务** | systemd system 1 + user 2、Windows 桥 2、常驻树（multica daemon + repo-sync ×3）、每会话 MCP 子进程 | `systemctl`/`ps`/unit 文件/`/mnt/c` 脚本 |
| **Autopilots** | 脚本型 5（agent_watchdog 25ba8a6f / issue_status_check 2dd8fa65 / architecture_sweep 5a40f7e4 / version_check / guard_pending）+ agent 评审型 2（Refacty 半周检 / Archi 周检）；**调度全在 multica 平台 cron trigger** | 脚本 + `docs/autopilots.md` + multica API |
| **Adapters** | hindsight-mcp.sh / hindsight-mcp-remote.py / upgrade-multica-selfhost.sh / workspace-env-check.sh（env 契约式配置） | 文件系统（需静态解析 env） |
| **repo-sync** | repos.d 3 仓注册（name/repo_path/remote/branch/lock_file…） | `repo-sync/repos.d/*.json` ✅ |
| **健康报告** | `toolchain_daily_check.py` 6 维度日检 → `~/.multica/toolchain-reports/{latest,history}.json`（GREEN/REDLINE）；`~/.multica/arch-patrol/last_report.json` | **现成 JSON，直接消费** |
| **MCP** | mcp-search（全局）、godot-mcp（KOL 系项目）、per-agent multica mcp_config | `.mcp.json` × N + multica API |
| **环境/权限** | settings.json：26 项 env（含 LiteLLM 模型映射、**GitHub PAT 需脱敏**）、permissions 9 allow / 2 deny、enabledPlugins（ECC on，官方 8 + hindsight off） | `~/.claude/settings.json` |
| **Teams** | teams/gameflow-dev（team-lead + backend×2 + frontend + tester，cwd 指向 Windows 侧） | `~/.claude/teams/` |

### 2.3 三个关键事实（决定架构）

1. **multica 的 runtime 就是 Claude Code**（`claude -p --permission-mode bypassPermissions --strict-mcp-config --mcp-config …`）。迁移不是换运行时，而是把 CLAUDE.md/hooks/skills 内容**上移为平台对象**。全局 `~/.claude/settings.json` 的 hooks 在 multica 会话里目前依然生效（双轨共存）。
2. **约一半资产已是 JSON 数据**（rules、repos.d、registration manifest、toolchain-reports、multica API），另一半散在 markdown/脚本常量/平台侧调度里。console 的采集器就是"把另一半也变成数据"。
3. **同名资产存在版本漂移**（KOL 家族 CLAUDE.md：3 份 md5 相同、2 份演化分叉、规则互相矛盾）。聚合必须按路径而非按名，漂移检测是一等公民功能。

---

## 3. 总体架构

```
┌─ 采集层 ────────────┐   ┌─ 规范层 ────────┐   ┌─ 服务层 ────────┐   ┌─ 展示层 ────────┐
│ builtin collectors  │   │                 │   │                 │   │                 │
│  (TS 模块,每域一个)  │──►│  Forge Asset    │──►│  Registry API   │──►│  Web UI (React) │
│ external collectors │   │  (forge-asset/1 │   │  (Fastify 只读  │   │  KOL Neo-Brutal │
│  (collectors.d/*)   │   │   JSON Schema)  │   │   + SSE)        │   │  design system  │
│ REST push (兜底)    │   │                 │   │                 │   │                 │
└─────────────────────┘   └─────────────────┘   └─────────────────┘   └─────────────────┘
        任意语言/任意格式          唯一契约                单向依赖                只认 API
```

**解耦原则**

- 采集器只做"读源 → 吐标准 JSON"，彼此独立、可单独禁用、可并行执行；一个采集器崩溃不影响其余（诊断信息进 diagnostics，不进资产流）。
- Registry 不认识任何域，只认识 Asset schema：校验、合并、去重、漂移分组、脱敏、快照。
- API 不知道资产从哪来；UI 不知道采集器存在。未知 kind 自动落到通用渲染器（兜底展示，永不白屏）。
- 新监控域的接入成本 = 一个采集器（≈100 行），无任何其他层改动。

**代码位置**：`dev-forge/console/`（pnpm monorepo）。理由：README 既定原则"single source of truth——编辑即生效，无部署复制"；console 监控 dev-forge 自身，同仓自举。目录：

```
console/
├─ package.json / pnpm-workspace.yaml
├─ packages/
│  ├─ schema/        # forge-asset/1 的 TS 类型 + JSON Schema + zod 校验
│  ├─ collectors/    # 内置采集器（src/collectors/<domain>.ts）
│  └─ server/        # Fastify：registry、查询 API、SSE、静态托管 web 产物
├─ apps/web/         # Vite + React + TS，纯自定义设计系统（无组件库）
├─ collectors.d/     # 外部采集器投放目录（可执行文件，stdout 吐契约 JSON）
├─ console.config.yaml
└─ tests/            # vitest（golden fixtures）+ 并入 tests/run_all.sh
```

技术栈理由：Node/TS 单语言贯穿 schema/server/UI（与 engine.js 同生态）；Fastify 轻量、类型共享；Vite+React 无组件库——KOL 形制是强定制 CSS，组件库只会帮倒忙。

---

## 4. 数据模型：Forge Asset 规范（`forge-asset/1`）

一切 harness 内容规范化为 **Asset（资产）** 与 **Relation（关系）**。契约文件随仓库发布（`packages/schema/asset.schema.json`），外部采集器据此自校验。

```jsonc
// 采集器输出（stdout，单 JSON 文档或 NDJSON）
{
  "collector": "devforge-hooks",
  "collectedAt": "2026-11-02T04:00:00+08:00",
  "assets": [ /* Asset[] */ ],
  "relations": [ /* Relation[] */ ],
  "diagnostics": [ { "level": "warn", "message": "…", "path": "…" } ]
}

// Asset
{
  "id": "hook-rule:push-guard/main-push",        // <kind>:<域内稳定键>
  "kind": "hook-rule",                            // 见 kind 表
  "name": "main-push 禁令",
  "summary": "禁止直推 main/master（push-guard-gates #1）",
  "attach": { "level": "workspace", "ref": "kol" },  // 挂载点：user | workspace | project | agent | platform（§4.1）
  "applies": {                                        // 生效域细化；缺省 = 自挂载点向下全量继承
    "agents": { "include": ["fronti", "revy"] },      // 仅当该轴对该 kind 可配置（§4.1 矩阵）
    "origin": "native"                                // native=原生机制强制 | overlay=.forge.yaml 约定登记
  },
  "enforcement": "enforced",                          // enforced | advisory | derived（强制力，§4.1）
  "platforms": ["claude-code", "multica"],        // 该资产当前生效的平台
  "provenance": "first-party",                    // first-party（自建）| third-party（第三方/平台自带 → 依赖架）
  "tags": ["blocking", "git", "deny"],
  "owner": "jerry",
  "enabled": true,
  "source": {                                      // 溯源——"不用查源码"的底气
    "collector": "devforge-hooks",
    "path": "/home/jerry/tools/dev-forge/claude-hooks/unified/rules.d/push-guard-gates.json",
    "locator": "$.rules[0]",
    "sha256": "…", "mtime": "…",
    "git": { "repo": "…/dev-forge", "rev": "b68c10c" }
  },
  "payload": { /* kind 专属，见下表 */ }
}

// Relation
{ "from": "hook-script:auto-pr-on-stop", "to": "autopilot:…",
  "type": "schedules" }   // mounts | references | schedules | runs-as | derived-from | gates
```

**kind 一览（payload 要点）**

| kind | payload 关键字段 | 首批来源 |
|---|---|---|
| `agent` | instructions(md)、model、thinkingLevel、mcpServers[]、customEnv、runtime、concurrency、status | multica API、`.claude/agents/*.md` |
| `instruction` | content(md)、lang、headings[]、lines、contentHash、copies[]（同 hash 副本=漂移组） | CLAUDE.md × N、rules/*.md、multica instructions |
| `skill` | description、triggers[]、body(md)、references[]、platformSkill(bool) | skills 目录、multica skill |
| `hook-registration` | hookPoints[]、entry、matcher | settings.json、hooks-registration.json |
| `hook-rule` | on、agents 门控、oneShot、when(op 树原文+人话摘要)、actions[]、enabled | rules JSON |
| `hook-script` | purpose、timeout、onFail、mounts[]（被哪些规则挂载）、lastFired | scripts/ + firelog |
| `service` | unitPath、trigger(boot\|login\|timer\|event)、execStart、environmentFile、status(live)、children[]、logPath | systemd、Windows 桥、daemon 进程树 |
| `autopilot` | script、schedule(cron+triggerId)、agent、lastRun、lastReport(json)、killSwitch、ledgerPath | autopilots/ + multica API + arch-patrol |
| `adapter` | target、envContract[]、purpose | adapters/ |
| `mcp-endpoint` | transport、command、scope、perAgent(bool)——**客户端接线配置**（server 实现多在 Mac，属远程 infra，仅健康探测不进资产） | .mcp.json × N、multica mcp_config |
| `project` | path、git、claudeMd、settings、hooks[]、skills[]、repoSync 注册 | 项目扫描 |
| `report` | schemaVersion、health(GREEN/REDLINE)、dimensions、findings、generatedAt | toolchain-reports、arch-patrol |
| `env` | key、valueRedacted、effect | settings.json env（**只存脱敏值**） |
| `custom` | 任意（通用渲染器兜底） | collectors.d / REST push |

### 4.1 作用域模型（scope lattice）

**五层轴**：`User`（本机全局）→ `Workspace`（产品域）→ `Project`（仓库检出/worktree）→ `Agent` → `Session/Task`（运行态）。

每个资产在每个轴上的格子取四值之一——回答"这一层作用域对该资产是可配的、派生的、还是无意义的"：

| 符号 | 语义 | 判据 |
|---|---|---|
| ● | 可配置·强制 | 运行时真会按它门控（有原生机制背书） |
| ◐ | 可配置·仅约定 | 只能记元数据，运行时不强制（对文档/迁移仍有价值；经 `.forge.yaml` overlay 登记，`origin: overlay`） |
| ◇ | 派生 | 作用域=文件位置或宿主关系，"放置即配置"，UI 不提供配置入口 |
| — | 无意义 | 对该资产类型此轴是无效设置 |

**全量矩阵（kind × 轴）**

| 资产 | 挂载默认 | Workspace | Project | Agent | Session |
|---|---|---|---|---|---|
| multica agent（本体） | platform | ◐ 住宿 residence（分组/上卷用，不门控） | — | 本体 | 实例（任务中） |
| agent.instructions | agent | ◐ | — | ◇ 位置即作用域（跟 agent 走） | 合成实例 |
| CC subagent 定义 | user/project | ◇ 随目录派生 | ◇ 位置（`.claude/agents/`） | 本体 | 实例 |
| CLAUDE.md | project | ◇ 派生（workspace 分组） | ◇ 位置即作用域 | —（对在此工作的**所有** agent 生效） | 合成实例（multica 前导拼接） |
| rules/*.md（第三方规则包 → 依赖架） | user | —（CC 现全量注入） | —（机制限制，如实标注） | — | 注入 |
| skill | user / project / platform | ● multica 平台分配；CC ◐ | ●/◇ 位置或平台分配 | ● multica `agent skills`；CC ◐ 约定 | 物化实例（workdir） |
| hook 注册 | user/project | — | ◇（`.claude/hooks/` 位置） | — | 触发点 |
| hook 规则 | user（dev-forge JSON） | ◇ `when.file` 路径间接圈定 | ● `when.file/command` | ● `agents.include/except` | ● `one_shot` 窗口 |
| hook 脚本 | user | ◇ 随挂载规则派生 | ◇ | ◇ | 执行实例 |
| service | machine/user | ◐ 组织元数据（健康上卷分组） | ●（repo-sync 一仓一守护） | — | 进程实例 |
| autopilot | platform:multica 原生调度（第二平台出现前不做跨平台抽象）+ user 脚本 | ◇ 派生自 target | ● `configs/*.json` target | ● runs-as | run 实例 |
| adapter | user | ◐ | ◐（workspace-env-check 按任务） | — | 调用实例 |
| MCP server | 四档皆可 | ◇ | ● `.mcp.json` | ● per-agent `mcp_config` | ● 注入文件实例（`/tmp/multica-mcp-*`） |
| env | user/agent/service | — | — | ● `custom_env` | 合并实例 |
| team / squad（存量≈0 → 暂缓采集，kind 降可选） | user/platform | ◐ | ◐（cwd 指向） | 本体即 agent 分组 | — |
| report / ledger | 派生自生产者 | ◇ | ◇ | ◇ | 产出实例 |

**六条不变量**

1. **挂载 ≠ 生效**：`attach`（定义在哪）与 `applies`（细化到哪）分离，两层都展示。活例：dev-forge 的 hook 规则物理住在 dev-forge 这个 project（`attach.level: project`），语义上是 user 全局（经绝对路径注册）。
2. **位置型资产没有作用域配置**：CLAUDE.md、`.mcp.json`、subagent 目录——作用域就是文件位置；UI 只显示派生结果，不给下拉框（配了也是假配置）。
3. **● 与 ◐ 必须分栏标注**：如"此 skill 给 Revy"在 multica 是强分配、在 CC 会话无人强制——Console 诚实显示强制力，避免"设了就生效"的错觉；◐ 型经 `.forge.yaml` 登记（`origin: overlay`）。
4. **Agent 的 workspace 关系是「住宿」（residence），不是作用域**：Fronti 住宿 KOL 域，但可被派去任何 project；residence 只用于分组、健康上卷、迁移建议，永不门控。
5. **Session/Task 层是「实例」不是「资产」**：multica 物化的 workdir CLAUDE.md、`/tmp` mcp-config、one-shot 哨兵都是资产的运行态投影，作为实例挂在资产详情下，不进资产列表。
6. **命名消歧**：本层 Workspace（产品域）≠ multica 的 task workspace（= Session 层）；grepai `--workspace kol` 与本层对齐。Workspace 不是多数数据源的原生概念，故引入 **workspace 注册表**（见下），KOL 家族 CLAUDE.md 漂移检测因此成为"workspace 内跨 project 对比"。

**Workspace 注册表**（`console.config.yaml`，声明 + 自动建议 + Owner 确认）：

```yaml
workspaces:
  - id: kol
    name: King of Likes
    projects:                       # 成员 project（路径）
      - /mnt/d/GodotProjects/king-of-likes
      - /home/jerry/s5recheck-worktree
      - /mnt/d/GodotProjects/see1089-qa
    residents: [fronti, revy, harti, archi, bachi, refacty, chekky]   # 住宿 agent
    services: [grepai-watch]        # 健康上卷分组
  - id: devforge
    projects: [/home/jerry/tools/dev-forge]
```

自动建议规则：git remote 同源 / worktree 亲缘 → 聚为一族；repo-sync `repos.d` 与 grepai `--workspace` 作为既有信号。M2 起 UI 内确认归属并回写 config。

**Effective Harness 合并语义**（沿轴就近、按 kind 定则）：instructions = **拼接**（multica 前导 + agent.instructions + 项目 CLAUDE.md）；skills/MCP = **并集**；model/env = **就近覆盖**（agent > project > workspace > user）。

### 4.2 hook 规则：条件语言的作用域投影（不重构引擎）

hook 引擎已有一套比五层格**更细**的作用域 DSL（`on` / `agents` / `one_shot.ids` / `when` 条件树）。结论：**编写权留在 rules JSON，console 只做投影展示**——把引擎字段单向翻译成 §4.1 的格子，不在 console 里另造一套作用域配置。

| 引擎字段（实测 rules-v2.json / rules.d） | 投影到 | 强制力 |
|---|---|---|
| `on.in / on.except` | 事件维（9 挂载点中的哪几个） | ● |
| `agents.include / except` | **Agent 轴**（经 `MULTICA_AGENT_NAME` 门控；12 条规则中 9 条在用） | ● |
| `one_shot.ids`（env 元组笛卡尔积） | **Session 轴窗口粒度**：`[MULTICA_AGENT_NAME, HOOK_ISSUE_ID]` = 每 issue×agent 一次；`[MULTICA_AGENT_NAME, HOOK_RUN_SCOPE_ID]` = 每 run×agent 一次 | ● |
| `when.file patterns` | Project 轴（运行时按事件内文件路径求值，如 `*.tscn/*.tres`） | ● |
| `when.command / tool / content / used_skill / branch` | **内容条件，不进作用域格**——展示为触发条件，不硬塞 lattice | ●（条件 ≠ 作用域） |
| 规则 `description` 里的适用性声明（如 push-guard-gates 写"三库 KOL/GQT/dev-forge 适用"） | ◐ 约定作用域 | 无强制——console 专门标注 |

**「声明 vs 强制」偏差提示是一等公民功能**：活例——push-guard-gates 的 description 声明"三库适用"，但其 `when` 条件**不判仓库**，实际对任何仓库的 main/master push 都拦。console 把这类"description 说的"与"条件实际强制的"差异亮出来，比急着重构引擎更有价值。若确需仓库级强制门控，扩展点是给引擎新增 `repo` 条件 op（M3 可选评估），而非 console 侧作用域。

**hook 注册的挂载层级（实况）**：CC 侧全部注册在 **user 层**（`~/.claude/settings.json` 9 挂载点 → dev-forge wrapper + hindsight 旁挂 3 点）；multica **无原生 hook 机制**，靠同一 user 层注册在 multica 派生的 headless claude 会话里继续生效；项目级 `.claude/hooks/` 脚本由 dispatcher 自动发现（KOL worktree 的 11–15 个脚本走此路）= project 层挂载、◇ 位置型。

**采集契约细节**

- 外部采集器：`console/collectors.d/<name>.{sh,py,js}`（可执行），参数 `--config <path>`，stdout 一个契约 JSON；退出码非 0 = 该采集器整体失败（记 diagnostics），不影响别人。超时 30s。
- 项目内声明式接入：任意仓库可放 `.forge.yaml`，声明本项目额外资产（例：一个 systemd 探测不到的看门狗脚本）。这是"规范格式接入"的最轻形态。
- REST 兜底：`POST /api/custom/assets`，body 即契约 JSON（同 schema 校验），供一次性/远端数据源。

**注册中心行为**

- 校验（zod + JSON Schema 双验）→ 脱敏（正则集：token/PAT/key/password，命中即 `valueRedacted`）→ 按 `source.sha256|contentHash` 分组做**漂移检测**（同 id 多副本内容分叉 → drift 告警，KOL CLAUDE.md 即首批用例）→ 合并进内存库 → 原子写 `registry.snapshot.json`。
- 刷新策略由采集器声明：`watch`（文件域，chokidar）、`interval`（multica/services 30–60s）、`on-request`（健康报告、昂贵扫描）。SSE 向 UI 推增量。
- 历史可选 SQLite（M2 起，只存 asset 版本序列，用于"上周规则改了什么"）。

---

## 5. API 规范（只读）

```
GET  /api/overview                      # 聚合：健康、各 kind 计数、drift 告警、活动流指针
GET  /api/assets?kind=&scope=&q=&tag=   # 列表/搜索（含 summary）
GET  /api/assets/:id                    # 全量 payload + 渲染用 content
GET  /api/graph?kind=…                  # assets+relations（图视图/血缘）
GET  /api/projects/:id/effective        # ★ 有效 harness 解析（见 §7.3）
GET  /api/health                        # 最新 toolchain-report + arch-patrol + 采集器自检
GET  /api/services/live                 # systemctl/ps 实时态（含进程树）
GET  /api/events                        # SSE：资产变更 / firelog tail / 报告更新
POST /api/custom/assets                 # 兜底推送（同 schema）
# M3（opt-in，默认关闭）：/api/actions/*（rerun autopilot、restart service、apply bundle）
```

绑定 `127.0.0.1`；如需局域网访问（Mac 上看），加静态 token（config 配置）。无任何写文件路径的端点；内容端点只回传已登记 source.path 的文件内容（防任意读）。

---

## 6. 内置采集器清单（首批 12 个）

| # | 采集器 | 域 | 模式 |
|---|---|---|---|
| 1 | `claude-global` | settings.json（hooks/env/permissions/plugins）、skills/、rules/、commands/、teams/、`.agents/skills/`、.mcp.json（rules/ 与 `.agents/skills/` 采入但标 third-party → 依赖架） | watch |
| 2 | `claude-projects` | 扫描根（config 声明：`/mnt/d/GodotProjects`、`~/tools`、`~/` depth-3 白名单）内 CLAUDE.md + `.claude/` | watch |
| 3 | `devforge-hooks` | rules-v2 + rules.d + hooks-registration + scripts 清单 + state 统计 | watch |
| 4 | `devforge-firelog` | firelog tail（复用 `hook-fire-path.lib.sh` 的落点解析规则）→ 规则命中/错误率、活动流 | interval(5s tail) |
| 5 | `devforge-autopilots` | autopilots/*.py 静态元数据 + configs/ + `docs/autopilots.md` trigger 台账 + ledger | watch |
| 6 | `devforge-launch` | repos.d/*.json、systemd 单元、toolchain.env | watch |
| 7 | `devforge-adapters` | adapters/* env 契约与目标（静态解析） | watch |
| 8 | `multica` | `multica agent/autopilot/squad/skill list --json`、runtime、task 概要（限流） | interval(60s) |
| 9 | `services` | systemctl user+system、toolchain-start-all cgroup 进程树、`/mnt/c/Users/Jerry/*.ps1|bat` 桥 | interval(30s) |
| 10 | `health` | 直接消费 `~/.multica/toolchain-reports/{latest,history}.json`、`arch-patrol/last_report.json` | watch |
| 11 | `hindsight` | `~/.hindsight/coding-agent.json`、bank 列表、API 健康探测 | interval |
| 12 | `sessions`（可选） | `~/.claude/projects/` 索引（642 目录）+ multica workspaces → 会话/任务总览 | on-request |

> 采集器实现对既有工具保持谦逊：不重新实现 toolchain_daily_check 的判定，只消费其 JSON；multica 数据一律走 CLI/API，不猜内部结构。

---

## 7. 前端设计

### 7.1 技术与结构

Vite + React + TypeScript；路由按页面域拆分；状态：服务端状态用 TanStack Query + SSE 失效刷新，无全局客户端 store。Markdown 渲染自研轻量组件（表格/代码块/标题锚点/`mention://` 与相对链接解析为内部跳转——KOL CLAUDE.md 大量 `docs/…` 相对引用需可跟随）。

### 7.2 页面地图（IA）

| 页面 | 回答的问题 | 核心组件 |
|---|---|---|
| **总览 Overview** | 整体健康吗？规模多大？刚发生了什么？ | 健康横幅（GREEN/REDLINE，读 toolchain-report）、StatTile 阵列（mono 大数字：8 agents / 22 规则 / 6+34 skills / 6 services / 7 autopilots / 7 projects）、漂移告警卡、活动流（firelog tail + autopilot run） |
| **Agents** | 每个 agent 是什么构成？ | 双栏：multica agents（服务端定义）/ CC subagents；详情页 = **Agent Anatomy**：instructions 渲染、model/thinking、MCP 表、env（脱敏）、关联 skills、近期任务、该 agent 被哪些规则门控（`agents` 字段反查） |
| **指令库 Instructions** | 我给各项目/全局下了什么指令？ | 按 scope 树（global / project / platform）；正文渲染 + 章节导航；**漂移视图**：同 contentHash 组对比、逐行 diff（KOL 家族矛盾规则直接可视）；multica 物化 CLAUDE.md 与源 CLAUDE.md 的前导差异 |
| **Hooks** | 9 个挂载点通向哪里？规则说了什么？ | 管线图（挂载点→wrapper→dispatcher→engine→规则→脚本，墨块节点+紫影）；规则表（on/门控/one-shot/**when 人话摘要**/action）；脚本卡（挂载方、超时、fail 策略、最近触发）；注册健康（doctor 五检结论）；firelog 实时 tail + 错误率 |
| **Skills** | 有哪些技能、谁在用？ | 卡片栅格（全局/ECC/项目/平台四色标签）；详情渲染 SKILL.md；反查被哪些 agent 绑定 |
| **服务 Services** | 什么在自启动？活着吗？ | 服务树（systemd → 子进程）；状态灯（running/enabled/failed/dead）；uptime、日志 tail 入口；Windows 桥（标注"疑似旧桥"）；每会话 MCP 子进程按父会话归组 |
| **Autopilots** | 什么在定时巡逻？上次跑了啥？ | 每行：cron 表达式（mono）+ trigger id + agent + 脚本 + 上次运行时间/退出码 + **lastReport JSON 树渲染** + kill-switch 状态 + ledger 链接 |
| **Projects** | 每个项目的 harness 组成？ | 组成矩阵（CLAUDE.md/settings/hooks/skills/MCP 有无与规模）+ git 状态 + repo-sync 注册 + 该项目 effective 链接 |
| **迁移 Migration** | 迁到 multica 差什么？ | 见 §8 |
| **关系图 Graph** | 谁挂谁、谁调度谁？ | 分层血缘图（非力导向——档案柜气质要整齐）：asset 节点按 kind 着墨块/纸块，边 = relations |
| **通用资产浏览器** | （兜底） | 未知 kind / custom 资产的 JSON 树 + 元信息表，永不白屏 |

**全局交互（作用域是一等导航维度）**：TopBar 下挂 Workspace 切换器（全部 / KOL / dev-forge / grepai…，来自 §4.1 注册表）——切换后所有页面按该产品域过滤（project 列表、住宿 agent、服务上卷健康、autopilot target）。每个资产详情页有**作用域面板**：按 §4.1 矩阵逐轴展示 `●强制 / ◐约定 / ◇派生 / —无效` 徽章 + `attach/applies` 详情；位置型资产只读展示派生结果。Agents 页按 residence 分组；漂移检测限定在 workspace 内跨 project 对比。**归属过滤与作用域并列为一等维度**：主清单默认只列 `first-party`，依赖架（ECC 34 技能、rules 规则包、claude-mem 脚本等 third-party）单独 tab 折叠展示——它影响行为但不属于"我们的 harness"，也不进迁移导出。

### 7.3 杀手级功能：Effective Harness（有效 harness 解析）

`GET /api/projects/:id/effective`：给定（项目 × agent），像运行时一样**合并**出实际生效的 harness，并给每一项溯源 chip：

```
项目 king-of-likes × agent Fronti（multica 会话）：
├─ 系统指令：workdir/CLAUDE.md = multica 前导 + agent.instructions + 项目 CLAUDE.md(144行)
├─ hooks：全局 9 点 dev-forge 引擎（22 规则中 agents 门控命中的 14 条）+ hindsight 3 点
├─ skills：全局 6 + ECC 34（禁用清单过滤后）+ 平台物化 4 + 项目 0
├─ MCP：godot-mcp（项目 .mcp.json）+ hindsight-mcp-remote（per-agent mcp_config）
├─ 模型：agent-fronti[1m] ← LiteLLM 映射
└─ env：26 项（脱敏）+ MULTICA_TASK_SESSION_ID 注入
```

这一页就是"不用每次查源代码"的终答，也是迁移 dry-run 的基准面。

### 7.4 设计系统：KOL 形制移植（Neo-Brutalism × 打字机档案 · 方案 E 紫调夜幕）

完整移植 KOL SEE-1220 定稿规范（`king-of-likes/docs/game-design/art/{ui_color_spec,ui_pixel_style_rework_d1}.md`），形制不变、介质从 Godot StyleBox 换 CSS：

**Tokens（CSS custom properties，`apps/web/src/styles/tokens.css`）**

```css
:root {
  /* 色板 · 方案E（唯一定稿，禁止散值 hex） */
  --paper:#EDEAF2; --paper-warm:#F8F6FC; --ink:#191422;
  --accent:#6C3FB8; --mint:#E29BC0; --amber:#E8B93A;
  --khaki:#D6D0DE; --gray:#837C90; --cream:#EFE7F0;
  --text-sub:#443D52; --text-on-dark:#F8F6FC;
  /* 字号阶梯（全站仅此 7 值） */
  --fs-L0:8px; --fs-L1:11px; --fs-L2:14px; --fs-L3:18px; --fs-L4:24px; --fs-D1:40px; --fs-D2:56px;
  /* 间距阶梯（8px 栅格） */
  --sp-1:4px; --sp-2:8px; --sp-3:16px; --sp-4:24px; --sp-5:32px; --sp-6:48px;
  /* 边框：2px 次级/小件，3px 主面板/主按钮；圆角恒 0 */
  --bw-1:2px; --bw-2:3px; --radius:0;
  /* 硬阴影（D3 定稿：紫影，右下，零模糊）三档 */
  --shadow-panel:8px 8px 0 var(--accent);
  --shadow-button:5px 5px 0 var(--accent);
  --shadow-divider:2px 2px 0 var(--ink);
}
```

**字体**：拉丁/数字 `"Courier New", "Courier Prime", ui-monospace, monospace`（Courier Prime woff2 自嵌入，OFL-1.1 合法）；中文 `fusion-pixel-12px-proportional-zh_hans`（OFL，与 KOL 一致），并提供系统 CJK 切换（长文阅读场景）。标签英文 mono 全大写 + letter-spacing 2–4px；统计数字 mono 大号（L3/L4）呈现档案仪表盘感。

**组件规格（与 KOL StyleBox 语义一一对应）**

| 组件 | 规格 |
|---|---|
| `PanelPaper` 主面板 | paper-warm 底 + 3px 墨边 + 紫硬影 (8,8)，radius 0 |
| `PanelPaperFlat` 列表行/嵌套面 | paper 底 + 2px 墨边，无影 |
| `PanelInk` 墨块（日志窗/代码块/健康横幅） | 墨底 + 纸色字 + 紫影 (8,8) |
| `ButtonMint`（主确认）/ `ButtonAmber`（次要/警示）/ `ButtonGhost`（工具） | mint/amber/paper-warm 底 + 墨边；normal 影 (5,5)，**hover 每轴 −2~−4px 微下沉，pressed 归 (0,0) 完全按入**，disabled 灰底灰字无影 |
| `InputPaper` | 白底 2px 墨边；focus 边框 3px + 左侧 4px 紫强调条 |
| `TooltipCream` | cream 底 + 2px 墨边 + 紫影 (5,5) |
| `DividerInk` | 纯墨 3px 横线分区（版面靠墨线不靠留白） |
| `StatTile` | PanelPaper 内 mono 大数字 + 灰 mono small-caps 标签 |
| 选中态 | **墨底纸字 + 紫影**（KOL"自我发言"语言移植：黑底白字+红影 → 紫调版） |
| 状态色语义 | running/GREEN=mint、warn/AMBER=amber、fail/REDLINE=accent 反白墨块、disabled=gray |

**布局气质**：档案柜式分区——顶部墨色 TopBar（站名 mono 全大写 + 健康灯），左侧窄导航（纸底 2px 墨边按钮列），主区 PanelPaper 网格；区块间用 DividerInk 而非阴影堆叠；层级靠"纸块/墨块反色 + 阴影高差"，不用透明度。移动端不投入（工作站监控台，桌面优先 ≥1280px）。

---

## 8. 迁移模块（终极愿景的落地形态）

**模型**：每 kind 定义目标平台投影（projection）。资产是唯一事实源，投影是纯函数。**§4.1 作用域词汇表就是可移植层**：投影的输入是 `(kind, attach, applies, enforcement)` 四元组——例如 CC 的 project 级 skill 投影到 multica = 平台导入 + 按该 workspace 住宿 agent 做分配；`—` 轴在投影中直接丢弃，不产生假迁移项。

| Claude Code 资产 | multica 投影 | 通道 | 状态 |
|---|---|---|---|
| instruction（CLAUDE.md/规则） | agent.instructions（模板合成，保留 multica 前导） | `multica agent update --instructions` | ✅ 直接可映 |
| skill | 平台 skill | `multica skill import` + `multica agent skills` | ✅ |
| subagent 定义 | multica agent 本体 + @mention 协作 | `multica agent create` | ✅（语义改写） |
| MCP server | per-agent `mcp_config` | `multica agent mcp` | ✅ |
| hook-rule | ⚠ **无原生对应物** | 策略 A：沿用全局 ~/.claude hooks（现状，multica 会话仍生效）；策略 B：转为 autopilot 预检/评审 prompt | ⚠ 平台缺口，逐条标注策略 |
| service/timer | multica autopilot（cron trigger） | `multica autopilot` | ✅ |
| rules/*.md 行为规则 | 并入 instructions 或平台 skill | 同 instruction | ✅ |

**迁移页三视图**：
1. **覆盖矩阵**：每 kind 资产 × 目标平台的映射状态（✅/⚠/❌）与覆盖率百分比；
2. **Dry-run diff**：选定项目/agent → 对比"当前平台侧定义"与"投影应生成定义"的差异（如 Fronti instructions 与 KOL CLAUDE.md 合成结果的 diff）；
3. **导出包**：生成迁移脚本（`multica agent update …`、`multica skill import …` 的 shell 清单）+ 变更说明书。**只生成、不执行**——执行永远走人工评审（与 dev-forge"fail-open 但不静默"的工程气质一致）。

新增目标平台 = 新增一组投影定义（YAML/TS 纯函数），资产与 UI 不动。

---

## 9. 安全与边界

- **只读默认**：一切端点无副作用；动作类端点 M3 才出现且 config 显式开启。
- **脱敏**：env/PAT/token 类值在采集层即替换为 `valueRedacted`（settings.json 里的 GitHub PAT 是首批用例）；UI 永远拿不到原文。
- **任意读防护**：内容端点仅回传已登记 source.path；路径不做参数拼接。
- **网络**：默认 127.0.0.1；开放局域网需显式配 token。
- **自举边界**：console 自身也会被 `services` 采集器看见（一个 user 级 systemd 单元），但不自改注册——bootstrap/doctor 仍由 dev-forge 既有流程管理。

---

## 10. 分期路线

| 阶段 | 范围 | 出口标准 |
|---|---|---|
| **M0 骨架**（1–2 天） | monorepo 脚手架、schema 包、采集器 1/2/3（claude-global、claude-projects、devforge-hooks）、registry+快照、API 最小集、UI：设计 tokens + 总览/指令库/Hooks 三页 | 三页能回答摸底报告 §2.2 的对应行；`tests/run_all.sh` 可跑 vitest |
| **M1 全量** | 采集器 4–12、SSE、Services/Autopilots/Skills/Agents/Projects 页、关系图、漂移检测告警 | §7.2 页面全上线；总览健康横幅读真实 toolchain-report |
| **M2 迁移** | Effective Harness 解析、迁移三视图、导出包、SQLite 资产历史 | 能对 Fronti 产出 instructions dry-run diff；KOL CLAUDE.md 漂移常显 |
| **M3 动作**（opt-in） | actions API + 鉴权、autopilot 重跑、报告订阅 | 动作全部过确认弹层 + 审计日志 |

**Quick win**（M0 之前即可做）：`health` 采集器 + 总览健康横幅——toolchain-reports/latest.json 是现成的，半天能亮灯。

---

## 11. 风险与开放问题

1. **multica CLI JSON 稳定性**：闭源二进制 v0.2.29，`--json` 输出无契约保证 → 采集器加 schema 宽容层 + 版本探测，升级（upgrade-multica-selfhost.sh）后跑 smoke。
2. **firelog 5.5MB 高频写**：tail 采集器用轮询 + offset 增量，不做全量解析；错误率统计复用 toolchain_daily_check 已有口径。
3. **KOL 家族漂移是特性不是缺陷**：worktree 副本天然落后主检出，漂移视图需区分"预期分叉"与"意外漂移"（按 git 关系标注），否则告警会疲劳。
4. **Windows 侧 harness**（C 盘 ecc/skills/agents…）首期只登记不采集——是否纳入、经什么通道（WSL 直读 /mnt/c），M1 后再定。
5. **hindsight MCP 工具在本会话不可用**，本方案中 Hindsight 相关事实（hook 旁挂、7 bank、HTTP 13581）来自实盘文件与服务探测，如与最新部署有出入以 `~/.hindsight/coding-agent.json` 为准。

---

## 实施状态（2026-11-03，feat/console 分支 · PR #41）

**M0+M1 已全部落地并上线**：

- `console/` monorepo（pnpm workspace）：schema（zod 契约 + `asset.schema.json`）/ collectors（12 内置 + 外部 `collectors.d/` 装载器 + REST 推送）/ server（零框架 builtin-http + token + SSE + chokidar watch，/mnt 9p 走 polling）/ apps/web（Vite+React，11+1 页，KOL 方案 E 设计系统 tokens.css）
- UI 按 Owner 12 张效果图精确对齐（2048×1152），紧凑高密度；真机截图全页比对通过
- 作用域 lattice / provenance 依赖架 / hook 条件投影（§4.2）/ Effective Harness 解析 / 迁移 dry-run（覆盖矩阵 + instructions 物化 diff + 导出脚本）均已实现
- 漂移检测实证：KOL 家族 CLAUDE.md 漂移组（144 行主检出 vs 157 行 worktree）
- **测试**：单元+API 54（schema 13 / collectors 28 / server 13）、Playwright E2E 16（fixture 确定性数据，真后端真浏览器）；既有设施回归：validator 237/237、`tests/run_all.sh` ALL GREEN、pytest 812 passed
- **上线**：`systemctl --user` 常驻 `forge-console.service`；LAN 经 Windows portproxy+防火墙放行 `http://192.168.1.105:7310`（token 在 `~/.config/forge-console/env`，0600）
- **运行时位置（重要）**：服务跑在独立 worktree `~/tools/forge-console`（feat/console 分支）——dev-forge 主检出由 repo-sync 守护管理（强制 main），不得在此直接 checkout 分支，否则源码目录会被守护清理、pnpm workspace 链接全断（已实证）。PR 合并后可将服务切回主检出。
- CI：新增独立 `console` job（engine-tests 零改动）
- 未做（按计划属 M2/M3）：SQLite 资产历史、写操作类 API、Windows 侧 harness 采集、`.forge.yaml` 声明式接入

## 附：与既有资产的关系

- 本方案不改动 dev-forge 任何现有组件；console 作为新顶层目录加入，遵循"数据驱动、fail-open、absolute-path 注册"三原则。
- `docs/autopilots.md` 继续是 autopilot 权威文档；console 的 autopilot 采集器以其 trigger 台账为输入之一，二者单向（doc → console）。
- doctor.sh 五检结论可作为 `devforge-hooks` 采集器的一项诊断输入（调用其 verify 模式，只读）。
