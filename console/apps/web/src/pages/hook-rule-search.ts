import type { AssetLite } from '../types';

export interface RulePayload {
  harness?: string[];
  whenKind?: 'none' | 'payload' | 'ops' | 'mixed';
  on: string[];
  onExcept?: string[];
  whenHuman: string;
  oneShot: string;
  when?: unknown;
  actions: Array<{ op: string; message?: string; path?: string }>;
  overlay: boolean;
  blocking?: boolean;
  versionNote?: string;
  fileDeclaredScope?: string;
  agents?: { include?: string[]; except?: string[] };
  repoGating?: { in?: string[]; registered?: boolean };
}

export const HARNESS_LABELS: Record<string, string> = { 'claude-code': 'Claude Code' };

/** 枚举型字段：取值集合小且可枚举，用分类筛选（下拉选值） */
export type RuleFacetKey = 'harness' | 'on' | 'agent' | 'repo' | 'when' | 'action' | 'oneshot';

export const RULE_FACET_KEYS: RuleFacetKey[] = ['harness', 'on', 'agent', 'repo', 'when', 'action', 'oneshot'];

const ACTION_LABELS: Record<string, string> = { deny: 'DENY', context: 'CONTEXT', run_script: 'SCRIPT' };

const WHEN_LABELS: Record<string, string> = { none: '—', payload: 'PAYLOAD', ops: 'OPS', mixed: 'PAYLOAD+OPS' };

const EXCEPT_PREFIX = 'except:';

/** 字段在单行上的取值集合：多值字段（harness/on/action/agent include）逐值参与匹配 */
export function ruleFacetValues(p: RulePayload, key: RuleFacetKey): string[] {
  switch (key) {
    case 'harness':
      return p.harness?.length ? p.harness : ['—'];
    case 'on':
      return p.on?.length ? p.on : ['—'];
    case 'agent':
      if (p.agents?.include?.length) return p.agents.include;
      if (p.agents?.except?.length) return p.agents.except.map((a) => `${EXCEPT_PREFIX}${a}`);
      return ['all'];
    case 'repo':
      if (p.repoGating?.in?.length) return p.repoGating.in;
      if (p.repoGating?.registered) return ['registered'];
      return ['all'];
    case 'when':
      return [p.whenKind ?? 'none'];
    case 'action':
      return p.actions?.length ? p.actions.map((a) => a.op) : ['—'];
    case 'oneshot':
      return [p.oneShot || '—'];
  }
}

export function ruleFacetLabel(key: RuleFacetKey, value: string): string {
  switch (key) {
    case 'harness':
      return HARNESS_LABELS[value] ?? value;
    case 'agent':
      return value.startsWith(EXCEPT_PREFIX) ? `except ${value.slice(EXCEPT_PREFIX.length)}` : value;
    case 'when':
      return WHEN_LABELS[value] ?? value;
    case 'action':
      return ACTION_LABELS[value] ?? value.toUpperCase();
    default:
      return value;
  }
}

export interface RuleFacetOption {
  value: string;
  label: string;
  count: number;
}

/** 从全量规则派生每个枚举字段的候选值（计数为命中行数，按次数降序） */
export function buildRuleFacets(rows: AssetLite[]): Record<RuleFacetKey, RuleFacetOption[]> {
  const acc: Record<RuleFacetKey, Map<string, number>> = {
    harness: new Map(),
    on: new Map(),
    agent: new Map(),
    repo: new Map(),
    when: new Map(),
    action: new Map(),
    oneshot: new Map(),
  };
  for (const row of rows) {
    const p = row.payload as RulePayload;
    for (const key of RULE_FACET_KEYS) {
      for (const v of new Set(ruleFacetValues(p, key))) {
        acc[key].set(v, (acc[key].get(v) ?? 0) + 1);
      }
    }
  }
  const out = {} as Record<RuleFacetKey, RuleFacetOption[]>;
  for (const key of RULE_FACET_KEYS) {
    out[key] = [...acc[key].entries()]
      .map(([value, count]) => ({ value, label: ruleFacetLabel(key, value), count }))
      .sort((a, b) => b.count - a.count || a.label.localeCompare(b.label));
  }
  return out;
}

/** 名称启发式过滤：空格分词 AND，子串命中即通过；大小写不敏感；空查询恒真。 */
export function matchesRuleNameQuery(name: string, query: string): boolean {
  const tokens = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (tokens.length === 0) return true;
  const hay = name.toLowerCase();
  return tokens.every((t) => hay.includes(t));
}

export interface RuleFilters {
  nameQuery: string;
  facets: Partial<Record<RuleFacetKey, string>>;
}

/** 各字段之间 AND；同一字段内多值行命中任一选中值即算命中 */
export function matchesRuleFilters(rule: AssetLite, filters: RuleFilters): boolean {
  if (!matchesRuleNameQuery(rule.name, filters.nameQuery)) return false;
  const p = rule.payload as RulePayload;
  for (const key of RULE_FACET_KEYS) {
    const selected = filters.facets[key];
    if (selected && !ruleFacetValues(p, key).includes(selected)) return false;
  }
  return true;
}

export function isRuleFilterActive(filters: RuleFilters): boolean {
  return filters.nameQuery.trim() !== '' || RULE_FACET_KEYS.some((key) => !!filters.facets[key]);
}
