import { useQuery } from '@tanstack/react-query';
import { apiGet } from '../api';
import type { MigrationView } from '../types';
import { Badge, DataTable, DiffView, Panel, SectionHeader } from '../components/ui';
import type { PageCtx } from './ctx';

export function MigrationPage(_props: { ctx: PageCtx }) {
  const mv = useQuery({ queryKey: ['migration'], queryFn: () => apiGet<MigrationView>('/api/migration') });
  if (!mv.data) return <div className="dim">加载中…</div>;
  const v = mv.data;

  return (
    <div>
      <div className="page-head">
        <div>
          <h2>迁移</h2>
          <div className="sub tagline">MIGRATION · 资产级投影 · 目标平台 multica · 只生成不执行（DRY-RUN）</div>
        </div>
        <div className="page-actions">
          <select className="search" defaultValue="multica">
            <option value="multica">目标: multica</option>
          </select>
          <span className="stat" style={{ padding: '2px 12px' }}>
            <span className="num" style={{ fontSize: 'var(--fs-l4)' }}>{v.coveragePct}%</span>
          </span>
        </div>
      </div>

      <div className="grid grid-2">
        <Panel title="覆盖矩阵" en={`COVERAGE MATRIX · ${v.coveragePct}%`}>
          <DataTable
            rows={v.rows.map((r) => ({ id: r.kind, ...r }))}
            cols={[
              { key: 'kind', head: '资产类型', render: (r) => <span className="mono">{r.kind}</span> },
              { key: 'count', head: '数量', render: (r) => <span className="mono">{r.covered}/{r.total}</span> },
              { key: 'st', head: '可映性', render: (r) => (r.status === 'ok' ? <Badge tone="ok">● 可映</Badge> : r.status === 'gap' ? <Badge tone="warn">⚠ 缺口</Badge> : <Badge tone="off">—</Badge>) },
              { key: 'note', head: '通道', render: (r) => <span className="dim" style={{ fontSize: 'var(--fs-l1)' }}>{r.note}</span> },
            ]}
          />
        </Panel>
        <Panel title="缺口与策略" en={`GAPS & STRATEGY · ${v.gaps.length}`}>
          <div style={{ maxHeight: 300, overflow: 'auto' }}>
            {v.gaps.map((g) => (
              <div key={g.assetId} className="row" style={{ padding: '3px 0', borderBottom: '1px solid var(--khaki)' }}>
                <Badge tone="warn">{g.kind}</Badge>
                <span className="mono" style={{ fontSize: 'var(--fs-l1)' }}>{g.name}</span>
                <span className="dim" style={{ fontSize: 'var(--fs-l1)', flex: 1 }}>{g.strategy}</span>
              </div>
            ))}
            {v.gaps.length === 0 && <div className="dim">无缺口</div>}
          </div>
        </Panel>
      </div>

      <SectionHeader no="01" title="instructions 一致性 dry-run" en="PLATFORM vs 物化 WORKDIR（最新采样）" />
      <div className="grid grid-2">
        {v.diffs.map((d) => (
          <div key={d.agent} className="panel-flat">
            <div className="row mb">
              <span style={{ fontWeight: 700 }}>{d.agent}</span>
              <Badge tone={d.identical ? 'ok' : 'warn'}>{d.identical ? '一致' : '漂移'}</Badge>
              <span className="mono dim" style={{ fontSize: 'var(--fs-label)' }}>{d.materializedPath}</span>
            </div>
            {!d.identical && <DiffView lines={d.diff.slice(0, 40)} />}
          </div>
        ))}
        {v.diffs.length === 0 && <div className="dim panel-flat">（暂无 workdir 采样 — multica 采集器运行后可用）</div>}
      </div>

      <SectionHeader no="02" title="导出脚本预览" en="EXPORT SCRIPT · 人工评审后执行" />
      <pre className="code">{v.commands.join('\n')}</pre>
    </div>
  );
}
