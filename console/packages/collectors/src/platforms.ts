import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { parse } from 'yaml';
import { ASSET_KINDS, type Asset, type Diagnostic } from '@forge/schema';

/**
 * 平台适配层（Owner 2026-11-06）：每个平台一套读写适配，声明在 console/platforms.d/*.yaml。
 * - 平台归属（Owner 2026-11-11）：以资产自声明 platforms 为准，采集路径完全不参与归属——
 *   平台原生源（multica://、~/.claude 配置域）由采集器声明；dev-forge 工具链内部文件由
 *   registry.d/owned.yaml 声明、overlay 盖到资产上（扫描路径只证明「是 dev-forge 的什么」，
 *   证明不了平台归属）。空声明 / source.platform='none' = 不归属任何平台，落平台页未适配桶。
 *   平台页若出现归属错误的资产，修的是声明（采集器或 owned.yaml），不是归桶逻辑。
 * - kinds[kind].read：读取方式（cli 命令 / file 扫描路径 / derived 派生 / none），平台页文档化展示
 * - kinds[kind].write：以库为准物化通道——file-write（本地文件）/ command（平台 CLI）/ none+advice（仅建议）
 * 安全校验（路径白名单/备份/dry-run）不在 YAML，仍在执行器代码。
 * 新增平台：PLATFORM_IDS 加 id → 复制一份 YAML（DEFAULT_PLATFORMS 同步，锁步单测兜底）→ 采集器给资产声明该平台 id。
 */
export interface PlatformWriteCommand {
  type: 'command';
  cmd: string[];
  /** platformId 取值位置：self=资产 payload.platformId；deployment=该 agent 的 deployment 资产 payload.platformId */
  platformIdFrom?: 'self' | 'deployment';
}
export interface PlatformWriteNone {
  type: 'none';
  advice: string;
}
export type PlatformWrite = { type: 'file-write' } | PlatformWriteCommand | PlatformWriteNone;

export interface PlatformRead {
  how: 'cli' | 'file' | 'derived' | 'none';
  /** 服务该 kind 的采集器名（文档归因；页面实时归因按资产 source.collector 汇总） */
  collector?: string;
  /** cli：清单/发现命令（采集器追加 --output json） */
  cmd?: string[];
  /** cli：逐条取正文的命令（如 multica skill get {id} --with-content） */
  detailCmd?: string[];
  /** detail 采集是否登记附带文件 files[]（multica 经 skill get --with-content 登记）。
   *  附带文件编辑后实例库记录是否同步重写以此为准：file 型采集只读本体，缺省不登记。 */
  files?: boolean;
  /** file：扫描路径模式（支持 ~ 与 <project>/<devforge>/<task.work_dir> 占位） */
  paths?: string[];
  note?: string;
}

export interface PlatformKindDef {
  /** false = 平台结构上无此对象类型（不适用，非未适配）；声明后不得再有 read/write，note 必填说明 */
  applicable?: false;
  note?: string;
  read?: PlatformRead;
  /** 适用 kind 必填；applicable=false 时禁止 */
  write?: PlatformWrite;
  /** 附带文件（非本体，如 skill 的 files[]）的以库为准写通道；{filePath} 为技能内相对路径。
   *  file-write 平台无需声明：附带文件路径 = dirname(本体路径)/{filePath}，同一本地写入通道。 */
  fileWrite?: PlatformWrite;
}

export interface PlatformDef {
  id: string;
  label?: string;
  kinds?: Record<string, PlatformKindDef>;
}

export interface LoadedPlatforms {
  platforms: PlatformDef[];
  diagnostics: Diagnostic[];
}

/** platforms.d 缺失时的兜底（与 console/platforms.d 的两份 YAML 逐字段等价，锁步单测兜底；运行态以 YAML 为准） */
export const DEFAULT_PLATFORMS: PlatformDef[] = [
  {
    id: 'claude-code',
    label: 'Claude Code（本地文件系统）',
    kinds: {
      instruction: {
        read: {
          how: 'file',
          collector: 'claude-projects',
          paths: ['<project>/CLAUDE.md', '~/.claude/rules/*/*.md'],
          note: '项目 CLAUDE.md（claude-projects）+ 全局规则包 rules/*（claude-global，第三方依赖架）',
        },
        write: { type: 'file-write' },
      },
      skill: {
        read: {
          how: 'file',
          collector: 'claude-global',
          paths: ['~/.claude/skills/*/SKILL.md', '~/.claude/.agents/skills/*/SKILL.md', '~/.claude/commands/*.md', '<project>/.claude/skills/*/SKILL.md'],
          note: '用户级技能/命令 + ECC .agents/skills（claude-global）；项目级 .claude/skills（claude-projects）',
        },
        write: { type: 'file-write' },
      },
      agent: {
        read: {
          how: 'file',
          collector: 'claude-projects',
          paths: ['<project>/.claude/agents/*.md'],
          note: 'CC subagent 定义文件（frontmatter name 去重，同名首见优先）',
        },
        write: { type: 'file-write' },
      },
      'hook-rule': {
        read: {
          how: 'file',
          collector: 'devforge-hooks',
          paths: ['<devforge>/claude-hooks/*.json'],
          note: '规则清单 JSON（devforge-hooks）；settings.json 挂载由 claude-global 读（hook-registration）',
        },
        write: { type: 'file-write' },
      },
      'hook-script': {
        read: {
          how: 'file',
          collector: 'devforge-hooks',
          paths: ['<devforge>/claude-hooks/scripts/*.sh', '<devforge>/claude-hooks/scripts/lib/*.sh', '<project>/.claude/hooks/*.sh'],
          note: 'dev-forge 挂载脚本与 lib（devforge-hooks）+ 项目钩子（claude-projects）',
        },
        write: { type: 'file-write' },
      },
      adapter: {
        read: {
          how: 'file',
          collector: 'devforge-adapters',
          paths: ['<devforge>/adapters/*'],
          note: '本地适配脚本（.sh/.py/.js，提取 env 契约）',
        },
        write: { type: 'file-write' },
      },
      patch: {
        read: {
          how: 'file',
          collector: 'devforge-patches',
          paths: ['~/.hindsight/patches/*.sh', '~/.hindsight/patches/*.state.json'],
          note: '本地补丁程序 + 应用基线 state（devforge-patches 实测漂移：升级覆盖/脚本已改/未记录基线）',
        },
        write: { type: 'file-write' },
      },
      'autopilot-registration': {
        applicable: false,
        note: 'Claude Code 无 autopilot 体系：注册项是 multica 平台对象，由资产声明归属 multica',
      },
      'autopilot-script': {
        applicable: false,
        note: 'Claude Code 无 autopilot 体系：dev-forge 巡逻脚本/评审巡逻由 registry.d 声明归属 multica',
      },
      'hook-registration': {
        read: {
          how: 'file',
          collector: 'claude-global',
          paths: ['~/.claude/settings.json'],
          note: 'settings.json hooks 挂载点实测（claude-global）；dev-forge 注册清单为自研面工件（custom，钩子页展示，非平台对象）',
        },
        write: { type: 'file-write' },
      },
      'mcp-endpoint': {
        read: {
          how: 'file',
          collector: 'claude-global',
          paths: ['~/.claude/.mcp.json', '<project>/.mcp.json'],
          note: '用户级与项目级 MCP 清单（url 脱敏）',
        },
        write: { type: 'none', advice: '.mcp.json 手工编辑（含密钥字段，采集已脱敏，不做自动物化）' },
      },
      env: {
        read: {
          how: 'file',
          collector: 'claude-global',
          paths: ['~/.claude/settings.json'],
          note: 'settings.json env（采集脱敏）',
        },
        write: { type: 'none', advice: 'env 含敏感值且采集已脱敏，不支持物化' },
      },
      project: {
        read: {
          how: 'derived',
          collector: 'claude-projects',
          paths: ['console.config.yaml#workspaces', '<project>/'],
          note: '登记驱动：workspaces.projects 注册路径 → 扫描 .claude/CLAUDE.md/.mcp.json 等（harnesses 声明门控）',
        },
        write: { type: 'none', advice: '项目登记在 console.config.yaml，不支持物化' },
      },
      report: {
        read: {
          how: 'file',
          collector: 'health',
          paths: ['~/.multica/toolchain-reports/latest.json', '~/.multica/arch-patrol/last_report.json'],
          note: '外部工具产出的健康报告（只读监控）',
        },
        write: { type: 'none', advice: '外部工具产出，只读' },
      },
      custom: {
        read: {
          how: 'derived',
          collector: 'claude-global',
          note: 'settings.json permissions/enabledPlugins 等杂项（各采集器附带产出）；跨平台聚合/运行时日志类 custom 无平台声明，落未适配桶',
        },
        write: { type: 'none', advice: '聚合/观测型资产，无写通道' },
      },
      deployment: {
        applicable: false,
        note: 'Claude Code 无部署实例对象：deployment 是 multica 的 agent×运行环境绑定（platformId/workspaceId/status），本地文件系统平台不存在此概念',
      },
    },
  },
  {
    id: 'multica',
    label: 'multica 平台',
    kinds: {
      skill: {
        read: {
          how: 'cli',
          collector: 'multica',
          cmd: ['multica', 'skill', 'list'],
          detailCmd: ['multica', 'skill', 'get', '{id}', '--with-content'],
          files: true,
          note: '清单经 skill list（--output json），正文逐条 skill get --with-content（并发限流 5，上限 50 条）',
        },
        write: { type: 'command', cmd: ['multica', 'skill', 'update', '{platformId}', '--content', '{content}'], platformIdFrom: 'self' },
        fileWrite: { type: 'command', cmd: ['multica', 'skill', 'files', 'upsert', '{platformId}', '--path', '{filePath}', '--content', '{content}'], platformIdFrom: 'self' },
      },
      agent: {
        read: {
          how: 'cli',
          collector: 'multica',
          cmd: ['multica', 'agent', 'list'],
          note: 'instructions/skills/mcp_config/运行态均在 agent list JSON 单次返回',
        },
        write: { type: 'command', cmd: ['multica', 'agent', 'update', '{platformId}', '--instructions', '{content}'], platformIdFrom: 'deployment' },
      },
      instruction: {
        read: {
          how: 'derived',
          collector: 'multica',
          paths: ['<task.work_dir>/CLAUDE.md'],
          note: 'agent instructions 随 agent list 采集（存于 agent 资产 payload）；另采样最新完成任务 workdir 的物化 CLAUDE.md（custom:multica-materialized-instructions，≤4 agent）作对账基准',
        },
        write: { type: 'none', advice: 'multica agent update <AGENT_ID> --instructions "$(cat <资产路径>)"（需指定目标 agent）' },
      },
      'autopilot-registration': {
        read: {
          how: 'cli',
          collector: 'multica',
          cmd: ['multica', 'autopilot', 'list'],
          detailCmd: ['multica', 'autopilot', 'trigger-list', '{id}'],
          note: '清单 autopilot list，触发器逐条 trigger-list（取前 20 个）',
        },
        write: { type: 'none', advice: 'multica autopilot 暂无通用更新命令：请在平台侧修改后重采，或改为「以生产为准」采纳进库' },
      },
      'autopilot-script': {
        read: {
          how: 'file',
          collector: 'devforge-autopilots',
          paths: ['<devforge>/autopilots/*.py', '<devforge>/autopilots/*.sh', '<devforge>/autopilots/configs/*.json', '<devforge>/autopilots/review-prompts/*'],
          note: 'dev-forge 巡逻脚本 + 配置 + agent 评审巡逻（registry.d 声明归属 multica，multica autopilot 引用执行）',
        },
        write: { type: 'file-write' },
      },
      'hook-rule': {
        read: { how: 'none', note: '规则源文件在 dev-forge 仓库（devforge-hooks 采集，registry.d 声明 claude-code+multica），无 multica 平台对象' },
        write: { type: 'none', advice: 'hook 规则经全局 ~/.claude hooks 生效于 multica 会话；以库为准时改 dev-forge 源文件即可，无平台对象' },
      },
      'hook-script': {
        read: { how: 'none', note: '脚本在 dev-forge 仓库文件系统（devforge-hooks 采集），无 multica 对象' },
        write: { type: 'none', advice: '脚本在 dev-forge 仓库，采集自文件系统，无平台对象' },
      },
      adapter: {
        read: { how: 'none', note: 'adapters 为 dev-forge 本地脚本（devforge-adapters 采集），无 multica 对象' },
        write: { type: 'none', advice: 'adapters 为本地脚本，无平台对象' },
      },
      deployment: {
        read: {
          how: 'cli',
          collector: 'multica',
          cmd: ['multica', 'agent', 'list'],
          note: '部署实例与 agent 同一 JSON 产出（platformId/workspaceId/status 等运行态字段只落在 deployment）',
        },
        write: { type: 'none', advice: '部署绑定由 multica daemon 管理，无物化通道' },
      },
      'mcp-endpoint': {
        read: {
          how: 'cli',
          collector: 'multica',
          cmd: ['multica', 'agent', 'list'],
          note: 'per-agent mcp_config.mcpServers 展开（采集时脱敏）',
        },
        write: { type: 'none', advice: 'per-agent MCP 配置含密钥（已脱敏），请在平台侧修改' },
      },
      service: {
        read: {
          how: 'cli',
          collector: 'multica',
          cmd: ['multica', 'runtime', 'list'],
          note: 'runtime 守护登记（取前 5）',
        },
        write: { type: 'none', advice: 'runtime 由平台守护，无写通道' },
      },
      custom: {
        read: {
          how: 'derived',
          collector: 'multica',
          cmd: ['multica', 'agent', 'tasks', '{agentId}'],
          paths: ['<task.work_dir>/CLAUDE.md'],
          note: '最近任务（agent tasks，每 agent 限 maxTasksPerAgent）+ 最新完成任务的 workdir CLAUDE.md 物化采样',
        },
        write: { type: 'none', advice: '采样/聚合型资产，无写通道' },
      },
    },
  },
];

export async function loadPlatforms(dir: string): Promise<LoadedPlatforms> {
  const diagnostics: Diagnostic[] = [];
  let files: string[] = [];
  try {
    files = (await readdir(dir)).filter((f) => f.endsWith('.yaml') || f.endsWith('.yml'));
  } catch {
    return { platforms: DEFAULT_PLATFORMS, diagnostics };
  }
  const platforms: PlatformDef[] = [];
  for (const f of files) {
    const path = join(dir, f);
    let def: unknown;
    try {
      def = parse(await readFile(path, 'utf8'));
    } catch (e) {
      diagnostics.push({ level: 'error', message: `[platforms] ${f} 解析失败：${String(e).slice(0, 150)}`, path });
      continue;
    }
    const issue = platformDefIssue(def);
    if (issue) {
      diagnostics.push({ level: 'error', message: `[platforms] ${f} 结构违规：${issue}`, path });
      continue;
    }
    platforms.push(def as PlatformDef);
  }
  return { platforms: platforms.length > 0 ? platforms : DEFAULT_PLATFORMS, diagnostics };
}

const isStrArr = (x: unknown): x is string[] => Array.isArray(x) && x.every((c) => typeof c === 'string');

/** 结构校验：YAML 不跑 zod，手工断言关键形状，坏文件出诊断并跳过（不进入执行路径） */
function platformDefIssue(def: unknown): string | null {
  if (!def || typeof def !== 'object') return 'not an object';
  const d = def as { id?: unknown; kinds?: unknown };
  if (typeof d.id !== 'string' || !d.id) return 'id 缺失或非字符串';
  if (d.kinds === undefined) return null;
  if (!d.kinds || typeof d.kinds !== 'object') return 'kinds 必须是映射';
  for (const [kind, v] of Object.entries(d.kinds as Record<string, unknown>)) {
    const kv = (v ?? {}) as { applicable?: unknown; note?: unknown };
    if (kv.applicable !== undefined) {
      if (kv.applicable !== false) return `kinds.${kind}.applicable 只接受 false（缺省即适用）`;
      if (typeof kv.note !== 'string') return `kinds.${kind}.applicable=false 需要 note 说明缘由`;
      const body = v as { read?: unknown; write?: unknown; fileWrite?: unknown };
      if (body.read !== undefined || body.write !== undefined || body.fileWrite !== undefined) {
        return `kinds.${kind}.applicable=false 时不得声明 read/write/fileWrite`;
      }
      continue;
    }
    const write = (v as { write?: unknown } | null)?.write as { type?: unknown; cmd?: unknown; platformIdFrom?: unknown; advice?: unknown } | undefined;
    const writeShapeIssue = (w: typeof write, field: string): string | null => {
      if (!w || typeof w.type !== 'string') return `kinds.${kind}.${field}.type 缺失`;
      if (!['file-write', 'command', 'none'].includes(w.type)) return `kinds.${kind}.${field}.type 未知：${String(w.type)}`;
      if (w.type === 'command') {
        if (!Array.isArray(w.cmd) || w.cmd.some((c) => typeof c !== 'string')) return `kinds.${kind}.${field}.cmd 必须是字符串数组`;
        if (w.platformIdFrom !== undefined && !['self', 'deployment'].includes(w.platformIdFrom as string)) {
          return `kinds.${kind}.${field}.platformIdFrom 只能是 self|deployment`;
        }
      }
      if (w.type === 'none' && typeof w.advice !== 'string') return `kinds.${kind}.${field}.advice 缺失（none 必须给建议）`;
      return null;
    };
    const writeIssue = writeShapeIssue(write, 'write');
    if (writeIssue) return writeIssue;
    const fileWrite = (v as { fileWrite?: unknown } | null)?.fileWrite as typeof write;
    if (fileWrite !== undefined) {
      const fileWriteIssue = writeShapeIssue(fileWrite, 'fileWrite');
      if (fileWriteIssue) return fileWriteIssue;
    }
    const read = (v as { read?: unknown } | null)?.read as
      | { how?: unknown; collector?: unknown; cmd?: unknown; detailCmd?: unknown; files?: unknown; paths?: unknown; note?: unknown }
      | undefined;
    if (read !== undefined) {
      if (!read || typeof read !== 'object') return `kinds.${kind}.read 必须是映射`;
      if (typeof read.how !== 'string' || !['cli', 'file', 'derived', 'none'].includes(read.how)) {
        return `kinds.${kind}.read.how 未知：${String(read.how)}`;
      }
      if (read.collector !== undefined && typeof read.collector !== 'string') return `kinds.${kind}.read.collector 必须是字符串`;
      if (read.files !== undefined && typeof read.files !== 'boolean') return `kinds.${kind}.read.files 必须是布尔值`;
      if (read.note !== undefined && typeof read.note !== 'string') return `kinds.${kind}.read.note 必须是字符串`;
      if (read.how === 'cli') {
        if (!isStrArr(read.cmd)) return `kinds.${kind}.read.how=cli 需要 cmd 字符串数组`;
        if (read.detailCmd !== undefined && !isStrArr(read.detailCmd)) return `kinds.${kind}.read.detailCmd 必须是字符串数组`;
      }
      if (read.how === 'file' && !isStrArr(read.paths)) return `kinds.${kind}.read.how=file 需要 paths 字符串数组`;
      if ((read.how === 'derived' || read.how === 'none') && typeof read.note !== 'string') {
        return `kinds.${kind}.read.how=${read.how} 需要 note 说明`;
      }
    }
  }
  return null;
}

/** 资产 → 所属平台（只读资产自声明 platforms；source.platform=none 显式豁免；声明内首个已注册平台生效） */
export function resolvePlatform(asset: Asset, platforms: PlatformDef[]): PlatformDef | undefined {
  if (asset.source.platform === 'none') return undefined;
  return platforms.find((p) => asset.platforms.includes(p.id));
}

export interface ResolvedWrite {
  write: PlatformWrite;
  platform: PlatformDef;
  platformId?: string;
  /** 不可执行时的说明（无通道 / platformId 缺失） */
  advice?: string;
}

/** 解析「以库为准物化」通道。返回 undefined = 该资产无对应平台 */
export function resolveWriteChannel(asset: Asset, assets: Asset[], platforms: PlatformDef[]): ResolvedWrite | undefined {
  const platform = resolvePlatform(asset, platforms);
  if (!platform) return undefined;
  const kindDef = platform.kinds?.[asset.kind];
  if (!kindDef) {
    return { write: { type: 'none', advice: `平台 ${platform.id} 未声明 kind ${asset.kind} 的写通道，请手动处理` }, platform };
  }
  if (kindDef.applicable === false || !kindDef.write) {
    return { write: { type: 'none', advice: `平台 ${platform.id} 无 ${asset.kind} 对象（契约声明不适用）` }, platform };
  }
  const write = kindDef.write;
  if (write.type === 'command') {
    const from = write.platformIdFrom ?? 'self';
    let platformId: string | undefined;
    if (from === 'self') {
      platformId = (asset.payload as { platformId?: string }).platformId;
    } else {
      const dep = assets.find(
        (a) => a.kind === 'deployment' && (a.payload as { agent?: string }).agent?.toLowerCase() === asset.name.toLowerCase()
      );
      platformId = (dep?.payload as { platformId?: string } | undefined)?.platformId;
    }
    if (!platformId) {
      return { write: { type: 'none', advice: `未找到 platformId（${from}），需手动执行` }, platform };
    }
    return { write, platform, platformId };
  }
  return { write, platform };
}

export interface PlatformAssetLite {
  id: string;
  name: string;
  summary: string;
  path: string;
  platformId?: string;
  enabled: boolean;
  provenance?: 'first-party' | 'third-party';
}

export interface PlatformKindView {
  kind: string;
  /** 是否在 platforms.d 声明（false = 仅有实有资产、YAML 未覆盖） */
  declared: boolean;
  /** true（序列化为 false）= 契约声明平台无此对象类型（不适用） */
  applicable?: false;
  note?: string;
  read?: PlatformRead;
  write?: PlatformWrite;
  assetCount: number;
  collectors: string[];
  assets: PlatformAssetLite[];
}

export interface PlatformView {
  id: string;
  label?: string;
  totalAssets: number;
  kinds: PlatformKindView[];
}

export interface PlatformsUnadapted {
  assetCount: number;
  kinds: Array<{ kind: string; count: number; paths: string[] }>;
}

export interface PlatformsView {
  platforms: PlatformView[];
  unadapted: PlatformsUnadapted;
}

const ASSETS_PER_KIND_CAP = 30;
const PATH_SAMPLE_CAP = 3;

function kindOrderIndex(kind: string): number {
  const i = (ASSET_KINDS as readonly string[]).indexOf(kind);
  return i === -1 ? ASSET_KINDS.length : i;
}

function sortKinds(a: string, b: string): number {
  return kindOrderIndex(a) - kindOrderIndex(b) || a.localeCompare(b);
}

function assetLite(a: Asset): PlatformAssetLite {
  const platformId = (a.payload as { platformId?: string }).platformId;
  return {
    id: a.id,
    name: a.name,
    summary: a.summary,
    path: a.source.path,
    ...(platformId !== undefined ? { platformId } : {}),
    enabled: a.enabled,
    ...(a.provenance ? { provenance: a.provenance } : {}),
  };
}

/** 平台页视图：平台契约（platforms.d）× 实时资产（resolvePlatform 归桶）。payload 不进视图。 */
export function buildPlatformsView(assets: Asset[], platforms: PlatformDef[]): PlatformsView {
  const buckets = new Map<string, Asset[]>();
  const unadapted: Asset[] = [];
  for (const a of assets) {
    const p = resolvePlatform(a, platforms);
    if (!p) unadapted.push(a);
    else buckets.set(p.id, [...(buckets.get(p.id) ?? []), a]);
  }

  const views: PlatformView[] = platforms.map((p) => {
    const bucket = buckets.get(p.id) ?? [];
    const byKind = new Map<string, Asset[]>();
    for (const a of bucket) byKind.set(a.kind, [...(byKind.get(a.kind) ?? []), a]);
    const declared = p.kinds ?? {};
    const kindKeys = [...new Set([...Object.keys(declared), ...byKind.keys()])].sort(sortKinds);
    const kinds: PlatformKindView[] = kindKeys.map((kind) => {
      const list = byKind.get(kind) ?? [];
      const d = declared[kind];
      return {
        kind,
        declared: kind in declared,
        ...(d?.applicable === false ? { applicable: false as const } : {}),
        ...(d?.note !== undefined ? { note: d.note } : {}),
        ...(d?.read ? { read: d.read } : {}),
        ...(d?.write ? { write: d.write } : {}),
        assetCount: list.length,
        collectors: [...new Set(list.map((a) => a.source.collector))].sort(),
        assets: list.slice(0, ASSETS_PER_KIND_CAP).map(assetLite),
      };
    });
    return {
      id: p.id,
      ...(p.label ? { label: p.label } : {}),
      totalAssets: bucket.length,
      kinds,
    };
  });

  const unadaptedByKind = new Map<string, Asset[]>();
  for (const a of unadapted) unadaptedByKind.set(a.kind, [...(unadaptedByKind.get(a.kind) ?? []), a]);
  return {
    platforms: views,
    unadapted: {
      assetCount: unadapted.length,
      kinds: [...unadaptedByKind.keys()].sort(sortKinds).map((kind) => {
        const list = unadaptedByKind.get(kind) ?? [];
        return { kind, count: list.length, paths: list.slice(0, PATH_SAMPLE_CAP).map((a) => a.source.path) };
      }),
    },
  };
}
