import type { ReactNode } from 'react';

export function Panel({ title, en, children, ink, className = '' }: { title?: string; en?: string; children: ReactNode; ink?: boolean; className?: string }) {
  return (
    <section className={`${ink ? 'panel-ink' : 'panel'} ${className}`}>
      {title && (
        <div className={`panel-title ${ink ? '' : ''}`}>
          {title}
          {en && <span className="en">{en}</span>}
        </div>
      )}
      {children}
    </section>
  );
}

export function SectionHeader({ no, title, en }: { no: string; title: string; en: string }) {
  return (
    <div className="sect">
      <span className="no">{no}</span>
      <span className="title">{title}</span>
      <span className="en">{en}</span>
    </div>
  );
}

export type BadgeTone = 'ok' | 'warn' | 'bad' | 'off' | 'plain' | 'default';

export function Badge({ tone = 'default', children }: { tone?: BadgeTone; children: ReactNode }) {
  return <span className={`badge ${tone === 'default' ? '' : `badge-${tone}`}`}>{children}</span>;
}

export function StatusBadge({ status }: { status: string }) {
  const s = status.toLowerCase();
  const tone: BadgeTone = ['green', 'active', 'running', 'ok', 'online', 'idle', 'completed'].some((k) => s.includes(k))
    ? 'ok'
    : ['yellow', 'paused', 'warn', 'degraded'].some((k) => s.includes(k))
      ? 'warn'
      : ['redline', 'failed', 'fail', 'error', 'dead'].some((k) => s.includes(k))
        ? 'bad'
        : ['disabled', 'inactive', 'archived', 'missing', 'unreachable'].some((k) => s.includes(k))
          ? 'off'
          : 'plain';
  return <Badge tone={tone}>{status}</Badge>;
}

export function Stat({ num, label, en }: { num: ReactNode; label: string; en: string }) {
  return (
    <div className="stat">
      <div className="num">{num}</div>
      <div className="label">
        {label}
        <span className="en">{en}</span>
      </div>
    </div>
  );
}

export interface Column<T> {
  key: string;
  head: string;
  render: (row: T) => ReactNode;
  width?: string;
}

export function DataTable<T extends { id?: string }>({ cols, rows, onRowClick, selectedId }: { cols: Array<Column<T>>; rows: T[]; onRowClick?: (row: T) => void; selectedId?: string }) {
  return (
    <div className="table-wrap">
      <table className="table">
        <thead>
          <tr>
            {cols.map((c) => (
              <th key={c.key} style={c.width ? { width: c.width } : undefined}>
                {c.head}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, i) => (
            <tr
              key={row.id ?? i}
              className={selectedId !== undefined && row.id === selectedId ? 'sel' : ''}
              onClick={onRowClick ? () => onRowClick(row) : undefined}
              style={onRowClick ? { cursor: 'pointer' } : undefined}
            >
              {cols.map((c) => (
                <td key={c.key}>{c.render(row)}</td>
              ))}
            </tr>
          ))}
          {rows.length === 0 && (
            <tr>
              <td colSpan={cols.length} className="dim" style={{ padding: '12px' }}>
                （空）
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}

export function KV({ items }: { items: Array<[string, ReactNode]> }) {
  return (
    <dl className="kv">
      {items.map(([k, v], i) => (
        <div key={i} style={{ display: 'contents' }}>
          <dt>{k}</dt>
          <dd>{v}</dd>
        </div>
      ))}
    </dl>
  );
}

export function JsonView({ data, max = 60 }: { data: unknown; max?: number }) {
  let text: string;
  try {
    text = JSON.stringify(data, null, 2);
  } catch {
    text = String(data);
  }
  if (text.length > max * 1000) text = text.slice(0, max * 1000) + '\n…(截断)';
  return <pre className="code">{text}</pre>;
}

export function DiffView({ lines }: { lines: string[] }) {
  return (
    <div>
      {lines.map((l, i) =>
        l.startsWith('+') ? (
          <span key={i} className="diff-plus">{l}</span>
        ) : l.startsWith('-') ? (
          <span key={i} className="diff-minus">{l}</span>
        ) : (
          <span key={i} className="diff-line">{l}</span>
        )
      )}
    </div>
  );
}

export function Chip({ children }: { children: ReactNode }) {
  return <span className="chip">{children}</span>;
}
