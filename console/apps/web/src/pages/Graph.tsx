import { useQuery } from '@tanstack/react-query';
import { useMemo, useState } from 'react';
import { apiGet } from '../api';
import type { GraphData } from '../types';
import { Badge, KV, Panel } from '../components/ui';
import type { PageCtx } from './ctx';

const KIND_ORDER = ['project', 'agent', 'instruction', 'skill', 'hook-registration', 'hook-rule', 'hook-script', 'service', 'autopilot', 'adapter', 'mcp-endpoint', 'report', 'env', 'custom'];
const KIND_COLOR: Record<string, string> = {
  project: 'var(--accent)',
  agent: 'var(--mint)',
  instruction: 'var(--amber)',
  skill: 'var(--mint)',
  'hook-rule': 'var(--accent)',
  'hook-script': 'var(--khaki)',
  service: 'var(--gray)',
  autopilot: 'var(--amber)',
};

interface Pos { x: number; y: number }

export function GraphPage(_props: { ctx: PageCtx }) {
  const graph = useQuery({ queryKey: ['graph'], queryFn: () => apiGet<GraphData>('/api/graph') });
  const [sel, setSel] = useState<string | null>(null);
  const [kindFilter, setKindFilter] = useState<string>('');

  const nodes = useMemo(() => (graph.data?.nodes ?? []).filter((n) => !kindFilter || n.kind === kindFilter), [graph.data, kindFilter]);
  const edges = useMemo(() => {
    const ids = new Set(nodes.map((n) => n.id));
    return (graph.data?.edges ?? []).filter((e) => ids.has(e.from) && ids.has(e.to));
  }, [graph.data, nodes]);

  // 分层布局：按 kind 列排布
  const layout = useMemo(() => {
    const cols = KIND_ORDER.filter((k) => nodes.some((n) => n.kind === k));
    const posById = new Map<string, Pos>();
    const colX = new Map<string, number>();
    cols.forEach((k, i) => colX.set(k, 30 + i * 150));
    const perKindY = new Map<string, number>();
    for (const n of nodes) {
      const x = colX.get(n.kind) ?? 30;
      const y = 44 + (perKindY.get(n.kind) ?? 0);
      perKindY.set(n.kind, y + 26);
      posById.set(n.id, { x, y });
    }
    const height = 44 + Math.max(...[...perKindY.values(), 0]);
    const width = 60 + cols.length * 150;
    return { posById, cols, colX, height, width };
  }, [nodes]);

  const selected = graph.data?.nodes.find((n) => n.id === sel);
  const selEdges = edges.filter((e) => e.from === sel || e.to === sel);

  return (
    <div>
      <div className="page-head">
        <div>
          <h2>关系图</h2>
          <div className="sub tagline">GRAPH · {nodes.length} 节点 · {edges.length} 边 · 分层血缘（非力导向）</div>
        </div>
        <div className="page-actions">
          <select className="search" value={kindFilter} onChange={(e) => setKindFilter(e.target.value)}>
            <option value="">全部类型</option>
            {KIND_ORDER.map((k) => (
              <option key={k} value={k}>{k}</option>
            ))}
          </select>
        </div>
      </div>

      <div className="grid" style={{ gridTemplateColumns: '1fr 280px' }}>
        <div className="panel-flat" style={{ overflow: 'auto' }}>
          <svg width={layout.width} height={layout.height} style={{ display: 'block' }}>
            {layout.cols.map((k) => (
              <text key={k} x={(layout.colX.get(k) ?? 0) + 6} y={22} className="graph-lane">
                {k}
              </text>
            ))}
            {edges.map((e, i) => {
              const a = layout.posById.get(e.from);
              const b = layout.posById.get(e.to);
              if (!a || !b) return null;
              const highlight = sel && (e.from === sel || e.to === sel);
              return (
                <path
                  key={i}
                  className="graph-edge"
                  d={`M ${a.x + 92} ${a.y + 8} C ${a.x + 130} ${a.y + 8}, ${b.x - 30} ${b.y + 8}, ${b.x} ${b.y + 8}`}
                  stroke={highlight ? 'var(--accent)' : 'var(--gray)'}
                  strokeWidth={highlight ? 2 : 1}
                  strokeDasharray={e.type === 'derived-from' ? '3 2' : undefined}
                />
              );
            })}
            {nodes.map((n) => {
              const p = layout.posById.get(n.id)!;
              return (
                <g key={n.id} onClick={() => setSel(n.id)} style={{ cursor: 'pointer' }}>
                  <rect
                    x={p.x}
                    y={p.y}
                    width={92}
                    height={16}
                    fill={n.id === sel ? 'var(--ink)' : 'var(--paper-warm)'}
                    stroke="var(--ink)"
                    strokeWidth={1}
                  />
                  <rect x={p.x} y={p.y} width={3} height={16} fill={KIND_COLOR[n.kind] ?? 'var(--gray)'} />
                  <text x={p.x + 7} y={p.y + 12} className="graph-text" fill={n.id === sel ? 'var(--paper-warm)' : 'var(--text-sub)'}>
                    {n.name.length > 12 ? n.name.slice(0, 12) + '…' : n.name}
                  </text>
                </g>
              );
            })}
          </svg>
        </div>
        <div className="col">
          <Panel title={selected?.name ?? '选中节点'} en={selected?.kind.toUpperCase() ?? 'INSPECTOR'}>
            {selected ? (
              <KV
                items={[
                  ['kind', <Badge tone="plain">{selected.kind}</Badge>],
                  ['挂载', <span className="mono">{selected.attach.level}{selected.attach.ref ? ` · ${selected.attach.ref}` : ''}</span>],
                  ['归属', selected.provenance === 'first-party' ? <Badge tone="ok">first-party</Badge> : <Badge tone="off">third-party</Badge>],
                  ['id', <span className="mono dim" style={{ fontSize: 'var(--fs-label)' }}>{selected.id}</span>],
                ]}
              />
            ) : (
              <div className="dim">点击图中节点查看</div>
            )}
          </Panel>
          <Panel title="关联边" en={`EDGES · ${selEdges.length}`}>
            {selEdges.map((e, i) => (
              <div key={i} className="mono" style={{ fontSize: 'var(--fs-l1)', padding: '2px 0' }}>
                <span className="dim">{e.from.split(':')[1] ?? e.from}</span>
                <Badge tone="plain">{e.type}</Badge>
                <span className="dim">{e.to.split(':')[1] ?? e.to}</span>
              </div>
            ))}
            {selEdges.length === 0 && <div className="dim">—</div>}
          </Panel>
          <Panel title="图例" en="LEGEND">
            <div style={{ fontSize: 'var(--fs-l1)', lineHeight: 2 }}>
              <div><Badge tone="plain">mounts</Badge> 规则挂载脚本</div>
              <div><Badge tone="plain">schedules</Badge> 服务调度</div>
              <div><Badge tone="plain">references</Badge> 引用</div>
              <div><Badge tone="plain">runs-as</Badge> 以 agent 运行</div>
              <div><Badge tone="plain">derived-from</Badge> 派生（虚线）</div>
            </div>
          </Panel>
        </div>
      </div>
    </div>
  );
}
