# Autopilot 脚本说明

> 本文档归集所有脚本型 autopilot 的脚本路径、参数、行为与输出说明，替代各 autopilot description 中的详细内容，使其保持"检出仓库 + 执行脚本 + 静默结束"的简洁形式。Agent 评审型 autopilot（三个周检）的实质条款在仓内 prompt 模板，本文档只记其调度信息与「台账合账」流程。

---

## 1. Agent Watchdog 卡死检测（已退役，SEE-1634）

> 本链已随 SEE-1634 整链退役（2026-11-25 Owner 裁决）：`autopilots/agent_watchdog.sh`、`autopilots/agent_watchdog.py` 与其专用模块 `autopilots/watchdog_report.py`、`autopilots/watchdog_state.py` 连同测试一并删除；平台 autopilot `25ba8a6f-aec5-4cfa-8fd7-c9eb6c54316b` 随本批收尾删除，删除前先备份 description 与触发器，备份附于 SEE-1634。退役理由：该巡检自 2026-06-19 之后没有再运行过。本节仅留退役说明，历史行为文档见 git 历史。

---

## 2. Issue 状态检查与催促（已退役，SEE-1634）

> 本链已随 SEE-1634 整链退役（2026-11-25 Owner 裁决）：`autopilots/issue_status_check.sh`、`autopilots/issue_status_check.py`、`autopilots/issue_status_analysis.py` 连同测试一并删除；平台 autopilot `2dd8fa65-514d-498b-8675-63bf8f188b96`（2026-11-16 起暂停）随本批收尾删除，删除前先备份 description 与触发器，备份附于 SEE-1634。退役理由：它的催促作用已被平台按 issue 设置的条件唤醒（issue wakeup）取代。本节仅留退役说明，历史行为文档见 git 历史。

---

## 3. 本地仓库巡检（已退役，SEE-1473 R3）

> 本链已随 SEE-1473 R3 整链退役（2026-10-27 Owner 裁决）：`autopilots/local_repo_check.py`/`.sh` 与其测试套件删除，autopilot `d655880c` 置 paused（保留历史可审计）。删除面已由平台 daemon gc 覆盖，本地巡检清理不再需要。本节仅留退役说明，历史行为文档见 git 历史。

---

## 4. 架构日检 Daily Architecture Check（Architecture Sweep）

> 每日 04:00（Asia/Hong_Kong，= 工具链日检 03:30 + 30 分钟）巡检，零写入共享分支：L0 为只读静态检查，周一附加的 L1 先在检出内自产全量 GUT junit 再跑静态检查。

- **Autopilot ID**: `5a40f7e4-2d76-46e8-821f-a3c0d7544235`
- **Assignee**: Chekky（agent `b2384294-919a-4a91-9f35-2c45848577aa`）
- **调度**: cron `0 4 * * *` Asia/Hong_Kong（trigger id `72c55517-7362-4a91-b396-6e0aad2e56e1`）
- **脚本路径**: `autopilots/architecture_sweep.sh`（wrapper，**唯一执行入口**：调用 Python 前对 KOL worktree 物化 submodule，L1 轮次另先自产全量 GUT junit；内部委托 `autopilots/architecture_sweep.py` 执行巡检）
- **执行方式**（一律经 wrapper，不直调 `.py`）:

```bash
# 日常 L0 巡检（与平台 autopilot Step 2 命令线一致；仓内执行去掉 dev-forge/ 前缀）
bash dev-forge/autopilots/architecture_sweep.sh \
  --execution-issue-id <本执行IssueID>

# 每周一（UTC，脚本内部判定基准）自动附加 L1 深度检查；其他日子可用 --l1 强制开启
bash autopilots/architecture_sweep.sh \
  --l1 --execution-issue-id <本执行IssueID>

# Revy 验证用：快速预览（跳过 gdlint 与 L1）
bash autopilots/architecture_sweep.sh \
  --dry-run --fast
```

### 执行步骤

1. 检出 `master`：`multica repo checkout https://github.com/tadki/KingOfLikes-Godot.git --ref master`
2. 经 wrapper 执行只读静态巡检（命令见「执行方式」）。wrapper 在调用 Python 脚本前，按巡逻 config（默认 `autopilots/configs/kol.json` 的 `repo_name`，`ARCH_SWEEP_CONFIG` 可覆盖）定位 KOL worktree，自动执行 `git submodule update --init --recursive` 物化红线 gitlink 并后置校验非空；物化失败（config 缺失 / repo_name 缺失 / worktree 定位失败 / update 失败 / 物化后红线目录仍空）一律非零退出 + 显式 JSON 错误，严禁静默降级（SEE-1460）。直连 GitHub 失败时 wrapper 自动回退平台镜像缓存重试一次（见「物化取件依赖」）；直连与回退均失败才整体非零退出（SEE-1482）

### 物化取件依赖（SEE-1482）

agent shell 的直连 git-over-HTTPS 可能被 egress 层 TLS 中断拦截（TCP 正常、ServerHello 前被掐断），物化依赖的 GitHub 取件路径不可达。wrapper 对此的持久化处置：

- 直连 `git submodule update --init --recursive` 失败时，按 `.gitmodules` 中红线 submodule 的 URL 推导平台镜像目录名（`https://github.com/tadki/godot-mcp.git` → `github.com+tadki+godot-mcp.git`），在平台镜像缓存 `<root>/<workspace-id>/<镜像名>` 定位 bare 镜像重试一次。
- 镜像 root 依次解析：`ARCH_SWEEP_MIRROR_ROOT`（显式覆盖，测试/运维用）→ `$MULTICA_TASK_WORKSPACES_ROOT/.repos`（daemon 实际布局）→ `~/.multica/workspaces/.repos`（文档备选布局）。
- 重试仅以**单次 git 调用作用域**的 `-c url.<镜像>.insteadOf=<URL>` 重写（另加 `-c protocol.file.allow=always`：镜像为本地 bare 仓，git ≥ 2.38.1 默认拒绝间接 submodule clone 走 file 传输）；**不写全局 git 配置、不改 `.gitmodules`**。
- checkout 仍由 pinned gitlink 内容寻址校验：镜像缺 pinned commit 时 `git submodule update` 自身失败，内容不符不可能判成功；「红线目录非空」后置校验对直连与回退两条路径同样生效。
- 直连与回退均无法物化时整体显式非零退出，Python 巡检层不感知此回退（保持只读，SEE-1460 契约不变）。
- 物化成功后 submodule gitdir 保留在本地（或 mirror worktree 存储），后续重跑无需再走网络。

### 参数说明

以下参数由 wrapper 透传至 `architecture_sweep.py`：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--workspace-root` | 当前 workspace 根 | Multica workspace 根目录（包含所有 worktree） |
| `--current-hash` | 自动检测 | 当前 worktree hash（脚本以 `workdir/KingOfLikes-Godot` 拼接） |
| `--dry-run` | 无 | 仅打印报告；不写 baseline/heartbeat/manifest/report 文件 |
| `--fast` | 无 | 跳过 gdlint 与 L1，仅跑 L0 快速项 |
| `--l1` | 无 | 强制开启 L1 周检（默认周一 UTC，脚本内部判定基准，自动开启） |
| `--execution-issue-id` | 空 | 本执行 Issue ID |

环境变量： `DRY_RUN=true`、`ARCH_SWEEP_L1=true`、`MULTICA_WORKTREE_HASH=<hash>`（wrapper 用）；`ARCH_SWEEP_CONFIG=<path>`（wrapper 物化步用的巡逻 config 覆盖）；`ARCH_SWEEP_MIRROR_ROOT=<path>`（wrapper 物化回退的平台镜像根覆盖，默认按 daemon 布局解析，见「物化取件依赖」）；`GODOT=<bin>`（L1 自产 junit 使用的 Godot 二进制，默认 `godot`）；`ARCH_SWEEP_GUT_IMPORT_TIMEOUT_SECONDS`（默认 900）、`ARCH_SWEEP_GUT_TIMEOUT_SECONDS`（默认 3600）（L1 GUT 导入/跑批超时护栏，见「检查维度」L1）。

### 检查维度

**L0 每日**（每次执行都跑）：
- `REDLINE_INIT/DELETED/MODIFIED/NEW` — `addons/godot_mcp/` SHA256 manifest 校验；仅豁免 pinned gitlink 树中未版本化的 Godot `*.import` / `.godot/` 导入副产物，且这些副产物不写入或重祝福 manifest；已版本化的同形文件仍按新增/修改/删除检出，pinned tree 无法读取时不豁免（fail-closed）
- `REDLINE_SKIPPED_UNINITIALIZED`（warn）— `addons/godot_mcp` gitlink 未物化时（`git submodule update --init` 未执行或失败）跳过整段红线比对，仅产出一条显式降级告警；此告警入 baseline，增量机制不会重复捕获，恢复覆盖需先物化 submodule（SEE-1460）
- `DEPRECATED_BRIDGE` — `@deprecated` 兼容桥存量
- `SEE_COMMENT` — `SEE-\d+` 注释存量
- `FILE_TOO_LONG` — 文件 > 800 行
- `FUNC_TOO_LONG` — 函数 > 50 行（轻量启发式）
- `AUTOLOAD_COUPLING` — 单文件引用 ≥ 5 个 autoloads（高耦合预警）
- `GAMESTATE_MIRROR_DIRECT` — 对 `GameState.{player_level|gold|total_likes|total_clicks}` 的直接赋值（含 `+=`/`-=`/`*=`/`/=`）；`_sync_*_to_game_state` 函数体内豁免
- `BLACKLIST_FUNCTION` — `OS.execute / OS.shell_open / OS.kill / get_tree().quit / SceneTree.quit` 业务代码内出现
- `GDLINT_NEW` — gdlint 警告增量（baseline diff；`--fast` 时跳过）

**L1 每周一（或 `--l1`）追加**：
- **自产 junit（SEE-1593）**：L1 轮次（非 `--dry-run`/`--fast`、kill switch 关闭）由 wrapper 先在本次被检检出内执行 `godot --headless --import` 与 `tests/run_tests.sh --all`，产出 junit 供现有 local 取源分支消费；junit 路径取自被检检出的 `.gutconfig.json` 的 `junit_xml_file`（去除 `res://` 前缀），该配置缺失、不可读或 `junit_xml_file` 为空时回退 `tests/reports/junit_report.xml`，不因缺失此配置中止 L1；输入与巡逻同一 HEAD，不依赖会被平台回收的 sibling slot。跑批前按解析后的路径清除本地 junit 及其时间戳变体，Python 层 local 候选同样只接受 7 天内的报告——上一轮残留不得被当作本轮输入（§SPEC-010）。跑批带超时护栏（`ARCH_SWEEP_GUT_IMPORT_TIMEOUT_SECONDS` 默认 900s、`ARCH_SWEEP_GUT_TIMEOUT_SECONDS` 默认 3600s）；import/跑批失败、超时或未产出 junit 均显式记录到 stderr 且**不阻断**后续静态巡检（输入缺失由下方规则表达）。此处对 `.gutconfig.json` 的空值回退仅决定 GUT junit 路径，不改变「执行步骤」中巡逻 config 缺失、`repo_name` 缺失及物化失败的显式非零退出契约
- `GUT_UNVERIFIED`（warn；连续 ≥2 个 L1 轮次无有效输入时升级为 error）— 「无有效输入」= 未解析到 junit、junit 零执行（`actual_tests==0`）或 stable 源 miss/stale，三类都推进 `gut_unverified_streak`，本轮 `actual_tests>0` 则归零。规则本身只在完全没有 junit 输入且未配置 stable 源时产出，属「未验证」而非产品信号（`gut_verified=false`）；junit 存在但零执行仍为下方 `GUT_SILENT_SKIP:error`，stable miss/stale 亦维持 error。连续次数写 `gut_unverified_streak`；状态来源为上一 L1 轮（`last_report.json`；若被工作日 L0 覆盖则回退 `baseline.jsonl` 中最近含 `gut_verified` 的记录）
- `GUT_SILENT_SKIP`（error）— 有 junit 但执行异常：全局实际执行数为 0、全局低于 95% 容差，或任一配置目录整体缺失/低于目录容差（D1 语义与 dedup 键不变）；已配置 stable 源却 miss/stale 仍为 error 并非零退出（SEE-1499 契约不放宽）
- 度量：`junit_source` 在命中本地/槽位/稳定源时为 `local`/`slot:<slot>`/`stable:<path>`，未解析到任何 junit 时为 `none`；`gut_verified` 仅在 L1 轮次写入（有 junit 且 `actual_tests>0` 为 true）
- 测试/代码比例趋势： `test_to_code_ratio`（test .gd 行数 / 非 test .gd 行数）
- autoload 引用矩阵与兼容桥趋势： 通过 baseline `metrics` 字段自然形成时序

### 状态文件（不写入共享分支）

- `~/.multica/arch-patrol/baseline.jsonl` — 每日一行： `{ts, metrics, findings_keys}`
- `~/.multica/arch-patrol/heartbeat.jsonl` — 心跳： `{ts, status, summary}`
- `~/.multica/arch-patrol/redline.manifest` — `addons/godot_mcp/` SHA256 manifest
- `~/.multica/arch-patrol/last_report.json` — 最近一次执行的结构化报告
- `~/.multica/arch-patrol/gut-last-run.log` — L1 自产 junit 的 import/跑批完整输出（每次 L1 覆盖）

### 防疲劳

- dedup key 基础为 `file:line + rule_id + severity`；`REDLINE_NEW/MODIFIED/DELETED` 另追加 `content_id` 内容哈希，同路径但内容不同的信号仍进入 `new_findings`，内容相同的重复信号继续去重。已在 baseline 中的 finding 不重复出现在 `new_findings`；`content_id` 仅用于 baseline 去重，不写入对外 report 的 `findings` / `new_findings`，report schema 不变，其他 finding 沿用原 key
- 心跳独立追加，无论是否有新告警
- 异常升级为滚动台账 issue 草稿由 Chekky 上游层消费（本脚本不自动 @）

### 严禁行为（脚本内部保证）

- 不修改 `project.godot`、不改 `addons/godot_mcp/`、不杀进程、不开 PR、不 @ 任何成员
- 所有写操作仅落在 `~/.multica/arch-patrol/`（例外：① wrapper 层 `git submodule update --init --recursive` 物化——按 gitlink pinned commit 恢复 `addons/godot_mcp/` 内容，属覆盖性恢复而非改动；② L1 自产 junit——写入被检检出内未版本化的 `tests/reports/`、`.godot/` 导入缓存及 `*.import` 副产物，不触碰受版本控制文件、不写共享分支）

### 退出码

- `0` — 全部检查通过
- `1` — 致命错误（锁冲突、repo 不存在；wrapper 层 submodule 物化失败，见「执行步骤」第 2 步）
- `2` — 至少一个检查阶段失败（SEE-1109：严禁静默 exit 0）

---

## 5. 架构半周检 Agent 评审（Architecture Review Refacty）

> 每周两次（周二 / 周五 03:00 Asia/Hong_Kong，= 工具链半周检 02:30 + 30 分钟）纯 agent 高维架构只读巡检。拼装已脚本化：执行 agent 每期运行 `autopilots/review-prompts/architecture/build_review_prompt.py`，脚本输出即当期完整评审 prompt。完整规格见 prompt 模板 `autopilots/review-prompts/architecture/prompts/architecture_review_prompt.md`。平台 description 只做薄壳（检出 → 跑拼装脚本 → 收尾），不复述实质条款。

- **Autopilot ID**: `a08b4ae1-737f-4c63-bc6f-fa0943b965f1`
- **Assignee**: Refacty（agent `3c6b6d88-ce6c-4e02-a78e-24ee08e70c85`）
- **执行模式**: `create_issue`（每次跑出一个执行 issue）
- **执行 issue 标题模板**: `架构半周检报告 {{date}}`（UTC YYYY-MM-DD；检查汇报以评论形式发到该执行 issue 下，不新开 issue）
- **调度**: cron `0 3 * * 2,5` Asia/Hong_Kong（trigger id `5d26c3bc-53b4-40dc-8be7-a436cd88a5bb`，与工具链半周检同为周二/周五）
- **拼装脚本**: `autopilots/review-prompts/architecture/build_review_prompt.py`（期号派生、四主题轮换 `(nth-1) % 4`：数据流与耦合 / 状态机与生命周期 / 模块边界与扩展点 / 可测性与反模式、占位符替换、Kill Switch 预检内置）
- **评审模板（脚本素材）**: `autopilots/review-prompts/architecture/prompts/architecture_review_prompt.md`
- **滚动台账**: `autopilots/review-prompts/architecture/ledger/YYYY-MM.md`（按月滚动，fingerprint 去重与趋势比对的数据底座）
- **期号计数器**: 与台账同目录的 `review-state.json`（随台账落仓，与工具链同构）

### 执行步骤

1. 检出被检仓库 `master`（只读）：`multica repo checkout https://github.com/tadki/KingOfLikes-Godot.git --ref master`；拼装脚本与台账所在的 dev-forge 用本执行 issue 的共享分支检出：`multica repo checkout https://github.com/tadki/dev-forge.git`
2. 运行拼装脚本生成当期评审任务：`python3 dev-forge/autopilots/review-prompts/architecture/build_review_prompt.py --output ./review_prompt.md`（退出码 `0` 正常 / `3` 本期跳过 / `2` 参数或模板错误，记台账后不重试 / `4` 见下一步）
3. 退出码为 4 时（拼装器无法确认有没有未合入的期次）：本期不派生期号、不写台账、不重试，也不用 `--nth` 强行补跑；把拼装器输出的那行错误原样作为一条简短评论发到本执行 issue，并在评论里按下一步的写法 @Atlas 请求排查。这是除「请合账」外唯一允许的 @
4. 照 `./review_prompt.md` 执行**只读**巡检（当次主题/指引是焦点而非边界——指引框架外、但只要落在本次巡检关注范围内的架构建议同样欢迎且鼓励），按其 §3「产出」把本期条目追加到台账，再把检查汇报（完整报告）作为评论发到本执行 issue 下
5. 台账落 main（Owner 2026-11-25 定案）：台账与期号计数器推到本执行 issue 的共享分支（`shared/<本期 issue 标识号>`），开台账 PR（目标 `main`），不自行合并、不直推 `main`；汇报评论的最末一段用正文写一句 `[@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5) 请合账`，这是除「请求排查」外唯一允许的 @。合入由 Atlas 按「台账合账」一节的固定步骤执行
6. 本执行 issue 置 backlog

### 严禁行为

- 不修改 `project.godot`、不改 `addons/godot_mcp/`、不杀进程；除台账 PR 外不开其他 PR；除「请合账」与退出码 4 时的「请求排查」两句外不 @ 任何成员
- 不 spawn 子代理、不持有 godot-mcp bridge
- 评审对象全程只读：KOL 仓库零写入、零推送；dev-forge 侧只写台账与期号计数器两个文件，且只推到本执行 issue 的共享分支
- 不自行合并台账 PR
- 不新开任何 issue（检查汇报直接发到本次创建的执行 issue 下）、不自动升级到 in_progress；升级走「滚动台账 → Atlas 周会裁决 → Atlas @ 责任人」单一决策链

---

## 6. 仓库结构周检（Repo Structure Check）

> 每周六 05:00（Asia/Hong_Kong）只读检查仓库文件与目录层面的结构健康：目录结构是否合理、文件是否归位、冗余文件清理候选。不深入代码内部。Agent 评审型，无拼装脚本、无期号：完整指引见仓内模板 `autopilots/review-prompts/repo-structure/prompts/repo_structure_review_prompt.md`，平台 description 只做薄壳（检出 → 读模板 → 收尾）。

- **Autopilot ID**: `4669e3e9-f85a-4294-844f-91fcbc8ca51f`
- **Assignee**: Refacty（agent `3c6b6d88-ce6c-4e02-a78e-24ee08e70c85`）
- **执行模式**: `create_issue`
- **执行 issue 标题模板**: `仓库结构周检报告 {{date}}`（UTC YYYY-MM-DD；检查汇报以评论形式发到该执行 issue 下，不新开 issue）
- **调度**: cron `0 5 * * 6` Asia/Hong_Kong（trigger id `d2df657d-aa2b-4277-b61b-6c433349dec7`；与半周检 02:30/03:00 周二五、日检 03:30/04:00 每日错开）
- **检查模板**: `autopilots/review-prompts/repo-structure/prompts/repo_structure_review_prompt.md`（全文即当期指引：检查范围、要做与禁止的事、报告骨架、台账体例）
- **检查范围**: 游戏代码域（KOL）+ 工具链域（dev-forge 为主，KOL 侧仅余 `.dev/` 与 `.github/workflows/`）；细目见模板 §1.1
- **滚动台账**: `docs/ledger/repo-structure/YYYY-MM.md`
- **收尾**: 本执行 issue 置 backlog（done 归 Owner）
- **防疲劳**: 除报告末尾那一句「请合账」外不 @、不指派、不催办；fingerprint 去重；无发现仍发汇报评论；清理建议只提报不执行

### 执行步骤

1. 检出被检仓库 `master`（只读）：`multica repo checkout https://github.com/tadki/KingOfLikes-Godot.git --ref master`；dev-forge 既是被检仓库也是台账所在，用本执行 issue 的共享分支检出：`multica repo checkout https://github.com/tadki/dev-forge.git`
2. 读当期检查指引并照做：`dev-forge/autopilots/review-prompts/repo-structure/prompts/repo_structure_review_prompt.md`
3. 按模板 §3 追加台账条目，把检查汇报作为评论发到本执行 issue 下。台账落 main（Owner 2026-11-25 定案）：台账推到本执行 issue 的共享分支（`shared/<本期 issue 标识号>`），开台账 PR（目标 `main`），不自行合并、不直推 `main`；汇报评论的最末一段用正文写一句 `[@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5) 请合账`，这是本流程唯一允许的 @。合入由 Atlas 按「台账合账」一节的固定步骤执行
4. 本执行 issue 置 backlog

### 严禁行为

- 不修复、不重构、不删文件、不挪文件（只检查提建议，清理决策归 Owner）
- 不深入代码内部（只看文件与目录层面）
- 不触碰 `addons/godot_mcp/`（vendored 只读红线）
- 除 dev-forge 的台账文件外不写任何仓库文件；KOL 仓库零写入、零推送
- 不自行合并台账 PR
- 不新开任何 issue（检查汇报直接发到本次创建的执行 issue 下）

---

## 7. 台账合账（三个周检系列共用，SEE-1634）

周检的台账只有进了 dev-forge `main` 才算落账。自 2026-11-25 起（Owner 定案，SEE-1634）合账固定由 Atlas 承接：执行者不自己合并，发完报告后请 Atlas 合；Atlas 按下面的固定步骤执行。本节是流程约定，不新增脚本。

### 三个系列的落点

| 系列 | 仓内指引 | 台账 | 期号计数器 |
|---|---|---|---|
| 工具链半周检 | `autopilots/review-prompts/toolchain/prompts/toolchain_review_prompt.md`（经拼装脚本生成当期任务） | `autopilots/review-prompts/toolchain/ledger/YYYY-MM.md` | 与台账同目录的 `review-state.json` |
| 架构半周检 | `autopilots/review-prompts/architecture/prompts/architecture_review_prompt.md`（经拼装脚本生成当期任务） | `autopilots/review-prompts/architecture/ledger/YYYY-MM.md` | 与台账同目录的 `review-state.json` |
| 仓库结构周检 | `autopilots/review-prompts/repo-structure/prompts/repo_structure_review_prompt.md`（无拼装脚本，全文即指引） | `docs/ledger/repo-structure/YYYY-MM.md` | 无 |

### 触发

执行者把台账（工具链、架构连同期号计数器）推到**本执行 issue 的共享分支**（`shared/<本期 issue 标识号>`），开一个台账 PR（目标 `main`），然后在报告评论的最末一段用正文写一句「请合账」并 @Atlas。Atlas 收到后随到随合。

周检流程里只允许两处 @Atlas：一处是上面的「请合账」；另一处是拼装器以退出码 4 结束时的「请求排查」——那一期没有派生期号，执行者不写台账、不重试，把拼装器输出的那行错误原样作为一条简短评论发到本执行 issue 并 @Atlas 请求排查（工具链、架构两个系列适用；仓库结构周检没有拼装脚本）。探测失败就宁可不跑一期，前提是失败要有人看见。其余场合一律不 @。

### Atlas 合账的固定步骤

1. **定位**：从「请合账」所在的报告 issue 找到台账 PR 与共享分支；同一系列若有更早的、仍开着的台账 PR，一并找出来。
2. **承接不丢行**：逐行核对 `main` 上该台账文件的每一行都仍按原顺序留在 PR 版本里——只允许追加，不允许改写或删除既有行，历史期次条目一行不动。
3. **期号同步**（工具链、架构）：PR 内台账最大期号等于期号计数器的 `nth`，合入后 `main` 上这个等式仍成立（日检 F6 对工具链的核对口径）。仓库结构周检无期号，跳过。
4. **CI**：台账 PR 的 lint、engine-tests、console 三项检查全部通过。
5. **rebase 合入**：用 rebase 方式合入 `main`（本仓只允许 rebase，不产生 merge commit、不 squash）；合入后关闭被本期承接、取代的旧台账 PR，在旧 PR 上注明由哪个 PR 承接。
6. **归档前人工核对**：要归档（置 cancelled）或收起一期报告 issue 之前，先确认该期条目已经在 `main` 的台账里；没落账的不归档。

以上任一项不成立就不合入，缺什么在该台账 PR 上写明。

---

## Kill Switch（统一入口，SEE-1440）

规范入口 = paused 文件 `~/.multica/toolchain-reports/DISABLED`（评审拼装器与全部脚本型
autopilot 共用，见 `autopilots/kill_switch.py`）：

- 放置该文件即暂停本期评审与 autopilot 的写操作（评审拼装器 exit 3 安静跳过）。
- `KILL_SWITCH=true` 环境变量保留为会话级临时覆盖，语义与 paused 文件一致。
- 显式 `--kill-switch true|false` 参数优先于上述默认值。
- `toolchain/toolchain_daily_check.py` F5 维度核对单源状态：历史别名
  `autopilots/review-prompts/toolchain/ledger/DISABLED` 仍生效，但会告警提示收敛到规范入口。

---

## 共享依赖

所有脚本共享以下模块：

- `autopilots/multica_helpers.py`: 提供 `AGENT_MAP`、`AGENT_NAME_MAP`、`multica_cli`、`multica_stdin_cmd`、文件锁、退避重试等。
- `autopilots/kill_switch.py`: Kill Switch 单源（paused 文件 + `KILL_SWITCH` env）。

## 通用原则

- 脚本型 autopilot 的 description 只保留"检出仓库 → 执行脚本 → 静默结束"，不重复脚本细节。
- Agent 评审型 autopilot（工具链半周检、架构半周检、仓库结构周检）的 description 同样只做薄壳：检出、运行拼装脚本（仓库结构周检是读仓内模板）、收尾三步。评审规则与报告骨架只在仓内模板里，description 不复述；收尾一步只留「台账推共享分支、开台账 PR、报告末尾请合账」这一句约定，另带退出码说明——拼装器以退出码 4 结束时没有拼装产物，执行者只能从 description 读到处置。
- 所有脚本相关说明以本文档为准。
