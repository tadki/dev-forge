import { writeFile, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';
import type { Asset, Collection, Diagnostic, Relation } from '@forge/schema';
import type { CollectContext, Collector } from './types.js';
import type { ReconcileReport } from './reconcile.js';

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
  collectorStatus: CollectorStatus[];
  lastCollectedAt: string;
  /** 平台对账报告（collectNow 末尾计算；push 型资产不触发重算） */
  reconcile?: ReconcileReport;
}

export function mergeCollections(collections: Collection[]): Omit<RegistryState, 'collectorStatus' | 'lastCollectedAt'> {
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
    collectorStatus: status,
    lastCollectedAt: ctx.now.toISOString(),
  };
}

export async function saveSnapshot(state: RegistryState, path: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, JSON.stringify(state, null, 2));
}
