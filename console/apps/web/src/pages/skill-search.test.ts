import { describe, expect, it } from 'vitest';
import type { AssetLite } from '../types';
import { matchesSkillQuery } from './skill-search.js';

function skill(over: Partial<AssetLite> = {}): AssetLite {
  return {
    id: 'skill:user-demo',
    kind: 'skill',
    name: 'demo',
    summary: 'a demo skill for testing',
    attach: { level: 'user' },
    enforcement: 'advisory',
    platforms: ['claude-code'],
    provenance: 'third-party',
    tags: ['skill', 'global'],
    enabled: true,
    source: { collector: 'claude-global', path: '/home/jerry/.claude/skills/demo/SKILL.md' },
    payload: {},
    ...over,
  };
}

describe('matchesSkillQuery', () => {
  it('空查询恒真', () => {
    const s = skill();
    expect(matchesSkillQuery(s, '')).toBe(true);
    expect(matchesSkillQuery(s, '   ')).toBe(true);
  });

  it('名称与摘要子串命中（大小写不敏感）', () => {
    expect(matchesSkillQuery(skill({ name: 'Deep-Research' }), 'research')).toBe(true);
    expect(matchesSkillQuery(skill(), 'DEMO SKILL')).toBe(true);
    expect(matchesSkillQuery(skill(), 'nonexistent')).toBe(false);
  });

  it('路径/平台/标签/id 均参与匹配', () => {
    expect(matchesSkillQuery(skill(), '.claude/skills')).toBe(true);
    expect(matchesSkillQuery(skill(), 'claude-code')).toBe(true);
    expect(matchesSkillQuery(skill(), 'global')).toBe(true);
    expect(matchesSkillQuery(skill(), 'skill:user-demo')).toBe(true);
  });

  it('多词 AND：全部词命中才通过', () => {
    expect(matchesSkillQuery(skill(), 'demo global')).toBe(true);
    expect(matchesSkillQuery(skill(), 'demo multica')).toBe(false);
  });

  it('attach 归属参与匹配', () => {
    expect(matchesSkillQuery(skill({ attach: { level: 'project', ref: '/repos/foo' } }), 'foo')).toBe(true);
  });
});
