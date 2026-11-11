import type { Asset, Relation } from '@forge/schema';
import { join } from 'node:path';
import { exists, firstHeading, guessLang, headings, listDir, readJson, readText, sha256 } from '../util.js';
import { asset, type CollectContext, type Collector } from '../types.js';
import { redactObject } from '../redact.js';

interface SettingsHooks {
  [event: string]: Array<{ matcher?: string; hooks?: Array<{ type?: string; command?: string }> }>;
}

/** 在插件缓存目录 `cache/<marketplace>/<plugin>/<version>/agents` 中选最新版本的 agents 目录 */
async function resolvePluginAgentsDir(pluginBase: string): Promise<string | null> {
  let best: { dir: string; ver: string } | null = null;
  for (const v of await listDir(pluginBase)) {
    const d = join(pluginBase, v, 'agents');
    if (!(await exists(d))) continue;
    if (!best || newerVersion(v, best.ver)) best = { dir: d, ver: v };
  }
  return best?.dir ?? null;
}

function newerVersion(a: string, b: string): boolean {
  const pa = a.split('.').map((x) => Number.parseInt(x, 10));
  const pb = b.split('.').map((x) => Number.parseInt(x, 10));
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const va = Number.isFinite(pa[i]) ? pa[i] : -1;
    const vb = Number.isFinite(pb[i]) ? pb[i] : -1;
    if (va !== vb) return va > vb;
  }
  return false;
}

export const claudeGlobalCollector: Collector = {
  name: 'claude-global',
  mode: 'watch',
  watchPaths: (ctx) => [ctx.paths.claude],
  async collect(ctx: CollectContext) {
    const assets: Asset[] = [];
    const relations: Relation[] = [];
    const claude = ctx.paths.claude;

    const settings = (await readJson<Record<string, unknown>>(join(claude, 'settings.json'))) ?? {};

    // hooks 注册（user 层）：按 CC hooks schema 整表遍历（event → matcher entry → hooks[] 全量命令）。
    // 归属判定：自研统一入口对照 bootstrap/hooks-registration.json 声明（wrapper 路径锚定，不按仓库名猜）；
    // hindsight 旁挂按部署根目录识别（根规则，非逐条登记）；其余为外部挂载。
    const hookManifest = await readJson<{ wrapper?: string; alias?: string }>(
      join(ctx.paths.devforge, 'bootstrap', 'hooks-registration.json')
    );
    const wrapperToken = hookManifest?.wrapper ? `claude-hooks/${hookManifest.wrapper}` : null;
    const hooks = (settings.hooks ?? {}) as SettingsHooks;
    for (const [event, entries] of Object.entries(hooks)) {
      for (let i = 0; i < entries.length; i++) {
        const entry = entries[i];
        const allCmds = entry.hooks ?? [];
        for (let j = 0; j < allCmds.length; j++) {
          const command = allCmds[j]?.command ?? '';
          if (!command) continue;
          const isDevforge = wrapperToken !== null && command.includes(wrapperToken);
          const isHindsight = command.includes('.hindsight');
          assets.push(
            asset({
              id: `hook-registration:${event}-${i}-${j}-${isDevforge ? 'devforge' : isHindsight ? 'hindsight' : 'other'}`,
              kind: 'hook-registration',
              name: `${event} → ${isDevforge ? 'dev-forge 统一入口' : isHindsight ? 'hindsight 旁挂' : '自定义'}`,
              summary: command.length > 120 ? command.slice(0, 120) + '…' : command,
              attach: { level: 'user' },
              enforcement: 'enforced',
              // user 级挂载对机器上所有 claude-code 会话生效，multica agent 会话同样经过这些钩子
              platforms: ['claude-code', 'multica'],
              provenance: isDevforge || isHindsight ? 'first-party' : 'third-party',
              tags: [event, isDevforge ? 'devforge' : isHindsight ? 'hindsight' : 'custom'],
              source: { collector: 'claude-global', path: join(claude, 'settings.json'), locator: `$.hooks.${event}[${i}][${j}]` },
              payload: { event, matcher: entry.matcher ?? '*', command: redactObject(command) },
            })
          );
        }
      }
    }

    // env（脱敏）
    const env = (settings.env ?? {}) as Record<string, string>;
    const envKeys = Object.keys(env);
    if (envKeys.length > 0) {
      assets.push(
        asset({
          id: 'env:claude-global-settings',
          kind: 'env',
          name: '全局 env（settings.json）',
          summary: `${envKeys.length} 项 · 已脱敏`,
          attach: { level: 'user' },
          enforcement: 'enforced',
          platforms: ['claude-code'],
          payload: { values: redactObject(env), count: envKeys.length },
          source: { collector: 'claude-global', path: join(claude, 'settings.json'), locator: '$.env' },
          tags: ['settings'],
        })
      );
    }

    // permissions + plugins
    const permissions = settings.permissions as Record<string, unknown> | undefined;
    if (permissions) {
      assets.push(
        asset({
          id: 'custom:claude-permissions',
          kind: 'custom',
          name: '权限策略（settings.json）',
          summary: `allow ${(permissions.allow as unknown[] | undefined)?.length ?? 0} · deny ${(permissions.deny as unknown[] | undefined)?.length ?? 0}`,
          attach: { level: 'user' },
          enforcement: 'enforced',
          platforms: ['claude-code'],
          payload: { permissions: redactObject(permissions) },
          source: { collector: 'claude-global', path: join(claude, 'settings.json'), locator: '$.permissions' },
          tags: ['permissions', 'first-party-config'],
        })
      );
    }
    const plugins = settings.enabledPlugins as Record<string, boolean> | undefined;
    if (plugins) {
      assets.push(
        asset({
          id: 'custom:claude-plugins',
          kind: 'custom',
          name: '插件开关（enabledPlugins）',
          summary: Object.entries(plugins).filter(([, v]) => v).map(([k]) => k.split('@')[0]).join(' · ') || '全部关闭',
          attach: { level: 'user' },
          enforcement: 'enforced',
          platforms: ['claude-code'],
          payload: { plugins },
          source: { collector: 'claude-global', path: join(claude, 'settings.json'), locator: '$.enabledPlugins' },
          tags: ['plugins', 'first-party-config'],
        })
      );
    }

    // .mcp.json → mcp-endpoint
    const mcp = (await readJson<{ mcpServers?: Record<string, { command?: string; args?: string[]; type?: string; url?: string }> }>(join(claude, '.mcp.json')))?.mcpServers ?? {};
    for (const [name, def] of Object.entries(mcp)) {
      assets.push(
        asset({
          id: `mcp-endpoint:user-${name}`,
          kind: 'mcp-endpoint',
          name: name,
          summary: def.url ? `HTTP ${def.url}` : `stdio ${def.command ?? ''} ${(def.args ?? []).join(' ').slice(0, 60)}`,
          attach: { level: 'user' },
          enforcement: 'enforced',
          platforms: ['claude-code'],
          payload: { transport: def.url ? 'http' : 'stdio', command: def.command, args: def.args, url: def.url ? redactObject(def.url) : undefined },
          source: { collector: 'claude-global', path: join(claude, '.mcp.json'), locator: `$.mcpServers.${name}` },
          tags: ['mcp'],
        })
      );
    }

    // skills（user 目录：均为第三方工具技能；自建需经 registry.d 声明）+ .agents/skills（ECC）
    for (const [dir, tag] of [
      [join(claude, 'skills'), 'global'] as const,
      [join(claude, '.agents', 'skills'), 'ecc'] as const,
    ]) {
      if (!(await exists(dir))) continue;
      for (const name of await listDir(dir)) {
        const skillDir = join(dir, name);
        const md = (await readText(join(skillDir, 'SKILL.md'))) ?? (await readText(join(skillDir, 'skill.md'))) ?? '';
        const descMatch = md.match(/^description:\s*(.+)$/m) ?? md.match(/^#\s+(.+)$/m);
        assets.push(
          asset({
            id: `skill:${tag === 'ecc' ? 'ecc' : 'user'}-${name}`,
            kind: 'skill',
            name: name,
            summary: descMatch ? descMatch[1].slice(0, 100) : '',
            attach: { level: 'user' },
            enforcement: 'advisory',
            platforms: ['claude-code'],
            provenance: 'third-party',
            tags: ['skill', tag],
            source: { collector: 'claude-global', path: join(skillDir, 'SKILL.md'), sha256: md ? sha256(md) : undefined },
            payload: { hasBody: md.length > 0, lines: md.split('\n').length, scope: tag, content: md.length <= 200_000 ? md : md.slice(0, 200_000) },
          })
        );
      }
    }

    // commands → skill（command 型）
    const commandsDir = join(claude, 'commands');
    if (await exists(commandsDir)) {
      for (const f of (await listDir(commandsDir)).filter((f) => f.endsWith('.md'))) {
        const md = (await readText(join(commandsDir, f))) ?? '';
        if (!md) continue;
        assets.push(
          asset({
            id: `skill:cmd-${f.replace(/\.md$/, '')}`,
            kind: 'skill',
            name: `/${f.replace(/\.md$/, '')}`,
            summary: md.split('\n').find((l) => l.trim())?.slice(0, 100) ?? '',
            attach: { level: 'user' },
            enforcement: 'advisory',
            platforms: ['claude-code'],
            provenance: 'third-party',
            payload: { command: true, lines: md.split('\n').length, content: md.length <= 200_000 ? md : md.slice(0, 200_000) },
            source: { collector: 'claude-global', path: join(commandsDir, f), sha256: sha256(md) },
            tags: ['command'],
          })
        );
      }
    }

    // agents：用户级 ~/.claude/agents + 已启用插件的 agents/（Claude Code 以 `插件:agent` 呈现）
    const enabledPlugins = (settings.enabledPlugins ?? {}) as Record<string, boolean>;
    const agentSources: Array<{ dir: string; plugin: string | null }> = [];
    const userAgentsDir = join(claude, 'agents');
    if (await exists(userAgentsDir)) agentSources.push({ dir: userAgentsDir, plugin: null });
    for (const [key, on] of Object.entries(enabledPlugins)) {
      if (!on) continue;
      const at = key.indexOf('@');
      const plugin = at > 0 ? key.slice(0, at) : key;
      const marketplace = at > 0 ? key.slice(at + 1) : '';
      const dir = marketplace
        ? await resolvePluginAgentsDir(join(claude, 'plugins', 'cache', marketplace, plugin))
        : null;
      if (dir) agentSources.push({ dir, plugin });
    }
    for (const { dir, plugin } of agentSources) {
      for (const f of (await listDir(dir)).filter((x) => x.endsWith('.md'))) {
        const p = join(dir, f);
        const md = (await readText(p)) ?? '';
        if (!md) continue;
        const fmName = md.match(/^name:\s*(.+)$/m)?.[1] ?? f.replace(/\.md$/, '');
        const desc = md.match(/^description:\s*(.+)$/m)?.[1] ?? '';
        assets.push(
          asset({
            id: plugin ? `agent:plugin-${plugin}-${fmName.toLowerCase()}` : `agent:user-${fmName.toLowerCase()}`,
            kind: 'agent',
            name: plugin ? `${plugin}:${fmName}` : fmName,
            summary: desc.slice(0, 100),
            attach: { level: 'user' },
            enforcement: 'advisory',
            platforms: ['claude-code'],
            provenance: 'third-party',
            payload: {
              subagent: true,
              plugin: plugin ?? undefined,
              frontmatter: md.split('---')[1]?.trim() ?? '',
              bodyLines: md.split('\n').length,
            },
            source: { collector: 'claude-global', path: p, sha256: sha256(md) },
            tags: plugin ? ['agent', 'plugin', plugin] : ['agent', 'user'],
          })
        );
      }
    }

    // rules/*.md → instruction（第三方规则包 → 依赖架）
    const rulesDir = join(claude, 'rules');
    if (await exists(rulesDir)) {
      const groups = await listDir(rulesDir);
      for (const g of groups) {
        const sub = join(rulesDir, g);
        const stat = await import('node:fs/promises').then((m) => m.stat(sub).catch(() => null));
        if (!stat?.isDirectory()) continue;
        for (const f of (await listDir(sub)).filter((x) => x.endsWith('.md'))) {
          const p = join(sub, f);
          const md = await readText(p);
          if (md === null) continue;
          assets.push(
            asset({
              id: `instruction:rules-${g}-${f.replace(/\.md$/, '')}`,
              kind: 'instruction',
              name: f.replace(/\.md$/, ''),
              summary: firstHeading(md) || `${md.split('\n').length} 行`,
              attach: { level: 'user' },
              enforcement: 'advisory',
              platforms: ['claude-code'],
              provenance: 'third-party',
              tags: ['rules', g],
              source: { collector: 'claude-global', path: p, sha256: sha256(md) },
              payload: {
                group: g,
                basename: f,
                lines: md.split('\n').length,
                headings: headings(md).slice(0, 20),
                lang: guessLang(md),
                content: md.length <= 200_000 ? md : md.slice(0, 200_000),
                contentHash: sha256(md),
              },
            })
          );
        }
      }
    }

    return { assets, relations, diagnostics: ctx.diagnostics };
  },
};
