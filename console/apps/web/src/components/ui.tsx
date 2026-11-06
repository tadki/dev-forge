import type { CSSProperties, ReactNode } from 'react';

export function Panel({
  title,
  en,
  children,
  ink,
  className = '',
  style,
}: {
  title?: string;
  en?: string;
  children: ReactNode;
  ink?: boolean;
  className?: string;
  style?: CSSProperties;
}) {
  return (
    <section className={`${ink ? 'panel-ink' : 'panel'} ${className}`} style={style}>
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

export function Badge({ tone = 'default', title, children }: { tone?: BadgeTone; title?: string; children: ReactNode }) {
  return (
    <span className={`badge ${tone === 'default' ? '' : `badge-${tone}`}`} title={title}>
      {children}
    </span>
  );
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

interface SplitRow {
  left?: string;
  right?: string;
  context?: string;
}

/** `-`/`+` 对 → 左右对照行：lineDiff 逐行输出 -x / +y，相邻即一对 */
function toSplitRows(lines: string[]): SplitRow[] {
  const rows: SplitRow[] = [];
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (l.startsWith('-')) {
      const next = lines[i + 1];
      if (next?.startsWith('+')) {
        rows.push({ left: l.slice(1), right: next.slice(1) });
        i++;
      } else {
        rows.push({ left: l.slice(1) });
      }
    } else if (l.startsWith('+')) {
      rows.push({ right: l.slice(1) });
    } else {
      rows.push({ context: l });
    }
  }
  return rows;
}

/**
 * 左右对照 diff。两种数据形态：
 * - rows（全文 LCS 对齐，优先）：左栏基准全文白底；右栏对比全文——same 白底、add 绿底 +、del 红底 -（显示被删原文）
 * - lines（差异行回退）：`-`/`+` 行对，左栏基准纯文本，右栏只渲染差异行
 */
export function SplitDiff({
  lines,
  rows,
  leftLabel = '基准侧',
  rightLabel = '对比侧',
}: {
  lines?: string[];
  rows?: Array<{ left: string | null; right: string | null; kind: 'same' | 'add' | 'del' }>;
  leftLabel?: string;
  rightLabel?: string;
}) {
  return (
    <div className="split-diff">
      <div className="split-diff-head">
        <span className="split-diff-head-cell">{leftLabel}</span>
        <span className="split-diff-head-cell">{rightLabel}</span>
      </div>
      {rows
        ? rows.map((r, i) => (
            <div key={i} className="split-diff-row">
              <span className="diff-line split-diff-cell">{r.left ?? ''}</span>
              {r.kind === 'add' ? (
                <span className="diff-plus split-diff-cell">+ {r.right ?? ''}</span>
              ) : r.kind === 'del' ? (
                <span className="diff-minus split-diff-cell">- {r.right ?? ''}</span>
              ) : (
                <span className="diff-line split-diff-cell">{r.right ?? ''}</span>
              )}
            </div>
          ))
        : toSplitRows(lines ?? []).map((r, i) =>
            r.context !== undefined ? (
              <div key={i} className="split-diff-row">
                <span className="diff-line split-diff-span">{r.context}</span>
              </div>
            ) : (
              <div key={i} className="split-diff-row">
                <span className="diff-line split-diff-cell">{r.left ?? ''}</span>
                {r.right !== undefined ? (
                  <span className="diff-plus split-diff-cell">+ {r.right}</span>
                ) : r.left !== undefined ? (
                  <span className="diff-minus split-diff-cell">- {r.left}</span>
                ) : (
                  <span className="split-diff-cell split-diff-empty" />
                )}
              </div>
            )
          )}
    </div>
  );
}

export function Chip({ children }: { children: ReactNode }) {
  return <span className="chip">{children}</span>;
}
