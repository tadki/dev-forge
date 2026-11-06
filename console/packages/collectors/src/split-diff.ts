/**
 * 全文对照 diff（LCS 行对齐）：
 * 输入基准文本（库内/平台侧）与对比文本（生产/本地侧），输出对齐行序列。
 * same = 两侧一致（白底）；add = 仅对比侧新增（右栏绿）；del = 仅基准侧有（右栏红显原文）。
 * 用于对账的左右全文对照：与简单逐 index 比较不同，插入/删除不会让后续全文都误判为差异。
 */
export interface SplitRow {
  left: string | null;
  right: string | null;
  kind: 'same' | 'add' | 'del';
}

const MAX_LINES_PER_SIDE = 800;

export function splitDiff(a: string, b: string): SplitRow[] {
  const al = a.split('\n');
  const bl = b.split('\n');
  const A = al.slice(0, MAX_LINES_PER_SIDE);
  const B = bl.slice(0, MAX_LINES_PER_SIDE);
  const m = A.length;
  const n = B.length;

  // LCS 长度表（dp[i][j] = A[:i] 与 B[:j] 的最长公共子序列长度）
  const dp: Uint32Array[] = [];
  for (let i = 0; i <= m; i++) dp.push(new Uint32Array(n + 1));
  for (let i = 1; i <= m; i++) {
    for (let j = 1; j <= n; j++) {
      dp[i][j] = A[i - 1] === B[j - 1] ? dp[i - 1][j - 1] + 1 : Math.max(dp[i - 1][j], dp[i][j - 1]);
    }
  }

  const out: SplitRow[] = [];
  let i = m;
  let j = n;
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && A[i - 1] === B[j - 1]) {
      out.push({ kind: 'same', left: A[i - 1], right: B[j - 1] });
      i--;
      j--;
    } else if (j > 0 && (i === 0 || dp[i][j - 1] >= dp[i - 1][j])) {
      out.push({ kind: 'add', left: null, right: B[j - 1] });
      j--;
    } else {
      out.push({ kind: 'del', left: A[i - 1], right: A[i - 1] });
      i--;
    }
  }
  out.reverse();
  return out;
}
