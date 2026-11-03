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
