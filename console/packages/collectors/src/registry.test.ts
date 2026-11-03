import { describe, expect, it } from 'vitest';
import type { Asset, Collection } from '@forge/schema';
import { mergeCollections } from './registry.js';

function instr(id: string, path: string, hash: string, ws?: string, lines = 100): Asset {
  return {
    id,
    kind: 'instruction',
    name: id.split(':')[1] ?? id,
    summary: '',
    attach: { level: 'project', ref: path.replace('/CLAUDE.md', '') },
    applies: ws ? { workspaces: [ws], origin: 'native' } : undefined,
    enforcement: 'derived',
    platforms: ['claude-code'],
    provenance: 'first-party',
    tags: ws ? [ws] : [],
    enabled: true,
    source: { collector: 'test', path },
    payload: { basename: 'CLAUDE.md', contentHash: hash, lines, projectName: path.split('/').slice(-2, -1)[0] },
  };
}

describe('mergeCollections', () => {
  it('dedupes by id, first wins, records conflict diagnostics', () => {
    const a: Collection = {
      collector: 'a',
      collectedAt: '2026-11-03T00:00:00Z',
      assets: [
        { ...instr('instruction:x/CLAUDE.md', '/x/CLAUDE.md', 'h1'), name: 'first' },
      ],
      relations: [],
      diagnostics: [],
    };
    const b: Collection = {
      collector: 'b',
      collectedAt: '2026-11-03T00:00:00Z',
      assets: [
        { ...instr('instruction:x/CLAUDE.md', '/x/CLAUDE.md', 'h2'), name: 'second' },
      ],
      relations: [],
      diagnostics: [],
    };
    const merged = mergeCollections([a, b]);
    expect(merged.assets).toHaveLength(1);
    expect(merged.assets[0].name).toBe('first');
    expect(merged.diagnostics.some((d) => d.message.includes('x/CLAUDE.md'))).toBe(true);
  });
});

describe('merge order stability（修前端闪动）', () => {
  it('同输入不同完成次序 → 输出顺序一致（kind+id 排序）', () => {
    const make = (ids: string[]) => ({
      collector: 'x',
      collectedAt: '',
      assets: ids.map((id) => instr(id, `/${id}/CLAUDE.md`, 'h1')),
      relations: [],
      diagnostics: [],
    });
    const a = mergeCollections([make(['instruction:b/CLAUDE.md', 'instruction:a/CLAUDE.md'])]);
    const b = mergeCollections([make(['instruction:a/CLAUDE.md', 'instruction:b/CLAUDE.md'])]);
    expect(a.assets.map((x) => x.id)).toEqual(['instruction:a/CLAUDE.md', 'instruction:b/CLAUDE.md']);
    expect(a.assets.map((x) => x.id)).toEqual(b.assets.map((x) => x.id));
  });
});
