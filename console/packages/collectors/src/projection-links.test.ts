import { describe, expect, it } from 'vitest';
import { mkdtemp, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import {
  loadProjectionLinks,
  saveProjectionLinks,
  upsertLink,
  markLinkLost,
  reconcileProjectionLinks,
  type ProjectionLink,
} from './projection-links.js';
import type { Asset } from '@forge/schema';

function mkAsset(id: string, path: string): Asset {
  return {
    id,
    kind: 'skill',
    name: id.split(':')[1] ?? id,
    summary: '',
    attach: { level: 'user' },
    enforcement: 'enforced',
    platforms: ['claude-code'],
    provenance: 'first-party',
    tags: [],
    enabled: true,
    source: { collector: 'test', path },
    payload: { content: 'body' },
  };
}

describe('projection-links（单一映射：真源 ↔ 投影坐标）', () => {
  it('upsert 幂等：同 (truthId, ref) 重复登记只刷新不新增', () => {
    const links: ProjectionLink[] = [];
    upsertLink(links, { truthId: 'skill:a', ref: '/x/a.md', coordinate: 'file', linkedBy: 'auto' });
    upsertLink(links, { truthId: 'skill:a', ref: '/x/a.md', coordinate: 'file', linkedBy: 'auto' });
    expect(links).toHaveLength(1);
  });

  it('ref 消失 → lost；复活 → 自动回连', () => {
    const links: ProjectionLink[] = [];
    const a = mkAsset('skill:a', '/x/a.md');
    upsertLink(links, { truthId: a.id, ref: '/x/a.md', coordinate: 'file', linkedBy: 'auto' });
    // 采集面只剩别的资产 → lost
    const r1 = reconcileProjectionLinks(links, [mkAsset('skill:b', '/x/b.md')]);
    expect(r1.lost).toBe(1);
    expect(links[0].status).toBe('lost');
    // 复活 → 回连
    const r2 = reconcileProjectionLinks(links, [a]);
    expect(r2.changed).toBe(true);
    expect(links[0].status).toBe('linked');
  });

  it('声明的新自建资产 → 自动登记', () => {
    const links: ProjectionLink[] = [];
    const a = mkAsset('skill:new', '/x/new.md');
    reconcileProjectionLinks(links, [a]);
    expect(links.some((l) => l.truthId === a.id && l.linkedBy === 'auto')).toBe(true);
  });

  it('load/save 往返保形', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'forge-links-'));
    const file = join(dir, 'projection-links.json');
    const links: ProjectionLink[] = [
      { truthId: 'skill:a', ref: '/x/a.md', coordinate: 'file', linkedBy: 'push', linkedAt: 't1', status: 'linked', lastFingerprint: 'fp1' },
      { truthId: 'skill:b', ref: '/x/b.md', coordinate: 'file', linkedBy: 'confirm', linkedAt: 't2', status: 'lost', lostAt: 't3' },
    ];
    await saveProjectionLinks(file, links);
    const loaded = await loadProjectionLinks(file);
    expect(loaded.links).toEqual(links);
    await rm(dir, { recursive: true, force: true });
  });

  it('持久化文件真实落盘（.trash 语义独立于本模块，此处只验 IO）', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'forge-links-io-'));
    const file = join(dir, 'projection-links.json');
    await saveProjectionLinks(file, []);
    const files = await readdir(dir);
    expect(files).toContain('projection-links.json');
    await rm(dir, { recursive: true, force: true });
  });
});
