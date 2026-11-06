import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { devforgePatchesCollector } from './devforge-patches.js';
import { buildReconcileReport } from '../reconcile.js';
import { defaultConfig, makeContext } from '../index.js';
import { sha256 } from '../util.js';

const APPLIER = '#!/usr/bin/env bash\n# fixture applier\necho patched\n';

let root = '';
let runtimeDir = '';
let patchesDir = '';
let target = '';

beforeAll(async () => {
  root = await mkdtemp(join(tmpdir(), 'forge-patches-'));
  patchesDir = join(root, '.hindsight', 'patches');
  runtimeDir = join(root, '.hindsight', 'coding-agents');
  await mkdir(patchesDir, { recursive: true });
  await mkdir(join(runtimeDir, 'dist'), { recursive: true });
  await writeFile(join(runtimeDir, 'package.json'), JSON.stringify({ name: '@vectorize-io/hindsight-coding-agents', version: '0.8.2' }));
  await writeFile(join(patchesDir, 'fixture-patch.sh'), APPLIER);
  target = join(runtimeDir, 'dist', 'hooked.js');
  await writeFile(target, 'patched content\n');
});

afterAll(async () => {
  if (root) await rm(root, { recursive: true, force: true });
});

function ctx() {
  return makeContext(defaultConfig({ home: root, devforge: root }));
}

async function writeState(overrides: Partial<{ applierSha256: string; targetSha: string | null; anchorVersion: string }> = {}) {
  await writeFile(
    join(patchesDir, 'fixture-patch.state.json'),
    JSON.stringify({
      program: 'fixture-patch',
      appliedAt: '2026-11-06T00:00:00Z',
      applierPath: join(patchesDir, 'fixture-patch.sh'),
      applierSha256: overrides.applierSha256 ?? sha256(APPLIER),
      runtimeDir,
      anchor: { package: '@vectorize-io/hindsight-coding-agents', version: overrides.anchorVersion ?? '0.8.2' },
      targets: [{ path: target, sha256: overrides.targetSha === undefined ? sha256('patched content\n') : overrides.targetSha, note: 'fixture 手术面' }],
    })
  );
}

describe('devforge-patches collector（应用事实 → 实测漂移）', () => {
  it('基线全匹配 → applied，无 warn 诊断', async () => {
    await writeState();
    const r = await devforgePatchesCollector.collect(ctx());
    const a = r.assets.find((x) => x.id === 'patch:fixture-patch');
    expect(a).toBeDefined();
    expect(a!.kind).toBe('patch');
    expect(a!.provenance).toBe('first-party');
    expect((a!.payload as { state?: string }).state).toBe('applied');
    expect(r.diagnostics).toEqual([]);
  });

  it('目标文件被改/上游版本升级 → drifted，WARN 诊断带出漂移目标', async () => {
    await writeState({ targetSha: sha256('pristine content\n') }); // 基线是旧内容，现状已不同
    const r = await devforgePatchesCollector.collect(ctx());
    const a = r.assets.find((x) => x.id === 'patch:fixture-patch')!;
    const p = a.payload as { state?: string; driftedTargets?: Array<{ path: string; reason: string }> };
    expect(p.state).toBe('drifted');
    expect(p.driftedTargets?.[0]).toMatchObject({ path: target, reason: '指纹与基线不符' });
    expect(r.diagnostics.some((d) => d.level === 'warn' && d.message.includes('fixture-patch'))).toBe(true);
  });

  it('补丁脚本改过但未重跑 → stale；锚定版本失配也判 drifted', async () => {
    await writeState({ applierSha256: 'deadbeef' });
    const stale = await devforgePatchesCollector.collect(ctx());
    expect((stale.assets.find((x) => x.id === 'patch:fixture-patch')!.payload as { state?: string }).state).toBe('stale');

    await writeState({ anchorVersion: '0.7.0' }); // 基线锚 0.7.0，现运行 0.8.2
    const anchor = await devforgePatchesCollector.collect(ctx());
    const p = anchor.assets.find((x) => x.id === 'patch:fixture-patch')!.payload as { state?: string; anchorDrift?: boolean };
    expect(p.state).toBe('drifted');
    expect(p.anchorDrift).toBe(true);
  });

  it('无 state → unverified（按契约跑一次即纳入）', async () => {
    await rm(join(patchesDir, 'fixture-patch.state.json'));
    const r = await devforgePatchesCollector.collect(ctx());
    expect((r.assets.find((x) => x.id === 'patch:fixture-patch')!.payload as { state?: string }).state).toBe('unverified');
  });
});

describe('patch-drift 对账闭环', () => {
  it('非 applied 的补丁 → 对账出 patch-drift 项 + 可执行 reapply 动作', async () => {
    await writeState({ targetSha: sha256('pristine content\n') });
    const r = await devforgePatchesCollector.collect(ctx());
    const report = buildReconcileReport({ assets: r.assets }, []);
    const item = report.items.find((i) => i.type === 'patch-drift');
    expect(item).toBeDefined();
    expect(item!.key).toBe('patch:fixture-patch');
    expect(item!.severity).toBe('warn');
    expect(report.summary.patch).toBe(1);
    const reapply = item!.actions.find((a) => a.id === 'reapply');
    expect(reapply?.executable).toBe(true);
    expect(reapply?.steps[0]).toMatchObject({ type: 'command', cmd: ['bash', join(patchesDir, 'fixture-patch.sh')] });
  });

  it('applied 的补丁不产生对账项', async () => {
    await writeState();
    const r = await devforgePatchesCollector.collect(ctx());
    const report = buildReconcileReport({ assets: r.assets }, []);
    expect(report.items.filter((i) => i.type === 'patch-drift')).toHaveLength(0);
    expect(report.summary.patch).toBe(0);
  });
});
