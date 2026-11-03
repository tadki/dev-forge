import { afterAll, describe, expect, it } from 'vitest';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import type { Asset } from '@forge/schema';
import type { RegistryState } from './registry.js';
import { applyRegistryOverlay, loadRegistryEntries } from './overlay.js';

const dir = join(tmpdir(), `forge-overlay-${Date.now()}`);

function mk(id: string, path: string, provenance: 'first-party' | 'third-party' = 'first-party'): Asset {
  return {
    id,
    kind: id.startsWith('service:') ? 'service' : 'hook-rule',
    name: id.split(':')[1] ?? id,
    summary: '',
    attach: { level: 'user' },
    enforcement: 'enforced',
    platforms: ['claude-code'],
    provenance,
    tags: [],
    enabled: true,
    source: { collector: 'test', path },
    payload: {},
  };
}

function stateOf(assets: Asset[]): RegistryState {
  return { assets, relations: [], diagnostics: [], collectorStatus: [], lastCollectedAt: '' };
}

const MANIFEST = `entries:
  - id: forge-console
    match:
      idPrefix: "service:systemd-forge-console"
    meta:
      owner: jerry
      category: infra
      lifecycle: stable
      criticality: high
      runtime: standalone
  - id: devforge-hooks
    match:
      pathPrefix: "/home/jerry/tools/dev-forge/claude-hooks"
    meta:
      owner: atlas
      category: governance
      criticality: high
  - id: never-matches
    match:
      idPrefix: "agent:ghost-"
    meta:
      owner: jerry
`;

describe('registry.d 声明盖戳（overlay）', () => {
  it('loads entries from yaml', async () => {
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, 'owned.yaml'), MANIFEST);
    const entries = await loadRegistryEntries(dir);
    expect(entries.map((e) => e.id)).toEqual(['forge-console', 'devforge-hooks', 'never-matches']);
  });

  it('missing dir → no entries', async () => {
    expect(await loadRegistryEntries(join(dir, 'nope'))).toEqual([]);
  });

  it('stamps meta + provenance on matched assets; third-party overridden to ours when declared', async () => {
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, 'owned.yaml'), MANIFEST);
    const entries = await loadRegistryEntries(dir);
    const a1 = mk('service:systemd-forge-console.service', 'systemd://user/forge-console.service', 'third-party');
    const a2 = mk('hook-rule:push-guard-master-gate', '/home/jerry/tools/dev-forge/claude-hooks/unified/rules.d/x.json');
    const out = applyRegistryOverlay(stateOf([a1, a2]), entries);
    const s1 = out.assets.find((x) => x.id === a1.id)!;
    expect(s1.provenance).toBe('first-party'); // 声明即归属
    expect(s1.meta).toMatchObject({ owner: 'jerry', criticality: 'high', lifecycle: 'stable' });
    expect((s1.payload as { registry?: { declaredBy?: string } }).registry?.declaredBy).toBe('forge-console');
    const s2 = out.assets.find((x) => x.id === a2.id)!;
    expect(s2.meta?.category).toBe('governance');
  });

  it('unmatched declarations surface as assets + diagnostics; undeclared first-party flagged', async () => {
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, 'owned.yaml'), MANIFEST);
    const entries = await loadRegistryEntries(dir);
    const stranger = mk('hook-rule:some-new-rule', '/home/jerry/elsewhere/new-rule.json');
    const third = mk('skill:ecc-x', '/x', 'third-party');
    const out = applyRegistryOverlay(stateOf([stranger, third]), entries);
    // 未匹配声明
    expect(out.assets.some((x) => x.id.startsWith('registry:unmatched-'))).toBe(true);
    expect(out.diagnostics.some((d) => d.message.includes('never-matches'))).toBe(true);
    // 未登记的自建资产被标记，第三方不标（overlay 生成新对象，从结果里取）
    const s = out.assets.find((x) => x.id === stranger.id)!;
    const tp = out.assets.find((x) => x.id === third.id)!;
    expect((s.payload as { registry?: { declared?: boolean } }).registry?.declared).toBe(false);
    expect((tp.payload as { registry?: { declared?: boolean } }).registry?.declared).toBeUndefined();
  });

  afterAll(async () => {
    await rm(dir, { recursive: true, force: true });
  });
});
