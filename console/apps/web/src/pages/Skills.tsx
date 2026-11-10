import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useEffect, useMemo, useRef, useState } from 'react';
import { apiGet, apiPost } from '../api';
import type { AssetLite } from '../types';
import { Badge, Panel } from '../components/ui';
import { Markdown } from '../components/Markdown';
import type { PageCtx } from './ctx';
import { matchesSkillQuery } from './skill-search';

function SaveIcon() {
  return (
    <svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" style={{ verticalAlign: '-2px', marginRight: 4 }} aria-hidden="true">
      <path d="M2.5 2.5h8.5l2.5 2.5v8.5h-11z" />
      <rect x="5.5" y="9" width="5" height="4.5" />
      <rect x="6" y="2.5" width="4" height="3" />
    </svg>
  );
}

function UndoIcon() {
  return (
    <svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.5" style={{ verticalAlign: '-2px', marginRight: 4 }} aria-hidden="true">
      <path d="M3.5 6.5h6a3.5 3.5 0 1 1 0 7H6" />
      <path d="M6.5 3.5l-3 3 3 3" />
    </svg>
  );
}

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
  const [query, setQuery] = useState('');
  const [draft, setDraft] = useState<string | null>(null);
  const [saveState, setSaveState] = useState<{ ok: boolean; text: string } | null>(null);
  const [saving, setSaving] = useState(false);
  const queryClient = useQueryClient();
  const searchRef = useRef<HTMLInputElement>(null);
  // 进入技能页默认聚焦搜索框
  useEffect(() => searchRef.current?.focus(), []);
  const allRows = all.data?.assets ?? [];
  const rows = useMemo(() => allRows.filter((s) => matchesSkillQuery(s, query)), [allRows, query]);
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
  useEffect(() => {
    setFile(null);
    setDraft(null);
    setSaveState(null);
  }, [selId]);
  // 切 tab 后旧选中 id 属于另一侧清单，重置为该 tab 首行，防止详情面板渲染他侧内容
  useEffect(() => setSel(null), [tab]);

  const dirty = draft !== null && draft !== content;
  const editable = view === 'source' && file === null && typeof content === 'string';

  const save = async (): Promise<void> => {
    if (!selId || draft === null) return;
    setSaving(true);
    try {
      const r = await apiPost<{ ok: boolean; output: string }>(`/api/assets/${encodeURIComponent(selId)}/content`, { content: draft, confirm: true });
      setSaveState({ ok: r.ok, text: r.output || (r.ok ? '已保存' : '保存失败') });
      if (r.ok) {
        setDraft(null);
        await queryClient.invalidateQueries({ queryKey: ['assets'] });
      }
    } catch (e) {
      setSaveState({ ok: false, text: String(e).slice(0, 300) });
    } finally {
      setSaving(false);
    }
  };

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
      {s.tags.includes('command') && <Badge tone="plain">command</Badge>}
    </>
  );


  return (
    <div className="fill-page">
      <div className="page-head">
        <div>
          <h2>技能</h2>
          <div className="sub tagline">
            SKILLS · {tab === 'first-party' ? '自建' : '第三方'} {rows.length}
            {query.trim() && ` / ${allRows.length}`}
          </div>
        </div>
        <div className="page-actions">
          <div className="tabs" style={{ marginBottom: 0 }}>
            <button className={`tab ${tab === 'first-party' ? 'active' : ''}`} onClick={() => setTab('first-party')}>自建 FIRST-PARTY</button>
            <button className={`tab ${tab === 'third-party' ? 'active' : ''}`} onClick={() => setTab('third-party')}>第三方 THIRD-PARTY</button>
          </div>
        </div>
      </div>

      <div className="grid fill-grid" style={{ gridTemplateColumns: '610px 1fr' }}>
        <Panel
          title="技能清单"
          en="ALL SKILLS"
          actions={
            // 紧跟 ALL SKILLS，右端与下方条目右对齐（panel-scroll 的 paddingRight 一致）
            <span style={{ display: 'flex', alignItems: 'center', paddingRight: 'var(--sp-3)' }}>
              <input
                ref={searchRef}
                className="search"
                aria-label="技能筛选"
                style={{ flex: 1, minWidth: 0 }}
                placeholder="筛选 名称/标签/平台…"
                title="启发式过滤：空格分词 AND，命中名称/摘要/id/路径/平台/标签"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
              />
            </span>
          }
        >
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
                // 过滤时全展开：命中条目可能藏在折叠节点里
                const platOpen = query.trim() !== '' || !collapsed.has(pk);
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
                      const locOpen = query.trim() !== '' || !collapsed.has(lk);
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
          <div className="tabs" style={{ alignItems: 'center' }}>
            {(['render', 'source'] as const).map((t) => (
              <button key={t} className={`tab ${view === t ? 'active' : ''}`} onClick={() => setView(t)}>
                {t === 'render' ? '渲染' : '源码'}
              </button>
            ))}
            {editable && (
              <span style={{ display: 'flex', gap: 'var(--sp-2)' }}>
                <button className="btn small btn-mint" disabled={!dirty || saving} onClick={() => void save()} title="先写入库内真源，再把所有同名部署实例（本地/各平台，按 platforms.d 声明通道）对照新内容更新">
                  <SaveIcon />保存并同步
                </button>
                <button
                  className="btn small btn-ghost"
                  disabled={!dirty || saving}
                  onClick={() => {
                    setDraft(null);
                    setSaveState(null);
                  }}
                >
                  <UndoIcon />撤销
                </button>
              </span>
            )}
          </div>
          {saveState && (
            <div style={{ marginBottom: 'var(--sp-2)' }}>
              <Badge tone={saveState.ok ? 'ok' : 'bad'}>{saveState.ok ? '已同步' : '失败'}</Badge>
              <pre style={{ whiteSpace: 'pre-wrap', margin: '4px 0 0', fontSize: 'var(--fs-label)', fontFamily: 'var(--font-mono)' }}>{saveState.text}</pre>
            </div>
          )}
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
                  if (view === 'render') return <Markdown text={content} />;
                  if (typeof content === 'string') {
                    return (
                      <textarea
                        className="code"
                        style={{ maxHeight: 'none', height: '100%', minHeight: 320, resize: 'vertical', whiteSpace: 'pre', width: '100%' }}
                        spellCheck={false}
                        value={draft ?? content}
                        onChange={(e) => {
                          setDraft(e.target.value);
                          setSaveState(null);
                        }}
                      />
                    );
                  }
                  return <pre className="code" style={{ maxHeight: 'none' }}>{String(content)}</pre>;
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
