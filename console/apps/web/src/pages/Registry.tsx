import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useMemo, useState } from 'react';
import { apiGet, apiPost } from '../api';
import type { AssetLite, ReconcileAction, ReconcileItem, ReconcileReport } from '../types';
import { Badge, Chip, DataTable, SplitDiff, Panel, SectionHeader } from '../components/ui';
import { KIND_ORDER } from '../kinds';
import type { PageCtx } from './ctx';


const RECONCILE_LABEL: Record<ReconcileItem['type'], string> = {
  'missing-on-platform': '声明未落地',
  'undeclared-platform': '未声明平台',
  'content-drift': '内容漂移',
  'store-drift': '库与生产分叉',
  'uncovered-assets': '未纳入对账',
};

const DIRECTION_LABEL: Record<ReconcileAction['direction'], string> = {
  'platform-to-local': '平台 → 本地',
  'local-to-platform': '本地 → 平台',
};

function humanizeStep(step: ReconcileAction['steps'][number]): string {
  if (step.type === 'registry-edit') {
    const s = step as { op?: string; platform?: string; entryId?: string };
    return `改 registry.d · ${s.entryId}: ${s.op === 'add-platform' ? '声明 +' : '移除声明 '}${s.platform}`;
  }
  if (step.type === 'file-write') {
    const s = step as { path?: string; contentFrom?: { from?: string } };
    const fromStore = s.contentFrom?.from === 'store' ? '（内容取自库内副本）' : '';
    return `写文件 ${String(s.path)}（先备份原文件）${fromStore}`;
  }
  if (step.type === 'command') {
    const s = step as { cmd?: string[] };
    return `执行命令 ${(s.cmd ?? []).join(' ')}`;
  }
  if (step.type === 'store-write') {
    const s = step as { assetId?: string };
    return `采纳生产进库：重写 ${String(s.assetId)} 副本（先备份旧副本）`;
  }
  return step.type;
}

function confirmTip(item: ReconcileItem, action: ReconcileAction): string {
  const steps = action.steps.length > 0 ? action.steps.map((s) => `  · ${humanizeStep(s)}`).join('\n') : '  （无自动步骤）';
  return `平台对账 · ${RECONCILE_LABEL[item.type]} · ${item.platform}\n${item.detail}\n\n动作：${action.label}\n\n将执行：\n${steps}\n\n确认执行？写操作会先备份目标文件，执行后可回滚。`;
}

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
  const rc = useQuery({
    queryKey: ['reconcile'],
    queryFn: () => apiGet<ReconcileReport>('/api/reconcile'),
  });
  const qc = useQueryClient();
  const [busyKey, setBusyKey] = useState('');
  const [actionResult, setActionResult] = useState<{ ok: boolean; text: string } | null>(null);
  const [kindFilter, setKindFilter] = useState('');

  async function runReconcileAction(item: ReconcileItem, action: ReconcileAction) {
    if (!action.executable) {
      window.alert(action.note ?? '该方向没有安全的自动执行路径，请手动处理。');
      return;
    }
    if (!window.confirm(confirmTip(item, action))) return;
    setBusyKey(`${item.key}:${action.id}`);
    setActionResult(null);
    try {
      const r = await apiPost<{ ok: boolean; output: string }>('/api/reconcile/actions', {
        key: item.key,
        actionId: action.id,
        confirm: true,
      });
      setActionResult({ ok: r.ok, text: `${item.name} · ${action.label}\n${r.output || '(无输出)'}` });
      void qc.invalidateQueries({ queryKey: ['reconcile'] });
      void qc.invalidateQueries({ queryKey: ['assets'] });
      void qc.invalidateQueries({ queryKey: ['overview'] });
    } catch (e) {
      setActionResult({ ok: false, text: String(e) });
    } finally {
      setBusyKey('');
    }
  }

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

      {rc.data && rc.data.summary.total > 0 && (
        <div className="reconcile-warn">
          <div className="reconcile-warn-head">
            ⚠ 平台对账
            <span className="en">RECONCILE · 声明平台 vs 采集实际 + 库内真源 vs 生产 · {rc.data.summary.total} 项差异待确认</span>
          </div>
          {(rc.data?.items ?? []).slice(0, 40).map((item) => (
            <Panel key={item.key} title={`${RECONCILE_LABEL[item.type]} · ${item.name}`} en={`${item.platform} · ${item.key}`}>
              <div className="dim" style={{ fontSize: 'var(--fs-l1)' }}>{item.detail}</div>
              {item.relatedKeys && item.relatedKeys.length > 0 && (
                <div className="dim" style={{ fontSize: 'var(--fs-label)' }}>关联差异：{item.relatedKeys.join(' · ')}</div>
              )}
              {item.copies.map((c) => (
                <div key={`${c.assetId}:${c.path}`} className="mono dim" style={{ fontSize: 'var(--fs-label)' }}>
                  {c.path || c.assetId}
                  {c.sha ? ` · ${String(c.sha).slice(0, 12)}` : ''}
                  {c.platforms.length > 0 ? ` · ${c.platforms.join('+')}` : ''}
                </div>
              ))}
              {item.diff && item.diff.length > 0 && item.diff[0] !== '(一致)' && item.diff[0] !== '(无差异)' && (
                <div
                  style={{
                    margin: '6px 0 0',
                    padding: '6px 8px',
                    maxHeight: item.splitRows ? 320 : 220,
                    overflow: 'auto',
                    border: '1px dashed var(--khaki)',
                  }}
                >
                  <SplitDiff
                    rows={item.splitRows}
                    lines={item.diff}
                    leftLabel={item.key.startsWith('store:') ? '库内真源' : item.key.startsWith('drift:multica:') ? 'multica 平台' : item.key.startsWith('drift:skill:') ? 'multica 副本' : '基准侧'}
                    rightLabel={item.key.startsWith('store:') ? '生产实测' : item.key.startsWith('drift:multica:') ? '物化 workdir' : item.key.startsWith('drift:skill:') ? '本地副本' : '对比侧'}
                  />
                </div>
              )}
              <div className="row mt" style={{ gap: 8, flexWrap: 'wrap' }}>
                {item.actions.map((a) => (
                  <button
                    key={a.id}
                    className={`btn small ${a.executable ? (a.direction === 'platform-to-local' ? 'btn-amber' : 'btn-mint') : 'btn-ghost'}`}
                    disabled={busyKey === `${item.key}:${a.id}`}
                    title={!a.executable ? a.note : DIRECTION_LABEL[a.direction]}
                    onClick={() => void runReconcileAction(item, a)}
                  >
                    {a.direction === 'platform-to-local' ? '⇠' : '⇢'} {a.label}
                    {!a.executable ? ' ·手动' : ''}
                  </button>
                ))}
              </div>
            </Panel>
          ))}
        </div>
      )}
      {actionResult && (
        <div className="panel-flat mt">
          <span className="row" style={{ gap: 8 }}>
            <Badge tone={actionResult.ok ? 'ok' : 'bad'}>{actionResult.ok ? '已执行' : '失败'}</Badge>
          </span>
          <pre style={{ whiteSpace: 'pre-wrap', margin: '6px 0 0', fontSize: 'var(--fs-l1)', fontFamily: 'var(--font-mono)' }}>{actionResult.text}</pre>
        </div>
      )}

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
                  {r.meta?.criticality && <Chip>{r.meta.criticality}</Chip>}
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
