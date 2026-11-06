import { afterAll, describe, expect, it } from 'vitest';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import type { Asset } from '@forge/schema';
import { loadPlatforms, resolvePlatform, resolveWriteChannel, buildPlatformsView, DEFAULT_PLATFORMS, type PlatformDef } from './platforms.js';

const dir = join(tmpdir(), `forge-platforms-${Date.now()}`);
/** 仓库真实声明（console/platforms.d）——顺带验证 YAML 文件本身可加载 */
const repoDir = join(import.meta.dirname, '..', '..', '..', 'platforms.d');

function mkAsset(id: string, path: string, kind: Asset['kind'], payload: Record<string, unknown> = {}): Asset {
  return {
    id,
    kind,
    name: id.split(':')[1] ?? id,
    summary: '',
    attach: { level: 'platform' },
    enforcement: 'enforced',
    platforms: [],
    provenance: 'first-party',
    tags: [],
    enabled: true,
    source: { collector: 'test', path },
    payload,
  };
}

describe('平台适配层（platforms.d）', () => {
  it('从 YAML 目录加载，缺失目录回退 DEFAULT_PLATFORMS', async () => {
    await mkdir(dir, { recursive: true });
    await writeFile(
      join(dir, 'p1.yaml'),
      `id: test-platform\nlabel: 测试平台\nmatch:\n  pathPrefix: ["test://"]\nkinds:\n  skill:\n    write:\n      type: command\n      cmd: [t, update, "{platformId}", --content, "{content}"]\n      platformIdFrom: self\n`
    );
    const { platforms } = await loadPlatforms(dir);
    expect(platforms.find((p) => p.id === 'test-platform')?.kinds?.skill?.write).toMatchObject({ type: 'command' });
    const missing = await loadPlatforms(join(dir, 'nope'));
    expect(missing.platforms.some((p) => p.id === 'multica')).toBe(true);
  });

  it('resolvePlatform：multica:// → multica，本地绝对路径 → claude-code', async () => {
    const { platforms } = await loadPlatforms(repoDir);
    expect(resolvePlatform(mkAsset('skill:m', 'multica://skills/a', 'skill'), platforms)?.id).toBe('multica');
    expect(resolvePlatform(mkAsset('instruction:l', '/home/x/CLAUDE.md', 'instruction'), platforms)?.id).toBe('claude-code');
    expect(resolvePlatform(mkAsset('custom:x', 'proc://whatever', 'custom'), platforms)).toBeUndefined();
  });

  it('resolveWriteChannel：command 通道 platformId 解析（self / deployment）与 none 降级', async () => {
    const { platforms } = await loadPlatforms(repoDir);
    const skill = mkAsset('skill:m', 'multica://skills/a', 'skill', { platformId: 'sk-1' });
    expect(resolveWriteChannel(skill, [skill], platforms)).toMatchObject({
      platformId: 'sk-1',
      write: { type: 'command' },
    });
    const agent = mkAsset('agent:fronti', 'multica://agents/f1', 'agent', {});
    const dep = mkAsset('deployment:multica:fronti', 'multica://agents/f1', 'deployment', { agent: 'Fronti', platformId: 'ag-9' });
    expect(resolveWriteChannel(agent, [agent, dep], platforms)).toMatchObject({ platformId: 'ag-9' });
    const noId = mkAsset('skill:n', 'multica://skills/b', 'skill', {});
    expect(resolveWriteChannel(noId, [noId], platforms)?.write.type).toBe('none');
    const ap = mkAsset('autopilot:multica-z', 'multica://autopilots/z', 'autopilot', {});
    expect(resolveWriteChannel(ap, [ap], platforms)?.write).toMatchObject({ type: 'none' });
    const file = mkAsset('instruction:l', '/home/x/CLAUDE.md', 'instruction', {});
    expect(resolveWriteChannel(file, [file], platforms)?.write.type).toBe('file-write');
  });

  afterAll(async () => {
    await rm(dir, { recursive: true, force: true });
  });
});

describe('platforms.d 结构校验（坏文件出诊断并跳过）', () => {
  it('pathPrefix 标量 / write.type 未知 / none 缺 advice → 跳过该文件', async () => {
    const badDir = join(dir, 'bad');
    await mkdir(badDir, { recursive: true });
    await writeFile(join(badDir, 'a.yaml'), 'id: bad-1\nmatch: { pathPrefix: "/" }\nkinds: { skill: { write: { type: file-write } } }\n');
    await writeFile(join(badDir, 'b.yaml'), 'id: bad-2\nmatch: { pathPrefix: ["/"] }\nkinds: { skill: { write: { type: magic } } }\n');
    await writeFile(join(badDir, 'c.yaml'), 'id: bad-3\nmatch: { pathPrefix: ["/"] }\nkinds: { skill: { write: { type: none } } }\n');
    await writeFile(join(badDir, 'd.yaml'), 'id: good-1\nmatch: { pathPrefix: ["ok://"] }\n');
    const { platforms, diagnostics } = await loadPlatforms(badDir);
    expect(platforms.map((p) => p.id)).toEqual(['good-1']);
    expect(diagnostics).toHaveLength(3);
    expect(diagnostics.every((d) => d.level === 'error' && d.message.includes('结构违规'))).toBe(true);
  });

  it('read 校验矩阵：how 未知 / cli 缺 cmd / file 缺 paths / none 缺 note → 跳过；合法 read 通过', async () => {
    const badDir = join(dir, 'bad-read');
    await mkdir(badDir, { recursive: true });
    await writeFile(join(badDir, 'a.yaml'), 'id: bad-how\nmatch: { pathPrefix: ["/"] }\nkinds: { skill: { read: { how: magic }, write: { type: file-write } } }\n');
    await writeFile(join(badDir, 'b.yaml'), 'id: bad-cli\nmatch: { pathPrefix: ["/"] }\nkinds: { skill: { read: { how: cli }, write: { type: file-write } } }\n');
    await writeFile(join(badDir, 'c.yaml'), 'id: bad-file\nmatch: { pathPrefix: ["/"] }\nkinds: { skill: { read: { how: file }, write: { type: file-write } } }\n');
    await writeFile(join(badDir, 'd.yaml'), 'id: bad-none\nmatch: { pathPrefix: ["/"] }\nkinds: { skill: { read: { how: none }, write: { type: file-write } } }\n');
    await writeFile(
      join(badDir, 'e.yaml'),
      'id: good-read\nmatch: { pathPrefix: ["ok://"] }\nkinds:\n  skill:\n    read:\n      how: cli\n      collector: test\n      cmd: [t, list]\n      detailCmd: [t, get, "{id}"]\n      note: 测试\n    write: { type: file-write }\n  instruction:\n    read: { how: derived, note: 派生, paths: ["<project>/CLAUDE.md"] }\n    write: { type: file-write }\n'
    );
    const { platforms, diagnostics } = await loadPlatforms(badDir);
    expect(platforms.map((p) => p.id)).toEqual(['good-read']);
    expect(diagnostics).toHaveLength(4);
    expect(diagnostics.every((d) => d.message.includes('结构违规'))).toBe(true);
  });
});

describe('DEFAULT_PLATFORMS 与 YAML 锁步 + read 声明', () => {
  it('DEFAULT_PLATFORMS 与 console/platforms.d 逐字段等价（单边漂移即红）', async () => {
    const { platforms } = await loadPlatforms(repoDir);
    const byId = (xs: PlatformDef[]) => Object.fromEntries(xs.map((p) => [p.id, p]));
    expect(byId(platforms)).toEqual(byId(DEFAULT_PLATFORMS));
    // 顺序也是行为：resolvePlatform first-match-wins，平台序与文件名序一致且 id 唯一
    expect(platforms.map((p) => p.id)).toEqual(DEFAULT_PLATFORMS.map((p) => p.id));
    expect(new Set(platforms.map((p) => p.id)).size).toBe(platforms.length);
  });

  it('真实 YAML 的 read 声明：multica 命令 / claude-code 路径 / truth kind 全覆盖', async () => {
    const { platforms } = await loadPlatforms(repoDir);
    const multica = platforms.find((p) => p.id === 'multica');
    expect(multica?.kinds?.skill?.read).toMatchObject({
      how: 'cli',
      cmd: ['multica', 'skill', 'list'],
      detailCmd: ['multica', 'skill', 'get', '{id}', '--with-content'],
    });
    expect(multica?.kinds?.agent?.read?.collector).toBe('multica');
    expect(multica?.kinds?.instruction?.read?.how).toBe('derived');
    expect(multica?.kinds?.instruction?.read?.note).toContain('workdir');
    const cc = platforms.find((p) => p.id === 'claude-code');
    expect(cc?.kinds?.instruction?.read?.paths).toContain('<project>/CLAUDE.md');
    const TRUTH = ['instruction', 'skill', 'agent', 'hook-rule', 'hook-script', 'adapter', 'autopilot'];
    for (const p of platforms) {
      for (const k of TRUTH) expect(p.kinds?.[k]?.read, `${p.id}.${k} 应有 read 声明`).toBeDefined();
    }
  });
});

describe('buildPlatformsView', () => {
  it('平台归桶 + 轻量投影 + 未适配桶', () => {
    const assets = [
      mkAsset('skill:a', 'multica://skills/a', 'skill', { platformId: 'sk-1' }),
      mkAsset('agent:fronti', 'multica://agents/fronti-1', 'agent', { instructions: 'x' }),
      mkAsset('service:grepai', 'systemd://user/grepai-watch.service', 'service'),
      mkAsset('instruction:k', '/e2e/kol/CLAUDE.md', 'instruction'),
    ];
    const v = buildPlatformsView(assets, DEFAULT_PLATFORMS);
    const multica = v.platforms.find((p) => p.id === 'multica');
    expect(multica?.totalAssets).toBe(2);
    const skillRow = multica?.kinds.find((k) => k.kind === 'skill');
    expect(skillRow).toMatchObject({ assetCount: 1, declared: true, collectors: ['test'] });
    expect(skillRow?.assets[0].platformId).toBe('sk-1');
    expect(skillRow?.assets[0]).not.toHaveProperty('payload');
    expect(skillRow?.read?.how).toBe('cli');
    const agentRow = multica?.kinds.find((k) => k.kind === 'agent');
    expect(agentRow?.assets[0]).not.toHaveProperty('instructions');
    const cc = v.platforms.find((p) => p.id === 'claude-code');
    expect(cc?.kinds.find((k) => k.kind === 'instruction')?.assetCount).toBe(1);
    expect(v.unadapted.assetCount).toBe(1);
    expect(v.unadapted.kinds[0]).toMatchObject({ kind: 'service', count: 1 });
    expect(v.unadapted.kinds[0].paths).toEqual(['systemd://user/grepai-watch.service']);
  });

  it('YAML 未声明的实有 kind → declared=false；kind 序循 ASSET_KINDS', () => {
    const defs: PlatformDef[] = [{ id: 't', match: { pathPrefix: ['t://'] }, kinds: { skill: { write: { type: 'file-write' } } } }];
    const assets = [mkAsset('custom:x', 't://x', 'custom'), mkAsset('skill:s', 't://s', 'skill')];
    const v = buildPlatformsView(assets, defs);
    expect(v.platforms[0].kinds.map((k) => k.kind)).toEqual(['skill', 'custom']);
    expect(v.platforms[0].kinds.find((k) => k.kind === 'custom')?.declared).toBe(false);
    expect(v.platforms[0].kinds.find((k) => k.kind === 'skill')?.declared).toBe(true);
  });
});
