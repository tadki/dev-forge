import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { apiGet } from '../api';
import type { PlatformReadChannel, PlatformsView, PlatformWriteChannel } from '../types';
import { Badge, Chip, DataTable, Panel, SectionHeader } from '../components/ui';
import type { PageCtx } from './ctx';

const READ_HOW_LABEL: Record<PlatformReadChannel['how'], string> = {
  cli: 'CLI 命令',
  file: '文件扫描',
  derived: '派生采集',
  none: '无读取',
};
const WRITE_TYPE_LABEL: Record<PlatformWriteChannel['type'], string> = {
  'file-write': '写文件',
  command: 'CLI 物化',
  none: '仅建议',
};

function ReadCell({ read }: { read?: PlatformReadChannel }) {
  if (!read) return <span className="dim">未声明读通道</span>;
  return (
    <div>
      <Badge tone={read.how === 'cli' ? 'ok' : read.how === 'none' ? 'off' : 'plain'}>{READ_HOW_LABEL[read.how]}</Badge>
      {read.cmd && (
        <div className="mono" style={{ fontSize: 'var(--fs-l1)' }}>
          {read.cmd.join(' ')}
        </div>
      )}
      {read.detailCmd && (
        <div className="mono dim" style={{ fontSize: 'var(--fs-l1)' }}>
          ↳ {read.detailCmd.join(' ')}
        </div>
      )}
      {read.paths?.map((p) => (
        <div key={p} className="mono dim" style={{ fontSize: 'var(--fs-l1)' }}>
          {p}
        </div>
      ))}
      {read.note && (
        <div className="dim" style={{ fontSize: 'var(--fs-l1)' }}>
          {read.note}
        </div>
      )}
    </div>
  );
}

function WriteCell({ write }: { write?: PlatformWriteChannel }) {
  if (!write) return <span className="dim">未声明写通道</span>;
  return (
    <div>
      <Badge tone={write.type === 'command' ? 'ok' : write.type === 'none' ? 'off' : 'plain'}>{WRITE_TYPE_LABEL[write.type]}</Badge>
      {write.cmd && (
        <div className="mono" style={{ fontSize: 'var(--fs-l1)' }}>
          {write.cmd.join(' ')}
        </div>
      )}
      {write.platformIdFrom && (
        <div>
          <Chip>platformId ← {write.platformIdFrom}</Chip>
        </div>
      )}
      {write.type === 'none' && write.advice && (
        <div className="dim" style={{ fontSize: 'var(--fs-l1)' }}>
          {write.advice}
        </div>
      )}
    </div>
  );
}

export function PlatformsPage(_props: { ctx: PageCtx }) {
  const q = useQuery({ queryKey: ['platforms'], queryFn: () => apiGet<PlatformsView>('/api/platforms') });
  // 只存选中行 key，SSE 刷新后从最新数据查行——不持有过期资产快照
  const [selKey, setSelKey] = useState<string | null>(null);
  if (!q.data) return <div className="dim">加载中…</div>;
  const v = q.data;
  const adapted = v.platforms.reduce((n, p) => n + p.totalAssets, 0);
  const grandTotal = adapted + v.unadapted.assetCount;

  return (
    <div>
      <div className="page-head">
        <div>
          <h2>平台</h2>
          <div className="sub tagline">
            PLATFORMS · {v.platforms.length} 平台 · {adapted}/{grandTotal} 资产已适配 · 契约 console/platforms.d
          </div>
        </div>
      </div>

      {v.diagnostics.length > 0 && (
        <Panel title="声明诊断" en={`DIAGNOSTICS · ${v.diagnostics.length}`}>
          {v.diagnostics.map((d, i) => (
            <div key={i} className="row" style={{ padding: '3px 0' }}>
              <Badge tone={d.level === 'error' ? 'bad' : 'warn'}>{d.level}</Badge>
              <span className="mono dim" style={{ fontSize: 'var(--fs-l1)' }}>
                {d.message}
              </span>
            </div>
          ))}
        </Panel>
      )}

      {v.platforms.map((p, i) => {
        const sel = selKey?.startsWith(`${p.id}:`) ? (p.kinds.find((k) => `${p.id}:${k.kind}` === selKey) ?? null) : null;
        return (
          <div key={p.id}>
            <SectionHeader
              no={String(i + 1).padStart(2, '0')}
              title={p.label ?? p.id}
              en={`${p.id} · ${p.totalAssets} ASSETS · MATCH ${p.matchPathPrefix.join(' ')}`}
            />
            <Panel title="读写契约" en="READ / WRITE CONTRACT">
              <DataTable
                rows={p.kinds.map((k) => ({ ...k, id: `${p.id}:${k.kind}` }))}
                selectedId={sel ? `${p.id}:${sel.kind}` : undefined}
                onRowClick={(row) => setSelKey((cur) => (cur === row.id ? null : (row.id ?? null)))}
                cols={[
                  {
                    key: 'kind',
                    head: '类型',
                    render: (r) => (
                      <span className="row">
                        <span className="mono">{r.kind}</span>
                        {!r.declared && <Badge tone="warn">未声明</Badge>}
                      </span>
                    ),
                  },
                  {
                    key: 'count',
                    head: '资产数',
                    render: (r) => (
                      <span className="row">
                        {r.assetCount > 0 ? <Badge tone="ok">{r.assetCount}</Badge> : <span className="dim">0</span>}
                        {r.collectors.map((c) => (
                          <Chip key={c}>{c}</Chip>
                        ))}
                      </span>
                    ),
                  },
                  { key: 'read', head: '读通道', render: (r) => <ReadCell read={r.read} /> },
                  { key: 'write', head: '写通道', render: (r) => <WriteCell write={r.write} /> },
                ]}
              />
            </Panel>
            {sel && (
              <Panel title={`${sel.kind} · ${sel.assetCount} 个资产`} en="ASSETS">
                {sel.assets.map((a) => (
                  <div key={a.id} className="row" style={{ padding: '3px 0', borderBottom: '1px solid var(--khaki)' }}>
                    <Badge tone={a.enabled ? 'ok' : 'off'}>{a.enabled ? '●' : '○'}</Badge>
                    <span className="mono" style={{ fontSize: 'var(--fs-l1)' }}>
                      {a.name}
                    </span>
                    <span className="mono dim" style={{ fontSize: 'var(--fs-l1)', flex: 1 }}>
                      {a.path}
                      {a.platformId ? ` · id ${a.platformId}` : ''}
                    </span>
                  </div>
                ))}
                {sel.assets.length === 0 && <div className="dim">（该 kind 当前无实有资产）</div>}
                {sel.assetCount > sel.assets.length && <div className="dim">…其余 {sel.assetCount - sel.assets.length} 个</div>}
              </Panel>
            )}
          </div>
        );
      })}

      {v.unadapted.assetCount > 0 && (
        <div>
          <SectionHeader no={String(v.platforms.length + 1).padStart(2, '0')} title="未适配" en={`UNADAPTED · ${v.unadapted.assetCount} ASSETS 无平台声明命中`} />
          <Panel title="无平台归属的资产" en="BY KIND">
            {v.unadapted.kinds.map((k) => (
              <div key={k.kind} className="row" style={{ padding: '3px 0', borderBottom: '1px solid var(--khaki)' }}>
                <Badge tone="warn">{k.count}</Badge>
                <span className="mono">{k.kind}</span>
                <span className="mono dim" style={{ fontSize: 'var(--fs-l1)', flex: 1 }}>
                  {k.paths.join(' · ')}
                </span>
              </div>
            ))}
          </Panel>
        </div>
      )}
    </div>
  );
}
