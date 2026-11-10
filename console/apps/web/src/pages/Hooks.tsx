import { useQuery } from '@tanstack/react-query';
import { useMemo, useState } from 'react';
import { apiGet } from '../api';
import type { AssetLite, FireEvent } from '../types';
import { Badge, DataTable, Panel, SectionHeader } from '../components/ui';
import type { PageCtx } from './ctx';
import {
  buildRuleFacets,
  HARNESS_LABELS,
  isRuleFilterActive,
  matchesRuleFilters,
  type RuleFacetKey,
  type RuleFilters,
  type RulePayload,
} from './hook-rule-search';

function RuleDetail({ rule }: { rule: AssetLite }) {
  const p = rule.payload as RulePayload;
  return (
    <Panel title={`规则详情 · ${rule.name}`} en="RULE DETAIL">
      <div className="rule-detail-body">
      <div className="kv kv-tight">
        <dt>状态</dt>
        <dd><Badge tone={rule.enabled ? 'ok' : 'off'}>{rule.enabled ? '启用' : '停用'}</Badge></dd>
        <dt>HARNESS</dt>
        <dd>
          {p.harness?.length
            ? p.harness.map((h) => <Badge key={h} tone="plain" title={`生效 harness：${h}`}>{HARNESS_LABELS[h] ?? h}</Badge>)
            : <span className="dim">—</span>}
        </dd>
        <dt>事件 ON</dt>
        <dd className="mono dim">{(p.on ?? []).join(',')}{p.onExcept?.length ? ` （除 ${p.onExcept.join('/')}）` : ''}</dd>
        <dt>AGENT 门控</dt>
        <dd>
          {p.agents?.include
            ? <span className="mono">{p.agents.include.join(', ')}</span>
            : p.agents?.except
              ? <span className="mono dim">except {p.agents.except.join(', ')}</span>
              : <span className="dim">不限</span>}
        </dd>
        <dt>REPO 门控</dt>
        <dd>
          {p.repoGating?.in?.length
            ? <span className="mono">{p.repoGating.in.join(', ')}</span>
            : p.repoGating?.registered
              ? '已注册仓库'
              : <span className="dim">不限仓库</span>}
        </dd>
        <dt>单发</dt>
        <dd className="mono dim">{p.oneShot}</dd>
        {p.blocking && (
          <>
            <dt>阻断</dt>
            <dd><Badge tone="bad" title="DENY 动作会拦截工具调用">BLOCKING</Badge></dd>
          </>
        )}
        {rule.owner && (
          <>
            <dt>Owner</dt>
            <dd className="mono dim">{rule.owner}</dd>
          </>
        )}
      </div>
      <div className="kv kv-tight" style={{ marginTop: 8 }}>
        <dt>when 投影</dt>
        <dd>{p.whenHuman}</dd>
        <dt>来源</dt>
        <dd className="dim">{p.overlay ? 'rules.d 覆盖层' : 'rules-v2 主表'}</dd>
        {p.versionNote && (
          <>
            <dt>版本注记</dt>
            <dd className="dim">{p.versionNote}</dd>
          </>
        )}
        {p.fileDeclaredScope && (
          <>
            <dt>文件级作用域</dt>
            <dd className="dim">{p.fileDeclaredScope}</dd>
          </>
        )}
        <dt>源文件</dt>
        <dd className="mono dim">{rule.source.path}</dd>
      </div>
      <pre className="code">{JSON.stringify(p.actions, null, 2)}</pre>
      <pre className="code">{JSON.stringify(p.when, null, 2)}</pre>
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
      aria-label={`筛选 ${key}`}
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
        filters={[
          <input
            key="name"
            className="search"
            aria-label="筛选 名称"
            placeholder="筛选名称…"
            title="启发式过滤：空格分词 AND，子串命中名称（大小写不敏感）"
            value={nameQuery}
            onChange={(e) => setNameQuery(e.target.value)}
          />,
          facetControl('harness'),
          facetControl('on'),
          facetControl('agent'),
          facetControl('repo'),
          facetControl('when'),
          facetControl('action'),
          facetControl('oneshot'),
        ]}
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
            render: (r) => {
              const g = (r.payload as RulePayload).agents;
              return g?.include ? <Badge tone="ok">{g.include.join(',')}</Badge> : g?.except ? <Badge tone="warn">except {g.except.join(',')}</Badge> : <Badge title="无 agent 门控">all</Badge>;
            },
          },
          {
            key: 'repo',
            head: 'REPO 门控',
            render: (r) => {
              const g = (r.payload as RulePayload).repoGating;
              if (g?.in?.length) return <Badge tone="ok" title="仓库门控：repos.json 注册表 origin 作用域">{g.in.join(',')}</Badge>;
              if (g?.registered) return <Badge tone="ok" title="仓库门控：任意已注册仓库">registered</Badge>;
              return <Badge title="无仓库门控（作用域不限仓库）">all</Badge>;
            },
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
            render: (r) => {
              const acts = (r.payload as RulePayload).actions ?? [];
              const ops = acts.map((a) => a.op);
              if (!ops.length) return <span className="dim">—</span>;
              const label = ops.map((o) => (o === 'run_script' ? 'SCRIPT' : o.toUpperCase())).join('+');
              return ops.includes('deny') ? <Badge tone="bad">{label}</Badge> : ops.includes('context') ? <Badge tone="plain">{label}</Badge> : <Badge>{label}</Badge>;
            },
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
