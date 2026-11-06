import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { claudeGlobalCollector } from './claude-global.js';
import { defaultConfig, makeContext } from '../index.js';

let root = '';

beforeAll(async () => {
  root = await mkdtemp(join(tmpdir(), 'forge-claude-global-'));
  await mkdir(join(root, '.claude', 'rules', 'common'), { recursive: true });
  await mkdir(join(root, '.claude', 'rules', 'zh'), { recursive: true });
  await writeFile(join(root, '.claude', 'rules', 'common', 'coding-style.md'), '# Coding\n\n正文 A。\n');
  await writeFile(join(root, '.claude', 'rules', 'zh', 'coding-style.md'), '# 编码风格\n\n正文 B。\n');
  await writeFile(join(root, '.claude', 'rules', 'common', 'notes.txt'), 'ignored');
  await writeFile(join(root, '.claude', 'rules', 'README.md'), '# Root\n');

  // 用户级 agents
  await mkdir(join(root, '.claude', 'agents'), { recursive: true });
  await writeFile(
    join(root, '.claude', 'agents', 'deploy-helper.md'),
    '---\nname: deploy-helper\ndescription: 部署助手\n---\n\n正文。\n'
  );

  // 插件 agents：多版本目录（0.9.0 / unknown / 1.2.0）+ 一个禁用插件
  await mkdir(join(root, '.claude', 'plugins', 'cache', 'my-market', 'my-plugin', '0.9.0', 'agents'), { recursive: true });
  await mkdir(join(root, '.claude', 'plugins', 'cache', 'my-market', 'my-plugin', 'unknown', 'agents'), { recursive: true });
  await mkdir(join(root, '.claude', 'plugins', 'cache', 'my-market', 'my-plugin', '1.2.0', 'agents'), { recursive: true });
  await mkdir(join(root, '.claude', 'plugins', 'cache', 'my-market', 'off-plugin', '1.0.0', 'agents'), { recursive: true });
  await writeFile(
    join(root, '.claude', 'plugins', 'cache', 'my-market', 'my-plugin', '0.9.0', 'agents', 'architect.md'),
    '---\nname: architect\ndescription: 旧版\n---\n'
  );
  await writeFile(
    join(root, '.claude', 'plugins', 'cache', 'my-market', 'my-plugin', 'unknown', 'agents', 'architect.md'),
    '---\nname: architect\ndescription: unknown 版\n---\n'
  );
  await writeFile(
    join(root, '.claude', 'plugins', 'cache', 'my-market', 'my-plugin', '1.2.0', 'agents', 'architect.md'),
    '---\nname: architect\ndescription: 新版架构师\n---\n'
  );
  await writeFile(
    join(root, '.claude', 'plugins', 'cache', 'my-market', 'off-plugin', '1.0.0', 'agents', 'ghost.md'),
    '---\nname: ghost\ndescription: 禁用插件\n---\n'
  );
  await writeFile(
    join(root, '.claude', 'settings.json'),
    JSON.stringify({ enabledPlugins: { 'my-plugin@my-market': true, 'off-plugin@my-market': false } })
  );
});

afterAll(async () => {
  if (root) await rm(root, { recursive: true, force: true });
});

function ctx() {
  return makeContext(defaultConfig({ home: root, devforge: root }));
}

describe('claude-global collector（rules → instruction）', () => {
  it('rules 子目录的 md 采集为第三方 instruction，并携带全文与内容 hash', async () => {
    const r = await claudeGlobalCollector.collect(ctx());
    const common = r.assets.find((a) => a.id === 'instruction:rules-common-coding-style');
    const zh = r.assets.find((a) => a.id === 'instruction:rules-zh-coding-style');

    expect(common).toBeDefined();
    expect(common!.kind).toBe('instruction');
    expect(common!.provenance).toBe('third-party');
    expect(common!.attach.level).toBe('user');
    expect(common!.platforms).toEqual(['claude-code']);
    expect(common!.payload).toMatchObject({
      group: 'common',
      basename: 'coding-style.md',
      content: '# Coding\n\n正文 A。\n',
    });
    expect(typeof common!.payload.contentHash).toBe('string');
    expect(common!.payload.lines).toBeGreaterThan(0);
    expect(Array.isArray(common!.payload.headings)).toBe(true);
    expect(typeof common!.payload.lang).toBe('string');

    // 同名文件在不同目录 → 不同 id / group，互不覆盖
    expect(zh).toBeDefined();
    expect(zh!.payload).toMatchObject({ group: 'zh', content: '# 编码风格\n\n正文 B。\n' });
    expect(zh!.id).not.toBe(common!.id);
  });

  it('跳过非 md 文件与 rules 根层散文件', async () => {
    const r = await claudeGlobalCollector.collect(ctx());
    const ids = r.assets.filter((a) => a.kind === 'instruction').map((a) => a.id);
    expect(ids).not.toContain('instruction:rules-common-notes');
    expect(ids.some((id) => id.includes('README'))).toBe(false);
  });
});

describe('claude-global collector（hook-registration 归属按声明清单判定）', () => {
  let hookRoot = '';

  beforeAll(async () => {
    hookRoot = await mkdtemp(join(tmpdir(), 'forge-hook-reg-'));
    await mkdir(join(hookRoot, 'bootstrap'), { recursive: true });
    await mkdir(join(hookRoot, '.claude'), { recursive: true });
    await writeFile(
      join(hookRoot, 'bootstrap', 'hooks-registration.json'),
      JSON.stringify({ version: 2, alias: 'unified-hook', wrapper: 'hook-wrapper.sh', matcher: '*', hook_points: ['PreToolUse', 'SessionStart'] })
    );
    // 统一入口命令刻意不含 "dev-forge" 字样：命中依据是清单声明的 wrapper 路径，不是仓库名字符串
    await writeFile(
      join(hookRoot, '.claude', 'settings.json'),
      JSON.stringify({
        hooks: {
          PreToolUse: [{ matcher: '*', hooks: [{ type: 'command', command: '/opt/anywhere/claude-hooks/hook-wrapper.sh PreToolUse unified-hook' }] }],
          SessionStart: [
            {
              matcher: '*',
              hooks: [
                { type: 'command', command: '/opt/anywhere/claude-hooks/hook-wrapper.sh SessionStart unified-hook' },
                { type: 'command', command: 'node "/home/x/.hindsight/coding-agents/dist/claude-sessionstart-hook.js"' },
              ],
            },
          ],
          Notification: [{ matcher: '*', hooks: [{ type: 'command', command: 'bash /opt/other/notify.sh' }] }],
        },
      })
    );
  });

  afterAll(async () => {
    if (hookRoot) await rm(hookRoot, { recursive: true, force: true });
  });

  it('wrapper 路径命中清单 → first-party/devforge；hindsight 根 → hindsight；其余 → 外部', async () => {
    const r = await claudeGlobalCollector.collect(makeContext(defaultConfig({ home: hookRoot, devforge: hookRoot })));
    const pre = r.assets.find((a) => a.id === 'hook-registration:PreToolUse-0-0-devforge');
    expect(pre).toBeDefined();
    expect(pre!.provenance).toBe('first-party');
    expect(pre!.tags).toContain('devforge');
    expect(pre!.name).toContain('统一入口');

    // 同一 matcher entry 内的多条命令全部采集（schema 全量遍历，不只取首条）
    const ss = r.assets.filter((a) => a.id.startsWith('hook-registration:SessionStart-0-'));
    expect(ss.map((a) => a.id)).toEqual(['hook-registration:SessionStart-0-0-devforge', 'hook-registration:SessionStart-0-1-hindsight']);

    const ext = r.assets.find((a) => a.id === 'hook-registration:Notification-0-0-other');
    expect(ext!.provenance).toBe('third-party');
    expect(ext!.tags).toContain('custom');
  });

  it('清单缺失时不做名义猜测：统一入口挂载降级为外部挂载', async () => {
    const noManifest = await mkdtemp(join(tmpdir(), 'forge-hook-nomanifest-'));
    try {
      await mkdir(join(noManifest, '.claude'), { recursive: true });
      await writeFile(
        join(noManifest, '.claude', 'settings.json'),
        JSON.stringify({ hooks: { PreToolUse: [{ matcher: '*', hooks: [{ type: 'command', command: '/opt/anywhere/claude-hooks/hook-wrapper.sh PreToolUse unified-hook' }] }] } })
      );
      const r = await claudeGlobalCollector.collect(makeContext(defaultConfig({ home: noManifest, devforge: noManifest })));
      const pre = r.assets.find((a) => a.id === 'hook-registration:PreToolUse-0-0-other');
      expect(pre).toBeDefined();
      expect(pre!.provenance).toBe('third-party');
    } finally {
      await rm(noManifest, { recursive: true, force: true });
    }
  });
});

describe('claude-global collector（agents）', () => {
  it('用户级 ~/.claude/agents 采集为第三方 agent', async () => {
    const r = await claudeGlobalCollector.collect(ctx());
    const a = r.assets.find((x) => x.id === 'agent:user-deploy-helper');

    expect(a).toBeDefined();
    expect(a!.kind).toBe('agent');
    expect(a!.name).toBe('deploy-helper');
    expect(a!.summary).toBe('部署助手');
    expect(a!.provenance).toBe('third-party');
    expect(a!.attach.level).toBe('user');
    expect(a!.payload).toMatchObject({ subagent: true });
    expect(a!.tags).toEqual(['agent', 'user']);
    expect(typeof a!.source.sha256).toBe('string');
  });

  it('已启用插件取最新版本 agents（unknown/旧版被忽略），禁用插件跳过', async () => {
    const r = await claudeGlobalCollector.collect(ctx());

    const a = r.assets.find((x) => x.id === 'agent:plugin-my-plugin-architect');
    expect(a).toBeDefined();
    expect(a!.name).toBe('my-plugin:architect');
    expect(a!.summary).toBe('新版架构师');
    expect(a!.payload).toMatchObject({ plugin: 'my-plugin', subagent: true });
    expect(a!.tags).toEqual(['agent', 'plugin', 'my-plugin']);

    expect(r.assets.find((x) => x.id === 'agent:plugin-off-plugin-ghost')).toBeUndefined();
  });
});
