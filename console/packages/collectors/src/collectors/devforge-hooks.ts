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
  action?: Array<{ op: string; message?: string; path?: string }>;
  owner?: string;
  blocking?: boolean;
  version_note?: string;
  description?: string;
  harness?: string[];
}

function oneShotSummary(os: RuleDef['one_shot']): string {
  if (!os) return '—';
  if (os === true) return 'run 一次';
  const ids = 'ids' in os ? os.ids : 'id' in os ? [os.id] : [];
  return (ids ?? []).join(' × ') || '一次';
}

function actionSummary(actions: RuleDef['action']): string {
  if (!actions?.length) return '—';
  const labels: Record<string, string> = { deny: 'DENY', context: 'CONTEXT', run_script: 'SCRIPT' };
  return actions.map((a) => labels[a.op] ?? a.op.toUpperCase()).join('+');
}

const WHEN_COMBINATORS = new Set(['all', 'any', 'not']);

function collectWhenSourceOps(node: unknown, acc: Set<string>): void {
  if (!node || typeof node !== 'object') return;
  const n = node as Record<string, unknown>;
  if (typeof n.op === 'string' && !WHEN_COMBINATORS.has(n.op)) acc.add(n.op);
  if (Array.isArray(n.args)) for (const a of n.args) collectWhenSourceOps(a, acc);
  if (n.arg && typeof n.arg === 'object') collectWhenSourceOps(n.arg, acc);
}

function whenKindOf(rule: RuleDef): 'none' | 'payload' | 'ops' | 'mixed' {
  if (!rule.when) return 'none';
  const ops = new Set<string>();
  collectWhenSourceOps(rule.when, ops);
  const hasPayload = ops.has('payload');
  const hasOps = [...ops].some((o) => o !== 'payload');
  if (hasPayload && hasOps) return 'mixed';
  return hasPayload ? 'payload' : 'ops';
}

/** 提取 when op 树中的 repo 门控（RIPPLE：repos.json 注册表作用域），无则 undefined */
export function repoGatingOf(when: unknown): { in?: string[]; registered?: boolean } | undefined {
  if (!when || typeof when !== 'object') return undefined;
  const n = when as Record<string, unknown>;
  if (n.op === 'repo') {
    return {
      in: Array.isArray(n.in) ? n.in.filter((x): x is string => typeof x === 'string') : undefined,
      registered: n.registered === true || undefined,
    };
  }
  if (Array.isArray(n.args)) {
    for (const a of n.args) {
      const hit = repoGatingOf(a);
      if (hit) return hit;
    }
  }
  if (n.arg && typeof n.arg === 'object') return repoGatingOf(n.arg);
  return undefined;
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
          id: 'custom:devforge-hook-manifest',
          kind: 'custom',
          name: 'dev-forge 注册清单（hooks-registration.json）',
          summary: `${(manifest.hook_points as string[] | undefined)?.length ?? 9} 挂载点 · alias ${String(manifest.alias ?? '')} · one-shot 哨兵 ${stateCount}`,
          attach: { level: 'user' },
          enforcement: 'enforced',
          // 自研面工件（非平台对象，钩子页展示）；归属声明由 registry.d 决定
          platforms: [],
          source: { collector: 'devforge-hooks', path: join(ctx.paths.devforge, 'bootstrap', 'hooks-registration.json'), sha256: sha256(JSON.stringify(manifest)) },
          payload: { ...manifest, stateSentinels: stateCount },
          tags: ['devforge', 'manifest'],
        })
      );
    }

    // 规则：rules-v2.json + rules.d/*.json
    const ruleFiles = [join(unified, 'rules-v2.json'), ...(await listDir(join(unified, 'rules.d'))).map((f) => join(unified, 'rules.d', f))];
    // 使用方分析（采集侧算好，payload.usage 供 UI 展示）：run_script 路径 basename → 挂载规则
    const mountedBy = new Map<string, Set<string>>();
    for (const file of ruleFiles) {
      const doc = await readJson<{ rules?: RuleDef[]; description?: string }>(file);
      if (!doc?.rules) continue;
      const isOverlay = file.includes('rules.d');
      const fileDesc = doc.description ?? '';
      for (const rule of doc.rules) {
        const whenHuman = rule.when ? humanizeWhen(rule.when) : '—（无 when，事件即触发）';
        const repoGating = repoGatingOf(rule.when);
        for (const a of rule.action ?? []) {
          if (a.op !== 'run_script') continue;
          const f = a.path?.split('/').pop();
          if (f) {
            if (!mountedBy.has(f)) mountedBy.set(f, new Set());
            mountedBy.get(f)!.add(rule.name);
          }
        }
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
            // dev-forge 工具链内部文件：归属由 registry.d 声明（devforge-hooks-engine → claude-code+multica）
            platforms: [],
            enabled: rule.enabled !== false,
            owner: rule.owner,
            source: { collector: 'devforge-hooks', path: file, locator: `$.rules[?(@.name=="${rule.name}")]`, sha256: undefined },
            payload: {
              harness: rule.harness ?? ['claude-code'],
              whenKind: whenKindOf(rule),
              on: rule.on?.in ?? rule.on?.except ?? [],
              onExcept: rule.on?.except,
              agents: rule.agents,
              repoGating,
              oneShot: oneShotSummary(rule.one_shot),
              whenHuman,
              when: rule.when,
              actions: rule.action?.map((a) => ({ op: a.op, message: (a.message ?? '').slice(0, 300), path: a.path?.split('/').pop() })) ?? [],
              blocking: rule.blocking,
              versionNote: rule.version_note?.slice(0, 400),
              fileDeclaredScope: fileDesc.slice(0, 400),
              overlay: isOverlay,
            },
            tags: [
              ...(rule.action?.some((a) => a.op === 'deny') ? ['blocking'] : []),
              ...(rule.agents?.include ?? []).map((a) => `agent:${a}`),
              ...(repoGating?.in ?? []).map((r) => `repo:${r}`),
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
          platforms: [],
          source: { collector: 'devforge-hooks', path: p, sha256: sha256(md) },
          payload: { lines: md.split('\n').length, purpose, content: md },
          tags: ['devforge', 'script'],
        })
      );
    }

    // 入口层脚本（wrapper / dispatcher / unified-hook）：非规则挂载体，是链路自身的环节；
    // 采集它们让「使用方」分析能闭合 lib 脚本的间接引用（被入口层 source）
    for (const f of (await listDir(hooksDir)).filter((x) => x.endsWith('.sh'))) {
      const p = join(hooksDir, f);
      const md = (await readText(p)) ?? '';
      const purpose = md.split('\n').find((l) => l.startsWith('# ') && !l.includes('!/'))?.replace(/^#\s*/, '') ?? '';
      assets.push(
        asset({
          id: `hook-script:entry-${f}`,
          kind: 'hook-script',
          name: f,
          summary: purpose.slice(0, 100),
          attach: { level: 'user' },
          enforcement: 'enforced',
          platforms: [],
          source: { collector: 'devforge-hooks', path: p, sha256: sha256(md) },
          payload: { lines: md.split('\n').length, purpose, content: md, entry: true },
          tags: ['devforge', 'entry'],
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
          // dev-forge 工具链内部文件：归属由 registry.d 声明（devforge-hooks-engine → claude-code+multica）
          platforms: [],
          source: { collector: 'devforge-hooks', path: join(libDir, f) },
          payload: {},
          tags: ['devforge', 'lib'],
        })
      );
    }

    // 使用方回填：mountedBy = 规则直接挂载；referencedBy = 其他脚本正文引用（lib 间接使用的依据）
    const scriptAssets = assets.filter((a) => a.kind === 'hook-script');
    for (const target of scriptAssets) {
      const variants = [target.name, target.name.startsWith('lib-') ? `lib/${target.name.slice(4)}` : target.name];
      const referencedBy = scriptAssets
        .filter((o) => o !== target)
        .filter((o) => {
          const c = (o.payload as { content?: string }).content ?? '';
          return variants.some((v) => c.includes(v));
        })
        .map((o) => o.name);
      const mount = new Set<string>(mountedBy.get(target.name) ?? []);
      for (const v of variants) for (const n of mountedBy.get(v) ?? []) mount.add(n);
      (target.payload as Record<string, unknown>).usage = {
        mountedBy: [...mount],
        referencedBy: [...new Set(referencedBy)],
      };
    }

    return { assets, relations, diagnostics: ctx.diagnostics };
  },
};
