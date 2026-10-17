<div align="center">

# dev-forge

**Decoupled dev toolchain: Claude hooks engine, autopilots, launch sentinels, bootstrap/doctor.**

与 Multica / KOL（KingOfLikes）/ Claude Code 三方解耦的自研开发工具链仓库。
全局 hooks 注册链直指本仓检出的绝对路径——本地改文件即生效，
**单一真源 = 本地 editable 检出**，不再随任何项目每次检出。

![ci](https://github.com/tadki/dev-forge/actions/workflows/ci.yml/badge.svg)

</div>

---

## Why dev-forge

此前全套工具链（hooks 统一引擎、autopilots、启动哨兵）寄宿在 KingOfLikes 仓库的
`.claude/hooks/` 与 `.dev/` 下，存在三重耦合：hooks 配置随 KOL 每次 checkout 漂移
（双轨真源）、工具链只能在 KOL 会话内生效、KOL 仓库承载了与自己无关的开发流程代码。

dev-forge 的最终态（SEE-1429 定案）：

- **注册链直指**：`~/.claude/settings.json` 的 9 时点注册行渲染为
  `~/tools/dev-forge/claude-hooks/hook-wrapper.sh <Event> unified-hook` 绝对路径，
  CC 运行时直接读本仓检出内代码——无部署复制、无 symlink。
- **零耦合**：本仓内不含任何 KOL/Multica 检出路径字面量；目标仓库路径一律经
  环境注入（`TARGET_REPO_ROOT`）；`adapters/` 内单系统绑定工具单独收口。
- **仓库级语义在 when 内表达**：引擎级总是加载全部规则，"这个仓库才触发"由规则
  when 条件（路径 / env / agents 维度）+ dispatcher 的 PROJECT_ROOT/REPO_ROOT
  探测实现——不靠每仓装引擎。

## Directory map

| 目录 | 语义 |
|---|---|
| `claude-hooks/` | hooks 运行链真源：`hook-wrapper.sh` → `dispatcher.sh` → `unified/`（engine.js + when-ops.js + rules-v2.json + rules.d/ + state/）→ `scripts/`（业务钩子 ×11 + lib/） |
| `bootstrap/` | 一次性首装体系：`bootstrap.sh`（渲染 settings 注册行，幂等）、`doctor.sh`（可重复健康检查）、`rollback.sh`（恢复注册段）、`registry-patch.js` + `hooks-registration.json`（声明式注册清单） |
| `adapters/` | **绑定单一外部系统的适配/运维工具，不做通用化改造**（Multica 升级 / Hindsight MCP launcher / workspace 环境检查） |
| `autopilots/` | Multica 巡逻框架（×7 + helpers）；扫描目标配置化于 `configs/kol.json`（数据非代码，换目标 = 换 config） |
| `launch/` | `toolchain-start.sh` 启动哨兵（目标仓路径经 EnvironmentFile 注入，零硬编码）+ `systemd/toolchain-start-all.service` |
| `docs/` | hooks 三件套（guide / usage-rules / v2-migration-map）、迁移计划、cutover runbook；`docs/archive/` 收历史部署备份快照 |
| `tests/` | shell 判据套件 + validator（`bash tests/run_all.sh`） |

## Quick start

```bash
# 0. 规范检出（唯一真源）
gh repo clone tadki/dev-forge ~/tools/dev-forge

# 1. 一次性首装：备份现 settings hooks 段 → 渲染 9 时点注册行 → 幂等校验
bash bootstrap/bootstrap.sh

# 1b. （systemd 场景）写 toolchain env（TARGET_REPO_ROOT = 工具链宿主仓库）
bash bootstrap/bootstrap.sh --write-toolchain-env --target-repo-root /path/to/repo

# 2. 健康检查（可重复执行）
bash bootstrap/doctor.sh

# 3. 回退（恢复注册段备份）
bash bootstrap/rollback.sh
```

Cutover / 回退 / 逐项验证清单：[`docs/dev-forge-cutover.md`](docs/dev-forge-cutover.md)
（顺序铁律：真源就位 → 注册切换 → 验证 → 清运行位 → 删旧物；双回退面独立）。

## Engine architecture

```
~/.claude/settings.json   ── 9 hook points (matcher *, command = 绝对路径)
        │  bash
        ▼
claude-hooks/hook-wrapper.sh      firelog 审计 + 转发
        │  exec (脚本自定位)
        ▼
claude-hooks/dispatcher.sh        PROJECT_ROOT / TARGET_REPO_ROOT 探测 + alias 路由
        │                          （未知 alias 静默透传，fail-open）
        ▼
claude-hooks/unified/unified-hook.sh
        │  node
        ▼
claude-hooks/unified/engine.js    ── rules-v2.json + rules.d/*.json（when 树求值）
        │                          ── run_script 挂载 scripts/*.sh（exit2 → deny 通道保真）
        ▼
hookSpecificOutput (deny / context / modify) → Claude Code
```

- **fail-open 硬约束**：node 缺失 / 引擎崩溃 / 配置损坏 → 透传原 stdin + exit 0 +
  firelog 审计行——引擎故障绝不阻塞工具调用。
- **one_shot 窗口**：`unified/state/`（gitignored）承载哨兵，multi-agent 场景按
  issue/run 双维度分型。

## Tests

```bash
bash tests/run_all.sh          # 聚合 runner（目录发现，排除清单带归因标签）
bash tests/test_v2_unified_engine_p0.sh   # 引擎核心套件
node --test tests/validator.test.mjs      # 规则校验器
```

## License

MIT — 与 godot-qa-toolkit 保持一致。

## Contributing

- 唯一检出 `~/tools/dev-forge/`（main 常驻）；改动走共享分支 + PR，merge 策略
  遵循仓库约定（禁 squash）。
- hooks 规则分为两个 lane：`rules-v2.json`（引擎级）与 `rules.d/runscript-mounts.json`
  （挂载级），两文件互不交叉编辑（见 docs/hooks-implementation-guide.md）。
- `adapters/` 内工具例外：单系统绑定，不做通用化改造。
