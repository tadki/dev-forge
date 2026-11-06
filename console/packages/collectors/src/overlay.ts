import { readdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { isMap, isSeq, parse, parseDocument, type YAMLSeq } from 'yaml';
import { registryEntrySchema, type Asset, type Diagnostic, type Meta } from '@forge/schema';
import type { RegistryState } from './registry.js';

export interface RegistryMatch {
  idPrefix?: string;
  pathPrefix?: string;
  ids?: string[];
  exclude?: { idPrefix?: string[]; pathPrefix?: string[]; ids?: string[] };
}

export interface RegistryEntry {
  id: string;
  match: RegistryMatch;
  /** 声明该资产已应用到的平台（claude-code / multica）。不写 = 不参与平台归属对账 */
  platforms?: string[];
  meta?: Meta;
  file: string;
}

export function matchesRegistryEntry(asset: Asset, entry: RegistryEntry): boolean {
  const m = entry.match ?? {};
  const included = (m.idPrefix !== undefined && asset.id.startsWith(m.idPrefix))
    || (m.pathPrefix !== undefined && asset.source.path.startsWith(m.pathPrefix))
    || (m.ids !== undefined && m.ids.includes(asset.id));
  if (!included) return false;
  const x = m.exclude;
  if (!x) return true;
  if (x.ids?.includes(asset.id)) return false;
  if (x.idPrefix?.some((p) => asset.id.startsWith(p))) return false;
  if (x.pathPrefix?.some((p) => asset.source.path.startsWith(p))) return false;
  return true;
}

export interface LoadedRegistry {
  entries: RegistryEntry[];
  /** 加载/校验诊断（YAML 解析失败、entry 契约违规——逐条报，不静默） */
  diagnostics: Diagnostic[];
}

/** 读 console/registry.d/*.yaml 并过 registryEntrySchema 校验（缺失目录 = 无声明，不报错） */
export async function loadRegistryEntries(dir: string): Promise<LoadedRegistry> {
  let files: string[] = [];
  try {
    files = (await readdir(dir)).filter((f) => f.endsWith('.yaml') || f.endsWith('.yml'));
  } catch {
    return { entries: [], diagnostics: [] };
  }
  const out: RegistryEntry[] = [];
  const diagnostics: Diagnostic[] = [];
  for (const f of files) {
    let raw: unknown;
    try {
      raw = parse(await readFile(join(dir, f), 'utf8'));
    } catch (e) {
      diagnostics.push({ level: 'error', message: `[registry] YAML 解析失败：${f}（${String(e).slice(0, 200)}）`, path: join(dir, f) });
      continue;
    }
    const entries = (raw as { entries?: unknown[] } | null)?.entries;
    if (!Array.isArray(entries)) continue;
    for (const e of entries) {
      const check = registryEntrySchema.safeParse(e);
      if (!check.success) {
        const issue = check.error.issues[0];
        const idHint = e && typeof e === 'object' && 'id' in e ? String((e as { id?: unknown }).id) : '(无 id)';
        diagnostics.push({
          level: 'error',
          message: `[registry] 声明 ${idHint} 违反 entry 契约：${issue.path.join('.') || '(root)'}: ${issue.message}`,
          path: join(dir, f),
        });
        continue;
      }
      const d = check.data;
      out.push({ id: d.id, match: d.match ?? {}, platforms: d.platforms, meta: d.meta, file: join(dir, f) });
    }
  }
  return { entries: out, diagnostics };
}

/**
 * 平台对账「平台→本地/本地→平台」声明回写：对 registry.d entry 的 platforms 做最小编辑。
 * parseDocument 保留文件头注释与其他字段；返回编辑后的 platforms。
 */
export async function editRegistryPlatforms(
  file: string,
  entryId: string,
  op: 'add-platform' | 'remove-platform',
  platform: string
): Promise<string[]> {
  const text = await readFile(file, 'utf8');
  const doc = parseDocument(text);
  const seq = doc.get('entries');
  if (!isSeq(seq)) throw new Error(`registry 文件无 entries 列表：${file}`);
  const node = seq.items.find((it) => isMap(it) && it.get('id') === entryId);
  if (!isMap(node)) throw new Error(`registry 文件 ${file} 中未找到 entry「${entryId}」`);
  const raw = node.get('platforms');
  const current = isSeq(raw) ? raw.items.map((x) => String(x)) : Array.isArray(raw) ? raw.map(String) : [];
  const next =
    op === 'add-platform'
      ? current.includes(platform) ? current : [...current, platform]
      : current.filter((p) => p !== platform);
  if (next.length === 0) {
    // 撤销最后一个平台 → 删除键本身，回到文档语义「不写 = 不参与平台对账」；
    // 写空数组会让 entry 以「participating with 0 platforms」参与对账，制造 undeclared 警告
    node.delete('platforms');
  } else {
    const seqNode = doc.createNode(next) as YAMLSeq;
    seqNode.flow = true; // 保持行内 [a, b] 风格，与 owned.yaml 现有写法一致
    node.set('platforms', seqNode);
  }
  await writeFile(file, doc.toString(), 'utf8');
  return next;
}

/**
 * 声明即归属：把 registry.d 的 meta/归属盖到匹配资产上（覆盖采集器推断）；
 * 未匹配声明 → 合成 registry:unmatched-* 资产 + 诊断；自建未声明 → payload.registry.declared=false。
 */
export function applyRegistryOverlay(state: RegistryState, entries: RegistryEntry[]): RegistryState {
  const matchedEntryIds = new Set<string>();
  const assets = state.assets.map((asset) => {
    const entry = entries.find((e) => matchesRegistryEntry(asset, e));
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
      payload: {
        ...asset.payload,
        registry: { declared: true, declaredBy: entry.id, ...(entry.platforms ? { declaredPlatforms: entry.platforms } : {}) },
      },
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
