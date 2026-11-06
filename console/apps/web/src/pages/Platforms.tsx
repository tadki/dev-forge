import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { apiGet } from '../api';
import type { PlatformKindContract, PlatformReadChannel, PlatformsView, PlatformWriteChannel } from '../types';
import { Badge, Chip, Panel } from '../components/ui';
import { KIND_ORDER } from '../kinds';
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

const SMALL = { fontSize: 'var(--fs-l1)' } as const;
const LABEL = { fontSize: 'var(--fs-label)' } as const;
const PANEL_FILL = { display: 'flex', flexDirection: 'column', minHeight: 0 } as const;
const SCROLL = { flex: 1, minHeight: 0, overflowY: 'auto' } as const;

function readTone(read?: PlatformReadChannel) {
  if (!read) return 'off' as const;
  return read.how === 'cli' ? ('ok' as const) : read.how === 'none' ? ('off' as const) : ('plain' as const);
}

function writeTone(write?: PlatformWriteChannel) {
  if (!write) return 'off' as const;
  return write.type === 'command' ? ('ok' as const) : write.type === 'none' ? ('off' as const) : ('plain' as const);
}

function Dash() {
  return <span className="dim">—</span>;
}

function FieldLine({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="row" style={{ gap: 6, alignItems: 'baseline', padding: '1px 0' }}>
      <span className="mono dim" style={{ ...LABEL, minWidth: 64 }}>
        {label}
      </span>
      <span style={{ flex: 1 }}>{children}</span>
    </div>
  );
}

/** 读通道全字段：缺失字段显示 —，与未适配一眼可辨 */
function ReadCell({ read }: { read?: PlatformReadChannel }) {
  return (
    <div>
      <FieldLine label="方式">{read ? <Badge tone={readTone(read)}>{READ_HOW_LABEL[read.how]}</Badge> : <Badge tone="off">未适配</Badge>}</FieldLine>
      <FieldLine label="采集器">
        {read?.collector ? (
          <span className="mono" style={SMALL}>
            {read.collector}
          </span>
        ) : (
          <Dash />
        )}
      </FieldLine>
      <FieldLine label="发现命令">
        {read?.cmd ? (
          <span className="mono" style={SMALL}>
            {read.cmd.join(' ')}
          </span>
        ) : (
          <Dash />
        )}
      </FieldLine>
      <FieldLine label="详情命令">
        {read?.detailCmd ? (
          <span className="mono dim" style={SMALL}>
            {read.detailCmd.join(' ')}
          </span>
        ) : (
          <Dash />
        )}
      </FieldLine>
      <FieldLine label="路径">
        {read?.paths?.length ? (
          <span className="mono dim" style={SMALL}>
            {read.paths.join(' · ')}
          </span>
        ) : (
          <Dash />
        )}
      </FieldLine>
      <FieldLine label="说明">
        {read?.note ? (
          <span className="dim" style={SMALL}>
            {read.note}
          </span>
        ) : (
          <Dash />
        )}
      </FieldLine>
    </div>
  );
}

/** 写通道全字段：缺失字段显示 — */
function WriteCell({ write }: { write?: PlatformWriteChannel }) {
  return (
    <div>
      <FieldLine label="方式">{write ? <Badge tone={writeTone(write)}>{WRITE_TYPE_LABEL[write.type]}</Badge> : <Badge tone="off">未适配</Badge>}</FieldLine>
      <FieldLine label="命令">
        {write?.cmd ? (
          <span className="mono" style={SMALL}>
            {write.cmd.join(' ')}
          </span>
        ) : (
          <Dash />
        )}
      </FieldLine>
      <FieldLine label="platformId">{write?.platformIdFrom ? <Chip>platformId ← {write.platformIdFrom}</Chip> : <Dash />}</FieldLine>
      <FieldLine label="建议">
        {write?.advice ? (
          <span className="dim" style={SMALL}>
            {write.advice}
          </span>
        ) : (
          <Dash />
        )}
      </FieldLine>
    </div>
  );
}

interface KindRow extends PlatformKindContract {
  id: string;
}

export function PlatformsPage(_props: { ctx: PageCtx }) {
  const q = useQuery({ queryKey: ['platforms'], queryFn: () => apiGet<PlatformsView>('/api/platforms') });
  const [selPlatformId, setSelPlatformId] = useState<string | null>(null);
  const [selKey, setSelKey] = useState<string | null>(null);
  if (!q.data) return <div className="dim">加载中…</div>;
  const v = q.data;
  const adapted = v.platforms.reduce((n, p) => n + p.totalAssets, 0);
  const grandTotal = adapted + v.unadapted.assetCount;
  const p = v.platforms.find((x) => x.id === selPlatformId) ?? v.platforms[0];
  if (!p) return <div className="dim">无已适配平台（console/platforms.d 为空）</div>;
  // 契约列表 = 全部资产大类（YAML 未声明的 kind 也占一行，标未适配）
  const rows: KindRow[] = KIND_ORDER.map((kind) => {
    const decl = p.kinds.find((k) => k.kind === kind);
    return {
      id: `${p.id}:${kind}`,
      kind,
      declared: !!decl,
      read: decl?.read,
      write: decl?.write,
      assetCount: decl?.assetCount ?? 0,
      collectors: decl?.collectors ?? [],
      assets: decl?.assets ?? [],
    };
  });
  // 详情默认展示首个 kind，切换平台时重置
  const sel = rows.find((r) => r.id === selKey) ?? rows[0];

  return (
    <div style={{ height: '100%', display: 'flex', flexDirection: 'column', minHeight: 0 }}>
      <div className="page-head">
        <div>
          <h2>平台</h2>
          <div className="sub tagline">
            PLATFORMS · {v.platforms.length} 平台 · {adapted}/{grandTotal} 资产已适配 · 契约 console/platforms.d
          </div>
        </div>
      </div>

      {v.diagnostics.length > 0 && (
        <Panel title="声明诊断" en={`DIAGNOSTICS · ${v.diagnostics.length}`} style={{ marginBottom: 'var(--sp-3)' }}>
          {v.diagnostics.map((d, i) => (
            <div key={i} className="row" style={{ padding: '3px 0' }}>
              <Badge tone={d.level === 'error' ? 'bad' : 'warn'}>{d.level}</Badge>
              <span className="mono dim" style={SMALL}>
                {d.message}
              </span>
            </div>
          ))}
        </Panel>
      )}

      <div style={{ flex: 1, minHeight: 0, display: 'grid', gridTemplateRows: 'minmax(0, 3fr) minmax(0, 1fr)', gap: 'var(--sp-4)' }}>
        <div style={{ display: 'grid', gridTemplateColumns: 'minmax(375px, 1fr) minmax(0, 5fr)', gap: 'var(--sp-4)', minHeight: 0 }}>
          <Panel style={PANEL_FILL}>
            <div className="sect" style={{ marginTop: 0 }}>
              <span className="no">01</span>
              <span className="title">适配平台</span>
              <span className="en">{v.platforms.length} ADAPTED</span>
            </div>
            <div style={SCROLL}>
              {v.platforms.map((item) => {
                const active = item.id === p.id;
                const adaptedKinds = item.kinds.filter((k) => k.declared).length;
                return (
                  <div
                    key={item.id}
                    className="platform-item"
                    onClick={() => {
                      setSelPlatformId(item.id);
                      setSelKey(null);
                    }}
                    style={{
                      cursor: 'pointer',
                      display: 'flex',
                      gap: 8,
                      alignItems: 'flex-start',
                      padding: '8px 6px',
                      borderBottom: '1px solid var(--khaki)',
                      borderLeft: active ? '3px solid var(--accent)' : '3px solid transparent',
                      background: active ? 'var(--cream)' : undefined,
                    }}
                  >
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ fontWeight: active ? 700 : 400 }}>{item.label ?? item.id}</div>
                      <div className="mono dim" style={LABEL}>
                        {item.id} · {item.matchPathPrefix.join(' ') || '—'}
                      </div>
                    </div>
                    <div style={{ textAlign: 'right' }}>
                      <Badge tone={item.totalAssets > 0 ? 'ok' : 'off'}>{item.totalAssets}</Badge>
                      <div className="dim" style={LABEL}>
                        {adaptedKinds}/{KIND_ORDER.length} kinds
                      </div>
                    </div>
                  </div>
                );
              })}
            </div>
          </Panel>

          <Panel style={PANEL_FILL}>
            <div className="sect" style={{ marginTop: 0 }}>
              <span className="no">02</span>
              <span className="title">{p.label ?? p.id}</span>
              <span className="en">
                READ / WRITE CONTRACT · {p.id} · {p.totalAssets} ASSETS · MATCH {p.matchPathPrefix.join(' ')}
              </span>
            </div>
            <div style={{ flex: 1, minHeight: 0, display: 'grid', gridTemplateColumns: 'minmax(220px, 28%) minmax(0, 1fr)', gap: 'var(--sp-3)', overflow: 'hidden' }}>
              {/* 左栏：契约单行列表（kind + 读写 badge，无具体命令），内部滚动 */}
              <div style={{ minHeight: 0, overflowY: 'auto' }}>
                {rows.map((r) => {
                  const active = r.id === sel.id;
                  return (
                    <div
                      key={r.id}
                      className="kind-item"
                      onClick={() => setSelKey(r.id)}
                      style={{
                        cursor: 'pointer',
                        display: 'flex',
                        gap: 6,
                        alignItems: 'center',
                        justifyContent: 'space-between',
                        padding: '5px 6px',
                        borderBottom: '1px solid var(--khaki)',
                        borderLeft: active ? '3px solid var(--accent)' : '3px solid transparent',
                        background: active ? 'var(--cream)' : undefined,
                      }}
                    >
                      <span className="row" style={{ gap: 6 }}>
                        <span className="mono" style={{ fontWeight: active ? 700 : 400 }}>
                          {r.kind}
                        </span>
                        {r.assetCount > 0 && (
                          <Badge tone="ok" title={`${r.assetCount} 个资产`}>
                            {r.assetCount}
                          </Badge>
                        )}
                      </span>
                      <span className="row" style={{ gap: 4 }}>
                        {r.declared ? (
                          <>
                            <Badge tone={readTone(r.read)}>{r.read ? READ_HOW_LABEL[r.read.how] : '读未声明'}</Badge>
                            <Badge tone={writeTone(r.write)}>{r.write ? WRITE_TYPE_LABEL[r.write.type] : '写未声明'}</Badge>
                          </>
                        ) : (
                          <Badge tone="off">未适配</Badge>
                        )}
                      </span>
                    </div>
                  );
                })}
              </div>

              {/* 右栏：选中契约的完整详情（全字段 + 资产清单），内部滚动 */}
              <div style={{ minHeight: 0, overflowY: 'auto', borderLeft: '1px solid var(--khaki)', paddingLeft: 'var(--sp-3)' }}>
                <div className="row mb">
                  <span className="mono" style={{ fontWeight: 700 }}>
                    {sel.kind}
                  </span>
                  <Badge tone={sel.assetCount > 0 ? 'ok' : 'off'}>{sel.assetCount} 资产</Badge>
                  {!sel.declared && <Badge tone="warn">未声明该 kind</Badge>}
                  {sel.collectors.map((c) => (
                    <Chip key={c}>{c}</Chip>
                  ))}
                </div>
                <div className="grid grid-2" style={{ alignItems: 'start' }}>
                  <div>
                    <div className="mono dim" style={{ ...LABEL, marginBottom: 4 }}>
                      读通道 READ
                    </div>
                    <ReadCell read={sel.read} />
                  </div>
                  <div>
                    <div className="mono dim" style={{ ...LABEL, marginBottom: 4 }}>
                      写通道 WRITE
                    </div>
                    <WriteCell write={sel.write} />
                  </div>
                </div>
                {sel.assets.length > 0 && (
                  <div style={{ marginTop: 'var(--sp-3)' }}>
                    <div className="mono dim" style={{ ...LABEL, marginBottom: 4 }}>
                      资产 ASSETS
                    </div>
                    {sel.assets.map((a) => (
                      <div key={a.id} className="row" style={{ padding: '3px 0', borderBottom: '1px solid var(--khaki)' }}>
                        {a.provenance === 'first-party' && (
                          <span
                            className="mono"
                            style={{
                              background: '#cca700',
                              color: 'var(--ink)',
                              borderRadius: 3,
                              padding: '0 5px',
                              fontSize: 'var(--fs-label)',
                              fontWeight: 600,
                            }}
                          >
                            自建
                          </span>
                        )}
                        <span className="mono" style={SMALL}>
                          {a.name}
                        </span>
                        <span className="mono dim" style={{ ...SMALL, flex: 1 }}>
                          {a.path}
                          {a.platformId ? ` · id ${a.platformId}` : ''}
                        </span>
                      </div>
                    ))}
                    {sel.assetCount > sel.assets.length && <div className="dim">…其余 {sel.assetCount - sel.assets.length} 个</div>}
                  </div>
                )}
              </div>
            </div>
          </Panel>
        </div>

        <Panel style={PANEL_FILL}>
          <div className="sect" style={{ marginTop: 0 }}>
            <span className="no">03</span>
            <span className="title">未适配</span>
            <span className="en">UNADAPTED · {v.unadapted.assetCount} ASSETS 无平台声明命中</span>
          </div>
          <div style={SCROLL}>
            {v.unadapted.kinds.length === 0 && <div className="dim">（无未适配资产）</div>}
            {v.unadapted.kinds.map((k) => (
              <div key={k.kind} className="row" style={{ padding: '3px 0', borderBottom: '1px solid var(--khaki)' }}>
                <Badge tone="warn">{k.count}</Badge>
                <span className="mono">{k.kind}</span>
                <span className="mono dim" style={{ ...SMALL, flex: 1 }}>
                  {k.paths.join(' · ')}
                </span>
              </div>
            ))}
          </div>
        </Panel>
      </div>
    </div>
  );
}
