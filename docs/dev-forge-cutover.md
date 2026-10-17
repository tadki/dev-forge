# dev-forge cutover runbook（SEE-1429 Phase 3 由 Atlas 主持执行）

> 顺序铁律（沿用 SEE-1330 裁定）：真源就位 → 注册切换 → 验证 → 清运行位 → 删 KOL 旧物。每步失败即回退。

## P0 预检

1. dev-forge 已建仓并检出 `~/tools/dev-forge/`（main）；本 Phase 2 迁移已合入。
2. 备份：`cp -a ~/.claude/hooks ~/.claude/hooks-backups/pre-cutover-<ts>/`；`cp ~/.claude/settings.json ~/.claude/settings.json.bak-manual-<ts>`；记录 firelog 水位 `wc -l ~/.claude/hook-fire.log`。
3. `~/.claude/hooks/backup-see*` 历史快照移档 `docs/archive/`（backup-see1333 已随 Phase 2 移入）。
4. 判据：`bash bootstrap/doctor.sh` 全 PASS。

## P1 注册链切换

1. `bash bootstrap/bootstrap.sh`（备份 settings → 渲染 9 时点注册行 → 幂等校验）。
2. 判据 1：settings diff 仅 9 行注册路径，全部指向 `~/tools/dev-forge/hooks/hook-wrapper.sh`。

## P2 触发验证

- push-guard firelog 行 + `rules=21` 数一致；SessionStart repo-checkout 链；deny 语义（mention-check/child-issue-guard 命中）；one_shot state 写入（`hooks/unified/state/` 新位成功、无 WARN 劣化）。
- 判据 2：firelog 新行 `script=` 字段为 dev-forge 路径。

## P3 清运行位

1. `rm -rf ~/.claude/hooks`（backup 快照已移档）。
2. 判据 3：目录不存在；再触发一轮 hooks 确认 firelog 走 dev-forge。

## P4 KOL 清理与引用修复

1. KOL 侧 `git rm` 迁出目录（`.claude/hooks/`、`.dev/hooks/`、`.dev/docs/claude/`、`.dev/autopilots/`、`.dev/launch/`、`.dev/systemd/`、`.dev/tests/hooks/`），commit 走 KOL 共享分支（可 revert = 回退面）。
2. 全仓 grep `dev/hooks|dev/autopilots|dev/launch|dev/systemd|docs/claude|KOL_REPO_ROOT|kingoflikes-start` 逐条修复。
3. systemd：`systemctl --user daemon-reload && systemctl --user reenable toolchain-start-all`（原 kingoflikes-start-all.service 已改名）。

## 回退设计

- 软回退：`bash bootstrap/rollback.sh`（恢复 settings 旧注册段）。
- 硬回退：KOL 侧 `git revert` 清理 commit + 从 `~/.claude/hooks-backups/pre-cutover-*` 恢复目录。双面独立。
- 备份保留期：稳定 2 周后清理。
