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

## 结构

| 路径 | 职责 |
|---|---|
| `packages/schema` | forge-asset/1 契约：zod schema + JSON Schema（`asset.schema.json`）+ 类型 |
| `packages/collectors` | 12 个内置采集器 + registry（合并/漂移分组/快照）+ effective harness 解析 + 迁移投影 |
| `packages/server` | 零框架 HTTP：token 鉴权（除 `/healthz` 与静态资源）、SSE、静态托管、chokidar watch（/mnt 9p 走 polling） |
| `apps/web` | Vite + React UI：11+1 页，设计 tokens 见 `src/styles/tokens.css` |
| `e2e` | Playwright：fixture 采集器 + 16 条用例（真后端真浏览器） |
| `console.config.yaml` | workspace 注册表（可提交）+ 扫描根 + multica/hindsight 配置 |
| `collectors.d/` | 外部采集器投放目录（可执行，stdout 吐契约 JSON；见下） |

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
