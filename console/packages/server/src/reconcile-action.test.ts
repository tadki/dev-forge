import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { Asset, RegistryState, ReconcileItem, WriteStep } from '@forge/collectors';
import { editRegistryPlatforms } from '@forge/collectors';
import { executeReconcileAction, resolveReconcileContent, type ReconcileExecDeps } from './reconcile-action.js';

let dir: string;
beforeAll(async () => {
  dir = await mkdtemp(join(tmpdir(), 'forge-reconcile-'));
});
afterAll(async () => {
  await import('node:fs/promises').then((m) => m.rm(dir, { recursive: true, force: true }));
});

function mk(id: string, kind: Asset['kind'], over: Partial<Asset> = {}): Asset {
  return {
    id,
    kind,
    name: id.split(':')[1] ?? id,
    summary: '',
    attach: { level: 'user' },
    enforcement: 'enforced',
    platforms: ['claude-code'],
    provenance: 'first-party',
    tags: [],
    enabled: true,
    source: { collector: 'test', path: `/tmp/${id}` },
    payload: {},
    ...over,
  };
}

const REGISTRY_YAML = `# 头部注释必须保留
entries:
  - id: my-skill
    match: { pathPrefix: "/tmp/skills" }
    platforms: [claude-code]
    meta: { owner: jerry }
`;

describe('editRegistryPlatforms', () => {
  it('add/remove 保留注释与相邻字段', async () => {
    const file = join(dir, 'owned.yaml');
    await writeFile(file, REGISTRY_YAML, 'utf8');
    const added = await editRegistryPlatforms(file, 'my-skill', 'add-platform', 'multica');
    expect(added).toEqual(['claude-code', 'multica']);
    let text = await readFile(file, 'utf8');
    expect(text).toContain('# 头部注释必须保留');
    expect(text).toContain('owner: jerry');
    expect(text).toMatch(/platforms:\s*\[\s*claude-code,\s*multica\s*\]/);

    const removed = await editRegistryPlatforms(file, 'my-skill', 'remove-platform', 'multica');
    expect(removed).toEqual(['claude-code']);
    text = await readFile(file, 'utf8');
    expect(text).toContain('# 头部注释必须保留');
  });

  it('entry 不存在时报错', async () => {
    const file = join(dir, 'owned2.yaml');
    await writeFile(file, REGISTRY_YAML, 'utf8');
    await expect(editRegistryPlatforms(file, 'no-such', 'add-platform', 'multica')).rejects.toThrow('no-such');
  });
});

function stateWith(assets: Asset[]): RegistryState {
  return { assets, relations: [], diagnostics: [], collectorStatus: [], lastCollectedAt: '' };
}

function itemWithSteps(steps: WriteStep[]): ReconcileItem {
  return {
    key: 'test:item',
    type: 'content-drift',
    severity: 'warn',
    platform: 'multica',
    name: 'test',
    detail: 'test',
    copies: [],
    actions: [{ id: 'a1', direction: 'local-to-platform', label: 'test', executable: true, steps }],
  };
}

const fakeExecDeps = (log: string[][], ok = true): ReconcileExecDeps => ({
  dryRun: false,
  exec: async (cmd, args) => {
    log.push([cmd, ...args]);
    return { ok, stdout: 'updated', stderr: '' };
  },
});

describe('executeReconcileAction', () => {
  it('file-write：白名单路径写入 + 备份；非白名单路径拒绝', async () => {
    const target = join(dir, 'shared.md');
    await writeFile(target, 'old body', 'utf8');
    const assets = [
      mk('instruction:src', 'instruction', {
        name: 'shared.md',
        source: { collector: 'test', path: join(dir, 'src.md'), sha256: 's1' },
        payload: { content: 'new body from src' },
      }),
      mk('instruction:dst', 'instruction', {
        name: 'shared.md',
        source: { collector: 'test', path: target, sha256: 's2' },
      }),
    ];
    const item = itemWithSteps([
      { type: 'file-write', path: target, contentFrom: { assetId: 'instruction:src', field: 'content' } },
    ]);
    const result = await executeReconcileAction(item, 'a1', stateWith(assets), fakeExecDeps([]));
    expect(result.status).toBe('ok');
    expect(await readFile(target, 'utf8')).toBe('new body from src');
    const backups = (await readdir(dir)).filter((f) => f.startsWith('shared.md.forge-bak-'));
    expect(backups.length).toBe(1);

    const evil = itemWithSteps([{ type: 'file-write', path: '/etc/passwd', contentFrom: { assetId: 'instruction:src', field: 'content' } }]);
    const denied = await executeReconcileAction(evil, 'a1', stateWith(assets), fakeExecDeps([]));
    expect(denied.status).toBe('failed');
    expect(denied.output).toContain('拒绝写入');
  });

  it('preserveMulticaPrefix：保留 harness 前后段，只替换 instructions 块', async () => {
    const target = join(dir, 'workdir-CLAUDE.md');
    const original = [
      '<!-- BEGIN MULTICA-RUNTIME (auto-managed; do not edit) -->',
      '# Multica Agent Runtime',
      '',
      '## Background Task Safety',
      'harness rules here',
      '',
      '## Agent Identity',
      '**You are: Fronti** (ID: `f1`)',
      '',
      'OLD INSTRUCTIONS',
      '',
      '## Available Commands',
      'harness commands',
      '',
      '<!-- END MULTICA-RUNTIME -->',
      '',
    ].join('\n');
    await writeFile(target, original, 'utf8');
    const assets = [
      mk('agent:fronti', 'agent', { payload: { instructions: 'NEW INSTRUCTIONS' } }),
      mk('instruction:mat', 'instruction', { source: { collector: 'test', path: target } }),
    ];
    const item = itemWithSteps([
      { type: 'file-write', path: target, contentFrom: { assetId: 'agent:fronti', field: 'instructions' }, preserveMulticaPrefix: true },
    ]);
    const result = await executeReconcileAction(item, 'a1', stateWith(assets), fakeExecDeps([]));
    expect(result.status).toBe('ok');
    const text = await readFile(target, 'utf8');
    expect(text).toContain('<!-- BEGIN MULTICA-RUNTIME');
    expect(text).toContain('## Background Task Safety');
    expect(text).toContain('**You are: Fronti**');
    expect(text).toContain('NEW INSTRUCTIONS');
    expect(text).toContain('## Available Commands');
    expect(text).toContain('harness commands');
    expect(text).toContain('<!-- END MULTICA-RUNTIME -->');
    expect(text).not.toContain('OLD INSTRUCTIONS');
    expect(text.indexOf('**You are: Fronti**')).toBeLessThan(text.indexOf('NEW INSTRUCTIONS'));
    expect(text.indexOf('NEW INSTRUCTIONS')).toBeLessThan(text.indexOf('## Available Commands'));
  });

  it('command：{content} 从物化样本解析并替换', async () => {
    const calls: string[][] = [];
    const assets = [
      mk('custom:multica-materialized-instructions', 'custom', {
        payload: { samples: [{ agent: 'Fronti', path: '/tmp/w/CLAUDE.md', hash: 'h', body: 'MATERIALIZED BODY' }] },
      }),
    ];
    const item = itemWithSteps([
      {
        type: 'command',
        cmd: ['multica', 'agent', 'update', 'f1', '--instructions', '{content}'],
        note: '',
        contentFrom: { assetId: 'custom:multica-materialized-instructions', field: 'materialized-body', agent: 'Fronti' },
      },
    ]);
    const result = await executeReconcileAction(item, 'a1', stateWith(assets), fakeExecDeps(calls));
    expect(result.status).toBe('ok');
    expect(calls[0]).toEqual(['multica', 'agent', 'update', 'f1', '--instructions', 'MATERIALIZED BODY']);
    expect(result.output).toContain('已执行');
    expect(result.output).not.toContain('MATERIALIZED BODY'); // 内容不回显
  });

  it('dry-run：不落盘不执行命令', async () => {
    const target = join(dir, 'dryrun-target.md');
    await writeFile(target, 'keep me', 'utf8');
    const calls: string[][] = [];
    const assets = [
      mk('instruction:src', 'instruction', { source: { collector: 'test', path: join(dir, 'src2.md') }, payload: { content: 'X' } }),
      mk('instruction:dst', 'instruction', { source: { collector: 'test', path: target } }),
    ];
    const item = itemWithSteps([
      { type: 'file-write', path: target, contentFrom: { assetId: 'instruction:src', field: 'content' } },
      { type: 'command', cmd: ['multica', 'agent', 'update', 'f1', '--instructions', '{content}'], note: '', contentFrom: { assetId: 'instruction:src', field: 'content' } },
    ]);
    const result = await executeReconcileAction(item, 'a1', stateWith(assets), { dryRun: true, exec: async (c, a) => { calls.push([c, ...a]); return { ok: true, stdout: '', stderr: '' }; } });
    expect(result.status).toBe('ok');
    expect(result.output).toContain('[dry-run]');
    expect(await readFile(target, 'utf8')).toBe('keep me');
    expect(calls).toHaveLength(0);
  });

  it('动作不存在 / 不可执行 → invalid', async () => {
    const item = itemWithSteps([]);
    expect((await executeReconcileAction(item, 'nope', stateWith([]), fakeExecDeps([]))).status).toBe('invalid');
    const manual: ReconcileItem = {
      ...itemWithSteps([]),
      actions: [{ id: 'manual', direction: 'local-to-platform', label: 'x', executable: false, note: '手动', steps: [] }],
    };
    const r = await executeReconcileAction(manual, 'manual', stateWith([]), fakeExecDeps([]));
    expect(r.status).toBe('invalid');
    expect(r.output).toBe('手动');
  });

  it('resolveReconcileContent 三种 field', () => {
    const assets = [
      mk('a:one', 'instruction', { payload: { content: 'C' } }),
      mk('agent:x', 'agent', { payload: { instructions: 'I' } }),
      mk('custom:multica-materialized-instructions', 'custom', { payload: { samples: [{ agent: 'X', body: 'B', path: '/tmp/x', hash: 'h' }] } }),
    ];
    const state = stateWith(assets);
    expect(resolveReconcileContent({ assetId: 'a:one', field: 'content' }, state)).toBe('C');
    expect(resolveReconcileContent({ assetId: 'agent:x', field: 'instructions' }, state)).toBe('I');
    expect(resolveReconcileContent({ assetId: 'custom:multica-materialized-instructions', field: 'materialized-body', agent: 'x' }, state)).toBe('B');
    expect(resolveReconcileContent({ assetId: 'missing', field: 'content' }, state)).toBeNull();
  });
});
