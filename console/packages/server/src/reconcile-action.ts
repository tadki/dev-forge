import { copyFile, readFile, writeFile } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import { editRegistryPlatforms, spliceAgentInstructions, writeStoreRecord, storeFileName } from '@forge/collectors';
import type { ContentRef, RegistryState, ReconcileItem, StoreRecord, WriteStep } from '@forge/collectors';

export interface ExecResult {
  ok: boolean;
  stdout: string;
  stderr: string;
}

export interface ReconcileExecDeps {
  exec: (cmd: string, args: string[], timeoutMs: number) => Promise<ExecResult>;
  dryRun?: boolean;
  /** 库目录（store-write 采纳动作必需） */
  storeDir?: string;
  /** 库内真源副本（ContentRef.from='store' 时解析内容用） */
  storeRecords?: Map<string, StoreRecord>;
}

export interface ReconcileActionResult {
  /** ok=执行成功；invalid=动作 id 不存在或不可执行（4xx）；failed=执行中断（200 + ok:false） */
  status: 'ok' | 'invalid' | 'failed';
  ok: boolean;
  output: string;
  steps: WriteStep[];
}

const COMMAND_TIMEOUT_MS = 60_000;
const OUTPUT_LIMIT = 800;

/** 从当前 state 的资产 payload（默认）或库内副本（from='store'）解析同步内容（服务端唯一内容来源） */
export function resolveReconcileContent(ref: ContentRef, state: RegistryState, storeRecords?: Map<string, StoreRecord>): string | null {
  const asset = ref.from === 'store' ? storeRecords?.get(ref.assetId)?.asset : state.assets.find((a) => a.id === ref.assetId);
  if (!asset) return null;
  const payload = asset.payload as Record<string, unknown>;
  if (ref.field === 'content' || ref.field === 'instructions') {
    const value = payload[ref.field];
    return typeof value === 'string' ? value : null;
  }
  const samples = (payload.samples as Array<{ agent: string; body: string }> | undefined) ?? [];
  const sample = samples.find((s) => ref.agent && s.agent.toLowerCase() === ref.agent.toLowerCase());
  return sample?.body ?? null;
}

/** 可写路径白名单：当前 state 里已登记的资产源路径 + 物化样本路径（客户端无法注入路径） */
function writablePaths(state: RegistryState): Set<string> {
  const out = new Set<string>();
  for (const a of state.assets) if (isAbsolute(a.source.path)) out.add(a.source.path);
  const samplesAsset = state.assets.find((a) => a.id === 'custom:multica-materialized-instructions');
  const samples = ((samplesAsset?.payload as { samples?: Array<{ path: string }> } | undefined)?.samples) ?? [];
  for (const s of samples) if (isAbsolute(s.path)) out.add(s.path);
  return out;
}

function clip(text: string): string {
  const trimmed = text.trim();
  return trimmed.length <= OUTPUT_LIMIT ? trimmed : `${trimmed.slice(0, OUTPUT_LIMIT)}…`;
}

async function runFileWrite(step: Extract<WriteStep, { type: 'file-write' }>, state: RegistryState, deps: ReconcileExecDeps): Promise<string> {
  if (!writablePaths(state).has(step.path)) {
    throw new Error(`拒绝写入：${step.path} 不是当前采集到的资产路径`);
  }
  const content = resolveReconcileContent(step.contentFrom, state, deps.storeRecords);
  if (content === null) throw new Error(`内容不可用：${step.contentFrom.assetId} 的 ${step.contentFrom.field} 为空（from=${step.contentFrom.from ?? 'state'}）`);
  let finalContent = content;
  if (step.preserveMulticaPrefix) {
    // 保留 multica harness 前后段，只替换嵌入的 instructions 块
    const existing = await readFile(step.path, 'utf8').catch(() => '');
    finalContent = spliceAgentInstructions(existing, content);
  }
  if (deps.dryRun) return `[dry-run] 将写入 ${step.path}（${Buffer.byteLength(finalContent)} 字节）`;
  const backup = `${step.path}.forge-bak-${Date.now()}`;
  let backupNote = '（新建文件，无需备份）';
  try {
    await copyFile(step.path, backup);
    backupNote = `，原文件备份 ${backup}`;
  } catch {
    /* 目标不存在 */
  }
  await writeFile(step.path, finalContent, 'utf8');
  return `已写入 ${step.path}（${Buffer.byteLength(finalContent)} 字节${backupNote}）`;
}

/** 采纳生产：以当前采集资产重写库内副本（先备份旧记录） */
async function runStoreWrite(step: Extract<WriteStep, { type: 'store-write' }>, state: RegistryState, deps: ReconcileExecDeps): Promise<string> {
  if (!deps.storeDir) throw new Error('storeDir 未配置，无法写库');
  const asset = state.assets.find((a) => a.id === step.assetId);
  if (!asset) throw new Error(`资产不在当前采集中：${step.assetId}`);
  const target = join(deps.storeDir, storeFileName(step.assetId));
  if (deps.dryRun) return `[dry-run] 将以生产内容重写库内副本 ${target}`;
  let backupNote = '';
  try {
    const backup = `${target}.forge-bak-${Date.now()}`;
    await copyFile(target, backup);
    backupNote = `，旧副本备份 ${backup.split('/').pop()}`;
  } catch {
    /* 无旧记录 */
  }
  await writeStoreRecord(deps.storeDir, asset, deps.storeRecords?.get(step.assetId));
  return `已采纳生产进库：${step.assetId}（指纹重算${backupNote}）`;
}

async function runCommand(step: Extract<WriteStep, { type: 'command' }>, state: RegistryState, deps: ReconcileExecDeps): Promise<string> {
  const resolved = step.cmd.map((arg) => {
    if (arg !== '{content}') return arg;
    const content = step.contentFrom ? resolveReconcileContent(step.contentFrom, state, deps.storeRecords) : null;
    if (content === null) throw new Error('命令内容占位 {content} 无法解析');
    return content;
  });
  const displayArgs = resolved.map((arg, i) => (step.cmd[i] === '{content}' ? `<${arg.length} 字符>` : arg));
  const display = [step.cmd[0], ...displayArgs].join(' ');
  if (deps.dryRun) return `[dry-run] ${display}`;
  const result = await deps.exec(resolved[0], resolved.slice(1), COMMAND_TIMEOUT_MS);
  const tail = clip(`${result.stdout}${result.stderr}`);
  if (!result.ok) throw new Error(`命令失败：${display}${tail ? `\n${tail}` : ''}`);
  return `已执行 ${display}${tail ? `\n${tail}` : ''}`;
}

/**
 * 执行对账动作。item/actionId 由调用端从服务端重算的报告里解析，steps 不来自客户端。
 * 逐步骤执行，任一步失败即停并回报已执行内容。
 */
export async function executeReconcileAction(
  item: ReconcileItem,
  actionId: string,
  state: RegistryState,
  deps: ReconcileExecDeps
): Promise<ReconcileActionResult> {
  const action = item.actions.find((a) => a.id === actionId);
  if (!action) return { status: 'invalid', ok: false, output: `动作不存在：${actionId}`, steps: [] };
  if (!action.executable) {
    return { status: 'invalid', ok: false, output: action.note ?? '该方向没有安全的自动执行路径，请按提示手动处理', steps: [] };
  }
  const lines: string[] = [];
  for (const step of action.steps) {
    try {
      if (step.type === 'registry-edit') {
        if (deps.dryRun) {
          lines.push(`[dry-run] registry-edit ${step.op} ${step.platform} → ${step.entryId}（${step.file}）`);
        } else {
          const next = await editRegistryPlatforms(step.file, step.entryId, step.op, step.platform);
          lines.push(`已更新 ${step.file}：${step.entryId}.platforms = [${next.join(', ')}]`);
        }
      } else if (step.type === 'file-write') {
        lines.push(await runFileWrite(step, state, deps));
      } else if (step.type === 'store-write') {
        lines.push(await runStoreWrite(step, state, deps));
      } else {
        lines.push(await runCommand(step, state, deps));
      }
    } catch (e) {
      return { status: 'failed', ok: false, output: clip([...lines, `失败：${String(e)}`].join('\n')), steps: action.steps };
    }
  }
  return { status: 'ok', ok: true, output: clip(lines.join('\n')), steps: action.steps };
}
