import { afterAll, describe, expect, it } from 'vitest';
import { mkdir, readdir, rm, stat } from 'node:fs/promises';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import type { Asset } from '@forge/schema';
import { contentFingerprint } from './store-content.js';
import { loadFirstPartyStore, syncFirstPartyStore, storeFileName, writeStoreRecord } from './first-party-store.js';

const dir = join(tmpdir(), `forge-fp-store-${Date.now()}`);

function mkAsset(id: string, opts?: { declared?: boolean; content?: string; kind?: string }): Asset {
  const kind = opts?.kind ?? 'skill';
  return {
    id,
    kind: kind as Asset['kind'],
    name: id.split(':')[1] ?? id,
    summary: '',
    attach: { level: 'user' },
    enforcement: 'advisory',
    platforms: ['claude-code'],
    provenance: 'first-party',
    tags: [],
    enabled: true,
    source: { collector: 'test', path: '/x/SKILL.md', sha256: 'abc' },
    payload: {
      ...(opts?.declared === false
        ? { registry: { declared: false } }
        : { registry: { declared: true, declaredBy: 'test-entry' } }),
      content: opts?.content ?? 'v1',
    },
  };
}

describe('first-party store（真源：create-only）', () => {
  it('首次见到才建副本；已存在副本即使生产内容变了也不覆写', async () => {
    const sub = join(dir, 'create-only');
    const r1 = await syncFirstPartyStore([mkAsset('skill:a', { content: 'v1' })], sub);
    expect(r1.written).toBe(1);
    const file = join(sub, storeFileName('skill:a'));
    const mtime1 = (await stat(file)).mtimeMs;
    const r2 = await syncFirstPartyStore([mkAsset('skill:a', { content: '生产改了' })], sub);
    expect(r2.unchanged).toBe(1);
    expect((await stat(file)).mtimeMs).toBe(mtime1); // 未重写
    const rec = JSON.parse(await readFile(file, 'utf8'));
    expect(rec.asset.payload.content).toBe('v1'); // 库内保持真源
    expect(rec.hashVersion).toBe(2);
  });

  it('非内容型 kind 与未声明资产不入库', async () => {
    const sub = join(dir, 'gating');
    const r = await syncFirstPartyStore(
      [mkAsset('service:x', { kind: 'service' }), mkAsset('skill:undeclared', { declared: false })],
      sub
    );
    expect(r.written).toBe(0);
    expect((await readdir(sub)).filter((f) => f.endsWith('.json'))).toHaveLength(0);
  });

  it('v1 记录迁移为 v2（按当前生产内容采纳基线），不报漂移', async () => {
    const sub = join(dir, 'migrate');
    const a = mkAsset('skill:old', { content: '现产' });
    // 手工构造 v1 记录（无 hashVersion，hash 是旧口径）
    await mkdir(sub, { recursive: true });
    const { writeFile } = await import('node:fs/promises');
    await writeFile(
      join(sub, storeFileName(a.id)),
      JSON.stringify({ id: a.id, kind: a.kind, name: a.name, savedAt: '2026-11-05T00:00:00Z', updatedAt: '2026-11-05T00:00:00Z', hash: 'old-v1-hash', asset: a })
    );
    const r = await syncFirstPartyStore([a], sub);
    expect(r.migrated).toBe(1);
    const rec = JSON.parse(await readFile(join(sub, storeFileName(a.id)), 'utf8'));
    expect(rec.hashVersion).toBe(2);
    expect(rec.hash).toBe(contentFingerprint(a));
    expect(rec.migratedAt).toBeTruthy();
    expect(rec.savedAt).toBe('2026-11-05T00:00:00Z'); // 首次入库时间保留
  });

  it('资产消失时副本保留（kept），不删数据', async () => {
    const sub = join(dir, 'kept');
    const a = mkAsset('skill:gone');
    await syncFirstPartyStore([a], sub);
    const r = await syncFirstPartyStore([mkAsset('skill:other')], sub);
    expect(r.kept).toBe(1);
    const loaded = await loadFirstPartyStore(sub);
    expect(loaded.records.get('skill:gone')?.id).toBe('skill:gone');
  });

  it('writeStoreRecord 供 adopt 复用：重写后 hash/updatedAt 刷新、savedAt 保留', async () => {
    const sub = join(dir, 'adopt');
    const a = mkAsset('skill:adopt', { content: 'v1' });
    const first = await writeStoreRecord(sub, a);
    await new Promise((r) => setTimeout(r, 5));
    const updated = await writeStoreRecord(sub, mkAsset('skill:adopt', { content: 'v2 采纳' }), first);
    expect(updated.savedAt).toBe(first.savedAt);
    expect(updated.updatedAt > first.updatedAt).toBe(true);
  });
});

describe('contentFingerprint（按 kind 内容字段，volatile 剔除）', () => {
  const base = {
    id: 'x',
    kind: 'instruction',
    name: 'x',
    summary: '',
    attach: { level: 'user' as const },
    enforcement: 'derived' as const,
    platforms: ['claude-code'],
    provenance: 'first-party' as const,
    tags: [],
    enabled: true,
    source: { collector: 't', path: '/x' },
  };

  it('instruction：只认 content，lines/headings/summary 变化不影响', () => {
    const a = { ...base, payload: { content: '正文', lines: 10, headings: [{ level: 1, text: 'h' }] } };
    const b = { ...base, payload: { content: '正文', lines: 99, headings: [] } };
    expect(contentFingerprint(a as Asset)).toBe(contentFingerprint(b as Asset));
    const c = { ...base, payload: { content: '正文改', lines: 10 } };
    expect(contentFingerprint(a as Asset)).not.toBe(contentFingerprint(c as Asset));
  });

  it('agent：剔除 customEnvKeyCount/instructionsHash/mcpRedacted；skills 顺序不敏感', () => {
    const p1 = { instructions: 'i1', model: 'm', customEnvKeyCount: 3, instructionsHash: 'h1', skills: [{ name: 'a' }, { name: 'b' }] };
    const p2 = { instructions: 'i1', model: 'm', customEnvKeyCount: 26, instructionsHash: 'h2', skills: [{ name: 'b' }, { name: 'a' }] };
    const f1 = contentFingerprint({ ...base, kind: 'agent', payload: p1 } as Asset);
    const f2 = contentFingerprint({ ...base, kind: 'agent', payload: p2 } as Asset);
    expect(f1).toBe(f2);
  });

  it('multica autopilot：next_run_at/lastRun* 不影响，cron 变化影响', () => {
    const t = (cron: string, next: string) => ({
      platformId: 'ap1',
      description: 'd',
      triggers: [{ id: 't1', kind: 'cron', cron_expression: cron, next_run_at: next }],
      lastRunAt: '2026-01-01',
      lastRunStatus: 'ok',
      nextRunAt: next,
      workspaceId: 'ws',
    });
    const same = contentFingerprint({ ...base, kind: 'autopilot', source: { collector: 't', path: 'multica://autopilots/ap1' }, payload: t('0 9 * * *', '2026-11-07T09:00') } as Asset);
    const nextChanged = contentFingerprint({ ...base, kind: 'autopilot', source: { collector: 't', path: 'multica://autopilots/ap1' }, payload: t('0 9 * * *', '2026-12-01T09:00') } as Asset);
    const cronChanged = contentFingerprint({ ...base, kind: 'autopilot', source: { collector: 't', path: 'multica://autopilots/ap1' }, payload: t('0 10 * * *', '2026-11-07T09:00') } as Asset);
    expect(same).toBe(nextChanged);
    expect(same).not.toBe(cronChanged);
  });

  it('skill：files 按 path 排序后比较，顺序不敏感；content 变化影响', () => {
    const files1 = [{ path: 'b.sh', content: 'x' }, { path: 'a.md', content: 'y' }];
    const files2 = [{ path: 'a.md', content: 'y' }, { path: 'b.sh', content: 'x' }];
    const f = (files: unknown, content: string) =>
      contentFingerprint({ ...base, kind: 'skill', payload: { content, files } } as Asset);
    expect(f(files1, 'c')).toBe(f(files2, 'c'));
    expect(f(files1, 'c')).not.toBe(f(files2, 'c2'));
  });
});

afterAll(async () => {
  await rm(dir, { recursive: true, force: true });
});
