import { afterAll, describe, expect, it } from 'vitest';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import type { Asset } from '@forge/schema';
import { loadPlatforms, resolvePlatform, resolveWriteChannel, buildPlatformsView, DEFAULT_PLATFORMS, type PlatformDef } from './platforms.js';

const dir = join(tmpdir(), `forge-platforms-${Date.now()}`);
/** 仓库真实声明（console/platforms.d）——顺带验证 YAML 文件本身可加载 */
const repoDir = join(import.meta.dirname, '..', '..', '..', 'platforms.d');

function mkAsset(
  id: string,
  path: string,
  kind: Asset['kind'],
  payload: Record<string, unknown> = {},
  platforms: string[] = [],
  sourcePlatform?: 'none'
): Asset {
  return {
    id,
    kind,
    name: id.split(':')[1] ?? id,
    summary: '',
    attach: { level: 'platform' },
    enforcement: 'enforced',
    platforms,
    provenance: 'first-party',
    tags: [],
    enabled: true,
    source: { collector: 'test', path, ...(sourcePlatform ? { platform: sourcePlatform } : {}) },
    payload,
  };
}

describe('平台适配层（platforms.d）', () => {
  it('从 YAML 目录加载，缺失目录回退 DEFAULT_PLATFORMS', async () => {
    await mkdir(dir, { recursive: true });
    await writeFile(
      join(dir, 'p1.yaml'),
      `id: test-platform\nlabel: 测试平台\nkinds:\n  skill:\n    discovery: { mode: scan, how: cli, cmd: [t, list], note: 清单即归属 }\n    read: { how: api, cmd: [t, get, "{id}"], note: 逐条取正文 }\n    write:\n      type: command\n      cmd: [t, update, "{platformId}", --content, "{content}"]\n      platformIdFrom: self\n`
    );
    const { platforms } = await loadPlatforms(dir);
    expect(platforms.find((p) => p.id === 'test-platform')?.kinds?.skill?.write).toMatchObject({ type: 'command' });
    const missing = await loadPlatforms(join(dir, 'nope'));
    expect(missing.platforms.some((p) => p.id === 'multica')).toBe(true);
  });

  it('resolvePlatform：只看资产自声明 platforms，路径不参与归属', () => {
    const { platforms } = { platforms: DEFAULT_PLATFORMS };
    // 声明为准：multica:// 路径但声明 claude-code → claude-code
    expect(resolvePlatform(mkAsset('skill:m', 'multica://skills/a', 'skill', {}, ['claude-code']), platforms)?.id).toBe('claude-code');
    // 本地绝对路径但声明 multica → multica
    expect(resolvePlatform(mkAsset('agent:a', '/home/x/agent.md', 'agent', {}, ['multica']), platforms)?.id).toBe('multica');
    // 无声明 → 未适配，即使路径看起来像某平台
    expect(resolvePlatform(mkAsset('skill:u', 'multica://skills/u', 'skill'), platforms)).toBeUndefined();
    expect(resolvePlatform(mkAsset('instruction:l', '/home/x/CLAUDE.md', 'instruction'), platforms)).toBeUndefined();
    // 多声明按平台注册序取首个（claude-code 先注册）
    expect(resolvePlatform(mkAsset('hook-rule:h', '/x/r.json', 'hook-rule', {}, ['multica', 'claude-code']), platforms)?.id).toBe('claude-code');
  });

  it('resolvePlatform：source.platform=none 显式豁免，即使有平台声明也不归桶', () => {
    const exempt: Asset = {
      ...mkAsset('service:grepai', 'systemd://user/grepai-watch.service', 'service', {}, ['claude-code'], 'none'),
    };
    expect(resolvePlatform(exempt, DEFAULT_PLATFORMS)).toBeUndefined();
    const v = buildPlatformsView([exempt], DEFAULT_PLATFORMS);
    expect(v.unadapted.assetCount).toBe(1);
    expect(v.unadapted.kinds[0]).toMatchObject({ kind: 'service', count: 1 });
    // platforms 为空的平台无资产声明 → 不产生未适配（显式 source.platform=none）
    const undeclared = mkAsset('custom:agg', '/anywhere', 'custom', {}, [], 'none');
    expect(buildPlatformsView([undeclared], DEFAULT_PLATFORMS).unadapted.assetCount).toBe(1);
  });

  it('resolveWriteChannel：command 通道 platformId 解析（self / deployment）与 none 降级', () => {
    const { platforms } = { platforms: DEFAULT_PLATFORMS };
    const skill = mkAsset('skill:m', 'multica://skills/a', 'skill', { platformId: 'sk-1' }, ['multica']);
    expect(resolveWriteChannel(skill, [skill], platforms)).toMatchObject({
      platformId: 'sk-1',
      write: { type: 'command' },
    });
    const agent = mkAsset('agent:fronti', 'multica://agents/f1', 'agent', {}, ['multica']);
    const dep = mkAsset('deployment:multica:fronti', 'multica://agents/f1', 'deployment', { agent: 'Fronti', platformId: 'ag-9' }, ['multica']);
    expect(resolveWriteChannel(agent, [agent, dep], platforms)).toMatchObject({ platformId: 'ag-9' });
    const noId = mkAsset('skill:n', 'multica://skills/b', 'skill', {}, ['multica']);
    expect(resolveWriteChannel(noId, [noId], platforms)?.write.type).toBe('none');
    const ap = mkAsset('autopilot-registration:multica-z', 'multica://autopilots/z', 'autopilot-registration', {}, ['multica']);
    expect(resolveWriteChannel(ap, [ap], platforms)?.write).toMatchObject({ type: 'none' });
    const file = mkAsset('instruction:l', '/home/x/CLAUDE.md', 'instruction', {}, ['claude-code']);
    expect(resolveWriteChannel(file, [file], platforms)?.write.type).toBe('file-write');
    const na = mkAsset('deployment:cc', '/does/not/happen', 'deployment', {}, ['claude-code']);
    expect(resolveWriteChannel(na, [na], platforms)?.write).toMatchObject({ type: 'none', advice: expect.stringContaining('不适用') });
    // 无平台声明 → 无写通道
    expect(resolveWriteChannel(mkAsset('skill:u', '/x', 'skill'), [], platforms)).toBeUndefined();
  });

  afterAll(async () => {
    await rm(dir, { recursive: true, force: true });
  });
});

describe('platforms.d 结构校验（坏文件出诊断并跳过）', () => {
  it('id 缺失 / write.type 未知 / none 缺 advice → 跳过该文件', async () => {
    const badDir = join(dir, 'bad');
    await mkdir(badDir, { recursive: true });
    await writeFile(join(badDir, 'a.yaml'), 'label: 无 id\nkinds: { skill: { write: { type: file-write } } }\n');
    await writeFile(join(badDir, 'b.yaml'), 'id: bad-2\nkinds: { skill: { write: { type: magic } } }\n');
    await writeFile(join(badDir, 'c.yaml'), 'id: bad-3\nkinds: { skill: { write: { type: none } } }\n');
    await writeFile(join(badDir, 'd.yaml'), 'id: good-1\n');
    const { platforms, diagnostics } = await loadPlatforms(badDir);
    expect(platforms.map((p) => p.id)).toEqual(['good-1']);
    expect(diagnostics).toHaveLength(3);
    expect(diagnostics.every((d) => d.level === 'error' && d.message.includes('结构违规'))).toBe(true);
  });

  it('契约校验矩阵：discovery 缺失/坏 mode/坏 how/cli 缺 cmd/file 缺 paths/declared 缺 registry + read 坏 how/api 缺 cmd/none 缺 note → 跳过；合法契约通过', async () => {
    const badDir = join(dir, 'bad-contract');
    await mkdir(badDir, { recursive: true });
    await writeFile(join(badDir, 'a.yaml'), 'id: bad-no-discovery\nkinds: { skill: { read: { how: file }, write: { type: file-write } } }\n');
    await writeFile(join(badDir, 'b.yaml'), 'id: bad-mode\nkinds: { skill: { discovery: { mode: magic, how: file, paths: [x] }, write: { type: file-write } } }\n');
    await writeFile(join(badDir, 'c.yaml'), 'id: bad-cli\nkinds: { skill: { discovery: { mode: scan, how: cli }, write: { type: file-write } } }\n');
    await writeFile(join(badDir, 'd.yaml'), 'id: bad-file\nkinds: { skill: { discovery: { mode: scan, how: file }, write: { type: file-write } } }\n');
    await writeFile(join(badDir, 'e.yaml'), 'id: bad-registry\nkinds: { skill: { discovery: { mode: declared, how: file, paths: [x] }, write: { type: file-write } } }\n');
    await writeFile(join(badDir, 'f.yaml'), 'id: bad-read-how\nkinds: { skill: { discovery: { mode: scan, how: file, paths: [x] }, read: { how: magic }, write: { type: file-write } } }\n');
    await writeFile(join(badDir, 'g.yaml'), 'id: bad-read-api\nkinds: { skill: { discovery: { mode: scan, how: file, paths: [x] }, read: { how: api }, write: { type: file-write } } }\n');
    await writeFile(join(badDir, 'h.yaml'), 'id: bad-read-none\nkinds: { skill: { discovery: { mode: scan, how: file, paths: [x] }, read: { how: none }, write: { type: file-write } } }\n');
    await writeFile(
      join(badDir, 'i.yaml'),
      'id: good-contract\nkinds:\n  skill:\n    discovery: { mode: scan, how: cli, collector: test, cmd: [t, list], files: true, note: 清单即归属 }\n    read: { how: api, cmd: [t, get, "{id}"], note: 逐条取正文 }\n    write: { type: file-write }\n  instruction:\n    discovery: { mode: scan, how: file, paths: ["<project>/CLAUDE.md"] }\n    read: { how: file }\n    write: { type: file-write }\n  hook-rule:\n    discovery: { mode: declared, how: file, paths: ["/repo/*.json"], registry: devforge-hooks-engine, note: 盖章归属 }\n    read: { how: file }\n    write: { type: file-write }\n  report:\n    discovery: { mode: scan, how: derived, collector: test, note: 派生采样 }\n    read: { how: none, note: 无正文可读 }\n    write: { type: none, advice: 只读 }\n'
    );
    const { platforms, diagnostics } = await loadPlatforms(badDir);
    expect(platforms.map((p) => p.id)).toEqual(['good-contract']);
    expect(platforms[0].kinds?.skill?.discovery).toMatchObject({ mode: 'scan', how: 'cli', files: true });
    expect(platforms[0].kinds?.['hook-rule']?.discovery).toMatchObject({ mode: 'declared', registry: 'devforge-hooks-engine' });
    expect(diagnostics).toHaveLength(8);
    expect(diagnostics.every((d) => d.message.includes('结构违规'))).toBe(true);
  });

  it('applicable 校验：只接受 false + note 必填 + 不得带 discovery/read/write；合法声明通过', async () => {
    const badDir = join(dir, 'bad-na');
    await mkdir(badDir, { recursive: true });
    await writeFile(join(badDir, 'a.yaml'), 'id: bad-true\nkinds: { skill: { applicable: true, write: { type: file-write } } }\n');
    await writeFile(join(badDir, 'b.yaml'), 'id: bad-nonote\nkinds: { skill: { applicable: false, write: { type: file-write } } }\n');
    await writeFile(join(badDir, 'c.yaml'), 'id: bad-with-rw\nkinds: { skill: { applicable: false, note: 无对象, discovery: { mode: scan, how: file, paths: [x] }, read: { how: file }, write: { type: file-write } } }\n');
    await writeFile(join(badDir, 'd.yaml'), 'id: good-na\nkinds: { skill: { applicable: false, note: 无对象 } }\n');
    const { platforms, diagnostics } = await loadPlatforms(badDir);
    expect(platforms.map((p) => p.id)).toEqual(['good-na']);
    expect(platforms[0].kinds?.skill).toEqual({ applicable: false, note: '无对象' });
    expect(diagnostics).toHaveLength(3);
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

  it('归桶语义：YAML 不承担归属，asset.platforms 是唯一依据', async () => {
    const { platforms } = await loadPlatforms(repoDir);
    for (const p of platforms) {
      expect(p).not.toHaveProperty('match');
    }
  });

  it('真实 YAML 的发现/读通道契约：multica 命令 / claude-code 路径 / 声明式发现 / truth kind 全覆盖', async () => {
    const { platforms } = await loadPlatforms(repoDir);
    const multica = platforms.find((p) => p.id === 'multica');
    // multica skill：scan 清单命令发现 + api 读正文（files 登记在 discovery）
    expect(multica?.kinds?.skill?.discovery).toMatchObject({
      mode: 'scan',
      how: 'cli',
      cmd: ['multica', 'skill', 'list'],
      files: true,
    });
    expect(multica?.kinds?.skill?.read).toMatchObject({
      how: 'api',
      cmd: ['multica', 'skill', 'get', '{id}', '--with-content'],
    });
    expect(multica?.kinds?.agent?.discovery?.collector).toBe('multica');
    expect(multica?.kinds?.instruction?.discovery?.how).toBe('derived');
    expect(multica?.kinds?.instruction?.discovery?.note).toContain('workdir');
    expect(multica?.kinds?.instruction?.read?.how).toBe('file');
    // multica 平台无 hooks 设置与挂载入口：三类 hook kind 均显式不适用（Owner 2026-11-11）
    expect(multica?.kinds?.['hook-rule']?.applicable).toBe(false);
    expect(multica?.kinds?.['hook-script']?.applicable).toBe(false);
    expect(multica?.kinds?.['hook-registration']?.applicable).toBe(false);
    const cc = platforms.find((p) => p.id === 'claude-code');
    expect(cc?.kinds?.instruction?.discovery?.paths).toContain('<project>/CLAUDE.md');
    expect(cc?.kinds?.instruction?.read).toEqual({ how: 'file' });
    // deployment 对 claude-code 是「不适用」（平台无此对象），非「未适配」
    expect(cc?.kinds?.deployment).toEqual({
      applicable: false,
      note: expect.stringContaining('deployment'),
    });
    // hook-registration：settings.json 挂载点实测（scan）；dev-forge 注册清单工件经 registry.d 盖章（同 kind 混合，note 说明）
    expect(cc?.kinds?.['hook-registration']?.discovery?.paths).toEqual(['~/.claude/settings.json']);
    expect(cc?.kinds?.['hook-registration']?.write).toEqual({ type: 'file-write' });
    // hook-rule / adapter / patch：声明式发现——registry.d 条目盖章归属
    expect(cc?.kinds?.['hook-rule']?.discovery).toMatchObject({ mode: 'declared', registry: 'devforge-hooks-engine' });
    expect(cc?.kinds?.adapter?.discovery).toMatchObject({ mode: 'declared', registry: 'devforge-adapters' });
    expect(cc?.kinds?.patch?.discovery).toMatchObject({ mode: 'declared', registry: 'hindsight-integration' });
    // Claude Code 无 autopilot 体系：两类 autopilot kind 均「不适用」
    expect(cc?.kinds?.['autopilot-registration']?.applicable).toBe(false);
    expect(cc?.kinds?.['autopilot-script']?.applicable).toBe(false);
    const TRUTH = ['instruction', 'skill', 'agent', 'hook-rule', 'hook-script', 'adapter', 'autopilot-script', 'autopilot-registration'];
    for (const p of platforms) {
      for (const k of TRUTH) {
        const def = p.kinds?.[k];
        expect(def?.discovery ?? def?.applicable === false, `${p.id}.${k} 应有发现通道声明或显式不适用`).toBeTruthy();
      }
    }
  });
});

describe('buildPlatformsView', () => {
  it('平台归桶 + 轻量投影 + 未适配桶', () => {
    const assets = [
      mkAsset('skill:a', 'multica://skills/a', 'skill', { platformId: 'sk-1' }, ['multica']),
      mkAsset('agent:fronti', 'multica://agents/fronti-1', 'agent', { instructions: 'x' }, ['multica']),
      mkAsset('service:grepai', 'systemd://user/grepai-watch.service', 'service', {}, [], 'none'),
      mkAsset('instruction:k', '/e2e/kol/CLAUDE.md', 'instruction', {}, ['claude-code']),
    ];
    const v = buildPlatformsView(assets, DEFAULT_PLATFORMS);
    const multica = v.platforms.find((p) => p.id === 'multica');
    expect(multica?.totalAssets).toBe(2);
    const skillRow = multica?.kinds.find((k) => k.kind === 'skill');
    expect(skillRow).toMatchObject({ assetCount: 1, declared: true, collectors: ['test'] });
    expect(skillRow?.assets[0].platformId).toBe('sk-1');
    expect(skillRow?.assets[0]).not.toHaveProperty('payload');
    expect(skillRow?.discovery).toMatchObject({ mode: 'scan', how: 'cli' });
    expect(skillRow?.read?.how).toBe('api');
    const agentRow = multica?.kinds.find((k) => k.kind === 'agent');
    expect(agentRow?.assets[0]).not.toHaveProperty('instructions');
    const cc = v.platforms.find((p) => p.id === 'claude-code');
    expect(cc?.kinds.find((k) => k.kind === 'instruction')?.assetCount).toBe(1);
    expect(cc?.kinds.find((k) => k.kind === 'deployment')).toMatchObject({
      declared: true,
      applicable: false,
      assetCount: 0,
      note: expect.stringContaining('deployment'),
    });
    expect(v.unadapted.assetCount).toBe(1);
    expect(v.unadapted.kinds[0]).toMatchObject({ kind: 'service', count: 1 });
    expect(v.unadapted.kinds[0].paths).toEqual(['systemd://user/grepai-watch.service']);
  });

  it('YAML 未声明的实有 kind → declared=false；kind 序循 ASSET_KINDS', () => {
    const defs: PlatformDef[] = [{ id: 't', kinds: { skill: { write: { type: 'file-write' } } } }];
    const assets = [mkAsset('custom:x', 't://x', 'custom', {}, ['t']), mkAsset('skill:s', 't://s', 'skill', {}, ['t'])];
    const v = buildPlatformsView(assets, defs);
    expect(v.platforms[0].kinds.map((k) => k.kind)).toEqual(['skill', 'custom']);
    expect(v.platforms[0].kinds.find((k) => k.kind === 'custom')?.declared).toBe(false);
    expect(v.platforms[0].kinds.find((k) => k.kind === 'skill')?.declared).toBe(true);
  });

  it('多平台声明：资产在每个声明过的已注册平台页都显示；declaredCount 唯一计数', () => {
    const assets = [
      mkAsset('hook-rule:shared', '/dev-forge/claude-hooks/rules.d/x.json', 'hook-rule', {}, ['claude-code', 'multica']),
      mkAsset('skill:cc-only', '/home/x/.claude/skills/s/SKILL.md', 'skill', {}, ['claude-code']),
      mkAsset('custom:none-tagged', '/x', 'custom', {}, ['claude-code'], 'none'),
    ];
    const v = buildPlatformsView(assets, DEFAULT_PLATFORMS);
    const ccRule = v.platforms.find((p) => p.id === 'claude-code')?.kinds.find((k) => k.kind === 'hook-rule');
    const mcRule = v.platforms.find((p) => p.id === 'multica')?.kinds.find((k) => k.kind === 'hook-rule');
    expect(ccRule?.assetCount).toBe(1);
    expect(mcRule?.assetCount).toBe(1);
    expect(mcRule?.assets[0].id).toBe('hook-rule:shared');
    // declaredCount 唯一计数：shared + cc-only = 2（none-tagged 进未适配）
    expect(v.declaredCount).toBe(2);
    expect(v.unadapted.assetCount).toBe(1);
  });
});
