[@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5) SEE-1429 migration-plan-md 子步骤完成：`dev-forge-migration-plan.md` 全文如下（Phase 2 落库 docs/，本 comment 即 taskflow 执行唯一依据）。汇编以 **Atlas 正典规格（16:30:32）为准**，与本 thread 内此前设计文档冲突之处一律以正典覆盖；未建仓、未改代码、未执行迁移，事实均本机实测。

---

# dev-forge 迁移计划

## 1. 背景与目标

Owner（jerry）发现 hooks 全局部署位与 KOL 仓库源双轨并存（SEE-1429 调查：2026-09-20 SEE-1330 事故 4 裁定全局优先；双轨漂移活例证 = commit `9350f94d` mention-check 收窄未同步）。经三轮讨论 Owner 定案最终态：**自研工具链从 KOL 仓库整体独立为新仓库 `dev-forge`，KOL 只留项目自身配置；全局 Claude hooks 注册链直指 dev-forge 检出的绝对路径；`~/tools/dev-forge/claude-hooks/` 代码全部清理（不投影、不 symlink）；与 Multica/KOL/Claude 三方解耦；单一真源 = 本地 editable 检出（改文件即生效）**。

## 2. 目标架构

- **注册链**：`~/.claude/settings.json` 9 时点注册行（PreToolUse/PostToolUse/SessionStart/SessionEnd/Stop/SubagentStop/UserPromptSubmit/Notification/PreCompact，matcher 全 `*`）由 bootstrap 渲染为绝对路径 `/home/jerry/tools/dev-forge/claude-hooks/hook-wrapper.sh <Event> unified-hook`。CC 运行时直接读 dev-forge 检出内代码。
- **运行链**：settings → hook-wrapper.sh → dispatcher.sh → unified/engine.js（+ rules）→ scripts/。四层全落 dev-forge，路径仓库内相对定位（§5）。
- **仓库级语义**（Owner 确认、Atlas 已实证）：引擎级总是加载全部规则，「仓库级触发」由规则 when 条件（路径/env/agents 维度）+ dispatcher 的 PROJECT_ROOT/REPO_ROOT 探测实现——不靠每仓装引擎。
- **~/tools/dev-forge/claude-hooks 终态**：清空删除；历史备份快照（backup-see1333-*/backup-see1392-*）移档 `docs/archive/` 留档。
- **adapters 语义**：绑定单一外部系统、无通用化语义的适配器专区（3 个），README 注明不做通用化改造。

## 3. 仓库布局终稿（正典规格）

```
dev-forge/                          # 唯一检出：~/tools/dev-forge/（main 常驻）
├── README.md                       # gqt 同等水准（§10）
├── claude-hooks/                   # hooks 运行链真源（注册直指此处）
│   ├── hook-wrapper.sh             # ← KOL .claude/hooks/hook-wrapper.sh（exec 相对化，§5.1）
│   ├── dispatcher.sh               # ← KOL .dev/hooks/dispatcher.sh（兜底分支删除，§5.2）
│   ├── validate-rules.js           # ← claude-hooks 根，与 unified/ 同级；engine.js:13 require('../validate-rules.js') 零改码（§5.3）
│   ├── unified/                    # 引擎 + 配置数据（不分离）
│   │   ├── unified-hook.sh / engine.js / when-ops.js   # unified-hook.sh 已相对定位，不改
│   │   ├── rules-v2.json / rules.d/*.json              # 含 runscript-mounts.json（agents include Atlas 终态）
│   │   └── state/                  # gitignore（one_shot 运行时写入，不入 git 树）
│   └── scripts/                    # 业务钩子 ×11 + lib/
│       ├── push-guard.sh / mention-check.sh / auto-pr-on-stop.sh
│       ├── atlas-taskflow-mark-a/b/exit-reminder.sh / gdformat-gdlint.sh / repo-checkout.sh
│       ├── mcp-tool-presence.sh / godot-mcp-launch-path.lib.sh   # rules 挂载支撑库，目标经 config 注入，不属孤立
│       └── lib/                    # gitlink-probe.sh / gitlink-sync-hint.sh / hook-fire-path.lib.sh
├── bootstrap/                      # 四件套（install-hooks.sh 角色重定义）
│   ├── bootstrap.sh                # 一次性首装：备份 settings hooks 段 → 按 hooks-registration.json + 实际检出路径渲染 9 行注册 → 幂等（重跑 diff=0）
│   ├── doctor.sh                   # 校验：注册行路径可达 / engine require 冒烟 / validate-rules.js 存在 / rules schema / $HOME/tools/dev-forge/claude-hooks 引用残留扫描（应 0）
│   ├── rollback.sh                 # 恢复 settings 注册段备份（uninstall 语义并入）
│   ├── registry-patch.js           # ← KOL .claude/hooks/registry-patch.js
│   └── hooks-registration.json     # 声明式注册清单（拍板归 bootstrap/ 侧）
├── adapters/                       # 孤立适配器专区（单系统绑定，不通用化）×3
│   ├── upgrade-multica-selfhost.sh # ← .dev/launch/（KOL_SERVICE→TOOLCHAIN_SERVICE 改名保留）
│   ├── hindsight-mcp.sh            # ← .dev/launch/（薄壳 launcher，内容与现用版逐字一致）
│   └── workspace-env-check.sh      # ← .dev/launch/（Multica workspace 校验，语义天生绑定）
├── autopilots/                     # ← .dev/autopilots/（×7 + multica_helpers.py + .sh wrappers）
│   └── configs/kol.json            # architecture_sweep 扫描目标 + addons/godot_mcp 红线清单配置化（数据非代码）
├── launch/
│   ├── toolchain-start.sh          # ← kingoflikes-start.sh 通用化改名
│   └── systemd/toolchain-start-all.service
├── docs/
│   ├── hooks-implementation-guide.md / hooks-usage-rules.md / hooks-v2-migration-map.md
│   ├── dev-forge-migration-plan.md # 本计划
│   ├── dev-forge-cutover.md        # runbook 落库版
│   └── archive/                    # backup-see1333-*/backup-see1392-* 移档 + hooks-old 移档
├── tests/                          # ← .dev/tests/hooks/ 全套（installer/engine/architecture/业务钩子）
└── .githooks/ + CI                 # gqt 同等体系（CI、提交规范）
```

## 4. 迁移清单三段

**迁出（→ dev-forge）**：`.claude/hooks/` 全部（unified/ 引擎+rules、scripts/ ×11+lib/、validate-rules.js、registry-patch.js、hooks-registration.json；install-hooks.sh 改造为 bootstrap 三件套不迁本体）；`.dev/hooks/`（dispatcher.sh、hook-wrapper.sh）；`.dev/docs/claude/` 三件套；`.dev/autopilots/` 全部；`.dev/launch/` 中 hindsight-mcp.sh / upgrade-multica-selfhost.sh / workspace-env-check.sh（→ adapters/）+ kingoflikes-start.sh（→ launch/toolchain-start.sh）；`.dev/systemd/kingoflikes-start-all.service`；`.dev/tests/hooks/`；`.dev/scripts/mcp-mouse-lint.sh` 不迁（留 KOL，existence guard）。

**留 KOL**：`.claude/settings.json`（项目自身配置，与 hooks 运行位无连接）、`.mcp.json`、`.gutconfig.json`、lint 配置、`.githooks/`、CI、素材脚本；`.dev/repo-sync/`（repo_sync.py/daemon/config——config 用 `__KOL_REPO_ROOT__` 哨兵解析 KOL 侧仓库根，属 KOL 自身守护配置）；`.dev/scripts/` 其余（lint-* 系列、reconcile-working-branch.sh 等）；`.dev/` 其余（review-prompts、repo-structure、architecture、env、tests 非 hooks 部分）；godot-mcp 子仓库（Owner 指示不动）。

**删除（KOL 侧，P3 执行）**：`.claude/hooks/` 整目录、`.dev/hooks/`、`.dev/docs/claude/`、`.dev/autopilots/`、`.dev/launch/`、`.dev/systemd/`、`.dev/tests/hooks/`；运行位 `~/tools/dev-forge/claude-hooks/`（hooks-old 移档后删）。

## 5. 相对定位改造（实际改 3 处）

1. **hook-wrapper.sh 末行** `exec "/home/jerry/tools/dev-forge/claude-hooks/dispatcher.sh"` → `exec "$(cd "$(dirname "$0")" && pwd)/dispatcher.sh"`；同文件 firelog lib 候选列表删除 `$HOME/tools/dev-forge/claude-hooks/...` 兜底项。
2. **dispatcher.sh:100-101** unified-hook case：首选改为 `$(dirname "$0")/unified/unified-hook.sh`；`$PROJECT_ROOT/.claude/hooks/unified/` 兜底分支删除（KOL 清理后无源）。
3. **engine.js**：零改码（validate-rules.js 根级镜像落位，`require('../validate-rules.js')` 原样）。
- unified-hook.sh:62 `ENGINE="$(dirname "$0")/engine.js"` 实测已是相对定位，不改。


## 6. 改名映射表（KOL 侧引用一并修复）

| 现名 | 新名 |
|---|---|
| `KOL_REPO_ROOT` | `TARGET_REPO_ROOT`（单仓场景）或按仓库派生 |
| `kingoflikes-start.sh` / `-all.service` | `toolchain-start.sh` / `toolchain-start-all.service` |
| `KOL_SERVICE`（adapters/upgrade-multica-selfhost.sh） | `TOOLCHAIN_SERVICE` |
| `__KOL_REPO_ROOT__` 哨兵（KOL 侧 repo_sync_config.json） | 留 KOL 侧，不改（KOL 自身配置） |
| autopilots SELF_AGENT_ID 默认值 | 保持环境变量可覆盖，不迁移改名 |

零残留判据：dev-forge 内 `grep -r 'KOL_REPO_ROOT\|kingoflikes\|KOL_SERVICE'` = 0 命中（adapters/ 内 TOOLCHAIN_SERVICE 改名后计入）。

## 7. cutover 步骤（P0-P4，顺序铁律：真源就位 → 注册切换 → 验证 → 清运行位 → 删 KOL 旧物）

- **P0 预检**：建仓 `tadki/dev-forge` + 检出 `~/tools/dev-forge/`（main）；迁移 + §5 改造 + §6 改名；备份 `cp -a ~/tools/dev-forge/claude-hooks ~/tools/dev-forge/claude-hooks-backups/pre-cutover-<ts>/` + `cp ~/.claude/settings.json +.bak-<ts>`；记录 firelog 水位。判据：doctor.sh 全 PASS（含 require 冒烟）+ tests/ 全绿。
- **P1 注册切换**：P1.1 bootstrap.sh 渲染 9 行注册（settings diff 仅 9 行路径）；P1.2-P1.4 触发验证：push-guard firelog 行 + rules=21 数一致；SessionStart repo-checkout 链正常；deny 语义（mention-check/child-issue-guard 命中返回 deny）；one_shot state 写入（claude-hooks/unified/state/ 新位成功、无 WARN 劣化）；判据：firelog `script=` 字段显示 dev-forge 路径。
- **P1.5** `mv ~/tools/dev-forge/claude-hooks ~/tools/dev-forge/claude-hooks-old`（不 rm）。
- **P2** hooks-old 移档 `docs/archive/hooks-old-<ts>/` 后彻底删除；再触发一轮 hooks 确认仍正常。
- **P2.5 -new MCP 实测节点**：hindsight-mcp.sh 就位 adapters/ 后，以平台 -new MCP 配置（`bash /home/jerry/tools/dev-forge/adapters/hindsight-mcp.sh`）做真实 hindsight 工具调用实测（agent_knowledge_recall 成功返回 = 链路通）；实测通过后报 Owner 切平台共享配置。
- **P3 KOL 清理**：§4 删除清单逐目录 `git rm`（KOL 共享分支 commit，可 revert）；KOL 侧引用修复（全仓 grep `dev/hooks|dev/autopilots|dev/launch|dev/systemd|docs/claude`）；systemd `daemon-reload + restart toolchain-start-all`。判据：KOL 干净 clone 后一轮 multica 任务全流程通。
- **P4 收口**：逐项测试清单（§9）全过，结果留 hook-fire.log + issue 证据。

**双回退面**：①settings 注册段恢复（rollback.sh，P1 任何失败即用）；②hooks-old 还原（`mv` 回原位）。两回退面独立；pre-cutover 备份与 hooks-old 保留 2 周。

## 8. Owner 手动操作清单

1. **已完成 ✓**：Multica 平台创建 -new 后缀 hindsight MCP（command=bash，args=`/home/jerry/tools/dev-forge/adapters/hindsight-mcp.sh`）。
2. GitHub 网页：dev-forge 建仓后 branch protection（禁 squash merge 等，对齐 gqt repo settings）。
3. P2.5 实测通过后：平台共享 MCP 配置从旧路径（`<旧 KOL 检出>/.dev/launch/hindsight-mcp.sh`）切换到 -new 或删旧留新。
4. （如需）systemd restart 授权。

## 9. 逐项实际测试清单（每个迁出物一条：验证动作 → 判据）

| # | 迁出物 | 验证动作 | 判据 |
|---|---|---|---|
| T1 | hook-wrapper.sh | 直接执行（喂 stdin 最小 hook payload） | exit 0，firelog 新增 wrapper 行且路径含 dev-forge |
| T2 | dispatcher.sh | 经 T1 链路执行 unified-hook alias | firelog `[dispatcher]` 行出现、script=dev-forge 路径 |
| T3 | unified-hook.sh + engine.js + when-ops.js | 触发一条 config 规则（如 grepai-search-reminder） | additionalContext 返回、rules=21 与切换前一致 |
| T4 | validate-rules.js（根级） | `node -e require(engine)` 冒烟 | 无 module-not-found |
| T5 | rules-v2.json / rules.d/*.json | doctor.sh schema 校验 + runscript-mounts agents=include Atlas 生效 | PASS；mention-check 仅对 Atlas 触发 |
| T6 | push-guard.sh | 尝试非法 push | deny（exit 2 → deny JSON） |
| T7 | mention-check.sh | 非 Atlas 触发 / Atlas 触发各一次 | 非 Atlas 放行、Atlas 走 mention 校验链 |
| T8 | atlas-taskflow-*.sh ×3 | Atlas 身份触发 mark-a/mark-b/exit-reminder 路径 | 状态标记写入、无报错 |
| T9 | gdformat-gdlint.sh | 触碰一个 .gd 文件 Write | lint 链触发；mcp-mouse-lint existence guard 静默跳过（KOL 场景生效时才执行） |
| T10 | auto-pr-on-stop.sh | Stop 事件 dry 观察 | fail-open，无阻塞、无异常 firelog |
| T11 | repo-checkout.sh | 新开 session | checkout hint 正常、10 分钟幂等 marker 生效 |
| T12 | mcp-tool-presence.sh + godot-mcp-launch-path.lib.sh | SessionStart 链内被调用 | 无 ENOENT，工具审计正常 |
| T13 | scripts/lib/ 三件 | T1/T2 链路隐式覆盖 + 直接 source 冒烟 | source 无错 |
| T14 | bootstrap.sh | 首跑 + 重跑 | 首跑 diff=9 行；重跑 diff=0（幂等） |
| T15 | doctor.sh | 全项执行 | PASS 清单，含残留扫描 0 命中 |
| T16 | rollback.sh | 测试环境演练（备份→改→恢复） | settings 注册段精确还原 |
| T17 | adapters/upgrade-multica-selfhost.sh | `--dry-run`（如无则语法检查 bash -n + 变量改名核对） | bash -n 0 错误、TOOLCHAIN_SERVICE 命名生效 |
| T18 | adapters/hindsight-mcp.sh | 以 -new MCP 配置起进程，真实调用 agent_knowledge_recall | 工具成功返回；进程解释器为 hindsight 插件 venv |
| T19 | adapters/workspace-env-check.sh | 手动执行带 --repo-dir 指向 dev-forge | 校验逻辑输出正常（multica CLI 调用成功） |
| T20 | autopilots ×7 + helpers | 逐脚本 `--dry-run`/DRY_RUN=true 执行（各自支持） | 全部正常输出 JSON/报告，无 import/路径错误 |
| T21 | autopilots/architecture_sweep 配置化 | 以 configs/kol.json 为目标跑 dry-run | redline 清单命中与迁移前一致 |
| T22 | launch/toolchain-start.sh + service | systemd 链路（授权后 restart） | 服务 active、multica daemon + repo-sync daemon 均起 |
| T23 | repo-sync（留 KOL） | 确认未迁移 + 守护继续工作 | KOL 侧 repo-sync 状态文件照常更新 |
| T24 | tests/ 全套迁入 | `bash .dev/tests/hooks/run_all.sh` 等价套件在 dev-forge 运行 | 全绿 |
| T25 | KOL 侧残留 | KOL 全仓 grep §4 删除清单关键词 | 0 引用残留 |
| T26 | 端到端 | KOL 干净 clone + 一轮真实 multica 任务（含 push-guard/mention-check/taskflow 记账/hooks 触发） | 全流程通过，firelog 证据齐 |

## 10. README 要求（对标 gqt）

结构：项目一句话定位 → 目录导览（claude-hooks/bootstrap/adapters/autopilots/launch/docs/tests 逐目录语义，adapters 特别注明「单系统绑定，不通用化」）→ 快速开始（clone 到 ~/tools/dev-forge + bootstrap.sh + doctor.sh）→ cutover/回退 runbook 链接（docs/dev-forge-cutover.md）→ 架构小节（注册链直指图、引擎级规则+仓库级 when 语义）→ 测试入口（tests/）→ License/贡献约定对齐 gqt。语言风格、徽章、目录树格式参考 godot-qa-toolkit README 现状。

## 11. 执行摘要（taskflow 编排输入）

Phase 2 实施（Refacty：建仓+迁移+§5/§6 改造+T24 全绿）→ Phase 3 切换（Atlas 主持：P1-P2.5，含 -new MCP 实测）→ P3 KOL 清理 → Revy QA（§9 清单逐项复核 + §SPEC-007 证据核查）→ Owner 平台配置切换收口。
