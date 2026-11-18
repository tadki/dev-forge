import { useQuery } from '@tanstack/react-query';
import { useEffect, useMemo, useState } from 'react';
import { apiGet } from '../api';
import type { AssetLite, FireEvent } from '../types';
import { Badge, DataTable, Panel, SectionHeader } from '../components/ui';
import type { PageCtx } from './ctx';
import {
  buildRuleFacets,
  HARNESS_LABELS,
  isRuleFilterActive,
  matchesRuleFilters,
  pruneStaleFacets,
  RULE_FACET_KEYS,
  RULE_FACET_LABELS,
  type RuleFacetKey,
  type RuleFilters,
  type RulePayload,
} from './hook-rule-search';

type DetailField = 'harness' | 'on' | 'agents' | 'repo' | 'when' | 'actions' | 'blocking' | 'owner' | 'overlay' | 'versionNote' | 'fileScope' | 'oneshot' | 'status';

const WHEN_KIND_LABELS: Record<string, string> = { none: '无 when', payload: '条件读 hook payload（零 I/O）', ops: '条件使用引擎算子（command/file/content 等）', mixed: 'payload 与引擎算子混用' };

function WhenBadges({ p }: { p: RulePayload }) {
  const kind = p.whenKind;
  if (kind === 'none' || !kind) return <span className="dim">—</span>;
  const badges = kind === 'payload' ? [['PAYLOAD', 'off'] as const] : kind === 'ops' ? [['OPS', 'plain'] as const] : [['PAYLOAD', 'off'], ['OPS', 'plain']] as const;
  return (
    <span style={{ display: 'inline-flex', gap: 4 }}>
      {badges.map(([b, tone]) => <Badge key={b} tone={tone} title={WHEN_KIND_LABELS[kind]}>{b}</Badge>)}
    </span>
  );
}

/* 表格列与详情栏共用的徽章渲染：两处必须同源，避免样式漂移 */
function AgentBadge({ p }: { p: RulePayload }) {
  const g = p.agents;
  return g?.include?.length
    ? <Badge tone="ok">{g.include.join(',')}</Badge>
    : g?.except?.length
      ? <Badge tone="warn">except {g.except.join(',')}</Badge>
      : <Badge title="无 agent 门控">all</Badge>;
}

function RepoBadge({ p }: { p: RulePayload }) {
  const g = p.repoGating;
  if (g?.in?.length) return <Badge tone="ok" title="仓库门控：repos.json 注册表 origin 作用域">{g.in.join(',')}</Badge>;
  if (g?.registered) return <Badge tone="ok" title="仓库门控：任意已注册仓库">registered</Badge>;
  return <Badge title="无仓库门控（作用域不限仓库）">all</Badge>;
}

function scriptNamesOf(p: RulePayload): string[] {
  return p.actions?.filter((a) => a.op === 'run_script').map((a) => (a.path ?? '').split('/').pop()).filter((x): x is string => !!x) ?? [];
}

function ActionBadge({ p }: { p: RulePayload }) {
  const acts = p.actions ?? [];
  if (!acts.length) return <span className="dim">—</span>;
  const ops = acts.map((a) => a.op);
  const label = ops.map((o) => (o === 'run_script' ? 'SCRIPT' : o.toUpperCase())).join('+');
  return ops.includes('deny') ? <Badge tone="bad">{label}</Badge> : ops.includes('context') ? <Badge tone="plain">{label}</Badge> : <Badge>{label}</Badge>;
}

function ScriptView({ path }: { path?: string }) {
  const base = (path ?? '').split('/').pop() ?? '';
  const q = useQuery({
    queryKey: ['hook-script-content', base],
    queryFn: () => apiGet<{ asset: AssetLite }>(`/api/assets/hook-script%3A${base}`),
    enabled: !!base,
  });
  if (!base) return <div className="dim">动作未声明脚本路径</div>;
  const a = q.data?.asset;
  const content = (a?.payload as { content?: string } | undefined)?.content;
  if (q.isLoading) return <div className="dim">读取脚本…</div>;
  if (!a || typeof content !== 'string') return <div className="dim">未找到脚本资产 hook-script:{base}（脚本可能已被移除）</div>;
  return <pre className="code">{content}</pre>;
}

function FieldDetail({ p, field }: { p: RulePayload; field: DetailField }) {
  switch (field) {
    case 'when':
      // 左栏「条件 WHEN」行已是 whenHuman 翻译投影；这里只放算子原文，避免同一内容写两遍
      return (
        <>
          <div className="dim">{WHEN_KIND_LABELS[p.whenKind ?? 'none']}</div>
          <pre className="code">{p.when ? JSON.stringify(p.when, null, 2) : '—（无 when，事件即触发）'}</pre>
        </>
      );
    case 'actions':
      return (
        <>
          {(p.actions ?? []).map((a, i) => (
            <div key={i} style={{ marginBottom: 6 }}>
              <Badge tone={a.op === 'deny' ? 'bad' : a.op === 'context' ? 'plain' : undefined}>{a.op === 'run_script' ? 'SCRIPT' : a.op.toUpperCase()}</Badge>
              {a.message && <div className="dim" style={{ marginTop: 2 }}>{a.message}</div>}
            </div>
          ))}
          {(p.actions ?? []).filter((a) => a.op === 'run_script').map((a, i) => (
            <ScriptView key={`s${i}`} path={a.path} />
          ))}
          {!p.actions?.length && <div className="dim">—</div>}
        </>
      );
    case 'agents':
      return p.agents?.include?.length
        ? <span className="mono">include {p.agents.include.join(', ')}</span>
        : p.agents?.except?.length
          ? <span className="mono">except {p.agents.except.join(', ')}</span>
          : <span className="dim">不限</span>;
    case 'repo':
      return p.repoGating?.in?.length
        ? <span className="mono">{p.repoGating.in.join(', ')}</span>
        : p.repoGating?.registered
          ? <span>任意已注册仓库（repos.json）</span>
          : <span className="dim">不限仓库</span>;
    case 'versionNote':
      return <div className="dim">{p.versionNote}</div>;
    case 'fileScope':
      return <div className="dim">{p.fileDeclaredScope}</div>;
    default:
      return null;
  }
}

function RuleDetail({ rule }: { rule: AssetLite }) {
  const p = rule.payload as RulePayload;
  const [sel, setSel] = useState<DetailField | null>(null);
  const hasBlocking = !!(p.blocking || p.actions?.some((a) => a.op === 'deny'));
  const hasAgents = !!(p.agents?.include?.length || p.agents?.except?.length);
  const hasRepo = !!(p.repoGating?.in?.length || p.repoGating?.registered);
  const hasActions = !!p.actions?.length;

  const rows: Array<{ key: DetailField; label: string; inline: React.ReactNode; selectable?: boolean }> = [
    { key: 'status', label: '状态', inline: <Badge tone={rule.enabled ? 'ok' : 'off'}>{rule.enabled ? '启用' : '停用'}</Badge> },
    { key: 'harness', label: '生效 HARNESS', inline: p.harness?.length
      ? <span style={{ display: 'inline-flex', gap: 4, flexWrap: 'wrap' }}>{p.harness.map((h) => <Badge key={h} tone="plain" title={`生效 harness：${h}`}>{HARNESS_LABELS[h] ?? h}</Badge>)}</span>
      : <span className="dim">—</span> },
    { key: 'on', label: '事件 ON', inline: <span className="mono dim">{(p.on ?? []).join(',')}{p.onExcept?.length ? ` （除 ${p.onExcept.join('/')}）` : ''}</span> },
    { key: 'agents', label: 'AGENT 门控', inline: <AgentBadge p={p} />, selectable: hasAgents },
    { key: 'repo', label: 'REPO 门控', inline: <RepoBadge p={p} />, selectable: hasRepo },
    { key: 'when', label: '条件 WHEN', inline: <span style={{ display: 'inline-flex', gap: 6, alignItems: 'center' }}><WhenBadges p={p} /><span className="dim">{p.whenHuman?.slice(0, 40)}</span></span>, selectable: true },
    { key: 'actions', label: '动作 ACTION', inline: <span style={{ display: 'inline-flex', gap: 4, flexWrap: 'wrap', alignItems: 'center' }}><ActionBadge p={p} />{scriptNamesOf(p).map((s) => <span key={s} className="mono dim" title={`run_script → ${s}`}>{s}</span>)}</span>, selectable: hasActions },
    { key: 'oneshot', label: '单发 ONE-SHOT', inline: <span className="mono dim">{p.oneShot}</span> },
    { key: 'blocking', label: '阻断 BLOCKING', inline: hasBlocking ? <Badge tone="bad" title="deny 动作或脚本动态拦截会阻断工具调用">✓</Badge> : <span className="dim">—</span> },
    { key: 'owner', label: 'Owner', inline: rule.owner ? <span className="mono dim">{rule.owner}</span> : <span className="dim">—</span> },
    { key: 'overlay', label: '来源', inline: <span className="dim">{p.overlay ? 'rules.d 覆盖层' : 'rules-v2 主表'}</span> },
    { key: 'versionNote', label: '版本注记', inline: p.versionNote ? <span className="dim">{p.versionNote.slice(0, 30)}…</span> : <span className="dim">—</span>, selectable: !!p.versionNote },
    { key: 'fileScope', label: '文件级作用域', inline: p.fileDeclaredScope ? <span className="dim">{p.fileDeclaredScope.slice(0, 30)}…</span> : <span className="dim">—</span>, selectable: !!p.fileDeclaredScope },
  ];

  const selected = rows.find((r) => r.key === sel);
  return (
    <Panel title={`规则详情 · ${rule.name}`} en="RULE DETAIL">
      <div className="rule-detail-body">
        <div className="rule-detail-split">
          <div className="rule-fields" role="listbox" aria-label="规则字段">
            {rows.map((r) => (
              <div
                key={r.key}
                role={r.selectable ? 'option' : undefined}
                aria-selected={r.selectable ? sel === r.key : undefined}
                tabIndex={r.selectable ? 0 : undefined}
                className={`rule-field${r.selectable ? ' is-selectable' : ''}${sel === r.key ? ' is-active' : ''}`}
                onClick={r.selectable ? () => setSel(r.key) : undefined}
                onKeyDown={r.selectable ? (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); setSel(r.key); } } : undefined}
              >
                <span className="rule-field-label">{r.label}</span>
                <span className="rule-field-value">{r.inline}</span>
                <span className="rule-field-go" aria-hidden>{r.selectable ? '›' : ''}</span>
              </div>
            ))}
          </div>
          <div className="rule-detail-pane">
            {selected
              ? <><div className="panel-title" style={{ fontSize: 'var(--fs-l1)' }}>{selected.label}</div><FieldDetail p={p} field={selected.key} /></>
              : <div className="dim">点击左栏可切换的字段，这里显示该字段详情（算子原文在「条件 WHEN」，脚本内容在「动作 ACTION」）</div>}
          </div>
        </div>
      </div>
    </Panel>
  );
}

export function HooksPage(_props: { ctx: PageCtx }) {
  const rules = useQuery({ queryKey: ['assets', 'hook-rule'], queryFn: () => apiGet<{ assets: AssetLite[] }>('/api/assets?kind=hook-rule') });
  const scripts = useQuery({ queryKey: ['assets', 'hook-script'], queryFn: () => apiGet<{ assets: AssetLite[] }>('/api/assets?kind=hook-script') });
  const regs = useQuery({ queryKey: ['assets', 'hook-registration'], queryFn: () => apiGet<{ assets: AssetLite[] }>('/api/assets?kind=hook-registration') });
  const [selRule, setSelRule] = useState<string | null>(null);
  const activity = useQuery({
    queryKey: ['activity'],
    queryFn: () => apiGet<{ asset: AssetLite }>('/api/assets/custom%3Aactivity-feed'),
    refetchInterval: 8000,
    select: (d) => (d.asset.payload as { events?: FireEvent[] } | undefined)?.events ?? [],
  });

  const ruleRows = rules.data?.assets ?? [];
  const [nameQuery, setNameQuery] = useState('');
  const [facets, setFacets] = useState<Partial<Record<RuleFacetKey, string>>>({});
  const filters: RuleFilters = useMemo(() => ({ nameQuery, facets }), [nameQuery, facets]);
  const facetOptions = useMemo(() => buildRuleFacets(ruleRows), [ruleRows]);
  const filteredRows = useMemo(() => ruleRows.filter((r) => matchesRuleFilters(r, filters)), [ruleRows, filters]);
  const selected = ruleRows.find((r) => r.id === selRule);

  // watch 重采集后候选值可能消失：清掉失效选中值，受控 select 回到「全部」
  useEffect(() => {
    setFacets((prev) => {
      const next = pruneStaleFacets(prev, facetOptions);
      return RULE_FACET_KEYS.every((k) => prev[k] === next[k]) ? prev : next;
    });
  }, [facetOptions]);

  const setFacet = (key: RuleFacetKey, value: string) =>
    setFacets((prev) => {
      const next = { ...prev };
      if (value) next[key] = value;
      else delete next[key];
      return next;
    });

  const facetControl = (key: RuleFacetKey) => (
    <select
      className="search"
      aria-label={`筛选 ${RULE_FACET_LABELS[key]}`}
      title={`分类筛选：该字段全部取值（含计数）`}
      value={facets[key] ?? ''}
      onChange={(e) => setFacet(key, e.target.value)}
    >
      <option value="">全部</option>
      {facetOptions[key].map((o) => (
        <option key={o.value} value={o.value}>
          {o.label} · {o.count}
        </option>
      ))}
    </select>
  );

  return (
    <div>
      <div className="page-head">
        <div>
          <h2>钩子</h2>
          <div className="sub tagline">HOOKS · {regs.data?.assets.length ?? 0} 挂载 → {ruleRows.length} 规则 · {scripts.data?.assets.length ?? 0} 脚本</div>
        </div>
      </div>

      <div className="pipeline">
        {['CC 9 挂载点', 'hook-wrapper.sh', 'dispatcher.sh', 'engine.js', 'rules-v2 + rules.d', 'scripts/'].map((n, i, arr) => (
          <div key={n} style={{ display: 'flex', alignItems: 'center' }}>
            <div className="pipe-node">{n}</div>
            {i < arr.length - 1 && <span className="pipe-arrow">→</span>}
          </div>
        ))}
      </div>

      <SectionHeader
        no="01"
        title="规则表"
        en={`RULES · ${isRuleFilterActive(filters) ? `${filteredRows.length} / ${ruleRows.length}` : ruleRows.length} · 点击行 → 右栏详情`}
      />
      <div className="split-rules">
      <DataTable
        rows={filteredRows}
        selectedId={selRule ?? undefined}
        onRowClick={(r) => setSelRule(r.id)}
        filters={{
          name: (
            <input
              className="search"
              aria-label="筛选 名称"
              placeholder="筛选名称…"
              title="启发式过滤：空格分词 AND，子串命中名称（大小写不敏感）"
              value={nameQuery}
              onChange={(e) => setNameQuery(e.target.value)}
            />
          ),
          harness: facetControl('harness'),
          on: facetControl('on'),
          agent: facetControl('agent'),
          repo: facetControl('repo'),
          when: facetControl('when'),
          action: facetControl('action'),
          oneshot: facetControl('oneshot'),
        }}
        cols={[
          {
            key: 'name',
            head: '名称 NAME',
            render: (r) => (
              <span style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                <Badge tone={r.enabled ? 'ok' : 'off'} title={r.enabled ? '已启用' : '已停用'}>{r.enabled ? '●' : '○'}</Badge>
                <span className="mono">{r.name}</span>
              </span>
            ),
          },
          {
            key: 'harness',
            head: '生效 HARNESS',
            render: (r) => {
              const hs = (r.payload as RulePayload).harness ?? [];
              if (!hs.length) return <span className="dim">—</span>;
              return (
                <span style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
                  {hs.map((h) => (
                    <Badge key={h} tone="plain" title={`生效 harness：${h}`}>{HARNESS_LABELS[h] ?? h}</Badge>
                  ))}
                </span>
              );
            },
          },
          { key: 'on', head: '事件 ON', render: (r) => <span className="mono dim">{((r.payload as RulePayload).on ?? []).join(',')}</span> },
          {
            key: 'agent',
            head: 'AGENT 门控',
            render: (r) => <AgentBadge p={r.payload as RulePayload} />,
          },
          {
            key: 'repo',
            head: 'REPO 门控',
            render: (r) => <RepoBadge p={r.payload as RulePayload} />,
          },
          {
            key: 'when',
            head: '条件 WHEN',
            render: (r) => {
              const kind = (r.payload as RulePayload).whenKind;
              const badges = kind === 'payload' ? [['PAYLOAD', 'off'] as const] : kind === 'ops' ? [['OPS', 'plain'] as const] : kind === 'mixed' ? ([['PAYLOAD', 'off'], ['OPS', 'plain']] as const) : [];
              if (!badges.length) return <span className="dim">—</span>;
              return (
                <>
                  {badges.map(([b, tone]) => (
                    <Badge key={b} tone={tone} title={b === 'PAYLOAD' ? '条件读 hook payload（零 I/O）' : '条件使用引擎算子（command/file/content 等）'}>{b}</Badge>
                  ))}
                </>
              );
            },
          },
          {
            key: 'action',
            head: '动作 ACTION',
            render: (r) => <ActionBadge p={r.payload as RulePayload} />,
          },
          { key: 'oneshot', head: '单发 ONE-SHOT', render: (r) => <span className="mono dim">{(r.payload as RulePayload).oneShot}</span> },
        ]}
      />
      <aside>
        {selected ? (
          <RuleDetail rule={selected} />
        ) : (
          <Panel title="规则详情" en="RULE DETAIL">
            <div className="dim">点击左侧规则行，这里显示该条钩子的完整定义</div>
          </Panel>
        )}
      </aside>
      </div>

      <div className="grid grid-2 mt">
        <Panel title="挂载脚本" en={`MOUNTED SCRIPTS · ${scripts.data?.assets.length ?? 0}`}>
          <div style={{ maxHeight: 300, overflow: 'auto' }}>
            {(scripts.data?.assets ?? []).map((s) => (
              <div key={s.id} className="row" style={{ padding: '2px 0', fontSize: 'var(--fs-l1)' }}>
                <span className="mono" style={{ minWidth: 220 }}>{s.name}</span>
                <span className="dim">{s.summary.slice(0, 70)}</span>
                {s.attach.level === 'project' && <Badge tone="plain">{s.attach.ref?.split('/').pop()}</Badge>}
              </div>
            ))}
          </div>
        </Panel>
        <section className="panel-ink">
          <div className="panel-title">
            FIRE LOG 实时 <span className="en" style={{ color: 'var(--khaki)' }}>TAIL · SSE</span>
          </div>
          <div style={{ maxHeight: 300, overflow: 'auto' }}>
            {(activity.data ?? []).slice(0, 60).map((ev, i) => (
              <div key={i} className="log-line">
                <span className="log-ts">{ev.ts.slice(11, 19)}</span>
                <span style={{ color: 'var(--khaki)', minWidth: 60 }}>{ev.agent ?? 'human'}</span>
                <span>{ev.event}</span>
                <span className={ev.action === 'deny' ? 'log-bad' : ev.action && ev.action !== 'none' ? 'log-warn' : ''}>{ev.action}</span>
              </div>
            ))}
          </div>
        </section>
      </div>
    </div>
  );
}
