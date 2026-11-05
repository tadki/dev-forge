import type { Asset } from '@forge/schema';
import type { RegistryEntry } from './overlay.js';
import { matchesRegistryEntry } from './overlay.js';
import { buildMigrationView, lineDiff } from './migration.js';

export type ReconcileItemType = 'missing-on-platform' | 'undeclared-platform' | 'content-drift' | 'uncovered-assets';
export type ReconcileDirection = 'platform-to-local' | 'local-to-platform';

/** 内容来源：从当前 state 的资产 payload 里取同步内容（服务端解析，客户端无法注入） */
export interface ContentRef {
  assetId: string;
  field: 'content' | 'instructions' | 'materialized-body';
  /** field=materialized-body 时：物化样本所属 agent 名 */
  agent?: string;
}

export type WriteStep =
  | { type: 'registry-edit'; file: string; entryId: string; op: 'add-platform' | 'remove-platform'; platform: string }
  | { type: 'file-write'; path: string; contentFrom: ContentRef; preserveMulticaPrefix?: boolean }
  /** cmd 中值为 '{content}' 的参数由执行端用 contentFrom 解析的内容替换 */
  | { type: 'command'; cmd: string[]; note: string; contentFrom?: ContentRef };

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
  /** content-drift 时的逐行差异（- 平台侧 / + 物化侧，与迁移页同源，截断 40 行） */
  diff?: string[];
  copies: ReconcileCopy[];
  actions: ReconcileAction[];
}

export interface ReconcileReport {
  generatedAt: string;
  items: ReconcileItem[];
  summary: { missing: number; undeclared: number; drift: number; uncovered: number; total: number };
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

/**
 * 平台对账：registry.d 声明的 platforms vs 采集到的实际 platforms，加上内容漂移
 * （multica agent instructions ↔ 物化 workdir CLAUDE.md；同 entry 同名副本 sha 分叉）。
 * 纯函数：动作步骤全部由这里生成，执行端只认 key+direction，不接收客户端提交的路径/命令。
 */
export function buildReconcileReport(
  state: { assets: Asset[] },
  entries: RegistryEntry[],
  now: Date = new Date()
): ReconcileReport {
  const items: ReconcileItem[] = [];

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
            executable: true,
            steps: [{ type: 'registry-edit', file: entry.file, entryId: entry.id, op: 'add-platform', platform: p }],
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
          direction: to.platforms.includes('multica') && !from.platforms.includes('multica') ? 'platform-to-local' : 'local-to-platform',
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
      a.source.path.startsWith('multica://') &&
      typeof (a.payload as { content?: unknown }).content === 'string'
  );
  for (const local of state.assets) {
    if (local.kind !== 'skill' || !local.source.path.startsWith('/') || !covered.has(local.id)) continue;
    const localContent = (local.payload as { content?: unknown }).content;
    if (typeof localContent !== 'string') continue;
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

  // 兜底：有平台归属但没有被任何 platforms 声明覆盖的自建资产（按 kind×平台分组提示补声明）
  const uncoveredGroups = new Map<string, Asset[]>();
  for (const a of state.assets) {
    if (a.provenance !== 'first-party' || a.platforms.length === 0 || covered.has(a.id)) continue;
    if (a.id.startsWith('registry:unmatched-')) continue;
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
  const view = buildMigrationView(state.assets);
  for (const d of view.diffs) {
    if (d.identical) continue;
    const agentAsset = state.assets.find(
      (a) => a.kind === 'agent' && a.name.toLowerCase() === d.agent.toLowerCase() && !(a.payload as { subagent?: boolean }).subagent
    );
    const sampleAsset = state.assets.find((a) => a.id === 'custom:multica-materialized-instructions');
    const deployment = state.assets.find((a) => a.id === `deployment:multica:${d.agent.toLowerCase()}`);
    const platformId = (deployment?.payload as { platformId?: string } | undefined)?.platformId;
    const hasInstructions = typeof (agentAsset?.payload as { instructions?: unknown } | undefined)?.instructions === 'string';
    const instructionsHash = (agentAsset?.payload as { instructionsHash?: string } | undefined)?.instructionsHash ?? d.currentHash;
    items.push({
      key: `drift:multica:${d.agent.toLowerCase()}`,
      type: 'content-drift',
      severity: 'warn',
      platform: 'multica',
      name: `${d.agent} · instructions`,
      detail: `平台 instructions 与物化 workdir CLAUDE.md 不一致（${instructionsHash.slice(0, 8)} vs ${d.materializedHash}）`,
      diff: d.diff.slice(0, 40),
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
          executable: hasInstructions && !!d.materializedPath?.startsWith('/'),
          note: hasInstructions ? undefined : 'agent instructions 未随资产采集，需手动回写',
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
          executable: !!platformId,
          note: platformId ? undefined : '未找到该 agent 的 multica platformId（deployment 资产缺失），需手动执行',
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

  items.sort((a, b) => a.key.localeCompare(b.key));
  return {
    generatedAt: now.toISOString(),
    items,
    summary: {
      missing: items.filter((i) => i.type === 'missing-on-platform').length,
      undeclared: items.filter((i) => i.type === 'undeclared-platform').length,
      drift: items.filter((i) => i.type === 'content-drift').length,
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
    'uncovered-assets': '未纳入对账',
  };
  return report.items.slice(0, limit).map((i) => ({
    level: 'warn' as const,
    message: `[reconcile] ${label[i.type]} · ${i.name}（${i.platform}）${i.detail}`,
    path: i.copies[0]?.path,
  }));
}
