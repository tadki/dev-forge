import { useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { apiGet } from '../api';
import type { AssetLite } from '../types';
import { Badge, Panel } from '../components/ui';
import { Markdown } from '../components/Markdown';
import type { PageCtx } from './ctx';

export interface ScopeGroup {
  key: string;
  label: string;
  thirdParty: boolean;
  platform: string;
  items: AssetLite[];
}

export interface PlatformGroup {
  platform: string;
  groups: ScopeGroup[];
  count: number;
}

export function buildScopeTree(assets: AssetLite[]): ScopeGroup[] {
  const groups = new Map<string, ScopeGroup>();
  for (const a of assets) {
    const thirdParty = a.provenance === 'third-party';
    const group = (a.payload as { group?: string }).group;
    const platform = (a.platforms ?? []).join('+') || '—';
    const label =
      a.attach.level === 'project'
        ? `项目 · ${a.attach.ref?.split('/').pop() ?? ''}`
        : a.attach.level === 'user'
          ? thirdParty
            ? `rules/${group ?? '其他'}`
            : '全局'
          : `平台 · ${a.attach.ref ?? ''}`;
    const key = `${a.attach.level}|${thirdParty ? 'tp' : 'fp'}|${thirdParty ? `${platform}|${group ?? ''}` : label}`;
    groups.set(key, {
      key,
      label,
      thirdParty,
      platform,
      items: [...(groups.get(key)?.items ?? []), a],
    });
  }
  const byLabel = (x: ScopeGroup, y: ScopeGroup) => x.label.localeCompare(y.label);
  const values = [...groups.values()];
  // 自研组在前（作用域名序），第三方依赖架组殿后
  return [...values.filter((g) => !g.thirdParty).sort(byLabel), ...values.filter((g) => g.thirdParty).sort(byLabel)];
}

export function groupByPlatform(groups: ScopeGroup[]): PlatformGroup[] {
  const map = new Map<string, ScopeGroup[]>();
  for (const g of groups) map.set(g.platform, [...(map.get(g.platform) ?? []), g]);
  return [...map.entries()]
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([platform, gs]) => ({ platform, groups: gs, count: gs.reduce((n, g) => n + g.items.length, 0) }));
}

export function InstructionsPage({ ctx }: { ctx: PageCtx }) {
  const list = useQuery({
    queryKey: ['assets', 'instruction'],
    queryFn: () => apiGet<{ assets: AssetLite[] }>(`/api/assets?kind=instruction${ctx.workspace ? `&workspace=${ctx.workspace}` : ''}`),
  });
  const [selected, setSelected] = useState<string | null>(null);
  const [tab, setTab] = useState<'render' | 'source' | 'meta'>('render');
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(new Set());

  const selId = selected ?? list.data?.assets[0]?.id ?? null;
  const detail = useQuery({
    queryKey: ['asset', selId],
    queryFn: () => apiGet<{ asset: AssetLite }>(`/api/assets/${encodeURIComponent(selId ?? '')}`),
    enabled: !!selId,
  });

  const tree = useMemo(() => buildScopeTree(list.data?.assets ?? []), [list.data]);
  const owned = tree.filter((g) => !g.thirdParty);
  const platforms = useMemo(() => groupByPlatform(tree.filter((g) => g.thirdParty)), [tree]);
  const ownedCount = owned.reduce((n, g) => n + g.items.length, 0);
  const depCount = platforms.reduce((n, p) => n + p.count, 0);

  const toggle = (key: string) =>
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });

  const renderItem = (a: AssetLite) => (
    <div
      key={a.id}
      className={`tree-node ${a.provenance === 'third-party' ? 'tp ' : ''}${a.id === selId ? 'sel' : ''}`}
      onClick={() => setSelected(a.id)}
    >
      {a.name}
    </div>
  );

  const payload = (detail.data?.asset.payload ?? {}) as { content?: string; lines?: number; headings?: Array<{ level: number; text: string }>; lang?: string; contentHash?: string };

  return (
    <div>
      <div className="page-head">
        <div>
          <h2>指令库</h2>
          <div className="sub tagline">
            INSTRUCTIONS · {list.data?.assets.length ?? 0} 份 · 自研 {ownedCount} · 第三方 {depCount} · 作用域树 + 渲染
          </div>
        </div>
      </div>
      <div className="grid" style={{ gridTemplateColumns: '230px 1fr' }}>
        <Panel title="作用域树" en="SCOPE TREE">
          {owned.map((g) => (
            <div key={g.key} style={{ marginBottom: 8 }}>
              <div className="tagline" style={{ color: 'var(--text-sub)' }}>
                {g.label} · {g.items.length}
              </div>
              {g.items.map(renderItem)}
            </div>
          ))}
          {platforms.length > 0 && (
            <>
              <div className="tree-sep tagline">第三方 · 依赖架（rules 包）</div>
              {platforms.map((p) => {
                const pk = `platform:${p.platform}`;
                return (
                  <div key={pk} style={{ marginBottom: 4 }}>
                    <div className="tagline tree-group" onClick={() => toggle(pk)}>
                      {expanded.has(pk) ? '▾' : '▸'} {p.platform} · {p.count}
                    </div>
                    {expanded.has(pk) &&
                      p.groups.map((g) => (
                        <div key={g.key} style={{ marginBottom: 2, paddingLeft: 'var(--sp-3)' }}>
                          <div className="tagline tree-group" onClick={() => toggle(g.key)}>
                            {expanded.has(g.key) ? '▾' : '▸'} {g.label} · {g.items.length}
                          </div>
                          {expanded.has(g.key) && g.items.map(renderItem)}
                        </div>
                      ))}
                  </div>
                );
              })}
            </>
          )}
        </Panel>

        <Panel title={detail.data?.asset.name ?? '—'} en={detail.data ? `LINES ${payload.lines ?? '?'} · ${payload.lang ?? ''}` : ''}>
          <div className="tabs">
            {(['render', 'source', 'meta'] as const).map((t) => (
              <button key={t} className={`tab ${tab === t ? 'active' : ''}`} onClick={() => setTab(t)}>
                {t === 'render' ? '渲染' : t === 'source' ? '源码' : '元信息'}
              </button>
            ))}
          </div>
          {tab === 'render' && <div style={{ maxHeight: 560, overflow: 'auto' }}>{payload.content ? <Markdown text={payload.content} /> : <div className="dim">（无正文）</div>}</div>}
          {tab === 'source' && <pre className="code" style={{ maxHeight: 560 }}>{payload.content ?? '—'}</pre>}
          {tab === 'meta' && (
            <dl className="kv">
              <dt>ID</dt><dd className="mono">{detail.data?.asset.id}</dd>
              <dt>归属</dt><dd>{detail.data?.asset.provenance === 'third-party' ? <Badge tone="off">third-party · 依赖架</Badge> : <Badge tone="ok">first-party</Badge>}</dd>
              <dt>挂载</dt><dd className="mono">{detail.data?.asset.attach.level}{detail.data?.asset.attach.ref ? ` · ${detail.data.asset.attach.ref}` : ''}</dd>
              <dt>平台</dt><dd className="mono">{detail.data?.asset.platforms?.join(' · ') || '—'}</dd>
              <dt>强制力</dt><dd>{detail.data?.asset.enforcement}</dd>
              <dt>hash</dt><dd className="mono">{payload.contentHash?.slice(0, 16)}</dd>
              <dt>章节</dt>
              <dd>{(payload.headings ?? []).slice(0, 12).map((h, i) => <div key={i} style={{ paddingLeft: (h.level - 1) * 12 }}>{'#'.repeat(h.level)} {h.text}</div>)}</dd>
              <dt>源文件</dt><dd className="mono dim">{detail.data?.asset.source.path}</dd>
            </dl>
          )}
        </Panel>
      </div>
    </div>
  );
}
