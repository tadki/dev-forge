import { useQuery } from '@tanstack/react-query';
import { useMemo, useState } from 'react';
import { apiGet } from '../api';
import type { AssetLite } from '../types';
import { Badge, Chip, DataTable, Panel, SectionHeader } from '../components/ui';
import type { PageCtx } from './ctx';

const KIND_ORDER = ['agent', 'instruction', 'skill', 'hook-registration', 'hook-rule', 'hook-script', 'service', 'autopilot', 'adapter', 'mcp-endpoint', 'project', 'report', 'env', 'custom'];

interface StatRow {
  id: string;
  kind: string;
  own: number;
  ext: number;
  levels: string;
  controllable: string;
}

export function RegistryPage(_props: { ctx: PageCtx }) {
  const all = useQuery({
    queryKey: ['assets', 'registry-all'],
    queryFn: () => apiGet<{ assets: AssetLite[] }>('/api/assets'),
  });
  const [kindFilter, setKindFilter] = useState('');

  const assets = all.data?.assets ?? [];
  const stats = useMemo<StatRow[]>(() => {
    return KIND_ORDER.filter((k) => assets.some((a) => a.kind === k)).map((kind) => {
      const list = assets.filter((a) => a.kind === kind);
      const own = list.filter((a) => a.provenance === 'first-party');
      const ext = list.length - own.length;
      const lv = new Map<string, number>();
      for (const a of list) lv.set(a.attach.level, (lv.get(a.attach.level) ?? 0) + 1);
      const controllable = list.filter(
        (a) => a.kind === 'service' && a.provenance === 'first-party' && (a.payload as { scope?: string }).scope === 'user'
      ).length;
      return {
        id: kind,
        kind,
        own: own.length,
        ext,
        levels: [...lv.entries()].map(([l, n]) => `${l}:${n}`).join(' · ') || '—',
        controllable: kind === 'service' ? `${controllable} 个 user 级可启停` : '—',
      };
    });
  }, [assets]);

  const ownList = useMemo(
    () => assets.filter((a) => a.provenance === 'first-party' && (!kindFilter || a.kind === kindFilter)),
    [assets, kindFilter]
  );
  const totalOwn = assets.filter((a) => a.provenance === 'first-party').length;
  const totalExt = assets.length - totalOwn;

  return (
    <div>
      <div className="page-head">
        <div>
          <h2>注册表</h2>
          <div className="sub tagline">REGISTRY · 自建 {totalOwn} · 外部 {totalExt} · 追溯"这是我们的还是外部的"</div>
        </div>
        <div className="page-actions">
          <select className="search" value={kindFilter} onChange={(e) => setKindFilter(e.target.value)}>
            <option value="">全部类型（自建清单）</option>
            {KIND_ORDER.map((k) => (
              <option key={k} value={k}>{k}</option>
            ))}
          </select>
        </div>
      </div>

      <Panel title="统计表" en={`BY KIND × PROVENANCE · ${assets.length} 总量`}>
        <DataTable
          rows={stats}
          cols={[
            { key: 'kind', head: '类型 KIND', render: (r) => <span className="mono">{r.kind}</span> },
            { key: 'own', head: '自建 OWN', render: (r) => <Badge tone="ok">{r.own}</Badge> },
            { key: 'ext', head: '外部 EXT', render: (r) => (r.ext > 0 ? <Badge tone="off">◇ {r.ext}</Badge> : <span className="dim">0</span>) },
            { key: 'levels', head: '挂载层级分布', render: (r) => <span className="mono dim">{r.levels}</span> },
            { key: 'ctl', head: '启停能力', render: (r) => <span className="dim">{r.controllable}</span> },
          ]}
        />
      </Panel>

      <SectionHeader no="01" title="注册管理" en={`REGISTRY MGMT · 声明 console/registry.d/owned.yaml`} />
      <div className="grid grid-3">
        <Panel title="已登记" en="DECLARED">
          <div className="num" style={{ fontFamily: 'var(--font-mono)', fontSize: 'var(--fs-d1)' }}>
            {assets.filter((a) => (a.payload as { registry?: { declared?: boolean } }).registry?.declared).length}
          </div>
          <div className="dim" style={{ fontSize: 'var(--fs-l1)' }}>声明命中（meta 已盖戳）</div>
        </Panel>
        <Panel title="未登记的自建资产" en="UNDECLARED">
          <div className="num" style={{ fontFamily: 'var(--font-mono)', fontSize: 'var(--fs-d1)', color: 'var(--accent)' }}>
            {assets.filter((a) => (a.payload as { registry?: { declared?: boolean } }).registry?.declared === false).length}
          </div>
          <div className="dim" style={{ fontSize: 'var(--fs-l1)' }}>建议补声明（registry.d 加 entry）</div>
        </Panel>
        <Panel title="未匹配声明" en="UNMATCHED">
          <div className="num" style={{ fontFamily: 'var(--font-mono)', fontSize: 'var(--fs-d1)', color: 'var(--gray)' }}>
            {assets.filter((a) => a.id.startsWith('registry:unmatched-')).length}
          </div>
          <div className="dim" style={{ fontSize: 'var(--fs-l1)' }}>声明了但没采到（检查 match）</div>
        </Panel>
      </div>
      {ownList.some((a) => (a.payload as { registry?: { declared?: boolean } }).registry?.declared === false) && (
        <div className="panel-flat mt" style={{ maxHeight: 220, overflow: 'auto' }}>
          <div className="tagline mb">未登记清单（自建但 registry.d 没声明）</div>
          {ownList
            .filter((a) => (a.payload as { registry?: { declared?: boolean } }).registry?.declared === false)
            .slice(0, 40)
            .map((a) => (
              <div key={a.id} className="row" style={{ padding: '2px 0', fontSize: 'var(--fs-l1)' }}>
                <Badge tone="warn">{a.kind}</Badge>
                <span className="mono">{a.name}</span>
                <span className="mono dim" style={{ fontSize: 'var(--fs-label)' }}>{a.source.path}</span>
              </div>
            ))}
        </div>
      )}

      <SectionHeader no="02" title="自建资产清单" en={`FIRST-PARTY INVENTORY · ${ownList.length}`} />
      <DataTable
        rows={ownList}
        cols={[
          { key: 'kind', head: '类型', render: (r) => <span className="mono">{r.kind}</span> },
          { key: 'name', head: '名称', render: (r) => <span className="mono">{r.name}</span> },
          { key: 'attach', head: '挂载', render: (r) => <span className="mono dim">{r.attach.level}{r.attach.ref ? ` · ${String(r.attach.ref).split('/').pop()}` : ''}</span> },
          { key: 'on', head: '启用', render: (r) => <Badge tone={r.enabled ? 'ok' : 'off'}>{r.enabled ? '●' : '○'}</Badge> },
          { key: 'en', head: '强制力', render: (r) => <span className="dim">{r.enforcement}</span> },
            {
              key: 'meta',
              head: 'META',
              render: (r) => (
                <span className="row" style={{ gap: 2 }}>
                  {r.meta?.category && <Chip>{r.meta.category}</Chip>}
                  {r.meta?.lifecycle && <Chip>{r.meta.lifecycle}</Chip>}
                  {r.meta?.criticality && <Chip>{r.meta.criticality === 'high' ? '⚑ high' : r.meta.criticality}</Chip>}
                  {r.meta?.runtime && <Chip>{r.meta.runtime}</Chip>}
                  {(r.payload as { registry?: { declared?: boolean } }).registry?.declared === false && <Badge tone="warn">未登记</Badge>}
                </span>
              ),
            },
          { key: 'src', head: '源', render: (r) => <span className="mono dim" style={{ fontSize: 'var(--fs-label)' }}>{r.source.path}</span> },
        ]}
      />
    </div>
  );
}
