import { describe, expect, it } from 'vitest';
import type { AssetLite } from '../types';
import { buildScopeTree, groupByPlatform } from './Instructions';

function asset(over: Partial<AssetLite> & { id: string }): AssetLite {
  return {
    kind: 'instruction',
    name: over.id,
    summary: '',
    attach: { level: 'user' },
    enforcement: 'advisory',
    platforms: ['claude-code'],
    provenance: 'first-party',
    enabled: true,
    source: { collector: 'test', path: '/x' },
    payload: {},
    tags: [],
    ...over,
  };
}

describe('buildScopeTree 作用域树', () => {
  it('第三方 rules 按 payload.group 细分为独立组，平台记在组上', () => {
    const tree = buildScopeTree([
      asset({ id: 'instruction:rules-common-coding-style', provenance: 'third-party', payload: { group: 'common' } }),
      asset({ id: 'instruction:rules-zh-coding-style', provenance: 'third-party', payload: { group: 'zh' } }),
    ]);
    expect(tree).toHaveLength(2);
    expect(tree.map((g) => g.label)).toEqual(['rules/common', 'rules/zh']);
    expect(tree.every((g) => g.thirdParty)).toBe(true);
    expect(tree.every((g) => g.platform === 'claude-code')).toBe(true);
    expect(new Set(tree.map((g) => g.key)).size).toBe(2);
    expect(tree[0].items[0].id).toBe('instruction:rules-common-coding-style');
  });

  it('同一 rules 子目录跨平台分成独立组，平台不互相吞并', () => {
    const tree = buildScopeTree([
      asset({ id: 'instruction:rules-common-agents', provenance: 'third-party', platforms: ['claude-code'], payload: { group: 'common' } }),
      asset({ id: 'instruction:rules-codex-common-agents', provenance: 'third-party', platforms: ['codex'], payload: { group: 'common' } }),
      asset({ id: 'instruction:rules-multi-hooks', provenance: 'third-party', platforms: ['claude-code', 'multica'], payload: { group: 'multi' } }),
    ]);
    expect(tree.map((g) => g.platform).sort()).toEqual(['claude-code', 'claude-code+multica', 'codex']);
  });

  it('groupByPlatform 按平台聚合并统计条目数', () => {
    const tree = buildScopeTree([
      asset({ id: 'instruction:rules-common-a', provenance: 'third-party', platforms: ['claude-code'], payload: { group: 'common' } }),
      asset({ id: 'instruction:rules-zh-a', provenance: 'third-party', platforms: ['claude-code'], payload: { group: 'zh' } }),
      asset({ id: 'instruction:rules-common-b', provenance: 'third-party', platforms: ['codex'], payload: { group: 'common' } }),
    ]);
    const platforms = groupByPlatform(tree.filter((g) => g.thirdParty));
    expect(platforms.map((p) => [p.platform, p.count])).toEqual([
      ['claude-code', 2],
      ['codex', 1],
    ]);
    expect(platforms[0].groups.map((g) => g.label)).toEqual(['rules/common', 'rules/zh']);
  });

  it('自研组排在第三方之前，第三方组殿后', () => {
    const tree = buildScopeTree([
      asset({ id: 'instruction:rules-common-x', provenance: 'third-party', payload: { group: 'common' } }),
      asset({ id: 'instruction:p/CLAUDE.md', attach: { level: 'project', ref: '/mnt/x/king-of-likes' } }),
      asset({ id: 'instruction:user-global' }),
    ]);
    const owned = tree.filter((g) => !g.thirdParty);
    expect(owned).toHaveLength(2);
    expect(tree[tree.length - 1].label).toBe('rules/common');
    expect(tree.slice(0, 2).every((g) => !g.thirdParty)).toBe(true);
  });

  it('项目组按路径末段命名，user 层自研归入「全局」', () => {
    const tree = buildScopeTree([
      asset({ id: 'instruction:p/CLAUDE.md', attach: { level: 'project', ref: '/mnt/d/GodotProjects/king-of-likes' } }),
      asset({ id: 'instruction:user-global' }),
    ]);
    expect(tree.map((g) => g.label)).toContain('项目 · king-of-likes');
    expect(tree.map((g) => g.label)).toContain('全局');
  });
});
