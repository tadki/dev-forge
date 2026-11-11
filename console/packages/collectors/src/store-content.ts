import { createHash } from 'node:crypto';
import type { Asset, AssetKind } from '@forge/schema';

/**
 * 库真源语义（Owner 2026-11-06）：first-party store 是真源，生产是投影。
 * 本模块定义「内容指纹」——按 kind 只取内容字段，剔除运行态/volatile 字段，
 * 供 store 落盘与 store-drift 对账共用（绝不两处各写一套）。
 */

/** 进库且参与漂移对账的 kind（其余 kind 永远只是生产实测投影） */
export const TRUTH_KINDS: readonly AssetKind[] = [
  'instruction',
  'skill',
  'agent',
  'hook-rule',
  'hook-script',
  'adapter',
  'autopilot-script',
  'autopilot-registration',
];

export function isTruthKind(kind: string): boolean {
  return (TRUTH_KINDS as readonly string[]).includes(kind);
}

/** 规范化 JSON：键排序 + 数组原样（需要排序的数组由各 kind 选择器先排好） */
function canon(value: unknown): string {
  if (value === undefined) return 'null';
  if (Array.isArray(value)) return `[${value.map(canon).join(',')}]`;
  if (value && typeof value === 'object') {
    const keys = Object.keys(value as Record<string, unknown>).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canon((value as Record<string, unknown>)[k])}`).join(',')}}`;
  }
  return JSON.stringify(value) ?? 'null';
}

function pick(payload: Record<string, unknown>, keys: string[]): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const k of keys) if (payload[k] !== undefined) out[k] = payload[k];
  return out;
}

function sortedBy<T>(arr: T[] | undefined, key: (item: T) => string | undefined): T[] | undefined {
  if (!Array.isArray(arr)) return undefined;
  return [...arr].sort((a, b) => String(key(a) ?? '').localeCompare(String(key(b) ?? '')));
}

/** 按 kind 提取内容视图（kind 之外的 kind 由上层排除，不会进来） */
function contentView(asset: Asset): Record<string, unknown> {
  const p = asset.payload as Record<string, unknown>;
  switch (asset.kind) {
    case 'instruction':
      return pick(p, ['content']);
    case 'skill': {
      const files = sortedBy(p.files as Array<{ path: string }> | undefined, (f) => f.path);
      const labels = Array.isArray(p.labels) ? [...(p.labels as string[])].sort() : undefined;
      return { ...pick(p, ['content', 'command', 'scope']), ...(files ? { files } : {}), ...(labels ? { labels } : {}) };
    }
    case 'agent': {
      const skills = sortedBy(p.skills as Array<{ name: string }> | undefined, (s) => s.name);
      // 剔除 customEnvKeyCount（计数是投影，env 值不可对账）、instructionsHash、mcpRedacted
      return { ...pick(p, ['instructions', 'description', 'model', 'thinkingLevel', 'mcp', 'customArgs', 'disabledRuntimeSkills']), ...(skills ? { skills } : {}) };
    }
    case 'hook-rule': {
      const { registry: _r, fileDeclaredScope: _f, ...rest } = p;
      return rest;
    }
    case 'hook-script':
      return { sha256: asset.source.sha256, ...pick(p, ['purpose']) };
    case 'adapter':
      return { sha256: asset.source.sha256, ...pick(p, ['envContract', 'purpose']) };
    case 'autopilot-script':
      // 本地脚本型 / 配置 / agent 评审型（content 已归档不进指纹）
      return { sha256: asset.source.sha256, ...pick(p, ['purpose', 'reviewKind', 'templates']) };
    case 'autopilot-registration': {
      // multica 平台注册项：只取调度定义，剔除 status/lastRun*/nextRunAt（含 triggers 内的 next_run_at）。
      // assignee 剔除：agent list 故障时解析为原始 UUID、恢复后为名字，指纹会在两次采集间来回翻转制造假漂移。
      const triggers = (p.triggers as Array<Record<string, unknown>> | undefined)?.map((t) =>
        pick(t, ['id', 'kind', 'cron_expression', 'timezone', 'enabled'])
      );
      const triggersSorted = sortedBy(triggers, (t) => t.id as string);
      return { ...pick(p, ['platformId', 'description']), ...(triggersSorted ? { triggers: triggersSorted } : {}) };
    }
    default:
      return p;
  }
}

/** 内容指纹 v2：kind + 内容视图（volatile 已剔除）。同名不同 id 不会碰撞（id 另存，不进指纹） */
export function contentFingerprint(asset: Asset): string {
  const view = contentView(asset);
  return createHash('sha256').update(`${asset.kind}|${canon(view)}`).digest('hex');
}

/** 内容视图的可读行（键排序、每字段一行，与 canon 同一排序语义）：无文本字段 kind 的 store-drift 用它做逐字段对照 */
export function contentViewLines(asset: Asset): string[] {
  const view = contentView(asset) as Record<string, unknown>;
  return Object.keys(view).sort().map((k) => `${k}: ${JSON.stringify(view[k])}`);
}
