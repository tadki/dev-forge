# Multica → Telegram 通知适配器（SEE-1561）

独立的 Python 适配器：连接 Multica realtime WebSocket，监听目标 workspace 的
`inbox:new` 个人事件，把每条收件箱通知以纯文本推送到你自建的 Telegram bot 私聊。
仅用 Python 3 标准库，无第三方依赖。

## 工作原理

1. 连接 `ws(s)://<server>/ws?workspace_id=<id>`（Multica v0.8.1 realtime 端点）。
2. 首帧发送 `{"type":"auth","payload":{"token":"<PAT>"}}` 完成鉴权，等待服务端
   `{"type":"auth_ack"}`；失败会收到 `{"error":...}` 且连接被服务端关闭。
3. 订阅免费：`inbox:new` 是个人事件，服务端只推给 token 对应的用户本人。
4. 适配器按 `payload.item.workspace_id` 过滤目标 workspace，去重后把通知文本
   （按 Telegram 的 UTF-16 计长口径截断到 4096 以内）通过 Telegram Bot API
   `sendMessage` 发给你的私聊（chat ID 自动发现）。失效的 chat ID（Telegram
   返回「chat not found」）会自动重新发现并重试一次；被 Telegram 永久拒绝的
   通知会记入已处理状态并告警，不会在重连后无限重发。通道级故障（bot token
   失效、bot 被拉黑、chat 尚未建立等）则保留待投递语义：通知不丢失，通道恢复
   （如重新 `/start`、换 token）后自动补投。
5. 断线自动重连（指数退避），malformed 帧忽略，已投递通知持久化在本地状态文件，
   重启/重连不会重复发送。

## 准备凭据（Owner 操作）

1. **创建 Telegram bot**：在 Telegram 中找 **@BotFather**，发送 `/newbot`，按提示
   命名后会得到一个 bot token（形如「数字:字母数字串」）。打开你新建的 bot 私聊，
   发送 `/start`——chat ID 由适配器通过 `getUpdates` 自动发现，无需手查。
2. **创建 Multica Personal Access Token**：在 Multica 设置里为你的账号创建 PAT
   （`mul_` 前缀）。注意：任务运行时的 `mat_` token 不能用于用户 WebSocket。
3. **写入本地配置文件**（不要把任何 token 发到 issue、评论或聊天里）：

```bash
mkdir -p ~/.config/dev-forge
cat > ~/.config/dev-forge/see-1561.env <<'EOF'
NOTIFIER_MULTICA_PAT=<你的 mul_ PAT>
NOTIFIER_TELEGRAM_BOT_TOKEN=<BotFather 下发的 token>
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

- `--once`：投递第一条通知后以 exit 0 退出；chat ID 发现失败或配置缺失
  exit 2（首次启动时 bot token 无效会在发现阶段就失败，同样 exit 2）；
  PAT 被永久拒绝时在一个退避周期后以 exit 4 确定性退出；投递阶段通道
  持续不可用（bot 被拉黑、chat 丢失等，连续失败不被健康会话打断）在一个
  退避周期后以 exit 5 确定性退出（live probe 不会无限重试）。
- `--log-json <path>`：结构化 JSONL 日志追加写入该文件（stderr 同步输出）。
  日志中凭据字段一律被替换为 `[REDACTED]`，可安全留存作证据。
- 通知触发源：任何会让你收到 Inbox 通知的真实动作（例如某个 agent 的正常汇报
  评论 @ 你）。不需要、也不应该为验证创建实验 issue。

## 配置项

| 环境变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `NOTIFIER_MULTICA_PAT` | 是 | — | Multica PAT（`mul_` 前缀） |
| `NOTIFIER_TELEGRAM_BOT_TOKEN` | 是 | — | BotFather 下发的 bot token |
| `NOTIFIER_MULTICA_SERVER_URL` | 是 | — | Multica 部署根地址（http/https） |
| `NOTIFIER_WORKSPACE_ID` | 是 | — | 只转发该 workspace 的 `inbox:new` |
| `NOTIFIER_TELEGRAM_API_BASE` | 否 | `https://api.telegram.org` | 测试可指向本地伪 API |
| `NOTIFIER_STATE_FILE` | 否 | `~/.local/state/dev-forge/multica-telegram-notifier/state.json` | 去重与 chat ID 缓存 |
| `NOTIFIER_RECONNECT_BACKOFF` | 否 | `1,2,4,8,15,30` | 断线重连退避秒数序列 |
| `NOTIFIER_SEND_RETRIES` | 否 | `1,2,4` | sendMessage 失败重试间隔秒数 |
| `NOTIFIER_CONNECT_TIMEOUT` | 否 | `10` | 连接/HTTP 超时秒数 |
| `NOTIFIER_READ_TIMEOUT` | 否 | `90` | 单帧读取超时秒数（须大于服务端 ~54s ping 周期；超时视为半开连接并重建会话） |

配置文件里已有的值优先于同名进程环境变量；进程环境变量再作为缺省回退。

## 密钥保护

- PAT 与 bot token 只放在权限 600 的本地配置文件中，不进仓库、不进日志、不进
  issue/评论；状态文件只存已投递通知 ID 与 chat ID。
- 运行产物（`--log-json` 日志、状态文件）都应放在仓库外（默认
  `~/.local/state/dev-forge/...`）；仓库 `.gitignore` 另有 `live-probe*.jsonl`
  兜底，避免探针产物被误提交。
- 日志与异常文本经全局 redaction；Telegram 客户端构造错误消息时刻意不带含
  token 的 URL。
- 泄漏应急：在 BotFather `/revoke` 换 token；在 Multica 设置里删除并重建 PAT。

## 测试

```bash
python3 -m pytest tests/adapters/multica_telegram_notifier -q
```

覆盖协议解析（auth/auth_ack/inbox:new）、Telegram 正常与失败路径、重连/去重/
malformed 容忍，以及伪 Multica WS → 真实适配器 → 伪 Telegram API 的端到端链路
（鉴权失败、发送失败与重试）。全套测试仅用本地伪服务器，不触网、不碰真实凭据。

## 与既有 autopilot / webhook 的关系

Multica autopilot 的 webhook 是入站触发器（外部系统 → Multica），不承担本通知
链路的任何环节；本适配器为独立进程，不修改 Multica 后端、既有 autopilot 或
systemd 配置。
