import { writeFile, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';
import type { Asset, Collection, Diagnostic, Relation } from '@forge/schema';
import type { CollectContext, Collector } from './types.js';

export interface DriftVariant {
  id: string;
  path: string;
  hash8: string;
  lines: number;
}

export interface DriftGroup {
  key: string;
  workspace: string;
  basename: string;
  copies: number;
  variants: DriftVariant[];
}

export interface CollectorStatus {
  name: string;
  mode: string;
  ok: boolean;
  ms: number;
  assets: number;
  error?: string;
}

export interface RegistryState {
  assets: Asset[];
  relations: Relation[];
  diagnostics: Diagnostic[];
  driftGroups: DriftGroup[];
  collectorStatus: CollectorStatus[];
  lastCollectedAt: string;
}

export function mergeCollections(collections: Collection[]): Omit<RegistryState, 'driftGroups' | 'collectorStatus' | 'lastCollectedAt'> {
  const byId = new Map<string, Asset>();
  const relations: Relation[] = [];
  const diagnostics: Diagnostic[] = [];
  for (const c of collections) {
    for (const d of c.diagnostics) diagnostics.push({ ...d, message: `[${c.collector}] ${d.message}` });
    for (const a of c.assets) {
      if (byId.has(a.id)) {
        diagnostics.push({ level: 'warn', message: `[merge] 资产 id 冲突，保留先到：${a.id}（后到来自 ${a.source.collector}）`, path: a.source.path });
      } else {
        byId.set(a.id, a);
      }
    }
    relations.push(...c.relations);
  }
  // 确定性顺序：采集是并发的，合并顺序否则随完成次序漂移 → 前端列表闪动
  const assets = [...byId.values()].sort((a, b) =>
    a.kind === b.kind ? a.id.localeCompare(b.id) : a.kind.localeCompare(b.kind)
  );
  return { assets, relations, diagnostics };
}

export function computeDriftGroups(assets: Asset[]): DriftGroup[] {
  const groups = new Map<string, Map<string, DriftVariant[]>>();
  for (const a of assets) {
    if (a.kind !== 'instruction') continue;
    const payload = a.payload as { basename?: string; contentHash?: string; lines?: number };
    if (!payload.basename || !payload.contentHash) continue;
    const ws = a.applies?.workspaces?.[0] ?? '(未分组)';
    const key = `${ws}:${payload.basename}`;
    if (!groups.has(key)) groups.set(key, new Map());
    const variant: DriftVariant = {
      id: a.id,
      path: a.source.path,
      hash8: payload.contentHash.slice(0, 8),
      lines: payload.lines ?? 0,
    };
    const byHash = groups.get(key)!;
    byHash.set(payload.contentHash, [...(byHash.get(payload.contentHash) ?? []), variant]);
  }
  const out: DriftGroup[] = [];
  for (const [key, byHash] of groups) {
    const variants = [...byHash.values()];
    const copies = variants.reduce((n, v) => n + v.length, 0);
    if (byHash.size > 1 && copies > 1) {
      const [workspace, basename] = key.split(':');
      out.push({
        key,
        workspace,
        basename,
        copies,
        variants: variants.map((v) => v[0]).sort((a, b) => b.lines - a.lines),
      });
    }
  }
  return out.sort((a, b) => b.copies - a.copies);
}

export async function runCollectors(
  ctx: CollectContext,
  collectors: Collector[]
): Promise<RegistryState> {
  const collections: Collection[] = [];
  const status: CollectorStatus[] = [];
  await Promise.all(
    collectors.map(async (c) => {
      const started = Date.now();
      try {
        const result = await c.collect({ ...ctx, diagnostics: [] });
        const collection: Collection = {
          collector: c.name,
          collectedAt: ctx.now.toISOString(),
          assets: result.assets,
          relations: result.relations,
          diagnostics: result.diagnostics,
        };
        collections.push(collection);
        status.push({ name: c.name, mode: c.mode, ok: true, ms: Date.now() - started, assets: result.assets.length });
      } catch (e) {
        status.push({ name: c.name, mode: c.mode, ok: false, ms: Date.now() - started, assets: 0, error: String(e).slice(0, 300) });
        collections.push({ collector: c.name, collectedAt: ctx.now.toISOString(), assets: [], relations: [], diagnostics: [{ level: 'error', message: `采集失败：${String(e).slice(0, 300)}` }] });
      }
    })
  );
  const merged = mergeCollections(collections);
  return {
    ...merged,
    driftGroups: computeDriftGroups(merged.assets),
    collectorStatus: status,
    lastCollectedAt: ctx.now.toISOString(),
  };
}

export async function saveSnapshot(state: RegistryState, path: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, JSON.stringify(state, null, 2));
}
