import { afterAll, describe, expect, it } from 'vitest';
import { execCapture } from './util.js';
import { createHash } from 'node:crypto';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { resetGitRecoveryCache, recoverBodyFromGit } from './git-history.js';

const root = join(tmpdir(), `forge-git-hist-${Date.now()}`);

async function git(root: string, args: string[]): Promise<void> {
  const r = await execCapture('git', ['-C', root, ...args], 10000);
  if (!r.ok) throw new Error(`git ${args.join(' ')} failed: ${r.stderr}`);
}

const v1 = '#!/usr/bin/env python3\n# sweep\n\ndef run_ok():\n    return True\n\ndef main():\n    print("sweep")\n';
const v2 = '#!/usr/bin/env python3\n# sweep\n\ndef main():\n    print("sweep")\n';
const sha = (s: string): string => createHash('sha256').update(s).digest('hex');

describe('recoverBodyFromGit（按 sha256 考古旧正文）', () => {
  it('命中历史版本：返回与 sha256 精确匹配的那一版全文；未命中/非仓库返回 undefined', async () => {
    const repo = join(root, 'repo');
    const dir = join(repo, 'autopilots');
    await mkdir(dir, { recursive: true });
    await git(repo, ['init']);
    await git(repo, ['config', 'user.email', 't@t']);
    await git(repo, ['config', 'user.name', 't']);
    await writeFile(join(dir, 'sweep.py'), v1);
    await git(repo, ['add', '.']);
    await git(repo, ['commit', '-m', 'v1']);
    await writeFile(join(dir, 'sweep.py'), v2);
    await git(repo, ['add', '.']);
    await git(repo, ['commit', '-m', 'v2']);

    expect(await recoverBodyFromGit(join(dir, 'sweep.py'), sha(v1))).toBe(v1);
    expect(await recoverBodyFromGit(join(dir, 'sweep.py'), sha(v2))).toBe(v2);
    expect(await recoverBodyFromGit(join(dir, 'sweep.py'), 'deadbeef')).toBeUndefined();
    expect(await recoverBodyFromGit(join(root, 'non-repo', 'x.py'), sha(v1))).toBeUndefined();
    expect(await recoverBodyFromGit(join(dir, 'sweep.py'), undefined)).toBeUndefined();
    expect(await recoverBodyFromGit('multica://autopilots/z', sha(v1))).toBeUndefined();

    // 负缓存：失败 key 不再重复试探（换回有效 sha 仍可命中）
    resetGitRecoveryCache();
    expect(await recoverBodyFromGit(join(dir, 'sweep.py'), sha(v1))).toBe(v1);
  });
});

afterAll(async () => {
  await rm(root, { recursive: true, force: true });
});
