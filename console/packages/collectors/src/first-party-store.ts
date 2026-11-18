import { mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { Asset, Diagnostic } from '@forge/schema';
import { sha256 } from './util.js';
import { contentFingerprint, isTruthKind } from './store-content.js';
import { recoverBodyFromGit } from './git-history.js';

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
  /** 旧记录缺正文 → 原地补写正文（生产侧指纹一致时取生产正文；漂移时经 git 考古按记录 sha256 复原旧版。不改哈希，不影响对账结论） */
  backfilled: number;
  unchanged: number;
  /** 自产观测/杂项（非 declared）内容变化 → 自动采纳重写 */
  adopted: number;
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
  hashVersion: 1 | 2 | 3 | 4;
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
  // Owner 2026-11-18：全 kind 入库。declared（创作型）漂移走对账裁决；
  // 自产观测/杂项（first-party 未声明，如 activity-feed）变化即自动采纳，不产出 store-drift
  return assets.filter((a) => {
    if (!isTruthKind(a.kind)) return false;
    const reg = (a.payload as { registry?: { declared?: boolean } }).registry;
    return reg?.declared === true || a.provenance === 'first-party';
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
    hashVersion: 4,
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
  let backfilled = 0;
  let unchanged = 0;
  let adopted = 0;
  const touched = new Set<string>();

  for (const a of truthEntries(assets)) {
    touched.add(a.id);
    const existing = records.get(a.id);
    if (!existing) {
      records.set(a.id, await writeStoreRecord(dir, a));
      written++;
      continue;
    }
    if (existing.hashVersion !== 4) {
      // 口径迁移（v1-v3 → v4）：指纹口径演进必须提升版本并在此重算，否则存量记录全部假漂移。
      // 关键：只对「库内副本自身内容」重算指纹（口径差自愈），不采纳当前生产内容——
      // 库=真源，生产分叉仍由 store-drift 显式裁决（adopt/push），迁移不得静默吞掉真实漂移
      const now = new Date().toISOString();
      const record: StoreRecord = {
        ...existing,
        hashVersion: 4,
        hash: contentFingerprint(existing.asset),
        updatedAt: now,
        migratedAt: existing.migratedAt ?? now,
      };
      await writeFile(join(dir, storeFileName(record.id)), JSON.stringify(record, null, 2));
      records.set(record.id, record); // 内存 records 同步刷新：否则对账读到旧 hashVersion 记录会被跳过
      migrated++;
      continue;
    }
    // 正文回填：早期 v3 记录只存指纹快照（正文归档政策之前），store-drift 无从全文对照。
    // 仅在指纹一致（无漂移）且生产正文在手、库内缺正文时原地补写——哈希与 savedAt 不变，不改对账结论；
    // 指纹有漂移的记录不动（回填以生产正文为准会掩盖「谁改的」这一事实，正文只能经 adopt 落库）。
    const prodContent = (a.payload as { content?: unknown }).content;
    const recContent = (existing.asset.payload as { content?: unknown }).content;
    if (existing.hash === contentFingerprint(a) && typeof prodContent === 'string' && typeof recContent !== 'string') {
      records.set(a.id, await writeStoreRecord(dir, a, existing));
      backfilled++;
      continue;
    }
    // 考古回填：库内缺正文且记录带内容 sha256 时，从 git 历史复原「记录当时认可的那一版」正文。
    // sha256 精确匹配才落库——指纹不变、漂移不掩盖，卡片照常呈现，但能出全文 diff（看到删了什么）。
    if (
      typeof recContent !== 'string' &&
      existing.asset.source.path.startsWith('/') &&
      typeof existing.asset.source.sha256 === 'string'
    ) {
      const body = await recoverBodyFromGit(existing.asset.source.path, existing.asset.source.sha256);
      if (body !== undefined) {
        records.set(a.id, await writeStoreRecord(dir, { ...existing.asset, payload: { ...existing.asset.payload, content: body } }, existing));
        backfilled++;
        continue;
      }
    }
    // 自产观测/杂项（first-party 非 declared）：内容变化 → 自动采纳（以最新生产为准，不产出 store-drift）
    const isDeclared = (a.payload as { registry?: { declared?: boolean } }).registry?.declared === true;
    if (!isDeclared && existing.hash !== contentFingerprint(a)) {
      records.set(a.id, await writeStoreRecord(dir, a, existing));
      adopted++;
      continue;
    }
    unchanged++;
  }

  let kept = 0;
  for (const id of records.keys()) if (!touched.has(id)) kept++;
  return { written, migrated, backfilled, unchanged, kept, adopted };
}
