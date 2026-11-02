import type { Asset, Relation } from '@forge/schema';
import { join } from 'node:path';
import { exists, guessLang, headings, listDir, readJson, readText, sha256 } from '../util.js';
import { asset, type CollectContext, type Collector } from '../types.js';
import { workspaceOf } from '../config.js';

async function scanProjects(ctx: CollectContext): Promise<string[]> {
  const found: string[] = [];
  const seen = new Set<string>();
  const excluded = (p: string) =>
    ctx.config.excludeNames.some((ex) => p.includes(ex)) || p.includes('/.') && !p.endsWith('/.claude');

  async function walk(dir: string, depth: number) {
    if (depth < 0 || seen.has(dir)) return;
    seen.add(dir);
    const hasHarness =
      (await exists(join(dir, 'CLAUDE.md'))) || (await exists(join(dir, '.claude')));
    if (hasHarness && !excluded(dir)) found.push(dir);
    if (depth === 0) return;
    for (const name of await listDir(dir)) {
      if (name.startsWith('.') || name === 'multica_workspaces') continue;
      const sub = join(dir, name);
      const st = await import('node:fs/promises').then((m) => m.stat(sub).catch(() => null));
      if (st?.isDirectory()) await walk(sub, depth - 1);
    }
  }

  for (const root of ctx.config.scanRoots) await walk(root.path, root.depth);
  return found;
}

export const claudeProjectsCollector: Collector = {
  name: 'claude-projects',
  mode: 'watch',
  watchPaths: (ctx) => ctx.config.scanRoots.map((r) => r.path),
  async collect(ctx: CollectContext) {
    const assets: Asset[] = [];
    const relations: Relation[] = [];
    const projects = await scanProjects(ctx);

    for (const dir of projects) {
      const name = dir.split('/').filter(Boolean).pop() ?? dir;
      const ws = workspaceOf(ctx.config, dir);
      const projectId = `project:${name}`;

      const claudeMd = await readText(join(dir, 'CLAUDE.md'));
      const dotClaude = join(dir, '.claude');
      const hasSettings = await exists(join(dotClaude, 'settings.json'));
      const hooksScripts = (await exists(join(dotClaude, 'hooks')))
        ? (await listDir(join(dotClaude, 'hooks'))).filter((f) => f.endsWith('.sh'))
        : [];
      const skillDirs = (await exists(join(dotClaude, 'skills'))) ? await listDir(join(dotClaude, 'skills')) : [];
      const agentFiles = (await exists(join(dotClaude, 'agents')))
        ? (await listDir(join(dotClaude, 'agents'))).filter((f) => f.endsWith('.md'))
        : [];
      const mcpJson = await readJson<{ mcpServers?: Record<string, { command?: string; args?: string[] }> }>(
        join(dir, '.mcp.json')
      );

      assets.push(
        asset({
          id: projectId,
          kind: 'project',
          name: name,
          summary: `${ws ? ws.name : '未分组'} · CLAUDE.md ${claudeMd ? claudeMd.split('\n').length + ' 行' : '无'} · hooks ${hooksScripts.length}`,
          attach: { level: 'project', ref: dir },
          applies: ws ? { workspaces: [ws.id], origin: 'native' } : undefined,
          enforcement: 'derived',
          platforms: ['claude-code'],
          source: { collector: 'claude-projects', path: dir },
          payload: {
            path: dir,
            workspace: ws?.id,
            workspaceName: ws?.name,
            hasClaudeMd: claudeMd !== null,
            claudeMdLines: claudeMd ? claudeMd.split('\n').length : 0,
            claudeMdHash: claudeMd ? sha256(claudeMd) : undefined,
            hasSettings,
            hooksScripts: hooksScripts.length,
            skills: skillDirs,
            agents: agentFiles,
            mcpServers: mcpJson?.mcpServers ? Object.keys(mcpJson.mcpServers) : [],
          },
          tags: ws ? [ws.id] : ['unassigned'],
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
            applies: ws ? { workspaces: [ws.id], origin: 'native' } : undefined,
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
            tags: ['claude-md', ...(ws ? [ws.id] : [])],
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
            applies: ws ? { workspaces: [ws.id], origin: 'native' } : undefined,
            enforcement: 'advisory',
            payload: { lines: md.split('\n').length },
            source: { collector: 'claude-projects', path: join(dotClaude, 'skills', s, 'SKILL.md'), sha256: md ? sha256(md) : undefined },
            tags: ['skill', 'project'],
          })
        );
      }

      for (const a of agentFiles) {
        const md = (await readText(join(dotClaude, 'agents', a))) ?? '';
        const fmName = md.match(/^name:\s*(.+)$/m)?.[1] ?? a.replace(/\.md$/, '');
        const desc = md.match(/^description:\s*(.+)$/m)?.[1] ?? '';
        assets.push(
          asset({
            id: `agent:sub-${name}-${fmName}`,
            kind: 'agent',
            name: fmName,
            summary: desc.slice(0, 100),
            attach: { level: 'project', ref: dir },
            applies: ws ? { workspaces: [ws.id], origin: 'native' } : undefined,
            enforcement: 'advisory',
            payload: { subagent: true, frontmatter: md.split('---')[1]?.trim() ?? '', bodyLines: md.split('\n').length },
            source: { collector: 'claude-projects', path: join(dotClaude, 'agents', a), sha256: sha256(md) },
            tags: ['subagent', 'claude-code'],
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
            tags: ['project-hook', ...(ws ? [ws.id] : [])],
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
            applies: ws ? { workspaces: [ws.id], origin: 'native' } : undefined,
            enforcement: 'enforced',
            payload: { transport: 'stdio', command: def.command, args: def.args },
            source: { collector: 'claude-projects', path: join(dir, '.mcp.json'), locator: `$.mcpServers.${mcpName}` },
            tags: ['mcp', ...(ws ? [ws.id] : [])],
          })
        );
      }
    }

    return { assets, relations, diagnostics: ctx.diagnostics };
  },
};
