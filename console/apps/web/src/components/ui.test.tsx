import { describe, expect, it } from 'vitest';
import { renderToStaticMarkup } from 'react-dom/server';
import { DataTable } from './ui';

interface Row {
  id: string;
  name: string;
}

const rows: Row[] = [{ id: 'a', name: 'alpha' }, { id: 'b', name: 'beta' }];
const cell = (r: Row) => <span>{r.name}</span>;
const cols = [
  { key: 'name', head: '名称', render: cell },
  { key: 'status', head: '状态', render: cell },
  { key: 'note', head: '备注', render: cell },
];

function thSegments(html: string): string[] {
  return html.split(/<th(?:\s[^>]*)?>/).slice(1).map((s) => s.slice(0, s.indexOf('</th>')));
}

describe('DataTable filters（按 col key 映射，控件与列头同单元格）', () => {
  it('filters 以 key 对应列，声明顺序与 cols 顺序无关', () => {
    const html = renderToStaticMarkup(
      <DataTable
        rows={rows}
        cols={cols}
        filters={{
          note: <input aria-label="筛备注" />,
          name: <input aria-label="筛名称" />,
        }}
      />
    );
    const ths = thSegments(html);
    expect(ths).toHaveLength(3);
    expect(ths[0]).toContain('名称');
    expect(ths[0]).toContain('aria-label="筛名称"');
    expect(ths[1]).toContain('状态');
    expect(ths[2]).toContain('备注');
    expect(ths[2]).toContain('aria-label="筛备注"');
  });

  it('无筛选列不渲染控件；不传 filters 时表头不含 col-filter', () => {
    const withFilters = thSegments(renderToStaticMarkup(<DataTable rows={rows} cols={cols} filters={{ name: <input aria-label="筛名称" /> }} />));
    expect(withFilters[0]).toContain('col-filter');
    expect(withFilters[1]).not.toContain('col-filter');

    const bare = renderToStaticMarkup(<DataTable rows={rows} cols={cols} />);
    expect(bare).not.toContain('col-filter');
  });
});
