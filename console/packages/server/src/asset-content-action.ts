import { copyFile, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, resolve, sep } from 'node:path';
import type { Asset } from '@forge/schema';
import type { PlatformDef, RegistryState, StoreRecord } from '@forge/collectors';
import { resolvePlatform, resolveWriteChannel, writeStoreRecord } from '@forge/collectors';

/**
 * 技能编辑保存并同步（Owner 2026-11-10，方向：以库为准）：
 * 1. 编辑内容先写入库内真源（first-party store）——库是唯一权威；
 * 2. 相关条目（技能的全部部署位置）从注册数据推导：注册表里同名的其他 skill 实例（本地 / 各平台），
 *    技能可部署在多个 Agent、分散在多个平台，全部同名实例都对照新内容更新（1:N）；
 * 3. 编辑资产自身 + 相关实例各自走 platforms.d 声明的写通道，把刚入库的内容推上去
 *    （等价于对账 store-drift 条目的「以库为准」push 方向，通道解析复用同一 resolveWriteChannel）。
 * 可编辑对象：SKILL.md 本体（file 省略）或技能附带文件（file=技能内相对路径，须已在 payload.files 登记）；
 * 附带文件通道走 kinds.skill.fileWrite 声明（file-write 平台无需声明，路径=dirname(本体)/{filePath}）。
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

/** 本地技能目录（附带文件写入只允许落在已登记技能的目录内） */
function skillDirs(state: RegistryState): string[] {
  return state.assets.filter((a) => a.kind === 'skill' && isAbsolute(a.source.path)).map((a) => dirname(a.source.path));
}

interface SkillFileEntry {
  path: string;
  content?: string;
}

/** 附带文件路径合法性：技能内相对路径，拒绝绝对路径与 .. 穿越（兼容 '\' 分隔，防将来跑在 Windows）；
 *  花括号与通道占位符（{content}/{platformId}/{filePath}）冲突，一并拒绝 */
function isSafeSkillFilePath(file: string): boolean {
  return file.length > 0 && !isAbsolute(file) && !file.split(/[\\/]/).includes('..') && !/[{}]/.test(file);
}

/** 编辑后的资产形态：本体 content 或附带文件 files[].content（实例缺该文件时按 upsert 补建） */
function updatedAsset(source: Asset, file: string | undefined, content: string): Asset {
  if (file === undefined) return { ...source, payload: { ...source.payload, content } };
  const files = ((source.payload as { files?: SkillFileEntry[] }).files ?? []).slice();
  const idx = files.findIndex((f) => f.path === file);
  const nextFiles = idx >= 0 ? files.map((f) => (f.path === file ? { ...f, content } : f)) : [...files, { path: file, content }];
  return { ...source, payload: { ...source.payload, files: nextFiles } };
}

/** 附带文件通道目标：fileWrite 声明（command 平台）或本体所在目录派生路径（file-write 平台） */
function fileChannelTarget(asset: Asset, state: RegistryState, platforms: PlatformDef[], file: string): AssetContentSyncTarget {
  const platform = resolvePlatform(asset, platforms);
  if (!platform) {
    return { platform: '—', kind: 'file', label: `物化 ${file}`, executable: false, note: '资产不匹配任何平台适配（platforms.d）' };
  }
  const pid = platform.id;
  const kindDef = platform.kinds?.[asset.kind];
  if (!kindDef) {
    return { platform: pid, kind: 'file', label: `物化 ${file}`, executable: false, note: `平台 ${pid} 未声明 kind ${asset.kind}` };
  }
  if (kindDef.fileWrite?.type === 'command') {
    const from = kindDef.fileWrite.platformIdFrom ?? 'self';
    const platformId =
      from === 'deployment'
        ? ((state.assets.find((a) => a.kind === 'deployment' && (a.payload as { agent?: string }).agent?.toLowerCase() === asset.name.toLowerCase())?.payload as
            | { platformId?: string }
            | undefined)?.platformId)
        : (asset.payload as { platformId?: string }).platformId;
    const args = kindDef.fileWrite.cmd.slice(1).map((a) => {
      if (a === '{platformId}') return platformId ?? '{platformId}';
      if (a === '{filePath}') return file;
      return a;
    });
    return {
      platform: pid,
      kind: 'command',
      cmd: kindDef.fileWrite.cmd[0],
      args,
      executable: !!platformId,
      label: `执行 ${pid} 文件更新命令 ${kindDef.fileWrite.cmd[0]} ${args.join(' ')}`,
      note: platformId ? undefined : '未找到 platformId，需手动执行',
    };
  }
  if (kindDef.fileWrite !== undefined && kindDef.fileWrite.type !== 'file-write') {
    return { platform: pid, kind: 'file', label: `物化 ${file}`, executable: false, note: kindDef.fileWrite.advice };
  }
  if (kindDef.fileWrite === undefined && kindDef.write?.type !== 'file-write') {
    return { platform: pid, kind: 'file', label: `物化 ${file}`, executable: false, note: `平台 ${pid} 未声明附带文件写通道（fileWrite）` };
  }
  // file-write 平台：附带文件 = dirname(本体)/{filePath}
  const dir = dirname(asset.source.path);
  const target = resolve(dir, file);
  const ok = isAbsolute(asset.source.path) && target.startsWith(dir + sep);
  return {
    platform: pid,
    kind: 'file',
    path: target,
    executable: ok,
    label: `写本地文件 ${target}`,
    note: ok ? undefined : '目标路径越出技能目录或本体不是本地绝对路径',
  };
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

/**
 * 实例采集端是否登记附带文件（platforms.d read.files 声明）：
 * 附带文件编辑后实例库记录是否同步重写以采集可见性为准。本地 file 型采集只读 SKILL.md，
 * 若把 files 硬写进其实例库记录，下轮采集立即产生无法自愈的 store-drift（库记录 create-only）。
 * 编辑资产自身不受此限：file 必已在其 payload.files 登记，其采集端必然回读 files。
 */
function instanceTracksFiles(inst: Asset, platforms: PlatformDef[]): boolean {
  return resolvePlatform(inst, platforms)?.kinds?.[inst.kind]?.read?.files === true;
}

function channelTarget(asset: Asset, state: RegistryState, platforms: PlatformDef[], file?: string): AssetContentSyncTarget {
  if (file !== undefined) return fileChannelTarget(asset, state, platforms, file);
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
  storeRecords?: Map<string, StoreRecord>,
  file?: string
): { blocked?: string; targets: AssetContentSyncTarget[] } {
  const targets: AssetContentSyncTarget[] = [channelTarget(asset, state, platforms, file)];

  // 1:N：技能可部署在多个 Agent、跨多个平台，全部同名实例都对照新内容更新（各自走本平台声明通道）
  const instances = relatedSkillInstances(asset, state);
  for (const inst of instances) targets.push(channelTarget(inst, state, platforms, file));

  // 库内真源只收自建资产：第三方技能不入库（store 是 first-party 真源，create-only 不回收，
  // 写进去会永久污染对账配对）；第三方编辑仅更新其部署位置（本地文件即其源头）
  if (asset.provenance === 'first-party') {
    targets.push({ platform: 'library', kind: 'store', assetId: asset.id, executable: true, label: `更新库内真源 ${asset.id}${file ? ` · ${file}` : ''}` });
  }
  for (const inst of instances) {
    // 附带文件：仅当实例采集会回读 files 才重写其库记录；不登记的平台只写生产文件，不动库记录
    if (storeRecords?.has(inst.id) && (file === undefined || instanceTracksFiles(inst, platforms))) {
      targets.push({ platform: 'library', kind: 'store', assetId: inst.id, executable: true, label: `更新库内真源 ${inst.id}${file ? ` · ${file}` : ''}` });
    }
  }
  // 自建技能没有任何平台通道可执行时仍可入库，但如实告知：内容只进了库，生产侧未落地；
  // 第三方无库目标且无通道 → 无事可做，直接拒绝
  const hasStore = targets.some((t) => t.kind === 'store');
  const blocked = targets.some((t) => t.kind !== 'store' && t.executable)
    ? undefined
    : hasStore
      ? '无任何可执行的平台同步通道'
      : '无任何可执行的同步通道（第三方技能不入库，也无平台写通道）';
  return { blocked, targets };
}

export async function executeAssetContentSave(
  assetId: string,
  content: string,
  state: RegistryState,
  deps: AssetContentSaveDeps,
  file?: string
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
  if (file !== undefined) {
    if (typeof file !== 'string' || !isSafeSkillFilePath(file)) {
      return { status: 'invalid', ok: false, output: 'file 必须是技能内相对路径（禁止绝对路径、.. 穿越与花括号占位符）', targets: [] };
    }
    const registered = ((asset.payload as { files?: SkillFileEntry[] }).files ?? []).some((f) => f.path === file);
    if (!registered) {
      return { status: 'invalid', ok: false, output: `技能未登记该附带文件：${file}（仅可编辑采集登记的 files）`, targets: [] };
    }
  }

  const { blocked, targets } = planAssetContentSync(asset, state, deps.platforms, deps.storeRecords, file);
  // blocked 且无库目标 = 真的无事可做（第三方无通道）；有库目标 = 入库但生产侧未落地
  const hasStore = targets.some((t) => t.kind === 'store');
  if (blocked && !hasStore) return { status: 'invalid', ok: false, output: blocked, targets };

  const whitelist = writablePaths(state);
  const dirs = skillDirs(state);
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
        // 本体路径须在白名单；附带文件放宽为落在任一已登记技能目录内（路径由服务端从注册文件派生）
        const writable = whitelist.has(t.path) || (file !== undefined && dirs.some((d) => t.path!.startsWith(d + sep)));
        if (!writable) throw new Error(`拒绝写入：${t.path} 不是当前采集到的资产路径`);
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
        const updated = updatedAsset(source, file, content);
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
