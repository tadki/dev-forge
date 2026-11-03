import { useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { apiGet } from '../api';
import type { AssetLite } from '../types';
import { Badge, Panel } from '../components/ui';
import { Markdown } from '../components/Markdown';
import type { PageCtx } from './ctx';

export function InstructionsPage({ ctx }: { ctx: PageCtx }) {
  const list = useQuery({
    queryKey: ['assets', 'instruction'],
    queryFn: () => apiGet<{ assets: AssetLite[] }>(`/api/assets?kind=instruction${ctx.workspace ? `&workspace=${ctx.workspace}` : ''}`),
  });
  const [selected, setSelected] = useState<string | null>(null);
  const [tab, setTab] = useState<'render' | 'source' | 'meta'>('render');

  const selId = selected ?? list.data?.assets[0]?.id ?? null;
  const detail = useQuery({
    queryKey: ['asset', selId],
    queryFn: () => apiGet<{ asset: AssetLite }>(`/api/assets/${encodeURIComponent(selId ?? '')}`),
    enabled: !!selId,
  });

  const tree = useMemo(() => {
    const groups = new Map<string, AssetLite[]>();
    for (const a of list.data?.assets ?? []) {
      const scope = a.attach.level === 'project' ? `项目 · ${a.attach.ref?.split('/').pop() ?? ''}` : a.attach.level === 'user' ? (a.provenance === 'third-party' ? '全局 · 依赖架（rules 包）' : '全局') : `平台 · ${a.attach.ref ?? ''}`;
      groups.set(scope, [...(groups.get(scope) ?? []), a]);
    }
    return [...groups.entries()].sort((a, b) => a[0].localeCompare(b[0]));
  }, [list.data]);

  const payload = (detail.data?.asset.payload ?? {}) as { content?: string; lines?: number; headings?: Array<{ level: number; text: string }>; lang?: string; contentHash?: string };

  return (
    <div>
      <div className="page-head">
        <div>
          <h2>指令库</h2>
          <div className="sub tagline">INSTRUCTIONS · {list.data?.assets.length ?? 0} 份 · 作用域树 + 渲染</div>
        </div>
      </div>
      <div className="grid" style={{ gridTemplateColumns: '230px 1fr' }}>
        <Panel title="作用域树" en="SCOPE TREE">
          {tree.map(([scope, items]) => (
            <div key={scope} style={{ marginBottom: 8 }}>
              <div className="tagline" style={{ color: 'var(--text-sub)' }}>{scope}</div>
              {items.map((a) => (
                <div key={a.id} className={`tree-node ${a.id === selId ? 'sel' : ''}`} onClick={() => setSelected(a.id)}>
                  {a.name}
                </div>
              ))}
            </div>
          ))}
        </Panel>

        <Panel title={detail.data?.asset.name ?? '—'} en={detail.data ? `LINES ${payload.lines ?? '?'} · ${payload.lang ?? ''}` : ''}>
          <div className="tabs">
            {(['render', 'source', 'meta'] as const).map((t) => (
              <button key={t} className={`tab ${tab === t ? 'active' : ''}`} onClick={() => setTab(t)}>
                {t === 'render' ? '渲染' : t === 'source' ? '源码' : '元信息'}
              </button>
            ))}
          </div>
          {tab === 'render' && <div style={{ maxHeight: 560, overflow: 'auto' }}>{payload.content ? <Markdown text={payload.content} /> : <div className="dim">（内容未采集 — 第三方 rules 仅登记元信息）</div>}</div>}
          {tab === 'source' && <pre className="code" style={{ maxHeight: 560 }}>{payload.content ?? '—'}</pre>}
          {tab === 'meta' && (
            <dl className="kv">
              <dt>ID</dt><dd className="mono">{detail.data?.asset.id}</dd>
              <dt>归属</dt><dd>{detail.data?.asset.provenance === 'third-party' ? <Badge tone="off">third-party · 依赖架</Badge> : <Badge tone="ok">first-party</Badge>}</dd>
              <dt>挂载</dt><dd className="mono">{detail.data?.asset.attach.level}{detail.data?.asset.attach.ref ? ` · ${detail.data.asset.attach.ref}` : ''}</dd>
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
