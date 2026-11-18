import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import type { Asset } from '@forge/schema';

/**
 * 投影映射表（Owner 2026-11-18）：一种映射——记录「真源 ↔ 投影坐标」的关系。
 * 线存下来后，投影改名/换位置都能查表找到真源；ref 失活 → lost（待拔线或重接）。
 *
 * 变更规则：新投影 → 登记为 linked；ref 消失 → lost；lost 后 ref 复活 → linked；
 * 用户拔线 → 删除条目；确认关联（改名/移动候选）→ 更新 ref。
 */

export interface ProjectionLink {
  truthId: string;
  /** 投影坐标：文件绝对路径 / multica:// URI / systemd:// URI 等 */
  ref: string;
  /** 坐标形态：file=本地文件；platform-object=平台远端对象；derived=派生产出 */
  coordinate: 'file' | 'platform-object' | 'derived';
  linkedBy: 'auto' | 'push' | 'adopt' | 'declare' | 'confirm';
  linkedAt: string;
  status: 'linked' | 'lost';
  lastFingerprint?: string;
  lastSeenAt?: string;
  lostAt?: string;
}

export interface LinksFile {
  version: 1;
  links: ProjectionLink[];
}

export async function loadProjectionLinks(file: string): Promise<LinksFile> {
  try {
    const raw = JSON.parse(await readFile(file, 'utf8')) as LinksFile;
    if (raw && Array.isArray(raw.links)) return { version: 1, links: raw.links };
  } catch {
    /* 不存在/损坏 → 空表起 */
  }
  return { version: 1, links: [] };
}

export async function saveProjectionLinks(file: string, links: ProjectionLink[]): Promise<void> {
  await mkdir(dirname(file), { recursive: true });
  await writeFile(file, JSON.stringify({ version: 1, links }, null, 2));
}

/** 按 (truthId, ref) 幂等登记；已存在则刷新 lastSeen */
export function upsertLink(
  links: ProjectionLink[],
  entry: Omit<ProjectionLink, 'linkedAt' | 'status'> & { linkedAt?: string; status?: 'linked' | 'lost' }
): boolean {
  const found = links.find((l) => l.truthId === entry.truthId && l.ref === entry.ref);
  const now = new Date().toISOString();
  if (found) {
    let touched = false;
    if (found.status !== 'linked') { found.status = 'linked'; touched = true; }
    found.lastSeenAt = now;
    if (entry.lastFingerprint !== undefined) found.lastFingerprint = entry.lastFingerprint;
    return touched;
  }
  links.push({
    truthId: entry.truthId,
    ref: entry.ref,
    coordinate: entry.coordinate,
    linkedBy: entry.linkedBy,
    linkedAt: now,
    status: 'linked',
    ...(entry.lastFingerprint !== undefined ? { lastFingerprint: entry.lastFingerprint } : {}),
  });
  return true;
}

/** 坐标失活：status → lost（保留线，待拔线或重接） */
export function markLinkLost(links: ProjectionLink[], ref: string): boolean {
  const found = links.find((l) => l.ref === ref && l.status === 'linked');
  if (!found) return false;
  found.status = 'lost';
  found.lostAt = new Date().toISOString();
  return true;
}

/**
 * 采集后连线对账：
 * - 声明的自建资产（first-party）无线 → 自动登记（linkedBy auto）
 * - 线的坐标不再出现在采集面 → 标 lost
 * 返回是否有变化（调用方据此落盘）。
 */
export function reconcileProjectionLinks(
  links: ProjectionLink[],
  assets: Asset[]
): { changed: boolean; registered: number; lost: number } {
  const now = new Date().toISOString();
  const refs = new Map<string, Asset>();
  for (const a of assets) {
    const ref = a.source.path;
    if (!refs.has(ref)) refs.set(ref, a);
  }
  let changed = false;
  let registered = 0;
  let lost = 0;

  for (const l of links) {
    if (l.status === 'linked' && !refs.has(l.ref)) {
      l.status = 'lost';
      l.lostAt = now;
      changed = true;
      lost++;
    } else if (l.status === 'lost' && refs.has(l.ref)) {
      // 坐标复活（资产重新出现/恢复）：自动重连
      l.status = 'linked';
      delete l.lostAt;
      changed = true;
    }
  }

  for (const a of assets) {
    if (a.provenance !== 'first-party') continue;
    const ref = a.source.path;
    if (refs.has(ref) && !links.some((l) => l.truthId === a.id && l.ref === ref)) {
      links.push({
        truthId: a.id,
        ref,
        coordinate: a.source.path.startsWith('multica://') ? 'platform-object' : a.source.path.startsWith('systemd://') ? 'derived' : 'file',
        linkedBy: 'auto',
        linkedAt: now,
        status: 'linked',
      });
      changed = true;
      registered++;
    }
  }
  return { changed, registered, lost };
}
