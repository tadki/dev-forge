import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { parse } from 'yaml';
import type { Asset } from '@forge/schema';
import type { Meta } from '@forge/schema';
import type { RegistryState } from './registry.js';

export interface RegistryMatch {
  idPrefix?: string;
  pathPrefix?: string;
}

export interface RegistryEntry {
  id: string;
  match: RegistryMatch;
  meta?: Meta;
  file: string;
}

interface ManifestFile {
  entries?: Array<{ id: string; match?: RegistryMatch; meta?: Meta }>;
}

function matches(asset: Asset, entry: RegistryEntry): boolean {
  const m = entry.match ?? {};
  if (m.idPrefix && asset.id.startsWith(m.idPrefix)) return true;
  if (m.pathPrefix && asset.source.path.startsWith(m.pathPrefix)) return true;
  return false;
}

/** 读 console/registry.d/*.yaml（缺失目录 = 无声明，不报错） */
export async function loadRegistryEntries(dir: string): Promise<RegistryEntry[]> {
  let files: string[] = [];
  try {
    files = (await readdir(dir)).filter((f) => f.endsWith('.yaml') || f.endsWith('.yml'));
  } catch {
    return [];
  }
  const out: RegistryEntry[] = [];
  for (const f of files) {
    let raw: ManifestFile;
    try {
      raw = parse(await readFile(join(dir, f), 'utf8')) as ManifestFile;
    } catch {
      continue;
    }
    for (const e of raw.entries ?? []) {
      if (e?.id) out.push({ id: e.id, match: e.match ?? {}, meta: e.meta, file: join(dir, f) });
    }
  }
  return out;
}

/**
 * 声明即归属：把 registry.d 的 meta/归属盖到匹配资产上（覆盖采集器推断）；
 * 未匹配声明 → 合成 registry:unmatched-* 资产 + 诊断；自建未声明 → payload.registry.declared=false。
 */
export function applyRegistryOverlay(state: RegistryState, entries: RegistryEntry[]): RegistryState {
  const matchedEntryIds = new Set<string>();
  const assets = state.assets.map((asset) => {
    const entry = entries.find((e) => matches(asset, e));
    if (!entry) {
      if (asset.provenance === 'first-party') {
        return { ...asset, payload: { ...asset.payload, registry: { declared: false } } };
      }
      return asset;
    }
    matchedEntryIds.add(entry.id);
    return {
      ...asset,
      provenance: 'first-party' as const,
      meta: { ...entry.meta, ...asset.meta },
      payload: { ...asset.payload, registry: { declared: true, declaredBy: entry.id } },
    };
  });

  const diagnostics = [...state.diagnostics];
  const extra: Asset[] = [];
  for (const entry of entries) {
    if (matchedEntryIds.has(entry.id)) continue;
    diagnostics.push({ level: 'warn', message: `[registry] 声明「${entry.id}」未匹配到任何资产（检查 match 规则）`, path: entry.file });
    extra.push({
      id: `registry:unmatched-${entry.id}`,
      kind: 'custom',
      name: `未匹配声明 · ${entry.id}`,
      summary: `registry.d 声明了但没有资产命中（${JSON.stringify(entry.match)}）`,
      attach: { level: 'user' },
      enforcement: 'advisory',
      platforms: ['claude-code'],
      provenance: 'first-party',
      tags: ['registry', 'unmatched'],
      enabled: true,
      source: { collector: 'registry-overlay', path: entry.file },
      payload: { entry },
    });
  }

  return { ...state, assets: [...assets, ...extra], diagnostics };
}
