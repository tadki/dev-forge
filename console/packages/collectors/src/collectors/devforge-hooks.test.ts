import { describe, expect, it } from 'vitest';
import { mkdir, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { makeContext, defaultConfig } from '../index.js';
import { devforgeHooksCollector, repoGatingOf } from './devforge-hooks.js';
import { humanizeWhen } from '../util.js';

describe('repoGatingOf', () => {
  it('repo in[] → 提取 id 列表', () => {
    expect(repoGatingOf({ op: 'repo', in: ['kol', 'gqt'] })).toEqual({ in: ['kol', 'gqt'], registered: undefined });
  });

  it('repo registered:true → registered', () => {
    expect(repoGatingOf({ op: 'repo', registered: true })).toEqual({ in: undefined, registered: true });
  });

  it('嵌套于 all/not 组合子内 → 穿透提取', () => {
    const when = {
      op: 'all',
      args: [
        { op: 'command', pattern: '^git push' },
        { op: 'not', arg: { op: 'repo', in: ['kol'] } },
      ],
    };
    expect(repoGatingOf(when)).toEqual({ in: ['kol'], registered: undefined });
  });

  it('非字符串 in[] 项被过滤', () => {
    expect(repoGatingOf({ op: 'repo', in: ['kol', 42, null] })).toEqual({ in: ['kol'], registered: undefined });
  });

  it('无 repo op / 非 when 树 → undefined', () => {
    expect(repoGatingOf({ op: 'command', pattern: '^git push' })).toBeUndefined();
    expect(repoGatingOf(null)).toBeUndefined();
    expect(repoGatingOf('push')).toBeUndefined();
  });
});

describe('humanizeWhen repo op 投影', () => {
  it('in[] → 仓库 id 列表', () => {
    expect(humanizeWhen({ op: 'repo', in: ['kol', 'gqt'] })).toBe('仓库 kol/gqt');
  });

  it('registered:true → 已注册仓库', () => {
    expect(humanizeWhen({ op: 'repo', registered: true })).toBe('已注册仓库');
  });

  it('组合子内正常拼接', () => {
    expect(humanizeWhen({ op: 'all', args: [{ op: 'command', pattern: '^git push' }, { op: 'repo', in: ['kol'] }] })).toContain('仓库 kol');
  });
});

describe('devforge-hooks collector repoGating 投影', () => {
  const root = join(tmpdir(), `forge-hooks-test-${Date.now()}`);

  it('规则 when 含 repo op → payload.repoGating + repo:* tags；不含 → 字段缺省', async () => {
    await mkdir(join(root, 'claude-hooks', 'unified', 'rules.d'), { recursive: true });
    await writeFile(
      join(root, 'claude-hooks', 'unified', 'rules.d', 'gates.json'),
      JSON.stringify({
        version: 2,
        rules: [
          {
            name: 'gate-scoped',
            on: { in: ['PreToolUse'] },
            when: { op: 'repo', in: ['kol', 'gqt'] },
            action: [{ op: 'deny', message: 'x' }],
          },
          { name: 'gate-free', on: { in: ['PreToolUse'] }, action: [{ op: 'context', message: 'y' }] },
        ],
      })
    );
    const r = await devforgeHooksCollector.collect(makeContext(defaultConfig({ devforge: root })));
    const scoped = r.assets.find((x) => x.id === 'hook-rule:gate-scoped');
    const free = r.assets.find((x) => x.id === 'hook-rule:gate-free');
    expect((scoped!.payload as { repoGating?: unknown }).repoGating).toEqual({ in: ['kol', 'gqt'], registered: undefined });
    expect(scoped!.tags).toContain('repo:kol');
    expect(scoped!.tags).toContain('repo:gqt');
    expect((free!.payload as { repoGating?: unknown }).repoGating).toBeUndefined();
    expect(free!.tags.some((t) => t.startsWith('repo:'))).toBe(false);
    await rm(root, { recursive: true, force: true });
  });
});

describe('devforge-hooks collector 平台继承（derive 框架）', () => {
  it('规则平台 = 自身 harness；脚本平台 = 挂载规则并集；lib = 引用链传递并集', async () => {
    const root = join(tmpdir(), `forge-hooks-derive-${Date.now()}`);
    await mkdir(join(root, 'claude-hooks', 'unified', 'rules.d'), { recursive: true });
    await mkdir(join(root, 'claude-hooks', 'scripts', 'lib'), { recursive: true });
    await writeFile(
      join(root, 'claude-hooks', 'unified', 'rules.d', 'mix.json'),
      JSON.stringify({
        rules: [
          { name: 'cc-rule', harness: ['claude-code'], action: [{ op: 'run_script', path: '${HOOKS_DIR}/scripts/cc.sh' }] },
          { name: 'mc-rule', harness: ['multica'], action: [{ op: 'run_script', path: '${HOOKS_DIR}/scripts/mc.sh' }] },
          { name: 'both-rule', harness: ['claude-code', 'multica'], action: [{ op: 'run_script', path: '${HOOKS_DIR}/scripts/both.sh' }] },
        ],
      })
    );
    await writeFile(join(root, 'claude-hooks', 'scripts', 'cc.sh'), '#!/bin/bash\n. "${HOOKS_DIR}/scripts/lib/shared.lib.sh"\n');
    await writeFile(join(root, 'claude-hooks', 'scripts', 'mc.sh'), '#!/bin/bash\n. "${HOOKS_DIR}/scripts/lib/shared.lib.sh"\n');
    await writeFile(join(root, 'claude-hooks', 'scripts', 'both.sh'), '#!/bin/bash\ntrue\n');
    await writeFile(join(root, 'claude-hooks', 'scripts', 'lib', 'shared.lib.sh'), '#!/bin/bash\n');

    const r = await devforgeHooksCollector.collect(makeContext(defaultConfig({ devforge: root })));
    const p = (name: string) =>
      r.assets.find((x) => x.id === `hook-script:${name}` || x.id === `hook-script:lib-${name}`)?.platforms;
    const rule = (name: string) => r.assets.find((x) => x.id === `hook-rule:${name}`)?.platforms;

    expect(rule('cc-rule')).toEqual(['claude-code']);
    expect(rule('mc-rule')).toEqual(['multica']);
    expect(rule('both-rule')).toEqual(['claude-code', 'multica']);
    expect(p('cc.sh')).toEqual(['claude-code']);
    expect(p('mc.sh')).toEqual(['multica']);
    expect(p('both.sh')).toEqual(['claude-code', 'multica']);
    // lib 不自行声明：两个平台共用 → 传递并集
    expect(p('shared.lib.sh')).toEqual(['claude-code', 'multica']);
    const lib = r.assets.find((x) => x.id === 'hook-script:lib-shared.lib.sh');
    expect(((lib!.payload as { usage?: { referencedBy: string[] } }).usage)?.referencedBy).toEqual(expect.arrayContaining(['cc.sh', 'mc.sh']));
    await rm(root, { recursive: true, force: true });
  });
});
