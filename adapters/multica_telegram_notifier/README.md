# Multica → Telegram 通知适配器（SEE-1561 / SEE-1567）

独立的 Python 适配器：连接 Multica realtime WebSocket，监听目标 workspace 的
`inbox:new` 个人事件，把每条收件箱通知推送到你自建的 Telegram bot 私聊。
仅用 Python 3 标准库，无第三方依赖。

## 消息排版（SEE-1567）

通知以可读元信息开头，正文按 Telegram HTML 渲染：

- **首部元信息**：`🤖 Agent 显示名 · SEE-XXX issue 标题`，随后一条分隔线。
  Agent 显示名优先用事件自带的可读字段；是 UUID 时通过 Multica 只读 REST
  查询（`GET /api/agents/<id>?workspace_id=…`，Bearer PAT 鉴权）补全，带
  TTL 缓存（命中 6 小时 / 失败 60 秒负缓存）与超时上限。查询失败时降级为
  类型标签（Agent / Member / Unknown），**永远不会出现裸 UUID**，也绝不会
  阻断通知投递。issue 标识符优先从事件标题前缀提取；缺失时查询
  `GET /api/issues/<id>` 补全。
- **Markdown 渲染**：常用 Markdown 以 `parse_mode=HTML` 渲染为 Telegram 支持
  的标签子集（粗体/斜体/删除线/行内代码/围栏代码/引用/链接/列表）；
  `& < >` 一律转义，危险链接协议（如 `javascript:`）去掉锚点只保留文字。
- **表格**：GFM 管道表格转为移动端友好的键值列表/逐行卡片——两列表格一行
  一条，三列及以上逐行成卡片，单元格行内格式保留；空单元格显示 `—`，
  列数不齐自动补齐/合并，超过 6 列的宽表以一行摘要代替，代码块内的
  伪表格保持原样。分隔行 `|---|` 不会出现在任何输出里。
- **降级**：仅当 Telegram 明确返回 400「can't parse entities」时，才以无
  `parse_mode` 的纯文本重发一次；其余 400、stale chat、通道/可重试错误
  分类与 SEE-1561 完全一致，同一通知不会重复成功投递。
- **长度**：按 Telegram 4096 UTF-16 单位上限先收缩源文本再渲染，永不切断
  HTML 标签或实体，孤立代理字符一律清除；超长正文保留开头部分。
- **取证**：`delivered` 日志事件记录实际出站 payload（`outbound_text`/
  `parse_mode`/`text_units`），实机 probe 可直接从 JSONL 日志核验可读首部、
  表格卡片与「无裸 UUID」；日志永不记录 PAT、bot token 或 chat ID 数值。

## 工作原理

1. 连接 `ws(s)://<server>/ws?workspace_id=<id>`（Multica v0.8.1 realtime 端点）。
2. 首帧发送 `{"type":"auth","payload":{"token":"<PAT>"}}` 完成鉴权，等待服务端
   `{"type":"auth_ack"}`；失败会收到 `{"error":...}` 且连接被服务端关闭。
3. 订阅免费：`inbox:new` 是个人事件，服务端只推给 token 对应的用户本人。
4. 适配器按 `payload.item.workspace_id` 过滤目标 workspace，去重后把通知文本
   （按 Telegram 的 UTF-16 计长口径截断到 4096 以内）通过 Telegram Bot API
   `sendMessage` 发给配置里指定的 chat ID——这是唯一投递目标，适配器不扫描
   bot 的其他私聊，其他私聊的会话也永远不会收到 Inbox 内容。失效的 chat ID
   （Telegram 返回「chat not found」）会复核配置 id 并重试一次；被 Telegram
   永久拒绝的通知会记入已处理状态并告警，不会在重连后无限重发。通道级故障
   （bot token 失效、bot 被拉黑、chat 尚未建立等）则保留待投递语义：通知
   不丢失，通道恢复（如重新 `/start`、换 token）后自动补投。
5. 断线自动重连（指数退避），malformed 帧忽略，已投递通知持久化在本地状态文件，
   重启/重连不会重复发送。

## 准备凭据（Owner 操作）

1. **创建 Telegram bot**：在 Telegram 中找 **@BotFather**，发送 `/newbot`，按提示
   命名后会得到一个 bot token（形如「数字:字母数字串」）。打开你新建的 bot 私聊，
   发送 `/start`，然后查询一次 `getUpdates` 取得你自己的数字 chat ID（任何
   Telegram API 客户端都可调用一次 `getUpdates`，或由已配置过的人提供）。
   适配器**只向配置里的这个 chat ID 发送**：它不扫描 bot 的其他私聊，因此
   其他人与该 bot 的会话不会收到任何 Inbox 内容。
2. **创建 Multica Personal Access Token**：在 Multica 设置里为你的账号创建 PAT
   （`mul_` 前缀）。注意：任务运行时的 `mat_` token 不能用于用户 WebSocket。
3. **写入本地配置文件**（不要把任何 token 发到 issue、评论或聊天里）：

```bash
mkdir -p ~/.config/dev-forge
cat > ~/.config/dev-forge/see-1561.env <<'EOF'
NOTIFIER_MULTICA_PAT=<你的 mul_ PAT>
NOTIFIER_TELEGRAM_BOT_TOKEN=<BotFather 下发的 token>
NOTIFIER_TELEGRAM_CHAT_ID=<你的数字 chat ID>
NOTIFIER_MULTICA_SERVER_URL=<你的 Multica 部署地址，如 http://192.168.x.x:9278>
NOTIFIER_WORKSPACE_ID=<workspace UUID>
EOF
chmod 600 ~/.config/dev-forge/see-1561.env
```

也可直接复制本目录的 `config.example.env` 作为模板。配置项说明见下。

## 启动与停止

```bash
# 常驻运行（Ctrl+C 或 kill 停止）
python3 adapters/multica_telegram_notifier/notifier.py \
  --config ~/.config/dev-forge/see-1561.env

# 单次 live probe：命中第一条真实通知后退出，exit 0（§SPEC-005 判据命令）
# 运行产物（日志/状态）一律放仓库外路径，不要落在 git 工作树里
python3 adapters/multica_telegram_notifier/notifier.py \
  --config ~/.config/dev-forge/see-1561.env \
  --once --log-json ~/.local/state/dev-forge/see-1561-live-probe/probe.jsonl
```

- `--once`：投递第一条通知后以 exit 0 退出；配置缺失或无效（含 chat ID
  非正整数、超时/退避含 `nan`/`inf`）exit 2；PAT 被永久拒绝时在一个退避
  周期后以 exit 4 确定性退出；投递阶段通道持续不可用（连续失败不被健康
  会话打断）在一个退避周期后以 exit 5 确定性退出；持续的可重试发送失败
  同样在一个退避周期后以 exit 6 确定性退出——通道/可重试两类失败交替
  出现时按「Telegram 失败总数」计界，同样以 exit 6 收束。两种失败都不会
  把通知标记为已处理，恢复后自动补投（live probe 不会无限重试）。
- `--log-json <path>`：结构化 JSONL 日志追加写入该文件（stderr 同步输出；
  路径支持 `~` 展开）。日志中凭据字段一律被替换为 `[REDACTED]`，可安全
  留存作证据。
- 通知触发源：任何会让你收到 Inbox 通知的真实动作（例如某个 agent 的正常汇报
  评论 @ 你）。不需要、也不应该为验证创建实验 issue。

## 配置项

| 环境变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `NOTIFIER_MULTICA_PAT` | 是 | — | Multica PAT（`mul_` 前缀） |
| `NOTIFIER_TELEGRAM_BOT_TOKEN` | 是 | — | BotFather 下发的 bot token |
| `NOTIFIER_TELEGRAM_CHAT_ID` | 是 | — | Owner 的数字 chat ID（正整数，唯一投递目标） |
| `NOTIFIER_MULTICA_SERVER_URL` | 是 | — | Multica 部署根地址（http/https） |
| `NOTIFIER_WORKSPACE_ID` | 是 | — | 只转发该 workspace 的 `inbox:new` |
| `NOTIFIER_TELEGRAM_API_BASE` | 否 | `https://api.telegram.org` | 测试可指向本地伪 API |
| `NOTIFIER_STATE_FILE` | 否 | `~/.local/state/dev-forge/multica-telegram-notifier/state.json` | 去重状态文件（支持 `~` 展开） |
| `NOTIFIER_RECONNECT_BACKOFF` | 否 | `1,2,4,8,15,30` | 断线重连退避秒数序列 |
| `NOTIFIER_SEND_RETRIES` | 否 | `1,2,4` | sendMessage 失败重试间隔秒数 |
| `NOTIFIER_CONNECT_TIMEOUT` | 否 | `10` | 连接/HTTP 超时秒数 |
| `NOTIFIER_READ_TIMEOUT` | 否 | `90` | 单帧读取超时秒数（须大于服务端 ~54s ping 周期；超时视为半开连接并重建会话） |
| `NOTIFIER_API_BASE` | 否 | 同 `NOTIFIER_MULTICA_SERVER_URL` | 元信息只读查询（Agent 显示名/issue 标识符）根地址 |
| `NOTIFIER_QUERY_TIMEOUT` | 否 | `5` | 单次元信息查询超时秒数；失败自动降级，不阻断投递 |

配置文件里已有的值优先于同名进程环境变量；进程环境变量再作为缺省回退。

## 密钥保护

- PAT 与 bot token 只放在权限 600 的本地配置文件中，不进仓库、不进日志、不进
  issue/评论；状态文件只存已投递通知 ID；日志事件一律不记录 chat ID 数值。
  元信息查询的 PAT 同样只出现在 Authorization 头里，错误消息刻意不含
  URL/token。
- 运行产物（`--log-json` 日志、状态文件）都应放在仓库外（默认
  `~/.local/state/dev-forge/...`）；仓库 `.gitignore` 另有 `live-probe*.jsonl`
  兜底，避免探针产物被误提交。
- 日志与异常文本经全局 redaction；Telegram 客户端构造错误消息时刻意不带含
  token 的 URL。
- 泄漏应急：在 BotFather `/revoke` 换 token；在 Multica 设置里删除并重建 PAT。

## 运维边界

- 元信息查询是只读 GET（`/api/agents/<id>`、`/api/issues/<id>`），带超时与
  双向 TTL 缓存；Multica 服务暂时不可用只会让消息首部降级为类型标签，
  投递照常进行。
- 本仓库的开发/测试不停止、不重启已部署的 `multica-telegram-notifier.service`；
  合并后的稳定目录更新与服务重启由 Owner 另行受控 rollout。

## 测试

```bash
python3 -m pytest tests/adapters/multica_telegram_notifier -q
```

覆盖协议解析（auth/auth_ack/inbox:new）、Markdown→HTML 渲染与转义、表格卡片
转换、元信息解析器（命中/缓存/超时/降级/凭据安全）、Telegram 正常与失败路径
（含 parse-entity 纯文本回退）、重连/去重/malformed 容忍，以及伪 Multica WS
+ 伪 Multica REST → 真实适配器 → 伪 Telegram API 的端到端链路（鉴权失败、
发送失败、重试、可读首部与降级）。全套测试仅用本地伪服务器，不触网、
不碰真实凭据。

## 与既有 autopilot / webhook 的关系

Multica autopilot 的 webhook 是入站触发器（外部系统 → Multica），不承担本通知
链路的任何环节；本适配器为独立进程，不修改 Multica 后端、既有 autopilot 或
systemd 配置。
