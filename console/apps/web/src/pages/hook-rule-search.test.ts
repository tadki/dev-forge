import { describe, expect, it } from 'vitest';
import type { AssetLite } from '../types';
import {
  buildRuleFacets,
  isRuleFilterActive,
  matchesRuleFilters,
  matchesRuleNameQuery,
  pruneStaleFacets,
  ruleFacetLabel,
  ruleFacetValues,
  type RulePayload,
} from './hook-rule-search.js';

function payload(over: Partial<RulePayload> = {}): RulePayload {
  return {
    harness: ['claude-code'],
    on: ['PreToolUse'],
    whenHuman: '—',
    oneShot: '—',
    actions: [{ op: 'context' }],
    overlay: false,
    ...over,
  };
}

function rule(over: Partial<AssetLite> = {}, p: Partial<RulePayload> = {}): AssetLite {
  return {
    id: 'hook-rule:demo',
    kind: 'hook-rule',
    name: 'demo-rule',
    summary: 'CONTEXT · demo',
    attach: { level: 'user' },
    enforcement: 'enforced',
    platforms: ['claude-code'],
    provenance: 'first-party',
    tags: ['devforge'],
    enabled: true,
    source: { collector: 'devforge-hooks', path: '/x/rules-v2.json' },
    payload: payload(p),
    ...over,
  };
}

describe('matchesRuleNameQuery', () => {
  it('空查询恒真', () => {
    expect(matchesRuleNameQuery('demo-rule', '')).toBe(true);
    expect(matchesRuleNameQuery('demo-rule', '   ')).toBe(true);
  });

  it('子串命中，大小写不敏感', () => {
    expect(matchesRuleNameQuery('Push-Guard', 'push')).toBe(true);
    expect(matchesRuleNameQuery('push-guard', 'GUARD')).toBe(true);
    expect(matchesRuleNameQuery('demo-rule', 'missing')).toBe(false);
  });

  it('多词 AND：全部词命中才通过', () => {
    expect(matchesRuleNameQuery('push-guard-gates', 'push gate')).toBe(true);
    expect(matchesRuleNameQuery('push-guard-gates', 'push deny')).toBe(false);
  });
});

describe('ruleFacetValues', () => {
  it('agent 门控：include 逐值、except 加前缀、无门控归 all', () => {
    expect(ruleFacetValues(payload({ agents: { include: ['Revy', 'Atlas'] } }), 'agent')).toEqual(['Revy', 'Atlas']);
    expect(ruleFacetValues(payload({ agents: { except: ['Bachi'] } }), 'agent')).toEqual(['except:Bachi']);
    expect(ruleFacetValues(payload(), 'agent')).toEqual(['all']);
  });

  it('repo 门控：in 逐仓、registered、无门控归 all', () => {
    expect(ruleFacetValues(payload({ repoGating: { in: ['kol', 'dev-forge'] } }), 'repo')).toEqual(['kol', 'dev-forge']);
    expect(ruleFacetValues(payload({ repoGating: { registered: true } }), 'repo')).toEqual(['registered']);
    expect(ruleFacetValues(payload(), 'repo')).toEqual(['all']);
  });

  it('when 取 whenKind，缺省为 none；action 取 op 列表，空归 —', () => {
    expect(ruleFacetValues(payload({ whenKind: 'mixed' }), 'when')).toEqual(['mixed']);
    expect(ruleFacetValues(payload({ whenKind: undefined }), 'when')).toEqual(['none']);
    expect(ruleFacetValues(payload({ actions: [{ op: 'deny' }, { op: 'run_script' }] }), 'action')).toEqual(['deny', 'run_script']);
    expect(ruleFacetValues(payload({ actions: [] }), 'action')).toEqual(['—']);
  });

  it('多值字段逐值参与：on 与 harness', () => {
    expect(ruleFacetValues(payload({ on: ['PreToolUse', 'Stop'] }), 'on')).toEqual(['PreToolUse', 'Stop']);
    expect(ruleFacetValues(payload({ harness: [] }), 'harness')).toEqual(['—']);
  });
});

describe('ruleFacetLabel', () => {
  it('harness/action/when/agent 显示标签映射', () => {
    expect(ruleFacetLabel('harness', 'claude-code')).toBe('Claude Code');
    expect(ruleFacetLabel('action', 'run_script')).toBe('SCRIPT');
    expect(ruleFacetLabel('action', 'notify')).toBe('NOTIFY');
    expect(ruleFacetLabel('when', 'mixed')).toBe('PAYLOAD+OPS');
    expect(ruleFacetLabel('when', 'none')).toBe('—');
    expect(ruleFacetLabel('agent', 'except:Bachi')).toBe('except Bachi');
    expect(ruleFacetLabel('agent', 'Revy')).toBe('Revy');
  });
});

describe('buildRuleFacets', () => {
  it('按字段聚合去重计数，次数降序', () => {
    const rows = [
      rule({ id: 'a', name: 'a' }, { on: ['PreToolUse'], whenKind: 'none' }),
      rule({ id: 'b', name: 'b' }, { on: ['PreToolUse', 'Stop'], whenKind: 'payload' }),
      rule({ id: 'c', name: 'c' }, { on: ['Stop'], whenKind: 'payload' }),
    ];
    const facets = buildRuleFacets(rows);
    expect(facets.on).toEqual([
      { value: 'PreToolUse', label: 'PreToolUse', count: 2 },
      { value: 'Stop', label: 'Stop', count: 2 },
    ]);
    expect(facets.when).toEqual([
      { value: 'payload', label: 'PAYLOAD', count: 2 },
      { value: 'none', label: '—', count: 1 },
    ]);
  });

  it('同一行重复取值只计一次', () => {
    const rows = [rule({ id: 'a' }, { actions: [{ op: 'deny' }, { op: 'deny' }] })];
    expect(buildRuleFacets(rows).action).toEqual([{ value: 'deny', label: 'DENY', count: 1 }]);
  });
});

describe('matchesRuleFilters', () => {
  const target = rule({ name: 'revy-guard' }, { on: ['PreToolUse', 'Stop'], whenKind: 'payload', agents: { include: ['Revy'] } });

  it('全空筛选恒真', () => {
    expect(matchesRuleFilters(target, { nameQuery: '', facets: {} })).toBe(true);
  });

  it('名称启发式与分类面 AND 组合', () => {
    expect(matchesRuleFilters(target, { nameQuery: 'revy', facets: { on: 'Stop' } })).toBe(true);
    expect(matchesRuleFilters(target, { nameQuery: 'revy', facets: { on: 'PostToolUse' } })).toBe(false);
    expect(matchesRuleFilters(target, { nameQuery: 'guard', facets: { when: 'payload' } })).toBe(true);
    expect(matchesRuleFilters(target, { nameQuery: 'guard', facets: { agent: 'Atlas' } })).toBe(false);
    expect(matchesRuleFilters(target, { nameQuery: 'missing', facets: {} })).toBe(false);
  });

  it('多值字段命中任一选中值即通过', () => {
    expect(matchesRuleFilters(target, { nameQuery: '', facets: { on: 'PreToolUse' } })).toBe(true);
    expect(matchesRuleFilters(target, { nameQuery: '', facets: { on: 'Stop' } })).toBe(true);
  });
});

describe('事件 ON 排除语义（on 与 onExcept 一致 ⇒ 排除式定义）', () => {
  // collector：on = rule.on.in ?? rule.on.except，排除式规则的 on 装的是排除值
  const exceptRule = rule({ name: 'except-stop' }, { on: ['Stop'], onExcept: ['Stop'] });
  const bothRule = rule({ name: 'in-and-except' }, { on: ['PreToolUse'], onExcept: ['Stop'] });
  const plainRule = rule({ name: 'plain' }, { on: ['PreToolUse'] });

  it('排除式规则：筛排除事件不命中，筛其他事件命中（规则在其余所有事件上触发）', () => {
    expect(matchesRuleFilters(exceptRule, { nameQuery: '', facets: { on: 'Stop' } })).toBe(false);
    expect(matchesRuleFilters(exceptRule, { nameQuery: '', facets: { on: 'PreToolUse' } })).toBe(true);
  });

  it('in 与 except 并存时按 in 语义匹配（on 数组装的是 in 值）', () => {
    expect(matchesRuleFilters(bothRule, { nameQuery: '', facets: { on: 'PreToolUse' } })).toBe(true);
    expect(matchesRuleFilters(bothRule, { nameQuery: '', facets: { on: 'Stop' } })).toBe(false);
  });

  it('普通规则不受影响；候选值聚合仍包含排除值本身', () => {
    expect(matchesRuleFilters(plainRule, { nameQuery: '', facets: { on: 'PreToolUse' } })).toBe(true);
    expect(buildRuleFacets([exceptRule, plainRule]).on.map((o) => o.value).sort()).toEqual(['PreToolUse', 'Stop']);
  });
});

describe('pruneStaleFacets', () => {
  const options = buildRuleFacets([
    rule({ id: 'a' }, { on: ['PreToolUse'], whenKind: 'ops' }),
    rule({ id: 'b' }, { on: ['Stop'], whenKind: 'none' }),
  ]);

  it('清除不在候选中的选中值，保留仍存在的', () => {
    const facets = { on: 'PreToolUse', when: 'payload', repo: 'kol' } as Partial<Record<string, string>>;
    expect(pruneStaleFacets(facets, options)).toEqual({ on: 'PreToolUse' });
  });

  it('全部有效时原样保留；空筛选恒空', () => {
    expect(pruneStaleFacets({ on: 'Stop', when: 'none' }, options)).toEqual({ on: 'Stop', when: 'none' });
    expect(pruneStaleFacets({}, options)).toEqual({});
  });
});

describe('isRuleFilterActive', () => {
  it('任一字段有值即激活', () => {
    expect(isRuleFilterActive({ nameQuery: '', facets: {} })).toBe(false);
    expect(isRuleFilterActive({ nameQuery: '  ', facets: { repo: 'kol' } })).toBe(true);
    expect(isRuleFilterActive({ nameQuery: 'push', facets: {} })).toBe(true);
  });
});
