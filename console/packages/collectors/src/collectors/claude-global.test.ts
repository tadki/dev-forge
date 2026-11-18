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
