import type { Asset, Relation } from '@forge/schema';
import { join } from 'node:path';
import { exists, firstHeading, guessLang, headings, listDir, readJson, readText, sha256 } from '../util.js';
import { asset, type CollectContext, type Collector } from '../types.js';
import { redactObject } from '../redact.js';

interface SettingsHooks {
  [event: string]: Array<{ matcher?: string; hooks?: Array<{ type?: string; command?: string }> }>;
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

    // hooks 注册（user 层）
    const hooks = (settings.hooks ?? {}) as SettingsHooks;
    for (const [event, entries] of Object.entries(hooks)) {
      for (let i = 0; i < entries.length; i++) {
        const entry = entries[i];
        const command = entry.hooks?.[0]?.command ?? '';
        if (!command) continue;
        const isDevforge = command.includes('dev-forge');
        const isHindsight = command.includes('.hindsight');
        assets.push(
          asset({
            id: `hook-registration:${event}-${i}-${isDevforge ? 'devforge' : isHindsight ? 'hindsight' : 'other'}`,
            kind: 'hook-registration',
            name: `${event} → ${isDevforge ? 'dev-forge 统一入口' : isHindsight ? 'hindsight 旁挂' : '自定义'}`,
            summary: command.length > 120 ? command.slice(0, 120) + '…' : command,
            attach: { level: 'user' },
            enforcement: 'enforced',
            platforms: ['claude-code'],
            provenance: isDevforge || isHindsight ? 'first-party' : 'third-party',
            tags: [event, isDevforge ? 'devforge' : isHindsight ? 'hindsight' : 'custom'],
            source: { collector: 'claude-global', path: join(claude, 'settings.json'), locator: `$.hooks.${event}[${i}]` },
            payload: { event, matcher: entry.matcher ?? '*', command: redactObject(command) },
          })
        );
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
          payload: { transport: def.url ? 'http' : 'stdio', command: def.command, args: def.args, url: def.url ? redactObject(def.url) : undefined },
          source: { collector: 'claude-global', path: join(claude, '.mcp.json'), locator: `$.mcpServers.${name}` },
          tags: ['mcp'],
        })
      );
    }

    // skills（first-party）+ .agents/skills（ECC third-party）
    for (const [dir, provenance, tag] of [
      [join(claude, 'skills'), 'first-party', 'global'] as const,
      [join(claude, '.agents', 'skills'), 'third-party', 'ecc'] as const,
    ]) {
      if (!(await exists(dir))) continue;
      for (const name of await listDir(dir)) {
        const skillDir = join(dir, name);
        const md = (await readText(join(skillDir, 'SKILL.md'))) ?? (await readText(join(skillDir, 'skill.md'))) ?? '';
        if (!md && provenance === 'first-party') continue;
        const descMatch = md.match(/^description:\s*(.+)$/m) ?? md.match(/^#\s+(.+)$/m);
        assets.push(
          asset({
            id: `skill:${provenance === 'first-party' ? 'user' : 'ecc'}-${name}`,
            kind: 'skill',
            name: name,
            summary: descMatch ? descMatch[1].slice(0, 100) : '',
            attach: { level: 'user' },
            enforcement: provenance === 'first-party' ? 'advisory' : 'advisory',
            provenance,
            tags: ['skill', tag],
            source: { collector: 'claude-global', path: join(skillDir, 'SKILL.md'), sha256: md ? sha256(md) : undefined },
            payload: { hasBody: md.length > 0, lines: md.split('\n').length, scope: tag },
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
            payload: { command: true, lines: md.split('\n').length },
            source: { collector: 'claude-global', path: join(commandsDir, f), sha256: sha256(md) },
            tags: ['command'],
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
              provenance: 'third-party',
              tags: ['rules', g],
              source: { collector: 'claude-global', path: p, sha256: sha256(md) },
              payload: { group: g, basename: f, lines: md.split('\n').length, headings: headings(md).slice(0, 20), lang: guessLang(md) },
            })
          );
        }
      }
    }

    return { assets, relations, diagnostics: ctx.diagnostics };
  },
};
