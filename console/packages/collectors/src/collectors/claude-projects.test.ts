import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { claudeProjectsCollector } from './claude-projects.js';
import { defaultConfig, makeContext } from '../index.js';
import type { WorkspaceDef } from '../config.js';

let root = '';

beforeAll(async () => {
  root = await mkdtemp(join(tmpdir(), 'forge-claude-projects-'));
  const alpha = join(root, 'ws-a', 'proj-alpha');
  await mkdir(join(alpha, '.claude', 'hooks'), { recursive: true });
  await mkdir(join(alpha, '.claude', 'skills', 'demo-skill'), { recursive: true });
  await mkdir(join(alpha, '.claude', 'agents'), { recursive: true });
  await writeFile(join(alpha, 'CLAUDE.md'), '# Alpha\n\n项目说明。\n');
  await writeFile(join(alpha, '.claude', 'hooks', 'guard.sh'), '#!/bin/bash\n');
  await writeFile(join(alpha, '.claude', 'skills', 'demo-skill', 'SKILL.md'), '---\ndescription: demo\n---\nbody\n');
  await writeFile(join(alpha, '.claude', 'agents', 'worker.md'), '---\nname: worker\ndescription: does work\n---\nbody\n');
  await writeFile(join(alpha, '.mcp.json'), JSON.stringify({ mcpServers: { grepai: { command: 'npx', args: ['grepai'] } } }));
  const bare = join(root, 'ws-b', 'proj-bare');
  await mkdir(bare, { recursive: true });
  // 未注册目录：即使带完整 harness 痕迹也不应产出资产
  const stray = join(root, 'stray', 'proj-stray');
  await mkdir(stray, { recursive: true });
  await writeFile(join(stray, 'CLAUDE.md'), '# Stray\n');
});

afterAll(async () => {
  if (root) await rm(root, { recursive: true, force: true });
});

function ctxFor(workspaces: WorkspaceDef[]) {
  const cfg = { ...defaultConfig({ home: root, devforge: root }), workspaces };
  return makeContext(cfg);
}

describe('claude-projects collector（注册制 + harness 声明制）', () => {
  it('只为注册路径产出资产，workspace 归属来自注册而非路径匹配', async () => {
    const ctx = ctxFor([
      { id: 'wsa', name: 'WS A', projects: [{ path: join(root, 'ws-a', 'proj-alpha'), harnesses: ['claude'] }] },
    ]);
    const r = await claudeProjectsCollector.collect(ctx);
    const proj = r.assets.find((a) => a.id === 'project:proj-alpha');
    expect(proj).toBeDefined();
    expect(proj!.payload).toMatchObject({
      path: join(root, 'ws-a', 'proj-alpha'),
      workspace: 'wsa',
      workspaceName: 'WS A',
      harnesses: ['claude'],
      hasClaudeMd: true,
      hooksScripts: 1,
      mcpServers: ['grepai'],
    });
    expect(proj!.applies?.workspaces).toEqual(['wsa']);
    // 声明了 claude → 解析 harness 目录内容
    expect(r.assets.some((a) => a.id === 'instruction:proj-alpha/CLAUDE.md')).toBe(true);
    expect(r.assets.some((a) => a.id === 'skill:project-proj-alpha-demo-skill')).toBe(true);
    expect(r.assets.some((a) => a.id === 'agent:worker')).toBe(true);
    expect(r.assets.find((a) => a.id === 'agent:worker')?.payload).toMatchObject({ subagent: true, project: 'proj-alpha' });
    expect(r.assets.some((a) => a.id === 'hook-script:project-proj-alpha-guard.sh')).toBe(true);
    expect(r.assets.some((a) => a.id === 'mcp-endpoint:project-proj-alpha-grepai')).toBe(true);
    // 磁盘上存在但未注册的目录不产出任何资产
    expect(r.assets.some((a) => a.source.path.includes('proj-stray'))).toBe(false);
  });

  it('未声明 harness → 只出项目资产，不解析 harness 目录内容', async () => {
    const ctx = ctxFor([
      { id: 'wsa', name: 'WS A', projects: [{ path: join(root, 'ws-a', 'proj-alpha'), harnesses: [] }] },
    ]);
    const r = await claudeProjectsCollector.collect(ctx);
    const proj = r.assets.find((a) => a.id === 'project:proj-alpha');
    expect(proj).toBeDefined();
    expect(proj!.payload).toMatchObject({ workspace: 'wsa', harnesses: [], hasClaudeMd: false, mcpServers: [] });
    expect(r.assets.filter((a) => a.kind !== 'project')).toHaveLength(0);
  });

  it('注册即项目：无 harness 痕迹的注册目录也产出资产', async () => {
    const ctx = ctxFor([{ id: 'wsb', name: 'WS B', projects: [{ path: join(root, 'ws-b', 'proj-bare'), harnesses: ['claude'] }] }]);
    const r = await claudeProjectsCollector.collect(ctx);
    const proj = r.assets.find((a) => a.id === 'project:proj-bare');
    expect(proj).toBeDefined();
    expect(proj!.payload).toMatchObject({ workspace: 'wsb', harnesses: ['claude'], hasClaudeMd: false, hooksScripts: 0 });
    expect(r.assets.filter((a) => a.kind !== 'project')).toHaveLength(0);
  });

  it('注册路径不存在 → missing 资产 + warn 诊断', async () => {
    const missing = join(root, 'gone', 'proj-missing');
    const ctx = ctxFor([{ id: 'wsc', name: 'WS C', projects: [{ path: missing, harnesses: ['claude'] }] }]);
    const r = await claudeProjectsCollector.collect(ctx);
    const proj = r.assets.find((a) => a.id === 'project:proj-missing');
    expect(proj).toBeDefined();
    expect(proj!.payload).toMatchObject({ path: missing, workspace: 'wsc', harnesses: ['claude'], missing: true });
    expect(r.diagnostics.some((d) => d.level === 'warn' && d.message.includes('proj-missing'))).toBe(true);
  });

  it('同一路径注册到两个 workspace → 首个胜出 + warn 诊断', async () => {
    const dup = join(root, 'ws-a', 'proj-alpha');
    const ctx = ctxFor([
      { id: 'first', name: 'First', projects: [{ path: dup, harnesses: ['claude'] }] },
      { id: 'second', name: 'Second', projects: [{ path: dup, harnesses: ['claude'] }] },
    ]);
    const r = await claudeProjectsCollector.collect(ctx);
    const projs = r.assets.filter((a) => a.id === 'project:proj-alpha');
    expect(projs).toHaveLength(1);
    expect(projs[0].payload).toMatchObject({ workspace: 'first' });
    expect(r.diagnostics.some((d) => d.level === 'warn' && d.message.includes('重复注册'))).toBe(true);
  });

  it('watchPaths 返回注册路径且不产生诊断副作用', () => {
    const p = join(root, 'ws-a', 'proj-alpha');
    const ctx = ctxFor([{ id: 'wsa', name: 'WS A', projects: [{ path: p, harnesses: [] }, { path: `${p}/`, harnesses: [] }] }]);
    const paths = claudeProjectsCollector.watchPaths!(ctx);
    expect(paths).toEqual([p]);
    expect(ctx.diagnostics).toHaveLength(0);
  });
});
