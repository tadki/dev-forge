# dev-forge

与 Multica / KOL / Claude 三方解耦的开发工具链仓库：Claude hooks 统一引擎、autopilots 巡逻框架、launch 哨兵、bootstrap/doctor/rollback。

## 布局

- `hooks/` — hooks 运行链真源（hook-wrapper.sh → dispatcher.sh → unified/ 引擎 + rules + scripts/ 业务钩子）
- `bootstrap/` — 一次性首装（bootstrap.sh 渲染 settings 注册行）、doctor.sh 校验、rollback.sh 回退、registry-patch.js + hooks-registration.json 声明式注册清单
- `autopilots/` — Multica 巡逻框架（目标经 TARGET_REPO_ROOT 配置注入）
- `adapters/` — 绑定单一外部系统的适配/运维工具（Multica 升级、Hindsight、workspace 环境检查），不做通用化改造
- `launch/` — toolchain-start.sh 启动哨兵 + repo-sync 守护 + systemd 单元
- `docs/` — hooks 三件套 + cutover runbook；`docs/archive/` 收历史部署备份快照
- `tests/` — shell 判据套件（`bash tests/run_all.sh`）

## 约定

- 唯一检出 `~/tools/dev-forge/`（main 常驻）；全局 settings 注册链直指检出内绝对路径，本地改文件即生效（editable 单一真源）
- 共享分支 + PR；merge 策略遵循仓库约定（禁 squash）
