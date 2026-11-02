import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { apiGet } from '../api';
import type { AssetLite } from '../types';
import { Badge, DataTable, KV, Panel, SectionHeader, StatusBadge } from '../components/ui';
import type { PageCtx } from './ctx';

interface ServicePayload {
  scope?: string;
  active?: string;
  sub?: string;
  enabled?: string;
  execStart?: string;
  envFile?: string;
  mainPid?: number;
  since?: string;
  children?: Array<{ pid: number; up: string; args: string }>;
  trigger?: string;
  note?: string;
  stale?: boolean;
  daemon?: string;
}

export function ServicesPage(_ctx: { ctx: PageCtx }) {
  const services = useQuery({ queryKey: ['assets', 'service'], queryFn: () => apiGet<{ assets: AssetLite[] }>('/api/assets?kind=service'), refetchInterval: 20_000 });
  const [sel, setSel] = useState<string | null>(null);

  const rows = services.data?.assets ?? [];
  const systemd = rows.filter((s) => s.source.path.startsWith('systemd://'));
  const repoSync = rows.filter((s) => s.id.startsWith('service:repo-sync'));
  const winBridges = rows.filter((s) => s.id.startsWith('service:winbridge'));
  const others = rows.filter((s) => !systemd.includes(s) && !repoSync.includes(s) && !winBridges.includes(s));
  const selId = sel ?? systemd[0]?.id ?? rows[0]?.id ?? null;
  const selected = rows.find((s) => s.id === selId);
  const p = (selected?.payload ?? {}) as ServicePayload;

  return (
    <div>
      <div className="page-head">
        <div>
          <h2>服务</h2>
          <div className="sub tagline">SERVICES · systemd {systemd.length} · repo-sync {repoSync.length} · Windows 桥 {winBridges.length} · 平台 {others.length}</div>
        </div>
      </div>

      <div className="grid" style={{ gridTemplateColumns: '1.2fr 1fr' }}>
        <div className="col">
          <Panel title="服务树" en="SERVICE TREE · 状态 20s 刷新">
            <DataTable
              rows={rows}
              selectedId={selId ?? undefined}
              onRowClick={(r) => setSel(r.id)}
              cols={[
                { key: 'name', head: '名称 NAME', render: (r) => <span className="mono">{r.name}</span> },
                { key: 'status', head: '状态', render: (r) => <StatusBadge status={`${(r.payload as ServicePayload).active ?? 'n/a'}`} /> },
                { key: 'en', head: '启用', render: (r) => <span className="mono dim">{(r.payload as ServicePayload).enabled ?? '—'}</span> },
                { key: 'kids', head: '子进程', render: (r) => <span className="mono">{(r.payload as ServicePayload).children?.length ?? 0}</span> },
                { key: 'trigger', head: '触发', render: (r) => <span className="dim">{(r.payload as ServicePayload).trigger ?? r.source.path.split('/')[2] ?? ''}</span> },
              ]}
            />
          </Panel>
        </div>
        <div className="col">
          <div className="panel">
            <div className="panel-title">
              详情 <span className="en">{selected?.name ?? '—'}</span>
            </div>
            <KV
              items={[
                ['ExecStart', <span className="mono" style={{ fontSize: 'var(--fs-l1)' }}>{p.execStart ?? p.daemon ?? '—'}</span>],
                ['EnvironmentFile', <span className="mono dim">{p.envFile ?? '—'}</span>],
                ['MainPID', p.mainPid ? <span className="mono">#{p.mainPid}</span> : '—'],
                ['since', <span className="mono dim">{p.since ?? '—'}</span>],
                ['trigger', p.trigger ?? '—'],
                ['note', (p.note ?? '') + (p.stale ? ' · 疑似旧桥（已被 systemd 取代）' : '')],
              ]}
            />
          </div>
          {p.children && p.children.length > 0 && (
            <>
              <SectionHeader no="01" title="子进程树" en={`CHILDREN · ${p.children.length}`} />
              <div className="panel-flat" style={{ maxHeight: 320, overflow: 'auto' }}>
                {p.children.map((c) => (
                  <div key={c.pid} className="mono" style={{ fontSize: 'var(--fs-l1)', padding: '2px 0' }}>
                    <span className="dim">#{c.pid}</span> <span className="dim">up {c.up}</span> {c.args.slice(0, 110)}
                  </div>
                ))}
              </div>
            </>
          )}
        </div>
      </div>

      <SectionHeader no="02" title="说明" en="NOTES" />
      <div className="panel-flat" style={{ fontSize: 'var(--fs-l1)' }}>
        常驻树根 = <span className="mono">toolchain-start-all.service</span>（系统级）→ repo-sync ×3 → multica daemon（前台 exec）。{' '}
        Windows 桥由登录计划任务触发 <span className="mono">wsl.exe</span>；hindsight 不常驻（走 CC hook 按事件触发）。
        <div className="row mt">
          <Badge tone="ok">running</Badge>
          <Badge tone="warn">degraded/paused</Badge>
          <Badge tone="bad">failed</Badge>
          <Badge tone="off">disabled/inactive</Badge>
        </div>
      </div>
    </div>
  );
}
