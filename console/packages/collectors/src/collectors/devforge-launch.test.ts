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

function ctx(exec?: (cmd: string, args: string[], timeoutMs: number) => Promise<{ ok: boolean; stdout: string; stderr: string }>) {
  return makeContext(defaultConfig({ devforge: root }), exec ? { exec } : undefined);
}

function daemonCmdline(configPath = join(root, 'repo-sync', 'repos.d', 'devforge.json')): string {
  return ['python3', join(root, 'repo_sync_daemon.py'), '--config', configPath, ''].join('\0');
}

function fakeProc(stdout: string, ok = true) {
  return async (cmd: string, args: string[]) => {
    if (cmd === 'cat' && args[0] === `/proc/${process.pid}/cmdline`) return { ok, stdout, stderr: ok ? '' : 'gone' };
    return { ok: false, stdout: '', stderr: 'unexpected exec' };
  };
}

describe('devforge-launch repo-sync 判活', () => {
  it('pid 文件缺失 → dead（守护已退出并自清理）', async () => {
    await writeRepos(JSON.stringify({ name: 'devforge', repo_path: '/x', pid_file: join(root, 'gone.pid') }));
    const r = await devforgeLaunchCollector.collect(ctx());
    const a = r.assets.find((x) => x.id === 'service:repo-sync-devforge');
    expect((a!.payload as { active: string }).active).toBe('dead');
  });

  it('pid 存活且 cmdline 为同一 repo-sync daemon + config → active', async () => {
    const pidFile = join(root, 'live.pid');
    await writeFile(pidFile, String(process.pid));
    await writeRepos(JSON.stringify({ name: 'devforge', repo_path: '/x', pid_file: pidFile }));
    const r = await devforgeLaunchCollector.collect(ctx(fakeProc(daemonCmdline())));
    const a = r.assets.find((x) => x.id === 'service:repo-sync-devforge');
    expect((a!.payload as { active: string }).active).toBe('active');
  });

  it('PID 复用但 cmdline 身份不匹配 → dead，不得显示 active', async () => {
    const pidFile = join(root, 'reused.pid');
    await writeFile(pidFile, String(process.pid));
    await writeRepos(JSON.stringify({ name: 'devforge', repo_path: '/x', pid_file: pidFile }));
    const r = await devforgeLaunchCollector.collect(ctx(fakeProc(['node', '/tmp/other.js', ''].join('\0'))));
    expect((r.assets.find((x) => x.id === 'service:repo-sync-devforge')!.payload as { active: string }).active).toBe('dead');
  });

  it('daemon 相同但 --config 不匹配 → dead', async () => {
    const pidFile = join(root, 'wrong-config.pid');
    await writeFile(pidFile, String(process.pid));
    await writeRepos(JSON.stringify({ name: 'devforge', repo_path: '/x', pid_file: pidFile }));
    const r = await devforgeLaunchCollector.collect(ctx(fakeProc(daemonCmdline('/tmp/other-registration.json'))));
    expect((r.assets.find((x) => x.id === 'service:repo-sync-devforge')!.payload as { active: string }).active).toBe('dead');
  });

  it('pid_file 遗留但 /proc cmdline 不存在（stale）→ dead', async () => {
    const pidFile = join(root, 'stale.pid');
    await writeFile(pidFile, String(process.pid));
    await writeRepos(JSON.stringify({ name: 'devforge', repo_path: '/x', pid_file: pidFile }));
    const r = await devforgeLaunchCollector.collect(ctx(fakeProc('', false)));
    expect((r.assets.find((x) => x.id === 'service:repo-sync-devforge')!.payload as { active: string }).active).toBe('dead');
  });

  it('无 pid_file 字段 → unknown，未声明 enabled 视为启用', async () => {
    await writeRepos(JSON.stringify({ name: 'devforge', repo_path: '/x' }));
    const r = await devforgeLaunchCollector.collect(ctx());
    const a = r.assets.find((x) => x.id === 'service:repo-sync-devforge')!;
    expect((a.payload as { active: string; enabled: boolean }).active).toBe('unknown');
    expect(a.enabled).toBe(true);
    expect((a.payload as { enabled: boolean }).enabled).toBe(true);
  });

  it('repo-sync 资产声明无平台（source.platform=none）且为自研（first-party）', async () => {
    await writeRepos(JSON.stringify({ name: 'devforge', repo_path: '/x' }));
    const r = await devforgeLaunchCollector.collect(ctx());
    const a = r.assets.find((x) => x.id === 'service:repo-sync-devforge')!;
    expect(a.source.platform).toBe('none');
    expect(a.source.path).toBe(join(root, 'repo-sync', 'repos.d', 'devforge.json'));
    expect(a.platforms).toEqual([]);
    expect(a.provenance).toBe('first-party');
  });

  it('enabled=false 且 pid 缺失 → disabled（顶层/payload 同步停用）', async () => {
    await writeRepos(JSON.stringify({ name: 'devforge', repo_path: '/x', enabled: false, pid_file: join(root, 'disabled-gone.pid') }));
    const r = await devforgeLaunchCollector.collect(ctx());
    const a = r.assets.find((x) => x.id === 'service:repo-sync-devforge')!;
    const payload = a.payload as { active: string; trigger: string; enabled: boolean };
    expect(payload.active).toBe('disabled');
    expect(payload.trigger).toBe('已手动停用（enabled=false）');
    expect(a.enabled).toBe(false);
    expect(payload.enabled).toBe(false);
  });

  it('enabled=false 且 pid 存活 → disabled（进程残留也不改停用语义）', async () => {
    const pidFile = join(root, 'disabled-live.pid');
    await writeFile(pidFile, String(process.pid));
    await writeRepos(JSON.stringify({ name: 'devforge', repo_path: '/x', enabled: false, pid_file: pidFile }));
    const r = await devforgeLaunchCollector.collect(ctx());
    const a = r.assets.find((x) => x.id === 'service:repo-sync-devforge')!;
    const payload = a.payload as { active: string; trigger: string; enabled: boolean };
    expect(payload.active).toBe('disabled');
    expect(payload.trigger).toBe('已手动停用（enabled=false）');
    expect(a.enabled).toBe(false);
    expect(payload.enabled).toBe(false);
  });

  it('显式 enabled=true 且 pid 缺失 → 保持 dead，顶层/payload 为启用', async () => {
    await writeRepos(JSON.stringify({ name: 'devforge', repo_path: '/x', enabled: true, pid_file: join(root, 'enabled-gone.pid') }));
    const r = await devforgeLaunchCollector.collect(ctx());
    const a = r.assets.find((x) => x.id === 'service:repo-sync-devforge')!;
    const payload = a.payload as { active: string; enabled: boolean };
    expect(payload.active).toBe('dead');
    expect(a.enabled).toBe(true);
    expect(payload.enabled).toBe(true);
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
