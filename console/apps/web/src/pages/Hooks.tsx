import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { apiGet } from '../api';
import type { AssetLite, FireEvent } from '../types';
import { Badge, DataTable, Panel, SectionHeader } from '../components/ui';
import type { PageCtx } from './ctx';

interface RulePayload {
  harness?: string[];
  on: string[];
  whenHuman: string;
  oneShot: string;
  actions: Array<{ op: string; message?: string }>;
  overlay: boolean;
  agents?: { include?: string[]; except?: string[] };
}

const HARNESS_LABELS: Record<string, string> = { 'claude-code': 'Claude Code' };

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
  const selected = ruleRows.find((r) => r.id === selRule);

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

      <SectionHeader no="01" title="规则表" en={`RULES · ${ruleRows.length} · when 条件 → 人话投影`} />
      <DataTable
        rows={ruleRows}
        selectedId={selRule ?? undefined}
        onRowClick={(r) => setSelRule(r.id)}
        cols={[
          { key: 'name', head: '名称 NAME', render: (r) => <span className="mono">{r.name}</span> },
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
              return g?.include ? <Badge tone="ok">{g.include.join(',')}</Badge> : g?.except ? <Badge tone="warn">except {g.except.join(',')}</Badge> : <span className="dim">全部</span>;
            },
          },
          { key: 'when', head: '条件 WHEN（投影）', render: (r) => <span className="mono dim" style={{ fontSize: 'var(--fs-label)' }}>{(r.payload as RulePayload).whenHuman}</span> },
          {
            key: 'action',
            head: '动作 ACTION',
            render: (r) => {
              const ops = (r.payload as RulePayload).actions?.map((a) => a.op) ?? [];
              return ops.includes('deny') ? <Badge tone="bad">DENY</Badge> : ops.includes('context') ? <Badge tone="plain">CONTEXT</Badge> : <Badge>{ops.join('+')}</Badge>;
            },
          },
          { key: 'oneshot', head: '单发 ONE-SHOT', render: (r) => <span className="mono dim">{(r.payload as RulePayload).oneShot}</span> },
          { key: 'enabled', head: '启用', render: (r) => <Badge tone={r.enabled ? 'ok' : 'off'}>{r.enabled ? '●' : '○'}</Badge> },
        ]}
      />

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

      {selected && (
        <>
          <SectionHeader no="02" title={`规则详情 · ${selected.name}`} en="RULE DETAIL" />
          <div className="panel-flat">
            <pre className="code" style={{ maxHeight: 200 }}>{JSON.stringify((selected.payload as RulePayload).actions, null, 2)}</pre>
            <div className="kv" style={{ marginTop: 8 }}>
              <dt>源文件</dt><dd className="mono dim">{selected.source.path}</dd>
              <dt>when 原文</dt>
              <dd>
                <pre className="code">{JSON.stringify((selected.payload as unknown as { when: unknown }).when, null, 2)}</pre>
              </dd>
            </div>
          </div>
        </>
      )}
    </div>
  );
}
