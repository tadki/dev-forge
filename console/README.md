# forge-console

dev-forge harness 的只读监控台：采集器（12 个内置）→ 标准资产模型（`forge-asset/1`）→ builtin-http API（token + SSE）→ React Web UI（KOL Neo-Brutalism 设计系统 · 方案 E 紫调夜幕）。

设计规格：[`../docs/harness-console-plan.md`](../docs/harness-console-plan.md)（四层架构 / 作用域 lattice / 迁移投影）。

## 快速开始

```bash
cd console
npx pnpm@9 install
npx pnpm@9 build            # 三个包 + web
npx pnpm@9 test             # 单元 + API（vitest）
cd e2e && npx playwright install chromium && npx playwright test   # E2E（fixture 确定性数据）
```

本地运行（无 token，绑 127.0.0.1）：

```bash
node packages/server/dist/index.js   # 默认 http://127.0.0.1:7310
```

## 部署（systemd 常驻 + LAN）

```bash
# 一次性：token 写入 env 文件（0600，不进 git）
mkdir -p ~/.config/forge-console
printf 'FORGE_CONSOLE_TOKEN=%s\nFORGE_CONSOLE_PORT=7310\nFORGE_CONSOLE_BIND=0.0.0.0\n' "$(openssl rand -hex 24)" > ~/.config/forge-console/env
chmod 600 ~/.config/forge-console/env

cp deploy/forge-console.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now forge-console
```

LAN 访问（Mac/手机）：Windows 侧 portproxy + 防火墙放行（已配置过的等价命令）：

```
netsh interface portproxy add v4tov4 listenport=7310 listenaddress=0.0.0.0 connectport=7310 connectaddress=127.0.0.1
netsh advfirewall firewall add rule name="forge-console-7310" dir=in action=allow protocol=TCP localport=7310
```

然后从局域网访问 `http://192.168.1.105:7310`，首屏输入 token（存 localStorage）。

> 注意：portproxy/防火墙规则持久于注册表，WSL 重启不影响；但 WSL 服务本身由 systemd user 单元拉起。

## 开发模式（HMR 实时热更，5173）

前端改动即时生效，无需 `pnpm build`（7310 始终展示最近一次构建产物，5173 始终展示当前源码）：

```bash
cp deploy/forge-console-dev.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now forge-console-dev
```

vite dev server 监听 `0.0.0.0:5173`，`/api`、`/healthz` 代理至本机 7310（后端 `forge-console.service` 需在跑，单元已声明 Wants 依赖）。Windows 浏览器直接开 `http://localhost:5173`；Mac/手机 需在 Windows 管理员 PowerShell 加 portproxy（同 7310 套路）：

```
netsh interface portproxy add v4tov4 listenport=5173 listenaddress=0.0.0.0 connectport=5173 connectaddress=<WSL_IP>
netsh advfirewall firewall add rule name="forge-console-dev-5173" dir=in action=allow protocol=TCP localport=5173
```

> 实际部署的 portproxy（2222/8890/7310/5173）都指向 WSL eth0 IP（当前 `172.17.196.205`，`hostname -I` 可查）；WSL 重启后 IP 若变，这些规则需同步更新。

token 按 origin 存 localStorage：`localhost:5173` 与 `192.168.1.105:5173` 各输一次。不用时 `systemctl --user stop forge-console-dev`。

## 结构

| 路径 | 职责 |
|---|---|
| `packages/schema` | forge-asset/1 契约：zod schema + JSON Schema（`asset.schema.json`）+ 类型 |
| `packages/collectors` | 12 个内置采集器 + registry（合并/漂移分组/快照）+ effective harness 解析 + 迁移投影 |
| `packages/server` | 零框架 HTTP：token 鉴权（除 `/healthz` 与静态资源）、SSE、静态托管、chokidar watch（/mnt 9p 走 polling） |
| `apps/web` | Vite + React UI：11+1 页，设计 tokens 见 `src/styles/tokens.css` |
| `e2e` | Playwright：fixture 采集器 + 16 条用例（真后端真浏览器） |
| `console.config.yaml` | workspace 注册表（可提交；当前单 workspace `jerry`，kol/godot-mcp/gqt/grepai/dev-forge 均为项目）+ multica/hindsight 配置 |
| `collectors.d/` | 外部采集器投放目录（可执行，stdout 吐契约 JSON；见下） |

## 自建资产注册（registry.d）与通用 metadata

每个资产除基础信封（kind/attach/provenance/owner/tags/source 溯源）外，还有一套**通用 meta 词汇表**：
`owner` / `category` / `lifecycle(stable|experimental|deprecated)` / `criticality(high|medium|low)` / `runtime(claude-code|multica|both|standalone)` / `docs` / `since` / `notes`。

**声明即归属**：`console/registry.d/*.yaml` 里按 `match: {idPrefix|pathPrefix}` 声明我们的资产并写 meta；引擎采集后统一盖戳（覆盖采集器对 provenance 的推断）。声明没命中 → 「未匹配声明」；自建但没声明 → 「未登记」。注册表页的「注册管理」区做覆盖核对，服务页等处在 name 上给自建资产标 ◆ 自建（外部 ◇ EXT）。

```yaml
entries:
  - id: my-domain
    match: { pathPrefix: "/home/jerry/tools/my-thing" }
    meta: { owner: jerry, category: infra, lifecycle: stable, criticality: high, runtime: both }
```

## 服务启停（写操作，仅限自建）

`POST /api/services/actions` `{unit, action: start|stop|restart}` 支持两类资产：

- **systemd**：仅接受注册表内 first-party 且 user 级单元；外部/第三方与 system 级一律 403（system 级需 root）。
- **repo-sync 进程服务**：按 `repo-sync/repos.d/<name>.json` 实值执行。严格 `enabled === false` 时 start/restart 返回 `ok:false`（输出含 `enabled=false`，且不执行任何进程命令），UI 显示中性停用态并隐藏启动/重启；disabled 时仅 API/服务端 stop 可用于清理残留（UI 不提供 start/stop/restart，调用 `POST /api/services/actions`）。注册必须声明非空 `pid_file`，否则所有动作零 exec 拒绝。停止前核对 `/proc/<pid>/cmdline` 的 daemon 与 config；stale pid 按未运行恢复，活 PID 身份不匹配拒杀。

repo-sync 启动不由 `forge-console` 沙箱内的进程直接写宿主。console 自身保持 `ProtectSystem=strict` / `ProtectHome=read-only` / `ReadWritePaths=`，只通过 `systemd-run --user` 创建**自动命名的 transient oneshot launcher**（不显式指定 `--unit`，由 systemd 分配独立且唯一的 transient unit 名称，具体名称格式由 systemd 决定）越过沙箱；launcher 以 `KillMode=process` + `--collect` 运行并退出，真正 daemon 始终由 `nohup python3 … --config …` 启动，stdout/stderr 追加到注册 `log_dir/repo-sync-daemon.log`，pid/state 由 daemon 按注册文件写入。它**不是**按仓命名的 transient daemon unit，也不会被首个 daemon 钉住共享名；pid_file 自锁与 SIGTERM 才是 daemon 生命周期契约。

动作结果以 HTTP 200 + `{ok, output}` 返回；业务拒绝（如停用门、身份不匹配）为 `ok:false`，前端直接展示 output。鉴权、注册表和参数校验错误仍用相应非 2xx。UI 在「服务」页给可控行加 ■停止/▶启动/↻ 按钮（停 forge-console 自身有二次警告）。`FORGE_CONSOLE_DRY_ACTIONS=1` 时只回显命令不执行（E2E 用）。「注册表」页给 kind×自建/外部的统计表与自建资产全量清单，外部服务在服务页标 ◇ EXT。

## 平台对账（声明 × 实际 + 双向同步）

注册表页「平台对账」区把 `registry.d` 声明与采集器看到的平台实际状态对账，差异逐条 warning 并可选择方向同步（**写操作逐次确认**）。

**声明**：`registry.d/*.yaml` entry 增加 `platforms: [claude-code, multica]`（不写 = 不参与归属对账），盖戳到资产 `payload.registry.declaredPlatforms`；资产的 `platforms` 保持采集实际值。

**差异类型**：
- `missing-on-platform`：声明已应用平台 P 但采集未发现 P 上实例（声明未匹配到资产时也触发）。
- `undeclared-platform`：资产实际出现在 P 但声明未包含 P。
- `content-drift`：multica agent instructions ↔ 最新物化 workdir CLAUDE.md 分叉（与迁移页同源）；同 entry 内同名副本 sha 分叉；已声明本地技能 ↔ multica 同名技能（名称归一化配对，如 taskassign ↔ task-assign）内容分叉。
- `uncovered-assets`：有平台归属但未被任何 `platforms` 声明覆盖的自建资产，按 kind×平台分组提示补声明（`custom`/`report` 是采集器派生的观测视图，不参与）。

**动作**（按差异类型给出，方向由用户裁决）：
- 平台 → 本地：`采纳现状`（把实际平台回写进声明）/ `撤销声明`（从声明移除未落地的平台）/ `以 agent instructions 回写 workdir 物化文件`（保留 MULTICA-RUNTIME 前缀）。
- 本地 → 平台：`以物化内容更新 agent instructions`（`multica agent update <platformId> --instructions`）/ 无安全自动路径时仅给出建议命令（如应用到平台、从平台下线）。

**写安全**：
- 客户端只提交 `{key, actionId, confirm:true}`，步骤完全由服务端按当前 state 重算生成——路径、命令、内容均不可由客户端注入；对账项已变化时返回 409 强制刷新。
- 文件写只允许当前采集到的资产路径（白名单），覆盖前自动备份 `*.forge-bak-<ts>`；registry 改写经 YAML Document 保留注释。
- `FORGE_CONSOLE_DRY_ACTIONS=1` 时只回显计划不落盘（E2E 用）；沙箱 `ReadWritePaths` 只放行 registry.d、~/.claude、~/multica_workspaces 与项目根（见 deploy/forge-console.service）。

**API**：`GET /api/reconcile`（报告与每条的 actions/steps 预览）；`POST /api/reconcile/actions` `{key, actionId, confirm:true}` → `{ok, output}`（缺 confirm 400、动作不可执行 400、项已变化 409、执行失败 200 + `ok:false`）。每次 collect 后报告入 `state.reconcile`，warn 诊断（前缀 `[reconcile]`）进 Overview 诊断尾部，`/api/overview` 附 `reconcile` 计数。

## 扩展接入（新增一个监控域）

1. **内置**：`packages/collectors/src/collectors/<domain>.ts` 实现 `Collector` 接口，注册进 `builtinCollectors`。
2. **外部脚本**：丢可执行到 `console/collectors.d/`（任意语言），stdout 输出 `forge-asset/1` Collection JSON（契约见 `packages/schema/asset.schema.json`）。
3. **REST 推送**（兜底）：`POST /api/custom/assets`（Bearer token），body 为同一契约。
4. **声明式**：项目根放 `.forge.yaml` 登记额外资产（M2）。

未知 kind 自动落「通用资产」页的 JSON 视图，永不白屏。

## 环境变量（服务）

| 变量 | 默认 | 说明 |
|---|---|---|
| `FORGE_CONSOLE_TOKEN` | （空） | 为空 = 本机模式全放行；生产必设 |
| `FORGE_CONSOLE_PORT` | `7310` | |
| `FORGE_CONSOLE_BIND` | `0.0.0.0` | 本机模式建议 `127.0.0.1` |
| `FORGE_CONSOLE_CONFIG` | `console.config.yaml` | 配置路径 |
| `FORGE_CONSOLE_WATCH` | `on` | `off` 关闭文件监听（测试用） |
| `FORGE_REPO_SYNC_START_TIMEOUT_MS` | `10000` | repo-sync 启动后等待匹配 pid/daemon 的窗口；超时文案由此值推导 |
| `FORGE_REPO_SYNC_STOP_TIMEOUT_MS` | `5000` | restart 等待旧 daemon 退出的窗口；超时则不重新拉起 |
