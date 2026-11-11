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
 * - kinds[kind].discovery：发现通道——怎么确定该 kind 的资产适配本平台（scan 枚举即归属 / declared 声明式发现）
 * - kinds[kind].read：读通道——怎么读到资产正文（file 本地读文件 / api Endpoint 读 / none），与写通道对应
 * - kinds[kind].write：写通道（以库为准物化）——file-write（本地文件）/ command（平台 CLI）/ none+advice（仅建议）
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

/**
 * 发现通道（owner 2026-11-11）：怎么确定某个资产适配于这个平台。
 * 两种模式（归属确认的判据）：
 * - scan：枚举即归属——枚举源本身就是平台域（本地路径扫描 / 平台清单命令 / 派生采样），命中即归属；
 * - declared：声明式发现——采集器只发现候选（如 dev-forge 仓库文件），归属由 registry.d 手工注册确认。
 * how 只是枚举介质（file/cli/derived），不改变模式语义。
 */
export interface PlatformDiscovery {
  mode: 'scan' | 'declared';
  how: 'file' | 'cli' | 'derived';
  /** 服务该 kind 的采集器名（文档归因；页面实时归因按资产 source.collector 汇总） */
  collector?: string;
  /** cli：清单/枚举命令（采集器追加 --output json） */
  cmd?: string[];
  /** file：扫描路径模式（支持 ~ 与 <project>/<devforge>/<task.work_dir> 占位） */
  paths?: string[];
  /** detail 采集是否登记附带文件 files[]（multica 经 skill get --with-content 登记）。
   *  附带文件编辑后实例库记录是否同步重写以此为准：file 型采集只读本体，缺省不登记。 */
  files?: boolean;
  /** declared：确认归属的 registry.d 条目 id（console/registry.d/*.yaml 的 entries[].id） */
  registry?: string;
  note?: string;
}

/** 读通道（owner 2026-11-11）：怎么读到资产的正文——本地资产读文件，远程资产走 Endpoint API。与写通道对应。 */
export interface PlatformRead {
  /** file=本地资产直接读 source.path；api=远程资产经平台 Endpoint/CLI 读取；none=无内容读取 */
  how: 'file' | 'api' | 'none';
  /** api：逐条取正文的命令（如 multica skill get {id} --with-content） */
  cmd?: string[];
  note?: string;
}

export interface PlatformKindDef {
  /** false = 平台结构上无此对象类型（不适用，非未适配）；声明后不得再有 discovery/read/write，note 必填说明 */
  applicable?: false;
  note?: string;
  discovery?: PlatformDiscovery;
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
        discovery: {
          mode: 'scan',
          how: 'file',
          collector: 'claude-projects',
          paths: ['<project>/CLAUDE.md', '~/.claude/rules/*/*.md'],
          note: '项目 CLAUDE.md（claude-projects）+ 全局规则包 rules/*（claude-global，第三方依赖架）',
        },
        read: { how: 'file' },
        write: { type: 'file-write' },
      },
      skill: {
        discovery: {
          mode: 'scan',
          how: 'file',
          collector: 'claude-global',
          paths: ['~/.claude/skills/*/SKILL.md', '~/.claude/.agents/skills/*/SKILL.md', '~/.claude/commands/*.md', '<project>/.claude/skills/*/SKILL.md'],
          note: '用户级技能/命令 + ECC .agents/skills（claude-global）；项目级 .claude/skills（claude-projects）',
        },
        read: { how: 'file' },
        write: { type: 'file-write' },
      },
      agent: {
        discovery: {
          mode: 'scan',
          how: 'file',
          collector: 'claude-projects',
          paths: ['<project>/.claude/agents/*.md'],
          note: 'CC subagent 定义文件（frontmatter name 去重，同名首见优先）',
        },
        read: { how: 'file' },
        write: { type: 'file-write' },
      },
      'hook-rule': {
        discovery: {
          mode: 'declared',
          how: 'file',
          collector: 'devforge-hooks',
          paths: ['<devforge>/claude-hooks/*.json'],
          registry: 'devforge-hooks-engine',
          note: '规则清单 JSON（devforge-hooks）；归属由 registry.d 条目盖章；settings.json 挂载由 claude-global 读（hook-registration）',
        },
        read: { how: 'file' },
        write: { type: 'file-write' },
      },
      'hook-script': {
        discovery: {
          mode: 'declared',
          how: 'file',
          collector: 'devforge-hooks',
          paths: ['<devforge>/claude-hooks/scripts/*.sh', '<devforge>/claude-hooks/scripts/lib/*.sh', '<project>/.claude/hooks/*.sh'],
          registry: 'devforge-hooks-engine',
          note: 'dev-forge 挂载脚本与 lib 经 registry.d 盖章；项目钩子（claude-projects）扫描直接声明——同 kind 混合',
        },
        read: { how: 'file' },
        write: { type: 'file-write' },
      },
      adapter: {
        discovery: {
          mode: 'declared',
          how: 'file',
          collector: 'devforge-adapters',
          paths: ['<devforge>/adapters/*'],
          registry: 'devforge-adapters',
          note: '本地适配脚本（.sh/.py/.js，提取 env 契约）；归属由 registry.d 条目盖章',
        },
        read: { how: 'file' },
        write: { type: 'file-write' },
      },
      patch: {
        discovery: {
          mode: 'declared',
          how: 'file',
          collector: 'devforge-patches',
          paths: ['<devforge>/patches/*.sh', '<devforge>/patches/*.state.json'],
          registry: 'devforge-patches',
          note: '本地补丁程序 + 应用基线 state（devforge-patches 实测漂移：升级覆盖/脚本已改/未记录基线）；补丁收编在 dev-forge 仓库，归属由 registry.d 条目盖章',
        },
        read: { how: 'file' },
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
        discovery: {
          mode: 'scan',
          how: 'file',
          collector: 'claude-global',
          paths: ['~/.claude/settings.json'],
          note: 'settings.json hooks 挂载点实测（claude-global 直接声明）；dev-forge 注册清单工件经 registry.d devforge-hook-registrations 盖章——同 kind 混合',
        },
        read: { how: 'file' },
        write: { type: 'file-write' },
      },
      'mcp-endpoint': {
        discovery: {
          mode: 'scan',
          how: 'file',
          collector: 'claude-global',
          paths: ['~/.claude/.mcp.json', '<project>/.mcp.json'],
          note: '用户级与项目级 MCP 清单（url 脱敏）',
        },
        read: { how: 'file' },
        write: { type: 'none', advice: '.mcp.json 手工编辑（含密钥字段，采集已脱敏，不做自动物化）' },
      },
      env: {
        discovery: {
          mode: 'scan',
          how: 'file',
          collector: 'claude-global',
          paths: ['~/.claude/settings.json', '<project>/.claude/settings.json', '<project>/.claude/settings.local.json'],
          note: '用户级 settings.json env（claude-global）+ 项目级 .claude/settings(.local).json env（claude-projects）；CC 层级合并中项目可覆盖全局（采集脱敏）',
        },
        read: { how: 'file', note: 'settings(.local).json env（采集脱敏）' },
        write: { type: 'none', advice: 'env 含敏感值且采集已脱敏，不支持物化' },
      },
      project: {
        discovery: {
          mode: 'scan',
          how: 'derived',
          collector: 'claude-projects',
          paths: ['console.config.yaml#workspaces', '<project>/'],
          note: '登记驱动：workspaces.projects 注册路径 → 扫描 .claude/CLAUDE.md/.mcp.json 等（harnesses 声明门控）',
        },
        read: { how: 'file', note: '项目登记本身无正文，内容读其子资产' },
        write: { type: 'none', advice: '项目登记在 console.config.yaml，不支持物化' },
      },
      report: {
        discovery: {
          mode: 'scan',
          how: 'file',
          collector: 'health',
          paths: ['~/.multica/toolchain-reports/latest.json', '~/.multica/arch-patrol/last_report.json'],
          note: '外部工具产出的健康报告（只读监控）',
        },
        read: { how: 'file' },
        write: { type: 'none', advice: '外部工具产出，只读' },
      },
      custom: {
        discovery: {
          mode: 'scan',
          how: 'derived',
          collector: 'claude-global',
          note: 'settings.json permissions/enabledPlugins 等杂项（各采集器附带产出）；跨平台聚合/运行时日志类 custom 无平台声明，落未适配桶',
        },
        read: { how: 'file', note: '读 settings.json 源文件（采集已脱敏）' },
        write: { type: 'none', advice: '聚合/观测型资产，无写通道' },
      },
      service: {
        applicable: false,
        note: 'Claude Code 无 service 对象：systemd 运行时探针是 dev 机器对象（source.platform=none），不归属任何平台',
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
        discovery: {
          mode: 'scan',
          how: 'cli',
          collector: 'multica',
          cmd: ['multica', 'skill', 'list'],
          files: true,
          note: '清单经 skill list（--output json），平台清单即平台域，命中即归属',
        },
        read: { how: 'api', cmd: ['multica', 'skill', 'get', '{id}', '--with-content'], note: '正文逐条 skill get --with-content（并发限流 5，上限 50 条）' },
        write: { type: 'command', cmd: ['multica', 'skill', 'update', '{platformId}', '--content', '{content}'], platformIdFrom: 'self' },
        fileWrite: { type: 'command', cmd: ['multica', 'skill', 'files', 'upsert', '{platformId}', '--path', '{filePath}', '--content', '{content}'], platformIdFrom: 'self' },
      },
      agent: {
        discovery: {
          mode: 'scan',
          how: 'cli',
          collector: 'multica',
          cmd: ['multica', 'agent', 'list'],
          note: 'instructions/skills/mcp_config/运行态均在 agent list JSON 单次返回',
        },
        read: { how: 'api', cmd: ['multica', 'agent', 'list'], note: 'instructions 在 agent list JSON 内，按 agent 取' },
        write: { type: 'command', cmd: ['multica', 'agent', 'update', '{platformId}', '--instructions', '{content}'], platformIdFrom: 'deployment' },
      },
      instruction: {
        discovery: {
          mode: 'scan',
          how: 'derived',
          collector: 'multica',
          paths: ['<task.work_dir>/CLAUDE.md'],
          note: 'agent instructions 随 agent list 采集（存于 agent 资产 payload）；另采样最新完成任务 workdir 的物化 CLAUDE.md（custom:multica-materialized-instructions，≤4 agent）作对账基准',
        },
        read: { how: 'file', note: '物化 CLAUDE.md 直接读 workdir 文件；agent instructions 在 agent list JSON（api）' },
        write: { type: 'none', advice: 'multica agent update <AGENT_ID> --instructions "$(cat <资产路径>)"（需指定目标 agent）' },
      },
      'autopilot-registration': {
        discovery: {
          mode: 'scan',
          how: 'cli',
          collector: 'multica',
          cmd: ['multica', 'autopilot', 'list'],
          note: '清单 autopilot list，平台清单即平台域，命中即归属',
        },
        read: { how: 'api', cmd: ['multica', 'autopilot', 'trigger-list', '{id}'], note: '触发器逐条 trigger-list（取前 20 个）' },
        write: { type: 'none', advice: 'multica autopilot 暂无通用更新命令：请在平台侧修改后重采，或改为「以生产为准」采纳进库' },
      },
      'autopilot-script': {
        discovery: {
          mode: 'declared',
          how: 'file',
          collector: 'devforge-autopilots',
          paths: ['<devforge>/autopilots/*.py', '<devforge>/autopilots/*.sh', '<devforge>/autopilots/configs/*.json', '<devforge>/autopilots/review-prompts/*'],
          registry: 'devforge-autopilots',
          note: 'dev-forge 巡逻脚本 + 配置 + agent 评审巡逻，归属由 registry.d 条目确认（multica autopilot 引用执行）',
        },
        read: { how: 'file' },
        write: { type: 'file-write' },
      },
      'hook-registration': {
        applicable: false,
        note: 'multica 平台无 hooks 设置与挂载入口；hook 资产只归属 claude-code（Owner 2026-11-11）',
      },
      'hook-rule': {
        applicable: false,
        note: 'multica 平台无 hooks 设置与挂载入口；hook 规则源在 dev-forge 仓库，归属 claude-code（Owner 2026-11-11）',
      },
      'hook-script': {
        applicable: false,
        note: 'multica 平台无 hooks 设置与挂载入口；hook 脚本在 dev-forge 仓库，归属 claude-code（Owner 2026-11-11）',
      },
      adapter: {
        applicable: false,
        note: 'multica 平台无 adapter 对象：adapters 为 dev-forge 本地脚本，归属 claude-code',
      },
      deployment: {
        discovery: {
          mode: 'scan',
          how: 'cli',
          collector: 'multica',
          cmd: ['multica', 'agent', 'list'],
          note: '部署实例与 agent 同一 JSON 产出（platformId/workspaceId/status 等运行态字段只落在 deployment）',
        },
        read: { how: 'api', cmd: ['multica', 'agent', 'list'], note: '运行态字段随 agent list JSON 返回' },
        write: { type: 'none', advice: '部署绑定由 multica daemon 管理，无物化通道' },
      },
      'mcp-endpoint': {
        discovery: {
          mode: 'scan',
          how: 'cli',
          collector: 'multica',
          cmd: ['multica', 'agent', 'list'],
          note: 'per-agent mcp_config.mcpServers 展开（采集时脱敏）',
        },
        read: { how: 'api', cmd: ['multica', 'agent', 'list'], note: 'mcp_config 随 agent list JSON 返回（已脱敏）' },
        write: { type: 'none', advice: 'per-agent MCP 配置含密钥（已脱敏），请在平台侧修改' },
      },
      service: {
        discovery: {
          mode: 'scan',
          how: 'cli',
          collector: 'multica',
          cmd: ['multica', 'runtime', 'list'],
          note: 'runtime 守护登记（取前 5）',
        },
        read: { how: 'api', cmd: ['multica', 'runtime', 'list'], note: 'runtime 状态随 runtime list 返回' },
        write: { type: 'none', advice: 'runtime 由平台守护，无写通道' },
      },
      custom: {
        discovery: {
          mode: 'scan',
          how: 'derived',
          collector: 'multica',
          cmd: ['multica', 'agent', 'tasks', '{agentId}'],
          paths: ['<task.work_dir>/CLAUDE.md'],
          note: '最近任务（agent tasks，每 agent 限 maxTasksPerAgent）+ 最新完成任务的 workdir CLAUDE.md 物化采样',
        },
        read: { how: 'file', note: '物化 CLAUDE.md 读 workdir 文件；任务元数据随 agent tasks 返回' },
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
      const body = v as { discovery?: unknown; read?: unknown; write?: unknown; fileWrite?: unknown };
      if (body.discovery !== undefined || body.read !== undefined || body.write !== undefined || body.fileWrite !== undefined) {
        return `kinds.${kind}.applicable=false 时不得声明 discovery/read/write/fileWrite`;
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
    const discovery = (v as { discovery?: unknown } | null)?.discovery as
      | { mode?: unknown; how?: unknown; collector?: unknown; cmd?: unknown; paths?: unknown; files?: unknown; registry?: unknown; note?: unknown }
      | undefined;
    if (!discovery) return `kinds.${kind}.discovery 缺失（适用 kind 必填发现通道）`;
    {
      if (typeof discovery !== 'object') return `kinds.${kind}.discovery 必须是映射`;
      if (typeof discovery.mode !== 'string' || !['scan', 'declared'].includes(discovery.mode)) {
        return `kinds.${kind}.discovery.mode 未知：${String(discovery.mode)}`;
      }
      if (typeof discovery.how !== 'string' || !['file', 'cli', 'derived'].includes(discovery.how)) {
        return `kinds.${kind}.discovery.how 未知：${String(discovery.how)}`;
      }
      if (discovery.collector !== undefined && typeof discovery.collector !== 'string') return `kinds.${kind}.discovery.collector 必须是字符串`;
      if (discovery.files !== undefined && typeof discovery.files !== 'boolean') return `kinds.${kind}.discovery.files 必须是布尔值`;
      if (discovery.note !== undefined && typeof discovery.note !== 'string') return `kinds.${kind}.discovery.note 必须是字符串`;
      if (discovery.registry !== undefined && typeof discovery.registry !== 'string') return `kinds.${kind}.discovery.registry 必须是字符串`;
      if (discovery.cmd !== undefined && !isStrArr(discovery.cmd)) return `kinds.${kind}.discovery.cmd 必须是字符串数组`;
      if (discovery.paths !== undefined && !isStrArr(discovery.paths)) return `kinds.${kind}.discovery.paths 必须是字符串数组`;
      if (discovery.how === 'cli' && !isStrArr(discovery.cmd)) return `kinds.${kind}.discovery.how=cli 需要 cmd 字符串数组`;
      if (discovery.how === 'file' && !isStrArr(discovery.paths)) return `kinds.${kind}.discovery.how=file 需要 paths 字符串数组`;
      if (discovery.mode === 'scan' && discovery.how === 'derived' && typeof discovery.note !== 'string') {
        return `kinds.${kind}.discovery.mode=scan how=derived 需要 note 说明派生来源`;
      }
      if (discovery.mode === 'declared' && typeof discovery.registry !== 'string') {
        return `kinds.${kind}.discovery.mode=declared 需要 registry 条目 id`;
      }
    }
    const read = (v as { read?: unknown } | null)?.read as { how?: unknown; cmd?: unknown; note?: unknown } | undefined;
    if (read !== undefined) {
      if (!read || typeof read !== 'object') return `kinds.${kind}.read 必须是映射`;
      if (typeof read.how !== 'string' || !['file', 'api', 'none'].includes(read.how)) {
        return `kinds.${kind}.read.how 未知：${String(read.how)}`;
      }
      if (read.cmd !== undefined && !isStrArr(read.cmd)) return `kinds.${kind}.read.cmd 必须是字符串数组`;
      if (read.note !== undefined && typeof read.note !== 'string') return `kinds.${kind}.read.note 必须是字符串`;
      if (read.how === 'api' && !isStrArr(read.cmd)) return `kinds.${kind}.read.how=api 需要 cmd 字符串数组`;
      if (read.how === 'none' && typeof read.note !== 'string') return `kinds.${kind}.read.how=none 需要 note 说明`;
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
  discovery?: PlatformDiscovery;
  /** declared 发现时盖章条目（discovery.registry）在 registry.d 里的 platforms 声明——展示完整归属链 */
  registryPlatforms?: string[];
  read?: PlatformRead;
  write?: PlatformWrite;
  assetCount: number;
  /** 该 kind 归属资产中的自建数（provenance=first-party，全量计数不受清单截断影响） */
  firstPartyCount: number;
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
  /** 至少声明了一个已注册平台的唯一资产数（跨平台共享资产只计一次，供页头汇总） */
  declaredCount: number;
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

/**
 * 平台页视图：平台契约（platforms.d）× 实时资产。payload 不进视图。
 * 归桶只读资产自声明 platforms：声明了哪个已注册平台，就出现在那个平台的页面
 * （跨平台共享资产在多个平台页都显示）；无任何声明 → 未适配桶。
 * （resolvePlatform 的 first-match-wins 只用于写通道解析，不用于页面归桶。）
 */
export function buildPlatformsView(
  assets: Asset[],
  platforms: PlatformDef[],
  /** registry.d 条目（仅取 id/platforms）：declared 发现的盖章声明原样带出，供页面展示完整归属链 */
  registryEntries: Array<{ id: string; platforms?: string[] }> = []
): PlatformsView {
  const registryPlatformsById = new Map(registryEntries.map((e) => [e.id, e.platforms]));
  const buckets = new Map<string, Asset[]>();
  const unadapted: Asset[] = [];
  let declaredCount = 0;
  for (const a of assets) {
    if (a.source.platform === 'none') {
      unadapted.push(a);
      continue;
    }
    const hit = platforms.filter((p) => a.platforms.includes(p.id));
    if (hit.length === 0) {
      unadapted.push(a);
    } else {
      declaredCount += 1;
      for (const p of hit) buckets.set(p.id, [...(buckets.get(p.id) ?? []), a]);
    }
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
        ...(d?.discovery ? { discovery: d.discovery } : {}),
        ...(d?.discovery?.registry && registryPlatformsById.get(d.discovery.registry)?.length
          ? { registryPlatforms: registryPlatformsById.get(d.discovery.registry) }
          : {}),
        ...(d?.read ? { read: d.read } : {}),
        ...(d?.write ? { write: d.write } : {}),
        assetCount: list.length,
        firstPartyCount: list.filter((a) => a.provenance === 'first-party').length,
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
    declaredCount,
    unadapted: {
      assetCount: unadapted.length,
      kinds: [...unadaptedByKind.keys()].sort(sortKinds).map((kind) => {
        const list = unadaptedByKind.get(kind) ?? [];
        return { kind, count: list.length, paths: list.slice(0, PATH_SAMPLE_CAP).map((a) => a.source.path) };
      }),
    },
  };
}
