# CC Hooks v2 迁移对照清单（SPEC-008）— P0 基线段

> SEE-1330 §SPEC-008 交付物。维护人：Revy（各阶段 QA 核验），Archi 终审。
> 本文档 P0 段仅填「迁移前基线」；「迁移后」列自 P1 起逐格填写。
> 基线依据 = issue description 现状基线关键事实 + 对 `.claude/hooks/`、`.dev/hooks/dispatcher.sh`、用户级 settings 注册布局的独立读取（S4 QA，2026-09-20，HEAD `fa330070`）。

## 1. v1 架构基线（全 hook 公共层）

| 维度 | 迁移前基线（v1） |
|---|---|
| 注册唯一真源 | 用户级 `~/.claude/settings.json`（11 项注册）；仓库 `.claude/settings.json` 无 hooks |
| 调用链 | `hook-wrapper.sh → dispatcher.sh → 业务脚本` 三层；wrapper 传 `<event> <alias>`，dispatcher 按 alias 路由 |
| dispatcher 路由 | 约定路由 `.claude/hooks/<alias>.sh` + 3 个显式 case（skill-check/skill-check-post→pre-comment-skill-check、auto-pr→auto-pr-on-stop、unified-hook→v2 引擎）；unified-hook case **全局部署位优先**（P1 cutover 修正，见 3.5-after #7） |
| dispatcher 输出协议 | exit≠0 → 透传原 stdin 且以原退出码退出；exit 0 + 输出含 `hookSpecificOutput` → 透传 hook 输出；否则透传原 stdin |
| firelog | 三级落点：repo `.claude/hook-fire.log` → `$HOME/.claude/hook-fire.log`；dispatcher 记 alias 行 + `[result]` 行 |
| fail-open 基调 | skill-check / mention-check / repo-checkout / auto-pr fail-open；gdformat-gdlint fail-close |

## 2. 12 hook × 行为维度迁移前基线表

> 「注册时点/触发条件」以实机 settings 注册布局为准（11 项注册 + dispatcher alias）。

### 2.1 pre-comment-skill-check（skill-check / skill-check-post）

| 维度 | 迁移前基线 |
|---|---|
| 注册时点 | PreToolUse `*`（skill-check）+ PostToolUse `Write\|Edit`（skill-check-post） |
| 触发条件 | 13 条规则（skill-check-rules.json）：agent 维度 + comment_add / any_tool / file_edit trigger + condition 树 |
| 动作语义 | block（自查后放行，sentinel 幂等）/ remind（per-run 一次）；D4 无条件规则；Chekky 例外；SEE-1238 tool_name 维度；doc-reminder disabled |
| 拦截通道 | `permissionDecision:deny` + exit 0 |
| 状态与幂等 | /tmp sentinel（键含 MULTICA_TASK_ID）；remind per-run 一次 |
| fail-open | 引擎异常 → 放行 |
| 输出协议 | hookSpecificOutput JSON（deny / additionalContext） |
| env 依赖 | MULTICA_AGENT_NAME、MULTICA_TASK_ID、PROJECT_ROOT；firelog 三级 |

### 2.2 mention-check

| 维度 | 迁移前基线 |
|---|---|
| 注册时点 | PreToolUse `Bash` |
| 触发条件 | `multica issue comment add` 命令段（fastpath + --content-file/--content 读取） |
| 动作语义 | 正文无 @mention → 拦截提醒补 mention；no-mention sentinel（see469）放行重复发布 |
| 拦截通道 | deny JSON + exit 0 |
| 状态与幂等 | mention sentinel（同 run 二次发布不再拦截） |
| fail-open | 读正文失败等 → 放行 |
| 输出协议 | deny JSON（node 序列化防注入） |
| env 依赖 | MULTICA_AGENT_NAME、PROJECT_ROOT |


### 2.2-after mention-check（S6 迁移后，2026-09-20）

| 维度 | 迁移后 | 备注 |
|---|---|---|
| 注册时点 | unified-hook 9 时点全 `*`（cutover 后）→ 引擎内 when: tool Bash | 触发面收敛至 when |
| 触发条件 | 挂载规则 `mention-check-mount`：on PreToolUse + tool Bash + agents.except [Chekky]；命令段判定/正文读取仍在脚本内（零改动） | 双层白名单（agents 顶层 + 脚本内）等价 |
| 动作语义 | run_script 挂载 `mention-check.sh`，deny JSON 经引擎 stdout 协议直通 | 脚本零改动 |
| 拦截通道 | deny JSON（permissionDecision=deny）+ 引擎 exit 0 —— 与 v1 相同形态 | stdout 协议直通 |
| 状态与幂等 | 脚本内 sentinel（mention-check-pass/no-mention-<TASK_ID>）不变 | 引擎不写 mention sentinel |
| fail-open | 脚本读正文失败等 → 脚本内放行；挂载/引擎层异常 → 引擎 fail-open 放行 | 双层 |
| 输出协议 | 脚本 stdout hookSpecificOutput 由引擎原样采纳 | P0 已有机制 |
| env 依赖 | MULTICA_AGENT_NAME/MULTICA_TASK_ID/PROJECT_ROOT 透传脚本 | run_script 全 env 透传 |
| 部署 | 脚本入 runtime_artifacts → `~/.claude/hooks/scripts/mention-check.sh`；挂载规则入 `unified/rules.d/p1-runscript-mounts.json` | |

### 2.2-after2 mention-check（SEE-1333 D2 语义变更，2026-09-21）

| 维度 | 变更前 | 变更后（Owner 裁定） |
|---|---|---|
| NO_MENTION fast-path | 首次无 mention 拦截 + 落 sentinel；同 task 后续无 mention 评论经 sentinel 检查免检直通 | 移除 fast-path，无 mention **逐条拦截**（sentinel 保留为观测记录，不再作放行依据） |
| SENTINEL_PASS fast-path | 任一带 mention 评论通过后，同 task 后续评论（含无 mention）全部免检直通 | 移除（§SPEC-010 判据：PASS 后无 mention 评论仍被拦）；PASS sentinel 仍随放行写入（观测/取证），finally 处 NO_MENTION/BLOCK 清理保留 |
| 引擎层联动 | — | when-ops loadCommentContent 多候选回退（D1，见 §6.1 mention-confirm-check 行）；mention-check.sh 与 when-ops.js 的路径解析候选集对齐 |

### 2.3 push-guard

| 维度 | 迁移前基线 |
|---|---|
| 注册时点 | PreToolUse `Bash` |
| 触发条件 | `git push` 命令段（含 backtick/force 检测、repo 检测、atlas/archi→master 白名单 see1069、shared 分支例外 see780） |
| 动作语义 | 非白名单 push 主分支 → 阻止；shared/See 分支放行 |
| 拦截通道 | **exit 2 + stderr**（v1 唯一 exit 2 通道之一） |
| 状态与幂等 | 无状态 |
| fail-open | 非 push 命令 / 检测异常 → 放行（fail-open，exit 0） |
| 输出协议 | stderr 文本；无 JSON |
| env 依赖 | MULTICA_AGENT_NAME、PROJECT_ROOT |


### 2.3-after push-guard（S6 迁移后，2026-09-20）

| 维度 | 迁移后 | 备注 |
|---|---|---|
| 注册时点 | 挂载规则 `push-guard-mount`：on PreToolUse + tool Bash | 引擎 9 时点全 `*` 后收敛 |
| 触发条件 | 保留：命令检测/白名单/shared 例外/backtick/force 全在脚本内（零改动） | |
| 动作语义 | exit 2 = 故意 deny 通道 → `deny_exit_codes:[2]` 声明 → **引擎转义为 PreToolUse deny JSON（reason=脚本 stderr 逐字保真）** | 🔴 通道形态迁移：v1 exit2+stderr → v2 deny JSON；语义等价（均拦截 + 反馈），S6 派发明确要求引擎转义 |
| 拦截通道 | deny JSON + exit 0（deny_exit_codes 命中）；其余脚本失败 → fail-open 放行 + firelog ERROR | on_fail 缺省 open |
| 状态与幂等 | 无状态 | 同 v1 |
| fail-open | 解析异常兜底放行（脚本内）+ 引擎级 run-script 失败放行 | |
| 输出协议 | deny JSON（v1 stderr 文案逐字进 reason，无引擎前缀） | |
| 部署 | `~/.claude/hooks/scripts/push-guard.sh` | |

### 2.4 tscn-tres-guard

| 维度 | 迁移前基线 |
|---|---|
| 注册时点 | PreToolUse `Write\|Edit` |
| 触发条件 | file_path 以 .tscn/.tres 结尾 |
| 动作语义 | 编辑 Godot 场景/资源文件 → 注入提醒（应走编辑器，禁止手编） |
| 拦截通道 | additionalContext（不拦截） |
| 状态与幂等 | 无状态 |
| fail-open | 非目标文件 → 静默放行 |
| 输出协议 | hookSpecificOutput additionalContext |
| env 依赖 | PROJECT_ROOT |

### 2.5 gdformat-gdlint

| 维度 | 迁移前基线 |
|---|---|
| 注册时点 | PostToolUse `Write\|Edit` |
| 触发条件 | .gd 文件写入后 |
| 动作语义 | 运行 gdformat/gdlint 检查格式与 lint |
| 拦截通道 | **exit 2 + stderr**（fail-close：检查失败即拦截反馈） |
| 状态与幂等 | 无状态 |
| fail-open | **fail-close（例外项）**：gdformat/gdlint 工具缺失/报错 → exit 2 |
| 输出协议 | stderr 检查输出 |
| env 依赖 | godot-mcp-launch-path.lib.sh（工具路径解析）、PROJECT_ROOT |


### 2.5-after gdformat-gdlint（S6 迁移后，2026-09-20）

| 维度 | 迁移后 | 备注 |
|---|---|---|
| 注册时点 | 挂载规则 `gdformat-gdlint-mount`：on PostToolUse + when: tool Write\|Edit × file *.gd | v1 matcher Write\|Edit + 脚本内 .gd 过滤，双层等价 |
| 触发条件 | 同上；.gd 判定前置到 when（file op），脚本内 case 兜底保留 | |
| 动作语义 | run_script 挂载 `gdformat-gdlint.sh`：原地格式化副作用、gdformat→gdlint→mcp-mouse-lint 三段串行、任一失败 exit 2 = fail-close 全保真 | 脚本零改动 |
| 拦截通道 | **exit 2 + stderr 直通**: deny_exit_codes [2] @ PostToolUse → 引擎 exit 2 + stderr 原样转发（无 deny JSON 协议位，保真 fail-close 通道） | 🔴 通道保真：与 v1 exit 2 完全同形 |
| 状态与幂等 | 无状态 | 同 v1 |
| fail-open | fail-close 例外项保留：检查失败 → exit 2；超时 → on_fail=close → exit 2（120s） | |
| 输出协议 | exit 2 + stderr（入口 unified-hook 桥接直通） | dispatcher 链路 exit 2 行为不变 |
| 部署 | `~/.claude/hooks/scripts/gdformat-gdlint.sh`（依赖 godot-mcp-launch-path.lib.sh + mcp-mouse-lint.sh 项目内解析不变） | |

### 2.6 auto-pr-on-stop

| 维度 | 迁移前基线 |
|---|---|
| 注册时点 | Stop `*` |
| 触发条件 | 会话 Stop；fetch 节流 5 分钟 marker（`.cc-auto-pr-*`） |
| 动作语义 | push 分支 + 建/更新 Draft PR + 通知 |
| 拦截通道 | 无拦截（附加动作型）；全部失败路径 exit 0 |
| 状态与幂等 | 5 分钟节流 marker |
| fail-open | push/PR/通知失败恒 exit 0（fail-open） |
| 输出协议 | 无 hookSpecificOutput（副作用型） |
| env 依赖 | MULTICA_TASK_ID、gh 认证、PROJECT_ROOT |


### 2.6-after auto-pr-on-stop（S10/P2 迁移后，2026-09-20）

| 维度 | 迁移后 | 备注 |
|---|---|---|
| 注册时点 | 挂载规则 `auto-pr-stop-mount`：on Stop（引擎 9 时点全 `*` 收敛） | v1 matcher Stop `*` 等价 |
| 触发条件 | when: `payload op`（stop_hook_active equals false）+ 脚本内 L23-37 检查第二道防线；fetch 节流 5 分钟 marker 不变（脚本内） | **防循环双防线**：引擎层 payload op 在引擎复驱 Stop（stop_hook_active=true）时短路规则，脚本自身检查为独立兜底 |
| 动作语义 | run_script 挂载 `auto-pr-on-stop.sh`：场景过滤/三清理/gitlink 剥离/push 重试/PR 创建/Multica 通知全在脚本内（零改动） | |
| 拦截通道 | 无拦截（附加动作型，run_script 输出协议外内容被抑制） | M2：Stop 无 deny（validator 把关） |
| 状态与幂等 | 5 分钟节流 marker（脚本内）不变；无 sentinel（one_shot 缺省 never） | |
| fail-open | run_script 缺省 on_fail=open：脚本失败/超时 → 放行 + firelog 审计；Stop 永不阻塞（套件 §8c 断言） | fail-open 硬承诺双层承载 |
| 输出协议 | 无 hookSpecificOutput（副作用型）——脚本 stdout 非 JSON 协议时不透传，由入口 stdin 透传兜底 | 与 v1 行为等价 |
| env 依赖 | 全 env 透传（MULTICA_TASK_ID、gh 认证、PROJECT_ROOT、ORIG_CWD 语义不变） | |
| timeout | 300s（push/PR 网络操作容忍；超时按 on_fail=open 放行） | |

**§6.4 stop_hook_active 防循环规格（P2/S10）**：
1. 引擎第一道防线：挂载规则 when = `{"op":"payload","path":"stop_hook_active","equals":false}`。payload op 语义：字段缺失/undefined/null/false 均判「未置位」（命中）；显式 true 判「已置位」（不触发）。CC 引擎复驱 Stop 时载荷带 stop_hook_active=true → 规则短路，脚本不执行（套件 §8a/8b 断言连续两次 Stop 仅一次副作用）。
2. 脚本第二道防线：auto-pr-on-stop.sh L23-37 的 stop_hook_active 检查保持原样（独立生效，不依赖挂载层）——防线冗余为有意设计（挂载层误配置时仍有兜底）。
3. M2 矩阵：Stop 时点 deny/modify 非法，validator 在挂载规则校验阶段即拒绝（fail-soft 跳过 + 审计，套件 §8d）。
4. 红线承诺：Stop 事件任何路径不得阻塞或循环——run_script 失败/超时按 on_fail=open 放行（§8c），引擎自身异常走 P0 fail-open。

### 2.7 repo-checkout

| 维度 | 迁移前基线 |
|---|---|
| 注册时点 | SessionStart `*` |
| 触发条件 | SessionStart；10 分钟幂等 marker（`.cc-aligned-*` 600s 新鲜度 + 分支/upstream 校验） |
| 动作语义 | checkout 任务仓库到专属分支；嵌套 worktree 防护；输出 checkout 元数据 hint |
| 拦截通道 | additionalContext 注入 |
| 状态与幂等 | `.cc-aligned-*` 600s marker；mcp-tool-presence 从属调用 |
| fail-open | 失败 → 放行 + hint |
| 输出协议 | additionalContext |
| env 依赖 | MULTICA_TASK_ID、workspace repo 列表、PROJECT_ROOT |


### 2.7-after repo-checkout（S14/P3 迁移后，2026-09-20）

| 维度 | 迁移后 | 备注 |
|---|---|---|
| 注册时点 | 挂载规则 `repo-checkout-mount`：on SessionStart（v2 注册行 9 时点全 `*` 收敛） | v1 matcher SessionStart `*` 等价 |
| 触发条件 | 脚本内判定保真（任务仓库探测/嵌套防护/10 分钟 marker `.cc-aligned-*` 600s + 分支/upstream 校验，零改动） | marker 协议套件 §10a/10b 钉住 |
| 动作语义 | run_script 挂载 `repo-checkout.sh`：checkout/对齐/rebase/marker/submodule 全链保真；mcp-tool-presence 从属调用不变 | 脚本字节级零改动 |
| 拦截通道 | additionalContext 注入（run_script hookSpecificOutput 协议直通，套件 §10a）；非阻断（全出口 exit 0，§10a 断言） | |
| 状态与幂等 | `.cc-aligned-*` 600s marker（脚本内，/tmp）；600s 内二次触发零 I/O 快路径（§10b 断言） | |
| fail-open | run_script 缺省 on_fail=open：失败/超时放行；脚本内失败 → 放行 + hint（v1 语义保持） | 双层 fail-open |
| 输出协议 | additionalContext（SessionStart/UPS 同形态；UPS 时点 hint 路由套件 §10c） | |
| env 依赖 | 全 env 透传（MULTICA_TASK_ID、MULTICA_AGENT_ID、PROJECT_ROOT）；**jq 依赖在挂载层环境可用性确认**：脚本以绝对路径依赖 `jq`（PATH 继承自引擎 run_script 全 env 透传，fixture 与实机均验证 jq-1.7 在位） | |
| timeout | 180s（checkout/rebase 网络操作容忍；超时按 on_fail=open 放行 + hint 缺失不阻塞） | |
| UPS 时点验证 | v2 注册行已含 UPS；引擎 on 匹配 + additionalContext 注入形态经套件 §10c 实证（hookEventName=UserPromptSubmit 正确回传） | 派发目标 3 |
| 文件规模 | 834 行超 800 上限——不在本子步骤修复，建议 P4 目录收敛阶段决策拆分（如 lib 层抽出） | 派发目标 4 记录 |

**repo-checkout 挂载规格（P3/S14）**：
1. when 用 `payload{hook_event_name equals SessionStart}` 显式门控（冗余但自文档化——on 已限定时点，与 auto-pr 同型保持挂载层风格一致）。
2. UPS 验证语义：v2 引擎对 UPS 的 on 匹配与 additionalContext 注入与 SessionStart 同通道（hookSpecificOutput.hookEventName 随载荷回传），无需独立挂载规则——脚本若未来需 UPS 行为由脚本内 EVENT 分支承载（§10c 探针验证该形态）。
3. v1 注册禁用（SessionStart `*` wrapper 行）由 Atlas 在 S17 QA PASS 后按 cutover 批次执行；本子步骤仅落 v2 侧。
### 2.8 atlas-taskflow mark-a / mark-b / exit-reminder

| 维度 | 迁移前基线（三个脚本同族） |
|---|---|
| 注册时点 | PostToolUse `Skill`（mark-a）/ PostToolUse `Bash`（mark-b）/ PreToolUse `Bash`（exit-reminder） |
| 触发条件 | Skill 工具调用 taskflow 技能（mark-a）/ multica 命令（mark-b）/ comment 命令段（exit-reminder） |
| 动作语义 | 状态文件驱动的 taskflow 阶段记账 + 出口提醒 |
| 拦截通道 | additionalContext / 无拦截 |
| 状态与幂等 | atlas-taskflow 状态文件（issue 维度） |
| fail-open | fail-open |
| 输出协议 | additionalContext |
| env 依赖 | MULTICA_TASK_ID、状态文件路径约定 |


### 2.8-after atlas-taskflow（S6 迁移后，2026-09-20）

| 维度 | mark-a | mark-b | exit-reminder |
|---|---|---|---|
| 挂载规则 | `atlas-taskflow-mark-a-mount`（PostToolUse + tool Skill + agents include Atlas） | `atlas-taskflow-mark-b-mount`（PostToolUse + tool Bash + Atlas） | `atlas-taskflow-exit-reminder-mount`（PreToolUse + tool Bash + Atlas） |
| 触发条件 | 脚本内 skill==taskflow 判定保真（零改动） | 脚本内 issue create 判定保真 | 脚本内 comment add 判定 + 目标 issue 提取保真 |
| 拦截通道 | 无拦截 / additionalContext JSON 直通 | 同 | deny / additionalContext 双分支 JSON 直通（形态同 v1） |
| 状态与幂等 | `/tmp/atlas-taskflow-state-<MULTICA_TASK_ID>` 键不变；脚本零改动 | 同 | 同 |
| fail-open | 脚本 fail-open；挂载层失败 → 引擎 fail-open | 同 | 同 |
| env 依赖 | 全 env 透传（MULTICA_TASK_ID、multica CLI 直调保真） | 同 | 同 |
| 时点映射 | v1 matcher Skill / Bash / Bash → on+when 精确一一对应 | 同 | 同 |

### 2.9 mcp-tool-presence（非注册·从属脚本）

| 维度 | 迁移前基线 |
|---|---|
| 注册时点 | 无独立注册；由 repo-checkout 从属调用（SessionStart 链内） |
| 触发条件 | 被 repo-checkout 调用 |
| 动作语义 | 只读 env + /tmp mcp-config + 父进程链探测，godot-mcp 工具清单证据落 firelog（SEE-1242/1316） |
| 拦截通道 | 无（纯审计） |
| 状态与幂等 | 无状态，任何失败 exit 0 |
| fail-open | 恒 exit 0 |
| 输出协议 | 无 stdout 协议；firelog 落点 |
| env 依赖 | MCP_TIMEOUT、MCP_TOOL_TIMEOUT、ECC_DISABLED_MCPS、/tmp/multica-mcp-*/mcp-config.json |

### 2.10 reconcile-working-branch（非注册·手动脚本）

| 维度 | 迁移前基线 |
|---|---|
| 注册时点 | 无注册（Leader 手动调用，非 hook） |
| 触发条件 | shared working branch auto-rebase 冲突后手动执行（--issue-id + branch / --continue） |
| 动作语义 | fetch → reconcile 分支 → rebase origin/master → 冲突人工处理 → --force-with-lease push（first-reconciler-wins） |
| 拦截通道 | n/a |
| 状态与幂等 | reconcile/<wb> 分支承载中间态 |
| fail-open | n/a（set -euo pipefail，失败即退出） |
| 输出协议 | 终端输出 |
| env 依赖 | git 凭证、origin 访问 |

### 2.11 godot-mcp-launch-path.lib.sh（lib 非注册）

| 维度 | 迁移前基线 |
|---|---|
| 注册时点 | 无（source 库） |
| 触发条件 | 被 gdformat-gdlint 等脚本 source |
| 动作语义 | 单落点解析 addons/godot_mcp/launch/ 工具链路径；解析不到返回 1（无 legacy 回退） |
| 拦截通道 | n/a |
| 状态与幂等 | 无状态 |
| fail-open | 调用方决定降级 |
| 输出协议 | stdout 路径 |
| env 依赖 | submodule 挂载布局 |


### 3.5-after S6 lane 通道桥接新增语义（v2 引擎 P1 扩展，2026-09-20）

1. run_script action 新增 `deny_exit_codes: [codes]` 与 `on_fail: open|close` 字段（validate-rules.js schema 已建）。
2. deny_exit_codes 命中 = 故意 deny 通道，无条件转义：PreToolUse → deny JSON（reason = 脚本 stderr 逐字保真，无引擎前缀）；非 PreToolUse → 引擎 exit 2 + stderr 直通（unified-hook.sh 实现通道转发，CC 视为阻塞错误）。
3. on_fail 仅管辖超时/崩溃路径：open（缺省，放行+审计）/ close（fail-close 例外项：Pre→deny、非 Pre→exit2）。
4. `${HOOKS_DIR}` 占位符由引擎解析为 hooks 根目录（repo 布局与 ~/.claude/hooks 部署布局一致）。
5. 引擎新增 `unified/rules.d/*.json` 多规则文件加载：挂载规则文件归 S6（p1-runscript-mounts.json），rules-v2.json 规则段归 S5，两 lane 互不交叉编辑。
6. 安装器 runtime_artifacts 扩充：挂载脚本 + rules.d 清单随运行物部署到全局位（P1 cutover 批次生效）。
7. **unified-hook 路由全局优先（P1 cutover 修正，2026-09-20 事故落地）**：dispatcher unified-hook case 与引擎 findConfigFile 均改为**全局部署位优先**（`~/.claude/hooks/unified/`），各会话 checkout 的 `.claude/hooks/unified/` 仅在全局缺运行物/配置时兜底（P4 随全局兜底路由收敛移除）。理由：v2 配置必须单一真源——CC 每次工具调用读 hooks 配置且在跑会话即时生效，PROJECT_ROOT 优先会让各会话按各自 checkout 的异构 v2 配置求值（规则集互不一致 + 与 v1 双轨），违背空规则灰度前提。

## 3. v2 统一引擎注册基线（P0 已交付，未 cutover）

| 维度 | P0 交付状态 |
|---|---|
| 声明式清单 | `.claude/hooks/hooks-registration.json`（真源） |
| 渲染形态 | 9 时点 `matcher:*`，命令 `hook-wrapper.sh <event> unified-hook`；与既有 v1 注册 merge 共存（v1 项保留） |
| 入口 | unified-hook.sh：stdin 缓冲 + HOOK_SCOPE_ID=`${HOOK_SCOPE_ID:-${MULTICA_TASK_ID:-}}` 映射 + fail-open（引擎缺失/node 缺失/非零退出 → 透传 + firelog ERROR） |
| 引擎 | engine.js：on/agents/when/one_shot 求值 + action[deny/context/modify/run_script] + v1 desugar 双读（v1_compat）+ fail-soft（单规则违规跳过+审计） |
| validator | validate-rules.js 显式状态机（INIT→SCHEMA_OK→ON_BOUND→AGENTS_BOUND→SCOPE_BOUND→WHEN_BOUND→ACTION_DONE），INVALID 带 rule+path+reason+trace |
| 安装器 | install-hooks.sh install/disable-v1/rollback/verify；原子写+备份+幂等 |

## 4. 等价保留项（裁定不修复）

| # | 项 | 定性 | 依据 |
|---|---|---|---|
| 1 | sentinel TOCTOU 竞态窗口（checkSentinel → when 求值 → writeSentinel 非原子；并发双调用可能同 run 双触发） | v1 同窗口语义等价保留；v1 pre-comment-skill-check / mention-check sentinel 同样非原子 | S3 发现（2026-09-20），编排裁定（issue Spec 节） |
| 2 | test_see764_unified_engine_regression 12 例失败 | v1 legacy 预存漂移（断言旧 9 条规则 vs 现 13 条 + 已退役 mem-search-context；P0 提交对 testee 零 diff） | S3 定性（2026-09-20），编排裁定：P1 随 SPEC-003 再定向 |
| 3 | dispatcher 全局/仓库双副本人工 cp 同步 | P0 unified-hook case 已进仓库副本；全局副本（`~/.claude/hooks/dispatcher.sh`）尚未同步 → test_see781 S3.T2 在 HEAD 上 1 例失败（基线绿），属 cutover 时序项非回归；随实机部署批次同步消除 | S4 QA 独立复跑对比（2026-09-20） |

## 5. 迁移后对照（P0 段留空，P1 起逐格填写）

| hook | 迁移后注册时点 | 迁移后触发条件 | 迁移后动作语义 | 迁移后拦截通道 | 迁移后状态与幂等 | 迁移后 fail-open | 迁移后输出协议 | 迁移后 env 依赖 | 核验签字 |
|---|---|---|---|---|---|---|---|---|---|
| pre-comment-skill-check（S5 配置化，全部 14 条省略 `when` 时的 D4 语义见 §6.1） | on: PreToolUse（comment_add/any_tool 类）；doc-reminder on: PostToolUse（enabled=false，语义校验跳过） | 14 条 v2 规则（`on`+`when` op 树+`agents` 顶层组合）：见 §6.1 逐规则对照 | 同列「§6.1 迁移后动作语义」 | deny → `permissionDecision:"deny"`；remind → `additionalContext` | one_shot{id:issue\|run}（SEE-1333 D4）sentinel `/tmp/.hook-fired-<rule>-<agent>-<windowId>`（§SPEC-013 键含 agent 维度；issue=HOOK_ISSUE_ID，run=HOOK_RUN_SCOPE_ID‖HOOK_SCOPE_ID‖session_id 单一窗口源，id 缺失 fail-open 跳过+WARN） | 引擎异常 fail-soft/fail-open（P0 交付） | hookSpecificOutput JSON（P0 引擎） | MULTICA_AGENT_NAME、HOOK_SCOPE_ID、MULTICA_TASK_ID、PROJECT_ROOT | S5 自验 ✅（validator 14/14 VALID；套件重定向全绿待 S8/S9 QA 核验） |
| tscn-tres-guard | on: PreToolUse（v2 取代 v1 settings matcher `Write\|Edit`） | tool op in [Write, Edit] + file op patterns *.tscn/*.tres（= v1 触发窗口全等价） | 编辑提示注入（原文案 verbatim） | additionalContext（不拦截，同 v1） | 无状态（同 v1） | 无命中→静默透传（同 v1） | hookSpecificOutput additionalContext | 无（仅载荷） | S5 自验 ✅ |

## 6. P1 S5 配置化 lane 迁移对照（2026-09-20）

### 6.1 skill-check 13 条 v1 规则 → v2 逐规则对照（同格 = 迁移后行为）

> 判等依据：payload 相同时，v1 引擎（pre-comment-skill-check.sh 内嵌 node）与 v2 引擎（engine.js + when-ops.js）的行为对照。v2 配置文件：`.claude/hooks/unified/rules-v2.json`（14 条，含 13 条 v1 等价翻译 + tscn-tres-guard）。

| v1 规则 | v1 维度 | v2 翻译（on / agents / one_shot / when / action） | 通道保真 | 等价性结论 |
|---|---|---|---|---|
| atlas-workflow-skill-check | trigger comment_add / agents [Atlas] / one_shot / not(or used taskflow/task-assign/code-review) / block | on:PreToolUse；agents.include:[Atlas]；one_shot{scope:run}；when: command(current, pattern `multica issue comment add(\s|$)`) AND not(any used_skill×3)；action:[deny + 原文案] | deny→deny JSON | 等价：v1 isCommentAdd ≡ v2 command op（同 parseCommand/extractCommands 语义库 SEE-815/1151）；block 自查放行 sentinel ≡ one_shot run（首拦次放，键含 scope id） |
| revy-testing-skill-check | 同上单技能 revy-testing | 同上（agents.include:[Revy]；not used_skill revy-testing） | deny→deny | 等价（同上） |
| archi-doc-edit-skill-check | not(or used doc-edit/edit-skill/edit-claude) | 同上（agents.include:[Archi]；not any used_skill×3） | deny→deny | 等价 |
| bachi-coding-skill-check | not used bachi-coding | 同上（agents.include:[Bachi]；not used_skill bachi-coding） | deny→deny | 等价 |
| atlas-bash-skill-reminder | trigger any_tool / agents [Atlas] / remind / one_shot / 无 condition | on:PreToolUse；agents.include:[Atlas]；one_shot{scope:run}；无 when（D4 恒真）；action:[context 原文案] | remind→additionalContext（v1 通道无 '[skill-check]' 前缀差 → v2 无前缀，message 原文保真） | 等价：恒真触发 + per-run 一次 |
| archi-doc-edit-reminder | 同上 | 同上（include:[Archi]） | 同上 | 等价 |
| revy-testing-reminder | 同上 | 同上（include:[Revy]） | 同上 | 等价 |
| bachi-coding-reminder | 同上 | 同上（include:[Bachi]） | 同上 | 等价 |
| recall-reminder | any_tool / 无 agents / remind / one_shot | on:PreToolUse；无 agents（全 agent 匹配）；one_shot{scope:run}；无 when（恒真）；context 原文案 | 同上 | 等价（agents 缺省 ≡ {include:[]} 全匹配）。⚠️ SEE-1333 D3 落实（Owner 指令 2026-09-21）：实装代码原为 scope:issue，issue 维度 sentinel 被首个 run 消耗后其余 agent 的后续 run 零注入（agent 间隔离失效）；已改 {scope:"run"}，run 天然归属单一 agent → 每 agent 每 run 注入（fixture 实证：同 run 抑制 / 换 run 重注入，HOOK_ISSUE_ID 已解析的生产仿真下） |
| mention-confirm-check | comment_add / content_matches mention 正则 / block / one_shot | on:PreToolUse；one_shot{scope:run}；when: command(current, comment add) AND content(pattern 为 v1 正则 verbatim)；action:[deny 原文案] | deny→deny | 等价（content op 的正文解析链 --content-file→--content→tool_input.content、stdin→空，两引擎同一实现）。SEE-1333 D1：when-ops loadCommentContent 补齐多候选回退（cwd → projectRoot → $MULTICA_WORKDIR → cwd/..，平移自 mention-check.sh SEE-1053/1054 语义）——hook 进程 cwd ≠ workdir 时 `--content-file` 相对路径不再静默盲视致首检失效 |
| child-issue-guard | any_tool / command_matches(create\|update, --parent 值) / block / 无 one_shot | on:PreToolUse；无 one_shot；when: command(current, pattern `multica issue (create|update)`, has_flag `--parent`, flag_has_value true)；action:[deny 原文案] | deny→deny | 等价（--parent 空值放行 / 标志值误报防护 / 复合段提取语义两引擎一致） |
| grepai-search-reminder | any_tool / or(command grep/rg/ag/ack, tool_name Grep) / remind / one_shot | on:PreToolUse；one_shot{scope:run}；when: any(command×4 pattern, tool op in ["Grep"])；action:[context 原文案] | remind→additionalContext | 等价：SEE-1238 tool_name 维度保留为 tool op；四条 command 变体逐条保留（真实正文应为 4+1）：v1 tool_name 匹配为大小写不敏感、v2 tool op 精确包含——现网 tool_name 恒为 'Grep'，行为等价 |
| doc-reminder | file_edit / file_matches md 系 + branch_is invert / remind / enabled=false | on:PostToolUse；enabled=false（M7 语义校验跳过）；when: all(file op patterns verbatim, not branch in [main,master])；action:[context 原文案] | remind→additionalContext | 等价：enabled false 恒不触发（v1 同）；结构语义按 v2 词表达（branch 非 git 目录恒 false 注记） |

D4 无条件规则语义裁定：v1「无 condition 的 remind = 恒真」→ v2 等价表达为「规则无 `when`」（5 条 remind 规则）；v1「无 condition 的 block = 恒假（永不触发）」——13 条规则中不存在该形态，v2 词表下同类写法（deny 无 when）为恒真，⚠️ 语义反转为引擎级差异，已记录于 §6.3 等价保留项；迁移配置未使用恒假形态，无回归面。

### 6.2 mention-check / push-guard 触发条件层配置化 + S5→S6 移交清单（S6 挂载层）

> 归属划分：rules-v2.json 规则段权属 S5；run_script 挂载层规则条目由 S6 按 §6.2 规格追加进 rules-v2.json（勿动 §6.1 的 14 条规则段）。以下为 S5 移交 S6 的挂载规格。

**mention-check（`.claude/hooks/scripts/mention-check.sh`，脚本零改动或最小改动）**

| 项 | 挂载规格（S6 落地进 rules-v2.json） |
|---|---|
| name | `mention-check` |
| on | `{ "in": ["PreToolUse"] }` |
| agents | 除 Chekky 外全部：`{ "except": ["Chekky"] }`（对应脚本首段白名单短路） |
| when（触发条件层） | `{ "op": "all", "args": [ { "op": "tool", "in": ["Bash"] }, { "op": "command", "scope": "current", "keyword": "multica issue comment add" } ] }` |
| action | `{ "op": "run_script", "path": "<repo>/.claude/hooks/scripts/mention-check.sh"（或部署路径）， "timeout_ms": 8000, "fail_open": true }` |
| 不可配置化部分（理由） | ① PHASE 0 mention gate 的三态结果（NO_MENTION sentinel 放行 / PASS sentinel 三态 / CONTENT_FILE_UNREADABLE 硬错误带 path/cwd/err）依赖按 TASK 的多 sentinel 状态机——v2 词表无 cross-head 状态 op（计划 §3.3 已否决 state/count）；② SEE-756/SEE-1092 触发检测含 space-cd 段内扫描（quote-aware），比 v2 command op 的 base+sub 锚定覆盖更宽——故触发层用 keyword 宽门（拦截 echo/字面量误召是安全的：脚本自身 isRealCommentAdd 权威复判后 PASS 透传） |
| 输出协议桥接 | 脚本现输出 `hookSpecificOutput` deny JSON 或透传 stdin。run_script 挂载下脚本输出的 deny JSON 需符合引擎 run-script 协议（stdout JSON 顶层含 hookSpecificOutput → 引擎转发该协议；无命中 → 空/透传）。若脚本需保留「输出为空=放行」语义，S6 在挂载层决定 stdin 透传或空输出桥接 |
| 状态与幂等（保持不变） | /tmp/mention-check-no-mention-/block-/pass-<TASK_ID>（脚本自持，unaffected by v2） |

**push-guard（`.claude/hooks/scripts/push-guard.sh`，脚本零改动；fail-close→非推送场景 fail-open 语义不变）**

| 项 | 挂载规格（S6 落地进 rules-v2.json） |
|---|---|
| name | `push-guard` |
| on | `{ "in": ["PreToolUse"] }` |
| agents | 顶层门控：v1 无 agents 限定（Atlas/Archi master 白名单在脚本内逻辑），v2 顶层不设限制，脚本内权威；如 S6 评估需顶层收窄再议 |
| when（触发条件层） | `{ "op": "all", "args": [ { "op": "tool", "in": ["Bash"] }, { "op": "command", "scope": "current", "pattern": "git push" } ] }` |
| action | `{ "op": "run_script", "path": "<repo>/.claude/hooks/scripts/push-guard.sh", "timeout_ms": 10000, "fail_open": true }` |
| 不可配置化部分（理由） | ① 深语义全在脚本：heredoc 剥离/tokenize/flag 跳步 pushTokenIndex 检测、-C/cd repo 根解析、--delete 旁路、force 检测（SEE-954 簇扫描）、master/main 三重分支策略、non-host repo 例外、Atlas/Archi agent_id 白名单+旁路审计日志、节流/ancestry/gitlink 检查——为复合环境副作用型逻辑（计划 §2.3 提取判据）不入配置；② 触发层 pattern 宽门可覆盖常规与 cd-复合形态，脚本 NOT_PUSH 权威复判兜底 |
| 输出协议桥接 | 🔴 v1 唯一 exit 2+stderr 通道：run_script 协议必须把「脚本 exit 2 + stderr」映射为 CC 可用的拦截形态（S6 目标1 定义的协议桥接；引擎 P0 已承诺把脚本非零退出转义为对应 CC 协议——S6 落地时验证 deny 转义的契约与 fail-close 语义一致） |
| fail-open（保持不变） | 非 push 命令/异常 → 脚本 exit 0 透传（恒等）；超时语义 → S6 目标 4（v1 检测异常兜底放行不变） |

### 6.3 S5 阶段等价保留项（补录）

| # | 项 | 定性 | 依据 |
|---|---|---|---|
| 4 | block 输出 reason 前缀 '[skill-check] ' → '[unified-hook] '（v1 deny JSON 另带 additionalContext 镜像字段，v2 deny reason 文本并入 permissionDecisionReason） | v2 引擎级统一前缀，文案正文保真；通道形态仍为 deny / additionalContext | S5 解读：引擎 P0 输出协议为统一真源，属框架收敛目标（非 drift） |
| 5 | sentinel 键格式 /tmp/skill-check-<rule>-<TASK> → /tmp/.hook-fired-<rule>-<scope-id> | v2 one_shot{scope} 设计（计划 §2.2.1）；禁迁移期双哨兵互斥检查（v1/v2 并行期各自 sentinel 独立计数，cutover 后 v1 体随注册禁用消亡） | 计划 §2.2.1 + 关键实施决策 2 |
| 6 | block 自查放行 sentinel：v2 writeSentinel 位于 when 求值后（P0 引擎 §"先落 sentinel 再执行 action"），与 v1 「命中即写 sentinel」语义一致；sentinel TOCTOU 竞态窗口继承 §4 等价保留项 #1（不修复） | 语义等价 | S5 阅读两引擎主流程确认 |


### 事故记录 4（非等价保留，修正已落地）：unified-hook per-checkout 路由事故（2026-09-20 08:3x UTC）

- **现象**：P0 安装器写入 unified-hook 注册行后在跑会话即时生效（CC 每次工具调用读取 hooks 配置），dispatcher「PROJECT_ROOT 优先」路由使各 agent 会话按各自 checkout 的 v2 配置求值：Atlas 会话 6 条未 QA 挂载规则提前生效、Bachi 会话 v2 deny 与 v1 同语义规则双轨、Archi 会话 rules=2 —— 规则集互不一致、违背 P0「空规则灰度、零行为变化」前提。
- **收敛动作（Atlas，即时）**：`install-hooks.sh rollback` 恢复 settings 纯 v1（11 项注册、0 条 unified-hook 行，verify 确认 v1 完好）；settings 的 unified-hook 注册行保持移除直至 P1 cutover。
- **修正（S6 范围增补，本条目随提交落地）**：dispatcher unified-hook case + 引擎 findConfigFile 反转为全局部署位优先；checkout 配置仅兜底；事故复现用例（异构 rules.d 时加载全局配置）入 `test_v2_unified_engine_p0.sh` §10d。
- **cutover 顺序裁定（防复发）**：QA PASS → 全局部署位就位 → 各会话 checkout 到 QA 提交 → 最后注入注册行。
- **P4 收敛处置记录（S18，2026-09-20）**：
  1. dispatcher alias 路由删除（仅剩 unified-hook case，全局优先；未知 alias 静默透传）——v1 时点全部由 v2 引擎接管，v1 业务脚本经挂载层 run_script 调用，不经 dispatcher。
  2. v1 兼容层删除：engine.js desugar 双读（v1_rules_file/v1_compat）移除、desugar.js 文件退役、rules-v2.json v1_compat 键移除、pre-comment-skill-check.sh 与 tscn-tres-guard.sh 退役（已被 14 条 v2 规则配置化替代，无引用方）。
  3. **reconcile-working-branch.sh 处置建议**：非注册脚本（当前无 settings 注册、无 dispatcher case），保留仓库原位，建议后续确认其调用方后另行处置——本子步骤不动。
  4. **mcp-tool-presence.sh 处置建议**：repo-checkout.sh 从属调用（SessionStart 链内），随 repo-checkout-mount run_script 保留运行——保留原位，P4 后仍被引用，不退役。
  5. run_script 挂载的 8 脚本全部保留（gdformat-gdlint/mention-check/push-guard/taskflow×3/auto-pr/repo-checkout——事故 6 补全后）。
- **事故记录 5（S8 硬化发现，已修复）——安装器备份时序缺陷（5e，MEDIUM）**：备份文件名秒级时间戳同秒可碰撞；`latest_backup()` 以 mtime 选取（`ls -1t`），而 cp 保留源 mtime 使备份 mtime 序与 settings 状态时序脱钩 → 多代备份下 rollback 可能恢复内容更早的备份（Revy 实测第 2 代 rollback 恢复第 1 代内容）。**修复裁定（组合方案，S6 执行）**：① 备份名追加纳秒+PID 后缀消除同秒碰撞；② `backup_if_changed` 同步落 `.last-backup` 指针文件（mv 原子替换），`latest_backup` 优先读指针、mtime 扫描降为兼容兜底——指针是时序真源，rollback 语义 = 恢复最近一次变更前状态。稳定性断言（10 轮同秒循环 + 3 代备份序列）入 installer 套件 §8。

## 附录 A. P0 实机部署 runbook 检查单（QA PASS 后由 Atlas 执行）

> 前提：本 QA 报告 PASS；执行人 Atlas；本 QA 不触碰实机。
> **状态：已执行**（2026-09-20，Atlas）。首装后因事故记录 4（per-checkout 异构配置求值）按本单第 6 步 rollback 收敛回纯 v1；unified-hook 注册行保持移除至 P1 批 cutover 重注——rollback 路径实机验证有效，构成本单的实证闭环。

1. **预检**
   - `git -C <repo> rev-parse --abbrev-ref @{upstream}` = `origin/shared/SEE-1330` 且 HEAD ≥ `fa330070`
   - 备份现状：`cp ~/.claude/settings.json ~/.claude/settings.json.bak-manual-$(date -u +%Y%m%dT%H%M%SZ)`
   - 记录部署前 firelog 尾部水位：`wc -l ~/.claude/hook-fire.log`
2. **全局部署物同步**（消除保留项 3 的 S3.T2 漂移）
   - `cp <repo>/.dev/hooks/dispatcher.sh ~/.claude/hooks/dispatcher.sh && cp <repo>/.dev/hooks/hook-wrapper.sh ~/.claude/hooks/hook-wrapper.sh`
   - `diff <repo>/.dev/hooks/dispatcher.sh ~/.claude/hooks/dispatcher.sh` = 空
   - 🔴 **顺序铁律（2026-09-20 事故裁定）**：全局部署位（运行物 + 配置）必须**先于** unified-hook 注册行就位；cutover 顺序 = QA PASS → 全局部署位就位 → 各会话 checkout 到 QA 提交 → 最后注入注册行。注册行先于配置一致性上线 = per-checkout 异构配置泄漏（见事故记录 4）。
   - unified-hook 路由为**全局部署位优先**（`~/.claude/hooks/unified/`）；各会话 checkout 内的 `.claude/hooks/unified/` 仅兜底，不得作为配置真源。
3. **运行物部署 + 注册渲染**（幂等；重复执行 diff=0）
   - `bash <repo>/.claude/hooks/install-hooks.sh install --settings ~/.claude/settings.json --global-hooks ~/.claude/hooks --repo-root <repo> --phase P0`
   - 复跑同命令一次 → 终端无新增 backup 行、settings diff=0
4. **verify**
   - `bash <repo>/.claude/hooks/install-hooks.sh verify --settings ~/.claude/settings.json --global-hooks ~/.claude/hooks`
5. **火线观察**（部署后 10 分钟）
   - `tail -f ~/.claude/hook-fire.log`：出现 `[unified-hook] event=... action=...` result 行
   - 无 `ERROR engine-missing` / `ERROR engine-exit` / `ERROR config-*` 行
   - v1 hook 行为零变化：existing alias 行（skill-check/mention-check/...）仍按原频率出现
6. **回滚**（任一观察点失败即执行）
   - `bash <repo>/.claude/hooks/install-hooks.sh rollback --settings ~/.claude/settings.json`（自动取最新备份；如需指定：`--backup <bak文件>`）
   - 回滚后 `diff` 备份与 settings = 空；再复跑步骤 2 的 verify 确认 v1 注册完好

## 附录 B. P1 实机 cutover runbook（S9 QA PASS 后由 Atlas 执行）

> 前提：S9 QA 报告 PASS（HEAD `546c951c`）；执行人 Atlas；QA 不触碰实机。
> **状态：已执行**（2026-09-20，Atlas）。P1 批 cutover 完成：全局部署位先于注册行就位、9 时点 unified-hook 注册注入、v1 注册 9 项禁用、firelog 火线观察无 ERROR、v1 alias 行消失且无双触发。
> 🔴 全程遵守事故记录 4 的顺序铁律：全局部署位就位 → 各会话 checkout 到 `546c951c` → 最后注入注册行。

1. **预检**
   - `git -C <repo> rev-parse --abbrev-ref @{upstream}` = `origin/shared/SEE-1330` 且 HEAD = `546c951c`
   - 备份：`cp ~/.claude/settings.json ~/.claude/settings.json.bak-manual-p1-$(date -u +%Y%m%dT%H%M%SZ)`
   - 记录 firelog 水位：`wc -l ~/.claude/hook-fire.log`
2. **全局部署位就位**（先于注册行）
   - `cp <repo>/.dev/hooks/dispatcher.sh <repo>/.dev/hooks/hook-wrapper.sh ~/.claude/hooks/`
   - `bash <repo>/.claude/hooks/install-hooks.sh install --settings ~/.claude/settings.json --global-hooks ~/.claude/hooks --repo-root <repo> --phase P1`
     - 该命令部署 runtime_artifacts（unified/* + rules.d/p1-runscript-mounts.json + 6 个挂载脚本）到 `~/.claude/hooks/`，但 **P1 阶段注册行注入与否以 phase 语义为准**——若 install 即写注册行而会话尚未 checkout，需先完成步骤 3 再执行 install（顺序铁律：checkout 先于注册行）
   - 各会话 checkout：`git -C <各 worktree> fetch && git reset --hard origin/shared/SEE-1330`（≥ `546c951c`）
3. **注册行注入（P1 批）**
   - `bash <repo>/.claude/hooks/install-hooks.sh install --settings ~/.claude/settings.json --global-hooks ~/.claude/hooks --repo-root <repo> --phase P1`（注入 9 时点 unified-hook 注册行，matcher 全 `*`）
   - 幂等复跑一次 → settings diff=0、无新增 backup
4. **v1 注册禁用（P1 批，同批 cutover 防双触发）**
   - `bash <repo>/.claude/hooks/install-hooks.sh disable-v1 --settings ~/.claude/settings.json --manifest <repo>/.claude/hooks/hooks-registration.json --global-hooks ~/.claude/hooks --phase P1`
   - 禁用清单（9 项）：`skill-check`、`skill-check-post`、`mention-check`、`push-guard`、`tscn-tres-guard`、`gdformat-gdlint`、`atlas-taskflow-mark-a`、`atlas-taskflow-mark-b`、`atlas-taskflow-exit-reminder`
   - 保留项核对：`auto-pr`（P2）、`repo-checkout`（P3）注册行必须仍在；v2 unified-hook 9 行必须完好（`count_v2_entries` = 9）
5. **verify**
   - `bash <repo>/.claude/hooks/install-hooks.sh verify --settings ~/.claude/settings.json --global-hooks ~/.claude/hooks` → ok
6. **火线观察**（10 分钟）
   - `tail -f ~/.claude/hook-fire.log`：`[unified-hook] event=... fired=...` result 行出现且规则名来自 rules-v2.json / p1-runscript-mounts.json
   - 无 `ERROR engine-missing/engine-exit/config-*/rules-d-*` 行
   - v1 alias 行（skill-check/mention-check/...）应**消失**（已禁用）；无同调用双触发（同一 tool call 无 v1+v2 双行）
   - 双开防双触发语义已在 7i 用例锁定：即使残留 v1 也不产生重复 deny JSON
7. **回滚**（任一观察点失败即执行）
   - `bash <repo>/.claude/hooks/install-hooks.sh rollback --settings ~/.claude/settings.json`（5e 修复后：`.last-backup` 指针优先，恢复最近一次变更前状态）
   - 回滚后 verify 确认 v1 注册完好；如需回到 P1 前多代状态：按备份文件名（含纳秒+PID 后缀）`--backup <文件>` 显式指定

### S9 核验记录（2026-09-20）
- 五套判据 fresh reset `546c951c` 独立复跑：引擎 190/0、validator 232/0、安装器 41/0、挂载 49/0、dispatcher 10/10 —— 全 PASS
- 安装器稳定性：6 次复跑全绿 + 套件序等价事故复现脚本 ×30 轮（2×15）零 mismatch —— 5e 修复验证 PASS（备份名纳秒+PID 后缀 + `.last-backup` 指针已落地，installer §8 四例稳定性断言在位）
- 逐规则对抗复核：14 条 v2 规则 + 6 条挂载，裸命令独立探针（正例命中 + 反例零泄漏 + agents 通道隔离）—— 全部与 §6.1/§2.x-after 对照表一致；复检中的 3 例「异常 deny」经隔离探针归因为同配置内 skill-check 规则的合法拦截（非缺陷）
- SPEC-003 重定向套件 14/14 全绿（含 see764 144/0——v1 legacy 套件已完成 v2 再定向，等价保留项 #2 消亡）
- 对照清单核验：§6.1 逐规则 13 条对照与 rules-v2.json 实况一致（14 条 = 13 v1 翻译 + tscn-tres-guard）；§6.2 挂载规格与 p1-runscript-mounts.json 一致（落地形态 rules.d lane，§3.5-after 已记录 lane 拆分）；等价保留项 #1–#6 与事故记录 4/5 逐条核对无失实
- S8 遗留裁定：mention 系 v1 直测套件（see400 3 例 / fastpath 30 例）——P0 基线 worktree 已确认同为红、mention-check.sh 零改动 → **PRE-EXISTING-DRIFT（环境性/预存）**；mention-check 挂载语义已由挂载套件 5b/7j 守护。处置：维持 legacy 标注，P1 cutover 后如需复兴按 P2/P4 批重定向（不阻塞本阶段）

### P2 批 cutover（S13 QA PASS 后由 Atlas 执行，2026-09-20 增补）

> 前提：S13 QA PASS（HEAD `9557ec58`）；执行人 Atlas；QA 不触碰实机。顺序铁律同附录 B（部署物先于注册行变更）。
> **状态：已执行**（2026-09-20，Atlas）。P2 批完成：when-ops.js/p1-runscript-mounts.json 差量部署、auto-pr v1 注册禁用（Stop 仅 unified-hook）、防循环实机验证（首发单次 / 复驱门控）零 ERROR。执行中暴露事故记录 6（runtime_artifacts 漏部署 auto-pr-on-stop.sh / repo-checkout.sh，ENOENT 静默失效约 1 小时）——已手工 cp 恢复 + 探针验证，installer 部署清单完整性修复并入 P4（18280fa3）。

1. **预检**
   - `git -C <repo> rev-parse --abbrev-ref @{upstream}` = `origin/shared/SEE-1330` 且 HEAD = `9557ec58`
   - 备份：`cp ~/.claude/settings.json ~/.claude/settings.json.bak-manual-p2-$(date -u +%Y%m%dT%H%M%SZ)`
   - firelog 水位：`wc -l ~/.claude/hook-fire.log`
2. **部署物更新**（P2 差量，先于注册变更）
   - 🔴 S12 已确认实机部署态为 P1 代：本次必须更新 `~/.claude/hooks/unified/when-ops.js`（payload op）与 `~/.claude/hooks/unified/rules.d/p1-runscript-mounts.json`（含 auto-pr-stop-mount）——`install --phase P2` 的 runtime_artifacts 部署自动覆盖
   - `bash <repo>/.claude/hooks/install-hooks.sh install --settings ~/.claude/settings.json --global-hooks ~/.claude/hooks --repo-root <repo> --phase P2`
   - 部署核验：`cmp` 确认 `~/.claude/hooks/unified/when-ops.js` 与仓库一致；`grep -c auto-pr-stop-mount ~/.claude/hooks/unified/rules.d/p1-runscript-mounts.json` = 1
   - 各会话 checkout 至 `9557ec58`
3. **auto-pr v1 注册禁用（P2 批）**
   - `bash <repo>/.claude/hooks/install-hooks.sh disable-v1 --settings ~/.claude/settings.json --manifest <repo>/.claude/hooks/hooks-registration.json --global-hooks ~/.claude/hooks --phase P2`
   - 禁用清单（1 项）：`auto-pr`（Stop `*` wrapper 注册行）；保留：`repo-checkout`（P3）与已禁用 P1 批 9 项不复活；unified-hook 9 行完好
4. **Stop unified-hook 生效确认**
   - `bash <repo>/.claude/hooks/install-hooks.sh verify --settings ~/.claude/settings.json --global-hooks ~/.claude/hooks` → ok
   - settings 中 Stop 时点仅 unified-hook 注册行（auto-pr wrapper 行已移除）
5. **防循环火线观察**（10 分钟 / 首次会话 Stop）
   - `tail -f ~/.claude/hook-fire.log`：出现 `event=Stop ... fired=auto-pr-stop-mount action=...` result 行（首发单次）
   - 引擎复驱 Stop（`stop_hook_active=true`）→ **零 fired=auto-pr-stop-mount 行**（payload op 第一道防线）
   - 无 `ERROR run-script`（auto-pr 脚本 ENOENT/超时若现 → 检查 runtime_artifacts 部署）；Stop 事件无任何 deny/阻塞输出
   - 会话正常退出（无 auto-pr 循环症状：hook-fire.log 单会话 Stop 行 ≤ 2）
6. **回滚**（任一观察点失败即执行）
   - `bash <repo>/.claude/hooks/install-hooks.sh rollback --settings ~/.claude/settings.json`（指针优先）
   - 如需仅回注册不动部署物：`rollback` 天然恢复 settings 前态；部署物回退需 `--phase P1` 重装或手动 cp P1 代工件

### S13 核验记录（2026-09-20）
- 五套判据 fresh reset `9557ec58` 独立复跑：引擎 190/0、挂载 69/0、validator 232/0、安装器 41/0、dispatcher 10/10 —— 全 PASS
- auto-pr 挂载对抗复核（裸探针独立构造，不信任自报）：stop_hook_active 无字段 FIRED / 显式 false FIRED / true GATED / 字符串 "true" GATED（truthy 语义钉一致）；实机主配置 Stop 事件 exit 0 零 deny（恒不阻塞）；main→rules.d 叠加顺序 main@22 < mount@28 实证
- §SPEC-005 判据：套件 §8 四例（首发单次/复驱门控/fail-open/M2 把关）+ §9 十六例全绿 —— PASS
- §6.4 对照核验：双防线（引擎 payload op + 脚本内 `stop_hook_active === true` 检查 L24-37 独立在位）、payload op 判读语义（缺失/null/false=未置位；true 及 truthy=已置位；equals:true=字面 true）、M2 把关 —— 与代码/配置实况一致
- P1 遗留确认：mention 系 legacy 标注维持（PRE-EXISTING-DRIFT，不阻塞）；等价保留项 #1–#6 状态不变；#2 已于 P1 消亡（see764 再定向）

### P3 批 cutover（S17 QA PASS 后由 Atlas 执行，2026-09-20 增补）

> 前提：S17 QA PASS（HEAD 含 §10 探针 equals 化清理）；执行人 Atlas；顺序铁律同附录 B。
> **状态：已执行**（2026-09-20，Atlas）。P3 批完成：repo-checkout-mount 部署 + SessionStart v1 注册禁用；**v2 全时点接管里程碑达成**——9 时点仅存 unified-hook 注册行，v1 wrapper 注册行清零（P1 批 9 项 + P2 auto-pr + P3 repo-checkout = 11 项全部禁用），marker 幂等探针实机通过。

1. **预检**
   - `git -C <repo> rev-parse --abbrev-ref @{upstream}` = `origin/shared/SEE-1330` 且 HEAD ≥ P3 hardening commit
   - 备份：`cp ~/.claude/settings.json ~/.claude/settings.json.bak-manual-p3-$(date -u +%Y%m%dT%H%M%SZ)`；firelog 水位 `wc -l ~/.claude/hook-fire.log`
2. **部署差量**（P3 批仅两项）
   - `~/.claude/hooks/unified/rules.d/p1-runscript-mounts.json` 更新（第 8 条 `repo-checkout-mount` 加入）
   - `~/.claude/hooks/scripts/repo-checkout.sh` runtime artifact 更新
   - `bash <repo>/.claude/hooks/install-hooks.sh install --settings ~/.claude/settings.json --global-hooks ~/.claude/hooks --repo-root <repo> --phase P3`（artifacts 部署 + SessionStart unified-hook 注册行注入）
   - 部署核验：`grep -c repo-checkout-mount ~/.claude/hooks/unified/rules.d/p1-runscript-mounts.json` = 1；`cmp` rules.d 与仓库一致
3. **repo-checkout v1 注册禁用（P3 批，SessionStart 时点唯一 v1 行）**
   - `bash <repo>/.claude/hooks/install-hooks.sh disable-v1 --settings ~/.claude/settings.json --manifest <repo>/.claude/hooks/hooks-registration.json --global-hooks ~/.claude/hooks --phase P3`
   - 禁用清单（1 项）：`repo-checkout`（SessionStart `*` wrapper 注册行）
4. **v2 全时点接管完成确认**（P3 后里程碑）
   - settings 中 9 时点（PreToolUse/PostToolUse/SessionStart/SessionEnd/Stop/SubagentStop/UserPromptSubmit/Notification/PreCompact）**仅存 unified-hook 注册行，v1 wrapper 注册行清零**（P1 批 9 项 + P2 批 auto-pr + P3 批 repo-checkout = 11 项全部禁用）
   - `bash <repo>/.claude/hooks/install-hooks.sh verify --settings ~/.claude/settings.json --global-hooks ~/.claude/hooks` → ok
5. **火线观察**（首个新会话 SessionStart）
   - `tail -f ~/.claude/hook-fire.log`：`event=SessionStart ... fired=repo-checkout-mount` result 行出现（checkout hint 以 additionalContext 注入会话）
   - 10 分钟内同目录二次 SessionStart → 无重复 hint（marker 快路径）
   - 无 `ERROR run-script` / `ERROR rules-d-*` 行；会话启动无阻塞（SessionStart 恒 exit 0）
6. **回滚**
   - `bash <repo>/.claude/hooks/install-hooks.sh rollback --settings ~/.claude/settings.json`（指针优先，恢复 P2 批终态 = auto-pr 禁用 + repo-checkout v1 注册恢复）

### S17 核验记录（2026-09-20）
- 五套判据 fresh reset 独立复跑：引擎 190/0、挂载 82/0、validator 232/0、安装器 41/0、dispatcher 10/10 —— 全 PASS（§SPEC-006/010/011 前置 S16 硬化 3/3 记录完整）
- repo-checkout 挂载对抗复核（裸探针修正后）：startup 首发 HINT / resume 600s 内 SILENT（快路径）/ stale marker 全路径 HINT（慢路径）/ UPS 不命中 equals:SessionStart（SILENT）/ UPS 后 SessionStart 仍 HINT（marker 未被消费）/ 二次 SessionStart SILENT（marker）—— 6/6 与 §2.7-after 一致
- §SPEC-008 P3 段：§2.7-after 迁移后行逐格与 rules.d 第 8 条 + repo-checkout.sh 实况一致；`in[]` 语义钉按裁定落档：**payload op 语义 = 单值 equals/isSet，多值匹配不支持、靠 on.in 兜底，词表收敛候选留 P4 决策**
- §10 死配置清理（S17 执行项）：探针规则 `in[]` → equals 单值双规则等价改写（SessionStart/UPS 各一），82/0 复跑全绿，行为零变化

### S20 一致性审计记录（P4 hardener，2026-09-20）
- 处置记录 1–5 逐条对照仓库实况：① dispatcher 仅剩 unified-hook case（grep 证实 0 个 v1 alias case）✓；② v1 兼容层（desugar.js 退役、engine v1_compat/v1_rules_file 零引用、rules-v2 无 v1_compat 键）✓——**勘误**：pre-comment-skill-check.sh 与 tscn-tres-guard.sh 文件仍留存仓库（不在 runtime_artifacts、无任何注册/路由引用方，属死文件），「退役」实为「除部署面外退役」；物理删除留 Archi/Refacty 裁定（S20 约束不改产品面）；③④ reconcile-working-branch.sh / mcp-tool-presence.sh 原位保留（后者仍被 repo-checkout.sh 引用 ×2）✓；⑤ 8 个挂载脚本全部在位 ✓。
- 等价保留项终态清点：#1 sentinel TOCTOU（保留）；#2 see764 漂移（P1 消亡）；#3 dispatcher 双副本时序（P1 cutover 消除）；#4 block 前缀统一（收敛目标达成）；#5 sentinel 键格式（v2 设计）；#6 TOCTOU 继承（保留）；`in[]` 语义钉（payload op 单值 equals/isSet，P4 词表候选——P4 未扩词表，钉维持）；事故 4（修正落地）/5（5e 修复落地，installer §8）/6（部署清单补全，18280fa3）均已关闭。
- 新增审计用例（engine 套件 §21，+7）：21a v1 残留 grep 零误伤（子串字段名）+ 零漏检（注入残留即红 + v1_rules_file 引擎层忽略）×4；21b dispatcher 11 别名 + 未知 alias 全量静默透传矩阵（必发规则判别形态）+ unified-hook 正路由 ×2；21c installer 9a 清单覆盖探针（完备态 COMPLETE + 漏列场景即红）×2；21d 聚合 runner 失败传播（单套件红→非零退出+报告；健康路径 ALL GREEN）×2。
- S20 变异抽查 3 点（累计 22 点零重复）：R1 dispatcher 未知 alias 误路由 unified-hook（初轮存活 → 21b 必发规则判别形态补杀）；R2 run_all 失败传播退出码归零（21d 杀）；R3 engine rules.d 目录扫描失效（挂载套件 12 例杀，跨套件 kill 有效）——kill 3/3，全部还原确认。

### P4 批实机收敛 runbook（S21 QA PASS 后由 Atlas 执行，2026-09-20 增补）

> 前提：S21 QA PASS（HEAD ≥ `4c383d1f`，含事故 7 hotfix）；执行人 Atlas；顺序铁律同附录 B。
> **状态：已执行（终态）**（2026-09-20，Atlas）。P4 实机收敛完成：dispatcher 全局副本同步（v1 alias case = 0，仅 unified-hook case 全局优先）、部署面旧 alias 脚本下线（`~/.claude/hooks/` 移除 pre-comment-skill-check.sh / tscn-tres-guard.sh / skill-check-rules.json；仓库内文件留存待本终审裁定，见 §7 死文件处置终审）、install 幂等补齐 + verify ok、事故 7 热修 engine.js 在位（`unified/state/` 主落点工作）、火线观察 9 时点 unified-hook 行正常且 v1 alias 行消失。**v2 单轨架构全时点收敛到此收口。**

1. **预检**
   - `git -C <repo> rev-parse --abbrev-ref @{upstream}` = `origin/shared/SEE-1330` 且 HEAD ≥ `4c383d1f`
   - 备份：`cp ~/.claude/settings.json ~/.claude/settings.json.bak-manual-p4-$(date -u +%Y%m%dT%H%M%SZ)`；firelog 水位
2. **dispatcher 全局副本同步**（收敛核心：单一路由上线）
   - `cp <repo>/.dev/hooks/dispatcher.sh <repo>/.dev/hooks/hook-wrapper.sh ~/.claude/hooks/`
   - 核验：`diff <repo>/.dev/hooks/dispatcher.sh ~/.claude/hooks/dispatcher.sh` = 空；`grep -c "unified-hook)" ~/.claude/hooks/dispatcher.sh` = 1 且 v1 alias case = 0
3. **旧 alias 脚本部署面下线**（对照清单处置记录 2/4 口径）
   - 自 `~/.claude/hooks/` 移除：`pre-comment-skill-check.sh`、`tscn-tres-guard.sh`（部署面退役项；仓库内文件保留，物理删除待 Archi 终审裁定）
   - `~/.claude/hooks/skill-check-rules.json` 同批移除（唯一引用方为已退役 pre-comment-skill-check.sh）
   - 保留：8 个挂载脚本 + `reconcile-working-branch.sh` + `mcp-tool-presence.sh` + `godot-mcp-launch-path.lib.sh`
4. **运行物差量核对**（事故 7 热修已在位确认）
   - `cmp ~/.claude/hooks/unified/engine.js <repo>/.claude/hooks/unified/engine.js` = 一致（sentinel 双落点）；`ls ~/.claude/hooks/unified/state/` 目录可用（`HOOK_STATE_DIR` 未设时主落点）
   - `bash <repo>/.claude/hooks/install-hooks.sh install --settings ~/.claude/settings.json --global-hooks ~/.claude/hooks --repo-root <repo> --phase P3`（幂等补齐 artifacts，P0–P3 禁用批不动）
   - `bash <repo>/.claude/hooks/install-hooks.sh verify --settings ~/.claude/settings.json --global-hooks ~/.claude/hooks` → ok
5. **收敛后火线观察**（10 分钟 / 首次各时点触发）
   - 9 时点 unified-hook `event=...` result 行正常；`alias=skill-check` 等 v1 alias 行**消失**
   - 无 `ERROR engine-missing/engine-exit/rules-d-*`；one_shot 语义正常（首触发一次，重复不重发——事故 7 回归钉）
   - `~/.claude/hooks/unified/state/` 出现 sentinel 文件（主落点工作）
6. **回滚**（P3 批终态恢复路径）
   - `bash <repo>/.claude/hooks/install-hooks.sh rollback --settings ~/.claude/settings.json`（恢复 settings）
   - dispatcher 回退：`git -C <repo> show 4c383d1f~1:.dev/hooks/dispatcher.sh > ~/.claude/hooks/dispatcher.sh`（P3 代副本，恢复 v1 alias case）；下线脚本回置：从仓库 `git show 4c383d1f~1:<path>` 恢复

### §7.2 收尾批执行记录（2026-09-20，Owner 指令：老架构完全退役后再做字段级补测）

- **产品面死文件物理删除**：`.claude/hooks/pre-comment-skill-check.sh`、`.claude/hooks/skill-check-rules.json`、`.claude/hooks/tscn-tres-guard.sh`（git rm，本提交）
- **11 个结构性 RED 套件归档退役** → `.dev/tests/hooks/legacy-v1/`（see399/see1125/see1151_qa/see1238_qa/e2e/see637/see678/see653_jsonl/see773，git mv 保留历史）
- **注册断言类套件 v2 终态重写**：test_hook_registration_see270（9 时点 unified-hook 完整性 + 11 v1 alias 清零 + 清单真源在位）、test_hooks_architecture_see188（组件在位/单一路由/兼容层退役/规则校验自洽）
- **全局部署位收尾**：`~/.claude/hooks/hook-wrapper.sh.bak` 移除；retired 三文件确认从未部署（P0–P3 runtime_artifacts 不含）
- **终验**：grep 死文件引用 `.claude/hooks/`+`.dev/hooks/` = 0；聚合 runner ALL GREEN；see270/see188 重写版 exit 0
- **🔴 回退路径**（若 v2 链路故障需回退 v1）：
  1. `git -C <repo> revert <本提交>` —— 恢复全部退役文件与套件（git 历史完整保留）
  2. 从恢复后的仓库重新部署：`cp <repo>/.claude/hooks/{pre-comment-skill-check.sh,tscn-tres-guard.sh,skill-check-rules.json} ~/.claude/hooks/`
  3. settings 恢复 v1 注册行：用 `~/.claude/settings.json.bak-manual-p4-*`（P4 批前备份，含 11 项 v1 注册）覆盖，或手工按对照清单 §2.1 快照回加
  4. dispatcher 回退 v1 alias 路由：`git -C <repo> show 4c383d1f~1:.dev/hooks/dispatcher.sh > ~/.claude/hooks/dispatcher.sh`
  5. 验证：`bash <repo>/.claude/hooks/install-hooks.sh verify` + firelog 出现 v1 alias 行
  6. 重新对齐注册真源：hooks-registration.json 若已删除条目，从 revert 后版本取回

### S21 核验记录（2026-09-20）
- 五套判据 fresh reset `4c383d1f` 独立复跑：聚合 runner ALL GREEN；引擎 182/0、安装器 43/0、挂载 78/0、dispatcher 10/10、validator 230/0 —— 全 PASS
- §SPEC-007 独立判定：unified 树 v1 字段残留 0（trigger/condition/v1_compat/v1_rules_file）；desugar.js 退役；engine v1 引用 0；dispatcher 单一 unified-hook case + 0 v1 alias case —— **PASS**
- 全链终态清点：8 挂载脚本在位 ✓；2 部署面退役脚本文件留存但零部署/路由引用 ✓；reconcile/mcp-tool-presence 保留（后者被引用 ×2）✓；rules-v2 14 条 + rules.d 8 条 ✓
- 事故 7 热修回归：§13/§19 sentinel 系列全 PASS；双落点裸探针（主落点抑制 + /tmp compat 清空后仍抑制 + 主落点清除后重触发）6/6 ✓；实机部署态 engine.js 与仓库一致（hotfix 已部署）
- 死文件处置建议：`pre-comment-skill-check.sh`（+ 其唯一依赖 `skill-check-rules.json`）与 `tscn-tres-guard.sh` 零部署/路由引用，仅被 4+2 个 v1 legacy 直测套件引用（S4 已裁定 PRE-EXISTING-DRIFT）——**建议 P4 收敛批后物理删除**（连同对应 6 个 legacy 套件归档退役），由 S22 Archi 终审定夺

## 7. S22 终审（Archi，2026-09-20）

### 7.1 对照清单全链一致性终审结论

按 §SPEC-008 判据对全文做一致性通审（终审基线 HEAD `df22a2b5` + 本节增补），逐段核对仓库实况（rules-v2.json 14 条 / rules.d 8 条 / dispatcher 单 unified-hook case / hooks-registration.json / 12 hook 脚本）与六轮核验记录（S4/S9/S13/S17/S20/S21）：

| 段 | 终审结论 |
|---|---|
| §1 v1 架构基线 + §2.1–2.11 基线表 | ✓ 与 P0 探查事实一致，历史快照保留正确（不动） |
| §2.x-after 迁移后段（mention/push/gdformat/auto-pr/repo-checkout/taskflow） | ✓ 逐格与 rules.d 挂载规则实况核对一致（8 条挂载含 push-guard-mount，run_script 通道三形态 + deny_exit_codes + on_fail 语义与 §3.5-after 一致） |
| §5 迁移后对照表（S5 配置化 2 行）+ §6.1 逐规则 13 条对照 | ✓ 与 rules-v2.json 实况一致（14 条 = 13 v1 翻译 + tscn-tres-guard；action 形态 deny×5 / context×7 / doc-reminder disabled=1；one_shot{scope:run}×10 与 §6.1 表逐条对得上） |
| §6.2 挂载规格 / §6.4 防循环规格 | ✓ 与 p1-runscript-mounts.json 的 auto-pr-stop-mount payload op + 脚本内 L23-37 双防线一致 |
| 等价保留项 #1–#6 + `in[]` 语义钉 | ✓ 终态清点（S20）无误：#1/#6 保留、#2 P1 消亡、#3 P1 消除、#4/#5 收敛目标达成；`in[]` 钉维持（P4 未扩词表） |
| 事故记录 4/5/6/7 | ✓ 4 项均已关闭（修正/修复/清单补全/双落点热修均落地并有套件钉住）；P2 批 runbook 状态标注补记事故 6 |
| 处置记录 5 条 | ✓ 与仓库实况一致（dispatcher 0 v1 alias case、desugar 退役、8 挂载脚本在位、reconcile/mcp-tool-presence 保留）；记录 2 的「退役」措辞已由 S20 勘误为「除部署面外退役」，本节 §7.2 给出物理删除终裁 |
| 六轮核验记录交叉引用 | ✓ 无未闭合事项；套件状态与 run_all.sh ALL GREEN 复跑一致（本终审独立复跑：引擎/安装器/挂载/dispatcher/validator 全绿） |

**终审结论：PASS。** 迁移对照清单全链（基线 → P0–P4 迁移后 → 等价保留项终态 → 事故/处置记录 → 核验记录）内部一致、与代码/配置实况一致、无未闭合事项。§SPEC-008 之「Archi 终审」签字到此完成。

### 7.2 死文件处置终审裁定（S21 遗留裁定输入）

**裁定：物理删除（P5/后续 issue 执行），6 个 v1 legacy 直测套件同步归档退役；不阻塞本次合并。**

| 对象 | 裁定 | 依据 |
|---|---|---|
| `.claude/hooks/pre-comment-skill-check.sh`（643 行） | **删除** | 14 条 v2 规则已全量配置化替代（§6.1 逐规则等价）；P4 后零注册/零路由/零部署（不在 runtime_artifacts、dispatcher 仅 unified-hook case、全局部署面已下线）；实测仅被 legacy 直测套件引用 |
| `.claude/hooks/skill-check-rules.json` | **删除** | 唯一引用方为已裁删的 pre-comment-skill-check.sh；规则真源已迁移至 unified/rules-v2.json |
| `.claude/hooks/tscn-tres-guard.sh`（38 行） | **删除** | v2 规则 `tscn-tres-guard`（rules-v2.json §404，additionalContext 原文案保真）已替代；零注册/零路由/零部署 |
| 6 个 v1 legacy 直测套件 | **归档退役**（移入 `.dev/tests/hooks/legacy-v1/` 并从 run_all 排除，或直接删除——二选一由执行批定） | 实测 16 个引用死文件的套件中 11 个 RED（testee 已退役，属结构性失败非回归）；其余 5 个 GREEN 套件（grepai×3/see802/see653-dispatcher 等）引用为 fixture 或注释残留，随批清理引用行即可保留 |

执行归属：**Atlas 在 Final Review 后的收尾批执行**（本子步骤不改产品面文件，遵守 doc 约束）；删除前以 `grep -rn` 终验零引用 + run_all.sh 复跑全绿。注意：`test_hook_registration_see270.sh` 与 `test_hooks_architecture_see188.sh` 属「注册断言/架构巡检」类套件，不应删除而应随收敛更新断言（P4 已有 installer 9a 覆盖探针承接，见遗留清单 #4）。

### 7.3 遗留事项清单（终审视角，供 Owner 与后续 issue 参考）

| # | 事项 | 级别 | 责任归属 | 建议时点 |
|---|---|---|---|---|
| 1 | `repo-checkout.sh` 834 行超 800 上限（§2.7-after 已记录）——建议拆出 lib 层（marker 管理分支：`.cc-aligned-*` 600s 新鲜度 + 分支/upstream 校验 + reconcile 通知文案），行为零变化 | MEDIUM | Bachi（code） | 下次触碰 repo-checkout 的 issue 顺手执行 |
| 2 | `in[]` 词表候选（S17 语义钉维持）：payload op 仅单值 equals/isSet，多值匹配靠 on.in 兜底；现网无需求，扩词表须重跑 M1–M7 矩阵 | LOW | Atlas 编排 + Bachi | 有真实多值需求时 |
| 3 | sentinel TOCTOU 竞态窗口（等价保留项 #1/#6）：checkSentinel→when 求值→writeSentinel 非原子；v1 同窗口语义等价保留。若未来出现同 run 双触发实害再立项 | LOW | Atlas 裁定 | 出现实害时 |
| 4 | 死文件物理删除 + 6 legacy 套件归档（§7.2 裁定）+ 注册断言类套件（see270/see188）随 v2 终态更新断言 | MEDIUM | Atlas 收尾批 | Final Review 后、合并前或合并后首个收尾批 |
| 5 | `hooks-implementation-guide.md` 已随本批更新至 v2 单轨架构；后续任何 hooks 增删须同步 rules-v2.json/rules.d 与 guide §4/§5（维护条款已迁移） | LOW | 全体（文档纪律） | 持续 |
| 6 | dispatcher `WSL_CANDIDATES` 硬编码 Windows 主仓库路径——本地 CC 直开主仓库场景专用；若主仓库路径迁移须同步（guide §4.4 已有维护条款） | LOW | Refacty | 路径变更时 |

### 7.4 终审核验记录（S22 自证）

- 工作树对齐：`git rev-parse --abbrev-ref @{upstream}` = `origin/shared/SEE-1330`（HEAD `df22a2b5` + 本节增补）
- 聚合 runner 独立复跑：`bash .dev/tests/hooks/run_all.sh` → ALL GREEN（引擎/安装器/挂载/dispatcher/validator 五套全绿）
- 死文件引用面独立取证：16 套件引用死文件 → 实测 11 RED（结构性失败：testee 缺失/语义漂移）+ 5 GREEN（fixture 或注释残留）；`.claude/hooks/`、`.dev/hooks/`、runtime_artifacts、dispatcher 均零引用（仅 pre-comment-skill-check.sh 自身文本含 skill-check-rules.json 读取逻辑）
- 规则清单独立核对：rules-v2.json 14 条（5 deny / 7 context / 1 disabled）+ rules.d 8 条挂载，与 §6.1/§2.x-after 逐条一致

## 8. 目录归集处置记录（S19b 归集批，Refacty，2026-09-20）

Owner 指令：「自定义脚本要归集到 hooks/scripts 下面」。业务脚本从 `.claude/hooks/` 根归集入 `.claude/hooks/scripts/`，共享 lib 入 `.claude/hooks/scripts/lib/`；框架文件（unified/、tests/、hooks-registration.json、install-hooks.sh、registry-patch.js、validate-rules.js）留根不动。行为零变化：聚合 runner ALL GREEN + see270/see188 exit 0 + 挂载套件 78/0；全 test_*.sh 树与归集前基线对照零新增失败（预存环境漂移 24 例不变，see756 因路径修正转绿）。

### 8.1 移动映射表（旧路径 → 新路径）

| 旧路径 | 新路径 |
|---|---|
| `.claude/hooks/gdformat-gdlint.sh` | `.claude/hooks/scripts/gdformat-gdlint.sh` |
| `.claude/hooks/mention-check.sh` | `.claude/hooks/scripts/mention-check.sh` |
| `.claude/hooks/push-guard.sh` | `.claude/hooks/scripts/push-guard.sh` |
| `.claude/hooks/auto-pr-on-stop.sh` | `.claude/hooks/scripts/auto-pr-on-stop.sh` |
| `.claude/hooks/atlas-taskflow-mark-a.sh` | `.claude/hooks/scripts/atlas-taskflow-mark-a.sh` |
| `.claude/hooks/atlas-taskflow-mark-b.sh` | `.claude/hooks/scripts/atlas-taskflow-mark-b.sh` |
| `.claude/hooks/atlas-taskflow-exit-reminder.sh` | `.claude/hooks/scripts/atlas-taskflow-exit-reminder.sh` |
| `.claude/hooks/repo-checkout.sh` | `.claude/hooks/scripts/repo-checkout.sh` |
| `.claude/hooks/mcp-tool-presence.sh` | `.claude/hooks/scripts/mcp-tool-presence.sh` |
| `.claude/hooks/reconcile-working-branch.sh` | `.claude/hooks/scripts/reconcile-working-branch.sh` |
| `.claude/hooks/godot-mcp-launch-path.lib.sh` | `.claude/hooks/scripts/godot-mcp-launch-path.lib.sh` |
| `.claude/hooks/lib/gitlink-probe.sh` | `.claude/hooks/scripts/lib/gitlink-probe.sh` |
| `.claude/hooks/lib/gitlink-sync-hint.sh` | `.claude/hooks/scripts/lib/gitlink-sync-hint.sh` |

### 8.2 引用面更新清单

1. `unified/rules.d/p1-runscript-mounts.json`：8 条挂载 `${HOOKS_DIR}/<script>.sh` → `${HOOKS_DIR}/scripts/<script>.sh`
2. `hooks-registration.json` runtime_artifacts：8 脚本条目加 `scripts/` 前缀
3. `install-hooks.sh`：无需改动（按 manifest artifact 相对路径部署，`mkdir -p $(dirname $dest)` 已覆盖 scripts/ 子目录）
4. `scripts/repo-checkout.sh` 内部：mcp-tool-presence.sh 引用、gitlink-sync-hint.sh 引用更新；launch-path lib 经 BASH_SOURCE 相对定位自解析
5. `scripts/push-guard.sh` / `scripts/auto-pr-on-stop.sh`：gitlink-probe.sh source 路径更新
6. 48 个测试套件脚本路径 + v2 挂载/引擎套件 fixture 布局（`$HOOKSROOT/scripts/`）+ gitlink 两套件 lib symlink 挂点 + see1008 历史 ref 路径保留旧值（git-show 历史路径不可改）
7. `hooks-implementation-guide.md` 与本清单路径引用更新

实机部署同步（`~/.claude/hooks/scripts/` 布局）由 Atlas 在本批 QA 后执行；S25 挂载证据将在终态布局复核。

## 9. SEE-1333 修复批（Bachi，2026-09-21）

Owner 裁定（SEE-1333）：D1/D2/engine.js 真源三项全部本 issue 内修复 + 新增 D3 指令。Revy ④ QA 复测发现 D1（HIGH）/D2（MEDIUM），D3 为 Owner 直派。本批改动与自验：

| # | 缺陷 | 修复 | 文件 | 自验 |
|---|---|---|---|---|
| D1 | HIGH：mention-confirm-check 对 `--content-file` 相对路径间歇性盲视（loadCommentContent 仅 cwd/projectRoot 候选，不可读静默置空） | 多候选回退平移自 mention-check.sh：cwd → projectRoot → `$MULTICA_WORKDIR` → cwd/.. | `unified/when-ops.js` | fixture 单元级+引擎级（cwd=repo 子目录、MULTICA_WORKDIR 指向 workdir → mention-confirm 首检恢复命中；无 MULTICA_WORKDIR 时保持 v1 盲视行为 = 回退必要性对照） |
| D2 | MEDIUM：mention-check SENTINEL_PASS fast-path + NO_MENTION「首拦后续放行」使无 mention 评论免检直通 | 移除两处 fast-path 读；无 mention 逐条拦截；sentinel 写入保留为观测记录 | `scripts/mention-check.sh` | fixture 脚本级（首拦/二次拦/PASS 后仍拦三态全 DENY） |
| D3 | HIGH（Owner 指令）：recall-reminder scope:issue 使 issue 维度 sentinel 被首个 run 消耗后其余 agent 零注入 | one_shot 改 `{scope:"run"}`（run 天然归属单一 agent → 每 agent 每 run 注入） | `unified/rules-v2.json` | fixture 引擎级生产仿真（HOOK_ISSUE_ID 显式注入）：新 run 首调注入 / 同 run 抑制 / 换 run 重注入 |
| 真源 | 部署位 engine.js 含 SEE-1330 M4 多 deny 叠加语义（Owner 指令 2026-09-21），仓库真源为首条胜出旧逻辑（27 行 diff） | 部署位 → 仓库真源回写，`cmp` 零 diff；多 deny 文案按规则顺序全量输出 | `unified/engine.js` | cmp 零 diff + fixture 双规则 deny 双文案（bachi skill-check + mention-confirm）按序叠加 |

配套测试断言随行为裁定更新（旧断言锁定的是被裁定废除的语义）：

- `test_mention_check_sentinel_see453.sh`：S1b/S1c/S1d/S1e/S1f、S3A-2~5、S3C-2/3 改逐条拦截语义
- `test_mention_check_see469_no_mention_sentinel.sh`：G1a-2/G1b-2/G1e-2/G3b-2/G3f-2 改二次仍拦
- `test_mention_check_see400_json_escaping.sh`：G1b/G2b/G5 改 mention-bearing passthrough 语义（PHASE2 移除遗留断言，基线即失败 7 项，本批收敛为 0）
- `test_v2_unified_engine_p0.sh`：16b 改 M4 全量输出语义 + 新增 16b-2 规则顺序断言

回归基线（push 前，2026-09-21）：validate-rules 14/14 + 8/8 VALID；validator.test.mjs 230/230；v2 三套件（engine_p0 / runscript_mounts_p1 / installer_p0）+ mention-check 四套件（see453 / see469 / see400 / see471）全 PASS；修复 fixture 12/12（red→green 全程留档）。

实机部署位同步（when-ops.js / mention-check.sh / rules-v2.json；engine.js 已一致）按 runbook 由 Atlas 在 QA 通过后执行。

## 10. SEE-1333 第二批：隔离 invariant + one_shot 去 scope 化（D4）（Bachi，2026-09-21）

Owner 第二/三轮裁定并入：§SPEC-013 隔离 invariant（sentinel 键加 agent 维度）+ §SPEC-006b one_shot 去 scope 名字层（原 §SPEC-006 obsolete）。与第一批（§9）同分支推进，本批为独立 commit。

### 10.1 引擎语义变更（`unified/engine.js`）

| 维度 | 变更前 | 变更后 |
|---|---|---|
| one_shot 配置 | `{scope:"issue"\|"run"\|"session"\|"never"}` 名字层 + 三层降级链（issue 缺 id→run→session，各落 WARN） | `{id:"issue"\|"run"}` 直接窗口 id 来源；`{scope}` 迁移期同名映射兼容（`session` 并入 run 窗口源）；无降级链 |
| 窗口 id 解析 | issue=HOOK_ISSUE_ID；run=HOOK_SCOPE_ID（mention-confirm 特例 HOOK_RUN_SCOPE_ID 优先）；session=payload.session_id\|'nosession' | issue=HOOK_ISSUE_ID；run=**HOOK_RUN_SCOPE_ID‖HOOK_SCOPE_ID‖session_id**（run/session 合一为单一窗口源；顺带消除 HOOK_SCOPE_ID 含 issue id 时的跨 run 泄漏隐患与 mention-confirm 特例） |
| id 缺失行为 | 降级链兜底（session/nosession 键照常拦截/注入） | **fail-open：跳过规则不拦截** + `WARN one-shot-id-missing` 审计（deny 规则绝不因窗口不可解析阻塞调用） |
| sentinel 键 | `.hook-fired-<rule>-<scopeId>`（无 agent 维度，跨 agent 共享） | `.hook-fired-<rule>-<agent>-<windowId>`（§SPEC-013 invariant：隔离由机制保证；无 agent 名显式占位 `noagent`） |

### 10.2 配置与校验

- `unified/rules-v2.json`：10 条 one_shot 规则全部迁移 `{scope}` → `{id}`（8×issue + 2×run），行为面不变。
- `validate-rules.js`：`transOneShot` 接受 `{id}`（白名单 issue/run）；`{scope}` 迁移期兼容（`session` 映射 run + 合一提示；其余形态落改写建议）；id 缺失告警语更新为 fail-open 语义。

### 10.3 配套测试断言更新（随裁定行为）

- `test_v2_unified_engine_p0.sh`：§5（5a-d2：窗口链/fail-open/键形状）、§9（9a/9b agent 键）、§13（13a session 回落、13b nosession 退役→fail-open、13d sanitize）更新；新增 5d2/13b fail-open WARN 断言与 16b-2（第一批）顺序断言。
- `test_v2_runscript_mounts_p1.sh`：7h 键形状加 agent 段 + 环境档位修正（D4 后 HOOK_RUN_SCOPE_ID 优先级最高，清空 TASK_ID 以保真「session_id 不参与键」测试意图）。
- `validator.test.mjs`：transOneShot 用例改 fail-open 告警语 + 新增 `{id}` 白名单/兼容形态/session 合并覆盖。

### 10.4 自验与回归（push 前）

- 修复 fixture 14/14（red→green：跨 agent 共享抑制 ×2、{id:issue} 被当 run 窗口、无 id 仍拦截 + WARN 缺失、生产形态 mention-confirm 键无 agent 段——六项 red 全部转绿）。
- run_all.sh 聚合 ALL GREEN；validator 14/14 VALID；validator.test.mjs 230/230；bash -n / node --check 全过。

实机部署位同步（engine.js / when-ops.js / mention-check.sh / rules-v2.json / validate-rules.js）在 QA 通过后按 runbook 由 Atlas 一次性执行（含部署位 state/ 旧格式 sentinel 的自然失效——键格式变更后旧键不再命中，one_shot 窗口等效重置一次，无行为风险）。

## 11. SEE-1333 第三批：one_shot 窗口 id 组合框架（D4 最终形态）（Bachi，2026-09-21）

Owner 第四轮裁定：组合框架取代 §10.1 的「统一加 agent 段」简单形态，成为 §SPEC-006b/§SPEC-013 最终语义。本批覆盖批二同区域实现。

### 11.1 最终语义

| 维度 | 最终形态 |
|---|---|
| one_shot 配置 | 单 id `{id:"issue"\|"run"}` per 单 id；**多 id `{ids:[...]}` per 各分量笛卡尔组合**（类比 when 层 op 组合）；分量白名单 `agent\|issue\|run` |
| sentinel 键 | `.hook-fired-<rule>-<分量 join('-')>`——组合框架下 agent 恒为存量规则组合分量（键内天然 per-agent 隔离，不依赖 agents 门控）；单 id 形态键无 agent 段 |
| 分量解析 | `agent`=MULTICA_AGENT_NAME（缺失占位 noagent）；`issue`=HOOK_ISSUE_ID；`run`=HOOK_RUN_SCOPE_ID‖HOOK_SCOPE_ID‖session_id（run/session 合一单一窗口源） |
| id 缺失 | 任一分量不可解析 → fail-open：跳过规则不拦截 + `WARN one-shot-id-missing rule=X id=<分量+清单>`；`{scope:"never"}` 语义保留 = 非一次性（无窗口） |
| 存量迁移 | 4 skill-check + 4 agent reminder → `{ids:["agent","issue"]}`；mention-confirm-check / recall-reminder → `{ids:["agent","run"]}`；10 条行为面不变（组合键形状与批二统一加段形态对这 10 条恰好同形） |
| validator | `transOneShot` 接受 `{ids}`（分量白名单 + 非空校验，S_scope='combo'）；`{id}`/`{scope}` 保留为次选/迁移期兼容 |

### 11.2 自验与回归

- fixture 14/14（red→green：{ids} 组合跨 agent 隔离、单 id 键形状、WARN 分量清单、mention-confirm 生产键 agent+run 组合）。
- run_all.sh ALL GREEN（engine_p0 新增 §13e 组合用例：双 agent 同窗口各自触发 + 双键落盘）；validate-rules 14/14；validator.test.mjs 230/230（新增 {ids} 覆盖）。

部署位同步清单同 §10（engine.js/rules-v2.json/validate-rules.js 与批二合并为一次部署）。

## 12. SEE-1333 第四批：one_shot 分量直读 env var 名（Owner 第五轮裁定终态，Bachi，2026-09-21）

Owner 裁定（原文「不用分量解析了，套个壳子没意义，直接让填 env var 的名字」）：组合框架的分量白名单壳子（agent/issue/run 命名层）整体退役，分量直接填 env var 名。

| 维度 | 终态 |
|---|---|
| 配置形态 | `{ids:["MULTICA_AGENT_NAME","HOOK_RUN_SCOPE_ID"]}`（多分量组合）/ `{id:"HOOK_ISSUE_ID"}`（单 env）——分量 = env var 名，引擎直读 `process.env[<name>]` |
| sentinel 键 | `.hook-fired-<rule>-<各 env 值 join('-')>`——键形状不变，仅分量来源从命名层改为 env 直读 |
| 存量映射 | 8 条 → `{ids:["MULTICA_AGENT_NAME","HOOK_ISSUE_ID"]}`；mention-confirm-check / recall-reminder → `{ids:["MULTICA_AGENT_NAME","HOOK_RUN_SCOPE_ID"]}`；键形状与 §11 终态同形（agent env 恒为分量，隔离语义不变） |
| run/session 合一 | 由入口层承载：`unified-hook.sh` 保证 `HOOK_RUN_SCOPE_ID` 缺位时回落 `HOOK_SCOPE_ID`；引擎不再内建兜底链 |
| fail-open | 任一 env var 未设置/空 → 跳过规则不拦截 + `WARN one-shot-id-missing rule=X id=<var 名 join('+')>` |
| 布尔/缺省 one_shot | 等价 `{ids:["MULTICA_TASK_ID"]}`（v1 兼容行） |
| validator | `{ids}`/`{id}` 分量校验 = env var 名形状（shell 标识符）+ 旧 scope 名（agent/issue/run/session/never）显式拒绝防误用静默失效；`{scope}` 保留迁移期兼容（scope:"run" ≙ MULTICA_TASK_ID 窗口，never = 非一次性） |
| 好处 | 窗口源零注册成本——新 env var（平台新增 id 注入）即时可用，无需改引擎；配置自文档化（直接可见数据来源） |

### 12.1 自验与回归

- fixture 14/14（red→green：env 组合键跨 agent 隔离、单 env 键形状、WARN 含 var 名清单、生产 mention-confirm 键 = agent+run env 值组合）。
- run_all.sh ALL GREEN；validate-rules 14/14；validator.test.mjs 230/230；P0 §5/§9/§13/§19 断言随终态更新（env 直读 + 兼容形态语义锁定）。

部署位同步清单同 §10（本批改动与批二/批三合并为一次部署）。
