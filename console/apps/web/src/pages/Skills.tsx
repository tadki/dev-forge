import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { apiGet } from '../api';
import type { AssetLite } from '../types';
import { Badge, Panel, SectionHeader } from '../components/ui';
import type { PageCtx } from './ctx';

export function SkillsPage({ ctx }: { ctx: PageCtx }) {
  const [tab, setTab] = useState<'first-party' | 'third-party'>('first-party');
  const all = useQuery({
    queryKey: ['assets', 'skill', tab],
    queryFn: () => apiGet<{ assets: AssetLite[] }>(`/api/assets?kind=skill&provenance=${tab}${ctx.workspace ? `&workspace=${ctx.workspace}` : ''}`),
  });
  const [sel, setSel] = useState<string | null>(null);
  const rows = all.data?.assets ?? [];
  const selId = sel ?? rows[0]?.id ?? null;
  const selected = rows.find((r) => r.id === selId);

  const groups = rows.reduce<Record<string, AssetLite[]>>((acc, s) => {
    const scope = s.attach.level === 'user' ? (s.provenance === 'third-party' ? 'ECC 依赖架（user）' : '全局（user）') : s.attach.level === 'project' ? `项目 · ${s.attach.ref?.split('/').pop()}` : `平台 · ${s.attach.ref}`;
    acc[scope] = [...(acc[scope] ?? []), s];
    return acc;
  }, {});

  return (
    <div>
      <div className="page-head">
        <div>
          <h2>技能</h2>
          <div className="sub tagline">SKILLS · 自建 {rows.filter((r) => r.provenance === 'first-party').length} · 依赖架（ECC 等）单独折叠</div>
        </div>
        <div className="page-actions">
          <div className="tabs" style={{ marginBottom: 0 }}>
            <button className={`tab ${tab === 'first-party' ? 'active' : ''}`} onClick={() => setTab('first-party')}>自建 FIRST-PARTY</button>
            <button className={`tab ${tab === 'third-party' ? 'active' : ''}`} onClick={() => setTab('third-party')}>依赖架 DEPENDENCIES</button>
          </div>
        </div>
      </div>

      <div className="grid" style={{ gridTemplateColumns: '2fr 1fr' }}>
        <div className="col">
          {Object.entries(groups).map(([scope, items]) => (
            <div key={scope}>
              <SectionHeader no="▤" title={scope} en={`${items.length} SKILLS`} />
              <div className="card-grid">
                {items.map((s) => (
                  <button key={s.id} className={`card ${s.id === selId ? 'sel' : ''}`} onClick={() => setSel(s.id)}>
                    <h3 className="mono" style={{ fontSize: 'var(--fs-l2)' }}>{s.name.startsWith('/') ? s.name : `/${s.name}`}</h3>
                    <div className="desc">{s.summary.slice(0, 100)}</div>
                    <div className="row">
                      {s.attach.level !== 'user' && <Badge tone="plain">{s.attach.level}</Badge>}
                      {s.platforms.includes('multica') && <Badge tone="warn">multica</Badge>}
                      {(s.payload as { platformSkill?: boolean }).platformSkill && <Badge tone="plain">平台物化</Badge>}
                      {s.tags.includes('command') && <Badge tone="plain">command</Badge>}
                    </div>
                  </button>
                ))}
              </div>
            </div>
          ))}
        </div>
        <div className="col">
          <Panel title={selected?.name ?? '—'} en="DETAIL">
            <div className="kv">
              <dt>归属</dt><dd>{selected?.provenance === 'third-party' ? <Badge tone="off">third-party · 依赖架</Badge> : <Badge tone="ok">first-party</Badge>}</dd>
              <dt>挂载</dt><dd className="mono">{selected?.attach.level}{selected?.attach.ref ? ` · ${selected.attach.ref}` : ''}</dd>
              <dt>强制力</dt><dd>{selected?.enforcement}</dd>
              <dt>规模</dt><dd className="mono">{String((selected?.payload as { lines?: number } | undefined)?.lines ?? '—')} 行</dd>
              <dt>源</dt><dd className="mono dim" style={{ fontSize: 'var(--fs-label)' }}>{selected?.source.path}</dd>
            </div>
          </Panel>
          <Panel title="接入方式" en="HOW TO ADD">
            <ol style={{ margin: '4px 0 0 16px', fontSize: 'var(--fs-l1)', lineHeight: 1.9 }}>
              <li>全局自建：放 <span className="mono">~/.claude/skills/&lt;name&gt;/SKILL.md</span></li>
              <li>项目级：放 <span className="mono">&lt;repo&gt;/.claude/skills/</span></li>
              <li>平台： <span className="mono">multica skill create</span> + agent 绑定</li>
              <li>兜底： <span className="mono">POST /api/custom/assets</span>（契约 JSON）或 <span className="mono">console/collectors.d/</span> 丢脚本</li>
            </ol>
          </Panel>
        </div>
      </div>
    </div>
  );
}
