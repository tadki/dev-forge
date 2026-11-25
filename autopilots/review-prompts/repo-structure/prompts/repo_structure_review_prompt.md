# 仓库结构周检 Agent 检查 Prompt 模板

> 版本：v1.0（2026-11-25，SEE-1634：指引入仓。此前指引只存在于平台 description，台账路径多写一层、占位符未被替换、收尾置 done；入仓时逐项订正，并补上「台账落 main」与「请合账」）
> 调度方：Multica autopilot `4669e3e9-f85a-4294-844f-91fcbc8ca51f`（每周六 05:00 Asia/Hong_Kong）
> 执行方：具备仓库只读访问权限的检查 agent（平台当前派 Refacty；可按需轮换或固定）
> 性质：模板（prompt 文本），非可执行脚本。**没有拼装脚本**：本文件全文即当期完整检查指引，执行 agent 直接读本文件；平台 description 只做薄壳（检出 → 读本文件 → 收尾），不复述实质条款。
> **指引粒度约定（Owner 指令）**：本模板只给框架与方向——查什么、什么算问题、怎么汇报、什么不能做。**不规定怎么查、查哪些文件、跑哪些命令**；具体执行方法由检查 agent 自主决定，允许发挥。

---

## 0. 模板使用说明（给调度器看）

| 字段 | 取值 | 说明 |
|---|---|---|
| 调度频率 | 每周六 05:00（Asia/Hong_Kong） | 与半周检（周二 / 周五 02:30、03:00）、日检（03:30、04:00）错开 |
| 指引来源 | 本文件全文 | 无拼装脚本、无期号、无主题轮换 |
| 被检仓库 | KingOfLikes-Godot `master`（只读）与 dev-forge（只读） | dev-forge 的台账文件是唯一的写入对象 |
| 输出回写 | 见 §3 产出 | 检查汇报以评论形式发到本次 autopilot 创建的执行 issue 下（不新开 issue），评论末尾带一句「请合账」；台账推到本执行 issue 的共享分支并开台账 PR，由 Atlas 合入 main（见 §2.1） |
| 收尾 | 本执行 issue 置 backlog | 与另两个周检系列一致；done 归 Owner |

---

## 1. 检查任务

你是本期仓库结构检查 agent，对 `KingOfLikes-Godot` 仓库 master 分支与 `dev-forge` 仓库做**只读**检查：从宏观上检查当前项目与工具链的文件夹结构是否合理、所有文件是否存放在合适的位置、有没有需要清理的冗余文件。只看文件与目录层面，不深入代码内部。

### 1.1 检查范围

检查范围分两个域：

- **游戏代码域**（KOL，包括但不限于）：`autoload/`、`systems/`、`scenes/`、`resources/`、`tests/`、`docs/`。结构合理性的对照基准是 `docs/project/DESIGN.MD` 的归集约定。
- **工具链域**：dev-forge 仓库（工具链真源，检查其 `claude-hooks/`、`autopilots/`、`adapters/`、`launch/`、`bootstrap/`、`tests/`、`.github/workflows/` 等目录的归集约定）；KOL 侧工具链域仅余 `.dev/`（env / repo-sync / scripts / logs 等；review-prompts、repo-structure、toolchain、autopilots 已全部从 KOL 迁到 dev-forge）与 `.github/workflows/`。

### 1.2 核心关注方向

目录结构与归集约定是否一致；文件是否放在约定位置（有无放错域、放错层的新文件）；冗余文件候选（无引用的 scene / resource / 脚本、临时产物、过期文档、重复副本）。

---

## 2. 指引和规则

### 2.1 要做的事

- 检查前先了解以下背景，不要凭空假设：
  - 两仓库的默认分支（KOL `master`、dev-forge `main`，只读），按域自行决定探索范围；
  - `docs/project/DESIGN.MD` 的目录归集约定（游戏代码域的对照基准）；
  - 上一期结构检查台账：dev-forge `docs/ledger/repo-structure/YYYY-MM.md`（用于比对趋势线与条目去重）。
- 检查完成后把本期条目追加到台账当期月份文件（`docs/ledger/repo-structure/` 下；没有当月文件就新建），供下期去重与趋势比对。
- 台账落 main（Owner 2026-11-25 定案，SEE-1634）：本期台账推到**本执行 issue 的共享分支**（`shared/<本期 issue 标识号>`，即 issue 元数据的 `working_branch`），并以它开一个台账 PR（目标 `main`，标题含「台账」二字）。**不自行合并**、不直推 `main`，合入由 Atlas 负责：汇报评论的最末一段用正文写一句 `[@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5) 请合账`（不要放进代码块或反引号，否则不触发）。这一句是本流程**唯一允许的 @**，其余场合仍适用 §2.2。本条只动 dev-forge 的台账文件，两个被检仓库的其余部分与 KOL 全程只读。同一系列更早一期的台账 PR 若还没合入，先把它的台账内容原样承接进来（不改其行）再追加本期条目——本期 PR 取代旧 PR，旧 PR 由 Atlas 合账时关闭。Atlas 合账的固定步骤见 `docs/autopilots.md` 的「台账合账」一节。
- 检查过程中遇到结构看不懂、上下文不足以支撑判断的情况时，先用 `/recall` 召回相关记忆（历史决策、既有教训）再下结论，不要靠猜。
- 清理建议只提报，不执行——所有"该删 / 该挪"的结论都是建议，交 Owner 决定。

### 2.2 禁止做的事

- 不修复、不重构、不删文件、不挪文件（只检查提建议）；
- 不新开任何 issue / discussion——检查汇报只发一条评论到本次执行 issue（见 §3）；
- 除 §2.1「台账落 main」里的那一句「请合账」外，不 @ 任何人；不设 assignee、不催办；
- 不重复提报台账中已存在且状态未变化的条目（去重规则见 §3.3）；
- 不深入代码内部（只看文件与目录层面）；
- 不触碰 `addons/godot_mcp/`（vendored 只读红线，其内部结构不在检查范围）；
- 除 dev-forge 的台账文件外不写任何仓库文件；不给 KOL 开 PR、不向 KOL 推送。

---

## 3. 产出

检查完成后依次做四件事：① 把本期条目追加到台账（§3.2）；② 台账落 main——推共享分支、开台账 PR，不自行合并（§2.1）；③ 把 §3.1 骨架改写/填空（删占位行，填上台账 PR 号）写入 `./repo_structure_report.md`；④ 以该文件为正文发评论到本执行 issue，评论最末一段按 §2.1 的写法用正文写「请合账」。最后把本执行 issue 的状态设置为 backlog（不置 done——done 归 Owner）。

```bash
multica issue comment add <本执行IssueID> \
  --content-file ./repo_structure_report.md
```

无发现仍发（正文写「本期无发现」）。

### 3.1 报告骨架（评论正文）

从骨架改写：删除占位行，尖括号里的提示换成实际值。

```markdown
## 本期元信息

- 日期：<本期日期，UTC YYYY-MM-DD>
- 执行 agent：<本期执行 agent 名>

## 结构问题与清理建议（无则写「本期无发现」）

| # | 域（游戏代码/工具链） | 位置 file/dir | 问题（错位/冗余/结构不合理） | 建议（挪到哪/删除依据） | fingerprint |
|---|------|------|------|------|-------------|
| 1 | | | | | |

## 上一期条目状态更新（无则写「无」）

- fingerprint `...`：仍存在 / 已处理 / 部分处理（一句话证据）

## 台账 PR（落 main）

- 台账 PR：<#号或链接>（台账已推到本执行 issue 的共享分支，未自行合并）
```

### 3.2 台账

台账是 dev-forge 的 `docs/ledger/repo-structure/YYYY-MM.md`（按月一个文件，滚动追加；不面向 Owner 阅读，Owner 可见的完整汇报在每期执行 issue 的评论里）。期次条目的体例沿用台账既有条目：标题写「YYYY-MM-DD 仓库结构周检（执行 agent，SEE-本期 issue 号）」，正文先写两仓基线（commit）与本期条目数、上期条目的核对结论，再接条目表（`fingerprint | 路径 | 类别 | 状态`）。台账只追加本期条目，不改写、不删除既有行——Atlas 合账前会逐行核对 `main` 上的既有行都还在原位（见 `docs/autopilots.md` 的「台账合账」一节）。

### 3.3 条目去重

`fingerprint = sha1(规范化(path) + 问题类型关键词)`，取前 10 位——位数与算法每期固定，不要换口径（同一问题各期指纹口径不一，台账就查重失效）。fingerprint 已存在且状态未变化 → 不重复提报，只在「上一期条目状态更新」写一行；已处理 → 标注「已处理 + 证据」。同一位置、同一问题沿用台账里已有的 fingerprint；位置或问题实质变了才另立新指纹，并在条目里注明原指纹。

---

## 4. 模板版本与演化

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-11-25 | SEE-1634（Owner 2026-11-25 定案）：指引入仓，取代平台 description 里的完整指引。相对原 description：台账路径订正为 `docs/ledger/repo-structure/YYYY-MM.md`（原多写一层 `ledger/`），去掉不会被替换的占位符，收尾由置 done 改为置 backlog；新增「台账落 main」与「请合账」（§2.1、§3）、台账条目体例与指纹口径（§3.2、§3.3）；两仓默认分支写清（KOL `master`、dev-forge `main`） |

后续修订原则：

- 每次修订须在表中带日期与一句话变更说明；
- 模板演化由 Archi 主导，重大结构变更需 Atlas 评审 + Owner 批准；
- **指引粒度上限（Owner 指令 SEE-1191）**：任何修订不得 reintroduce 执行级细节（动作清单、具体命令、目录清单、必查表）；指引只写方向与契约。
