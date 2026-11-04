import { useQuery, useQueryClient } from '@tanstack/react-query';
import { useState } from 'react';
import { apiGet, apiPost } from '../api';
import type { AssetLite } from '../types';
import { Badge, Chip, DataTable, KV, Panel, SectionHeader, StatusBadge } from '../components/ui';
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

function unitOf(a: AssetLite): string {
  return a.source.path.split('/').pop() ?? '';
}

function unitOfRs(a: AssetLite): string {
  return a.id.replace('service:repo-sync-', '');
}

function canToggle(a: AssetLite): boolean {
  const p2 = a.payload as ServicePayload;
  if (a.provenance !== 'first-party') return false;
  if (a.id.startsWith('service:repo-sync-')) return true;
  return p2.scope === 'user' && a.source.path.startsWith('systemd://user/');
}

interface ServiceSwitchProps {
  row: AssetLite;
  actionMsg?: string;
  onAction: (row: AssetLite, action: 'start' | 'stop' | 'restart') => void;
}

export function ServiceSwitch({ row, actionMsg, onAction }: ServiceSwitchProps) {
  const payload = row.payload as ServicePayload;
  if (actionMsg) return <span className="badge badge-plain">{actionMsg}</span>;
  if (payload.active === 'disabled') {
    return <span className="badge badge-off" title={payload.trigger ?? '已手动停用（enabled=false）'}>已停用（enabled=false）</span>;
  }
  if (!canToggle(row)) {
    const why = row.provenance !== 'first-party' ? 'EXT 外部' : payload.scope !== 'user' ? 'system 级需 root' : '非受管来源';
    return <span className="badge badge-off" title={why}>开关 {why}</span>;
  }
  const running = payload.active === 'active';
  return (
    <span className="row" style={{ gap: 4 }}>
      <button className={`btn small ${running ? 'btn-amber' : 'btn-mint'}`} onClick={(e) => { e.stopPropagation(); onAction(row, running ? 'stop' : 'start'); }}>
        {running ? '■ 停止' : '▶ 启动'}
      </button>
      <button className="btn small btn-ghost" onClick={(e) => { e.stopPropagation(); onAction(row, 'restart'); }}>↻</button>
    </span>
  );
}

function MetaChips({ meta }: { meta?: AssetLite['meta'] }) {
  if (!meta) return <span className="dim">—</span>;
  return (
    <span className="row">
      {meta.owner && <Chip>owner {meta.owner}</Chip>}
      {meta.category && <Chip>{meta.category}</Chip>}
      {meta.lifecycle && <Chip>{meta.lifecycle}</Chip>}
      {meta.criticality && <Chip>criticality {meta.criticality}</Chip>}
      {meta.runtime && <Chip>{meta.runtime}</Chip>}
    </span>
  );
}

export function ServicesPage(_props: { ctx: PageCtx }) {
  const queryClient = useQueryClient();
  const services = useQuery({ queryKey: ['assets', 'service'], queryFn: () => apiGet<{ assets: AssetLite[] }>('/api/assets?kind=service'), refetchInterval: 20_000 });
  const [sel, setSel] = useState<string | null>(null);
  const [actionMsg, setActionMsg] = useState<Record<string, string>>({});

  async function runAction(a: AssetLite, action: 'start' | 'stop' | 'restart'): Promise<void> {
    const unit = a.id.startsWith('service:repo-sync-') ? `repo-sync-${unitOfRs(a)}` : unitOf(a);
    const isConsole = unit.startsWith('forge-console');
    const tip =
      action === 'stop' && isConsole
        ? `即将停止 forge-console 自身！停止后本页面失联，恢复需在终端执行 systemctl --user start forge-console。确认停止 ${unit}？`
        : `确认对自建服务 ${unit} 执行 ${action}？`;
    if (!window.confirm(tip)) return;
    setActionMsg((m) => ({ ...m, [a.id]: `${action}…` }));
    try {
      const r = await apiPost<{ ok: boolean; output?: string }>('/api/services/actions', { unit, action });
      setActionMsg((m) => ({ ...m, [a.id]: r.ok ? `${action} ✓` : `${action} ✕ ${r.output ?? ''}`.slice(0, 80) }));
    } catch (e) {
      setActionMsg((m) => ({ ...m, [a.id]: `${action} ✕ ${String(e).slice(0, 80)}` }));
    }
    setTimeout(() => void queryClient.invalidateQueries({ queryKey: ['assets', 'service'] }), 2500);
  }

  const rows = [...(services.data?.assets ?? [])].sort((a, b) => a.id.localeCompare(b.id));
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

      <div className="grid" style={{ gridTemplateColumns: '1.8fr 0.75fr' }}>
        <div className="col">
          <Panel title="服务树" en="SERVICE TREE · 状态 20s 刷新">
            <DataTable
              rows={rows}
              selectedId={selId ?? undefined}
              onRowClick={(r) => setSel(r.id)}
              cols={[
                {
                  key: 'name',
                  head: '名称 NAME',
                  render: (r) => (
                    <span className="row" style={{ gap: 4 }}>
                      <span className="mono">{r.name}</span>
                      {r.provenance === 'first-party' ? (
                        <Badge tone="ok" title={`own${r.meta?.owner ? ` · owner ${r.meta.owner}` : ''}`}>OWN</Badge>
                      ) : (
                        <Badge tone="off">EXT</Badge>
                      )}
                    </span>
                  ),
                },
                { key: 'status', head: '状态', render: (r) => <StatusBadge status={`${(r.payload as ServicePayload).active ?? 'n/a'}`} /> },
                { key: 'en', head: '启用', render: (r) => <span className="mono dim">{(r.payload as ServicePayload).enabled ?? '—'}</span> },
                { key: 'kids', head: '子进程', render: (r) => <span className="mono">{(r.payload as ServicePayload).children?.length ?? 0}</span> },
                { key: 'trigger', head: '启动时机', render: (r) => <span className="dim">{(r.payload as ServicePayload).trigger ?? r.source.path.split('/')[2] ?? ''}</span> },
                {
                  key: 'switch',
                  head: '启停开关',
                  render: (r) => <ServiceSwitch row={r} actionMsg={actionMsg[r.id]} onAction={(a, action) => void runAction(a, action)} />,
                },
              ]}
            />
          </Panel>
          <div className="panel-flat" style={{ fontSize: 'var(--fs-l1)' }}>
            <div className="tagline mb">说明 NOTES</div>
            常驻树根 = <span className="mono">toolchain-start-all.service</span>（系统级，驻留监督）→ repo-sync（按注册 enabled 开关，缺失补拉）＋独立 multica daemon。{' '}
            Windows 桥由登录计划任务触发 <span className="mono">wsl.exe</span>；hindsight 不常驻（走 CC hook 按事件触发）。
            <div className="row mt">
              <Badge tone="ok">running</Badge>
              <Badge tone="warn">degraded/paused</Badge>
              <Badge tone="bad">failed</Badge>
              <Badge tone="off">disabled/inactive</Badge>
            </div>
          </div>
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
                ['meta', <MetaChips meta={selected?.meta} />],
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
    </div>
  );
}
