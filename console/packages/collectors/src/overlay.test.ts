import { afterAll, describe, expect, it } from 'vitest';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import type { Asset } from '@forge/schema';
import type { RegistryState } from './registry.js';
import { applyRegistryOverlay, loadRegistryEntries, matchesRegistryEntry, type RegistryEntry } from './overlay.js';

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
    const { entries } = await loadRegistryEntries(dir);
    expect(entries.map((e) => e.id)).toEqual(['forge-console', 'devforge-hooks', 'never-matches']);
  });

  it('missing dir → no entries', async () => {
    expect(await loadRegistryEntries(join(dir, 'nope'))).toEqual({ entries: [], diagnostics: [] });
  });

  it('stamps meta + provenance on matched assets; third-party overridden to ours when declared', async () => {
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, 'owned.yaml'), MANIFEST);
    const { entries } = await loadRegistryEntries(dir);
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
    const { entries } = await loadRegistryEntries(dir);
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

  it('entry 契约违规 → 跳过该 entry 并报 error 诊断（坏平台枚举/坏 lifecycle）', async () => {
    const badDir = join(dir, 'invalid');
    await mkdir(badDir, { recursive: true });
    await writeFile(
      join(badDir, 'bad.yaml'),
      `entries:
  - id: ok-entry
    match: { pathPrefix: "/home/jerry/tools/" }
    platforms: [claude-code]
  - id: bad-platform
    match: { pathPrefix: "/x" }
    platforms: [hermes]
  - id: bad-lifecycle
    match: { pathPrefix: "/y" }
    meta: { lifecycle: stablee }
`
    );
    const { entries, diagnostics } = await loadRegistryEntries(badDir);
    expect(entries.map((e) => e.id)).toEqual(['ok-entry']);
    expect(diagnostics).toHaveLength(2);
    expect(diagnostics.every((d) => d.level === 'error')).toBe(true);
    expect(diagnostics.map((d) => d.message).join(';')).toMatch(/bad-platform/);
    expect(diagnostics.map((d) => d.message).join(';')).toMatch(/bad-lifecycle/);
  });

  it('match 语义：ids 精确 / exclude 剔除 / fallthrough 到下一条 entry', async () => {
    const entries: RegistryEntry[] = [
      { id: 'exact', match: { ids: ['skill:a', 'skill:b'] }, file: '/x' },
      { id: 'broad', match: { pathPrefix: '/platform/', exclude: { ids: ['skill:platform-own'] } }, file: '/x' },
      { id: 'catch-all', match: { pathPrefix: '/platform/' }, file: '/x' },
    ];
    const at = (id: string, path: string): Asset => mk(id, path);
    // ids 精确命中
    expect(matchesRegistryEntry(at('skill:a', '/anywhere'), entries[0])).toBe(true);
    expect(matchesRegistryEntry(at('skill:c', '/anywhere'), entries[0])).toBe(false);
    // 前缀命中但被 exclude 剔除 → 不命中该 entry
    expect(matchesRegistryEntry(at('skill:platform-own', '/platform/x'), entries[1])).toBe(false);
    expect(matchesRegistryEntry(at('skill:mine', '/platform/x'), entries[1])).toBe(true);
    // 被 exclude 挡掉的资产会 fallthrough 命中后面更宽的 entry（find 语义）
    const hit = entries.find((e) => matchesRegistryEntry(at('skill:platform-own', '/platform/x'), e));
    expect(hit?.id).toBe('catch-all');
  });

  afterAll(async () => {
    await rm(dir, { recursive: true, force: true });
  });
});
