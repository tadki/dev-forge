import type { Asset, Relation } from '@forge/schema';
import { join } from 'node:path';
import { readText, sha256 } from '../util.js';
import { asset, type Collector, type CollectContext } from '../types.js';
import { redactObject } from '../redact.js';

interface MulticaAgent {
  id: string;
  name: string;
  description?: string;
  instructions?: string;
  model?: string;
  thinking_level?: string;
  status?: string;
  archived_at?: string | null;
  max_concurrent_tasks?: number;
  runtime_id?: string;
  workspace_id?: string;
  mcp_config?: { mcpServers?: Record<string, Record<string, unknown>> };
  mcp_config_redacted?: boolean;
  custom_args?: string[];
  custom_env_key_count?: number;
  has_custom_env?: boolean;
  skills?: Array<{ id: string; name: string; description?: string; enabled?: boolean }>;
  disabled_runtime_skills?: string[];
}

interface MulticaAutopilot {
  id: string;
  title: string;
  description?: string;
  assignee_id?: string;
  assignee_type?: string;
  status?: string;
  last_run_at?: string;
  last_run_status?: string;
  next_run_at?: string;
  workspace_id?: string;
  trigger_kinds?: string[];
}

interface MulticaSkill {
  id: string;
  name: string;
  description?: string;
  labels?: Array<{ name: string; color?: string }>;
  workspace_id?: string;
  /** skill get --with-content 时返回 SKILL.md 正文 */
  content?: string;
  /** skill get --with-content 时返回附加文件（脚本等），content 为文件正文 */
  files?: Array<{ path: string; content?: string }>;
}

interface MulticaTask {
  id: string;
  agent_id: string;
  issue_id?: string;
  status?: string;
  work_dir?: string;
  started_at?: string;
  completed_at?: string;
  result?: { session_id?: string; pr_url?: string; output?: string };
}

async function multicaJson<T>(
  ctx: { exec: CollectContext['exec'] },
  args: string[],
  timeoutMs: number
): Promise<T | null> {
  const r = await ctx.exec('multica', [...args, '--output', 'json'], timeoutMs);
  if (!r.ok || !r.stdout.trim()) return null;
  try {
    return JSON.parse(r.stdout) as T;
  } catch {
    return null;
  }
}

export const MULTICA_PREFIX_MARK = '<!-- BEGIN MULTICA-RUNTIME';

const IDENTITY_LINE = /\*\*You are:[^\n]*\n/;
const HARNESS_SUFFIX_MARK = '\n## Available Commands';

/**
 * 从物化 workdir CLAUDE.md 中提取 agent instructions 原文。
 * 文件结构（multica 生成）：BEGIN 注释 → harness 前段（Runtime/Background Safety/Agent Identity）
 * → instructions（原文）→ harness 后段（Available Commands …）→ END 注释。
 * 只剥第一行注释会把整个 harness 当 instructions，导致全部 agent 误报漂移。
 */
export function extractAgentInstructions(md: string): string {
  const beginIdx = md.indexOf(MULTICA_PREFIX_MARK);
  const endMarkerIdx = md.indexOf('<!-- END MULTICA-RUNTIME');
  let inner = md;
  if (beginIdx >= 0) {
    const beginEnd = md.indexOf('-->', beginIdx);
    inner = md.slice(beginEnd >= 0 ? beginEnd + 3 : beginIdx + MULTICA_PREFIX_MARK.length, endMarkerIdx > beginIdx ? endMarkerIdx : md.length);
  }
  const identity = inner.match(IDENTITY_LINE);
  let rest = identity ? inner.slice(identity.index! + identity[0].length) : inner;
  const suffixIdx = rest.indexOf(HARNESS_SUFFIX_MARK);
  if (suffixIdx >= 0) rest = rest.slice(0, suffixIdx);
  return rest.trim();
}

/**
 * 把新的 instructions 写回物化文件：保留 harness 前段（到 Agent Identity 行）与
 * 后段（## Available Commands 到 END 注释），只替换中间的 instructions 块。
 */
export function spliceAgentInstructions(existing: string, instructions: string): string {
  const body = instructions.trim();
  const beginIdx = existing.indexOf(MULTICA_PREFIX_MARK);
  const endMarkerIdx = existing.indexOf('<!-- END MULTICA-RUNTIME');
  if (beginIdx < 0 || endMarkerIdx < 0) {
    // 无标记文件（非 multica 生成）不做结构拼接，整体覆盖正文
    return `${body}\n`;
  }
  const beginEnd = existing.indexOf('-->', beginIdx);
  if (beginEnd < 0) return `${body}\n`;
  const afterBegin = existing.slice(beginEnd + 3, endMarkerIdx);
  const identity = afterBegin.match(IDENTITY_LINE);
  const prefixBlock = identity ? afterBegin.slice(0, identity.index! + identity[0].length).trim() : '';
  const rest = identity ? afterBegin.slice(identity.index! + identity[0].length) : afterBegin;
  const suffixIdx = rest.indexOf(HARNESS_SUFFIX_MARK);
  const suffixBlock = suffixIdx >= 0 ? rest.slice(suffixIdx).trim() : '';
  const head = existing.slice(0, beginEnd + 3).trimEnd();
  const endBlock = existing.slice(endMarkerIdx).trim();
  return [head, prefixBlock, body, suffixBlock, endBlock].filter(Boolean).join('\n\n') + '\n';
}

export const multicaCollector: Collector = {
  name: 'multica',
  mode: 'interval',
  intervalMs: 60_000,
  async collect(ctx) {
    const assets: Asset[] = [];
    const relations: Relation[] = [];
    const diagnostics = ctx.diagnostics;
    if (!ctx.config.multica.enabled) return { assets, relations, diagnostics };
    const t = ctx.config.multica.timeoutMs;

    const agents = await multicaJson<MulticaAgent[]>(ctx, ['agent', 'list'], t);
    const agentById = new Map<string, string>();
    const seenAgentNames = new Set<string>();
    if (Array.isArray(agents)) {
      for (const a of agents) {
        agentById.set(a.id, a.name);
        if (seenAgentNames.has(a.name.toLowerCase())) {
          diagnostics.push({ level: 'warn', message: `[multica] agent 名重复，跳过后出现的：${a.name}` });
          continue;
        }
        seenAgentNames.add(a.name.toLowerCase());
        const instructions = a.instructions ?? '';
        const agentId = `agent:${a.name.toLowerCase()}`;
        const deploymentId = `deployment:multica:${a.name.toLowerCase()}`;
        assets.push(
          asset({
            id: agentId,
            kind: 'agent',
            name: a.name,
            summary: (a.description ?? '').slice(0, 120) || `agent · ${a.model ?? ''}`,
            attach: { level: 'user' },
            enforcement: 'enforced',
            // multica 平台原生对象（multica:// 源即声明）。环境无关原则约束的是 payload 运行态
            // 字段（归 deployment），平台归属声明与此不冲突
            platforms: ['multica'],
            enabled: true,
            source: { collector: 'multica', path: 'multica://agents/' + a.id, locator: `$.agents[${a.id}]` },
            payload: {
              description: a.description,
              instructions: instructions.length > 60_000 ? instructions.slice(0, 60_000) + '\n…(截断)' : instructions,
              instructionsHash: instructions ? sha256(instructions) : undefined,
              model: a.model,
              thinkingLevel: a.thinking_level,
              skills: a.skills ?? [],
              disabledRuntimeSkills: a.disabled_runtime_skills ?? [],
              mcp: redactObject(a.mcp_config?.mcpServers ?? {}),
              mcpRedacted: a.mcp_config_redacted,
              customEnvKeyCount: a.custom_env_key_count ?? 0,
              customArgs: a.custom_args ?? [],
            },
            tags: [],
          })
        );
        assets.push(
          asset({
            id: deploymentId,
            kind: 'deployment',
            name: `${a.name} @ multica`,
            summary: `${a.status ?? '?'} · ws ${a.workspace_id?.slice(0, 8) ?? '—'} · 并发 ${a.max_concurrent_tasks ?? '—'}`,
            attach: { level: 'platform', ref: 'multica' },
            enforcement: 'enforced',
            platforms: ['multica'],
            enabled: !a.archived_at,
            source: { collector: 'multica', path: 'multica://agents/' + a.id, locator: `$.agents[${a.id}]` },
            payload: {
              platform: 'multica',
              agent: a.name,
              platformId: a.id,
              workspaceId: a.workspace_id,
              status: a.status,
              maxConcurrentTasks: a.max_concurrent_tasks,
              runtimeId: a.runtime_id,
            },
            tags: ['multica', ...(a.status === 'idle' ? ['idle'] : ['working'])],
          })
        );
        relations.push({ from: agentId, to: deploymentId, type: 'runs-as' });
        for (const [mcpName, def] of Object.entries(a.mcp_config?.mcpServers ?? {})) {
          assets.push(
            asset({
              id: `mcp-endpoint:multica-${a.name.toLowerCase()}-${mcpName}`,
              kind: 'mcp-endpoint',
              name: `${mcpName}（${a.name}）`,
              summary: 'per-agent mcp_config',
              attach: { level: 'agent', ref: a.name },
              enforcement: 'enforced',
              platforms: ['multica'],
              source: { collector: 'multica', path: 'multica://agents/' + a.id, locator: `$.mcp_config.mcpServers.${mcpName}` },
              payload: { transport: 'stdio', config: redactObject(def), perAgent: true },
              tags: ['mcp', 'multica'],
            })
          );
        }
      }
    } else {
      diagnostics.push({ level: 'warn', message: 'multica agent list 不可用（daemon 未运行或 CLI 失败）' });
    }

    const apResult = await multicaJson<{ autopilots?: MulticaAutopilot[] }>(ctx, ['autopilot', 'list'], t);
    const aps = apResult?.autopilots ?? [];
    for (const ap of aps.slice(0, 20)) {
      let triggers: Array<{ id: string; kind: string; cron_expression?: string; timezone?: string; enabled?: boolean; next_run_at?: string; label?: string }> = [];
      if (ap.id) {
        const tr = await multicaJson<{ triggers?: Array<{ id: string; kind: string; cron_expression?: string; timezone?: string; enabled?: boolean; next_run_at?: string; label?: string }> }>(
          ctx,
          ['autopilot', 'trigger-list', ap.id],
          t
        );
        triggers = tr?.triggers ?? [];
      }
      const assignee = ap.assignee_id ? agentById.get(ap.assignee_id) ?? ap.assignee_id : undefined;
      assets.push(
        asset({
          id: `autopilot-registration:${ap.id.slice(0, 8)}`,
          kind: 'autopilot-registration',
          name: ap.title,
          summary: `${assignee ? `${assignee} · ` : ''}${triggers.map((tr) => tr.cron_expression ?? tr.kind).join(' / ') || '无触发器'}`,
          attach: { level: 'platform', ref: 'multica' },
          applies: assignee ? { agents: { include: [assignee] }, origin: 'native' } : undefined,
          enforcement: 'enforced',
          platforms: ['multica'],
          enabled: ap.status === 'active',
          source: { collector: 'multica', path: 'multica://autopilots/' + ap.id },
          payload: {
            platformId: ap.id,
            description: (ap.description ?? '').slice(0, 4000),
            assignee,
            status: ap.status,
            triggers,
            lastRunAt: ap.last_run_at,
            lastRunStatus: ap.last_run_status,
            nextRunAt: ap.next_run_at ?? triggers.find((tr) => tr.next_run_at)?.next_run_at,
            workspaceId: ap.workspace_id,
          },
          tags: ['autopilot', 'multica', ...(ap.status === 'paused' ? ['paused'] : [])],
        })
      );
      // 与 dev-forge 脚本巡逻关联（标题含脚本名 → derived-from）
      for (const stem of ['agent_watchdog', 'issue_status_check', 'architecture_sweep', 'version_check', 'guard_pending']) {
        if (ap.title.toLowerCase().includes(stem.replace(/_/g, ' ')) || ap.title.toLowerCase().includes(stem) || (ap.description ?? '').includes(stem)) {
          relations.push({ from: `autopilot-script:${stem}`, to: `autopilot-registration:${ap.id.slice(0, 8)}`, type: 'derived-from' });
          break;
        }
      }
    }

    const skills = await multicaJson<MulticaSkill[]>(ctx, ['skill', 'list'], t);
    if (Array.isArray(skills)) {
      // skill get 并发限流（此前逐条串行 = 每轮采集 N+1 次 CLI 调用）
      const listed = skills.slice(0, 50);
      const CONCURRENCY = 5;
      const details: Array<MulticaSkill | null> = [];
      for (let i = 0; i < listed.length; i += CONCURRENCY) {
        const batch = await Promise.all(
          listed.slice(i, i + CONCURRENCY).map((s) =>
            multicaJson<MulticaSkill>(ctx, ['skill', 'get', s.id, '--with-content'], t).catch(() => null)
          )
        );
        details.push(...batch);
      }
      for (let idx = 0; idx < listed.length; idx++) {
        const s = listed[idx];
        const detail = details[idx];
        const body = detail?.content ?? '';
        const files = (detail?.files ?? []).flatMap((f) =>
          typeof f.content === 'string'
            ? [{ path: f.path, content: f.content.length <= 200_000 ? f.content : f.content.slice(0, 200_000) }]
            : []
        );
        assets.push(
          asset({
            id: `skill:multica-${s.name}`,
            kind: 'skill',
            name: s.name,
            summary: (s.description ?? '').slice(0, 120),
            attach: { level: 'platform', ref: 'multica' },
            enforcement: 'enforced',
            platforms: ['multica'],
            source: { collector: 'multica', path: 'multica://skills/' + s.id },
            payload: {
              platformId: s.id,
              labels: s.labels?.map((l) => l.name) ?? [],
              workspaceId: s.workspace_id,
              ...(body ? { content: body.length <= 200_000 ? body : body.slice(0, 200_000) } : {}),
              ...(files.length ? { files } : {}),
            },
            tags: ['skill', 'multica', 'platform'],
          })
        );
      }
    }

    // runtime + daemon
    const runtimes = await multicaJson<Array<{ id: string; name?: string; custom_name?: string; provider?: string; status?: string; last_seen_at?: string; metadata?: Record<string, unknown> }>>(ctx, ['runtime', 'list'], t);
    if (Array.isArray(runtimes)) {
      for (const rt of runtimes.slice(0, 5)) {
        assets.push(
          asset({
            id: `service:multica-runtime-${rt.id.slice(0, 8)}`,
            kind: 'service',
            name: `multica runtime · ${rt.custom_name ?? rt.name ?? rt.id.slice(0, 8)}`,
            summary: `provider ${rt.provider ?? '?'} · ${rt.status ?? '?'} · 最后在线 ${rt.last_seen_at ?? '—'}`,
            attach: { level: 'platform', ref: 'multica' },
            provenance: 'third-party',
            enforcement: 'enforced',
            platforms: ['multica'],
            source: { collector: 'multica', path: 'multica://runtimes/' + rt.id },
            payload: { ...redactObject(rt), active: rt.status, trigger: '平台守护登记' },
            tags: ['multica', 'runtime'],
          })
        );
      }
    }

    // 每 agent 最近任务（sessions/概览用）+ 最新 workdir CLAUDE.md 采样（迁移 diff 用）
    const recentTasks: Array<MulticaTask & { agentName?: string }> = [];
    const latestWorkdirs = new Map<string, { path: string; startedAt?: string }>();
    if (Array.isArray(agents)) {
      for (const a of agents) {
        const tasks = await multicaJson<MulticaTask[]>(ctx, ['agent', 'tasks', a.id, '--limit', String(ctx.config.multica.maxTasksPerAgent)], t);
        if (!Array.isArray(tasks)) continue;
        for (const task of tasks) {
          recentTasks.push({ ...task, agentName: a.name });
          if (task.work_dir && task.status === 'completed') {
            const prev = latestWorkdirs.get(a.name);
            if (!prev || (task.started_at ?? '') > (prev.startedAt ?? '')) {
              latestWorkdirs.set(a.name, { path: task.work_dir, startedAt: task.started_at });
            }
          }
        }
      }
    }
    if (recentTasks.length > 0) {
      assets.push(
        asset({
          id: 'custom:multica-recent-tasks',
          kind: 'custom',
          name: 'multica 最近任务',
          summary: `${recentTasks.length} 条（${new Set(recentTasks.map((t) => t.agentName)).size} agents）`,
          attach: { level: 'platform', ref: 'multica' },
          enforcement: 'derived',
          platforms: ['multica'],
          source: { collector: 'multica', path: 'multica://tasks' },
          payload: { tasks: recentTasks.slice(0, 100).map((t) => ({ id: t.id, agent: t.agentName, issue: t.issue_id, status: t.status, workDir: t.work_dir, startedAt: t.started_at, completedAt: t.completed_at, sessionId: t.result?.session_id, prUrl: t.result?.pr_url })) },
          tags: ['sessions', 'multica'],
        })
      );
    }
    const materialized: Array<{ agent: string; path: string; hash: string; body: string }> = [];
    for (const [agentName, { path: workdir }] of [...latestWorkdirs].slice(0, 4)) {
      const md = await readText(join(workdir, 'CLAUDE.md'));
      if (md === null) continue;
      const body = extractAgentInstructions(md);
      // 与 agent.instructions 同口径 60k + 截断标记：对账的 update-agent 动作以样本为权威内容，低限截断会造成平台侧数据丢失
      materialized.push({ agent: agentName, path: join(workdir, 'CLAUDE.md'), hash: sha256(body), body: body.length > 60_000 ? body.slice(0, 60_000) + '\n…(截断)' : body });
    }
    if (materialized.length > 0) {
      assets.push(
        asset({
          id: 'custom:multica-materialized-instructions',
          kind: 'custom',
          name: 'multica 物化 CLAUDE.md 样本',
          summary: `${materialized.length} 个 agent 的最新 workdir 采样`,
          attach: { level: 'platform', ref: 'multica' },
          enforcement: 'derived',
          platforms: ['multica'],
          source: { collector: 'multica', path: 'multica://workdirs' },
          payload: { samples: materialized },
          tags: ['reconcile', 'multica'],
        })
      );
    }

    return { assets, relations, diagnostics };
  },
};
