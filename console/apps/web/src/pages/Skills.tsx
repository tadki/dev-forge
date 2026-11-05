import { useQuery } from '@tanstack/react-query';
import { useEffect, useState } from 'react';
import { apiGet } from '../api';
import type { AssetLite } from '../types';
import { Badge, Panel } from '../components/ui';
import { Markdown } from '../components/Markdown';
import type { PageCtx } from './ctx';

export function SkillsPage({ ctx }: { ctx: PageCtx }) {
  const [tab, setTab] = useState<'first-party' | 'third-party'>('first-party');
  const all = useQuery({
    queryKey: ['assets', 'skill', tab],
    queryFn: () => apiGet<{ assets: AssetLite[] }>(`/api/assets?kind=skill&provenance=${tab}${ctx.workspace ? `&workspace=${ctx.workspace}` : ''}`),
  });
  const [sel, setSel] = useState<string | null>(null);
  const [view, setView] = useState<'render' | 'source'>('render');
  const [metaOpen, setMetaOpen] = useState(false);
  const [file, setFile] = useState<string | null>(null);
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const rows = all.data?.assets ?? [];
  const selId = sel ?? rows[0]?.id ?? null;
  const selected = rows.find((r) => r.id === selId);
  const full = useQuery({
    queryKey: ['assets', 'detail', selId],
    queryFn: () => apiGet<{ asset: AssetLite }>(`/api/assets/${encodeURIComponent(selId ?? '')}`),
    enabled: !!selId,
  });
  const fullPayload = (full.data?.asset.payload ?? {}) as { content?: string; files?: Array<{ path: string; content?: string }> };
  const content = fullPayload.content;
  const files = fullPayload.files ?? [];
  useEffect(() => setFile(null), [selId]);

  const locOf = (s: AssetLite): string => {
    if (s.attach.level === 'project') return `项目 ${s.attach.ref?.split('/').pop() ?? s.attach.ref ?? '?'}`;
    const p = s.source.path ?? '';
    if (p.includes('/.claude/.agents/skills/')) return '全局 ~/.claude/.agents/skills（ECC 插件）';
    if (p.includes('/.claude/skills/')) return '全局 ~/.claude/skills';
    if (p.includes('/.claude/commands/')) return '全局 ~/.claude/commands';
    return s.platforms.join(' · ') || '其他';
  };
  const locOrder = (k: string) =>
    k.includes('.agents') ? 1 : k.includes('commands') ? 2 : k.startsWith('全局') ? 0 : k.startsWith('项目') ? 3 : 4;

  const byName = (a: AssetLite, b: AssetLite) => a.name.localeCompare(b.name);

  // 第三方两级树：平台 → 扫描位置 → 技能
  const tree = Object.entries(
    rows.reduce<Record<string, AssetLite[]>>((acc, s) => {
      const plat = s.platforms.length ? s.platforms.join(' · ') : 'unknown';
      acc[plat] = [...(acc[plat] ?? []), s];
      return acc;
    }, {})
  )
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([plat, items]) => ({
      plat,
      locs: Object.entries(items.reduce<Record<string, AssetLite[]>>((acc, s) => {
        const loc = locOf(s);
        acc[loc] = [...(acc[loc] ?? []), s];
        return acc;
      }, {}))
        .sort(([a], [b]) => locOrder(a) - locOrder(b) || a.localeCompare(b))
        .map(([loc, li]) => ({ loc, items: [...li].sort(byName) })),
    }));
  const toggleNode = (k: string) =>
    setCollapsed((prev) => {
      const next = new Set(prev);
      if (next.has(k)) next.delete(k);
      else next.add(k);
      return next;
    });

  const badgesOf = (s: AssetLite) => (
    <>
      {s.attach.level === 'project' && <Badge tone="plain">{s.attach.level}</Badge>}
      {s.platforms.includes('multica') && <Badge tone="warn">multica</Badge>}
      {(s.payload as { platformSkill?: boolean }).platformSkill && <Badge tone="plain">平台物化</Badge>}
      {s.tags.includes('command') && <Badge tone="plain">command</Badge>}
    </>
  );


  return (
    <div className="fill-page">
      <div className="page-head">
        <div>
          <h2>技能</h2>
          <div className="sub tagline">SKILLS · {tab === 'first-party' ? `自建 ${rows.length}` : `第三方 ${rows.length}`}</div>
        </div>
        <div className="page-actions">
          <div className="tabs" style={{ marginBottom: 0 }}>
            <button className={`tab ${tab === 'first-party' ? 'active' : ''}`} onClick={() => setTab('first-party')}>自建 FIRST-PARTY</button>
            <button className={`tab ${tab === 'third-party' ? 'active' : ''}`} onClick={() => setTab('third-party')}>第三方 THIRD-PARTY</button>
          </div>
        </div>
      </div>

      <div className="grid fill-grid" style={{ gridTemplateColumns: '610px 1fr' }}>
        <Panel title="技能清单" en="ALL SKILLS">
          <div className="panel-scroll" style={{ paddingRight: 'var(--sp-3)' }}>
            {tab === 'first-party' ? (
              <div>
                {[...rows].sort(byName).map((s) => (
                  <div
                    key={s.id}
                    className={`tree-node mono ${s.id === selId ? 'sel' : ''}`}
                    style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 'var(--sp-2)' }}
                    onClick={() => setSel(s.id)}
                  >
                    <span>{s.name.startsWith('/') ? s.name : `/${s.name}`}</span>
                    <span className="row">
                      {s.platforms.map((p) => (
                        <Badge key={p} tone={p === 'multica' ? 'warn' : 'plain'}>{p}</Badge>
                      ))}
                    </span>
                  </div>
                ))}
              </div>
            ) : (
              tree.map(({ plat, locs }) => {
                const pk = `p:${plat}`;
                const platOpen = !collapsed.has(pk);
                return (
                  <div key={plat}>
                    <div
                      className="tagline"
                      style={{ cursor: 'pointer', userSelect: 'none', marginTop: 'var(--sp-2)', fontWeight: 600 }}
                      onClick={() => toggleNode(pk)}
                    >
                      {platOpen ? '▾' : '▸'} <span className="mono">{plat}</span> · {locs.reduce((n, l) => n + l.items.length, 0)}
                    </div>
                    {platOpen && locs.map(({ loc, items }) => {
                      const lk = `${pk}:${loc}`;
                      const locOpen = !collapsed.has(lk);
                      return (
                        <div key={loc}>
                          <div
                            className="tagline"
                            style={{ cursor: 'pointer', userSelect: 'none', color: 'var(--text-sub)', paddingLeft: 'var(--sp-4)' }}
                            onClick={() => toggleNode(lk)}
                          >
                            {locOpen ? '▾' : '▸'} {loc} · {items.length}
                          </div>
                          {locOpen && items.map((s) => (
                            <div
                              key={s.id}
                              className={`tree-node mono ${s.id === selId ? 'sel' : ''}`}
                              style={{ paddingLeft: 'var(--sp-5)', display: 'flex', alignItems: 'center', gap: 'var(--sp-2)' }}
                              onClick={() => setSel(s.id)}
                            >
                              <span>{s.name.startsWith('/') ? s.name : `/${s.name}`}</span>
                              <span className="row">{badgesOf(s)}</span>
                            </div>
                          ))}
                        </div>
                      );
                    })}
                  </div>
                );
              })
            )}
          </div>
        </Panel>
        <Panel title={selected?.name ? (selected.name.startsWith('/') ? selected.name : `/${selected.name}`) : '—'} en={selected ? `LINES ${String((selected.payload as { lines?: number } | undefined)?.lines ?? '?')}` : ''}>
          <div className="tabs">
            {(['render', 'source'] as const).map((t) => (
              <button key={t} className={`tab ${view === t ? 'active' : ''}`} onClick={() => setView(t)}>
                {t === 'render' ? '渲染' : '源码'}
              </button>
            ))}
          </div>
          <div className="tagline meta-toggle" onClick={() => setMetaOpen((v) => !v)}>
            {metaOpen ? '▾' : '▸'} 元信息
          </div>
          {metaOpen && (
            <dl className="kv" style={{ marginBottom: 'var(--sp-2)' }}>
              <dt>归属</dt><dd>{selected?.provenance === 'third-party' ? <Badge tone="off">third-party</Badge> : <Badge tone="ok">first-party</Badge>}</dd>
              <dt>挂载</dt><dd className="mono">{selected?.attach.level}{selected?.attach.ref ? ` · ${selected.attach.ref}` : ''}</dd>
              <dt>平台</dt><dd className="mono">{selected?.platforms?.join(' · ') || '—'}</dd>
              <dt>强制力</dt><dd>{selected?.enforcement}</dd>
              <dt>规模</dt><dd className="mono">{String((selected?.payload as { lines?: number } | undefined)?.lines ?? '—')} 行</dd>
              <dt>源</dt><dd className="mono dim" style={{ fontSize: 'var(--fs-label)' }}>{selected?.source.path}</dd>
            </dl>
          )}
          <div style={{ flex: 1, minHeight: 0, display: 'flex', gap: 'var(--sp-3)' }}>
            <aside style={{ width: 180, flexShrink: 0, overflowY: 'auto', borderRight: '1px solid var(--khaki)', paddingRight: 'var(--sp-2)' }}>
              <div className="tagline" style={{ color: 'var(--text-sub)' }}>FILES · {files.length + 1}</div>
              <div className={`tree-node mono ${file === null ? 'sel' : ''}`} onClick={() => setFile(null)}>SKILL.md</div>
              {files.map((f) => (
                <div key={f.path} className={`tree-node mono ${file === f.path ? 'sel' : ''}`} onClick={() => setFile(f.path)}>{f.path}</div>
              ))}
            </aside>
            <div className="panel-scroll" style={{ minWidth: 0 }}>
              {(() => {
                if (file !== null) {
                  const f = files.find((x) => x.path === file);
                  if (!f) return <div className="dim">文件不存在。</div>;
                  return view === 'render'
                    ? <Markdown text={f.content ?? ''} />
                    : <pre className="code" style={{ maxHeight: 'none' }}>{f.content ?? '—'}</pre>;
                }
                if (content !== undefined) {
                  return view === 'render' ? <Markdown text={content} /> : <pre className="code" style={{ maxHeight: 'none' }}>{content}</pre>;
                }
                return (
                  <div className="dim">
                    {selected?.attach.level === 'platform'
                      ? '平台技能无本地全文，请在 multica 查看。'
                      : full.isLoading ? '加载中…' : '无内容。'}
                  </div>
                );
              })()}
            </div>
          </div>
        </Panel>
      </div>
    </div>
  );
}
