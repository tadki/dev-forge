import { afterAll, describe, expect, it } from 'vitest';
import { mkdir, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { devforgeLaunchCollector, makeContext, defaultConfig } from '../index.js';

const root = join(tmpdir(), `forge-launch-test-${Date.now()}`);

async function writeRepos(fixture: string): Promise<void> {
  await mkdir(join(root, 'repo-sync', 'repos.d'), { recursive: true });
  await writeFile(join(root, 'repo-sync', 'repos.d', 'devforge.json'), fixture);
}

function ctx() {
  return makeContext(defaultConfig({ devforge: root }));
}

describe('devforge-launch repo-sync 判活', () => {
  it('pid 文件缺失 → dead（守护已退出并自清理）', async () => {
    await writeRepos(JSON.stringify({ name: 'devforge', repo_path: '/x', pid_file: join(root, 'gone.pid') }));
    const r = await devforgeLaunchCollector.collect(ctx());
    const a = r.assets.find((x) => x.id === 'service:repo-sync-devforge');
    expect((a!.payload as { active: string }).active).toBe('dead');
  });

  it('pid 存活 → active', async () => {
    const pidFile = join(root, 'live.pid');
    await writeFile(pidFile, String(process.pid));
    await writeRepos(JSON.stringify({ name: 'devforge', repo_path: '/x', pid_file: pidFile }));
    const r = await devforgeLaunchCollector.collect(ctx());
    const a = r.assets.find((x) => x.id === 'service:repo-sync-devforge');
    expect((a!.payload as { active: string }).active).toBe('active');
  });

  it('无 pid_file 字段 → unknown', async () => {
    await writeRepos(JSON.stringify({ name: 'devforge', repo_path: '/x' }));
    const r = await devforgeLaunchCollector.collect(ctx());
    const a = r.assets.find((x) => x.id === 'service:repo-sync-devforge');
    expect((a!.payload as { active: string }).active).toBe('unknown');
  });

  it('enabled=false 且 pid 缺失 → disabled（不因缺 pid 报 dead）', async () => {
    await writeRepos(JSON.stringify({ name: 'devforge', repo_path: '/x', enabled: false, pid_file: join(root, 'disabled-gone.pid') }));
    const r = await devforgeLaunchCollector.collect(ctx());
    const payload = r.assets.find((x) => x.id === 'service:repo-sync-devforge')!.payload as { active: string; trigger: string };
    expect(payload.active).toBe('disabled');
    expect(payload.trigger).toBe('已手动停用（enabled=false）');
  });

  it('enabled=false 且 pid 存活 → disabled（进程残留也不改停用语义）', async () => {
    const pidFile = join(root, 'disabled-live.pid');
    await writeFile(pidFile, String(process.pid));
    await writeRepos(JSON.stringify({ name: 'devforge', repo_path: '/x', enabled: false, pid_file: pidFile }));
    const r = await devforgeLaunchCollector.collect(ctx());
    const payload = r.assets.find((x) => x.id === 'service:repo-sync-devforge')!.payload as { active: string; trigger: string };
    expect(payload.active).toBe('disabled');
    expect(payload.trigger).toBe('已手动停用（enabled=false）');
  });

  it('显式 enabled=true 且 pid 缺失 → 保持 dead', async () => {
    await writeRepos(JSON.stringify({ name: 'devforge', repo_path: '/x', enabled: true, pid_file: join(root, 'enabled-gone.pid') }));
    const r = await devforgeLaunchCollector.collect(ctx());
    expect((r.assets.find((x) => x.id === 'service:repo-sync-devforge')!.payload as { active: string }).active).toBe('dead');
  });

  it('字符串 enabled="false" 不冒充布尔停用，保持 dead', async () => {
    await writeRepos(JSON.stringify({ name: 'devforge', repo_path: '/x', enabled: 'false', pid_file: join(root, 'string-enabled-gone.pid') }));
    const r = await devforgeLaunchCollector.collect(ctx());
    expect((r.assets.find((x) => x.id === 'service:repo-sync-devforge')!.payload as { active: string }).active).toBe('dead');
  });

  it('数字 enabled=0 / null 等假值不冒充布尔停用，保持 dead 与自动启动文案', async () => {
    await writeRepos(JSON.stringify({ name: 'devforge', repo_path: '/x', enabled: 0, pid_file: join(root, 'zero-enabled-gone.pid') }));
    const r0 = await devforgeLaunchCollector.collect(ctx());
    const p0 = r0.assets.find((x) => x.id === 'service:repo-sync-devforge')!.payload as { active: string; trigger: string };
    expect(p0.active).toBe('dead');
    expect(p0.trigger).toBe('随 toolchain-start-all 启动');

    await writeRepos(JSON.stringify({ name: 'devforge', repo_path: '/x', enabled: null, pid_file: join(root, 'null-enabled-gone.pid') }));
    const rNull = await devforgeLaunchCollector.collect(ctx());
    expect((rNull.assets.find((x) => x.id === 'service:repo-sync-devforge')!.payload as { active: string }).active).toBe('dead');
  });

  afterAll(async () => {
    await rm(root, { recursive: true, force: true });
  });
});
