import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { apiGet } from '../api';
import type { AssetLite } from '../types';
import { Badge, DataTable, JsonView, Panel, SectionHeader, StatusBadge } from '../components/ui';
import type { PageCtx } from './ctx';

interface ApPayload {
  triggers?: Array<{ kind: string; cron_expression?: string; timezone?: string; enabled?: boolean; next_run_at?: string }>;
  assignee?: string;
  status?: string;
  lastRunAt?: string;
  lastRunStatus?: string;
  nextRunAt?: string;
  purpose?: string;
  reviewKind?: string;
  script?: boolean;
}

export function AutopilotsPage({ ctx }: { ctx: PageCtx }) {
  const all = useQuery({
    queryKey: ['assets', 'autopilot-registration,autopilot-script', ctx.workspace],
    queryFn: () => apiGet<{ assets: AssetLite[] }>(`/api/assets?kind=autopilot-registration,autopilot-script${ctx.workspace ? `&workspace=${ctx.workspace}` : ''}`),
  });
  const [sel, setSel] = useState<string | null>(null);
  const rows = all.data?.assets ?? [];
  const selId = sel ?? rows[0]?.id ?? null;
  const selected = rows.find((r) => r.id === selId);
  const p = (selected?.payload ?? {}) as ApPayload;

  return (
    <div>
      <div className="page-head">
        <div>
          <h2>巡逻</h2>
          <div className="sub tagline">AUTOPILOTS · {rows.length} 个 · 调度全在 multica 平台 cron trigger（脚本在 dev-forge）</div>
        </div>
      </div>

      <DataTable
        rows={rows}
        selectedId={selId ?? undefined}
        onRowClick={(r) => setSel(r.id)}
        cols={[
          { key: 'name', head: '名称 NAME', render: (r) => <span className="mono">{r.name}</span> },
          {
            key: 'cron',
            head: '调度 SCHEDULE',
            render: (r) => {
              const trs = (r.payload as ApPayload).triggers ?? [];
              return trs.length ? (
                <span className="mono">{trs.map((t) => t.cron_expression ?? t.kind).join(' / ')}</span>
              ) : (
                <span className="dim">（脚本/评审型 · 平台侧登记）</span>
              );
            },
          },
          { key: 'agent', head: 'AGENT', render: (r) => <Badge tone="plain">{(r.payload as ApPayload).assignee ?? '—'}</Badge> },
          { key: 'last', head: '上次运行', render: (r) => <span className="mono dim">{(r.payload as ApPayload).lastRunAt?.slice(0, 16).replace('T', ' ') ?? '—'} {(r.payload as ApPayload).lastRunStatus ? <StatusBadge status={(r.payload as ApPayload).lastRunStatus!} /> : null}</span> },
          { key: 'next', head: '下次', render: (r) => <span className="mono dim">{(r.payload as ApPayload).nextRunAt?.slice(0, 16).replace('T', ' ') ?? '—'}</span> },
          { key: 'st', head: '状态', render: (r) => <StatusBadge status={(r.payload as ApPayload).status ?? (r.enabled ? 'active' : 'off')} /> },
        ]}
      />

      {selected && (
        <>
          <SectionHeader no="01" title={`详情 · ${selected.name}`} en="DETAIL" />
          <div className="grid grid-2">
            <Panel title="定义" en="DEFINITION">
              <div className="kv">
                <dt>assignee</dt><dd>{p.assignee ?? '—'}</dd>
                <dt>status</dt><dd><StatusBadge status={p.status ?? '?'} /></dd>
                <dt>类型</dt><dd>{p.script ? '脚本型（dev-forge autopilots/）' : p.reviewKind ? `agent 评审型（${p.reviewKind}）` : '平台原生'}</dd>
                <dt>purpose</dt><dd className="dim" style={{ fontSize: 'var(--fs-l1)' }}>{p.purpose ?? selected.summary}</dd>
                <dt>源</dt><dd className="mono dim" style={{ fontSize: 'var(--fs-l1)' }}>{selected.source.path}</dd>
              </div>
              {(p.triggers ?? []).map((t, i) => (
                <div key={i} className="row mt">
                  <span className="mono">{t.cron_expression ?? t.kind}</span>
                  <span className="dim">{t.timezone}</span>
                  <Badge tone={t.enabled ? 'ok' : 'off'}>{t.enabled ? 'enabled' : 'off'}</Badge>
                </div>
              ))}
            </Panel>
            <Panel title="平台数据" en="RAW PAYLOAD" >
              <JsonView data={selected.payload} max={20} />
            </Panel>
          </div>
        </>
      )}

      <SectionHeader no="02" title="kill-switch 机制" en="KILL SWITCH" />
      <div className="panel-flat" style={{ fontSize: 'var(--fs-l1)' }}>
        共享单源：<span className="mono">~/.multica/toolchain-reports/DISABLED</span> 文件存在即全停（<span className="mono">kill_switch.py</span> 单源实现，KILL_SWITCH env 可覆写）。架构巡逻产物在 <span className="mono">~/.multica/arch-patrol/last_report.json</span>。
      </div>
    </div>
  );
}
