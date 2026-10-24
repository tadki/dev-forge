# Autopilot 脚本说明

> 本文档归集所有脚本型 autopilot 的脚本路径、参数、行为与输出说明，替代各 autopilot description 中的详细内容，使其保持"检出仓库 + 执行脚本 + 静默结束"的简洁形式。

---

## 1. Agent Watchdog 卡死检测

- **Autopilot ID**: `25ba8a6f-aec5-4cfa-8fd7-c9eb6c54316b`
- **脚本路径**: `autopilots/agent_watchdog.py`
- **执行方式**:

```bash
python autopilots/agent_watchdog.py \
  --no-dry-run \
  --max-restarts-per-hour 3 \
  --verbose \
  --execution-issue-id <本执行IssueID>
```

### 参数说明

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--no-dry-run` | 无 | 实际执行模式（默认开启 dry-run） |
| `--max-restarts-per-hour` | `3` | 每个 issue 每小时最多重启次数 |
| `--verbose` | 无 | 输出详细日志 |
| `--execution-issue-id` | 空 | 本执行 Issue ID，脚本会把报告发布到该 issue |

### 行为说明

1. 获取所有 workspace agent 列表（排除 Atlas 和自身）。
2. 对每个 agent 获取 `failed/cancelled` tasks。
3. 检测被 `idle_watchdog` 自动杀死的任务（status=failed，error 包含 `"idle watchdog"`）。
4. 验证被 kill 的任务是 issue 的最新 run，且 issue 状态不在 `done/cancelled/blocked/wont_fix`。
5. 应用每小时重启次数限流。
6. 对通过限流检查的任务执行 `multica issue rerun`。
7. 生成 JSON 报告并发布评论到 `--execution-issue-id`。

### 输出 JSON 字段速查

- `summary`: 扫描 agent 数、scanned tasks 数、idle_watchdog kills 数、reruns 数、Kill Switch 状态。
- `agents_scanned`: 被扫描的 agent 列表。
- `scanned_tasks`: 扫描到的 failed/cancelled tasks 列表。
- `idle_watchdog_kills`: 检测到的被 idle_watchdog 杀死的任务列表。
- `rerun_results`: 重启执行结果。
- `skipped_tasks`: 因限流跳过的任务列表。
- `kill_switch`: Kill Switch 是否触发。

### 故障排查

- **报告未发布到执行 Issue**: 检查 `--execution-issue-id` 是否正确。
- **rerun 未执行**: 确认 issue 状态不在 `NO_RERUN_ISSUE_STATUSES`（`done/cancelled/blocked/wont_fix`）。
- **Kill Switch 触发**: 错误率超过阈值时进入纯输出模式，需人工检查 workspace 健康状态。

---

## 2. Issue 状态检查与催促

- **Autopilot ID**: `2dd8fa65-514d-498b-8675-63bf8f188b96`
- **脚本路径**: `autopilots/issue_status_check.py`
- **执行方式**:

```bash
python autopilots/issue_status_check.py \
  --no-dry-run \
  --verbose \
  --alert-issue-id <本执行IssueID>
```

### 参数说明

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--no-dry-run` | 无 | 实际执行（发送催促评论、@mention） |
| `--verbose` | 无 | 输出详细日志 |
| `--alert-issue-id` | 空 | 本执行 Issue ID（Kill Switch 告警目标） |
| `--kill-switch` | `false` | 纯输出模式（故障降级） |

### 行为说明

1. 扫描所有 issue 的状态与元数据。
2. 按规则分类：
   - `need_push`: 可以催促推进的 issue。
   - `need_push_decision`: 需要决策后才能推进的 issue。
   - `running`: 正在执行中的 issue（任何尚未到达终态的 run：queued / dispatched / running 都会归入本类，不会发送催促）。
   - `no_assignee`: 无负责人的 issue。
3. `running` 类别的 issue 不会发送催促；其余类别仅在非 dry-run 且 Kill Switch 未触发时，发送催促评论或 @mention。
4. 输出 JSON 汇总。

> cancelled 状态 issue 不会被扫描；done 状态 issue 已过滤。

### 输出 JSON 字段速查

- `summary`: 总 issue 数、状态统计、分类统计。
- `need_push`: 可以催促的 issue 列表。
- `need_push_decision`: 需要决策的 issue 列表。
- `running`: 执行中的 issue 列表。
- `no_assignee`: 无负责人的 issue 列表。
- `push_actions`: 催促发送结果列表。
- `push_actions_summary`: 催促发送结果汇总。
- `kill_switch`: Kill Switch 状态。
- `kill_switch_alert`: Kill Switch 告警信息（若触发）。

### 故障排查

- **未发送催促**: 检查是否在 `--no-dry-run` 模式下；Kill Switch 触发时会降级为纯输出。
- **Kill Switch 触发**: 错误率或 issue 数量超过阈值，需人工检查。

---

## 3. 本地仓库巡检

- **Autopilot ID**: `d655880c-d256-454e-898f-1cae6f71deea`
- **脚本路径**: `autopilots/local_repo_check.py`
- **执行方式**:

```bash
python autopilots/local_repo_check.py \
  --execution-issue-id <本执行IssueID>
```

### 参数说明

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--workspace-root` | 当前 workspace 根目录 | 巡检的 workspace 根目录 |
| `--current-hash` | 自动检测 | 当前 worktree hash，用于跳过自身 |
| `--dry-run` | 无 | 仅预览，不执行删除等破坏性操作 |
| `--execution-issue-id` | 空 | 执行 Issue ID，用于报告与状态更新 |

### 行为说明

1. 扫描所有 worktree 目录。
2. 检查每个 worktree 的 git 状态。
3. 自动删除已 push 且 git 干净的 worktree（issue 状态为 `done/cancelled`）。
4. 如有需要决策的仓库：创建汇总 issue、添加标签、@mention 相关 agent。
5. 在 `--execution-issue-id` 中汇报结果并标记为 `done`。
6. 所有仓库正常时静默结束并标记 `done`。

> 默认 `DRY_RUN=false`（实际执行）；如需预览，加 `--dry-run`。

### 输出 JSON 字段速查

- `summary`: 总 worktree 数、已删除数、需决策数、异常数。
- `deleted`: 已删除的 worktree 列表。
- `need_decision`: 需要决策的 worktree 列表。
- `errors`: 异常列表。

### 故障排查

- **执行 Issue 未标记 done**: 检查 `--execution-issue-id` 是否正确；脚本失败时不会标记 done，下次巡检会重新执行。
- **worktree 未被删除**: 确认 issue 状态为 `done` 或 `cancelled`，且本地无未提交改动。

---

## 4. 架构日检 Daily Architecture Check（Architecture Sweep）

> 每日 04:00（Asia/Hong_Kong，= 工具链日检 03:30 + 30 分钟）只读静态巡检，零写入共享分支；周一自动附加 L1 深度检查。

- **Autopilot ID**: `5a40f7e4-2d76-46e8-821f-a3c0d7544235`
- **Assignee**: Chekky（agent `b2384294-919a-4a91-9f35-2c45848577aa`）
- **调度**: cron `0 4 * * *` Asia/Hong_Kong（trigger id `72c55517-7362-4a91-b396-6e0aad2e56e1`）
- **脚本路径**: `autopilots/architecture_sweep.sh`（wrapper，**唯一执行入口**：调用 Python 前对 KOL worktree 物化 submodule；内部委托 `autopilots/architecture_sweep.py` 执行巡检）
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
2. 经 wrapper 执行只读静态巡检（命令见「执行方式」）。wrapper 在调用 Python 脚本前，按巡逻 config（默认 `autopilots/configs/kol.json` 的 `repo_name`，`ARCH_SWEEP_CONFIG` 可覆盖）定位 KOL worktree，自动执行 `git submodule update --init --recursive` 物化红线 gitlink 并后置校验非空；物化失败（config 缺失 / repo_name 缺失 / worktree 定位失败 / update 失败 / 物化后红线目录仍空）一律非零退出 + 显式 JSON 错误，严禁静默降级（SEE-1460）

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

环境变量： `DRY_RUN=true`、`ARCH_SWEEP_L1=true`、`MULTICA_WORKTREE_HASH=<hash>`（wrapper 用）；`ARCH_SWEEP_CONFIG=<path>`（wrapper 物化步用的巡逻 config 覆盖）。

### 检查维度

**L0 每日**（每次执行都跑）：
- `REDLINE_INIT/DELETED/MODIFIED/NEW` — `addons/godot_mcp/` SHA256 manifest 校验
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
- `GUT_SILENT_SKIP` — `.gutconfig.json` 预期测试数 vs `tests/reports/junit_report.xml` 实跑数差值
- 测试/代码比例趋势： `test_to_code_ratio`（test .gd 行数 / 非 test .gd 行数）
- autoload 引用矩阵与兼容桥趋势： 通过 baseline `metrics` 字段自然形成时序

### 状态文件（不写入共享分支）

- `~/.multica/arch-patrol/baseline.jsonl` — 每日一行： `{ts, metrics, findings_keys}`
- `~/.multica/arch-patrol/heartbeat.jsonl` — 心跳： `{ts, status, summary}`
- `~/.multica/arch-patrol/redline.manifest` — `addons/godot_mcp/` SHA256 manifest
- `~/.multica/arch-patrol/last_report.json` — 最近一次执行的结构化报告

### 防疲劳

- dedup key = `file:line + rule_id + severity`，已在 baseline 中的 finding 不重复出现在 `new_findings`
- 心跳独立追加，无论是否有新告警
- 异常升级为滚动台账 issue 草稿由 Chekky 上游层消费（本脚本不自动 @）

### 严禁行为（脚本内部保证）

- 不修改 `project.godot`、不改 `addons/godot_mcp/`、不杀进程、不开 PR、不 @ 任何成员
- 所有写操作仅落在 `~/.multica/arch-patrol/`（唯一例外：wrapper 层 `git submodule update --init --recursive` 物化——按 gitlink pinned commit 恢复 `addons/godot_mcp/` 内容，属覆盖性恢复而非改动）

### 退出码

- `0` — 全部检查通过
- `1` — 致命错误（锁冲突、repo 不存在；wrapper 层 submodule 物化失败，见「执行步骤」第 2 步）
- `2` — 至少一个检查阶段失败（SEE-1109：严禁静默 exit 0）

---

## 5. 架构半周检 Agent 评审（Architecture Review Refacty）

> 每周两次（周二 / 周五 03:00 Asia/Hong_Kong，= 工具链半周检 02:30 + 30 分钟）纯 agent 高维架构只读巡检。拼装已脚本化：执行 agent 每期运行 `.dev/review-prompts/architecture/build_review_prompt.py`，脚本输出即当期完整评审 prompt。完整规格见 prompt 模板 `.dev/review-prompts/architecture/prompts/architecture_review_prompt.md` 与 autopilot description 本地副本 `.dev/autopilot_descriptions/architecture_review_refacty.md`。

- **Autopilot ID**: `a08b4ae1-737f-4c63-bc6f-fa0943b965f1`
- **Assignee**: Refacty（agent `3c6b6d88-ce6c-4e02-a78e-24ee08e70c85`）
- **执行模式**: `create_issue`（每次跑出一个执行 issue）
- **执行 issue 标题模板**: `架构半周检报告 {{date}}`（UTC YYYY-MM-DD；检查汇报以评论形式发到该执行 issue 下，不新开 issue）
- **调度**: cron `0 3 * * 2,5` Asia/Hong_Kong（trigger id `5d26c3bc-53b4-40dc-8be7-a436cd88a5bb`，与工具链半周检同为周二/周五）
- **拼装脚本**: `.dev/review-prompts/architecture/build_review_prompt.py`（期次自增、四主题轮换 `(nth-1) % 4`：数据流与耦合 / 状态机与生命周期 / 模块边界与扩展点 / 可测性与反模式、占位符替换、Kill Switch 预检内置）
- **评审模板（脚本素材）**: `.dev/review-prompts/architecture/prompts/architecture_review_prompt.md`
- **滚动台账**: `.dev/review-prompts/architecture/ledger/YYYY-MM.md`（按月滚动，fingerprint 去重与趋势比对的数据底座）

### 执行步骤

1. 检出 `master`：`multica repo checkout https://github.com/tadki/KingOfLikes-Godot.git --ref master`
2. 运行拼装脚本生成当期评审任务：`python3 KingOfLikes-Godot/.dev/review-prompts/architecture/build_review_prompt.py --output ./review_prompt.md`（退出码 0 正常 / 3 本期跳过 / 2 错误记台账）
3. 照 `./review_prompt.md` 执行**只读**巡检（当次主题/指引是焦点而非边界——指引框架外、但只要落在本次巡检关注范围内的架构建议同样欢迎且鼓励），按其末节「7. 产出」把检查汇报（完整报告）作为评论发到本执行 issue 下 + 台账追加
4. 本执行 issue 标 done

### 严禁行为

- 不修改 `project.godot`、不改 `addons/godot_mcp/`、不杀进程、不开 PR、不 @ 任何成员
- 不 spawn 子代理、不持有 godot-mcp bridge
- 不修改任何仓库文件、不推送任何分支
- 不新开任何 issue（检查汇报直接发到本次创建的执行 issue 下）、不自动升级到 in_progress；升级走「滚动台账 → Atlas 周会裁决 → Atlas @ 责任人」单一决策链

---

## 6. 仓库结构周检（Repo Structure Check）

> 每周六 05:00（Asia/Hong_Kong）只读检查仓库文件与目录层面的结构健康：目录结构是否合理、文件是否归位、冗余文件清理候选。不深入代码内部。description 即完整指引（Agent 评审型，无脚本）。

- **Autopilot ID**: `4669e3e9-f85a-4294-844f-91fcbc8ca51f`
- **Assignee**: Archi（agent `809951ab-c70c-48c3-b0d6-7b16b49e1ce3`）
- **执行模式**: `create_issue`
- **执行 issue 标题模板**: `仓库结构周检报告 {{date}}`（UTC YYYY-MM-DD；检查汇报以评论形式发到该执行 issue 下，不新开 issue）
- **调度**: cron `0 5 * * 6` Asia/Hong_Kong（trigger id `d2df657d-aa2b-4277-b61b-6c433349dec7`；与半周检 02:30/03:00 周二五、日检 03:30/04:00 每日错开）
- **检查范围**: 游戏代码域（包括但不限于 `autoload/`、`systems/`、`scenes/`、`resources/`、`tests/`、`docs/`；对照 `docs/project/DESIGN.MD` 归集约定）+ 工具链域（包括但不限于 `.dev/`、`.claude/hooks/`、`.github/workflows/`）
- **滚动台账**: `.dev/repo-structure/ledger/YYYY-MM.md`
- **防疲劳**: 不自动 @、不指派、不催办；fingerprint 去重；无发现仍发汇报评论；清理建议只提报不执行

### 严禁行为

- 不修复、不重构、不删文件、不挪文件（只检查提建议，清理决策归 Owner）
- 不深入代码内部（只看文件与目录层面）
- 不触碰 `addons/godot_mcp/`（vendored 只读红线）
- 不新开任何 issue（检查汇报直接发到本次创建的执行 issue 下）

---

## Kill Switch（统一入口，SEE-1440）

规范入口 = paused 文件 `~/.multica/toolchain-reports/DISABLED`（评审拼装器与全部脚本型
autopilot 共用，见 `autopilots/kill_switch.py`）：

- 放置该文件即暂停本期评审与 autopilot 的写操作（评审拼装器 exit 3 安静跳过）。
- `KILL_SWITCH=true` 环境变量保留为会话级临时覆盖，语义与 paused 文件一致。
- 显式 `--kill-switch true|false` 参数优先于上述默认值。
- `toolchain/toolchain_daily_check.py` F5 维度核对单源状态：历史别名
  `review-prompts/toolchain/ledger/DISABLED` 仍生效，但会告警提示收敛到规范入口。

---

## 共享依赖

所有脚本共享以下模块：

- `autopilots/multica_helpers.py`: 提供 `AGENT_MAP`、`AGENT_NAME_MAP`、`multica_cli`、`multica_stdin_cmd`、文件锁、退避重试等。
- `autopilots/kill_switch.py`: Kill Switch 单源（paused 文件 + `KILL_SWITCH` env）。
- `autopilots/watchdog_report.py` / `autopilots/watchdog_state.py`: 仅 Agent Watchdog 使用。

## 通用原则

- 脚本型 autopilot 的 description 只保留"检出仓库 → 执行脚本 → 静默结束"，不重复脚本细节。
- 所有脚本相关说明以本文档为准。
