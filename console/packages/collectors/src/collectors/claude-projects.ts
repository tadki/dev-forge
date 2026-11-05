import type { Asset, Relation } from '@forge/schema';
import { join } from 'node:path';
import { exists, execCapture, guessLang, headings, listDir, readJson, readText, sha256 } from '../util.js';
import { asset, type CollectContext, type Collector } from '../types.js';
import type { ProjectDef, WorkspaceDef } from '../config.js';

interface RegisteredProject {
  path: string;
  ws: WorkspaceDef;
  def: ProjectDef;
}

function registeredProjects(ctx: CollectContext): RegisteredProject[] {
  const out: RegisteredProject[] = [];
  const ownerOf = new Map<string, string>();
  for (const ws of ctx.config.workspaces) {
    for (const def of ws.projects ?? []) {
      const norm = def.path.replace(/\/+$/, '') || '/';
      const identity = def.git?.trim() || norm;
      const firstWs = ownerOf.get(identity);
      if (firstWs) {
        ctx.diagnostics.push({ level: 'warn', message: `[claude-projects] 仓库身份重复注册（归属 ${firstWs}，${ws.id} 跳过）：${identity}` });
        continue;
      }
      ownerOf.set(identity, ws.id);
      out.push({ path: norm, ws, def });
    }
  }
  return out;
}

async function gitIdentity(def: ProjectDef, dir: string): Promise<string | undefined> {
  const declared = def.git?.trim();
  if (declared) return declared;
  const r = await execCapture('git', ['-C', dir, 'remote', 'get-url', 'origin'], 3000);
  const url = r.stdout.trim();
  return r.ok && url ? url : undefined;
}

export const claudeProjectsCollector: Collector = {
  name: 'claude-projects',
  mode: 'watch',
  watchPaths: (ctx) => [...new Set(registeredProjects({ ...ctx, diagnostics: [] }).map((r) => r.path))],
  async collect(ctx: CollectContext) {
    const assets: Asset[] = [];
    const relations: Relation[] = [];
    // agent 本体身份 = 名字（Owner 原则 2026-11-03：与项目/平台解耦）；同名首见优先，重名告警
    const agentNamesSeen = new Set<string>();

    for (const { path: dir, ws, def } of registeredProjects(ctx)) {
      const name = dir.split('/').filter(Boolean).pop() ?? dir;
      const st = await import('node:fs/promises').then((m) => m.stat(dir).catch(() => null));
      const hasHarness = def.harnesses.includes('claude');

      if (!st?.isDirectory()) {
        ctx.diagnostics.push({ level: 'warn', message: `[claude-projects] 注册的项目路径不存在或不是目录：${dir}（workspace ${ws.id}）` });
        assets.push(
          asset({
            id: `project:${name}`,
            kind: 'project',
            name,
            summary: `${ws.name} · 路径不存在`,
            attach: { level: 'project', ref: dir },
            applies: { workspaces: [ws.id], origin: 'native' },
            enforcement: 'derived',
            platforms: ['claude-code'],
            source: { collector: 'claude-projects', path: dir },
            payload: { path: dir, git: def.git?.trim() || undefined, workspace: ws.id, workspaceName: ws.name, harnesses: def.harnesses, missing: true },
            tags: [ws.id],
          })
        );
        continue;
      }

      const projectId = `project:${name}`;
      const git = await gitIdentity(def, dir);
      const claudeMd = hasHarness ? await readText(join(dir, 'CLAUDE.md')) : null;
      const dotClaude = join(dir, '.claude');
      const hasSettings = hasHarness ? await exists(join(dotClaude, 'settings.json')) : false;
      const hooksScripts = hasHarness && (await exists(join(dotClaude, 'hooks')))
        ? (await listDir(join(dotClaude, 'hooks'))).filter((f) => f.endsWith('.sh'))
        : [];
      const skillDirs = hasHarness && (await exists(join(dotClaude, 'skills'))) ? await listDir(join(dotClaude, 'skills')) : [];
      const agentFiles = hasHarness && (await exists(join(dotClaude, 'agents')))
        ? (await listDir(join(dotClaude, 'agents'))).filter((f) => f.endsWith('.md'))
        : [];
      const mcpJson = hasHarness
        ? await readJson<{ mcpServers?: Record<string, { command?: string; args?: string[] }> }>(join(dir, '.mcp.json'))
        : null;

      assets.push(
        asset({
          id: projectId,
          kind: 'project',
          name: name,
          summary: hasHarness
            ? `${ws.name} · CLAUDE.md ${claudeMd ? claudeMd.split('\n').length + ' 行' : '无'} · hooks ${hooksScripts.length}`
            : `${ws.name} · 未声明 harness 解析`,
          attach: { level: 'project', ref: dir },
          applies: { workspaces: [ws.id], origin: 'native' },
          enforcement: 'derived',
          platforms: ['claude-code'],
          source: { collector: 'claude-projects', path: dir },
          payload: {
            path: dir,
            git,
            workspace: ws.id,
            workspaceName: ws.name,
            harnesses: def.harnesses,
            hasClaudeMd: claudeMd !== null,
            claudeMdLines: claudeMd ? claudeMd.split('\n').length : 0,
            claudeMdHash: claudeMd ? sha256(claudeMd) : undefined,
            hasSettings,
            hooksScripts: hooksScripts.length,
            skills: skillDirs,
            agents: agentFiles,
            mcpServers: mcpJson?.mcpServers ? Object.keys(mcpJson.mcpServers) : [],
          },
          tags: [ws.id],
        })
      );

      if (claudeMd !== null) {
        assets.push(
          asset({
            id: `instruction:${name}/CLAUDE.md`,
            kind: 'instruction',
            name: `${name}/CLAUDE.md`,
            summary: (headings(claudeMd)[0]?.text ?? '').slice(0, 80),
            attach: { level: 'project', ref: dir },
            applies: { workspaces: [ws.id], origin: 'native' },
            enforcement: 'derived',
            source: {
              collector: 'claude-projects',
              path: join(dir, 'CLAUDE.md'),
              sha256: sha256(claudeMd),
            },
            payload: {
              content: claudeMd.length <= 200_000 ? claudeMd : claudeMd.slice(0, 200_000),
              basename: 'CLAUDE.md',
              lines: claudeMd.split('\n').length,
              headings: headings(claudeMd),
              lang: guessLang(claudeMd),
              contentHash: sha256(claudeMd),
              projectName: name,
            },
            tags: ['claude-md', ws.id],
          })
        );
      }

      for (const s of skillDirs) {
        const md = (await readText(join(dotClaude, 'skills', s, 'SKILL.md'))) ?? '';
        assets.push(
          asset({
            id: `skill:project-${name}-${s}`,
            kind: 'skill',
            name: s,
            summary: md.match(/^description:\s*(.+)$/m)?.[1]?.slice(0, 100) ?? '',
            attach: { level: 'project', ref: dir },
            applies: { workspaces: [ws.id], origin: 'native' },
            enforcement: 'advisory',
            provenance: 'third-party',
            payload: { lines: md.split('\n').length, content: md.length <= 200_000 ? md : md.slice(0, 200_000) },
            source: { collector: 'claude-projects', path: join(dotClaude, 'skills', s, 'SKILL.md'), sha256: md ? sha256(md) : undefined },
            tags: ['skill', 'project'],
          })
        );
      }

      for (const a of agentFiles) {
        const md = (await readText(join(dotClaude, 'agents', a))) ?? '';
        const fmName = md.match(/^name:\s*(.+)$/m)?.[1] ?? a.replace(/\.md$/, '');
        const desc = md.match(/^description:\s*(.+)$/m)?.[1] ?? '';
        if (agentNamesSeen.has(fmName.toLowerCase())) {
          ctx.diagnostics.push({ level: 'warn', message: `[claude-projects] agent 本体重名（${fmName}，${name} 的 .claude/agents 跳过）` });
          continue;
        }
        agentNamesSeen.add(fmName.toLowerCase());
        assets.push(
          asset({
            id: `agent:${fmName.toLowerCase()}`,
            kind: 'agent',
            name: fmName,
            summary: desc.slice(0, 100),
            attach: { level: 'project', ref: dir },
            applies: { workspaces: [ws.id], origin: 'native' },
            enforcement: 'advisory',
            provenance: 'third-party',
            payload: { subagent: true, project: name, frontmatter: md.split('---')[1]?.trim() ?? '', bodyLines: md.split('\n').length },
            source: { collector: 'claude-projects', path: join(dotClaude, 'agents', a), sha256: sha256(md) },
            tags: ['subagent', 'claude-code', 'discovered'],
          })
        );
      }

      for (const h of hooksScripts) {
        const p = join(dotClaude, 'hooks', h);
        const md = await readText(p);
        assets.push(
          asset({
            id: `hook-script:project-${name}-${h}`,
            kind: 'hook-script',
            name: h,
            summary: (md ?? '').split('\n').find((l) => l.startsWith('#') && l.length > 3)?.replace(/^#\s*/, '').slice(0, 80) ?? '',
            attach: { level: 'project', ref: dir },
            enforcement: 'enforced',
            payload: { lines: (md ?? '').split('\n').length },
            source: { collector: 'claude-projects', path: p, sha256: md ? sha256(md) : undefined },
            tags: ['project-hook', ws.id],
          })
        );
      }

      for (const [mcpName, def] of Object.entries(mcpJson?.mcpServers ?? {})) {
        assets.push(
          asset({
            id: `mcp-endpoint:project-${name}-${mcpName}`,
            kind: 'mcp-endpoint',
            name: mcpName,
            summary: `stdio ${def.command ?? ''}`.slice(0, 100),
            attach: { level: 'project', ref: dir },
            applies: { workspaces: [ws.id], origin: 'native' },
            enforcement: 'enforced',
            payload: { transport: 'stdio', command: def.command, args: def.args },
            source: { collector: 'claude-projects', path: join(dir, '.mcp.json'), locator: `$.mcpServers.${mcpName}` },
            tags: ['mcp', ws.id],
          })
        );
      }
    }

    return { assets, relations, diagnostics: ctx.diagnostics };
  },
};
