import { mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { Asset, Diagnostic } from '@forge/schema';
import { sha256 } from './util.js';
import { contentFingerprint, isTruthKind } from './store-content.js';

/**
 * 本地自建资产源（first-party store）——真源（Owner 2026-11-06）：
 * - 只收「已声明（registry.d 盖戳）且内容型 kind（TRUTH_KINDS）」的资产，一资产一文件；
 * - **create-only**：首次见到才建副本；已存在的 v2 副本永不覆写——生产变更不再自动追平，
 *   而是交 store-drift 对账由人裁决（采纳生产 → 重写副本；以库为准 → 物化）；
 * - v1 旧记录（全 payload hash 时代）首轮按当前生产内容迁移为 v2 指纹（基线采纳，不报漂移）；
 * - 资产从采集中消失时副本保留不删（对账期望态）。
 */
export interface StoreSyncResult {
  written: number;
  migrated: number;
  unchanged: number;
  /** 库内保留但本轮采集未见对应声明资产的条目数（消失资产 + 非内容型历史记录） */
  kept: number;
}

export interface StoreRecord {
  id: string;
  kind: string;
  name: string;
  declaredBy?: string;
  /** 首次入库时间 */
  savedAt: string;
  /** 内容最后一次变更时间（adopt 重写时更新） */
  updatedAt: string;
  /** v1→v2 指纹口径迁移时间 */
  migratedAt?: string;
  hashVersion: 1 | 2;
  /** 内容指纹（v2 = contentFingerprint，只含内容字段） */
  hash: string;
  asset: Asset;
}

/** id → 稳定文件名（可读前缀 + id 哈希保证唯一） */
export function storeFileName(id: string): string {
  const safe = id.replace(/[^a-zA-Z0-9._-]/g, '_').slice(0, 80);
  return `${safe}-${sha256(id).slice(0, 8)}.json`;
}

export interface LoadedStore {
  records: Map<string, StoreRecord>;
  diagnostics: Diagnostic[];
}

export async function loadFirstPartyStore(dir: string): Promise<LoadedStore> {
  const records = new Map<string, StoreRecord>();
  const diagnostics: Diagnostic[] = [];
  let files: string[] = [];
  try {
    files = (await readdir(dir)).filter((f) => f.endsWith('.json'));
  } catch {
    return { records, diagnostics };
  }
  for (const f of files) {
    try {
      const rec = JSON.parse(await readFile(join(dir, f), 'utf8')) as StoreRecord;
      if (rec?.id) records.set(rec.id, rec);
    } catch (e) {
      diagnostics.push({ level: 'warn', message: `[first-party-store] 记录解析失败，跳过：${f}（${String(e).slice(0, 150)}）`, path: join(dir, f) });
    }
  }
  return { records, diagnostics };
}

function truthEntries(assets: Asset[]): Asset[] {
  return assets.filter((a) => {
    if (!isTruthKind(a.kind)) return false;
    const reg = (a.payload as { registry?: { declared?: boolean } }).registry;
    return reg?.declared === true;
  });
}

/** 重写一条记录（新建 / v1 迁移 / adopt 采纳共用） */
export async function writeStoreRecord(dir: string, asset: Asset, prev?: StoreRecord): Promise<StoreRecord> {
  await mkdir(dir, { recursive: true });
  const now = new Date().toISOString();
  const record: StoreRecord = {
    id: asset.id,
    kind: asset.kind,
    name: asset.name,
    declaredBy: (asset.payload as { registry?: { declaredBy?: string } }).registry?.declaredBy,
    savedAt: prev?.savedAt ?? now,
    updatedAt: now,
    hashVersion: 2,
    hash: contentFingerprint(asset),
    asset,
    ...(prev?.migratedAt ? { migratedAt: prev.migratedAt } : {}),
  };
  await writeFile(join(dir, storeFileName(asset.id)), JSON.stringify(record, null, 2));
  return record;
}

export async function syncFirstPartyStore(
  assets: Asset[],
  dir: string,
  opts?: { records?: Map<string, StoreRecord> }
): Promise<StoreSyncResult> {
  await mkdir(dir, { recursive: true });
  const records = opts?.records ?? (await loadFirstPartyStore(dir)).records;
  let written = 0;
  let migrated = 0;
  let unchanged = 0;
  const touched = new Set<string>();

  for (const a of truthEntries(assets)) {
    touched.add(a.id);
    const existing = records.get(a.id);
    if (!existing) {
      await writeStoreRecord(dir, a);
      written++;
      continue;
    }
    if (existing.hashVersion !== 2) {
      // v1 基线迁移：按当前生产内容重算 v2 指纹，视为库已认可，不产生漂移
      await writeStoreRecord(dir, a, { ...existing, migratedAt: new Date().toISOString() });
      migrated++;
      continue;
    }
    unchanged++;
  }

  let kept = 0;
  for (const id of records.keys()) if (!touched.has(id)) kept++;
  return { written, migrated, unchanged, kept };
}
