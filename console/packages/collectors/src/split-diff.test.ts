import { describe, expect, it } from 'vitest';
import { splitDiff } from './split-diff.js';

describe('splitDiff（LCS 全文对齐）', () => {
  it('中间插入一行：只有插入处为 add，其余全文保持 same（不淹没为全绿）', () => {
    const a = 'l1\nl2\nl3\nl4';
    const b = 'l1\nl2\n插入\nl3\nl4';
    const rows = splitDiff(a, b);
    expect(rows.filter((r) => r.kind === 'add')).toHaveLength(1);
    expect(rows.filter((r) => r.kind === 'same')).toHaveLength(4);
    expect(rows.filter((r) => r.kind === 'del')).toHaveLength(0);
  });

  it('基准侧删除行：del 在右栏红显原文，左栏白底保留', () => {
    const rows = splitDiff('a\nb\nc', 'a\nc');
    const del = rows.find((r) => r.kind === 'del')!;
    expect(del.left).toBe('b');
    expect(del.right).toBe('b');
    expect(rows.filter((r) => r.kind === 'same')).toHaveLength(2);
  });

  it('修改一行 = del + add 成对出现', () => {
    const rows = splitDiff('a\nold\nc', 'a\nnew\nc');
    expect(rows.some((r) => r.kind === 'del' && r.left === 'old')).toBe(true);
    expect(rows.some((r) => r.kind === 'add' && r.right === 'new')).toBe(true);
    expect(rows.filter((r) => r.kind === 'same')).toHaveLength(2);
  });

  it('完全一致 → 全 same；完全不一致 → 无 same', () => {
    expect(splitDiff('a\nb', 'a\nb').every((r) => r.kind === 'same')).toBe(true);
    expect(splitDiff('a', 'b').some((r) => r.kind === 'same')).toBe(false);
  });
});
