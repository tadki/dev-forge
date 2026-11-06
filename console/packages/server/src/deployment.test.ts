import { describe, expect, it } from 'vitest';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';

const unitPath = join(import.meta.dirname, '../../../deploy/forge-console.service');
const readmePath = join(import.meta.dirname, '../../../README.md');

describe('SEE-1522 部署沙箱与服务动作文档', () => {
  it('forge-console 自身继续保持只读沙箱，写仅限对账目标（自建项目根 + 平台资产根）', async () => {
    const unit = await readFile(unitPath, 'utf8');
    expect(unit).toContain('ProtectSystem=strict');
    expect(unit).toContain('ProtectHome=read-only');
    // store-drift push（以库为准）要能写已声明资产的生产路径；实际写入仍受 reconcile file-write 白名单（仅资产路径）约束
    expect(unit).toContain('ReadWritePaths=%h/tools/dev-forge');
    expect(unit).toContain('ReadWritePaths=%h/tools/grepai');
    expect(unit).toContain('ReadWritePaths=%h/tools/godot-qa-toolkit');
    expect(unit).toContain('ReadWritePaths=%h/.claude');
    expect(unit).toContain('ReadWritePaths=%h/multica_workspaces');
    expect(unit).toContain('ReadWritePaths=/mnt/d/GodotProjects');
  });

  it('README 记录自动命名 launcher、停用门控、拒绝响应与可配置启动窗口', async () => {
    const readme = await readFile(readmePath, 'utf8');
    expect(readme).toContain('transient oneshot launcher');
    expect(readme).toContain('不显式指定 `--unit`');
    expect(readme).toContain('systemd 分配独立且唯一');
    expect(readme).toContain('KillMode=process');
    expect(readme).toContain('enabled=false');
    expect(readme).toContain('disabled 时仅 API/服务端 stop 可用');
    expect(readme).toContain('ok:false');
    expect(readme).toContain('FORGE_REPO_SYNC_START_TIMEOUT_MS');
    expect(readme).toContain('FORGE_REPO_SYNC_STOP_TIMEOUT_MS');
  });
});
