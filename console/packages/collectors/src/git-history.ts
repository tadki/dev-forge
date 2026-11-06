import { dirname, relative } from 'node:path';
import { execCapture, sha256 } from './util.js';

/**
 * 从 git 历史考古恢复旧正文：给定文件绝对路径与其内容 sha256，遍历该文件的提交历史，
 * 逐版计算 sha256，命中即返回该版全文。用途：正文归档政策之前的库内旧记录只存指纹，
 * 由此可无损复原「库当时认可的那一版」正文，供 store-drift 全文对照——
 * 哈希精确匹配才返回，不改记录指纹、不掩盖漂移。
 */

/** 进程内负缓存：考古失败的 (path, sha) 不在后续采集轮里反复试探（重启后重置重试） */
const recoveryMiss = new Set<string>();

export function resetGitRecoveryCache(): void {
  recoveryMiss.clear();
}

export async function recoverBodyFromGit(
  filePath: string,
  sha256Hex: string | undefined,
  opts?: { maxCommits?: number }
): Promise<string | undefined> {
  if (!filePath.startsWith('/') || !sha256Hex) return undefined;
  const key = `${filePath}|${sha256Hex}`;
  if (recoveryMiss.has(key)) return undefined;

  const toplevel = await execCapture('git', ['-C', dirname(filePath), 'rev-parse', '--show-toplevel'], 5000);
  if (!toplevel.ok) {
    recoveryMiss.add(key);
    return undefined;
  }
  const root = toplevel.stdout.trim();
  const rel = relative(root, filePath);
  if (!rel || rel.startsWith('..')) {
    recoveryMiss.add(key);
    return undefined;
  }

  const log = await execCapture(
    'git',
    ['-C', root, 'log', '--format=%H', `-n`, String(opts?.maxCommits ?? 300), '--', rel],
    10000
  );
  if (!log.ok) {
    recoveryMiss.add(key);
    return undefined;
  }
  for (const commit of log.stdout.split('\n').filter(Boolean)) {
    const blob = await execCapture('git', ['-C', root, 'show', `${commit}:${rel}`], 5000);
    if (blob.ok && sha256(blob.stdout) === sha256Hex) return blob.stdout;
  }
  recoveryMiss.add(key);
  return undefined;
}
