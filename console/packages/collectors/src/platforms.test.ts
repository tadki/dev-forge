import { afterAll, describe, expect, it } from 'vitest';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import type { Asset } from '@forge/schema';
import { loadPlatforms, resolvePlatform, resolveWriteChannel } from './platforms.js';

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
