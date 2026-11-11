import { z } from 'zod';

export const ASSET_KINDS = [
  'agent',
  // 部署实例：agent 本体 × 运行环境（platform/workspace）的绑定。运行时状态（platformId、
  // workspaceId、status 等）只允许出现在 deployment，agent 本体保持环境无关（Owner 原则 2026-11-03）
  'deployment',
  'instruction',
  'skill',
  'hook-registration',
  'hook-rule',
  'hook-script',
  'service',
  // autopilot 拆二（Owner 2026-11-11，对齐 hook 三分法）：registration = multica 平台注册项
  // （multica:// 源，CLI 采集），script = dev-forge 本地脚本/配置/评审巡逻（扫描源）。
  // 单一 autopilot kind 把平台对象与本地脚本混为一谈，是平台页归属错位的根因。
  'autopilot-registration',
  'autopilot-script',
  'adapter',
  // 本地补丁：我们对第三方文件的修改（hindsight-local-mods 等）。第三方文件本体仍归
  // 第三方，改动以 patch 资产名义注册为自建；payload 记录应用事实基线 + drift 实测状态
  'patch',
  'mcp-endpoint',
  'project',
  'report',
  'env',
  'custom',
] as const;

export const RELATION_TYPES = [
  'mounts',
  'references',
  'schedules',
  'runs-as',
  'derived-from',
  'gates',
] as const;

const kindEnum = z.enum(ASSET_KINDS);

export const attachSchema = z.object({
  level: z.enum(['user', 'workspace', 'project', 'agent', 'platform']),
  ref: z.string().optional(),
});

export const appliesSchema = z.object({
  workspaces: z.array(z.string()).optional(),
  projects: z.array(z.string()).optional(),
  agents: z
    .object({
      include: z.array(z.string()).optional(),
      except: z.array(z.string()).optional(),
    })
    .optional(),
  origin: z.enum(['native', 'overlay']).optional(),
});

/** 通用 metadata 词汇表——所有 kind 通用的属性标签（registry.d 声明盖戳 > 采集器推断） */
export const META_LIFECYCLE = ['stable', 'experimental', 'deprecated'] as const;
export const META_CRITICALITY = ['high', 'medium', 'low'] as const;
export const META_RUNTIME = ['claude-code', 'multica', 'both', 'standalone'] as const;

export const metaSchema = z.object({
  owner: z.string().optional(),
  category: z.string().optional(),
  lifecycle: z.enum(META_LIFECYCLE).optional(),
  criticality: z.enum(META_CRITICALITY).optional(),
  runtime: z.enum(META_RUNTIME).optional(),
  docs: z.string().optional(),
  since: z.string().optional(),
  notes: z.string().optional(),
});

export const sourceSchema = z.object({
  collector: z.string(),
  path: z.string(),
  locator: z.string().optional(),
  sha256: z.string().optional(),
  mtime: z.string().optional(),
  git: z.object({ repo: z.string(), rev: z.string() }).optional(),
  /** 显式声明不属于任何平台（平台归属豁免）：落平台页未适配桶（与 platforms: [] 同义，双保险保留） */
  platform: z.literal('none').optional(),
});

/** 平台 id 注册（当前两个运行时；新增平台 = 扩这里 + 对应采集器/投影） */
export const PLATFORM_IDS = ['claude-code', 'multica'] as const;

/**
 * registry.d 声明 entry 契约：元信息层（归属/生命周期/平台声明），与资产 payload 契约互不重叠。
 * match 三档粒度：idPrefix/pathPrefix 前缀（自有文件系统域）、ids 精确清单（平台命名空间推荐）、
 * exclude 前缀命中后排除（平台自带资产剔除）。命中 = include 命中 && 无 exclude 命中。
 */
export const registryEntrySchema = z.object({
  id: z.string().min(1),
  match: z
    .object({
      idPrefix: z.string().optional(),
      pathPrefix: z.string().optional(),
      ids: z.array(z.string()).optional(),
      exclude: z
        .object({
          idPrefix: z.array(z.string()).optional(),
          pathPrefix: z.array(z.string()).optional(),
          ids: z.array(z.string()).optional(),
        })
        .optional(),
    })
    .optional(),
  platforms: z.array(z.enum(PLATFORM_IDS)).optional(),
  meta: metaSchema.optional(),
});

export type RegistryDeclaration = z.infer<typeof registryEntrySchema>;

/**
 * Per-kind payload 契约：字段取自各内置采集器实际产出 + 消费端（UI/effective/platforms/reconcile）
 * 实际读取的交集。语义是「已知名键的类型约束」，不是「必填字段清单」：
 * - 全部字段 optional（缺失不报错）——REST 推送 / collectors.d 外部脚本可以只给子集
 * - looseObject 允许未知键透传（overlay 盖戳的 registry、未来新增字段）
 * - 已知键类型不符即拒绝——这是 payload 漂移的实际防线
 * registry.d 声明是元信息层（归属/生命周期/平台声明），其字段不属于这里。
 */
const headingSchema = z.object({ level: z.number(), text: z.string() });

const agentPayload = z.looseObject({
  // CC subagent（claude-projects 从 .claude/agents/*.md 采集）
  subagent: z.boolean().optional(),
  project: z.string().optional(),
  frontmatter: z.string().optional(),
  bodyLines: z.number().optional(),
  // multica 平台 agent（环境无关字段；运行时状态归 deployment）
  description: z.string().optional(),
  instructions: z.string().optional(),
  instructionsHash: z.string().optional(),
  model: z.string().optional(),
  thinkingLevel: z.string().optional(),
  skills: z.array(z.object({ name: z.string(), id: z.string().optional(), description: z.string().optional(), enabled: z.boolean().optional() })).optional(),
  disabledRuntimeSkills: z.array(z.string()).optional(),
  mcp: z.record(z.string(), z.unknown()).optional(),
  mcpRedacted: z.boolean().optional(),
  customEnvKeyCount: z.number().optional(),
  customArgs: z.array(z.string()).optional(),
});

const deploymentPayload = z.looseObject({
  platform: z.string().optional(),
  agent: z.string().optional(),
  platformId: z.string().optional(),
  workspaceId: z.string().optional(),
  status: z.string().optional(),
  maxConcurrentTasks: z.number().optional(),
  runtimeId: z.string().optional(),
});

const instructionPayload = z.looseObject({
  group: z.string().optional(),
  basename: z.string().optional(),
  lines: z.number().optional(),
  headings: z.array(headingSchema).optional(),
  lang: z.string().optional(),
  content: z.string().optional(),
  contentHash: z.string().optional(),
  projectName: z.string().optional(),
});

const skillPayload = z.looseObject({
  hasBody: z.boolean().optional(),
  lines: z.number().optional(),
  scope: z.string().optional(),
  content: z.string().optional(),
  command: z.boolean().optional(),
  // multica 平台技能
  platformId: z.string().optional(),
  labels: z.array(z.string()).optional(),
  workspaceId: z.string().optional(),
  files: z.array(z.object({ path: z.string(), content: z.string().optional() })).optional(),
});

const hookRegistrationPayload = z.looseObject({
  // settings.json hooks 挂载点
  event: z.string().optional(),
  matcher: z.string().optional(),
  // dev-forge hooks-registration.json 清单（整份展开，含 hook_points/alias 等）
  stateSentinels: z.number().optional(),
});

const hookRulePayload = z.looseObject({
  harness: z.array(z.string()).optional(),
  whenKind: z.enum(['none', 'payload', 'ops', 'mixed']).optional(),
  on: z.array(z.string()).optional(),
  onExcept: z.array(z.string()).optional(),
  agents: z.object({ include: z.array(z.string()).optional(), except: z.array(z.string()).optional() }).optional(),
  repoGating: z.object({ in: z.array(z.string()).optional(), registered: z.boolean().optional() }).optional(),
  oneShot: z.string().optional(),
  whenHuman: z.string().optional(),
  actions: z.array(z.object({ op: z.string(), message: z.string().optional(), path: z.string().optional() })).optional(),
  blocking: z.boolean().optional(),
  versionNote: z.string().optional(),
  fileDeclaredScope: z.string().optional(),
  overlay: z.boolean().optional(),
});

const hookScriptPayload = z.looseObject({
  lines: z.number().optional(),
  purpose: z.string().optional(),
});

const servicePayload = z.looseObject({
  // systemd 单元：active/sub/is-enabled 均为 systemctl 原文（active|dead|disabled|enabled…）
  // repo-sync（devforge-launch）：active 为实值探测，enabled 为布尔（注册文件 enabled 取反）
  active: z.string().optional(),
  sub: z.string().optional(),
  enabled: z.union([z.string(), z.boolean()]).optional(),
  scope: z.string().optional(),
  execStart: z.string().optional(),
  envFile: z.string().optional(),
  mainPid: z.number().optional(),
  since: z.string().optional(),
  description: z.string().optional(),
  children: z.array(z.object({ pid: z.number(), up: z.string(), args: z.string() })).optional(),
  trigger: z.string().optional(),
  // repo-sync
  daemon: z.string().optional(),
  logDir: z.string().optional(),
  // Windows 登录桥
  script: z.union([z.string(), z.boolean()]).optional(),
  taskStatus: z.string().optional(),
  stale: z.boolean().optional(),
  note: z.string().optional(),
});

const autopilotRegistrationPayload = z.looseObject({
  // multica 平台注册项（autopilot list / trigger-list）
  platformId: z.string().optional(),
  description: z.string().optional(),
  assignee: z.string().optional(),
  status: z.string().optional(),
  triggers: z.array(z.object({
    id: z.string(),
    kind: z.string(),
    cron_expression: z.string().optional(),
    timezone: z.string().optional(),
    enabled: z.boolean().optional(),
    next_run_at: z.string().optional(),
    label: z.string().optional(),
  })).optional(),
  lastRunAt: z.string().optional(),
  lastRunStatus: z.string().optional(),
  nextRunAt: z.string().optional(),
  workspaceId: z.string().optional(),
});

const autopilotScriptPayload = z.looseObject({
  // dev-forge 本地脚本型 / 配置 / agent 评审型
  script: z.boolean().optional(),
  lines: z.number().optional(),
  purpose: z.string().optional(),
  reviewKind: z.string().optional(),
  templates: z.array(z.string()).optional(),
  content: z.string().optional(),
});

const adapterPayload = z.looseObject({
  envContract: z.array(z.string()).optional(),
  lines: z.number().optional(),
});

const patchPayload = z.looseObject({
  // applied = 基线全匹配；drifted = 目标文件/上游版本变了；stale = 补丁脚本自身改过未重跑；unverified = 尚无 state 记录
  state: z.enum(['applied', 'drifted', 'stale', 'unverified']).optional(),
  appliedAt: z.string().optional(),
  applierSha256: z.string().optional(),
  anchor: z.object({ package: z.string().optional(), version: z.string().optional() }).optional(),
  anchorDrift: z.boolean().optional(),
  targets: z.array(z.object({ path: z.string(), sha256: z.string().nullable(), note: z.string().optional() })).optional(),
  driftedTargets: z.array(z.object({ path: z.string(), note: z.string().optional(), reason: z.string() })).optional(),
  targetCount: z.number().optional(),
});

const mcpEndpointPayload = z.looseObject({
  transport: z.string().optional(),
  command: z.string().optional(),
  args: z.array(z.string()).optional(),
  url: z.string().optional(),
  config: z.record(z.string(), z.unknown()).optional(),
  perAgent: z.boolean().optional(),
});

const projectPayload = z.looseObject({
  path: z.string().optional(),
  git: z.string().optional(),
  workspace: z.string().optional(),
  workspaceName: z.string().optional(),
  harnesses: z.array(z.string()).optional(),
  missing: z.boolean().optional(),
  hasClaudeMd: z.boolean().optional(),
  claudeMdLines: z.number().optional(),
  claudeMdHash: z.string().optional(),
  hasSettings: z.boolean().optional(),
  hooksScripts: z.number().optional(),
  skills: z.array(z.string()).optional(),
  agents: z.array(z.string()).optional(),
  mcpServers: z.array(z.string()).optional(),
});

const reportPayload = z.looseObject({
  health: z.string().optional(),
  generatedAt: z.string().optional(),
  redlineCount: z.number().optional(),
  redlines: z.array(z.unknown()).optional(),
  dimensions: z.unknown().optional(),
  inputMissing: z.unknown().optional(),
  exitCode: z.number().optional(),
  report: z.record(z.string(), z.unknown()).optional(),
});

const envPayload = z.looseObject({
  values: z.record(z.string(), z.unknown()).optional(),
  count: z.number().optional(),
});

export const payloadSchemas: Record<AssetKind, z.ZodType> = {
  agent: agentPayload,
  deployment: deploymentPayload,
  instruction: instructionPayload,
  skill: skillPayload,
  'hook-registration': hookRegistrationPayload,
  'hook-rule': hookRulePayload,
  'hook-script': hookScriptPayload,
  service: servicePayload,
  'autopilot-registration': autopilotRegistrationPayload,
  'autopilot-script': autopilotScriptPayload,
  adapter: adapterPayload,
  patch: patchPayload,
  'mcp-endpoint': mcpEndpointPayload,
  project: projectPayload,
  report: reportPayload,
  env: envPayload,
  // custom 是通用兜底 kind（sessions/activity/plugins/recent-tasks…），不做字段约束
  custom: z.looseObject({}),
};

export const assetBase = {
  kind: kindEnum,
  name: z.string(),
  summary: z.string().default(''),
  attach: attachSchema,
  applies: appliesSchema.optional(),
  enforcement: z.enum(['enforced', 'advisory', 'derived']),
  platforms: z.array(z.string()).default([]),
  provenance: z.enum(['first-party', 'third-party']),
  tags: z.array(z.string()).default([]),
  owner: z.string().optional(),
  meta: metaSchema.optional(),
  enabled: z.boolean().default(true),
  source: sourceSchema,
  payload: z.record(z.string(), z.unknown()).default({}),
};

export const assetSchema = z
  .object({ id: z.string().min(3), ...assetBase })
  .superRefine((a, ctx) => {
    const prefix = `${a.kind}:`;
    if (!a.id.startsWith(prefix)) {
      ctx.addIssue({
        code: 'custom',
        message: `id prefix must be "${prefix}" (got "${a.id}")`,
      });
    }
    const payloadCheck = payloadSchemas[a.kind].safeParse(a.payload);
    if (!payloadCheck.success) {
      for (const issue of payloadCheck.error.issues.slice(0, 5)) {
        ctx.addIssue({
          code: 'custom',
          message: `payload/${a.kind} ${issue.path.join('.') || '(root)'}: ${issue.message}`,
        });
      }
    }
  });

/** 单资产校验（采集出口 fail-open 用）：返回首个 payload 违规描述，null = 通过 */
export function assetPayloadIssue(a: Pick<Asset, 'id' | 'kind' | 'payload'>): string | null {
  const check = payloadSchemas[a.kind]?.safeParse(a.payload);
  if (!check || check.success) return null;
  const issue = check.error.issues[0];
  return `${issue.path.join('.') || '(root)'}: ${issue.message}`;
}

export const relationSchema = z.object({
  from: z.string(),
  to: z.string(),
  type: z.enum(RELATION_TYPES),
});

export const diagnosticSchema = z.object({
  level: z.enum(['info', 'warn', 'error']),
  message: z.string(),
  path: z.string().optional(),
});

export const collectionSchema = z.object({
  collector: z.string(),
  collectedAt: z.string(),
  assets: z.array(assetSchema).default([]),
  relations: z.array(relationSchema).default([]),
  diagnostics: z.array(diagnosticSchema).default([]),
});

export type AssetKind = (typeof ASSET_KINDS)[number];
export type RelationType = (typeof RELATION_TYPES)[number];
export type Asset = z.infer<typeof assetSchema>;
export type Relation = z.infer<typeof relationSchema>;
export type Diagnostic = z.infer<typeof diagnosticSchema>;
export type Collection = z.infer<typeof collectionSchema>;
export type Attach = z.infer<typeof attachSchema>;
export type Applies = z.infer<typeof appliesSchema>;

export type Meta = z.infer<typeof metaSchema>;
