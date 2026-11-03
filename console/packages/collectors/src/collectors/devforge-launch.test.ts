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

  afterAll(async () => {
    await rm(root, { recursive: true, force: true });
  });
});
