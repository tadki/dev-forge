import { describe, expect, it } from 'vitest';
import type { Asset } from '@forge/schema';
import { resolveEffective } from './effective.js';

function base(id: string, kind: Asset['kind'], over: Partial<Asset> = {}): Asset {
  return {
    id,
    kind,
    name: id.split(':')[1] ?? id,
    summary: '',
    attach: { level: 'user' },
    enforcement: 'enforced',
    platforms: ['claude-code'],
    provenance: 'first-party',
    tags: [],
    enabled: true,
    source: { collector: 'test', path: `/tmp/${id}` },
    payload: {},
    ...over,
  };
}

const project = base('project:king-of-likes', 'project', {
  attach: { level: 'project', ref: '/mnt/d/GodotProjects/king-of-likes' },
  payload: { path: '/mnt/d/GodotProjects/king-of-likes', workspace: 'kol', workspaceName: 'King of Likes' },
});

const fronti = base('agent:multica-fronti', 'agent', {
  name: 'Fronti',
  attach: { level: 'platform', ref: 'multica' },
  payload: { platformId: 'f-1', model: 'agent-fronti[1m]', thinkingLevel: 'max', customEnvKeyCount: 3, instructions: 'You are Fronti…', skills: [{ name: 'code-review' }, { name: 'recall' }] },
});

const kolMd = base('instruction:king-of-likes/CLAUDE.md', 'instruction', {
  attach: { level: 'project', ref: '/mnt/d/GodotProjects/king-of-likes' },
  applies: { workspaces: ['kol'], origin: 'native' },
  payload: { basename: 'CLAUDE.md', lines: 144, content: '# KOL' },
});

const ruleForFronti = base('hook-rule:fronti-gate', 'hook-rule', {
  applies: { agents: { include: ['Fronti'] }, origin: 'native' },
});
const ruleForRevy = base('hook-rule:revy-gate', 'hook-rule', {
  applies: { agents: { include: ['Revy'] }, origin: 'native' },
});
const ruleGlobal = base('hook-rule:global-gate', 'hook-rule', {});

const assets = [
  project,
  fronti,
  kolMd,
  ruleForFronti,
  ruleForRevy,
  ruleGlobal,
  base('skill:user-recall', 'skill', { name: 'recall' }),
  base('skill:ecc-foo', 'skill', { provenance: 'third-party' }),
  base('mcp-endpoint:project-kol-godot-mcp', 'mcp-endpoint', { name: 'godot-mcp', attach: { level: 'project', ref: '/mnt/d/GodotProjects/king-of-likes' } }),
  base('mcp-endpoint:multica-fronti-hindsight', 'mcp-endpoint', { name: 'hindsight（Fronti）', attach: { level: 'agent', ref: 'Fronti' } }),
];

describe('resolveEffective', () => {
  it('resolves project + agent with gated rules counted', () => {
    const eff = resolveEffective(assets, [], 'king-of-likes', 'Fronti');
    expect(eff.project.workspace).toBe('kol');
    expect(eff.agent?.platform).toBe('multica');
    const hooks = eff.sections.find((s) => s.id === 'hooks')!;
    expect(hooks.items[1].detail).toContain('2/3'); // fronti-gate + global-gate 命中
    const mcp = eff.sections.find((s) => s.id === 'mcp')!;
    expect(mcp.items.map((i) => i.label)).toContain('godot-mcp');
    expect(mcp.items.map((i) => i.label)).toContain('hindsight（Fronti）');
  });

  it('agent gating excludes non-matching agents', () => {
    const eff = resolveEffective(assets, [], 'king-of-likes', 'Revy');
    const hooks = eff.sections.find((s) => s.id === 'hooks')!;
    expect(hooks.items[1].detail).toContain('2/3');
  });

  it('human session (no agent) passes all gates', () => {
    const eff = resolveEffective(assets, [], 'king-of-likes');
    const hooks = eff.sections.find((s) => s.id === 'hooks')!;
    expect(hooks.items[1].detail).toContain('3/3');
  });

  it('includes CLAUDE.md and platform skills for Fronti', () => {
    const eff = resolveEffective(assets, [], 'king-of-likes', 'Fronti');
    const ins = eff.sections.find((s) => s.id === 'instructions')!;
    expect(ins.items.some((i) => i.label === '项目 CLAUDE.md')).toBe(true);
    const skills = eff.sections.find((s) => s.id === 'skills')!;
    expect(skills.items.some((i) => i.label === 'multica 平台技能（物化进 workdir）')).toBe(true);
  });
});
