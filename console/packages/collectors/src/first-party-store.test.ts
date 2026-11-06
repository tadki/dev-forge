import { afterAll, describe, expect, it } from 'vitest';
import { mkdir, readdir, rm, stat, writeFile } from 'node:fs/promises';
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
    expect(rec.hashVersion).toBe(3);
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
    expect(rec.hashVersion).toBe(3);
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

  const scriptAsset = (sha256: string, content?: string): Asset => ({
    id: 'hook-script:patch.sh',
    kind: 'hook-script',
    name: 'patch.sh',
    summary: '',
    attach: { level: 'user' },
    enforcement: 'enforced',
    platforms: ['claude-code'],
    provenance: 'first-party',
    tags: [],
    enabled: true,
    source: { collector: 'test', path: '/tmp/hooks/patch.sh', sha256 },
    payload: {
      lines: 3,
      purpose: '修补',
      registry: { declared: true, declaredBy: 'e' },
      ...(content !== undefined ? { content } : {}),
    },
  });

  it('正文回填：指纹一致且旧记录缺正文 → 原地补写正文，哈希与 savedAt 不变', async () => {
    const sub = join(dir, 'backfill');
    const old = scriptAsset('sha-old');
    await writeStoreRecord(sub, old);
    const oldRec = (await loadFirstPartyStore(sub)).records.get(old.id)!;
    const prod = scriptAsset('sha-old', '#!/bin/sh\necho hi\n');
    const r = await syncFirstPartyStore([prod], sub);
    expect(r.backfilled).toBe(1);
    expect(r.unchanged).toBe(0);
    const rec = (await loadFirstPartyStore(sub)).records.get(old.id)!;
    expect((rec.asset.payload as { content?: string }).content).toBe('#!/bin/sh\necho hi\n');
    expect(rec.hash).toBe(oldRec.hash); // 指纹不变（content 不参与）
    expect(rec.savedAt).toBe(oldRec.savedAt);
    // 已回填后再次同步 → 未变，不重写
    const r2 = await syncFirstPartyStore([prod], sub);
    expect(r2.backfilled).toBe(0);
    expect(r2.unchanged).toBe(1);
  });

  it('正文回填不越过漂移：指纹不同时不回填（正文只能经 adopt 落库）', async () => {
    const sub = join(dir, 'backfill-drift');
    const old = scriptAsset('sha-old');
    const oldRec = await writeStoreRecord(sub, old);
    const r = await syncFirstPartyStore([scriptAsset('sha-new', '#!/bin/sh\necho new\n')], sub);
    expect(r.backfilled).toBe(0);
    const rec = (await loadFirstPartyStore(sub)).records.get(old.id)!;
    expect((rec.asset.payload as { content?: string }).content).toBeUndefined();
    expect(rec.hash).toBe(oldRec.hash); // 库内真源未被生产覆写
  });

  it('考古回填：漂移记录可按记录 sha256 从 git 历史复原旧正文（哈希不变、漂移保留）', async () => {
    const { execCapture } = await import('./util.js');
    const { resetGitRecoveryCache } = await import('./git-history.js');
    const { createHash } = await import('node:crypto');
    const repo = join(dir, 'archaeo-repo');
    const scriptsDir = join(repo, 'autopilots');
    await mkdir(scriptsDir, { recursive: true });
    const init = await execCapture('git', ['-C', repo, 'init'], 10000);
    expect(init.ok, init.stderr).toBe(true);
    const oldBody = '#!/usr/bin/env python3\n# v1 has run_ok\n\ndef run_ok():\n    return True\n';
    const newBody = '#!/usr/bin/env python3\n# v2 dropped run_ok\n';
    for (const [body, msg] of [
      [oldBody, 'v1'],
      [newBody, 'v2'],
    ] as const) {
      await writeFile(join(scriptsDir, 'sweep.py'), body);
      for (const args of [['add', '.'], ['-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-m', msg]]) {
        const r = await execCapture('git', ['-C', repo, ...args], 10000);
        expect(r.ok, r.stderr).toBe(true);
      }
    }
    const oldSha = createHash('sha256').update(oldBody).digest('hex');
    resetGitRecoveryCache();

    const sub = join(dir, 'archaeo');
    const old = { ...scriptAsset(oldSha), source: { collector: 't', path: join(scriptsDir, 'sweep.py'), sha256: oldSha } };
    const oldRec = await writeStoreRecord(sub, old);
    const prod = { ...scriptAsset('sha-new'), source: { collector: 't', path: join(scriptsDir, 'sweep.py'), sha256: 'sha-new' } };
    (prod.payload as Record<string, unknown>).content = newBody;

    const r = await syncFirstPartyStore([prod], sub);
    expect(r.backfilled).toBe(1);
    const rec = (await loadFirstPartyStore(sub)).records.get(old.id)!;
    expect((rec.asset.payload as { content?: string }).content).toBe(oldBody); // 复原的是旧版，不是生产版
    expect(rec.hash).toBe(oldRec.hash); // 指纹不变 → store-drift 卡片照常存在
    expect(rec.savedAt).toBe(oldRec.savedAt);
    // 已复原 → 后续同步未变，不再试探
    const r2 = await syncFirstPartyStore([prod], sub);
    expect(r2.backfilled).toBe(0);
    expect(r2.unchanged).toBe(1);
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

describe('contentFingerprint 审核回归', () => {
  const base = {
    id: 'x', kind: 'autopilot', name: 'x', summary: '', attach: { level: 'user' as const },
    enforcement: 'derived' as const, platforms: ['multica'], provenance: 'first-party' as const,
    tags: [], enabled: true, source: { collector: 't', path: 'multica://autopilots/z' },
  };
  it('multica autopilot：assignee（UUID/名字解析不稳定）不参与指纹；trigger 缺 id 不崩溃', () => {
    const f = (assignee: string, triggers: unknown[]) => contentFingerprint({ ...base, payload: { platformId: 'z', assignee, triggers } } as Asset);
    expect(f('Fronti', [{ id: 't1', kind: 'cron', cron_expression: '0 9 * * *', next_run_at: 'x' }]))
      .toBe(f('uuid-123', [{ id: 't1', kind: 'cron', cron_expression: '0 9 * * *', next_run_at: 'y' }]));
    expect(() => contentFingerprint({ ...base, payload: { platformId: 'z', triggers: [{ kind: 'cron' }] } } as Asset)).not.toThrow();
  });

  it('文件型 kind（autopilot/hook-script/adapter）：payload.content 不参与指纹（正文归档不制造假漂移）', () => {
    const fp = (kind: Asset['kind'], path: string, content: string) =>
      contentFingerprint({
        ...base, kind, source: { collector: 't', path },
        payload: content === '' ? { purpose: 'p' } : { purpose: 'p', content },
      } as Asset);
    for (const [kind, path] of [
      ['autopilot', '/x/a.py'],
      ['hook-script', '/x/b.sh'],
      ['adapter', '/x/c.sh'],
    ] as const) {
      expect(fp(kind, path, '')).toBe(fp(kind, path, '任意正文'));
    }
  });
});
