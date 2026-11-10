import { copyFile, writeFile } from 'node:fs/promises';
import { isAbsolute } from 'node:path';
import type { Asset } from '@forge/schema';
import type { PlatformDef, RegistryState, StoreRecord } from '@forge/collectors';
import { resolveWriteChannel, writeStoreRecord } from '@forge/collectors';

/**
 * 技能编辑保存并同步（Owner 2026-11-10，方向：以库为准）：
 * 1. 编辑内容先写入库内真源（first-party store）——库是唯一权威；
 * 2. 相关条目（技能的全部部署位置）从注册数据推导：注册表里同名的其他 skill 实例（本地 / 各平台），
 *    技能可部署在多个 Agent、分散在多个平台，全部同名实例都对照新内容更新（1:N）；
 * 3. 编辑资产自身 + 相关实例各自走 platforms.d 声明的写通道，把刚入库的内容推上去
 *    （等价于对账 store-drift 条目的「以库为准」push 方向，通道解析复用同一 resolveWriteChannel）。
 * 无平台特判。技能挂载形态（平台级技能库 → 分配给各 Agent，或 Agent 级实例）是平台适配层的差异：
 * 平台级实例更新一次即覆盖其下所有 Agent；Agent 级实例由采集器登记为独立资产，此处逐个更新。
 * 路径白名单/备份/超时与 reconcile-action 同一套安全约定。
 */

export interface AssetContentSyncTarget {
  platform: string;
  kind: 'file' | 'command' | 'store';
  label: string;
  executable: boolean;
  note?: string;
  /** kind=file：目标绝对路径 */
  path?: string;
  /** kind=command：argv[0] 与参数模板（{content} 由执行端替换） */
  cmd?: string;
  args?: string[];
  /** kind=store：要重写的库记录 assetId */
  assetId?: string;
}

export interface AssetContentSaveDeps {
  platforms: PlatformDef[];
  storeDir?: string;
  storeRecords?: Map<string, StoreRecord>;
  exec: (cmd: string, args: string[], timeoutMs: number) => Promise<{ ok: boolean; stdout: string; stderr: string }>;
  dryRun?: boolean;
}

export interface AssetContentSaveResult {
  /** ok=全部目标成功；invalid=资产/内容不合法（4xx）；failed=部分执行后中断（200 + ok:false） */
  status: 'ok' | 'invalid' | 'failed';
  ok: boolean;
  output: string;
  targets: AssetContentSyncTarget[];
}

const COMMAND_TIMEOUT_MS = 60_000;
const OUTPUT_LIMIT = 800;
/** 与采集器截断上限一致：超限内容保存后下轮采集必截断 → 立即漂移，直接拒绝 */
export const CONTENT_MAX_CHARS = 200_000;

function clip(text: string): string {
  const trimmed = text.trim();
  return trimmed.length <= OUTPUT_LIMIT ? trimmed : `${trimmed.slice(0, OUTPUT_LIMIT)}…`;
}

/** 可写路径白名单：当前 state 里已登记的资产源路径（客户端无法注入路径） */
function writablePaths(state: RegistryState): Set<string> {
  const out = new Set<string>();
  for (const a of state.assets) if (isAbsolute(a.source.path)) out.add(a.source.path);
  return out;
}

/** 与 reconcile.ts 跨平台技能配对同一口径：小写去非字母数字 */
function normName(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]/g, '');
}

/**
 * 本技能的全部部署位置：注册表里同名的其他 skill 实例（本地文件 / 各平台登记副本）。
 * 语义（Owner 2026-11-10）：技能修改后，所有部署了这条技能的生产位置都对照入库的新内容更新；
 * 「部署了」的判定就是采集注册到的实例本身，本地与平台实例同口径处理，无平台特判。
 * 归属须同源：同名但 provenance 不同（如第三方依赖技能）是另一个资产，不是本技能的部署位置。
 */
export function relatedSkillInstances(asset: Asset, state: RegistryState): Asset[] {
  const want = normName(asset.name);
  return state.assets.filter(
    (a) => a.id !== asset.id && a.kind === 'skill' && a.provenance === asset.provenance && normName(a.name) === want
  );
}

function channelTarget(asset: Asset, state: RegistryState, platforms: PlatformDef[]): AssetContentSyncTarget {
  const resolved = resolveWriteChannel(asset, state.assets, platforms);
  if (!resolved) {
    return { platform: '—', kind: 'file', label: `物化 ${asset.source.path}`, executable: false, note: '资产不匹配任何平台适配（platforms.d）' };
  }
  const pid = resolved.platform.id;
  if (resolved.write.type === 'file-write') {
    const ok = isAbsolute(asset.source.path);
    return {
      platform: pid,
      kind: 'file',
      path: asset.source.path,
      executable: ok,
      label: `写本地文件 ${asset.source.path}`,
      note: ok ? undefined : '来源路径不是本地绝对路径，无安全写入通道',
    };
  }
  if (resolved.write.type === 'command') {
    const args = resolved.write.cmd.slice(1).map((a) => (a === '{platformId}' ? (resolved.platformId ?? '{platformId}') : a));
    return {
      platform: pid,
      kind: 'command',
      cmd: resolved.write.cmd[0],
      args,
      executable: !!resolved.platformId,
      label: `执行 ${pid} 更新命令 ${resolved.write.cmd[0]} ${args.join(' ')}`,
      note: resolved.platformId ? undefined : '未找到 platformId，需手动执行',
    };
  }
  return { platform: pid, kind: 'file', label: `物化到 ${pid}`, executable: false, note: resolved.write.advice };
}

/** 同步计划：编辑侧平台通道 + 跨平台同名副本通道 + 库内真源记录重写。纯函数，便于单测。 */
export function planAssetContentSync(
  asset: Asset,
  state: RegistryState,
  platforms: PlatformDef[],
  storeRecords?: Map<string, StoreRecord>
): { blocked?: string; targets: AssetContentSyncTarget[] } {
  const targets: AssetContentSyncTarget[] = [channelTarget(asset, state, platforms)];

  // 1:N：技能可部署在多个 Agent、跨多个平台，全部同名实例都对照新内容更新（各自走本平台声明通道）
  const instances = relatedSkillInstances(asset, state);
  for (const inst of instances) targets.push(channelTarget(inst, state, platforms));

  // 库内真源：编辑资产必入库（编辑即「先进入源头库」）；相关实例已有记录才重写，不给未声明资产建档
  targets.push({ platform: 'library', kind: 'store', assetId: asset.id, executable: true, label: `更新库内真源 ${asset.id}` });
  for (const inst of instances) {
    if (storeRecords?.has(inst.id)) {
      targets.push({ platform: 'library', kind: 'store', assetId: inst.id, executable: true, label: `更新库内真源 ${inst.id}` });
    }
  }
  // 没有任何平台通道可执行时仍可入库，但如实告知：内容只进了库，生产侧未落地
  const blocked = targets.some((t) => t.kind !== 'store' && t.executable) ? undefined : '无任何可执行的平台同步通道';
  return { blocked, targets };
}

export async function executeAssetContentSave(
  assetId: string,
  content: string,
  state: RegistryState,
  deps: AssetContentSaveDeps
): Promise<AssetContentSaveResult> {
  const asset = state.assets.find((a) => a.id === assetId);
  if (!asset) return { status: 'invalid', ok: false, output: `资产不在当前采集中：${assetId}`, targets: [] };
  if (asset.kind !== 'skill') return { status: 'invalid', ok: false, output: `仅支持技能（skill）资产的编辑保存，${assetId} 是 ${asset.kind}`, targets: [] };
  if (typeof content !== 'string' || content.length === 0) {
    return { status: 'invalid', ok: false, output: 'content 必填（非空字符串）', targets: [] };
  }
  if (content.length > CONTENT_MAX_CHARS) {
    return { status: 'invalid', ok: false, output: `content 超过 ${CONTENT_MAX_CHARS} 字符上限（采集会在该上限截断，保存即漂移），请缩减后保存`, targets: [] };
  }

  const { blocked, targets } = planAssetContentSync(asset, state, deps.platforms, deps.storeRecords);

  const whitelist = writablePaths(state);
  // 库先落地，再推生产；blocked 不拒绝入库，只在输出里明示生产侧未落地
  const lines: string[] = blocked ? [`${blocked}（本次仅写入库内真源）`] : [];
  const ordered = [...targets.filter((t) => t.kind === 'store'), ...targets.filter((t) => t.kind !== 'store')];
  for (const t of ordered) {
    try {
      if (!t.executable) {
        lines.push(`跳过 ${t.platform}：${t.note ?? '无可执行通道'}`);
        continue;
      }
      if (t.kind === 'file' && t.path) {
        if (!whitelist.has(t.path)) throw new Error(`拒绝写入：${t.path} 不是当前采集到的资产路径`);
        if (deps.dryRun) {
          lines.push(`[dry-run] 将写入 ${t.path}（${Buffer.byteLength(content)} 字节）`);
          continue;
        }
        const backup = `${t.path}.forge-bak-${Date.now()}`;
        let backupNote = '（新建文件，无需备份）';
        try {
          await copyFile(t.path, backup);
          backupNote = `，原文件备份 ${backup}`;
        } catch {
          /* 目标不存在 */
        }
        await writeFile(t.path, content, 'utf8');
        lines.push(`已写入 ${t.path}（${Buffer.byteLength(content)} 字节${backupNote}）`);
      } else if (t.kind === 'command' && t.cmd && t.args) {
        const resolvedArgs = t.args.map((a) => (a === '{content}' ? content : a));
        if (deps.dryRun) {
          const display = t.args.map((a) => (a === '{content}' ? `<${content.length} 字符>` : a)).join(' ');
          lines.push(`[dry-run] ${t.cmd} ${display}`);
          continue;
        }
        const result = await deps.exec(t.cmd, resolvedArgs, COMMAND_TIMEOUT_MS);
        const tail = clip(`${result.stdout}${result.stderr}`);
        if (!result.ok) throw new Error(`命令失败：${t.cmd} ${resolvedArgs.slice(0, 2).join(' ')} …${tail ? `\n${tail}` : ''}`);
        lines.push(`已执行 ${t.cmd}（${t.platform} 写通道）${tail ? `\n${tail}` : ''}`);
      } else if (t.kind === 'store' && t.assetId) {
        if (!deps.storeDir) throw new Error('storeDir 未配置，无法写库');
        const source = state.assets.find((a) => a.id === t.assetId) ?? asset;
        const updated: Asset = { ...source, payload: { ...source.payload, content } };
        if (deps.dryRun) {
          lines.push(`[dry-run] 将重写库内真源 ${t.assetId}（指纹重算）`);
          continue;
        }
        await writeStoreRecord(deps.storeDir, updated, deps.storeRecords?.get(t.assetId));
        lines.push(`已更新库内真源 ${t.assetId}（指纹重算）`);
      }
    } catch (e) {
      return { status: 'failed', ok: false, output: clip([...lines, `失败 @ ${t.platform}：${String(e).slice(0, 300)}`].join('\n')), targets };
    }
  }
  return { status: 'ok', ok: true, output: clip(lines.join('\n')), targets };
}
