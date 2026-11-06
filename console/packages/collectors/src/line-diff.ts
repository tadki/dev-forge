/** 无差异哨兵：lineDiff 输出与消费方（对账回退展示、前端守卫）共用同一字面量 */
export const NO_DIFF_SENTINEL = '(无差异)';

/** 逐行 `-`/`+` diff（量小、供旧版单栏视图与对账条目回退展示使用；全文双栏见 split-diff） */
export function lineDiff(a: string, b: string): string[] {
  const al = a.split('\n');
  const bl = b.split('\n');
  const out: string[] = [];
  const n = Math.max(al.length, bl.length);
  for (let i = 0; i < n && out.length < 40; i++) {
    const x = al[i] ?? '';
    const y = bl[i] ?? '';
    if (x !== y) {
      out.push(`- ${x}`);
      out.push(`+ ${y}`);
    }
  }
  return out.length === 0 ? [NO_DIFF_SENTINEL] : out;
}
