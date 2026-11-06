import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { parse } from 'yaml';
import type { Asset, Diagnostic } from '@forge/schema';

/**
 * 平台适配层（Owner 2026-11-06）：每个平台一套读写适配，声明在 console/platforms.d/*.yaml。
 * - match：资产归属识别（替代散落的 source.path.startsWith('multica://') 硬编码）
 * - kinds[kind].write：以库为准物化通道——file-write（本地文件）/ command（平台 CLI）/ none+advice（仅建议）
 * 安全校验（路径白名单/备份/dry-run）不在 YAML，仍在执行器代码。
 */
export interface PlatformWriteCommand {
  type: 'command';
  cmd: string[];
  /** platformId 取值位置：self=资产 payload.platformId；deployment=该 agent 的 deployment 资产 payload.platformId */
  platformIdFrom?: 'self' | 'deployment';
}
export interface PlatformWriteNone {
  type: 'none';
  advice: string;
}
export type PlatformWrite = { type: 'file-write' } | PlatformWriteCommand | PlatformWriteNone;

export interface PlatformDef {
  id: string;
  label?: string;
  match: { pathPrefix?: string[] };
  kinds?: Record<string, { write: PlatformWrite }>;
}

export interface LoadedPlatforms {
  platforms: PlatformDef[];
  diagnostics: Diagnostic[];
}

/** platforms.d 缺失时的兜底（与 console/platforms.d 的两份 YAML 等价；运行态以 YAML 为准） */
export const DEFAULT_PLATFORMS: PlatformDef[] = [
  {
    id: 'claude-code',
    label: 'Claude Code（本地文件系统）',
    match: { pathPrefix: ['/'] },
    kinds: {
      instruction: { write: { type: 'file-write' } },
      skill: { write: { type: 'file-write' } },
      agent: { write: { type: 'file-write' } },
      'hook-rule': { write: { type: 'file-write' } },
      'hook-script': { write: { type: 'file-write' } },
      adapter: { write: { type: 'file-write' } },
      autopilot: { write: { type: 'file-write' } },
    },
  },
  {
    id: 'multica',
    label: 'multica 平台',
    match: { pathPrefix: ['multica://'] },
    kinds: {
      skill: {
        write: { type: 'command', cmd: ['multica', 'skill', 'update', '{platformId}', '--content', '{content}'], platformIdFrom: 'self' },
      },
      agent: {
        write: { type: 'command', cmd: ['multica', 'agent', 'update', '{platformId}', '--instructions', '{content}'], platformIdFrom: 'deployment' },
      },
      instruction: {
        write: { type: 'none', advice: 'multica agent update <AGENT_ID> --instructions "$(cat <资产路径>)"（需指定目标 agent）' },
      },
      autopilot: {
        write: { type: 'none', advice: 'multica autopilot 暂无通用更新命令：请在平台侧修改后重采，或改为「以生产为准」采纳进库' },
      },
      'hook-rule': {
        write: { type: 'none', advice: 'hook 规则经全局 ~/.claude hooks 生效于 multica 会话；以库为准时改 dev-forge 源文件即可，无平台对象' },
      },
      'hook-script': {
        write: { type: 'none', advice: '脚本在 dev-forge 仓库，采集自文件系统，无平台对象' },
      },
      adapter: { write: { type: 'none', advice: 'adapters 为本地脚本，无平台对象' } },
    },
  },
];

export async function loadPlatforms(dir: string): Promise<LoadedPlatforms> {
  const diagnostics: Diagnostic[] = [];
  let files: string[] = [];
  try {
    files = (await readdir(dir)).filter((f) => f.endsWith('.yaml') || f.endsWith('.yml'));
  } catch {
    return { platforms: DEFAULT_PLATFORMS, diagnostics };
  }
  const platforms: PlatformDef[] = [];
  for (const f of files) {
    const path = join(dir, f);
    let def: unknown;
    try {
      def = parse(await readFile(path, 'utf8'));
    } catch (e) {
      diagnostics.push({ level: 'error', message: `[platforms] ${f} 解析失败：${String(e).slice(0, 150)}`, path });
      continue;
    }
    const issue = platformDefIssue(def);
    if (issue) {
      diagnostics.push({ level: 'error', message: `[platforms] ${f} 结构违规：${issue}`, path });
      continue;
    }
    platforms.push(def as PlatformDef);
  }
  return { platforms: platforms.length > 0 ? platforms : DEFAULT_PLATFORMS, diagnostics };
}

/** 结构校验：YAML 不跑 zod，手工断言关键形状，坏文件出诊断并跳过（不进入执行路径） */
function platformDefIssue(def: unknown): string | null {
  if (!def || typeof def !== 'object') return 'not an object';
  const d = def as { id?: unknown; match?: unknown; kinds?: unknown };
  if (typeof d.id !== 'string' || !d.id) return 'id 缺失或非字符串';
  if (!d.match || typeof d.match !== 'object') return 'match 缺失';
  const prefix = (d.match as { pathPrefix?: unknown }).pathPrefix;
  if (prefix !== undefined && (!Array.isArray(prefix) || prefix.some((p) => typeof p !== 'string'))) {
    return 'match.pathPrefix 必须是字符串数组';
  }
  if (d.kinds === undefined) return null;
  if (!d.kinds || typeof d.kinds !== 'object') return 'kinds 必须是映射';
  for (const [kind, v] of Object.entries(d.kinds as Record<string, unknown>)) {
    const write = (v as { write?: unknown } | null)?.write as { type?: unknown; cmd?: unknown; platformIdFrom?: unknown; advice?: unknown } | undefined;
    if (!write || typeof write.type !== 'string') return `kinds.${kind}.write.type 缺失`;
    if (!['file-write', 'command', 'none'].includes(write.type)) return `kinds.${kind}.write.type 未知：${String(write.type)}`;
    if (write.type === 'command') {
      if (!Array.isArray(write.cmd) || write.cmd.some((c) => typeof c !== 'string')) return `kinds.${kind}.write.cmd 必须是字符串数组`;
      if (write.platformIdFrom !== undefined && !['self', 'deployment'].includes(write.platformIdFrom as string)) {
        return `kinds.${kind}.write.platformIdFrom 只能是 self|deployment`;
      }
    }
    if (write.type === 'none' && typeof write.advice !== 'string') return `kinds.${kind}.write.advice 缺失（none 必须给建议）`;
  }
  return null;
}

/** 资产 → 所属平台（首个 match 命中的 platform） */
export function resolvePlatform(asset: Asset, platforms: PlatformDef[]): PlatformDef | undefined {
  return platforms.find((p) => (p.match.pathPrefix ?? []).some((prefix) => asset.source.path.startsWith(prefix)));
}

export interface ResolvedWrite {
  write: PlatformWrite;
  platform: PlatformDef;
  platformId?: string;
  /** 不可执行时的说明（无通道 / platformId 缺失） */
  advice?: string;
}

/** 解析「以库为准物化」通道。返回 undefined = 该资产无对应平台 */
export function resolveWriteChannel(asset: Asset, assets: Asset[], platforms: PlatformDef[]): ResolvedWrite | undefined {
  const platform = resolvePlatform(asset, platforms);
  if (!platform) return undefined;
  const kindDef = platform.kinds?.[asset.kind];
  if (!kindDef) {
    return { write: { type: 'none', advice: `平台 ${platform.id} 未声明 kind ${asset.kind} 的写通道，请手动处理` }, platform };
  }
  const write = kindDef.write;
  if (write.type === 'command') {
    const from = write.platformIdFrom ?? 'self';
    let platformId: string | undefined;
    if (from === 'self') {
      platformId = (asset.payload as { platformId?: string }).platformId;
    } else {
      const dep = assets.find(
        (a) => a.kind === 'deployment' && (a.payload as { agent?: string }).agent?.toLowerCase() === asset.name.toLowerCase()
      );
      platformId = (dep?.payload as { platformId?: string } | undefined)?.platformId;
    }
    if (!platformId) {
      return { write: { type: 'none', advice: `未找到 platformId（${from}），需手动执行` }, platform };
    }
    return { write, platform, platformId };
  }
  return { write, platform };
}
