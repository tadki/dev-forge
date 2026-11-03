import { useQuery } from '@tanstack/react-query';
import { Link } from 'react-router-dom';
import { apiGet } from '../api';
import type { AssetLite, FireEvent } from '../types';
import type { PageCtx } from './ctx';

export function OverviewPage({ ctx }: { ctx: PageCtx }) {
  const overview = ctx.overview.data;
  const activity = useQuery({
    queryKey: ['activity'],
    queryFn: () => apiGet<{ asset: AssetLite }>('/api/assets/custom%3Aactivity-feed'),
    refetchInterval: 10_000,
    select: (d) => (d.asset.payload as { events?: FireEvent[] } | undefined)?.events ?? [],
  });
  if (!overview) return <div className="dim">加载中…</div>;

  const health = overview.health;
  const bannerCls = health.status === 'GREEN' ? 'banner-ok' : health.status === 'REDLINE' ? 'banner-bad' : 'banner-warn';
  const kindsForBars: Array<[string, string, string]> = [
    ['instruction', '指令', 'var(--accent)'],
    ['skill', '技能', 'var(--mint)'],
    ['hook-rule', '钩子规则', 'var(--amber)'],
    ['autopilot', '巡逻', 'var(--ink)'],
    ['service', '服务', 'var(--accent)'],
    ['agent', '智能体', 'var(--mint)'],
    ['deployment', '部署', 'var(--amber)'],
    ['mcp-endpoint', 'MCP', 'var(--amber)'],
    ['hook-script', '钩子脚本', 'var(--ink)'],
  ];
  const maxCount = Math.max(...kindsForBars.map(([k]) => overview.counts[k] ?? 0), 1);

  return (
    <div>
      <div className="page-head">
        <div>
          <h2>总览</h2>
          <div className="sub tagline">OVERVIEW · 采集于 {overview.lastCollectedAt.slice(11, 19)} UTC · 自建 {overview.firstPartyTotal}/{overview.total}</div>
        </div>
        <div className="page-actions">
          <Link to="/effective" className="btn btn-ghost">有效 HARNESS →</Link>
        </div>
      </div>

      <div className={bannerCls}>
        <span className="banner-title">SYSTEM {health.status}</span>
        <span style={{ marginLeft: 12 }}>
          {health.status === 'GREEN' ? '工具链日检通过' : health.status === 'REDLINE' ? `红线 ${health.redlineCount} 条` : '暂无日检报告'} · 采集器 {overview.collectors.filter((c) => c.ok).length}/{overview.collectors.length} 在线
        </span>
      </div>

      <div className="stat-grid">
        <StatBlock num={overview.counts['project'] ?? 0} label="工作区/项目" en="PROJECTS" />
        <StatBlock num={overview.counts['agent'] ?? 0} label="智能体" en="AGENTS" />
        <StatBlock num={overview.counts['instruction'] ?? 0} label="指令" en="INSTRUCTIONS" />
        <StatBlock num={overview.counts['skill'] ?? 0} label="技能" en="SKILLS" />
        <StatBlock num={overview.counts['hook-rule'] ?? 0} label="钩子规则" en="HOOK RULES" />
      </div>

      <div className="grid grid-2">
        <section className="panel">
          <div className="panel-title">
            资产构成 <span className="en">ASSET COMPOSITION</span>
          </div>
          {kindsForBars.map(([kind, zh, color]) => {
            const n = overview.counts[kind] ?? 0;
            return (
              <div key={kind} className="row" style={{ marginBottom: 4 }}>
                <span style={{ width: 72, fontSize: 'var(--fs-l1)' }}>{zh}</span>
                <div style={{ flex: 1, border: '1px solid var(--ink)', height: 14, background: 'var(--paper)' }}>
                  <div style={{ width: `${(n / maxCount) * 100}%`, background: color, height: '100%' }} />
                </div>
                <span className="mono" style={{ width: 36, textAlign: 'right' }}>{n}</span>
              </div>
            );
          })}
        </section>

        <section className="panel-ink">
          <div className="panel-title">
            最近活动 <span className="en" style={{ color: 'var(--khaki)' }}>ACTIVITY · FIRELOG TAIL</span>
          </div>
          <div style={{ maxHeight: 260, overflow: 'auto' }}>
            {(activity.data ?? []).slice(0, 30).map((ev, i) => (
              <div key={i} className="log-line">
                <span className="log-ts">{ev.ts.slice(11, 19)}</span>
                <span style={{ color: 'var(--khaki)' }}>{ev.agent ?? 'human'}</span>
                <span className={ev.action === 'deny' ? 'log-bad' : ev.action && ev.action !== 'none' ? 'log-warn' : ''}>
                  {ev.event} {ev.action && ev.action !== 'none' ? `[${ev.action}]` : ''} {ev.rules ? `rules=${ev.rules}` : ''}
                </span>
              </div>
            ))}
            {(activity.data ?? []).length === 0 && <div className="log-ts">（暂无 firelog 事件）</div>}
          </div>
        </section>
      </div>

      {overview.collectors.some((c) => !c.ok) && (
        <>
          <div className="sect">
            <span className="no">✕</span>
            <span className="title">采集器异常</span>
            <span className="en">FAILED COLLECTORS</span>
          </div>
          <div className="panel-flat">
            {overview.collectors.filter((c) => !c.ok).map((c) => (
              <div key={c.name} className="mono" style={{ fontSize: 'var(--fs-l1)' }}>
                <span className="log-bad">{c.name}</span> <span className="dim">{c.error}</span>
              </div>
            ))}
          </div>
        </>
      )}
    </div>
  );
}

function StatBlock({ num, label, en }: { num: number; label: string; en: string }) {
  return (
    <div className="stat">
      <div className="num">{num}</div>
      <div className="label">
        {label}
        <span className="en">{en}</span>
      </div>
    </div>
  );
}
