import type { Asset, Relation } from '@forge/schema';
import { join } from 'node:path';
import { humanizeWhen, listDir, readJson, readText, sha256 } from '../util.js';
import { asset, type CollectContext, type Collector } from '../types.js';

interface RuleDef {
  name: string;
  on?: { in?: string[]; except?: string[] };
  agents?: { include?: string[]; except?: string[] };
  one_shot?: boolean | { ids?: string[] } | { id?: string };
  enabled?: boolean;
  when?: unknown;
  action?: Array<{ op: string; message?: string }>;
  owner?: string;
  blocking?: boolean;
  version_note?: string;
  description?: string;
}

function oneShotSummary(os: RuleDef['one_shot']): string {
  if (!os) return '—';
  if (os === true) return 'run 一次';
  const ids = 'ids' in os ? os.ids : 'id' in os ? [os.id] : [];
  return (ids ?? []).join(' × ') || '一次';
}

function actionSummary(actions: RuleDef['action']): string {
  if (!actions?.length) return '—';
  return actions.map((a) => (a.op === 'deny' ? 'DENY' : a.op === 'context' ? 'CONTEXT' : a.op.toUpperCase())).join('+');
}

export const devforgeHooksCollector: Collector = {
  name: 'devforge-hooks',
  mode: 'watch',
  watchPaths: (ctx) => [join(ctx.paths.devforge, 'claude-hooks')],
  async collect(ctx: CollectContext) {
    const assets: Asset[] = [];
    const relations: Relation[] = [];
    const hooksDir = join(ctx.paths.devforge, 'claude-hooks');
    const unified = join(hooksDir, 'unified');

    // 注册清单 manifest
    const manifest = await readJson<Record<string, unknown>>(join(ctx.paths.devforge, 'bootstrap', 'hooks-registration.json'));
    if (manifest) {
      const stateCount = (await listDir(join(unified, 'state'))).length;
      assets.push(
        asset({
          id: 'hook-registration:devforge-manifest',
          kind: 'hook-registration',
          name: 'dev-forge 注册清单（hooks-registration.json）',
          summary: `${(manifest.hook_points as string[] | undefined)?.length ?? 9} 挂载点 · alias ${String(manifest.alias ?? '')} · one-shot 哨兵 ${stateCount}`,
          attach: { level: 'user' },
          enforcement: 'enforced',
          platforms: ['claude-code', 'multica'],
          source: { collector: 'devforge-hooks', path: join(ctx.paths.devforge, 'bootstrap', 'hooks-registration.json'), sha256: sha256(JSON.stringify(manifest)) },
          payload: { ...manifest, stateSentinels: stateCount },
          tags: ['devforge', 'manifest'],
        })
      );
    }

    // 规则：rules-v2.json + rules.d/*.json
    const ruleFiles = [join(unified, 'rules-v2.json'), ...(await listDir(join(unified, 'rules.d'))).map((f) => join(unified, 'rules.d', f))];
    for (const file of ruleFiles) {
      const doc = await readJson<{ rules?: RuleDef[]; description?: string }>(file);
      if (!doc?.rules) continue;
      const isOverlay = file.includes('rules.d');
      const fileDesc = doc.description ?? '';
      for (const rule of doc.rules) {
        const whenHuman = rule.when ? humanizeWhen(rule.when) : '—（无 when，事件即触发）';
        assets.push(
          asset({
            id: `hook-rule:${rule.name}`,
            kind: 'hook-rule',
            name: rule.name,
            summary: `${actionSummary(rule.action)} · ${whenHuman}`.slice(0, 140),
            attach: { level: 'user' },
            applies: rule.agents
              ? {
                  agents: { include: rule.agents.include, except: rule.agents.except },
                  origin: 'native',
                }
              : undefined,
            enforcement: 'enforced',
            platforms: ['claude-code', 'multica'],
            enabled: rule.enabled !== false,
            owner: rule.owner,
            source: { collector: 'devforge-hooks', path: file, locator: `$.rules[?(@.name=="${rule.name}")]`, sha256: undefined },
            payload: {
              on: rule.on?.in ?? rule.on?.except ?? [],
              onExcept: rule.on?.except,
              agents: rule.agents,
              oneShot: oneShotSummary(rule.one_shot),
              whenHuman,
              when: rule.when,
              actions: rule.action?.map((a) => ({ op: a.op, message: (a.message ?? '').slice(0, 300) })) ?? [],
              blocking: rule.blocking,
              versionNote: rule.version_note?.slice(0, 400),
              fileDeclaredScope: fileDesc.slice(0, 400),
              overlay: isOverlay,
            },
            tags: [
              ...(rule.action?.some((a) => a.op === 'deny') ? ['blocking'] : []),
              ...(rule.agents?.include ?? []).map((a) => `agent:${a}`),
              'devforge',
            ],
          })
        );
      }
    }

    // 挂载脚本
    const scriptsDir = join(hooksDir, 'scripts');
    for (const f of (await listDir(scriptsDir))) {
      if (!f.endsWith('.sh')) continue;
      const p = join(scriptsDir, f);
      const md = (await readText(p)) ?? '';
      const purpose = md.split('\n').find((l) => l.startsWith('# ') && !l.includes('!/'))?.replace(/^#\s*/, '') ?? '';
      assets.push(
        asset({
          id: `hook-script:${f}`,
          kind: 'hook-script',
          name: f,
          summary: purpose.slice(0, 100),
          attach: { level: 'user' },
          enforcement: 'enforced',
          platforms: ['claude-code'],
          source: { collector: 'devforge-hooks', path: p, sha256: sha256(md) },
          payload: { lines: md.split('\n').length, purpose },
          tags: ['devforge', 'script'],
        })
      );
    }

    // lib 脚本
    const libDir = join(scriptsDir, 'lib');
    for (const f of (await listDir(libDir)).filter((x) => x.endsWith('.sh'))) {
      assets.push(
        asset({
          id: `hook-script:lib-${f}`,
          kind: 'hook-script',
          name: `lib/${f}`,
          summary: '共用库（被 scripts 引用）',
          attach: { level: 'user' },
          enforcement: 'derived',
          source: { collector: 'devforge-hooks', path: join(libDir, f) },
          payload: {},
          tags: ['devforge', 'lib'],
        })
      );
    }

    return { assets, relations, diagnostics: ctx.diagnostics };
  },
};
