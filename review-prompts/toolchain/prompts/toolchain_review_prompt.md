# 工具链半周检 Agent 评审 Prompt 模板

> 版本：v2.4（2026-10-14，SEE-1408 主题重组——hooks+autopilots 合并、新增 GQT 库主题、godot-mcp 表述随重构布局更新；v2.3 结构与粒度约定不变）
> 调度方：Multica autopilot（由 SEE-1183 任务 2b 配置，每周两次）
> 执行方：具备仓库只读访问权限的评审 agent（默认 Archi；可按主题轮换或固定）
> 性质：模板（prompt 文本），非可执行脚本。**拼装已脚本化**：执行 agent 每期运行 `dev-forge/review-prompts/toolchain/build_review_prompt.py`，脚本输出即当期完整评审 prompt（期次自增、四主题轮换、当期对标参考随主题注入、占位符替换、Kill Switch 检查均已内置）。本文件是脚本的拼装素材与设计规格。
> **章节归属约定**：「§N」指拼装产物中的第 N 节（§1 评审任务 / §2 指引和规则 / §3 产出）；本文件第 4-7 节为主题素材，仅供脚本按期取材注入 §1.1，不独立出现在拼装产物中。
> **指引粒度约定（Owner 指令）**：本模板只给框架与方向——评什么主题、什么算好、怎么汇报、什么不能做。**不规定怎么查、查哪些文件、跑哪些命令**；具体执行方法由评审 agent 自主决定，允许发挥。

---

## 0. 模板使用说明（给调度器看，不进拼装产物）

| 字段 | 取值 | 说明 |
|---|---|---|
| 调度频率 | 每周 2 次（建议周二 / 周五） | 与游戏巡检半周检错峰至少 6 小时 |
| 主题轮换 | hooks 与 autopilots 编排 → godot-mcp 链路 → 工具链测试有效性 → GQT 库架构 → 回到合并主题 | 每两周一轮，四主题全覆盖 |
| 主题注入 | §4-§7 主题素材按 `(nth-1) % 4` 轮换，正文注入 §1.1，对标参考随主题注入（非本期参考不进 prompt） | 由脚本完成 |
| 输出回写 | 见 §3 产出 | 检查汇报以评论形式发到本次 autopilot 创建的执行 issue 下（不新开 issue）；台账同步追加 |
| Kill Switch | 在台账目录放置 `DISABLED` 文件，或在 `~/.multica/toolchain-reports/` 放置 `DISABLED` 文件即跳过本次 | 由 Owner / Atlas 手动放置（两处任一存在即生效，与日检报告目录共用位置） |
| 失败处理 | 单次执行失败只记录到台账 `errors:` 字段，**不重试** | 连续 2 次失败由日检红色阈值捕获 |

**拼装规则（已脚本化）**：执行 agent 每期只需一条命令——

```bash
python3 dev-forge/review-prompts/toolchain/build_review_prompt.py --output ./review_prompt.md
```

脚本自动完成：① 期次自增（本地计数器）并按 `(nth-1) % 4` 从 §4-§7 取当期主题素材（含该主题对标参考）注入 §1.1；② 按 §1 → §2 → §3 顺序拼接（连续编号，无跳号）；③ 替换全部 `{{var}}` 占位符（date/nth/theme_zh/theme_body/executor_agent/daily_report_dir/ledger_path）；④ Kill Switch 预检（exit=3 表示本期跳过）。**脚本输出即当期完整评审 prompt，直接执行其中要求即可**。本节仅供脚本维护者参考（脚本源码 `dev-forge/review-prompts/toolchain/build_review_prompt.py` 内 `ASSEMBLE_SECTIONS_ORDER` 为拼装顺序的单一事实源）。

---

## 1. 评审任务

你是本期工具链评审 agent，对 dev-forge 仓库与 `KingOfLikes-Godot` 仓库 master 分支做**只读**架构评审（工具链域以 dev-forge 为主域）：对标业界工具链最佳实践做评估，不是罗列现状。每条结论必须能回答两个问题：

- **判据**：这条判断对应业界哪个被验证过的范式？（本期参考见 §1.1）
- **路径**：从当前形态演化到对标形态，最小一步是什么？

引用对标时指名具体来源 + 一句话说明映射；禁止泛泛而谈"业界通常这么做"。

### 1.1 评审主题：{{theme_zh}}

{{theme_body}}

### 1.2 建议范围

当次主题是本期评审的**焦点**，不是建议的边界——主题之外、但属于本巡检范围（工具链域；范围排除见 §2.2）的工具链建议同样欢迎，照常提报。

---

## 2. 指引和规则

### 2.1 要做的事

- 评审前先了解以下背景，不要凭空假设：
  - 仓库 master 分支（只读）。工具链域：dev-forge 仓库（`claude-hooks/`、`autopilots/`、`toolchain/`、`review-prompts/`、`adapters/`、`launch/`、`bootstrap/`、`tests/` 等为主域；`addons/godot_mcp/`（KOL submodule，只读）与 `.github/workflows/` 为 KOL 侧残留检查点）、`~/.claude/settings.json` 注册链，以及两库独立仓 `tadki/godot-mcp`、`tadki/godot-qa-toolkit`，按主题自行决定探索范围；
  - 最近 7 天日检产物：`{{daily_report_dir}}`（`latest.json` 当日全量 + `history.json` 30 天窗口）；
  - 上一期半周检台账：`{{ledger_path}}`（用于趋势线比对与条目去重）；
  - 按主题用 hindsight recall 检索过往工具链决策与教训。
- 评审完成后把本期条目追加到台账 `{{ledger_path}}`，供下期去重与趋势比对。
- 评审过程中遇到结构看不懂、上下文不足以支撑判断的情况时，先用 `/recall` 召回相关记忆（历史决策、既有教训）再下结论，不要靠猜。
- 遇到已拍板裁决的违反项直接提报，不需重新论证：单 WS slot 独占（SEE-1148）；registry 只是加速层、lease sidecar 是真相源；remote branch 巡检停用 / deleteBranchOnMerge（SEE-1179）。
- 遇到 CRITICAL 级问题按红线升级通道处理（见 §3.4）。
- 评审自身运行失败时：只在台账 `errors:` 字段记一行，不发汇报评论、不重试（连续 2 次失败由日检阈值捕获）。

### 2.2 禁止做的事

- 不修复、不重构、不写代码（只评审）；
- 不新开任何 issue / discussion——检查汇报只发一条评论到本次执行 issue（见 §3）；
- 不自动 @ 任何人、不设 assignee、不催办；
- 不重复提报台账中已存在且状态未变化的条目（去重规则见 §3.3）；
- 不评审游戏业务代码（属架构半周检范围）；
- 不评审 skills 版本健康（Owner 明确从巡检范围中移除）；
- 不触碰 `addons/godot_mcp/`（vendored 只读红线）。

---

## 3. 产出

评审完成后做三件事：① 把 §3.1 骨架改写/填空（删占位行）写入 `./toolchain_review_report.md`；② 以该文件为正文发评论到本执行 issue；③ 把本期条目追加到台账。

```bash
multica issue comment add <本执行IssueID> \
  --content-file ./toolchain_review_report.md
```

无新发现仍发（正文写「本期无新发现」+ 趋势线）。

### 3.1 报告骨架（评论正文与台账条目共用）

每条建议须具备六个字段，缺一不可：维度 / 位置 / 问题模式 / 对标最佳实践 / 优化方向 / 预估收益。数量不设上限，按预估收益排序；低收益且暂无演进动力的条目放"暂缓"区。

```markdown
## 本期元信息

- 期数：第 {{nth}} 期
- 日期：{{date}}
- 主题：{{theme_zh}}
- 执行 agent：{{executor_agent}}

## 新增建议（无则写「本期无新发现」）

| # | 维度 | 位置 file:line | 问题模式 | 对标最佳实践 | 优化方向 | 预估收益 | fingerprint |
|---|------|----------------|----------|--------------|----------|----------|-------------|
| 1 | | | | | | | |

## 上一期条目状态更新（无则写「无」）

- fingerprint `...`：仍存在 / 已修复 / 部分修复（一句话证据）

## 趋势线（首期写「首期，无上期」）

| 指标 | 上期 | 本期 | 方向 |
|------|------|------|------|
| | | | |

（按当次主题自选 3-5 个关键指标）

## 暂缓区（无则写「无」）

## CRITICAL 提案区（无则写「本期无」）

- （如有：标题 + 问题描述 + 建议负责人；台账同步打 `severity: CRITICAL`，由日检转草稿走 Owner 审批）
```

### 3.2 台账

追加本期条目到 `{{ledger_path}}`（每个主题一节，含 fingerprint 全量明细），供下期去重与趋势比对。

### 3.3 条目去重

`fingerprint = sha1(规范化(file) + line + 模式关键词)`。下期评审时：fingerprint 已存在且状态未变化 → 不重复提报，只在「上一期条目状态更新」写一行；严重度上升 → 重报并注明升级；已修复 → 标注「已修复 + 证据」。同一 fingerprint 72h 内不重复提报。

### 3.4 红线升级通道

如评审中遇到 **CRITICAL**（架构层面存在严重缺陷、可能导致系统不稳定或数据丢失），不自行开整改 issue、不自动 @ 任何人。改为：

1. 在台账该条目上打 `severity: CRITICAL` 标签；
2. 在条目末尾添加 `proposal:` 字段，写一份**草稿 issue 提案**（标题 + 一段问题描述 + 建议负责人）；
3. 在当期汇报评论的「CRITICAL 提案区」同步列出该提案；
4. 由日检在每日扫描时把台账中新增的 `severity: CRITICAL` 条目转成正式草稿 issue，走 Owner / Atlas 审批通道。

---

## 4. 主题素材 A · hooks 与 autopilots 编排架构（第 1 / 5 / 9 ... 期注入）

关注 hooks 体系（cc 平台 hooks 与 git hooks）与 dev-forge `autopilots/` 编排脚本的架构健康。核心方向——每个 hook 是否单一职责、可组合，失败是否显式冒泡而非静默吞掉，阻断型拦截是否有明确 owner 与出处，三层调用链（wrapper → dispatcher → 脚本）是否仍然清晰，新增 hook 的接入成本；编排脚本侧——幂等性（重复执行结果一致）、锁防重叠与锁残留回收、失败重试的分类与退避、Kill Switch 可用性、调度窗口错峰、必要性收敛（对照 SEE-1179：是否仍有脚本在做平台已自动完成的事）、是否存在两处以上重复实现、该提取共用模块的代码（如全局与项目副本的双份脚本）。

本期对标参考（按需引用，不要硬套）：Git hooks 官方 `core.hooksPath` 组合范式、Husky / lint-staged 的薄壳 + 任务编排分层、Claude Code hooks 官方"小脚本 + 显式 stdin/stdout 契约"、Google Shell Style Guide、systemd timer 的幂等与错峰语义、Kubernetes CronJob `concurrencyPolicy: Forbid`、Sidekiq 的唯一性锁与重试退避、GitHub Actions `concurrency` 组取消语义、Argo Workflows `shutdown` 控制字段（进程级停用开关范式）。

---

## 5. 主题素材 B · godot-mcp 链路架构（第 2 / 6 / 10 ... 期注入）

关注 godot-mcp 启动 / 桥接链路（控制面在 fork `tadki/godot-mcp`，经 `addons/godot_mcp/` submodule 挂载到本仓库）的架构健康。核心方向——单 WS slot 独占硬约束是否仍是唯一守门；状态机闭环（COLD → WARMING → WARM/FAILED/RECOVERING）每条边可观测、FAILED 退出不留残留；每类故障有独立失败码与恢复路径且 runbook 覆盖；冷启动与竞态路径（并发启动、多 runtime 接管、PID 复用、schema 漂移）的现状与设计是否一致；submodule 挂载方式下 fork 侧演进与本仓库消费侧的版本对齐与升级路径。

本期对标参考（按需引用，不要硬套）：Language Server Protocol 单会话模型、VS Code Remote Server 的 launcher + lease + reaper 三段式、JetBrains IDE protocol 的单连接约束、Kubernetes lease 对象的 holderIdentity + renewTime 字段语义、git submodule / vendored 依赖的版本锁定与升级范式。

---

## 6. 主题素材 C · 工具链测试有效性（第 3 / 7 / 11 ... 期注入）

关注工具链测试（dev-forge `tests/` 与两库自持测试树）的真实保护力。核心方向——测试的存在性 / 有效性（真实断言还是空跑恒真）/ 可信度（是否真在跑、失败是否被 `|| true` / `continue-on-error` 吞掉）；测试树与被测工具链内的重复代码状况——功能重复的并存实现该清理、功能相近的实现该合并提取共用模块；GUT 假绿教训的工具链等价物（聚合脚本吞错、断言弱化、环境依赖、定时弹窗、跳过即通过、mock 吞真）——该清单为已知枚举而非全集，清单外发现同样欢迎提报。

本期对标参考（按需引用，不要硬套）：Google Testing Blog "Just Say No to More End-to-End Tests"、ThoughtWorks 测试金字塔、微软 "Test Ivories" 假绿反模式、GUT `errors_do_not_cause_failure` 假绿教训（本项目亲历）、Mutation Testing 思想、Chaos Engineering 故障注入。

---

## 7. 主题素材 D · GQT 库架构（第 4 / 8 / 12 ... 期注入）

关注独立仓 `tadki/godot-qa-toolkit`（GQT，经 `scripts/install.sh` 全局 pip editable 安装、被 CI 与 dev-forge 工具链消费）的架构健康。核心方向——各检查器（doctor / gherkin / complexity / coverage / mutation / timing 等）职责边界是否清晰、结果契约是否一致（退出码 / 输出结构）；重复或功能相近的检查器与实现是否存在、该合并或清理的代码；扩展新检查器的接入成本与既有范式的一致性；与消费方（本仓库 CI workflow、dev-forge 脚本）之间的耦合面是否稳定。

本期对标参考（按需引用，不要硬套）：pytest 插件体系的入口注册与结果契约、mypy 的 checker 分层与公共诊断结构、CLI 工具的统一退出码约定（如 syft / trivy 的扫描器结果 schema）、Google Testing Blog 对测试工具分层职责的论述。

---

## 8. 模板版本与演化

| 版本 | 日期 | 变更 |
|---|---|---|
| v2.4 | 2026-10-14 | Owner 指令（SEE-1408）：主题重组——原 A hooks 与 B autopilots 合并为「hooks 与 autopilots 编排」；godot-mcp 链路表述随 SEE-1273 重构布局更新（控制面迁 fork + `addons/godot_mcp/` submodule）；原 D 工具链测试有效性前移为 C，并增补「重复代码清理/合并」核心方向；新增 D「GQT 库架构」主题；§2.1 工具链域清单去旧挂载退役路径、反映 submodule 与两库独立仓现状 |
| v2.3 | 2026-08-28 | Owner 指令（SEE-1191 第八轮）：补 refactor 覆盖缺口——架构侧主题 C 加「重复实现提取共用模块」、主题 D 反模式枚举加「无人调用的函数/过期实现」；工具链侧主题 B（autopilots 编排）加同向关切（双份脚本）（与 architecture v2.3 同步） |
| v2.2 | 2026-08-28 | Owner 指令（SEE-1191 第五轮）：§2.1 要做的事新增一条——评审中遇到结构看不懂或上下文不足时，必须先用 /recall 召回相关记忆再下结论（与 architecture v2.2 同步） |
| v2.1 | 2026-08-28 | Owner 指令（SEE-1191 第四轮）：结构重组——拼装产物连续编号 §1 评审任务 / §2 指引和规则 / §3 产出，消除 3→7 跳号；主题节并入 §1.1（评审任务第一节），对标参考随主题注入（非本期参考不再进 prompt）；原 §1 通用输入改为 §2.1 要做的事的自明表述；禁止行为全篇归一到 §2.2（原 §2.4、§7 汇报硬约束、§8 防疲劳中的禁止项）；原 §8 防疲劳节整体删除，非禁止项并入 §2.1 / §3；删除「（每次评审都会注入）」类解释性缀语；「评审通用要求」改名「评审任务」（与 architecture v2.1 同步） |
| v2.0 | 2026-08-28 | Owner 指令（SEE-1191 第三轮）：全量瘦身为框架性指引——删除评审动作清单、目录级评审范围、维度必查表、竞态剧本、假绿等价物明细 |
| v1.7 | 2026-08-28 | Owner 指令（SEE-1191 第二轮）：纠正建议范围语义——当次主题是焦点不是边界 |
| v1.6 | 2026-08-28 | Owner 指令（SEE-1191）：检查汇报直接发到本次创建的执行 issue 下，不新开 issue |
| v1.5 | 2026-08-28 | Owner 指令（SEE-1188）：移除新增建议数量上限 |
| v1.4.x | 2026-08-27 | 拼装脚本化及闭环自查修复 |
| v1.3 | 2026-08-27 | Owner backlog 报告指令：产出改 backlog 报告 issue（后被 v1.6 改为评论汇报） |
| v1 | 2026-08-27 | 初版，SEE-1183 任务 2 产出 |

后续修订原则：

- 每次修订须在表中带日期与一句话变更说明；
- 模板演化由 Archi 主导，重大结构变更需 Atlas 评审 + Owner 批准；
- 主题新增 / 删除须与 Owner 沟通确认；
- **指引粒度上限（Owner 指令 SEE-1191）**：任何修订不得 reintroduce 执行级细节（动作清单、具体命令、目录清单、必查表）；指引只写方向与契约。
