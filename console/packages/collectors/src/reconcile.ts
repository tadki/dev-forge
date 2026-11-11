import { PLATFORM_IDS, type Asset } from '@forge/schema';
import type { RegistryEntry } from './overlay.js';
import { matchesRegistryEntry } from './overlay.js';
import { lineDiff, NO_DIFF_SENTINEL } from './line-diff.js';
import { buildMaterializedInstructionDiffs } from './materialized-instructions.js';
import { contentFingerprint, contentViewLines, isTruthKind } from './store-content.js';
import type { StoreRecord } from './first-party-store.js';
import { DEFAULT_PLATFORMS, resolvePlatform, resolveWriteChannel, type PlatformDef } from './platforms.js';
import { splitDiff, type SplitRow } from './split-diff.js';

export type ReconcileItemType =
  | 'missing-on-platform'
  | 'undeclared-platform'
  | 'content-drift'
  | 'store-drift'
  | 'patch-drift'
  | 'uncovered-assets';
export type ReconcileDirection = 'platform-to-local' | 'local-to-platform';

/** 内容来源：从当前 state 的资产 payload（默认）或库内副本（from:'store'）取同步内容（服务端解析，客户端无法注入） */
export interface ContentRef {
  assetId: string;
  field: 'content' | 'instructions' | 'materialized-body';
  /** field=materialized-body 时：物化样本所属 agent 名 */
  agent?: string;
  /** state=当前采集实测；store=库内真源副本（「以库为准」方向） */
  from?: 'state' | 'store';
}

export type WriteStep =
  | { type: 'registry-edit'; file: string; entryId: string; op: 'add-platform' | 'remove-platform'; platform: string }
  | { type: 'file-write'; path: string; contentFrom: ContentRef; preserveMulticaPrefix?: boolean }
  /** cmd 中值为 '{content}' 的参数由执行端用 contentFrom 解析的内容替换 */
  | { type: 'command'; cmd: string[]; note: string; contentFrom?: ContentRef }
  /** 采纳生产：以当前采集资产重写库内副本（first-party store） */
  | { type: 'store-write'; assetId: string };

export interface ReconcileAction {
  /** 同方向多动作时用 #n 区分（POST 按此 id 寻址，不用 direction） */
  id: string;
  direction: ReconcileDirection;
  label: string;
  /** false = 无安全自动路径，仅展示 note（建议命令/处理方式） */
  executable: boolean;
  note?: string;
  steps: WriteStep[];
}

export interface ReconcileCopy {
  assetId: string;
  name: string;
  path: string;
  sha?: string;
  platforms: string[];
}

export interface ReconcileItem {
  key: string;
  type: ReconcileItemType;
  severity: 'warn' | 'error';
  platform: string;
  entryId?: string;
  name: string;
  detail: string;
  /** content-drift 时的逐行差异（- 平台侧 / + 物化侧，供对账条目回退展示，截断 40 行） */
  diff?: string[];
  /** 全文对照（LCS 行对齐）：same 白底 / add 右栏绿 / del 右栏红；文本差异时提供 */
  splitRows?: SplitRow[];
  copies: ReconcileCopy[];
  actions: ReconcileAction[];
  /** 关联差异项（如 store-drift ↔ drift:multica 同一 agent），互链展示不合并 */
  relatedKeys?: string[];
}

export interface ReconcileReport {
  generatedAt: string;
  items: ReconcileItem[];
  summary: { missing: number; undeclared: number; drift: number; store: number; patch: number; uncovered: number; total: number };
}

function copyOf(a: Asset): ReconcileCopy {
  return {
    assetId: a.id,
    name: a.name,
    path: a.source.path,
    sha: a.source.sha256 ?? (a.payload as { contentHash?: string }).contentHash,
    platforms: a.platforms,
  };
}

function manualApplyNote(platform: string, matched: Asset[]): string {
  const example = matched[0];
  if (example?.kind === 'instruction') {
    return `需指定目标 agent 后执行：multica agent update <AGENT_ID> --instructions "$(cat ${example.source.path})"`;
  }
  return `无通用自动应用路径：请按资产类型手动在 ${platform} 上应用（或从声明中移除该平台）`;
}

export interface ReconcileOpts {
  /** 库内真源副本（v2）。提供时启用 store-drift 检测：库指纹 ≠ 生产指纹即差异 */
  store?: Map<string, StoreRecord>;
  /** 平台适配（默认 DEFAULT_PLATFORMS；生产由 engine 从 console/platforms.d 加载） */
  platforms?: PlatformDef[];
}

/** 库 vs 生产对账：真源副本指纹与当前采集内容分叉 → adopt（采纳生产）/ push（以库为准物化） */
function buildStoreDriftItems(state: { assets: Asset[] }, opts: ReconcileOpts): ReconcileItem[] {
  const store = opts.store;
  if (!store) return [];
  const platforms = opts.platforms ?? DEFAULT_PLATFORMS;
  const items: ReconcileItem[] = [];
  const contentField = (a: Asset): 'content' | 'instructions' | undefined => {
    if (a.kind === 'agent') return 'instructions';
    if (a.kind === 'instruction' || a.kind === 'skill') return 'content';
    // 文件型 kind（autopilot-script 脚本/配置/评审巡逻、hook-script、adapter）：正文已随 payload 归档（content），
    // 生产侧真有正文且是绝对路径文件时走全文 diff / 可执行 push；缺正文 → 内容视图逐字段对照
    if (a.kind === 'autopilot-script' || a.kind === 'hook-script' || a.kind === 'adapter') {
      const path = a.source.path;
      if (path.startsWith('/') && typeof (a.payload as { content?: unknown }).content === 'string') return 'content';
    }
    return undefined;
  };

  for (const a of state.assets) {
    if (!isTruthKind(a.kind)) continue;
    const reg = (a.payload as { registry?: { declared?: boolean } }).registry;
    if (reg?.declared !== true) continue;
    const record = store.get(a.id);
    if (!record || record.hashVersion !== 3) continue; // 未入库/待迁移 → 不比
    const fp = contentFingerprint(a);
    if (fp === record.hash) continue;

    const field = contentField(a);
    const storeText = field ? (record.asset.payload as Record<string, unknown>)[field] : undefined;
    const prodText = field ? (a.payload as Record<string, unknown>)[field] : undefined;
    // 有文本字段 → 全文 diff；两侧缺正文（旧记录未回填 / 无文件资产）或文本一致而指纹仍漂移
    // （差异来自元数据，如 skill 附带文件、agent model）→ 内容视图逐字段对照
    const bothText = typeof storeText === 'string' && typeof prodText === 'string';
    const viewSide = { left: contentViewLines(record.asset).join('\n'), right: contentViewLines(a).join('\n') };
    const textSide = bothText ? { left: storeText, right: prodText } : viewSide;
    const textDiff = lineDiff(textSide.left, textSide.right);
    const useView = textDiff[0] === NO_DIFF_SENTINEL;
    const side = useView ? viewSide : textSide;
    const diff = useView ? lineDiff(viewSide.left, viewSide.right) : textDiff; // - 库内真源 / + 生产实测

    const resolved = resolveWriteChannel(a, state.assets, platforms);
    let push: ReconcileAction;
    if (!resolved) {
      push = { id: 'push', direction: 'local-to-platform', label: '以库为准：物化到生产', executable: false, note: '资产不匹配任何平台适配（platforms.d）', steps: [] };
    } else if (resolved.write.type === 'file-write') {
      const executable = a.source.path.startsWith('/') && field !== undefined && typeof storeText === 'string';
      push = {
        id: 'push',
        direction: 'local-to-platform',
        label: `以库为准：覆盖 ${a.source.path}`,
        executable,
        note: executable ? undefined : '库内副本缺少可写入的文本字段（content/instructions），需手动同步',
        steps: executable ? [{ type: 'file-write', path: a.source.path, contentFrom: { assetId: a.id, field: field!, from: 'store' } }] : [],
      };
    } else if (resolved.write.type === 'command') {
      const executable = field !== undefined && typeof storeText === 'string';
      const cmd = resolved.write.cmd.map((arg) => (arg === '{platformId}' ? (resolved.platformId ?? '{platformId}') : arg));
      push = {
        id: 'push',
        direction: 'local-to-platform',
        label: `以库为准：执行 ${resolved.platform.id} 更新命令`,
        executable,
        note: executable ? undefined : '库内副本缺少可推送的文本字段（instructions/content），需手动执行',
        steps: executable
          ? [{ type: 'command', cmd, note: `${resolved.platform.label ?? resolved.platform.id} 写通道`, contentFrom: { assetId: a.id, field: field!, from: 'store' } }]
          : [],
      };
    } else {
      push = { id: 'push', direction: 'local-to-platform', label: `以库为准：物化到 ${resolved.platform.id}`, executable: false, note: resolved.write.advice, steps: [] };
    }

    items.push({
      key: `store:${a.id}`,
      type: 'store-drift',
      severity: 'warn',
      platform: a.platforms.join('+') || 'local',
      name: a.name,
      detail: `库内真源与生产实测分叉（${record.hash.slice(0, 8)} vs ${fp.slice(0, 8)}）`,
      diff: diff.slice(0, 40),
      splitRows: splitDiff(side.left, side.right),
      copies: [
        { assetId: record.asset.id, name: `${record.asset.name}（库内）`, path: record.asset.source.path, sha: record.hash.slice(0, 16), platforms: ['store'] },
        copyOf(a),
      ],
      actions: [
        {
          id: 'adopt',
          direction: 'platform-to-local',
          label: '以生产为准：把当前采集内容采纳进库',
          executable: true,
          steps: [{ type: 'store-write', assetId: a.id }],
        },
        push,
      ],
      ...(a.kind === 'agent' && resolvePlatform(a, platforms)?.id === 'multica'
        ? { relatedKeys: [`drift:multica:${a.name.toLowerCase()}`] }
        : {}),
    });
  }
  return items;
}

/**
 * 本地补丁漂移：patch 资产实测状态非 applied（升级覆盖 / 脚本已改 / 未记录基线）→ 提示重跑补丁。
 * 补丁的「真源」是 applier 脚本本身 + 它写下的 state 基线，不存在库内副本，因此只给 reapply 方向。
 */
function buildPatchDriftItems(state: { assets: Asset[] }): ReconcileItem[] {
  const reasonLabel: Record<string, string> = {
    drifted: '目标文件或上游版本与基线不符（补丁可能被升级覆盖）',
    stale: '补丁脚本已修改但未重跑，基线停留在旧脚本',
    unverified: '尚无应用基线，按契约跑一次补丁脚本即可纳入对账',
  };
  return state.assets
    .filter((a) => a.kind === 'patch' && (a.payload as { state?: string }).state !== 'applied')
    .map((a) => {
      const payload = a.payload as {
        state?: string;
        anchor?: { package?: string; version?: string };
        driftedTargets?: Array<{ path: string; reason: string }>;
        targetCount?: number;
      };
      const st = payload.state ?? 'unverified';
      const drifted = payload.driftedTargets ?? [];
      const sample = drifted
        .slice(0, 3)
        .map((d) => `${d.path.split('/').pop() ?? d.path}（${d.reason}）`)
        .join('、');
      const anchor = payload.anchor?.version ? ` · 锚定 ${payload.anchor.package ?? '?'}@${payload.anchor.version}` : '';
      return {
        key: `patch:${a.name}`,
        type: 'patch-drift' as const,
        severity: 'warn' as const,
        platform: a.platforms.join('+') || 'claude-code',
        name: `${a.name} · 本地补丁`,
        detail: `${reasonLabel[st] ?? st}${sample ? `：${sample}${drifted.length > 3 ? ` 等 ${drifted.length} 项` : ''}` : ''}${anchor}`,
        copies: [
          { assetId: a.id, name: `${a.name}（补丁程序）`, path: a.source.path, sha: a.source.sha256, platforms: a.platforms },
          ...drifted.slice(0, 5).map((d) => ({ assetId: a.id, name: d.path.split('/').pop() ?? d.path, path: d.path, platforms: a.platforms })),
        ],
        actions: [
          {
            id: 'reapply',
            direction: 'local-to-platform' as const,
            label: '重新应用补丁（重跑 applier，刷新基线）',
            executable: a.source.path.startsWith('/'),
            note: a.source.path.startsWith('/') ? undefined : '补丁脚本路径不可执行，请手动重跑',
            steps: a.source.path.startsWith('/')
              ? [{ type: 'command' as const, cmd: ['bash', a.source.path], note: '重跑本地补丁程序：重新应用修改并重写 state 基线' }]
              : [],
          },
        ],
      };
    });
}

/**
 * 平台对账：registry.d 声明的 platforms vs 采集到的实际 platforms，加上内容漂移
 * （库 vs 生产 store-drift；本地补丁 vs 现状 patch-drift；multica agent instructions ↔ 物化 workdir CLAUDE.md；同 entry 同名副本 sha 分叉）。
 * 纯函数：动作步骤全部由这里生成，执行端只认 key+direction，不接收客户端提交的路径/命令。
 */
export function buildReconcileReport(
  state: { assets: Asset[] },
  entries: RegistryEntry[],
  now: Date = new Date(),
  opts: ReconcileOpts = {}
): ReconcileReport {
  const items: ReconcileItem[] = [];
  const platforms = opts.platforms ?? DEFAULT_PLATFORMS;

  for (const entry of entries) {
    if (entry.platforms === undefined) continue; // 未声明平台 → 不参与归属对账
    const matched = state.assets.filter((a) => matchesRegistryEntry(a, entry));
    const actual = new Set(matched.flatMap((a) => a.platforms));

    for (const p of entry.platforms) {
      if (actual.has(p)) continue;
      items.push({
        key: `missing:${entry.id}:${p}`,
        type: 'missing-on-platform',
        severity: 'warn',
        platform: p,
        entryId: entry.id,
        name: entry.id,
        detail: `声明已应用于 ${p}，但采集未发现 ${p} 上的实例${matched.length === 0 ? '（声明未匹配到任何资产）' : ''}`,
        copies: matched.slice(0, 6).map(copyOf),
        actions: [
          {
            id: 'apply',
            direction: 'local-to-platform',
            label: `应用到 ${p}`,
            executable: false,
            note: manualApplyNote(p, matched),
            steps: [],
          },
          {
            id: 'retract',
            direction: 'platform-to-local',
            label: `撤销声明（从 ${entry.id} 移除 ${p}）`,
            executable: true,
            steps: [{ type: 'registry-edit', file: entry.file, entryId: entry.id, op: 'remove-platform', platform: p }],
          },
        ],
      });
    }

    for (const p of [...actual].sort()) {
      if (entry.platforms.includes(p)) continue;
      // 未注册平台（外部/推送资产的自由字符串）不能写进 registry.d——z.enum 校验会让整个 entry 下次加载被跳过
      const adoptable = (PLATFORM_IDS as readonly string[]).includes(p);
      items.push({
        key: `undeclared:${entry.id}:${p}`,
        type: 'undeclared-platform',
        severity: 'warn',
        platform: p,
        entryId: entry.id,
        name: entry.id,
        detail: `资产实际出现在 ${p}，但声明未包含该平台`,
        copies: matched.filter((a) => a.platforms.includes(p)).slice(0, 6).map(copyOf),
        actions: [
          {
            id: 'adopt',
            direction: 'platform-to-local',
            label: `采纳现状：声明 ${entry.id} 已应用 ${p}`,
            executable: adoptable,
            note: adoptable ? undefined : `平台 ${p} 未注册（PLATFORM_IDS / platforms.d），先在平台适配层注册后再声明，避免污染 registry 枚举`,
            steps: adoptable
              ? [{ type: 'registry-edit', file: entry.file, entryId: entry.id, op: 'add-platform', platform: p }]
              : [],
          },
          {
            id: 'retire',
            direction: 'local-to-platform',
            label: `以声明为准：从 ${p} 下线该资产`,
            executable: false,
            note: `不提供自动下线：请在 ${p} 上手动移除/停用后重采，或改用「采纳现状」`,
            steps: [],
          },
        ],
      });
    }
  }

  // 同 entry 同名副本漂移：同一逻辑资产的多份拷贝内容分叉
  for (const entry of entries) {
    const groups = new Map<string, Asset[]>();
    for (const a of state.assets) {
      if (!matchesRegistryEntry(a, entry)) continue;
      if (!a.source.sha256) continue;
      const k = `${a.kind}|${a.name}`;
      groups.set(k, [...(groups.get(k) ?? []), a]);
    }
    for (const [k, list] of groups) {
      const shas = new Set(list.map((a) => a.source.sha256).filter((s): s is string => !!s));
      if (list.length < 2 || shas.size < 2) continue;
      const [kind, ...nameParts] = k.split('|');
      const actions: ReconcileAction[] = [];
      for (let i = 0; i < list.length && i < 2; i++) {
        const src = list[i];
        const dst = list[(i + 1) % Math.min(list.length, 2)];
        const from = src as Asset;
        const to = dst as Asset;
        const hasContent = typeof (from.payload as { content?: unknown }).content === 'string';
        actions.push({
          id: `copy-${i}`,
          // 方向按内容流向：本地源 → multica 目标 = local-to-platform（此前按目标平台反推，混合平台时箭头相反）
          direction: to.platforms.includes('multica') && !from.platforms.includes('multica') ? 'local-to-platform' : 'platform-to-local',
          label: `以 ${from.source.path} 为准覆盖 ${to.source.path}`,
          executable: hasContent && to.source.path.startsWith('/'),
          note: hasContent ? undefined : '源副本内容未随资产采集（payload.content 缺失），需手动同步',
          steps: hasContent && to.source.path.startsWith('/')
            ? [{ type: 'file-write', path: to.source.path, contentFrom: { assetId: from.id, field: 'content' } }]
            : [],
        });
      }
      items.push({
        key: `drift:${entry.id}:${kind}:${nameParts.join('|')}`,
        type: 'content-drift',
        severity: 'warn',
        platform: [...new Set(list.flatMap((a) => a.platforms))].join('+') || 'local',
        entryId: entry.id,
        name: nameParts.join('|'),
        detail: `${list.length} 份同名副本 sha 分叉（${[...shas].map((s) => s.slice(0, 8)).join(' / ')}）`,
        copies: list.map(copyOf),
        actions,
      });
    }
  }

  // 覆盖集：被任一「声明了 platforms」的 entry 匹配到的资产（用于技能配对与兜底分组）
  const covered = new Set<string>();
  for (const entry of entries) {
    if (entry.platforms === undefined) continue;
    for (const a of state.assets) if (matchesRegistryEntry(a, entry)) covered.add(a.id);
  }

  // 跨平台技能：本地声明的自建 skill ↔ multica 同名 skill（名称归一化匹配），内容分叉即漂移
  const normName = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, '');
  const multicaSkills = state.assets.filter(
    (a) =>
      a.kind === 'skill' &&
      a.platforms.includes('multica') &&
      resolvePlatform(a, platforms)?.id === 'multica' &&
      typeof (a.payload as { content?: unknown }).content === 'string'
  );
  for (const local of state.assets) {
    if (local.kind !== 'skill' || resolvePlatform(local, platforms)?.id !== 'claude-code' || !covered.has(local.id)) continue;
    const localContent = (local.payload as { content?: unknown }).content;
    // 本地无 SKILL.md（content 为空）时不配对：属于"本地缺文件"，不是内容漂移
    if (typeof localContent !== 'string' || localContent.trim() === '') continue;
    const remote = multicaSkills.find((m) => normName(m.name) === normName(local.name));
    if (!remote) continue;
    const remoteContent = (remote.payload as { content?: unknown }).content;
    if (typeof remoteContent !== 'string' || remoteContent.trim() === localContent.trim()) continue;
    const platformId = (remote.payload as { platformId?: string }).platformId;
    items.push({
      key: `drift:skill:${local.id}`,
      type: 'content-drift',
      severity: 'warn',
      platform: 'claude-code+multica',
      name: `${local.name} · SKILL.md`,
      detail: `claude-code 与 multica 两侧同名技能内容不一致（跨平台副本分叉）`,
      diff: lineDiff(remoteContent, localContent), // - multica 副本 / + 本地
      splitRows: splitDiff(remoteContent, localContent),
      copies: [copyOf(local), copyOf(remote)],
      actions: [
        {
          id: 'write-local',
          direction: 'platform-to-local',
          label: '以 multica 副本覆盖 claude-code 侧 SKILL.md',
          executable: true,
          steps: [{ type: 'file-write', path: local.source.path, contentFrom: { assetId: remote.id, field: 'content' } }],
        },
        {
          id: 'update-platform',
          direction: 'local-to-platform',
          label: '以 claude-code 侧 SKILL.md 更新 multica 技能',
          executable: !!platformId,
          note: platformId ? undefined : '未找到该 multica 技能的 platformId，需手动执行',
          steps: platformId
            ? [
                {
                  type: 'command',
                  cmd: ['multica', 'skill', 'update', platformId, '--content', '{content}'],
                  note: 'SKILL.md 内容在执行端从本地资产读取后传入',
                  contentFrom: { assetId: local.id, field: 'content' },
                },
              ]
            : [],
        },
      ],
    });
  }

  // 兜底：有平台归属但没有被任何 platforms 声明覆盖的自建资产（按 kind×平台分组提示补声明）。
  // custom 是采集器派生的观测视图（活动流、健康报告、样本聚合），不参与平台对账。
  const NET_EXCLUDED_KINDS = new Set(['custom']);
  const uncoveredGroups = new Map<string, Asset[]>();
  for (const a of state.assets) {
    if (a.provenance !== 'first-party' || a.platforms.length === 0 || covered.has(a.id)) continue;
    if (NET_EXCLUDED_KINDS.has(a.kind) || a.id.startsWith('registry:unmatched-')) continue;
    const k = `${a.kind}:${[...a.platforms].sort().join('+')}`;
    uncoveredGroups.set(k, [...(uncoveredGroups.get(k) ?? []), a]);
  }
  for (const [k, list] of uncoveredGroups) {
    const [kind, platform] = k.split(':');
    items.push({
      key: `uncovered:${k}`,
      type: 'uncovered-assets',
      severity: 'warn',
      platform,
      name: `${kind} × ${platform} · ${list.length} 项未纳入对账`,
      detail: '这些自建资产有平台归属，但没有被任何声明 platforms 的 registry entry 覆盖，归属差异无处对账',
      copies: list.slice(0, 6).map(copyOf),
      actions: [
        {
          id: 'declare',
          direction: 'platform-to-local',
          label: '采纳现状：在 registry.d 补声明',
          executable: false,
          note: `在 console/registry.d/owned.yaml 补 entry：match: { idPrefix: "${kind}:" }（或更精确的 pathPrefix）  platforms: [${platform}]`,
          steps: [],
        },
      ],
    });
  }

  // multica：agent instructions（平台权威）↔ 最新物化 workdir CLAUDE.md
  const instructionDiffs = buildMaterializedInstructionDiffs(state.assets);
  for (const d of instructionDiffs) {
    if (d.identical) continue;
    const agentAsset = state.assets.find(
      (a) => a.kind === 'agent' && a.name.toLowerCase() === d.agent.toLowerCase() && !(a.payload as { subagent?: boolean }).subagent
    );
    const sampleAsset = state.assets.find((a) => a.id === 'custom:multica-materialized-instructions');
    const deployment = state.assets.find((a) => a.id === `deployment:multica:${d.agent.toLowerCase()}`);
    const platformId = (deployment?.payload as { platformId?: string } | undefined)?.platformId;
    const hasInstructions = typeof (agentAsset?.payload as { instructions?: unknown } | undefined)?.instructions === 'string';
    const instructionsText = hasInstructions ? (agentAsset!.payload as { instructions: string }).instructions : '';
    const instructionsTruncated = instructionsText.endsWith('…(截断)');
    const sampleBody = (((sampleAsset?.payload as { samples?: Array<{ agent: string; body: string }> } | undefined)?.samples) ?? []).find(
      (s) => s.agent.toLowerCase() === d.agent.toLowerCase()
    )?.body;
    const sampleTruncated = sampleBody?.endsWith('…(截断)') ?? false;
    const instructionsHash = (agentAsset?.payload as { instructionsHash?: string } | undefined)?.instructionsHash ?? d.currentHash;
    items.push({
      key: `drift:multica:${d.agent.toLowerCase()}`,
      type: 'content-drift',
      severity: 'warn',
      platform: 'multica',
      name: `${d.agent} · instructions`,
      detail: `平台 instructions 与物化 workdir CLAUDE.md 不一致（${instructionsHash.slice(0, 8)} vs ${d.materializedHash}）`,
      diff: d.diff.slice(0, 40),
      ...(hasInstructions && sampleBody ? { splitRows: splitDiff(instructionsText, sampleBody) } : {}),
      copies: [
        ...(agentAsset ? [copyOf(agentAsset)] : []),
        { assetId: sampleAsset?.id ?? 'custom:multica-materialized-instructions', name: `${d.agent} workdir CLAUDE.md`, path: d.materializedPath ?? '', sha: d.materializedHash, platforms: ['multica'] },
      ],
      actions: [
        {
          id: 'write-workdir',
          // 平台权威内容 → 覆盖本地（workdir）文件
          direction: 'platform-to-local',
          label: `以 agent instructions 为准，回写 workdir 物化文件`,
          executable: hasInstructions && !instructionsTruncated && !!d.materializedPath?.startsWith('/'),
          note: hasInstructions
            ? instructionsTruncated
              ? 'instructions 超过 60k 已被截断采集，禁止自动回写（防截断内容覆盖生产）；请手动处理'
              : undefined
            : 'agent instructions 未随资产采集，需手动回写',
          steps:
            hasInstructions && d.materializedPath?.startsWith('/')
              ? [
                  {
                    type: 'file-write',
                    path: d.materializedPath,
                    contentFrom: { assetId: agentAsset!.id, field: 'instructions' },
                    preserveMulticaPrefix: true,
                  },
                ]
              : [],
        },
        {
          id: 'update-agent',
          // 物化（本地）内容 → 更新平台
          direction: 'local-to-platform',
          label: `以物化 CLAUDE.md 为准，更新 agent instructions`,
          executable: !!platformId && !sampleTruncated,
          note: platformId
            ? sampleTruncated
              ? '物化样本超过 60k 已被截断，禁止自动推送（防截断内容覆盖平台）；请手动执行'
              : undefined
            : '未找到该 agent 的 multica platformId（deployment 资产缺失），需手动执行',
          steps: platformId
            ? [
                {
                  type: 'command',
                  cmd: ['multica', 'agent', 'update', platformId, '--instructions', '{content}'],
                  note: 'instructions 内容在执行端从物化样本读取后传入',
                  contentFrom: { assetId: 'custom:multica-materialized-instructions', field: 'materialized-body', agent: d.agent },
                },
              ]
            : [],
        },
      ],
    });
  }

  // 库（真源）vs 生产：指纹分叉 → store-drift（adopt / push 双向裁决）
  items.push(...buildStoreDriftItems(state, opts));

  // 本地补丁 vs 现状：基线失配 → patch-drift（reapply 单向）
  items.push(...buildPatchDriftItems(state));

  items.sort((a, b) => a.key.localeCompare(b.key));
  return {
    generatedAt: now.toISOString(),
    items,
    summary: {
      missing: items.filter((i) => i.type === 'missing-on-platform').length,
      undeclared: items.filter((i) => i.type === 'undeclared-platform').length,
      drift: items.filter((i) => i.type === 'content-drift').length,
      store: items.filter((i) => i.type === 'store-drift').length,
      patch: items.filter((i) => i.type === 'patch-drift').length,
      uncovered: items.filter((i) => i.type === 'uncovered-assets').length,
      total: items.length,
    },
  };
}

/** 对账差异 → warn 诊断（截断防刷屏；Overview 的诊断尾部自然展示） */
export function reconcileDiagnostics(report: ReconcileReport, limit = 30): Array<{ level: 'warn'; message: string; path?: string }> {
  const label: Record<ReconcileItemType, string> = {
    'missing-on-platform': '声明未落地',
    'undeclared-platform': '未声明平台',
    'content-drift': '内容漂移',
    'store-drift': '库与生产分叉',
    'patch-drift': '补丁漂移',
    'uncovered-assets': '未纳入对账',
  };
  return report.items.slice(0, limit).map((i) => ({
    level: 'warn' as const,
    message: `[reconcile] ${label[i.type]} · ${i.name}（${i.platform}）${i.detail}`,
    path: i.copies[0]?.path,
  }));
}
