import { describe, expect, it } from 'vitest';
import type { Asset, Collection } from '@forge/schema';
import { computeDriftGroups, mergeCollections } from './registry.js';

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

const kol = 'kol';

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

describe('computeDriftGroups', () => {
  it('flags same-basename instructions with different hashes inside one workspace', () => {
    const assets = [
      instr('instruction:kol-main/CLAUDE.md', '/mnt/d/GodotProjects/king-of-likes/CLAUDE.md', 'aaa', kol, 144),
      instr('instruction:s5/CLAUDE.md', '/home/jerry/s5recheck-worktree/CLAUDE.md', 'bbb', kol, 157),
      instr('instruction:qa/CLAUDE.md', '/mnt/d/GodotProjects/see1089-qa/CLAUDE.md', 'bbb', kol, 152),
    ];
    const groups = computeDriftGroups(assets);
    expect(groups).toHaveLength(1);
    expect(groups[0].workspace).toBe(kol);
    expect(groups[0].basename).toBe('CLAUDE.md');
    expect(groups[0].variants).toHaveLength(2); // aaa 与 bbb 两个 hash 变体
    expect(groups[0].copies).toBe(3);
  });

  it('does not group across workspaces', () => {
    const assets = [
      instr('instruction:a/CLAUDE.md', '/a/CLAUDE.md', 'aaa', 'ws1'),
      instr('instruction:b/CLAUDE.md', '/b/CLAUDE.md', 'bbb', 'ws2'),
    ];
    expect(computeDriftGroups(assets)).toHaveLength(0);
  });

  it('ignores identical copies (no drift, just copies)', () => {
    const assets = [
      instr('instruction:a/CLAUDE.md', '/a/CLAUDE.md', 'same', kol),
      instr('instruction:b/CLAUDE.md', '/b/CLAUDE.md', 'same', kol),
    ];
    const groups = computeDriftGroups(assets);
    expect(groups).toHaveLength(0);
  });

  it('unassigned workspace falls into "(未分组)" bucket', () => {
    const assets = [
      instr('instruction:a/CLAUDE.md', '/a/CLAUDE.md', 'h1'),
      instr('instruction:b/CLAUDE.md', '/b/CLAUDE.md', 'h2'),
    ];
    const groups = computeDriftGroups(assets);
    expect(groups).toHaveLength(1);
    expect(groups[0].workspace).toBe('(未分组)');
  });
});
